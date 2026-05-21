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
    r"(powershell|pwsh|vssadmin|wbadmin|bcdedit|mshta|wscript|cscript|certutil|"
    r"regsvr32|rundll32|wmic)",
    re.I,
)

_LINUX_LOLBIN_BASENAMES = frozenset(
    name.lower().removesuffix(".exe") for name in _LOLBIN_NAMES
)


def merge_category_scores(signals: PlatformSignals, scores: Dict[str, float]) -> None:
    existing: Dict[str, float] = dict(signals.extra.get("category_scores") or {})
    for key, val in scores.items():
        v = max(-1.0, min(1.0, float(val)))
        existing[key] = max(existing.get(key, 0.0), v)
    signals.extra["category_scores"] = existing


def _linux_posture_in_scope(category: str) -> bool:
    from gxra.agent.platform import detect_platform
    from gxra.agent.signals.strategy import is_category_in_scope, max_tier_from_env

    plat = detect_platform()
    return is_category_in_scope(
        category,  # type: ignore[arg-type]
        plat.target,
        max_tier=max_tier_from_env(),
    )


def collect_linux_posture() -> Dict[str, float]:
    scores: Dict[str, float] = {}
    if _linux_posture_in_scope("backup_integrity"):
        scores["backup_integrity"] = _linux_backup_integrity()
    if _linux_posture_in_scope("lolbin_activity"):
        scores["lolbin_activity"] = _linux_lolbin_activity()
    if _linux_posture_in_scope("security_product"):
        scores["security_product"] = _linux_security_product()
    if _linux_posture_in_scope("auth_anomaly"):
        scores["auth_anomaly"] = _linux_auth_anomaly()
    if _linux_posture_in_scope("volume_activity"):
        scores["volume_activity"] = _linux_volume_activity()
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
    hits = 0
    try:
        out = subprocess.run(
            ["ps", "-eo", "comm="],
            capture_output=True,
            text=True,
            timeout=8,
        )
        if out.returncode == 0:
            for line in out.stdout.splitlines():
                comm = line.strip().lower()
                if not comm:
                    continue
                base = comm.split("/")[-1]
                if base in _LINUX_LOLBIN_BASENAMES or _LINUX_LOLBIN_RE.search(comm):
                    hits += 1
        out_args = subprocess.run(
            ["ps", "-eo", "args="],
            capture_output=True,
            text=True,
            timeout=8,
        )
        if out_args.returncode == 0:
            for line in out_args.stdout.splitlines():
                if _LINUX_LOLBIN_RE.search(line):
                    hits += 1
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return 0.0
    if hits == 0:
        return 0.05
    if hits <= 2:
        return 0.35
    return min(1.0, 0.35 + hits * 0.15)


def _linux_auth_anomaly() -> float:
    """Failed SSH / sudo auth in the last hour (lightweight journal or auth.log)."""
    failures = 0
    try:
        out = subprocess.run(
            [
                "journalctl",
                "-u",
                "ssh",
                "--since",
                "1 hour ago",
                "--no-pager",
                "-q",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if out.returncode == 0:
            failures = sum(
                1
                for line in out.stdout.splitlines()
                if "Failed password" in line or "Failed publickey" in line
            )
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        pass
    if failures == 0:
        from pathlib import Path

        auth_log = Path("/var/log/auth.log")
        if auth_log.is_file():
            try:
                tail = auth_log.read_text(errors="replace").splitlines()[-500:]
                failures = sum(
                    1
                    for line in tail
                    if "Failed password" in line or "Failed publickey" in line
                )
            except OSError:
                failures = 0
    if failures == 0:
        return 0.05
    if failures < 5:
        return 0.35
    return min(1.0, 0.4 + failures * 0.08)


def _linux_volume_activity() -> float:
    """Recent file churn under /tmp (lab + ransomware-style volume signals)."""
    try:
        out = subprocess.run(
            [
                "find",
                "/tmp",
                "-maxdepth",
                "3",
                "-type",
                "f",
                "-mmin",
                "-30",
            ],
            capture_output=True,
            text=True,
            timeout=12,
        )
        if out.returncode != 0:
            return 0.05
        count = sum(1 for line in out.stdout.splitlines() if line.strip())
        if count < 10:
            return 0.05
        if count < 50:
            return 0.25
        if count < 200:
            return 0.45
        return min(1.0, 0.5 + count / 500.0)
    except (OSError, subprocess.SubprocessError, FileNotFoundError):
        return 0.05


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

