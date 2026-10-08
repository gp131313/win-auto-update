# Vpn-Bypass.ps1 - keeps Windows Update / Delivery Optimization traffic out of a full-tunnel VPN.
# The tunnel owns 0.0.0.0/0, and update servers are CDNs with changing addresses, so the exclusion is by name:
# every run resolves the hosts from config.json (VpnBypass.Hosts), and adds a /32 route for each address through
# the physical default gateway (metric 1, not persistent). Routes are tracked in vpn-bypass.state and removed when
# the tunnel is down, when the gateway changes (other network) or with -Remove.
# Run by the task "Win Auto Update (VPN bypass)" every 10 minutes and by Update-Apps.ps1 before Windows Update.
# Windows PowerShell 5.1 compatible, ASCII only.
param([switch]$Remove)
$ErrorActionPreference = 'Continue'
$Dir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$State = Join-Path $Dir 'vpn-bypass.state'
$LogD  = Join-Path $Dir 'logs'; New-Item -ItemType Directory -Force $LogD | Out-Null
$Log   = Join-Path $LogD 'vpn-bypass.log'
function Log([string]$m) { Add-Content $Log ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m) -Encoding UTF8 }
if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 512KB) { Get-Content $Log -Tail 300 | Set-Content $Log -Encoding UTF8 }

$cfg = $null
try { $cfg = (Get-Content (Join-Path $Dir 'config.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json).VpnBypass } catch { }
$hosts = @()
if ($cfg -and $cfg.Hosts) { $hosts = @($cfg.Hosts) }
if (-not $hosts.Count) {
    $hosts = @('windowsupdate.microsoft.com', 'update.microsoft.com', 'fe2cr.update.microsoft.com', 'fe3cr.delivery.mp.microsoft.com',
               'sls.update.microsoft.com', 'download.windowsupdate.com', 'au.download.windowsupdate.com', 'ctldl.windowsupdate.com',
               'dl.delivery.mp.microsoft.com', 'tlu.dl.delivery.mp.microsoft.com', 'emdl.ws.microsoft.com',
               'tsfe.trafficshaping.dsp.mp.microsoft.com', 'geo.prod.do.dsp.mp.microsoft.com', 'kv801.prod.do.dsp.mp.microsoft.com',
               'array801.prod.do.dsp.mp.microsoft.com', 'disc801.prod.do.dsp.mp.microsoft.com', 'catalog.update.microsoft.com',
               'go.microsoft.com', 'download.microsoft.com', 'officecdn.microsoft.com')
}

# tracked routes: lines "ip gateway ifindex"
$tracked = @()
if (Test-Path $State) { $tracked = @(Get-Content $State | Where-Object { $_ -match '\S' }) }
function Save-State($lines) { if ($lines.Count) { Set-Content $State ($lines -join "`r`n") -Encoding ASCII } else { Remove-Item $State -Force -ErrorAction SilentlyContinue } }
function Remove-Tracked {
    $n = 0
    foreach ($l in $tracked) {
        $p = $l -split ' '
        if (Get-NetRoute -DestinationPrefix ($p[0] + '/32') -InterfaceIndex $p[2] -ErrorAction SilentlyContinue) {
            Remove-NetRoute -DestinationPrefix ($p[0] + '/32') -InterfaceIndex $p[2] -Confirm:$false -ErrorAction SilentlyContinue; $n++
        }
    }
    if ($n) { Log ('removed ' + $n + ' route(s)') }
    Save-State @()
}

# the tunnel: an adapter that is up and carries a default route of its own (OpenConnect / Wintun / any VPN)
$tunnel = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'OpenConnect|Wintun|TAP-Windows|WireGuard|VPN') }
if ($Remove -or -not $tunnel) { Remove-Tracked; exit 0 }
$tunIdx = @($tunnel | ForEach-Object InterfaceIndex)

# physical default gateway = best default route that is NOT on the tunnel and has a real next hop
$gwRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $tunIdx -notcontains $_.InterfaceIndex -and $_.NextHop -ne '0.0.0.0' } |
    ForEach-Object { $a = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue; if ($a -and $a.Status -eq 'Up') { $_ } } |
    Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
if (-not $gwRoute) { Log 'tunnel is up but no physical default gateway found - nothing done'; exit 0 }
$gw = $gwRoute.NextHop; $if = $gwRoute.InterfaceIndex

# gateway changed (other network): drop the old routes first
if ($tracked.Count -and ($tracked | Where-Object { ($_ -split ' ')[1] -ne $gw -or ($_ -split ' ')[2] -ne "$if" })) { Log ('gateway changed to ' + $gw + ' on if ' + $if); Remove-Tracked; $tracked = @() }

$added = 0; $ips = @{}
foreach ($h in $hosts) {
    try { Resolve-DnsName $h -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $ips[$_.IPAddress] = $h } } catch { }
}
foreach ($ip in $ips.Keys) {
    if ($tracked -contains ($ip + ' ' + $gw + ' ' + $if)) { continue }
    if (Get-NetRoute -DestinationPrefix ($ip + '/32') -InterfaceIndex $if -ErrorAction SilentlyContinue) { $tracked += ($ip + ' ' + $gw + ' ' + $if); continue }
    try {
        New-NetRoute -DestinationPrefix ($ip + '/32') -InterfaceIndex $if -NextHop $gw -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
        $tracked += ($ip + ' ' + $gw + ' ' + $if); $added++
    } catch { Log ('route ' + $ip + ' (' + $ips[$ip] + '): ' + $_.Exception.Message) }
}
Save-State $tracked
if ($added) { Log ('added ' + $added + ' route(s) via ' + $gw + ' (if ' + $if + '), ' + $tracked.Count + ' total, ' + $ips.Count + ' addresses from ' + $hosts.Count + ' hosts') }
exit 0
