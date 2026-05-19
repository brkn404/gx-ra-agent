#!/usr/bin/env bash
# Deploy gxra-agent on this Linux host and freeze baseline.
set -euo pipefail

API="${GXRA_API_URL:-http://192.168.68.54:8081}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"
HOST="${1:-$(hostname -s)}"
INTERVAL="${GXRA_LEARN_INTERVAL:-5}"
COUNT="${GXRA_LEARN_COUNT:-4}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -e ".[dev]"

export GXRA_API_URL="$API" GXRA_TENANT_ID="$TENANT"

echo "API: $API"
curl -sf "$API/health" | python3 -m json.tool

gxra-agent register --hostname "$HOST"
gxra-agent learn --start-learning --interval "$INTERVAL" --count "$COUNT" --freeze --min-samples 3
gxra-agent status

echo ""
echo "Run E2E demo:"
echo "  GXRA_API_URL=$API GXRA_TENANT_ID=$TENANT ./scripts/gxra_e2e_demo.sh"
