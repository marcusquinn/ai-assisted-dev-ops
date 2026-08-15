#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic aggregate direct and last-touch marketing attribution."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import timedelta
from decimal import Decimal
import re
from typing import Any

from marketing_attribution_render import (
    AllocationTotals,
    CountSummary,
    UncertaintyConditions,
    ValueSummary,
    analysis_status,
    confidence,
    cost_document,
    derived_account,
    derived_scope,
    maturity,
    outcome_document,
    render_allocations,
    selected_currency,
    source_quality,
    uncertainty_reasons,
    visible,
)
from marketing_optimization_contract import (
    MINIMUM_AGGREGATE_CELL_SIZE,
    OptimizationError,
    OptimizationSnapshot,
    divide,
    identity_is_uncertain,
    number,
    parse_datetime,
    require_integer,
    require_metric,
    typed_reference,
    wire_number,
)
from marketing_optimization_io import evidence_refs
from marketing_optimization_snapshot_validation import canonical_subject_map
from marketing_optimization_validation_common import ATTRIBUTION_CAUSAL_STATEMENT

TOUCHPOINT_TYPES = {"engagement", "visit", "outreach_reply"}
OUTCOME_TYPES = {"conversion", "lead_created", "lead_stage", "sale", "revenue"}
COUNT_UNITS = {"conversion", "lead", "sale"}
ATTRIBUTION_REF_RE = re.compile(r"^mkt-attribution-v1:[a-f0-9]{64}$")


@dataclass(frozen=True)
class AttributionRequest:
    """Policy and scope for one attribution projection."""

    outcome_metric_id: str
    model: str
    lookback_seconds: int
    refund_maturity_seconds: int
    minimum_cell_size: int
    model_version: int = 1
    include_view_through: bool = False
    account_ref: str | None = None
    campaign_id: str | None = None
    currency: str | None = None
    supersedes: str | None = None


def _validate_request(request: AttributionRequest) -> None:
    """Validate public attribution policy before analysis."""
    require_metric(request.outcome_metric_id, "outcome_metric_id")
    require_integer(request.lookback_seconds, "lookback_seconds", 1, 31536000)
    require_integer(request.refund_maturity_seconds, "refund_maturity_seconds", 0, 31536000)
    require_integer(
        request.minimum_cell_size,
        "minimum_cell_size",
        MINIMUM_AGGREGATE_CELL_SIZE,
        1000000,
    )
    require_integer(request.model_version, "model_version", 1, 1000000)
    if request.model not in {"direct", "last_touch"}:
        raise OptimizationError("attribution model must be direct or last_touch")
    if not isinstance(request.include_view_through, bool):
        raise OptimizationError("include_view_through must be boolean")
    if request.currency is not None and not re.fullmatch(r"[A-Z]{3}", request.currency):
        raise OptimizationError("currency must be an ISO-style uppercase code")
    if request.supersedes is not None and not ATTRIBUTION_REF_RE.fullmatch(request.supersedes):
        raise OptimizationError("supersedes must be an attribution reference")


def _event_count(event: dict[str, Any]) -> int:
    """Return aggregate count semantics without coercing monetary values."""
    measurement = event["measurement"]
    value = number(measurement["value"], "outcome value")
    if measurement["unit"] not in COUNT_UNITS:
        return 1
    if value < 0 or value != value.to_integral_value():
        raise OptimizationError("count outcomes require non-negative integer values")
    return int(value)


def _outcomes(snapshot: OptimizationSnapshot, request: AttributionRequest) -> list[dict[str, Any]]:
    """Select outcome records for the requested metric."""
    return [
        event
        for event in snapshot.events
        if event["event"]["type"] in OUTCOME_TYPES
        and event["measurement"]["metric_id"] == request.outcome_metric_id
    ]


def _touchpoints(snapshot: OptimizationSnapshot, request: AttributionRequest) -> list[dict[str, Any]]:
    """Select eligible touchpoints in deterministic chronological order."""
    eligible_types = set(TOUCHPOINT_TYPES)
    if request.include_view_through:
        eligible_types.add("impression")
    return [event for event in snapshot.events if event["event"]["type"] in eligible_types]


def _direct_key(outcome: dict[str, Any]) -> tuple[str, str | None, str | None, str | None]:
    """Use only dimensions observed directly on the outcome record."""
    if outcome["subject"].get("identity_state") in {"ambiguous", "split"}:
        return ("identity_uncertain", None, None, None)
    scope = outcome["scope"]
    observed = any(scope.get(key) is not None for key in ("touchpoint_id", "channel", "creative_id"))
    if not observed:
        return ("unattributed", None, None, None)
    return ("direct_observed", None, scope.get("channel"), scope.get("creative_id"))


def _last_touch_key(
    outcome: dict[str, Any],
    touchpoints: list[dict[str, Any]],
    lookback_seconds: int,
    canonical_by_alias: dict[str, str],
) -> tuple[str, str | None, str | None, str | None]:
    """Select the latest prior touchpoint for one unambiguous subject."""
    subject = outcome["subject"]
    subject_id = subject.get("subject_id")
    if subject.get("identity_state") in {"ambiguous", "split"}:
        return ("identity_uncertain", None, None, None)
    if subject_id is None:
        return ("unattributed", None, None, None)
    subject_ref = canonical_by_alias.get(str(subject_id), str(subject_id))
    outcome_at = parse_datetime(outcome["event"]["occurred_at"], "outcome occurred_at")
    lower_bound = outcome_at - timedelta(seconds=lookback_seconds)
    candidates = [
        event
        for event in touchpoints
        if event["subject"].get("subject_id") is not None
        and not identity_is_uncertain(event["subject"].get("identity_state"))
        and canonical_by_alias.get(
            str(event["subject"]["subject_id"]),
            str(event["subject"]["subject_id"]),
        )
        == subject_ref
        and lower_bound <= parse_datetime(event["event"]["occurred_at"], "touchpoint occurred_at") <= outcome_at
    ]
    if not candidates:
        return ("unattributed", None, None, None)
    selected = max(
        candidates,
        key=lambda item: (
            parse_datetime(item["event"]["occurred_at"], "touchpoint occurred_at"),
            item["record_ref"],
        ),
    )
    scope = selected["scope"]
    return ("touchpoint", selected["record_ref"], scope.get("channel"), scope.get("creative_id"))


def _allocation_totals(
    outcomes: list[dict[str, Any]],
    touchpoints: list[dict[str, Any]],
    request: AttributionRequest,
    canonical_by_alias: dict[str, str],
) -> dict[tuple[str, str | None, str | None, str | None], AllocationTotals]:
    """Aggregate outcomes by deterministic model bucket."""
    totals: dict[tuple[str, str | None, str | None, str | None], AllocationTotals] = defaultdict(AllocationTotals)
    for outcome in outcomes:
        key = (
            _direct_key(outcome)
            if request.model == "direct"
            else _last_touch_key(outcome, touchpoints, request.lookback_seconds, canonical_by_alias)
        )
        count = _event_count(outcome)
        totals[key].outcome_count += count
        totals[key].credit += Decimal(count)
        totals[key].value += number(outcome["measurement"]["value"], "outcome value")
        totals[key].observe(outcome, count, canonical_by_alias)
    return totals


def _currencies(events: list[dict[str, Any]]) -> set[str]:
    """Return non-null measurement currencies."""
    return {str(event["measurement"]["currency"]) for event in events if event["measurement"].get("currency")}


def _refund_summary(
    snapshot: OptimizationSnapshot,
    outcomes: list[dict[str, Any]],
) -> tuple[Decimal, int, list[dict[str, Any]], bool]:
    """Sum refunds matched by aggregate-safe outcome ID."""
    if not outcomes or any(event["measurement"]["unit"] != "currency" for event in outcomes):
        return Decimal(0), 0, [], False
    outcome_by_scope: dict[tuple[str, str, str | None, str], tuple[Any, str]] = {}
    for event in outcomes:
        outcome_id = event["scope"].get("outcome_id")
        if outcome_id is None:
            continue
        key = (
            event["source"]["kind"],
            event["source"]["account_ref"],
            event["scope"].get("campaign_id"),
            str(outcome_id),
        )
        if key in outcome_by_scope:
            raise OptimizationError("attribution outcomes contain duplicate refund match keys")
        outcome_by_scope[key] = (
            parse_datetime(event["event"]["occurred_at"], "outcome occurred_at"),
            str(event["measurement"]["currency"]),
        )
    refunds = [
        event
        for event in snapshot.events
        if event["event"]["type"] == "refund" and event["measurement"]["unit"] == "currency"
    ]
    matched: list[dict[str, Any]] = []
    currency_mismatch = False
    for event in refunds:
        outcome = outcome_by_scope.get(
            (
                event["source"]["kind"],
                event["source"]["account_ref"],
                event["scope"].get("campaign_id"),
                str(event["scope"].get("outcome_id")),
            )
        )
        if outcome is None:
            continue
        outcome_at, outcome_currency = outcome
        refund_at = parse_datetime(event["event"]["occurred_at"], "refund occurred_at")
        if refund_at < outcome_at:
            continue
        if event["measurement"].get("currency") != outcome_currency:
            currency_mismatch = True
            continue
        matched.append(event)
    unmatched = len(refunds) - len(matched)
    value = sum((number(event["measurement"]["value"], "refund value") for event in matched), Decimal(0))
    return value, unmatched, matched, currency_mismatch


def _cost_summary(
    snapshot: OptimizationSnapshot,
    net_value: Decimal,
    outcome_currency: str | None,
) -> tuple[Decimal | None, str | None, str, Decimal | None, bool]:
    """Return cost, currency, allocation state, ROI, and mismatch state."""
    costs = [event for event in snapshot.events if event["event"]["type"] == "cost"]
    if not costs:
        return None, None, "not_applicable", None, False
    currencies = _currencies(costs)
    cost_currency = next(iter(currencies)) if len(currencies) == 1 else None
    mismatch = len(currencies) != 1 or (outcome_currency is not None and cost_currency != outcome_currency)
    if mismatch:
        return None, cost_currency, "currency_mismatch", None, True
    total = sum((number(event["measurement"]["value"], "cost value") for event in costs), Decimal(0))
    roi = divide(net_value - total, total) if outcome_currency is not None else None
    exact = all(event["scope"].get("campaign_id") is not None for event in costs)
    return total, cost_currency, "exact" if exact else "unallocated", roi, False


def _value_summary(
    snapshot: OptimizationSnapshot,
    outcomes: list[dict[str, Any]],
    request: AttributionRequest,
) -> ValueSummary:
    """Calculate exact aggregate values and explicit currency mismatch state."""
    units = {str(event["measurement"]["unit"]) for event in outcomes}
    if len(units) > 1:
        raise OptimizationError("attribution outcomes contain incompatible measurement units")
    if request.currency is not None and outcomes and units != {"currency"}:
        raise OptimizationError("currency filters cannot be applied to non-currency outcomes")
    gross_value = sum((number(event["measurement"]["value"], "outcome value") for event in outcomes), Decimal(0))
    refund_value, unmatched_refunds, matched_refunds, refund_currency_mismatch = _refund_summary(
        snapshot,
        outcomes,
    )
    currencies = _currencies(outcomes + matched_refunds)
    currency = selected_currency(currencies, request.currency)
    currency_mismatch = (
        refund_currency_mismatch
        or len(currencies) > 1
        or bool(request.currency and currencies and currencies != {request.currency})
    )
    net_value = gross_value - refund_value
    cost_value, cost_currency, cost_allocation, roi, cost_mismatch = _cost_summary(snapshot, net_value, currency)
    return ValueSummary(
        gross=gross_value,
        refund=refund_value,
        net=net_value,
        currency=currency,
        currency_mismatch=currency_mismatch or cost_mismatch,
        unmatched_refunds=unmatched_refunds,
        cost=cost_value,
        cost_currency=cost_currency,
        cost_allocation=cost_allocation,
        roi=roi,
    )


def _count_summary(
    outcomes: list[dict[str, Any]],
    totals: dict[tuple[str, str | None, str | None, str | None], AllocationTotals],
) -> CountSummary:
    """Calculate aggregate attribution counts."""
    eligible = sum((_event_count(event) for event in outcomes), 0)
    attributed = sum(total.outcome_count for key, total in totals.items() if key[0] in {"touchpoint", "direct_observed"})
    uncertain = sum(total.outcome_count for key, total in totals.items() if key[0] == "identity_uncertain")
    return CountSummary(eligible=eligible, attributed=attributed, identity_uncertain=uncertain)


def _privacy_size(outcomes: list[dict[str, Any]], canonical_by_alias: dict[str, str]) -> int:
    """Return a conservative distinct-subject or pre-aggregated cell size."""
    total = AllocationTotals()
    for outcome in outcomes:
        total.observe(outcome, _event_count(outcome), canonical_by_alias)
    return total.privacy_size


def _late_event_count(outcomes: list[dict[str, Any]], lookback_seconds: int) -> int:
    """Count outcomes observed after one attribution lookback period."""
    delay = timedelta(seconds=lookback_seconds)
    return sum(
        int(
            parse_datetime(event["source"]["observed_at"], "source observed_at")
            - parse_datetime(event["event"]["occurred_at"], "outcome occurred_at")
            > delay
        )
        for event in outcomes
    )


def _is_provisional(
    snapshot: OptimizationSnapshot,
    outcomes: list[dict[str, Any]],
    refund_maturity_seconds: int,
) -> bool:
    """Return whether the most recent outcome remains inside refund maturity."""
    if not outcomes:
        return False
    outcome_times = [parse_datetime(event["event"]["occurred_at"], "outcome occurred_at") for event in outcomes]
    maturity = max(outcome_times) + timedelta(seconds=refund_maturity_seconds)
    return maturity > parse_datetime(snapshot.as_of, "snapshot as_of")


def _validate_snapshot_scope(snapshot: OptimizationSnapshot, request: AttributionRequest) -> None:
    """Reject explicit attribution labels over a broader input snapshot."""
    if request.account_ref is not None and (
        any(event["source"]["account_ref"] != request.account_ref for event in snapshot.events)
        or any(source["account_ref"] != request.account_ref for source in snapshot.sources)
    ):
        raise OptimizationError("attribution snapshot contains events outside its requested account scope")
    if request.campaign_id is not None and any(
        event["scope"]["campaign_id"] != request.campaign_id for event in snapshot.events
    ):
        raise OptimizationError("attribution snapshot contains events outside its requested campaign scope")


def build_attribution(snapshot: OptimizationSnapshot, request: AttributionRequest) -> dict[str, Any]:
    """Build one replay-safe, aggregate attribution projection."""
    _validate_request(request)
    _validate_snapshot_scope(snapshot, request)
    outcomes = _outcomes(snapshot, request)
    canonical_by_alias = canonical_subject_map(snapshot.subjects)
    totals = _allocation_totals(
        outcomes,
        _touchpoints(snapshot, request),
        request,
        canonical_by_alias,
    )
    counts = _count_summary(outcomes, totals)
    values = _value_summary(snapshot, outcomes, request)
    suppressed = _privacy_size(outcomes, canonical_by_alias) < request.minimum_cell_size
    allocations, suppressed_allocations = render_allocations(totals, request.minimum_cell_size, values.currency_mismatch)
    source_reasons, missing_scopes = source_quality(snapshot)
    late_events = _late_event_count(outcomes, request.lookback_seconds)
    provisional = _is_provisional(snapshot, outcomes, request.refund_maturity_seconds)
    conditions = UncertaintyConditions(
        suppressed=suppressed,
        identity_uncertain=counts.identity_uncertain,
        currency_mismatch=values.currency_mismatch,
        late_events=late_events,
        unmatched_refunds=values.unmatched_refunds,
        provisional=provisional,
    )
    reasons = uncertainty_reasons(
        source_reasons,
        conditions,
    )
    earliest_outcome = min(
        outcomes,
        key=lambda event: (
            parse_datetime(event["event"]["occurred_at"], "outcome occurred_at"),
            event["record_ref"],
        ),
        default=None,
    )
    body: dict[str, Any] = {
        "schema_version": 1,
        "run": {
            "analysis_version": 1,
            "input_snapshot_sha256": snapshot.digest,
            "as_of": snapshot.as_of,
            "generated_at": snapshot.as_of,
            "status": analysis_status(outcomes, suppressed, reasons),
        },
        "scope": {
            "account_ref": derived_account(snapshot, request.account_ref),
            "campaign_id": derived_scope(snapshot, request.campaign_id, "campaign_id"),
            "outcome_metric_id": request.outcome_metric_id,
            "currency": values.currency,
        },
        "model": {
            "id": request.model,
            "version": request.model_version,
            "lookback_seconds": request.lookback_seconds,
            "include_view_through": request.include_view_through,
            "tie_break": "occurred_at_then_record_ref",
        },
        "window": {
            "outcome_start": earliest_outcome["event"]["occurred_at"] if earliest_outcome else None,
            "outcome_end": snapshot.as_of,
            "refund_maturity_seconds": request.refund_maturity_seconds,
            "maturity": maturity(outcomes, provisional),
        },
        "outcomes": outcome_document(outcomes, counts, values, suppressed),
        "costs": cost_document(values, suppressed),
        "allocations": allocations,
        "coverage": {
            "fraction": visible(wire_number(divide(Decimal(counts.attributed), Decimal(counts.eligible))), suppressed),
            "minimum_cell_size": request.minimum_cell_size,
            "suppressed_allocations": visible(suppressed_allocations, suppressed),
            "late_events": visible(late_events, suppressed),
            "unmatched_refunds": visible(values.unmatched_refunds, suppressed),
            "missing_scopes": missing_scopes,
        },
        "uncertainty": {"data_confidence": confidence(outcomes, reasons), "reasons": reasons},
        "causal_assessment": {
            "status": "observational_only",
            "statement": ATTRIBUTION_CAUSAL_STATEMENT,
        },
        "provenance": {
            "source_snapshot_refs": [snapshot.digest],
            "evidence_refs": evidence_refs(snapshot),
            "supersedes": request.supersedes,
        },
    }
    body["attribution_ref"] = typed_reference("mkt-attribution-v1", body)
    return body
