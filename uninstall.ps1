# uninstall.ps1 - removes the task "Win Auto Update", the Apps entry and the install folder.
# winget pins stay (list: winget pin list; remove: winget pin remove --id <Id>). Logs are deleted with the folder.
param([switch]$Quiet)
$ErrorActionPreference = 'Continue'
$me  = [Security.Principal.WindowsIdentity]::GetCurrent()
$adm = (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm) {
    Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"' + $(if ($Quiet) { ' -Quiet' } else { '' })) -Verb RunAs -Wait
    return
}
$AppsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WinAutoUpdate'
$dir = (Get-ItemProperty $AppsKey -ErrorAction SilentlyContinue).InstallLocation
if (-not $dir) { $dir = Split-Path -Parent $MyInvocation.MyCommand.Path }
Unregister-ScheduledTask -TaskName 'Win Auto Update' -Confirm:$false -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $dir 'Vpn-Bypass.ps1')) { & (Join-Path $dir 'Vpn-Bypass.ps1') -Remove }
Unregister-ScheduledTask -TaskName 'Win Auto Update (VPN bypass)' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item $AppsKey -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:LOCALAPPDATA 'WinAutoUpdate') -Recurse -Force -ErrorAction SilentlyContinue
# the folder holds this very script: delete it after we exit
$cmd = 'Start-Sleep 2; Remove-Item -LiteralPath "' + $dir + '" -Recurse -Force'
Start-Process powershell.exe -ArgumentList ('-NoProfile -WindowStyle Hidden -Command ' + $cmd)
if (-not $Quiet) { Write-Host 'Win Auto Update removed.' -ForegroundColor Green }
