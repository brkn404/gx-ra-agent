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
#   sudo GXRA_TIMEWARP_SYSTEMD_UNIT=timewarp-worker.service \
#        GXRA_TIMEWARP_LVM_ORIGIN=/dev/vg_timewarp/lv_worker \
#        ./scripts/timewarp-criu-poc.sh capture-set
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
TIMEWARP_TARGET_PROFILE="${GXRA_TIMEWARP_TARGET_PROFILE:-default}"
GXRA_AGENT_BIN="${GXRA_AGENT_BIN:-}"
CAPTURE_TELEMETRY="${GXRA_TIMEWARP_CAPTURE_TELEMETRY:-1}"
TARGET_KIND="${GXRA_TIMEWARP_TARGET_KIND:-auto}"
KILL_ORIGINAL_ON_RESTORE="${GXRA_TIMEWARP_KILL_ORIGINAL:-0}"
TERM_WAIT_SEC="${GXRA_TIMEWARP_TERM_WAIT_SEC:-3}"
RESTORE_WAIT_SEC="${GXRA_TIMEWARP_RESTORE_WAIT_SEC:-10}"
CRIU_LOG_LEVEL="${GXRA_TIMEWARP_CRIU_LOG_LEVEL:-4}"
CRIU_LOG_PID="${GXRA_TIMEWARP_CRIU_LOG_PID:-1}"
# auto: use --shell-job only on an interactive TTY (avoids restore hangs when piped to tee)
TIMEWARP_SHELL_JOB="${GXRA_TIMEWARP_SHELL_JOB:-auto}"
TIMEWARP_TARGET_ID="${GXRA_TIMEWARP_TARGET_ID:-}"
TIMEWARP_TARGET_CLASS="${GXRA_TIMEWARP_TARGET_CLASS:-recovery}"
TIMEWARP_BOUNDARY_TYPE="${GXRA_TIMEWARP_BOUNDARY_TYPE:-process_tree}"
TIMEWARP_BOUNDARY_ID="${GXRA_TIMEWARP_BOUNDARY_ID:-}"
TIMEWARP_SYSTEMD_UNIT="${GXRA_TIMEWARP_SYSTEMD_UNIT:-}"
TIMEWARP_CGROUP_PATH="${GXRA_TIMEWARP_CGROUP_PATH:-}"
TIMEWARP_CONTAINER_REF="${GXRA_TIMEWARP_CONTAINER_REF:-}"
TIMEWARP_MOUNT_POINTS="${GXRA_TIMEWARP_MOUNT_POINTS:-}"
TIMEWARP_NETWORK_NOTES="${GXRA_TIMEWARP_NETWORK_NOTES:-}"
TIMEWARP_DEPENDENCY_NOTES="${GXRA_TIMEWARP_DEPENDENCY_NOTES:-}"
TIMEWARP_QUIESCE_MODE="${GXRA_TIMEWARP_QUIESCE_MODE:-none}"
TIMEWARP_CONSISTENCY_GRADE="${GXRA_TIMEWARP_CONSISTENCY_GRADE:-best_effort}"
TIMEWARP_CLEAN_CORRIDOR_DEPTH="${GXRA_TIMEWARP_CLEAN_CORRIDOR_DEPTH:-0}"
TIMEWARP_HYBRID_SCORE="${GXRA_TIMEWARP_HYBRID_SCORE:-}"
TIMEWARP_CAPTURE_POSTURE="${GXRA_TIMEWARP_CAPTURE_POSTURE:-auto}"
TIMEWARP_STORAGE_PROVIDER="${GXRA_TIMEWARP_STORAGE_PROVIDER:-none}"
TIMEWARP_STORAGE_SNAPSHOT_REF="${GXRA_TIMEWARP_STORAGE_SNAPSHOT_REF:-}"
TIMEWARP_STORAGE_SCOPE="${GXRA_TIMEWARP_STORAGE_SCOPE:-}"
TIMEWARP_LVM_ORIGIN="${GXRA_TIMEWARP_LVM_ORIGIN:-}"
TIMEWARP_LVM_SNAPSHOT_SIZE="${GXRA_TIMEWARP_LVM_SNAPSHOT_SIZE:-2G}"
TIMEWARP_LVM_SNAPSHOT_NAME="${GXRA_TIMEWARP_LVM_SNAPSHOT_NAME:-}"

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

_cfg_path() {
  local cfg_path="${GXRA_AGENT_CONFIG:-}"
  local sudo_home=""
  sudo_home="$(_sudo_user_home)"
  if [[ -z "$cfg_path" && -n "${ROOT:-}" && -f "$ROOT/.gxra-agent-config.json" ]]; then
    cfg_path="$ROOT/.gxra-agent-config.json"
  fi
  if [[ -z "$cfg_path" && -n "$sudo_home" && -f "$sudo_home/.config/gxra-agent/config.json" ]]; then
    cfg_path="$sudo_home/.config/gxra-agent/config.json"
  fi
  if [[ -z "$cfg_path" && -f "$HOME/.config/gxra-agent/config.json" ]]; then
    cfg_path="$HOME/.config/gxra-agent/config.json"
  fi
  echo "$cfg_path"
}

_resolve_agent_bin() {
  if [[ -n "$GXRA_AGENT_BIN" && -x "$GXRA_AGENT_BIN" ]]; then
    echo "$GXRA_AGENT_BIN"
    return
  fi
  local sudo_home=""
  sudo_home="$(_sudo_user_home)"
  local candidates=(
    "${VIRTUAL_ENV:-}/bin/gxra-agent"
    "$ROOT/.venv/bin/gxra-agent"
    "$PWD/.venv/bin/gxra-agent"
    "$sudo_home/.venv/bin/gxra-agent"
    "$sudo_home/gx-ra-agent/.venv/bin/gxra-agent"
    "$sudo_home/.local/bin/gxra-agent"
  )
  local candidate=""
  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done
  if command -v gxra-agent >/dev/null 2>&1; then
    command -v gxra-agent
    return
  fi
  echo ""
}

_slugify() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

_systemd_show_property() {
  local unit="$1"
  local prop="$2"
  systemctl show -p "$prop" --value "$unit" 2>/dev/null | "$PY_BIN" -c 'import sys; print(sys.stdin.read().strip())'
}

_find_mount_for_source() {
  local source="$1"
  command -v findmnt >/dev/null 2>&1 || return 0
  findmnt -nr -S "$source" -o TARGET 2>/dev/null | "$PY_BIN" -c 'import sys; data=sys.stdin.read().strip().splitlines(); print(data[0] if data else "")'
}

_read_cfg_json() {
  local cfg_path=""
  cfg_path="$(_cfg_path)"
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
  local arch_flags=()
  case "$(uname -m)" in
    x86_64)
      arch_flags=(-march=x86-64 -mtune=generic)
      ;;
    aarch64|arm64)
      arch_flags=(-march=armv8-a)
      ;;
  esac
  cc \
    -O0 \
    -g \
    -Wall \
    -Wextra \
    -fno-stack-protector \
    -fcf-protection=none \
    -fno-omit-frame-pointer \
    -fno-pie \
    -no-pie \
    "${arch_flags[@]}" \
    "$ROOT/scripts/timewarp_target.c" \
    -o "$out_bin"
}

_spawn_demo_target() {
  local run_dir="$1"
  local state_file="$2"
  local stdout_log="$3"
  local stderr_log="$4"

  local chosen="${TARGET_KIND}"
  local label="$TIMEWARP_LABEL"
  local stdout_target="$stdout_log"
  local stderr_target="$stderr_log"
  local blob_mb="$TIMEWARP_BLOB_MB"
  local tick_sec="$TIMEWARP_TICK_SEC"
  if [[ "$TIMEWARP_TARGET_PROFILE" == "minimal" ]]; then
    printf 'minimal profile redirects target stdout to /dev/null\n' >"$stdout_log"
    printf 'minimal profile redirects target stderr to /dev/null\n' >"$stderr_log"
    stdout_target="/dev/null"
    stderr_target="/dev/null"
    if [[ "$blob_mb" == "8" ]]; then
      blob_mb="1"
    fi
    if [[ "$tick_sec" == "1.0" ]]; then
      tick_sec="0.5"
    fi
  fi
  if [[ "$chosen" == "auto" || "$chosen" == "c" ]]; then
    local out_bin="$run_dir/timewarp_target_bin"
    if _build_c_target "$out_bin"; then
      nohup "$out_bin" \
        --state-file "$state_file" \
        --blob-mb "$blob_mb" \
        --tick-sec "$tick_sec" \
        --profile "$TIMEWARP_TARGET_PROFILE" \
        --label "${label}-c" \
        >"$stdout_target" 2>"$stderr_target" &
      echo "$! c:${TIMEWARP_TARGET_PROFILE}"
      return
    fi
    if [[ "$chosen" == "c" ]]; then
      echo "Failed to build C target; install a C compiler or use GXRA_TIMEWARP_TARGET_KIND=python." >&2
      exit 1
    fi
  fi

  nohup "$PY_BIN" "$ROOT/scripts/timewarp_target.py" \
    --state-file "$state_file" \
    --blob-mb "$blob_mb" \
    --tick-sec "$tick_sec" \
    --label "${label}-python" \
    >"$stdout_target" 2>"$stderr_target" &
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
    printf '.' >&2
    sleep 1
    i=$((i + 1))
    if (( i >= max_wait )); then
      printf '\n' >&2
      return 1
    fi
  done
  if (( i > 0 )); then
    printf ' done\n' >&2
  fi
  return 0
}

_manifest_systemd_unit() {
  local manifest_path="$1"
  local unit="${TIMEWARP_SYSTEMD_UNIT:-}"
  if [[ -n "$unit" ]]; then
    echo "$unit"
    return
  fi
  local target_kind=""
  target_kind="$(_read_manifest_field "$manifest_path" "target_kind")"
  if [[ "$target_kind" == systemd:* ]]; then
    echo "${target_kind#systemd:}"
  fi
}

_stop_systemd_unit_for_restore() {
  local unit="$1"
  echo "Stopping $unit before CRIU restore (systemd would respawn if only the PID were killed)..."
  systemctl stop "$unit" 2>/dev/null || true
  local i=0
  while systemctl is-active --quiet "$unit" 2>/dev/null; do
    printf '.' >&2
    sleep 1
    i=$((i + 1))
    if (( i >= RESTORE_WAIT_SEC )); then
      printf '\n' >&2
      echo "Unit still active after ${RESTORE_WAIT_SEC}s; cleaning worker processes..." >&2
      break
    fi
  done
  if (( i > 0 )) && (( i < RESTORE_WAIT_SEC )); then
    printf ' inactive\n' >&2
  fi

  if pgrep -f '/opt/gxra-timewarp/timewarp-worker' >/dev/null 2>&1; then
    echo "Sending SIGTERM to remaining timewarp-worker processes..."
    pkill -TERM -f '/opt/gxra-timewarp/timewarp-worker' 2>/dev/null || true
    if ! _wait_for_pgrep_exit '/opt/gxra-timewarp/timewarp-worker' "$TERM_WAIT_SEC"; then
      echo "Escalating to SIGKILL for timewarp-worker..." >&2
      pkill -9 -f '/opt/gxra-timewarp/timewarp-worker' 2>/dev/null || true
      _wait_for_pgrep_exit '/opt/gxra-timewarp/timewarp-worker' "$RESTORE_WAIT_SEC" || true
    fi
  fi
  echo "Service boundary stopped; starting CRIU restore."
}

_wait_for_pgrep_exit() {
  local pattern="$1"
  local max_wait="$2"
  local i=0
  while pgrep -f "$pattern" >/dev/null 2>&1; do
    printf '.' >&2
    sleep 1
    i=$((i + 1))
    if (( i >= max_wait )); then
      printf '\n' >&2
      return 1
    fi
  done
  if (( i > 0 )); then
    printf ' done\n' >&2
  fi
  return 0
}

_pid_status_line() {
  local pid="$1"
  ps -o pid=,ppid=,pgid=,stat=,etime=,cmd= -p "$pid" 2>/dev/null | "$PY_BIN" -c 'import sys; print(sys.stdin.read().strip())'
}

_stop_pid_for_restore() {
  local pid="$1"
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  echo "Original PID $pid still alive; sending SIGTERM..."
  kill "$pid" 2>/dev/null || true
  if _wait_for_pid_exit "$pid" "$TERM_WAIT_SEC"; then
    return 0
  fi

  local status_line=""
  status_line="$(_pid_status_line "$pid")"
  if [[ -n "$status_line" ]]; then
    echo "Original PID $pid still present after ${TERM_WAIT_SEC}s: $status_line" >&2
  else
    echo "Original PID $pid still present after ${TERM_WAIT_SEC}s." >&2
  fi

  echo "Escalating to SIGKILL for PID $pid..." >&2
  kill -9 "$pid" 2>/dev/null || true
  if _wait_for_pid_exit "$pid" "$RESTORE_WAIT_SEC"; then
    return 0
  fi

  status_line="$(_pid_status_line "$pid")"
  if [[ -n "$status_line" ]]; then
    echo "PID $pid still exists after SIGKILL: $status_line" >&2
  else
    echo "PID $pid still exists after SIGKILL." >&2
  fi
  return 1
}

_criu_shell_job_args() {
  # Prints --shell-job when appropriate; empty when restore should run headless.
  case "$TIMEWARP_SHELL_JOB" in
    1 | yes | true) echo --shell-job ;;
    0 | no | false) ;;
    auto)
      if [[ -t 0 ]] && [[ -t 1 ]]; then
        echo --shell-job
      fi
      ;;
    *)
      if [[ -t 0 ]] && [[ -t 1 ]]; then
        echo --shell-job
      fi
      ;;
  esac
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

_write_diag_report() {
  local out_path="$1"
  {
    echo "timestamp: $(date -Is)"
    echo "criu_bin: $CRIU_BIN"
    echo "criu_version:"
    "$CRIU_BIN" --version || true
    echo ""
    echo "criu_check:"
    "$CRIU_BIN" check || true
    echo ""
    echo "recent_dmesg:"
    dmesg | tail -n 120 || true
  } >"$out_path" 2>&1
}

_print_log_excerpt() {
  local log_base="$1"
  local matched=0
  local file=""
  shopt -s nullglob
  for file in "$log_base"*; do
    [[ -f "$file" ]] || continue
    matched=1
    echo "--- $(basename "$file") ---" >&2
    sed -n '1,160p' "$file" >&2 || true
  done
  shopt -u nullglob
  if [[ $matched -eq 0 ]]; then
    echo "No CRIU logs found matching ${log_base}*" >&2
  fi
}

_capture_telemetry() {
  local agent_bin="$1"
  local cfg_path="$2"
  local log_path="$3"
  if [[ "$CAPTURE_TELEMETRY" != "1" ]]; then
    echo "status: disabled by GXRA_TIMEWARP_CAPTURE_TELEMETRY" >"$log_path"
    echo ""
    return 0
  fi
  if [[ -z "$agent_bin" ]]; then
    echo "status: gxra-agent binary not found under sudo" >"$log_path"
    echo "hint: set GXRA_AGENT_BIN explicitly if needed" >>"$log_path"
    echo ""
    return 0
  fi
  if [[ -z "$cfg_path" ]]; then
    echo "status: gxra-agent config not found under sudo" >"$log_path"
    echo "hint: set GXRA_AGENT_CONFIG explicitly if needed" >>"$log_path"
    echo "agent_bin: $agent_bin" >>"$log_path"
    echo ""
    return 0
  fi
  local out
  {
    echo "agent_bin: $agent_bin"
    echo "cfg_path: $cfg_path"
    echo "working_dir: $ROOT"
    echo ""
  } >"$log_path"
  out="$(GXRA_AGENT_CONFIG="$cfg_path" "$agent_bin" snapshot 2>>"$log_path" || true)"
  if [[ -n "$out" ]]; then
    {
      echo "snapshot_stdout:"
      echo "$out"
    } >>"$log_path"
  else
    echo "snapshot_stdout: <empty>" >>"$log_path"
  fi
  echo "$out"
}

_maybe_capture_storage_snapshot() {
  local run_dir="$1"
  local run_id="$2"
  local provider="$TIMEWARP_STORAGE_PROVIDER"
  local snapshot_ref="$TIMEWARP_STORAGE_SNAPSHOT_REF"
  local scope="$TIMEWARP_STORAGE_SCOPE"
  local captured_at=""
  local log_path="$run_dir/storage-snapshot.log"
  : >"$log_path"

  if [[ -n "$TIMEWARP_LVM_ORIGIN" ]]; then
    command -v lvcreate >/dev/null 2>&1 || {
      echo "Missing lvcreate; install lvm2 or provide GXRA_TIMEWARP_STORAGE_SNAPSHOT_REF." >&2
      exit 1
    }
    local origin_ref="$TIMEWARP_LVM_ORIGIN"
    origin_ref="${origin_ref#/dev/}"
    local origin_vg="${origin_ref%/*}"
    local origin_lv="${origin_ref##*/}"
    local snapshot_name="${TIMEWARP_LVM_SNAPSHOT_NAME:-$(_slugify "${origin_lv}-snap-${run_id}")}"
    {
      echo "provider: lvm"
      echo "origin: $TIMEWARP_LVM_ORIGIN"
      echo "snapshot_name: $snapshot_name"
      echo "snapshot_size: $TIMEWARP_LVM_SNAPSHOT_SIZE"
    } >>"$log_path"
    lvcreate -s -n "$snapshot_name" -L "$TIMEWARP_LVM_SNAPSHOT_SIZE" "$TIMEWARP_LVM_ORIGIN" >>"$log_path" 2>&1
    provider="lvm"
    snapshot_ref="${origin_vg}/${snapshot_name}"
    captured_at="$(date +%s)"
    if [[ -z "$scope" ]]; then
      local origin_source="$TIMEWARP_LVM_ORIGIN"
      if [[ "$origin_source" != /dev/* ]]; then
        origin_source="/dev/$origin_source"
      fi
      scope="$(_find_mount_for_source "$origin_source")"
    fi
  fi

  printf '%s\n%s\n%s\n%s\n' "$provider" "$snapshot_ref" "$scope" "$captured_at"
}

_write_recovery_set() {
  local recovery_set_path="$1"
  local run_dir="$2"
  local images_dir="$3"
  local pid="$4"
  local state_file="$5"
  local checkpoint_digest="$6"
  local telemetry_out="$7"
  local target_kind="$8"
  local target_profile="$9"
  local capture_started_at="${10}"
  local capture_completed_at="${11}"
  local behavioral_captured_at="${12}"
  local process_captured_at="${13}"
  local storage_provider="${14}"
  local storage_snapshot_ref="${15}"
  local storage_scope="${16}"
  local storage_captured_at="${17}"

  local cfg_json
  cfg_json="$(_read_cfg_json)"
  RECOVERY_SET_PATH="$recovery_set_path" \
  RUN_DIR="$run_dir" \
  IMAGES_DIR="$images_dir" \
  TARGET_PID="$pid" \
  STATE_FILE="$state_file" \
  CHECKPOINT_DIGEST="$checkpoint_digest" \
  TELEMETRY_OUT="$telemetry_out" \
  CFG_JSON="$cfg_json" \
  TIMEWARP_LABEL="$TIMEWARP_LABEL" \
  TARGET_KIND="$target_kind" \
  TARGET_PROFILE="$target_profile" \
  CAPTURE_STARTED_AT="$capture_started_at" \
  CAPTURE_COMPLETED_AT="$capture_completed_at" \
  BEHAVIORAL_CAPTURED_AT="$behavioral_captured_at" \
  PROCESS_CAPTURED_AT="$process_captured_at" \
  STORAGE_PROVIDER="$storage_provider" \
  STORAGE_SNAPSHOT_REF="$storage_snapshot_ref" \
  STORAGE_SCOPE="$storage_scope" \
  STORAGE_CAPTURED_AT="$storage_captured_at" \
  TIMEWARP_TARGET_ID="$TIMEWARP_TARGET_ID" \
  TIMEWARP_TARGET_CLASS="$TIMEWARP_TARGET_CLASS" \
  TIMEWARP_BOUNDARY_TYPE="$TIMEWARP_BOUNDARY_TYPE" \
  TIMEWARP_BOUNDARY_ID="$TIMEWARP_BOUNDARY_ID" \
  TIMEWARP_SYSTEMD_UNIT="$TIMEWARP_SYSTEMD_UNIT" \
  TIMEWARP_CGROUP_PATH="$TIMEWARP_CGROUP_PATH" \
  TIMEWARP_CONTAINER_REF="$TIMEWARP_CONTAINER_REF" \
  TIMEWARP_MOUNT_POINTS="$TIMEWARP_MOUNT_POINTS" \
  TIMEWARP_NETWORK_NOTES="$TIMEWARP_NETWORK_NOTES" \
  TIMEWARP_DEPENDENCY_NOTES="$TIMEWARP_DEPENDENCY_NOTES" \
  TIMEWARP_QUIESCE_MODE="$TIMEWARP_QUIESCE_MODE" \
  TIMEWARP_CONSISTENCY_GRADE="$TIMEWARP_CONSISTENCY_GRADE" \
  TIMEWARP_CLEAN_CORRIDOR_DEPTH="$TIMEWARP_CLEAN_CORRIDOR_DEPTH" \
  TIMEWARP_HYBRID_SCORE="$TIMEWARP_HYBRID_SCORE" \
  TIMEWARP_CAPTURE_POSTURE="$TIMEWARP_CAPTURE_POSTURE" \
  "$PY_BIN" - <<'PY'
import json
import os
import re
import time
from pathlib import Path


def parse_float(value):
    if value in (None, ""):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def parse_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def parse_csv(value):
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]


def parse_capture_posture(requested, state_id, drift_score, hybrid_score):
    if requested and requested != "auto":
        return requested
    if not state_id:
        return "confirm"
    if hybrid_score is not None and hybrid_score >= 0.85:
        return "deny"
    if drift_score is not None and drift_score >= 0.15:
        return "deny"
    if hybrid_score is not None and hybrid_score >= 0.5:
        return "confirm"
    if drift_score is not None and drift_score >= 0.08:
        return "confirm"
    return "allow"


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
    match = re.search(pattern, telemetry)
    if not match:
        continue
    if key == "state_id":
        state_id = match.group(1)
    elif key == "genome_digest":
        genome_digest = match.group(1).rstrip("…")
    elif key == "drift":
        drift = match.group(1)

mount_points = parse_csv(os.environ.get("TIMEWARP_MOUNT_POINTS", ""))
storage_provider = os.environ.get("STORAGE_PROVIDER", "") or "none"
storage_snapshot_ref = os.environ.get("STORAGE_SNAPSHOT_REF", "")
storage_scope = os.environ.get("STORAGE_SCOPE", "")
storage_captured_at = parse_int(os.environ.get("STORAGE_CAPTURED_AT", "") or 0, 0)
behavioral_captured_at = parse_int(os.environ.get("BEHAVIORAL_CAPTURED_AT", "") or int(time.time()), int(time.time()))
process_captured_at = parse_int(os.environ.get("PROCESS_CAPTURED_AT", "") or int(time.time()), int(time.time()))
drift_score = parse_float(drift)
hybrid_score = parse_float(os.environ.get("TIMEWARP_HYBRID_SCORE", ""))
capture_posture = parse_capture_posture(
    os.environ.get("TIMEWARP_CAPTURE_POSTURE", "auto"),
    state_id,
    drift_score,
    hybrid_score,
)

boundary_type = os.environ.get("TIMEWARP_BOUNDARY_TYPE", "process_tree") or "process_tree"
systemd_unit = os.environ.get("TIMEWARP_SYSTEMD_UNIT", "")
cgroup_path = os.environ.get("TIMEWARP_CGROUP_PATH", "")
boundary_id = os.environ.get("TIMEWARP_BOUNDARY_ID", "")
if not boundary_id:
    boundary_id = systemd_unit or cgroup_path or f"pid:{os.environ['TARGET_PID']}"

target_id = os.environ.get("TIMEWARP_TARGET_ID", "")
if not target_id:
    if systemd_unit:
        target_id = f"rt-{systemd_unit}"
    else:
        target_id = f"rt-{os.environ['TIMEWARP_LABEL']}"

artifacts = []
if state_id:
    artifacts.append(
        {
            "artifact_id": "art-behavioral-state",
            "artifact_type": "behavioral_state",
            "state_layer": "behavioral",
            "captured_at": behavioral_captured_at,
            "provider": "gxra-agent",
            "reference": state_id,
            "digest": genome_digest,
            "verification_status": "passed",
        }
    )

if storage_snapshot_ref:
    artifacts.append(
        {
            "artifact_id": "art-storage-snapshot",
            "artifact_type": "fs_snapshot",
            "state_layer": "storage",
            "captured_at": storage_captured_at or process_captured_at,
            "provider": storage_provider,
            "reference": storage_snapshot_ref,
            "scope": storage_scope,
            "verification_status": "passed",
        }
    )

artifacts.append(
    {
        "artifact_id": "art-criu-image",
        "artifact_type": "criu_image",
        "state_layer": "process",
        "captured_at": process_captured_at,
        "provider": "criu",
        "reference": os.environ["IMAGES_DIR"],
        "digest": os.environ["CHECKPOINT_DIGEST"],
        "scope": os.environ["TARGET_KIND"],
        "verification_status": "passed",
    }
)

lane_type = "process_storage" if storage_snapshot_ref else "process_only"
required_artifacts = ["art-criu-image"]
if storage_snapshot_ref:
    required_artifacts.insert(0, "art-storage-snapshot")

candidate_lane = {
    "lane_id": f"lane-{lane_type}",
    "lane_type": lane_type,
    "required_artifact_ids": required_artifacts,
    "compatibility_score": 0.7 if storage_snapshot_ref else 0.6,
    "cleanliness_score": 0.95 if capture_posture == "allow" else 0.7 if capture_posture == "confirm" else 0.2,
    "blast_radius_score": 0.9 if lane_type == "process_storage" else 0.85,
    "rto_score": 0.9 if lane_type == "process_storage" else 0.8,
    "evidence_score": 0.7,
    "posture": capture_posture,
    "rank": 1,
    "reasons": [
        "assurance-linked behavioral capture" if state_id else "behavioral capture unavailable",
        "matching storage snapshot present" if storage_snapshot_ref else "process-only artifact set",
        f"boundary={boundary_id}",
    ],
}

capture_order = ["behavioral"]
if storage_snapshot_ref:
    capture_order.append("storage")
capture_order.append("process")

recovery_set = {
    "recovery_set_id": Path(os.environ["RUN_DIR"]).name,
    "tenant_id": cfg.get("tenant_id", ""),
    "entity_id": cfg.get("entity_id", ""),
    "target_id": target_id,
    "target_class": os.environ.get("TIMEWARP_TARGET_CLASS", "recovery") or "recovery",
    "status": "captured",
    "created_at": parse_int(os.environ.get("CAPTURE_STARTED_AT", "") or int(time.time()), int(time.time())),
    "updated_at": parse_int(os.environ.get("CAPTURE_COMPLETED_AT", "") or int(time.time()), int(time.time())),
    "capture_window": {
        "window_id": f"cw-{Path(os.environ['RUN_DIR']).name}",
        "started_at": parse_int(os.environ.get("CAPTURE_STARTED_AT", "") or int(time.time()), int(time.time())),
        "completed_at": parse_int(os.environ.get("CAPTURE_COMPLETED_AT", "") or int(time.time()), int(time.time())),
        "quiesce_mode": os.environ.get("TIMEWARP_QUIESCE_MODE", "none") or "none",
        "capture_order": capture_order,
        "consistency_grade": os.environ.get("TIMEWARP_CONSISTENCY_GRADE", "best_effort") or "best_effort",
        "notes": "Generated by timewarp-criu-poc.sh",
    },
    "behavioral_context": {
        "gxra_state_id": state_id,
        "gxra_genome_digest": genome_digest,
        "bsal_level": "L2" if state_id else "L1",
        "drift_score": drift_score,
        "hybrid_threat_score": hybrid_score,
        "clean_corridor_depth": parse_int(os.environ.get("TIMEWARP_CLEAN_CORRIDOR_DEPTH", "") or 0, 0),
        "post_backup_scan_status": None,
        "capture_posture": capture_posture,
        "reasons": [
            f"target_kind={os.environ.get('TARGET_KIND', '')}",
            f"target_profile={os.environ.get('TARGET_PROFILE', '')}",
        ],
    },
    "boundary": {
        "boundary_type": boundary_type,
        "boundary_id": boundary_id,
        "systemd_unit": systemd_unit,
        "cgroup_path": cgroup_path,
        "container_ref": os.environ.get("TIMEWARP_CONTAINER_REF", ""),
        "root_pid": parse_int(os.environ["TARGET_PID"], 0),
        "processes": [],
        "mount_points": mount_points,
        "network_notes": os.environ.get("TIMEWARP_NETWORK_NOTES", ""),
        "dependency_notes": os.environ.get("TIMEWARP_DEPENDENCY_NOTES", ""),
    },
    "artifacts": artifacts,
    "candidate_lanes": [candidate_lane],
    "selected_lane": None,
    "execution": None,
    "audit": {
        "assurance_anchor_ref": "",
        "export_ref": "",
        "incident_id": "",
        "tags": ["timewarp", "criu", lane_type],
    },
}

Path(os.environ["RECOVERY_SET_PATH"]).write_text(json.dumps(recovery_set, indent=2))
PY
}

_write_manifest() {
  local manifest_path="$1"
  local checkpoint_dir="$2"
  local pid="$3"
  local state_file="$4"
  local checkpoint_digest="$5"
  local telemetry_out="$6"
  local target_kind="$7"
  local target_profile="$8"

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
  TARGET_PROFILE="$target_profile" \
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
    "target_profile": os.environ.get("TARGET_PROFILE", ""),
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

_run_capture() {
  local run_id="$1"
  local run_dir="$2"
  local pid="$3"
  local target_kind="$4"
  local state_file="$5"

  _check_linux
  _need_root
  command -v "$CRIU_BIN" >/dev/null 2>&1 || {
    echo "Missing CRIU. Install with your distro package manager first." >&2
    exit 1
  }
  local images_dir="$run_dir/images"
  local criu_log="$run_dir/criu-dump.log"
  local telemetry_log="$run_dir/gxra-snapshot.log"
  local dump_diag="$run_dir/criu-dump-diagnostics.txt"

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Target PID $pid is not running." >&2
    exit 1
  fi

  local capture_started_at
  capture_started_at="$(date +%s)"

  local agent_bin=""
  agent_bin="$(_resolve_agent_bin)"
  local cfg_path=""
  cfg_path="$(_cfg_path)"
  local telemetry_out=""
  telemetry_out="$(_capture_telemetry "$agent_bin" "$cfg_path" "$telemetry_log")"
  local behavioral_captured_at
  behavioral_captured_at="$(date +%s)"

  local storage_provider=""
  local storage_snapshot_ref=""
  local storage_scope=""
  local storage_captured_at=""
  if [[ -n "$TIMEWARP_LVM_ORIGIN" || -n "$TIMEWARP_STORAGE_SNAPSHOT_REF" ]]; then
    mapfile -t _storage_meta < <(_maybe_capture_storage_snapshot "$run_dir" "$run_id")
    storage_provider="${_storage_meta[0]:-}"
    storage_snapshot_ref="${_storage_meta[1]:-}"
    storage_scope="${_storage_meta[2]:-}"
    storage_captured_at="${_storage_meta[3]:-}"
  fi

  local criu_log_args=("-v${CRIU_LOG_LEVEL}")
  if [[ "$CRIU_LOG_PID" == "1" ]]; then
    criu_log_args+=(--log-pid)
  fi

  local shell_job_args=()
  read -r -a shell_job_args <<<"$(_criu_shell_job_args)"

  set +e
  "$CRIU_BIN" dump \
    -t "$pid" \
    -D "$images_dir" \
    "${shell_job_args[@]}" \
    --leave-running \
    "${criu_log_args[@]}" \
    -o "$criu_log"
  local dump_rc=$?
  set -e

  if [[ $dump_rc -ne 0 ]]; then
    _write_diag_report "$dump_diag"
    echo "=== Time-Warp capture failed ===" >&2
    echo "run_dir: $run_dir" >&2
    echo "dump_log: $criu_log*" >&2
    echo "diagnostics: $dump_diag" >&2
    _print_log_excerpt "$criu_log"
    exit "$dump_rc"
  fi

  local digest
  digest="$(_compute_dir_digest "$images_dir")"
  _write_manifest "$run_dir/timewarp-manifest.json" "$run_dir" "$pid" "$state_file" "$digest" "$telemetry_out" "$target_kind" "$TIMEWARP_TARGET_PROFILE"
  local process_captured_at
  process_captured_at="$(date +%s)"
  _write_recovery_set "$run_dir/recovery-set.json" "$run_dir" "$images_dir" "$pid" "$state_file" "$digest" "$telemetry_out" "$target_kind" "$TIMEWARP_TARGET_PROFILE" "$capture_started_at" "$process_captured_at" "$behavioral_captured_at" "$process_captured_at" "$storage_provider" "$storage_snapshot_ref" "$storage_scope" "$storage_captured_at"

  if [[ "${GXRA_RECOVERY_INGEST:-1}" == "1" && -x "$ROOT/scripts/gxra-recovery-ingest.sh" ]]; then
    if ! "$ROOT/scripts/gxra-recovery-ingest.sh" "$run_dir/recovery-set.json"; then
      echo "Warning: GX-RA recovery ingest failed (capture artifacts remain on disk)." >&2
    fi
  fi

  echo "=== Time-Warp capture complete ==="
  echo "run_dir: $run_dir"
  echo "target_pid: $pid"
  echo "target_kind: $target_kind"
  echo "target_profile: $TIMEWARP_TARGET_PROFILE"
  echo "images_dir: $images_dir"
  echo "manifest: $run_dir/timewarp-manifest.json"
  echo "recovery_set: $run_dir/recovery-set.json"
  if [[ -n "$storage_snapshot_ref" ]]; then
    echo "storage_snapshot: $storage_provider:$storage_snapshot_ref"
  fi
  if [[ -n "$telemetry_out" ]]; then
    echo "gxra_snapshot: $telemetry_out"
  else
    echo "gxra_snapshot: unavailable (see $telemetry_log)"
  fi
  echo ""
  echo "Next:"
  echo "  1) inspect $state_file, $run_dir/timewarp-manifest.json, and $run_dir/recovery-set.json"
  echo "  2) stop original PID $pid before restore, or use GXRA_TIMEWARP_KILL_ORIGINAL=1"
  echo "  3) sudo GXRA_TIMEWARP_KILL_ORIGINAL=1 $0 restore $run_dir"
}

capture_mode() {
  mkdir -p "$WORK_ROOT"
  local run_id
  run_id="$(date +%Y%m%d-%H%M%S)"
  local run_dir="$WORK_ROOT/$run_id"
  local images_dir="$run_dir/images"
  local state_file="$run_dir/live-state.json"
  mkdir -p "$images_dir"

  local pid=""
  local target_kind=""
  if [[ -n "$ARG" ]]; then
    pid="$ARG"
    target_kind="external:${TIMEWARP_TARGET_PROFILE}"
  else
    read -r pid target_kind <<<"$(_spawn_demo_target "$run_dir" "$state_file" "$run_dir/target.stdout.log" "$run_dir/target.stderr.log")"
    sleep 2
  fi

  _run_capture "$run_id" "$run_dir" "$pid" "$target_kind" "$state_file"
}

capture_set_mode() {
  _check_linux
  _need_root
  [[ -n "$TIMEWARP_SYSTEMD_UNIT" ]] || {
    echo "capture-set requires GXRA_TIMEWARP_SYSTEMD_UNIT." >&2
    exit 1
  }
  if [[ -z "$TIMEWARP_LVM_ORIGIN" && -z "$TIMEWARP_STORAGE_SNAPSHOT_REF" ]]; then
    echo "capture-set requires GXRA_TIMEWARP_LVM_ORIGIN or GXRA_TIMEWARP_STORAGE_SNAPSHOT_REF." >&2
    exit 1
  fi

  local pid=""
  pid="$(_systemd_show_property "$TIMEWARP_SYSTEMD_UNIT" MainPID)"
  if [[ -z "$pid" || "$pid" == "0" ]]; then
    echo "Could not resolve MainPID for $TIMEWARP_SYSTEMD_UNIT." >&2
    exit 1
  fi
  if [[ -z "$TIMEWARP_CGROUP_PATH" ]]; then
    TIMEWARP_CGROUP_PATH="$(_systemd_show_property "$TIMEWARP_SYSTEMD_UNIT" ControlGroup)"
  fi
  if [[ -z "$TIMEWARP_BOUNDARY_ID" ]]; then
    TIMEWARP_BOUNDARY_ID="$TIMEWARP_SYSTEMD_UNIT"
  fi
  if [[ "$TIMEWARP_BOUNDARY_TYPE" == "process_tree" ]]; then
    TIMEWARP_BOUNDARY_TYPE="systemd_unit"
  fi
  if [[ -z "$TIMEWARP_TARGET_ID" ]]; then
    TIMEWARP_TARGET_ID="rt-$(_slugify "$TIMEWARP_SYSTEMD_UNIT")"
  fi
  if [[ -z "$TIMEWARP_MOUNT_POINTS" && -n "$TIMEWARP_LVM_ORIGIN" ]]; then
    local origin_source="$TIMEWARP_LVM_ORIGIN"
    if [[ "$origin_source" != /dev/* ]]; then
      origin_source="/dev/$origin_source"
    fi
    TIMEWARP_MOUNT_POINTS="$(_find_mount_for_source "$origin_source")"
  fi

  mkdir -p "$WORK_ROOT"
  local run_id
  run_id="$(date +%Y%m%d-%H%M%S)"
  local run_dir="$WORK_ROOT/$run_id"
  local images_dir="$run_dir/images"
  local state_file="$run_dir/live-state.json"
  mkdir -p "$images_dir"

  _run_capture "$run_id" "$run_dir" "$pid" "systemd:${TIMEWARP_SYSTEMD_UNIT}" "$state_file"
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
  local restore_diag="$run_dir/criu-restore-diagnostics.txt"
  [[ -d "$images_dir" ]] || {
    echo "Missing images dir: $images_dir" >&2
    exit 1
  }

  local target_pid=""
  target_pid="$(_read_manifest_field "$manifest_path" "target_pid")"
  local systemd_unit=""
  systemd_unit="$(_manifest_systemd_unit "$manifest_path")"

  if [[ "$KILL_ORIGINAL_ON_RESTORE" == "1" ]]; then
    if [[ -n "$systemd_unit" ]]; then
      _stop_systemd_unit_for_restore "$systemd_unit"
    elif [[ -n "$target_pid" ]] && kill -0 "$target_pid" 2>/dev/null; then
      if ! _stop_pid_for_restore "$target_pid"; then
        echo "Failed to stop original PID $target_pid; refusing restore." >&2
        exit 1
      fi
    fi
  elif [[ -n "$target_pid" ]] && kill -0 "$target_pid" 2>/dev/null; then
    echo "Original PID $target_pid is still alive. Refusing restore to avoid PID collision." >&2
    echo "Retry with: sudo GXRA_TIMEWARP_KILL_ORIGINAL=1 $0 restore $run_dir" >&2
    exit 1
  fi

  # Service checkpoints restore headless; --shell-job on an SSH TTY often hangs forever.
  if [[ -n "$systemd_unit" && "$TIMEWARP_SHELL_JOB" == "auto" ]]; then
    TIMEWARP_SHELL_JOB=0
    echo "Using headless CRIU restore for systemd unit (GXRA_TIMEWARP_SHELL_JOB=0)."
  fi

  local criu_log_args=("-v${CRIU_LOG_LEVEL}")
  if [[ "$CRIU_LOG_PID" == "1" ]]; then
    criu_log_args+=(--log-pid)
  fi

  local shell_job_args=()
  read -r -a shell_job_args <<<"$(_criu_shell_job_args)"

  echo "Starting CRIU restore from $images_dir (often 30–90s with no further output; log: $restore_log)..."
  if [[ ${#shell_job_args[@]} -gt 0 ]]; then
    echo "  criu args: ${shell_job_args[*]} (set GXRA_TIMEWARP_SHELL_JOB=0 if restore hangs on SSH)"
  fi

  set +e
  "$CRIU_BIN" restore \
    -D "$images_dir" \
    "${shell_job_args[@]}" \
    "${criu_log_args[@]}" \
    -o "$restore_log"
  local restore_rc=$?
  set -e

  if [[ $restore_rc -ne 0 ]]; then
    _write_diag_report "$restore_diag"
    echo "=== Time-Warp restore failed ===" >&2
    echo "run_dir: $run_dir" >&2
    echo "restore_log: $restore_log*" >&2
    echo "diagnostics: $restore_diag" >&2
    _print_log_excerpt "$restore_log"
    exit "$restore_rc"
  fi

  echo "=== Time-Warp restore succeeded ==="
  echo "run_dir: $run_dir"
  echo "restore_log: $restore_log*"
  echo "Inspect the restored process state via the target state file or process list."
}

case "$MODE" in
  capture) capture_mode ;;
  capture-set) capture_set_mode ;;
  restore) restore_mode ;;
  *)
    echo "Usage: $0 {capture [pid]|capture-set|restore <run_dir>}" >&2
    exit 1
    ;;
esac
