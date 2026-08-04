#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Deterministic PASS/REGRESSION/INCONCLUSIVE coverage for GH#27777.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
readonly BENCHMARK="${SCRIPT_DIR}/../github-api-efficiency-benchmark.sh"
readonly TEMP_BASE="${AIDEVOPS_TEMP_DIR:-${HOME:+$HOME/.aidevops/.agent-workspace/tmp}}"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0
LAST_EXIT=0
LAST_OUTPUT=""
LAST_JSON=""
LAST_MARKDOWN=""

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
		printf 'PASS: %s\n' "$label"
		return 0
	fi
	printf 'FAIL: %s\n' "$label"
	if [[ -n "$detail" ]]; then
		printf '      %s\n' "$detail"
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

mkdir -p "$TEMP_BASE"
TEST_ROOT=$(mktemp -d "${TEMP_BASE}/github-api-efficiency-test.XXXXXX")
trap cleanup EXIT

python3 - "$TEST_ROOT" <<'PY'
import copy
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(sys.argv[1])
EVIDENCE_SCHEMA = "aidevops-github-api-efficiency-evidence/v3"
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


def transport(
    first,
    duration,
    attempts,
    graphql_attempts,
    graphql_points,
    rest_attempts,
    search_attempts,
    *,
    errors,
    retries,
    additional_pages,
    elapsed_ms,
    unknown_quota=0,
    unknown_elapsed=0,
    other_attempts=0,
    schema=2,
):
    assert (
        graphql_attempts + rest_attempts + search_attempts + other_attempts
        == attempts
    )
    return {
        "_meta": {
            "schema_version": schema,
            "first_retained_ts": first,
            "last_retained_ts": first + duration,
            "effective_window_seconds": duration,
            "attempted_requests": attempts,
            "retries": retries,
            "pages": attempts,
            "additional_pages": additional_pages,
            "successful_attempts": attempts - errors,
            "failed_attempts": errors,
            "elapsed_ms": elapsed_ms,
            "unknown_elapsed_attempts": unknown_elapsed,
            "known_quota_cost": graphql_points,
            "unknown_quota_cost_attempts": unknown_quota,
            "duplicate_attempt_ids": 0,
            "unidentified_attempts": 0,
            "unknown_page_attempts": 0,
            "window_malformed_v2_records": 0,
            "legacy_events": 0,
            "opaque_paginated_attempts": 0,
            "attempts_exact": True,
        },
        "by_path": {
            "graphql": path_metrics(graphql_attempts, graphql_points),
            "rest": path_metrics(rest_attempts, 0, unknown_quota),
            "search-rest": path_metrics(search_attempts),
            "other": path_metrics(other_attempts),
        },
    }


def evidence(*, p50, p95, burst, completed_p95, webhook_p95, complete=True):
    return {
        "schema": EVIDENCE_SCHEMA,
        "transport_sha256": "",
        "complete": complete,
        "population": {
            "repository_count": 10,
            "pulse_cycles": 100,
            "unchanged_cycles": 80,
            "actionable_changes": 20,
            "unique_actionable_head_shas": 20,
            "repository_set_sha256": REPOSITORY_SET,
        },
        "latency": {
            "p50_ms": p50,
            "p95_ms": p95,
            "peak_attempts_per_minute": burst,
            "completed_action_samples": 20 if completed_p95 is not None else 0,
            "completed_action_p95_ms": completed_p95,
        },
        "cache": {
            "fresh_hits": 80,
            "fresh_empty_hits": 20,
            "misses": 10,
            "stale": 2,
            "invalidated": 5,
        },
        "single_flight": {
            "leaders": 30,
            "waits": 10,
            "takeovers": 1,
            "duplicate_leaders": 0,
        },
        "webhook": {
            "invalidations": 10,
            "lag_samples": 10 if webhook_p95 is not None else 0,
            "lag_p50_ms": 100,
            "lag_p95_ms": webhook_p95,
            "duplicate_actions": 0,
            "missed_recoveries": 0,
        },
        "guardrails": {
            "stale_snapshot_detections": 1,
            "forced_live_refreshes": 1,
            "stale_positive_decisions": 0,
            "dispatch_dependency_violations": 0,
            "required_check_merge_preflight_mismatches": 0,
        },
        "path_budgets": {
            "fingerprint_verification_list_calls": 0,
            "fresh_empty_live_fallbacks": 0,
            "aggregate_check_fetches": 20,
            "cycle_scoped_aggregate_check_fetches": 20,
            "unique_cycle_scoped_actionable_heads": 20,
        },
    }


BASELINE_REPORT = transport(
    1_000,
    43_200,
    1_000,
    200,
    200,
    700,
    100,
    errors=10,
    retries=20,
    additional_pages=50,
    elapsed_ms=500_000,
)
BASELINE_EVIDENCE = evidence(
    p50=100, p95=500, burst=50, completed_p95=1_000, webhook_p95=400
)
PASS_REPORT = transport(
    50_000,
    43_200,
    800,
    160,
    180,
    560,
    80,
    errors=5,
    retries=8,
    additional_pages=25,
    elapsed_ms=360_000,
)
PASS_EVIDENCE = evidence(
    p50=90, p95=450, burst=45, completed_p95=900, webhook_p95=350
)


def write_case(name, canary_report, canary_evidence, baseline_evidence=None):
    baseline_report_path = ROOT / f"{name}-baseline-report.json"
    baseline_evidence_path = ROOT / f"{name}-baseline-evidence.json"
    canary_report_path = ROOT / f"{name}-canary-report.json"
    canary_evidence_path = ROOT / f"{name}-canary-evidence.json"

    write_json(baseline_report_path, BASELINE_REPORT)
    baseline_sidecar = copy.deepcopy(
        BASELINE_EVIDENCE if baseline_evidence is None else baseline_evidence
    )
    baseline_sidecar["transport_sha256"] = hashlib.sha256(
        baseline_report_path.read_bytes()
    ).hexdigest()
    write_json(baseline_evidence_path, baseline_sidecar)

    write_json(canary_report_path, canary_report)
    canary_sidecar = copy.deepcopy(canary_evidence)
    canary_sidecar["transport_sha256"] = hashlib.sha256(
        canary_report_path.read_bytes()
    ).hexdigest()
    write_json(canary_evidence_path, canary_sidecar)


write_case("pass", PASS_REPORT, PASS_EVIDENCE)

empty_baseline_evidence = copy.deepcopy(BASELINE_EVIDENCE)
empty_canary_evidence = copy.deepcopy(PASS_EVIDENCE)
for sidecar in (empty_baseline_evidence, empty_canary_evidence):
    sidecar["population"]["unchanged_cycles"] = 100
    sidecar["population"]["actionable_changes"] = 0
    sidecar["population"]["unique_actionable_head_shas"] = 0
    sidecar["latency"]["completed_action_samples"] = 0
    sidecar["latency"]["completed_action_p95_ms"] = None
    sidecar["webhook"]["invalidations"] = 0
    sidecar["webhook"]["lag_samples"] = 0
    sidecar["webhook"]["lag_p50_ms"] = None
    sidecar["webhook"]["lag_p95_ms"] = None
    sidecar["path_budgets"]["aggregate_check_fetches"] = 0
    sidecar["path_budgets"]["cycle_scoped_aggregate_check_fetches"] = 0
    sidecar["path_budgets"]["unique_cycle_scoped_actionable_heads"] = 0
write_case(
    "empty-distributions",
    PASS_REPORT,
    empty_canary_evidence,
    empty_baseline_evidence,
)

sample_mismatch_evidence = copy.deepcopy(PASS_EVIDENCE)
sample_mismatch_evidence["latency"]["completed_action_samples"] = 0
sample_mismatch_evidence["latency"]["completed_action_p95_ms"] = None
write_case("sample-mismatch", PASS_REPORT, sample_mismatch_evidence)

invalid_distribution_evidence = copy.deepcopy(PASS_EVIDENCE)
invalid_distribution_evidence["latency"]["completed_action_samples"] = 0
write_case("distribution-invalid", PASS_REPORT, invalid_distribution_evidence)

regression_report = transport(
    50_000,
    43_200,
    1_200,
    260,
    260,
    820,
    120,
    errors=30,
    retries=40,
    additional_pages=80,
    elapsed_ms=900_000,
)
regression_evidence = evidence(
    p50=150, p95=700, burst=70, completed_p95=1_400, webhook_p95=700
)
regression_evidence["single_flight"]["duplicate_leaders"] = 1
regression_evidence["webhook"]["duplicate_actions"] = 1
regression_evidence["path_budgets"]["fingerprint_verification_list_calls"] = 1
regression_evidence["path_budgets"]["aggregate_check_fetches"] = 21
regression_evidence["path_budgets"]["cycle_scoped_aggregate_check_fetches"] = 21
write_case("regression", regression_report, regression_evidence)

incomplete_evidence = copy.deepcopy(PASS_EVIDENCE)
incomplete_evidence["complete"] = False
incomplete_evidence["latency"]["p95_ms"] = None
write_case("incomplete", PASS_REPORT, incomplete_evidence)

uncovered_distribution_evidence = copy.deepcopy(PASS_EVIDENCE)
uncovered_distribution_evidence["complete"] = False
uncovered_distribution_evidence["latency"]["completed_action_samples"] = None
uncovered_distribution_evidence["latency"]["completed_action_p95_ms"] = None
uncovered_distribution_evidence["webhook"]["lag_samples"] = None
uncovered_distribution_evidence["webhook"]["lag_p50_ms"] = None
uncovered_distribution_evidence["webhook"]["lag_p95_ms"] = None
write_case(
    "uncovered-distributions",
    PASS_REPORT,
    uncovered_distribution_evidence,
)

unequal_report = transport(
    50_000,
    10_000,
    800,
    160,
    180,
    560,
    80,
    errors=5,
    retries=8,
    additional_pages=25,
    elapsed_ms=360_000,
)
write_case("unequal", unequal_report, PASS_EVIDENCE)

workload_evidence = copy.deepcopy(PASS_EVIDENCE)
workload_evidence["population"]["unchanged_cycles"] = 100
workload_evidence["population"]["actionable_changes"] = 0
workload_evidence["population"]["unique_actionable_head_shas"] = 0
workload_evidence["path_budgets"]["cycle_scoped_aggregate_check_fetches"] = 0
workload_evidence["path_budgets"]["unique_cycle_scoped_actionable_heads"] = 0
write_case("workload", PASS_REPORT, workload_evidence)

invalid_population_evidence = copy.deepcopy(PASS_EVIDENCE)
invalid_population_evidence["population"]["unchanged_cycles"] = 101
write_case("population-invalid", PASS_REPORT, invalid_population_evidence)

unknown_quota_report = transport(
    50_000,
    43_200,
    800,
    160,
    180,
    560,
    80,
    errors=5,
    retries=8,
    additional_pages=25,
    elapsed_ms=360_000,
    unknown_quota=1,
)
write_case("unknown-quota", unknown_quota_report, PASS_EVIDENCE)

unknown_latency_report = transport(
    50_000,
    43_200,
    800,
    160,
    180,
    560,
    80,
    errors=5,
    retries=8,
    additional_pages=25,
    elapsed_ms=360_000,
    unknown_elapsed=1,
)
write_case("unknown-latency", unknown_latency_report, PASS_EVIDENCE)

incompatible_report = copy.deepcopy(PASS_REPORT)
incompatible_report["_meta"]["schema_version"] = 1
write_case("incompatible", incompatible_report, PASS_EVIDENCE)

counter_mismatch_report = copy.deepcopy(PASS_REPORT)
counter_mismatch_report["_meta"]["successful_attempts"] = 800
write_case("counter-mismatch", counter_mismatch_report, PASS_EVIDENCE)

unclassified_report = transport(
    50_000,
    43_200,
    800,
    160,
    180,
    559,
    80,
    errors=5,
    retries=8,
    additional_pages=25,
    elapsed_ms=360_000,
    other_attempts=1,
)
write_case("unclassified", unclassified_report, PASS_EVIDENCE)

write_case("digest", PASS_REPORT, PASS_EVIDENCE)
digest_path = ROOT / "digest-canary-evidence.json"
digest_payload = json.loads(digest_path.read_text(encoding="utf-8"))
digest_payload["transport_sha256"] = "0" * 64
write_json(digest_path, digest_payload)
PY

run_case() {
	local scenario="$1"
	local canary_not_before="${2:-45000}"
	LAST_JSON="${TEST_ROOT}/${scenario}-result.json"
	LAST_MARKDOWN="${TEST_ROOT}/${scenario}-result.md"
	rm -f "$LAST_JSON" "$LAST_MARKDOWN"
	set +e
	LAST_OUTPUT=$(
		"$BENCHMARK" compare \
			--baseline-report "${TEST_ROOT}/${scenario}-baseline-report.json" \
			--baseline-evidence "${TEST_ROOT}/${scenario}-baseline-evidence.json" \
			--baseline-label "baseline-${scenario}" \
			--canary-report "${TEST_ROOT}/${scenario}-canary-report.json" \
			--canary-evidence "${TEST_ROOT}/${scenario}-canary-evidence.json" \
			--canary-label "canary-${scenario}" \
			--canary-not-before "$canary_not_before" \
			--json-out "$LAST_JSON" \
			--markdown-out "$LAST_MARKDOWN" 2>&1
	)
	LAST_EXIT=$?
	set -e
	return 0
}

test_pass_and_determinism() {
	run_case pass
	assert_eq "comparable fixture exits zero" "0" "$LAST_EXIT"
	assert_jq "comparable fixture reports PASS" \
		'.schema == "aidevops-github-api-efficiency-benchmark/v1" and .status == "PASS" and .reasons == []' "$LAST_JSON"
	assert_jq "PASS reports normalized attempt savings" \
		'.deltas.attempt_reduction_pct.per_repo_hour == 20 and .deltas.attempt_reduction_pct.per_pulse_cycle == 20' "$LAST_JSON"
	assert_jq "PASS records both evidence digests" \
		'(.windows.baseline.evidence_sha256 | length) == 64 and (.windows.canary.evidence_sha256 | length) == 64' "$LAST_JSON"
	local markdown=""
	markdown=$(<"$LAST_MARKDOWN")
	assert_contains "Markdown reports PASS" "**Status:** \`PASS\`" "$markdown"

	local first_json="${TEST_ROOT}/pass-first.json"
	local first_markdown="${TEST_ROOT}/pass-first.md"
	cp "$LAST_JSON" "$first_json"
	cp "$LAST_MARKDOWN" "$first_markdown"
	run_case pass
	if cmp -s "$first_json" "$LAST_JSON" && cmp -s "$first_markdown" "$LAST_MARKDOWN"; then
		record_result "identical inputs produce byte-stable reports" 0
	else
		record_result "identical inputs produce byte-stable reports" 1
	fi

	run_case empty-distributions
	assert_eq "observed empty distributions can pass" "0" "$LAST_EXIT"
	assert_jq "empty distributions are explicit and comparable" \
		'.status == "PASS" and .windows.baseline.latency.completed_action_samples == 0 and .windows.baseline.latency.completed_action_p95_ms == null and .windows.canary.webhook.lag_samples == 0 and .windows.canary.webhook.lag_p95_ms == null' "$LAST_JSON"
	markdown=$(<"$LAST_MARKDOWN")
	assert_contains "Markdown distinguishes empty distributions" "not applicable" "$markdown"
	return 0
}

test_regression() {
	run_case regression
	assert_eq "regression exits one" "1" "$LAST_EXIT"
	assert_jq "regression fixture reports REGRESSION" \
		'.status == "REGRESSION" and (.reasons | length) >= 5' "$LAST_JSON"
	assert_jq "path budget breach is explicit" \
		'.reasons | any(contains("fingerprint_verification_list_calls"))' "$LAST_JSON"
	assert_jq "cycle-scoped fetch budget breach is explicit" \
		'.reasons | any(contains("cycle-scoped aggregate check fetches"))' "$LAST_JSON"
	return 0
}

test_inconclusive_windows() {
	run_case incomplete
	assert_eq "incomplete evidence exits two" "2" "$LAST_EXIT"
	assert_jq "incomplete evidence is INCONCLUSIVE" \
		'.status == "INCONCLUSIVE" and (.reasons | any(contains("marked incomplete"))) and (.reasons | any(contains("latency.p95_ms is unknown")))' "$LAST_JSON"

	run_case uncovered-distributions
	assert_eq "uncovered distributions exit two" "2" "$LAST_EXIT"
	assert_jq "uncovered distributions remain INCONCLUSIVE without crashing" \
		'.status == "INCONCLUSIVE" and (.reasons | any(contains("completed_action_samples is unknown"))) and (.reasons | any(contains("lag_samples is unknown")))' "$LAST_JSON"

	run_case unequal
	assert_eq "unequal retained windows exit two" "2" "$LAST_EXIT"
	assert_jq "unequal retained windows are INCONCLUSIVE" \
		'.status == "INCONCLUSIVE" and (.reasons | any(contains("materially unequal")))' "$LAST_JSON"

	run_case workload
	assert_eq "non-equivalent workload exits two" "2" "$LAST_EXIT"
	assert_jq "workload mix is part of comparability" \
		'.status == "INCONCLUSIVE" and (.comparability.workload_rates_equivalent == false) and (.reasons | any(contains("actionable_changes rates")))' "$LAST_JSON"

	run_case sample-mismatch
	assert_eq "one-sided completed-action samples exit two" "2" "$LAST_EXIT"
	assert_jq "one-sided completed-action samples are noncomparable" \
		'.status == "INCONCLUSIVE" and (.reasons | any(contains("completed-action latency sample availability differs")))' "$LAST_JSON"

	run_case pass 60000
	assert_eq "pre-rollout canary exits two" "2" "$LAST_EXIT"
	assert_jq "rollout boundary is enforced" \
		'.status == "INCONCLUSIVE" and (.reasons | any(contains("before the required rollout boundary")))' "$LAST_JSON"
	return 0
}

test_fail_closed_transport() {
	run_case unknown-quota
	assert_eq "unknown quota evidence exits two" "2" "$LAST_EXIT"
	assert_jq "unknown quota evidence cannot pass" \
		'.status == "INCONCLUSIVE" and (.reasons | any(contains("quota cost is unknown")))' "$LAST_JSON"

	run_case unknown-latency
	assert_eq "unknown latency evidence exits two" "2" "$LAST_EXIT"
	assert_jq "unknown latency evidence cannot pass" \
		'.status == "INCONCLUSIVE" and (.reasons | any(contains("request latency is unknown")))' "$LAST_JSON"

	run_case unclassified
	assert_eq "unclassified transport exits two" "2" "$LAST_EXIT"
	assert_jq "unclassified transport cannot pass" \
		'.status == "INCONCLUSIVE" and (.reasons | any(contains("unclassified transport attempts")))' "$LAST_JSON"

	run_case incompatible
	assert_eq "incompatible schema exits two" "2" "$LAST_EXIT"
	assert_contains "incompatible schema explains rejection" "schema_version must be 2" "$LAST_OUTPUT"
	assert_missing "incompatible schema writes no JSON" "$LAST_JSON"

	run_case counter-mismatch
	assert_eq "inconsistent counters exit two" "2" "$LAST_EXIT"
	assert_contains "inconsistent counters explain rejection" "do not reconcile" "$LAST_OUTPUT"
	assert_missing "inconsistent counters write no JSON" "$LAST_JSON"

	run_case population-invalid
	assert_eq "inconsistent population exits two" "2" "$LAST_EXIT"
	assert_contains "inconsistent population explains rejection" "exceed Pulse cycles" "$LAST_OUTPUT"
	assert_missing "inconsistent population writes no JSON" "$LAST_JSON"

	run_case distribution-invalid
	assert_eq "inconsistent distribution exits two" "2" "$LAST_EXIT"
	assert_contains "inconsistent distribution explains rejection" "must be null when its sample count is zero" "$LAST_OUTPUT"
	assert_missing "inconsistent distribution writes no JSON" "$LAST_JSON"

	run_case digest
	assert_eq "mismatched evidence digest exits two" "2" "$LAST_EXIT"
	assert_contains "digest mismatch explains rejection" "does not match" "$LAST_OUTPUT"
	assert_missing "digest mismatch writes no JSON" "$LAST_JSON"
	return 0
}

main() {
	test_pass_and_determinism
	test_regression
	test_inconclusive_windows
	test_fail_closed_transport

	printf '\nTests run: %d\n' "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf 'Tests failed: %d\n' "$TESTS_FAILED"
		return 1
	fi
	printf 'All tests passed\n'
	return 0
}

main "$@"
