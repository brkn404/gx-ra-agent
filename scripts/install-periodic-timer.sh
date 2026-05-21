#!/usr/bin/env bash
# Install or remove a systemd timer: gxra-agent snapshot every 30 minutes.
#
# Prereq: deploy-linux-agent.sh or bind + frozen baseline; config at ~/.config/gxra-agent/config.json
#
# Usage:
#   ./scripts/install-periodic-timer.sh --entity-id ent-dc373af54c54
#   GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1 ./scripts/install-periodic-timer.sh
#   ./scripts/install-periodic-timer.sh --remove
#
set -euo pipefail

case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "install-periodic-timer.sh is for Linux (systemd) only." >&2
    echo "On Windows, open PowerShell and run:" >&2
    echo "  .\\scripts\\install-periodic-task.ps1" >&2
    exit 1
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITY_ID="${GXRA_ENTITY_ID:-}"
REMOVE=0
INTERVAL_MIN="${GXRA_SNAPSHOT_INTERVAL_MIN:-30}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entity-id) ENTITY_ID="$2"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    --interval-min) INTERVAL_MIN="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

API="${GXRA_API_URL:-http://192.168.68.54:8081}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"
GXRA="${ROOT}/.venv/bin/gxra-agent"
USER_NAME="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
UNIT=gxra-agent-snapshot

if [[ ! -x "$GXRA" ]]; then
  echo "gxra-agent not found at $GXRA — run deploy-linux-agent.sh first." >&2
  exit 1
fi

if [[ "$REMOVE" -eq 1 ]]; then
  sudo systemctl disable --now "${UNIT}.timer" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/${UNIT}.service" "/etc/systemd/system/${UNIT}.timer"
  sudo systemctl daemon-reload
  echo "Removed ${UNIT}.timer"
  exit 0
fi

if [[ -z "$ENTITY_ID" ]]; then
  CFG="${HOME_DIR}/.config/gxra-agent/config.json"
  if [[ -f "$CFG" ]]; then
    ENTITY_ID="$(python3 -c "import json; print(json.load(open('$CFG'))['entity_id'])" 2>/dev/null || true)"
  fi
fi
if [[ -z "$ENTITY_ID" ]]; then
  echo "Pass --entity-id ent-… or bind agent first." >&2
  exit 1
fi

SERVICE=$(cat <<EOF
[Unit]
Description=GX-RA agent snapshot (oneshot)
After=network-online.target

[Service]
Type=oneshot
User=${USER_NAME}
Environment=GXRA_API_URL=${API}
Environment=GXRA_TENANT_ID=${TENANT}
Environment=GXRA_AGENT_TIER_MAX=1
ExecStart=${GXRA} snapshot

[Install]
WantedBy=multi-user.target
EOF
)

TIMER=$(cat <<EOF
[Unit]
Description=GX-RA agent snapshot every ${INTERVAL_MIN} minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=${INTERVAL_MIN}min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
)

echo "$SERVICE" | sudo tee "/etc/systemd/system/${UNIT}.service" >/dev/null
echo "$TIMER" | sudo tee "/etc/systemd/system/${UNIT}.timer" >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now "${UNIT}.timer"
sudo systemctl status "${UNIT}.timer" --no-pager || true
echo ""
echo "OK: ${UNIT}.timer every ${INTERVAL_MIN} min → snapshot (entity ${ENTITY_ID} in ~/.config/gxra-agent/config.json)"
echo "Check: systemctl list-timers ${UNIT}.timer"
