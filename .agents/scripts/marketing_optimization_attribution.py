#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic aggregate marketing attribution."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import Any

from marketing_optimization_common import (
    SCHEMA_ATTRIBUTION,
    OptimizationError,
    canonical,
    decimal_text,
    decimal_value,
    digest,
    timestamp,
)

TOUCHPOINT_TYPES = {"impression", "engagement", "social_receipt", "visit", "outreach_sent"}
OUTCOME_TYPES = {"conversion", "lead_created", "lead_stage", "sale", "revenue"}


@dataclass(frozen=True)
class AttributionOptions:
    """Versioned attribution run options."""

    model: str
    window_days: int
    model_version: int
    window_version: int
    run_id: str
    generated_at: str


@dataclass(frozen=True)
class AttributionContext:
    """Lookup state shared while attributing events."""

    model: str
    window_seconds: int
    touchpoints: dict[str, list[tuple[datetime, dict[str, Any]]]]


def _event_parts(event: dict[str, Any]) -> tuple[str, datetime, dict[str, Any], dict[str, Any], dict[str, Any]]:
    try:
        event_type = str(event["event"]["type"])
        occurred_at = timestamp(event["event"]["occurred_at"], "event.occurred_at")
        subject = event["subject"]
        scope = event["scope"]
        measurement = event["measurement"]
    except (KeyError, TypeError) as exc:
        raise OptimizationError("events must follow marketing-performance-event v1") from exc
    if not all(isinstance(value, dict) for value in (subject, scope, measurement)):
        raise OptimizationError("event subject, scope, and measurement must be objects")
    return event_type, occurred_at, subject, scope, measurement


def _parse_events(events: list[dict[str, Any]]) -> list[tuple[Any, ...]]:
    parsed = []
    for index, raw_event in enumerate(events):
        if not isinstance(raw_event, dict):
            raise OptimizationError("each event must be an object")
        event_type, occurred_at, subject, scope, measurement = _event_parts(raw_event)
        stable_ref = str(raw_event.get("event_ref") or f"event-{index:08d}")
        parsed.append((occurred_at, event_type, subject, scope, measurement, stable_ref))
    parsed.sort(key=lambda item: (item[0], item[5]))
    return parsed


def _validate_input(document: dict[str, Any], model: str) -> tuple[list[dict[str, Any]], str, str, list[tuple[Any, ...]]]:
    if model not in {"direct", "last_touch"}:
        raise OptimizationError("model must be direct or last_touch")
    events = document.get("events")
    if not isinstance(events, list):
        raise OptimizationError("events must be an array")
    snapshot = str(document.get("source_snapshot") or "")
    if not snapshot:
        raise OptimizationError("source_snapshot is required")
    coverage = document.get("coverage", "unknown")
    if coverage not in {"complete", "partial", "unknown"}:
        raise OptimizationError("coverage must be complete, partial, or unknown")
    return events, snapshot, coverage, _parse_events(events)


def _touchpoint_index(parsed: list[tuple[Any, ...]]) -> dict[str, list[tuple[datetime, dict[str, Any]]]]:
    touchpoints: dict[str, list[tuple[datetime, dict[str, Any]]]] = defaultdict(list)
    for occurred_at, event_type, subject, scope, _measurement, _event_ref in parsed:
        subject_id = subject.get("subject_id")
        if event_type in TOUCHPOINT_TYPES and isinstance(subject_id, str):
            touchpoints[subject_id].append((occurred_at, scope))
    return touchpoints


def _bucket(totals: dict[tuple[Any, ...], dict[str, Any]], scope: dict[str, Any], currency: str | None) -> dict[str, Any]:
    key = (scope.get("campaign_id"), scope.get("channel"), currency)
    return totals.setdefault(
        key,
        {"credited_outcomes": 0, "credit": Decimal(0), "revenue": Decimal(0), "refunds": Decimal(0), "costs": Decimal(0), "uncertain": False},
    )


def _attributed_scope(event: tuple[Any, ...], context: AttributionContext) -> dict[str, Any] | None:
    occurred_at, _event_type, subject, scope, _measurement, _event_ref = event
    if subject.get("identity_state") == "ambiguous":
        return None
    if context.model == "direct":
        return scope
    subject_id = subject.get("subject_id")
    if isinstance(subject_id, str):
        candidates = [
            candidate_scope
            for touched_at, candidate_scope in context.touchpoints.get(subject_id, [])
            if 0 <= (occurred_at - touched_at).total_seconds() <= context.window_seconds
        ]
        if candidates:
            return candidates[-1]
    return scope if scope.get("channel") == "direct" else None


def _currency(measurement: dict[str, Any]) -> str | None:
    currency = measurement.get("currency")
    if currency is not None and not isinstance(currency, str):
        raise OptimizationError("measurement.currency must be a string or null")
    return currency


def _apply_event(event: tuple[Any, ...], totals: dict[tuple[Any, ...], dict[str, Any]], context: AttributionContext) -> tuple[int, int, int]:
    _occurred_at, event_type, subject, scope, measurement, _event_ref = event
    value = decimal_value(measurement.get("value"), "measurement.value")
    currency = _currency(measurement)
    if event_type in {"refund", "cost"}:
        target = _bucket(totals, scope, currency)
        target["refunds" if event_type == "refund" else "costs"] += abs(value)
        return 0, 0, 0
    if event_type not in OUTCOME_TYPES:
        return 0, 0, 0
    identity_state = subject.get("identity_state")
    uncertain = int(identity_state == "ambiguous")
    selected_scope = _attributed_scope(event, context)
    if selected_scope is None:
        return 0, 1, uncertain
    target = _bucket(totals, selected_scope, currency)
    target["credited_outcomes"] += 1
    target["credit"] += Decimal(1)
    target["revenue"] += value if event_type == "revenue" else Decimal(0)
    target["uncertain"] = target["uncertain"] or identity_state == "split"
    return 1, 0, uncertain


def _attribute_events(parsed: list[tuple[Any, ...]], options: AttributionOptions) -> tuple[dict[tuple[Any, ...], dict[str, Any]], int, int, int]:
    context = AttributionContext(options.model, options.window_days * 86400, _touchpoint_index(parsed))
    totals: dict[tuple[Any, ...], dict[str, Any]] = {}
    matched = unattributed = uncertain = 0
    for event in parsed:
        event_matched, event_unattributed, event_uncertain = _apply_event(event, totals, context)
        matched += event_matched
        unattributed += event_unattributed
        uncertain += event_uncertain
    return totals, matched, unattributed, uncertain


def _aggregates(totals: dict[tuple[Any, ...], dict[str, Any]], coverage: str) -> list[dict[str, Any]]:
    aggregates = []
    ordering = lambda item: tuple("" if value is None else value for value in item[0])
    for (campaign_id, channel, currency), values in sorted(totals.items(), key=ordering):
        uncertainty = "high" if values["uncertain"] or coverage == "unknown" else "medium" if coverage == "partial" else "low"
        aggregates.append({
            "campaign_id": campaign_id,
            "channel": channel,
            "credited_outcomes": values["credited_outcomes"],
            "credit": decimal_text(values["credit"]),
            "revenue": decimal_text(values["revenue"]),
            "refunds": decimal_text(values["refunds"]),
            "costs": decimal_text(values["costs"]),
            "net_revenue": decimal_text(values["revenue"] - values["refunds"]),
            "currency": currency,
            "uncertainty": uncertainty,
        })
    return aggregates


def attribute(document: dict[str, Any], options: AttributionOptions) -> dict[str, Any]:
    """Build a deterministic aggregate attribution projection."""
    events, snapshot, coverage, parsed = _validate_input(document, options.model)
    totals, matched, unattributed, uncertain = _attribute_events(parsed, options)
    identity_events = sorted(events, key=lambda event: (str(event.get("event_ref", "")), canonical(event)))
    identity = {"source_snapshot": snapshot, "model": options.model, "model_version": options.model_version, "window_days": options.window_days, "window_version": options.window_version, "events": identity_events}
    return {
        "schema": SCHEMA_ATTRIBUTION,
        "projection_id": digest("mkt-attribution-v1", identity),
        "run_id": options.run_id,
        "source_snapshot": snapshot,
        "model": {"name": options.model, "version": options.model_version},
        "window": {"days": options.window_days, "version": options.window_version},
        "generated_at": options.generated_at,
        "coverage": {"source": coverage, "matched_outcomes": matched, "unattributed_outcomes": unattributed, "identity_uncertain_outcomes": uncertain},
        "causality": {"claim": "observational", "caveat": "Attribution assigns observational credit; it does not establish incremental or causal growth."},
        "aggregates": _aggregates(totals, coverage),
    }
