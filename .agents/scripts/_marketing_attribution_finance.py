#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Refund, cost, and currency aggregation for marketing attribution."""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from marketing_attribution_render import ValueSummary, selected_currency
from marketing_optimization_contract import (
    OptimizationError,
    OptimizationSnapshot,
    divide,
    number,
    parse_datetime,
)


def _currencies(events: list[dict[str, Any]]) -> set[str]:
    """Return non-null measurement currencies."""
    return {
        str(event["measurement"]["currency"])
        for event in events
        if event["measurement"].get("currency")
    }


def _refund_index(outcomes: list[dict[str, Any]]) -> dict[tuple[str, str, str | None, str], tuple[Any, str]]:
    """Index unique aggregate-safe outcome keys for refund matching."""
    indexed: dict[tuple[str, str, str | None, str], tuple[Any, str]] = {}
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
        if key in indexed:
            raise OptimizationError("attribution outcomes contain duplicate refund match keys")
        indexed[key] = (
            parse_datetime(event["event"]["occurred_at"], "outcome occurred_at"),
            str(event["measurement"]["currency"]),
        )
    return indexed


def _refund_key(event: dict[str, Any]) -> tuple[str, str, str | None, str]:
    """Return the aggregate-safe key used to match one refund."""
    return (
        event["source"]["kind"],
        event["source"]["account_ref"],
        event["scope"].get("campaign_id"),
        str(event["scope"].get("outcome_id")),
    )


def _matched_refunds(
    refunds: list[dict[str, Any]],
    outcomes: dict[tuple[str, str, str | None, str], tuple[Any, str]],
) -> tuple[list[dict[str, Any]], bool]:
    """Match chronological refunds and report currency disagreement."""
    matched: list[dict[str, Any]] = []
    currency_mismatch = False
    for event in refunds:
        outcome = outcomes.get(_refund_key(event))
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
    return matched, currency_mismatch


def _refund_summary(
    snapshot: OptimizationSnapshot,
    outcomes: list[dict[str, Any]],
) -> tuple[Decimal, int, list[dict[str, Any]], bool]:
    """Sum refunds matched by aggregate-safe outcome ID."""
    if not outcomes or any(event["measurement"]["unit"] != "currency" for event in outcomes):
        return Decimal(0), 0, [], False
    refunds = [
        event
        for event in snapshot.events
        if event["event"]["type"] == "refund" and event["measurement"]["unit"] == "currency"
    ]
    matched, currency_mismatch = _matched_refunds(refunds, _refund_index(outcomes))
    value = sum((number(event["measurement"]["value"], "refund value") for event in matched), Decimal(0))
    return value, len(refunds) - len(matched), matched, currency_mismatch


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


def value_summary(
    snapshot: OptimizationSnapshot,
    outcomes: list[dict[str, Any]],
    requested_currency: str | None,
) -> ValueSummary:
    """Calculate exact aggregate values and explicit currency mismatch state."""
    units = {str(event["measurement"]["unit"]) for event in outcomes}
    if len(units) > 1:
        raise OptimizationError("attribution outcomes contain incompatible measurement units")
    if requested_currency is not None and outcomes and units != {"currency"}:
        raise OptimizationError("currency filters cannot be applied to non-currency outcomes")
    gross_value = sum((number(event["measurement"]["value"], "outcome value") for event in outcomes), Decimal(0))
    refund_value, unmatched_refunds, matched_refunds, refund_mismatch = _refund_summary(snapshot, outcomes)
    currencies = _currencies(outcomes + matched_refunds)
    currency = selected_currency(currencies, requested_currency)
    currency_mismatch = refund_mismatch or len(currencies) > 1
    currency_mismatch = currency_mismatch or bool(
        requested_currency and currencies and currencies != {requested_currency}
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
