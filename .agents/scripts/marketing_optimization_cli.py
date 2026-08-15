#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Command handlers for the privacy-safe marketing optimization helper."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from growth_recommendations import RecommendationPolicy
from marketing_attribution import AttributionRequest, build_attribution
from marketing_experiment import ExperimentAnalysisRequest, analyze_experiment, record_experiment_decision
from marketing_experiment_analysis_registry import registered_analysis
from marketing_optimization_contract import OptimizationError
from marketing_optimization_io import (
    SnapshotRequest,
    artifact_path,
    ensure_layout,
    immutable_json,
    immutable_text,
    load_policy,
    load_snapshot,
    publish_snapshot,
    read_immutable_json,
    read_json,
    report_artifact_path,
    resolve_paths,
)
from marketing_optimization_artifact_registry import (
    build_registered_recommendations,
    build_registered_report,
)
from marketing_optimization_registry import (
    analysis_slot_reference,
    assignment_registration_slot_reference,
    decision_slot_reference,
    publish_decision_transition,
    publish_registered_assignment,
    publish_registered_definition,
    publish_successor_transition,
    recommendation_slot_reference,
    registered_assignment,
    registered_definition,
)
from marketing_optimization_report import render_report_markdown
from performance_contract import canonical_json


def _repo(value: str) -> Path:
    """Resolve one requested repository root."""
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise OptimizationError("repository path must be a directory")
    return path


def _print_json(document: Any) -> None:
    """Write canonical machine-readable output."""
    print(canonical_json(document))


def _read_many(paths: list[str], label: str) -> list[dict[str, Any]]:
    """Read explicit aggregate evidence documents in argument order."""
    return [read_json(Path(value).expanduser().absolute(), label) for value in paths]


def _persist_document(
    paths: Any,
    kind: str,
    reference: str,
    document: dict[str, Any],
    dry_run: bool,
) -> None:
    """Publish one immutable derived artifact unless dry-run was requested."""
    if not dry_run:
        immutable_json(paths, artifact_path(paths, kind, reference), document)


def cmd_init(args: argparse.Namespace) -> int:
    """Provision optimization policy and derived-output directories."""
    paths = resolve_paths(_repo(args.repo))
    ensure_layout(paths)
    _print_json({"schema": "aidevops.marketing-optimization-init/v1", "initialized": True})
    return 0


def _count_artifacts(directory: Path, prefixes: tuple[str, ...]) -> int:
    """Count regular immutable JSON artifacts without following symlinks."""
    if not directory.is_dir() or directory.is_symlink():
        return 0
    return sum(
        1
        for item in directory.iterdir()
        if item.is_file() and not item.is_symlink() and item.suffix == ".json" and item.name.startswith(prefixes)
    )


def cmd_status(args: argparse.Namespace) -> int:
    """Report local optimization initialization and artifact counts."""
    paths = resolve_paths(_repo(args.repo))
    initialized = paths.config.is_file() and not paths.config.is_symlink()
    _print_json(
        {
            "schema": "aidevops.marketing-optimization-status/v1",
            "initialized": initialized,
            "artifacts": {
                "attribution": _count_artifacts(paths.attribution, ("mkt-attribution-v1-",)),
                "experiment": _count_artifacts(
                    paths.experiments,
                    (
                        "mkt-experiment-v1-",
                        "mkt-experiment-run-v1-",
                        "mkt-experiment-decision-v1-",
                        "mkt-experiment-identity-v1-",
                        "mkt-assignment-registration-slot-v1-",
                    ),
                ),
                "recommendation": _count_artifacts(paths.recommendations, ("mkt-recommendation-v1-",)),
            },
        }
    )
    return 0


def _snapshot(args: argparse.Namespace, *, account_ref: str | None = None, campaign_id: str | None = None) -> Any:
    """Load the explicit fixture or immutable performance projection."""
    return load_snapshot(
        SnapshotRequest(
            repo=_repo(args.repo),
            input_path=Path(args.input).expanduser() if args.input else None,
            as_of=args.as_of,
            source=getattr(args, "source", None),
            account_ref=account_ref if account_ref is not None else getattr(args, "account_ref", None),
            campaign_id=campaign_id if campaign_id is not None else getattr(args, "campaign_id", None),
        )
    )


def _minimum_cell_size(args: argparse.Namespace, policy: dict[str, Any]) -> int:
    """Resolve a requested threshold without relaxing repository policy."""
    configured = int(policy["default_minimum_cell_size"])
    requested = args.minimum_cell_size if args.minimum_cell_size is not None else configured
    if requested < configured:
        raise OptimizationError("minimum_cell_size cannot be below the configured privacy floor")
    return int(requested)


def cmd_attribution(args: argparse.Namespace) -> int:
    """Build and optionally publish one deterministic attribution projection."""
    paths = resolve_paths(_repo(args.repo))
    policy = load_policy(paths, provision=False)
    snapshot = _snapshot(args)
    request = AttributionRequest(
        outcome_metric_id=args.outcome_metric_id,
        model=args.model or policy["default_attribution_model"],
        lookback_seconds=args.lookback_seconds
        if args.lookback_seconds is not None
        else policy["default_lookback_seconds"],
        refund_maturity_seconds=args.refund_maturity_seconds
        if args.refund_maturity_seconds is not None
        else policy["default_refund_maturity_seconds"],
        minimum_cell_size=_minimum_cell_size(args, policy),
        model_version=args.model_version
        if args.model_version is not None
        else policy["default_attribution_model_version"],
        include_view_through=args.include_view_through,
        account_ref=args.account_ref,
        campaign_id=args.campaign_id,
        currency=args.currency,
        supersedes=args.supersedes,
    )
    projection = build_attribution(snapshot, request)
    publish_snapshot(paths, snapshot, dry_run=args.dry_run)
    _persist_document(paths, "attribution", projection["attribution_ref"], projection, args.dry_run)
    _print_json(projection)
    return 0


def cmd_experiment_register(args: argparse.Namespace) -> int:
    """Publish one approved definition with a trusted append-time receipt."""
    paths = resolve_paths(_repo(args.repo))
    load_policy(paths, provision=False)
    definition = read_json(Path(args.definition).expanduser().absolute(), "experiment definition")
    registered = publish_registered_definition(paths, definition, dry_run=args.dry_run)
    _print_json(registered)
    return 0


def cmd_experiment_assignment_register(args: argparse.Namespace) -> int:
    """Publish assignment evidence with a trusted pre-exposure receipt."""
    paths = resolve_paths(_repo(args.repo))
    load_policy(paths, provision=False)
    definition_input = read_json(Path(args.definition).expanduser().absolute(), "experiment definition")
    assignment = read_json(Path(args.assignment_snapshot).expanduser().absolute(), "assignment snapshot")
    registered = publish_registered_assignment(
        paths,
        definition_input,
        assignment,
        dry_run=args.dry_run,
    )
    definition = registered_definition(paths, definition_input)
    assignment_slot_ref = assignment_registration_slot_reference(definition["experiment_ref"])
    result = (
        {
            "schema": "aidevops.marketing-assignment-registration-result/v1",
            "assignment_ref": registered["assignment_ref"],
            "assignment_slot_ref": assignment_slot_ref,
            "experiment_ref": definition["experiment_ref"],
            "experiment_id": definition["experiment_id"],
            "definition_version": definition["definition_version"],
            "dry_run": True,
        }
        if args.dry_run
        else read_immutable_json(
            paths,
            artifact_path(paths, "experiment", assignment_slot_ref),
            "assignment registration receipt",
        )
    )
    _print_json(result)
    return 0


def cmd_experiment_analyze(args: argparse.Namespace) -> int:
    """Analyse one preregistered look against aggregate-safe evidence."""
    paths = resolve_paths(_repo(args.repo))
    load_policy(paths, provision=False)
    if args.dry_run:
        raise OptimizationError("experiment analysis must persist its look reservation")
    definition_input = read_json(Path(args.definition).expanduser().absolute(), "experiment definition")
    definition = (
        registered_analysis(paths, definition_input)
        if definition_input.get("analysis") is not None
        else registered_definition(paths, definition_input)
    )
    assignment_input = (
        read_json(Path(args.assignment_snapshot).expanduser().absolute(), "assignment snapshot")
        if args.assignment_snapshot
        else None
    )
    assignment = registered_assignment(paths, definition, assignment_input)
    policy = definition["data_policy"]
    snapshot = _snapshot(args, account_ref=policy.get("account_ref"), campaign_id=policy["campaign_id"])
    analysed = analyze_experiment(
        definition,
        snapshot,
        ExperimentAnalysisRequest(args.look_number, args.look_type, assignment),
    )
    publish_snapshot(paths, snapshot, dry_run=False)
    run_ref = analysed["analysis"]["run_ref"]
    slot_ref = analysis_slot_reference(analysed["experiment_ref"], args.look_number)
    if definition.get("analysis") is not None:
        publish_successor_transition(paths, definition, analysed, dry_run=False)
    _persist_document(paths, "experiment", slot_ref, analysed, False)
    _persist_document(paths, "experiment", run_ref, analysed, False)
    _print_json(analysed)
    return 0


def cmd_experiment_decide(args: argparse.Namespace) -> int:
    """Record an explicit owner-approved local experiment decision."""
    paths = resolve_paths(_repo(args.repo))
    load_policy(paths, provision=False)
    experiment_input = read_json(Path(args.experiment).expanduser().absolute(), "analysed experiment")
    experiment = registered_analysis(paths, experiment_input)
    decision = read_json(Path(args.decision).expanduser().absolute(), "experiment decision")
    decided = record_experiment_decision(experiment, decision)
    run_ref = decided["analysis"]["run_ref"]
    slot_ref = decision_slot_reference(decided["experiment_ref"], run_ref)
    decision_ref = publish_decision_transition(paths, decided, dry_run=args.dry_run)
    _persist_document(paths, "experiment", slot_ref, decided, args.dry_run)
    _persist_document(paths, "experiment", decision_ref, decided, args.dry_run)
    _print_json(decided)
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    """Build and optionally publish an aggregate report JSON and Markdown draft."""
    paths = resolve_paths(_repo(args.repo))
    policy = load_policy(paths, provision=False)
    snapshot = _snapshot(args)
    threshold = _minimum_cell_size(args, policy)
    report = build_registered_report(
        paths,
        snapshot,
        _read_many(args.attribution, "attribution"),
        _read_many(args.experiment, "experiment"),
        threshold,
    )
    publish_snapshot(paths, snapshot, dry_run=args.dry_run)
    if not args.dry_run:
        report_path = report_artifact_path(paths, report["report_ref"])
        directory = report_path.parent
        immutable_json(paths, report_path, report)
        immutable_text(paths, directory / "report.md", render_report_markdown(report))
    _print_json(report)
    return 0


def cmd_recommend(args: argparse.Namespace) -> int:
    """Build and optionally publish ranked approval-bound recommendations."""
    paths = resolve_paths(_repo(args.repo))
    policy = load_policy(paths, provision=False)
    report_input = read_json(Path(args.report).expanduser().absolute(), "marketing optimization report")
    recommendation_policy = RecommendationPolicy(
        owner=policy["default_recommendation_owner"],
        required_approval=policy["default_required_approval"],
        time_horizon_seconds=policy["default_recommendation_time_horizon_seconds"],
        rollback_window_seconds=policy["default_rollback_window_seconds"],
        retest_window_seconds=policy["default_retest_window_seconds"],
    )
    recommendations = build_registered_recommendations(
        paths,
        report_input,
        recommendation_policy,
        _read_many(args.prior, "prior recommendation"),
    )
    for recommendation in recommendations:
        _persist_document(
            paths,
            "recommendation",
            recommendation_slot_reference(recommendation),
            recommendation,
            args.dry_run,
        )
        _persist_document(
            paths,
            "recommendation",
            recommendation["recommendation_ref"],
            recommendation,
            args.dry_run,
        )
    _print_json({"schema": "aidevops.growth-recommendations/v1", "recommendations": recommendations})
    return 0
