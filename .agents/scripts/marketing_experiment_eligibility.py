#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fail-closed eligibility decisions for marketing experiment analyses."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class AnalysisEligibility:
    """One fully evaluated decision and causal eligibility state."""

    status: str
    decision_eligible: bool
    normal_eligible: bool
    causal_status: str
    reasons: tuple[str, ...]


@dataclass(frozen=True)
class EligibilityInputs:
    """All independent gates evaluated for one analysis look."""

    invalid_reasons: set[str]
    waiting_reasons: set[str]
    lifecycle_eligible: bool
    assignment_integrity_invalid: bool
    assignment_verified: bool
    guardrail_breach: bool
    safety_stop: bool
    assignment_method: str


def _causal_status(invalid: bool, assignment_verified: bool, normal_eligible: bool, method: str) -> str:
    """Render a causal state that never treats a safety stop as positive lift."""
    if invalid:
        return "invalid"
    if assignment_verified and normal_eligible:
        return "causal_supported"
    if method == "observational":
        return "observational"
    return "insufficient_evidence"


def evaluate_eligibility(inputs: EligibilityInputs) -> AnalysisEligibility:
    """Combine lifecycle, evidence, privacy, stopping, and guardrail gates."""
    invalid = set(inputs.invalid_reasons)
    waiting = set(inputs.waiting_reasons)
    if not inputs.lifecycle_eligible:
        invalid.add("lifecycle_not_analysis_eligible")
    if inputs.assignment_integrity_invalid:
        invalid.add("assignment_integrity_invalid")
    if not inputs.assignment_verified:
        waiting.add("verified_assignment_required")
    if inputs.guardrail_breach:
        waiting.add("guardrail_breach")
    privacy_ready = "privacy_threshold_not_met" not in waiting
    normal_eligible = not invalid and not waiting and not inputs.guardrail_breach
    safety_eligible = inputs.guardrail_breach and inputs.safety_stop and not invalid and privacy_ready
    decision_eligible = not invalid and privacy_ready and (normal_eligible or safety_eligible)
    status = "invalid" if invalid else "guardrail_breach" if inputs.guardrail_breach else "complete" if normal_eligible else "insufficient_evidence"
    return AnalysisEligibility(
        status=status,
        decision_eligible=decision_eligible,
        normal_eligible=normal_eligible,
        causal_status=_causal_status(
            bool(invalid),
            inputs.assignment_verified,
            normal_eligible,
            inputs.assignment_method,
        ),
        reasons=tuple(sorted(invalid.union(waiting))),
    )
