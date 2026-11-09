<#
.SYNOPSIS
    Windows Hello 얼굴 인식을 켜고 얼굴 등록 화면을 연다.

.DESCRIPTION
    관리자 권한이 필요하다. -WhatIf 로 미리보기, -Confirm 으로 단계별 확인을 할 수 있다.
      1. Windows Biometric Service(WbioSrvc) 시작 유형을 '자동'으로 하고 시작
      2. "Hello.Face" 선택적 기능이 설치돼 있지 않으면 설치 (인터넷/Windows Update 필요)
      3. 생체 인식 장치 다시 검색 (장치 관리자의 "하드웨어 변경 사항 검색"과 동일)
      4. 설정 > 계정 > 로그인 옵션 > 얼굴 인식 등록 화면 열기

    다음은 일부러 하지 않는다 (보안 설정이므로 사용자가 직접 판단):
      - 그룹 정책으로 막힌 생체 인식 해제
      - 보안 강화 로그인(ESS) 끄기
      - 지문 등록 삭제

.PARAMETER SkipCapability
    선택적 기능 설치 단계를 건너뛴다.

.PARAMETER NoEnroll
    마지막에 얼굴 등록 화면을 열지 않는다.

.EXAMPLE
    # 관리자 PowerShell 에서
    powershell -ExecutionPolicy Bypass -File .\scripts\Enable-HelloFace.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Enable-HelloFace.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$SkipCapability,
    [switch]$NoEnroll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '관리자 권한이 필요합니다. "관리자 권한으로 실행" 한 PowerShell 에서 다시 실행하세요.' -ForegroundColor Red
    exit 1
}

function Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# --- 0. 사전 차단 요인 확인 ----------------------------------------------
Step '사전 점검'
$bioPolicy = $null
try { $bioPolicy = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Biometrics' -Name Enabled -ErrorAction Stop).Enabled } catch { }
if ($bioPolicy -eq 0) {
    Write-Host '그룹 정책으로 생체 인식이 꺼져 있습니다 (HKLM\SOFTWARE\Policies\Microsoft\Biometrics\Enabled = 0).' -ForegroundColor Red
    Write-Host '회사/학교 관리 PC라면 IT 관리자에게 문의하세요. 이 스크립트는 정책을 바꾸지 않습니다.'
    exit 2
}
Write-Host '정책 차단 없음.'

# --- 1. 생체 인식 서비스 --------------------------------------------------
Step 'Windows Biometric Service (WbioSrvc)'
$svc = Get-Service -Name WbioSrvc -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host 'WbioSrvc 서비스가 없습니다. Windows 이미지가 손상됐을 수 있습니다 (sfc /scannow 권장).' -ForegroundColor Red
    exit 2
}
$startMode = (Get-CimInstance Win32_Service -Filter "Name='WbioSrvc'").StartMode
if ($startMode -ne 'Auto') {
    if ($PSCmdlet.ShouldProcess('WbioSrvc', "시작 유형 $startMode -> Automatic")) {
        Set-Service -Name WbioSrvc -StartupType Automatic
    }
}
if ($svc.Status -ne 'Running') {
    if ($PSCmdlet.ShouldProcess('WbioSrvc', '서비스 시작')) {
        Start-Service -Name WbioSrvc
    }
}
Write-Host "WbioSrvc: $((Get-Service WbioSrvc).Status)"

# --- 2. Hello.Face 선택적 기능 -------------------------------------------
if (-not $SkipCapability) {
    Step 'Windows Hello Face 선택적 기능'
    $caps = @(Get-WindowsCapability -Online | Where-Object { $_.Name -like 'Hello.Face*' })
    if ($caps.Count -eq 0) {
        Write-Host '이 Windows 버전에는 별도 기능 패키지가 없습니다 (기본 내장). 건너뜁니다.'
    } else {
        foreach ($cap in $caps) {
            if ($cap.State -eq 'Installed') {
                Write-Host "$($cap.Name): 이미 설치됨"
            } elseif ($PSCmdlet.ShouldProcess($cap.Name, '선택적 기능 설치')) {
                Write-Host "$($cap.Name) 설치 중... (몇 분 걸릴 수 있음)"
                $r = Add-WindowsCapability -Online -Name $cap.Name
                if ($r.RestartNeeded) { Write-Host '설치 완료 - 재부팅이 필요합니다.' -ForegroundColor Yellow }
            }
        }
    }
}

# --- 3. 장치 다시 검색 ----------------------------------------------------
Step '하드웨어 다시 검색'
if ($PSCmdlet.ShouldProcess('PnP 장치', '하드웨어 변경 사항 검색')) {
    & pnputil.exe /scan-devices | Out-Null
}
$face = @(Get-PnpDevice -PresentOnly -Class Biometric -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'Face|얼굴' })
if ($face.Count -eq 0) {
    Write-Host '얼굴 인식 장치가 아직 보이지 않습니다.' -ForegroundColor Yellow
    Write-Host ' - IR 카메라가 없는 노트북이면 외장 Windows Hello 웹캠이 필요합니다 (HARDWARE.md).'
    Write-Host ' - IR 카메라가 있다면: 재부팅 -> Samsung Update 에서 카메라 드라이버 업데이트 -> 다시 실행.'
} else {
    $face | ForEach-Object { Write-Host "발견: $($_.FriendlyName) [$($_.Status)]" -ForegroundColor Green }
}

# --- 4. 얼굴 등록 ----------------------------------------------------------
if (-not $NoEnroll) {
    Step '얼굴 등록 화면 열기'
    Write-Host 'PIN 이 없다면 먼저 PIN 을 만들라는 안내가 나옵니다.'
    if ($PSCmdlet.ShouldProcess('설정 앱', '얼굴 인식 등록 화면 열기')) {
        Start-Process 'ms-settings:signinoptions-launchfaceenrollment'
    }
}

Write-Host "`n완료. 등록 후 잠금(Win+L) 하고 카메라를 바라보면 잠금이 해제됩니다." -ForegroundColor Green
Write-Host '설정 > 계정 > 로그인 옵션 > 얼굴 인식 > "Windows Hello가 얼굴을 인식하면 자동으로 잠금 화면 해제" 를 켜두면 클릭 없이 바로 넘어갑니다.'
