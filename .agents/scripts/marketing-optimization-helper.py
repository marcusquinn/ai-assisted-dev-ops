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


def _write(document: dict[str, Any], output: str | None) -> None:
    rendered = json.dumps(document, sort_keys=True, indent=2) + "\n"
    if output is None:
        print(rendered, end="")
        return
    target = Path(output).expanduser().absolute()
    target.parent.mkdir(parents=True, exist_ok=True)
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


def attribute(document: dict[str, Any], model: str, window_days: int, model_version: int, window_version: int, run_id: str, generated_at: str) -> dict[str, Any]:
    """Build a deterministic aggregate attribution projection."""
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

    parsed: list[tuple[datetime, str, dict[str, Any], dict[str, Any], dict[str, Any], str]] = []
    for index, raw_event in enumerate(events):
        if not isinstance(raw_event, dict):
            raise OptimizationError("each event must be an object")
        event_type, occurred_at, subject, scope, measurement = _event_parts(raw_event)
        stable_ref = str(raw_event.get("event_ref") or f"event-{index:08d}")
        parsed.append((occurred_at, event_type, subject, scope, measurement, stable_ref))
    parsed.sort(key=lambda item: (item[0], item[5]))

    touchpoints: dict[str, list[tuple[datetime, dict[str, Any]]]] = defaultdict(list)
    for occurred_at, event_type, subject, scope, _measurement, _event_ref in parsed:
        subject_id = subject.get("subject_id")
        if event_type in TOUCHPOINT_TYPES and isinstance(subject_id, str):
            touchpoints[subject_id].append((occurred_at, scope))

    totals: dict[tuple[str | None, str | None, str | None], dict[str, Any]] = {}
    matched = 0
    unattributed = 0
    uncertain = 0

    def bucket(scope: dict[str, Any], currency: str | None) -> dict[str, Any]:
        key = (scope.get("campaign_id"), scope.get("channel"), currency)
        return totals.setdefault(
            key,
            {"credited_outcomes": 0, "credit": Decimal(0), "revenue": Decimal(0), "refunds": Decimal(0), "costs": Decimal(0), "uncertain": False},
        )

    window_seconds = window_days * 86400
    for occurred_at, event_type, subject, scope, measurement, _event_ref in parsed:
        value = _decimal(measurement.get("value"), "measurement.value")
        currency = measurement.get("currency")
        if currency is not None and not isinstance(currency, str):
            raise OptimizationError("measurement.currency must be a string or null")
        if event_type in {"refund", "cost"}:
            target = bucket(scope, currency)
            target["refunds" if event_type == "refund" else "costs"] += abs(value)
            continue
        if event_type not in OUTCOME_TYPES:
            continue

        attributed_scope: dict[str, Any] | None = None
        identity_state = subject.get("identity_state")
        subject_id = subject.get("subject_id")
        if identity_state == "ambiguous":
            uncertain += 1
        elif model == "direct":
            attributed_scope = scope
        elif isinstance(subject_id, str):
            candidates = [
                candidate_scope
                for touched_at, candidate_scope in touchpoints.get(subject_id, [])
                if 0 <= (occurred_at - touched_at).total_seconds() <= window_seconds
            ]
            if candidates:
                attributed_scope = candidates[-1]
        if attributed_scope is None and scope.get("channel") == "direct":
            attributed_scope = scope
        if attributed_scope is None:
            unattributed += 1
            continue

        target = bucket(attributed_scope, currency)
        target["credited_outcomes"] += 1
        target["credit"] += Decimal(1)
        if event_type == "revenue":
            target["revenue"] += value
        if identity_state in {"ambiguous", "split"}:
            target["uncertain"] = True
        matched += 1

    aggregates = []
    for (campaign_id, channel, currency), values in sorted(totals.items(), key=lambda item: tuple("" if value is None else value for value in item[0])):
        net_revenue = values["revenue"] - values["refunds"]
        uncertainty = "high" if values["uncertain"] or source_coverage == "unknown" else "medium" if source_coverage == "partial" else "low"
        aggregates.append(
            {
                "campaign_id": campaign_id,
                "channel": channel,
                "credited_outcomes": values["credited_outcomes"],
                "credit": _decimal_text(values["credit"]),
                "revenue": _decimal_text(values["revenue"]),
                "refunds": _decimal_text(values["refunds"]),
                "costs": _decimal_text(values["costs"]),
                "net_revenue": _decimal_text(net_revenue),
                "currency": currency,
                "uncertainty": uncertainty,
            }
        )

    identity = {"source_snapshot": snapshot, "model": model, "model_version": model_version, "window_days": window_days, "window_version": window_version, "events": events}
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


def analyze_experiment(document: dict[str, Any], run_id: str, observed_at: str) -> dict[str, Any]:
    """Analyze preregistered aggregate binary outcomes without optional stopping."""
    required = ["experiment_id", "source_snapshot", "variants", "assignment", "metrics", "sample_policy", "window", "observations"]
    missing = [field for field in required if field not in document]
    if missing:
        raise OptimizationError(f"experiment input missing: {', '.join(missing)}")
    variants = document["variants"]
    observations = document["observations"]
    if not isinstance(variants, list) or len(variants) < 2 or not isinstance(observations, list):
        raise OptimizationError("experiment requires at least two variants and aggregate observations")
    control = document["assignment"].get("control_variant")
    if control not in variants:
        raise OptimizationError("control_variant must name a preregistered variant")
    by_variant = {str(item.get("variant")): item for item in observations if isinstance(item, dict)}
    if set(by_variant) != set(variants):
        raise OptimizationError("observations must contain each preregistered variant exactly once")
    policy = document["sample_policy"]
    minimum = max(int(policy["minimum_per_variant"]), int(policy["privacy_minimum"]))
    threshold = float(policy["confidence_threshold"])
    window = document["window"]
    elapsed_days = (_timestamp(window["ends_at"], "window.ends_at") - _timestamp(window["starts_at"], "window.starts_at")).total_seconds() / 86400
    peeking = elapsed_days < int(window["minimum_days"])

    rows: list[dict[str, Any]] = []
    insufficient = peeking
    for variant in variants:
        observation = by_variant[variant]
        sample = int(observation.get("sample", 0))
        successes = int(observation.get("successes", 0))
        if sample < 0 or successes < 0 or successes > sample:
            raise OptimizationError("experiment sample and successes are invalid")
        if sample < minimum:
            insufficient = True
        rows.append({"variant": variant, "sample": sample, "successes": successes, "rate": successes / sample if sample else 0.0, "guardrails": observation.get("guardrails", {})})

    control_row = next(row for row in rows if row["variant"] == control)
    candidates: list[tuple[float, dict[str, Any], float]] = []
    guardrail_regression = False
    if not insufficient:
        for row in rows:
            if row["variant"] == control:
                continue
            pooled = (row["successes"] + control_row["successes"]) / (row["sample"] + control_row["sample"])
            error = math.sqrt(pooled * (1 - pooled) * (1 / row["sample"] + 1 / control_row["sample"]))
            z_score = (row["rate"] - control_row["rate"]) / error if error else 0.0
            confidence = math.erf(abs(z_score) / math.sqrt(2))
            row["lift"] = row["rate"] - control_row["rate"]
            row["confidence"] = confidence
            regressions = [name for name, value in row["guardrails"].items() if isinstance(value, dict) and value.get("regressed") is True]
            row["guardrail_regressions"] = sorted(regressions)
            guardrail_regression = guardrail_regression or bool(regressions)
            if row["lift"] > 0 and confidence >= threshold:
                candidates.append((row["lift"], row, confidence))

    if insufficient:
        status, reason, winner = "insufficient_evidence", "Minimum sample, privacy threshold, or preregistered duration has not been met.", None
    elif guardrail_regression:
        status, reason, winner = "guardrail_regression", "A preregistered guardrail regressed; no winner may be adopted.", None
    elif candidates:
        winner_row = max(candidates, key=lambda item: (item[0], item[1]["variant"]))[1]
        status, reason, winner = "candidate_winner", "A treatment exceeded control at the preregistered confidence threshold.", winner_row["variant"]
    else:
        status, reason, winner = "no_material_difference", "No treatment exceeded control at the preregistered confidence threshold.", None

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
        "causality": "experimental" if document["assignment"].get("method") in {"deterministic_hash", "provider_randomized"} else "observational",
    }


def build_report(document: dict[str, Any], minimum_cohort: int, stale_after_hours: int, generated_at: str) -> dict[str, Any]:
    """Render only aggregate, threshold-safe decision evidence."""
    attribution = document.get("attribution")
    experiments = document.get("experiments", [])
    if attribution is not None and attribution.get("schema") != SCHEMA_ATTRIBUTION:
        raise OptimizationError("report attribution input has an unsupported schema")
    if not isinstance(experiments, list):
        raise OptimizationError("experiments must be an array")
    generated = _timestamp(generated_at, "generated_at")
    sources = document.get("sources", [])
    freshness = []
    stale = False
    for source in sources:
        observed = _timestamp(source.get("observed_at"), "sources.observed_at")
        age_hours = max(0.0, (generated - observed).total_seconds() / 3600)
        source_stale = age_hours > stale_after_hours
        stale = stale or source_stale
        freshness.append({"source": source.get("source"), "coverage": source.get("coverage", "unknown"), "observed_at": source.get("observed_at"), "age_hours": round(age_hours, 3), "status": "stale" if source_stale else "fresh"})

    aggregates = []
    suppressed = 0
    if attribution:
        for aggregate in attribution["aggregates"]:
            if int(aggregate["credited_outcomes"]) < minimum_cohort:
                suppressed += 1
                continue
            revenue = Decimal(aggregate["revenue"])
            refunds = Decimal(aggregate["refunds"])
            costs = Decimal(aggregate["costs"])
            net = revenue - refunds
            roi = (net - costs) / costs if costs else None
            aggregates.append({**aggregate, "roi": _decimal_text(roi) if roi is not None else None, "payback": "not_computable" if costs == 0 else "covered" if net >= costs else "not_covered"})

    return {
        "schema": SCHEMA_REPORT,
        "report_id": _digest("mkt-optimization-report-v1", {"attribution": attribution, "experiments": experiments, "freshness": freshness, "minimum_cohort": minimum_cohort}),
        "generated_at": generated_at,
        "status": "stale" if stale else "current",
        "privacy": {"minimum_cohort": minimum_cohort, "suppressed_aggregates": suppressed, "individual_records": False},
        "freshness": freshness,
        "funnel": aggregates,
        "experiments": experiments,
        "caveats": ["Observational attribution does not establish causality.", "Suppressed cohorts are omitted rather than inferred.", "Missing or partial source coverage limits comparisons."],
        "decision_outputs": [experiment for experiment in experiments if experiment.get("status") in {"candidate_winner", "guardrail_regression", "insufficient_evidence"}],
    }


def recommend(document: dict[str, Any], owner: str, approval: str, rollback: str, retest_at: str, created_at: str) -> dict[str, Any]:
    """Create an approval-bound recommendation, never a provider mutation."""
    evidence = document.get("evidence")
    if not isinstance(evidence, dict):
        raise OptimizationError("evidence is required")
    required = ["refs", "source_snapshot", "sample_size", "causality", "target_metric", "observed_problem", "expected_impact"]
    missing = [field for field in required if field not in evidence]
    if missing:
        raise OptimizationError(f"recommendation evidence missing: {', '.join(missing)}")
    if int(evidence["sample_size"]) < int(document.get("minimum_sample", 2)) or document.get("evidence_status") == "insufficient_evidence":
        status = "insufficient_evidence"
    else:
        status = "awaiting_approval"
    supersedes = sorted(set(document.get("supersedes", [])))
    identity = {"evidence": evidence, "owner": owner, "approval": approval, "rollback": rollback, "retest_at": retest_at}
    return {
        "schema": SCHEMA_RECOMMENDATION,
        "recommendation_id": _digest("growth-rec-v1", identity),
        "status": status,
        "observed_problem": evidence["observed_problem"],
        "target_metric": evidence["target_metric"],
        "evidence": {"refs": sorted(set(evidence["refs"])), "source_snapshot": evidence["source_snapshot"], "sample_size": int(evidence["sample_size"]), "privacy_safe": True, "causality": evidence["causality"]},
        "expected_impact": evidence["expected_impact"],
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
