<#
.SYNOPSIS
    FaceUnlock 제거: 잠금 화면 등록 해제, 바꾼 정책 복원, 저장된 비밀번호/얼굴 데이터/파일 삭제.
#>
[CmdletBinding()]
param([switch]$KeepFaceData)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FaceUnlock.psm1') -Force
Assert-Admin
$paths = Get-FaceUnlockPaths

Write-Host '잠금 화면 등록 해제'
Unregister-FaceUnlockProvider
Restore-FaceUnlockPolicies

Write-Host '저장된 비밀번호 삭제'
Remove-FaceUnlockSecret
if (Test-Path $paths.ConfigKey) { Remove-Item $paths.ConfigKey -Recurse -Force }

if (-not $KeepFaceData -and (Test-Path $paths.DataDir)) {
    Write-Host '얼굴 데이터 삭제'
    Remove-Item $paths.DataDir -Recurse -Force
}

if (Test-Path $paths.InstallDir) {
    Write-Host '프로그램 파일 삭제'
    try {
        Remove-Item $paths.InstallDir -Recurse -Force
    } catch {
        Write-Warning "일부 파일이 사용 중이라 지우지 못했습니다. 재부팅 후 '$($paths.InstallDir)' 폴더를 직접 지우세요."
    }
}
Write-Host '제거 완료.' -ForegroundColor Green
