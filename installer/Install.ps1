<#
.SYNOPSIS
    FaceUnlock 설치: 파일 복사 -> 비밀번호 저장 -> 얼굴 등록 -> 확인 테스트 -> 잠금 화면 등록.

.DESCRIPTION
    관리자 PowerShell 에서 압축을 푼 폴더의 installer\Install.ps1 을 실행한다.
    잠금 화면 등록은 맨 마지막에, 얼굴 확인 테스트가 통과한 뒤에만 한다.

.PARAMETER SkipEnroll
    이미 등록한 얼굴을 그대로 쓴다 (재설치/업데이트 시).
#>
[CmdletBinding()]
param([switch]$SkipEnroll)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FaceUnlock.psm1') -Force
Assert-Admin
$paths = Get-FaceUnlockPaths
$src = Split-Path $PSScriptRoot -Parent

function Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

Write-Host @'
=====================================================================
 FaceUnlock - 일반 웹캠 얼굴 인식 잠금 해제
---------------------------------------------------------------------
 주의: 적외선 카메라를 쓰는 Windows Hello 와 달리, 일반 카메라는
 실제 얼굴과 사진/영상을 구분하지 못합니다. 내 사진을 가진 사람이
 잠금을 풀 수 있습니다. 집에서 개인용으로만 쓰세요.
 Windows 비밀번호는 SYSTEM 전용 LSA 저장소에 보관됩니다.
=====================================================================
'@ -ForegroundColor Yellow
if (-not (Read-YesNo '이 위험을 이해하고 설치할까요?')) { return }

# 1. 파일 복사 ---------------------------------------------------------------
Step "파일 복사 -> $($paths.InstallDir)"
foreach ($required in @('FaceUnlockProvider.dll', 'verifier\faceunlock.exe')) {
    if (-not (Test-Path (Join-Path $src $required))) {
        throw "$required 이 없습니다. GitHub Actions 빌드 결과(FaceUnlock.zip)를 압축 해제한 폴더에서 실행하세요."
    }
}
if ((Resolve-Path $src).Path.TrimEnd('\') -ne $paths.InstallDir.TrimEnd('\')) {
    New-Item -ItemType Directory -Path $paths.InstallDir -Force | Out-Null
    try {
        Copy-Item -Path (Join-Path $src '*') -Destination $paths.InstallDir -Recurse -Force
    } catch {
        throw "복사 실패: $($_.Exception.Message)`n잠금 화면이 DLL 을 쓰고 있을 수 있습니다. 재부팅 후 다시 실행하세요."
    }
}
Install-Models (Join-Path $paths.InstallDir 'verifier\models')

# 2. 데이터 폴더 -------------------------------------------------------------
Step "데이터 폴더 권한 설정 -> $($paths.DataDir)"
Initialize-DataDir

# 3. 비밀번호 ---------------------------------------------------------------
Step '로그인 정보 저장'
Set-FaceUnlockCredential

# 4. 얼굴 등록 --------------------------------------------------------------
if (-not $SkipEnroll -or -not (Test-Path (Join-Path $paths.DataDir 'face.npz'))) {
    Step '얼굴 등록 (카메라 창이 뜹니다. 밝은 곳에서 정면을 보세요)'
    & $paths.Verifier enroll --preview
    if ($LASTEXITCODE -ne 0) { throw "얼굴 등록 실패 (코드 $LASTEXITCODE). installer\Enroll.ps1 로 다시 시도하세요." }
}

# 5. 확인 테스트 -------------------------------------------------------------
Step '얼굴 확인 테스트 (10초 안에 카메라를 보세요)'
& $paths.Verifier verify --verbose
if ($LASTEXITCODE -ne 0) {
    throw "확인 테스트 실패 (코드 $LASTEXITCODE). 잠금 화면에는 등록하지 않았습니다. Enroll.ps1 로 다시 등록해 보세요."
}
Write-Host '확인 테스트 통과.' -ForegroundColor Green

# 6. 잠금 화면 등록 ----------------------------------------------------------
Step '잠금 화면에 FaceUnlock 등록'
Register-FaceUnlockProvider (Join-Path $paths.InstallDir 'FaceUnlockProvider.dll')
Write-Host '등록 완료. 기존 PIN/지문/비밀번호 로그인은 그대로 남아 있습니다.' -ForegroundColor Green

# 7. 선택 옵션 ---------------------------------------------------------------
Step '선택 옵션'
if (Read-YesNo '잠금 화면에서 FaceUnlock 을 기본 로그인 방식으로 할까요? (권장)' $true) {
    Set-FaceUnlockPolicy 'SetDefaultProvider'
}
if (Read-YesNo '잠금 화면 사진(시계 화면)을 건너뛰고 바로 얼굴 인식을 시작할까요? (권장)' $true) {
    Set-FaceUnlockPolicy 'SetNoLockScreen'
}

Write-Host @"

설치 완료!
  테스트: Win + L 로 잠근 뒤 카메라를 바라보세요.
  안 되면 '얼굴 인식' 타일에서 '다시 시도' 를 누르거나 PIN/지문으로 푸세요.
  로그: $($paths.DataDir)\verify.log
  제거: installer\Uninstall.ps1
"@ -ForegroundColor Green
