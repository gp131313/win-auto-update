# Update-Apps.ps1 - win-auto-update: one daily pass that updates everything on a Windows machine.
#   1. the kit itself (latest release of gp131313/win-auto-update, SHA256 checked)
#   2. winget packages ("winget upgrade --all"), except the Ids pinned in exclude.txt
#   3. apps that are not in winget: latest GitHub release of each entry in config.json (GitHubApps)
#   4. Windows Update: search, download, install; never reboots by itself
# Run by the scheduled task "Win Auto Update" (your account, highest privileges): at logon +10 min and daily.
# At most one full pass per day (last-run.txt); -Force runs it again. Log: logs\update-<date>.log.
# Windows PowerShell 5.1 compatible, ASCII only.
param([switch]$Force, [switch]$NoSelfUpdate, [switch]$NoWinget, [switch]$NoGitHubApps, [switch]$NoWindowsUpdate)

$KitVersion = '1.1.0'
$KitRepo    = 'gp131313/win-auto-update'

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Dir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogD   = Join-Path $Dir 'logs'
$Stamp  = Join-Path $Dir 'last-run.txt'
$today  = Get-Date -Format 'yyyy-MM-dd'
New-Item -ItemType Directory -Force $LogD | Out-Null
$Log = Join-Path $LogD ('update-' + $today + '.log')
$Gh  = @{ 'User-Agent' = 'win-auto-update/' + $KitVersion }

$cfgFile = Join-Path $Dir 'config.json'
$cfg = $null
if (Test-Path $cfgFile) { try { $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfgErr = $_.Exception.Message } }
if (-not $cfg) { $cfg = New-Object psobject }
function Cfg([string]$n, $def) { if ($cfg.PSObject.Properties[$n] -and $null -ne $cfg.$n) { return $cfg.$n } return $def }
# downloads: %LOCALAPPDATA%\WinAutoUpdate\download, or "DownloadDir" from config.json (an antivirus may hold
# scripts and installers that run from AppData - point it at a folder the antivirus trusts)
$Down = [Environment]::ExpandEnvironmentVariables([string](Cfg 'DownloadDir' (Join-Path $env:LOCALAPPDATA 'WinAutoUpdate\download')))
New-Item -ItemType Directory -Force $Down | Out-Null

function Log([string]$m) { Add-Content $Log ('{0:HH:mm:ss} {1}' -f (Get-Date), $m) -Encoding UTF8 }
function LogLines($lines) { $lines | ForEach-Object { "$_" } | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*[-\\|/]\s*$' -and $_ -notmatch '[\u2588\u2592]' } | ForEach-Object { Add-Content $Log ('  ' + $_) -Encoding UTF8 } }
function Expand-Env([string]$s) { [Environment]::ExpandEnvironmentVariables($s) }

# "v1.2.3", "1.2.3.0", "ad 9.7.13" -> [version]; $null when there is no number
function To-Version([string]$s) {
    if (-not $s) { return $null }
    $m = [regex]::Match($s, '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $p = @($m.Value.Split('.')); while ($p.Count -lt 2) { $p += '0' }
    try { return [version]($p -join '.') } catch { return $null }
}

function Get-Download([string]$Url, [string]$Name) {
    $out = Join-Path $Down $Name
    foreach ($try in 1..3) {
        try { Invoke-WebRequest $Url -OutFile $out -UseBasicParsing -Headers $Gh -TimeoutSec 900; return $out }
        catch { Log ('  download retry ' + $try + ': ' + $_.Exception.Message); Start-Sleep 5 }
    }
    return $null
}

# verifies $File against the SHA256SUMS.txt asset of the release (sha256sum format); $true when ok or no sums file
function Test-ReleaseHash($Release, [string]$File) {
    # electron-builder feeds carry a base64 SHA512 of the file
    if ($Release.PSObject.Properties['sha512'] -and $Release.sha512) {
        $sha = [Security.Cryptography.SHA512]::Create()
        $have = [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($File)))
        if ($have -ne $Release.sha512) { Log ('  SHA512 mismatch for ' + (Split-Path $File -Leaf)); return $false }
        return $true
    }
    $sumA = $Release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    if (-not $sumA) { Log '  no SHA256SUMS.txt in the release - hash not checked'; return $true }
    $sums = Get-Download $sumA.browser_download_url ('SHA256SUMS-' + [IO.Path]::GetFileNameWithoutExtension($File) + '.txt')
    if (-not $sums) { return $false }
    $leaf = Split-Path $File -Leaf
    $line = Get-Content $sums | Where-Object { $_ -match ('\s\*?' + [regex]::Escape($leaf) + '\s*$') } | Select-Object -First 1
    if (-not $line) { Log ('  ' + $leaf + ' is not listed in SHA256SUMS.txt'); return $false }
    $want = ($line -split '\s+')[0].ToLower()
    $have = (Get-FileHash $File -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $have) { Log ('  SHA256 mismatch for ' + $leaf); return $false }
    return $true
}

function Get-LatestRelease([string]$Repo) {
    try { return Invoke-RestMethod ('https://api.github.com/repos/' + $Repo + '/releases/latest') -Headers $Gh -UseBasicParsing -TimeoutSec 60 }
    catch { Log ('  GitHub API: ' + $_.Exception.Message); return $null }
}

# electron-builder "generic" feed (latest.yml next to the installers): version, path, sha512 -> same shape as a GitHub release
function Get-LatestFeed([string]$Url) {
    try {
        $y = (Invoke-WebRequest $Url -Headers $Gh -UseBasicParsing -TimeoutSec 60).Content
        if ($y -is [byte[]]) { $y = [Text.Encoding]::UTF8.GetString($y) }
        $ver = [regex]::Match($y, '(?m)^version:\s*(\S+)').Groups[1].Value
        $path = [regex]::Match($y, '(?m)^path:\s*(\S+)').Groups[1].Value
        $sha = [regex]::Match($y, '(?m)^sha512:\s*(\S+)').Groups[1].Value
        if (-not $ver -or -not $path) { Log ('  feed has no version/path: ' + $Url); return $null }
        $base = $Url.Substring(0, $Url.LastIndexOf('/') + 1)
        return [pscustomobject]@{ tag_name = $ver; sha512 = $sha; assets = @([pscustomobject]@{ name = $path; browser_download_url = ($base + $path) }) }
    } catch { Log ('  feed: ' + $_.Exception.Message); return $null }
}

# ------------------------------------------------------------------ start
if (-not $Force -and (Test-Path $Stamp) -and ((Get-Content $Stamp -Raw).Trim() -eq $today)) { exit 0 }
Log ('start: win-auto-update ' + $KitVersion + ', user ' + $env:USERNAME + ', computer ' + $env:COMPUTERNAME + ', force=' + [bool]$Force)
if ($cfgErr) { Log ('config.json is not valid JSON, defaults used: ' + $cfgErr) }

# waits for the process itself, not for its children (Start-Process -Wait in PowerShell 5.1 also waits for every
# descendant - an installer that starts the program it installed would never return); $null when it timed out
function Wait-Exit($Proc, [int]$Minutes) {
    if ($Proc.WaitForExit($Minutes * 60000)) { return $Proc.ExitCode }
    Log ('  still running after ' + $Minutes + ' min - not waiting any longer')
    return $null
}
$online = $true
try { [void][Net.Dns]::GetHostAddresses('api.github.com') } catch { $online = $false }
if (-not $online) { Log 'no DNS for api.github.com - skipped, retry at the next trigger'; exit 0 }

# ------------------------------------------------------------------ 1. self-update
if (-not $NoSelfUpdate -and (Cfg 'SelfUpdate' $true)) {
    Log ('self-update: checking ' + $KitRepo)
    $rel = Get-LatestRelease $KitRepo
    $new = $null; if ($rel) { $new = To-Version $rel.tag_name }
    if ($new -and $new -gt (To-Version $KitVersion)) {
        $zipA = $rel.assets | Where-Object { $_.name -like 'win-auto-update-*.zip' } | Select-Object -First 1
        $zip = $null; if ($zipA) { $zip = Get-Download $zipA.browser_download_url $zipA.name }
        if ($zip -and (Test-ReleaseHash $rel $zip)) {
            $x = Join-Path $Down 'self'
            if (Test-Path $x) { Remove-Item $x -Recurse -Force }
            Expand-Archive $zip $x -Force
            $src = Get-ChildItem $x -Recurse -Filter 'Update-Apps.ps1' | Select-Object -First 1
            if ($src) {
                $srcDir = $src.DirectoryName
                foreach ($f in Get-ChildItem $srcDir -File) {
                    # exclude.txt and config.json are the user's settings: never overwritten, new defaults land as *.default
                    if ($f.Name -in 'exclude.txt', 'config.json' -and (Test-Path (Join-Path $Dir $f.Name))) { Copy-Item $f.FullName (Join-Path $Dir ($f.Name + '.default')) -Force; continue }
                    Copy-Item $f.FullName (Join-Path $Dir $f.Name) -Force
                }
                Get-ChildItem $Dir -File | Unblock-File -ErrorAction SilentlyContinue
                Log ('self-update: ' + $KitVersion + ' -> ' + $rel.tag_name + ', restarting with the new script')
                $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $Dir 'Update-Apps.ps1') + '"'), '-Force', '-NoSelfUpdate')
                if ($NoWinget) { $argv += '-NoWinget' }; if ($NoGitHubApps) { $argv += '-NoGitHubApps' }; if ($NoWindowsUpdate) { $argv += '-NoWindowsUpdate' }
                $p = Start-Process $ps -ArgumentList $argv -PassThru -WindowStyle Hidden
                $rc = Wait-Exit $p 230
                exit $(if ($null -eq $rc) { 1 } else { $rc })
            } else { Log 'self-update: Update-Apps.ps1 not found in the archive - skipped' }
        } else { Log 'self-update: download or hash failed - skipped' }
    } elseif ($rel) { Log ('self-update: ' + $KitVersion + ' is current (latest ' + $rel.tag_name + ')') }
}

$rcAll = 0

# ------------------------------------------------------------------ 2. winget
if (-not $NoWinget -and (Cfg 'Winget' $true)) {
    $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (-not (Test-Path $wg)) {
        $wg = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe' -ErrorAction SilentlyContinue |
              Sort-Object FullName | Select-Object -Last 1 -ExpandProperty FullName
    }
    if (-not $wg) { Log 'winget.exe not found - skipped'; $rcAll = 1 }
    else {
        try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
        # exclusions: every Id in exclude.txt is pinned as blocking (winget then skips it everywhere)
        $ex = @(Get-Content (Join-Path $Dir 'exclude.txt') -ErrorAction SilentlyContinue | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
        $pins = (& $wg pin list --disable-interactivity 2>&1 | ForEach-Object { "$_" }) -join "`n"
        foreach ($id in $ex) {
            if ($pins -match ('(?m)\s' + [regex]::Escape($id) + '\s')) { continue }
            $o = & $wg pin add --id $id --exact --blocking --accept-source-agreements --disable-interactivity 2>&1
            Log ('winget pin add ' + $id + ' rc=' + $LASTEXITCODE)
        }
        Log 'winget: available upgrades'
        LogLines (& $wg upgrade --accept-source-agreements --disable-interactivity 2>&1)
        foreach ($try in 1..2) {
            Log ('winget upgrade --all (try ' + $try + ')')
            LogLines (& $wg upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1)
            $rc = $LASTEXITCODE
            if ($rc -eq 0) { break }
            Start-Sleep 60
        }
        Log ('winget done, rc=' + $rc + $(if ($rc -ne 0) { ' (something failed - retried tomorrow)' } else { '' }))
        if ($rc -ne 0) { $rcAll = 1 }
    }
}

# ------------------------------------------------------------------ 3. apps from GitHub releases
function Get-InstalledApp($app) {
    # returns @{ Version = [version]; Dir = <install folder or $null> } or $null when the app is not installed
    $w = $app.Installed
    if (-not $w) { return $null }
    switch ($w.Type) {
        'Registry' {
            $k = Get-ItemProperty (Expand-Env $w.Key) -ErrorAction SilentlyContinue
            if (-not $k) { return $null }
            return @{ Version = (To-Version $k.DisplayVersion); Dir = $k.InstallLocation }
        }
        'RegistryName' {
            $hives = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            $k = Get-ItemProperty $hives -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $w.Name } | Select-Object -First 1
            if (-not $k) { return $null }
            return @{ Version = (To-Version $k.DisplayVersion); Dir = $k.InstallLocation }
        }
        'File' {
            $f = Expand-Env $w.Path
            if (-not (Test-Path $f)) { return $null }
            $vi = (Get-Item $f).VersionInfo
            return @{ Version = (To-Version $(if ($vi.ProductVersion) { $vi.ProductVersion } else { $vi.FileVersion })); Dir = (Split-Path $f -Parent) }
        }
    }
    return $null
}

function Install-GitHubApp($app, $rel, $cur) {
    $asset = $rel.assets | Where-Object { $_.name -match $app.Asset } | Select-Object -First 1
    if (-not $asset) { Log ('  asset not found: ' + $app.Asset); return $false }
    $file = Get-Download $asset.browser_download_url $asset.name
    if (-not $file) { return $false }
    if (-not (Test-ReleaseHash $rel $file)) { return $false }
    Unblock-File $file -ErrorAction SilentlyContinue
    switch ($app.Install.Type) {
        'Exe' {
            $a = [string]$app.Install.Args
            if ($app.Install.DirArg -and $cur.Dir) { $a = ($a + ' ' + ($app.Install.DirArg -replace '\{dir\}', $cur.Dir)).Trim() }
            Log ('  run: ' + $asset.name + ' ' + $a)
            if ($a) { $p = Start-Process $file -ArgumentList $a -PassThru -WindowStyle Hidden }
            else    { $p = Start-Process $file -PassThru -WindowStyle Hidden }
            $rc = Wait-Exit $p 30
            Log ('  exit code ' + $rc)
            return ($rc -in 0, 3010)
        }
        'Zip' {
            # unpack next to the installed exe: stop the program, replace the files, start it again (not elevated, via explorer)
            $exe = Expand-Env $app.Install.Exe
            $dst = Split-Path $exe -Parent
            $x = Join-Path $Down ([IO.Path]::GetFileNameWithoutExtension($asset.name))
            if (Test-Path $x) { Remove-Item $x -Recurse -Force }
            Expand-Archive $file $x -Force
            $newExe = Get-ChildItem $x -Recurse -Filter (Split-Path $exe -Leaf) | Select-Object -First 1
            if (-not $newExe) { Log ('  ' + (Split-Path $exe -Leaf) + ' not found in the archive'); return $false }
            $proc = [IO.Path]::GetFileNameWithoutExtension($exe)
            Get-Process $proc -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2
            Copy-Item $exe ($exe + '.bak') -Force -ErrorAction SilentlyContinue
            Copy-Item (Join-Path $newExe.DirectoryName '*') $dst -Recurse -Force
            Get-ChildItem $dst -File | Unblock-File -ErrorAction SilentlyContinue
            if ($app.Install.Restart -ne $false) { Start-Process explorer.exe -ArgumentList ('"' + $exe + '"') }
            return $true
        }
    }
    Log ('  unknown Install.Type ' + $app.Install.Type); return $false
}

if (-not $NoGitHubApps) {
    foreach ($app in @(Cfg 'GitHubApps' @())) {
        if ($app.Enabled -eq $false) { continue }
        $cur = Get-InstalledApp $app
        if (-not $cur) { Log ('github ' + $app.Name + ': not installed - skipped'); continue }
        $rel = $(if ($app.Feed) { Get-LatestFeed $app.Feed } else { Get-LatestRelease $app.Repo })
        if (-not $rel) { $rcAll = 1; continue }
        $new = To-Version $rel.tag_name
        if (-not $new) { Log ('github ' + $app.Name + ': cannot read a version from tag ' + $rel.tag_name); continue }
        if ($cur.Version -and $new -le $cur.Version) { Log ('github ' + $app.Name + ': ' + $cur.Version + ' is current'); continue }
        Log ('github ' + $app.Name + ': ' + $(if ($cur.Version) { "$($cur.Version)" } else { '?' }) + ' -> ' + $rel.tag_name)
        if (Install-GitHubApp $app $rel $cur) {
            $after = Get-InstalledApp $app
            Log ('github ' + $app.Name + ': done, now ' + $(if ($after -and $after.Version) { "$($after.Version)" } else { '?' }))
        } else { Log ('github ' + $app.Name + ': failed - retried tomorrow'); $rcAll = 1 }
    }
}

# ------------------------------------------------------------------ 4. Windows Update
$wu = Cfg 'WindowsUpdate' $null
if (-not $NoWindowsUpdate -and $wu -and $wu.Enabled -ne $false) {
    # full-tunnel VPN: route the update servers around it first (see Vpn-Bypass.ps1)
    $vb = Cfg 'VpnBypass' $null
    if ($vb -and $vb.Enabled -and (Test-Path (Join-Path $Dir 'Vpn-Bypass.ps1'))) { & (Join-Path $Dir 'Vpn-Bypass.ps1'); Log 'vpn bypass: routes for the update servers refreshed (logs\vpn-bypass.log)' }
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'win-auto-update'
        $searcher = $session.CreateUpdateSearcher()
        $crit = "IsInstalled=0 and IsHidden=0 and Type='Software'"
        if ($wu.Drivers) { $crit = "IsInstalled=0 and IsHidden=0" }
        Log ('windows update: searching (' + $crit + ')')
        $res = $searcher.Search($crit)
        $todo = New-Object -ComObject Microsoft.Update.UpdateColl
        $upgradeCat = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'   # category "Upgrades" = feature updates (new Windows versions)
        foreach ($u in $res.Updates) {
            $isUpgrade = [bool](@($u.Categories | Where-Object { $_.CategoryID -eq $upgradeCat }).Count)
            if ($isUpgrade -and -not $wu.FeatureUpgrades) { Log ('  skip feature upgrade: ' + $u.Title); continue }
            if ($u.InstallationBehavior.CanRequestUserInput) { Log ('  skip (needs user input): ' + $u.Title); continue }
            if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
            [void]$todo.Add($u)
            Log ('  ' + $u.Title + ' (' + [math]::Round(($u.MaxDownloadSize / 1MB), 1) + ' MB)')
        }
        if ($todo.Count -eq 0) { Log 'windows update: nothing to install' }
        else {
            $dl = $session.CreateUpdateDownloader(); $dl.Updates = $todo
            Log ('windows update: downloading ' + $todo.Count + ' update(s)')
            $dr = $dl.Download()
            Log ('  download result ' + $dr.ResultCode + ' (2 = ok)')
            $ready = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $todo) { if ($u.IsDownloaded) { [void]$ready.Add($u) } }
            if ($ready.Count -gt 0) {
                $inst = $session.CreateUpdateInstaller(); $inst.Updates = $ready
                try { $inst.ForceQuiet = $true } catch { }
                Log ('windows update: installing ' + $ready.Count + ' update(s)')
                $ir = $inst.Install()
                for ($i = 0; $i -lt $ready.Count; $i++) { Log ('  ' + $ready.Item($i).Title + ': result ' + $ir.GetUpdateResult($i).ResultCode) }
                Log ('windows update: result ' + $ir.ResultCode + ' (2 = ok, 3 = ok with errors), reboot required: ' + $ir.RebootRequired)
                if ($ir.RebootRequired) { Set-Content (Join-Path $Dir 'REBOOT-REQUIRED') ((Get-Date).ToString('s')) -Encoding ASCII }
                if ($ir.ResultCode -notin 2, 3) { $rcAll = 1 }
            } else { Log 'windows update: nothing downloaded'; $rcAll = 1 }
        }
    } catch { Log ('windows update: ' + $_.Exception.Message); $rcAll = 1 }
}

Set-Content $Stamp $today -Encoding ASCII
Log ('done, rc=' + $rcAll)
Get-ChildItem $LogD -Filter 'update-*.log' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-60) } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem $Down -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
exit 0
