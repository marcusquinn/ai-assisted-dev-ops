#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validated input model for the GitHub API efficiency benchmark."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any

from github_api_efficiency_metrics import (
    build_transport_metrics,
    counter_relationship_error,
)


EVIDENCE_SCHEMA = "aidevops-github-api-efficiency-evidence/v3"
TRANSPORT_SCHEMA_VERSION = 2
_SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
_MAX_SAFE_INTEGER = 9_007_199_254_740_991
_ALLOWED_PATHS = frozenset(
    ("graphql", "rest", "search-graphql", "search-rest", "other", "unknown")
)
_RECONCILED_PATH_METRICS = (
    "attempted_requests",
    "known_quota_cost",
    "unknown_quota_cost_attempts",
)

REPORT_COUNTERS = (
    "attempted_requests",
    "retries",
    "pages",
    "additional_pages",
    "successful_attempts",
    "failed_attempts",
    "elapsed_ms",
    "unknown_elapsed_attempts",
    "known_quota_cost",
    "unknown_quota_cost_attempts",
    "duplicate_attempt_ids",
    "unidentified_attempts",
    "unknown_page_attempts",
    "window_malformed_v2_records",
    "legacy_events",
    "opaque_paginated_attempts",
)
POPULATION_FIELDS = (
    "repository_count",
    "pulse_cycles",
    "unchanged_cycles",
    "actionable_changes",
    "unique_actionable_head_shas",
)
EVIDENCE_GROUPS = {
    "latency": (
        "p50_ms",
        "p95_ms",
        "peak_attempts_per_minute",
        "completed_action_samples",
        "completed_action_p95_ms",
    ),
    "cache": ("fresh_hits", "fresh_empty_hits", "misses", "stale", "invalidated"),
    "single_flight": ("leaders", "waits", "takeovers", "duplicate_leaders"),
    "webhook": (
        "invalidations",
        "lag_samples",
        "lag_p50_ms",
        "lag_p95_ms",
        "duplicate_actions",
        "missed_recoveries",
    ),
    "guardrails": (
        "stale_snapshot_detections",
        "forced_live_refreshes",
        "stale_positive_decisions",
        "dispatch_dependency_violations",
        "required_check_merge_preflight_mismatches",
    ),
    "path_budgets": (
        "fingerprint_verification_list_calls",
        "fresh_empty_live_fallbacks",
        "aggregate_check_fetches",
        "cycle_scoped_aggregate_check_fetches",
        "unique_cycle_scoped_actionable_heads",
    ),
}
DISTRIBUTION_SAMPLE_FIELDS = {
    ("latency", "completed_action_p95_ms"): "completed_action_samples",
    ("webhook", "lag_p50_ms"): "lag_samples",
    ("webhook", "lag_p95_ms"): "lag_samples",
}
_MEASURED_EVIDENCE_FIELDS = frozenset(
    (
        ("latency", "p50_ms"),
        ("latency", "p95_ms"),
        ("latency", "completed_action_p95_ms"),
        ("webhook", "lag_p50_ms"),
        ("webhook", "lag_p95_ms"),
    )
)


class BenchmarkInputError(ValueError):
    """Raised when a report or evidence sidecar violates its schema."""


@dataclass(frozen=True)
class Window:
    label: str
    report: dict[str, Any]
    evidence: dict[str, Any]
    transport_sha256: str
    evidence_sha256: str
    totals: dict[str, int]
    normalized: dict[str, dict[str, float | None]]


def _load_object(path: Path, role: str) -> tuple[dict[str, Any], str]:
    if path.is_symlink() or not path.is_file():
        raise BenchmarkInputError(
            f"{role} must be a regular, non-symlink file"
        )
    try:
        raw = path.read_bytes()
        payload = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BenchmarkInputError(f"{role} is not readable JSON") from exc
    if not isinstance(payload, dict):
        raise BenchmarkInputError(f"{role} root must be an object")
    return payload, hashlib.sha256(raw).hexdigest()


def _object(payload: dict[str, Any], key: str, context: str) -> dict[str, Any]:
    value = payload.get(key)
    if not isinstance(value, dict):
        raise BenchmarkInputError(f"{context}.{key} must be an object")
    return value


def _number(
    value: Any,
    context: str,
    *,
    integer: bool = True,
    nullable: bool = False,
) -> int | float | None:
    if value is None:
        if nullable:
            return None
        raise BenchmarkInputError(f"{context} must be a non-negative number")
    expected = (int,) if integer else (int, float)
    if type(value) not in expected:
        raise BenchmarkInputError(f"{context} must be a non-negative number")
    if isinstance(value, float):
        if not math.isfinite(value):
            raise BenchmarkInputError(
                f"{context} must be a non-negative safe JSON number"
            )
    if not 0 <= value <= _MAX_SAFE_INTEGER:
        raise BenchmarkInputError(
            f"{context} must be a non-negative safe JSON number"
        )
    return value


def _validate_retained_window(meta: dict[str, Any]) -> None:
    first = _number(meta.get("first_retained_ts"), "transport._meta.first_retained_ts")
    last = _number(meta.get("last_retained_ts"), "transport._meta.last_retained_ts")
    duration = _number(
        meta.get("effective_window_seconds"),
        "transport._meta.effective_window_seconds",
    )
    if first <= 0 or last <= first or duration != last - first:
        raise BenchmarkInputError(
            "transport retained timestamps and effective duration are inconsistent"
        )
    if not isinstance(meta.get("attempts_exact"), bool):
        raise BenchmarkInputError("transport._meta.attempts_exact must be boolean")


def _validate_path_metrics(by_path: dict[str, Any]) -> dict[str, int]:
    totals = {metric: 0 for metric in _RECONCILED_PATH_METRICS}
    for path_name, path_metrics in by_path.items():
        if path_name not in _ALLOWED_PATHS:
            raise BenchmarkInputError("transport.by_path contains an unsupported path")
        if not isinstance(path_metrics, dict):
            raise BenchmarkInputError("transport.by_path entries must be objects")
        for metric in _RECONCILED_PATH_METRICS:
            value = _number(
                path_metrics.get(metric),
                f"transport.by_path.{path_name}.{metric}",
            )
            totals[metric] += int(value)
    return totals


def _validate_report(payload: dict[str, Any]) -> None:
    meta = _object(payload, "_meta", "transport")
    schema = _number(meta.get("schema_version"), "transport._meta.schema_version")
    if schema != TRANSPORT_SCHEMA_VERSION:
        raise BenchmarkInputError("transport report schema_version must be 2")
    for field in REPORT_COUNTERS:
        _number(meta.get(field), f"transport._meta.{field}")
    _validate_retained_window(meta)
    counter_error = counter_relationship_error(meta)
    if counter_error:
        raise BenchmarkInputError(counter_error)
    by_path = _object(payload, "by_path", "transport")
    path_totals = _validate_path_metrics(by_path)
    for metric, path_total in path_totals.items():
        if path_total != meta[metric]:
            raise BenchmarkInputError(
                f"transport {metric} does not reconcile by path"
            )


def _validate_evidence_relationships(payload: dict[str, Any]) -> None:
    population = payload["population"]
    path_budgets = payload["path_budgets"]
    constraints = (
        (
            population["unchanged_cycles"],
            population["pulse_cycles"],
            "evidence unchanged cycles exceed Pulse cycles",
        ),
        (
            population["unique_actionable_head_shas"],
            population["actionable_changes"],
            "evidence unique actionable head SHAs exceed actionable changes",
        ),
        (
            path_budgets["cycle_scoped_aggregate_check_fetches"],
            path_budgets["aggregate_check_fetches"],
            "evidence cycle-scoped aggregate check fetches exceed total fetches",
        ),
        (
            path_budgets["unique_cycle_scoped_actionable_heads"],
            population["actionable_changes"],
            "evidence cycle-scoped actionable heads exceed actionable observations",
        ),
    )
    for left, right, message in constraints:
        if None not in (left, right) and left > right:
            raise BenchmarkInputError(message)


def _validate_population(payload: dict[str, Any]) -> None:
    population = _object(payload, "population", "evidence")
    for field in POPULATION_FIELDS:
        if field not in population:
            raise BenchmarkInputError(f"evidence.population.{field} is required")
        _number(
            population[field],
            f"evidence.population.{field}",
            nullable=True,
        )
    if "repository_set_sha256" not in population:
        raise BenchmarkInputError(
            "evidence.population.repository_set_sha256 is required"
        )
    population_hash = population["repository_set_sha256"]
    if population_hash is None:
        return
    if not isinstance(population_hash, str):
        raise BenchmarkInputError(
            "evidence.population.repository_set_sha256 must be null or lowercase SHA-256"
        )
    if not _SHA256_RE.fullmatch(population_hash):
        raise BenchmarkInputError(
            "evidence.population.repository_set_sha256 must be null or lowercase SHA-256"
        )


def _validate_evidence_groups(payload: dict[str, Any]) -> None:
    for group_name, fields in EVIDENCE_GROUPS.items():
        group = _object(payload, group_name, "evidence")
        for field in fields:
            if field not in group:
                raise BenchmarkInputError(
                    f"evidence.{group_name}.{field} is required"
                )
            _number(
                group[field],
                f"evidence.{group_name}.{field}",
                integer=(group_name, field) not in _MEASURED_EVIDENCE_FIELDS,
                nullable=True,
            )


def _validate_distribution_relationships(payload: dict[str, Any]) -> None:
    for (group_name, percentile_field), sample_field in (
        DISTRIBUTION_SAMPLE_FIELDS.items()
    ):
        samples = payload[group_name][sample_field]
        percentile = payload[group_name][percentile_field]
        context = f"evidence.{group_name}.{percentile_field}"
        if samples is None:
            if percentile is not None:
                raise BenchmarkInputError(f"{context} requires a sample count")
            continue
        if samples == 0 and percentile is not None:
            raise BenchmarkInputError(
                f"{context} must be null when its sample count is zero"
            )
        if samples > 0 and percentile is None:
            raise BenchmarkInputError(
                f"{context} is required when its sample count is positive"
            )


def _validate_evidence(
    payload: dict[str, Any], transport_sha256: str
) -> None:
    if payload.get("schema") != EVIDENCE_SCHEMA:
        raise BenchmarkInputError(f"evidence schema must be {EVIDENCE_SCHEMA}")
    if payload.get("transport_sha256") != transport_sha256:
        raise BenchmarkInputError(
            "evidence transport_sha256 does not match the transport report"
        )
    if not isinstance(payload.get("complete"), bool):
        raise BenchmarkInputError("evidence.complete must be boolean")
    _validate_population(payload)
    _validate_evidence_groups(payload)
    _validate_distribution_relationships(payload)
    _validate_evidence_relationships(payload)


def load_transport_report(
    path: Path, role: str = "transport report"
) -> tuple[dict[str, Any], str]:
    """Load and validate one immutable schema-v2 transport report."""
    report, transport_sha256 = _load_object(path, role)
    _validate_report(report)
    return report, transport_sha256


def build_window(
    label: str, report_path: Path, evidence_path: Path
) -> Window:
    report, transport_sha256 = load_transport_report(
        report_path, f"{label} transport report"
    )
    evidence, evidence_sha256 = _load_object(
        evidence_path, f"{label} evidence"
    )
    _validate_evidence(evidence, transport_sha256)
    totals, normalized = build_transport_metrics(report, evidence)
    return Window(
        label,
        report,
        evidence,
        transport_sha256,
        evidence_sha256,
        totals,
        normalized,
    )
