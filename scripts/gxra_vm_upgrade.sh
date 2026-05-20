#!/usr/bin/env bash
# After git pull: reinstall agent + learn/freeze + E2E (Linux or Git Bash on Windows).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

API="${GXRA_API_URL:-http://192.168.68.54:8081}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"
export GXRA_API_URL="$API" GXRA_TENANT_ID="$TENANT"

if [[ -f "${ROOT}/.venv/Scripts/python.exe" ]]; then
  PY="${ROOT}/.venv/Scripts/python.exe"
  PIP="${ROOT}/.venv/Scripts/pip.exe"
  GXRA="${ROOT}/.venv/Scripts/gxra-agent.exe"
  E2E="${ROOT}/scripts/gxra_e2e_windows.sh"
elif [[ -f "${ROOT}/.venv/bin/python" ]]; then
  PY="${ROOT}/.venv/bin/python"
  PIP="${ROOT}/.venv/bin/pip"
  GXRA="${ROOT}/.venv/bin/gxra-agent"
  E2E="${ROOT}/scripts/gxra_e2e_demo.sh"
else
  python3 -m venv .venv
  PY="${ROOT}/.venv/bin/python"
  PIP="${ROOT}/.venv/bin/pip"
  GXRA="${ROOT}/.venv/bin/gxra-agent"
  E2E="${ROOT}/scripts/gxra_e2e_demo.sh"
fi

"${PIP}" install -q -e .
curl -sf "${API}/health" | "${PY}" -m json.tool | head -5

unset ENTITY_ID
"${GXRA}" status
"${GXRA}" learn --start-learning --interval 1 --count 4 --freeze
exec "${E2E}"
