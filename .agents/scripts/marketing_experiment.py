#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Preregistered lifecycle and conservative analysis for marketing experiments."""

from __future__ import annotations

import copy
from dataclasses import dataclass
from datetime import timedelta
from decimal import Decimal
from typing import Any

from marketing_experiment_assignment import build_population, load_assignment_evidence
from marketing_experiment_definition import register_experiment
from marketing_experiment_eligibility import EligibilityInputs, evaluate_eligibility
from marketing_experiment_evidence import experiment_run_reference, validate_previous_analysis
from marketing_experiment_statistics import StatisticsBundle, calculate_statistics
from marketing_optimization_contract import (
    OptimizationError,
    OptimizationSnapshot,
    SOURCE_COVERAGE_REASONS,
    SOURCE_FRESHNESS_REASONS,
    assert_public_safe,
    parse_datetime,
    require_object,
    require_text,
    snapshot_quality,
)
from marketing_optimization_validation_common import exact
from performance_contract import require_alias

LOOK_TYPES = {"interim", "final", "safety"}


@dataclass(frozen=True)
class ExperimentAnalysisRequest:
    """Declared analysis look and optional local assignment evidence."""

    look_number: int
    look_type: str
    assignment_document: dict[str, Any] | None = None


def _readiness_reasons(
    definition: dict[str, Any],
    snapshot: OptimizationSnapshot,
    statistics: StatisticsBundle,
) -> set[str]:
    """Evaluate preregistered sample, runtime, maturity, and source gates."""
    sample = definition["sample_plan"]
    reasons: set[str] = set(statistics.reasons)
    if any(item.exposed < sample["required_sample_per_variant"] for item in statistics.aggregates):
        reasons.add("sample_size_not_met")
    if any(item.conversions < sample["minimum_conversions_per_variant"] for item in statistics.aggregates):
        reasons.add("conversion_floor_not_met")
    policy = definition["data_policy"]
    elapsed = parse_datetime(snapshot.as_of, "analysis as_of") - parse_datetime(policy["started_at"], "started_at")
    if elapsed.total_seconds() < sample["minimum_runtime_seconds"]:
        reasons.add("minimum_runtime_not_met")
    quality_reasons, _missing = snapshot_quality(snapshot)
    quality = set(quality_reasons)
    policy_gated = SOURCE_COVERAGE_REASONS | SOURCE_FRESHNESS_REASONS
    reasons.update(quality - policy_gated)
    if policy["require_complete_coverage"]:
        reasons.update(quality.intersection(SOURCE_COVERAGE_REASONS))
    if policy["require_fresh_sources"]:
        reasons.update(quality.intersection(SOURCE_FRESHNESS_REASONS))
    relevant_times = [parse_datetime(event["event"]["occurred_at"], "event occurred_at") for event in snapshot.events]
    maturity = timedelta(seconds=policy["refund_maturity_seconds"])
    if relevant_times and max(relevant_times) + maturity > parse_datetime(snapshot.as_of, "analysis as_of"):
        reasons.add("refund_window_provisional")
    return reasons


def _look_reasons(
    definition: dict[str, Any],
    snapshot: OptimizationSnapshot,
    request: ExperimentAnalysisRequest,
    candidate_winners: tuple[str, ...],
    guardrail_breach: bool,
) -> tuple[set[str], set[str]]:
    """Return invalid and not-yet-ready reasons for the declared look."""
    invalid: set[str] = set()
    waiting: set[str] = set()
    stopping = definition["stopping_policy"]
    if request.look_type not in LOOK_TYPES or not 1 <= request.look_number <= stopping["allowed_looks"]:
        invalid.add("invalid_analysis_look")
        return invalid, waiting
    if request.look_type == "safety" and not stopping["safety_stop"]:
        invalid.add("safety_look_not_preregistered")
    elif request.look_type == "safety" and not guardrail_breach:
        waiting.add("safety_look_without_guardrail_breach")
    ended = parse_datetime(definition["data_policy"]["ended_at"], "ended_at")
    if stopping["method"] == "fixed_horizon":
        if request.look_type != "final" or parse_datetime(snapshot.as_of, "analysis as_of") < ended:
            waiting.add("fixed_horizon_not_complete")
    elif request.look_type == "interim" and not candidate_winners:
        waiting.add("sequential_boundary_not_crossed")
    elif request.look_type == "final" and parse_datetime(snapshot.as_of, "analysis as_of") < ended:
        waiting.add("experiment_window_open")
    return invalid, waiting


def _winner(statistics: StatisticsBundle, direction: str) -> str | None:
    """Select the strongest adjusted significant practical treatment."""
    candidates = [
        item
        for item in statistics.comparisons
        if item["significant"] and item["practically_significant"] and item["absolute_effect"] is not None
    ]
    if not candidates:
        return None
    reverse = direction == "higher_is_better"
    selected = sorted(candidates, key=lambda item: Decimal(str(item["absolute_effect"])), reverse=reverse)[0]
    return str(selected["treatment_variant_id"])


def analyze_experiment(
    definition: dict[str, Any],
    snapshot: OptimizationSnapshot,
    request: ExperimentAnalysisRequest,
) -> dict[str, Any]:
    """Analyse one preregistered look without making an owner decision."""
    registered = register_experiment(definition)
    if registered.get("decision") is not None:
        raise OptimizationError("decided experiments require a new definition version for reanalysis")
    previous = validate_previous_analysis(registered, snapshot.as_of, request.look_number)
    evidence = load_assignment_evidence(request.assignment_document, registered)
    population = build_population(snapshot, registered, evidence)
    statistics = calculate_statistics(registered, population, request.look_number)
    invalid_reasons, look_waiting = _look_reasons(
        registered,
        snapshot,
        request,
        statistics.candidate_winners,
        statistics.guardrail_breach,
    )
    waiting = _readiness_reasons(registered, snapshot, statistics).union(look_waiting, population.reasons)
    stopping = registered["stopping_policy"]
    eligibility = evaluate_eligibility(
        EligibilityInputs(
            invalid_reasons=invalid_reasons,
            waiting_reasons=waiting,
            lifecycle_eligible=registered["lifecycle"] in {"approved", "running", "analysis_ready"},
            assignment_integrity_invalid=population.invalid or statistics.assignment_imbalance,
            assignment_verified=population.assignment_verified,
            guardrail_breach=statistics.guardrail_breach,
            safety_stop=stopping["safety_stop"],
            assignment_method=registered["assignment"]["method"],
        )
    )
    direction = registered["metrics"]["primary"]["direction"]
    winner = _winner(statistics, direction) if eligibility.normal_eligible and request.look_type != "safety" else None
    analysis: dict[str, Any] = {
        "analysis_version": 1,
        "input_snapshot_sha256": snapshot.digest,
        "as_of": snapshot.as_of,
        "look_number": request.look_number,
        "look_type": request.look_type,
        "previous_run_ref": previous.get("run_ref") if previous is not None else None,
        "status": eligibility.status,
        "recommended_lifecycle": "analysis_ready" if eligibility.decision_eligible else "running",
        "decision_eligible": eligibility.decision_eligible,
        "variant_results": list(statistics.variant_results),
        "comparisons": list(statistics.comparisons),
        "guardrails": list(statistics.guardrails),
        "causal_status": eligibility.causal_status,
        "winner_variant_id": winner,
        "insufficient_reasons": list(eligibility.reasons),
    }
    analysis["run_ref"] = experiment_run_reference(str(registered["experiment_ref"]), analysis)
    output = copy.deepcopy(registered)
    output["lifecycle"] = analysis["recommended_lifecycle"]
    output["analysis"] = analysis
    output["decision"] = None
    refs = {snapshot.digest}
    if evidence.assignment_ref is not None:
        refs.add("sha256:" + evidence.assignment_ref.rsplit(":", 1)[1])
    output["provenance"]["source_snapshot_refs"] = sorted(refs)
    return output


def record_experiment_decision(
    experiment: dict[str, Any],
    decision: dict[str, Any],
) -> dict[str, Any]:
    """Record an explicit owner-approved decision without provider mutation."""
    registered = register_experiment(experiment)
    analysis = require_object(registered.get("analysis"), "experiment analysis")
    exact(
        decision,
        {"status", "winner_variant_id", "reason", "decided_at", "owner_approval_ref"},
        "experiment decision",
    )
    status = decision.get("status")
    if status not in {"winner", "no_winner", "guardrail_stop", "invalidated"}:
        raise OptimizationError("experiment decision status is unsupported")
    require_text(decision.get("reason"), "decision.reason")
    decided_at = parse_datetime(decision.get("decided_at"), "decision.decided_at")
    if decided_at < parse_datetime(analysis.get("as_of"), "analysis.as_of"):
        raise OptimizationError("decision cannot predate its analysis")
    require_alias(decision.get("owner_approval_ref"), "decision.owner_approval_ref")
    winner = decision.get("winner_variant_id")
    if status == "winner" and (not analysis.get("decision_eligible") or winner != analysis.get("winner_variant_id")):
        raise OptimizationError("winner decision does not match eligible analysis")
    if status == "no_winner" and not analysis.get("decision_eligible"):
        raise OptimizationError("no-winner decision requires eligible analysis")
    if analysis.get("status") == "guardrail_breach" and status != "guardrail_stop":
        raise OptimizationError("guardrail breaches require a guardrail-stop decision")
    if status == "guardrail_stop" and (
        analysis.get("status") != "guardrail_breach" or not analysis.get("decision_eligible")
    ):
        raise OptimizationError("guardrail stop requires a guardrail breach")
    if status != "winner" and winner is not None:
        raise OptimizationError("only winner decisions may name a variant")
    output = copy.deepcopy(registered)
    output["lifecycle"] = "decided"
    output["decision"] = copy.deepcopy(decision)
    assert_public_safe(output, "experiment decision")
    return output
