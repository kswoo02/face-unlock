@echo off
chcp 65001 >nul
setlocal
set "HERE=%~dp0"

echo [1/2] Windows Hello face check (read-only)
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%scripts\Check-HelloFace.ps1"
if %ERRORLEVEL% EQU 2 (
  echo.
  echo Blocking issue found. See docs\HARDWARE.md
  pause
  exit /b 2
)

echo.
echo [2/2] Enable Windows Hello face (admin rights requested)
pause
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','\"%HERE%scripts\Enable-HelloFace.ps1\"'"
endlocal
