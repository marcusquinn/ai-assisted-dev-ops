#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Adjusted treatment comparisons for marketing experiments."""

from __future__ import annotations

import math
from decimal import Decimal
from statistics import NormalDist
from typing import Any

from marketing_experiment_statistics_models import VariantAggregate
from marketing_optimization_contract import divide, number, require_object, wire_number


def adjusted_alpha(definition: dict[str, Any], look_number: int, comparisons: int) -> Decimal:
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


def _interval_supported(
    control: VariantAggregate,
    treatment: VariantAggregate,
    alpha: Decimal,
) -> bool:
    """Return whether two aggregates support a bounded-rate interval."""
    checks = (
        Decimal(0) < alpha < Decimal(1),
        control.denominator > 0,
        treatment.denominator > 0,
        control.metric_supported,
        treatment.metric_supported,
        Decimal(0) <= control.numerator <= control.denominator,
        Decimal(0) <= treatment.numerator <= treatment.denominator,
    )
    return all(checks)


def _proportion_interval(
    control: VariantAggregate,
    treatment: VariantAggregate,
    alpha: Decimal,
) -> tuple[Decimal | None, Decimal | None]:
    """Return a conservative normal interval for two bounded rates."""
    if not _interval_supported(control, treatment, alpha):
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


def comparison(
    control: VariantAggregate,
    treatment: VariantAggregate,
    primary: dict[str, Any],
    alpha: Decimal,
) -> dict[str, Any]:
    """Compare one treatment to the preregistered control."""
    hidden = control.suppressed or treatment.suppressed
    absolute = None
    relative = None
    if not hidden and control.metric_value is not None and treatment.metric_value is not None:
        absolute = treatment.metric_value - control.metric_value
        relative = divide(absolute, abs(control.metric_value))
    low, high = (None, None) if hidden else _proportion_interval(control, treatment, alpha)
    significant = _significant(low, high, str(primary["direction"]))
    return {
        "control_variant_id": control.variant_id,
        "treatment_variant_id": treatment.variant_id,
        "absolute_effect": wire_number(absolute),
        "relative_effect": wire_number(relative),
        "confidence_interval_low": wire_number(low),
        "confidence_interval_high": wire_number(high),
        "adjusted_alpha": wire_number(alpha),
        "significant": significant,
        "practically_significant": significant and _practical(absolute, primary),
    }
