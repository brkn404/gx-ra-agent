# Raspberry Pi — gxra-agent quickstart

**API:** `http://192.168.68.54:8081` · **Tenant:** `pilot-1`  
Target profile: **`linux-arm64`** (same collectors as Ubuntu ARM).

## 1. Packages + clone

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip git curl

git clone https://github.com/brkn404/gx-ra-agent.git ~/gx-ra-agent
cd ~/gx-ra-agent
git pull   # latest: benchmark, periodic timer, collectors
```

## 2. Reach API from the Pi

```bash
curl -s http://192.168.68.54:8081/health | python3 -m json.tool
```

Must return `"status":"ok"`. Fix routing/firewall if not.

## 3. Deploy (new fleet entity)

Creates a **new** `ent-…` on the API (do not use `bind` unless reusing an existing entity).

```bash
export GXRA_API_URL=http://192.168.68.54:8081
export GXRA_TENANT_ID=pilot-1

# Product default (standard ~24h baseline + 30m timer):
./scripts/deploy-linux-agent.sh rpi-lab-01 --product-default

# Pilot-fast only:
# ./scripts/deploy-linux-agent.sh rpi-lab-01 --quick-baseline
```

## 4. Verify

```bash
.venv/bin/gxra-agent info
.venv/bin/gxra-agent status
./scripts/benchmark-agent-overhead.sh
# optional: sudo apt install -y time  (script works without it)
```

Expect `target: linux-arm64` in `info`.

## 5. Console

Open `http://192.168.68.54:8081/console` → **Entities** → find **rpi-lab-01** → Overview (top slots after snapshots).

## Reuse existing entity (pilot bind)

Only if this Pi replaces a known host:

```bash
.venv/bin/gxra-agent bind ent-XXXXXXXX --hostname rpi-lab-01
```

## Notes

| Topic | Pi-specific |
|-------|-------------|
| Arch | `linux-arm64` — fully supported |
| Overhead | Run `benchmark-agent-overhead.sh`; often 1–5 s per collect on light SD images |
| SD card | Prefer `GXRA_AGENT_TIER_MAX=1` for timer/pre-freeze |
| Binary | Optional release `gxra-agent-linux-arm64.tar.gz` if you skip Python venv |
| Heat/load | Avoid `linux-synthetic-drift-lab.sh` stress-ng on small Pis unless testing |

See also: [`UBUNTU-VM-QUICKSTART.md`](UBUNTU-VM-QUICKSTART.md), [`gxra-agent-deployment-modes.md`](gxra-agent-deployment-modes.md).
