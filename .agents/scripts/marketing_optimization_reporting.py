#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Aggregate marketing reporting and approval-bound recommendations."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Any

from marketing_optimization_common import (
    PROHIBITED_MUTATIONS,
    SCHEMA_ATTRIBUTION,
    SCHEMA_RECOMMENDATION,
    SCHEMA_REPORT,
    OptimizationError,
    decimal_text,
    digest,
    timestamp,
)


@dataclass(frozen=True)
class RecommendationOptions:
    """Governance fields required for a recommendation."""

    owner: str
    approval: str
    rollback: str
    retest_at: str
    created_at: str


def _freshness(sources: Any, generated_at: str, stale_after_hours: int) -> tuple[list[dict[str, Any]], bool]:
    if not isinstance(sources, list):
        raise OptimizationError("report sources must be an array")
    generated = timestamp(generated_at, "generated_at")
    records = []
    stale = False
    for source in sources:
        observed = timestamp(source.get("observed_at"), "sources.observed_at")
        age_hours = max(0.0, (generated - observed).total_seconds() / 3600)
        source_stale = age_hours > stale_after_hours
        stale = stale or source_stale
        records.append({"source": source.get("source"), "coverage": source.get("coverage", "unknown"), "observed_at": source.get("observed_at"), "age_hours": round(age_hours, 3), "status": "stale" if source_stale else "fresh"})
    return records, stale


def _funnel_row(aggregate: dict[str, Any], minimum_cohort: int) -> dict[str, Any] | None:
    if int(aggregate["credited_outcomes"]) < minimum_cohort:
        return None
    revenue = Decimal(aggregate["revenue"])
    refunds = Decimal(aggregate["refunds"])
    costs = Decimal(aggregate["costs"])
    net = revenue - refunds
    roi = (net - costs) / costs if costs else None
    return {**aggregate, "roi": decimal_text(roi) if roi is not None else None, "payback": "not_computable" if costs == 0 else "covered" if net >= costs else "not_covered"}


def _funnel(attribution: Any, minimum_cohort: int) -> tuple[list[dict[str, Any]], int]:
    if attribution is not None and attribution.get("schema") != SCHEMA_ATTRIBUTION:
        raise OptimizationError("report attribution input has an unsupported schema")
    records = []
    suppressed = 0
    if attribution:
        for aggregate in attribution["aggregates"]:
            row = _funnel_row(aggregate, minimum_cohort)
            if row is None:
                suppressed += 1
                continue
            records.append(row)
    return records, suppressed


def _empty_metric_groups() -> dict[str, list[dict[str, Any]]]:
    return {"reach": [], "engagement": [], "account_growth": [], "traffic": [], "conversion": [], "leads_and_stages": [], "sales": [], "revenue_refunds_costs": [], "other": []}


def _metric_category(metric_id: str) -> str:
    categories = (
        ("reach", ("impression", "reach")),
        ("engagement", ("engagement", "click", "reply")),
        ("account_growth", ("follower", "subscriber", "account_growth")),
        ("traffic", ("visit", "traffic", "session")),
        ("conversion", ("conversion",)),
        ("leads_and_stages", ("lead", "stage")),
        ("sales", ("sale",)),
        ("revenue_refunds_costs", ("revenue", "refund", "cost", "roi", "payback")),
    )
    return next((name for name, markers in categories if any(marker in metric_id for marker in markers)), "other")


def _metrics(metrics: Any, minimum_cohort: int) -> tuple[dict[str, list[dict[str, Any]]], int]:
    groups = _empty_metric_groups()
    if not isinstance(metrics, list):
        raise OptimizationError("report metrics must be an array")
    suppressed = 0
    for metric in metrics:
        if not isinstance(metric, dict) or "metric_id" not in metric:
            raise OptimizationError("each report metric must be an object with metric_id")
        if {"subject_id", "event_ref", "contact", "email"}.intersection(metric):
            raise OptimizationError("individual-level fields are forbidden in reports")
        if int(metric.get("cohort_size", 0)) < minimum_cohort:
            suppressed += 1
            continue
        groups[_metric_category(str(metric["metric_id"]))].append(metric)
    for group in groups.values():
        group.sort(key=lambda metric: (str(metric.get("metric_id")), str(metric.get("source_ref", ""))))
    return groups, suppressed


def build_report(document: dict[str, Any], minimum_cohort: int, stale_after_hours: int, generated_at: str) -> dict[str, Any]:
    """Render only aggregate, threshold-safe decision evidence."""
    attribution = document.get("attribution")
    experiments = document.get("experiments", [])
    if not isinstance(experiments, list):
        raise OptimizationError("experiments must be an array")
    freshness, stale = _freshness(document.get("sources", []), generated_at, stale_after_hours)
    funnel, suppressed = _funnel(attribution, minimum_cohort)
    metric_groups, metric_suppressed = _metrics(document.get("metrics", []), minimum_cohort)
    suppressed += metric_suppressed
    contradictions = document.get("contradictions", [])
    if not isinstance(contradictions, list):
        raise OptimizationError("contradictions must be an array")
    caveats = ["Observational attribution does not establish causality.", "Suppressed cohorts are omitted rather than inferred.", "Missing or partial source coverage limits comparisons."]
    if contradictions:
        caveats.append("Contradictory metrics require owner review before a recommendation or decision.")
    identity = {"attribution": attribution, "experiments": experiments, "metrics": metric_groups, "freshness": freshness, "minimum_cohort": minimum_cohort, "contradictions": contradictions}
    return {
        "schema": SCHEMA_REPORT,
        "report_id": digest("mkt-optimization-report-v1", identity),
        "generated_at": generated_at,
        "status": "stale" if stale else "current",
        "privacy": {"minimum_cohort": minimum_cohort, "suppressed_aggregates": suppressed, "individual_records": False},
        "freshness": freshness,
        "funnel": funnel,
        "metrics": metric_groups,
        "experiments": experiments,
        "contradictions": contradictions,
        "caveats": caveats,
        "decision_outputs": [experiment for experiment in experiments if experiment.get("status") in {"candidate_winner", "guardrail_regression", "insufficient_evidence"}],
    }


def _evidence(document: dict[str, Any]) -> dict[str, Any]:
    evidence = document.get("evidence")
    if not isinstance(evidence, dict):
        raise OptimizationError("evidence is required")
    required = ["refs", "source_snapshot", "sample_size", "causality", "target_metric", "observed_problem", "expected_impact"]
    missing = [field for field in required if field not in evidence]
    if missing:
        raise OptimizationError(f"recommendation evidence missing: {', '.join(missing)}")
    return evidence


def _recommendation_status(document: dict[str, Any], evidence: dict[str, Any]) -> str:
    blocked = document.get("evidence_status") in {"insufficient_evidence", "stale", "contradictory"}
    blocked = blocked or evidence.get("freshness") == "stale" or evidence.get("contradictory") is True
    if int(evidence["sample_size"]) < int(document.get("minimum_sample", 2)) or blocked:
        return "insufficient_evidence"
    return "awaiting_approval"


def _impact(evidence: dict[str, Any], options: RecommendationOptions) -> dict[str, Any]:
    expected_impact = evidence["expected_impact"]
    if not isinstance(expected_impact, dict) or float(expected_impact["minimum"]) > float(expected_impact["maximum"]):
        raise OptimizationError("expected impact minimum cannot exceed maximum")
    if timestamp(options.retest_at, "retest_at") <= timestamp(options.created_at, "created_at"):
        raise OptimizationError("retest_at must be after created_at")
    return expected_impact


def recommend(document: dict[str, Any], options: RecommendationOptions) -> dict[str, Any]:
    """Create an approval-bound recommendation, never a provider mutation."""
    evidence = _evidence(document)
    supersedes = sorted(set(document.get("supersedes", [])))
    identity = {"evidence": evidence, "owner": options.owner, "approval": options.approval, "rollback": options.rollback, "retest_at": options.retest_at, "supersedes": supersedes}
    return {
        "schema": SCHEMA_RECOMMENDATION,
        "recommendation_id": digest("growth-rec-v1", identity),
        "status": _recommendation_status(document, evidence),
        "observed_problem": evidence["observed_problem"],
        "target_metric": evidence["target_metric"],
        "evidence": {"refs": sorted(set(evidence["refs"])), "source_snapshot": evidence["source_snapshot"], "sample_size": int(evidence["sample_size"]), "privacy_safe": True, "causality": evidence["causality"]},
        "expected_impact": _impact(evidence, options),
        "confidence": evidence.get("confidence", "medium"),
        "owner": options.owner,
        "required_approval": options.approval,
        "prohibited_mutations": PROHIBITED_MUTATIONS,
        "rollback": options.rollback,
        "retest_at": options.retest_at,
        "created_at": options.created_at,
        "supersedes": supersedes,
    }


def status(document: dict[str, Any], now: str, stale_after_hours: int) -> dict[str, Any]:
    """Return freshness without mutating reports or decisions."""
    observed_value = document.get("generated_at") or document.get("observed_at")
    observed = timestamp(observed_value, "generated_at/observed_at")
    age_hours = max(0.0, (timestamp(now, "now") - observed).total_seconds() / 3600)
    return {"schema": "aidevops.marketing-optimization-status/v1", "status": "stale" if age_hours > stale_after_hours else "current", "age_hours": round(age_hours, 3), "stale_after_hours": stale_after_hours, "source_schema": document.get("schema")}
