#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Immutable run and look resolution for marketing experiment analyses."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from marketing_experiment import ExperimentAnalysisRequest, analyze_experiment
from marketing_experiment_analysis_validation import validate_analysis_semantics
from marketing_experiment_definition import register_experiment
from marketing_experiment_evidence import experiment_run_reference
from marketing_optimization_contract import (
    OptimizationError,
    parse_datetime,
    require_integer,
    require_object,
)
from marketing_optimization_io import (
    OptimizationPaths,
    artifact_path,
    read_immutable_json,
    registered_snapshot,
)
from marketing_optimization_registry import (
    analysis_slot_reference,
    registered_assignment,
    registered_definition,
    registered_successor_transition,
)


@dataclass(frozen=True)
class RunResolutionContext:
    """Stable registry evidence shared across one recursive run-chain lookup."""

    paths: OptimizationPaths
    registered: dict[str, Any]
    assignment: dict[str, Any] | None
    visited: set[str]


def _registered_look(
    paths: OptimizationPaths,
    definition: dict[str, Any],
    look_number: int,
) -> dict[str, Any]:
    """Resolve one canonical analysis through its immutable look reservation."""
    slot_ref = analysis_slot_reference(str(definition["experiment_ref"]), look_number)
    stored = read_immutable_json(paths, artifact_path(paths, "experiment", slot_ref), "registered analysis look")
    canonical = register_experiment(stored)
    if canonical["experiment_ref"] != definition["experiment_ref"]:
        raise OptimizationError("experiment analysis look is not registered for its definition")
    return canonical


def _resolve_registered_run(
    context: RunResolutionContext,
    run_ref: str,
    expected_look: int,
) -> dict[str, Any]:
    """Resolve and recursively validate one immutable sequential run chain."""
    if run_ref in context.visited:
        raise OptimizationError("experiment analysis run chain contains a cycle")
    context.visited.add(run_ref)
    stored = read_immutable_json(
        context.paths,
        artifact_path(context.paths, "experiment", run_ref),
        "registered analysis",
    )
    canonical = register_experiment(stored)
    analysis = require_object(canonical.get("analysis"), "registered analysis")
    look_number = require_integer(
        analysis.get("look_number"),
        "experiment analysis look_number",
        1,
        int(context.registered["stopping_policy"]["allowed_looks"]),
    )
    registration_matches = (
        canonical["experiment_ref"] == context.registered["experiment_ref"],
        analysis.get("run_ref") == run_ref,
        experiment_run_reference(str(context.registered["experiment_ref"]), analysis) == run_ref,
        look_number == expected_look,
        _registered_look(context.paths, context.registered, expected_look) == canonical,
    )
    if not all(registration_matches):
        raise OptimizationError("experiment analysis run chain is not registered")
    validate_analysis_semantics(context.registered, analysis, context.assignment)
    previous_run_ref = analysis.get("previous_run_ref")
    sequential = context.registered["stopping_policy"]["method"] == "sequential"
    if expected_look == 1:
        if previous_run_ref is not None:
            raise OptimizationError("first experiment analysis look cannot name a previous run")
        predecessor = context.registered
    else:
        if not sequential or previous_run_ref is None:
            raise OptimizationError("sequential experiment analysis is missing its previous run")
        previous = _resolve_registered_run(
            context,
            str(previous_run_ref),
            expected_look - 1,
        )
        previous_analysis = require_object(previous.get("analysis"), "previous registered analysis")
        if parse_datetime(analysis["as_of"], "analysis as_of") <= parse_datetime(
            previous_analysis["as_of"],
            "previous analysis as_of",
        ):
            raise OptimizationError("experiment analysis run chain is not chronological")
        registered_successor_transition(context.paths, canonical)
        predecessor = previous
    snapshot = registered_snapshot(context.paths, str(analysis["input_snapshot_sha256"]))
    recomputed = analyze_experiment(
        predecessor,
        snapshot,
        ExperimentAnalysisRequest(
            look_number=look_number,
            look_type=str(analysis["look_type"]),
            assignment_document=context.assignment,
        ),
    )
    if recomputed != canonical:
        raise OptimizationError("experiment analysis does not match recomputed immutable evidence")
    return canonical


def registered_analysis(paths: OptimizationPaths, candidate: dict[str, Any]) -> dict[str, Any]:
    """Return an assignment-bound analysis from its run and look registrations."""
    requested = register_experiment(candidate)
    registered = registered_definition(paths, requested)
    requested_analysis = require_object(requested.get("analysis"), "experiment analysis")
    run_ref = str(requested_analysis.get("run_ref", ""))
    if experiment_run_reference(str(registered["experiment_ref"]), requested_analysis) != run_ref:
        raise OptimizationError("experiment analysis reference does not match its content")
    look_number = require_integer(
        requested_analysis.get("look_number"),
        "experiment analysis look_number",
        1,
        int(registered["stopping_policy"]["allowed_looks"]),
    )
    assignment = registered_assignment(paths, registered, None)
    context = RunResolutionContext(paths, registered, assignment, set())
    canonical = _resolve_registered_run(context, run_ref, look_number)
    if canonical != requested:
        raise OptimizationError("experiment analysis is not registered")
    return canonical
