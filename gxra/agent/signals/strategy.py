"""
Machine-readable signal scope matrix for GX-RA host agents.

See docs/gxra-agent-signal-strategy.md for threat context and per-platform rationale.
"""

from __future__ import annotations

from typing import Dict, FrozenSet, Literal, Optional

SignalTier = Literal[0, 1, 2]

SignalCategory = Literal[
    "identity",
    "virt_placement",
    "backup_integrity",
    "persistence_delta",
    "lolbin_activity",
    "auth_anomaly",
    "process_posture",
    "volume_activity",
    "network_posture",
    "security_product",
    "runtime_soft",
]

# Tier assignment per category
CATEGORY_TIER: Dict[SignalCategory, SignalTier] = {
    "identity": 0,
    "virt_placement": 0,
    "backup_integrity": 1,
    "persistence_delta": 1,
    "lolbin_activity": 1,
    "auth_anomaly": 1,
    "process_posture": 1,
    "security_product": 1,
    "volume_activity": 2,
    "network_posture": 2,
    "runtime_soft": 1,
}

# Categories enabled per GX-RA target (OS build). Empty = use default set.
_TARGET_CATEGORIES: Dict[str, FrozenSet[SignalCategory]] = {
    "linux-amd64": frozenset(
        {
            "identity",
            "virt_placement",
            "backup_integrity",
            "persistence_delta",
            "lolbin_activity",
            "auth_anomaly",
            "process_posture",
            "security_product",
            "runtime_soft",
            "volume_activity",
            "network_posture",
        }
    ),
    "linux-arm64": frozenset(
        {
            "identity",
            "virt_placement",
            "backup_integrity",
            "persistence_delta",
            "lolbin_activity",
            "auth_anomaly",
            "process_posture",
            "security_product",
            "runtime_soft",
            "volume_activity",
            "network_posture",
        }
    ),
    "windows-amd64": frozenset(
        {
            "identity",
            "virt_placement",
            "backup_integrity",
            "persistence_delta",
            "lolbin_activity",
            "auth_anomaly",
            "process_posture",
            "security_product",
            "runtime_soft",
            "volume_activity",
            "network_posture",
        }
    ),
    "windows-x86": frozenset(
        {
            "identity",
            "virt_placement",
            "backup_integrity",
            "persistence_delta",
            "lolbin_activity",
            "auth_anomaly",
            "process_posture",
            "security_product",
            "runtime_soft",
        }
    ),
    "darwin-amd64": frozenset(
        {
            "identity",
            "virt_placement",
            "backup_integrity",
            "persistence_delta",
            "process_posture",
            "security_product",
            "runtime_soft",
        }
    ),
    "darwin-arm64": frozenset(
        {
            "identity",
            "virt_placement",
            "backup_integrity",
            "persistence_delta",
            "process_posture",
            "security_product",
            "runtime_soft",
        }
    ),
}

# Workload-scoped agent (container/K8s sidecar) — narrower than node agent
_WORKLOAD_CATEGORIES: FrozenSet[SignalCategory] = frozenset(
    {
        "identity",
        "virt_placement",
        "process_posture",
        "runtime_soft",
    }
)

# Categories explicitly denied on all platforms (documentation + guard)
DENIED_CATEGORIES: FrozenSet[str] = frozenset(
    {
        "file_content",
        "keystrokes",
        "clipboard",
        "browser_history",
        "email_content",
        "packet_payload",
        "secrets",
    }
)


def tier_for_category(category: SignalCategory) -> SignalTier:
    return CATEGORY_TIER[category]


def categories_for_target(
    target: str,
    *,
    scope: Literal["host", "workload"] = "host",
    max_tier: SignalTier = 2,
) -> FrozenSet[SignalCategory]:
    if scope == "workload":
        base = _WORKLOAD_CATEGORIES
    else:
        base = _TARGET_CATEGORIES.get(target, _TARGET_CATEGORIES["linux-amd64"])
    return frozenset(c for c in base if tier_for_category(c) <= max_tier)


def is_category_in_scope(
    category: SignalCategory,
    target: str,
    *,
    scope: Literal["host", "workload"] = "host",
    max_tier: SignalTier = 2,
) -> bool:
    if category in DENIED_CATEGORIES:  # type: ignore[comparison-overlap]
        return False
    return category in categories_for_target(target, scope=scope, max_tier=max_tier)


def max_tier_from_env() -> SignalTier:
    import os

    raw = os.environ.get("GXRA_AGENT_TIER_MAX", "2").strip()
    if raw in ("0", "1", "2"):
        return int(raw)  # type: ignore[return-value]
    return 2
