#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict validation for externally referenced growth recommendations."""

from __future__ import annotations

from typing import Any

from marketing_optimization_contract import (
    OptimizationError,
    assert_public_safe,
    digest_document,
    parse_datetime,
    require_integer,
    require_list,
    require_metric,
    require_text,
)
from marketing_optimization_validation_common import (
    ATTRIBUTION_REF_RE,
    EVIDENCE_LINK_RE,
    EXPERIMENT_RUN_REF_RE,
    FORBIDDEN_SIDE_EFFECTS,
    RECOMMENDATION_CAUSAL_WORDING,
    RECOMMENDATION_REF_RE,
    REPORT_REF_RE,
    SHA256_REF_RE,
    content_reference,
    enum_value,
    exact,
    optional_number,
    optional_timestamp,
    reference,
    reference_list,
)
from performance_contract import optional_alias, require_alias

RECOMMENDATION_FIELDS = (
    "schema_version", "recommendation_ref", "recommendation_key", "status", "scope", "finding", "evidence",
    "evidence_rank", "causal_assessment", "target_metric", "expected_impact", "uncertainty", "action",
    "authority", "rollback", "retest", "provenance",
)


def _validate_scope_and_finding(document: dict[str, Any]) -> dict[str, Any]:
    """Validate recommendation scope and aggregate finding fields."""
    scope = exact(
        document["scope"],
        {"campaign_id", "channel", "creative_id", "metric_family", "aggregate_segment"},
        "recommendation scope",
    )
    for field in ("campaign_id", "channel", "creative_id", "aggregate_segment"):
        optional_alias(scope[field], f"recommendation scope.{field}")
    require_alias(scope["metric_family"], "recommendation scope.metric_family")
    finding = exact(
        document["finding"],
        {"kind", "period_start", "period_end", "current_value", "baseline_value", "unit", "observation", "interpretation"},
        "recommendation finding",
    )
    enum_value(
        finding["kind"],
        {"opportunity", "constraint", "risk", "instrumentation_gap"},
        "recommendation finding.kind",
    )
    optional_timestamp(finding["period_start"], "recommendation finding.period_start")
    parse_datetime(finding["period_end"], "recommendation finding.period_end")
    optional_number(finding["current_value"], "recommendation finding.current_value")
    optional_number(finding["baseline_value"], "recommendation finding.baseline_value")
    require_alias(finding["unit"], "recommendation finding.unit")
    require_text(finding["observation"], "recommendation finding.observation")
    require_text(finding["interpretation"], "recommendation finding.interpretation")
    return scope


def _validate_evidence(value: Any, label: str) -> None:
    """Validate one aggregate evidence link."""
    evidence = exact(value, {"ref", "type", "relationship", "confidence", "freshness"}, label)
    reference(evidence["ref"], EVIDENCE_LINK_RE, f"{label}.ref")
    enum_value(
        evidence["type"],
        {"attribution", "experiment", "performance", "report", "qualitative"},
        f"{label}.type",
    )
    enum_value(evidence["relationship"], {"supports", "contradicts", "qualifies"}, f"{label}.relationship")
    enum_value(evidence["confidence"], {"low", "medium", "high", "verified"}, f"{label}.confidence")
    enum_value(evidence["freshness"], {"fresh", "stale", "partial", "unknown"}, f"{label}.freshness")


def _validate_evidence_and_target(document: dict[str, Any]) -> dict[str, Any]:
    """Validate evidence ranking, causal wording, and target metric."""
    evidence = require_list(document["evidence"], "recommendation evidence")
    if not evidence:
        raise OptimizationError("recommendation evidence must not be empty")
    for index, item in enumerate(evidence):
        _validate_evidence(item, f"recommendation evidence[{index}]")
    enum_value(
        document["evidence_rank"],
        {"causal_experiment", "verified_observation", "directional_observation", "hypothesis_only"},
        "recommendation evidence rank",
    )
    causal = exact(document["causal_assessment"], {"status", "allowed_wording"}, "recommendation causal assessment")
    causal_status = enum_value(
        causal["status"],
        {"causal_supported", "observational_only", "insufficient_evidence", "contradicted"},
        "recommendation causal status",
    )
    if causal["allowed_wording"] != RECOMMENDATION_CAUSAL_WORDING[causal_status]:
        raise OptimizationError("recommendation causal wording is not canonical")
    target = exact(
        document["target_metric"],
        {"metric_id", "direction", "current_value", "target_value", "unit"},
        "recommendation target metric",
    )
    require_metric(target["metric_id"], "recommendation target metric.metric_id")
    enum_value(
        target["direction"],
        {"higher_is_better", "lower_is_better", "neutral"},
        "recommendation target direction",
    )
    optional_number(target["current_value"], "recommendation target current_value")
    optional_number(target["target_value"], "recommendation target target_value")
    require_alias(target["unit"], "recommendation target unit")
    return target


def _validate_impact_and_uncertainty(document: dict[str, Any]) -> None:
    """Validate bounded impact assumptions and falsifiable uncertainty."""
    impact = exact(
        document["expected_impact"],
        {"status", "lower", "expected", "upper", "unit", "time_horizon_seconds", "assumptions"},
        "recommendation expected impact",
    )
    enum_value(impact["status"], {"estimated", "not_estimated"}, "recommendation impact status")
    for field in ("lower", "expected", "upper"):
        optional_number(impact[field], f"recommendation impact.{field}")
    require_alias(impact["unit"], "recommendation impact.unit")
    require_integer(impact["time_horizon_seconds"], "recommendation time horizon", 1, 31_536_000)
    for item in require_list(impact["assumptions"], "recommendation assumptions"):
        require_text(item, "recommendation assumption")
    uncertainty = exact(
        document["uncertainty"],
        {"data_confidence", "freshness", "coverage", "contradictions", "falsifiers"},
        "recommendation uncertainty",
    )
    enum_value(
        uncertainty["data_confidence"],
        {"low", "medium", "high", "verified"},
        "recommendation data confidence",
    )
    enum_value(
        uncertainty["freshness"],
        {"fresh", "stale", "partial", "unknown"},
        "recommendation freshness",
    )
    optional_number(uncertainty["coverage"], "recommendation coverage")
    for field in ("contradictions", "falsifiers"):
        for item in require_list(uncertainty[field], f"recommendation {field}"):
            require_text(item, f"recommendation {field}")


def _validate_action_and_authority(document: dict[str, Any]) -> dict[str, Any]:
    """Validate handoff action and preserve the no-side-effect boundary."""
    action = exact(document["action"], {"type", "summary"}, "recommendation action")
    enum_value(
        action["type"],
        {"run_experiment", "instrument", "content_iteration", "review_channel", "review_budget", "hold"},
        "recommendation action type",
    )
    require_text(action["summary"], "recommendation action summary")
    authority = exact(
        document["authority"],
        {"owner", "required_approval", "approval_status", "approval_ref", "permitted_handoff", "forbidden_side_effects"},
        "recommendation authority",
    )
    require_alias(authority["owner"], "recommendation authority.owner")
    require_alias(authority["required_approval"], "recommendation authority.required_approval")
    enum_value(
        authority["approval_status"],
        {"not_requested", "pending", "approved", "rejected"},
        "recommendation approval status",
    )
    optional_alias(authority["approval_ref"], "recommendation authority.approval_ref")
    if authority["approval_status"] in {"approved", "rejected"} or authority["approval_ref"] is not None:
        raise OptimizationError("recommendation approval transitions require independent registration")
    enum_value(
        authority["permitted_handoff"],
        {"content", "marketing", "product", "reports", "instrumentation"},
        "recommendation handoff",
    )
    forbidden = require_list(authority["forbidden_side_effects"], "recommendation forbidden side effects")
    if set(forbidden) != FORBIDDEN_SIDE_EFFECTS or len(forbidden) != len(FORBIDDEN_SIDE_EFFECTS):
        raise OptimizationError("recommendation authority boundary is invalid")
    return action


def _validate_rollback_and_retest(
    document: dict[str, Any],
    target: dict[str, Any],
) -> None:
    """Validate explicit rollback and retest contracts."""
    rollback = exact(
        document["rollback"],
        {
            "trigger_metric",
            "operator",
            "threshold",
            "window_seconds",
            "owner",
            "instruction",
        },
        "recommendation rollback",
    )
    require_metric(rollback["trigger_metric"], "recommendation rollback.trigger_metric")
    operator = enum_value(
        rollback["operator"],
        {"less_than", "greater_than", "not_applicable"},
        "recommendation rollback.operator",
    )
    optional_number(rollback["threshold"], "recommendation rollback.threshold")
    require_integer(rollback["window_seconds"], "recommendation rollback.window_seconds", 1, 31_536_000)
    require_alias(rollback["owner"], "recommendation rollback.owner")
    require_text(rollback["instruction"], "recommendation rollback.instruction")
    if rollback["trigger_metric"] != target["metric_id"]:
        raise OptimizationError("recommendation rollback metric must match its target metric")
    if rollback["owner"] != document["authority"]["owner"]:
        raise OptimizationError("recommendation rollback owner must match its authority owner")
    threshold = rollback["threshold"]
    expected_operator = {
        "higher_is_better": "less_than",
        "lower_is_better": "greater_than",
        "neutral": "not_applicable",
    }[target["direction"]]
    if threshold is None:
        if operator != "not_applicable":
            raise OptimizationError("recommendation rollback without a threshold is not applicable")
    elif operator != expected_operator or operator == "not_applicable":
        raise OptimizationError("recommendation rollback operator contradicts its target direction")
    retest = exact(
        document["retest"],
        {"at", "metric_id", "design", "window_seconds", "success_rule"},
        "recommendation retest",
    )
    parse_datetime(retest["at"], "recommendation retest.at")
    require_metric(retest["metric_id"], "recommendation retest.metric_id")
    if retest["metric_id"] != target["metric_id"]:
        raise OptimizationError("recommendation retest metric must match its target metric")
    enum_value(
        retest["design"],
        {"fixed_horizon_experiment", "instrumentation_review", "observational_review"},
        "recommendation retest.design",
    )
    require_integer(retest["window_seconds"], "recommendation retest.window_seconds", 1, 31_536_000)
    require_text(retest["success_rule"], "recommendation retest.success_rule")


def _validate_identity(
    document: dict[str, Any],
    scope: dict[str, Any],
    target: dict[str, Any],
    action: dict[str, Any],
) -> str:
    """Validate immutable provenance, stable identity, and content reference."""
    provenance = exact(
        document["provenance"],
        {"input_snapshot_sha256", "report_ref", "attribution_refs", "experiment_refs", "generated_at", "supersedes"},
        "recommendation provenance",
    )
    reference(provenance["input_snapshot_sha256"], SHA256_REF_RE, "recommendation snapshot reference")
    reference(provenance["report_ref"], REPORT_REF_RE, "recommendation report reference")
    reference_list(provenance["attribution_refs"], ATTRIBUTION_REF_RE, "recommendation attribution refs")
    reference_list(provenance["experiment_refs"], EXPERIMENT_RUN_REF_RE, "recommendation experiment refs")
    parse_datetime(provenance["generated_at"], "recommendation generated_at")
    if provenance["supersedes"] is not None:
        reference(provenance["supersedes"], RECOMMENDATION_REF_RE, "recommendation supersedes")
    expected_key = digest_document(
        {"scope": scope, "metric_id": target["metric_id"], "action_type": action["type"]}
    )
    if document.get("recommendation_key") != expected_key:
        raise OptimizationError("recommendation key does not match its stable identity")
    return content_reference(
        document,
        "recommendation_ref",
        "mkt-recommendation-v1",
        RECOMMENDATION_REF_RE,
        "recommendation",
    )


def validate_recommendation_artifact(document: dict[str, Any]) -> str:
    """Validate a complete approval-bound recommendation and return its reference."""
    assert_public_safe(document, "growth recommendation")
    exact(
        document,
        set(RECOMMENDATION_FIELDS),
        "growth recommendation",
    )
    if document["schema_version"] != 1:
        raise OptimizationError("growth recommendation schema_version is unsupported")
    status = enum_value(
        document["status"],
        {"draft", "review_required", "approved", "rejected", "superseded", "expired", "insufficient_evidence"},
        "growth recommendation status",
    )
    if status in {"approved", "rejected"}:
        raise OptimizationError("recommendation approval transitions require independent registration")
    scope = _validate_scope_and_finding(document)
    target = _validate_evidence_and_target(document)
    _validate_impact_and_uncertainty(document)
    action = _validate_action_and_authority(document)
    _validate_rollback_and_retest(document, target)
    return _validate_identity(document, scope, target, action)
