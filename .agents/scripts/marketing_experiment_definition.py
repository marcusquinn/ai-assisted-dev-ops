#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Immutable preregistration validation for marketing experiments."""

from __future__ import annotations

import copy
import re
from decimal import Decimal
from typing import Any

from marketing_experiment_analysis_validation import validate_analysis_shape
from marketing_experiment_evidence import experiment_run_reference
from marketing_experiment_policy import validate_metrics, validate_privacy_and_data, validate_sample_and_stopping
from marketing_optimization_contract import (
    OptimizationError,
    assert_public_safe,
    number,
    parse_datetime,
    require_integer,
    require_list,
    require_metric,
    require_object,
    require_text,
    typed_reference,
)
from marketing_optimization_validation_common import exact
from performance_contract import require_alias

EXPERIMENT_REF_RE = re.compile(r"^mkt-experiment-v1:[a-f0-9]{64}$")
SNAPSHOT_REF_RE = re.compile(r"^sha256:[a-f0-9]{64}$")
LIFECYCLES = {"draft", "approved", "running", "analysis_ready", "decided", "archived"}
IMMUTABLE_FIELDS = (
    "schema_version",
    "experiment_id",
    "definition_version",
    "owner",
    "approval_ref",
    "hypothesis",
    "variants",
    "assignment",
    "metrics",
    "sample_plan",
    "stopping_policy",
    "privacy",
    "data_policy",
)
DEFINITION_FIELDS = set(IMMUTABLE_FIELDS).union({"lifecycle", "decision", "provenance"})
OPTIONAL_DEFINITION_FIELDS = {"experiment_ref", "analysis"}


def _validate_definition_fields(definition: dict[str, Any]) -> None:
    """Reject missing or undeclared experiment definition fields."""
    fields = set(definition)
    if DEFINITION_FIELDS - fields or fields - DEFINITION_FIELDS - OPTIONAL_DEFINITION_FIELDS:
        raise OptimizationError("experiment fields are invalid")


def _definition_reference(definition: dict[str, Any]) -> str:
    """Hash immutable preregistration fields independently of lifecycle state."""
    body = {field: definition[field] for field in IMMUTABLE_FIELDS}
    provenance = require_object(definition["provenance"], "experiment provenance")
    body["supersedes"] = provenance.get("supersedes")
    return typed_reference("mkt-experiment-v1", body)


def _validate_variants(definition: dict[str, Any]) -> None:
    """Validate unique control/treatment variants and exact allocation."""
    variants = [
        exact(item, {"variant_id", "role", "asset_snapshot_ref", "allocation"}, "variant")
        for item in require_list(definition.get("variants"), "variants")
    ]
    if not 2 <= len(variants) <= 50:
        raise OptimizationError("experiments require between two and fifty variants")
    variant_ids = [require_alias(item.get("variant_id"), "variant_id") for item in variants]
    if len(variant_ids) != len(set(variant_ids)):
        raise OptimizationError("experiment variant IDs must be unique")
    roles = [item.get("role") for item in variants]
    if roles.count("control") != 1 or any(role not in {"control", "treatment"} for role in roles):
        raise OptimizationError("experiments require one control and one or more treatments")
    allocations = [number(item.get("allocation"), "variant allocation") for item in variants]
    if any(value <= 0 for value in allocations) or sum(allocations, Decimal(0)) != Decimal(1):
        raise OptimizationError("variant allocations must be positive and sum exactly to one")
    for item in variants:
        require_alias(item.get("asset_snapshot_ref"), "asset_snapshot_ref")


def _validate_assignment(definition: dict[str, Any]) -> None:
    """Validate declared assignment and exposure evidence policy."""
    assignment = exact(
        definition.get("assignment"),
        {
            "unit",
            "method",
            "verification",
            "snapshot_ref",
            "sticky",
            "exposure_metric_id",
            "contamination_policy",
        },
        "assignment",
    )
    require_metric(assignment.get("exposure_metric_id"), "assignment.exposure_metric_id")
    if assignment.get("unit") not in {"subject", "account", "session", "geo"}:
        raise OptimizationError("assignment.unit is unsupported")
    if assignment.get("method") not in {"randomized", "deterministic_split", "observational"}:
        raise OptimizationError("assignment.method is unsupported")
    if assignment.get("verification") not in {"verified", "unverified"}:
        raise OptimizationError("assignment.verification is unsupported")
    if not isinstance(assignment.get("sticky"), bool):
        raise OptimizationError("assignment.sticky must be boolean")
    snapshot_ref = assignment.get("snapshot_ref")
    if snapshot_ref is not None and not re.fullmatch(r"mkt-assignment-v1:sha256:[a-f0-9]{64}", str(snapshot_ref)):
        raise OptimizationError("assignment.snapshot_ref is invalid")
    if assignment.get("verification") == "verified" and snapshot_ref is None:
        raise OptimizationError("verified assignment requires snapshot_ref")
    if assignment.get("method") == "observational" and assignment.get("verification") == "verified":
        raise OptimizationError("observational assignment cannot be marked verified")
    if assignment.get("contamination_policy") not in {"exclude_crossovers", "mark_invalid"}:
        raise OptimizationError("assignment.contamination_policy is unsupported")


def _validate_provenance(definition: dict[str, Any]) -> None:
    """Validate immutable source and supersession references."""
    provenance = exact(
        definition.get("provenance"),
        {"source_snapshot_refs", "supersedes"},
        "provenance",
    )
    for item in require_list(provenance.get("source_snapshot_refs"), "source_snapshot_refs"):
        if not SNAPSHOT_REF_RE.fullmatch(str(item)):
            raise OptimizationError("source_snapshot_refs contains an invalid digest")
    supersedes = provenance.get("supersedes")
    if supersedes is not None and not EXPERIMENT_REF_RE.fullmatch(str(supersedes)):
        raise OptimizationError("experiment supersedes reference is invalid")


def _validate_decision(value: Any) -> None:
    """Validate an optional owner decision without accepting undeclared fields."""
    if value is None:
        return
    decision = exact(
        value,
        {"status", "winner_variant_id", "reason", "decided_at", "owner_approval_ref"},
        "experiment decision",
    )
    status = decision["status"]
    if status not in {"winner", "no_winner", "guardrail_stop", "invalidated"}:
        raise OptimizationError("experiment decision status is unsupported")
    winner = decision["winner_variant_id"]
    if winner is not None:
        require_alias(winner, "experiment decision winner_variant_id")
    if (status == "winner") != (winner is not None):
        raise OptimizationError("experiment winner decision is inconsistent")
    require_text(decision["reason"], "experiment decision reason")
    parse_datetime(decision["decided_at"], "experiment decision decided_at")
    require_alias(decision["owner_approval_ref"], "experiment decision owner_approval_ref")


def register_experiment(definition: dict[str, Any]) -> dict[str, Any]:
    """Validate and reference one immutable preregistration version."""
    assert_public_safe(definition, "experiment")
    _validate_definition_fields(definition)
    if definition.get("schema_version") != 1:
        raise OptimizationError("experiment schema_version is unsupported")
    require_alias(definition.get("experiment_id"), "experiment_id")
    require_integer(definition.get("definition_version"), "definition_version", 1, 1000000)
    lifecycle = definition.get("lifecycle")
    if lifecycle not in LIFECYCLES:
        raise OptimizationError("experiment lifecycle is unsupported")
    require_alias(definition.get("owner"), "owner")
    approval_ref = definition.get("approval_ref")
    if lifecycle == "draft":
        if approval_ref is not None:
            require_alias(approval_ref, "approval_ref")
    else:
        require_alias(approval_ref, "approval_ref")
    hypothesis = exact(
        definition.get("hypothesis"),
        {"change", "expected_direction", "rationale", "preregistered_at"},
        "hypothesis",
    )
    require_text(hypothesis.get("change"), "hypothesis.change")
    require_text(hypothesis.get("rationale"), "hypothesis.rationale")
    if hypothesis.get("expected_direction") not in {"increase", "decrease", "non_inferior"}:
        raise OptimizationError("hypothesis.expected_direction is unsupported")
    preregistered = parse_datetime(hypothesis.get("preregistered_at"), "hypothesis.preregistered_at")
    _validate_variants(definition)
    _validate_assignment(definition)
    validate_metrics(definition)
    validate_sample_and_stopping(definition)
    validate_privacy_and_data(definition)
    started = parse_datetime(definition["data_policy"]["started_at"], "data_policy.started_at")
    if preregistered >= started:
        raise OptimizationError("experiment preregistration must predate the experiment window")
    _validate_provenance(definition)
    analysis: dict[str, Any] | None = None
    if "analysis" in definition:
        analysis = require_object(definition["analysis"], "experiment analysis")
        validate_analysis_shape(definition, analysis)
    _validate_decision(definition.get("decision"))
    output = copy.deepcopy(definition)
    expected_ref = _definition_reference(output)
    declared_ref = output.get("experiment_ref")
    if declared_ref is not None and declared_ref != expected_ref:
        raise OptimizationError("experiment_ref does not match the preregistration")
    if analysis is not None and experiment_run_reference(expected_ref, analysis) != analysis["run_ref"]:
        raise OptimizationError("experiment analysis run reference does not match its content")
    output["experiment_ref"] = expected_ref
    output.setdefault("decision", None)
    return output
