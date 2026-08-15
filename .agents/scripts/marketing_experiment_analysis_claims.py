#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Comparison and guardrail validation for experiment analyses."""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from marketing_optimization_contract import (
    OptimizationError,
    number,
    require_list,
    require_metric,
)
from marketing_optimization_validation_common import (
    boolean,
    enum_value,
    exact,
    optional_number,
)
from performance_contract import require_alias

COMPARISON_FIELDS = (
    "control_variant_id",
    "treatment_variant_id",
    "absolute_effect",
    "relative_effect",
    "confidence_interval_low",
    "confidence_interval_high",
    "adjusted_alpha",
    "significant",
    "practically_significant",
)
INTERVAL_FIELDS = (
    "absolute_effect",
    "confidence_interval_low",
    "confidence_interval_high",
)


def _validate_comparison_fields(comparison: dict[str, Any], label: str) -> None:
    """Validate scalar comparison fields."""
    require_alias(comparison["control_variant_id"], f"{label}.control_variant_id")
    require_alias(comparison["treatment_variant_id"], f"{label}.treatment_variant_id")
    for field in (*INTERVAL_FIELDS, "relative_effect"):
        optional_number(comparison[field], f"{label}.{field}")
    alpha = number(comparison["adjusted_alpha"], f"{label}.adjusted_alpha")
    if not Decimal(0) < alpha < Decimal(1):
        raise OptimizationError("experiment analysis adjusted_alpha must be between zero and one")
    boolean(comparison["significant"], f"{label}.significant")
    boolean(comparison["practically_significant"], f"{label}.practically_significant")


def _validate_comparison_evidence(comparison: dict[str, Any]) -> None:
    """Require significance claims to carry complete effect evidence."""
    if comparison["practically_significant"] and not comparison["significant"]:
        raise OptimizationError("experiment practical significance requires statistical significance")
    interval_present = [comparison[field] is not None for field in INTERVAL_FIELDS]
    if any(interval_present) and not all(interval_present):
        raise OptimizationError("experiment comparison has incomplete effect evidence")
    claims_result = comparison["relative_effect"] is not None
    claims_result = claims_result or comparison["significant"]
    claims_result = claims_result or comparison["practically_significant"]
    if not any(interval_present) and claims_result:
        raise OptimizationError("experiment comparison claims a result without effect evidence")


def validate_comparisons(value: Any) -> list[dict[str, Any]]:
    """Require exact treatment-comparison fields."""
    comparisons: list[dict[str, Any]] = []
    for index, item in enumerate(require_list(value, "experiment analysis comparisons")):
        label = f"experiment analysis comparisons[{index}]"
        comparison = exact(item, set(COMPARISON_FIELDS), label)
        _validate_comparison_fields(comparison, label)
        _validate_comparison_evidence(comparison)
        comparisons.append(comparison)
    return comparisons


def validate_guardrails(value: Any) -> list[dict[str, Any]]:
    """Require exact aggregate guardrail-result fields."""
    guardrails: list[dict[str, Any]] = []
    for index, item in enumerate(require_list(value, "experiment analysis guardrails")):
        label = f"experiment analysis guardrails[{index}]"
        guardrail = exact(item, {"metric_id", "status", "effect"}, label)
        require_metric(guardrail["metric_id"], f"{label}.metric_id")
        status = enum_value(
            guardrail["status"],
            {"pass", "breach", "insufficient_evidence"},
            f"{label}.status",
        )
        optional_number(guardrail["effect"], f"{label}.effect")
        if (status == "insufficient_evidence") != (guardrail["effect"] is None):
            raise OptimizationError("experiment guardrail status and effect are inconsistent")
        guardrails.append(guardrail)
    return guardrails
