#!/usr/bin/env bash
# Deploy gxra-agent on this Linux host and freeze baseline.
#
# Fresh Ubuntu VM:
#   sudo apt update && sudo apt install -y python3 python3-venv python3-pip git curl
#   git clone https://github.com/brkn404/gx-ra-agent.git ~/gx-ra-agent
#   cd ~/gx-ra-agent
#   export GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1
#   ./scripts/deploy-linux-agent.sh my-linux-host
set -euo pipefail

API="${GXRA_API_URL:-http://192.168.68.54:8081}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"
HOST="${1:-$(hostname -s)}"
INTERVAL="${GXRA_LEARN_INTERVAL:-5}"
COUNT="${GXRA_LEARN_COUNT:-4}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f pyproject.toml ]]; then
  echo "Run this from the gx-ra-agent repo root (missing pyproject.toml)." >&2
  echo "  git clone https://github.com/brkn404/gx-ra-agent.git ~/gx-ra-agent && cd ~/gx-ra-agent" >&2
  exit 1
fi

if ! command -v python3 >/dev/null; then
  echo "Install Python 3: sudo apt install -y python3 python3-venv python3-pip" >&2
  exit 1
fi

if [[ ! -d .venv ]]; then
  if ! python3 -m venv .venv 2>/dev/null; then
    echo "python3-venv required. Run:" >&2
    echo "  sudo apt install -y python3-venv" >&2
    exit 1
  fi
fi

PIP="${ROOT}/.venv/bin/pip"
GXRA="${ROOT}/.venv/bin/gxra-agent"

"${PIP}" install -q --upgrade pip
"${PIP}" install -q -e ".[dev]"

export GXRA_API_URL="$API" GXRA_TENANT_ID="$TENANT"

echo "API: $API"
curl -sf "$API/health" | python3 -m json.tool

"${GXRA}" register --hostname "$HOST"
"${GXRA}" learn --start-learning --interval "$INTERVAL" --count "$COUNT" --freeze --min-samples 3
"${GXRA}" status

echo ""
echo "Run E2E demo:"
echo "  cd $ROOT"
echo "  export GXRA_API_URL=$API GXRA_TENANT_ID=$TENANT"
echo "  ./scripts/gxra_e2e_demo.sh"
echo ""
echo "Run tests:"
echo "  ${ROOT}/.venv/bin/pytest tests/test_e2e_pilot.py -v"
