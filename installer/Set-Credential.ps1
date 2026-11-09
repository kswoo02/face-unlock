<#
.SYNOPSIS
    Windows 비밀번호를 바꾼 뒤 FaceUnlock 에 저장된 비밀번호를 갱신한다 (관리자).
#>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FaceUnlock.psm1') -Force
Assert-Admin
Set-FaceUnlockCredential
