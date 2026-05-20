"""Linux amd64 / arm64 collector."""

from __future__ import annotations

import os
import socket
from pathlib import Path

from gxra.agent.collectors.common import PlatformSignals, apply_virt_to_signals
from gxra.agent.collectors.security_posture import collect_linux_posture, merge_category_scores
from gxra.agent.platform import PlatformInfo
from gxra.agent.virtualization import detect_virt_linux


def _machine_id() -> str:
    for path in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        p = Path(path)
        if p.is_file():
            return p.read_text().strip()
    return f"linux-fallback-{socket.gethostname()}"


def _load_1m() -> float | None:
    try:
        load1, _, _ = os.getloadavg()
        return float(load1)
    except (AttributeError, OSError):
        return None


def collect(plat: PlatformInfo) -> PlatformSignals:
    sig = PlatformSignals(
        machine_id=_machine_id(),
        hostname=socket.gethostname(),
        os=plat.os,
        arch=plat.arch,
        target=plat.target,
        load_1m=_load_1m(),
    )
    sig = apply_virt_to_signals(sig, detect_virt_linux())
    merge_category_scores(sig, collect_linux_posture())
    return sig
