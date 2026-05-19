#!/usr/bin/env bash
# GX-RA end-to-end demo: agent baseline → backup → scan → ALLOW → verify
# Run on Linux host with gxra-agent deployed, or set ENTITY_ID manually.
set -euo pipefail

BASE="${GXRA_API_BASE:-${GXRA_API_URL:-http://192.168.68.54:8081}}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"
HDR=(-H "X-Tenant-Id: ${TENANT}" -H "Content-Type: application/json")
CFG="${GXRA_AGENT_CONFIG:-$HOME/.config/gxra-agent/config.json}"
HOST_LABEL="${GXRA_DEMO_HOST:-linux-lab}"

if [[ -z "${ENTITY_ID:-}" ]] && [[ -f "$CFG" ]]; then
  ENTITY_ID=$(python3 -c "import json; print(json.load(open('$CFG'))['entity_id'])")
fi
ENTITY_ID="${ENTITY_ID:?Set ENTITY_ID or deploy agent (gxra-agent register)}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  GX-RA E2E demo — trusted Linux path                          ║"
echo "║  API: ${BASE}  tenant: ${TENANT}  entity: ${ENTITY_ID}"
echo "╚══════════════════════════════════════════════════════════════╝"

curl -sf "${BASE}/health" >/dev/null || { echo "API down at ${BASE}"; exit 1; }

echo ""
echo "▶ Step 0 — Behavioral baseline (from agent)"
curl -sf "${BASE}/v1/entities/${ENTITY_ID}/behavioral-baseline?compare_latest=true" \
  -H "X-Tenant-Id: ${TENANT}" | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert r['status'] == 'frozen', f\"Expected frozen baseline, got: {r.get('status')}\"
print(f\"  ✓ Baseline frozen ({r['sample_count']} samples) drift={r.get('drift_distance')}\")
"

GENOME_JSON=$(curl -sf "${BASE}/v1/entities/${ENTITY_ID}/behavioral-baseline" \
  -H "X-Tenant-Id: ${TENANT}" \
  | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['baseline_genome']))")

TS=$(date +%s)
JOB="${HOST_LABEL}-backup-${TS}"

echo ""
echo "▶ Step 1 — Veeam backup-complete (capture-time genome from baseline)"
BACKUP=$(curl -sf -X POST "${BASE}/v1/webhooks/veeam/backup-complete" "${HDR[@]}" \
  -d "{
    \"entity_id\": \"${ENTITY_ID}\",
    \"job_id\": \"${JOB}\",
    \"finished_at\": ${TS},
    \"repository_path\": \"s3://backups/${JOB}\",
    \"genome\": ${GENOME_JSON},
    \"auto_qsba\": false,
    \"qsba_score\": 0.08,
    \"bsal_level\": \"L2\",
    \"drift_envelope\": \"acceptable\"
  }")
echo "$BACKUP" | python3 -c "
import sys,json
r=json.load(sys.stdin)
a=r['association']
print(f\"  ✓ Associated {a['association_id']} job={a['external_snapshot_id']}\")
print(f\"    chain block={a.get('chain_block_index')} pos_b={a.get('pos_b_id')}\")
"

echo ""
echo "▶ Step 2 — Predatar scan clean"
curl -sf -X POST "${BASE}/v1/webhooks/predatar/scan-complete" "${HDR[@]}" \
  -d "{\"external_snapshot_id\":\"${JOB}\",\"status\":\"clean\",\"confidence_score\":0.98}" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(f\"  ✓ Scan {r['scan']['scan_id']} effective_qsba={r.get('effective_qsba_score')}\")"

echo ""
echo "▶ Step 3 — Recovery authorize (expect ALLOW)"
AUTH=$(curl -sf -X POST "${BASE}/v1/recovery/authorize" "${HDR[@]}" \
  -d "{\"entity_id\":\"${ENTITY_ID}\",\"external_snapshot_id\":\"${JOB}\"}")
echo "$AUTH" | python3 -c "
import sys,json
r=json.load(sys.stdin)
assert r['decision']=='ALLOW', r
print(f\"  ✓ Authorize: {r['decision']} effective_qsba={r.get('effective_qsba_score')}\")
for x in r.get('reasons',[]):
    print(f\"    · {x}\")
"

echo ""
echo "▶ Step 4 — Verify assurance"
curl -sf "${BASE}/v1/verify/assurance?external_snapshot_id=${JOB}" \
  -H "X-Tenant-Id: ${TENANT}" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(f\"  ✓ Verify ok={r['ok']}\")"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  E2E complete — job=${JOB}"
echo "  Windows entity (compare): ent-c8b507e0cad4 (WIN-VM-LAB01)"
echo "  Linux entity (this run):  ${ENTITY_ID}"
echo "══════════════════════════════════════════════════════════════"
