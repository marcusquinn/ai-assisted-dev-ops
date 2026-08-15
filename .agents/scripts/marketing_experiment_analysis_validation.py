#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict state validation for registered marketing experiment analyses."""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from marketing_optimization_contract import (
    OptimizationError,
    divide,
    number,
    parse_datetime,
    require_integer,
    require_list,
    require_metric,
)
from marketing_optimization_validation_common import (
    EXPERIMENT_RUN_REF_RE,
    SHA256_REF_RE,
    alias_list,
    boolean,
    enum_value,
    exact,
    optional_count,
    optional_number,
    reference,
)
from performance_contract import optional_alias, require_alias

ANALYSIS_FIELDS = {
    "analysis_version",
    "input_snapshot_sha256",
    "as_of",
    "look_number",
    "look_type",
    "previous_run_ref",
    "status",
    "recommended_lifecycle",
    "decision_eligible",
    "variant_results",
    "comparisons",
    "guardrails",
    "causal_status",
    "winner_variant_id",
    "insufficient_reasons",
    "run_ref",
}


def _validate_variant_results(value: Any) -> list[dict[str, Any]]:
    """Require exact aggregate variant-result fields."""
    fields = {
        "variant_id",
        "suppressed",
        "exposed_count",
        "eligible_count",
        "numerator",
        "denominator",
        "metric_value",
        "gross_value",
        "refund_value",
        "net_value",
    }
    results: list[dict[str, Any]] = []
    for index, item in enumerate(require_list(value, "experiment analysis variant_results")):
        result = exact(item, fields, f"experiment analysis variant_results[{index}]")
        require_alias(result["variant_id"], f"experiment analysis variant_results[{index}].variant_id")
        boolean(result["suppressed"], f"experiment analysis variant_results[{index}].suppressed")
        for field in ("exposed_count", "eligible_count"):
            optional_count(result[field], f"experiment analysis variant_results[{index}].{field}")
        for field in ("numerator", "denominator", "metric_value", "gross_value", "refund_value", "net_value"):
            optional_number(result[field], f"experiment analysis variant_results[{index}].{field}")
        sensitive_fields = fields - {"variant_id", "suppressed"}
        if result["suppressed"]:
            if any(result[field] is not None for field in sensitive_fields):
                raise OptimizationError("suppressed experiment variant result exposes aggregate values")
        else:
            if result["exposed_count"] is None or result["eligible_count"] is None:
                raise OptimizationError("visible experiment variant result lacks population counts")
            if result["exposed_count"] != result["eligible_count"]:
                raise OptimizationError("experiment variant population counts are inconsistent")
            metric_fields = ("numerator", "denominator", "metric_value", "gross_value", "refund_value", "net_value")
            populated = [result[field] is not None for field in metric_fields]
            if any(populated) and not all(populated):
                raise OptimizationError("visible experiment variant result has incomplete metric values")
            if all(populated):
                numerator = number(result["numerator"], "experiment analysis numerator")
                denominator = number(result["denominator"], "experiment analysis denominator")
                metric_value = number(result["metric_value"], "experiment analysis metric_value")
                gross = number(result["gross_value"], "experiment analysis gross_value")
                refund = number(result["refund_value"], "experiment analysis refund_value")
                net = number(result["net_value"], "experiment analysis net_value")
                if denominator <= 0 or not Decimal(0) <= numerator <= denominator:
                    raise OptimizationError("experiment variant binomial aggregates are invalid")
                if metric_value != divide(numerator, denominator):
                    raise OptimizationError("experiment variant metric_value is inconsistent")
                if gross != numerator or refund != 0 or net != numerator:
                    raise OptimizationError("experiment variant ratio value aggregates are inconsistent")
        results.append(result)
    return results


def _validate_comparisons(value: Any) -> list[dict[str, Any]]:
    """Require exact treatment-comparison fields."""
    fields = {
        "control_variant_id",
        "treatment_variant_id",
        "absolute_effect",
        "relative_effect",
        "confidence_interval_low",
        "confidence_interval_high",
        "adjusted_alpha",
        "significant",
        "practically_significant",
    }
    comparisons: list[dict[str, Any]] = []
    for index, item in enumerate(require_list(value, "experiment analysis comparisons")):
        comparison = exact(item, fields, f"experiment analysis comparisons[{index}]")
        require_alias(
            comparison["control_variant_id"],
            f"experiment analysis comparisons[{index}].control_variant_id",
        )
        require_alias(
            comparison["treatment_variant_id"],
            f"experiment analysis comparisons[{index}].treatment_variant_id",
        )
        for field in (
            "absolute_effect",
            "relative_effect",
            "confidence_interval_low",
            "confidence_interval_high",
        ):
            optional_number(comparison[field], f"experiment analysis comparisons[{index}].{field}")
        alpha = number(comparison["adjusted_alpha"], f"experiment analysis comparisons[{index}].adjusted_alpha")
        if not Decimal(0) < alpha < Decimal(1):
            raise OptimizationError("experiment analysis adjusted_alpha must be between zero and one")
        boolean(comparison["significant"], f"experiment analysis comparisons[{index}].significant")
        boolean(
            comparison["practically_significant"],
            f"experiment analysis comparisons[{index}].practically_significant",
        )
        if comparison["practically_significant"] and not comparison["significant"]:
            raise OptimizationError("experiment practical significance requires statistical significance")
        interval_fields = ("absolute_effect", "confidence_interval_low", "confidence_interval_high")
        interval_present = [comparison[field] is not None for field in interval_fields]
        if any(interval_present) and not all(interval_present):
            raise OptimizationError("experiment comparison has incomplete effect evidence")
        if not any(interval_present) and (
            comparison["relative_effect"] is not None
            or comparison["significant"]
            or comparison["practically_significant"]
        ):
            raise OptimizationError("experiment comparison claims a result without effect evidence")
        comparisons.append(comparison)
    return comparisons


def _validate_guardrails(value: Any) -> list[dict[str, Any]]:
    """Require exact aggregate guardrail-result fields."""
    guardrails: list[dict[str, Any]] = []
    for index, item in enumerate(require_list(value, "experiment analysis guardrails")):
        guardrail = exact(
            item,
            {"metric_id", "status", "effect"},
            f"experiment analysis guardrails[{index}]",
        )
        require_metric(guardrail["metric_id"], f"experiment analysis guardrails[{index}].metric_id")
        status = enum_value(
            guardrail["status"],
            {"pass", "breach", "insufficient_evidence"},
            f"experiment analysis guardrails[{index}].status",
        )
        optional_number(guardrail["effect"], f"experiment analysis guardrails[{index}].effect")
        if (status == "insufficient_evidence") != (guardrail["effect"] is None):
            raise OptimizationError("experiment guardrail status and effect are inconsistent")
        guardrails.append(guardrail)
    return guardrails


def _validate_analysis_links(
    definition: dict[str, Any],
    analysis: dict[str, Any],
    results: list[dict[str, Any]],
    comparisons: list[dict[str, Any]],
    guardrails: list[dict[str, Any]],
) -> None:
    """Bind aggregate rows and claims to the preregistered variants and metrics."""
    variants = require_list(definition["variants"], "experiment variants")
    variant_ids = [str(item["variant_id"]) for item in variants]
    control_id = next(str(item["variant_id"]) for item in variants if item["role"] == "control")
    treatment_ids = [str(item["variant_id"]) for item in variants if item["role"] == "treatment"]
    result_ids = [str(item["variant_id"]) for item in results]
    if result_ids != variant_ids:
        raise OptimizationError("experiment analysis variant results do not match the definition")
    expected_comparisons = [(control_id, treatment_id) for treatment_id in treatment_ids]
    actual_comparisons = [
        (str(item["control_variant_id"]), str(item["treatment_variant_id"]))
        for item in comparisons
    ]
    if actual_comparisons != expected_comparisons:
        raise OptimizationError("experiment analysis comparisons do not match the definition")
    expected_guardrails = [str(item["metric_id"]) for item in definition["metrics"]["guardrails"]]
    if [str(item["metric_id"]) for item in guardrails] != expected_guardrails:
        raise OptimizationError("experiment analysis guardrails do not match the definition")

    results_by_id = {str(item["variant_id"]): item for item in results}
    primary = definition["metrics"]["primary"]
    direction = str(primary["direction"])
    practical_threshold = number(primary["minimum_practical_effect"], "minimum practical effect")
    candidate_winners: list[tuple[str, Decimal]] = []
    for comparison in comparisons:
        control = results_by_id[str(comparison["control_variant_id"])]
        treatment = results_by_id[str(comparison["treatment_variant_id"])]
        hidden = control["suppressed"] or treatment["suppressed"] or control["metric_value"] is None or treatment["metric_value"] is None
        derived_fields = (
            "absolute_effect",
            "relative_effect",
            "confidence_interval_low",
            "confidence_interval_high",
        )
        if hidden:
            if any(comparison[field] is not None for field in derived_fields) or comparison["significant"] or comparison["practically_significant"]:
                raise OptimizationError("experiment comparison exposes unavailable variant evidence")
            continue
        control_metric = number(control["metric_value"], "control metric_value")
        treatment_metric = number(treatment["metric_value"], "treatment metric_value")
        absolute = treatment_metric - control_metric
        if number(comparison["absolute_effect"], "absolute_effect") != absolute:
            raise OptimizationError("experiment comparison absolute effect is inconsistent")
        expected_relative = divide(absolute, abs(control_metric))
        if expected_relative is None:
            if comparison["relative_effect"] is not None:
                raise OptimizationError("experiment comparison relative effect is inconsistent")
        elif number(comparison["relative_effect"], "relative_effect") != expected_relative:
            raise OptimizationError("experiment comparison relative effect is inconsistent")
        low = number(comparison["confidence_interval_low"], "confidence_interval_low")
        high = number(comparison["confidence_interval_high"], "confidence_interval_high")
        significant = (direction == "higher_is_better" and low > 0) or (
            direction == "lower_is_better" and high < 0
        )
        practical = significant and (
            (direction == "higher_is_better" and absolute >= practical_threshold)
            or (direction == "lower_is_better" and absolute <= -practical_threshold)
        )
        if comparison["significant"] != significant or comparison["practically_significant"] != practical:
            raise OptimizationError("experiment comparison significance claims are inconsistent")
        if practical:
            candidate_winners.append((str(comparison["treatment_variant_id"]), absolute))

    winner = analysis["winner_variant_id"]
    if winner is not None:
        if not candidate_winners:
            raise OptimizationError("experiment winner lacks a qualifying comparison")
        reverse = direction == "higher_is_better"
        expected_winner = sorted(candidate_winners, key=lambda item: item[1], reverse=reverse)[0][0]
        if winner != expected_winner:
            raise OptimizationError("experiment winner does not match its strongest comparison")
    unavailable = any(item["suppressed"] or item["metric_value"] is None for item in results)
    if unavailable and (
        analysis["decision_eligible"]
        or analysis["causal_status"] == "causal_supported"
        or winner is not None
    ):
        raise OptimizationError("experiment analysis claims a result from unavailable variant evidence")
    if unavailable and any(item["status"] != "insufficient_evidence" for item in guardrails):
        raise OptimizationError("experiment guardrail exposes unavailable variant evidence")
    guardrail_incomplete = any(item["status"] == "insufficient_evidence" for item in guardrails)
    if guardrail_incomplete and (
        analysis["decision_eligible"]
        or analysis["causal_status"] == "causal_supported"
        or winner is not None
    ):
        raise OptimizationError("experiment analysis claims a result with incomplete guardrails")
    guardrail_breach = any(item["status"] == "breach" for item in guardrails)
    if guardrail_breach != (analysis["status"] == "guardrail_breach"):
        raise OptimizationError("experiment analysis guardrail breach status is inconsistent")


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
    results = _validate_variant_results(analysis["variant_results"])
    comparisons = _validate_comparisons(analysis["comparisons"])
    guardrails = _validate_guardrails(analysis["guardrails"])
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
    _validate_analysis_links(definition, analysis, results, comparisons, guardrails)
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
