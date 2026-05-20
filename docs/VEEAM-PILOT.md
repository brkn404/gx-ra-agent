# Veeam pilot — simulate vs 30-day trial

GX-RA does not need Veeam installed to prove the assurance loop. Your E2e demo already **simulates** Veeam via:

`POST /v1/webhooks/veeam/backup-complete`

---

## Recommendation

| Phase | Approach | When |
|-------|----------|------|
| **Now** | **Simulate** webhooks + agent on VM | Demos, dev, pytest |
| **Later** | **Veeam trial** (30 days) | Customer-facing “real backup” story |

Simulation is enough for MVP sign-off: same API contract, PoS-B, chain anchor, authorize.

---

## Option A — Simulate (no Veeam)

### One-shot (after agent deploy)

```bash
cd ~/gx-ra-agent
export GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1

# Optional: push fresh telemetry like pre-freeze
SNAPSHOT=1 ./scripts/simulate-veeam-backup.sh

# Or webhook only (uses frozen baseline genome)
./scripts/simulate-veeam-backup.sh

# Full story
./scripts/gxra_e2e_demo.sh
```

### What Veeam would send (same shape)

```json
{
  "entity_id": "ent-dc373af54c54",
  "job_id": "veeam-job-20260520-001",
  "finished_at": 1716200000,
  "repository_path": "veeam://backup/repo/job-001",
  "genome": [ ... optional from agent ... ],
  "qsba_score": 0.08,
  "bsal_level": "L2",
  "drift_envelope": "acceptable"
}
```

Map your pilot VMs:

| VM | entity_id |
|----|-----------|
| WIN-VM-LAB01 | `ent-2272a0680155` |
| ubuntuvmlab01 | `ent-dc373af54c54` |

---

## Option B — Veeam 30-day trial

### Typical layout

```text
[Veeam B&R server]  --backs up-->  [WIN-VM-LAB01] [ubuntuvmlab01]
        |
        +-- post-job script or orchestrator --> GX-RA API :8081
[GX-RA API @ 192.168.68.54]
```

### Trial install (high level)

1. Download **Veeam Backup & Replication** trial (Windows server VM).
2. Add **GX-RA protected VMs** as backup jobs.
3. On each guest: `gxra-agent` + pre-freeze script (`gxra-agent snapshot`).
4. On backup success: HTTP POST to GX-RA (PowerShell `Invoke-RestMethod` or curl from Veeam server).

### Post-job script example (Veeam server / guest)

```powershell
$body = @{
  entity_id = "ent-2272a0680155"
  job_id = "veeam-$($env:COMPUTERNAME)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  finished_at = [int][double]::Parse((Get-Date -UFormat %s))
  repository_path = "veeam://repo/job"
  auto_qsba = $false
  qsba_score = 0.08
  bsal_level = "L2"
  drift_envelope = "acceptable"
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://192.168.68.54:8081/v1/webhooks/veeam/backup-complete" `
  -Method Post -Headers @{ "X-Tenant-Id" = "pilot-1" } `
  -ContentType "application/json" -Body $body
```

Store `entity_id` per VM in the script or Veeam credentials/description field.

### Linux guests

Veeam can backup Linux via agent or network mode; pre-freeze can be a bash hook calling `gxra-agent snapshot` then the same webhook from a jump host or automation (Ansible/cron).

---

## Predatar / scan layer

Still simulated for pilot unless you have Predatar:

```bash
curl -X POST .../v1/webhooks/predatar/scan-complete \
  -d '{"external_snapshot_id":"<job_id>","status":"clean","confidence_score":0.98}'
```

Use `status":"infected"` to demo **DENY** (repository layer).

---

## Decision guide

| Goal | Use |
|------|-----|
| Prove GX-RA logic this week | **Simulate** (`simulate-veeam-backup.sh` + `gxra_e2e_demo.sh`) |
| Sales demo “with Veeam logo” | Trial + one Windows VM job |
| Production | Licensed Veeam + certified connector hardening (post-MVP) |

---

## Related

- [UBUNTU-VM-QUICKSTART.md](./UBUNTU-VM-QUICKSTART.md)
- Agent install (Windows): GX-RA `docs/gxra-agent-install.md` (on main GX-RA repo when restored)
