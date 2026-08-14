"""Bounded adapters for normalized marketing performance fixtures."""

from __future__ import annotations

from importlib import import_module
from typing import Any

SUPPORTED = {"campaign", "social", "analytics", "crm", "commerce", "payment", "outreach", "manual"}


def normalize(adapter: str, document: Any, *, source_account: str | None = None, evidence_ref: str | None = None) -> dict[str, Any]:
    """Load one bounded adapter and return its provider-neutral envelope."""
    selected = "commerce" if adapter == "payment" else adapter
    if selected not in SUPPORTED:
        raise ValueError(f"unsupported adapter: {adapter}")
    module = import_module(f"performance_adapters.{selected}")
    return module.normalize(document, source_account=source_account, evidence_ref=evidence_ref)
