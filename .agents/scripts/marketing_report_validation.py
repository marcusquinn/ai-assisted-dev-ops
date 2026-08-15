#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict validation for externally referenced optimization reports."""

from __future__ import annotations

from typing import Any

from marketing_attribution_validation import (
    validate_allocation,
    validate_attribution_privacy,
    validate_attribution_scope,
    validate_costs,
    validate_coverage,
    validate_model,
    validate_outcomes,
    validate_window,
)
from marketing_optimization_contract import (
    MINIMUM_AGGREGATE_CELL_SIZE,
    OptimizationError,
    assert_public_safe,
    number,
    parse_datetime,
    require_integer,
    require_list,
    require_metric,
    require_object,
    require_text,
)
from marketing_optimization_validation_common import (
    ASSIGNMENT_REF_RE,
    ATTRIBUTION_REF_RE,
    EXPERIMENT_REF_RE,
    EXPERIMENT_RUN_REF_RE,
    FORBIDDEN_SIDE_EFFECTS,
    REPORT_CAUSAL_STATEMENT,
    REPORT_REF_RE,
    SHA256_REF_RE,
    alias_list,
    boolean,
    content_reference,
    currency,
    enum_value,
    exact,
    optional_count,
    optional_number,
    optional_timestamp,
    reference,
    reference_list,
)
from performance_contract import optional_alias, require_alias


def _validate_report_row(value: Any, label: str) -> None:
    """Validate one privacy-gated aggregate report row."""
    row = exact(
        value,
        {
            "category",
            "metric_id",
            "campaign_id",
            "channel",
            "creative_id",
            "touchpoint_id",
            "dimensions",
            "unit",
            "currency",
            "value",
            "record_count",
            "suppressed",
            "suppression_reason",
        },
        label,
    )
    require_alias(row["category"], f"{label}.category")
    require_metric(row["metric_id"], f"{label}.metric_id")
    for field in ("campaign_id", "channel", "creative_id", "touchpoint_id"):
        optional_alias(row[field], f"{label}.{field}")
    if row["dimensions"] is not None:
        dimensions = require_object(row["dimensions"], f"{label}.dimensions")
        if not set(dimensions).issubset({"cohort", "environment", "region"}):
            raise OptimizationError(f"{label}.dimensions contains an unsupported key")
        for field, item in dimensions.items():
            require_alias(item, f"{label}.dimensions.{field}")
    require_alias(row["unit"], f"{label}.unit")
    currency(row["currency"], f"{label}.currency")
    optional_number(row["value"], f"{label}.value")
    optional_count(row["record_count"], f"{label}.record_count")
    boolean(row["suppressed"], f"{label}.suppressed")
    if row["suppression_reason"] not in {None, "below_minimum_cell_size"}:
        raise OptimizationError(f"{label}.suppression_reason is unsupported")
    hidden_fields = (
        "campaign_id",
        "channel",
        "creative_id",
        "touchpoint_id",
        "dimensions",
        "value",
        "record_count",
    )
    if row["suppressed"]:
        if row["suppression_reason"] != "below_minimum_cell_size" or any(
            row[field] is not None for field in hidden_fields
        ):
            raise OptimizationError(f"{label} exposes a suppressed report cell")
    else:
        if row["suppression_reason"] is not None or row["value"] is None:
            raise OptimizationError(f"{label} has inconsistent suppression metadata")
        record_count = row["record_count"]
        if (
            not isinstance(record_count, int)
            or isinstance(record_count, bool)
            or record_count < MINIMUM_AGGREGATE_CELL_SIZE
        ):
            raise OptimizationError(f"{label}.record_count is below the privacy floor")


def _validate_attribution_summary(value: Any, label: str) -> None:
    """Validate one attribution section embedded in a report."""
    summary = exact(
        value,
        {
            "attribution_ref",
            "input_snapshot_sha256",
            "as_of",
            "model",
            "scope",
            "window",
            "run_status",
            "outcomes",
            "costs",
            "allocations",
            "coverage",
            "data_confidence",
            "uncertainty_reasons",
            "causal_status",
        },
        label,
    )
    reference(summary["attribution_ref"], ATTRIBUTION_REF_RE, f"{label}.attribution_ref")
    reference(summary["input_snapshot_sha256"], SHA256_REF_RE, f"{label}.input_snapshot_sha256")
    parse_datetime(summary["as_of"], f"{label}.as_of")
    validate_model(summary["model"], f"{label}.model")
    validate_attribution_scope(summary["scope"], f"{label}.scope")
    validate_window(summary["window"], f"{label}.window")
    enum_value(summary["run_status"], {"complete", "partial", "insufficient_evidence"}, f"{label}.run_status")
    validate_outcomes(summary["outcomes"], f"{label}.outcomes")
    validate_costs(summary["costs"], f"{label}.costs")
    allocations = require_list(summary["allocations"], f"{label}.allocations")
    for index, item in enumerate(allocations):
        validate_allocation(item, f"{label}.allocations[{index}]")
    validate_coverage(summary["coverage"], f"{label}.coverage")
    validate_attribution_privacy(
        summary["outcomes"],
        summary["costs"],
        allocations,
        summary["coverage"],
        summary["run_status"],
        label,
    )
    enum_value(
        summary["data_confidence"],
        {"low", "medium", "high", "verified"},
        f"{label}.data_confidence",
    )
    alias_list(summary["uncertainty_reasons"], f"{label}.uncertainty_reasons")
    if summary["causal_status"] != "observational_only":
        raise OptimizationError(f"{label} must remain observational")


def _validate_metric(value: Any, label: str) -> None:
    """Validate a preregistered primary metric projection."""
    metric = exact(
        value,
        {"metric_id", "denominator_metric_id", "unit", "direction", "minimum_practical_effect"},
        label,
    )
    require_metric(metric["metric_id"], f"{label}.metric_id")
    if metric["denominator_metric_id"] is not None:
        require_metric(metric["denominator_metric_id"], f"{label}.denominator_metric_id")
    require_alias(metric["unit"], f"{label}.unit")
    enum_value(metric["direction"], {"higher_is_better", "lower_is_better", "neutral"}, f"{label}.direction")
    number(metric["minimum_practical_effect"], f"{label}.minimum_practical_effect")


def _validate_variant_result(value: Any, label: str, minimum_cell_size: int) -> None:
    """Validate one aggregate experiment variant result."""
    result = exact(
        value,
        {
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
        },
        label,
    )
    require_alias(result["variant_id"], f"{label}.variant_id")
    boolean(result["suppressed"], f"{label}.suppressed")
    for field in ("exposed_count", "eligible_count"):
        optional_count(result[field], f"{label}.{field}")
    for field in ("numerator", "denominator", "metric_value", "gross_value", "refund_value", "net_value"):
        optional_number(result[field], f"{label}.{field}")
    aggregate_fields = (
        "exposed_count",
        "eligible_count",
        "numerator",
        "denominator",
        "metric_value",
        "gross_value",
        "refund_value",
        "net_value",
    )
    if result["suppressed"]:
        if any(result[field] is not None for field in aggregate_fields):
            raise OptimizationError(f"{label} exposes a suppressed experiment cell")
    elif any(result[field] is None or int(result[field]) < minimum_cell_size for field in ("exposed_count", "eligible_count")):
        raise OptimizationError(f"{label} is visible below the report privacy floor")


def _validate_comparison(value: Any, label: str) -> None:
    """Validate one aggregate experiment treatment comparison."""
    comparison = exact(
        value,
        {
            "control_variant_id",
            "treatment_variant_id",
            "absolute_effect",
            "relative_effect",
            "confidence_interval_low",
            "confidence_interval_high",
            "adjusted_alpha",
            "significant",
            "practically_significant",
        },
        label,
    )
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


def _validate_experiment_summary(value: Any, label: str, minimum_cell_size: int) -> None:
    """Validate one experiment analysis section embedded in a report."""
    summary = exact(
        value,
        {
            "experiment_ref",
            "run_ref",
            "input_snapshot_sha256",
            "as_of",
            "experiment_id",
            "owner",
            "scope",
            "window",
            "assignment",
            "analysis_status",
            "causal_status",
            "decision_eligible",
            "winner_variant_id",
            "primary_metric",
            "variant_results",
            "comparisons",
            "guardrails",
            "insufficient_reasons",
        },
        label,
    )
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
    assignment = exact(
        summary["assignment"],
        {"method", "verification", "sticky", "snapshot_ref"},
        f"{label}.assignment",
    )
    enum_value(
        assignment["method"],
        {"randomized", "deterministic_split", "observational"},
        f"{label}.assignment.method",
    )
    enum_value(assignment["verification"], {"verified", "unverified"}, f"{label}.assignment.verification")
    boolean(assignment["sticky"], f"{label}.assignment.sticky")
    if assignment["snapshot_ref"] is not None:
        reference(assignment["snapshot_ref"], ASSIGNMENT_REF_RE, f"{label}.assignment.snapshot_ref")
    enum_value(
        summary["analysis_status"],
        {"complete", "insufficient_evidence", "invalid", "guardrail_breach"},
        f"{label}.analysis_status",
    )
    enum_value(
        summary["causal_status"],
        {"causal_supported", "observational", "invalid", "insufficient_evidence"},
        f"{label}.causal_status",
    )
    boolean(summary["decision_eligible"], f"{label}.decision_eligible")
    optional_alias(summary["winner_variant_id"], f"{label}.winner_variant_id")
    _validate_metric(summary["primary_metric"], f"{label}.primary_metric")
    variant_results = require_list(summary["variant_results"], f"{label}.variant_results")
    for index, item in enumerate(variant_results):
        _validate_variant_result(item, f"{label}.variant_results[{index}]", minimum_cell_size)
    suppressed_variants = {
        str(require_object(item, "experiment variant result")["variant_id"])
        for item in variant_results
        if require_object(item, "experiment variant result")["suppressed"]
    }
    comparisons = require_list(summary["comparisons"], f"{label}.comparisons")
    for index, item in enumerate(comparisons):
        _validate_comparison(item, f"{label}.comparisons[{index}]")
        comparison = require_object(item, "experiment comparison")
        if suppressed_variants.intersection(
            {str(comparison["control_variant_id"]), str(comparison["treatment_variant_id"])}
        ):
            derived = (
                "absolute_effect",
                "relative_effect",
                "confidence_interval_low",
                "confidence_interval_high",
            )
            if any(comparison[field] is not None for field in derived) or comparison["significant"] or comparison["practically_significant"]:
                raise OptimizationError(f"{label} comparison exposes a suppressed experiment cell")
    guardrails = require_list(summary["guardrails"], f"{label}.guardrails")
    for index, item in enumerate(guardrails):
        _validate_guardrail(item, f"{label}.guardrails[{index}]")
    if suppressed_variants:
        if summary["causal_status"] == "causal_supported" or summary["decision_eligible"] or summary["winner_variant_id"] is not None:
            raise OptimizationError(f"{label} cannot claim a result from suppressed variants")
        if any(
            require_object(item, "experiment guardrail")["status"] != "insufficient_evidence"
            or require_object(item, "experiment guardrail")["effect"] is not None
            for item in guardrails
        ):
            raise OptimizationError(f"{label} guardrail exposes a suppressed experiment cell")
    alias_list(summary["insufficient_reasons"], f"{label}.insufficient_reasons")


def _validate_report_metadata(document: dict[str, Any]) -> None:
    """Validate report run, scope, performance, quality, and authority."""
    run = exact(
        document["run"],
        {"input_snapshot_sha256", "as_of", "generated_at", "period_start", "period_end", "status"},
        "report run",
    )
    reference(run["input_snapshot_sha256"], SHA256_REF_RE, "report snapshot reference")
    parse_datetime(run["as_of"], "report run.as_of")
    parse_datetime(run["generated_at"], "report run.generated_at")
    optional_timestamp(run["period_start"], "report run.period_start")
    parse_datetime(run["period_end"], "report run.period_end")
    enum_value(run["status"], {"complete", "partial", "insufficient_evidence"}, "report run.status")
    scope = exact(document["scope"], {"account_ref", "campaign_id"}, "report scope")
    optional_alias(scope["account_ref"], "report scope.account_ref")
    optional_alias(scope["campaign_id"], "report scope.campaign_id")
    performance = exact(document["performance"], {"rows", "categories"}, "report performance")
    rows = require_list(performance["rows"], "report performance rows")
    for index, item in enumerate(rows):
        _validate_report_row(item, f"report performance rows[{index}]")
    categories = alias_list(performance["categories"], "report performance categories")
    if categories != sorted({str(require_object(item, "report row")["category"]) for item in rows}):
        raise OptimizationError("report performance categories do not match its rows")
    quality = exact(
        document["quality"],
        {
            "minimum_cell_size",
            "freshness",
            "coverage",
            "data_confidence",
            "reasons",
            "missing_scopes",
            "suppressed_cells",
        },
        "report quality",
    )
    require_integer(
        quality["minimum_cell_size"],
        "report quality.minimum_cell_size",
        MINIMUM_AGGREGATE_CELL_SIZE,
        1000000,
    )
    enum_value(quality["freshness"], {"fresh", "stale", "partial", "unknown"}, "report quality.freshness")
    optional_number(quality["coverage"], "report quality.coverage")
    enum_value(
        quality["data_confidence"],
        {"low", "medium", "high", "verified"},
        "report quality.data_confidence",
    )
    quality_reasons = alias_list(quality["reasons"], "report quality.reasons")
    alias_list(quality["missing_scopes"], "report quality.missing_scopes")
    require_integer(quality["suppressed_cells"], "report quality.suppressed_cells", 0, 9_007_199_254_740_991)
    if quality["suppressed_cells"] != sum(
        int(require_object(item, "report row")["suppressed"]) for item in rows
    ):
        raise OptimizationError("report suppressed cell count does not match its rows")
    if (run["status"] == "complete" and quality_reasons) or (
        run["status"] == "partial" and not quality_reasons
    ):
        raise OptimizationError("report run status does not match its quality reasons")


def _validate_evidence_quality(document: dict[str, Any]) -> None:
    """Require nested evidence caveats to remain visible at report level."""
    reasons: set[str] = set()
    for value in require_list(document["attributions"], "report attributions"):
        attribution = require_object(value, "report attribution")
        reasons.update(str(reason) for reason in attribution["uncertainty_reasons"])
        if attribution["run_status"] != "complete":
            reasons.add(f"attribution_{attribution['run_status']}")
    for value in require_list(document["experiments"], "report experiments"):
        experiment = require_object(value, "report experiment")
        reasons.update(str(reason) for reason in experiment["insufficient_reasons"])
        if experiment["analysis_status"] != "complete":
            reasons.add(f"experiment_{experiment['analysis_status']}")
    report_reasons = set(require_list(document["quality"]["reasons"], "report quality reasons"))
    if not reasons.issubset(report_reasons):
        raise OptimizationError("report quality omits nested evidence caveats")


def _validate_report_boundaries(document: dict[str, Any]) -> None:
    """Validate immutable interpretation, authority, and provenance boundaries."""
    interpretation = exact(
        document["interpretation"],
        {"causal_statement", "distinguishes_business_outcomes", "roi_requires_compatible_currency", "payback_status"},
        "report interpretation",
    )
    if interpretation["causal_statement"] != REPORT_CAUSAL_STATEMENT:
        raise OptimizationError("report causal statement is not canonical")
    business_outcomes = interpretation["distinguishes_business_outcomes"] is True
    compatible_currency = interpretation["roi_requires_compatible_currency"] is True
    if not business_outcomes or not compatible_currency:
        raise OptimizationError("report interpretation boundary is invalid")
    require_alias(interpretation["payback_status"], "report interpretation.payback_status")
    authority = exact(
        document["authority"],
        {"interpretation_only", "owner_review_required", "forbidden_side_effects"},
        "report authority",
    )
    if authority["interpretation_only"] is not True or authority["owner_review_required"] is not True:
        raise OptimizationError("report authority boundary is invalid")
    forbidden = require_list(authority["forbidden_side_effects"], "report forbidden side effects")
    if set(forbidden) != FORBIDDEN_SIDE_EFFECTS or len(forbidden) != len(FORBIDDEN_SIDE_EFFECTS):
        raise OptimizationError("report authority boundary is invalid")
    provenance = exact(
        document["provenance"],
        {"source_snapshot_refs", "attribution_refs", "experiment_refs"},
        "report provenance",
    )
    reference_list(provenance["source_snapshot_refs"], SHA256_REF_RE, "report source snapshots")
    reference_list(provenance["attribution_refs"], ATTRIBUTION_REF_RE, "report attribution refs")
    reference_list(provenance["experiment_refs"], EXPERIMENT_RUN_REF_RE, "report experiment refs")


def validate_report_artifact(document: dict[str, Any]) -> str:
    """Validate a complete aggregate report artifact and return its reference."""
    assert_public_safe(document, "marketing optimization report")
    exact(
        document,
        {
            "schema",
            "schema_version",
            "run",
            "scope",
            "performance",
            "attributions",
            "experiments",
            "quality",
            "interpretation",
            "authority",
            "provenance",
            "report_ref",
        },
        "marketing optimization report",
    )
    if document["schema"] != "aidevops.marketing-optimization-report/v1" or document["schema_version"] != 1:
        raise OptimizationError("recommendations require a marketing optimization report")
    _validate_report_metadata(document)
    for index, item in enumerate(require_list(document["attributions"], "report attributions")):
        _validate_attribution_summary(item, f"report attributions[{index}]")
    minimum_cell_size = int(document["quality"]["minimum_cell_size"])
    for index, item in enumerate(require_list(document["experiments"], "report experiments")):
        _validate_experiment_summary(item, f"report experiments[{index}]", minimum_cell_size)
    _validate_evidence_quality(document)
    _validate_report_boundaries(document)
    return content_reference(document, "report_ref", "mkt-report-v1", REPORT_REF_RE, "report")
