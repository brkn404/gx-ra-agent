#!/usr/bin/env bash
# E2E for Windows pilot VM (frozen baseline ent-c8b507e0cad4). Run from any host with API access.
set -euo pipefail
export ENTITY_ID="${ENTITY_ID:-ent-c8b507e0cad4}"
export GXRA_DEMO_HOST="${GXRA_DEMO_HOST:-win-vm-lab01}"
export GXRA_API_BASE="${GXRA_API_BASE:-${GXRA_API_URL:-http://192.168.68.54:8081}}"
export GXRA_TENANT_ID="${GXRA_TENANT_ID:-pilot-1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${SCRIPT_DIR}/gxra_e2e_demo.sh"
