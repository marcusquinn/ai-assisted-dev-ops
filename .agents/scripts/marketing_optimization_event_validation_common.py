#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared strict primitives for normalized event validation."""

from __future__ import annotations

from typing import Any

from performance_contract import PerformanceContractError, parse_timestamp


def object_fields(
    value: Any,
    label: str,
    required: set[str],
    optional: set[str] | None = None,
) -> dict[str, Any]:
    """Require one object with no missing or undeclared fields."""
    if not isinstance(value, dict):
        raise PerformanceContractError(f"{label} must be an object")
    missing = required - set(value)
    extras = set(value) - required - (optional or set())
    if missing or extras:
        raise PerformanceContractError(f"{label} fields do not match the normalized event contract")
    return value


def nullable_timestamp(value: Any, label: str) -> str | None:
    """Validate one nullable canonical timestamp."""
    return None if value is None else parse_timestamp(value, label)
