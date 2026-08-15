#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict validation for externally referenced attribution artifacts."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from marketing_optimization_contract import (
    MINIMUM_AGGREGATE_CELL_SIZE,
    OptimizationError,
    assert_public_safe,
    parse_datetime,
    require_integer,
    require_list,
    require_metric,
    require_object,
    require_text,
)
from marketing_optimization_validation_common import (
    ATTRIBUTION_CAUSAL_STATEMENT,
    ATTRIBUTION_REF_RE,
    EVIDENCE_REF_RE,
    RECORD_REF_RE,
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


def _validate_run(value: Any, label: str) -> None:
    """Validate a deterministic attribution run envelope."""
    run = exact(
        value,
        {"analysis_version", "input_snapshot_sha256", "as_of", "generated_at", "status"},
        label,
    )
    if run["analysis_version"] != 1:
        raise OptimizationError(f"{label} analysis_version is unsupported")
    reference(run["input_snapshot_sha256"], SHA256_REF_RE, f"{label} snapshot reference")
    parse_datetime(run["as_of"], f"{label}.as_of")
    parse_datetime(run["generated_at"], f"{label}.generated_at")
    enum_value(run["status"], {"complete", "partial", "insufficient_evidence"}, f"{label}.status")


def validate_attribution_scope(value: Any, label: str) -> None:
    """Validate aggregate attribution scope aliases."""
    scope = exact(value, {"account_ref", "campaign_id", "outcome_metric_id", "currency"}, label)
    optional_alias(scope["account_ref"], f"{label}.account_ref")
    optional_alias(scope["campaign_id"], f"{label}.campaign_id")
    require_metric(scope["outcome_metric_id"], f"{label}.outcome_metric_id")
    currency(scope["currency"], f"{label}.currency")


def validate_model(value: Any, label: str) -> None:
    """Validate versioned direct or last-touch model metadata."""
    model = exact(value, {"id", "version", "lookback_seconds", "include_view_through", "tie_break"}, label)
    enum_value(model["id"], {"direct", "last_touch"}, f"{label}.id")
    require_integer(model["version"], f"{label}.version", 1, 1_000_000)
    require_integer(model["lookback_seconds"], f"{label}.lookback_seconds", 1, 31_536_000)
    boolean(model["include_view_through"], f"{label}.include_view_through")
    if model["tie_break"] != "occurred_at_then_record_ref":
        raise OptimizationError(f"{label}.tie_break is unsupported")


def validate_window(value: Any, label: str) -> None:
    """Validate attribution outcome and refund windows."""
    window = exact(value, {"outcome_start", "outcome_end", "refund_maturity_seconds", "maturity"}, label)
    optional_timestamp(window["outcome_start"], f"{label}.outcome_start")
    parse_datetime(window["outcome_end"], f"{label}.outcome_end")
    require_integer(window["refund_maturity_seconds"], f"{label}.refund_maturity_seconds", 0, 31_536_000)
    enum_value(window["maturity"], {"mature", "provisional", "not_applicable"}, f"{label}.maturity")


def validate_outcomes(value: Any, label: str) -> None:
    """Validate aggregate attribution outcome totals."""
    outcomes = exact(
        value,
        {
            "suppressed",
            "eligible_count",
            "attributed_count",
            "unattributed_count",
            "identity_uncertain_count",
            "gross_value",
            "refund_value",
            "net_value",
            "unit",
            "currency",
        },
        label,
    )
    boolean(outcomes["suppressed"], f"{label}.suppressed")
    for field in ("eligible_count", "attributed_count", "unattributed_count", "identity_uncertain_count"):
        optional_count(outcomes[field], f"{label}.{field}")
    for field in ("gross_value", "refund_value", "net_value"):
        optional_number(outcomes[field], f"{label}.{field}")
    require_alias(outcomes["unit"], f"{label}.unit")
    currency(outcomes["currency"], f"{label}.currency")
    if outcomes["suppressed"] and any(
        outcomes[field] is not None
        for field in (
            "eligible_count",
            "attributed_count",
            "unattributed_count",
            "identity_uncertain_count",
            "gross_value",
            "refund_value",
            "net_value",
        )
    ):
        raise OptimizationError(f"{label} exposes a suppressed aggregate")


def validate_costs(value: Any, label: str) -> None:
    """Validate aggregate cost and ROI values."""
    costs = exact(value, {"value", "currency", "allocation", "roi"}, label)
    optional_number(costs["value"], f"{label}.value")
    currency(costs["currency"], f"{label}.currency")
    enum_value(
        costs["allocation"],
        {"exact", "unallocated", "not_applicable", "currency_mismatch"},
        f"{label}.allocation",
    )
    optional_number(costs["roi"], f"{label}.roi")


def validate_allocation(value: Any, label: str) -> None:
    """Validate one privacy-safe aggregate attribution allocation."""
    allocation = exact(
        value,
        {
            "bucket",
            "touchpoint_ref",
            "channel",
            "creative_id",
            "outcome_count",
            "credit",
            "value",
            "suppressed",
            "suppression_reason",
        },
        label,
    )
    enum_value(
        allocation["bucket"],
        {"touchpoint", "direct_observed", "unattributed", "identity_uncertain"},
        f"{label}.bucket",
    )
    if allocation["touchpoint_ref"] is not None:
        reference(allocation["touchpoint_ref"], RECORD_REF_RE, f"{label}.touchpoint_ref")
    optional_alias(allocation["channel"], f"{label}.channel")
    optional_alias(allocation["creative_id"], f"{label}.creative_id")
    optional_count(allocation["outcome_count"], f"{label}.outcome_count")
    optional_number(allocation["credit"], f"{label}.credit")
    optional_number(allocation["value"], f"{label}.value")
    boolean(allocation["suppressed"], f"{label}.suppressed")
    if allocation["suppression_reason"] not in {None, "below_minimum_cell_size"}:
        raise OptimizationError(f"{label}.suppression_reason is unsupported")
    hidden_fields = (
        "touchpoint_ref",
        "channel",
        "creative_id",
        "outcome_count",
        "credit",
        "value",
    )
    if allocation["suppressed"]:
        if allocation["suppression_reason"] != "below_minimum_cell_size" or any(
            allocation[field] is not None for field in hidden_fields
        ):
            raise OptimizationError(f"{label} exposes a suppressed allocation")
    elif allocation["suppression_reason"] is not None:
        raise OptimizationError(f"{label} has inconsistent suppression metadata")


def validate_coverage(value: Any, label: str) -> None:
    """Validate attribution coverage and suppression metadata."""
    coverage = exact(
        value,
        {"fraction", "minimum_cell_size", "suppressed_allocations", "late_events", "unmatched_refunds", "missing_scopes"},
        label,
    )
    optional_number(coverage["fraction"], f"{label}.fraction")
    require_integer(
        coverage["minimum_cell_size"],
        f"{label}.minimum_cell_size",
        MINIMUM_AGGREGATE_CELL_SIZE,
        1_000_000,
    )
    for field in ("suppressed_allocations", "late_events", "unmatched_refunds"):
        optional_count(coverage[field], f"{label}.{field}")
    alias_list(coverage["missing_scopes"], f"{label}.missing_scopes")


@dataclass(frozen=True)
class AttributionPrivacyContext:
    """Cross-section values needed to enforce aggregate privacy floors."""

    outcomes: dict[str, Any]
    costs: dict[str, Any]
    allocations: list[Any]
    coverage: dict[str, Any]
    run_status: Any
    label: str


def _validate_suppressed_privacy(context: AttributionPrivacyContext) -> None:
    """Require every sensitive section to remain hidden when suppressed."""
    sensitive_coverage = ("fraction", "suppressed_allocations", "late_events", "unmatched_refunds")
    if context.run_status != "insufficient_evidence":
        raise OptimizationError(f"{context.label} suppressed evidence must be insufficient")
    if context.costs["value"] is not None or context.costs["roi"] is not None:
        raise OptimizationError(f"{context.label} exposes suppressed cost evidence")
    if any(context.coverage[field] is not None for field in sensitive_coverage):
        raise OptimizationError(f"{context.label} exposes suppressed coverage counts")
    if any(not require_object(item, f"{context.label} allocation")["suppressed"] for item in context.allocations):
        raise OptimizationError(f"{context.label} exposes an allocation below the aggregate floor")


def _valid_visible_count(value: Any, minimum: int) -> bool:
    """Return whether one visible count meets the declared aggregate floor."""
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def _validate_visible_privacy(context: AttributionPrivacyContext) -> None:
    """Require complete visible counts and floor-eligible allocations."""
    minimum = int(context.coverage["minimum_cell_size"])
    if not _valid_visible_count(context.outcomes["eligible_count"], minimum):
        raise OptimizationError(f"{context.label} eligible count is below its privacy floor")
    outcome_fields = ("attributed_count", "unattributed_count", "identity_uncertain_count")
    if any(context.outcomes[field] is None for field in outcome_fields):
        raise OptimizationError(f"{context.label} visible outcome counts are incomplete")
    coverage_fields = ("fraction", "suppressed_allocations", "late_events", "unmatched_refunds")
    if any(context.coverage[field] is None for field in coverage_fields):
        raise OptimizationError(f"{context.label} visible coverage counts are incomplete")
    suppressed_allocations = 0
    for index, item in enumerate(context.allocations):
        allocation = require_object(item, f"{context.label} allocations[{index}]")
        if allocation["suppressed"]:
            suppressed_allocations += 1
            continue
        if not _valid_visible_count(allocation["outcome_count"], minimum):
            raise OptimizationError(f"{context.label} allocation outcome count is below its privacy floor")
    if context.coverage["suppressed_allocations"] != suppressed_allocations:
        raise OptimizationError(f"{context.label} suppressed allocation count is inconsistent")


def validate_attribution_privacy(context: AttributionPrivacyContext) -> None:
    """Validate cross-section privacy floors and suppression invariants."""
    if context.outcomes["suppressed"] is True:
        _validate_suppressed_privacy(context)
    else:
        _validate_visible_privacy(context)


def validate_attribution_artifact(document: dict[str, Any]) -> str:
    """Validate a complete aggregate attribution artifact and return its reference."""
    assert_public_safe(document, "attribution artifact")
    exact(
        document,
        {
            "schema_version",
            "attribution_ref",
            "run",
            "scope",
            "model",
            "window",
            "outcomes",
            "costs",
            "allocations",
            "coverage",
            "uncertainty",
            "causal_assessment",
            "provenance",
        },
        "attribution artifact",
    )
    if document["schema_version"] != 1:
        raise OptimizationError("attribution schema_version is unsupported")
    _validate_run(document["run"], "attribution run")
    validate_attribution_scope(document["scope"], "attribution scope")
    validate_model(document["model"], "attribution model")
    validate_window(document["window"], "attribution window")
    validate_outcomes(document["outcomes"], "attribution outcomes")
    validate_costs(document["costs"], "attribution costs")
    allocations = require_list(document["allocations"], "attribution allocations")
    for index, value in enumerate(allocations):
        validate_allocation(value, f"attribution allocations[{index}]")
    validate_coverage(document["coverage"], "attribution coverage")
    privacy = AttributionPrivacyContext(
        document["outcomes"], document["costs"], allocations,
        document["coverage"], document["run"]["status"], "attribution",
    )
    validate_attribution_privacy(privacy)
    uncertainty = exact(document["uncertainty"], {"data_confidence", "reasons"}, "attribution uncertainty")
    enum_value(
        uncertainty["data_confidence"],
        {"low", "medium", "high", "verified"},
        "attribution uncertainty.data_confidence",
    )
    alias_list(uncertainty["reasons"], "attribution uncertainty.reasons")
    causal = exact(document["causal_assessment"], {"status", "statement"}, "attribution causal assessment")
    if causal["status"] != "observational_only":
        raise OptimizationError("attribution evidence must remain observational")
    if causal["statement"] != ATTRIBUTION_CAUSAL_STATEMENT:
        raise OptimizationError("attribution causal statement is not canonical")
    provenance = exact(
        document["provenance"],
        {"source_snapshot_refs", "evidence_refs", "supersedes"},
        "attribution provenance",
    )
    reference_list(provenance["source_snapshot_refs"], SHA256_REF_RE, "attribution source snapshots")
    reference_list(provenance["evidence_refs"], EVIDENCE_REF_RE, "attribution evidence refs")
    if provenance["supersedes"] is not None:
        reference(provenance["supersedes"], ATTRIBUTION_REF_RE, "attribution supersedes")
    return content_reference(document, "attribution_ref", "mkt-attribution-v1", ATTRIBUTION_REF_RE, "attribution")
