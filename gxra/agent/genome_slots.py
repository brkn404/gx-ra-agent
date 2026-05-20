"""
Semantic 64D Recovery Assurance genome (GX-RA agent profile).

Slot map: docs/gxra-genome-dimensions.md
"""

from __future__ import annotations

import hashlib
import math
import time
from dataclasses import dataclass
from typing import Dict, List, Optional

from gxra.agent.collectors.common import PlatformSignals

AGENT_RA_DIMENSIONS = 64

# Slot index constants (blocks)
IDENTITY_END = 8
AUTH_END = 16
CORE_OS_END = 24
FILESYSTEM_END = 32
PROCESS_END = 40
NETWORK_END = 48
RUNTIME_END = 64


@dataclass(frozen=True)
class SlotSpec:
    index: int
    name: str
    category: Optional[str]


def slot_specs() -> List[SlotSpec]:
    """Canonical 64-slot map (see docs/gxra-genome-dimensions.md)."""
    names = [
        # A identity 0-7
        "machine_id_band_a",
        "machine_id_band_b",
        "hostname_stability",
        "os_family",
        "cpu_arch",
        "virt_role",
        "virt_platform",
        "deploy_target",
        # B auth 8-15
        "interactive_user_count",
        "remote_session_ratio",
        "failed_auth_rate",
        "privilege_escalation",
        "login_hour_deviation",
        "new_credentials",
        "service_account_activity",
        "cross_system_login",
        # C core os 16-23
        "system_binary_delta",
        "driver_module_delta",
        "boot_config_change",
        "autostart_delta",
        "service_count_delta",
        "scheduled_task_delta",
        "os_component_drift",
        "config_integrity",
        # D filesystem 24-31
        "system_volume_write_rate",
        "user_data_write_rate",
        "extension_churn",
        "rename_delete_burst",
        "shadow_copy_health",
        "backup_target_touch",
        "temp_path_anomaly",
        "path_entropy",
        # E process 32-39
        "unsigned_process_ratio",
        "parent_child_anomaly",
        "powershell_activity",
        "cmd_script_activity",
        "recovery_tool_invocation",
        "process_spawn_rate",
        "injection_proxy",
        "lolbin_aggregate",
        # F network 40-47
        "egress_diversity",
        "new_destination_rate",
        "dns_anomaly",
        "listening_port_delta",
        "encrypted_egress_ratio",
        "lateral_movement_proxy",
        "beacon_regularity",
        "backup_path_exfil",
        # G runtime + security 48-63
        "load_1m",
        "cpu_utilization",
        "memory_pressure",
        "av_edr_present",
        "av_edr_healthy",
        "definition_freshness",
        "security_service_delta",
        "tamper_proxy",
        "backup_job_health",
        "vss_writer_health",
        "repo_integrity",
        "recovery_point_freshness",
        "hour_sin",
        "hour_cos",
        "dow_sin",
        "dow_cos",
    ]
    categories = (
        ["identity"] * 3
        + ["identity", "identity", "virt_placement", "virt_placement", "virt_placement"]
        + ["auth_anomaly"] * 8
        + ["persistence_delta"] * 8
        + ["volume_activity"] * 4
        + ["backup_integrity", "backup_integrity"]
        + ["volume_activity"] * 2
        + ["process_posture"] * 2
        + ["lolbin_activity"] * 2
        + ["lolbin_activity", "process_posture", "process_posture", "lolbin_activity"]
        + ["network_posture"] * 8
        + ["runtime_soft"] * 3
        + ["security_product"] * 5
        + ["backup_integrity"] * 4
        + ["runtime_soft"] * 4
    )
    assert len(names) == AGENT_RA_DIMENSIONS
    assert len(categories) == AGENT_RA_DIMENSIONS
    return [
        SlotSpec(index=i, name=names[i], category=categories[i])
        for i in range(AGENT_RA_DIMENSIONS)
    ]


def _clamp(v: float, lo: float = -1.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, v))


def _hash_band(s: str, offset: int = 0) -> float:
    digest = hashlib.sha256(f"{s}:{offset}".encode()).digest()
    return (digest[0] / 255.0) * 2 - 1


def _encode_os(os_name: str) -> float:
    o = os_name.lower()
    if o == "linux":
        return -0.5
    if o == "windows":
        return 0.0
    if o == "darwin":
        return 0.5
    return 0.0


def _encode_arch(arch: str) -> float:
    a = arch.lower()
    if "arm" in a:
        return -0.3
    if "amd64" in a or "x86_64" in a:
        return 0.3
    if "x86" in a:
        return 0.1
    return 0.0


def _encode_virt_role(role: str) -> float:
    r = role.lower()
    if r == "physical":
        return 0.0
    if r in ("guest", "vm"):
        return 0.5
    if r in ("container", "pod"):
        return -0.5
    return 0.0


def _encode_virt_platform(platform: str) -> float:
    p = platform.lower()
    mapping = {
        "bare_metal": 0.0,
        "vmware": 0.35,
        "kvm": 0.25,
        "hyperv": 0.4,
        "xen": 0.3,
        "cloud": 0.45,
        "unknown": 0.0,
    }
    return mapping.get(p, 0.1)


def _temporal_dims() -> tuple[float, float, float, float]:
    lt = time.localtime()
    hour = lt.tm_hour + lt.tm_min / 60.0
    dow = float(lt.tm_wday)
    h_rad = 2.0 * math.pi * hour / 24.0
    d_rad = 2.0 * math.pi * dow / 7.0
    return (
        math.sin(h_rad),
        math.cos(h_rad),
        math.sin(d_rad),
        math.cos(d_rad),
    )


def _score(signals: PlatformSignals, category: str, slot_name: str) -> float:
    """Category aggregate or per-slot override; neutral if absent."""
    scores: Dict[str, float] = signals.extra.get("category_scores") or {}
    if not scores and signals.extra.get("slot_scores"):
        scores = {}
    slot_scores: Dict[str, float] = signals.extra.get("slot_scores") or {}
    if slot_name in slot_scores:
        return _clamp(float(slot_scores[slot_name]))
    if category in scores:
        return _clamp(float(scores[category]))
    return 0.0


def encode_identity_block(signals: PlatformSignals) -> List[float]:
    host = signals.hostname or ""
    return [
        _hash_band(signals.machine_id, 0),
        _hash_band(signals.machine_id, 1),
        _clamp(len(host) / 32.0, 0.0, 1.0) * 2 - 1,
        _encode_os(signals.os),
        _encode_arch(signals.arch),
        _encode_virt_role(signals.virt_role),
        _encode_virt_platform(signals.virt_platform),
        _hash_band(signals.target, 2),
    ]


def encode_runtime_block(signals: PlatformSignals) -> List[float]:
    load = 0.0
    if signals.load_1m is not None:
        load = _clamp(signals.load_1m / 10.0)
    cpu = 0.0
    if signals.cpu_percent is not None:
        cpu = _clamp(signals.cpu_percent / 50.0 - 1.0)
    mem = 0.0
    if signals.mem_used_ratio is not None:
        mem = _clamp(signals.mem_used_ratio * 2 - 1)
    h_sin, h_cos, d_sin, d_cos = _temporal_dims()
    return [load, cpu, mem, h_sin, h_cos, d_sin, d_cos]


def encode_category_block(
    signals: PlatformSignals, specs: List[SlotSpec]
) -> List[float]:
    return [_score(signals, spec.category or "", spec.name) for spec in specs]


def encode_agent_ra(signals: PlatformSignals) -> List[float]:
    """Build full 64D semantic genome from platform signals."""
    specs = slot_specs()
    out = [0.0] * AGENT_RA_DIMENSIONS

    identity = encode_identity_block(signals)
    for i, v in enumerate(identity):
        out[i] = v

    runtime_indices = {48, 49, 50, 60, 61, 62, 63}
    for spec in specs[IDENTITY_END:]:
        if spec.index in runtime_indices:
            continue
        out[spec.index] = _score(signals, spec.category or "", spec.name)

    runtime_tail = encode_runtime_block(signals)
    # D48-50 load/cpu/mem
    out[48], out[49], out[50] = runtime_tail[0], runtime_tail[1], runtime_tail[2]
    # D51-59 from category scores (security + backup) — already set in loop above
    # D60-63 temporal
    out[60], out[61], out[62], out[63] = (
        runtime_tail[3],
        runtime_tail[4],
        runtime_tail[5],
        runtime_tail[6],
    )

    return [_clamp(v) for v in out]


def category_scores_from_genome(genome: List[float]) -> Dict[str, float]:
    """Aggregate slot values by signal category (for hybrid TI)."""
    specs = slot_specs()
    acc: Dict[str, List[float]] = {}
    n = min(len(genome), len(specs))
    for i in range(n):
        cat = specs[i].category
        if not cat:
            continue
        acc.setdefault(cat, []).append(abs(genome[i]))
    return {k: _clamp(sum(v) / len(v)) for k, v in acc.items() if v}
