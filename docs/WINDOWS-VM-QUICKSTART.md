# Windows VM — gxra-agent quickstart (pilot)

**API:** `http://192.168.68.54:8081` · **Tenant:** `pilot-1`  
**Pilot entity:** `ent-2272a0680155` (WIN-VM-LAB01) — baseline **frozen** on API

---

## Prerequisites

- Windows 10/11 or Server 2019+
- Network to spark API (`192.168.68.54:8081`)
- **Git for Windows** (for E2E bash script) — [https://git-scm.com/download/win](https://git-scm.com/download/win)
- Python 3.10+ (installer can use `winget` if missing)

---

## Path A — Pilot VM (recommended for your test)

Use the **existing** fleet entity; do **not** run `register` (that creates a new `ent-…`).

### 1. PowerShell (Admin optional)

```powershell
cd C:\path\to\gx-ra-agent
# or: git clone https://github.com/brkn404/gx-ra-agent.git C:\gx-ra-agent
$env:GXRA_API_URL = "http://192.168.68.54:8081"
$env:GXRA_TENANT_ID = "pilot-1"
.\scripts\install-windows.ps1 -PilotEntity
```

This installs into `C:\gxra-agent-venv`, binds `ent-2272a0680155`, skips learn (already frozen).

**Manual bind** (if agent already installed):

```powershell
C:\gxra-agent-venv\Scripts\gxra-agent.exe bind ent-2272a0680155 `
  --hostname WIN-VM-LAB01 --device-did did:gx:host-WIN-VM-LAB01
C:\gxra-agent-venv\Scripts\gxra-agent.exe status
```

Config file: `%APPDATA%\gxra-agent\config.json`

### 1b. Continuous watch (30 min scheduled task)

After baseline is **frozen**, install the periodic snapshot task (tier 1 collectors, low overhead):

```powershell
$env:GXRA_API_URL = "http://192.168.68.54:8081"
$env:GXRA_TENANT_ID = "pilot-1"
.\scripts\install-periodic-task.ps1
Get-ScheduledTask -TaskName GXRA-Agent-Snapshot | Get-ScheduledTaskInfo
```

Verify from spark: `GET /v1/entities/ent-2272a0680155/watch/status` → `watch_state: active`.

### 2. E2E demo (Git Bash)

```bash
cd /c/gx-ra-agent   # or your clone path
export GXRA_API_URL=http://192.168.68.54:8081
export GXRA_TENANT_ID=pilot-1
./scripts/gxra_e2e_windows.sh
```

Or double-click `scripts\gxra_e2e_windows.bat` (uses pilot entity by default).

**Expected:** Step 0 frozen baseline → backup → clean scan → **ALLOW** → verify ok.

---

## Path B — New Windows host (register + learn)

```powershell
$env:GXRA_API_URL = "http://192.168.68.54:8081"
$env:GXRA_TENANT_ID = "pilot-1"
.\scripts\install-windows.ps1 -Hostname MY-WIN-HOST
```

Then E2E with entity from config:

```bash
./scripts/gxra_e2e_windows.sh
```

---

## Troubleshooting

| Issue | Fix |
|--------|-----|
| `gxra-agent: command not found` | Use `C:\gxra-agent-venv\Scripts\gxra-agent.exe` or re-run `install-windows.ps1` |
| Step 0 not frozen | `gxra-agent learn --start-learning --interval 60 --count 4 --freeze` |
| Wrong entity in E2E | `ENTITY_ID=ent-2272a0680155 ./scripts/gxra_e2e_windows.sh` |
| API unreachable | Ping/curl `http://192.168.68.54:8081/health` from VM |
| Git Bash missing | Install Git for Windows or use Path A PowerShell + API curl tests |

---

## Pilot console

Open from Windows browser: **http://192.168.68.54:8081/console**  
Settings → API URL: `http://192.168.68.54:8081`

---

## Related

- `docs/UBUNTU-VM-QUICKSTART.md` — Linux peer host  
- `docs/VEEAM-PILOT.md` — backup webhook simulation  
- GX-RA `docs/PILOT-RUNBOOK.md` — fleet entity table  
