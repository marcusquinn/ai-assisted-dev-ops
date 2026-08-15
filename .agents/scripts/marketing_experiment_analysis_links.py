#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Semantic links between experiment definitions and aggregate analyses."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Any

from marketing_optimization_contract import (
    OptimizationError,
    divide,
    number,
    require_list,
)


@dataclass(frozen=True)
class AnalysisLinks:
    """Definition-bound analysis rows and decision state."""

    definition: dict[str, Any]
    analysis: dict[str, Any]
    results: list[dict[str, Any]]
    comparisons: list[dict[str, Any]]
    guardrails: list[dict[str, Any]]


def _validate_registered_rows(context: AnalysisLinks) -> tuple[str, str, Decimal]:
    """Require rows to follow preregistered variant and metric order."""
    variants = require_list(context.definition["variants"], "experiment variants")
    variant_ids = [str(item["variant_id"]) for item in variants]
    control_id = next(str(item["variant_id"]) for item in variants if item["role"] == "control")
    treatment_ids = [str(item["variant_id"]) for item in variants if item["role"] == "treatment"]
    if [str(item["variant_id"]) for item in context.results] != variant_ids:
        raise OptimizationError("experiment analysis variant results do not match the definition")
    expected = [(control_id, treatment_id) for treatment_id in treatment_ids]
    actual = [
        (str(item["control_variant_id"]), str(item["treatment_variant_id"]))
        for item in context.comparisons
    ]
    if actual != expected:
        raise OptimizationError("experiment analysis comparisons do not match the definition")
    expected_guardrails = [str(item["metric_id"]) for item in context.definition["metrics"]["guardrails"]]
    if [str(item["metric_id"]) for item in context.guardrails] != expected_guardrails:
        raise OptimizationError("experiment analysis guardrails do not match the definition")
    primary = context.definition["metrics"]["primary"]
    return control_id, str(primary["direction"]), number(
        primary["minimum_practical_effect"],
        "minimum practical effect",
    )


def _comparison_is_hidden(control: dict[str, Any], treatment: dict[str, Any]) -> bool:
    """Return whether either compared aggregate is unavailable."""
    hidden = bool(control["suppressed"] or treatment["suppressed"])
    hidden = hidden or control["metric_value"] is None
    return hidden or treatment["metric_value"] is None


def _validate_hidden_comparison(comparison: dict[str, Any]) -> None:
    """Reject claims derived from unavailable aggregate evidence."""
    derived_fields = (
        "absolute_effect",
        "relative_effect",
        "confidence_interval_low",
        "confidence_interval_high",
    )
    has_derived_value = any(comparison[field] is not None for field in derived_fields)
    has_claim = bool(comparison["significant"] or comparison["practically_significant"])
    if has_derived_value or has_claim:
        raise OptimizationError("experiment comparison exposes unavailable variant evidence")


def _expected_relative(absolute: Decimal, control_metric: Decimal) -> Decimal | None:
    """Return the comparison's exact expected relative effect."""
    return divide(absolute, abs(control_metric))


def _comparison_significance(
    comparison: dict[str, Any],
    direction: str,
    absolute: Decimal,
    practical_threshold: Decimal,
) -> bool:
    """Validate interval-derived significance and return practicality."""
    low = number(comparison["confidence_interval_low"], "confidence_interval_low")
    high = number(comparison["confidence_interval_high"], "confidence_interval_high")
    significant = direction == "higher_is_better" and low > 0
    significant = significant or (direction == "lower_is_better" and high < 0)
    practical = direction == "higher_is_better" and absolute >= practical_threshold
    practical = practical or (direction == "lower_is_better" and absolute <= -practical_threshold)
    practical = significant and practical
    if comparison["significant"] != significant:
        raise OptimizationError("experiment comparison significance claims are inconsistent")
    if comparison["practically_significant"] != practical:
        raise OptimizationError("experiment comparison significance claims are inconsistent")
    return practical


def _validate_visible_comparison(
    comparison: dict[str, Any],
    control: dict[str, Any],
    treatment: dict[str, Any],
    direction: str,
    practical_threshold: Decimal,
) -> tuple[str, Decimal] | None:
    """Validate one visible comparison and return a qualifying winner."""
    control_metric = number(control["metric_value"], "control metric_value")
    treatment_metric = number(treatment["metric_value"], "treatment metric_value")
    absolute = treatment_metric - control_metric
    if number(comparison["absolute_effect"], "absolute_effect") != absolute:
        raise OptimizationError("experiment comparison absolute effect is inconsistent")
    expected_relative = _expected_relative(absolute, control_metric)
    actual_relative = comparison["relative_effect"]
    if expected_relative is None and actual_relative is not None:
        raise OptimizationError("experiment comparison relative effect is inconsistent")
    if expected_relative is not None and number(actual_relative, "relative_effect") != expected_relative:
        raise OptimizationError("experiment comparison relative effect is inconsistent")
    if _comparison_significance(comparison, direction, absolute, practical_threshold):
        return str(comparison["treatment_variant_id"]), absolute
    return None


def _candidate_winners(
    context: AnalysisLinks,
    direction: str,
    practical_threshold: Decimal,
) -> list[tuple[str, Decimal]]:
    """Validate comparisons and collect qualifying treatment effects."""
    results_by_id = {str(item["variant_id"]): item for item in context.results}
    candidates: list[tuple[str, Decimal]] = []
    for comparison in context.comparisons:
        control = results_by_id[str(comparison["control_variant_id"])]
        treatment = results_by_id[str(comparison["treatment_variant_id"])]
        if _comparison_is_hidden(control, treatment):
            _validate_hidden_comparison(comparison)
            continue
        candidate = _validate_visible_comparison(
            comparison,
            control,
            treatment,
            direction,
            practical_threshold,
        )
        if candidate is not None:
            candidates.append(candidate)
    return candidates


def _validate_winner(
    analysis: dict[str, Any],
    candidates: list[tuple[str, Decimal]],
    direction: str,
) -> None:
    """Bind a declared winner to the strongest qualifying comparison."""
    winner = analysis["winner_variant_id"]
    if winner is None:
        return
    if not candidates:
        raise OptimizationError("experiment winner lacks a qualifying comparison")
    reverse = direction == "higher_is_better"
    expected_winner = sorted(candidates, key=lambda item: item[1], reverse=reverse)[0][0]
    if winner != expected_winner:
        raise OptimizationError("experiment winner does not match its strongest comparison")


def _analysis_claims_result(analysis: dict[str, Any]) -> bool:
    """Return whether the analysis claims decision-ready causal evidence."""
    claims_result = bool(analysis["decision_eligible"])
    claims_result = claims_result or analysis["causal_status"] == "causal_supported"
    return claims_result or analysis["winner_variant_id"] is not None


def _validate_evidence_availability(context: AnalysisLinks) -> None:
    """Reject aggregate and guardrail claims from hidden evidence."""
    unavailable = any(item["suppressed"] or item["metric_value"] is None for item in context.results)
    if unavailable and _analysis_claims_result(context.analysis):
        raise OptimizationError("experiment analysis claims a result from unavailable variant evidence")
    if unavailable and any(item["status"] != "insufficient_evidence" for item in context.guardrails):
        raise OptimizationError("experiment guardrail exposes unavailable variant evidence")
    incomplete = any(item["status"] == "insufficient_evidence" for item in context.guardrails)
    if incomplete and _analysis_claims_result(context.analysis):
        raise OptimizationError("experiment analysis claims a result with incomplete guardrails")


def _validate_guardrail_state(context: AnalysisLinks) -> None:
    """Bind aggregate guardrail status to the analysis lifecycle state."""
    breached = any(item["status"] == "breach" for item in context.guardrails)
    if breached != (context.analysis["status"] == "guardrail_breach"):
        raise OptimizationError("experiment analysis guardrail breach status is inconsistent")


def validate_analysis_links(
    definition: dict[str, Any],
    analysis: dict[str, Any],
    results: list[dict[str, Any]],
    comparisons: list[dict[str, Any]],
    guardrails: list[dict[str, Any]],
) -> None:
    """Bind aggregate rows and claims to preregistered variants and metrics."""
    context = AnalysisLinks(definition, analysis, results, comparisons, guardrails)
    _control_id, direction, practical_threshold = _validate_registered_rows(context)
    candidates = _candidate_winners(context, direction, practical_threshold)
    _validate_winner(analysis, candidates, direction)
    _validate_evidence_availability(context)
    _validate_guardrail_state(context)
