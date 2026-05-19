"""Threat-informed signal taxonomy for scoped host collection."""

from gxra.agent.signals.strategy import (
    SignalCategory,
    SignalTier,
    categories_for_target,
    is_category_in_scope,
    tier_for_category,
)

__all__ = [
    "SignalCategory",
    "SignalTier",
    "categories_for_target",
    "is_category_in_scope",
    "tier_for_category",
]
