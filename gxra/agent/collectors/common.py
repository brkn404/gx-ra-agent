"""Shared signal → genome mapping (all platforms)."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import List, Optional

from gxra.agent.platform import PlatformInfo
from gxra.agent.virtualization import VirtContext


@dataclass
class PlatformSignals:
    machine_id: str
    hostname: str
    os: str
    arch: str
    target: str
    load_1m: Optional[float] = None
    cpu_percent: Optional[float] = None
    mem_used_ratio: Optional[float] = None
    virt_role: str = "physical"
    virt_platform: str = "bare_metal"
    virt_instance_id: Optional[str] = None
    extra: dict = field(default_factory=dict)


def apply_virt_to_signals(signals: PlatformSignals, virt: VirtContext) -> PlatformSignals:
    signals.virt_role = virt.role
    signals.virt_platform = virt.platform
    signals.virt_instance_id = virt.instance_id
    signals.extra = {**signals.extra, **virt.to_source_refs()}
    return signals


def _optional_psutil_metrics() -> tuple[Optional[float], Optional[float]]:
    try:
        import psutil  # type: ignore[import-untyped]
    except ImportError:
        return None, None
    try:
        cpu = float(psutil.cpu_percent(interval=0.1))
        mem = psutil.virtual_memory()
        ratio = float(mem.used) / float(mem.total) if mem.total else None
        return cpu, ratio
    except Exception:
        return None, None


def enrich_with_psutil(signals: PlatformSignals) -> PlatformSignals:
    cpu, mem = _optional_psutil_metrics()
    if cpu is not None:
        signals.cpu_percent = cpu
    if mem is not None:
        signals.mem_used_ratio = mem
    return signals


def signals_to_genome(signals: PlatformSignals, dimensions: int = 64) -> List[float]:
    """
    Semantic Recovery Assurance genome (default 64D).

    See docs/gxra-genome-dimensions.md. Widths other than 64 pad/truncate with neutral 0.0.
    """
    from gxra.agent.genome_slots import AGENT_RA_DIMENSIONS, encode_agent_ra

    if dimensions == AGENT_RA_DIMENSIONS:
        return encode_agent_ra(signals)

    full = encode_agent_ra(signals)
    if dimensions < AGENT_RA_DIMENSIONS:
        return full[:dimensions]
    # Pad with neutral 0.0 (never hash-fill)
    return full + [0.0] * (dimensions - AGENT_RA_DIMENSIONS)


def _collect_signals(plat: PlatformInfo) -> PlatformSignals:
    if plat.os == "linux":
        from gxra.agent.collectors import linux as mod

        return mod.collect(plat)
    if plat.os == "windows":
        from gxra.agent.collectors import windows as mod

        return mod.collect(plat)
    if plat.os == "darwin":
        from gxra.agent.collectors import darwin as mod

        return mod.collect(plat)
    raise RuntimeError(f"No collector for {plat.os}")


def collect_host_genome(dimensions: int = 64, plat: PlatformInfo | None = None) -> List[float]:
    from gxra.agent.platform import detect_platform

    p = plat or detect_platform()
    signals = enrich_with_psutil(_collect_signals(p))
    return signals_to_genome(signals, dimensions)


def genome_digest(genome: List[float]) -> str:
    payload = ",".join(f"{v:.8f}" for v in genome)
    return hashlib.sha256(payload.encode()).hexdigest()
