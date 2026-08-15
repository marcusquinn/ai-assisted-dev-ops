#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guardrail and assignment checks for marketing experiment statistics."""

from __future__ import annotations

import math
from decimal import Decimal
from typing import Any

from marketing_experiment_assignment import ExperimentPopulation
from marketing_experiment_statistics_models import VariantAggregate
from marketing_experiment_statistics_observations import (
    binomial_observations,
    eligible_events,
    sum_metric,
)
from marketing_optimization_contract import divide, number, wire_number


def _insufficient(metric_id: Any) -> dict[str, Any]:
    """Render one privacy-safe insufficient guardrail result."""
    return {"metric_id": metric_id, "status": "insufficient_evidence", "effect": None}


def _guardrail_value(
    population: ExperimentPopulation,
    aggregate: VariantAggregate,
    metric_id: str,
    privacy_threshold: int,
) -> Decimal | None:
    """Return one privacy-eligible aggregate guardrail value."""
    events = eligible_events(population, aggregate.variant_id)
    observations = [event for event in events if event["measurement"]["metric_id"] == metric_id]
    subjects = binomial_observations(events, metric_id)
    if subjects is None or len(subjects) < privacy_threshold:
        return None
    if aggregate.exposed < privacy_threshold:
        return None
    return divide(sum_metric(observations, metric_id), Decimal(aggregate.exposed))


def guardrail_result(
    guardrail: dict[str, Any],
    control: VariantAggregate,
    treatments: list[VariantAggregate],
    population: ExperimentPopulation,
    privacy_threshold: int,
) -> dict[str, Any]:
    """Evaluate worst observed treatment harm for one guardrail."""
    metric_id = str(guardrail["metric_id"])
    if control.suppressed or any(treatment.suppressed for treatment in treatments):
        return _insufficient(guardrail["metric_id"])
    control_value = _guardrail_value(population, control, metric_id, privacy_threshold)
    if control_value is None:
        return _insufficient(guardrail["metric_id"])
    effects: list[Decimal] = []
    for treatment in treatments:
        treatment_value = _guardrail_value(population, treatment, metric_id, privacy_threshold)
        if treatment_value is None:
            return _insufficient(guardrail["metric_id"])
        effects.append(treatment_value - control_value)
    if not effects:
        return _insufficient(guardrail["metric_id"])
    effect = min(effects) if guardrail["direction"] == "higher_is_better" else max(effects)
    threshold = number(guardrail["harm_threshold"], "guardrail harm_threshold")
    breach = effect < -threshold if guardrail["direction"] == "higher_is_better" else effect > threshold
    return {
        "metric_id": guardrail["metric_id"],
        "status": "breach" if breach else "pass",
        "effect": wire_number(effect),
    }


def assignment_imbalance(
    aggregates: tuple[VariantAggregate, ...],
    variants: list[dict[str, Any]],
) -> bool:
    """Flag exposure shares outside a conservative three-sigma tolerance."""
    total = sum(item.exposed for item in aggregates)
    if total == 0:
        return False
    observed = {item.variant_id: item.exposed / total for item in aggregates}
    for variant in variants:
        expected = float(number(variant["allocation"], "variant allocation"))
        tolerance = max(0.05, 3.0 * math.sqrt(expected * (1.0 - expected) / total))
        if abs(observed[str(variant["variant_id"])] - expected) > tolerance:
            return True
    return False
