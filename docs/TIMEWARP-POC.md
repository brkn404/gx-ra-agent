# Time-Warp CRIU proof-of-capability

**Scope:** Linux-only, CRIU-based, assurance-linked proof slice for process/memory checkpoint work.

**Status:** Lab-validated on Ubuntu 24.04 with CRIU 4.2

## What this proves

This proof is intentionally narrower than the full research architecture.

It proves:

1. A Linux process can be checkpointed with **CRIU**
2. The checkpoint can be represented as a fixed artifact set (`images/` + manifest)
3. The checkpoint can be linked to the current GX-RA host identity and latest behavioral state capture
4. The run can emit both a legacy `timewarp-manifest.json` and a more product-shaped `recovery-set.json`
5. The checkpoint can be restored later in a controlled lab setting

It does **not** prove yet:

- adaptive interval control
- pre-attack triggering from GenomeX/QSBA
- ring-buffer retention
- API-native Time-Warp object storage in GX-RA
- production-safe restore semantics for arbitrary workloads

## Validation status

The assurance-linked Linux proof now has one successful end-to-end lab validation on:

- Ubuntu 24.04 VM
- Linux `6.17.0-29-generic`
- CRIU `4.2`
- `gxra-agent` registered against GX-RA API
- bundled C demo target using the `minimal` profile

That validation proved:

1. `gxra-agent snapshot` returned a real `state_id`
2. `criu dump` completed and produced checkpoint images
3. the manifest captured GX-RA metadata plus checkpoint digests
4. `criu restore` succeeded after the original PID was stopped

An earlier Ubuntu 22.04 / CRIU 3.16.1 AMD VM reproduced the capture path but failed during restore, which now appears to be an environment-level compatibility problem rather than a flaw in the assurance-link design.

## Why this is the first slice

The research docs are ambitious, but they also call out real constraints:

- CRIU is **Linux-only**
- very short intervals like 3 seconds are not realistic today for most workloads
- the first risk is proving checkpoint/restore works at all for representative processes

So the first proof should be:

```text
gxra-agent snapshot
  -> CRIU checkpoint of a Linux process
  -> manifest with entity_id + state_id + digests
  -> optional manual restore
```

That gives GX-RA an **assurance-linked** checkpoint artifact without pretending the full product already exists.

## Files

- `scripts/timewarp-criu-poc.sh`
- `scripts/timewarp_target.py`

## Prerequisites

| Item | Notes |
|------|-------|
| Linux host | Ubuntu lab VM or another Linux test node |
| Root | `sudo` required for CRIU in most cases |
| `criu` | Install via distro package manager |
| `gxra-agent` config | Needed if you want the proof linked to an entity/state |

Example install:

```bash
sudo apt-get update
sudo apt-get install -y criu
```

## Capture flow

### Demo target

Run the proof with the bundled mutable target:

```bash
cd ~/kit/gx-ra-agent
sudo ./scripts/timewarp-criu-poc.sh capture
```

This will:

1. start a simple demo target (`scripts/timewarp_target.c` when `cc` is available, otherwise `scripts/timewarp_target.py`)
2. optionally run `gxra-agent snapshot`
3. checkpoint the target with CRIU
4. write a manifest under `/tmp/gxra-timewarp-poc/<run-id>/`

For the most conservative retest path, force the minimal C profile:

```bash
sudo GXRA_TIMEWARP_TARGET_PROFILE=minimal ./scripts/timewarp-criu-poc.sh capture
```

That profile uses a smaller memory blob, faster ticks with sparser state-file writes, `/dev/null` for target stdout/stderr, and conservative compiler flags for the C demo target.

### Existing PID

Checkpoint a specific process instead:

```bash
sudo ./scripts/timewarp-criu-poc.sh capture <pid>
```

### Compound service boundary

Capture a `systemd`-managed service boundary with a paired storage snapshot:

```bash
sudo GXRA_TIMEWARP_TARGET_ID=rt-timewarp-worker-service \
     GXRA_TIMEWARP_SYSTEMD_UNIT=timewarp-worker.service \
     GXRA_TIMEWARP_LVM_ORIGIN=/dev/vg_timewarp/lv_worker \
     GXRA_TIMEWARP_MOUNT_POINTS=/srv/timewarp-worker \
     GXRA_TIMEWARP_QUIESCE_MODE=cooperative \
     GXRA_TIMEWARP_CONSISTENCY_GRADE=quiesced \
     ./scripts/timewarp-criu-poc.sh capture-set
```

Concrete lab target entry:

- `docs/timewarp-ubuntu24-worker-target.json`

## Output layout

```text
/tmp/gxra-timewarp-poc/<run-id>/
├── images/                  # CRIU checkpoint images
├── live-state.json          # demo target state (if using bundled target)
├── criu-dump.log*           # CRIU dump logs (`--log-pid` may add suffixes)
├── criu-dump-diagnostics.txt
├── criu-restore.log*        # after restore (`--log-pid` may add suffixes)
├── criu-restore-diagnostics.txt
├── gxra-snapshot.log        # gxra-agent resolution/snapshot diagnostics
├── target.stdout.log
├── target.stderr.log
├── timewarp-manifest.json   # legacy proof manifest
└── recovery-set.json        # compound recovery_set record
```

## Manifest fields

The initial manifest includes:

- `entity_id`
- `device_did`
- `hostname`
- `tenant_id`
- `gxra_state_id`
- `gxra_genome_digest`
- `gxra_drift`
- `checkpoint_digest`
- `target_pid`
- `target_kind`
- `target_profile`
- `checkpoint_dir`

This is the current bridge from Time-Warp to GX-RA assurance.

## Recovery-set output

Each capture now also emits `recovery-set.json` with:

- `capture_window`
- `behavioral_context`
- `boundary`
- `artifacts`
- `candidate_lanes`

When `capture-set` is used with `GXRA_TIMEWARP_SYSTEMD_UNIT` and `GXRA_TIMEWARP_LVM_ORIGIN`, the script will:

1. resolve the service boundary from `systemd`
2. create an LVM snapshot
3. run the CRIU dump
4. write a `recovery-set.json` that binds the behavioral, storage, and process artifacts together

When `GXRA_RECOVERY_INGEST=1` (default), capture also runs `scripts/gxra-recovery-ingest.sh`, which:

1. registers `docs/timewarp-ubuntu24-worker-target.json` with the agent `entity_id`
2. posts `recovery-set.json` to `POST /v1/recovery/sets` on `GXRA_API_URL`

Disable with `GXRA_RECOVERY_INGEST=0` or ingest manually:

```bash
export GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1
./scripts/gxra-recovery-ingest.sh /tmp/gxra-timewarp-poc/<run-id>/recovery-set.json
```

## Restore flow

The restore path now refuses to run if the original PID is still alive, unless you explicitly allow the script to stop it.

### Safe restore with auto-stop

```bash
sudo GXRA_TIMEWARP_KILL_ORIGINAL=1 ./scripts/timewarp-criu-poc.sh restore /tmp/gxra-timewarp-poc/<run-id>
```

The auto-stop path now sends `SIGTERM`, waits a short grace period, and escalates to `SIGKILL` if the original PID still has not exited. If the PID still lingers, the script prints `ps` details before refusing the restore.

### Manual stop first

```bash
sudo kill <pid>
while ps -p <pid> > /dev/null; do sleep 1; done
sudo ./scripts/timewarp-criu-poc.sh restore /tmp/gxra-timewarp-poc/<run-id>
```

If restore fails, the script now prints a restore failure summary and the CRIU log tail.

If restore still fails with only a short CRIU fatal line, inspect:

```bash
sudo sed -n '1,200p' /tmp/gxra-timewarp-poc/<run-id>/criu-restore.log*
sudo sed -n '1,200p' /tmp/gxra-timewarp-poc/<run-id>/criu-restore-diagnostics.txt
```

## Assurance-link troubleshooting

If capture reports `gxra_snapshot: unavailable`, inspect:

```bash
sudo sed -n '1,200p' /tmp/gxra-timewarp-poc/<run-id>/gxra-snapshot.log
```

You can also force the exact agent binary/config under `sudo`:

```bash
sudo GXRA_AGENT_BIN=/home/<user>/gx-ra-agent/.venv/bin/gxra-agent \
     GXRA_AGENT_CONFIG=/home/<user>/.config/gxra-agent/config.json \
     ./scripts/timewarp-criu-poc.sh capture
```

## Conservative retest path

If the default C target still crashes at restore, retest with the most conservative profile:

```bash
sudo GXRA_TIMEWARP_TARGET_PROFILE=minimal ./scripts/timewarp-criu-poc.sh capture
sudo GXRA_TIMEWARP_TARGET_PROFILE=minimal GXRA_TIMEWARP_KILL_ORIGINAL=1 \
     ./scripts/timewarp-criu-poc.sh restore /tmp/gxra-timewarp-poc/<run-id>
```

## Practical caveats

- Use simple lab targets first. Arbitrary processes with network sockets, namespaces, or special kernel interactions may fail.
- The PoC now prefers a very small C demo target when a compiler is available because it is typically more CRIU-friendly than a full Python process.
- The first successful restore validation was on Ubuntu 24.04 with CRIU 4.2; older distro/package combinations may still fail at restore time.
- Restore semantics are workload-specific; a successful CRIU restore does not automatically imply production-safe recovery.
- The manifest is currently a local artifact, not yet a first-class GX-RA API object.

## Recommended next step after this proof

After a successful Linux lab run:

1. ~~add a GX-RA API concept for `recovery_set`~~ (done in GX-RA `POST /v1/recovery/sets`)
2. ~~store the recovery-set manifest server-side~~ (ingest script + console UI)
3. link authorize decisions to ledger for set-only paths (GX-RA API)
3. optionally anchor digest metadata on the assurance ledger
4. connect checkpoint triggering to watch/QSBA conditions
