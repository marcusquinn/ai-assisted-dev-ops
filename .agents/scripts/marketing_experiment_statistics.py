#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Conservative aggregate statistics for preregistered marketing experiments."""

from __future__ import annotations

import math
from dataclasses import dataclass
from decimal import Decimal
from statistics import NormalDist
from typing import Any

from marketing_experiment_assignment import ExperimentPopulation
from marketing_optimization_contract import divide, number, require_object, wire_number

@dataclass(frozen=True)
class VariantAggregate:
    """Exact internal aggregates for one experiment variant."""

    variant_id: str
    exposed: int
    eligible: int
    conversions: int
    numerator: Decimal
    denominator: Decimal
    metric_subjects: int
    metric_value: Decimal | None
    gross: Decimal
    refund: Decimal
    net: Decimal
    metric_supported: bool
    suppressed: bool


@dataclass(frozen=True)
class StatisticsBundle:
    """Schema-ready statistics plus analysis-only decision evidence."""

    aggregates: tuple[VariantAggregate, ...]
    variant_results: tuple[dict[str, Any], ...]
    comparisons: tuple[dict[str, Any], ...]
    guardrails: tuple[dict[str, Any], ...]
    candidate_winners: tuple[str, ...]
    adjusted_alpha: Decimal
    reasons: tuple[str, ...]
    guardrail_breach: bool
    assignment_imbalance: bool


def _eligible_events(population: ExperimentPopulation, variant_id: str) -> list[dict[str, Any]]:
    """Return events only for subjects with an observed exposure."""
    exposed = population.exposed_subjects[variant_id]
    return [event for event in population.events_by_variant[variant_id] if event["subject"].get("subject_id") in exposed]


def _sum_metric(events: list[dict[str, Any]], metric_id: str) -> Decimal:
    """Sum one normalized metric exactly."""
    return sum(
        (number(event["measurement"]["value"], metric_id) for event in events if event["measurement"]["metric_id"] == metric_id),
        Decimal(0),
    )


def _binomial_observations(
    events: list[dict[str, Any]],
    metric_id: str,
) -> dict[str, Decimal] | None:
    """Return one non-monetary binary observation per measured subject."""
    observations = [event for event in events if event["measurement"]["metric_id"] == metric_id]
    observed_subjects: dict[str, Decimal] = {}
    for event in observations:
        measurement = event["measurement"]
        value = number(measurement["value"], metric_id)
        subject_id = event["subject"].get("subject_id")
        if (
            subject_id is None
            or str(subject_id) in observed_subjects
            or measurement["unit"] in {"currency", "ratio"}
            or measurement.get("currency") is not None
            or value not in {Decimal(0), Decimal(1)}
        ):
            return None
        observed_subjects[str(subject_id)] = value
    return observed_subjects


def _variant_aggregate(
    variant_id: str,
    population: ExperimentPopulation,
    primary: dict[str, Any],
    privacy_threshold: int,
) -> VariantAggregate:
    """Calculate one variant without exposing subject rows."""
    events = _eligible_events(population, variant_id)
    exposed = len(population.exposed_subjects[variant_id])
    numerator = _sum_metric(events, str(primary["metric_id"]))
    denominator_metric = primary.get("denominator_metric_id")
    denominator = _sum_metric(events, str(denominator_metric)) if denominator_metric else Decimal(exposed)
    numerator_observations = _binomial_observations(events, str(primary["metric_id"]))
    denominator_observations = (
        _binomial_observations(events, str(denominator_metric)) if denominator_metric is not None else None
    )
    metric_supported = (
        numerator_observations is not None
        and denominator_observations is not None
        and set(numerator_observations).issubset(denominator_observations)
        and all(value == Decimal(1) for value in denominator_observations.values())
        and all(
            value <= denominator_observations[subject_id]
            for subject_id, value in numerator_observations.items()
        )
    )
    metric_subjects = len(numerator_observations) if metric_supported else 0
    qualifying_conversions = (
        sum(int(value == Decimal(1)) for value in numerator_observations.values())
        if metric_supported and numerator_observations is not None
        else 0
    )
    metric_value = divide(numerator, denominator) if metric_supported else None
    refund = Decimal(0)
    return VariantAggregate(
        variant_id=variant_id,
        exposed=exposed,
        eligible=exposed,
        conversions=qualifying_conversions,
        numerator=numerator,
        denominator=denominator,
        metric_subjects=metric_subjects,
        metric_value=metric_value,
        gross=numerator,
        refund=refund,
        net=numerator - refund,
        metric_supported=metric_supported,
        suppressed=exposed < privacy_threshold or (metric_supported and metric_subjects < privacy_threshold),
    )


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


def _adjusted_alpha(definition: dict[str, Any], look_number: int, comparisons: int) -> Decimal:
    """Apply a conservative declared-look and multiplicity correction."""
    sample_plan = require_object(definition["sample_plan"], "sample_plan")
    stopping = require_object(definition["stopping_policy"], "stopping_policy")
    alpha = number(sample_plan["alpha"], "sample_plan.alpha")
    divisor = max(1, comparisons)
    if stopping["method"] == "fixed_horizon":
        return alpha / Decimal(divisor)
    looks = int(stopping["allowed_looks"])
    if stopping.get("alpha_spending") == "obrien_fleming":
        fraction = min(1.0, look_number / looks)
        base = NormalDist().inv_cdf(1.0 - float(alpha) / 2.0)
        spent = 2.0 * (1.0 - NormalDist().cdf(base / math.sqrt(fraction)))
        return Decimal(str(spent)) / Decimal(divisor)
    return alpha / Decimal(looks * divisor)


def _stat_decimal(value: float) -> Decimal:
    """Bound floating statistical output to a deterministic decimal."""
    return Decimal(format(value, ".12g"))


def _proportion_interval(
    control: VariantAggregate,
    treatment: VariantAggregate,
    alpha: Decimal,
) -> tuple[Decimal | None, Decimal | None]:
    """Return a conservative normal interval for two bounded rates."""
    if not Decimal(0) < alpha < Decimal(1):
        return None, None
    if control.denominator <= 0 or treatment.denominator <= 0:
        return None, None
    if not control.metric_supported or not treatment.metric_supported:
        return None, None
    if not (Decimal(0) <= control.numerator <= control.denominator):
        return None, None
    if not (Decimal(0) <= treatment.numerator <= treatment.denominator):
        return None, None
    control_rate = float(control.numerator / control.denominator)
    treatment_rate = float(treatment.numerator / treatment.denominator)
    variance = control_rate * (1.0 - control_rate) / float(control.denominator)
    variance += treatment_rate * (1.0 - treatment_rate) / float(treatment.denominator)
    critical = NormalDist().inv_cdf(1.0 - float(alpha) / 2.0)
    margin = critical * math.sqrt(max(0.0, variance))
    effect = treatment_rate - control_rate
    return _stat_decimal(effect - margin), _stat_decimal(effect + margin)


def _practical(effect: Decimal | None, primary: dict[str, Any]) -> bool:
    """Apply the preregistered practical-effect direction."""
    if effect is None:
        return False
    threshold = number(primary["minimum_practical_effect"], "minimum practical effect")
    if primary["direction"] == "higher_is_better":
        return effect >= threshold
    if primary["direction"] == "lower_is_better":
        return effect <= -threshold
    return False


def _significant(low: Decimal | None, high: Decimal | None, direction: str) -> bool:
    """Require the adjusted interval to exclude zero in the declared direction."""
    if low is None or high is None:
        return False
    if direction == "higher_is_better":
        return low > 0
    if direction == "lower_is_better":
        return high < 0
    return False


def _comparison(
    control: VariantAggregate,
    treatment: VariantAggregate,
    primary: dict[str, Any],
    adjusted_alpha: Decimal,
) -> dict[str, Any]:
    """Compare one treatment to the preregistered control."""
    hidden = control.suppressed or treatment.suppressed
    absolute = None
    relative = None
    if not hidden and control.metric_value is not None and treatment.metric_value is not None:
        absolute = treatment.metric_value - control.metric_value
        relative = divide(absolute, abs(control.metric_value))
    low, high = (None, None) if hidden else _proportion_interval(control, treatment, adjusted_alpha)
    significant = _significant(low, high, str(primary["direction"]))
    return {
        "control_variant_id": control.variant_id,
        "treatment_variant_id": treatment.variant_id,
        "absolute_effect": wire_number(absolute),
        "relative_effect": wire_number(relative),
        "confidence_interval_low": wire_number(low),
        "confidence_interval_high": wire_number(high),
        "adjusted_alpha": wire_number(adjusted_alpha),
        "significant": significant,
        "practically_significant": significant and _practical(absolute, primary),
    }


def _guardrail_result(
    guardrail: dict[str, Any],
    control: VariantAggregate,
    treatments: list[VariantAggregate],
    population: ExperimentPopulation,
    privacy_threshold: int,
) -> dict[str, Any]:
    """Evaluate worst observed treatment harm for one guardrail."""
    if control.suppressed or any(treatment.suppressed for treatment in treatments):
        return {"metric_id": guardrail["metric_id"], "status": "insufficient_evidence", "effect": None}
    control_events = _eligible_events(population, control.variant_id)
    metric_id = str(guardrail["metric_id"])
    control_observations = [event for event in control_events if event["measurement"]["metric_id"] == metric_id]
    control_subjects = _binomial_observations(control_events, metric_id)
    if (
        control_subjects is None
        or len(control_subjects) < privacy_threshold
        or control.exposed < privacy_threshold
    ):
        return {"metric_id": guardrail["metric_id"], "status": "insufficient_evidence", "effect": None}
    control_value = divide(_sum_metric(control_observations, metric_id), Decimal(control.exposed))
    effects: list[Decimal] = []
    for treatment in treatments:
        treatment_events = _eligible_events(population, treatment.variant_id)
        treatment_observations = [
            event for event in treatment_events if event["measurement"]["metric_id"] == metric_id
        ]
        treatment_subjects = _binomial_observations(treatment_events, metric_id)
        if (
            treatment_subjects is None
            or len(treatment_subjects) < privacy_threshold
            or treatment.exposed < privacy_threshold
        ):
            return {"metric_id": guardrail["metric_id"], "status": "insufficient_evidence", "effect": None}
        treatment_value = divide(_sum_metric(treatment_observations, metric_id), Decimal(treatment.exposed))
        if control_value is not None and treatment_value is not None:
            effects.append(treatment_value - control_value)
    if not effects:
        return {"metric_id": guardrail["metric_id"], "status": "insufficient_evidence", "effect": None}
    effect = min(effects) if guardrail["direction"] == "higher_is_better" else max(effects)
    threshold = number(guardrail["harm_threshold"], "guardrail harm_threshold")
    breach = effect < -threshold if guardrail["direction"] == "higher_is_better" else effect > threshold
    return {"metric_id": guardrail["metric_id"], "status": "breach" if breach else "pass", "effect": wire_number(effect)}


def _assignment_imbalance(aggregates: tuple[VariantAggregate, ...], variants: list[dict[str, Any]]) -> bool:
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
        _variant_aggregate(str(variant["variant_id"]), population, primary, threshold) for variant in variants
    )
    control = next(item for item in aggregates if next(v for v in variants if v["variant_id"] == item.variant_id)["role"] == "control")
    treatments = [item for item in aggregates if item.variant_id != control.variant_id]
    adjusted_alpha = _adjusted_alpha(definition, look_number, len(treatments))
    comparisons = tuple(_comparison(control, item, primary, adjusted_alpha) for item in treatments)
    guardrails = tuple(
        _guardrail_result(require_object(item, "guardrail"), control, treatments, population, threshold)
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
    imbalance = _assignment_imbalance(aggregates, variants)
    if imbalance:
        reasons.add("assignment_imbalance")
    return StatisticsBundle(
        aggregates=aggregates,
        variant_results=tuple(_variant_result(item) for item in aggregates),
        comparisons=comparisons,
        guardrails=guardrails,
        candidate_winners=winners,
        adjusted_alpha=adjusted_alpha,
        reasons=tuple(sorted(reasons)),
        guardrail_breach=any(item["status"] == "breach" for item in guardrails),
        assignment_imbalance=imbalance,
    )
