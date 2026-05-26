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
TARGET_KIND="${GXRA_TIMEWARP_TARGET_KIND:-auto}"
KILL_ORIGINAL_ON_RESTORE="${GXRA_TIMEWARP_KILL_ORIGINAL:-0}"
RESTORE_WAIT_SEC="${GXRA_TIMEWARP_RESTORE_WAIT_SEC:-10}"

_sudo_user_home() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    getent passwd "$SUDO_USER" | "$PY_BIN" -c 'import sys; line=sys.stdin.read().strip(); print(line.split(":")[5] if line else "")'
  fi
}

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
  local sudo_home=""
  sudo_home="$(_sudo_user_home)"
  if [[ -n "$sudo_home" && -x "$sudo_home/gx-ra-agent/.venv/bin/gxra-agent" ]]; then
    echo "$sudo_home/gx-ra-agent/.venv/bin/gxra-agent"
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
  local cfg_path="${GXRA_AGENT_CONFIG:-}"
  if [[ -z "$cfg_path" ]]; then
    local sudo_home=""
    sudo_home="$(_sudo_user_home)"
    if [[ -n "$sudo_home" && -f "$sudo_home/.config/gxra-agent/config.json" ]]; then
      cfg_path="$sudo_home/.config/gxra-agent/config.json"
    fi
  fi
  export GXRA_TIMEWARP_CFG_PATH="${cfg_path:-}"
  "$PY_BIN" - <<'PY'
import json, os
from pathlib import Path

cfg_env = os.environ.get("GXRA_TIMEWARP_CFG_PATH")
cfg = Path(cfg_env) if cfg_env else Path(os.environ.get("GXRA_AGENT_CONFIG", Path.home() / ".config/gxra-agent/config.json"))
if not cfg.is_file():
    print("{}")
else:
    print(cfg.read_text())
PY
}

_build_c_target() {
  local out_bin="$1"
  command -v cc >/dev/null 2>&1 || return 1
  cc -O2 -Wall -Wextra "$ROOT/scripts/timewarp_target.c" -o "$out_bin"
}

_spawn_demo_target() {
  local run_dir="$1"
  local state_file="$2"
  local stdout_log="$3"
  local stderr_log="$4"

  local chosen="${TARGET_KIND}"
  local label="$TIMEWARP_LABEL"
  if [[ "$chosen" == "auto" || "$chosen" == "c" ]]; then
    local out_bin="$run_dir/timewarp_target_bin"
    if _build_c_target "$out_bin"; then
      nohup "$out_bin" \
        --state-file "$state_file" \
        --blob-mb "$TIMEWARP_BLOB_MB" \
        --tick-sec "$TIMEWARP_TICK_SEC" \
        --label "${label}-c" \
        >"$stdout_log" 2>"$stderr_log" &
      echo "$! c"
      return
    fi
    if [[ "$chosen" == "c" ]]; then
      echo "Failed to build C target; install a C compiler or use GXRA_TIMEWARP_TARGET_KIND=python." >&2
      exit 1
    fi
  fi

  nohup "$PY_BIN" "$ROOT/scripts/timewarp_target.py" \
    --state-file "$state_file" \
    --blob-mb "$TIMEWARP_BLOB_MB" \
    --tick-sec "$TIMEWARP_TICK_SEC" \
    --label "${label}-python" \
    >"$stdout_log" 2>"$stderr_log" &
  echo "$! python"
}

_read_manifest_field() {
  local manifest_path="$1"
  local field="$2"
  MANIFEST_PATH="$manifest_path" FIELD="$field" "$PY_BIN" - <<'PY'
import json
import os
from pathlib import Path

p = Path(os.environ["MANIFEST_PATH"])
field = os.environ["FIELD"]
if not p.is_file():
    print("")
else:
    data = json.loads(p.read_text())
    print(data.get(field, ""))
PY
}

_wait_for_pid_exit() {
  local pid="$1"
  local max_wait="$2"
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
    if (( i >= max_wait )); then
      return 1
    fi
  done
  return 0
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
  local target_kind="$7"

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
  TARGET_KIND="$target_kind" \
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
    "target_kind": os.environ.get("TARGET_KIND", ""),
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
  local target_kind=""
  if [[ -n "$ARG" ]]; then
    pid="$ARG"
    target_kind="external"
  else
    read -r pid target_kind <<<"$(_spawn_demo_target "$run_dir" "$state_file" "$run_dir/target.stdout.log" "$run_dir/target.stderr.log")"
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
  _write_manifest "$run_dir/timewarp-manifest.json" "$run_dir" "$pid" "$state_file" "$digest" "$telemetry_out" "$target_kind"

  echo "=== Time-Warp capture complete ==="
  echo "run_dir: $run_dir"
  echo "target_pid: $pid"
  echo "target_kind: $target_kind"
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
  echo "  2) stop original PID $pid before restore, or use GXRA_TIMEWARP_KILL_ORIGINAL=1"
  echo "  3) sudo GXRA_TIMEWARP_KILL_ORIGINAL=1 $0 restore $run_dir"
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
  local manifest_path="$run_dir/timewarp-manifest.json"
  [[ -d "$images_dir" ]] || {
    echo "Missing images dir: $images_dir" >&2
    exit 1
  }

  local target_pid=""
  target_pid="$(_read_manifest_field "$manifest_path" "target_pid")"
  if [[ -n "$target_pid" ]] && kill -0 "$target_pid" 2>/dev/null; then
    if [[ "$KILL_ORIGINAL_ON_RESTORE" == "1" ]]; then
      echo "Original PID $target_pid still alive; sending SIGTERM..."
      kill "$target_pid" 2>/dev/null || true
      if ! _wait_for_pid_exit "$target_pid" "$RESTORE_WAIT_SEC"; then
        echo "Original PID $target_pid did not exit after ${RESTORE_WAIT_SEC}s; sending SIGKILL..." >&2
        kill -9 "$target_pid" 2>/dev/null || true
        if ! _wait_for_pid_exit "$target_pid" 2; then
          echo "Failed to stop original PID $target_pid; refusing restore." >&2
          exit 1
        fi
      fi
    else
      echo "Original PID $target_pid is still alive. Refusing restore to avoid PID collision." >&2
      echo "Retry with: sudo GXRA_TIMEWARP_KILL_ORIGINAL=1 $0 restore $run_dir" >&2
      exit 1
    fi
  fi

  set +e
  "$CRIU_BIN" restore \
    -D "$images_dir" \
    --shell-job \
    -o "$restore_log"
  local restore_rc=$?
  set -e

  if [[ $restore_rc -ne 0 ]]; then
    echo "=== Time-Warp restore failed ===" >&2
    echo "run_dir: $run_dir" >&2
    echo "restore_log: $restore_log" >&2
    if [[ -f "$restore_log" ]]; then
      echo "--- restore log excerpt ---" >&2
      sed -n '1,120p' "$restore_log" >&2
    fi
    exit "$restore_rc"
  fi

  echo "=== Time-Warp restore succeeded ==="
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
