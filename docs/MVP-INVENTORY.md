# GX-RA MVP — inventory (built vs demo)

**As of:** 2026-05-20  
**Pilot API:** `http://192.168.68.54:8081` · tenant `pilot-1`  
**Repos:** [GX-RA](https://github.com/brkn404/GX-RA) (API/product) · [gx-ra-agent](https://github.com/brkn404/gx-ra-agent) (host agent + demos)

> **Note:** GX-RA source restored on `spark` from Docker (2026-05-20): `gxra/`, `docker-compose.yml`, lighthouse scripts, MVP docs under `docs/`.

---

## 1. MVP goal (what “done” means)

A lighthouse customer can:

1. Install **gxra-agent** on protected VMs (Windows + Linux).  
2. **Learn + freeze** a behavioral baseline.  
3. On backup: agent snapshot + **Veeam-shaped webhook** → association, PoS-B, chain anchor.  
4. Optional **post-backup scan** (Predatar-shaped webhook).  
5. **Authorize** restore → `ALLOW` / `DENY` / `CONFIRM` with reasons + token.  
6. **Verify** / export assurance artifacts.

---

## 2. What is built (running pilot)

### 2.1 GX-RA API (Docker `gxra-api`, port 8081)

| Capability | Status | Notes |
|------------|--------|--------|
| Health / OpenAPI | ✅ | `/health`, `/docs` |
| Entity registry | ✅ | `POST /v1/entities` |
| Behavioral baseline | ✅ | start-learning, freeze, GET baseline + drift |
| Telemetry ingest | ✅ | `POST /v1/telemetry/states` + hybrid TI fields |
| Snapshot associate | ✅ | Merkle + BDNA chain + PoS-B vault |
| Veeam webhook | ✅ | `POST /v1/webhooks/veeam/backup-complete` |
| Generic backup vendors | ✅ | Cohesity, Rubrik, etc. via generic connector |
| Predatar / scan webhooks | ✅ | `scan-complete` → effective QSBA |
| Recovery authorize | ✅ | Policy on BSAL, QSBA, scans, hybrid TI |
| Assurance verify | ✅ | `GET /v1/verify/assurance` |
| Assurance export ZIP | ✅ | `GET /v1/assurance/export` |
| Audit trail | ✅ | `GET /v1/audit/events` |
| Threat intel bundle | ✅ | MalwareBazaar / abuse.ch; offline bundle in volume |
| Agent install downloads | ✅ | `/agent/*` (when static mounted in image) |
| Webhook HMAC | ❌ | Not implemented |
| GenomeX in Docker | ❌ | Default `memory` stub; QSBA often 0 without explicit scores |
| Baseline drift in authorize | ❌ | Drift computed on telemetry; not gating authorize yet |
| Multi-tenant hardening | ❌ | Header-based tenant only |

### 2.2 Host agent (`gx-ra-agent` repo)

| Capability | Status | Notes |
|------------|--------|--------|
| CLI: register, learn, freeze, snapshot, status | ✅ | |
| 51D host fingerprint genome | ✅ | Tier 0 MVP collector |
| Linux / Windows / macOS | ✅ | pip + PyInstaller CI |
| Virt detection (VMware guest, etc.) | ✅ | |
| Windows install scripts | ✅ | `install-windows.ps1`, `run-install.bat` |
| Tier 1 collectors (backup_integrity, etc.) | ❌ | Strategy doc only |
| agentGX pipeline | ❌ | Future |

### 2.3 Integrity layer (`bsr/` in monorepo)

| Capability | Status |
|------------|--------|
| Merkle tree, chain ledger | ✅ (in API path) |
| Local OS snapshot scan | ✅ (API exists; not in main demo path) |

---

## 3. What is in the demo (scripts & tests)

All scripts live in **gx-ra-agent** unless noted.

| Script / test | Story | Proven on |
|---------------|--------|-----------|
| `deploy-linux-agent.sh` | Install agent + learn + freeze | ubuntuvmlab01, spark |
| `gxra_e2e_demo.sh` | Baseline → backup → scan → **ALLOW** → verify | ubuntuvmlab01 ✅ |
| `simulate-veeam-backup.sh` | `snapshot` + Veeam webhook (with telemetry) | ubuntuvmlab01 ✅ |
| `tests/test_e2e_pilot.py` | Automated ALLOW path | ubuntuvmlab01 ✅, WIN-VM ✅ |
| `tests/test_e2e_deny.py` | Hybrid hash DENY + infected scan DENY | spark ✅ |
| `gxra_e2e_windows.sh` | Windows entity E2E (`ent-c8b507e0cad4`) | spark ✅ |
| `run-install.bat` / `install-windows.ps1` | Windows agent deploy | WIN-VM (manual) |
| **Ransomware lighthouse** (`GX-RA/scripts/gxra_ransomware_lighthouse_demo.sh`) | ALLOW + hybrid DENY + scan DENY + export | spark ✅ |
| **Hybrid smoke** (`GX-RA/scripts/gxra_hybrid_demo.sh`) | Single TI DENY | GX-RA repo |
| Manual `curl` authorize | ALLOW on `veeam-sim-*` without scan | spark ✅ |

### Demo flow (trusted path — what you show customers)

```text
[gxra-agent on VM]  register → learn → freeze
       ↓
[optional] gxra-agent snapshot  (pre-backup)
       ↓
[Veeam sim or real]  POST .../veeam/backup-complete  (genome + L2)
       ↓
[Predatar sim]       POST .../predatar/scan-complete  (clean)
       ↓
[Orchestrator]       POST .../recovery/authorize  → ALLOW
       ↓
[Auditor]            GET .../verify/assurance  → ok=true
```

### Demo flow (ransomware lighthouse — negative cases)

```text
Act 1: clean backup + scan → ALLOW
Act 2: malware hash at backup → hybrid DENY (T1486)
Act 3: infected repository scan → DENY
Act 4: assurance export ZIP
```

---

## 4. Pilot fleet (tenant `pilot-1`)

| Display name | entity_id | Agent deployed | E2E ALLOW | Notes |
|--------------|-----------|----------------|-----------|--------|
| **ubuntuvmlab01** | `ent-dc373af54c54` | ✅ frozen (4) | ✅ | Primary Linux demo VM |
| **linux-lab-01** (spark) | `ent-ee15ec9d6569` | ✅ frozen (4) | ✅ | Dev host |
| **WIN-VM-LAB01** | `ent-c8b507e0cad4` | ✅ frozen (6) | ✅ | `gxra_e2e_windows.sh` ALLOW path |
| WIN-VM-LAB01 (duplicate reg) | `ent-9ca6a15a491c` | ? | — | Clean up if unused |
| lighthouse-* | various | ❌ | ✅ | Demo-only entities from lighthouse script |

---

## 5. MVP roadmap phase status

| Phase | Goal | Status |
|-------|------|--------|
| **0** Foundation | API, connectors, TI, chain, policy | ✅ Running in Docker |
| **1** Trusted host | Agent + ALLOW path + install docs | ✅ **Done** (ubuntuvmlab01) |
| **2** Production behavioral | GenomeX, Tier-1 collectors, drift policy | ❌ Not started |
| **3** Hardening | HMAC, deployment guide, export v2, perf | ❌ Partial (install docs in agent repo) |
| **4** Sign-off | Rehearsal, pilot kit, checklist | ❌ In progress |

---

## 6. Gaps vs MVP sign-off checklist

| # | Criterion | Status |
|---|-----------|--------|
| 1 | Ransomware lighthouse demo script | ⚠️ Restore in GX-RA repo |
| 2 | Trusted VM demo (Linux + Windows) | ✅ Linux; ⚠️ Windows E2E |
| 3 | GenomeX QSBA in Docker | ❌ |
| 4 | Predatar infected → DENY documented | ✅ (lighthouse Act 3; curl) |
| 5 | Assurance export ZIP verifies | ✅ (when script run) |
| 6 | TI bundle sync documented | ⚠️ `.env` + sync; doc in GX-RA if restored |
| 7 | Agent install Win + Linux | ✅ gx-ra-agent docs |
| 8 | Webhook HMAC | ❌ |
| 9 | Deployment + runbook | ⚠️ Partial (`UBUNTU-VM-QUICKSTART`, `VEEAM-PILOT`) |
| 10 | No critical bugs on pilot path | ✅ Current path stable |

---

## 7. Veeam: simulate vs trial

| Mode | Status | Use |
|------|--------|-----|
| **Simulate** (`simulate-veeam-backup.sh`) | ✅ Production-shaped | All current demos |
| **Veeam 30-day trial** | Not installed | Optional sales story |

See [VEEAM-PILOT.md](./VEEAM-PILOT.md).

---

## 8. Documentation map

| Doc | Repo | Purpose |
|-----|------|---------|
| **MVP-INVENTORY.md** (this file) | gx-ra-agent | Built vs demo inventory |
| [UBUNTU-VM-QUICKSTART.md](./UBUNTU-VM-QUICKSTART.md) | gx-ra-agent | Ubuntu VM agent install |
| [VEEAM-PILOT.md](./VEEAM-PILOT.md) | gx-ra-agent | Simulate vs real Veeam |
| README.md | gx-ra-agent | Agent install overview |
| `gxra-mvp-roadmap.md` | GX-RA (missing locally) | Phased plan ~8–10 weeks |
| `gxra-product-overview.md` | GX-RA (missing locally) | Product story |
| `gxra-phase1-spec.md` | GX-RA (missing locally) | API spec |
| `gxra-agent-install.md` | GX-RA (missing locally) | Full install + Windows |

**Action:** Restore GX-RA product docs from git history or backup; keep operational docs in gx-ra-agent until then.

---

## 9. Recommended demo command (single machine)

On **ubuntuvmlab01** (or any Linux agent host):

```bash
cd ~/gx-ra-agent
export GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1
SNAPSHOT=1 ./scripts/simulate-veeam-backup.sh
# scan + authorize (or full e2e):
./scripts/gxra_e2e_demo.sh
```

On **spark** (authorize only for last sim job):

```bash
curl -s -X POST http://192.168.68.54:8081/v1/recovery/authorize \
  -H "X-Tenant-Id: pilot-1" -H "Content-Type: application/json" \
  -d '{"entity_id":"ent-dc373af54c54","external_snapshot_id":"<job-from-sim>"}'
```

---

## 10. Next engineering priorities

1. **Restore GX-RA repo** (source + `gxra_ransomware_lighthouse_demo.sh` + MVP docs).  
2. **Windows E2E** — `ENTITY_ID=ent-c8b507e0cad4 ./scripts/gxra_e2e_demo.sh` from a host with API access.  
3. **pytest DENY path** — hybrid hash + infected scan (mirror lighthouse).  
4. **Phase 2** — GenomeX optional in compose; drift thresholds on authorize.  
5. **Phase 3** — webhook HMAC + single deployment runbook PDF/md.
