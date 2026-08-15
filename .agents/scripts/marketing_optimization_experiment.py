#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Preregistered aggregate marketing experiment analysis."""

from __future__ import annotations

import math
from typing import Any

from marketing_optimization_common import (
    SCHEMA_EXPERIMENT_ANALYSIS,
    OptimizationError,
    digest,
    timestamp,
)


def _require_fields(document: dict[str, Any]) -> None:
    required = ["experiment_id", "source_snapshot", "state", "hypothesis", "owner", "variants", "assignment", "metrics", "sample_policy", "window", "stopping_policy", "exclusions", "observations"]
    missing = [field for field in required if field not in document]
    if missing:
        raise OptimizationError(f"experiment input missing: {', '.join(missing)}")


def _validate_collections(document: dict[str, Any]) -> None:
    variants = document["variants"]
    observations = document["observations"]
    if not isinstance(variants, list):
        raise OptimizationError("experiment variants must be an array")
    if len(variants) < 2:
        raise OptimizationError("experiment requires at least two variants")
    if not isinstance(observations, list):
        raise OptimizationError("experiment requires aggregate observations")


def _validate_registry(document: dict[str, Any]) -> None:
    _validate_collections(document)
    if document["state"] not in {"running", "analysis_ready", "decided"}:
        raise OptimizationError("only running, analysis_ready, or decided experiments can be analyzed")
    if not str(document["hypothesis"]).strip():
        raise OptimizationError("experiment hypothesis must be preregistered")
    if not str(document["owner"]).strip():
        raise OptimizationError("experiment owner must be preregistered")
    if not str(document["stopping_policy"]).strip():
        raise OptimizationError("experiment stopping_policy must be preregistered")
    if not isinstance(document["exclusions"], list):
        raise OptimizationError("experiment exclusions must be preregistered")


def _contract(document: dict[str, Any]) -> tuple[list[str], dict[str, dict[str, Any]], str, dict[str, Any], dict[str, Any]]:
    _require_fields(document)
    _validate_registry(document)
    variants = document["variants"]
    observations = document["observations"]
    control = document["assignment"].get("control_variant")
    if control not in variants:
        raise OptimizationError("control_variant must name a preregistered variant")
    by_variant = {str(item.get("variant")): item for item in observations if isinstance(item, dict)}
    if set(by_variant) != set(variants):
        raise OptimizationError("observations must contain each preregistered variant exactly once")
    return variants, by_variant, control, document["sample_policy"], document["window"]


def _window_peeking(window: dict[str, Any], observed_at: str) -> bool:
    starts_at = timestamp(window["starts_at"], "window.starts_at")
    ends_at = timestamp(window["ends_at"], "window.ends_at")
    analysis_time = timestamp(observed_at, "observed_at")
    elapsed_days = (min(analysis_time, ends_at) - starts_at).total_seconds() / 86400
    return analysis_time < ends_at or elapsed_days < int(window["minimum_days"])


def _row(variant: str, observation: dict[str, Any], minimum: int, guardrails: set[str]) -> tuple[dict[str, Any], bool]:
    sample = int(observation.get("sample", 0))
    successes = int(observation.get("successes", 0))
    if sample < 0 or successes < 0 or successes > sample:
        raise OptimizationError("experiment sample and successes are invalid")
    observed_guardrails = observation.get("guardrails", {})
    if not isinstance(observed_guardrails, dict) or set(observed_guardrails) != guardrails:
        raise OptimizationError("observed guardrails must exactly match preregistered guardrail metrics")
    result = {"variant": variant, "sample": sample, "successes": successes, "rate": successes / sample if sample else 0.0, "guardrails": observed_guardrails}
    return result, sample < minimum


def _rows(document: dict[str, Any], variants: list[str], by_variant: dict[str, dict[str, Any]], minimum: int) -> tuple[list[dict[str, Any]], bool, list[Any]]:
    validity_flags = document.get("validity_flags", [])
    if not isinstance(validity_flags, list):
        raise OptimizationError("validity_flags must be an array")
    guardrails = set(document["metrics"].get("guardrails", []))
    rows = []
    insufficient = bool(validity_flags)
    for variant in variants:
        result, below_minimum = _row(variant, by_variant[variant], minimum, guardrails)
        rows.append(result)
        insufficient = insufficient or below_minimum
    return rows, insufficient, validity_flags


def _score_row(row: dict[str, Any], control: dict[str, Any], threshold: float) -> tuple[bool, bool]:
    pooled = (row["successes"] + control["successes"]) / (row["sample"] + control["sample"])
    error = math.sqrt(pooled * (1 - pooled) * (1 / row["sample"] + 1 / control["sample"]))
    z_score = (row["rate"] - control["rate"]) / error if error else 0.0
    confidence = math.erf(abs(z_score) / math.sqrt(2))
    row["lift"] = row["rate"] - control["rate"]
    row["confidence"] = confidence
    regressions = [name for name, value in row["guardrails"].items() if isinstance(value, dict) and value.get("regressed") is True]
    row["guardrail_regressions"] = sorted(regressions)
    return bool(regressions), row["lift"] > 0 and confidence >= threshold


def _score(rows: list[dict[str, Any]], control_name: str, threshold: float, insufficient: bool) -> tuple[list[dict[str, Any]], bool]:
    control = next(row for row in rows if row["variant"] == control_name)
    candidates = []
    guardrail_regression = False
    if not insufficient:
        for row in rows:
            if row["variant"] == control_name:
                continue
            row_regression, candidate = _score_row(row, control, threshold)
            guardrail_regression = guardrail_regression or row_regression
            if candidate:
                candidates.append(row)
    return candidates, guardrail_regression


def _decision(context: dict[str, Any]) -> tuple[str, str, str | None]:
    status = "no_material_difference"
    reason = "No treatment exceeded control at the preregistered confidence threshold."
    winner = None
    if context["validity_flags"]:
        status = "insufficient_evidence"
        reason = "Novelty, seasonality, or another preregistered validity concern requires more evidence."
    elif context["insufficient"]:
        status = "insufficient_evidence"
        reason = "Minimum sample, privacy threshold, or preregistered duration has not been met."
    elif context["contradictory"]:
        status = "contradictory"
        reason = "Primary or supporting metrics conflict; owner review is required."
    elif context["guardrail_regression"]:
        status = "guardrail_regression"
        reason = "A preregistered guardrail regressed; no winner may be adopted."
    elif context["candidates"]:
        winner = max(context["candidates"], key=lambda row: (row["lift"], row["variant"]))["variant"]
        status = "candidate_winner"
        reason = "A treatment exceeded control at the preregistered confidence threshold."
    return status, reason, winner


def analyze_experiment(document: dict[str, Any], run_id: str, observed_at: str) -> dict[str, Any]:
    """Analyze preregistered aggregate binary outcomes without optional stopping."""
    variants, by_variant, control, policy, window = _contract(document)
    minimum = max(int(policy["minimum_per_variant"]), int(policy["privacy_minimum"]))
    rows, insufficient, validity_flags = _rows(document, variants, by_variant, minimum)
    peeking = _window_peeking(window, observed_at)
    insufficient = insufficient or peeking
    candidates, guardrail_regression = _score(rows, control, float(policy["confidence_threshold"]), insufficient)
    decision_context = {"validity_flags": validity_flags, "insufficient": insufficient, "contradictory": document.get("contradictory_metrics") is True, "guardrail_regression": guardrail_regression, "candidates": candidates}
    status, reason, winner = _decision(decision_context)
    identity = {"experiment_id": document["experiment_id"], "source_snapshot": document["source_snapshot"], "run_id": run_id, "rows": rows, "policy": policy, "window": window}
    return {
        "schema": SCHEMA_EXPERIMENT_ANALYSIS,
        "analysis_id": digest("mkt-experiment-analysis-v1", identity),
        "experiment_id": document["experiment_id"],
        "run_id": run_id,
        "source_snapshot": document["source_snapshot"],
        "primary_metric": document["metrics"]["primary"],
        "status": status,
        "reason": reason,
        "winner": winner,
        "observed_at": observed_at,
        "variants": rows,
        "peeking_detected": peeking,
        "validity_flags": sorted(str(flag) for flag in validity_flags),
        "causality": "experimental" if document["assignment"].get("method") in {"deterministic_hash", "provider_randomized"} else "observational",
    }
