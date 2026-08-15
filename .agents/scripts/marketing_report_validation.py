#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict validation for externally referenced optimization reports."""

from __future__ import annotations

from typing import Any

from _marketing_report_experiment_validation import validate_experiment_summary
from _marketing_report_performance_validation import validate_attribution_summary, validate_report_row
from marketing_optimization_contract import (
    MINIMUM_AGGREGATE_CELL_SIZE,
    OptimizationError,
    assert_public_safe,
    parse_datetime,
    require_integer,
    require_list,
    require_object,
    require_text,
)
from marketing_optimization_validation_common import (
    ATTRIBUTION_REF_RE,
    EXPERIMENT_RUN_REF_RE,
    FORBIDDEN_SIDE_EFFECTS,
    REPORT_CAUSAL_STATEMENT,
    REPORT_REF_RE,
    SHA256_REF_RE,
    alias_list,
    content_reference,
    enum_value,
    exact,
    optional_number,
    optional_timestamp,
    reference,
    reference_list,
)
from performance_contract import optional_alias, require_alias


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
        validate_report_row(item, f"report performance rows[{index}]")
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
        validate_attribution_summary(item, f"report attributions[{index}]")
    minimum_cell_size = int(document["quality"]["minimum_cell_size"])
    for index, item in enumerate(require_list(document["experiments"], "report experiments")):
        validate_experiment_summary(item, f"report experiments[{index}]", minimum_cell_size)
    _validate_evidence_quality(document)
    _validate_report_boundaries(document)
    return content_reference(document, "report_ref", "mkt-report-v1", REPORT_REF_RE, "report")
