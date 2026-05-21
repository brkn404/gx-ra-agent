#!/usr/bin/env bash
# Drive *real* gxra-agent collector drift on Linux for pilot testing.
#
# Usage (on protected VM, after bind/register + frozen baseline):
#   export GXRA_API_URL=http://192.168.68.54:8081 GXRA_TENANT_ID=pilot-1
#   ./scripts/linux-synthetic-drift-lab.sh
#
# What moves today (gxra-agent collectors):
#   - runtime_soft: load, CPU%, memory (psutil)
#   - lolbin_activity: comm/args match certutil, wscript, etc.
#   - volume_activity: /tmp file churn (find -mmin -30)
#   - auth_anomaly: failed SSH in journal or auth.log
#   - security_product: clamav/falcon/mdatp/esets/sophos systemd active
#   - backup_integrity: snapper timer or LVM snapshots
#   - runtime_soft: hour/dow (time of snapshot)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

API="${GXRA_API_URL:-http://192.168.68.54:8081}"
TENANT="${GXRA_TENANT_ID:-pilot-1}"
GXRA="${ROOT}/.venv/bin/gxra-agent"
if [[ ! -x "$GXRA" ]]; then
  GXRA="$(command -v gxra-agent || true)"
fi
if [[ -z "$GXRA" || ! -x "$GXRA" ]]; then
  echo "gxra-agent not found. Run deploy-linux-agent.sh or pip install -e ." >&2
  exit 1
fi

export GXRA_API_URL="$API" GXRA_TENANT_ID="$TENANT"

LAB_PIDS=()
cleanup() {
  for pid in "${LAB_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -f /tmp/gxra-lab-certutil /tmp/gxra-lab-fill 2>/dev/null || true
}
trap cleanup EXIT

echo "=== GX-RA Linux synthetic drift lab ==="
echo "API: $API  tenant: $TENANT"
curl -sf "$API/health" >/dev/null && echo "API ok" || { echo "API unreachable"; exit 1; }

echo ""
echo "--- Baseline snapshot (before lab) ---"
"$GXRA" snapshot
BEFORE=$("$GXRA" status)
echo "$BEFORE" | python3 -c "import sys,json; b=json.load(sys.stdin); print('  drift_distance:', b.get('drift_distance')); print('  top slots:', len(b.get('top_slot_deltas') or []))" 2>/dev/null || true

echo ""
echo "--- Applying synthetic host activity (30s) ---"

# 1) LOLBin-style comm (T1490 / recovery-tool pattern) — linux collector scans ps comm=
if command -v stress-ng >/dev/null; then
  stress-ng --cpu 2 --vm 1 --vm-bytes 256M --timeout 25s >/dev/null 2>&1 &
  LAB_PIDS+=($!)
  echo "  [runtime] stress-ng cpu+mem (pid $!)"
else
  ( yes >/dev/null ) & LAB_PIDS+=($!)
  echo "  [runtime] yes cpu load (pid $!) — install stress-ng for cleaner signal"
fi

# Process name visible to ps as certutil (matches _LINUX_LOLBIN_RE)
cp "$(command -v sleep)" /tmp/gxra-lab-certutil 2>/dev/null || cp /bin/sleep /tmp/gxra-lab-certutil
chmod +x /tmp/gxra-lab-certutil
/tmp/gxra-lab-certutil 120 &
LAB_PIDS+=($!)
echo "  [lolbin] /tmp/gxra-lab-certutil sleep 120s (pid $!)"

# Optional: wscript pattern
cp "$(command -v sleep)" /tmp/wscript 2>/dev/null || true
[[ -x /tmp/wscript ]] && /tmp/wscript 120 & LAB_PIDS+=($!) && echo "  [lolbin] /tmp/wscript (pid $!)"

# 2) Volume-ish activity (mostly for future tier-2; may not move genome slots yet)
mkdir -p /tmp/gxra-lab-churn
for i in $(seq 1 200); do
  echo "lab-$i" >"/tmp/gxra-lab-churn/file_$i.dat"
done
echo "  [volume lab] 200 files in /tmp/gxra-lab-churn (may not affect 64D until collectors extended)"

# 3) Security product — only if clamav installed
if systemctl is-active clamav-daemon >/dev/null 2>&1; then
  echo "  [security] clamav-daemon already active (good)"
else
  echo "  [security] tip: sudo apt install -y clamav && sudo systemctl start clamav-daemon"
fi

echo "  waiting 8s for metrics to settle..."
sleep 8

echo ""
echo "--- After-lab snapshot ---"
"$GXRA" snapshot
AFTER=$("$GXRA" status)
echo "$AFTER" | python3 -m json.tool 2>/dev/null || echo "$AFTER"

echo ""
echo "Done. Open console entity → Overview / Genome for top_slot_deltas."
echo "Cleanup runs on exit (stops lab processes)."
