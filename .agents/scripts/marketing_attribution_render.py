#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Privacy-gated rendering helpers for aggregate marketing attribution."""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any

from marketing_optimization_contract import (
    OptimizationSnapshot,
    identity_is_uncertain,
    minimum_confidence,
    snapshot_quality,
    wire_number,
)
from performance_contract import require_alias


@dataclass
class AllocationTotals:
    """Internal exact totals for one aggregate attribution bucket."""

    outcome_count: int = 0
    credit: Decimal = Decimal(0)
    value: Decimal = Decimal(0)
    subject_refs: set[str] = field(default_factory=set)
    anonymous_records: set[str] = field(default_factory=set)
    aggregate_count: int = 0

    def observe(self, event: dict[str, Any], count: int, canonical_by_alias: dict[str, str]) -> None:
        """Count distinct linked subjects or already-aggregate observations."""
        if identity_is_uncertain(event["subject"].get("identity_state")):
            return
        subject_id = event["subject"].get("subject_id")
        if subject_id is not None:
            subject_ref = str(subject_id)
            self.subject_refs.add(canonical_by_alias.get(subject_ref, subject_ref))
        elif event["subject"].get("kind") == "aggregate":
            self.aggregate_count += count
        else:
            self.anonymous_records.add(str(event["record_ref"]))

    @property
    def privacy_size(self) -> int:
        """Return the conservative aggregate cell size."""
        return len(self.subject_refs) + len(self.anonymous_records) + self.aggregate_count


@dataclass(frozen=True)
class CountSummary:
    """Aggregate outcome counts before privacy suppression."""

    eligible: int
    attributed: int
    identity_uncertain: int


@dataclass(frozen=True)
class ValueSummary:
    """Exact outcome, refund, and cost values before privacy suppression."""

    gross: Decimal
    refund: Decimal
    net: Decimal
    currency: str | None
    currency_mismatch: bool
    unmatched_refunds: int
    cost: Decimal | None
    cost_currency: str | None
    cost_allocation: str
    roi: Decimal | None


@dataclass(frozen=True)
class UncertaintyConditions:
    """Explicit conditions that cap attribution confidence."""

    suppressed: bool
    identity_uncertain: int
    currency_mismatch: bool
    late_events: int
    unmatched_refunds: int
    provisional: bool


def source_quality(snapshot: OptimizationSnapshot) -> tuple[list[str], list[str]]:
    """Return quality reasons and missing source scopes."""
    return snapshot_quality(snapshot)


def confidence(outcomes: list[dict[str, Any]], reasons: list[str]) -> str:
    """Combine effective source confidence with explicit uncertainty caps."""
    observed = [str(event["quality"]["effective_confidence"]) for event in outcomes]
    observed_confidence = minimum_confidence(observed)
    if not reasons:
        return observed_confidence
    critical = {"identity_ambiguity", "currency_mismatch", "insufficient_events"}
    cap = "low" if critical.intersection(reasons) else "medium"
    return minimum_confidence([observed_confidence, cap])


def render_allocations(
    totals: dict[tuple[str, str | None, str | None, str | None], AllocationTotals],
    minimum_cell_size: int,
    currency_mismatch: bool,
) -> tuple[list[dict[str, Any]], int]:
    """Suppress small cells and render stable aggregate allocation rows."""
    output: list[dict[str, Any]] = []
    suppressed_count = 0
    for key in sorted(totals, key=lambda item: tuple(value or "" for value in item)):
        bucket, touchpoint_ref, channel, creative_id = key
        total = totals[key]
        suppressed = total.privacy_size < minimum_cell_size
        suppressed_count += int(suppressed)
        output.append(
            {
                "bucket": bucket,
                "touchpoint_ref": visible(touchpoint_ref, suppressed),
                "channel": visible(channel, suppressed),
                "creative_id": visible(creative_id, suppressed),
                "outcome_count": visible(total.outcome_count, suppressed),
                "credit": visible(wire_number(total.credit), suppressed),
                "value": visible(wire_number(total.value), suppressed or currency_mismatch),
                "suppressed": suppressed,
                "suppression_reason": "below_minimum_cell_size" if suppressed else None,
            }
        )
    return output, suppressed_count


def derived_scope(snapshot: OptimizationSnapshot, explicit: str | None, field: str) -> str | None:
    """Derive a nullable scope only when all events agree."""
    if explicit is not None:
        return require_alias(explicit, field)
    values = {event["scope"].get(field) for event in snapshot.events if event["scope"].get(field)}
    return next(iter(values)) if len(values) == 1 else None


def derived_account(snapshot: OptimizationSnapshot, explicit: str | None) -> str | None:
    """Derive an account scope only when all events agree."""
    if explicit is not None:
        return require_alias(explicit, "account_ref")
    values = {event["source"].get("account_ref") for event in snapshot.events if event["source"].get("account_ref")}
    return next(iter(values)) if len(values) == 1 else None


def selected_currency(currencies: set[str], requested: str | None) -> str | None:
    """Return one observed currency without manufacturing requested metadata."""
    if len(currencies) != 1:
        return None
    observed = next(iter(currencies))
    return observed if requested is None or requested == observed else None


def uncertainty_reasons(source_reasons: list[str], conditions: UncertaintyConditions) -> list[str]:
    """Render stable reason codes from explicit analysis conditions."""
    flags = (
        (conditions.suppressed, "insufficient_events"),
        (conditions.identity_uncertain > 0, "identity_ambiguity"),
        (conditions.currency_mismatch, "currency_mismatch"),
        (conditions.late_events > 0, "late_events"),
        (conditions.unmatched_refunds > 0, "unmatched_refunds"),
        (conditions.provisional, "provisional_refunds"),
    )
    return sorted(set(source_reasons).union(reason for active, reason in flags if active))


def analysis_status(outcomes: list[dict[str, Any]], suppressed: bool, reasons: list[str]) -> str:
    """Return complete, partial, or insufficient evidence state."""
    if not outcomes or suppressed:
        return "insufficient_evidence"
    if reasons:
        return "partial"
    return "complete"


def visible(value: Any, hidden: bool) -> Any:
    """Return null when aggregate privacy or comparability hides a value."""
    return None if hidden else value


def maturity(outcomes: list[dict[str, Any]], provisional: bool) -> str:
    """Return the aggregate refund maturity label."""
    states = {(True, False): "not_applicable", (False, True): "provisional", (False, False): "mature"}
    return states[(not outcomes, provisional)]


def outcome_document(
    outcomes: list[dict[str, Any]],
    counts: CountSummary,
    values: ValueSummary,
    suppressed: bool,
) -> dict[str, Any]:
    """Render privacy-gated outcome totals."""
    hide_value = suppressed or values.currency_mismatch
    return {
        "suppressed": suppressed,
        "eligible_count": visible(counts.eligible, suppressed),
        "attributed_count": visible(counts.attributed, suppressed),
        "unattributed_count": visible(counts.eligible - counts.attributed - counts.identity_uncertain, suppressed),
        "identity_uncertain_count": visible(counts.identity_uncertain, suppressed),
        "gross_value": visible(wire_number(values.gross), hide_value),
        "refund_value": visible(wire_number(values.refund), hide_value),
        "net_value": visible(wire_number(values.net), hide_value),
        "unit": outcomes[0]["measurement"]["unit"] if outcomes else "conversion",
        "currency": values.currency,
    }


def cost_document(values: ValueSummary, suppressed: bool) -> dict[str, Any]:
    """Render privacy-gated cost and ROI totals."""
    hidden = suppressed or values.currency_mismatch
    return {
        "value": visible(wire_number(values.cost), hidden),
        "currency": values.cost_currency,
        "allocation": values.cost_allocation,
        "roi": visible(wire_number(values.roi), hidden),
    }
