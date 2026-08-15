#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Conservative aggregate statistics for preregistered marketing experiments."""

from __future__ import annotations

from typing import Any

from marketing_experiment_assignment import ExperimentPopulation
from marketing_experiment_statistics_comparisons import adjusted_alpha, comparison
from marketing_experiment_statistics_guardrails import assignment_imbalance, guardrail_result
from marketing_experiment_statistics_models import StatisticsBundle, VariantAggregate
from marketing_experiment_statistics_observations import variant_aggregate
from marketing_optimization_contract import require_object, wire_number


def _variant_result(aggregate: VariantAggregate) -> dict[str, Any]:
    """Render one privacy-gated variant result."""
    hidden = aggregate.suppressed
    hidden_metric = hidden or not aggregate.metric_supported
    return {
        "variant_id": aggregate.variant_id,
        "suppressed": hidden,
        "exposed_count": None if hidden else aggregate.exposed,
        "eligible_count": None if hidden else aggregate.eligible,
        "numerator": None if hidden_metric else wire_number(aggregate.numerator),
        "denominator": None if hidden_metric else wire_number(aggregate.denominator),
        "metric_value": None if hidden_metric else wire_number(aggregate.metric_value),
        "gross_value": None if hidden_metric else wire_number(aggregate.gross),
        "refund_value": None if hidden_metric else wire_number(aggregate.refund),
        "net_value": None if hidden_metric else wire_number(aggregate.net),
    }


def calculate_statistics(
    definition: dict[str, Any],
    population: ExperimentPopulation,
    look_number: int,
) -> StatisticsBundle:
    """Calculate aggregate results, corrected comparisons, and guardrails."""
    metrics = require_object(definition["metrics"], "metrics")
    primary = require_object(metrics["primary"], "metrics.primary")
    privacy = require_object(definition["privacy"], "privacy")
    threshold = max(int(privacy["minimum_cell_size"]), int(privacy["minimum_subject_count"]))
    variants = [require_object(item, "variant") for item in definition["variants"]]
    aggregates = tuple(
        variant_aggregate(str(variant["variant_id"]), population, primary, threshold) for variant in variants
    )
    control = next(item for item in aggregates if next(v for v in variants if v["variant_id"] == item.variant_id)["role"] == "control")
    treatments = [item for item in aggregates if item.variant_id != control.variant_id]
    alpha = adjusted_alpha(definition, look_number, len(treatments))
    comparisons = tuple(comparison(control, item, primary, alpha) for item in treatments)
    guardrails = tuple(
        guardrail_result(require_object(item, "guardrail"), control, treatments, population, threshold)
        for item in metrics["guardrails"]
    )
    reasons: set[str] = set()
    if any(item.suppressed for item in aggregates):
        reasons.add("privacy_threshold_not_met")
    if any(not item.metric_supported for item in aggregates):
        reasons.add("unsupported_metric_distribution")
    if any(item["confidence_interval_low"] is None for item in comparisons):
        reasons.add("unsupported_or_insufficient_metric_distribution")
    if any(item["status"] == "insufficient_evidence" for item in guardrails):
        reasons.add("guardrail_evidence_missing")
    winners = tuple(item["treatment_variant_id"] for item in comparisons if item["significant"] and item["practically_significant"])
    imbalance = assignment_imbalance(aggregates, variants)
    if imbalance:
        reasons.add("assignment_imbalance")
    return StatisticsBundle(
        aggregates=aggregates,
        variant_results=tuple(_variant_result(item) for item in aggregates),
        comparisons=comparisons,
        guardrails=guardrails,
        candidate_winners=winners,
        adjusted_alpha=alpha,
        reasons=tuple(sorted(reasons)),
        guardrail_breach=any(item["status"] == "breach" for item in guardrails),
        assignment_imbalance=imbalance,
    )
