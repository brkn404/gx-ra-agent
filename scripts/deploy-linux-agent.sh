#!/usr/bin/env bash
# Deploy gxra-agent on this Linux host and freeze baseline.
#
# Fresh Ubuntu VM:
#   sudo apt update && sudo apt install -y python3 python3-venv python3-pip git curl
#   git clone https://github.com/brkn404/gx-ra-agent.git ~/gx-ra-agent
#   cd ~/gx-ra-agent
#   export GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1
#   ./scripts/deploy-linux-agent.sh my-linux-host
#   ./scripts/deploy-linux-agent.sh my-host --product-default   # standard baseline + 30m timer
#   ./scripts/deploy-linux-agent.sh my-host --quick-baseline    # pilot lab only (~20s)
set -euo pipefail

API="${GXRA_API_URL:-http://192.168.68.54:8081}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"
PERIODIC_30M=0
QUICK_BASELINE=0
PRODUCT_DEFAULT=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --periodic-30m) PERIODIC_30M=1 ;;
    --quick-baseline) QUICK_BASELINE=1 ;;
    --product-default) PRODUCT_DEFAULT=1; PERIODIC_30M=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
HOST="${ARGS[0]:-$(hostname -s)}"

# Baseline profile: quick (pilot) | standard (product default) | extended
# See GX-RA docs/gxra-agent-baseline-profiles.md
PROFILE="${GXRA_BASELINE_PROFILE:-standard}"
if [[ "$QUICK_BASELINE" -eq 1 ]]; then
  PROFILE=quick
fi
case "$PROFILE" in
  quick)
    INTERVAL="${GXRA_LEARN_INTERVAL:-5}"
    COUNT="${GXRA_LEARN_COUNT:-4}"
    MIN_SAMPLES="${GXRA_LEARN_MIN_SAMPLES:-3}"
    ;;
  extended)
    INTERVAL="${GXRA_LEARN_INTERVAL:-3600}"
    COUNT="${GXRA_LEARN_COUNT:-168}"
    MIN_SAMPLES="${GXRA_LEARN_MIN_SAMPLES:-24}"
    ;;
  standard|*)
    INTERVAL="${GXRA_LEARN_INTERVAL:-300}"
    COUNT="${GXRA_LEARN_COUNT:-48}"
    MIN_SAMPLES="${GXRA_LEARN_MIN_SAMPLES:-12}"
    PROFILE=standard
    ;;
esac

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

_venv_broken() {
  [[ -d .venv ]] && [[ ! -x .venv/bin/pip ]] && return 0
  [[ -d .venv ]] && [[ ! -x .venv/bin/python3 ]] && return 0
  return 1
}

if _venv_broken; then
  echo "Removing broken .venv (common after installing python3-venv later)..."
  rm -rf .venv
fi

if [[ ! -d .venv ]]; then
  if ! python3 -m venv .venv; then
    echo "python3-venv required. Run:" >&2
    echo "  sudo apt install -y python3-venv" >&2
    exit 1
  fi
fi

PIP="${ROOT}/.venv/bin/pip"
GXRA="${ROOT}/.venv/bin/gxra-agent"

if [[ ! -x "$PIP" ]]; then
  echo "Virtualenv failed: $PIP missing. Run: rm -rf .venv && $0 $*" >&2
  exit 1
fi

"${PIP}" install -q --upgrade pip
"${PIP}" install -q -e ".[dev]"

export GXRA_API_URL="$API" GXRA_TENANT_ID="$TENANT"

echo "API: $API"
curl -sf "$API/health" | python3 -m json.tool

echo "Baseline profile: ${PROFILE} (interval=${INTERVAL}s count=${COUNT} min_samples=${MIN_SAMPLES})"
echo "  Docs: GX-RA docs/gxra-agent-baseline-profiles.md · gxra-continuous-watch-plan.md"

"${GXRA}" register --hostname "$HOST"
"${GXRA}" learn --start-learning --interval "$INTERVAL" --count "$COUNT" --freeze --min-samples "$MIN_SAMPLES"
"${GXRA}" status

if [[ "$PERIODIC_30M" -eq 1 ]]; then
  echo ""
  echo "Installing 30-minute snapshot timer..."
  ENTITY_ID="$("${GXRA}" status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('entity_id',''))" 2>/dev/null || true)"
  if [[ -z "$ENTITY_ID" ]]; then
    ENTITY_ID="$(python3 -c "import json; print(json.load(open('${HOME}/.config/gxra-agent/config.json'))['entity_id'])" 2>/dev/null || true)"
  fi
  if [[ -n "$ENTITY_ID" ]]; then
    "${ROOT}/scripts/install-periodic-timer.sh" --entity-id "$ENTITY_ID"
  else
    echo "Skip timer: could not resolve entity_id — run install-periodic-timer.sh manually." >&2
  fi
fi

echo ""
echo "Run E2E demo:"
echo "  cd $ROOT"
echo "  export GXRA_API_URL=$API GXRA_TENANT_ID=$TENANT"
echo "  ./scripts/gxra_e2e_demo.sh"
echo ""
echo "Run tests:"
echo "  ${ROOT}/.venv/bin/pytest tests/test_e2e_pilot.py -v"
