#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Scalar and timestamp helpers for performance contracts."""

from __future__ import annotations

import math
import re
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any

from _performance_contract_definitions import (
    ALIAS_RE, CONTROL_RE, DIRECT_DIMENSION_VALUE_RE, MAX_SAFE_JSON_INTEGER,
    PHONE_CANDIDATE_RE, TIMESTAMP_RE, VANITY_PHONE_RE, PerformanceContractError,
)


def utc_now() -> str:
    """Return a canonical UTC timestamp."""
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_timestamp(value: Any, field: str) -> str:
    """Validate and canonicalize one RFC3339 UTC timestamp."""
    if not isinstance(value, str) or not TIMESTAMP_RE.fullmatch(value):
        raise PerformanceContractError(f"{field} must be an RFC3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise PerformanceContractError(f"{field} must be an RFC3339 UTC timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() != timezone.utc.utcoffset(parsed):
        raise PerformanceContractError(f"{field} must use UTC")
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def timestamp_epoch(value: str) -> float:
    """Convert a validated timestamp to a UTC epoch."""
    return datetime.fromisoformat(value[:-1] + "+00:00").timestamp()


def contains_direct_identifier(value: str) -> bool:
    """Detect contact destinations in bounded public values."""
    if DIRECT_DIMENSION_VALUE_RE.search(value) or VANITY_PHONE_RE.search(value):
        return True
    return any(
        10 <= len(re.sub(r"[^0-9]", "", candidate)) <= 15
        for candidate in PHONE_CANDIDATE_RE.findall(value)
    )


def require_alias(value: Any, field: str) -> str:
    """Require a bounded local alias safe for normalized output and paths."""
    valid_text = isinstance(value, str) and bool(ALIAS_RE.fullmatch(value))
    if not valid_text or contains_direct_identifier(value):
        raise PerformanceContractError(f"{field} must be a bounded lowercase alias")
    return value


def require_private_ref(value: Any, field: str) -> str:
    """Require an in-memory source reference that will be pseudonymized."""
    valid_text = isinstance(value, str) and bool(value) and len(value) <= 512
    if not valid_text or CONTROL_RE.search(value):
        raise PerformanceContractError(f"{field} must be a bounded source reference")
    return value


def optional_alias(value: Any, field: str) -> str | None:
    """Normalize one optional safe alias."""
    return None if value is None else require_alias(value, field)


def _as_decimal(value: Any, field: str) -> Decimal:
    if isinstance(value, bool):
        raise PerformanceContractError(f"{field} must be numeric")
    try:
        number = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise PerformanceContractError(f"{field} must be numeric") from exc
    finite_float = not isinstance(value, float) or math.isfinite(value)
    if not number.is_finite() or not finite_float:
        raise PerformanceContractError(f"{field} must be finite")
    return number


def _bounded_decimal(number: Decimal, field: str) -> str:
    if len(number.as_tuple().digits) > 128 or (number and abs(number.adjusted()) > 128):
        raise PerformanceContractError(f"{field} exceeds the decimal precision limit")
    normalized = format(number, "f")
    if "." in normalized:
        normalized = normalized.rstrip("0").rstrip(".")
    normalized = "0" if normalized in {"-0", ""} else normalized
    if len(normalized) > 128:
        raise PerformanceContractError(f"{field} exceeds the decimal precision limit")
    return normalized


def _require_exact_json_number(normalized: str, original: Any, field: str) -> None:
    if "." not in normalized:
        if abs(int(normalized)) > MAX_SAFE_JSON_INTEGER:
            raise PerformanceContractError(f"{field} exceeds the exact JSON integer range")
        return
    if isinstance(original, str):
        return
    rendered = float(normalized)
    if not math.isfinite(rendered) or Decimal(str(rendered)) != Decimal(normalized):
        raise PerformanceContractError(f"{field} cannot be represented as an exact JSON number")


def decimal_text(value: Any, field: str) -> str:
    """Return a finite canonical decimal string without exponent notation."""
    normalized = _bounded_decimal(_as_decimal(value, field), field)
    _require_exact_json_number(normalized, value, field)
    return normalized


def decimal_json(value: str) -> int | Decimal:
    """Render one canonical decimal string as an exact JSON-number value."""
    return int(value) if "." not in value else Decimal(value)


def decimal_wire(value: str) -> int | str:
    """Render exact normalized wire values without binary decimal rounding."""
    return int(value) if "." not in value else value
