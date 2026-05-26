# gx-ra-agent

Host agent for **[GX-RA](https://github.com/brkn404/GX-RA)** (GenomeX Recovery Assurance). Installs on protected VMs, learns a behavioral baseline, and pushes telemetry to your GX-RA API at backup time.

**API / product repo:** [GX-RA](https://github.com/brkn404/GX-RA) (Docker, webhooks, authorize, threat intel)

---

## Quick install

### Windows (PowerShell)

**Pilot VM (WIN-VM-LAB01, entity `ent-2272a0680155`):** full steps in [`docs/WINDOWS-VM-QUICKSTART.md`](docs/WINDOWS-VM-QUICKSTART.md)

```powershell
git clone https://github.com/brkn404/gx-ra-agent.git C:\gx-ra-agent
cd C:\gx-ra-agent
$env:GXRA_API_URL = "http://192.168.68.54:8081"
$env:GXRA_TENANT_ID = "pilot-1"
.\scripts\install-windows.ps1 -PilotEntity   # bind fleet entity; skip learn (frozen on API)
```

**New host** (creates a new `ent-…`):

```powershell
.\scripts\install-windows.ps1 -Hostname MY-WIN-HOST
```

**E2E (Git Bash):** `./scripts/gxra_e2e_windows.sh` or `scripts\gxra_e2e_windows.bat`

Config: `%APPDATA%\gxra-agent\config.json`

### Linux / Raspberry Pi (ARM64)

Pi OS and Ubuntu ARM: see [`docs/RASPBERRY-PI-QUICKSTART.md`](docs/RASPBERRY-PI-QUICKSTART.md).

```bash
python3 -m venv ~/.venv/gxra-agent
source ~/.venv/gxra-agent/bin/activate
pip install "gx-ra-agent @ git+https://github.com/brkn404/gx-ra-agent.git"

export GXRA_API_URL=http://192.168.68.54:8081
export GXRA_TENANT_ID=pilot-1

gxra-agent register --hostname prod-linux-01
gxra-agent learn --start-learning --interval 300 --count 12 --freeze
```

### Standalone binary (no Python on host)

Download from **[Releases](https://github.com/brkn404/gx-ra-agent/releases)**:

| Artifact | Platform |
|----------|----------|
| `gxra-agent-windows-amd64.zip` | Windows x64 |
| `gxra-agent-linux-amd64.tar.gz` | Linux x64 |
| `gxra-agent-linux-arm64.tar.gz` | Linux ARM64 |
| `gxra-agent-darwin-arm64.tar.gz` | macOS Apple Silicon |

```powershell
# Example: Windows
Expand-Archive gxra-agent-windows-amd64.zip -DestinationPath "C:\Program Files\GX-RA"
$env:GXRA_API_URL = "http://192.168.68.54:8081"
$env:GXRA_TENANT_ID = "pilot-1"
& "C:\Program Files\GX-RA\gxra-agent.exe" register --hostname win-vm3
```

---

## Prerequisites

| Item | Notes |
|------|--------|
| GX-RA API | Running and reachable from the VM (e.g. `http://<host>:8081/health`) |
| Tenant | `GXRA_TENANT_ID` must match API (`X-Tenant-Id`) |
| Outbound HTTP | Agent only **calls** the API; no inbound firewall rules |

Test from the VM:

```powershell
Invoke-RestMethod "$env:GXRA_API_URL/health"
```

---

## Commands

| Command | Purpose |
|---------|---------|
| `gxra-agent info` | OS, arch, config path, signal tiers |
| `gxra-agent register` | Create entity on API, save `entity_id` locally |
| `gxra-agent start-learning` | Open baseline learning window |
| `gxra-agent learn` | Push telemetry on an interval (optional `--freeze`) |
| `gxra-agent freeze` | Freeze baseline from samples |
| `gxra-agent snapshot` | One-shot telemetry push (Veeam pre-freeze) |
| `gxra-agent status` | Baseline status + drift |

---

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `GXRA_API_URL` | `http://127.0.0.1:8080` | GX-RA API base URL |
| `GXRA_TENANT_ID` | `default` | Tenant header |
| `GXRA_AGENT_CONFIG` | OS-specific path | Override config file |
| `GXRA_SIGNAL_TIER_MAX` | `0` | Max collector tier (see GX-RA signal strategy doc) |

---

## Deployment and overhead

The agent is **not** a daemon. Default pilot mode: **one `snapshot` per backup** (Veeam pre-freeze). Optional periodic timer for drift between backups.

See [`docs/gxra-agent-deployment-modes.md`](docs/gxra-agent-deployment-modes.md) and run:

```bash
./scripts/benchmark-agent-overhead.sh
```

| Variable | Purpose |
|----------|---------|
| `GXRA_AGENT_TIER_MAX` | `0`–`2` — skip heavier collectors at lower tiers (`2` = full) |

## Veeam pre-freeze (optional)

```bat
@echo off
set GXRA_API_URL=http://192.168.68.54:8081
set GXRA_TENANT_ID=pilot-1
"C:\Program Files\GX-RA\gxra-agent.exe" snapshot
exit /b 0
```

---

## MVP inventory

**What is built vs what the demos prove:** [docs/MVP-INVENTORY.md](docs/MVP-INVENTORY.md)

## Time-Warp proof of capability

Linux-only CRIU proof scaffold (checkpoint + restore + GX-RA state link):

- [docs/TIMEWARP-POC.md](docs/TIMEWARP-POC.md)
- `sudo ./scripts/timewarp-criu-poc.sh capture`
- `sudo GXRA_TIMEWARP_TARGET_ID=rt-timewarp-worker-service GXRA_TIMEWARP_SYSTEMD_UNIT=timewarp-worker.service GXRA_TIMEWARP_LVM_ORIGIN=/dev/vg_timewarp/lv_worker GXRA_TIMEWARP_MOUNT_POINTS=/srv/timewarp-worker ./scripts/timewarp-criu-poc.sh capture-set`
- `sudo GXRA_TIMEWARP_TARGET_PROFILE=minimal ./scripts/timewarp-criu-poc.sh capture`
- `sudo GXRA_TIMEWARP_KILL_ORIGINAL=1 ./scripts/timewarp-criu-poc.sh restore /tmp/gxra-timewarp-poc/<run-id>`

The PoC now prefers a tiny C demo target when `cc` is available, supports a more conservative `minimal` target profile for restore retests, emits verbose CRIU diagnostics into the run directory, writes both a legacy `timewarp-manifest.json` and a product-shaped `recovery-set.json`, and can capture a first compound `systemd + LVM` boundary via `capture-set`. The first successful assurance-linked restore validation was completed on Ubuntu 24.04 with CRIU 4.2.

Concrete lab target entry:

- `docs/timewarp-ubuntu24-worker-target.json`

## Linux deploy + E2E demo

Fresh Ubuntu VM: see **[docs/UBUNTU-VM-QUICKSTART.md](docs/UBUNTU-VM-QUICKSTART.md)**.

```bash
cd ~/gx-ra-agent   # not ~/kit/gx-ra-agent unless that path exists
export GXRA_API_URL=http://192.168.68.54:8081
export GXRA_TENANT_ID=pilot-1
./scripts/deploy-linux-agent.sh my-hostname
./scripts/gxra_e2e_demo.sh
.venv/bin/pytest tests/test_e2e_pilot.py -v
```

Automated test (API must be running):

```bash
GXRA_API_BASE=http://192.168.68.54:8081 pytest tests/test_e2e_pilot.py -v
```

## Development

```bash
git clone https://github.com/brkn404/gx-ra-agent.git
cd gx-ra-agent
pip install -e ".[dev,build]"
pytest -q
./scripts/build_agent.sh
```

Source is synced from the main GX-RA monorepo (`gxra/agent/`). In GX-RA run:

`./scripts/sync_agent_to_gxra_agent_repo.sh`

---

## License

MIT — see [LICENSE](LICENSE).
