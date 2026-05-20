#!/usr/bin/env bash
# E2E on Windows — uses agent config entity_id, or pilot default ent-c8b507e0cad4.
set -euo pipefail
export GXRA_DEMO_HOST="${GXRA_DEMO_HOST:-win-vm-lab01}"
export GXRA_API_BASE="${GXRA_API_BASE:-${GXRA_API_URL:-http://192.168.68.54:8081}}"
export GXRA_TENANT_ID="${GXRA_TENANT_ID:-pilot-1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CFG="${GXRA_AGENT_CONFIG:-$HOME/.config/gxra-agent/config.json}"
if [[ -z "${ENTITY_ID:-}" ]] && [[ -f "$CFG" ]]; then
  ENTITY_ID="$(python3 -c "import json; print(json.load(open('$CFG'))['entity_id'])")"
fi
export ENTITY_ID="${ENTITY_ID:-ent-c8b507e0cad4}"

if [[ -x "${ROOT}/.venv/Scripts/gxra-agent.exe" ]]; then
  export PATH="${ROOT}/.venv/Scripts:${PATH}"
elif [[ -x "${ROOT}/.venv/bin/gxra-agent" ]]; then
  export PATH="${ROOT}/.venv/bin:${PATH}"
fi

echo "Windows E2E uses entity ${ENTITY_ID}"
echo "If Step 0 fails, run: gxra-agent learn --start-learning --interval 1 --count 4 --freeze"
echo ""

exec "${SCRIPT_DIR}/gxra_e2e_demo.sh"
