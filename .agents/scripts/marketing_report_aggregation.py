#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Aggregate normalized performance events into privacy-gated report rows."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any

from marketing_optimization_contract import OptimizationSnapshot, identity_is_uncertain, number, wire_number
from marketing_optimization_snapshot_validation import canonical_subject_map

CATEGORY_GROUPS = (
    ("reach", frozenset({"impression"})),
    ("engagement", frozenset({"engagement", "social_receipt"})),
    ("account_growth", frozenset({"follower", "subscriber"})),
    ("traffic", frozenset({"visit"})),
    ("conversion", frozenset({"conversion"})),
    ("leads", frozenset({"lead_created", "lead_stage"})),
    ("sales", frozenset({"sale"})),
    ("revenue_refunds", frozenset({"revenue", "refund"})),
    ("costs", frozenset({"cost"})),
    ("outreach", frozenset({"outreach_sent", "outreach_reply", "outreach_bounce"})),
    ("guardrails", frozenset({"unsubscribe"})),
)
COUNT_UNITS = {
    "impression",
    "engagement",
    "follower",
    "subscriber",
    "receipt",
    "visit",
    "conversion",
    "lead",
    "sale",
    "refund",
    "message",
    "reply",
    "bounce",
    "unsubscribe",
}
CONTEXT_DIMENSIONS = ("cohort", "environment", "region")


@dataclass
class MetricCell:
    """Internal exact metric cell with conservative privacy cardinality."""

    value: Decimal = Decimal(0)
    records: int = 0
    subjects: set[str] = field(default_factory=set)
    anonymous_records: set[str] = field(default_factory=set)
    aggregate_count: int = 0

    def add(self, event: dict[str, Any], canonical_by_alias: dict[str, str]) -> None:
        """Add one effective normalized event."""
        measurement = event["measurement"]
        amount = number(measurement["value"], "report metric value")
        self.value += amount
        self.records += 1
        if identity_is_uncertain(event["subject"].get("identity_state")):
            return
        subject_id = event["subject"].get("subject_id")
        if subject_id is not None:
            subject_ref = str(subject_id)
            self.subjects.add(canonical_by_alias.get(subject_ref, subject_ref))
        elif event["subject"].get("kind") == "aggregate" and measurement["unit"] in COUNT_UNITS:
            self.aggregate_count += _whole_count(amount)
        else:
            self.anonymous_records.add(str(event["record_ref"]))

    @property
    def privacy_size(self) -> int:
        """Return distinct linked subjects plus safe aggregate observations."""
        return len(self.subjects) + len(self.anonymous_records) + self.aggregate_count


def _whole_count(value: Decimal) -> int:
    """Count only non-negative whole aggregate units."""
    if value < 0 or value != value.to_integral_value():
        return 0
    return int(value)


def _category(event_type: str) -> str:
    """Map one normalized event type to a report category."""
    return next((category for category, event_types in CATEGORY_GROUPS if event_type in event_types), "other")


def _cell_key(event: dict[str, Any]) -> tuple[str, ...]:
    """Return one stable aggregate metric and scope key."""
    scope = event["scope"]
    measurement = event["measurement"]
    dimensions = scope.get("dimensions", {})
    context = {field: dimensions[field] for field in CONTEXT_DIMENSIONS if field in dimensions}
    return (
        _category(str(event["event"]["type"])),
        str(measurement["metric_id"]),
        str(measurement["unit"]),
        str(measurement.get("currency") or ""),
        str(scope.get("campaign_id") or ""),
        str(scope.get("channel") or ""),
        str(scope.get("creative_id") or ""),
        str(scope.get("touchpoint_id") or ""),
        json.dumps(context, sort_keys=True, separators=(",", ":")),
    )


def _nullable(value: str) -> str | None:
    """Convert empty aggregate key components to JSON null."""
    return value or None


def _render_cell(key: tuple[str, ...], cell: MetricCell, minimum_cell_size: int) -> dict[str, Any]:
    """Render one metric cell with dimensions hidden below threshold."""
    category, metric_id, unit, currency, campaign, channel, creative, touchpoint, dimensions = key
    suppressed = cell.privacy_size < minimum_cell_size
    return {
        "category": category,
        "metric_id": metric_id,
        "campaign_id": None if suppressed else _nullable(campaign),
        "channel": None if suppressed else _nullable(channel),
        "creative_id": None if suppressed else _nullable(creative),
        "touchpoint_id": None if suppressed else _nullable(touchpoint),
        "dimensions": None if suppressed else json.loads(dimensions),
        "unit": unit,
        "currency": _nullable(currency),
        "value": None if suppressed else wire_number(cell.value),
        "record_count": None if suppressed else cell.privacy_size,
        "suppressed": suppressed,
        "suppression_reason": "below_minimum_cell_size" if suppressed else None,
    }


def aggregate_performance(snapshot: OptimizationSnapshot, minimum_cell_size: int) -> list[dict[str, Any]]:
    """Aggregate all effective events without emitting subject-level rows."""
    cells: dict[tuple[str, ...], MetricCell] = {}
    canonical_by_alias = canonical_subject_map(snapshot.subjects)
    for event in snapshot.events:
        if number(event["measurement"]["value"], "report metric value") == 0:
            continue
        key = _cell_key(event)
        cells.setdefault(key, MetricCell()).add(event, canonical_by_alias)
    return [_render_cell(key, cells[key], minimum_cell_size) for key in sorted(cells)]
