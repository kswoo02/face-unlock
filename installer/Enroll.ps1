<#
.SYNOPSIS
    얼굴을 다시 등록하거나(기본), 인식 점수를 실시간으로 확인한다(-Test). 관리자 권한 필요.

.EXAMPLE
    .\Enroll.ps1          # 다시 등록
    .\Enroll.ps1 -Append  # 기존 등록은 두고 다른 조명/각도/안경 샘플 추가
    .\Enroll.ps1 -Test    # 점수 확인 (Ctrl+C 종료). 점수 기준은 C:\ProgramData\FaceUnlock\config.json 의 threshold
#>
param([switch]$Test, [switch]$Append)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FaceUnlock.psm1') -Force
Assert-Admin
$paths = Get-FaceUnlockPaths
$exe = if (Test-Path $paths.Verifier) { $paths.Verifier } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'verifier\faceunlock.exe' }
$extra = @(); if ($Append) { $extra = @('--append') }
if ($Test) { & $exe test } else { Initialize-DataDir; & $exe enroll --preview @extra }
exit $LASTEXITCODE
