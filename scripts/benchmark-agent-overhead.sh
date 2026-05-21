#!/usr/bin/env bash
# Measure gxra-agent CPU time, wall time, and peak RSS on this host.
#
# Usage:
#   ./scripts/benchmark-agent-overhead.sh
#   GXRA_AGENT_TIER_MAX=1 ./scripts/benchmark-agent-overhead.sh
#   SKIP_API=1 ./scripts/benchmark-agent-overhead.sh   # collect only, no snapshot POST
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PY="${ROOT}/.venv/bin/python"
GXRA="${ROOT}/.venv/bin/gxra-agent"

if [[ ! -x "$PY" ]]; then
  echo "Run ./scripts/deploy-linux-agent.sh first (creates .venv)." >&2
  exit 1
fi

TIER="${GXRA_AGENT_TIER_MAX:-2}"
SKIP_API="${SKIP_API:-0}"
REPEATS="${BENCH_REPEATS:-3}"

echo "=== GX-RA agent overhead benchmark ==="
echo "host: $(hostname -s)  tier_max=${TIER}  repeats=${REPEATS}"
"$GXRA" info 2>/dev/null | "$PY" -c "import sys,json; d=json.load(sys.stdin); print('  target:', d.get('target'), 'categories:', len(d.get('signal_categories_in_scope',[])))" 2>/dev/null || true
echo ""

# Portable timing (Kali/minimal images often lack GNU time in /usr/bin/time).
_time_one() {
  local label="$1"
  shift
  "$PY" -c '
import resource
import subprocess
import sys
import time

label, args = sys.argv[1], sys.argv[2:]
t0 = time.perf_counter()
proc = subprocess.run(args)
elapsed = time.perf_counter() - t0
child_usage = getattr(resource, "RUSAGE_CHILD", None) or getattr(
    resource, "RUSAGE_CHILDREN", resource.RUSAGE_SELF
)
ru = resource.getrusage(child_usage)
# Linux: ru_maxrss in KB; macOS would need /1024 — Pi/Kali are Linux.
print(
    f"{label} elapsed={elapsed:.2f}s  exit={proc.returncode}  "
    f"maxrss_kb={ru.ru_maxrss}"
)
sys.exit(proc.returncode)
' "$label" "$@"
}

echo "--- Tier ${TIER}: collect_host_genome (×${REPEATS}) ---"
export GXRA_AGENT_TIER_MAX="$TIER"
for i in $(seq 1 "$REPEATS"); do
  _time_one "  run ${i}/${REPEATS}" "$PY" -c "from gxra.agent.collectors.common import collect_host_genome; collect_host_genome(64)"
done

if [[ "$SKIP_API" != "1" ]] && [[ -f "${HOME}/.config/gxra-agent/config.json" ]]; then
  echo ""
  echo "--- snapshot (API POST, entity from config) ---"
  export GXRA_AGENT_TIER_MAX="$TIER"
  _time_one "  snapshot" "$GXRA" snapshot || echo "  (snapshot failed — check GXRA_API_URL and bind)"
else
  echo ""
  echo "--- snapshot skipped (SKIP_API=1 or no ~/.config/gxra-agent/config.json) ---"
fi

echo ""
echo "Notes:"
echo "  - Agent is NOT a daemon; these numbers are per-invocation burst cost."
echo "  - GXRA_AGENT_TIER_MAX=1 skips tier-2 collectors (e.g. volume_activity / heavy find)."
echo "  - Production pilot: prefer Veeam pre-freeze snapshot only; optional timer for drift (see docs/gxra-agent-deployment-modes.md)."
