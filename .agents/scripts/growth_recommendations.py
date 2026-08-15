#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Evidence-ranked, approval-bound growth recommendation projections."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from growth_recommendation_validation import validate_recommendation_artifact
from marketing_optimization_contract import (
    add_seconds,
    digest_document,
    typed_reference,
)
from marketing_optimization_report import FORBIDDEN_SIDE_EFFECTS, validate_report_document
from marketing_optimization_validation_common import RECOMMENDATION_CAUSAL_WORDING
from performance_contract import require_alias

RECOMMENDATION_REF_RE = re.compile(r"^mkt-recommendation-v1:[a-f0-9]{64}$")
RANK_ORDER = {
    "causal_experiment": 0,
    "verified_observation": 1,
    "directional_observation": 2,
    "hypothesis_only": 3,
}


@dataclass(frozen=True)
class RecommendationPolicy:
    """Human authority and review windows for generated recommendations."""

    owner: str
    required_approval: str
    time_horizon_seconds: int = 2592000
    rollback_window_seconds: int = 604800
    retest_window_seconds: int = 1209600


def _metric_family(metric_id: str) -> str:
    """Return a bounded family alias from one metric ID."""
    parts = metric_id.split(".")
    return parts[1] if len(parts) > 2 else "performance"


def _freshness(report: dict[str, Any]) -> str:
    """Return one schema-compatible evidence freshness label."""
    value = report["quality"]["freshness"]
    return value if value in {"fresh", "stale", "partial", "unknown"} else "unknown"


def _authority(policy: RecommendationPolicy, handoff: str) -> dict[str, Any]:
    """Render an explicit no-side-effect approval boundary."""
    return {
        "owner": require_alias(policy.owner, "recommendation owner"),
        "required_approval": require_alias(policy.required_approval, "required approval"),
        "approval_status": "not_requested",
        "approval_ref": None,
        "permitted_handoff": handoff,
        "forbidden_side_effects": FORBIDDEN_SIDE_EFFECTS,
    }


def _report_evidence(report: dict[str, Any], relationship: str = "qualifies") -> dict[str, Any]:
    """Reference the aggregate report without embedding evidence rows."""
    return {
        "ref": report["report_ref"],
        "type": "report",
        "relationship": relationship,
        "confidence": report["quality"]["data_confidence"],
        "freshness": _freshness(report),
    }


def _contradictions(report: dict[str, Any]) -> list[str]:
    """Convert quality reason codes into bounded caveat statements."""
    return [f"Report caveat: {reason}." for reason in report["quality"]["reasons"]]


def _stable_key(scope: dict[str, Any], metric_id: str, action_type: str) -> str:
    """Return a stable recommendation identity across report reruns."""
    return digest_document({"scope": scope, "metric_id": metric_id, "action_type": action_type})


def _prior_reference(
    recommendation_key: str,
    report_ref: str,
    prior: dict[str, dict[str, Any]],
) -> str | None:
    """Supersede a prior run only when its source report changed."""
    existing = prior.get(recommendation_key)
    if existing is None or existing.get("provenance", {}).get("report_ref") == report_ref:
        return None
    reference = str(existing.get("recommendation_ref", ""))
    return reference if RECOMMENDATION_REF_RE.fullmatch(reference) else None


def _finalize(
    body: dict[str, Any],
    report: dict[str, Any],
    prior: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    """Attach stable identity, supersession, and immutable reference."""
    key = _stable_key(body["scope"], body["target_metric"]["metric_id"], body["action"]["type"])
    body["recommendation_key"] = key
    body["provenance"]["supersedes"] = _prior_reference(key, report["report_ref"], prior)
    body["recommendation_ref"] = typed_reference("mkt-recommendation-v1", body)
    validate_recommendation_artifact(body)
    return body


def _base_provenance(report: dict[str, Any]) -> dict[str, Any]:
    """Return report and snapshot provenance common to all recommendations."""
    return {
        "input_snapshot_sha256": report["run"]["input_snapshot_sha256"],
        "report_ref": report["report_ref"],
        "attribution_refs": [],
        "experiment_refs": [],
        "generated_at": report["run"]["generated_at"],
        "supersedes": None,
    }


def _variant_value(experiment: dict[str, Any], variant_id: str) -> Any:
    """Return one aggregate primary metric value by variant ID."""
    result = next((item for item in experiment["variant_results"] if item["variant_id"] == variant_id), None)
    return None if result is None else result["metric_value"]


def _rollback_condition(direction: str, threshold: Any) -> tuple[str, Any]:
    """Return an executable adverse-direction comparator and threshold."""
    if threshold is None or direction == "neutral":
        return "not_applicable", None
    return (
        "less_than" if direction == "higher_is_better" else "greater_than",
        threshold,
    )


def _experiment_recommendation(
    report: dict[str, Any],
    experiment: dict[str, Any],
    policy: RecommendationPolicy,
    prior: dict[str, dict[str, Any]],
) -> dict[str, Any] | None:
    """Build an estimated-impact recommendation only from eligible causal evidence."""
    winner = experiment.get("winner_variant_id")
    if experiment.get("causal_status") != "causal_supported" or not experiment.get("decision_eligible") or winner is None:
        return None
    comparison = next((item for item in experiment["comparisons"] if item["treatment_variant_id"] == winner), None)
    if comparison is None:
        return None
    metric = experiment["primary_metric"]
    baseline = _variant_value(experiment, comparison["control_variant_id"])
    current = _variant_value(experiment, winner)
    scope = {
        "campaign_id": report["scope"]["campaign_id"],
        "channel": None,
        "creative_id": None,
        "metric_family": _metric_family(metric["metric_id"]),
        "aggregate_segment": None,
    }
    provenance = _base_provenance(report)
    provenance["experiment_refs"] = [experiment["run_ref"]]
    rollback_operator, rollback_threshold = _rollback_condition(
        str(metric["direction"]),
        baseline,
    )
    body: dict[str, Any] = {
        "schema_version": 1,
        "status": "review_required",
        "scope": scope,
        "finding": {
            "kind": "opportunity",
            "period_start": report["run"]["period_start"],
            "period_end": report["run"]["period_end"],
            "current_value": current,
            "baseline_value": baseline,
            "unit": metric["unit"],
            "observation": f"The verified eligible experiment analysis identified {winner} as the treatment.",
            "interpretation": "The preregistered population and window support a causal effect, subject to owner review.",
        },
        "evidence": [
            {
                "ref": experiment["run_ref"],
                "type": "experiment",
                "relationship": "supports",
                "confidence": "verified",
                "freshness": _freshness(report),
            },
            _report_evidence(report),
        ],
        "evidence_rank": "causal_experiment",
        "causal_assessment": {
            "status": "causal_supported",
            "allowed_wording": RECOMMENDATION_CAUSAL_WORDING["causal_supported"],
        },
        "target_metric": {
            "metric_id": metric["metric_id"],
            "direction": metric["direction"],
            "current_value": baseline,
            "target_value": current,
            "unit": metric["unit"],
        },
        "expected_impact": {
            "status": "estimated",
            "lower": comparison["confidence_interval_low"],
            "expected": comparison["absolute_effect"],
            "upper": comparison["confidence_interval_high"],
            "unit": metric["unit"],
            "time_horizon_seconds": policy.time_horizon_seconds,
            "assumptions": ["The measured population, assignment integrity, implementation, and guardrails remain comparable."],
        },
        "uncertainty": {
            "data_confidence": "verified",
            "freshness": _freshness(report),
            "coverage": report["quality"]["coverage"],
            "contradictions": _contradictions(report),
            "falsifiers": ["A preregistered replication fails to reproduce the practical effect or breaches a guardrail."],
        },
        "action": {
            "type": "content_iteration",
            "summary": "Prepare an owner-reviewed iteration from the winning treatment without publishing or mutating providers.",
        },
        "authority": _authority(policy, "content"),
        "rollback": {
            "trigger_metric": metric["metric_id"],
            "operator": rollback_operator,
            "threshold": rollback_threshold,
            "window_seconds": policy.rollback_window_seconds,
            "owner": policy.owner,
            "instruction": "Revert the approved iteration if the target metric falls below the measured baseline or a guardrail breaches.",
        },
        "retest": {
            "at": add_seconds(report["run"]["as_of"], policy.retest_window_seconds),
            "metric_id": metric["metric_id"],
            "design": "fixed_horizon_experiment",
            "window_seconds": policy.retest_window_seconds,
            "success_rule": "Reproduce the preregistered practical effect without breaching guardrails.",
        },
        "provenance": provenance,
    }
    return _finalize(body, report, prior)


def _leading_allocation(attribution: dict[str, Any]) -> dict[str, Any] | None:
    """Return the strongest visible aggregate allocation."""
    visible = [item for item in attribution["allocations"] if not item["suppressed"] and item["outcome_count"] is not None]
    return sorted(visible, key=lambda item: (-int(item["outcome_count"]), str(item.get("channel") or "")))[0] if visible else None


def _attribution_recommendation(
    report: dict[str, Any],
    attribution: dict[str, Any],
    policy: RecommendationPolicy,
    prior: dict[str, dict[str, Any]],
) -> dict[str, Any] | None:
    """Turn one observational allocation into an experiment proposal."""
    allocation = _leading_allocation(attribution)
    if allocation is None:
        return None
    metric_id = attribution["scope"]["outcome_metric_id"]
    outcomes = attribution["outcomes"]
    current = outcomes["net_value"] if outcomes["net_value"] is not None else outcomes["gross_value"]
    confidence = attribution["data_confidence"]
    rank = "verified_observation" if confidence in {"high", "verified"} and attribution["run_status"] == "complete" else "directional_observation"
    scope = {
        "campaign_id": attribution["scope"]["campaign_id"],
        "channel": allocation["channel"],
        "creative_id": allocation["creative_id"],
        "metric_family": _metric_family(metric_id),
        "aggregate_segment": None,
    }
    provenance = _base_provenance(report)
    provenance["attribution_refs"] = [attribution["attribution_ref"]]
    channel = allocation["channel"] or "the leading aggregate allocation"
    rollback_operator, rollback_threshold = _rollback_condition(
        "higher_is_better",
        current,
    )
    body: dict[str, Any] = {
        "schema_version": 1,
        "status": "review_required",
        "scope": scope,
        "finding": {
            "kind": "opportunity",
            "period_start": attribution["window"]["outcome_start"],
            "period_end": attribution["window"]["outcome_end"],
            "current_value": current,
            "baseline_value": None,
            "unit": outcomes["unit"],
            "observation": f"The {attribution['model']['id']} model associates {channel} with the largest visible aggregate outcome allocation.",
            "interpretation": "This is an observational signal suitable for a controlled test, not a causal growth claim.",
        },
        "evidence": [
            {
                "ref": attribution["attribution_ref"],
                "type": "attribution",
                "relationship": "supports",
                "confidence": confidence,
                "freshness": _freshness(report),
            },
            _report_evidence(report),
        ],
        "evidence_rank": rank,
        "causal_assessment": {
            "status": "observational_only",
            "allowed_wording": RECOMMENDATION_CAUSAL_WORDING["observational_only"],
        },
        "target_metric": {
            "metric_id": metric_id,
            "direction": "higher_is_better",
            "current_value": current,
            "target_value": None,
            "unit": outcomes["unit"],
        },
        "expected_impact": {
            "status": "not_estimated",
            "lower": None,
            "expected": None,
            "upper": None,
            "unit": outcomes["unit"],
            "time_horizon_seconds": policy.time_horizon_seconds,
            "assumptions": ["No causal impact estimate is available from observational attribution alone."],
        },
        "uncertainty": {
            "data_confidence": confidence,
            "freshness": _freshness(report),
            "coverage": report["quality"]["coverage"],
            "contradictions": _contradictions(report),
            "falsifiers": ["A preregistered controlled test shows no practical lift or an adverse guardrail effect."],
        },
        "action": {
            "type": "run_experiment",
            "summary": "Design an owner-approved fixed-horizon test of the aggregate allocation before changing campaign execution.",
        },
        "authority": _authority(policy, "marketing"),
        "rollback": {
            "trigger_metric": metric_id,
            "operator": rollback_operator,
            "threshold": rollback_threshold,
            "window_seconds": policy.rollback_window_seconds,
            "owner": policy.owner,
            "instruction": "Stop the approved test if the target metric degrades or any preregistered guardrail breaches.",
        },
        "retest": {
            "at": add_seconds(report["run"]["as_of"], policy.retest_window_seconds),
            "metric_id": metric_id,
            "design": "fixed_horizon_experiment",
            "window_seconds": policy.retest_window_seconds,
            "success_rule": "Meet the preregistered sample, practical-effect, and guardrail thresholds.",
        },
        "provenance": provenance,
    }
    return _finalize(body, report, prior)


def _instrumentation_recommendation(
    report: dict[str, Any],
    policy: RecommendationPolicy,
    prior: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    """Create one explicit no-evidence instrumentation recommendation."""
    metric_id = "marketing.measurement.coverage"
    scope = {
        "campaign_id": report["scope"]["campaign_id"],
        "channel": None,
        "creative_id": None,
        "metric_family": "measurement",
        "aggregate_segment": None,
    }
    reasons = report["quality"]["reasons"] or ["no_eligible_aggregate_opportunity"]
    rollback_operator, rollback_threshold = _rollback_condition(
        "higher_is_better",
        report["quality"]["coverage"],
    )
    body: dict[str, Any] = {
        "schema_version": 1,
        "status": "insufficient_evidence",
        "scope": scope,
        "finding": {
            "kind": "instrumentation_gap",
            "period_start": report["run"]["period_start"],
            "period_end": report["run"]["period_end"],
            "current_value": report["quality"]["coverage"],
            "baseline_value": None,
            "unit": "ratio",
            "observation": "Current aggregate evidence is not sufficient for an actionable growth recommendation.",
            "interpretation": "Improve measurement coverage and freshness before estimating impact or changing execution.",
        },
        "evidence": [_report_evidence(report, "supports")],
        "evidence_rank": "hypothesis_only",
        "causal_assessment": {
            "status": "insufficient_evidence",
            "allowed_wording": RECOMMENDATION_CAUSAL_WORDING["insufficient_evidence"],
        },
        "target_metric": {
            "metric_id": metric_id,
            "direction": "higher_is_better",
            "current_value": report["quality"]["coverage"],
            "target_value": 1,
            "unit": "ratio",
        },
        "expected_impact": {
            "status": "not_estimated",
            "lower": None,
            "expected": None,
            "upper": None,
            "unit": "ratio",
            "time_horizon_seconds": policy.time_horizon_seconds,
            "assumptions": ["Instrumentation changes improve evidence quality but do not themselves establish business impact."],
        },
        "uncertainty": {
            "data_confidence": "low",
            "freshness": _freshness(report),
            "coverage": report["quality"]["coverage"],
            "contradictions": [f"Evidence limitation: {reason}." for reason in reasons],
            "falsifiers": ["A fresh complete source snapshot with sufficient aggregate cells resolves the evidence gap."],
        },
        "action": {"type": "instrument", "summary": "Review missing or stale aggregate measurement before further optimization."},
        "authority": _authority(policy, "instrumentation"),
        "rollback": {
            "trigger_metric": metric_id,
            "operator": rollback_operator,
            "threshold": rollback_threshold,
            "window_seconds": policy.rollback_window_seconds,
            "owner": policy.owner,
            "instruction": "Revert the instrumentation change if it reduces validated coverage or corrupts source provenance.",
        },
        "retest": {
            "at": add_seconds(report["run"]["as_of"], policy.retest_window_seconds),
            "metric_id": metric_id,
            "design": "instrumentation_review",
            "window_seconds": policy.retest_window_seconds,
            "success_rule": "Produce fresh complete aggregate evidence without privacy suppression regressions.",
        },
        "provenance": _base_provenance(report),
    }
    return _finalize(body, report, prior)


def _build_recommendations_from_resolved_report(
    report: dict[str, Any],
    policy: RecommendationPolicy,
    prior_recommendations: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Build recommendations from a report already resolved by the immutable registry."""
    validate_report_document(report)
    prior_items = prior_recommendations or []
    for item in prior_items:
        validate_recommendation_artifact(item)
    prior = {str(item["recommendation_key"]): item for item in prior_items}
    output: list[dict[str, Any]] = []
    for experiment in report["experiments"]:
        recommendation = _experiment_recommendation(report, experiment, policy, prior)
        if recommendation is not None:
            output.append(recommendation)
    for attribution in report["attributions"]:
        recommendation = _attribution_recommendation(report, attribution, policy, prior)
        if recommendation is not None:
            output.append(recommendation)
    if not output or report["quality"]["reasons"]:
        output.append(_instrumentation_recommendation(report, policy, prior))
    unique = {item["recommendation_key"]: item for item in output}
    return sorted(unique.values(), key=lambda item: (RANK_ORDER[item["evidence_rank"]], item["recommendation_key"]))
