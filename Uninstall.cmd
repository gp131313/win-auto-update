@echo off
rem Uninstall.cmd - removes win-auto-update (task, Apps entry, folder).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
