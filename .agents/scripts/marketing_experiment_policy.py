#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation for marketing experiment metrics, stopping, privacy, and data policy."""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from marketing_optimization_contract import (
    MINIMUM_AGGREGATE_CELL_SIZE,
    MINIMUM_EXPERIMENT_CONVERSIONS_PER_VARIANT,
    MINIMUM_EXPERIMENT_RUNTIME_SECONDS,
    MINIMUM_EXPERIMENT_SAMPLE_PER_VARIANT,
    OptimizationError,
    number,
    parse_datetime,
    require_integer,
    require_list,
    require_metric,
    require_object,
)
from marketing_optimization_validation_common import exact
from performance_contract import require_alias


def _validate_metric(metric: dict[str, Any], field: str) -> None:
    """Validate one preregistered metric."""
    exact(
        metric,
        {"metric_id", "denominator_metric_id", "unit", "direction", "minimum_practical_effect"},
        field,
    )
    require_metric(metric.get("metric_id"), f"{field}.metric_id")
    denominator = metric.get("denominator_metric_id")
    if denominator is not None:
        require_metric(denominator, f"{field}.denominator_metric_id")
    require_alias(metric.get("unit"), f"{field}.unit")
    if metric.get("direction") not in {"higher_is_better", "lower_is_better", "neutral"}:
        raise OptimizationError(f"{field}.direction is unsupported")
    if number(metric.get("minimum_practical_effect"), f"{field}.minimum_practical_effect") < 0:
        raise OptimizationError(f"{field}.minimum_practical_effect cannot be negative")


def validate_metrics(definition: dict[str, Any]) -> None:
    """Validate primary, secondary, and guardrail metrics."""
    metrics = exact(definition.get("metrics"), {"primary", "secondary", "guardrails"}, "metrics")
    primary = require_object(metrics.get("primary"), "metrics.primary")
    _validate_metric(primary, "metrics.primary")
    if primary.get("unit") != "ratio" or primary.get("denominator_metric_id") is None:
        raise OptimizationError("experiment primary metric must be a supported binomial-rate ratio")
    assignment = require_object(definition.get("assignment"), "assignment")
    if primary["denominator_metric_id"] != assignment.get("exposure_metric_id"):
        raise OptimizationError("experiment primary denominator must match its exposure metric")
    for index, item in enumerate(require_list(metrics.get("secondary"), "metrics.secondary")):
        _validate_metric(require_object(item, f"metrics.secondary[{index}]"), f"metrics.secondary[{index}]")
    for index, item in enumerate(require_list(metrics.get("guardrails"), "metrics.guardrails")):
        guardrail = exact(
            item,
            {"metric_id", "unit", "direction", "harm_threshold"},
            f"metrics.guardrails[{index}]",
        )
        require_metric(guardrail.get("metric_id"), f"metrics.guardrails[{index}].metric_id")
        require_alias(guardrail.get("unit"), f"metrics.guardrails[{index}].unit")
        if guardrail.get("unit") != "ratio":
            raise OptimizationError("experiment guardrails must use supported binomial-rate ratios")
        if guardrail.get("direction") not in {"higher_is_better", "lower_is_better"}:
            raise OptimizationError("guardrail direction is unsupported")
        if number(guardrail.get("harm_threshold"), "guardrail harm_threshold") < 0:
            raise OptimizationError("guardrail harm_threshold cannot be negative")


def validate_sample_and_stopping(definition: dict[str, Any]) -> None:
    """Validate sample assumptions and stopping rules."""
    sample = exact(
        definition.get("sample_plan"),
        {
            "baseline",
            "minimum_detectable_effect",
            "alpha",
            "power",
            "required_sample_per_variant",
            "minimum_conversions_per_variant",
            "minimum_runtime_seconds",
        },
        "sample_plan",
    )
    for field in ("baseline", "minimum_detectable_effect", "alpha", "power"):
        value = number(sample.get(field), f"sample_plan.{field}")
        if value < 0:
            raise OptimizationError(f"sample_plan.{field} cannot be negative")
    alpha = number(sample["alpha"], "sample_plan.alpha")
    power = number(sample["power"], "sample_plan.power")
    if not Decimal(0) < alpha < Decimal(1) or not Decimal(0) < power < Decimal(1):
        raise OptimizationError("alpha and power must be between zero and one")
    require_integer(
        sample.get("required_sample_per_variant"),
        "required_sample_per_variant",
        MINIMUM_EXPERIMENT_SAMPLE_PER_VARIANT,
        1000000000,
    )
    require_integer(
        sample.get("minimum_conversions_per_variant"),
        "minimum_conversions_per_variant",
        MINIMUM_EXPERIMENT_CONVERSIONS_PER_VARIANT,
        1000000000,
    )
    require_integer(
        sample.get("minimum_runtime_seconds"),
        "minimum_runtime_seconds",
        MINIMUM_EXPERIMENT_RUNTIME_SECONDS,
        31536000,
    )
    stopping = exact(
        definition.get("stopping_policy"),
        {"method", "allowed_looks", "alpha_spending", "safety_stop"},
        "stopping_policy",
    )
    allowed = require_integer(stopping.get("allowed_looks"), "allowed_looks", 1, 1000)
    method = stopping.get("method")
    spending = stopping.get("alpha_spending")
    if method == "fixed_horizon" and (allowed != 1 or spending is not None):
        raise OptimizationError("fixed-horizon experiments require one look and no alpha spending")
    if method == "sequential" and spending not in {"obrien_fleming", "pocock"}:
        raise OptimizationError("sequential experiments require a supported alpha-spending rule")
    if method not in {"fixed_horizon", "sequential"} or not isinstance(stopping.get("safety_stop"), bool):
        raise OptimizationError("stopping policy is unsupported")


def validate_privacy_and_data(definition: dict[str, Any]) -> None:
    """Validate aggregate privacy and bounded experiment dates."""
    privacy = exact(
        definition.get("privacy"),
        {
            "policy_ref",
            "minimum_cell_size",
            "minimum_subject_count",
            "suppression_mode",
            "aggregate_only",
        },
        "privacy",
    )
    require_alias(privacy.get("policy_ref"), "privacy.policy_ref")
    require_integer(
        privacy.get("minimum_cell_size"),
        "minimum_cell_size",
        MINIMUM_AGGREGATE_CELL_SIZE,
        1000000,
    )
    require_integer(
        privacy.get("minimum_subject_count"),
        "minimum_subject_count",
        MINIMUM_AGGREGATE_CELL_SIZE,
        1000000000,
    )
    if privacy.get("suppression_mode") != "null_with_reason" or privacy.get("aggregate_only") is not True:
        raise OptimizationError("experiment privacy must remain aggregate-only with null suppression")
    policy = exact(
        definition.get("data_policy"),
        {
            "campaign_id",
            "account_ref",
            "started_at",
            "ended_at",
            "refund_maturity_seconds",
            "require_complete_coverage",
            "require_fresh_sources",
        },
        "data_policy",
    )
    require_alias(policy.get("campaign_id"), "data_policy.campaign_id")
    if policy.get("account_ref") is not None:
        require_alias(policy.get("account_ref"), "data_policy.account_ref")
    started = parse_datetime(policy.get("started_at"), "data_policy.started_at")
    ended = parse_datetime(policy.get("ended_at"), "data_policy.ended_at")
    if ended <= started:
        raise OptimizationError("experiment ended_at must follow started_at")
    require_integer(policy.get("refund_maturity_seconds"), "refund_maturity_seconds", 0, 31536000)
    if not isinstance(policy.get("require_complete_coverage"), bool) or not isinstance(policy.get("require_fresh_sources"), bool):
        raise OptimizationError("data quality requirements must be boolean")


def validate_configured_experiment_floors(
    definition: dict[str, Any],
    policy: dict[str, Any],
) -> None:
    """Require a definition to honor immutable repository policy floors."""
    sample = require_object(definition.get("sample_plan"), "sample_plan")
    privacy = require_object(definition.get("privacy"), "privacy")
    checks = (
        (sample, "required_sample_per_variant", policy["default_minimum_sample_per_variant"]),
        (sample, "minimum_conversions_per_variant", policy["default_minimum_conversions_per_variant"]),
        (sample, "minimum_runtime_seconds", policy["default_minimum_runtime_seconds"]),
        (privacy, "minimum_cell_size", policy["default_minimum_cell_size"]),
        (privacy, "minimum_subject_count", policy["default_minimum_cell_size"]),
    )
    if any(int(container[field]) < int(floor) for container, field, floor in checks):
        raise OptimizationError("experiment definition cannot relax configured policy floors")
