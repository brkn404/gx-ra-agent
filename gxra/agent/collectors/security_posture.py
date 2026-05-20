"""
Tier-1 host posture signals → category_scores for the 64D genome.

Cross-platform: backup_integrity, lolbin_activity, security_product (lightweight).
"""

from __future__ import annotations

import re
import subprocess
import sys
from typing import Dict

from gxra.agent.collectors.common import PlatformSignals

# Process names associated with recovery inhibition / LOLBins (T1490, T1059)
_LOLBIN_NAMES = frozenset(
    {
        "powershell.exe",
        "powershell_ise.exe",
        "pwsh.exe",
        "cmd.exe",
        "wscript.exe",
        "cscript.exe",
        "mshta.exe",
        "vssadmin.exe",
        "wbadmin.exe",
        "bcdedit.exe",
        "wmic.exe",
        "certutil.exe",
        "regsvr32.exe",
        "rundll32.exe",
    }
)

_LINUX_LOLBIN_RE = re.compile(
    r"(powershell|pwsh|vssadmin|wbadmin|bcdedit|mshta|wscript|cscript|certutil)",
    re.I,
)


def merge_category_scores(signals: PlatformSignals, scores: Dict[str, float]) -> None:
    existing: Dict[str, float] = dict(signals.extra.get("category_scores") or {})
    for key, val in scores.items():
        v = max(-1.0, min(1.0, float(val)))
        existing[key] = max(existing.get(key, 0.0), v)
    signals.extra["category_scores"] = existing


def collect_linux_posture() -> Dict[str, float]:
    scores: Dict[str, float] = {}
    scores["backup_integrity"] = _linux_backup_integrity()
    scores["lolbin_activity"] = _linux_lolbin_activity()
    scores["security_product"] = _linux_security_product()
    return scores


def collect_windows_posture() -> Dict[str, float]:
    scores: Dict[str, float] = {}
    scores["backup_integrity"] = _windows_backup_integrity()
    scores["lolbin_activity"] = _windows_lolbin_activity()
    scores["security_product"] = _windows_security_product()
    return scores


def collect_darwin_posture() -> Dict[str, float]:
    return {
        "backup_integrity": 0.05,
        "lolbin_activity": _darwin_lolbin_activity(),
        "security_product": 0.05,
    }


def _linux_backup_integrity() -> float:
    """Low = healthy snapshots/VSS-like tooling; high = missing or impaired."""
    from pathlib import Path

    if Path("/run/snapper-root/config").exists():
        return 0.05
    try:
        out = subprocess.run(
            ["systemctl", "is-active", "snapper-timeline.timer"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.stdout.strip() == "active":
            return 0.05
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        pass
    try:
        out = subprocess.run(
            ["lvdisplay", "--snapshot"],
            capture_output=True,
            text=True,
            timeout=8,
        )
        if out.returncode == 0 and "snapshot" in out.stdout.lower():
            return 0.08
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        pass
    return 0.25


def _linux_lolbin_activity() -> float:
    try:
        out = subprocess.run(
            ["ps", "-eo", "comm="],
            capture_output=True,
            text=True,
            timeout=8,
        )
        if out.returncode != 0:
            return 0.0
        hits = sum(
            1
            for line in out.stdout.splitlines()
            if _LINUX_LOLBIN_RE.search(line.strip())
        )
        if hits == 0:
            return 0.05
        if hits <= 2:
            return 0.35
        return min(1.0, 0.35 + hits * 0.15)
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return 0.0


def _linux_security_product() -> float:
    for svc in ("clamav-daemon", "falcon-sensor", "mdatp", "esets", "sophos"):
        try:
            out = subprocess.run(
                ["systemctl", "is-active", svc],
                capture_output=True,
                text=True,
                timeout=4,
            )
            if out.stdout.strip() == "active":
                return 0.05
        except (OSError, subprocess.SubprocessError, FileNotFoundError):
            continue
    return 0.4


def _windows_backup_integrity() -> float:
    try:
        out = subprocess.run(
            ["sc", "query", "VSS"],
            capture_output=True,
            text=True,
            timeout=8,
        )
        text = (out.stdout or "") + (out.stderr or "")
        if "RUNNING" in text:
            return 0.05
        if "STOPPED" in text:
            return 0.75
        return 0.35
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return 0.3


def _windows_lolbin_activity() -> float:
    if sys.platform != "win32":
        return 0.0
    hits = 0
    for name in _LOLBIN_NAMES:
        try:
            out = subprocess.run(
                ["tasklist", "/FI", f"IMAGENAME eq {name}", "/NH"],
                capture_output=True,
                text=True,
                timeout=8,
            )
            lines = [
                ln
                for ln in (out.stdout or "").splitlines()
                if name.lower() in ln.lower() and "no tasks" not in ln.lower()
            ]
            hits += len(lines)
        except (OSError, subprocess.SubprocessError, FileNotFoundError):
            continue
    if hits == 0:
        return 0.05
    if hits <= 2:
        return 0.4
    return min(1.0, 0.45 + hits * 0.1)


def _windows_security_product() -> float:
    for svc in ("WinDefend", "Sense", "McAfeeFramework", "epsecurity", "Sophos"):
        try:
            out = subprocess.run(
                ["sc", "query", svc],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if "RUNNING" in (out.stdout or ""):
                return 0.05
        except (OSError, subprocess.SubprocessError, FileNotFoundError):
            continue
    return 0.45


def _darwin_lolbin_activity() -> float:
    try:
        out = subprocess.run(
            ["ps", "-eo", "comm="],
            capture_output=True,
            text=True,
            timeout=8,
        )
        hits = sum(
            1
            for line in out.stdout.splitlines()
            if _LINUX_LOLBIN_RE.search(line.strip())
        )
        return 0.05 if hits == 0 else min(1.0, 0.3 + hits * 0.2)
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return 0.0

