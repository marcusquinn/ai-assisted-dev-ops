#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic correction resolution for optimization snapshots."""

from __future__ import annotations

import copy
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from marketing_optimization_contract import OptimizationError

EventValidator = Callable[[Any, int], dict[str, Any]]
OrderKey = Callable[[dict[str, Any]], tuple[Any, str]]


@dataclass(frozen=True)
class CorrectionContext:
    """Indexed correction state and trusted validation callbacks."""

    by_event_ref: dict[str, dict[str, Any]]
    corrected_refs: frozenset[str]
    validate_event: EventValidator
    order_key: OrderKey


def _index_events(events: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Index unique event and record identities."""
    by_event_ref: dict[str, dict[str, Any]] = {}
    record_refs: set[str] = set()
    for event in events:
        event_ref = str(event["event_ref"])
        record_ref = str(event["record_ref"])
        if event_ref in by_event_ref:
            raise OptimizationError("optimization snapshot contains duplicate event_ref values")
        if record_ref in record_refs:
            raise OptimizationError("optimization snapshot contains duplicate record_ref values")
        by_event_ref[event_ref] = event
        record_refs.add(record_ref)
    return by_event_ref


def _correction_semantics(event: dict[str, Any]) -> tuple[Any, ...]:
    """Return immutable identity and measurement semantics for correction matching."""
    measurement = {key: value for key, value in event["measurement"].items() if key != "value"}
    return (
        event["source"]["kind"],
        event["source"]["account_ref"],
        event["subject"],
        event["scope"],
        measurement,
    )


def _validate_correction_targets(
    events: list[dict[str, Any]],
    by_event_ref: dict[str, dict[str, Any]],
) -> frozenset[str]:
    """Require unique available targets with matching immutable semantics."""
    corrected_refs: set[str] = set()
    for event in events:
        target_ref = event["event"].get("correction_of")
        if target_ref is None:
            continue
        target_key = str(target_ref)
        target = by_event_ref.get(target_key)
        if target is None:
            raise OptimizationError("optimization snapshot correction target is unavailable")
        if target_key in corrected_refs:
            raise OptimizationError("optimization snapshot correction target is ambiguous")
        if _correction_semantics(event) != _correction_semantics(target):
            raise OptimizationError("optimization snapshot correction target semantics do not match")
        corrected_refs.add(target_key)
    return frozenset(corrected_refs)


def _resolved_semantics(
    event: dict[str, Any],
    by_event_ref: dict[str, dict[str, Any]],
    seen: frozenset[str],
) -> tuple[str, str]:
    """Resolve the original event type and economic occurrence time."""
    event_ref = str(event["event_ref"])
    if event_ref in seen:
        raise OptimizationError("optimization snapshot correction chain contains a cycle")
    if event["event"]["type"] != "correction":
        return str(event["event"]["type"]), str(event["event"]["occurred_at"])
    target = by_event_ref[str(event["event"]["correction_of"])]
    return _resolved_semantics(target, by_event_ref, seen | {event_ref})


def _validate_correction_chains(
    events: list[dict[str, Any]],
    by_event_ref: dict[str, dict[str, Any]],
) -> None:
    """Reject every cyclic correction chain before materialization."""
    for event in events:
        if event["event"]["type"] == "correction":
            _resolved_semantics(event, by_event_ref, frozenset())


def _materialize_effective_events(
    events: list[dict[str, Any]],
    context: CorrectionContext,
) -> list[dict[str, Any]]:
    """Suppress corrected rows and validate effective replacements."""
    output: list[dict[str, Any]] = []
    for event in events:
        if str(event["event_ref"]) in context.corrected_refs:
            continue
        if event["event"]["type"] != "correction":
            output.append(event)
            continue
        replacement = copy.deepcopy(event)
        event_type, occurred_at = _resolved_semantics(event, context.by_event_ref, frozenset())
        replacement["event"]["type"] = event_type
        replacement["event"]["occurred_at"] = occurred_at
        replacement["event"]["correction_of"] = None
        output.append(context.validate_event(replacement, len(output)))
    return sorted(output, key=context.order_key)


def effective_events(
    events: list[dict[str, Any]],
    validate_event: EventValidator,
    order_key: OrderKey,
) -> list[dict[str, Any]]:
    """Resolve corrections and reject duplicate identities in one snapshot."""
    by_event_ref = _index_events(events)
    corrected_refs = _validate_correction_targets(events, by_event_ref)
    _validate_correction_chains(events, by_event_ref)
    context = CorrectionContext(by_event_ref, corrected_refs, validate_event, order_key)
    return _materialize_effective_events(events, context)
