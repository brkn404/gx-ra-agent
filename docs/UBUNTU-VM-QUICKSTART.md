# Ubuntu VM — gxra-agent quickstart

Use this on **ubuntuvmlab01** (or any fresh Ubuntu guest).  
Do **not** use `~/kit/gx-ra-agent` unless that path exists on the VM.

## 1. Packages + clone (once)

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip git curl

git clone https://github.com/brkn404/gx-ra-agent.git ~/gx-ra-agent
cd ~/gx-ra-agent
```

## 2. Check API from this VM

```bash
curl -s http://192.168.68.54:8081/health
```

Must return `"status":"ok"`. If not, fix network (bridged NIC) or use the correct GX-RA host IP.

## 3. Deploy agent

```bash
export GXRA_API_URL=http://192.168.68.54:8081
export GXRA_TENANT_ID=pilot-1

./scripts/deploy-linux-agent.sh ubuntuvmlab01
```

## 4. E2E demo

```bash
cd ~/gx-ra-agent
export GXRA_API_URL=http://192.168.68.54:8081
export GXRA_TENANT_ID=pilot-1
./scripts/gxra_e2e_demo.sh
```

## 5. Benchmark overhead (optional)

```bash
cd ~/gx-ra-agent
./scripts/benchmark-agent-overhead.sh
GXRA_AGENT_TIER_MAX=1 ./scripts/benchmark-agent-overhead.sh
```

See [`gxra-agent-deployment-modes.md`](gxra-agent-deployment-modes.md) for when to use backup-only vs periodic snapshots.

## 6. Synthetic drift lab (collector testing)

```bash
cd ~/gx-ra-agent
export GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1
./scripts/linux-synthetic-drift-lab.sh
# Manual snapshot (venv — not on default PATH):
./.venv/bin/gxra-agent snapshot
./.venv/bin/gxra-agent status
```

## 7. Automated test (use venv pytest, not system pytest)

```bash
cd ~/gx-ra-agent
GXRA_API_BASE=http://192.168.68.54:8081 .venv/bin/pytest tests/test_e2e_pilot.py -v
```

## Common mistakes

| Error | Fix |
|-------|-----|
| `cd ~/kit/gx-ra-agent` No such file | Use `cd ~/gx-ra-agent` |
| `.venv/bin/activate` missing | Run `./scripts/deploy-linux-agent.sh` (creates `.venv`) |
| `python3-venv` / venv failed | `sudo apt install -y python3-venv` |
| `pytest not found` | Use `.venv/bin/pytest`, not bare `pytest` |
| `ENTITY_ID` / deploy first | Run `deploy-linux-agent.sh` before `gxra_e2e_demo.sh` |
