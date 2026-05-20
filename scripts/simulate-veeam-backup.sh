#!/usr/bin/env bash
# Simulate a Veeam backup-complete webhook for GX-RA (no Veeam install required).
#
# Usage:
#   export GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1
#   ./scripts/simulate-veeam-backup.sh                    # uses ~/.config/gxra-agent
#   ./scripts/simulate-veeam-backup.sh ent-dc373af54c54   # explicit entity
#   SNAPSHOT=1 ./scripts/simulate-veeam-backup.sh         # gxra-agent snapshot first
set -euo pipefail

BASE="${GXRA_API_URL:-http://192.168.68.54:8081}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"
HDR=(-H "X-Tenant-Id: ${TENANT}" -H "Content-Type: application/json")
CFG="${GXRA_AGENT_CONFIG:-$HOME/.config/gxra-agent/config.json}"
JOB_PREFIX="${GXRA_JOB_PREFIX:-veeam-sim}"

ENTITY="${1:-}"
if [[ -z "$ENTITY" ]] && [[ -f "$CFG" ]]; then
  ENTITY=$(python3 -c "import json; print(json.load(open('$CFG'))['entity_id'])")
fi
ENTITY="${ENTITY:?entity_id or agent config required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GXRA="${ROOT}/.venv/bin/gxra-agent"

if [[ "${SNAPSHOT:-0}" == "1" ]] && [[ -x "$GXRA" ]]; then
  echo "==> Pre-backup: gxra-agent snapshot"
  export GXRA_API_URL="$BASE" GXRA_TENANT_ID="$TENANT"
  "$GXRA" snapshot
fi

TS=$(date +%s)
JOB="${JOB_PREFIX}-${ENTITY: -8}-${TS}"

echo "==> Simulated Veeam backup-complete"
echo "    entity=$ENTITY job=$JOB"

if [[ "${AUTOBIND:-0}" == "1" ]]; then
  echo "    mode=auto-bind (no genome in webhook — API uses agent telemetry / frozen baseline)"
  curl -sf -X POST "${BASE}/v1/webhooks/veeam/backup-complete" "${HDR[@]}" \
    -d "{
      \"entity_id\": \"${ENTITY}\",
      \"job_id\": \"${JOB}\",
      \"finished_at\": ${TS},
      \"repository_path\": \"veeam://repository/sim/${JOB}\",
      \"tags\": [\"veeam-sim\", \"pilot\", \"autobind\"]
    }" | python3 -m json.tool
else
  GENOME_JSON=$(curl -sf "${BASE}/v1/entities/${ENTITY}/behavioral-baseline" \
    -H "X-Tenant-Id: ${TENANT}" \
    | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('baseline_genome') or []))")
  AUTO="${GXRA_SIM_AUTO_QSBA:-true}"
  if [[ "$AUTO" == "true" ]]; then
    curl -sf -X POST "${BASE}/v1/webhooks/veeam/backup-complete" "${HDR[@]}" \
      -d "{
        \"entity_id\": \"${ENTITY}\",
        \"job_id\": \"${JOB}\",
        \"finished_at\": ${TS},
        \"repository_path\": \"veeam://repository/sim/${JOB}\",
        \"genome\": ${GENOME_JSON},
        \"auto_qsba\": true,
        \"tags\": [\"veeam-sim\", \"pilot\"]
      }" | python3 -m json.tool
  else
    curl -sf -X POST "${BASE}/v1/webhooks/veeam/backup-complete" "${HDR[@]}" \
      -d "{
        \"entity_id\": \"${ENTITY}\",
        \"job_id\": \"${JOB}\",
        \"finished_at\": ${TS},
        \"repository_path\": \"veeam://repository/sim/${JOB}\",
        \"genome\": ${GENOME_JSON},
        \"auto_qsba\": false,
        \"qsba_score\": 0.08,
        \"bsal_level\": \"L2\",
        \"drift_envelope\": \"acceptable\",
        \"tags\": [\"veeam-sim\", \"pilot\"]
      }" | python3 -m json.tool
  fi
fi

echo ""
echo "Next (optional):"
echo "  curl -s -X POST ${BASE}/v1/webhooks/predatar/scan-complete -H X-Tenant-Id:${TENANT} -H Content-Type:application/json \\"
echo "    -d '{\"external_snapshot_id\":\"${JOB}\",\"status\":\"clean\",\"confidence_score\":0.98}'"
echo "  curl -s -X POST ${BASE}/v1/recovery/authorize -H X-Tenant-Id:${TENANT} -H Content-Type:application/json \\"
echo "    -d '{\"entity_id\":\"${ENTITY}\",\"external_snapshot_id\":\"${JOB}\"}'"
