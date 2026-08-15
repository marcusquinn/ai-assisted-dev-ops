#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Immutable registry checks and concurrency slots for optimization evidence."""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any

from marketing_experiment_definition import register_experiment
from marketing_experiment_evidence import load_assignment_evidence
from marketing_experiment_policy import validate_configured_experiment_floors
from marketing_optimization_contract import (
    OptimizationError,
    parse_datetime,
    require_object,
    typed_reference,
)
from marketing_optimization_io import (
    OptimizationPaths,
    assignment_artifact_path,
    artifact_path,
    immutable_private_json,
    immutable_json,
    load_policy,
    read_immutable_json,
    read_optional_immutable_json,
)
from marketing_optimization_validation_common import EXPERIMENT_REF_RE, EXPERIMENT_RUN_REF_RE

DEFINITION_RECEIPT_SCHEMA = "aidevops.marketing-experiment-registration-receipt/v1"
ASSIGNMENT_RECEIPT_SCHEMA = "aidevops.marketing-assignment-registration-receipt/v1"
RUN_TRANSITION_RECEIPT_SCHEMA = "aidevops.marketing-experiment-run-transition/v1"
DECISION_REFERENCE_RE = re.compile(r"^mkt-experiment-decision-v1:[a-f0-9]{64}$")


def _utc_now() -> str:
    """Return the trusted local append timestamp in canonical UTC form."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _require_exact_fields(document: dict[str, Any], expected: set[str], label: str) -> None:
    """Reject missing or undeclared receipt fields."""
    if set(document) != expected:
        raise OptimizationError(f"{label} fields are invalid")


def experiment_identity_slot_reference(experiment_id: str, definition_version: int) -> str:
    """Return one immutable slot for a logical experiment definition version."""
    return typed_reference(
        "mkt-experiment-identity-v1",
        {"experiment_id": experiment_id, "definition_version": definition_version},
    )


def assignment_registration_slot_reference(experiment_ref: str) -> str:
    """Return one immutable assignment-registration slot for an experiment."""
    return typed_reference("mkt-assignment-registration-slot-v1", {"experiment_ref": experiment_ref})


def _definition_receipt(
    definition: dict[str, Any],
    slot_ref: str,
    registered_at: str,
) -> dict[str, Any]:
    """Build one content-bound append-time approval and preregistration receipt."""
    body: dict[str, Any] = {
        "schema": DEFINITION_RECEIPT_SCHEMA,
        "experiment_slot_ref": slot_ref,
        "experiment_ref": definition["experiment_ref"],
        "experiment_id": definition["experiment_id"],
        "definition_version": definition["definition_version"],
        "owner": definition["owner"],
        "approval_ref": definition["approval_ref"],
        "preregistered_at": definition["hypothesis"]["preregistered_at"],
        "started_at": definition["data_policy"]["started_at"],
        "registered_at": registered_at,
        "supersedes": definition["provenance"]["supersedes"],
    }
    body["registration_ref"] = typed_reference("mkt-experiment-registration-v1", body)
    return body


def _validate_definition_receipt(
    receipt: dict[str, Any],
    definition: dict[str, Any],
    slot_ref: str,
) -> None:
    """Verify one append-time receipt against its immutable definition."""
    _require_exact_fields(
        receipt,
        {
            "schema",
            "experiment_slot_ref",
            "experiment_ref",
            "experiment_id",
            "definition_version",
            "owner",
            "approval_ref",
            "preregistered_at",
            "started_at",
            "registered_at",
            "supersedes",
            "registration_ref",
        },
        "experiment registration receipt",
    )
    body = {key: value for key, value in receipt.items() if key != "registration_ref"}
    if receipt.get("schema") != DEFINITION_RECEIPT_SCHEMA:
        raise OptimizationError("experiment registration receipt schema is unsupported")
    if typed_reference("mkt-experiment-registration-v1", body) != receipt.get("registration_ref"):
        raise OptimizationError("experiment registration receipt reference does not match its content")
    expected = {
        "experiment_slot_ref": slot_ref,
        "experiment_ref": definition["experiment_ref"],
        "experiment_id": definition["experiment_id"],
        "definition_version": definition["definition_version"],
        "owner": definition["owner"],
        "approval_ref": definition["approval_ref"],
        "preregistered_at": definition["hypothesis"]["preregistered_at"],
        "started_at": definition["data_policy"]["started_at"],
        "supersedes": definition["provenance"]["supersedes"],
    }
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise OptimizationError("experiment registration receipt does not match its definition")
    registered_at = parse_datetime(receipt.get("registered_at"), "experiment registered_at")
    started_at = parse_datetime(definition["data_policy"]["started_at"], "experiment started_at")
    if registered_at >= started_at:
        raise OptimizationError("experiment registration must predate the experiment window")


def _definition_from_receipt(
    paths: OptimizationPaths,
    receipt: dict[str, Any],
    slot_ref: str,
) -> dict[str, Any]:
    """Resolve and validate one canonical definition from its identity receipt."""
    reference = str(receipt.get("experiment_ref", ""))
    stored = read_immutable_json(paths, artifact_path(paths, "experiment", reference), "registered experiment")
    canonical = register_experiment(stored)
    validate_configured_experiment_floors(canonical, load_policy(paths, provision=False))
    if canonical.get("lifecycle") != "approved" or canonical.get("analysis") is not None:
        raise OptimizationError("registered experiment must contain only an approved definition")
    _validate_definition_receipt(receipt, canonical, slot_ref)
    return canonical


def _definition_for_identity(
    paths: OptimizationPaths,
    experiment_id: str,
    definition_version: int,
) -> dict[str, Any]:
    """Resolve one registered definition by its stable logical identity."""
    slot_ref = experiment_identity_slot_reference(experiment_id, definition_version)
    receipt = read_immutable_json(
        paths,
        artifact_path(paths, "experiment", slot_ref),
        "experiment registration receipt",
    )
    return _definition_from_receipt(paths, receipt, slot_ref)


def _validate_definition_supersession(paths: OptimizationPaths, definition: dict[str, Any]) -> None:
    """Require changed logical definitions to advance exactly one registered version."""
    version = int(definition["definition_version"])
    supersedes = definition["provenance"]["supersedes"]
    if version == 1:
        if supersedes is not None:
            raise OptimizationError("experiment definition version one cannot supersede another definition")
        return
    previous = _definition_for_identity(paths, str(definition["experiment_id"]), version - 1)
    if supersedes != previous["experiment_ref"]:
        raise OptimizationError("experiment definition must supersede the preceding registered version")


def publish_registered_definition(
    paths: OptimizationPaths,
    candidate: dict[str, Any],
    *,
    dry_run: bool,
) -> dict[str, Any]:
    """Append one approved definition and its trusted identity receipt."""
    definition = register_experiment(candidate)
    validate_configured_experiment_floors(definition, load_policy(paths, provision=False))
    if definition.get("lifecycle") != "approved" or definition.get("analysis") is not None:
        raise OptimizationError("experiment registration requires an approved definition without analysis")
    slot_ref = experiment_identity_slot_reference(
        str(definition["experiment_id"]),
        int(definition["definition_version"]),
    )
    slot_path = artifact_path(paths, "experiment", slot_ref)
    existing = read_optional_immutable_json(paths, slot_path, "experiment registration receipt")
    if existing is not None:
        canonical = _definition_from_receipt(paths, existing, slot_ref)
        if canonical["experiment_ref"] != definition["experiment_ref"]:
            raise OptimizationError("experiment identity and definition version already identify different content")
        return canonical
    _validate_definition_supersession(paths, definition)
    registered_at = _utc_now()
    if parse_datetime(registered_at, "experiment registered_at") >= parse_datetime(
        definition["data_policy"]["started_at"],
        "experiment started_at",
    ):
        raise OptimizationError("experiment registration must predate the experiment window")
    receipt = _definition_receipt(definition, slot_ref, registered_at)
    if dry_run:
        return definition
    immutable_json(paths, artifact_path(paths, "experiment", definition["experiment_ref"]), definition)
    try:
        immutable_json(paths, slot_path, receipt)
    except OptimizationError:
        winner = read_optional_immutable_json(paths, slot_path, "experiment registration receipt")
        if winner is None:
            raise
        canonical = _definition_from_receipt(paths, winner, slot_ref)
        if canonical["experiment_ref"] != definition["experiment_ref"]:
            raise OptimizationError("experiment identity and definition version already identify different content") from None
        return canonical
    return definition


def registered_definition(paths: OptimizationPaths, candidate: dict[str, Any]) -> dict[str, Any]:
    """Require an experiment's immutable definition and approval to be registered."""
    requested = register_experiment(candidate)
    canonical = _definition_for_identity(
        paths,
        str(requested["experiment_id"]),
        int(requested["definition_version"]),
    )
    if canonical["experiment_ref"] != requested["experiment_ref"]:
        raise OptimizationError("experiment definition is not registered as approved")
    return canonical


def _assignment_receipt(
    definition: dict[str, Any],
    assignment_ref: str,
    slot_ref: str,
    registered_at: str,
) -> dict[str, Any]:
    """Build one append-time receipt that commits assignment before exposure."""
    body: dict[str, Any] = {
        "schema": ASSIGNMENT_RECEIPT_SCHEMA,
        "assignment_slot_ref": slot_ref,
        "assignment_ref": assignment_ref,
        "experiment_ref": definition["experiment_ref"],
        "experiment_id": definition["experiment_id"],
        "definition_version": definition["definition_version"],
        "started_at": definition["data_policy"]["started_at"],
        "registered_at": registered_at,
    }
    body["registration_ref"] = typed_reference("mkt-assignment-registration-v1", body)
    return body


def _validate_assignment_receipt(
    receipt: dict[str, Any],
    definition: dict[str, Any],
    assignment_ref: str,
    slot_ref: str,
) -> None:
    """Verify one assignment receipt and its trusted pre-exposure timestamp."""
    _require_exact_fields(
        receipt,
        {
            "schema",
            "assignment_slot_ref",
            "assignment_ref",
            "experiment_ref",
            "experiment_id",
            "definition_version",
            "started_at",
            "registered_at",
            "registration_ref",
        },
        "assignment registration receipt",
    )
    body = {key: value for key, value in receipt.items() if key != "registration_ref"}
    if receipt.get("schema") != ASSIGNMENT_RECEIPT_SCHEMA:
        raise OptimizationError("assignment registration receipt schema is unsupported")
    if typed_reference("mkt-assignment-registration-v1", body) != receipt.get("registration_ref"):
        raise OptimizationError("assignment registration receipt reference does not match its content")
    expected = {
        "assignment_slot_ref": slot_ref,
        "assignment_ref": assignment_ref,
        "experiment_ref": definition["experiment_ref"],
        "experiment_id": definition["experiment_id"],
        "definition_version": definition["definition_version"],
        "started_at": definition["data_policy"]["started_at"],
    }
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise OptimizationError("assignment registration receipt does not match its experiment")
    registered_at = parse_datetime(receipt.get("registered_at"), "assignment registered_at")
    started_at = parse_datetime(definition["data_policy"]["started_at"], "experiment started_at")
    if registered_at >= started_at:
        raise OptimizationError("assignment registration must predate the experiment window")


def _assignment_from_receipt(
    paths: OptimizationPaths,
    definition: dict[str, Any],
    receipt: dict[str, Any],
    slot_ref: str,
) -> dict[str, Any]:
    """Resolve canonical assignment evidence through its registration receipt."""
    assignment_ref = str(receipt.get("assignment_ref", ""))
    stored = read_immutable_json(
        paths,
        assignment_artifact_path(paths, assignment_ref),
        "registered assignment",
    )
    evidence = load_assignment_evidence(stored, definition)
    if not evidence.verified or evidence.assignment_ref != assignment_ref:
        raise OptimizationError("assignment evidence is not eligible for verified analysis")
    _validate_assignment_receipt(receipt, definition, assignment_ref, slot_ref)
    return stored


def publish_registered_assignment(
    paths: OptimizationPaths,
    definition_candidate: dict[str, Any],
    assignment: dict[str, Any],
    *,
    dry_run: bool,
) -> dict[str, Any]:
    """Append verified assignment evidence and a trusted pre-exposure receipt."""
    definition = registered_definition(paths, definition_candidate)
    evidence = load_assignment_evidence(assignment, definition)
    if not evidence.verified or evidence.assignment_ref is None:
        raise OptimizationError("only verified assignment evidence can be registered")
    slot_ref = assignment_registration_slot_reference(str(definition["experiment_ref"]))
    slot_path = artifact_path(paths, "experiment", slot_ref)
    existing = read_optional_immutable_json(paths, slot_path, "assignment registration receipt")
    if existing is not None:
        canonical = _assignment_from_receipt(paths, definition, existing, slot_ref)
        if existing.get("assignment_ref") != evidence.assignment_ref:
            raise OptimizationError("experiment assignment registration already identifies different content")
        return canonical
    registered_at = _utc_now()
    if parse_datetime(registered_at, "assignment registered_at") >= parse_datetime(
        definition["data_policy"]["started_at"],
        "experiment started_at",
    ):
        raise OptimizationError("assignment registration must predate the experiment window")
    receipt = _assignment_receipt(definition, evidence.assignment_ref, slot_ref, registered_at)
    if dry_run:
        return assignment
    immutable_private_json(paths, assignment_artifact_path(paths, evidence.assignment_ref), assignment)
    try:
        immutable_json(paths, slot_path, receipt)
    except OptimizationError:
        winner = read_optional_immutable_json(paths, slot_path, "assignment registration receipt")
        if winner is None:
            raise
        canonical = _assignment_from_receipt(paths, definition, winner, slot_ref)
        if winner.get("assignment_ref") != evidence.assignment_ref:
            raise OptimizationError("experiment assignment registration already identifies different content") from None
        return canonical
    return assignment


def registered_assignment(
    paths: OptimizationPaths,
    definition: dict[str, Any],
    candidate: dict[str, Any] | None,
) -> dict[str, Any] | None:
    """Require declared assignment evidence to match its registered immutable artifact."""
    declared_ref = definition["assignment"].get("snapshot_ref")
    if declared_ref is None:
        if candidate is not None:
            raise OptimizationError("assignment evidence is not declared by the experiment")
        return None
    if candidate is not None:
        evidence = load_assignment_evidence(candidate, definition)
        if not evidence.verified or evidence.assignment_ref != declared_ref:
            raise OptimizationError("assignment evidence is not eligible for verified analysis")
    slot_ref = assignment_registration_slot_reference(str(definition["experiment_ref"]))
    receipt = read_immutable_json(
        paths,
        artifact_path(paths, "experiment", slot_ref),
        "assignment registration receipt",
    )
    return _assignment_from_receipt(paths, definition, receipt, slot_ref)


def analysis_slot_reference(experiment_ref: str, look_number: int) -> str:
    """Return one immutable concurrency slot for an experiment look number."""
    return typed_reference(
        "mkt-experiment-look-v1",
        {"experiment_ref": experiment_ref, "look_number": look_number},
    )


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


def _run_transition_receipt(
    experiment_ref: str,
    run_ref: str,
    transition_kind: str,
    target_ref: str,
) -> dict[str, Any]:
    """Build one mutually exclusive decision-or-successor receipt."""
    slot_ref = run_transition_slot_reference(experiment_ref, run_ref)
    body: dict[str, Any] = {
        "schema": RUN_TRANSITION_RECEIPT_SCHEMA,
        "transition_slot_ref": slot_ref,
        "experiment_ref": experiment_ref,
        "run_ref": run_ref,
        "transition_kind": transition_kind,
        "target_ref": target_ref,
    }
    body["transition_ref"] = typed_reference("mkt-experiment-run-transition-v1", body)
    return body


def _validate_run_transition_receipt(
    receipt: dict[str, Any],
    slot_ref: str,
) -> tuple[str, str]:
    """Validate one content-bound run transition receipt."""
    _require_exact_fields(
        receipt,
        {
            "schema",
            "transition_slot_ref",
            "experiment_ref",
            "run_ref",
            "transition_kind",
            "target_ref",
            "transition_ref",
        },
        "experiment run transition receipt",
    )
    body = {key: value for key, value in receipt.items() if key != "transition_ref"}
    if receipt.get("schema") != RUN_TRANSITION_RECEIPT_SCHEMA:
        raise OptimizationError("experiment run transition receipt schema is unsupported")
    if typed_reference("mkt-experiment-run-transition-v1", body) != receipt.get("transition_ref"):
        raise OptimizationError("experiment run transition reference does not match its content")
    experiment_ref = str(receipt.get("experiment_ref", ""))
    run_ref = str(receipt.get("run_ref", ""))
    if not EXPERIMENT_REF_RE.fullmatch(experiment_ref) or not EXPERIMENT_RUN_REF_RE.fullmatch(run_ref):
        raise OptimizationError("experiment run transition source reference is invalid")
    if (
        receipt.get("transition_slot_ref") != slot_ref
        or run_transition_slot_reference(experiment_ref, run_ref) != slot_ref
    ):
        raise OptimizationError("experiment run transition slot does not match its source")
    transition_kind = str(receipt.get("transition_kind", ""))
    target_ref = str(receipt.get("target_ref", ""))
    target_pattern = {
        "decision": DECISION_REFERENCE_RE,
        "successor": EXPERIMENT_RUN_REF_RE,
    }.get(transition_kind)
    if target_pattern is None or not target_pattern.fullmatch(target_ref):
        raise OptimizationError("experiment run transition target is invalid")
    return transition_kind, target_ref


def _transition_conflict(transition_kind: str) -> OptimizationError:
    """Return a stable conflict for the transition that already won."""
    if transition_kind == "decision":
        return OptimizationError("experiment run already has an owner decision")
    return OptimizationError("experiment run already has a successor analysis")


def _reserve_run_transition(
    paths: OptimizationPaths,
    experiment_ref: str,
    run_ref: str,
    transition_kind: str,
    target_ref: str,
    *,
    dry_run: bool,
) -> dict[str, Any]:
    """Atomically reserve one mutually exclusive run transition."""
    slot_ref = run_transition_slot_reference(experiment_ref, run_ref)
    slot_path = artifact_path(paths, "experiment", slot_ref)
    expected = _run_transition_receipt(experiment_ref, run_ref, transition_kind, target_ref)
    existing = read_optional_immutable_json(paths, slot_path, "experiment run transition receipt")
    if existing is not None:
        existing_kind, existing_target = _validate_run_transition_receipt(existing, slot_ref)
        if existing_kind == transition_kind and existing_target == target_ref:
            return existing
        raise _transition_conflict(existing_kind)
    if dry_run:
        return expected
    try:
        immutable_json(paths, slot_path, expected)
    except OptimizationError:
        winner = read_optional_immutable_json(paths, slot_path, "experiment run transition receipt")
        if winner is None:
            raise
        winner_kind, winner_target = _validate_run_transition_receipt(winner, slot_ref)
        if winner_kind == transition_kind and winner_target == target_ref:
            return winner
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
    return _reserve_run_transition(
        paths,
        experiment_ref,
        previous_run_ref,
        "successor",
        next_run_ref,
        dry_run=dry_run,
    )


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
    """Reserve an analysed run for exactly one immutable owner decision."""
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
    _reserve_run_transition(
        paths,
        experiment_ref,
        run_ref,
        "decision",
        decision_ref,
        dry_run=dry_run,
    )
    return decision_ref


def recommendation_slot_reference(recommendation: dict[str, Any]) -> str:
    """Return an append-only recommendation-generation concurrency slot."""
    return typed_reference(
        "mkt-recommendation-slot-v1",
        {
            "recommendation_key": recommendation["recommendation_key"],
            "supersedes": recommendation["provenance"]["supersedes"],
        },
    )
