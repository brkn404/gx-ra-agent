#!/usr/bin/env bash
# Register recovery target (agent entity_id) and ingest recovery-set.json into GX-RA API.
#
# Usage:
#   export GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1
#   ./scripts/gxra-recovery-ingest.sh /tmp/gxra-timewarp-poc/20260527-080336/recovery-set.json
#
# Optional:
#   GXRA_RECOVERY_REGISTER_TARGET=0   — skip POST /v1/recovery/targets
#   GXRA_RECOVERY_TARGET_JSON=path    — default docs/timewarp-ubuntu24-worker-target.json
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${1:-}"
PY_BIN="${PY_BIN:-python3}"

if [[ -z "$MANIFEST" || ! -f "$MANIFEST" ]]; then
  echo "Usage: $0 /path/to/recovery-set.json" >&2
  exit 1
fi

BASE="${GXRA_API_URL:-${GXRA_API_BASE:-http://127.0.0.1:8081}}"
BASE="${BASE%/}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"
TARGET_JSON="${GXRA_RECOVERY_TARGET_JSON:-$ROOT/docs/timewarp-ubuntu24-worker-target.json}"
REGISTER_TARGET="${GXRA_RECOVERY_REGISTER_TARGET:-1}"

_cfg_path() {
  local cfg_path="${GXRA_AGENT_CONFIG:-}"
  if [[ -z "$cfg_path" && -f "$ROOT/.gxra-agent-config.json" ]]; then
    cfg_path="$ROOT/.gxra-agent-config.json"
  fi
  if [[ -z "$cfg_path" && -f "${HOME}/.config/gxra-agent/config.json" ]]; then
    cfg_path="${HOME}/.config/gxra-agent/config.json"
  fi
  echo "$cfg_path"
}

ENTITY_ID="$("$PY_BIN" -c "import json,sys; print(json.load(open(sys.argv[1]))['entity_id'])" "$MANIFEST")"
if [[ -z "$ENTITY_ID" ]]; then
  cfg="$(_cfg_path)"
  if [[ -n "$cfg" && -f "$cfg" ]]; then
    ENTITY_ID="$("$PY_BIN" -c "import json; print(json.load(open('$cfg'))['entity_id'])")"
  fi
fi
if [[ -z "$ENTITY_ID" ]]; then
  echo "Could not resolve entity_id from manifest or agent config." >&2
  exit 1
fi

HDR=(-H "X-Tenant-Id: ${TENANT}" -H "Content-Type: application/json")

if [[ "$REGISTER_TARGET" == "1" ]]; then
  if [[ ! -f "$TARGET_JSON" ]]; then
    echo "Target JSON not found: $TARGET_JSON" >&2
    exit 1
  fi
  echo "Registering recovery target for entity_id=${ENTITY_ID} ..."
  TARGET_PAYLOAD="$("$PY_BIN" - "$TARGET_JSON" "$ENTITY_ID" "$TENANT" <<'PY'
import json, sys
path, entity_id, tenant = sys.argv[1:4]
target = json.load(open(path))
target["entity_id"] = entity_id
target["tenant_id"] = tenant
print(json.dumps(target))
PY
)"
  curl -sf -X POST "${BASE}/v1/recovery/targets" "${HDR[@]}" -d "$TARGET_PAYLOAD" >/dev/null
  echo "  target registered: $(echo "$TARGET_PAYLOAD" | "$PY_BIN" -c 'import json,sys; print(json.load(sys.stdin)["target_id"])')"
fi

echo "Ingesting recovery set from ${MANIFEST} ..."
INGEST_PAYLOAD="$("$PY_BIN" - "$MANIFEST" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
keep = (
    "recovery_set_id", "entity_id", "target_id", "target_class", "status",
    "capture_window", "behavioral_context", "boundary", "artifacts",
    "candidate_lanes", "audit", "lab_run_dir",
)
payload = {k: raw[k] for k in keep if k in raw}
if not payload.get("candidate_lanes"):
    payload["auto_rank_lanes"] = True
else:
    payload["auto_rank_lanes"] = False
if not payload.get("lab_run_dir"):
    import os
    payload["lab_run_dir"] = os.path.dirname(os.path.abspath(sys.argv[1]))
print(json.dumps(payload))
PY
)"
RESP="$(curl -sf -X POST "${BASE}/v1/recovery/sets" "${HDR[@]}" -d "$INGEST_PAYLOAD")"
SET_ID="$(echo "$RESP" | "$PY_BIN" -c 'import json,sys; print(json.load(sys.stdin)["recovery_set_id"])')"
TOP_LANE="$(echo "$RESP" | "$PY_BIN" -c 'import json,sys; d=json.load(sys.stdin); lanes=d.get("candidate_lanes") or []; print(lanes[0]["lane_id"] if lanes else "")')"
echo "  recovery_set_id=${SET_ID} status=$(echo "$RESP" | "$PY_BIN" -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
if [[ -n "$TOP_LANE" ]]; then
  echo "  top_lane=${TOP_LANE}"
  echo "  authorize: curl -s -X POST ${BASE}/v1/recovery/authorize ${HDR[*]} -d '{\"entity_id\":\"${ENTITY_ID}\",\"recovery_set_id\":\"${SET_ID}\",\"lane_id\":\"${TOP_LANE}\"}'"
fi
