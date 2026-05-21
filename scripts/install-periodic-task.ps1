# GX-RA agent — Windows scheduled task (continuous watch every 30 min)
param(
    [string]$ApiUrl = $env:GXRA_API_URL,
    [string]$TenantId = $env:GXRA_TENANT_ID,
    [int]$IntervalMin = 30,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$TaskName = "GXRA-Agent-Snapshot"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$GxraExe = Join-Path $Root ".venv\Scripts\gxra-agent.exe"

if (-not (Test-Path $GxraExe)) {
    $GxraExe = Join-Path $Root ".venv\Scripts\python.exe"
    if (-not (Test-Path $GxraExe)) {
        throw "Run install-windows.ps1 first (.venv missing)."
    }
    $GxraCmd = "`"$GxraExe`" -m gxra.agent.cli snapshot"
} else {
    $GxraCmd = "`"$GxraExe`" snapshot"
}

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task $TaskName"
    exit 0
}

if (-not $ApiUrl) { $ApiUrl = Read-Host "GX-RA API URL" }
if (-not $TenantId) { $TenantId = Read-Host "Tenant ID" }
$ApiUrl = $ApiUrl.TrimEnd("/")

$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
    "`$env:GXRA_API_URL='$ApiUrl'; `$env:GXRA_TENANT_ID='$TenantId'; `$env:GXRA_AGENT_TIER_MAX='1'; $GxraCmd"
)
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin) -RepetitionDuration ([TimeSpan]::MaxValue)
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null

Write-Host "OK: $TaskName every $IntervalMin min (GXRA_AGENT_TIER_MAX=1)"
Write-Host "Check: Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
