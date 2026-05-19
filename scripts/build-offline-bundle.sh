#!/usr/bin/env bash
# Build a folder you can copy to Windows (VMware shared folder / USB) for offline pip install.
set -euo pipefail

OUT="${1:-/tmp/gxra-agent-windows-bundle}"
mkdir -p "$OUT"

python3 -m pip install --upgrade pip wheel
python3 -m pip download "gx-ra-agent @ git+https://github.com/brkn404/gx-ra-agent.git" -d "$OUT"

cat > "$OUT/INSTALL.txt" <<'EOF'
Windows offline install (PowerShell on the VM):

  py -3.12 -m venv C:\gxra-agent-venv
  C:\gxra-agent-venv\Scripts\pip.exe install --no-index --find-links C:\path\to\this\folder gx-ra-agent

  $env:GXRA_API_URL = "http://192.168.68.54:8081"
  $env:GXRA_TENANT_ID = "pilot-1"
  C:\gxra-agent-venv\Scripts\gxra-agent.exe register --hostname win-vm3
  C:\gxra-agent-venv\Scripts\gxra-agent.exe learn --start-learning --interval 60 --count 6 --freeze
EOF

echo "Bundle ready: $OUT"
echo "Copy this folder to Windows (VMware: VM Settings → Options → Shared Folders)"
ls -la "$OUT" | head -20
