# GX-RA agent — Windows install
param(
    [string]$ApiUrl = $env:GXRA_API_URL,
    [string]$TenantId = $env:GXRA_TENANT_ID,
    [string]$Hostname = $env:COMPUTERNAME,
    [string]$EntityId = "",
    [switch]$PilotEntity,
    [switch]$SkipLearn,
    [int]$LearnInterval = 60,
    [int]$LearnCount = 6
)

# Pilot fleet: WIN-VM-LAB01 (baseline already frozen on API)
$PilotEntityId = "ent-2272a0680155"
if ($PilotEntity) {
    $EntityId = $PilotEntityId
    $SkipLearn = $true
    if (-not $Hostname -or $Hostname -eq $env:COMPUTERNAME) {
        $Hostname = "WIN-VM-LAB01"
    }
}

$ErrorActionPreference = "Stop"
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Invoke-GxraPy {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if ($script:PyLauncher) {
        & py -3.12 @Args
    } else {
        & $script:PythonExe @Args
    }
    if ($LASTEXITCODE -ne 0) { throw "Python failed: py @Args" }
}

if (-not $ApiUrl) { $ApiUrl = Read-Host "GX-RA API URL (e.g. http://192.168.68.54:8081)" }
if (-not $TenantId) { $TenantId = Read-Host "Tenant ID (e.g. pilot-1)" }
if (-not $Hostname) { $Hostname = Read-Host "Hostname for this VM" }

$ApiUrl = $ApiUrl.TrimEnd("/")
$env:GXRA_API_URL = $ApiUrl
$env:GXRA_TENANT_ID = $TenantId

Write-Step "Checking GX-RA API at $ApiUrl"
$health = Invoke-RestMethod "$ApiUrl/health" -TimeoutSec 10
Write-Host "  API OK: $($health.status)" -ForegroundColor Green

Write-Step "Finding Python 3.10+"
$script:PyLauncher = $false
$script:PythonExe = $null

if (Get-Command py -ErrorAction SilentlyContinue) {
    try {
        & py -3.12 -c "import sys" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $script:PyLauncher = $true }
    } catch {}
}

if (-not $script:PyLauncher) {
    foreach ($name in @("python", "python3")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        try {
            & $cmd.Source -c "import sys; exit(0 if sys.version_info[:2] >= (3,10) else 1)" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $script:PythonExe = $cmd.Source
                break
            }
        } catch {}
    }
}

if (-not $script:PyLauncher -and -not $script:PythonExe) {
    Write-Host "  Installing Python 3.12 via winget..." -ForegroundColor Yellow
    winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
    foreach ($name in @("python", "python3")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { $script:PythonExe = $cmd.Source; break }
    }
    if (Get-Command py -ErrorAction SilentlyContinue) { $script:PyLauncher = $true }
}

if (-not $script:PyLauncher -and -not $script:PythonExe) {
    throw "Python 3.10+ not found. Re-open PowerShell after winget install, or install from python.org"
}

Write-Step "Creating venv at C:\gxra-agent-venv"
$venv = "C:\gxra-agent-venv"
Invoke-GxraPy -m venv $venv
$pip = "$venv\Scripts\pip.exe"
$gxra = "$venv\Scripts\gxra-agent.exe"

Write-Step "Installing gx-ra-agent from GitHub"
& $pip install --upgrade pip
& $pip install "gx-ra-agent @ git+https://github.com/brkn404/gx-ra-agent.git"

if ($EntityId) {
    Write-Step "Binding to existing entity $EntityId (no new registration)"
    & $gxra bind $EntityId --hostname $Hostname --device-did "did:gx:host-WIN-VM-LAB01"
} else {
    Write-Step "Registering host $Hostname"
    & $gxra register --hostname $Hostname
}

if (-not $SkipLearn) {
    Write-Step "Learning baseline ($LearnCount x ${LearnInterval}s) then freeze"
    & $gxra learn --start-learning --interval $LearnInterval --count $LearnCount --freeze
} elseif ($EntityId) {
    Write-Step "Skipping learn (pilot entity — confirm frozen baseline)"
    & $gxra status
}

Write-Step "Status"
& $gxra status
Write-Host "`nDone. Config: $env:APPDATA\gxra-agent\config.json" -ForegroundColor Green
