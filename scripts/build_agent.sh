#!/usr/bin/env bash
# Build a single-platform gxra-agent binary with PyInstaller.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! python -c "import PyInstaller" 2>/dev/null; then
  echo "Install build deps: pip install -e '.[build]'"
  exit 1
fi

TARGET="$(python -c 'from gxra.agent.platform import detect_platform; print(detect_platform().target)')"
OUT_DIR="${GXRA_AGENT_DIST:-$ROOT/dist}/gxra-agent-${TARGET}"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

pyinstaller --noconfirm --clean \
  --distpath "$OUT_DIR" \
  --workpath "$ROOT/build/pyinstaller" \
  packaging/gxra-agent.spec

echo "Built: $OUT_DIR/gxra-agent"
if [[ -f "$OUT_DIR/gxra-agent.exe" ]]; then
  echo "Built: $OUT_DIR/gxra-agent.exe"
fi
