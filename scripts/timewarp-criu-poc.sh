#!/usr/bin/env bash
# Linux-only Time-Warp proof-of-capability:
#   1) capture a GX-RA behavioral state via gxra-agent snapshot
#   2) checkpoint a demo or supplied process with CRIU
#   3) write an assurance-linked manifest with digests + entity metadata
#   4) optionally restore from the checkpoint later
#
# Usage:
#   sudo ./scripts/timewarp-criu-poc.sh capture
#   sudo ./scripts/timewarp-criu-poc.sh capture <pid>
#   sudo ./scripts/timewarp-criu-poc.sh restore /tmp/gxra-timewarp-poc/<run-id>
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-capture}"
ARG="${2:-}"

WORK_ROOT="${GXRA_TIMEWARP_DIR:-/tmp/gxra-timewarp-poc}"
CRIU_BIN="${CRIU_BIN:-criu}"
PY_BIN="${PY_BIN:-python3}"
TIMEWARP_LABEL="${TIMEWARP_LABEL:-timewarp-demo}"
TIMEWARP_BLOB_MB="${TIMEWARP_BLOB_MB:-8}"
TIMEWARP_TICK_SEC="${TIMEWARP_TICK_SEC:-1.0}"
GXRA_AGENT_BIN="${GXRA_AGENT_BIN:-}"
CAPTURE_TELEMETRY="${GXRA_TIMEWARP_CAPTURE_TELEMETRY:-1}"

_need_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "Run as root (CRIU dump/restore usually requires sudo)." >&2
    exit 1
  fi
}

_check_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Linux only: this proof uses CRIU." >&2
    exit 1
  fi
}

_resolve_agent_bin() {
  if [[ -n "$GXRA_AGENT_BIN" && -x "$GXRA_AGENT_BIN" ]]; then
    echo "$GXRA_AGENT_BIN"
    return
  fi
  if [[ -x "$ROOT/.venv/bin/gxra-agent" ]]; then
    echo "$ROOT/.venv/bin/gxra-agent"
    return
  fi
  if command -v gxra-agent >/dev/null 2>&1; then
    command -v gxra-agent
    return
  fi
  echo ""
}

_read_cfg_json() {
  "$PY_BIN" - <<'PY'
import json, os
from pathlib import Path

cfg = Path(os.environ.get("GXRA_AGENT_CONFIG", Path.home() / ".config/gxra-agent/config.json"))
if not cfg.is_file():
    print("{}")
else:
    print(cfg.read_text())
PY
}

_compute_dir_digest() {
  local target_dir="$1"
  TARGET_DIR="$target_dir" "$PY_BIN" - <<'PY'
import hashlib
import os
from pathlib import Path

root = Path(os.environ["TARGET_DIR"])
h = hashlib.sha256()
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    rel = path.relative_to(root).as_posix().encode()
    h.update(rel)
    h.update(b"\0")
    h.update(path.read_bytes())
    h.update(b"\0")
print(h.hexdigest())
PY
}

_capture_telemetry() {
  local agent_bin="$1"
  if [[ "$CAPTURE_TELEMETRY" != "1" ]]; then
    echo ""
    return 0
  fi
  if [[ -z "$agent_bin" ]]; then
    echo ""
    return 0
  fi
  local out
  out="$("$agent_bin" snapshot 2>/dev/null || true)"
  echo "$out"
}

_write_manifest() {
  local manifest_path="$1"
  local checkpoint_dir="$2"
  local pid="$3"
  local state_file="$4"
  local checkpoint_digest="$5"
  local telemetry_out="$6"

  local cfg_json
  cfg_json="$(_read_cfg_json)"
  MANIFEST_PATH="$manifest_path" \
  CHECKPOINT_DIR="$checkpoint_dir" \
  TARGET_PID="$pid" \
  STATE_FILE="$state_file" \
  CHECKPOINT_DIGEST="$checkpoint_digest" \
  TELEMETRY_OUT="$telemetry_out" \
  CFG_JSON="$cfg_json" \
  TIMEWARP_LABEL="$TIMEWARP_LABEL" \
  "$PY_BIN" - <<'PY'
import json
import os
import re
import time
from pathlib import Path

cfg = json.loads(os.environ["CFG_JSON"])
telemetry = os.environ.get("TELEMETRY_OUT", "")
state_id = ""
genome_digest = ""
drift = ""

for key, pattern in {
    "state_id": r"state_id=([^\s]+)",
    "genome_digest": r"digest=([^\s]+)",
    "drift": r"drift=([^\s]+)",
}.items():
    m = re.search(pattern, telemetry)
    if m:
        if key == "state_id":
            state_id = m.group(1)
        elif key == "genome_digest":
            genome_digest = m.group(1).rstrip("…")
        elif key == "drift":
            drift = m.group(1)

manifest = {
    "timewarp_label": os.environ["TIMEWARP_LABEL"],
    "created_at": time.time(),
    "checkpoint_dir": os.environ["CHECKPOINT_DIR"],
    "checkpoint_digest": os.environ["CHECKPOINT_DIGEST"],
    "target_pid": int(os.environ["TARGET_PID"]),
    "state_file": os.environ["STATE_FILE"],
    "entity_id": cfg.get("entity_id", ""),
    "device_did": cfg.get("device_did", ""),
    "hostname": cfg.get("hostname", ""),
    "tenant_id": cfg.get("tenant_id", ""),
    "api_url": cfg.get("api_url", ""),
    "gxra_state_id": state_id,
    "gxra_genome_digest": genome_digest,
    "gxra_drift": drift,
    "assurance_linked": bool(state_id),
    "notes": [
        "Initial Linux-only Time-Warp proof slice",
        "Checkpoint linked to latest gxra-agent snapshot when available",
        "Future GX-RA API work should persist this manifest as a first-class Time-Warp event",
    ],
}

Path(os.environ["MANIFEST_PATH"]).write_text(json.dumps(manifest, indent=2))
PY
}

capture_mode() {
  _check_linux
  _need_root
  command -v "$CRIU_BIN" >/dev/null 2>&1 || {
    echo "Missing CRIU. Install with your distro package manager first." >&2
    exit 1
  }

  mkdir -p "$WORK_ROOT"
  local run_id
  run_id="$(date +%Y%m%d-%H%M%S)"
  local run_dir="$WORK_ROOT/$run_id"
  local images_dir="$run_dir/images"
  local state_file="$run_dir/live-state.json"
  local criu_log="$run_dir/criu-dump.log"
  mkdir -p "$images_dir"

  local pid=""
  if [[ -n "$ARG" ]]; then
    pid="$ARG"
  else
    nohup "$PY_BIN" "$ROOT/scripts/timewarp_target.py" \
      --state-file "$state_file" \
      --blob-mb "$TIMEWARP_BLOB_MB" \
      --tick-sec "$TIMEWARP_TICK_SEC" \
      --label "$TIMEWARP_LABEL" \
      >"$run_dir/target.stdout.log" 2>"$run_dir/target.stderr.log" &
    pid="$!"
    sleep 2
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Target PID $pid is not running." >&2
    exit 1
  fi

  local agent_bin=""
  agent_bin="$(_resolve_agent_bin)"
  local telemetry_out=""
  telemetry_out="$(_capture_telemetry "$agent_bin")"

  "$CRIU_BIN" dump \
    -t "$pid" \
    -D "$images_dir" \
    --shell-job \
    --leave-running \
    -o "$criu_log"

  local digest
  digest="$(_compute_dir_digest "$images_dir")"
  _write_manifest "$run_dir/timewarp-manifest.json" "$run_dir" "$pid" "$state_file" "$digest" "$telemetry_out"

  echo "=== Time-Warp capture complete ==="
  echo "run_dir: $run_dir"
  echo "target_pid: $pid"
  echo "images_dir: $images_dir"
  echo "manifest: $run_dir/timewarp-manifest.json"
  if [[ -n "$telemetry_out" ]]; then
    echo "gxra_snapshot: $telemetry_out"
  else
    echo "gxra_snapshot: skipped (no gxra-agent config/bin or disabled)"
  fi
  echo ""
  echo "Next:"
  echo "  1) inspect $state_file and $run_dir/timewarp-manifest.json"
  echo "  2) stop original PID $pid before restore"
  echo "  3) sudo $0 restore $run_dir"
}

restore_mode() {
  _check_linux
  _need_root
  if [[ -z "$ARG" ]]; then
    echo "Usage: sudo $0 restore /path/to/run_dir" >&2
    exit 1
  fi
  local run_dir="$ARG"
  local images_dir="$run_dir/images"
  local restore_log="$run_dir/criu-restore.log"
  [[ -d "$images_dir" ]] || {
    echo "Missing images dir: $images_dir" >&2
    exit 1
  }

  "$CRIU_BIN" restore \
    -D "$images_dir" \
    --shell-job \
    -o "$restore_log"

  echo "=== Time-Warp restore invoked ==="
  echo "run_dir: $run_dir"
  echo "restore_log: $restore_log"
  echo "Inspect the restored process state via the target state file or process list."
}

case "$MODE" in
  capture) capture_mode ;;
  restore) restore_mode ;;
  *)
    echo "Usage: $0 {capture [pid]|restore <run_dir>}" >&2
    exit 1
    ;;
esac
