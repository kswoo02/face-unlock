@echo off
rem Double-click: run Install.ps1 as administrator
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','\"%~dp0Install.ps1\"'"
