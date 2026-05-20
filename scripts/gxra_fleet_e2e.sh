#!/usr/bin/env bash
# API-side ALLOW path for pilot fleet entities (no agent on this host required).
set -euo pipefail

API="${GXRA_API_BASE:-${GXRA_API_URL:-http://192.168.68.54:8081}}"
API="${API%/}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"

run_entity() {
  local name="$1" eid="$2"
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  Fleet E2E — ${name} (${eid})"
  echo "══════════════════════════════════════════════════════════════"

  local bl job ts genome
  bl="$(curl -sf "${API}/v1/entities/${eid}/behavioral-baseline" -H "X-Tenant-Id: ${TENANT}")"
  local status
  status="$(python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" <<<"$bl")"
  if [[ "$status" != "frozen" ]]; then
    echo "  ✗ Baseline not frozen (status=${status}) — run learn/freeze on ${name}" >&2
    return 1
  fi
  echo "  ✓ Baseline frozen ($(python3 -c "import json,sys; print(json.load(sys.stdin)['sample_count'])" <<<"$bl") samples)"

  job="fleet-e2e-${name}-$(date +%s)"
  ts="$(date +%s)"
  genome="$(python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['baseline_genome']))" <<<"$bl")"

  curl -sf -X POST "${API}/v1/webhooks/veeam/backup-complete" \
    -H "X-Tenant-Id: ${TENANT}" -H "Content-Type: application/json" \
    -d "{\"entity_id\":\"${eid}\",\"job_id\":\"${job}\",\"finished_at\":${ts},\"repository_path\":\"s3://backups/${job}\",\"genome\":${genome},\"auto_qsba\":false,\"qsba_score\":0.08,\"bsal_level\":\"L2\",\"drift_envelope\":\"acceptable\"}" \
    >/dev/null
  echo "  ✓ Backup associated job=${job}"

  curl -sf -X POST "${API}/v1/webhooks/predatar/scan-complete" \
    -H "X-Tenant-Id: ${TENANT}" -H "Content-Type: application/json" \
    -d "{\"external_snapshot_id\":\"${job}\",\"status\":\"clean\",\"confidence_score\":0.98}" \
    >/dev/null
  echo "  ✓ Predatar clean scan"

  local auth decision
  auth="$(curl -sf -X POST "${API}/v1/recovery/authorize" \
    -H "X-Tenant-Id: ${TENANT}" -H "Content-Type: application/json" \
    -d "{\"entity_id\":\"${eid}\",\"external_snapshot_id\":\"${job}\"}")"
  decision="$(python3 -c "import json,sys; print(json.load(sys.stdin)['decision'])" <<<"$auth")"
  if [[ "$decision" != "ALLOW" ]]; then
    echo "  ✗ Authorize: ${decision}" >&2
    python3 -m json.tool <<<"$auth" >&2
    return 1
  fi
  echo "  ✓ Authorize: ALLOW"
  python3 -c "
import json, sys
a = json.load(sys.stdin)
for r in a.get('reasons', []):
    print(f'    · {r}')
" <<<"$auth"
}

curl -sf "${API}/health" | python3 -m json.tool | head -8
echo "API: ${API}  tenant: ${TENANT}"

fail=0
run_entity "ubuntuvmlab01" "ent-dc373af54c54" || fail=1
run_entity "WIN-VM-LAB01" "ent-2272a0680155" || fail=1

echo ""
if [[ "$fail" -eq 0 ]]; then
  echo "Fleet E2E complete — both entities ALLOW"
else
  echo "Fleet E2E failed — re-run learn/freeze on the failing host" >&2
  exit 1
fi
