#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Aggregate-row validation for marketing experiment analyses."""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from marketing_optimization_contract import (
    OptimizationError,
    divide,
    number,
    require_list,
)
from marketing_optimization_validation_common import (
    boolean,
    exact,
    optional_count,
    optional_number,
)
from performance_contract import require_alias

VARIANT_RESULT_FIELDS = (
    "variant_id",
    "suppressed",
    "exposed_count",
    "eligible_count",
    "numerator",
    "denominator",
    "metric_value",
    "gross_value",
    "refund_value",
    "net_value",
)
METRIC_FIELDS = (
    "numerator",
    "denominator",
    "metric_value",
    "gross_value",
    "refund_value",
    "net_value",
)


def _validate_variant_field_types(result: dict[str, Any], label: str) -> None:
    """Validate one variant row's scalar field types."""
    require_alias(result["variant_id"], f"{label}.variant_id")
    boolean(result["suppressed"], f"{label}.suppressed")
    for field in ("exposed_count", "eligible_count"):
        optional_count(result[field], f"{label}.{field}")
    for field in METRIC_FIELDS:
        optional_number(result[field], f"{label}.{field}")


def _validate_suppressed_variant(result: dict[str, Any]) -> None:
    """Ensure privacy-suppressed rows expose no aggregate values."""
    sensitive_fields = set(VARIANT_RESULT_FIELDS) - {"variant_id", "suppressed"}
    if any(result[field] is not None for field in sensitive_fields):
        raise OptimizationError("suppressed experiment variant result exposes aggregate values")


def _validate_metric_values(result: dict[str, Any]) -> None:
    """Bind visible ratio fields to their exact aggregate values."""
    numerator = number(result["numerator"], "experiment analysis numerator")
    denominator = number(result["denominator"], "experiment analysis denominator")
    metric_value = number(result["metric_value"], "experiment analysis metric_value")
    gross = number(result["gross_value"], "experiment analysis gross_value")
    refund = number(result["refund_value"], "experiment analysis refund_value")
    net = number(result["net_value"], "experiment analysis net_value")
    if denominator <= 0 or not Decimal(0) <= numerator <= denominator:
        raise OptimizationError("experiment variant binomial aggregates are invalid")
    if metric_value != divide(numerator, denominator):
        raise OptimizationError("experiment variant metric_value is inconsistent")
    if gross != numerator or refund != 0 or net != numerator:
        raise OptimizationError("experiment variant ratio value aggregates are inconsistent")


def _validate_visible_variant(result: dict[str, Any]) -> None:
    """Validate population and metric consistency for one visible row."""
    if result["exposed_count"] is None or result["eligible_count"] is None:
        raise OptimizationError("visible experiment variant result lacks population counts")
    if result["exposed_count"] != result["eligible_count"]:
        raise OptimizationError("experiment variant population counts are inconsistent")
    populated = [result[field] is not None for field in METRIC_FIELDS]
    if any(populated) and not all(populated):
        raise OptimizationError("visible experiment variant result has incomplete metric values")
    if all(populated):
        _validate_metric_values(result)


def validate_variant_results(value: Any) -> list[dict[str, Any]]:
    """Require exact aggregate variant-result fields."""
    results: list[dict[str, Any]] = []
    for index, item in enumerate(require_list(value, "experiment analysis variant_results")):
        label = f"experiment analysis variant_results[{index}]"
        result = exact(item, set(VARIANT_RESULT_FIELDS), label)
        _validate_variant_field_types(result, label)
        if result["suppressed"]:
            _validate_suppressed_variant(result)
        else:
            _validate_visible_variant(result)
        results.append(result)
    return results
