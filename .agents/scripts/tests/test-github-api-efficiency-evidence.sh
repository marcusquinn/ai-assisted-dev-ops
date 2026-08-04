#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Deterministic coverage for the GitHub API efficiency sidecar producer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
readonly PRODUCER="${SCRIPT_DIR}/../github-api-efficiency-evidence.sh"
readonly TEMP_BASE="${AIDEVOPS_TEMP_DIR:-${HOME:+$HOME/.aidevops/.agent-workspace/tmp}}"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0
LAST_EXIT=0
LAST_OUTPUT=""

cleanup() {
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
        rm -rf "$TEST_ROOT"
    fi
    return 0
}

record_result() {
    local label="$1"
    local passed="$2"
    local detail="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$passed" -eq 0 ]]; then
        printf "PASS: %s\n" "$label"
        return 0
    fi
    printf "FAIL: %s\n" "$label"
    if [[ -n "$detail" ]]; then
        printf "      %s\n" "$detail"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 0
}

assert_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        record_result "$label" 0
        return 0
    fi
    record_result "$label" 1 "expected=${expected}, actual=${actual}"
    return 0
}

assert_jq() {
    local label="$1"
    local filter="$2"
    local file="$3"
    if [[ -f "$file" ]] && jq -e "$filter" "$file" >/dev/null 2>&1; then
        record_result "$label" 0
        return 0
    fi
    record_result "$label" 1 "jq assertion failed: ${filter}"
    return 0
}

assert_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        record_result "$label" 0
        return 0
    fi
    record_result "$label" 1 "missing text: ${needle}"
    return 0
}

assert_missing() {
    local label="$1"
    local file="$2"
    if [[ ! -e "$file" ]]; then
        record_result "$label" 0
        return 0
    fi
    record_result "$label" 1 "unexpected file: ${file}"
    return 0
}

file_sha256() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | cut -d " " -f 1
        return 0
    fi
    openssl dgst -sha256 "$file" | awk "{print \$NF}"
    return 0
}

file_mode() {
    local file="$1"
    stat -f "%Lp" "$file" 2>/dev/null || stat -c "%a" "$file"
    return 0
}

run_build() {
    local report="$1"
    local output="$2"
    set +e
    LAST_OUTPUT=$("$PRODUCER" build --transport-report "$report" --output "$output" 2>&1)
    LAST_EXIT=$?
    set -e
    return 0
}

mkdir -p "$TEMP_BASE"
TEST_ROOT=$(mktemp -d "${TEMP_BASE}/github-api-efficiency-evidence-test.XXXXXX")
trap cleanup EXIT

python3 - "$TEST_ROOT" <<"PY"
import copy
import json
from pathlib import Path
import sys

ROOT = Path(sys.argv[1])
REPOSITORY_SET = "a" * 64


def write_json(path, payload):
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )


def path_metrics(attempts, quota=0, unknown_quota=0):
    return {
        "attempted_requests": attempts,
        "known_quota_cost": quota,
        "unknown_quota_cost_attempts": unknown_quota,
    }


def decision_map(events):
    return {
        f"evidence:{name}:{value}": {"evidence_events": count}
        for name, value, count in events
    }


def transport(events):
    return {
        "_meta": {
            "schema_version": 2,
            "first_retained_ts": 1000,
            "last_retained_ts": 1060,
            "effective_window_seconds": 60,
            "attempted_requests": 3,
            "retries": 0,
            "pages": 3,
            "additional_pages": 0,
            "successful_attempts": 3,
            "failed_attempts": 0,
            "elapsed_ms": 60,
            "unknown_elapsed_attempts": 0,
            "request_p50_ms": 10,
            "request_p95_ms": 30,
            "peak_attempts_per_minute": 2,
            "known_quota_cost": 0,
            "unknown_quota_cost_attempts": 0,
            "duplicate_attempt_ids": 0,
            "unidentified_attempts": 0,
            "unknown_page_attempts": 0,
            "window_malformed_v2_records": 0,
            "legacy_events": 0,
            "opaque_paginated_attempts": 0,
            "attempts_exact": True,
        },
        "by_path": {"rest": path_metrics(3)},
        "by_route_decision": decision_map(events),
    }


EVENTS = [
    ("contract", "2", 1),
    ("coverage-start", "900", 1),
    ("coverage-end", "1100", 1),
    ("coverage.population", "2", 1),
    ("coverage.latency", "2", 1),
    ("coverage.cache", "2", 1),
    ("coverage.single_flight", "2", 1),
    ("coverage.webhook", "2", 1),
    ("coverage.guardrails", "2", 1),
    ("coverage.path_budgets", "2", 1),
    ("population.repository_count", "10", 1),
    ("population.repository_set_sha256", REPOSITORY_SET, 1),
    ("population.pulse_cycles", "4", 1),
    ("population.unchanged_cycles", "3", 1),
    ("population.actionable_changes", "3", 1),
    ("population.actionable_head_token", "b" * 64, 2),
    ("population.actionable_head_token", "c" * 64, 1),
    ("latency.completed_action_ms", "100", 1),
    ("latency.completed_action_ms", "200", 2),
    ("cache.fresh_hits", "3", 1),
    ("cache.fresh_empty_hits", "1", 1),
    ("cache.misses", "2", 1),
    ("cache.stale", "1", 1),
    ("cache.invalidated", "1", 1),
    ("single_flight.leaders", "2", 1),
    ("single_flight.waits", "1", 1),
    ("webhook.invalidations", "2", 1),
    ("webhook.lag_ms", "10", 1),
    ("webhook.lag_ms", "30", 2),
    ("guardrails.stale_snapshot_detections", "1", 1),
    ("guardrails.forced_live_refreshes", "1", 1),
    ("path_budgets.aggregate_check_fetches", "1", 2),
    ("path_budgets.cycle_scoped_aggregate_check_fetches", "1", 2),
    ("path_budgets.cycle_scoped_actionable_head_token", "d" * 64, 1),
    ("path_budgets.cycle_scoped_actionable_head_token", "e" * 64, 2),
]

complete = transport(EVENTS)
write_json(ROOT / "complete-report.json", complete)

empty_distribution_names = {
    "population.unchanged_cycles",
    "population.actionable_changes",
    "population.actionable_head_token",
    "latency.completed_action_ms",
    "webhook.invalidations",
    "webhook.lag_ms",
    "path_budgets.aggregate_check_fetches",
    "path_budgets.cycle_scoped_aggregate_check_fetches",
    "path_budgets.cycle_scoped_actionable_head_token",
}
empty_distribution_events = [
    event for event in EVENTS if event[0] not in empty_distribution_names
]
empty_distribution_events.append(("population.unchanged_cycles", "4", 1))
write_json(
    ROOT / "empty-distributions-report.json",
    transport(empty_distribution_events),
)

mixed_contract_events = EVENTS + [
    ("contract", "1", 1),
    ("coverage-start", "800", 1),
    *[(f"coverage.{group}", "1", 1) for group in (
        "population", "latency", "cache", "single_flight", "webhook",
        "guardrails", "path_budgets",
    )],
]
write_json(ROOT / "mixed-contract-report.json", transport(mixed_contract_events))

incomplete_events = [
    event for event in EVENTS if event[0] != "coverage.webhook"
]
write_json(ROOT / "incomplete-report.json", transport(incomplete_events))

unknown_latency = transport(EVENTS)
unknown_latency["_meta"]["unknown_elapsed_attempts"] = 1
write_json(ROOT / "unknown-latency-report.json", unknown_latency)

head_hash_failure = transport(
    EVENTS + [("population.actionable_head_hash_failures", "1", 1)]
)
write_json(ROOT / "head-hash-failure-report.json", head_hash_failure)

cycle_head_hash_failure = transport(
    EVENTS
    + [("path_budgets.cycle_scoped_actionable_head_hash_failures", "1", 1)]
)
write_json(ROOT / "cycle-head-hash-failure-report.json", cycle_head_hash_failure)

bad_integer = transport(EVENTS)
bad_integer["by_route_decision"]["evidence:cache.fresh_hits:bad"] = {
    "evidence_events": 1
}
write_json(ROOT / "bad-integer-report.json", bad_integer)

conflicting = transport(EVENTS)
conflicting["by_route_decision"]["evidence:population.repository_count:11"] = {
    "evidence_events": 1
}
write_json(ROOT / "conflicting-report.json", conflicting)

untyped = copy.deepcopy(complete)
untyped["by_route_decision"]["evidence:cache.fresh_hits:3"][
    "evidence_events"
] = 0
write_json(ROOT / "untyped-report.json", untyped)
PY

test_hash_failure_evidence() {
    local head_output="${TEST_ROOT}/head-hash-failure-evidence.json"
    local cycle_output="${TEST_ROOT}/cycle-head-hash-failure-evidence.json"

    run_build "${TEST_ROOT}/head-hash-failure-report.json" "$head_output"
    assert_eq "actionable head hash failure exits zero" "0" "$LAST_EXIT"
    assert_contains "actionable head hash failure reports incomplete" "evidence sidecar: incomplete" "$LAST_OUTPUT"
    assert_jq "actionable head hash failure stays unknown" '.complete == false and .population.actionable_changes == 3 and .population.unique_actionable_head_shas == null and (._meta.missing_fields | index("population.unique_actionable_head_shas")) != null' "$head_output"

    run_build "${TEST_ROOT}/cycle-head-hash-failure-report.json" "$cycle_output"
    assert_eq "cycle-scoped head hash failure exits zero" "0" "$LAST_EXIT"
    assert_contains "cycle-scoped head hash failure reports incomplete" "evidence sidecar: incomplete" "$LAST_OUTPUT"
    assert_jq "cycle-scoped head hash failure stays unknown" '.complete == false and .path_budgets.cycle_scoped_aggregate_check_fetches == 2 and .path_budgets.unique_cycle_scoped_actionable_heads == null and (._meta.missing_fields | index("path_budgets.unique_cycle_scoped_actionable_heads")) != null' "$cycle_output"
    return 0
}

test_contract_migration_evidence() {
    local output="${TEST_ROOT}/mixed-contract-evidence.json"
    run_build "${TEST_ROOT}/mixed-contract-report.json" "$output"
    assert_eq "mixed historical contract exits zero" "0" "$LAST_EXIT"
    assert_contains "current contract survives historical markers" "evidence sidecar: complete" "$LAST_OUTPUT"
    assert_jq "latest activation bounds migrated evidence" '._meta.contract_version == "2" and ._meta.coverage_start_ts == 900 and .complete == true' "$output"
    return 0
}

finish_test_run() {
    printf "\nTests run: %d\n" "$TESTS_RUN"
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        printf "Tests failed: %d\n" "$TESTS_FAILED"
        return 1
    fi
    printf "All tests passed\n"
    return 0
}

main() {
    local complete_report="${TEST_ROOT}/complete-report.json"
    local complete_output="${TEST_ROOT}/complete-evidence.json"
    local first_output="${TEST_ROOT}/complete-first.json"
    local expected_digest=""
    local actual_digest=""
    local schema=""
    local repository_set=""
    local mode=""

    run_build "$complete_report" "$complete_output"
    assert_eq "complete evidence exits zero" "0" "$LAST_EXIT"
    assert_contains "complete evidence reports status" "evidence sidecar: complete" "$LAST_OUTPUT"
    assert_jq "complete evidence populates every group" ".complete and .population.repository_count == 10 and .population.pulse_cycles == 4 and .population.unchanged_cycles == 3 and .population.actionable_changes == 3 and .population.unique_actionable_head_shas == 2 and .latency.p50_ms == 10 and .latency.p95_ms == 30 and .latency.peak_attempts_per_minute == 2 and .latency.completed_action_samples == 3 and .latency.completed_action_p95_ms == 200 and .cache.fresh_hits == 3 and .cache.fresh_empty_hits == 1 and .cache.misses == 2 and .cache.stale == 1 and .cache.invalidated == 1 and .single_flight.leaders == 2 and .single_flight.waits == 1 and .single_flight.takeovers == 0 and .single_flight.duplicate_leaders == 0 and .webhook.invalidations == 2 and .webhook.lag_samples == 3 and .webhook.lag_p50_ms == 30 and .webhook.lag_p95_ms == 30 and .webhook.duplicate_actions == 0 and .webhook.missed_recoveries == 0 and .guardrails.stale_snapshot_detections == 1 and .guardrails.forced_live_refreshes == 1 and .guardrails.stale_positive_decisions == 0 and .guardrails.dispatch_dependency_violations == 0 and .guardrails.required_check_merge_preflight_mismatches == 0 and .path_budgets.aggregate_check_fetches == 2 and .path_budgets.cycle_scoped_aggregate_check_fetches == 2 and .path_budgets.unique_cycle_scoped_actionable_heads == 2 and (._meta.missing_fields | length) == 0" "$complete_output"
    schema=$(jq -r .schema "$complete_output")
    assert_eq "sidecar schema is versioned" "aidevops-github-api-efficiency-evidence/v3" "$schema"
    repository_set=$(jq -r .population.repository_set_sha256 "$complete_output")
    assert_eq "repository population stays digest-only" "$(printf "a%.0s" {1..64})" "$repository_set"
    expected_digest=$(file_sha256 "$complete_report")
    actual_digest=$(jq -r .transport_sha256 "$complete_output")
    assert_eq "sidecar binds exact transport bytes" "$expected_digest" "$actual_digest"
    mode=$(file_mode "$complete_output")
    assert_eq "sidecar output is private" "600" "$mode"

    local empty_output="${TEST_ROOT}/empty-distributions-evidence.json"
    run_build "${TEST_ROOT}/empty-distributions-report.json" "$empty_output"
    assert_eq "observed empty distributions exit zero" "0" "$LAST_EXIT"
    assert_jq "observed empty distributions remain complete" '.complete == true and .population.unchanged_cycles == 4 and .population.actionable_changes == 0 and .latency.completed_action_samples == 0 and .latency.completed_action_p95_ms == null and .webhook.invalidations == 0 and .webhook.lag_samples == 0 and .webhook.lag_p50_ms == null and .webhook.lag_p95_ms == null and (._meta.missing_fields | length) == 0' "$empty_output"

    test_contract_migration_evidence

    cp "$complete_output" "$first_output"
    run_build "$complete_report" "$complete_output"
    if cmp -s "$first_output" "$complete_output"; then
        record_result "identical input produces byte-stable sidecar" 0
    else
        record_result "identical input produces byte-stable sidecar" 1
    fi

    local incomplete_output="${TEST_ROOT}/incomplete-evidence.json"
    run_build "${TEST_ROOT}/incomplete-report.json" "$incomplete_output"
    assert_eq "partial coverage exits zero" "0" "$LAST_EXIT"
    assert_contains "partial coverage reports incomplete" "evidence sidecar: incomplete" "$LAST_OUTPUT"
    assert_jq "unsupported group stays null" ".complete == false and .webhook.invalidations == null and .webhook.lag_samples == null and .webhook.lag_p50_ms == null and ._meta.coverage_groups.webhook == false and (._meta.missing_fields | length) == 6" "$incomplete_output"

    local unknown_latency_output="${TEST_ROOT}/unknown-latency-evidence.json"
    run_build "${TEST_ROOT}/unknown-latency-report.json" "$unknown_latency_output"
    assert_eq "unknown latency evidence exits zero" "0" "$LAST_EXIT"
    assert_jq "unknown latency invalidates only latency coverage" ".complete == false and .latency.p50_ms == null and .latency.p95_ms == null and .latency.peak_attempts_per_minute == null and .latency.completed_action_samples == null and .latency.completed_action_p95_ms == null and ._meta.coverage_groups.latency == false and (._meta.missing_fields | length) == 5" "$unknown_latency_output"

    test_hash_failure_evidence

    local bad_output="${TEST_ROOT}/bad-evidence.json"
    run_build "${TEST_ROOT}/bad-integer-report.json" "$bad_output"
    assert_eq "invalid numeric evidence exits two" "2" "$LAST_EXIT"
    assert_contains "invalid numeric evidence explains rejection" "invalid integer" "$LAST_OUTPUT"
    assert_missing "invalid numeric evidence writes no sidecar" "$bad_output"

    run_build "${TEST_ROOT}/conflicting-report.json" "$bad_output"
    assert_eq "conflicting snapshots exit two" "2" "$LAST_EXIT"
    assert_contains "conflicting snapshots explain rejection" "conflicting snapshots" "$LAST_OUTPUT"
    assert_missing "conflicting snapshots write no sidecar" "$bad_output"

    run_build "${TEST_ROOT}/untyped-report.json" "$bad_output"
    assert_eq "untyped evidence decision exits two" "2" "$LAST_EXIT"
    assert_contains "untyped evidence decision explains rejection" "typed evidence events" "$LAST_OUTPUT"
    assert_missing "untyped evidence decision writes no sidecar" "$bad_output"

    local symlink_target="${TEST_ROOT}/symlink-target.json"
    local symlink_output="${TEST_ROOT}/symlink-output.json"
    local target_contents=""
    printf "sentinel\n" >"$symlink_target"
    ln -s "$symlink_target" "$symlink_output"
    run_build "$complete_report" "$symlink_output"
    assert_eq "symlink output exits two" "2" "$LAST_EXIT"
    assert_contains "symlink output explains rejection" "must not be a symlink" "$LAST_OUTPUT"
    target_contents=$(<"$symlink_target")
    assert_eq "symlink target remains unchanged" "sentinel" "$target_contents"

    local before_digest=""
    local after_digest=""
    before_digest=$(file_sha256 "$complete_report")
    run_build "$complete_report" "$complete_report"
    after_digest=$(file_sha256 "$complete_report")
    assert_eq "identical input and output exits two" "2" "$LAST_EXIT"
    assert_contains "identical path explains rejection" "must be distinct" "$LAST_OUTPUT"
    assert_eq "identical path leaves input unchanged" "$before_digest" "$after_digest"

    local input_link="${TEST_ROOT}/input-link.json"
    local linked_output="${TEST_ROOT}/linked-input-evidence.json"
    ln -s "$complete_report" "$input_link"
    run_build "$input_link" "$linked_output"
    assert_eq "symlink input exits two" "2" "$LAST_EXIT"
    assert_contains "symlink input explains rejection" "regular, non-symlink file" "$LAST_OUTPUT"
    assert_missing "symlink input writes no sidecar" "$linked_output"

    finish_test_run
    return $?
}

main "$@"
