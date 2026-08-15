#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Source and event quality projection for optimization snapshots."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from marketing_optimization_contract import (
    OptimizationSnapshot,
    parse_datetime,
    source_is_stale,
)


@dataclass
class QualityState:
    """Mutable quality evidence accumulated for one immutable snapshot."""

    as_of: str
    reasons: set[str] = field(default_factory=set)
    missing: set[str] = field(default_factory=set)
    source_keys: set[tuple[str, str]] = field(default_factory=set)


def _expected_source_keys(snapshot: OptimizationSnapshot) -> set[tuple[str, str]]:
    """Return source/account pairs represented by normalized events."""
    return {
        (str(event["source"]["kind"]), str(event["source"]["account_ref"]))
        for event in snapshot.events
    }


def _collect_source_quality(state: QualityState, source: dict[str, Any]) -> None:
    """Accumulate one source summary's freshness and coverage evidence."""
    key = (str(source.get("source")), str(source.get("account_ref")))
    if key in state.source_keys:
        state.reasons.add("duplicate_source_summary")
    state.source_keys.add(key)
    observed_at = source.get("last_observed_at")
    if observed_at is None or source.get("lag_seconds") is None:
        state.reasons.add("unknown_source_freshness")
    elif parse_datetime(observed_at, "source last_observed_at") > parse_datetime(state.as_of, "snapshot as_of"):
        state.reasons.add("future_source_observation")
    if source_is_stale(state.as_of, source):
        state.reasons.add("stale_source")
    if source.get("status") in {"leased", "unavailable", "unknown"}:
        state.reasons.add("source_not_ready")
    coverage = source.get("coverage")
    if coverage in {"partial", "unknown"}:
        state.reasons.add(f"{coverage}_coverage")
    if int(source.get("unresolved_quarantine", 0)) > 0:
        state.reasons.add("unresolved_quarantine")
    state.missing.update(str(item) for item in source.get("missing_scopes", []))


def _collect_event_quality(state: QualityState, event: dict[str, Any]) -> None:
    """Accumulate one event's normalized coverage and confidence evidence."""
    coverage = event["source"].get("coverage")
    if coverage in {"partial", "unknown"}:
        state.reasons.add(f"{coverage}_coverage")
    state.missing.update(str(item) for item in event["source"].get("missing_scopes", []))
    quality = event["quality"]
    completeness = str(quality["completeness"])
    if completeness in {"partial", "unknown"}:
        state.reasons.add(f"{completeness}_coverage")
    if quality["effective_confidence"] not in {"high", "verified"}:
        state.reasons.add("insufficient_event_confidence")


def snapshot_quality(snapshot: OptimizationSnapshot) -> tuple[list[str], list[str]]:
    """Return normalized source/event quality reasons and missing scopes."""
    state = QualityState(snapshot.as_of)
    if not snapshot.sources:
        state.reasons.add("missing_sources")
    for source in snapshot.sources:
        _collect_source_quality(state, source)
    if _expected_source_keys(snapshot) - state.source_keys:
        state.reasons.add("missing_source_summary")
    for event in snapshot.events:
        _collect_event_quality(state, event)
    if state.missing:
        state.reasons.add("missing_scopes")
    return sorted(state.reasons), sorted(state.missing)
