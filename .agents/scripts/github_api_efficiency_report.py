#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Decision and rendering layer for GitHub API efficiency evidence."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Any

from github_api_efficiency_inputs import (
    DISTRIBUTION_SAMPLE_FIELDS,
    EVIDENCE_GROUPS,
    POPULATION_FIELDS,
    Window,
)
from github_api_efficiency_metrics import TRANSPORT_METRICS


BENCHMARK_SCHEMA = "aidevops-github-api-efficiency-benchmark/v1"
STATUS_OK = "PASS"
STATUS_REGRESSION = "REGRESSION"
STATUS_INCONCLUSIVE = "INCONCLUSIVE"
EXIT_REGRESSION = 1
EXIT_INCONCLUSIVE = 2

_DENOMINATOR_LABELS = {
    "per_repo_hour": "Per repository-hour",
    "per_pulse_cycle": "Per Pulse cycle",
    "per_unchanged_cycle": "Per unchanged cycle",
    "per_actionable_change": "Per actionable change",
    "per_unique_head_sha": "Per unique actionable head SHA",
}


@dataclass(frozen=True)
class Thresholds:
    max_window_ratio: float
    max_cycle_rate_change_pct: float
    min_attempt_reduction_pct: float
    max_graphql_point_increase_pct: float
    max_error_rate_increase_points: float
    max_latency_increase_pct: float
    max_burst_increase_pct: float
    canary_not_before: int


def _flag(reasons: list[str], condition: bool, message: str) -> None:
    if condition:
        reasons.append(message)


def _unknown_evidence(window: Window) -> list[str]:
    reasons: list[str] = []
    population = window.evidence["population"]
    for field in POPULATION_FIELDS:
        _flag(
            reasons,
            population[field] is None,
            f"{window.label}: population.{field} is unknown",
        )
    _flag(
        reasons,
        population["repository_set_sha256"] is None,
        f"{window.label}: repository population fingerprint is unknown",
    )
    for group_name, fields in EVIDENCE_GROUPS.items():
        for field in fields:
            sample_field = DISTRIBUTION_SAMPLE_FIELDS.get((group_name, field))
            observed_empty = (
                sample_field is not None
                and window.evidence[group_name][sample_field] == 0
            )
            _flag(
                reasons,
                window.evidence[group_name][field] is None and not observed_empty,
                f"{window.label}: {group_name}.{field} is unknown",
            )
    return reasons


def _window_inconclusive_reasons(window: Window) -> list[str]:
    meta = window.report["_meta"]
    population = window.evidence["population"]
    reasons = _unknown_evidence(window)
    _flag(
        reasons,
        not window.evidence["complete"],
        f"{window.label}: evidence is marked incomplete",
    )
    _flag(
        reasons,
        not meta["attempts_exact"],
        f"{window.label}: transport attempts are not exact",
    )
    health_fields = {
        "unknown_quota_cost_attempts": "quota cost is unknown",
        "unknown_elapsed_attempts": "request latency is unknown",
        "duplicate_attempt_ids": "duplicate attempt IDs exist",
        "unidentified_attempts": "unidentified attempts exist",
        "unknown_page_attempts": "unknown page attempts exist",
        "window_malformed_v2_records": "malformed v2 records exist",
        "legacy_events": "legacy events exist",
        "opaque_paginated_attempts": "opaque pagination attempts exist",
    }
    for field, message in health_fields.items():
        _flag(reasons, meta[field] > 0, f"{window.label}: {message}")
    _flag(
        reasons,
        meta["attempted_requests"] == 0,
        f"{window.label}: no transport attempts were observed",
    )
    _flag(
        reasons,
        window.totals["other_attempts"] > 0,
        f"{window.label}: unclassified transport attempts exist",
    )
    _flag(
        reasons,
        population["repository_count"] == 0,
        f"{window.label}: repository population is empty",
    )
    _flag(
        reasons,
        population["pulse_cycles"] == 0,
        f"{window.label}: no Pulse cycles were observed",
    )
    return reasons


def _pct_change(
    baseline: float | int | None, canary: float | int | None
) -> float | None:
    if baseline is None or canary is None:
        return None
    if baseline == 0:
        return 0.0 if canary == 0 else None
    return round(((canary - baseline) / baseline) * 100, 6)


def _growth_exceeds(
    baseline: float | int | None,
    canary: float | int | None,
    maximum_pct: float,
) -> bool:
    if baseline is None or canary is None:
        return False
    if baseline == 0:
        return canary > 0
    return ((canary - baseline) / baseline) * 100 > maximum_pct


def _empty_comparability() -> dict[str, Any]:
    return {
        "duration_ratio": None,
        "pulse_cycle_rate_change_pct": None,
        "population_rate_change_pct": {
            "unchanged_cycles": None,
            "actionable_changes": None,
            "unique_actionable_head_shas": None,
        },
        "repository_population_match": False,
        "workload_rates_equivalent": False,
        "windows_do_not_overlap": False,
    }


def _comparability(
    baseline: Window, canary: Window, thresholds: Thresholds
) -> tuple[dict[str, Any], list[str]]:
    base_meta = baseline.report["_meta"]
    canary_meta = canary.report["_meta"]
    base_population = baseline.evidence["population"]
    canary_population = canary.evidence["population"]
    durations = (
        base_meta["effective_window_seconds"],
        canary_meta["effective_window_seconds"],
    )
    duration_ratio = max(durations) / min(durations)
    base_cycle_rate = base_population["pulse_cycles"] / (durations[0] / 3600)
    canary_cycle_rate = canary_population["pulse_cycles"] / (durations[1] / 3600)
    cycle_rate_change_pct = _pct_change(base_cycle_rate, canary_cycle_rate)
    workload_fields = (
        "unchanged_cycles",
        "actionable_changes",
        "unique_actionable_head_shas",
    )
    population_rate_changes = {
        field: _pct_change(
            base_population[field] / (durations[0] / 3600),
            canary_population[field] / (durations[1] / 3600),
        )
        for field in workload_fields
    }
    reasons: list[str] = []
    _flag(
        reasons,
        base_population["repository_count"]
        != canary_population["repository_count"],
        "repository population counts differ",
    )
    _flag(
        reasons,
        base_population["repository_set_sha256"]
        != canary_population["repository_set_sha256"],
        "repository population fingerprints differ",
    )
    _flag(
        reasons,
        duration_ratio > thresholds.max_window_ratio,
        "effective retained windows are materially unequal",
    )
    _flag(
        reasons,
        canary_meta["first_retained_ts"] <= base_meta["last_retained_ts"],
        "baseline and canary retained windows overlap",
    )
    _flag(
        reasons,
        canary_meta["first_retained_ts"] < thresholds.canary_not_before,
        "canary begins before the required rollout boundary",
    )
    cycle_rate_differs = (
        cycle_rate_change_pct is None
        or abs(cycle_rate_change_pct) > thresholds.max_cycle_rate_change_pct
    )
    _flag(
        reasons,
        cycle_rate_differs,
        "Pulse cycle rates are materially non-equivalent",
    )
    for field, change_pct in population_rate_changes.items():
        rate_differs = (
            change_pct is None
            or abs(change_pct) > thresholds.max_cycle_rate_change_pct
        )
        _flag(
            reasons,
            rate_differs,
            f"{field} rates are materially non-equivalent",
        )
    distribution_samples = (
        ("latency", "completed_action_samples", "completed-action latency"),
        ("webhook", "lag_samples", "webhook-lag latency"),
    )
    for group_name, sample_field, label in distribution_samples:
        baseline_samples = baseline.evidence[group_name][sample_field]
        canary_samples = canary.evidence[group_name][sample_field]
        baseline_has_samples = baseline_samples is not None and baseline_samples > 0
        canary_has_samples = canary_samples is not None and canary_samples > 0
        _flag(
            reasons,
            baseline_has_samples != canary_has_samples,
            f"{label} sample availability differs",
        )
    details = {
        "duration_ratio": round(duration_ratio, 6),
        "pulse_cycle_rate_change_pct": cycle_rate_change_pct,
        "population_rate_change_pct": population_rate_changes,
        "repository_population_match": not any(
            "repository population" in reason for reason in reasons
        ),
        "workload_rates_equivalent": not any(
            "rates are materially non-equivalent" in reason for reason in reasons
        ),
        "windows_do_not_overlap": (
            canary_meta["first_retained_ts"] > base_meta["last_retained_ts"]
        ),
    }
    return details, reasons


def _transport_regression_reasons(
    baseline: Window, canary: Window, thresholds: Thresholds
) -> list[str]:
    reasons: list[str] = []
    normalisations = (
        ("per_repo_hour", "repository-hour"),
        ("per_pulse_cycle", "Pulse cycle"),
    )
    for denominator, label in normalisations:
        base_rate = baseline.normalized[denominator]
        canary_rate = canary.normalized[denominator]
        attempt_change = _pct_change(
            base_rate["attempted_requests"], canary_rate["attempted_requests"]
        )
        attempt_reduction = -float(attempt_change or 0)
        _flag(
            reasons,
            attempt_reduction < thresholds.min_attempt_reduction_pct,
            f"attempt reduction per {label} is below the required minimum",
        )
        graphql_regressed = _growth_exceeds(
            float(base_rate["graphql_points"]),
            float(canary_rate["graphql_points"]),
            thresholds.max_graphql_point_increase_pct,
        )
        _flag(
            reasons,
            graphql_regressed,
            f"GraphQL points per {label} regressed",
        )
    base_error_rate = (
        baseline.totals["api_errors"]
        / baseline.totals["attempted_requests"]
    )
    canary_error_rate = (
        canary.totals["api_errors"] / canary.totals["attempted_requests"]
    )
    _flag(
        reasons,
        (canary_error_rate - base_error_rate) * 100
        > thresholds.max_error_rate_increase_points,
        "API error rate regressed",
    )
    return reasons


def _latency_regression_reasons(
    baseline: Window, canary: Window, thresholds: Thresholds
) -> list[str]:
    reasons: list[str] = []
    for field in ("p95_ms", "completed_action_p95_ms"):
        regressed = _growth_exceeds(
            baseline.evidence["latency"][field],
            canary.evidence["latency"][field],
            thresholds.max_latency_increase_pct,
        )
        _flag(reasons, regressed, f"{field} regressed")
    burst_regressed = _growth_exceeds(
        baseline.evidence["latency"]["peak_attempts_per_minute"],
        canary.evidence["latency"]["peak_attempts_per_minute"],
        thresholds.max_burst_increase_pct,
    )
    _flag(
        reasons, burst_regressed, "peak short-window API burst regressed"
    )
    webhook_lag_regressed = _growth_exceeds(
        baseline.evidence["webhook"]["lag_p95_ms"],
        canary.evidence["webhook"]["lag_p95_ms"],
        thresholds.max_latency_increase_pct,
    )
    _flag(
        reasons, webhook_lag_regressed, "webhook invalidation lag regressed"
    )
    return reasons


def _budget_regression_reasons(canary: Window) -> list[str]:
    reasons: list[str] = []
    violation_fields = (
        ("guardrails", "stale_positive_decisions"),
        ("guardrails", "dispatch_dependency_violations"),
        ("guardrails", "required_check_merge_preflight_mismatches"),
        ("path_budgets", "fingerprint_verification_list_calls"),
        ("path_budgets", "fresh_empty_live_fallbacks"),
        ("single_flight", "duplicate_leaders"),
        ("webhook", "duplicate_actions"),
        ("webhook", "missed_recoveries"),
    )
    for group, field in violation_fields:
        _flag(
            reasons,
            canary.evidence[group][field] > 0,
            f"canary {group}.{field} is non-zero",
        )
    check_fetches = canary.evidence["path_budgets"][
        "cycle_scoped_aggregate_check_fetches"
    ]
    unique_heads = canary.evidence["path_budgets"][
        "unique_cycle_scoped_actionable_heads"
    ]
    _flag(
        reasons,
        check_fetches > unique_heads,
        "cycle-scoped aggregate check fetches exceed cycle-scoped actionable heads",
    )
    return reasons


def _regression_reasons(
    baseline: Window, canary: Window, thresholds: Thresholds
) -> list[str]:
    return (
        _transport_regression_reasons(baseline, canary, thresholds)
        + _latency_regression_reasons(baseline, canary, thresholds)
        + _budget_regression_reasons(canary)
    )


def _window_projection(window: Window) -> dict[str, Any]:
    meta = window.report["_meta"]
    return {
        "label": window.label,
        "transport_sha256": window.transport_sha256,
        "evidence_sha256": window.evidence_sha256,
        "first_retained_ts": meta["first_retained_ts"],
        "last_retained_ts": meta["last_retained_ts"],
        "effective_window_seconds": meta["effective_window_seconds"],
        "population": window.evidence["population"],
        "transport": window.totals,
        "normalized": window.normalized,
        **{group: window.evidence[group] for group in EVIDENCE_GROUPS},
    }


def _deltas(baseline: Window, canary: Window) -> dict[str, Any]:
    base_repo_hour = baseline.normalized["per_repo_hour"]
    canary_repo_hour = canary.normalized["per_repo_hour"]
    repo_hour_change = {
        metric: _pct_change(base_repo_hour[metric], canary_repo_hour[metric])
        for metric in TRANSPORT_METRICS
    }
    base_cycle = baseline.normalized["per_pulse_cycle"]
    canary_cycle = canary.normalized["per_pulse_cycle"]
    cycle_change = {
        metric: _pct_change(base_cycle[metric], canary_cycle[metric])
        for metric in TRANSPORT_METRICS
    }
    return {
        "per_repo_hour_change_pct": repo_hour_change,
        "per_pulse_cycle_change_pct": cycle_change,
        "attempt_reduction_pct": {
            "per_repo_hour": _reduction(repo_hour_change["attempted_requests"]),
            "per_pulse_cycle": _reduction(cycle_change["attempted_requests"]),
        },
        "p95_latency_change_pct": _pct_change(
            baseline.evidence["latency"]["p95_ms"],
            canary.evidence["latency"]["p95_ms"],
        ),
        "completed_action_latency_change_pct": _pct_change(
            baseline.evidence["latency"]["completed_action_p95_ms"],
            canary.evidence["latency"]["completed_action_p95_ms"],
        ),
        "peak_burst_change_pct": _pct_change(
            baseline.evidence["latency"]["peak_attempts_per_minute"],
            canary.evidence["latency"]["peak_attempts_per_minute"],
        ),
        "webhook_lag_p95_change_pct": _pct_change(
            baseline.evidence["webhook"]["lag_p95_ms"],
            canary.evidence["webhook"]["lag_p95_ms"],
        ),
    }


def _reduction(change: float | None) -> float | None:
    return None if change is None else round(-change, 6)


def build_result(
    baseline: Window, canary: Window, thresholds: Thresholds
) -> dict[str, Any]:
    reasons = _window_inconclusive_reasons(
        baseline
    ) + _window_inconclusive_reasons(canary)
    comparability = _empty_comparability()
    if not reasons:
        comparability, comparability_reasons = _comparability(
            baseline, canary, thresholds
        )
        reasons.extend(comparability_reasons)
    status = STATUS_INCONCLUSIVE
    if not reasons:
        reasons = _regression_reasons(baseline, canary, thresholds)
        status = STATUS_REGRESSION if reasons else STATUS_OK
    return {
        "schema": BENCHMARK_SCHEMA,
        "status": status,
        "thresholds": asdict(thresholds),
        "comparability": comparability,
        "windows": {
            "baseline": _window_projection(baseline),
            "canary": _window_projection(canary),
        },
        "deltas": _deltas(baseline, canary),
        "reasons": reasons,
    }


def _fmt(value: Any) -> str:
    if value is None:
        return "unknown"
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)


def _fmt_metric(metric: str, value: Any, values: dict[str, Any]) -> str:
    sample_fields = {
        "completed_action_p95_ms": "completed_action_samples",
        "lag_p50_ms": "lag_samples",
        "lag_p95_ms": "lag_samples",
    }
    sample_field = sample_fields.get(metric)
    if value is None and sample_field is not None and values.get(sample_field) == 0:
        return "not applicable"
    return _fmt(value)


def _utc(timestamp: int) -> str:
    return datetime.fromtimestamp(
        timestamp, tz=timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")


def _metric_table(
    lines: list[str],
    title: str,
    baseline: dict[str, Any],
    canary: dict[str, Any],
) -> None:
    lines.extend(
        (
            f"### {title}",
            "",
            "| Metric | Baseline | Canary |",
            "|---|---:|---:|",
        )
    )
    for metric in baseline:
        lines.append(
            f"| `{metric}` | {_fmt_metric(metric, baseline[metric], baseline)} | "
            f"{_fmt_metric(metric, canary[metric], canary)} |"
        )
    lines.append("")


def _window_table(lines: list[str], result: dict[str, Any]) -> None:
    lines.extend(
        (
            "## Retained windows",
            "",
            "| Window | Label | First attempt | Last attempt | "
            "Effective seconds | Repositories | Pulse cycles |",
            "|---|---|---|---|---:|---:|---:|",
        )
    )
    for name in ("baseline", "canary"):
        window = result["windows"][name]
        label = window["label"].replace("|", "\\|")
        lines.append(
            f"| {name.title()} | {label} | "
            f"{_utc(window['first_retained_ts'])} | "
            f"{_utc(window['last_retained_ts'])} | "
            f"{window['effective_window_seconds']} | "
            f"{_fmt(window['population']['repository_count'])} | "
            f"{_fmt(window['population']['pulse_cycles'])} |"
        )
    lines.append("")


def render_markdown(result: dict[str, Any]) -> str:
    baseline = result["windows"]["baseline"]
    canary = result["windows"]["canary"]
    lines = [
        "# GitHub API Efficiency Benchmark",
        "",
        f"**Status:** `{result['status']}`",
        "",
    ]
    _window_table(lines, result)
    lines.extend(("## Transport totals", ""))
    _metric_table(
        lines, "Absolute", baseline["transport"], canary["transport"]
    )
    lines.extend(("## Normalized transport", ""))
    for denominator, title in _DENOMINATOR_LABELS.items():
        _metric_table(
            lines,
            title,
            baseline["normalized"][denominator],
            canary["normalized"][denominator],
        )
    lines.extend(("## Outcomes and guardrails", ""))
    groups = (
        "latency",
        "cache",
        "single_flight",
        "webhook",
        "guardrails",
        "path_budgets",
    )
    for group in groups:
        _metric_table(
            lines,
            group.replace("_", " ").title(),
            baseline[group],
            canary[group],
        )
    lines.extend(("## Decision", ""))
    if result["reasons"]:
        lines.extend(f"- {reason}" for reason in result["reasons"])
    else:
        lines.append(
            "- Comparable evidence meets the savings, freshness, "
            "correctness, latency, burst, and path-budget thresholds."
        )
    lines.append("")
    return "\n".join(lines)
