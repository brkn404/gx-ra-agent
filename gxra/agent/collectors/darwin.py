"""macOS Intel (amd64) and Apple Silicon (arm64) collector."""

from __future__ import annotations

import re
import socket
import subprocess
from typing import Optional

from gxra.agent.collectors.common import PlatformSignals, apply_virt_to_signals
from gxra.agent.collectors.security_posture import collect_darwin_posture, merge_category_scores
from gxra.agent.platform import PlatformInfo
from gxra.agent.virtualization import detect_virt_darwin


def _ioreg_uuid() -> Optional[str]:
    try:
        out = subprocess.check_output(
            ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
        m = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', out)
        return m.group(1).strip() if m else None
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return None


def _machine_id() -> str:
    uid = _ioreg_uuid()
    if uid:
        return uid
    return f"darwin-fallback-{socket.gethostname()}"


def collect(plat: PlatformInfo) -> PlatformSignals:
    sig = PlatformSignals(
        machine_id=_machine_id(),
        hostname=socket.gethostname(),
        os=plat.os,
        arch=plat.arch,
        target=plat.target,
        load_1m=None,
    )
    sig = apply_virt_to_signals(sig, detect_virt_darwin())
    merge_category_scores(sig, collect_darwin_posture())
    return sig
