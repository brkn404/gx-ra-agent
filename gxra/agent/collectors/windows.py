"""Windows amd64 / x86 collector."""

from __future__ import annotations

import socket
import subprocess
import sys
from typing import Optional

from gxra.agent.collectors.common import PlatformSignals, apply_virt_to_signals
from gxra.agent.collectors.security_posture import collect_windows_posture, merge_category_scores
from gxra.agent.platform import PlatformInfo
from gxra.agent.virtualization import detect_virt_windows


def _machine_guid_registry() -> Optional[str]:
    if sys.platform != "win32":
        return None
    try:
        import winreg  # type: ignore[import-untyped]

        key = winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE,
            r"SOFTWARE\Microsoft\Cryptography",
        )
        value, _ = winreg.QueryValueEx(key, "MachineGuid")
        winreg.CloseKey(key)
        return str(value).strip()
    except OSError:
        return None


def _machine_guid_wmic() -> Optional[str]:
    try:
        out = subprocess.check_output(
            ["wmic", "csproduct", "get", "uuid"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
        lines = [ln.strip() for ln in out.splitlines() if ln.strip() and ln.strip().lower() != "uuid"]
        return lines[0] if lines else None
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return None


def _machine_id() -> str:
    guid = _machine_guid_registry() or _machine_guid_wmic()
    if guid:
        return guid
    return f"win-fallback-{socket.gethostname()}"


def collect(plat: PlatformInfo) -> PlatformSignals:
    sig = PlatformSignals(
        machine_id=_machine_id(),
        hostname=socket.gethostname(),
        os=plat.os,
        arch=plat.arch,
        target=plat.target,
        load_1m=None,
        extra={"edition": sys.getwindowsversion().platform if sys.platform == "win32" else ""},
    )
    sig = apply_virt_to_signals(sig, detect_virt_windows())
    if sys.platform == "win32":
        merge_category_scores(sig, collect_windows_posture())
    return sig
