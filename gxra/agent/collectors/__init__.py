"""Platform-specific host signal collectors."""

from gxra.agent.collectors.common import (
    PlatformSignals,
    _collect_signals,
    collect_host_genome,
    genome_digest,
)
from gxra.agent.platform import PlatformInfo, detect_platform

__all__ = [
    "PlatformSignals",
    "collect_host_genome",
    "genome_digest",
    "collect_platform_signals",
    "detect_platform",
]


def collect_platform_signals(plat: PlatformInfo | None = None) -> PlatformSignals:
    from gxra.agent.collectors.common import enrich_with_psutil

    p = plat or detect_platform()
    return enrich_with_psutil(_collect_signals(p))
