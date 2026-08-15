#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict state validation for registered marketing experiment analyses."""

from __future__ import annotations

from typing import Any

from marketing_experiment_analysis_aggregates import validate_variant_results
from marketing_experiment_analysis_claims import validate_comparisons, validate_guardrails
from marketing_experiment_analysis_links import validate_analysis_links
from marketing_optimization_contract import (
    OptimizationError,
    parse_datetime,
    require_integer,
)
from marketing_optimization_validation_common import (
    EXPERIMENT_RUN_REF_RE,
    SHA256_REF_RE,
    alias_list,
    boolean,
    enum_value,
    exact,
    reference,
)
from performance_contract import optional_alias

ANALYSIS_FIELDS = frozenset(
    "analysis_version input_snapshot_sha256 as_of look_number look_type previous_run_ref status "
    "recommended_lifecycle decision_eligible variant_results comparisons guardrails causal_status "
    "winner_variant_id insufficient_reasons run_ref".split()
)


def _validate_shape(definition: dict[str, Any], analysis: dict[str, Any]) -> tuple[int, str, str, bool]:
    """Validate exact fields and return state used by semantic checks."""
    exact(analysis, ANALYSIS_FIELDS, "experiment analysis")
    if analysis["analysis_version"] != 1:
        raise OptimizationError("experiment analysis version is unsupported")
    reference(analysis["run_ref"], EXPERIMENT_RUN_REF_RE, "experiment analysis run")
    reference(analysis["input_snapshot_sha256"], SHA256_REF_RE, "experiment analysis snapshot")
    parse_datetime(analysis["as_of"], "experiment analysis as_of")
    look_number = require_integer(
        analysis["look_number"],
        "experiment analysis look_number",
        1,
        int(definition["stopping_policy"]["allowed_looks"]),
    )
    enum_value(analysis["look_type"], {"interim", "final", "safety"}, "experiment analysis look_type")
    previous_run_ref = analysis["previous_run_ref"]
    if previous_run_ref is not None:
        reference(previous_run_ref, EXPERIMENT_RUN_REF_RE, "previous experiment run")
    if look_number == 1 and previous_run_ref is not None:
        raise OptimizationError("first experiment analysis look cannot name a previous run")
    results = validate_variant_results(analysis["variant_results"])
    comparisons = validate_comparisons(analysis["comparisons"])
    guardrails = validate_guardrails(analysis["guardrails"])
    alias_list(analysis["insufficient_reasons"], "experiment analysis insufficient_reasons")
    optional_alias(analysis["winner_variant_id"], "experiment analysis winner_variant_id")
    status = enum_value(
        analysis["status"],
        {"complete", "insufficient_evidence", "invalid", "guardrail_breach"},
        "experiment analysis status",
    )
    causal_status = enum_value(
        analysis["causal_status"],
        {"causal_supported", "observational", "invalid", "insufficient_evidence"},
        "experiment analysis causal_status",
    )
    decision_eligible = boolean(analysis["decision_eligible"], "experiment analysis decision_eligible")
    enum_value(
        analysis["recommended_lifecycle"],
        {"running", "analysis_ready"},
        "experiment analysis recommended_lifecycle",
    )
    validate_analysis_links(definition, analysis, results, comparisons, guardrails)
    return look_number, status, causal_status, decision_eligible


def validate_analysis_shape(definition: dict[str, Any], analysis: dict[str, Any]) -> None:
    """Validate exact analysis fields without requiring registry evidence."""
    _look_number, status, causal_status, decision_eligible = _validate_shape(definition, analysis)
    _validate_state(analysis, status, causal_status, decision_eligible)


def _validate_state(analysis: dict[str, Any], status: str, causal_status: str, decision_eligible: bool) -> None:
    """Validate lifecycle, eligibility, winner, and status consistency."""
    expected_lifecycle = "analysis_ready" if decision_eligible else "running"
    if analysis["recommended_lifecycle"] != expected_lifecycle:
        raise OptimizationError("experiment analysis lifecycle recommendation is inconsistent")
    if status == "complete" and not decision_eligible:
        raise OptimizationError("complete experiment analysis must be decision eligible")
    if status in {"invalid", "insufficient_evidence"} and decision_eligible:
        raise OptimizationError("ineligible experiment analysis cannot permit a decision")
    if status == "invalid" and causal_status != "invalid":
        raise OptimizationError("invalid experiment analysis must have invalid causal status")
    if causal_status == "causal_supported" and (status != "complete" or not decision_eligible):
        raise OptimizationError("causal-supported experiment analysis must be complete and eligible")
    if status == "complete" and causal_status != "causal_supported":
        raise OptimizationError("complete experiment analysis must be causal supported")
    if not decision_eligible and analysis["winner_variant_id"] is not None:
        raise OptimizationError("ineligible experiment analysis cannot name a winner")
    if status != "complete" and analysis["winner_variant_id"] is not None:
        raise OptimizationError("only complete experiment analysis can name a winner")
    if analysis["winner_variant_id"] is not None and causal_status != "causal_supported":
        raise OptimizationError("experiment winner requires causal-supported analysis")


def _validate_causal_assignment(
    definition: dict[str, Any],
    assignment: dict[str, Any] | None,
    status: str,
    causal_status: str,
    decision_eligible: bool,
) -> None:
    """Require registered randomized assignment evidence for causal wording."""
    if causal_status != "causal_supported":
        return
    declared = definition["assignment"]
    requirements = (
        assignment is not None,
        status == "complete",
        decision_eligible,
        declared["method"] == "randomized",
        declared["verification"] == "verified",
        declared["sticky"] is True,
        declared["snapshot_ref"] is not None,
    )
    if not all(requirements):
        raise OptimizationError("causal experiment analysis lacks registered assignment evidence")


def validate_analysis_semantics(
    definition: dict[str, Any],
    analysis: dict[str, Any],
    assignment: dict[str, Any] | None,
) -> None:
    """Fail closed on forged analysis state and causal eligibility flags."""
    _look_number, status, causal_status, decision_eligible = _validate_shape(definition, analysis)
    _validate_state(analysis, status, causal_status, decision_eligible)
    _validate_causal_assignment(definition, assignment, status, causal_status, decision_eligible)
