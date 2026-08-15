#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Batch, subject, and scope normalization."""

from __future__ import annotations

from typing import Any

from _performance_contract_definitions import (
    COMPLETENESS, IDENTITY_STATES, SOURCE_KINDS, SUBJECT_KINDS,
    PerformanceContractError,
)
from _performance_contract_values import (
    normalize_dimensions, optional_alias, parse_timestamp, require_alias,
    require_private_ref,
)


def _batch_source(batch: dict[str, Any]) -> str:
    source = batch.get("source")
    if not isinstance(source, str) or source not in SOURCE_KINDS:
        raise PerformanceContractError("batch.source is unsupported")
    return source


def _batch_coverage(batch: dict[str, Any]) -> str:
    coverage = batch.get("coverage", "unknown")
    if not isinstance(coverage, str) or coverage not in COMPLETENESS:
        raise PerformanceContractError("batch.coverage is unsupported")
    return coverage


def _batch_cursor(batch: dict[str, Any]) -> str | None:
    cursor = batch.get("cursor")
    if cursor is not None:
        cursor = require_private_ref(cursor, "batch.cursor")
    return cursor


def _batch_missing_scopes(batch: dict[str, Any]) -> list[str]:
    missing_raw = batch.get("missing_scopes", [])
    if not isinstance(missing_raw, list):
        raise PerformanceContractError("batch.missing_scopes must be an array")
    return sorted({require_alias(item, "batch.missing_scopes[]") for item in missing_raw})


def _batch_events(batch: dict[str, Any]) -> list[Any]:
    events = batch.get("events")
    if not isinstance(events, list):
        raise PerformanceContractError("batch.events must be an array")
    return events


def validate_batch_header(batch: Any) -> dict[str, Any]:
    """Validate source/account isolation, freshness, and cursor metadata."""
    if not isinstance(batch, dict):
        raise PerformanceContractError("batch must be an object")
    source = _batch_source(batch)
    coverage = _batch_coverage(batch)
    cursor = _batch_cursor(batch)
    missing_scopes = _batch_missing_scopes(batch)
    events = _batch_events(batch)
    return {
        "source": source,
        "account_ref": require_alias(batch.get("account_ref"), "batch.account_ref"),
        "cursor": cursor,
        "observed_at": parse_timestamp(batch.get("observed_at"), "batch.observed_at"),
        "coverage": coverage,
        "missing_scopes": missing_scopes,
        "events": events,
    }


def _subject_references(subject: dict[str, Any]) -> tuple[Any, list[str]]:
    candidates_raw = subject.get("candidate_refs", [])
    if not isinstance(candidates_raw, list):
        raise PerformanceContractError("event.subject.candidate_refs must be an array")
    candidates = [require_private_ref(item, "event.subject.candidate_refs[]") for item in candidates_raw]
    return subject.get("source_ref"), candidates


def _aggregate_subject(state: str, source_ref: Any, candidates: list[str]) -> Any:
    if source_ref is not None or candidates or state != "not_applicable":
        raise PerformanceContractError("aggregate subjects cannot carry identity references")
    return source_ref


def _ambiguous_subject(source_ref: Any, candidates: list[str]) -> Any:
    if source_ref is not None or len(set(candidates)) < 2:
        raise PerformanceContractError("ambiguous subjects require at least two candidates")
    return source_ref


def _resolved_subject(source_ref: Any, candidates: list[str]) -> str:
    resolved = require_private_ref(source_ref, "event.subject.source_ref")
    if candidates:
        raise PerformanceContractError("resolved subjects cannot carry candidate refs")
    return resolved


def _validate_subject_identity(kind: str, state: str, source_ref: Any, candidates: list[str]) -> Any:
    if kind == "aggregate":
        return _aggregate_subject(state, source_ref, candidates)
    if state == "ambiguous":
        return _ambiguous_subject(source_ref, candidates)
    if state in {"linked", "split"}:
        raise PerformanceContractError("linked and split identity states require owner reconciliation")
    if state != "isolated":
        raise PerformanceContractError("resolved source subjects must be isolated")
    return _resolved_subject(source_ref, candidates)


def normalize_subject(subject: Any) -> dict[str, Any]:
    """Normalize a subject without exposing source identity references."""
    if not isinstance(subject, dict):
        raise PerformanceContractError("event.subject must be an object")
    kind = subject.get("kind")
    state = subject.get("identity_state")
    if not isinstance(kind, str) or kind not in SUBJECT_KINDS:
        raise PerformanceContractError("event.subject.kind is unsupported")
    if not isinstance(state, str) or state not in IDENTITY_STATES:
        raise PerformanceContractError("event.subject.identity_state is unsupported")
    source_ref, candidates = _subject_references(subject)
    source_ref = _validate_subject_identity(kind, state, source_ref, candidates)
    return {"kind": kind, "identity_state": state, "source_ref": source_ref, "candidate_refs": sorted(set(candidates))}


def normalize_scope(scope: Any) -> dict[str, Any]:
    """Normalize dedicated attribution scope fields and public dimensions."""
    scope = {} if scope is None else scope
    if not isinstance(scope, dict):
        raise PerformanceContractError("event.scope must be an object")
    allowed = {"campaign_id", "channel", "creative_id", "touchpoint_id", "outcome_id", "dimensions"}
    extras = set(scope) - allowed
    if extras:
        raise PerformanceContractError(f"event.scope has unsupported fields: {', '.join(sorted(extras))}")
    normalized = {
        field: optional_alias(scope.get(field), f"event.scope.{field}")
        for field in ("campaign_id", "channel", "creative_id", "touchpoint_id", "outcome_id")
    }
    normalized["dimensions"] = normalize_dimensions(scope.get("dimensions", {}), "event.scope.dimensions")
    return normalized
