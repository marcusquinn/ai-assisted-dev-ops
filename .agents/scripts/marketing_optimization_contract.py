#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared deterministic contracts for marketing optimization projections."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, localcontext
from typing import Any

from performance_contract import (
    CONTROL_RE,
    DIRECT_DIMENSION_KEY_RE,
    METRIC_RE,
    PerformanceContractError,
    canonical_json,
    contains_direct_identifier,
    decimal_text,
    decimal_wire,
    parse_timestamp,
    require_alias,
)

RECORD_REF_RE = re.compile(r"^mkt-record-v1:[a-f0-9]{64}$")
EVENT_REF_RE = re.compile(r"^mkt-event-v1:[a-f0-9]{64}$")
SUBJECT_REF_RE = re.compile(r"^mkt-subj-v1:[a-f0-9]{64}$")
EVIDENCE_REF_RE = re.compile(r"^mkt-evidence-v1:sha256:[a-f0-9]{64}$")
SAFE_DIGEST_REF_RE = re.compile(r"^(?:sha256:[a-f0-9]{64}|mkt-[a-z0-9-]+-v[0-9]+:(?:sha256:)?[a-f0-9]{64})$")
SAFE_DECIMAL_RE = re.compile(r"^-?(?:0|[1-9][0-9]*)\.[0-9]*[1-9]$")
DECIMAL_FIELD_NAMES = {
    "absolute_effect",
    "adjusted_alpha",
    "allocation",
    "alpha",
    "baseline",
    "baseline_value",
    "confidence_interval_high",
    "confidence_interval_low",
    "coverage",
    "credit",
    "current_value",
    "denominator",
    "effect",
    "expected",
    "fraction",
    "gross_value",
    "harm_threshold",
    "interval_high",
    "interval_low",
    "lower",
    "metric_value",
    "minimum_detectable_effect",
    "minimum_practical_effect",
    "net_value",
    "numerator",
    "power",
    "refund_value",
    "relative_effect",
    "roi",
    "rollback_threshold",
    "target_value",
    "threshold",
    "upper",
    "value",
}
CONFIDENCE_ORDER = {"low": 0, "medium": 1, "high": 2, "verified": 3}
MINIMUM_AGGREGATE_CELL_SIZE = 10
MINIMUM_EXPERIMENT_SAMPLE_PER_VARIANT = 250
MINIMUM_EXPERIMENT_CONVERSIONS_PER_VARIANT = 10
MINIMUM_EXPERIMENT_RUNTIME_SECONDS = 604800
SOURCE_FRESHNESS_REASONS = frozenset({"stale_source", "unknown_source_freshness"})
SOURCE_COVERAGE_REASONS = frozenset({"missing_scopes", "partial_coverage", "unknown_coverage"})
UNCERTAIN_IDENTITY_STATES = frozenset({"ambiguous", "split"})


class OptimizationError(PerformanceContractError):
    """Raised when optimization evidence cannot be analysed safely."""


@dataclass(frozen=True)
class OptimizationSnapshot:
    """One deterministic aggregate-analysis input snapshot."""

    as_of: str
    events: tuple[dict[str, Any], ...]
    subjects: tuple[dict[str, Any], ...]
    sources: tuple[dict[str, Any], ...]
    digest: str


def require_object(value: Any, field: str) -> dict[str, Any]:
    """Require one JSON object."""
    if not isinstance(value, dict):
        raise OptimizationError(f"{field} must be an object")
    return value


def require_list(value: Any, field: str) -> list[Any]:
    """Require one JSON array."""
    if not isinstance(value, list):
        raise OptimizationError(f"{field} must be an array")
    return value


def require_metric(value: Any, field: str) -> str:
    """Require a stable marketing metric ID."""
    if not isinstance(value, str) or not METRIC_RE.fullmatch(value):
        raise OptimizationError(f"{field} must be a marketing metric ID")
    return value


def require_text(value: Any, field: str, maximum: int = 1024) -> str:
    """Require bounded text without direct identifiers or control bytes."""
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise OptimizationError(f"{field} must be bounded text")
    if CONTROL_RE.search(value) or contains_direct_identifier(value):
        raise OptimizationError(f"{field} cannot contain direct identifiers")
    return value


def require_integer(value: Any, field: str, minimum: int, maximum: int) -> int:
    """Require a bounded non-boolean integer."""
    if isinstance(value, bool) or not isinstance(value, int):
        raise OptimizationError(f"{field} must be an integer")
    if value < minimum or value > maximum:
        raise OptimizationError(f"{field} is outside the supported range")
    return value


def number(value: Any, field: str) -> Decimal:
    """Parse one exact bounded decimal."""
    return Decimal(decimal_text(value, field))


def wire_number(value: Decimal | int | str | None) -> int | str | None:
    """Render one exact number in the normalized wire representation."""
    if value is None:
        return None
    source: Decimal | int | str = str(value) if isinstance(value, Decimal) else value
    return decimal_wire(decimal_text(source, "derived value"))


def divide(numerator: Decimal, denominator: Decimal) -> Decimal | None:
    """Divide exactly when the denominator is non-zero."""
    if denominator == 0:
        return None
    with localcontext() as context:
        context.prec = 28
        return numerator / denominator


def digest_document(value: Any) -> str:
    """Return a canonical SHA-256 digest reference."""
    payload = canonical_json(value).encode("utf-8")
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def typed_reference(prefix: str, value: Any) -> str:
    """Return one deterministic typed reference."""
    digest = digest_document(value).split(":", 1)[1]
    return f"{prefix}:{digest}"


def parse_datetime(value: Any, field: str) -> datetime:
    """Return one validated UTC datetime."""
    timestamp = parse_timestamp(value, field)
    return datetime.fromisoformat(timestamp[:-1] + "+00:00")


def add_seconds(value: str, seconds: int) -> str:
    """Add seconds to one canonical UTC timestamp."""
    result = parse_datetime(value, "timestamp") + timedelta(seconds=seconds)
    return result.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def minimum_confidence(values: list[str]) -> str:
    """Return the lowest recognized confidence, failing closed for no evidence."""
    if not values:
        return "low"
    return min(values, key=lambda item: CONFIDENCE_ORDER.get(item, -1))


def identity_is_uncertain(identity_state: Any) -> bool:
    """Return whether one identity state cannot represent a distinct subject."""
    return identity_state in UNCERTAIN_IDENTITY_STATES


def source_is_stale(as_of: str, source: dict[str, Any]) -> bool:
    """Derive source staleness at the snapshot boundary without trusting flags."""
    observed_at = source.get("last_observed_at")
    if observed_at is None:
        return bool(source.get("stale") or source.get("status") == "stale")
    age_seconds = (
        parse_datetime(as_of, "snapshot as_of")
        - parse_datetime(observed_at, "source last_observed_at")
    ).total_seconds()
    threshold = int(source.get("stale_after_seconds", 0))
    return bool(
        source.get("stale")
        or source.get("status") == "stale"
        or (age_seconds >= 0 and age_seconds > threshold)
    )


def _timestamp_field(field_name: str) -> bool:
    """Return whether one output field is expected to contain a timestamp."""
    explicit_fields = {"period_start", "period_end", "started_at", "ended_at"}
    return field_name == "as_of" or field_name.endswith("_at") or field_name in explicit_fields


def _safe_timestamp(value: Any, field: str, field_name: str) -> bool:
    """Return whether one string is a valid timestamp in a timestamp field."""
    if not isinstance(value, str) or not _timestamp_field(field_name):
        return False
    try:
        parse_timestamp(value, field)
    except PerformanceContractError:
        return False
    return True


def _unsafe_identifier_text(value: Any, safe_decimal: bool, safe_timestamp: bool) -> bool:
    """Return whether one scalar contains a direct identifier."""
    if not isinstance(value, str):
        return False
    if SAFE_DIGEST_REF_RE.fullmatch(value):
        return False
    if safe_decimal or safe_timestamp:
        return False
    return contains_direct_identifier(value)


def assert_public_safe(value: Any, field: str = "document") -> None:
    """Reject direct identifiers recursively before durable output."""
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or DIRECT_DIMENSION_KEY_RE.search(key):
                raise OptimizationError(f"{field} contains a forbidden identifier field")
            assert_public_safe(item, f"{field}.{key}")
        return
    if isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            assert_public_safe(item, f"{field}[{index}]")
        return
    field_name = field.rsplit(".", 1)[-1]
    safe_decimal = field_name in DECIMAL_FIELD_NAMES and SAFE_DECIMAL_RE.fullmatch(str(value))
    safe_timestamp = _safe_timestamp(value, field, field_name)
    if _unsafe_identifier_text(value, bool(safe_decimal), safe_timestamp):
        raise OptimizationError(f"{field} cannot contain direct identifiers")


from marketing_optimization_snapshot_quality import snapshot_quality  # noqa: E402
