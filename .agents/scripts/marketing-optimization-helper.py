#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic privacy-safe marketing attribution and experiment analysis."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import tempfile
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

SCHEMA_ATTRIBUTION = "aidevops.marketing-attribution/v1"
SCHEMA_EXPERIMENT_ANALYSIS = "aidevops.marketing-experiment-analysis/v1"
SCHEMA_REPORT = "aidevops.marketing-optimization-report/v1"
SCHEMA_RECOMMENDATION = "aidevops.growth-recommendation/v1"
TOUCHPOINT_TYPES = {"impression", "engagement", "social_receipt", "visit", "outreach_sent"}
OUTCOME_TYPES = {"conversion", "lead_created", "lead_stage", "sale", "revenue"}
PROHIBITED_MUTATIONS = [
    "publish",
    "message",
    "spend",
    "retarget",
    "change_audience",
    "change_offer",
    "mutate_provider_account",
]


class OptimizationError(ValueError):
    """Raised when an optimization input violates the public contract."""


def _load(path: str) -> dict[str, Any]:
    document = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise OptimizationError("input must be a JSON object")
    return document


def _canonical(document: Any) -> str:
    return json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def _digest(prefix: str, document: Any) -> str:
    value = hashlib.sha256(_canonical(document).encode("utf-8")).hexdigest()
    return f"{prefix}:{value}"


def _timestamp(value: Any, field: str) -> datetime:
    if not isinstance(value, str):
        raise OptimizationError(f"{field} must be an RFC 3339 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise OptimizationError(f"{field} must be an RFC 3339 timestamp") from exc
    if parsed.tzinfo is None:
        raise OptimizationError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _decimal(value: Any, field: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise OptimizationError(f"{field} must be an integer or canonical decimal string")
    try:
        return Decimal(str(value))
    except InvalidOperation as exc:
        raise OptimizationError(f"{field} is not numeric") from exc


def _decimal_text(value: Decimal) -> str:
    normalized = format(value, "f")
    if "." in normalized:
        normalized = normalized.rstrip("0").rstrip(".")
    return normalized or "0"


def _artifact_identity(document: dict[str, Any]) -> Any:
    fields = ("projection_id", "analysis_id", "report_id", "recommendation_id")
    return next((document.get(field) for field in fields if document.get(field)), None)


def _artifact_time(document: dict[str, Any]) -> Any:
    return document.get("generated_at") or document.get("observed_at") or document.get("created_at")


def _guard_publish(target: Path, document: dict[str, Any]) -> None:
    if not target.exists():
        return
    existing = json.loads(target.read_text(encoding="utf-8"))
    existing_time = _artifact_time(existing)
    incoming_time = _artifact_time(document)
    same_identity = _artifact_identity(existing) == _artifact_identity(document)
    if same_identity or not existing_time or not incoming_time:
        return
    if _timestamp(incoming_time, "incoming publish time") <= _timestamp(existing_time, "existing publish time"):
        raise OptimizationError("atomic publish refused to overwrite an equal or newer analytical artifact")


def _atomic_replace(target: Path, rendered: str) -> None:
    file_descriptor, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _write(document: dict[str, Any], output: str | None) -> None:
    rendered = json.dumps(document, sort_keys=True, indent=2) + "\n"
    if output is None:
        print(rendered, end="")
        return
    target = Path(output).expanduser().absolute()
    target.parent.mkdir(parents=True, exist_ok=True)
    _guard_publish(target, document)
    _atomic_replace(target, rendered)


def _event_parts(event: dict[str, Any]) -> tuple[str, datetime, dict[str, Any], dict[str, Any], dict[str, Any]]:
    try:
        event_type = str(event["event"]["type"])
        occurred_at = _timestamp(event["event"]["occurred_at"], "event.occurred_at")
        subject = event["subject"]
        scope = event["scope"]
        measurement = event["measurement"]
    except (KeyError, TypeError) as exc:
        raise OptimizationError("events must follow marketing-performance-event v1") from exc
    if not all(isinstance(value, dict) for value in (subject, scope, measurement)):
        raise OptimizationError("event subject, scope, and measurement must be objects")
    return event_type, occurred_at, subject, scope, measurement


def _parse_attribution_events(events: list[dict[str, Any]]) -> list[tuple[Any, ...]]:
    parsed: list[tuple[datetime, str, dict[str, Any], dict[str, Any], dict[str, Any], str]] = []
    for index, raw_event in enumerate(events):
        if not isinstance(raw_event, dict):
            raise OptimizationError("each event must be an object")
        event_type, occurred_at, subject, scope, measurement = _event_parts(raw_event)
        stable_ref = str(raw_event.get("event_ref") or f"event-{index:08d}")
        parsed.append((occurred_at, event_type, subject, scope, measurement, stable_ref))
    parsed.sort(key=lambda item: (item[0], item[5]))
    return parsed


def _attribution_input(document: dict[str, Any], model: str) -> tuple[list[dict[str, Any]], str, str, list[tuple[Any, ...]]]:
    if model not in {"direct", "last_touch"}:
        raise OptimizationError("model must be direct or last_touch")
    events = document.get("events")
    if not isinstance(events, list):
        raise OptimizationError("events must be an array")
    snapshot = str(document.get("source_snapshot") or "")
    if not snapshot:
        raise OptimizationError("source_snapshot is required")
    source_coverage = document.get("coverage", "unknown")
    if source_coverage not in {"complete", "partial", "unknown"}:
        raise OptimizationError("coverage must be complete, partial, or unknown")
    parsed = _parse_attribution_events(events)
    return events, snapshot, source_coverage, parsed


def _touchpoint_index(parsed: list[tuple[Any, ...]]) -> dict[str, list[tuple[datetime, dict[str, Any]]]]:
    touchpoints: dict[str, list[tuple[datetime, dict[str, Any]]]] = defaultdict(list)
    for occurred_at, event_type, subject, scope, _measurement, _event_ref in parsed:
        subject_id = subject.get("subject_id")
        if event_type in TOUCHPOINT_TYPES and isinstance(subject_id, str):
            touchpoints[subject_id].append((occurred_at, scope))
    return touchpoints


def _attribution_bucket(totals: dict[tuple[Any, ...], dict[str, Any]], scope: dict[str, Any], currency: str | None) -> dict[str, Any]:
    key = (scope.get("campaign_id"), scope.get("channel"), currency)
    return totals.setdefault(
        key,
        {"credited_outcomes": 0, "credit": Decimal(0), "revenue": Decimal(0), "refunds": Decimal(0), "costs": Decimal(0), "uncertain": False},
    )


def _attributed_scope(occurred_at: datetime, subject: dict[str, Any], scope: dict[str, Any], model: str, window_seconds: int, touchpoints: dict[str, list[tuple[datetime, dict[str, Any]]]]) -> dict[str, Any] | None:
    if subject.get("identity_state") == "ambiguous":
        return None
    if model == "direct":
        return scope
    subject_id = subject.get("subject_id")
    if isinstance(subject_id, str):
        candidates = [
            candidate_scope
            for touched_at, candidate_scope in touchpoints.get(subject_id, [])
            if 0 <= (occurred_at - touched_at).total_seconds() <= window_seconds
        ]
        if candidates:
            return candidates[-1]
    return scope if scope.get("channel") == "direct" else None


def _measurement_currency(measurement: dict[str, Any]) -> str | None:
    currency = measurement.get("currency")
    if currency is not None and not isinstance(currency, str):
        raise OptimizationError("measurement.currency must be a string or null")
    return currency


def _apply_attribution_event(event: tuple[Any, ...], totals: dict[tuple[Any, ...], dict[str, Any]], model: str, window_days: int, touchpoints: dict[str, list[tuple[datetime, dict[str, Any]]]]) -> tuple[int, int, int]:
    occurred_at, event_type, subject, scope, measurement, _event_ref = event
    value = _decimal(measurement.get("value"), "measurement.value")
    currency = _measurement_currency(measurement)
    if event_type in {"refund", "cost"}:
        target = _attribution_bucket(totals, scope, currency)
        target["refunds" if event_type == "refund" else "costs"] += abs(value)
        return 0, 0, 0
    if event_type not in OUTCOME_TYPES:
        return 0, 0, 0
    identity_state = subject.get("identity_state")
    uncertain = int(identity_state == "ambiguous")
    selected_scope = _attributed_scope(occurred_at, subject, scope, model, window_days * 86400, touchpoints)
    if selected_scope is None:
        return 0, 1, uncertain
    target = _attribution_bucket(totals, selected_scope, currency)
    target["credited_outcomes"] += 1
    target["credit"] += Decimal(1)
    target["revenue"] += value if event_type == "revenue" else Decimal(0)
    target["uncertain"] = target["uncertain"] or identity_state == "split"
    return 1, 0, uncertain


def _attribute_events(parsed: list[tuple[Any, ...]], model: str, window_days: int) -> tuple[dict[tuple[Any, ...], dict[str, Any]], int, int, int]:
    touchpoints = _touchpoint_index(parsed)
    totals: dict[tuple[Any, ...], dict[str, Any]] = {}
    matched = unattributed = uncertain = 0
    for event in parsed:
        event_matched, event_unattributed, event_uncertain = _apply_attribution_event(event, totals, model, window_days, touchpoints)
        matched += event_matched
        unattributed += event_unattributed
        uncertain += event_uncertain
    return totals, matched, unattributed, uncertain


def _attribution_aggregates(totals: dict[tuple[Any, ...], dict[str, Any]], source_coverage: str) -> list[dict[str, Any]]:
    aggregates = []
    for (campaign_id, channel, currency), values in sorted(
        totals.items(), key=lambda item: tuple("" if value is None else value for value in item[0])
    ):
        uncertainty = "high" if values["uncertain"] or source_coverage == "unknown" else "medium" if source_coverage == "partial" else "low"
        aggregates.append({
            "campaign_id": campaign_id,
            "channel": channel,
            "credited_outcomes": values["credited_outcomes"],
            "credit": _decimal_text(values["credit"]),
            "revenue": _decimal_text(values["revenue"]),
            "refunds": _decimal_text(values["refunds"]),
            "costs": _decimal_text(values["costs"]),
            "net_revenue": _decimal_text(values["revenue"] - values["refunds"]),
            "currency": currency,
            "uncertainty": uncertainty,
        })
    return aggregates


def attribute(document: dict[str, Any], model: str, window_days: int, model_version: int, window_version: int, run_id: str, generated_at: str) -> dict[str, Any]:
    """Build a deterministic aggregate attribution projection."""
    events, snapshot, source_coverage, parsed = _attribution_input(document, model)
    totals, matched, unattributed, uncertain = _attribute_events(parsed, model, window_days)
    aggregates = _attribution_aggregates(totals, source_coverage)

    identity_events = sorted(events, key=lambda event: (str(event.get("event_ref", "")), _canonical(event)))
    identity = {"source_snapshot": snapshot, "model": model, "model_version": model_version, "window_days": window_days, "window_version": window_version, "events": identity_events}
    return {
        "schema": SCHEMA_ATTRIBUTION,
        "projection_id": _digest("mkt-attribution-v1", identity),
        "run_id": run_id,
        "source_snapshot": snapshot,
        "model": {"name": model, "version": model_version},
        "window": {"days": window_days, "version": window_version},
        "generated_at": generated_at,
        "coverage": {"source": source_coverage, "matched_outcomes": matched, "unattributed_outcomes": unattributed, "identity_uncertain_outcomes": uncertain},
        "causality": {"claim": "observational", "caveat": "Attribution assigns observational credit; it does not establish incremental or causal growth."},
        "aggregates": aggregates,
    }


def _require_experiment_fields(document: dict[str, Any]) -> None:
    required = ["experiment_id", "source_snapshot", "state", "hypothesis", "owner", "variants", "assignment", "metrics", "sample_policy", "window", "stopping_policy", "exclusions", "observations"]
    missing = [field for field in required if field not in document]
    if missing:
        raise OptimizationError(f"experiment input missing: {', '.join(missing)}")


def _validate_experiment_collections(document: dict[str, Any]) -> None:
    variants = document["variants"]
    observations = document["observations"]
    if not isinstance(variants, list):
        raise OptimizationError("experiment variants must be an array")
    if len(variants) < 2:
        raise OptimizationError("experiment requires at least two variants")
    if not isinstance(observations, list):
        raise OptimizationError("experiment requires at least two variants and aggregate observations")


def _validate_experiment_registry(document: dict[str, Any]) -> None:
    _validate_experiment_collections(document)
    if document["state"] not in {"running", "analysis_ready", "decided"}:
        raise OptimizationError("only running, analysis_ready, or decided experiments can be analyzed")
    if not str(document["hypothesis"]).strip():
        raise OptimizationError("experiment hypothesis and owner must be preregistered")
    if not str(document["owner"]).strip():
        raise OptimizationError("experiment hypothesis and owner must be preregistered")
    if not str(document["stopping_policy"]).strip():
        raise OptimizationError("experiment stopping_policy and exclusions must be preregistered")
    if not isinstance(document["exclusions"], list):
        raise OptimizationError("experiment stopping_policy and exclusions must be preregistered")


def _experiment_contract(document: dict[str, Any]) -> tuple[list[str], dict[str, dict[str, Any]], str, dict[str, Any], dict[str, Any]]:
    _require_experiment_fields(document)
    _validate_experiment_registry(document)
    variants = document["variants"]
    observations = document["observations"]
    control = document["assignment"].get("control_variant")
    if control not in variants:
        raise OptimizationError("control_variant must name a preregistered variant")
    by_variant = {str(item.get("variant")): item for item in observations if isinstance(item, dict)}
    if set(by_variant) != set(variants):
        raise OptimizationError("observations must contain each preregistered variant exactly once")
    return variants, by_variant, control, document["sample_policy"], document["window"]


def _experiment_window(window: dict[str, Any], observed_at: str) -> bool:
    starts_at = _timestamp(window["starts_at"], "window.starts_at")
    ends_at = _timestamp(window["ends_at"], "window.ends_at")
    analysis_time = _timestamp(observed_at, "observed_at")
    elapsed_days = (min(analysis_time, ends_at) - starts_at).total_seconds() / 86400
    return analysis_time < ends_at or elapsed_days < int(window["minimum_days"])


def _experiment_row(variant: str, observation: dict[str, Any], minimum: int, registered_guardrails: set[str]) -> tuple[dict[str, Any], bool]:
    sample = int(observation.get("sample", 0))
    successes = int(observation.get("successes", 0))
    if sample < 0 or successes < 0 or successes > sample:
        raise OptimizationError("experiment sample and successes are invalid")
    observed_guardrails = observation.get("guardrails", {})
    if not isinstance(observed_guardrails, dict) or set(observed_guardrails) != registered_guardrails:
        raise OptimizationError("observed guardrails must exactly match preregistered guardrail metrics")
    row = {"variant": variant, "sample": sample, "successes": successes, "rate": successes / sample if sample else 0.0, "guardrails": observed_guardrails}
    return row, sample < minimum


def _experiment_rows(document: dict[str, Any], variants: list[str], by_variant: dict[str, dict[str, Any]], minimum: int) -> tuple[list[dict[str, Any]], bool, list[Any]]:
    validity_flags = document.get("validity_flags", [])
    if not isinstance(validity_flags, list):
        raise OptimizationError("validity_flags must be an array")
    registered_guardrails = set(document["metrics"].get("guardrails", []))
    rows = []
    insufficient = bool(validity_flags)
    for variant in variants:
        row, below_minimum = _experiment_row(variant, by_variant[variant], minimum, registered_guardrails)
        rows.append(row)
        insufficient = insufficient or below_minimum
    return rows, insufficient, validity_flags


def _score_experiment_row(row: dict[str, Any], control_row: dict[str, Any], threshold: float) -> tuple[bool, bool]:
    pooled = (row["successes"] + control_row["successes"]) / (row["sample"] + control_row["sample"])
    error = math.sqrt(pooled * (1 - pooled) * (1 / row["sample"] + 1 / control_row["sample"]))
    z_score = (row["rate"] - control_row["rate"]) / error if error else 0.0
    confidence = math.erf(abs(z_score) / math.sqrt(2))
    row["lift"] = row["rate"] - control_row["rate"]
    row["confidence"] = confidence
    regressions = [name for name, value in row["guardrails"].items() if isinstance(value, dict) and value.get("regressed") is True]
    row["guardrail_regressions"] = sorted(regressions)
    return bool(regressions), row["lift"] > 0 and confidence >= threshold


def _score_experiment(rows: list[dict[str, Any]], control: str, threshold: float, insufficient: bool) -> tuple[list[dict[str, Any]], bool]:
    control_row = next(row for row in rows if row["variant"] == control)
    candidates: list[dict[str, Any]] = []
    guardrail_regression = False
    if not insufficient:
        for row in rows:
            if row["variant"] == control:
                continue
            row_regression, candidate = _score_experiment_row(row, control_row, threshold)
            guardrail_regression = guardrail_regression or row_regression
            if candidate:
                candidates.append(row)
    return candidates, guardrail_regression


def _experiment_decision(validity_flags: list[Any], insufficient: bool, contradictory: bool, guardrail_regression: bool, candidates: list[dict[str, Any]]) -> tuple[str, str, str | None]:
    if validity_flags:
        return "insufficient_evidence", "Novelty, seasonality, or another preregistered validity concern requires more evidence.", None
    if insufficient:
        return "insufficient_evidence", "Minimum sample, privacy threshold, or preregistered duration has not been met.", None
    if contradictory:
        return "contradictory", "Primary or supporting metrics conflict; owner review is required.", None
    if guardrail_regression:
        return "guardrail_regression", "A preregistered guardrail regressed; no winner may be adopted.", None
    if candidates:
        winner = max(candidates, key=lambda row: (row["lift"], row["variant"]))["variant"]
        return "candidate_winner", "A treatment exceeded control at the preregistered confidence threshold.", winner
    return "no_material_difference", "No treatment exceeded control at the preregistered confidence threshold.", None


def analyze_experiment(document: dict[str, Any], run_id: str, observed_at: str) -> dict[str, Any]:
    """Analyze preregistered aggregate binary outcomes without optional stopping."""
    variants, by_variant, control, policy, window = _experiment_contract(document)
    minimum = max(int(policy["minimum_per_variant"]), int(policy["privacy_minimum"]))
    rows, insufficient, validity_flags = _experiment_rows(document, variants, by_variant, minimum)
    peeking = _experiment_window(window, observed_at)
    insufficient = insufficient or peeking
    candidates, guardrail_regression = _score_experiment(rows, control, float(policy["confidence_threshold"]), insufficient)
    status, reason, winner = _experiment_decision(validity_flags, insufficient, document.get("contradictory_metrics") is True, guardrail_regression, candidates)
    identity = {"experiment_id": document["experiment_id"], "source_snapshot": document["source_snapshot"], "run_id": run_id, "rows": rows, "policy": policy, "window": window}
    return {
        "schema": SCHEMA_EXPERIMENT_ANALYSIS,
        "analysis_id": _digest("mkt-experiment-analysis-v1", identity),
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


def _report_freshness(sources: Any, generated_at: str, stale_after_hours: int) -> tuple[list[dict[str, Any]], bool]:
    if not isinstance(sources, list):
        raise OptimizationError("report sources must be an array")
    generated = _timestamp(generated_at, "generated_at")
    freshness = []
    stale = False
    for source in sources:
        observed = _timestamp(source.get("observed_at"), "sources.observed_at")
        age_hours = max(0.0, (generated - observed).total_seconds() / 3600)
        source_stale = age_hours > stale_after_hours
        stale = stale or source_stale
        freshness.append({"source": source.get("source"), "coverage": source.get("coverage", "unknown"), "observed_at": source.get("observed_at"), "age_hours": round(age_hours, 3), "status": "stale" if source_stale else "fresh"})
    return freshness, stale


def _report_funnel_row(aggregate: dict[str, Any], minimum_cohort: int) -> dict[str, Any] | None:
    if int(aggregate["credited_outcomes"]) < minimum_cohort:
        return None
    revenue = Decimal(aggregate["revenue"])
    refunds = Decimal(aggregate["refunds"])
    costs = Decimal(aggregate["costs"])
    net = revenue - refunds
    roi = (net - costs) / costs if costs else None
    return {**aggregate, "roi": _decimal_text(roi) if roi is not None else None, "payback": "not_computable" if costs == 0 else "covered" if net >= costs else "not_covered"}


def _report_funnel(attribution: Any, minimum_cohort: int) -> tuple[list[dict[str, Any]], int]:
    if attribution is not None and attribution.get("schema") != SCHEMA_ATTRIBUTION:
        raise OptimizationError("report attribution input has an unsupported schema")
    aggregates = []
    suppressed = 0
    if attribution:
        for aggregate in attribution["aggregates"]:
            row = _report_funnel_row(aggregate, minimum_cohort)
            if row is None:
                suppressed += 1
                continue
            aggregates.append(row)
    return aggregates, suppressed


def _empty_metric_groups() -> dict[str, list[dict[str, Any]]]:
    return {
        "reach": [],
        "engagement": [],
        "account_growth": [],
        "traffic": [],
        "conversion": [],
        "leads_and_stages": [],
        "sales": [],
        "revenue_refunds_costs": [],
        "other": [],
    }


def _metric_category(metric_id: str) -> str:
    category_markers = (
        ("reach", ("impression", "reach")),
        ("engagement", ("engagement", "click", "reply")),
        ("account_growth", ("follower", "subscriber", "account_growth")),
        ("traffic", ("visit", "traffic", "session")),
        ("conversion", ("conversion",)),
        ("leads_and_stages", ("lead", "stage")),
        ("sales", ("sale",)),
        ("revenue_refunds_costs", ("revenue", "refund", "cost", "roi", "payback")),
    )
    return next((name for name, markers in category_markers if any(marker in metric_id for marker in markers)), "other")


def _report_metrics(metrics: Any, minimum_cohort: int) -> tuple[dict[str, list[dict[str, Any]]], int]:
    metric_groups = _empty_metric_groups()
    if not isinstance(metrics, list):
        raise OptimizationError("report metrics must be an array")
    suppressed = 0
    for metric in metrics:
        if not isinstance(metric, dict) or "metric_id" not in metric:
            raise OptimizationError("each report metric must be an object with metric_id")
        if {"subject_id", "event_ref", "contact", "email"}.intersection(metric):
            raise OptimizationError("individual-level fields are forbidden in reports")
        if int(metric.get("cohort_size", 0)) < minimum_cohort:
            suppressed += 1
            continue
        metric_groups[_metric_category(str(metric["metric_id"]))].append(metric)
    for group in metric_groups.values():
        group.sort(key=lambda metric: (str(metric.get("metric_id")), str(metric.get("source_ref", ""))))
    return metric_groups, suppressed


def build_report(document: dict[str, Any], minimum_cohort: int, stale_after_hours: int, generated_at: str) -> dict[str, Any]:
    """Render only aggregate, threshold-safe decision evidence."""
    attribution = document.get("attribution")
    experiments = document.get("experiments", [])
    if not isinstance(experiments, list):
        raise OptimizationError("experiments must be an array")
    freshness, stale = _report_freshness(document.get("sources", []), generated_at, stale_after_hours)
    aggregates, suppressed = _report_funnel(attribution, minimum_cohort)
    metric_groups, metric_suppressed = _report_metrics(document.get("metrics", []), minimum_cohort)
    suppressed += metric_suppressed
    contradictions = document.get("contradictions", [])
    if not isinstance(contradictions, list):
        raise OptimizationError("contradictions must be an array")
    caveats = ["Observational attribution does not establish causality.", "Suppressed cohorts are omitted rather than inferred.", "Missing or partial source coverage limits comparisons."]
    if contradictions:
        caveats.append("Contradictory metrics require owner review before a recommendation or decision.")

    return {
        "schema": SCHEMA_REPORT,
        "report_id": _digest("mkt-optimization-report-v1", {"attribution": attribution, "experiments": experiments, "metrics": metric_groups, "freshness": freshness, "minimum_cohort": minimum_cohort, "contradictions": contradictions}),
        "generated_at": generated_at,
        "status": "stale" if stale else "current",
        "privacy": {"minimum_cohort": minimum_cohort, "suppressed_aggregates": suppressed, "individual_records": False},
        "freshness": freshness,
        "funnel": aggregates,
        "metrics": metric_groups,
        "experiments": experiments,
        "contradictions": contradictions,
        "caveats": caveats,
        "decision_outputs": [experiment for experiment in experiments if experiment.get("status") in {"candidate_winner", "guardrail_regression", "insufficient_evidence"}],
    }


def _recommendation_evidence(document: dict[str, Any]) -> dict[str, Any]:
    evidence = document.get("evidence")
    if not isinstance(evidence, dict):
        raise OptimizationError("evidence is required")
    required = ["refs", "source_snapshot", "sample_size", "causality", "target_metric", "observed_problem", "expected_impact"]
    missing = [field for field in required if field not in evidence]
    if missing:
        raise OptimizationError(f"recommendation evidence missing: {', '.join(missing)}")
    return evidence


def _recommendation_status(document: dict[str, Any], evidence: dict[str, Any]) -> str:
    evidence_blocked = document.get("evidence_status") in {"insufficient_evidence", "stale", "contradictory"}
    evidence_blocked = evidence_blocked or evidence.get("freshness") == "stale" or evidence.get("contradictory") is True
    if int(evidence["sample_size"]) < int(document.get("minimum_sample", 2)) or evidence_blocked:
        return "insufficient_evidence"
    return "awaiting_approval"


def _recommendation_impact(evidence: dict[str, Any], retest_at: str, created_at: str) -> dict[str, Any]:
    expected_impact = evidence["expected_impact"]
    if not isinstance(expected_impact, dict) or float(expected_impact["minimum"]) > float(expected_impact["maximum"]):
        raise OptimizationError("expected impact minimum cannot exceed maximum")
    if _timestamp(retest_at, "retest_at") <= _timestamp(created_at, "created_at"):
        raise OptimizationError("retest_at must be after created_at")
    return expected_impact


def recommend(document: dict[str, Any], owner: str, approval: str, rollback: str, retest_at: str, created_at: str) -> dict[str, Any]:
    """Create an approval-bound recommendation, never a provider mutation."""
    evidence = _recommendation_evidence(document)
    status = _recommendation_status(document, evidence)
    supersedes = sorted(set(document.get("supersedes", [])))
    expected_impact = _recommendation_impact(evidence, retest_at, created_at)
    identity = {"evidence": evidence, "owner": owner, "approval": approval, "rollback": rollback, "retest_at": retest_at, "supersedes": supersedes}
    return {
        "schema": SCHEMA_RECOMMENDATION,
        "recommendation_id": _digest("growth-rec-v1", identity),
        "status": status,
        "observed_problem": evidence["observed_problem"],
        "target_metric": evidence["target_metric"],
        "evidence": {"refs": sorted(set(evidence["refs"])), "source_snapshot": evidence["source_snapshot"], "sample_size": int(evidence["sample_size"]), "privacy_safe": True, "causality": evidence["causality"]},
        "expected_impact": expected_impact,
        "confidence": evidence.get("confidence", "medium"),
        "owner": owner,
        "required_approval": approval,
        "prohibited_mutations": PROHIBITED_MUTATIONS,
        "rollback": rollback,
        "retest_at": retest_at,
        "created_at": created_at,
        "supersedes": supersedes,
    }


def status(document: dict[str, Any], now: str, stale_after_hours: int) -> dict[str, Any]:
    """Return freshness without mutating reports or decisions."""
    observed_value = document.get("generated_at") or document.get("observed_at")
    observed = _timestamp(observed_value, "generated_at/observed_at")
    age_hours = max(0.0, (_timestamp(now, "now") - observed).total_seconds() / 3600)
    return {"schema": "aidevops.marketing-optimization-status/v1", "status": "stale" if age_hours > stale_after_hours else "current", "age_hours": round(age_hours, 3), "stale_after_hours": stale_after_hours, "source_schema": document.get("schema")}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    attribute_parser = subparsers.add_parser("attribute", help="Build a versioned attribution projection")
    attribute_parser.add_argument("--input", required=True)
    attribute_parser.add_argument("--output")
    attribute_parser.add_argument("--model", choices=("direct", "last_touch"), default="last_touch")
    attribute_parser.add_argument("--window-days", type=int, default=30)
    attribute_parser.add_argument("--model-version", type=int, default=1)
    attribute_parser.add_argument("--window-version", type=int, default=1)
    attribute_parser.add_argument("--run-id", required=True)
    attribute_parser.add_argument("--generated-at", required=True)

    experiment_parser = subparsers.add_parser("experiment", help="Analyze a preregistered aggregate experiment")
    experiment_parser.add_argument("--input", required=True)
    experiment_parser.add_argument("--output")
    experiment_parser.add_argument("--run-id", required=True)
    experiment_parser.add_argument("--observed-at", required=True)

    report_parser = subparsers.add_parser("report", help="Build a freshness-aware aggregate report")
    report_parser.add_argument("--input", required=True)
    report_parser.add_argument("--output")
    report_parser.add_argument("--minimum-cohort", type=int, default=10)
    report_parser.add_argument("--stale-after-hours", type=int, default=48)
    report_parser.add_argument("--generated-at", required=True)

    recommend_parser = subparsers.add_parser("recommend", help="Create an approval-bound recommendation")
    recommend_parser.add_argument("--input", required=True)
    recommend_parser.add_argument("--output")
    recommend_parser.add_argument("--owner", choices=("content", "marketing", "product", "sales", "seo", "campaign-owner", "report-owner"), required=True)
    recommend_parser.add_argument("--approval", required=True)
    recommend_parser.add_argument("--rollback", required=True)
    recommend_parser.add_argument("--retest-at", required=True)
    recommend_parser.add_argument("--created-at", required=True)

    status_parser = subparsers.add_parser("status", help="Check projection or report freshness")
    status_parser.add_argument("--input", required=True)
    status_parser.add_argument("--output")
    status_parser.add_argument("--now", required=True)
    status_parser.add_argument("--stale-after-hours", type=int, default=48)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        document = _load(args.input)
        if args.command == "attribute":
            result = attribute(document, args.model, args.window_days, args.model_version, args.window_version, args.run_id, args.generated_at)
        elif args.command == "experiment":
            result = analyze_experiment(document, args.run_id, args.observed_at)
        elif args.command == "report":
            result = build_report(document, args.minimum_cohort, args.stale_after_hours, args.generated_at)
        elif args.command == "recommend":
            result = recommend(document, args.owner, args.approval, args.rollback, args.retest_at, args.created_at)
        else:
            result = status(document, args.now, args.stale_after_hours)
        _write(result, args.output)
    except (OSError, json.JSONDecodeError, OptimizationError, KeyError, TypeError, ValueError) as exc:
        print(json.dumps({"schema": "aidevops.marketing-optimization-error/v1", "error": str(exc)}))
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
