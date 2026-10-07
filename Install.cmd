@echo off
rem Install.cmd - installs win-auto-update (asks for administrator rights once). Keys: see install.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 pause
