# install.ps1 - win-auto-update installer. Start it with Install.cmd (asks for administrator rights once).
# Idempotent: run it again to update the kit or to change the folder / time.
#   Install.cmd                      install to %ProgramFiles%\WinAutoUpdate, task daily at 12:00 and at logon +10 min
#   Install.cmd -At 03:00            another daily time
#   Install.cmd -InstallDir D:\upd   another folder
#   Install.cmd -RunNow              start the first pass right away (log: <folder>\logs)
#   Install.cmd -Check               only show what would be done
# Windows PowerShell 5.1 compatible, ASCII only.
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'WinAutoUpdate'),
    [string]$SourceDir,
    [string]$At = '12:00',
    [switch]$RunNow,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
if (-not $SourceDir) { $SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path }

$KitVersion = '1.0.1'
$Task       = 'Win Auto Update'
$LegacyTask = 'Winget Auto Update'
$AppsKey    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\WinAutoUpdate'
$Files      = 'Update-Apps.ps1', 'install.ps1', 'uninstall.ps1', 'Install.cmd', 'Uninstall.cmd', 'config.json', 'exclude.txt', 'README.md', 'LICENSE'

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Step([string]$t) { Write-Host ''; Write-Host ('== ' + $t) -ForegroundColor Cyan }
function Ok([string]$t)   { Say ('   ok: ' + $t) 'Green' }
function Plan([string]$t) { Say ('   ' + $(if ($Check) { 'would: ' } else { '' }) + $t) 'Yellow' }

Say ('win-auto-update ' + $KitVersion + $(if ($Check) { '  (check mode, nothing changes)' } else { '' })) 'White'
$me  = [Security.Principal.WindowsIdentity]::GetCurrent()
$adm = (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm -and -not $Check) {
    # ask for elevation once and run this same script again
    $a = '-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '" -InstallDir "' + $InstallDir + '" -SourceDir "' + $SourceDir + '" -At ' + $At + $(if ($RunNow) { ' -RunNow' } else { '' })
    Start-Process powershell.exe -ArgumentList $a -Verb RunAs -Wait
    return
}
Say ('account: ' + $me.Name + ', computer: ' + $env:COMPUTERNAME)
foreach ($f in 'Update-Apps.ps1', 'config.json', 'exclude.txt') { if (-not (Test-Path (Join-Path $SourceDir $f))) { throw ($f + ' not found in ' + $SourceDir) } }

# ------------------------------------------------------------------ files
Step ('Files -> ' + $InstallDir)
$inPlace = ([IO.Path]::GetFullPath($SourceDir).TrimEnd('\') -eq [IO.Path]::GetFullPath($InstallDir).TrimEnd('\'))
Plan 'copy the scripts; keep an existing config.json and exclude.txt (new defaults are saved as *.default)'
if (-not $Check) {
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    if (-not $inPlace) {
        foreach ($f in $Files) {
            $s = Join-Path $SourceDir $f; $d = Join-Path $InstallDir $f
            if (-not (Test-Path $s)) { continue }
            if ($f -in 'config.json', 'exclude.txt' -and (Test-Path $d)) { Copy-Item $s ($d + '.default') -Force; continue }
            Copy-Item $s $d -Force
        }
    }
    # exclusions of the old "Winget Auto Update" task are carried over once
    $legacyEx = Join-Path (Join-Path $SourceDir '..\winget-auto') 'exclude.txt'
    foreach ($cand in @('C:\ClaudeScripts\winget-auto\exclude.txt', $legacyEx)) {
        if ((Test-Path $cand) -and -not (Test-Path (Join-Path $InstallDir 'exclude.txt.migrated'))) {
            $cur = Join-Path $InstallDir 'exclude.txt'
            $ids = @(Get-Content $cand | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
            $have = @(Get-Content $cur | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
            $add = @($ids | Where-Object { $_ -notin $have })
            if ($add.Count) { Add-Content $cur ($add -join "`r`n") -Encoding ASCII; Say ('   carried over from ' + $cand + ': ' + ($add -join ', ')) }
            Set-Content (Join-Path $InstallDir 'exclude.txt.migrated') $cand -Encoding ASCII
            break
        }
    }
    Get-ChildItem $InstallDir -File | Unblock-File -ErrorAction SilentlyContinue
    Ok 'files in place'
}

# the task runs these files with administrator rights: only Administrators and SYSTEM may write them
Step 'Folder permissions'
Plan 'write: Administrators and SYSTEM; read: Users'
if (-not $Check) {
    & icacls $InstallDir /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
    & icacls $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
    & icacls (Join-Path $InstallDir '*') /reset /T /C /Q | Out-Null
    Ok 'locked'
}

# ------------------------------------------------------------------ task
Step ('Scheduled task "' + $Task + '"')
$ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Plan ('daily at ' + $At + ' and at logon +10 min, account ' + $me.Name + ', highest privileges, no console window')
if (-not $Check) {
    if (Get-ScheduledTask -TaskName $LegacyTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $LegacyTask -Confirm:$false
        Say ('   removed the old task "' + $LegacyTask + '"')
    }
    # conhost --headless: a plain powershell.exe -WindowStyle Hidden still flashes a console window at every run
    $act = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
           -Argument ('--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir 'Update-Apps.ps1') + '"')
    $t1 = New-ScheduledTaskTrigger -AtLogOn -User $me.Name; $t1.Delay = 'PT10M'
    $t2 = New-ScheduledTaskTrigger -Daily -At $At
    $pr = New-ScheduledTaskPrincipal -UserId $me.Name -LogonType Interactive -RunLevel Highest
    $st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable `
          -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    Register-ScheduledTask -TaskName $Task -Action $act -Trigger $t1, $t2 -Principal $pr -Settings $st -Force `
        -Description ('win-auto-update ' + $KitVersion + ': winget, GitHub releases, Windows Update (' + $InstallDir + ')') | Out-Null
    $t = Get-ScheduledTask -TaskName $Task
    Ok ('{0}, next run {1}' -f $t.State, (Get-ScheduledTaskInfo -TaskName $Task).NextRunTime)
}

# ------------------------------------------------------------------ winget pins
Step 'winget exclusions'
$wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
$ex = @(Get-Content (Join-Path $InstallDir 'exclude.txt') -ErrorAction SilentlyContinue | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
if (-not (Test-Path $wg)) { Say '   winget not found - pins are set at the first pass' 'Yellow' }
elseif ($ex.Count -eq 0) { Say '   exclude.txt is empty' }
else {
    Plan ('pin as blocking: ' + ($ex -join ', '))
    if (-not $Check) {
        $ErrorActionPreference = 'Continue'
        foreach ($id in $ex) { $o = & $wg pin add --id $id --exact --blocking --accept-source-agreements --disable-interactivity 2>&1; Say ('   ' + $id + ': rc=' + $LASTEXITCODE) }
        $ErrorActionPreference = 'Stop'
    }
}

# ------------------------------------------------------------------ Apps entry
Step 'Entry in Settings -> Apps'
Plan ('Win Auto Update ' + $KitVersion)
if (-not $Check) {
    $un = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDir 'uninstall.ps1') + '"'
    New-Item -Path $AppsKey -Force | Out-Null
    Set-ItemProperty $AppsKey DisplayName 'Win Auto Update'
    Set-ItemProperty $AppsKey DisplayVersion $KitVersion
    Set-ItemProperty $AppsKey Publisher 'gp131313'
    Set-ItemProperty $AppsKey URLInfoAbout 'https://github.com/gp131313/win-auto-update'
    Set-ItemProperty $AppsKey InstallLocation $InstallDir
    Set-ItemProperty $AppsKey UninstallString $un
    Set-ItemProperty $AppsKey QuietUninstallString ($un + ' -Quiet')
    Set-ItemProperty $AppsKey NoModify 1 -Type DWord
    Set-ItemProperty $AppsKey NoRepair 1 -Type DWord
    Ok 'registered'
}

if ($RunNow -and -not $Check) {
    Step 'First pass'
    Start-ScheduledTask -TaskName $Task
    Say ('   started; log: ' + (Join-Path $InstallDir 'logs'))
}
Write-Host ''
Say 'Done.' 'Green'
