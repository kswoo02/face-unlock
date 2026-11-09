# windows-hello-face-unlock

삼성 노트북(갤럭시 북 등) Windows 에서 **지문 대신 Windows Hello 얼굴 인식으로 잠금 해제**를
쓰도록 점검·설정을 도와주는 PowerShell 스크립트 모음입니다.

> ⚠️ **IR(적외선) 카메라가 있어야 합니다.** 일반 웹캠으로는 Windows Hello 얼굴 인식이 안 됩니다.
> 내 노트북에 있는지 모르겠다면 1단계 점검부터 하세요. 없으면 외장 Windows Hello 웹캠이 필요합니다.
> → [docs/HARDWARE.md](docs/HARDWARE.md)

## 구성

| 파일 | 하는 일 | 권한 |
| --- | --- | --- |
| `scripts/Check-HelloFace.ps1` | IR 카메라·얼굴 인식 장치·서비스·정책·ESS·PIN 상태 점검 (**읽기 전용**) | 일반 (관리자면 더 자세히) |
| `scripts/Enable-HelloFace.ps1` | 생체 인식 서비스 켜기 → Hello.Face 기능 설치 → 장치 재검색 → 얼굴 등록 화면 열기 | 관리자 |
| `run.cmd` | 더블클릭용: 점검 후 관리자 권한으로 설정 스크립트 실행 | — |
| `docs/HARDWARE.md` | 하드웨어 조건, 삼성 모델 확인법, 외장 웹캠, ESS 설명 | — |

## 사용법

### 가장 간단한 방법

1. 이 저장소를 내려받습니다 (Code > Download ZIP → 압축 해제).
2. `run.cmd` 를 더블클릭합니다.
3. 점검 결과를 확인하고, 관리자 권한 요청(UAC)에 "예"를 누릅니다.
4. 설정 앱의 얼굴 등록 화면이 뜨면 안내에 따라 카메라를 바라봅니다.
5. `Win + L` 로 잠근 뒤 카메라를 보면 잠금이 해제됩니다.

### PowerShell 로 직접

```powershell
# 1) 점검 (아무것도 바꾸지 않음)
powershell -ExecutionPolicy Bypass -File .\scripts\Check-HelloFace.ps1

# 2) 미리보기 — 무엇을 바꿀지만 출력
powershell -ExecutionPolicy Bypass -File .\scripts\Enable-HelloFace.ps1 -WhatIf

# 3) 실제 적용 (관리자 PowerShell)
powershell -ExecutionPolicy Bypass -File .\scripts\Enable-HelloFace.ps1
```

`Check-HelloFace.ps1` 종료 코드: `0` 준비 완료 / `1` 경고 있음 / `2` 차단 요인 있음.

## 등록 후 추천 설정

설정 > 계정 > 로그인 옵션 > 얼굴 인식(Windows Hello) 에서

- **"Windows Hello가 얼굴을 인식하면 자동으로 잠금 화면 해제"** 켜기 → 클릭 없이 바로 바탕화면
- **"인식률 향상"** 으로 안경 착용/미착용 등 추가 등록

## 스크립트가 일부러 하지 않는 것

보안과 직결되는 설정은 사용자가 직접 판단하도록 건드리지 않습니다.

- 그룹 정책으로 막힌 생체 인식 해제 (회사 관리 PC)
- 보안 강화 로그인(ESS) 끄기
- 지문 등록 삭제
- 일반 웹캠으로 얼굴 인식을 흉내 내는 우회 방식

## 문제 해결

| 증상 | 해결 |
| --- | --- |
| "이 옵션은 현재 사용할 수 없습니다" | IR 카메라 없음 또는 드라이버 문제 → Samsung Update 로 드라이버 업데이트, 없으면 외장 웹캠 |
| 외장 IR 웹캠을 꽂았는데 인식 안 됨 | ESS 켜짐 → "외부 카메라 또는 지문 판독기로 로그인" 켜기 ([HARDWARE.md](docs/HARDWARE.md)) |
| 얼굴 등록 버튼이 회색 | PIN 먼저 설정 |
| 스크립트 실행이 막힘 | `-ExecutionPolicy Bypass` 로 실행하거나 파일 속성 > "차단 해제" |
| 한글이 깨짐 | 파일을 UTF-8 (BOM) 그대로 두세요. 다른 편집기로 저장하면 깨질 수 있습니다 |

## 요구 사항

- Windows 10 2004 이상 / Windows 11
- Windows PowerShell 5.1 (기본 내장) 또는 PowerShell 7
- IR 카메라 (내장 또는 외장 Windows Hello 웹캠)
