#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Privacy-safe observation aggregation for marketing experiments."""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from marketing_experiment_assignment import ExperimentPopulation
from marketing_experiment_statistics_models import VariantAggregate
from marketing_optimization_contract import divide, number


def eligible_events(population: ExperimentPopulation, variant_id: str) -> list[dict[str, Any]]:
    """Return events only for subjects with an observed exposure."""
    exposed = population.exposed_subjects[variant_id]
    return [event for event in population.events_by_variant[variant_id] if event["subject"].get("subject_id") in exposed]


def sum_metric(events: list[dict[str, Any]], metric_id: str) -> Decimal:
    """Sum one normalized metric exactly."""
    return sum(
        (
            number(event["measurement"]["value"], metric_id)
            for event in events
            if event["measurement"]["metric_id"] == metric_id
        ),
        Decimal(0),
    )


def _invalid_observation(
    subject_id: Any,
    observed_subjects: dict[str, Decimal],
    measurement: dict[str, Any],
    value: Decimal,
) -> bool:
    """Return whether one event cannot represent a binary subject observation."""
    if subject_id is None:
        return True
    if str(subject_id) in observed_subjects:
        return True
    if measurement["unit"] in {"currency", "ratio"}:
        return True
    if measurement.get("currency") is not None:
        return True
    return value not in {Decimal(0), Decimal(1)}


def binomial_observations(
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
        if _invalid_observation(subject_id, observed_subjects, measurement, value):
            return None
        observed_subjects[str(subject_id)] = value
    return observed_subjects


def _metric_supported(
    numerator: dict[str, Decimal] | None,
    denominator: dict[str, Decimal] | None,
) -> bool:
    """Require paired binary observations on the declared exposure denominator."""
    if numerator is None or denominator is None:
        return False
    if not set(numerator).issubset(denominator):
        return False
    if any(value != Decimal(1) for value in denominator.values()):
        return False
    return all(value <= denominator[subject_id] for subject_id, value in numerator.items())


def variant_aggregate(
    variant_id: str,
    population: ExperimentPopulation,
    primary: dict[str, Any],
    privacy_threshold: int,
) -> VariantAggregate:
    """Calculate one variant without exposing subject rows."""
    events = eligible_events(population, variant_id)
    exposed = len(population.exposed_subjects[variant_id])
    numerator = sum_metric(events, str(primary["metric_id"]))
    denominator_metric = primary.get("denominator_metric_id")
    denominator = sum_metric(events, str(denominator_metric)) if denominator_metric else Decimal(exposed)
    numerator_observations = binomial_observations(events, str(primary["metric_id"]))
    denominator_observations = (
        binomial_observations(events, str(denominator_metric)) if denominator_metric is not None else None
    )
    metric_supported = _metric_supported(numerator_observations, denominator_observations)
    metric_subjects = len(numerator_observations) if metric_supported and numerator_observations is not None else 0
    conversions = 0
    if metric_supported and numerator_observations is not None:
        conversions = sum(int(value == Decimal(1)) for value in numerator_observations.values())
    metric_value = divide(numerator, denominator) if metric_supported else None
    refund = Decimal(0)
    return VariantAggregate(
        variant_id=variant_id,
        exposed=exposed,
        eligible=exposed,
        conversions=conversions,
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
