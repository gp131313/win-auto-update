# get.ps1 - one-line install of win-auto-update:
#   irm https://raw.githubusercontent.com/gp131313/win-auto-update/main/get.ps1 | iex
# Downloads the latest release zip, checks it against SHA256SUMS.txt of the same release,
# unpacks it to %LOCALAPPDATA%\WinAutoUpdate\setup\<version> and starts Install.cmd.
# Extra keys for the installer: $env:WAU_ARGS = '-RunNow -At 03:00' before the line above.
# ASCII only (it is executed as a downloaded string).

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $repo = 'gp131313/win-auto-update'
    $h = @{ 'User-Agent' = 'win-auto-update-get' }

    $rel  = Invoke-RestMethod ('https://api.github.com/repos/' + $repo + '/releases/latest') -Headers $h -UseBasicParsing
    $zipA = $rel.assets | Where-Object { $_.name -like 'win-auto-update-*.zip' } | Select-Object -First 1
    $sumA = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    if (-not $zipA -or -not $sumA) { throw 'release assets not found' }

    $base = Join-Path $env:LOCALAPPDATA ('WinAutoUpdate\setup\' + $rel.tag_name)
    New-Item -ItemType Directory -Force $base | Out-Null
    $zip  = Join-Path $base $zipA.name
    $sums = Join-Path $base 'SHA256SUMS.txt'
    Invoke-WebRequest $zipA.browser_download_url -OutFile $zip -Headers $h -UseBasicParsing
    Invoke-WebRequest $sumA.browser_download_url -OutFile $sums -Headers $h -UseBasicParsing

    $line = Get-Content $sums | Where-Object { $_ -match [regex]::Escape($zipA.name) } | Select-Object -First 1
    $want = ($line -split '\s+')[0].ToLower()
    $have = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $have) { throw ('SHA256 mismatch for ' + $zipA.name) }
    Write-Host ('win-auto-update ' + $rel.tag_name + ': SHA256 ok') -ForegroundColor Green

    $dir = Join-Path $base 'kit'
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Expand-Archive $zip $dir -Force
    Get-ChildItem $dir -Recurse -File | Unblock-File
    $extra = @(); if ($env:WAU_ARGS) { $extra = $env:WAU_ARGS -split '\s+' }
    & (Join-Path $dir 'Install.cmd') @extra
}
