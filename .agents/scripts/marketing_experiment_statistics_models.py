#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Internal aggregate models for marketing experiment statistics."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Any


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
