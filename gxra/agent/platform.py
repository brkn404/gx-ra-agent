"""Host OS / CPU detection for multi-platform agent builds."""

from __future__ import annotations

import os
import platform
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Optional

GxraOs = Literal["linux", "windows", "darwin"]
GxraArch = Literal["amd64", "arm64", "x86"]
GxraTarget = Literal[
    "linux-amd64",
    "linux-arm64",
    "windows-amd64",
    "windows-x86",
    "darwin-amd64",
    "darwin-arm64",
]


@dataclass(frozen=True)
class PlatformInfo:
    os: GxraOs
    arch: GxraArch
    target: GxraTarget
    python_version: str
    hostname: str
    machine: str
    processor: str

    @property
    def label(self) -> str:
        return self.target


def _normalize_os(system: str) -> Optional[GxraOs]:
    s = system.lower()
    if s == "linux":
        return "linux"
    if s == "windows":
        return "windows"
    if s in ("darwin", "macos", "mac os x"):
        return "darwin"
    return None


def _normalize_arch(machine: str) -> GxraArch:
    m = machine.lower().replace("-", "_")
    if m in ("aarch64", "arm64", "armv8", "armv8l"):
        return "arm64"
    if m in ("x86_64", "amd64", "x64"):
        return "amd64"
    if m in ("i386", "i686", "x86", "i486"):
        return "x86"
    if m.startswith("arm"):
        return "arm64"
    return "amd64"


def detect_platform(
    *,
    system: Optional[str] = None,
    machine: Optional[str] = None,
) -> PlatformInfo:
    sys_name = system or platform.system()
    os_name = _normalize_os(sys_name)
    if os_name is None:
        raise RuntimeError(f"Unsupported host OS: {sys_name!r}")

    arch = _normalize_arch(machine or platform.machine())
    if os_name == "windows" and arch == "x86":
        target: GxraTarget = "windows-x86"
    elif os_name == "windows":
        target = "windows-amd64"
    elif os_name == "darwin" and arch == "arm64":
        target = "darwin-arm64"
    elif os_name == "darwin":
        target = "darwin-amd64"
    elif os_name == "linux" and arch == "arm64":
        target = "linux-arm64"
    else:
        target = "linux-amd64"

    return PlatformInfo(
        os=os_name,
        arch=arch,
        target=target,
        python_version=sys.version.split()[0],
        hostname=platform.node(),
        machine=machine or platform.machine(),
        processor=platform.processor() or "",
    )


def default_config_dir() -> Path:
    override = os.environ.get("GXRA_AGENT_CONFIG_DIR")
    if override:
        return Path(override)

    plat = detect_platform()
    home = Path.home()
    if plat.os == "windows":
        base = os.environ.get("APPDATA", str(home / "AppData" / "Roaming"))
        return Path(base) / "gxra-agent"
    if plat.os == "darwin":
        return home / "Library" / "Application Support" / "gxra-agent"
    return home / ".config" / "gxra-agent"


def default_config_path() -> Path:
    return default_config_dir() / "config.json"
