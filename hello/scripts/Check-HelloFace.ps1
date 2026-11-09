<#
.SYNOPSIS
    Windows Hello 얼굴 인식을 이 PC에서 쓸 수 있는지 점검한다 (읽기 전용).

.DESCRIPTION
    아무 설정도 바꾸지 않는다. 다음 항목을 확인하고 결과를 표로 보여준다.
      1. IR 카메라 / Windows Hello 얼굴 인식 장치 존재 여부
      2. Windows Biometric Service(WbioSrvc) 상태
      3. "Hello.Face" 선택적 기능 설치 여부 (관리자 권한일 때만 확인 가능)
      4. 그룹 정책/레지스트리로 생체 인식이 꺼져 있는지
      5. 보안 강화 로그인(ESS) 상태 - 켜져 있으면 외장 IR 카메라는 사용 불가
      6. 현재 등록된 로그인 방식(PIN, 지문, 얼굴)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Check-HelloFace.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Item, [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ 항목 = $Item; 상태 = $Status; 내용 = $Detail })
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# --- 0. 기본 정보 ---------------------------------------------------------
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($cs) { Add-Result '기기' 'INFO' "$($cs.Manufacturer) $($cs.Model)" }
if ($os) { Add-Result 'Windows' 'INFO' "$($os.Caption) (빌드 $($os.BuildNumber))" }
Add-Result '관리자 권한' 'INFO' $(if ($isAdmin) { '예' } else { '아니오 (일부 항목은 확인 불가)' })

# --- 1. 카메라 / 생체 인식 장치 ------------------------------------------
$cameras = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.Class -in @('Camera', 'Image') })
$irCameras = @($cameras | Where-Object { $_.FriendlyName -match '\bIR\b|Infrared|적외선|Hello' })
$bioDevices = @(Get-PnpDevice -PresentOnly -Class Biometric -ErrorAction SilentlyContinue)
$faceDevices = @($bioDevices | Where-Object { $_.FriendlyName -match 'Face|얼굴' })
$fingerDevices = @($bioDevices | Where-Object { $_.FriendlyName -match 'Finger|지문|Synaptics|Goodix|ELAN|FPC|Egis' })

if ($cameras.Count -eq 0) {
    Add-Result '카메라' 'FAIL' '연결된 카메라가 없습니다.'
} else {
    Add-Result '카메라' 'INFO' (($cameras | ForEach-Object { "$($_.FriendlyName) [$($_.Status)]" }) -join '; ')
}

if ($faceDevices.Count -gt 0) {
    $faceOk = @($faceDevices | Where-Object { $_.Status -eq 'OK' }).Count -gt 0
    Add-Result 'Hello 얼굴 장치' $(if ($faceOk) { 'OK' } else { 'WARN' }) (($faceDevices | ForEach-Object { "$($_.FriendlyName) [$($_.Status)]" }) -join '; ')
} elseif ($irCameras.Count -gt 0) {
    Add-Result 'Hello 얼굴 장치' 'WARN' "IR 카메라($($irCameras[0].FriendlyName))는 보이지만 얼굴 인식 장치가 없습니다. Enable-HelloFace.ps1 로 기능 설치를 시도하세요."
} else {
    Add-Result 'Hello 얼굴 장치' 'FAIL' 'IR(적외선) 카메라가 없습니다. 일반 웹캠으로는 Windows Hello 얼굴 인식을 쓸 수 없습니다. HARDWARE.md 참고.'
}

if ($fingerDevices.Count -gt 0) {
    Add-Result '지문 센서' 'INFO' (($fingerDevices | ForEach-Object { $_.FriendlyName }) -join '; ')
}

# --- 2. Windows Biometric Service ----------------------------------------
$svc = Get-Service -Name WbioSrvc -ErrorAction SilentlyContinue
if (-not $svc) {
    Add-Result '생체 인식 서비스' 'FAIL' 'WbioSrvc 서비스가 없습니다.'
} else {
    $startType = (Get-CimInstance Win32_Service -Filter "Name='WbioSrvc'" -ErrorAction SilentlyContinue).StartMode
    $st = if ($svc.Status -eq 'Running' -or $startType -in @('Auto', 'Manual')) { 'OK' } else { 'FAIL' }
    Add-Result '생체 인식 서비스' $st "상태=$($svc.Status), 시작유형=$startType"
}

# --- 3. Hello.Face 선택적 기능 -------------------------------------------
if ($isAdmin) {
    $cap = @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Hello.Face*' })
    if ($cap.Count -eq 0) {
        Add-Result 'Hello.Face 기능' 'WARN' '목록에서 찾지 못했습니다 (Windows 버전에 따라 기본 내장일 수 있음).'
    } else {
        $installed = @($cap | Where-Object { $_.State -eq 'Installed' }).Count -gt 0
        Add-Result 'Hello.Face 기능' $(if ($installed) { 'OK' } else { 'WARN' }) (($cap | ForEach-Object { "$($_.Name)=$($_.State)" }) -join '; ')
    }
} else {
    Add-Result 'Hello.Face 기능' 'INFO' '관리자 권한으로 실행하면 확인합니다.'
}

# --- 4. 정책 ---------------------------------------------------------------
$bioPolicy = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Biometrics' 'Enabled'
if ($null -eq $bioPolicy) {
    Add-Result '생체 인식 정책' 'OK' '정책 미설정 (기본값: 허용)'
} elseif ($bioPolicy -eq 0) {
    Add-Result '생체 인식 정책' 'FAIL' 'HKLM\SOFTWARE\Policies\Microsoft\Biometrics\Enabled = 0 (정책으로 차단됨). 회사 PC라면 IT 관리자에게 문의.'
} else {
    Add-Result '생체 인식 정책' 'OK' "Enabled = $bioPolicy"
}

$antiSpoof = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Biometrics\FacialFeatures' 'EnhancedAntiSpoofing'
if ($antiSpoof -eq 1) {
    Add-Result '얼굴 위조 방지 강화' 'INFO' '켜짐 - 위조 방지를 지원하지 않는 카메라는 거부될 수 있음'
}

# --- 5. 보안 강화 로그인 (ESS) -------------------------------------------
$ess = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\SecureBiometrics' 'Enabled'
if ($ess -eq 1) {
    Add-Result '보안 강화 로그인(ESS)' 'WARN' '켜짐 - 내장 센서만 사용 가능. 외장 IR 카메라를 쓰려면 설정 > 계정 > 로그인 옵션 에서 "외부 카메라 또는 지문 판독기로 로그인" 을 켜야 합니다 (HARDWARE.md).'
} elseif ($null -ne $ess) {
    Add-Result '보안 강화 로그인(ESS)' 'INFO' "Enabled = $ess"
} else {
    Add-Result '보안 강화 로그인(ESS)' 'INFO' '미지원 또는 미설정'
}

# --- 6. 현재 등록 상태 ----------------------------------------------------
# 사용자별 NGC(PIN) 폴더는 SYSTEM 소유라 직접 읽을 수 없으므로 로그인 공급자 레지스트리로 추정한다.
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$credProv = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
$pinProvider = '{D6886603-9D2F-4EB2-B667-1971041FA96B}'
$pinEnrolled = Test-Path "$credProv\$pinProvider\$sid"
Add-Result 'Windows Hello PIN' $(if ($pinEnrolled) { 'OK' } else { 'INFO' }) $(if ($pinEnrolled) { '등록됨' } else { '확인 안 됨 (추정치) - 얼굴 등록 전에 PIN 이 있어야 합니다.' })

# --- 출력 -----------------------------------------------------------------
$results | Format-Table -AutoSize -Wrap

$fail = @($results | Where-Object { $_.상태 -eq 'FAIL' }).Count
$warn = @($results | Where-Object { $_.상태 -eq 'WARN' }).Count
Write-Host ''
if ($fail -gt 0) {
    Write-Host "결론: FAIL $fail 건 - 위 항목을 먼저 해결해야 합니다." -ForegroundColor Red
    exit 2
} elseif ($warn -gt 0) {
    Write-Host "결론: WARN $warn 건 - 관리자 권한으로 Enable-HelloFace.ps1 을 실행해 보세요." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host '결론: 얼굴 인식을 쓸 준비가 됐습니다. Enable-HelloFace.ps1 로 등록 화면을 여세요.' -ForegroundColor Green
    exit 0
}
