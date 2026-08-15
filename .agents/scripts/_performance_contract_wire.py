#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Dimension and exact JSON wire helpers for performance contracts."""

from __future__ import annotations

import json
from decimal import Decimal
from typing import Any

from _performance_contract_definitions import (
    CONTROL_RE, DIMENSION_KEY_RE, DIRECT_DIMENSION_KEY_RE,
    RESERVED_DIMENSION_KEYS, PerformanceContractError,
)
from _performance_contract_scalar import contains_direct_identifier, decimal_text


def _numeric_dimension(item: int | float | Decimal, field: str) -> int | float:
    normalized = decimal_text(item, field)
    if contains_direct_identifier(normalized):
        raise PerformanceContractError(f"{field} cannot contain direct identifiers")
    return int(normalized) if "." not in normalized else float(normalized)


def _text_dimension(item: str, field: str) -> str:
    bounded_text = isinstance(item, str) and 0 < len(item) <= 128
    if bounded_text and not CONTROL_RE.search(item):
        if contains_direct_identifier(item):
            raise PerformanceContractError(f"{field} cannot contain direct identifiers")
        return item
    raise PerformanceContractError(f"{field} must be a bounded scalar string, number, or boolean")


def _dimension_value(item: Any, field: str) -> str | int | float | bool:
    if isinstance(item, bool):
        return item
    if isinstance(item, (int, float, Decimal)):
        return _numeric_dimension(item, field)
    if isinstance(item, str):
        return _text_dimension(item, field)
    raise PerformanceContractError(f"{field} must be a bounded scalar string, number, or boolean")


def normalize_dimensions(value: Any, field: str) -> dict[str, str | int | float | bool]:
    """Normalize bounded Phase 1-compatible scalar dimensions."""
    if not isinstance(value, dict):
        raise PerformanceContractError(f"{field} must be an object")
    if len(value) > 32:
        raise PerformanceContractError(f"{field} exceeds 32 entries")
    output: dict[str, str | int | float | bool] = {}
    for key, item in sorted(value.items()):
        if not isinstance(key, str) or not DIMENSION_KEY_RE.fullmatch(key):
            raise PerformanceContractError(f"{field} keys must use bounded lower_snake_case")
        if key in RESERVED_DIMENSION_KEYS:
            raise PerformanceContractError(f"{field}.{key} must use its dedicated scope or measurement field")
        if DIRECT_DIMENSION_KEY_RE.search(key):
            raise PerformanceContractError(f"{field}.{key} cannot contain direct identifiers")
        output[key] = _dimension_value(item, f"{field}.{key}")
    return output


def _wire_mapping(value: dict[str, Any]) -> str:
    if not all(isinstance(key, str) for key in value):
        raise PerformanceContractError("JSON object keys must be strings")
    pairs = (f"{json.dumps(key, ensure_ascii=True)}:{wire_json(value[key])}" for key in sorted(value))
    return "{" + ",".join(pairs) + "}"


def _wire_primitive(value: Any) -> tuple[bool, str]:
    if value is None:
        result = "null"
    elif isinstance(value, bool):
        result = "true" if value else "false"
    elif isinstance(value, Decimal):
        if not value.is_finite():
            raise PerformanceContractError("JSON decimal must be finite")
        result = format(value, "f")
    elif isinstance(value, int):
        result = str(value)
    elif isinstance(value, float):
        result = json.dumps(value, allow_nan=False)
    elif isinstance(value, str):
        result = json.dumps(value, ensure_ascii=True)
    else:
        return False, ""
    return True, result


def wire_json(value: Any) -> str:
    """Serialize JSON while preserving Decimal values as exact number tokens."""
    primitive, result = _wire_primitive(value)
    if primitive:
        return result
    if isinstance(value, (list, tuple)):
        result = "[" + ",".join(wire_json(item) for item in value) + "]"
    elif isinstance(value, dict):
        result = _wire_mapping(value)
    else:
        raise PerformanceContractError("value is not JSON serializable")
    return result


def canonical_json(value: Any) -> str:
    """Serialize deterministic JSON used for immutable fingerprints."""
    return wire_json(value)
