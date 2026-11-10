# FaceUnlock 설치 스크립트 공통 함수

$script:Clsid = '{02619F57-D8AD-4F76-907C-3B27103F8DCD}'
$script:InstallDir = Join-Path $env:ProgramFiles 'FaceUnlock'
$script:DataDir = Join-Path $env:ProgramData 'FaceUnlock'
$script:ConfigKey = 'HKLM:\SOFTWARE\FaceUnlock'
$script:SecretName = 'L$FaceUnlock'
$script:CpKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$script:Clsid"
$script:ClsidKey = "HKLM:\SOFTWARE\Classes\CLSID\$script:Clsid"
# 모델은 바뀔 수 있는 main 브랜치에서 받으므로 SHA256 으로 고정한다. 바뀐 모델은 "아무 얼굴이나 통과" 가 될 수 있다.
$script:Models = @{
    'face_detection_yunet_2023mar.onnx'   = @{ Url = 'https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx'; Sha256 = '8F2383E4DD3CFBB4553EA8718107FC0423210DC964F9F4280604804ED2552FA4' }
    'face_recognition_sface_2021dec.onnx' = @{ Url = 'https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx'; Sha256 = '0BA9FBFA01B5270C96627C4EF784DA859931E02F04419C829E83484087C34E79' }
}

function Get-FaceUnlockPaths {
    [pscustomobject]@{
        Clsid = $script:Clsid; InstallDir = $script:InstallDir; DataDir = $script:DataDir
        ConfigKey = $script:ConfigKey; CpKey = $script:CpKey; ClsidKey = $script:ClsidKey
        Verifier = Join-Path $script:InstallDir 'verifier\faceunlock.exe'
    }
}

function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '관리자 권한이 필요합니다. "관리자 권한으로 실행" 한 PowerShell 에서 다시 실행하세요.'
    }
}

function Read-YesNo([string]$Question, [bool]$Default = $false) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$Question $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a -match '^(y|yes|예|ㅇ)$'
}

# --- LSA 비밀 (SYSTEM/관리자만 읽을 수 있는 저장소) ------------------------
$lsaSource = @'
using System;
using System.Runtime.InteropServices;
using System.Security;

public static class FaceUnlockNative {
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES {
        public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes;
        public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
    }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES oa, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LogonUserW(string user, string domain, IntPtr password, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const uint POLICY_CREATE_SECRET = 0x20;

    // value 가 null 이면 비밀을 삭제한다.
    public static void StoreSecret(string name, SecureString value) {
        var oa = new LSA_OBJECT_ATTRIBUTES();
        IntPtr policy;
        uint st = LsaOpenPolicy(IntPtr.Zero, ref oa, POLICY_CREATE_SECRET, out policy);
        if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));
        IntPtr keyBuf = Marshal.StringToHGlobalUni(name);
        IntPtr secret = IntPtr.Zero, dataPtr = IntPtr.Zero;
        try {
            var key = new LSA_UNICODE_STRING { Length = (ushort)(name.Length * 2), MaximumLength = (ushort)(name.Length * 2), Buffer = keyBuf };
            if (value != null) {
                secret = Marshal.SecureStringToGlobalAllocUnicode(value);
                var data = new LSA_UNICODE_STRING { Length = (ushort)(value.Length * 2), MaximumLength = (ushort)(value.Length * 2), Buffer = secret };
                dataPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LSA_UNICODE_STRING)));
                Marshal.StructureToPtr(data, dataPtr, false);
            }
            st = LsaStorePrivateData(policy, ref key, dataPtr);
            // 삭제할 때 비밀이 없으면 STATUS_OBJECT_NAME_NOT_FOUND(0xC0000034) - 무시
            if (st != 0 && !(value == null && st == 0xC0000034))
                throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));
        } finally {
            if (secret != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(secret);
            if (dataPtr != IntPtr.Zero) Marshal.FreeHGlobal(dataPtr);
            Marshal.FreeHGlobal(keyBuf);
            LsaClose(policy);
        }
    }

    // 비밀번호가 맞는지 실제 로그온으로 확인한다 (세션은 만들지 않음).
    public static int TestLogon(string user, string domain, SecureString password) {
        IntPtr pw = Marshal.SecureStringToGlobalAllocUnicode(password);
        try {
            IntPtr token;
            if (LogonUserW(user, domain, pw, 2 /*INTERACTIVE*/, 0, out token)) { CloseHandle(token); return 0; }
            return Marshal.GetLastWin32Error();
        } finally { Marshal.ZeroFreeGlobalAllocUnicode(pw); }
    }
}
'@
if (-not ('FaceUnlockNative' -as [type])) { Add-Type -TypeDefinition $lsaSource -Language CSharp }

function Set-FaceUnlockSecret([Security.SecureString]$Password) { [FaceUnlockNative]::StoreSecret($script:SecretName, $Password) }
function Remove-FaceUnlockSecret { [FaceUnlockNative]::StoreSecret($script:SecretName, $null) }

function Get-AccountInfo {
    <# 잠금 해제할 계정을 묻는다. 로컬 계정 / Microsoft 계정 구분. #>
    $name = $env:USERNAME
    $local = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    $source = if ($local) { [string]$local.PrincipalSource } else { 'Unknown' }
    Write-Host "현재 사용자: $name (계정 종류: $source)"

    if ($source -eq 'MicrosoftAccount') {
        $guess = $null
        try {
            $guess = (Get-ChildItem 'HKCU:\Software\Microsoft\IdentityCRL\UserExtendedProperties' -ErrorAction Stop |
                Select-Object -First 1).PSChildName
        } catch { }
        $email = Read-Host "Microsoft 계정 이메일$(if ($guess) { " (Enter = $guess)" })"
        if ([string]::IsNullOrWhiteSpace($email)) { $email = $guess }
        if ([string]::IsNullOrWhiteSpace($email)) { throw '이메일이 필요합니다.' }
        return [pscustomobject]@{ UserName = $email.Trim(); Domain = 'MicrosoftAccount'; Kind = 'MicrosoftAccount' }
    }
    if ($source -in @('AzureAD', 'ActiveDirectory')) {
        Write-Warning '회사/학교 계정은 정책상 막혀 있을 수 있습니다. 계속 진행은 하지만 동작을 보장하지 않습니다.'
        $domain = if ($source -eq 'AzureAD') { 'AzureAD' } else { $env:USERDOMAIN }
        return [pscustomobject]@{ UserName = $name; Domain = $domain; Kind = $source }
    }
    return [pscustomobject]@{ UserName = $name; Domain = '.'; Kind = 'Local' }
}

function Set-FaceUnlockCredential {
    $acct = Get-AccountInfo
    Write-Host ''
    Write-Host '잠금 해제에 쓸 Windows 비밀번호를 입력하세요. (PIN 이 아니라 계정 비밀번호)' -ForegroundColor Cyan
    Write-Host '비밀번호는 SYSTEM 만 읽을 수 있는 LSA 저장소에 저장됩니다.'
    for ($i = 0; $i -lt 3; $i++) {
        $pw1 = Read-Host '비밀번호' -AsSecureString
        $pw2 = Read-Host '비밀번호 확인' -AsSecureString
        $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1)
        $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2)
        try {
            $same = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1) -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
        }
        if (-not $same) { Write-Warning '두 비밀번호가 다릅니다.'; continue }

        $testDomain = if ($acct.Domain -eq '.') { $env:COMPUTERNAME } else { $acct.Domain }
        $err = [FaceUnlockNative]::TestLogon($acct.UserName, $testDomain, $pw1)
        if ($err -eq 0) {
            Write-Host '비밀번호 확인 완료.' -ForegroundColor Green
        } else {
            Write-Warning "비밀번호 확인 실패 (Win32 오류 $err). 1326 = 이름 또는 비밀번호가 틀림."
            if (-not (Read-YesNo '그래도 저장할까요?')) { continue }
        }
        if (-not (Test-Path $script:ConfigKey)) { New-Item $script:ConfigKey -Force | Out-Null }
        Set-ItemProperty $script:ConfigKey -Name UserName -Value $acct.UserName
        Set-ItemProperty $script:ConfigKey -Name Domain -Value $acct.Domain
        Set-FaceUnlockSecret $pw1
        Write-Host "저장 완료: $($acct.Domain)\$($acct.UserName)" -ForegroundColor Green
        return
    }
    throw '비밀번호 설정을 3번 실패했습니다.'
}

function Initialize-DataDir {
    <# 얼굴 템플릿 폴더: SYSTEM + Administrators 만 접근. 일반 사용자가 남의 얼굴로 바꿔치기 못하게. #>
    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
    # ProgramData 는 일반 사용자도 폴더를 만들 수 있다. 미리 만든 사람이 소유자로 남으면 권한을 되돌릴 수 있으므로 소유자부터 바꾼다.
    & icacls.exe $script:DataDir /setowner '*S-1-5-32-544' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "폴더 소유자 설정 실패: $script:DataDir" }
    & icacls.exe $script:DataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "폴더 권한 설정 실패: $script:DataDir" }
}

function Install-Models([string]$ModelDir) {
    New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
    foreach ($name in $script:Models.Keys) {
        $m = $script:Models[$name]
        $dst = Join-Path $ModelDir $name
        if ((Test-Path $dst) -and (Get-FileHash $dst -Algorithm SHA256).Hash -eq $m.Sha256) { continue }
        Write-Host "모델 다운로드: $name"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $m.Url -OutFile $dst -UseBasicParsing
        if ((Get-FileHash $dst -Algorithm SHA256).Hash -ne $m.Sha256) {
            Remove-Item $dst -Force
            throw "모델 해시 불일치: $name (변조되었거나 원본이 바뀌었습니다)"
        }
    }
}

function Register-FaceUnlockProvider([string]$DllPath) {
    New-Item -Path $script:ClsidKey -Force | Out-Null
    Set-Item -Path $script:ClsidKey -Value 'FaceUnlock Credential Provider'
    New-Item -Path "$script:ClsidKey\InprocServer32" -Force | Out-Null
    Set-Item -Path "$script:ClsidKey\InprocServer32" -Value $DllPath
    Set-ItemProperty -Path "$script:ClsidKey\InprocServer32" -Name ThreadingModel -Value 'Apartment'
    New-Item -Path $script:CpKey -Force | Out-Null
    Set-Item -Path $script:CpKey -Value 'FaceUnlock'
}

function Unregister-FaceUnlockProvider {
    foreach ($k in @($script:CpKey, $script:ClsidKey)) {
        if (Test-Path $k) { Remove-Item $k -Recurse -Force }
    }
}

# 선택 옵션: 설치 때 바꾼 정책을 기록해 두었다가 제거 때 되돌린다.
$script:PolicyChanges = @(
    @{ Flag = 'SetDefaultProvider'; Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'DefaultCredentialProvider'; Value = $script:Clsid; Type = 'String' },
    @{ Flag = 'SetNoLockScreen'; Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'; Name = 'NoLockScreen'; Value = 1; Type = 'DWord' }
)

function Set-FaceUnlockPolicy([string]$Flag) {
    $p = $script:PolicyChanges | Where-Object { $_.Flag -eq $Flag }
    if (-not (Test-Path $p.Key)) { New-Item $p.Key -Force | Out-Null }
    $old = (Get-ItemProperty $p.Key -Name $p.Name -ErrorAction SilentlyContinue).($p.Name)
    if ($null -ne $old) { Set-ItemProperty $script:ConfigKey -Name "$Flag.Old" -Value ([string]$old) }
    New-ItemProperty -Path $p.Key -Name $p.Name -Value $p.Value -PropertyType $p.Type -Force | Out-Null
    Set-ItemProperty $script:ConfigKey -Name $Flag -Value 1 -Type DWord
}

function Restore-FaceUnlockPolicies {
    if (-not (Test-Path $script:ConfigKey)) { return }
    $cfg = Get-ItemProperty $script:ConfigKey
    foreach ($p in $script:PolicyChanges) {
        if ($cfg.PSObject.Properties[$p.Flag] -and $cfg.($p.Flag) -eq 1) {
            $oldProp = $cfg.PSObject.Properties["$($p.Flag).Old"]
            if ($oldProp) {
                $v = if ($p.Type -eq 'DWord') { [int]$oldProp.Value } else { $oldProp.Value }
                New-ItemProperty -Path $p.Key -Name $p.Name -Value $v -PropertyType $p.Type -Force | Out-Null
            } else {
                Remove-ItemProperty -Path $p.Key -Name $p.Name -ErrorAction SilentlyContinue
            }
            Write-Host "정책 복원: $($p.Name)"
        }
    }
}

Export-ModuleMember -Function * -Variable @()
