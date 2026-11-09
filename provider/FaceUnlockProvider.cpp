// FaceUnlock Credential Provider
//
// 잠금 화면/로그인 화면에 "얼굴 인식" 타일을 추가한다.
//   1. LogonUI 가 이 공급자를 불러오면(Advise) 백그라운드 스레드에서
//      <설치폴더>\verifier\faceunlock.exe verify 를 실행한다.
//   2. 종료 코드 0(얼굴 일치)이면 CredentialsChanged 로 LogonUI 에 알리고,
//      자동 로그온 대상으로 자신을 지정한다.
//   3. GetSerialization 에서 LSA 비밀(L$FaceUnlock)에 저장된 비밀번호로
//      KERB_INTERACTIVE_UNLOCK_LOGON 을 만들어 돌려준다.
//
// 설계 원칙: 무거운 작업(카메라, 얼굴 인식)은 별도 프로세스에서 한다.
// 이 DLL 은 LogonUI.exe 안에서 돌기 때문에, 여기서 죽으면 로그인 화면이 깨진다.

#include <windows.h>
#include <ntsecapi.h>
#include <credentialprovider.h>
#include <shlwapi.h>
#include <new>
#include <string>

#ifndef STATUS_SUCCESS
#define STATUS_SUCCESS ((NTSTATUS)0x00000000L)
#endif

// {02619F57-D8AD-4F76-907C-3B27103F8DCD}
static const CLSID CLSID_FaceUnlockProvider =
    {0x02619f57, 0xd8ad, 0x4f76, {0x90, 0x7c, 0x3b, 0x27, 0x10, 0x3f, 0x8d, 0xcd}};

static const wchar_t kConfigKey[] = L"SOFTWARE\\FaceUnlock";
static const wchar_t kSecretName[] = L"L$FaceUnlock";
static const DWORD kVerifyTimeoutMs = 20000;

static HINSTANCE g_hinst = nullptr;
static LONG g_cRef = 0;
static void DllAddRef() { InterlockedIncrement(&g_cRef); }
static void DllRelease() { InterlockedDecrement(&g_cRef); }

// ---------------------------------------------------------------------------
// 필드 정의
// ---------------------------------------------------------------------------
enum FIELD_ID { FI_TILEIMAGE = 0, FI_LABEL, FI_STATUS, FI_RETRY, FI_NUM_FIELDS };

struct FieldDef {
    CREDENTIAL_PROVIDER_FIELD_TYPE type;
    const wchar_t* label;
    CREDENTIAL_PROVIDER_FIELD_STATE state;
};

static const FieldDef kFields[FI_NUM_FIELDS] = {
    {CPFT_TILE_IMAGE, L"Image", CPFS_DISPLAY_IN_BOTH},
    {CPFT_LARGE_TEXT, L"얼굴 인식", CPFS_DISPLAY_IN_BOTH},
    {CPFT_SMALL_TEXT, L"Status", CPFS_DISPLAY_IN_SELECTED_TILE},
    {CPFT_COMMAND_LINK, L"다시 시도", CPFS_DISPLAY_IN_SELECTED_TILE},
};

// ---------------------------------------------------------------------------
// 유틸리티
// ---------------------------------------------------------------------------
static std::wstring ModuleDir() {
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(g_hinst, path, MAX_PATH);
    PathRemoveFileSpecW(path);
    return path;
}

static bool ReadRegString(const wchar_t* name, std::wstring& out) {
    wchar_t buf[512] = {};
    DWORD cb = sizeof(buf) - sizeof(wchar_t);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, kConfigKey, name, RRF_RT_REG_SZ, nullptr, buf, &cb) != ERROR_SUCCESS)
        return false;
    out = buf;
    return true;
}

static bool IsConfigured() {
    std::wstring user;
    return ReadRegString(L"UserName", user) && !user.empty();
}

// LSA 비밀에서 비밀번호를 읽는다 (SYSTEM/관리자만 가능). 호출자가 SecureZeroMemory 해야 함.
static bool ReadPassword(std::wstring& out) {
    LSA_OBJECT_ATTRIBUTES oa = {};
    LSA_HANDLE policy = nullptr;
    if (LsaOpenPolicy(nullptr, &oa, POLICY_GET_PRIVATE_INFORMATION, &policy) != STATUS_SUCCESS)
        return false;
    LSA_UNICODE_STRING key;
    key.Buffer = const_cast<PWSTR>(kSecretName);
    key.Length = (USHORT)(wcslen(kSecretName) * sizeof(wchar_t));
    key.MaximumLength = key.Length;
    PLSA_UNICODE_STRING data = nullptr;
    NTSTATUS st = LsaRetrievePrivateData(policy, &key, &data);
    LsaClose(policy);
    if (st != STATUS_SUCCESS || !data) return false;
    out.assign(data->Buffer, data->Length / sizeof(wchar_t));
    SecureZeroMemory(data->Buffer, data->Length);
    LsaFreeMemory(data);
    return true;
}

static void InitUnicodeString(UNICODE_STRING& us, const std::wstring& s) {
    us.Length = (USHORT)(s.size() * sizeof(wchar_t));
    us.MaximumLength = us.Length;
    us.Buffer = const_cast<PWSTR>(s.c_str());
}

// KERB_INTERACTIVE_UNLOCK_LOGON 을 버퍼 하나로 직렬화한다.
// 문자열 포인터는 버퍼 시작 기준 오프셋으로 바꿔 넣는다 (LogonUI 규약).
static HRESULT PackUnlockLogon(const std::wstring& domain, const std::wstring& user, const std::wstring& password,
                               CREDENTIAL_PROVIDER_USAGE_SCENARIO cpus, BYTE** ppb, DWORD* pcb) {
    KERB_INTERACTIVE_UNLOCK_LOGON kiul = {};
    KERB_INTERACTIVE_LOGON& kil = kiul.Logon;
    kil.MessageType = (cpus == CPUS_UNLOCK_WORKSTATION) ? KerbWorkstationUnlockLogon : KerbInteractiveLogon;
    InitUnicodeString(kil.LogonDomainName, domain);
    InitUnicodeString(kil.UserName, user);
    InitUnicodeString(kil.Password, password);

    DWORD cb = sizeof(kiul) + kil.LogonDomainName.Length + kil.UserName.Length + kil.Password.Length;
    BYTE* pb = (BYTE*)CoTaskMemAlloc(cb);
    if (!pb) return E_OUTOFMEMORY;

    KERB_INTERACTIVE_UNLOCK_LOGON* out = (KERB_INTERACTIVE_UNLOCK_LOGON*)pb;
    *out = kiul;
    BYTE* cursor = pb + sizeof(kiul);
    UNICODE_STRING* src[3] = {&kil.LogonDomainName, &kil.UserName, &kil.Password};
    UNICODE_STRING* dst[3] = {&out->Logon.LogonDomainName, &out->Logon.UserName, &out->Logon.Password};
    for (int i = 0; i < 3; ++i) {
        if (src[i]->Length) memcpy(cursor, src[i]->Buffer, src[i]->Length);
        dst[i]->Buffer = (PWSTR)(cursor - pb);
        cursor += src[i]->Length;
    }
    *ppb = pb;
    *pcb = cb;
    return S_OK;
}

static HRESULT NegotiateAuthPackage(ULONG* pkg) {
    HANDLE lsa = nullptr;
    if (LsaConnectUntrusted(&lsa) != STATUS_SUCCESS) return E_FAIL;
    LSA_STRING name;
    name.Buffer = (PCHAR) "Negotiate";
    name.Length = (USHORT)strlen(name.Buffer);
    name.MaximumLength = name.Length + 1;
    NTSTATUS st = LsaLookupAuthenticationPackage(lsa, &name, pkg);
    LsaDeregisterLogonProcess(lsa);
    return st == STATUS_SUCCESS ? S_OK : E_FAIL;
}

// 타일 이미지: 리소스 없이 간단한 얼굴 아이콘을 그린다.
static HBITMAP CreateTileBitmap() {
    const int size = 128;
    HDC screen = GetDC(nullptr);
    HDC dc = CreateCompatibleDC(screen);
    HBITMAP bmp = CreateCompatibleBitmap(screen, size, size);
    ReleaseDC(nullptr, screen);
    if (!dc || !bmp) {
        if (dc) DeleteDC(dc);
        if (bmp) DeleteObject(bmp);
        return nullptr;
    }
    HGDIOBJ old = SelectObject(dc, bmp);
    RECT rc = {0, 0, size, size};
    HBRUSH bg = CreateSolidBrush(RGB(0, 120, 212));
    FillRect(dc, &rc, bg);
    DeleteObject(bg);
    HPEN pen = CreatePen(PS_SOLID, 6, RGB(255, 255, 255));
    HGDIOBJ oldPen = SelectObject(dc, pen);
    HGDIOBJ oldBrush = SelectObject(dc, GetStockObject(NULL_BRUSH));
    Ellipse(dc, 28, 20, 100, 108);  // 얼굴
    Ellipse(dc, 46, 50, 54, 58);    // 눈
    Ellipse(dc, 74, 50, 82, 58);
    Arc(dc, 46, 60, 82, 92, 46, 80, 82, 80);  // 입
    SelectObject(dc, oldBrush);
    SelectObject(dc, oldPen);
    DeleteObject(pen);
    SelectObject(dc, old);
    DeleteDC(dc);
    return bmp;
}

class FaceUnlockProvider;

// ---------------------------------------------------------------------------
// Credential (타일 하나)
// ---------------------------------------------------------------------------
class FaceUnlockCredential final : public ICredentialProviderCredential {
public:
    explicit FaceUnlockCredential(FaceUnlockProvider* provider) : m_cRef(1), m_provider(provider) { DllAddRef(); }

    void Detach() { m_provider = nullptr; }

    // IUnknown
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&m_cRef); }
    IFACEMETHODIMP_(ULONG) Release() override {
        LONG c = InterlockedDecrement(&m_cRef);
        if (!c) delete this;
        return c;
    }
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_INVALIDARG;
        if (riid == IID_IUnknown || riid == IID_ICredentialProviderCredential) {
            *ppv = static_cast<ICredentialProviderCredential*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    // ICredentialProviderCredential
    IFACEMETHODIMP Advise(ICredentialProviderCredentialEvents* pcpce) override {
        if (m_events) m_events->Release();
        m_events = pcpce;
        if (m_events) m_events->AddRef();
        return S_OK;
    }
    IFACEMETHODIMP UnAdvise() override {
        if (m_events) m_events->Release();
        m_events = nullptr;
        return S_OK;
    }
    IFACEMETHODIMP SetSelected(BOOL* pbAutoLogon) override;
    IFACEMETHODIMP SetDeselected() override { return S_OK; }
    IFACEMETHODIMP GetFieldState(DWORD id, CREDENTIAL_PROVIDER_FIELD_STATE* pcpfs,
                                 CREDENTIAL_PROVIDER_FIELD_INTERACTIVE_STATE* pcpfis) override {
        if (id >= FI_NUM_FIELDS || !pcpfs || !pcpfis) return E_INVALIDARG;
        *pcpfs = kFields[id].state;
        *pcpfis = CPFIS_NONE;
        return S_OK;
    }
    IFACEMETHODIMP GetStringValue(DWORD id, PWSTR* ppsz) override;
    IFACEMETHODIMP GetBitmapValue(DWORD id, HBITMAP* phbmp) override {
        if (id != FI_TILEIMAGE || !phbmp) return E_INVALIDARG;
        *phbmp = CreateTileBitmap();
        return *phbmp ? S_OK : E_FAIL;
    }
    IFACEMETHODIMP GetCheckboxValue(DWORD, BOOL*, PWSTR*) override { return E_NOTIMPL; }
    IFACEMETHODIMP GetSubmitButtonValue(DWORD, DWORD*) override { return E_NOTIMPL; }
    IFACEMETHODIMP GetComboBoxValueCount(DWORD, DWORD*, DWORD*) override { return E_NOTIMPL; }
    IFACEMETHODIMP GetComboBoxValueAt(DWORD, DWORD, PWSTR*) override { return E_NOTIMPL; }
    IFACEMETHODIMP SetStringValue(DWORD, PCWSTR) override { return E_NOTIMPL; }
    IFACEMETHODIMP SetCheckboxValue(DWORD, BOOL) override { return E_NOTIMPL; }
    IFACEMETHODIMP SetComboBoxSelectedValue(DWORD, DWORD) override { return E_NOTIMPL; }
    IFACEMETHODIMP CommandLinkClicked(DWORD id) override;
    IFACEMETHODIMP GetSerialization(CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* pcpgsr,
                                    CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcs, PWSTR* ppszOptionalStatusText,
                                    CREDENTIAL_PROVIDER_STATUS_ICON* pcpsiOptionalStatusIcon) override;
    IFACEMETHODIMP ReportResult(NTSTATUS ntsStatus, NTSTATUS, PWSTR* ppszOptionalStatusText,
                                CREDENTIAL_PROVIDER_STATUS_ICON* pcpsiOptionalStatusIcon) override;

    void UpdateStatusField(const wchar_t* text) {
        if (m_events) m_events->SetFieldString(this, FI_STATUS, text);
    }

private:
    ~FaceUnlockCredential() {
        if (m_events) m_events->Release();
        DllRelease();
    }
    LONG m_cRef;
    FaceUnlockProvider* m_provider;  // 소유자. 공급자가 먼저 사라지면 Detach 로 끊는다.
    ICredentialProviderCredentialEvents* m_events = nullptr;
};

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------
class FaceUnlockProvider final : public ICredentialProvider {
public:
    FaceUnlockProvider() : m_cRef(1) {
        DllAddRef();
        InitializeCriticalSection(&m_lock);
        m_status = L"카메라를 바라보세요";
    }

    // IUnknown
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&m_cRef); }
    IFACEMETHODIMP_(ULONG) Release() override {
        LONG c = InterlockedDecrement(&m_cRef);
        if (!c) delete this;
        return c;
    }
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_INVALIDARG;
        if (riid == IID_IUnknown || riid == IID_ICredentialProvider) {
            *ppv = static_cast<ICredentialProvider*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    // ICredentialProvider
    IFACEMETHODIMP SetUsageScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO cpus, DWORD) override {
        if ((cpus != CPUS_LOGON && cpus != CPUS_UNLOCK_WORKSTATION) || !IsConfigured()) return E_NOTIMPL;
        m_cpus = cpus;
        if (!m_credential) {
            m_credential = new (std::nothrow) FaceUnlockCredential(this);
            if (!m_credential) return E_OUTOFMEMORY;
        }
        return S_OK;
    }
    IFACEMETHODIMP SetSerialization(const CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION*) override { return E_NOTIMPL; }
    IFACEMETHODIMP Advise(ICredentialProviderEvents* pcpe, UINT_PTR ctx) override {
        EnterCriticalSection(&m_lock);
        if (m_events) m_events->Release();
        m_events = pcpe;
        if (m_events) m_events->AddRef();
        m_adviseContext = ctx;
        LeaveCriticalSection(&m_lock);
        if (!m_attempted) StartRecognition();
        return S_OK;
    }
    IFACEMETHODIMP UnAdvise() override {
        EnterCriticalSection(&m_lock);
        if (m_events) m_events->Release();
        m_events = nullptr;
        LeaveCriticalSection(&m_lock);
        CancelRecognition();
        return S_OK;
    }
    IFACEMETHODIMP GetFieldDescriptorCount(DWORD* pdwCount) override {
        if (!pdwCount) return E_INVALIDARG;
        *pdwCount = FI_NUM_FIELDS;
        return S_OK;
    }
    IFACEMETHODIMP GetFieldDescriptorAt(DWORD id, CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR** ppcpfd) override {
        if (id >= FI_NUM_FIELDS || !ppcpfd) return E_INVALIDARG;
        auto* fd = (CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR*)CoTaskMemAlloc(sizeof(CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR));
        if (!fd) return E_OUTOFMEMORY;
        ZeroMemory(fd, sizeof(*fd));
        fd->dwFieldID = id;
        fd->cpft = kFields[id].type;
        HRESULT hr = SHStrDupW(kFields[id].label, &fd->pszLabel);
        if (FAILED(hr)) {
            CoTaskMemFree(fd);
            return hr;
        }
        *ppcpfd = fd;
        return S_OK;
    }
    IFACEMETHODIMP GetCredentialCount(DWORD* pdwCount, DWORD* pdwDefault, BOOL* pbAutoLogonWithDefault) override {
        if (!pdwCount || !pdwDefault || !pbAutoLogonWithDefault) return E_INVALIDARG;
        *pdwCount = m_credential ? 1 : 0;
        if (m_credential && IsMatched()) {
            *pdwDefault = 0;
            *pbAutoLogonWithDefault = TRUE;
        } else {
            *pdwDefault = CREDENTIAL_PROVIDER_NO_DEFAULT;
            *pbAutoLogonWithDefault = FALSE;
        }
        return S_OK;
    }
    IFACEMETHODIMP GetCredentialAt(DWORD idx, ICredentialProviderCredential** ppcpc) override {
        if (idx != 0 || !ppcpc || !m_credential) return E_INVALIDARG;
        return m_credential->QueryInterface(IID_ICredentialProviderCredential, (void**)ppcpc);
    }

    // --- 내부 ---------------------------------------------------------------
    bool IsMatched() const { return InterlockedCompareExchange(const_cast<LONG*>(&m_matched), 0, 0) != 0; }
    void ConsumeMatch() { InterlockedExchange(&m_matched, 0); }
    CREDENTIAL_PROVIDER_USAGE_SCENARIO Scenario() const { return m_cpus; }

    std::wstring Status() {
        EnterCriticalSection(&m_lock);
        std::wstring s = m_status;
        LeaveCriticalSection(&m_lock);
        return s;
    }
    void SetStatus(const wchar_t* s) {
        EnterCriticalSection(&m_lock);
        m_status = s;
        LeaveCriticalSection(&m_lock);
    }

    // 백그라운드에서 faceunlock.exe verify 를 실행한다. 이미 실행 중이면 무시.
    void StartRecognition() {
        if (InterlockedCompareExchange(&m_running, 1, 0) != 0) return;
        m_attempted = true;
        ConsumeMatch();
        SetStatus(L"얼굴 인식 중... 카메라를 바라보세요");
        if (m_cancel) CloseHandle(m_cancel);
        m_cancel = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        AddRef();  // 스레드가 끝날 때 Release
        HANDLE th = CreateThread(nullptr, 0, &FaceUnlockProvider::ThreadProc, this, 0, nullptr);
        if (th) {
            CloseHandle(th);
        } else {
            InterlockedExchange(&m_running, 0);
            SetStatus(L"얼굴 인식을 시작하지 못했습니다");
            Release();
        }
    }
    void CancelRecognition() {
        if (m_cancel) SetEvent(m_cancel);
    }

private:
    ~FaceUnlockProvider() {
        if (m_credential) {
            m_credential->Detach();
            m_credential->Release();
        }
        if (m_events) m_events->Release();
        if (m_cancel) CloseHandle(m_cancel);
        DeleteCriticalSection(&m_lock);
        DllRelease();
    }

    static DWORD WINAPI ThreadProc(LPVOID p) {
        auto* self = static_cast<FaceUnlockProvider*>(p);
        self->RunVerifier();
        InterlockedExchange(&self->m_running, 0);
        self->NotifyChanged();
        self->Release();
        return 0;
    }

    void RunVerifier() {
        std::wstring exe = ModuleDir() + L"\\verifier\\faceunlock.exe";
        std::wstring cmd = L"\"" + exe + L"\" verify";
        STARTUPINFOW si = {};
        si.cb = sizeof(si);
        PROCESS_INFORMATION pi = {};
        if (!CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr,
                            nullptr, &si, &pi)) {
            SetStatus(L"얼굴 인식 프로그램을 찾을 수 없습니다");
            return;
        }
        CloseHandle(pi.hThread);
        HANDLE waits[2] = {pi.hProcess, m_cancel};
        DWORD w = WaitForMultipleObjects(2, waits, FALSE, kVerifyTimeoutMs);
        DWORD code = 1;
        if (w == WAIT_OBJECT_0) {
            GetExitCodeProcess(pi.hProcess, &code);
        } else {
            TerminateProcess(pi.hProcess, 1);
            WaitForSingleObject(pi.hProcess, 2000);
            code = (w == WAIT_OBJECT_0 + 1) ? 0xFFFF : 1;
        }
        CloseHandle(pi.hProcess);

        switch (code) {
            case 0:
                InterlockedExchange(&m_matched, 1);
                SetStatus(L"얼굴이 확인되었습니다");
                break;
            case 2: SetStatus(L"등록된 얼굴이 없습니다 (Enroll.ps1 실행)"); break;
            case 3: SetStatus(L"카메라를 열 수 없습니다"); break;
            case 0xFFFF: break;  // 취소됨
            case 1: SetStatus(L"얼굴을 인식하지 못했습니다. '다시 시도'를 누르세요"); break;
            default: SetStatus(L"얼굴 인식 오류 (verify.log 확인)"); break;
        }
    }

    // LogonUI 에 자격 증명이 바뀌었음을 알린다 -> GetCredentialCount 가 다시 불린다.
    void NotifyChanged() {
        EnterCriticalSection(&m_lock);
        ICredentialProviderEvents* ev = m_events;
        UINT_PTR ctx = m_adviseContext;
        if (ev) ev->AddRef();
        LeaveCriticalSection(&m_lock);
        if (ev) {
            ev->CredentialsChanged(ctx);
            ev->Release();
        }
    }

    LONG m_cRef;
    CRITICAL_SECTION m_lock;
    CREDENTIAL_PROVIDER_USAGE_SCENARIO m_cpus = CPUS_INVALID;
    FaceUnlockCredential* m_credential = nullptr;
    ICredentialProviderEvents* m_events = nullptr;
    UINT_PTR m_adviseContext = 0;
    HANDLE m_cancel = nullptr;
    LONG m_running = 0;
    LONG m_matched = 0;
    bool m_attempted = false;
    std::wstring m_status;
};

// --- Credential 메서드 (Provider 정의 이후) ---------------------------------
IFACEMETHODIMP FaceUnlockCredential::SetSelected(BOOL* pbAutoLogon) {
    if (!pbAutoLogon) return E_INVALIDARG;
    *pbAutoLogon = (m_provider && m_provider->IsMatched()) ? TRUE : FALSE;
    return S_OK;
}

IFACEMETHODIMP FaceUnlockCredential::GetStringValue(DWORD id, PWSTR* ppsz) {
    if (id >= FI_NUM_FIELDS || !ppsz) return E_INVALIDARG;
    if (id == FI_STATUS) {
        std::wstring s = m_provider ? m_provider->Status() : L"";
        return SHStrDupW(s.c_str(), ppsz);
    }
    return SHStrDupW(kFields[id].label, ppsz);
}

IFACEMETHODIMP FaceUnlockCredential::CommandLinkClicked(DWORD id) {
    if (id != FI_RETRY || !m_provider) return E_INVALIDARG;
    m_provider->StartRecognition();
    UpdateStatusField(L"얼굴 인식 중... 카메라를 바라보세요");
    return S_OK;
}

IFACEMETHODIMP FaceUnlockCredential::GetSerialization(CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* pcpgsr,
                                                      CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcs,
                                                      PWSTR* ppszOptionalStatusText,
                                                      CREDENTIAL_PROVIDER_STATUS_ICON* pcpsiOptionalStatusIcon) {
    if (!pcpgsr || !pcpcs) return E_INVALIDARG;
    *pcpgsr = CPGSR_NO_CREDENTIAL_NOT_FINISHED;
    if (ppszOptionalStatusText) *ppszOptionalStatusText = nullptr;
    if (pcpsiOptionalStatusIcon) *pcpsiOptionalStatusIcon = CPSI_NONE;

    if (!m_provider || !m_provider->IsMatched()) {
        // 얼굴이 확인되지 않았으면 아무것도 넘기지 않는다.
        if (ppszOptionalStatusText) SHStrDupW(L"먼저 얼굴을 인식해야 합니다", ppszOptionalStatusText);
        return S_OK;
    }
    m_provider->ConsumeMatch();  // 한 번 쓰면 끝. 실패해도 자동 재시도 루프에 빠지지 않게.

    std::wstring user, domain, password;
    if (!ReadRegString(L"UserName", user) || !ReadPassword(password)) {
        if (ppszOptionalStatusText) SHStrDupW(L"저장된 로그인 정보를 읽지 못했습니다", ppszOptionalStatusText);
        if (pcpsiOptionalStatusIcon) *pcpsiOptionalStatusIcon = CPSI_ERROR;
        return S_OK;
    }
    if (!ReadRegString(L"Domain", domain) || domain.empty() || domain == L".") {
        wchar_t name[MAX_COMPUTERNAME_LENGTH + 1] = {};
        DWORD n = ARRAYSIZE(name);
        GetComputerNameW(name, &n);
        domain = name;
    }

    BYTE* pb = nullptr;
    DWORD cb = 0;
    HRESULT hr = PackUnlockLogon(domain, user, password, m_provider->Scenario(), &pb, &cb);
    SecureZeroMemory(&password[0], password.size() * sizeof(wchar_t));
    if (FAILED(hr)) return hr;

    ULONG pkg = 0;
    hr = NegotiateAuthPackage(&pkg);
    if (FAILED(hr)) {
        SecureZeroMemory(pb, cb);
        CoTaskMemFree(pb);
        return hr;
    }
    pcpcs->ulAuthenticationPackage = pkg;
    pcpcs->clsidCredentialProvider = CLSID_FaceUnlockProvider;
    pcpcs->rgbSerialization = pb;  // LogonUI 가 해제
    pcpcs->cbSerialization = cb;
    *pcpgsr = CPGSR_RETURN_CREDENTIAL_FINISHED;
    return S_OK;
}

IFACEMETHODIMP FaceUnlockCredential::ReportResult(NTSTATUS ntsStatus, NTSTATUS, PWSTR* ppszOptionalStatusText,
                                                  CREDENTIAL_PROVIDER_STATUS_ICON* pcpsiOptionalStatusIcon) {
    if (ppszOptionalStatusText) *ppszOptionalStatusText = nullptr;
    if (pcpsiOptionalStatusIcon) *pcpsiOptionalStatusIcon = CPSI_NONE;
    if (ntsStatus != STATUS_SUCCESS) {
        const wchar_t* msg = L"로그인 실패: 저장된 비밀번호가 바뀌었을 수 있습니다 (Set-Credential.ps1)";
        if (m_provider) m_provider->SetStatus(msg);
        UpdateStatusField(msg);
        if (ppszOptionalStatusText) SHStrDupW(msg, ppszOptionalStatusText);
        if (pcpsiOptionalStatusIcon) *pcpsiOptionalStatusIcon = CPSI_ERROR;
    }
    return S_OK;
}

// ---------------------------------------------------------------------------
// Class factory / DLL exports
// ---------------------------------------------------------------------------
class ClassFactory final : public IClassFactory {
public:
    IFACEMETHODIMP_(ULONG) AddRef() override { return 2; }  // 정적 객체
    IFACEMETHODIMP_(ULONG) Release() override { return 1; }
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_INVALIDARG;
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *ppv = static_cast<IClassFactory*>(this);
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override {
        if (!ppv) return E_INVALIDARG;
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        auto* p = new (std::nothrow) FaceUnlockProvider();
        if (!p) return E_OUTOFMEMORY;
        HRESULT hr = p->QueryInterface(riid, ppv);
        p->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock) override {
        lock ? DllAddRef() : DllRelease();
        return S_OK;
    }
};

static ClassFactory g_factory;

extern "C" {

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_hinst = hinst;
        DisableThreadLibraryCalls(hinst);
    }
    return TRUE;
}

STDAPI DllCanUnloadNow() { return g_cRef > 0 ? S_FALSE : S_OK; }

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv) {
    if (!ppv) return E_INVALIDARG;
    *ppv = nullptr;
    if (rclsid != CLSID_FaceUnlockProvider) return CLASS_E_CLASSNOTAVAILABLE;
    return g_factory.QueryInterface(riid, ppv);
}

}  // extern "C"
