# FaceUnlock one-line installer.
# Usage (cmd or PowerShell, no admin needed):
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/kswoo02/face-unlock/main/setup.ps1 | iex"
# Downloads the latest release, extracts it to %USERPROFILE%\FaceUnlock and starts installer\Install.ps1 as administrator.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # progress bar makes downloads very slow on Windows PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url = 'https://github.com/kswoo02/face-unlock/releases/latest/download/FaceUnlock.zip'
$zip = Join-Path $env:TEMP 'FaceUnlock.zip'
$dir = Join-Path $HOME 'FaceUnlock'

Write-Host "[1/3] Downloading $url (about 100 MB)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

Write-Host "[2/3] Extracting to $dir" -ForegroundColor Cyan
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $dir -Force
Get-ChildItem $dir -Recurse | Unblock-File
Remove-Item $zip -Force

$installer = Get-ChildItem $dir -Recurse -Filter Install.ps1 | Select-Object -First 1
if (-not $installer) { throw "Install.ps1 not found in $dir" }

Write-Host "[3/3] Starting installer as administrator. Click 'Yes' on the UAC prompt." -ForegroundColor Cyan
Start-Process powershell -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$($installer.FullName)`"")
Write-Host "Continue in the new blue window." -ForegroundColor Green
