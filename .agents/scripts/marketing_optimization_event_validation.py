#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict validation for persisted normalized marketing performance events."""

from __future__ import annotations

import re
from typing import Any

from marketing_optimization_contract import (
    EVIDENCE_REF_RE,
    EVENT_REF_RE,
    RECORD_REF_RE,
    SUBJECT_REF_RE,
    identity_is_uncertain,
)
from marketing_optimization_event_quality import validate_event_quality
from marketing_optimization_event_measurement import validate_measurement
from marketing_optimization_event_validation_common import nullable_timestamp, object_fields
from performance_contract import (
    COMPLETENESS,
    EVENT_TYPES,
    IDENTITY_STATES,
    MAX_SAFE_JSON_INTEGER,
    PUBLIC_DIMENSION_KEYS,
    SOURCE_KINDS,
    SUBJECT_KINDS,
    PerformanceContractError,
    normalize_dimensions,
    optional_alias,
    parse_timestamp,
    require_alias,
)

DIMENSION_REF_RE = re.compile(r"^mkt-dim-v1:[a-f0-9]{64}$")
ELIGIBILITY_REASONS = {
    "eligible",
    "aggregate",
    "consent_unknown",
    "consent_denied",
    "suppressed",
    "identity_ambiguous",
    "subject_ineligible",
}


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
    source = object_fields(value, "event.source", fields)
    if source["kind"] not in SOURCE_KINDS:
        raise PerformanceContractError("event.source.kind is unsupported")
    require_alias(source["account_ref"], "event.source.account_ref")
    revision = source["revision"]
    if isinstance(revision, bool) or not isinstance(revision, int) or not 1 <= revision <= MAX_SAFE_JSON_INTEGER:
        raise PerformanceContractError("event.source.revision must be a bounded positive integer")
    parse_timestamp(source["observed_at"], "event.source.observed_at")
    parse_timestamp(source["recorded_at"], "event.source.recorded_at")
    nullable_timestamp(source["source_observed_at"], "event.source.source_observed_at")
    nullable_timestamp(source["source_recorded_at"], "event.source.source_recorded_at")
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
    event = object_fields(value, "event.event", {"type", "occurred_at", "correction_of"})
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
    subject = object_fields(value, "event.subject", {"subject_id", "kind", "identity_state"})
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
    scope = object_fields(value, "event.scope", fields)
    for field in fields - {"dimensions"}:
        optional_alias(scope[field], f"event.scope.{field}")
    dimensions = normalize_dimensions(scope["dimensions"], "event.scope.dimensions")
    for key, item in dimensions.items():
        if key not in PUBLIC_DIMENSION_KEYS and (not isinstance(item, str) or not DIMENSION_REF_RE.fullmatch(item)):
            raise PerformanceContractError(f"event.scope.dimensions.{key} must be pseudonymized")
        if key in PUBLIC_DIMENSION_KEYS and isinstance(item, str):
            require_alias(item, f"event.scope.dimensions.{key}")


def _governance(value: Any, identity_state: str) -> None:
    """Validate the aggregate-safe audience eligibility projection."""
    governance = object_fields(value, "event.governance", {"audience_eligible", "eligibility_reason"})
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
    event = object_fields(value, "event", fields)
    if event["schema_version"] != 1 or not RECORD_REF_RE.fullmatch(str(event["record_ref"])):
        raise PerformanceContractError("event record reference is invalid")
    if not EVENT_REF_RE.fullmatch(str(event["event_ref"])):
        raise PerformanceContractError("event reference is invalid")
    source, evidence_ref = _source(event["source"])
    event_type = _event(event["event"])
    identity_state = _subject(event["subject"])
    _scope(event["scope"])
    validate_measurement(event["measurement"], event_type)
    validate_event_quality(event["quality"], source, evidence_ref)
    _governance(event["governance"], identity_state)
    return event
