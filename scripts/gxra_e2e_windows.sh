#!/usr/bin/env bash
# E2E on Windows — uses agent config entity_id, or pilot default ent-c8b507e0cad4.
set -euo pipefail
export GXRA_DEMO_HOST="${GXRA_DEMO_HOST:-win-vm-lab01}"
export GXRA_API_BASE="${GXRA_API_BASE:-${GXRA_API_URL:-http://192.168.68.54:8081}}"
export GXRA_TENANT_ID="${GXRA_TENANT_ID:-pilot-1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Windows agent config lives in %APPDATA%\gxra-agent\ (not ~/.config).
_resolve_agent_config() {
  if [[ -n "${GXRA_AGENT_CONFIG:-}" && -f "${GXRA_AGENT_CONFIG}" ]]; then
    echo "${GXRA_AGENT_CONFIG}"
  elif [[ -n "${APPDATA:-}" && -f "${APPDATA}/gxra-agent/config.json" ]]; then
    echo "${APPDATA}/gxra-agent/config.json"
  elif [[ -f "${HOME}/.config/gxra-agent/config.json" ]]; then
    echo "${HOME}/.config/gxra-agent/config.json"
  fi
}
CFG="$(_resolve_agent_config || true)"
export GXRA_AGENT_CONFIG="${CFG:-${GXRA_AGENT_CONFIG:-}}"

if [[ -z "${ENTITY_ID:-}" && -n "${CFG}" ]]; then
  ENTITY_ID="$(python3 -c "import json; print(json.load(open('${CFG}'))['entity_id'])")"
fi
export ENTITY_ID="${ENTITY_ID:-ent-c8b507e0cad4}"

if [[ -x "${ROOT}/.venv/Scripts/gxra-agent.exe" ]]; then
  export PATH="${ROOT}/.venv/Scripts:${PATH}"
elif [[ -x "${ROOT}/.venv/bin/gxra-agent" ]]; then
  export PATH="${ROOT}/.venv/bin:${PATH}"
fi

echo "Windows E2E uses entity ${ENTITY_ID}"
[[ -n "${CFG}" ]] && echo "Config: ${CFG}"
echo "If Step 0 fails: unset ENTITY_ID, then gxra-agent learn --start-learning --interval 1 --count 4 --freeze"
echo ""

exec "${SCRIPT_DIR}/gxra_e2e_demo.sh"
