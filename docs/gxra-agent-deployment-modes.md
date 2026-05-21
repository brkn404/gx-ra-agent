# gxra-agent — deployment modes and overhead

The agent is a **CLI**, not a background service. Choose how often it runs based on what you need to prove at recovery time.

## Modes (recommended order)

| Mode | When it runs | Steady-state CPU/RAM | Best for |
|------|----------------|----------------------|----------|
| **A. Pre-backup snapshot** (default) | Veeam / backup pre-freeze hook | **~0** between backups | Pilot, production — behavior **at backup time** |
| **B. Periodic snapshot** | systemd timer / cron (e.g. 30–60 min) | **~0** between ticks; burst per run | Drift trending, console top slots without waiting for backup |
| **C. Learn loop** | Install / re-baseline only | Process exits after `--count` samples | Initial 64D baseline — **not** 24/7 |
| **D. Always-on daemon** | Not shipped | Would be continuous | Only if you add live alerting later |

**Recommendation for GX-RA pilot:** **A only** on protected VMs, plus **C once** at install (`deploy-linux-agent.sh`). Add **B** only on hosts where you want drift visible between backups.

## Why not run all the time?

Recovery assurance is anchored on **“was this host behaving normally when we took the backup?”** That question is answered by a **snapshot at pre-freeze**, not by a resident process.

| Always-on / every few minutes | Pre-backup only |
|------------------------------|-----------------|
| More API states, QSBA noise, storage | One state per backup job |
| ~10s burst × 96/day @ 15 min = noisy | ~10s burst × backups/day |
| Harder to explain “ground truth” moment | Clear story for auditors |

Use **periodic** snapshots when operators need the console drift view between backups; use **15–60 min** intervals, not every 1–2 min.

## Overhead (measure on each host)

```bash
cd ~/gx-ra-agent
./scripts/benchmark-agent-overhead.sh
GXRA_AGENT_TIER_MAX=1 ./scripts/benchmark-agent-overhead.sh
```

Typical **per invocation** (Linux, tier 2):

- **Wall time:** ~2–15 s (depends on `journalctl`, `/tmp` file count, `ps`)
- **Peak RAM:** ~35–45 MB (short-lived Python + httpx + psutil)
- **CPU:** brief spike; `psutil` uses a **100 ms** blocking CPU sample per collect

Between runs: **no agent process** → **0%** agent CPU/RAM.

## Signal tiers (lighter collects)

| `GXRA_AGENT_TIER_MAX` | Collectors |
|------------------------|------------|
| `2` (default) | Full host set including `volume_activity` (`find /tmp`) |
| `1` | Tier 0–1 only — skips tier-2 `volume_activity` |
| `0` | Identity + virt only — minimal |

Set in the backup hook or timer environment:

```bash
export GXRA_AGENT_TIER_MAX=1
```

## Example: periodic drift (optional)

```ini
# /etc/systemd/system/gxra-agent-snapshot.timer
[Unit]
Description=GX-RA behavioral snapshot

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/gxra-agent-snapshot.service
[Unit]
Description=GX-RA snapshot push

[Service]
Type=oneshot
Environment=GXRA_API_URL=http://192.168.68.54:8081
Environment=GXRA_TENANT_ID=pilot-1
Environment=GXRA_AGENT_TIER_MAX=1
ExecStart=/home/kit/gxra-agent/.venv/bin/gxra-agent snapshot
```

Enable: `sudo systemctl enable --now gxra-agent-snapshot.timer`

## Veeam pre-freeze (production path)

```bash
export GXRA_API_URL=http://192.168.68.54:8081
export GXRA_TENANT_ID=pilot-1
export GXRA_AGENT_TIER_MAX=1
/home/<user>/gx-ra-agent/.venv/bin/gxra-agent snapshot
```

Pair with the Veeam webhook / associate flow on the API (see `docs/VEEAM-PILOT.md`).

## Decision checklist

1. **Is baseline frozen?** → if no, run `learn` once, not continuously.  
2. **Do you need drift between backups?** → if no, **snapshot on backup only**.  
3. **Is collect >10s on this host?** → run benchmark; try `GXRA_AGENT_TIER_MAX=1`.  
4. **Is backup window sensitive?** → tier 1 + pre-freeze only; avoid 5 min timers on the same VM.
