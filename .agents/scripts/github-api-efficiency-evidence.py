#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Build a digest-bound GitHub API efficiency evidence sidecar."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys
from typing import Any, Callable

from github_api_efficiency_inputs import (
    BenchmarkInputError,
    DISTRIBUTION_SAMPLE_FIELDS,
    EVIDENCE_GROUPS,
    EVIDENCE_SCHEMA,
    POPULATION_FIELDS,
    load_transport_report,
)
from github_api_efficiency_events import (
    EvidenceBuildError,
    _event_map,
    _non_negative_int,
)
from github_api_efficiency_io import AtomicWriteError, atomic_write_text


CONTRACT_VERSION = "2"
_SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
_COVERAGE_GROUPS = tuple(("population", *EVIDENCE_GROUPS.keys()))



def _parsed_values(
    events: dict[str, Counter[str]], name: str, parser: Callable[[str], Any]
) -> list[Any]:
    try:
        return [parser(value) for value in events.get(name, {})]
    except (TypeError, ValueError) as exc:
        raise EvidenceBuildError(f"evidence {name} contains an invalid value") from exc


def _snapshot(
    events: dict[str, Counter[str]], name: str, parser: Callable[[str], Any]
) -> Any | None:
    values = _parsed_values(events, name, parser)
    if not values:
        return None
    if len(set(values)) != 1:
        raise EvidenceBuildError(f"evidence {name} contains conflicting snapshots")
    return values[0]


def _extreme_int(
    events: dict[str, Counter[str]], name: str, selector: Callable[[list[int]], int]
) -> int | None:
    values = _parsed_values(events, name, int)
    if any(value < 0 for value in values):
        raise EvidenceBuildError(f"evidence {name} must be non-negative")
    return selector(values) if values else None


def _sum_event(events: dict[str, Counter[str]], name: str) -> int:
    total = 0
    for value, count in events.get(name, {}).items():
        try:
            parsed = int(value)
        except ValueError as exc:
            raise EvidenceBuildError(
                f"evidence {name} contains an invalid integer"
            ) from exc
        number = _non_negative_int(parsed, f"evidence {name}")
        total += number * count
    return total


def _unique_actionable_heads(
    events: dict[str, Counter[str]], actionable: int
) -> int | None:
    failures = _sum_event(events, "population.actionable_head_hash_failures")
    if failures:
        return None
    tokens = events.get("population.actionable_head_token", {})
    legacy = events.get("population.unique_actionable_head_shas", {})
    if tokens and legacy:
        raise EvidenceBuildError("actionable head evidence mixes tokens and legacy counts")
    if tokens:
        if any(not _SHA256_RE.fullmatch(token) for token in tokens):
            raise EvidenceBuildError("actionable head tokens must be lowercase SHA-256")
        unique = len(tokens)
    elif legacy:
        unique = _sum_event(events, "population.unique_actionable_head_shas")
    elif actionable:
        return None
    else:
        unique = 0
    if unique > actionable:
        raise EvidenceBuildError("unique actionable heads exceed actionable changes")
    return unique


def _unique_cycle_scoped_actionable_heads(
    events: dict[str, Counter[str]], cycle_scoped_fetches: int
) -> int | None:
    failures = _sum_event(
        events, "path_budgets.cycle_scoped_actionable_head_hash_failures"
    )
    if failures:
        return None
    tokens = events.get("path_budgets.cycle_scoped_actionable_head_token", {})
    if any(not _SHA256_RE.fullmatch(token) for token in tokens):
        raise EvidenceBuildError(
            "cycle-scoped actionable head tokens must be lowercase SHA-256"
        )
    if tokens:
        return len(tokens)
    return None if cycle_scoped_fetches else 0


def _sample_percentile(
    events: dict[str, Counter[str]], name: str, percent: int
) -> int | None:
    samples = events.get(name, {})
    total = sum(samples.values())
    if total < 1:
        return None
    target = (total * percent + 99) // 100
    cumulative = 0
    for value in sorted(samples, key=int):
        number = _non_negative_int(int(value), f"evidence {name}")
        cumulative += samples[value]
        if cumulative >= target:
            return number
    raise EvidenceBuildError(f"evidence {name} percentile could not be computed")


def _sample_count(events: dict[str, Counter[str]], name: str) -> int:
    return sum(events.get(name, {}).values())


def _window_is_bounded(
    contract: Any, start: int | None, end: int | None, first: int, last: int
) -> bool:
    if contract != CONTRACT_VERSION or start is None or end is None:
        return False
    if start > first:
        return False
    return end >= last


def _coverage(
    events: dict[str, Counter[str]], meta: dict[str, Any]
) -> tuple[dict[str, bool], int | None, int | None]:
    start = _extreme_int(events, "coverage-start", max)
    end = _extreme_int(events, "coverage-end", max)
    contract_values = _parsed_values(events, "contract", str)
    contract = CONTRACT_VERSION if CONTRACT_VERSION in contract_values else None
    first = _non_negative_int(meta.get("first_retained_ts"), "first retained timestamp")
    last = _non_negative_int(meta.get("last_retained_ts"), "last retained timestamp")
    bounded = _window_is_bounded(contract, start, end, first, last)
    groups = {
        group: bounded
        and CONTRACT_VERSION
        in _parsed_values(events, f"coverage.{group}", str)
        for group in _COVERAGE_GROUPS
    }
    if _non_negative_int(
        meta.get("unknown_elapsed_attempts"), "unknown elapsed attempts"
    ):
        groups["latency"] = False
    return groups, start, end


def _covered_count(
    events: dict[str, Counter[str]], name: str, covered: bool
) -> int | None:
    return _sum_event(events, name) if covered else None


def _meta_count(meta: dict[str, Any], name: str, covered: bool) -> int | None:
    if not covered:
        return None
    value = meta.get(name)
    if type(value) is not int or value < 0:
        return None
    return value


def _build_population(
    events: dict[str, Counter[str]], covered: bool
) -> dict[str, int | str | None]:
    if not covered:
        return {**{field: None for field in POPULATION_FIELDS}, "repository_set_sha256": None}
    repository_count = _snapshot(events, "population.repository_count", int)
    repository_hash = _snapshot(events, "population.repository_set_sha256", str)
    if repository_count is not None:
        _non_negative_int(repository_count, "repository count")
    if repository_hash is not None and not _SHA256_RE.fullmatch(repository_hash):
        raise EvidenceBuildError("repository set digest must be lowercase SHA-256")
    actionable = _sum_event(events, "population.actionable_changes")
    return {
        "repository_count": repository_count,
        "pulse_cycles": _sum_event(events, "population.pulse_cycles"),
        "unchanged_cycles": _sum_event(events, "population.unchanged_cycles"),
        "actionable_changes": actionable,
        "unique_actionable_head_shas": _unique_actionable_heads(
            events, actionable
        ),
        "repository_set_sha256": repository_hash,
    }


def _missing_fields(payload: dict[str, Any]) -> list[str]:
    missing: list[str] = []
    population = payload["population"]
    for field in (*POPULATION_FIELDS, "repository_set_sha256"):
        if population[field] is None:
            missing.append(f"population.{field}")
    for group, fields in EVIDENCE_GROUPS.items():
        for field in fields:
            if payload[group][field] is not None:
                continue
            sample_field = DISTRIBUTION_SAMPLE_FIELDS.get((group, field))
            if sample_field is not None and payload[group][sample_field] == 0:
                continue
            missing.append(f"{group}.{field}")
    return missing


def _build_count_group(
    events: dict[str, Counter[str]], group: str, covered: bool
) -> dict[str, int | None]:
    return {
        field: _covered_count(events, f"{group}.{field}", covered)
        for field in EVIDENCE_GROUPS[group]
    }


def _build_path_budgets(
    events: dict[str, Counter[str]], covered: bool
) -> dict[str, int | None]:
    payload = _build_count_group(events, "path_budgets", covered)
    if not covered:
        return payload
    cycle_scoped_fetches = payload["cycle_scoped_aggregate_check_fetches"]
    if cycle_scoped_fetches is None:
        return payload
    payload["unique_cycle_scoped_actionable_heads"] = (
        _unique_cycle_scoped_actionable_heads(events, cycle_scoped_fetches)
    )
    return payload


def _build_latency(
    events: dict[str, Counter[str]], meta: dict[str, Any], covered: bool
) -> dict[str, int | None]:
    return {
        "p50_ms": _meta_count(meta, "request_p50_ms", covered),
        "p95_ms": _meta_count(meta, "request_p95_ms", covered),
        "peak_attempts_per_minute": _meta_count(
            meta, "peak_attempts_per_minute", covered
        ),
        "completed_action_samples": (
            _sample_count(events, "latency.completed_action_ms")
            if covered
            else None
        ),
        "completed_action_p95_ms": (
            _sample_percentile(events, "latency.completed_action_ms", 95)
            if covered
            else None
        ),
    }


def _build_webhook(
    events: dict[str, Counter[str]], covered: bool
) -> dict[str, int | None]:
    return {
        "invalidations": _covered_count(events, "webhook.invalidations", covered),
        "lag_samples": (
            _sample_count(events, "webhook.lag_ms") if covered else None
        ),
        "lag_p50_ms": (
            _sample_percentile(events, "webhook.lag_ms", 50) if covered else None
        ),
        "lag_p95_ms": (
            _sample_percentile(events, "webhook.lag_ms", 95) if covered else None
        ),
        "duplicate_actions": _covered_count(
            events, "webhook.duplicate_actions", covered
        ),
        "missed_recoveries": _covered_count(
            events, "webhook.missed_recoveries", covered
        ),
    }


def build_sidecar(report: dict[str, Any], transport_sha256: str) -> dict[str, Any]:
    meta = report["_meta"]
    events = _event_map(report)
    covered, start, end = _coverage(events, meta)
    payload: dict[str, Any] = {
        "schema": EVIDENCE_SCHEMA,
        "transport_sha256": transport_sha256,
        "complete": False,
        "population": _build_population(events, covered["population"]),
        "latency": _build_latency(events, meta, covered["latency"]),
        "cache": _build_count_group(events, "cache", covered["cache"]),
        "single_flight": _build_count_group(
            events, "single_flight", covered["single_flight"]
        ),
        "webhook": _build_webhook(events, covered["webhook"]),
    }
    payload["guardrails"] = _build_count_group(
        events, "guardrails", covered["guardrails"]
    )
    payload["path_budgets"] = _build_path_budgets(
        events, covered["path_budgets"]
    )
    missing = _missing_fields(payload)
    payload["complete"] = not missing and all(covered.values())
    payload["_meta"] = {
        "contract_version": CONTRACT_VERSION,
        "coverage_start_ts": start,
        "coverage_end_ts": end,
        "coverage_groups": covered,
        "missing_fields": missing,
    }
    return payload


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build",))
    parser.add_argument("--transport-report", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        if args.transport_report.resolve(strict=False) == args.output.resolve(strict=False):
            raise EvidenceBuildError("output must be distinct from the transport report")
        report, transport_sha256 = load_transport_report(args.transport_report)
        payload = build_sidecar(report, transport_sha256)
        content = json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n"
        atomic_write_text(args.output, content)
    except (AtomicWriteError, BenchmarkInputError, EvidenceBuildError) as exc:
        print(f"github-api-efficiency-evidence: {exc}", file=sys.stderr)
        return 2
    status = "complete" if payload["complete"] else "incomplete"
    print(f"evidence sidecar: {status}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
