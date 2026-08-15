#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Mutually exclusive owner-decision and successor-run transitions."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from marketing_optimization_contract import OptimizationError, require_object, typed_reference
from marketing_optimization_io import (
    OptimizationPaths,
    artifact_path,
    immutable_json,
    read_immutable_json,
    read_optional_immutable_json,
)
from marketing_optimization_validation_common import EXPERIMENT_REF_RE, EXPERIMENT_RUN_REF_RE

RUN_TRANSITION_RECEIPT_SCHEMA = "aidevops.marketing-experiment-run-transition/v1"
DECISION_REFERENCE_RE = re.compile(r"^mkt-experiment-decision-v1:[a-f0-9]{64}$")


@dataclass(frozen=True)
class RunTransition:
    """One requested immutable transition from an analyzed run."""

    experiment_ref: str
    run_ref: str
    transition_kind: str
    target_ref: str


def decision_slot_reference(experiment_ref: str, run_ref: str) -> str:
    """Return one immutable concurrency slot for a run's owner decision."""
    return typed_reference(
        "mkt-experiment-decision-slot-v1",
        {"experiment_ref": experiment_ref, "run_ref": run_ref},
    )


def run_transition_slot_reference(experiment_ref: str, run_ref: str) -> str:
    """Return the shared immutable slot for a run's decision or successor."""
    return typed_reference(
        "mkt-experiment-run-transition-slot-v1",
        {"experiment_ref": experiment_ref, "run_ref": run_ref},
    )


def _run_transition_receipt(transition: RunTransition) -> dict[str, Any]:
    """Build one mutually exclusive decision-or-successor receipt."""
    slot_ref = run_transition_slot_reference(transition.experiment_ref, transition.run_ref)
    body: dict[str, Any] = {
        "schema": RUN_TRANSITION_RECEIPT_SCHEMA,
        "transition_slot_ref": slot_ref,
        "experiment_ref": transition.experiment_ref,
        "run_ref": transition.run_ref,
        "transition_kind": transition.transition_kind,
        "target_ref": transition.target_ref,
    }
    body["transition_ref"] = typed_reference("mkt-experiment-run-transition-v1", body)
    return body


def _require_receipt_fields(receipt: dict[str, Any]) -> None:
    """Require the exact immutable transition receipt shape."""
    fields = {
        "schema",
        "transition_slot_ref",
        "experiment_ref",
        "run_ref",
        "transition_kind",
        "target_ref",
        "transition_ref",
    }
    if set(receipt) != fields:
        raise OptimizationError("experiment run transition receipt fields are invalid")


def _validate_run_transition_receipt(
    receipt: dict[str, Any],
    slot_ref: str,
) -> tuple[str, str]:
    """Validate one content-bound run transition receipt."""
    _require_receipt_fields(receipt)
    body = {key: value for key, value in receipt.items() if key != "transition_ref"}
    if receipt.get("schema") != RUN_TRANSITION_RECEIPT_SCHEMA:
        raise OptimizationError("experiment run transition receipt schema is unsupported")
    if typed_reference("mkt-experiment-run-transition-v1", body) != receipt.get("transition_ref"):
        raise OptimizationError("experiment run transition reference does not match its content")
    experiment_ref = str(receipt.get("experiment_ref", ""))
    run_ref = str(receipt.get("run_ref", ""))
    if not EXPERIMENT_REF_RE.fullmatch(experiment_ref) or not EXPERIMENT_RUN_REF_RE.fullmatch(run_ref):
        raise OptimizationError("experiment run transition source reference is invalid")
    expected_slot = run_transition_slot_reference(experiment_ref, run_ref)
    if receipt.get("transition_slot_ref") != slot_ref or expected_slot != slot_ref:
        raise OptimizationError("experiment run transition slot does not match its source")
    transition_kind = str(receipt.get("transition_kind", ""))
    target_ref = str(receipt.get("target_ref", ""))
    target_pattern = {"decision": DECISION_REFERENCE_RE, "successor": EXPERIMENT_RUN_REF_RE}.get(transition_kind)
    if target_pattern is None or not target_pattern.fullmatch(target_ref):
        raise OptimizationError("experiment run transition target is invalid")
    return transition_kind, target_ref


def _transition_conflict(transition_kind: str) -> OptimizationError:
    """Return a stable conflict for the transition that already won."""
    if transition_kind == "decision":
        return OptimizationError("experiment run already has an owner decision")
    return OptimizationError("experiment run already has a successor analysis")


def _matches_transition(existing: dict[str, Any], slot_ref: str, requested: RunTransition) -> bool:
    """Return whether an existing receipt is the requested idempotent transition."""
    existing_kind, existing_target = _validate_run_transition_receipt(existing, slot_ref)
    return existing_kind == requested.transition_kind and existing_target == requested.target_ref


def _reserve_run_transition(
    paths: OptimizationPaths,
    transition: RunTransition,
    *,
    dry_run: bool,
) -> dict[str, Any]:
    """Atomically reserve one mutually exclusive run transition."""
    slot_ref = run_transition_slot_reference(transition.experiment_ref, transition.run_ref)
    slot_path = artifact_path(paths, "experiment", slot_ref)
    expected = _run_transition_receipt(transition)
    existing = read_optional_immutable_json(paths, slot_path, "experiment run transition receipt")
    if existing is not None:
        if _matches_transition(existing, slot_ref, transition):
            return existing
        existing_kind, _target = _validate_run_transition_receipt(existing, slot_ref)
        raise _transition_conflict(existing_kind)
    if dry_run:
        return expected
    try:
        immutable_json(paths, slot_path, expected)
    except OptimizationError:
        winner = read_optional_immutable_json(paths, slot_path, "experiment run transition receipt")
        if winner is None:
            raise
        if _matches_transition(winner, slot_ref, transition):
            return winner
        winner_kind, _target = _validate_run_transition_receipt(winner, slot_ref)
        raise _transition_conflict(winner_kind) from None
    return expected


def publish_successor_transition(
    paths: OptimizationPaths,
    predecessor: dict[str, Any],
    successor: dict[str, Any],
    *,
    dry_run: bool,
) -> dict[str, Any]:
    """Reserve a predecessor run for exactly one successor analysis."""
    previous_analysis = require_object(predecessor.get("analysis"), "predecessor experiment analysis")
    next_analysis = require_object(successor.get("analysis"), "successor experiment analysis")
    previous_run_ref = str(previous_analysis.get("run_ref", ""))
    next_run_ref = str(next_analysis.get("run_ref", ""))
    experiment_ref = str(predecessor.get("experiment_ref", ""))
    if successor.get("experiment_ref") != experiment_ref:
        raise OptimizationError("successor analysis belongs to a different experiment")
    if next_analysis.get("previous_run_ref") != previous_run_ref:
        raise OptimizationError("successor analysis does not identify its predecessor run")
    if next_analysis.get("look_number") != previous_analysis.get("look_number", 0) + 1:
        raise OptimizationError("successor analysis look does not advance exactly once")
    transition = RunTransition(experiment_ref, previous_run_ref, "successor", next_run_ref)
    return _reserve_run_transition(paths, transition, dry_run=dry_run)


def registered_successor_transition(
    paths: OptimizationPaths,
    successor: dict[str, Any],
) -> dict[str, Any]:
    """Require a sequential analysis to own its predecessor transition slot."""
    analysis = require_object(successor.get("analysis"), "successor experiment analysis")
    previous_run_ref = str(analysis.get("previous_run_ref", ""))
    experiment_ref = str(successor.get("experiment_ref", ""))
    slot_ref = run_transition_slot_reference(experiment_ref, previous_run_ref)
    receipt = read_immutable_json(
        paths,
        artifact_path(paths, "experiment", slot_ref),
        "experiment run transition receipt",
    )
    transition_kind, target_ref = _validate_run_transition_receipt(receipt, slot_ref)
    if transition_kind != "successor" or target_ref != analysis.get("run_ref"):
        raise OptimizationError("experiment run transition does not register this successor analysis")
    return receipt


def publish_decision_transition(
    paths: OptimizationPaths,
    decided: dict[str, Any],
    *,
    dry_run: bool,
) -> str:
    """Reserve an analyzed run for exactly one immutable owner decision."""
    analysis = require_object(decided.get("analysis"), "decided experiment analysis")
    decision = require_object(decided.get("decision"), "experiment decision")
    if decided.get("lifecycle") != "decided":
        raise OptimizationError("experiment decision transition requires a decided lifecycle")
    experiment_ref = str(decided.get("experiment_ref", ""))
    run_ref = str(analysis.get("run_ref", ""))
    decision_ref = typed_reference(
        "mkt-experiment-decision-v1",
        {"experiment_ref": experiment_ref, "run_ref": run_ref, "decision": decision},
    )
    transition = RunTransition(experiment_ref, run_ref, "decision", decision_ref)
    _reserve_run_transition(paths, transition, dry_run=dry_run)
    return decision_ref
