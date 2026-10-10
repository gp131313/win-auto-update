# Set-GitHubToken.ps1 - stores a GitHub token for private releases (config.json: "Private": true).
#   Set-GitHubToken.ps1            asks for the token (hidden input)
#   Set-GitHubToken.ps1 -Stdin     reads the token as one line from stdin (for scripts; never on the command line)
#   $env:WAU_GITHUB_TOKEN = '...'; Set-GitHubToken.ps1    takes it from the environment
#   Set-GitHubToken.ps1 -Check     says whether a token is stored and whether GitHub accepts it
#   Set-GitHubToken.ps1 -Remove    deletes the stored token
# The token is kept in %ProgramData%\WinAutoUpdate\github-token.dat, encrypted with DPAPI (machine scope),
# readable by Administrators and SYSTEM only. A fine-grained token with "Contents: read-only" on the
# private repositories is enough. Windows PowerShell 5.1 compatible, ASCII only.
param([switch]$Stdin, [switch]$Check, [switch]$Remove)
$ErrorActionPreference = 'Stop'
$File = Join-Path $env:ProgramData 'WinAutoUpdate\github-token.dat'
Add-Type -AssemblyName System.Security

$me  = [Security.Principal.WindowsIdentity]::GetCurrent()
$adm = (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm) { throw 'run as administrator' }

function Read-Token {
    if (-not (Test-Path $File)) { return $null }
    $b = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($File), $null, 'LocalMachine')
    return [Text.Encoding]::UTF8.GetString($b)
}

if ($Remove) {
    if (Test-Path $File) { Remove-Item $File -Force; Write-Host 'token removed' } else { Write-Host 'no token stored' }
    return
}
if ($Check) {
    $t = Read-Token
    if (-not $t) { Write-Host 'no token stored' -ForegroundColor Yellow; return }
    try {
        $r = Invoke-WebRequest 'https://api.github.com/rate_limit' -Headers @{ 'User-Agent' = 'win-auto-update'; 'Authorization' = 'Bearer ' + $t } -UseBasicParsing -TimeoutSec 30
        $lim = ($r.Content | ConvertFrom-Json).resources.core
        Write-Host ('token stored, GitHub accepts it (rate limit ' + $lim.remaining + '/' + $lim.limit + ')') -ForegroundColor Green
    } catch { Write-Host ('token stored, but GitHub rejects it: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
    return
}

$token = $null
if ($Stdin) { $token = [Console]::In.ReadLine() }
elseif ($env:WAU_GITHUB_TOKEN) { $token = $env:WAU_GITHUB_TOKEN; $env:WAU_GITHUB_TOKEN = $null }
else {
    $s = Read-Host 'GitHub token (input is hidden)' -AsSecureString
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}
if ($token) { $token = $token.Trim() }
if (-not $token) { throw 'empty token' }
if ($token -notmatch '^[A-Za-z0-9_]{20,}$') { throw 'this does not look like a GitHub token' }

New-Item -ItemType Directory -Force (Split-Path $File -Parent) | Out-Null
$enc = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($token), $null, 'LocalMachine')
[IO.File]::WriteAllBytes($File, $enc)
$token = $null
& icacls $File /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /Q | Out-Null
Write-Host ('token stored: ' + $File) -ForegroundColor Green
