#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Explicit, replayable Phase 1 marketing-result backfill adapter."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

from performance_contract import (
    METRIC_CONTRACTS,
    PerformanceContractError,
    canonical_json,
    metric_event_type,
    normalize_dimensions,
    parse_timestamp,
    require_alias,
    require_private_ref,
)


def _records(raw_bytes: bytes) -> list[Any]:
    try:
        text = raw_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PerformanceContractError("Phase 1 backfill input must be UTF-8") from exc
    stripped = text.strip()
    if not stripped:
        raise PerformanceContractError("Phase 1 backfill input is empty")
    if stripped.startswith("["):
        try:
            document = json.loads(stripped, parse_float=Decimal)
        except (json.JSONDecodeError, InvalidOperation, ValueError) as exc:
            raise PerformanceContractError("Phase 1 backfill array is invalid JSON") from exc
        if not isinstance(document, list):
            raise PerformanceContractError("Phase 1 backfill array is invalid")
        return document
    output: list[Any] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            output.append(json.loads(line, parse_float=Decimal))
        except (json.JSONDecodeError, InvalidOperation, ValueError):
            output.append(None)
    return output


def _scope(subject: dict[str, Any], dimensions: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    subject_type = subject.get("type")
    if not isinstance(subject_type, str):
        raise PerformanceContractError("phase1.subject.type must be a string")
    subject_ref = require_private_ref(subject.get("id"), "phase1.subject.id")
    scope = {
        "campaign_id": None,
        "channel": None,
        "creative_id": None,
        "touchpoint_id": None,
        "outcome_id": None,
        "dimensions": {},
    }
    if subject_type == "campaign":
        scope["campaign_id"] = require_alias(subject_ref, "phase1.subject.id")
        normalized_subject = {
            "kind": "aggregate",
            "identity_state": "not_applicable",
            "source_ref": None,
            "candidate_refs": [],
        }
    else:
        kind = subject_type if subject_type in {"account", "audience"} else "anonymous"
        normalized_subject = {
            "kind": kind,
            "identity_state": "isolated",
            "source_ref": subject_ref,
            "candidate_refs": [],
        }
    for field in ("channel", "creative_id", "touchpoint_id", "outcome_id"):
        value = dimensions.get(field)
        if value is not None:
            scope[field] = require_alias(value, f"phase1.dimensions.{field}")
    reserved = {
        "channel",
        "creative_id",
        "touchpoint_id",
        "outcome_id",
        "currency",
    }
    scope["dimensions"] = normalize_dimensions(
        {
            key: value
            for key, value in dimensions.items()
            if key not in reserved
        },
        "phase1.dimensions",
    )
    return scope, normalized_subject


def _measurement(
    metric_id: str,
    raw: dict[str, Any],
    dimensions: dict[str, Any],
) -> dict[str, Any]:
    contract = METRIC_CONTRACTS.get(metric_id)
    if contract is None:
        raise PerformanceContractError("Phase 1 metric is not a supported marketing metric")
    expected_unit = contract[1]
    source_unit = raw.get("unit")
    currency = dimensions.get("currency")
    if expected_unit == "currency":
        if isinstance(source_unit, str) and len(source_unit) == 3 and source_unit.isalpha():
            currency = source_unit.upper()
            source_unit = "currency"
        if isinstance(currency, str):
            currency = currency.upper()
    if source_unit != expected_unit:
        raise PerformanceContractError("Phase 1 measurement unit does not match its metric")
    aggregation = raw.get("aggregation")
    if not isinstance(aggregation, str) or aggregation not in contract[2]:
        raise PerformanceContractError("Phase 1 aggregation is unsupported for its metric")
    period_start = raw.get("period_start")
    period_end = raw.get("period_end")
    if period_start is not None:
        period_start = parse_timestamp(period_start, "phase1.measurement.period_start")
    if period_end is not None:
        period_end = parse_timestamp(period_end, "phase1.measurement.period_end")
    return {
        "metric_id": metric_id,
        "value": raw.get("value"),
        "unit": source_unit,
        "aggregation": aggregation,
        "currency": currency,
        "period_start": period_start,
        "period_end": period_end,
    }


def _normalize_record(record: Any) -> tuple[dict[str, Any], str]:
    if not isinstance(record, dict) or record.get("schema_version") != 1:
        raise PerformanceContractError("Phase 1 record schema_version must be 1")
    metric = record.get("metric")
    subject = record.get("subject")
    dimensions = record.get("dimensions", {})
    measurement = record.get("measurement")
    quality = record.get("quality")
    if not all(isinstance(item, dict) for item in (metric, subject, dimensions, measurement, quality)):
        raise PerformanceContractError("Phase 1 record shape is invalid")
    metric_id = metric.get("id")
    if not isinstance(metric_id, str):
        raise PerformanceContractError("Phase 1 metric id is required")
    scope, normalized_subject = _scope(subject, dimensions)
    normalized_measurement = _measurement(metric_id, measurement, dimensions)
    observed_at = parse_timestamp(measurement.get("observed_at"), "phase1.measurement.observed_at")
    recorded_at = parse_timestamp(
        measurement.get("recorded_at", observed_at), "phase1.measurement.recorded_at"
    )
    occurred_at = parse_timestamp(
        measurement.get("source_event_at", observed_at), "phase1.measurement.source_event_at"
    )
    identity_scope = dict(scope)
    if not identity_scope["dimensions"]:
        identity_scope.pop("dimensions")
    identity = {
        "metric_id": metric_id,
        "subject": {"type": subject.get("type"), "id": subject.get("id")},
        "scope": identity_scope,
        "period_start": normalized_measurement["period_start"],
        "period_end": normalized_measurement["period_end"],
        "observed_at": observed_at,
    }
    source_event_id = "phase1-" + hashlib.sha256(canonical_json(identity).encode("utf-8")).hexdigest()
    source_type = quality.get("source_type", "manual")
    confidence = quality.get("confidence", "medium")
    event = {
        "source_event_id": source_event_id,
        "revision": record.get("revision", 1),
        "event_type": metric_event_type(metric_id),
        "occurred_at": occurred_at,
        "source_observed_at": observed_at,
        "source_recorded_at": recorded_at,
        "correction_of": None,
        "subject": normalized_subject,
        "scope": scope,
        "measurement": normalized_measurement,
        "quality": {
            "confidence": confidence,
            "completeness": "complete",
            "source_type": source_type,
            "collected_by": "phase1-backfill",
            "verified_by": "phase1-backfill" if confidence == "verified" else None,
        },
        "governance": {"consent": [], "suppression": None},
    }
    return event, recorded_at


def normalize_phase1_results(
    raw_bytes: bytes,
    path: Path,
    account_override: str | None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Convert explicit Phase 1 JSONL/array input into one replayable batch."""
    events: list[dict[str, Any]] = []
    recorded_times: list[str] = []
    errors: list[dict[str, Any]] = []
    for index, record in enumerate(_records(raw_bytes)):
        try:
            event, recorded_at = _normalize_record(record)
            events.append(event)
            recorded_times.append(recorded_at)
        except PerformanceContractError as exc:
            errors.append(
                {
                    "index": index,
                    "reason": str(exc),
                    "source_event_id": f"phase1-record-{index}",
                }
            )
    fallback = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(
        microsecond=0
    ).isoformat().replace("+00:00", "Z")
    return (
        {
            "source": "phase1",
            "account_ref": account_override or "phase1-backfill",
            "cursor": "sha256:" + hashlib.sha256(raw_bytes).hexdigest(),
            "observed_at": max(recorded_times, default=fallback),
            "coverage": "partial" if errors else "complete",
            "missing_scopes": ["legacy_record_errors"] if errors else [],
            "events": events,
        },
        errors,
    )
