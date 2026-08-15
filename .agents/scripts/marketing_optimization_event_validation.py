#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict validation for persisted normalized marketing performance events."""

from __future__ import annotations

import re
from decimal import Decimal
from typing import Any

from marketing_optimization_contract import (
    EVIDENCE_REF_RE,
    EVENT_REF_RE,
    RECORD_REF_RE,
    SUBJECT_REF_RE,
    identity_is_uncertain,
)
from marketing_optimization_event_quality import validate_event_quality
from performance_contract import (
    AGGREGATIONS,
    COMPLETENESS,
    EVENT_TYPES,
    IDENTITY_STATES,
    MAX_SAFE_JSON_INTEGER,
    METRIC_CONTRACTS,
    PUBLIC_DIMENSION_KEYS,
    SOURCE_KINDS,
    SUBJECT_KINDS,
    UNITS,
    PerformanceContractError,
    decimal_text,
    normalize_dimensions,
    optional_alias,
    parse_timestamp,
    require_alias,
    timestamp_epoch,
)

DIMENSION_REF_RE = re.compile(r"^mkt-dim-v1:[a-f0-9]{64}$")
CURRENCY_RE = re.compile(r"^[A-Z]{3}$")
ELIGIBILITY_REASONS = {
    "eligible",
    "aggregate",
    "consent_unknown",
    "consent_denied",
    "suppressed",
    "identity_ambiguous",
    "subject_ineligible",
}


def _object(value: Any, label: str, required: set[str], optional: set[str] | None = None) -> dict[str, Any]:
    """Require one object with no missing or undeclared fields."""
    if not isinstance(value, dict):
        raise PerformanceContractError(f"{label} must be an object")
    missing = required - set(value)
    extras = set(value) - required - (optional or set())
    if missing or extras:
        raise PerformanceContractError(f"{label} fields do not match the normalized event contract")
    return value


def _timestamp(value: Any, label: str) -> str | None:
    """Validate one nullable canonical timestamp."""
    return None if value is None else parse_timestamp(value, label)


def _source(value: Any) -> tuple[dict[str, Any], str]:
    """Validate normalized source provenance and return its evidence reference."""
    fields = {
        "kind",
        "account_ref",
        "revision",
        "observed_at",
        "recorded_at",
        "source_observed_at",
        "source_recorded_at",
        "evidence_ref",
        "coverage",
        "missing_scopes",
    }
    source = _object(value, "event.source", fields)
    if source["kind"] not in SOURCE_KINDS:
        raise PerformanceContractError("event.source.kind is unsupported")
    require_alias(source["account_ref"], "event.source.account_ref")
    revision = source["revision"]
    if isinstance(revision, bool) or not isinstance(revision, int) or not 1 <= revision <= MAX_SAFE_JSON_INTEGER:
        raise PerformanceContractError("event.source.revision must be a bounded positive integer")
    parse_timestamp(source["observed_at"], "event.source.observed_at")
    parse_timestamp(source["recorded_at"], "event.source.recorded_at")
    _timestamp(source["source_observed_at"], "event.source.source_observed_at")
    _timestamp(source["source_recorded_at"], "event.source.source_recorded_at")
    evidence_ref = str(source["evidence_ref"])
    if not EVIDENCE_REF_RE.fullmatch(evidence_ref):
        raise PerformanceContractError("event.source.evidence_ref is invalid")
    if source["coverage"] not in COMPLETENESS or not isinstance(source["missing_scopes"], list):
        raise PerformanceContractError("event.source coverage is invalid")
    missing_scopes = [require_alias(item, "event.source.missing_scopes[]") for item in source["missing_scopes"]]
    if len(missing_scopes) != len(set(missing_scopes)):
        raise PerformanceContractError("event.source.missing_scopes must be unique")
    return source, evidence_ref


def _event(value: Any) -> str:
    """Validate normalized event identity, time, and correction binding."""
    event = _object(value, "event.event", {"type", "occurred_at", "correction_of"})
    event_type = event["type"]
    if event_type not in EVENT_TYPES:
        raise PerformanceContractError("event.event.type is unsupported")
    parse_timestamp(event["occurred_at"], "event.event.occurred_at")
    correction = event["correction_of"]
    if correction is not None and not EVENT_REF_RE.fullmatch(str(correction)):
        raise PerformanceContractError("event.event.correction_of is invalid")
    if (event_type == "correction") != (correction is not None):
        raise PerformanceContractError("event correction binding is invalid")
    return str(event_type)


def _subject(value: Any) -> str:
    """Validate pseudonymous subject shape and aggregate consistency."""
    subject = _object(value, "event.subject", {"subject_id", "kind", "identity_state"})
    subject_id = subject["subject_id"]
    kind = subject["kind"]
    identity_state = subject["identity_state"]
    if subject_id is not None and not SUBJECT_REF_RE.fullmatch(str(subject_id)):
        raise PerformanceContractError("event.subject.subject_id is invalid")
    if kind not in SUBJECT_KINDS or identity_state not in IDENTITY_STATES:
        raise PerformanceContractError("event.subject state is unsupported")
    aggregate = kind == "aggregate"
    if aggregate != (subject_id is None) or aggregate != (identity_state == "not_applicable"):
        raise PerformanceContractError("aggregate subject identity is inconsistent")
    return str(identity_state)


def _scope(value: Any) -> None:
    """Validate output-bound aliases and privacy-safe dimensions."""
    fields = {"campaign_id", "channel", "creative_id", "touchpoint_id", "outcome_id", "dimensions"}
    scope = _object(value, "event.scope", fields)
    for field in fields - {"dimensions"}:
        optional_alias(scope[field], f"event.scope.{field}")
    dimensions = normalize_dimensions(scope["dimensions"], "event.scope.dimensions")
    for key, item in dimensions.items():
        if key not in PUBLIC_DIMENSION_KEYS and (not isinstance(item, str) or not DIMENSION_REF_RE.fullmatch(item)):
            raise PerformanceContractError(f"event.scope.dimensions.{key} must be pseudonymized")
        if key in PUBLIC_DIMENSION_KEYS and isinstance(item, str):
            require_alias(item, f"event.scope.dimensions.{key}")


def _measurement(value: Any, event_type: str) -> None:
    """Validate exact metric values, units, periods, and optional catalog rules."""
    required = {"metric_id", "value", "unit", "aggregation", "currency"}
    measurement = _object(value, "event.measurement", required, {"period_start", "period_end"})
    metric_id = measurement["metric_id"]
    if not isinstance(metric_id, str) or not re.fullmatch(r"marketing\.[a-z0-9_]+(?:\.[a-z0-9_]+)+", metric_id):
        raise PerformanceContractError("event.measurement.metric_id is invalid")
    unit = measurement["unit"]
    aggregation = measurement["aggregation"]
    if unit not in UNITS or aggregation not in AGGREGATIONS:
        raise PerformanceContractError("event.measurement unit or aggregation is unsupported")
    contract = METRIC_CONTRACTS.get(metric_id)
    if contract is not None:
        event_types, expected_unit, aggregations = contract
        if event_type != "correction" and event_type not in event_types:
            raise PerformanceContractError("event type does not match metric identity")
        if unit != expected_unit or aggregation not in aggregations:
            raise PerformanceContractError("measurement does not match metric identity")
    normalized_value = decimal_text(measurement["value"], "event.measurement.value")
    if Decimal(normalized_value) < 0 and event_type != "correction" and unit != "ratio":
        raise PerformanceContractError("non-correction count and currency values cannot be negative")
    currency = measurement["currency"]
    if (unit == "currency" and (not isinstance(currency, str) or not CURRENCY_RE.fullmatch(currency))) or (
        unit != "currency" and currency is not None
    ):
        raise PerformanceContractError("event.measurement currency is inconsistent")
    period_start = _timestamp(measurement.get("period_start"), "event.measurement.period_start")
    period_end = _timestamp(measurement.get("period_end"), "event.measurement.period_end")
    if (period_start is None) != (period_end is None):
        raise PerformanceContractError("measurement periods require both start and end")
    if period_start is not None and timestamp_epoch(period_start) > timestamp_epoch(str(period_end)):
        raise PerformanceContractError("measurement period start must not follow end")


def _governance(value: Any, identity_state: str) -> None:
    """Validate the aggregate-safe audience eligibility projection."""
    governance = _object(value, "event.governance", {"audience_eligible", "eligibility_reason"})
    eligible = governance["audience_eligible"]
    reason = governance["eligibility_reason"]
    if not isinstance(eligible, bool) or reason not in ELIGIBILITY_REASONS:
        raise PerformanceContractError("event.governance eligibility is invalid")
    if eligible != (reason == "eligible"):
        raise PerformanceContractError("event.governance eligibility is inconsistent")
    if identity_is_uncertain(identity_state) and (eligible or reason != "identity_ambiguous"):
        raise PerformanceContractError("uncertain event identity must be audience-ineligible")


def validate_normalized_event(value: Any) -> dict[str, Any]:
    """Validate every field consumed or re-emitted by optimization analyses."""
    fields = {"schema_version", "record_ref", "event_ref", "source", "event", "subject", "scope", "measurement", "quality", "governance"}
    event = _object(value, "event", fields)
    if event["schema_version"] != 1 or not RECORD_REF_RE.fullmatch(str(event["record_ref"])):
        raise PerformanceContractError("event record reference is invalid")
    if not EVENT_REF_RE.fullmatch(str(event["event_ref"])):
        raise PerformanceContractError("event reference is invalid")
    source, evidence_ref = _source(event["source"])
    event_type = _event(event["event"])
    identity_state = _subject(event["subject"])
    _scope(event["scope"])
    _measurement(event["measurement"], event_type)
    validate_event_quality(event["quality"], source, evidence_ref)
    _governance(event["governance"], identity_state)
    return event
