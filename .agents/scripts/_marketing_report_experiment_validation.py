#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Experiment sections embedded in aggregate optimization reports."""

from __future__ import annotations

from typing import Any

from marketing_optimization_contract import (
    OptimizationError,
    number,
    parse_datetime,
    require_list,
    require_metric,
    require_object,
)
from marketing_optimization_validation_common import (
    ASSIGNMENT_REF_RE,
    EXPERIMENT_REF_RE,
    EXPERIMENT_RUN_REF_RE,
    SHA256_REF_RE,
    alias_list,
    boolean,
    enum_value,
    exact,
    optional_count,
    optional_number,
    reference,
)
from performance_contract import optional_alias, require_alias

EXPERIMENT_SUMMARY_FIELDS = (
    "experiment_ref", "run_ref", "input_snapshot_sha256", "as_of", "experiment_id", "owner", "scope",
    "window", "assignment", "analysis_status", "causal_status", "decision_eligible", "winner_variant_id",
    "primary_metric", "variant_results", "comparisons", "guardrails", "insufficient_reasons",
)


def _validate_metric(value: Any, label: str) -> None:
    """Validate a preregistered primary metric projection."""
    fields = {"metric_id", "denominator_metric_id", "unit", "direction", "minimum_practical_effect"}
    metric = exact(value, fields, label)
    require_metric(metric["metric_id"], f"{label}.metric_id")
    if metric["denominator_metric_id"] is not None:
        require_metric(metric["denominator_metric_id"], f"{label}.denominator_metric_id")
    require_alias(metric["unit"], f"{label}.unit")
    enum_value(metric["direction"], {"higher_is_better", "lower_is_better", "neutral"}, f"{label}.direction")
    number(metric["minimum_practical_effect"], f"{label}.minimum_practical_effect")


def _validate_variant_result(value: Any, label: str, minimum_cell_size: int) -> None:
    """Validate one aggregate experiment variant result."""
    fields = {
        "variant_id", "suppressed", "exposed_count", "eligible_count", "numerator", "denominator",
        "metric_value", "gross_value", "refund_value", "net_value",
    }
    result = exact(value, fields, label)
    require_alias(result["variant_id"], f"{label}.variant_id")
    boolean(result["suppressed"], f"{label}.suppressed")
    for field in ("exposed_count", "eligible_count"):
        optional_count(result[field], f"{label}.{field}")
    for field in ("numerator", "denominator", "metric_value", "gross_value", "refund_value", "net_value"):
        optional_number(result[field], f"{label}.{field}")
    aggregate_fields = (
        "exposed_count", "eligible_count", "numerator", "denominator", "metric_value", "gross_value",
        "refund_value", "net_value",
    )
    if result["suppressed"]:
        if any(result[field] is not None for field in aggregate_fields):
            raise OptimizationError(f"{label} exposes a suppressed experiment cell")
        return
    counts = (result["exposed_count"], result["eligible_count"])
    if any(item is None or int(item) < minimum_cell_size for item in counts):
        raise OptimizationError(f"{label} is visible below the report privacy floor")


def _validate_comparison(value: Any, label: str) -> None:
    """Validate one aggregate experiment treatment comparison."""
    fields = {
        "control_variant_id", "treatment_variant_id", "absolute_effect", "relative_effect",
        "confidence_interval_low", "confidence_interval_high", "adjusted_alpha", "significant",
        "practically_significant",
    }
    comparison = exact(value, fields, label)
    require_alias(comparison["control_variant_id"], f"{label}.control_variant_id")
    require_alias(comparison["treatment_variant_id"], f"{label}.treatment_variant_id")
    for field in ("absolute_effect", "relative_effect", "confidence_interval_low", "confidence_interval_high"):
        optional_number(comparison[field], f"{label}.{field}")
    number(comparison["adjusted_alpha"], f"{label}.adjusted_alpha")
    boolean(comparison["significant"], f"{label}.significant")
    boolean(comparison["practically_significant"], f"{label}.practically_significant")


def _validate_guardrail(value: Any, label: str) -> None:
    """Validate one aggregate experiment guardrail result."""
    guardrail = exact(value, {"metric_id", "status", "effect"}, label)
    require_metric(guardrail["metric_id"], f"{label}.metric_id")
    enum_value(guardrail["status"], {"pass", "breach", "insufficient_evidence"}, f"{label}.status")
    optional_number(guardrail["effect"], f"{label}.effect")


def _validate_assignment(summary: dict[str, Any], label: str) -> None:
    """Validate embedded assignment evidence metadata."""
    assignment = exact(summary["assignment"], {"method", "verification", "sticky", "snapshot_ref"}, f"{label}.assignment")
    enum_value(assignment["method"], {"randomized", "deterministic_split", "observational"}, f"{label}.assignment.method")
    enum_value(assignment["verification"], {"verified", "unverified"}, f"{label}.assignment.verification")
    boolean(assignment["sticky"], f"{label}.assignment.sticky")
    if assignment["snapshot_ref"] is not None:
        reference(assignment["snapshot_ref"], ASSIGNMENT_REF_RE, f"{label}.assignment.snapshot_ref")


def _validate_suppressed_claims(
    summary: dict[str, Any],
    guardrails: list[Any],
    suppressed_variants: set[str],
    label: str,
) -> None:
    """Reject causal and guardrail claims derived from suppressed cells."""
    if not suppressed_variants:
        return
    claims_result = summary["causal_status"] == "causal_supported" or summary["decision_eligible"]
    claims_result = claims_result or summary["winner_variant_id"] is not None
    if claims_result:
        raise OptimizationError(f"{label} cannot claim a result from suppressed variants")
    exposes_guardrail = any(
        require_object(item, "experiment guardrail")["status"] != "insufficient_evidence"
        or require_object(item, "experiment guardrail")["effect"] is not None
        for item in guardrails
    )
    if exposes_guardrail:
        raise OptimizationError(f"{label} guardrail exposes a suppressed experiment cell")


def validate_experiment_summary(value: Any, label: str, minimum_cell_size: int) -> None:
    """Validate one experiment analysis section embedded in a report."""
    summary = exact(value, set(EXPERIMENT_SUMMARY_FIELDS), label)
    reference(summary["experiment_ref"], EXPERIMENT_REF_RE, f"{label}.experiment_ref")
    reference(summary["run_ref"], EXPERIMENT_RUN_REF_RE, f"{label}.run_ref")
    reference(summary["input_snapshot_sha256"], SHA256_REF_RE, f"{label}.input_snapshot_sha256")
    parse_datetime(summary["as_of"], f"{label}.as_of")
    require_alias(summary["experiment_id"], f"{label}.experiment_id")
    require_alias(summary["owner"], f"{label}.owner")
    scope = exact(summary["scope"], {"account_ref", "campaign_id"}, f"{label}.scope")
    optional_alias(scope["account_ref"], f"{label}.scope.account_ref")
    require_alias(scope["campaign_id"], f"{label}.scope.campaign_id")
    window = exact(summary["window"], {"started_at", "ended_at"}, f"{label}.window")
    parse_datetime(window["started_at"], f"{label}.window.started_at")
    parse_datetime(window["ended_at"], f"{label}.window.ended_at")
    _validate_assignment(summary, label)
    enum_value(summary["analysis_status"], {"complete", "insufficient_evidence", "invalid", "guardrail_breach"}, f"{label}.analysis_status")
    enum_value(summary["causal_status"], {"causal_supported", "observational", "invalid", "insufficient_evidence"}, f"{label}.causal_status")
    boolean(summary["decision_eligible"], f"{label}.decision_eligible")
    optional_alias(summary["winner_variant_id"], f"{label}.winner_variant_id")
    _validate_metric(summary["primary_metric"], f"{label}.primary_metric")
    variant_results = require_list(summary["variant_results"], f"{label}.variant_results")
    for index, item in enumerate(variant_results):
        _validate_variant_result(item, f"{label}.variant_results[{index}]", minimum_cell_size)
    suppressed = {
        str(require_object(item, "experiment variant result")["variant_id"])
        for item in variant_results
        if require_object(item, "experiment variant result")["suppressed"]
    }
    comparisons = require_list(summary["comparisons"], f"{label}.comparisons")
    for index, item in enumerate(comparisons):
        _validate_comparison(item, f"{label}.comparisons[{index}]")
        comparison = require_object(item, "experiment comparison")
        compared = {str(comparison["control_variant_id"]), str(comparison["treatment_variant_id"])}
        if suppressed.intersection(compared):
            derived = ("absolute_effect", "relative_effect", "confidence_interval_low", "confidence_interval_high")
            exposes_result = any(comparison[field] is not None for field in derived)
            exposes_result = exposes_result or comparison["significant"] or comparison["practically_significant"]
            if exposes_result:
                raise OptimizationError(f"{label} comparison exposes a suppressed experiment cell")
    guardrails = require_list(summary["guardrails"], f"{label}.guardrails")
    for index, item in enumerate(guardrails):
        _validate_guardrail(item, f"{label}.guardrails[{index}]")
    _validate_suppressed_claims(summary, guardrails, suppressed, label)
    alias_list(summary["insufficient_reasons"], f"{label}.insufficient_reasons")
