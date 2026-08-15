#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation for local pseudonymous marketing experiment assignment evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from marketing_optimization_contract import (
    SUBJECT_REF_RE,
    OptimizationError,
    assert_public_safe,
    parse_datetime,
    require_list,
    require_object,
    typed_reference,
)
from marketing_optimization_validation_common import exact
from performance_contract import require_alias


@dataclass(frozen=True)
class AssignmentEvidence:
    """Validated local assignment evidence; never emitted as audience rows."""

    assignment_ref: str | None
    assignments: dict[str, str]
    assigned_at: dict[str, str]
    verified: bool
    reasons: tuple[str, ...]


def experiment_run_reference(experiment_ref: str, analysis: dict[str, Any]) -> str:
    """Bind one analysis run reference to its immutable experiment definition."""
    body = {key: value for key, value in analysis.items() if key != "run_ref"}
    return typed_reference(
        "mkt-experiment-run-v1",
        {"experiment_ref": experiment_ref, "analysis": body},
    )


def _assignment_reference(document: dict[str, Any]) -> str:
    """Derive the assignment reference without trusting its declared value."""
    body = {key: value for key, value in document.items() if key != "assignment_ref"}
    return typed_reference("mkt-assignment-v1:sha256", body)


def _assignment_rows(
    document: dict[str, Any],
    variant_ids: set[str],
) -> tuple[dict[str, str], dict[str, str]]:
    """Validate unique pseudonymous subject assignments."""
    assignments: dict[str, str] = {}
    assigned_at: dict[str, str] = {}
    rows = require_list(document.get("assignments"), "assignment snapshot assignments")
    for index, value in enumerate(rows):
        row = exact(
            value,
            {"unit_ref", "variant_id", "assigned_at"},
            f"assignments[{index}]",
        )
        subject_ref = str(row.get("unit_ref", ""))
        variant_id = require_alias(row.get("variant_id"), f"assignments[{index}].variant_id")
        timestamp = str(row.get("assigned_at", ""))
        if not SUBJECT_REF_RE.fullmatch(subject_ref):
            raise OptimizationError("assignment unit_ref must be a pseudonymous subject reference")
        if variant_id not in variant_ids:
            raise OptimizationError("assignment references an unknown variant")
        parse_datetime(timestamp, f"assignments[{index}].assigned_at")
        if subject_ref in assignments:
            raise OptimizationError("assignment snapshot contains duplicate assignments")
        assignments[subject_ref] = variant_id
        assigned_at[subject_ref] = timestamp
    return assignments, assigned_at


def load_assignment_evidence(
    document: dict[str, Any] | None,
    definition: dict[str, Any],
) -> AssignmentEvidence:
    """Validate optional assignment evidence against the preregistration."""
    assignment = require_object(definition.get("assignment"), "experiment assignment")
    declared_ref = assignment.get("snapshot_ref")
    supported = (
        assignment.get("unit") == "subject"
        and assignment.get("method") == "randomized"
        and assignment.get("sticky") is True
    )
    declared_verified = assignment.get("verification") == "verified" and declared_ref is not None
    if document is None:
        reason = "missing_assignment_snapshot" if declared_verified else "assignment_unverified"
        return AssignmentEvidence(None, {}, {}, False, (reason,))
    exact(
        document,
        {
            "schema",
            "experiment_id",
            "definition_version",
            "generated_at",
            "assignments",
            "assignment_ref",
        },
        "assignment snapshot",
    )
    if document.get("schema") != "aidevops.marketing-assignment-snapshot/v1":
        raise OptimizationError("assignment snapshot schema is unsupported")
    if document.get("experiment_id") != definition.get("experiment_id"):
        raise OptimizationError("assignment snapshot experiment_id does not match")
    if document.get("definition_version") != definition.get("definition_version"):
        raise OptimizationError("assignment snapshot definition_version does not match")
    parse_datetime(document.get("generated_at"), "assignment snapshot generated_at")
    assert_public_safe(document, "assignment snapshot")
    expected_ref = _assignment_reference(document)
    if document.get("assignment_ref") != expected_ref or declared_ref != expected_ref:
        raise OptimizationError("assignment snapshot reference does not match its content")
    variant_ids = {str(item["variant_id"]) for item in require_list(definition.get("variants"), "variants")}
    assignments, assigned_at = _assignment_rows(document, variant_ids)
    verified = supported and declared_verified
    reasons: list[str] = []
    if not supported:
        reasons.append("unsupported_assignment_method")
    if not declared_verified:
        reasons.append("assignment_unverified")
    if not assignments:
        reasons.append("empty_assignment_snapshot")
        verified = False
    return AssignmentEvidence(expected_ref, assignments, assigned_at, verified, tuple(sorted(reasons)))


def validate_previous_analysis(
    definition: dict[str, Any],
    snapshot_as_of: str,
    look_number: int,
) -> dict[str, Any] | None:
    """Require sequential looks to form one verified monotonic run chain."""
    previous_value = definition.get("analysis")
    method = definition["stopping_policy"]["method"]
    if previous_value is None:
        if method == "sequential" and look_number != 1:
            raise OptimizationError("sequential experiment looks must start at one")
        return None
    previous = require_object(previous_value, "previous experiment analysis")
    run_ref = str(previous.get("run_ref", ""))
    if experiment_run_reference(str(definition["experiment_ref"]), previous) != run_ref:
        raise OptimizationError("previous experiment analysis reference does not match its content")
    if method != "sequential" or look_number != previous.get("look_number", 0) + 1:
        raise OptimizationError("experiment analysis looks must advance exactly once")
    if parse_datetime(snapshot_as_of, "analysis as_of") <= parse_datetime(previous.get("as_of"), "previous analysis as_of"):
        raise OptimizationError("experiment analysis looks require a later snapshot")
    return previous
