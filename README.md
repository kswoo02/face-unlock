# FaceUnlock

노트북에 달린 **일반 웹캠**으로 얼굴을 인식해 Windows 잠금 화면을 해제합니다.
IR 카메라가 없어 Windows Hello 얼굴 인식을 쓸 수 없는 노트북(삼성 갤럭시 북 등)을 위한 프로젝트입니다.

> ⚠️ **보안 경고 — 반드시 읽어 주세요**
> - 일반 카메라는 실제 얼굴과 **사진·영상을 구분하지 못합니다.** 휴대폰에 띄운 내 사진으로도 풀릴 수 있습니다.
>   집에서 혼자 쓰는 개인 노트북에만 사용하세요.
> - 잠금을 풀려면 Windows **비밀번호를 PC에 저장**해야 합니다. 비밀번호는 SYSTEM 계정만 읽을 수 있는 LSA 저장소에 보관됩니다.
> - 잠금 화면 모듈이 문제를 일으켜도 기존 **PIN·지문·비밀번호 로그인은 그대로 남아** 있습니다. 복구 방법은 아래에 있습니다.
>
> 노트북에 IR 카메라가 있다면 이 프로젝트 대신 Windows Hello 를 쓰세요 → [`hello/`](hello/README.md)

## 동작 방식

```
Win+L ─▶ 잠금 화면(LogonUI)
           │  FaceUnlockProvider.dll (Credential Provider)
           │     └─ 백그라운드에서 실행 ─▶ verifier\faceunlock.exe verify
           │                                 ├ 웹캠 프레임 읽기 (OpenCV)
           │                                 ├ 얼굴 검출: YuNet
           │                                 ├ 얼굴 특징: SFace → 등록된 얼굴과 코사인 유사도
           │                                 └ 연속 3프레임 기준 통과 → 종료 코드 0
           │  ◀── 일치 ──┘
           └─ LSA 에 저장된 비밀번호로 자동 로그인 → 잠금 해제
```

- 카메라·얼굴 인식은 **별도 프로세스**에서 돌립니다. 잠금 화면 DLL 은 결과만 받으므로, 인식 프로그램이 죽어도 로그인 화면은 멀쩡합니다.
- 얼굴 데이터(`C:\ProgramData\FaceUnlock\face.npz`)는 **사진이 아니라 숫자 특징값**이며, SYSTEM·관리자만 접근할 수 있게 권한을 잠급니다.
- 인터넷 연결이나 클라우드 서비스는 쓰지 않습니다.

## 설치

1. GitHub 저장소의 **Actions** 탭 → 최신 `build` 실행 → **FaceUnlock** 아티팩트를 내려받아 압축을 풉니다.
   (태그 `v*` 를 붙이면 Releases 에 `FaceUnlock.zip` 이 올라갑니다.)
2. `installer\install.cmd` 를 더블클릭하고 관리자 권한 요청에 **예** 를 누릅니다.
3. 안내에 따라 진행합니다.
   1. 위험 안내 확인
   2. Windows **계정 비밀번호** 입력 (PIN 아님). Microsoft 계정이면 이메일도 확인합니다.
   3. 카메라 창이 뜨면 정면을 보며 고개를 조금씩 움직입니다 (15장 촬영).
   4. 확인 테스트: 10초 안에 카메라를 바라봅니다. **통과해야만** 잠금 화면에 등록됩니다.
   5. 선택 옵션: FaceUnlock 을 기본 로그인 방식으로 지정 / 잠금 화면 사진 건너뛰기 (둘 다 권장)
4. `Win + L` 로 잠그고 카메라를 바라보면 잠금이 해제됩니다.

## 관리

| 할 일 | 방법 (관리자 PowerShell, 설치 폴더 `C:\Program Files\FaceUnlock\installer`) |
| --- | --- |
| Windows 비밀번호를 바꿨을 때 | `.\Set-Credential.ps1` |
| 얼굴 다시 등록 (안경, 머리 스타일 변경 등) | `.\Enroll.ps1` |
| 인식 점수 확인 | `.\Enroll.ps1 -Test` |
| 완전 제거 | `.\Uninstall.ps1` (바꾼 정책도 되돌림) |

### 인식 기준 조정 — `C:\ProgramData\FaceUnlock\config.json`

| 키 | 기본값 | 의미 |
| --- | --- | --- |
| `threshold` | `0.45` | 유사도 기준. 높일수록 엄격 (남이 풀 확률↓, 내가 실패할 확률↑) |
| `consecutive` | `3` | 연속으로 기준을 넘어야 하는 프레임 수 |
| `timeout_sec` | `10` | 한 번 시도할 때 카메라를 켜 두는 시간 |
| `camera_index` | `0` | 카메라가 여러 대일 때 번호 |
| `min_face_px` | `80` | 이보다 작게 잡힌 얼굴(멀리 있는 사람)은 무시 |

`Enroll.ps1 -Test` 로 내 얼굴 점수(보통 0.6 이상)와 다른 사람 점수(보통 0.3 이하)를 보고 사이 값으로 정하세요.

## 문제 해결

| 증상 | 해결 |
| --- | --- |
| 잠금 화면에 "얼굴 인식" 타일이 없음 | 로그인 옵션 아이콘 중 얼굴 모양 선택. 그래도 없으면 `Install.ps1 -SkipEnroll` 재실행 |
| "카메라를 열 수 없습니다" | 다른 앱이 카메라 사용 중인지 확인. 설정 > 개인 정보 > 카메라 > "데스크톱 앱이 카메라에 액세스하도록 허용" 켜기 |
| "얼굴을 인식하지 못했습니다" | 조명 확인 → '다시 시도'. 반복되면 `Enroll.ps1` 로 재등록 |
| "로그인 실패: 저장된 비밀번호…" | `Set-Credential.ps1` |
| Microsoft 계정에서 로그인 실패 | 설정 > 계정 > 로그인 옵션 > "보안 강화를 위해 Microsoft 계정에 Windows Hello 로그인만 허용" **끄기** |
| 자세한 원인 | `C:\ProgramData\FaceUnlock\verify.log` |

### 비상 복구 (로그인 화면이 이상할 때)

1. 로그인 화면에서 **PIN·지문·비밀번호**로 로그인 → `Uninstall.ps1`.
2. 로그인 화면 자체가 뜨지 않으면: 로그인 화면 오른쪽 아래 전원 아이콘 → **Shift 누른 채 다시 시작**
   → 문제 해결 > 고급 옵션 > 시작 설정 > **안전 모드** → 로그인 후 관리자 cmd 에서:

```
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{02619F57-D8AD-4F76-907C-3B27103F8DCD}" /f
```

## 개발

```
provider/   C++ Credential Provider (CMake, MSVC 또는 mingw-w64)
verifier/   Python 얼굴 등록/확인 도구 (OpenCV YuNet + SFace) → PyInstaller 로 exe
installer/  설치·제거·비밀번호·재등록 PowerShell 스크립트
tests/      판정 로직 단위 테스트 (카메라 불필요)
hello/      IR 카메라가 있는 기기용 Windows Hello 점검/설정 스크립트
```

- 빌드: GitHub Actions(`.github/workflows/build.yml`)가 Windows 러너에서 DLL·exe 를 빌드하고 모델을 받아 패키징합니다.
- 테스트: `pip install numpy opencv-python-headless pytest && pytest tests`
- 로컬 DLL 빌드: `cmake -S provider -B build -A x64 && cmake --build build --config Release`

## 사용한 모델

- [YuNet](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet) — MIT
- [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) — Apache-2.0

모델 파일은 저장소에 넣지 않고 빌드/설치 시 opencv_zoo 에서 내려받습니다.
