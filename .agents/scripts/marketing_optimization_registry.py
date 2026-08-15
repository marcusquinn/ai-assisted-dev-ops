#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Immutable registry checks and concurrency slots for optimization evidence."""

from __future__ import annotations

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
from marketing_optimization_run_transition import (
    decision_slot_reference,
    publish_decision_transition,
    publish_successor_transition,
    registered_successor_transition,
    run_transition_slot_reference,
)

DEFINITION_RECEIPT_SCHEMA = "aidevops.marketing-experiment-registration-receipt/v1"
ASSIGNMENT_RECEIPT_SCHEMA = "aidevops.marketing-assignment-registration-receipt/v1"


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


def recommendation_slot_reference(recommendation: dict[str, Any]) -> str:
    """Return an append-only recommendation-generation concurrency slot."""
    return typed_reference(
        "mkt-recommendation-slot-v1",
        {
            "recommendation_key": recommendation["recommendation_key"],
            "supersedes": recommendation["provenance"]["supersedes"],
        },
    )
