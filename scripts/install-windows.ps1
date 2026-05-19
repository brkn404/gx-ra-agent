# GX-RA agent — one-shot Windows install (run inside the VM in PowerShell).
# Usage:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   irm https://raw.githubusercontent.com/brkn404/gx-ra-agent/main/scripts/install-windows.ps1 | iex
# Save script, then:
#   .\install-windows.ps1 -ApiUrl http://192.168.68.54:8081 -TenantId pilot-1 -Hostname win-vm3

param(
    [string]$ApiUrl = $env:GXRA_API_URL,
    [string]$TenantId = $env:GXRA_TENANT_ID,
    [string]$Hostname = $env:COMPUTERNAME,
    [switch]$SkipLearn,
    [int]$LearnInterval = 60,
    [int]$LearnCount = 6
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

if (-not $ApiUrl) { $ApiUrl = Read-Host "GX-RA API URL (e.g. http://192.168.68.54:8081)" }
if (-not $TenantId) { $TenantId = Read-Host "Tenant ID (e.g. pilot-1)" }
if (-not $Hostname) { $Hostname = Read-Host "Hostname for this VM" }

$ApiUrl = $ApiUrl.TrimEnd("/")
$env:GXRA_API_URL = $ApiUrl
$env:GXRA_TENANT_ID = $TenantId

Write-Step "Checking GX-RA API at $ApiUrl"
try {
    $health = Invoke-RestMethod "$ApiUrl/health" -TimeoutSec 10
    Write-Host "  API OK: $($health.status)" -ForegroundColor Green
} catch {
    Write-Host "  Cannot reach API. From this VM, fix network/firewall first." -ForegroundColor Red
    Write-Host "  $_"
    exit 1
}

Write-Step "Finding Python 3.10+"
$py = $null
foreach ($cmd in @("py -3.12", "py -3.11", "py -3.10", "python3", "python")) {
    try {
        $ver = Invoke-Expression "$cmd -c `"import sys; print(sys.version_info[:2])`"" 2>$null
        if ($ver -match "3\.1[0-9]") { $py = $cmd; break }
    } catch {}
}
if (-not $py) {
    Write-Host "  Python not found. Installing Python 3.12 via winget..." -ForegroundColor Yellow
    winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
    $py = "py -3.12"
}

Write-Step "Creating venv at C:\gxra-agent-venv"
$venv = "C:\gxra-agent-venv"
& $py -m venv $venv
$pip = "$venv\Scripts\pip.exe"
$gxra = "$venv\Scripts\gxra-agent.exe"

Write-Step "Installing gx-ra-agent from GitHub"
& $pip install --upgrade pip
& $pip install "gx-ra-agent @ git+https://github.com/brkn404/gx-ra-agent.git"

Write-Step "Registering host $Hostname"
& $gxra register --hostname $Hostname

if (-not $SkipLearn) {
    Write-Step "Learning baseline ($LearnCount samples, ${LearnInterval}s apart) then freeze"
    & $gxra learn --start-learning --interval $LearnInterval --count $LearnCount --freeze
}

Write-Step "Status"
& $gxra status

$config = "$env:APPDATA\gxra-agent\config.json"
Write-Host "`nDone." -ForegroundColor Green
Write-Host "  Config: $config"
Write-Host "  Add entity_id from config to Veeam backup-complete webhook."
Write-Host "  Re-open PowerShell and run:"
Write-Host "    C:\gxra-agent-venv\Scripts\Activate.ps1"
Write-Host "    gxra-agent snapshot"
