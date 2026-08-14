"""Shared normalization for synthetic or exported provider-neutral envelopes."""

from __future__ import annotations

import copy
import datetime as dt
from typing import Any


def envelope(document: Any, source_class: str, *, source_account: str | None = None, evidence_ref: str | None = None) -> dict[str, Any]:
    """Validate adapter ownership and add only non-sensitive source defaults."""
    if not isinstance(document, dict):
        raise ValueError("adapter input must be a JSON object")
    result = copy.deepcopy(document)
    source = result.setdefault("source", {})
    if not isinstance(source, dict):
        raise ValueError("source must be an object")
    source.setdefault("provider", source_class)
    source["source_class"] = source_class
    source.setdefault("account_id", source_account or "default")
    source.setdefault("captured_at", dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"))
    source.setdefault("cursor", "fixture:1")
    source.setdefault("coverage", 1.0)
    source.setdefault("scope_status", "complete")
    if evidence_ref:
        source.setdefault("evidence_ref", evidence_ref)
    result.setdefault("subjects", [])
    result.setdefault("events", [])
    return result
