# GX-RA agent — Windows scheduled task (continuous watch every 30 min)
#
# Run in PowerShell (Admin recommended), NOT Git Bash:
#   cd C:\Users\brkni\gx-ra-agent
#   $env:GXRA_API_URL = "http://192.168.68.54:8081"
#   $env:GXRA_TENANT_ID = "pilot-1"
#   .\scripts\install-periodic-task.ps1
#
param(
    [string]$ApiUrl = $env:GXRA_API_URL,
    [string]$TenantId = $env:GXRA_TENANT_ID,
    [int]$IntervalMin = 30,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$TaskName = "GXRA-Agent-Snapshot"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Resolve-GxraSnapshotCommand {
    # install-windows.ps1 uses C:\gxra-agent-venv by default
    $candidates = @(
        "C:\gxra-agent-venv\Scripts\gxra-agent.exe",
        (Join-Path $Root ".venv\Scripts\gxra-agent.exe"),
        "C:\gxra-agent-venv\Scripts\python.exe",
        (Join-Path $Root ".venv\Scripts\python.exe")
    )
    foreach ($exe in $candidates) {
        if (-not (Test-Path $exe)) { continue }
        if ($exe -like "*python.exe") {
            return "`"$exe`" -m gxra.agent.cli snapshot"
        }
        return "`"$exe`" snapshot"
    }
    throw "gxra-agent not found. Run .\scripts\install-windows.ps1 -PilotEntity first."
}

$GxraCmd = Resolve-GxraSnapshotCommand

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task $TaskName"
    exit 0
}

if (-not $ApiUrl) { $ApiUrl = Read-Host "GX-RA API URL (e.g. http://192.168.68.54:8081)" }
if (-not $TenantId) { $TenantId = Read-Host "Tenant ID (e.g. pilot-1)" }
$ApiUrl = $ApiUrl.TrimEnd("/")

# ScheduledTasks -Argument must be one string (not string[]).
$psCommand = "`$env:GXRA_API_URL='$ApiUrl'; `$env:GXRA_TENANT_ID='$TenantId'; `$env:GXRA_AGENT_TIER_MAX='1'; $GxraCmd"
$psArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"$psCommand`""
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $psArgs
# RepetitionDuration cannot be [TimeSpan]::MaxValue (Task Scheduler rejects P99999999D…).
# Daily trigger + 24h repetition = every IntervalMin indefinitely.
$Trigger = New-ScheduledTaskTrigger -Daily -At "00:05" `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin) `
    -RepetitionDuration (New-TimeSpan -Hours 24)
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null

Write-Host "OK: $TaskName every $IntervalMin min (GXRA_AGENT_TIER_MAX=1)"
Write-Host "  command: $GxraCmd"
Write-Host "Check: Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
