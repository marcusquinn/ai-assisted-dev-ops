#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Immutable registry resolution for externally supplied optimization artifacts."""

from __future__ import annotations

from typing import Any

from growth_recommendations import RecommendationPolicy, _build_recommendations_from_resolved_report
from growth_recommendation_validation import validate_recommendation_artifact
from marketing_attribution import AttributionRequest, build_attribution
from marketing_attribution_validation import validate_attribution_artifact
from marketing_experiment_analysis_registry import registered_analysis
from marketing_optimization_contract import OptimizationError, OptimizationSnapshot
from marketing_optimization_io import (
    OptimizationPaths,
    artifact_path,
    load_policy,
    read_immutable_json,
    registered_snapshot,
    report_artifact_path,
    snapshot_document,
    snapshot_from_document,
)
from marketing_optimization_report import _build_report_from_resolved_evidence
from marketing_report_validation import validate_report_artifact


def _attribution_replay_currency(
    stored: dict[str, Any],
    snapshot: OptimizationSnapshot,
) -> str | None:
    """Recover a replay-equivalent currency request from a v1 artifact."""
    selected = stored["scope"]["currency"]
    if selected is not None:
        return str(selected)
    if "currency_mismatch" not in stored["uncertainty"]["reasons"]:
        return None
    metric_id = str(stored["scope"]["outcome_metric_id"])
    observed = {
        str(event["measurement"]["currency"])
        for event in snapshot.events
        if event["measurement"]["metric_id"] == metric_id
        and event["measurement"].get("currency") is not None
    }
    if len(observed) != 1:
        return None
    return "ZZZ" if "ZZZ" not in observed else "XXX"


def registered_attribution(paths: OptimizationPaths, candidate: dict[str, Any]) -> dict[str, Any]:
    """Resolve and recompute attribution from its immutable source snapshot."""
    requested_ref = validate_attribution_artifact(candidate)
    stored = read_immutable_json(
        paths,
        artifact_path(paths, "attribution", requested_ref),
        "registered attribution",
    )
    if validate_attribution_artifact(stored) != requested_ref or stored != candidate:
        raise OptimizationError("attribution evidence is not registered")
    minimum_cell_size = int(stored["coverage"]["minimum_cell_size"])
    configured_floor = int(load_policy(paths, provision=False)["default_minimum_cell_size"])
    if minimum_cell_size < configured_floor:
        raise OptimizationError("registered attribution relaxes the configured privacy floor")
    snapshot = registered_snapshot(paths, str(stored["run"]["input_snapshot_sha256"]))
    request = AttributionRequest(
        outcome_metric_id=str(stored["scope"]["outcome_metric_id"]),
        model=str(stored["model"]["id"]),
        lookback_seconds=int(stored["model"]["lookback_seconds"]),
        refund_maturity_seconds=int(stored["window"]["refund_maturity_seconds"]),
        minimum_cell_size=minimum_cell_size,
        model_version=int(stored["model"]["version"]),
        include_view_through=bool(stored["model"]["include_view_through"]),
        account_ref=stored["scope"]["account_ref"],
        campaign_id=stored["scope"]["campaign_id"],
        currency=_attribution_replay_currency(stored, snapshot),
        supersedes=stored["provenance"]["supersedes"],
    )
    if build_attribution(snapshot, request) != stored:
        raise OptimizationError("attribution does not match recomputed immutable evidence")
    return stored


def build_registered_report(
    paths: OptimizationPaths,
    snapshot: OptimizationSnapshot,
    attribution_candidates: list[dict[str, Any]],
    experiment_candidates: list[dict[str, Any]],
    minimum_cell_size: int,
) -> dict[str, Any]:
    """Build a report only after resolving every supplied evidence artifact."""
    if not isinstance(snapshot, OptimizationSnapshot):
        raise OptimizationError("report snapshot must be a validated optimization snapshot")
    canonical_snapshot = snapshot_from_document(snapshot_document(snapshot))
    if canonical_snapshot != snapshot:
        raise OptimizationError("report snapshot does not match its canonical digest")
    configured_floor = int(load_policy(paths, provision=False)["default_minimum_cell_size"])
    if minimum_cell_size < configured_floor:
        raise OptimizationError("report minimum_cell_size cannot relax the configured privacy floor")
    attributions = [registered_attribution(paths, item) for item in attribution_candidates]
    experiments = [registered_analysis(paths, item) for item in experiment_candidates]
    return _build_report_from_resolved_evidence(
        canonical_snapshot,
        attributions,
        experiments,
        minimum_cell_size,
    )


def registered_report(paths: OptimizationPaths, candidate: dict[str, Any]) -> dict[str, Any]:
    """Resolve and recompute a report and all of its immutable evidence."""
    requested_ref = validate_report_artifact(candidate)
    stored = read_immutable_json(
        paths,
        report_artifact_path(paths, requested_ref),
        "registered marketing optimization report",
    )
    if validate_report_artifact(stored) != requested_ref or stored != candidate:
        raise OptimizationError("marketing optimization report is not registered")
    snapshot = registered_snapshot(paths, str(stored["run"]["input_snapshot_sha256"]))
    attributions = []
    for summary in stored["attributions"]:
        reference = str(summary["attribution_ref"])
        attribution = read_immutable_json(
            paths,
            artifact_path(paths, "attribution", reference),
            "registered report attribution",
        )
        attributions.append(registered_attribution(paths, attribution))
    experiments = []
    for summary in stored["experiments"]:
        reference = str(summary["run_ref"])
        experiment = read_immutable_json(
            paths,
            artifact_path(paths, "experiment", reference),
            "registered report experiment",
        )
        experiments.append(registered_analysis(paths, experiment))
    minimum_cell_size = int(stored["quality"]["minimum_cell_size"])
    configured_floor = int(load_policy(paths, provision=False)["default_minimum_cell_size"])
    if minimum_cell_size < configured_floor:
        raise OptimizationError("registered report relaxes the configured privacy floor")
    if _build_report_from_resolved_evidence(snapshot, attributions, experiments, minimum_cell_size) != stored:
        raise OptimizationError("marketing optimization report does not match recomputed immutable evidence")
    return stored


def _registered_recommendation(
    paths: OptimizationPaths,
    candidate: dict[str, Any],
    visited: set[str],
) -> dict[str, Any]:
    """Resolve and recompute one recommendation and its supersession chain."""
    requested_ref = validate_recommendation_artifact(candidate)
    if requested_ref in visited:
        raise OptimizationError("growth recommendation supersession contains a cycle")
    visited.add(requested_ref)
    stored = read_immutable_json(
        paths,
        artifact_path(paths, "recommendation", requested_ref),
        "registered growth recommendation",
    )
    if validate_recommendation_artifact(stored) != requested_ref or stored != candidate:
        raise OptimizationError("growth recommendation is not registered")
    report_ref = str(stored["provenance"]["report_ref"])
    report_candidate = read_immutable_json(
        paths,
        report_artifact_path(paths, report_ref),
        "registered recommendation report",
    )
    report = registered_report(paths, report_candidate)
    prior: list[dict[str, Any]] = []
    supersedes = stored["provenance"]["supersedes"]
    if supersedes is not None:
        previous = read_immutable_json(
            paths,
            artifact_path(paths, "recommendation", str(supersedes)),
            "superseded growth recommendation",
        )
        prior.append(_registered_recommendation(paths, previous, visited))
    recommendation_policy = RecommendationPolicy(
        owner=str(stored["authority"]["owner"]),
        required_approval=str(stored["authority"]["required_approval"]),
        time_horizon_seconds=int(stored["expected_impact"]["time_horizon_seconds"]),
        rollback_window_seconds=int(stored["rollback"]["window_seconds"]),
        retest_window_seconds=int(stored["retest"]["window_seconds"]),
    )
    recomputed = _build_recommendations_from_resolved_report(report, recommendation_policy, prior)
    matching = next(
        (item for item in recomputed if item["recommendation_ref"] == requested_ref),
        None,
    )
    if matching != stored:
        raise OptimizationError("growth recommendation does not match recomputed immutable evidence")
    return stored


def registered_recommendation(paths: OptimizationPaths, candidate: dict[str, Any]) -> dict[str, Any]:
    """Resolve a recomputed prior recommendation from immutable storage."""
    return _registered_recommendation(paths, candidate, set())


def build_registered_recommendations(
    paths: OptimizationPaths,
    report_candidate: dict[str, Any],
    policy: RecommendationPolicy,
    prior_candidates: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Build recommendations only from a registered report and prior chain."""
    report = registered_report(paths, report_candidate)
    prior = [registered_recommendation(paths, item) for item in (prior_candidates or [])]
    return _build_recommendations_from_resolved_report(report, policy, prior)
