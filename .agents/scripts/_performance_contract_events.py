#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Event and batch normalization for marketing performance contracts."""

from __future__ import annotations

import re
from copy import deepcopy
from decimal import Decimal
from typing import Any

from _performance_contract_definitions import (
    AGGREGATIONS,
    EVENT_TYPES,
    MAX_SAFE_JSON_INTEGER,
    METRIC_CONTRACTS,
    METRIC_DEFINITIONS,
    METRIC_RE,
    UNITS,
    PerformanceContractError,
)
from _performance_contract_values import (
    decimal_text,
    parse_timestamp,
    require_private_ref,
    timestamp_epoch,
)
from _performance_contract_subjects import (
    normalize_scope as _normalize_scope,
    normalize_subject as _normalize_subject,
    validate_batch_header as validate_batch_header,
)
from _performance_contract_governance import (
    normalize_governance as _normalize_governance,
    normalize_quality as _normalize_quality,
    validate_unsubscribe as _validate_unsubscribe,
)


def _metric_id(metric_id: Any) -> str:
    if not isinstance(metric_id, str) or not METRIC_RE.fullmatch(metric_id):
        raise PerformanceContractError("event.measurement.metric_id is invalid")
    return metric_id


def _measurement_unit(unit: Any) -> str:
    if not isinstance(unit, str) or unit not in UNITS:
        raise PerformanceContractError("event.measurement.unit is unsupported")
    return unit


def _measurement_aggregation(aggregation: Any) -> str:
    if not isinstance(aggregation, str) or aggregation not in AGGREGATIONS:
        raise PerformanceContractError("event.measurement.aggregation is unsupported")
    return aggregation


def _measurement_contract(metric_id: Any, event_type: str, unit: Any, aggregation: Any) -> tuple[str, str, str]:
    metric_id = _metric_id(metric_id)
    unit = _measurement_unit(unit)
    aggregation = _measurement_aggregation(aggregation)
    contract = METRIC_CONTRACTS.get(metric_id)
    if contract is None:
        raise PerformanceContractError("event.measurement.metric_id is unsupported")
    event_types, expected_unit, aggregations = contract
    if event_type != "correction" and event_type not in event_types:
        raise PerformanceContractError("event type does not match metric identity")
    if unit != expected_unit:
        raise PerformanceContractError("measurement unit does not match metric identity")
    if aggregation not in aggregations:
        raise PerformanceContractError("measurement aggregation does not match metric identity")
    return metric_id, unit, aggregation


def _measurement_currency(measurement: dict[str, Any], unit: str) -> Any:
    currency = measurement.get("currency")
    if unit == "currency":
        if not isinstance(currency, str) or not re.fullmatch(r"[A-Z]{3}", currency):
            raise PerformanceContractError("currency measurements require an ISO currency")
    elif currency is not None:
        raise PerformanceContractError("non-currency measurements cannot carry currency")
    return currency


def _measurement_period(measurement: dict[str, Any]) -> tuple[str | None, str | None]:
    start_raw = measurement.get("period_start")
    end_raw = measurement.get("period_end")
    if (start_raw is None) != (end_raw is None):
        raise PerformanceContractError("measurement periods require both start and end")
    if start_raw is None:
        return None, None
    start = parse_timestamp(start_raw, "event.measurement.period_start")
    end = parse_timestamp(end_raw, "event.measurement.period_end")
    if timestamp_epoch(start) > timestamp_epoch(end):
        raise PerformanceContractError("measurement period start must not follow end")
    return start, end


def _normalize_measurement(measurement: Any, event_type: str) -> dict[str, Any]:
    if not isinstance(measurement, dict):
        raise PerformanceContractError("event.measurement must be an object")
    metric_id, unit, aggregation = _measurement_contract(
        measurement.get("metric_id"), event_type, measurement.get("unit"), measurement.get("aggregation", "sum")
    )
    start, end = _measurement_period(measurement)
    return {
        "metric_id": metric_id,
        "value": decimal_text(measurement.get("value"), "event.measurement.value"),
        "unit": unit,
        "aggregation": aggregation,
        "currency": _measurement_currency(measurement, unit),
        "period_start": start,
        "period_end": end,
    }


def _event_revision(event: dict[str, Any]) -> int:
    revision = event.get("revision", 1)
    bounded_revision = isinstance(revision, int) and not isinstance(revision, bool) and 1 <= revision <= MAX_SAFE_JSON_INTEGER
    if not bounded_revision:
        raise PerformanceContractError("event.revision must be a bounded positive integer")
    return revision


def _event_type(event: dict[str, Any]) -> str:
    event_type = event.get("event_type")
    if not isinstance(event_type, str) or event_type not in EVENT_TYPES:
        raise PerformanceContractError("event.event_type is unsupported")
    return event_type


def _correction_reference(event: dict[str, Any], event_type: str, source_event_id: str) -> Any:
    correction_of = event.get("correction_of")
    if correction_of is not None:
        correction_of = require_private_ref(correction_of, "event.correction_of")
    if event_type == "correction" and correction_of is None:
        raise PerformanceContractError("correction events require correction_of")
    if event_type != "correction" and correction_of is not None:
        raise PerformanceContractError("only correction events may carry correction_of")
    if correction_of == source_event_id:
        raise PerformanceContractError("correction events cannot correct themselves")
    return correction_of


def _event_identity(event: dict[str, Any]) -> tuple[str, int, str, Any]:
    source_event_id = require_private_ref(event.get("source_event_id"), "event.source_event_id")
    revision = _event_revision(event)
    event_type = _event_type(event)
    correction_of = _correction_reference(event, event_type, source_event_id)
    return source_event_id, revision, event_type, correction_of


def _optional_timestamp(event: dict[str, Any], name: str) -> str | None:
    value = event.get(name)
    return None if value is None else parse_timestamp(value, f"event.{name}")


def validate_event(event: Any, batch_coverage: str, missing_scopes: list[str] | None = None) -> dict[str, Any]:
    """Normalize one adapter event while retaining private refs only in memory."""
    if not isinstance(event, dict):
        raise PerformanceContractError("event must be an object")
    source_event_id, revision, event_type, correction_of = _event_identity(event)
    occurred_at = parse_timestamp(event.get("occurred_at"), "event.occurred_at")
    subject = _normalize_subject(event.get("subject"))
    measurement = _normalize_measurement(event.get("measurement"), event_type)
    negative_disallowed = Decimal(measurement["value"]) < 0 and event_type != "correction" and measurement["unit"] != "ratio"
    if negative_disallowed:
        raise PerformanceContractError("non-correction count and currency values cannot be negative")
    effective_coverage = "partial" if missing_scopes else batch_coverage
    governance = _normalize_governance(event.get("governance"), subject["kind"])
    if event_type == "unsubscribe":
        _validate_unsubscribe(governance, occurred_at)
    return {
        "source_event_id": source_event_id,
        "revision": revision,
        "event_type": event_type,
        "occurred_at": occurred_at,
        "source_observed_at": _optional_timestamp(event, "source_observed_at"),
        "source_recorded_at": _optional_timestamp(event, "source_recorded_at"),
        "correction_of": correction_of,
        "subject": subject,
        "scope": _normalize_scope(event.get("scope")),
        "measurement": measurement,
        "quality": _normalize_quality(event.get("quality"), effective_coverage),
        "governance": governance,
    }


def event_for_fingerprint(event: dict[str, Any]) -> dict[str, Any]:
    """Return a detached deterministic event payload for conflict checks."""
    payload = deepcopy(event)
    if not payload["scope"].get("dimensions"):
        payload["scope"].pop("dimensions", None)
    return payload


def metric_definition(metric_id: str, unit: str) -> dict[str, Any]:
    """Build stable Phase 1 metric metadata for one normalized measurement."""
    fallback_kind = "currency" if unit == "currency" else "ratio" if unit == "ratio" else "count"
    label, kind, description = METRIC_DEFINITIONS.get(
        metric_id,
        (metric_id.rsplit(".", 1)[-1].replace("_", " ").title(), fallback_kind, "Provider-neutral normalized marketing outcome"),
    )
    return {"id": metric_id, "label": label, "description": description, "domain": "marketing", "kind": kind, "owner": "performance-plane", "version": 1}


def metric_event_type(metric_id: str) -> str:
    """Return the canonical non-correction event type for one v1 metric."""
    contract = METRIC_CONTRACTS.get(metric_id)
    if contract is None:
        raise PerformanceContractError("legacy metric identity is unsupported")
    return sorted(contract[0])[0]
