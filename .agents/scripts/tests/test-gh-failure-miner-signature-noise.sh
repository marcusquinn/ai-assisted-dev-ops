#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#26113/GH#26127/GH#27738/GH#29522: gh-failure-miner must not
# cluster GitHub runner-echoed shell source as failure signatures.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_equals() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected: %s\n' "$(printf '%q' "$expected")"
		printf '  actual:   %s\n' "$(printf '%q' "$actual")"
	fi
	return 0
}

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  missing: %s\n' "$(printf '%q' "$needle")"
	fi
	return 0
}

assert_not_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  unexpected: %s\n' "$(printf '%q' "$needle")"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="$SCRIPT_DIR/gh-failure-miner-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf '%sFATAL%s: %s not found\n' "$TEST_RED" "$TEST_NC" "$HELPER" >&2
	exit 1
fi

set -- help
# shellcheck source=/dev/null
source "$HELPER" >/dev/null

gh() {
	local first="${1:-}" second="${2:-}" endpoint="${3:-}"
	if [[ "$first" == "api" && "$endpoint" == "repos/marcusquinn/aidevops/actions/runs/29373303758/jobs" ]]; then
		printf '%s\n' '{"jobs":[{"id":1,"conclusion":"failure","check_run_url":"https://api.github.com/repos/marcusquinn/aidevops/check-runs/1","steps":[{"name":"Resolve task","conclusion":"failure"}]}]}'
		return 0
	fi
	if [[ "$first" == "api" && "$endpoint" == "repos/marcusquinn/aidevops/actions/runs/28472942857/jobs" ]]; then
		printf '%s\n' '{"jobs":[{"id":84390104069,"conclusion":"failure","check_run_url":"https://api.github.com/repos/marcusquinn/aidevops/check-runs/84390104069","steps":[{"name":"Gate result","conclusion":"failure"}]}]}'
		return 0
	fi
	if [[ "$first" == "api" && "$endpoint" == "repos/marcusquinn/aidevops/actions/runs/30898422945/jobs" ]]; then
		printf '%s\n' '{"jobs":[{"id":91958107008,"conclusion":"failure","check_run_url":"https://api.github.com/repos/marcusquinn/aidevops/check-runs/91958107008","steps":[{"name":"Enforce gate","conclusion":"failure"}]}]}'
		return 0
	fi
	if [[ "$first" == "run" && "$second" == "view" ]]; then
		if [[ "${GH_LOG_SCENARIO:-}" == "unstructured_echoed_runner_guard" ]]; then
			printf '%s\n' 'sync / Sync Issue Hygiene on PR Merge	UNKNOWN STEP	2026-08-04T20:48:14.7114649Z ^[[36;1m  echo "::error::Runner Git binary is unavailable before guard activation"^[[0m'
			printf '%s\n' 'sync / Sync Issue Hygiene on PR Merge	UNKNOWN STEP	2026-08-04T20:48:27.8644706Z ERROR: closing issue #29494 has no exact ref:GH#29494 TODO mapping'
			return 0
		fi
		if [[ "${GH_LOG_SCENARIO:-}" == "echoed_runner_guard" ]]; then
			printf 'resolve-task\tResolve task\t2026-07-14T23:00:00Z\t\033[36;1mif ! command -v git; then echo "Runner Git binary is unavailable"; exit 1; fi\033[0m\n'
			printf 'resolve-task\tResolve task\t2026-07-14T23:00:01Z\t::error::Closing issue has no exact TODO mapping\n'
			return 0
		fi
		if [[ "${GH_LOG_SCENARIO:-}" == "qlty_unstructured_source" ]]; then
			printf '%s\n' 'Qlty Smell Regression Enforce gate 2026-08-04T10:01:52.5121359Z # t2133: simplification PRs cannot use ratchet-bump — their goal is to reduce smells, not shift them.'
			printf '%s\n' $'Qlty Smell Regression\tEnforce gate\t2026-08-04T10:01:52.5242388Z\t##[error]Qlty smell regression detected (exit 1).'
			return 0
		fi
		printf 'gate / review-bot-gate\tUNKNOWN STEP\t2026-06-30T20:14:24.8559907Z\t\033[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.\033[0m\n'
		printf 'gate / review-bot-gate\tGate result\t2026-06-30T20:14:25.0000000Z\t::error::No AI review bots have posted a real, settled review on this PR yet.\n'
		return 0
	fi
	return 1
}

signature=$(extract_failure_signature "marcusquinn/aidevops" "28472942857" "84390104069")
assert_equals "runner-echoed shell comment is skipped" "gate / review-bot-gate Gate result 2026-06-30T20:14:25.0000000Z ::error::No AI review bots have posted a real, settled review on this PR yet." "$signature"

GH_LOG_SCENARIO="echoed_runner_guard"
signature=$(extract_failure_signature "marcusquinn/aidevops" "29373303758" "1")
assert_equals "runner-echoed guard source cannot mask the executed failure" "resolve-task Resolve task 2026-07-14T23:00:01Z ::error::Closing issue has no exact TODO mapping" "$signature"

GH_LOG_SCENARIO="unstructured_echoed_runner_guard"
signature=$(extract_failure_signature "marcusquinn/aidevops" "29373303758" "1")
assert_equals "GH#29522 timestamp-prefixed runner source cannot become infrastructure evidence" "sync / Sync Issue Hygiene on PR Merge UNKNOWN STEP 2026-08-04T20:48:27.8644706Z ERROR: closing issue #29494 has no exact ref:GH#29494 TODO mapping" "$signature"

GH_LOG_SCENARIO="qlty_unstructured_source"
signature=$(extract_failure_signature "marcusquinn/aidevops" "30898422945" "91958107008")
assert_equals "GH#29468 qlty source comment cannot mask structured error" "Qlty Smell Regression Enforce gate 2026-08-04T10:01:52.5242388Z ##[error]Qlty smell regression detected (exit 1)." "$signature"
GH_LOG_SCENARIO="echoed_runner_guard"

event_file=$(mktemp)
failed_runs_json='[{"name":"Issue sync","id":1,"conclusion":"failure","details_url":"https://github.com/marcusquinn/aidevops/actions/runs/29373303758/job/1","html_url":"https://github.com/marcusquinn/aidevops/actions/runs/29373303758","completed_at":"2026-07-14T23:00:01Z","app":{"slug":"github-actions"}}]'
checks_json='{"check_runs":[{"name":"Issue sync","conclusion":"failure"},{"name":"ShellCheck","conclusion":"success"}]}'
run_logs_checked=$(process_failed_runs "$failed_runs_json" "marcusquinn/aidevops" "pr" "27738" "https://github.com/marcusquinn/aidevops/pull/27738" "27738" "abc123" "2026-07-14T23:00:01Z" "true" "0" "8" "$event_file" "$checks_json")
event_json=$(jq -s '.[0]' "$event_file")
events_json=$(jq -s '.' "$event_file")
assert_equals "executed guard fixture consumes one log fetch" "1" "$run_logs_checked"
assert_equals "executed policy failure remains the event signature" "resolve-task Resolve task 2026-07-14T23:00:01Z ::error::Closing issue has no exact TODO mapping" "$(printf '%s\n' "$event_json" | jq -r '.signature')"
assert_equals "executed policy failure remains non-infrastructure" "false" "$(printf '%s\n' "$event_json" | jq -r '.is_infra')"
assert_equals "non-infrastructure event has no infrastructure reason" "null" "$(printf '%s\n' "$event_json" | jq -r '.infra_reason')"
below_threshold_output=$(create_systemic_issues "$events_json" "2" "3" "true" 2>&1)
assert_contains "single policy failure cannot create an advisory below threshold" "No systemic clusters met threshold (2)." "$below_threshold_output"
rm -f "$event_file"
unset GH_LOG_SCENARIO

duplicate_events='[
  {"repo":"marcusquinn/aidevops","source_kind":"pr","source_ref":"29462","check_name":"Qlty Smell Regression","signature":"same failure","details_url":"https://example.invalid/actions/runs/1/job/2","run_id":1},
  {"repo":"marcusquinn/aidevops","source_kind":"pr","source_ref":"29467","check_name":"Qlty Smell Regression","signature":"same failure","details_url":"https://example.invalid/actions/runs/1/job/2","run_id":1}
]'
deduplicated_events=$(deduplicate_failed_events_json "$duplicate_events")
assert_equals "GH#29468 repeated notification for one check run counts once" "1" "$(printf '%s\n' "$deduplicated_events" | jq 'length')"

filtered=$(filter_signature_noise_lines $'job\tUNKNOWN STEP\ttime\t\033[36;1m# comment cannot merge\033[0m\njob\tStep\ttime\treal error')
assert_equals "comment-only log lines are filtered" $'job\tStep\ttime\treal error' "$filtered"

filtered=$(filter_signature_noise_lines $'job\tUNKNOWN STEP\ttime\t+ # rate-limit grace is disabled — they cannot merge on rate-limit-only.\njob\tStep\ttime\treal error')
assert_equals "xtrace-prefixed shell comments are filtered" $'job\tStep\ttime\treal error' "$filtered"

filtered=$(filter_signature_noise_lines $'job\tStep\ttime\t\033[36;1mif missing; then echo "Runner is unavailable"; fi\033[0m\njob\tStep\ttime\t::error::real policy failure')
assert_equals "cyan runner-echoed executable source is filtered" $'job\tStep\ttime\t::error::real policy failure' "$filtered"

filtered=$(filter_signature_noise_lines $'sync / Sync Issue Hygiene on PR Merge\tUNKNOWN STEP\t2026-08-04T20:48:14.7114649Z ^[[36;1m  echo "::error::Runner Git binary is unavailable before guard activation"^[[0m\nsync / Sync Issue Hygiene on PR Merge\tUNKNOWN STEP\t2026-08-04T20:48:27.8644706Z ERROR: closing issue #29494 has no exact ref:GH#29494 TODO mapping')
assert_equals "GH#29522 three-field timestamped source is filtered" $'sync / Sync Issue Hygiene on PR Merge\tUNKNOWN STEP\t2026-08-04T20:48:27.8644706Z ERROR: closing issue #29494 has no exact ref:GH#29494 TODO mapping' "$filtered"

filtered=$(filter_signature_noise_lines $'gate / review-bot-gate\tUNKNOWN STEP\t2026-06-30T20:14:24.8559907Z\t\033[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.\033[0m')
signature=$(normalize_signature_line "$filtered")
assert_equals "GH#26127 comment-only systemic signature normalizes empty" "no_error_signature_detected" "$signature"

filtered=$(filter_signature_noise_lines $'2026-06-30T20:14:24.8559907Z \033[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.\033[0m\n2026-06-30T20:14:25.0000000Z ::error::No AI review bots have posted a real, settled review on this PR yet.')
assert_equals "GH#26144 timestamp-prefixed shell comments are filtered" $'2026-06-30T20:14:25.0000000Z ::error::No AI review bots have posted a real, settled review on this PR yet.' "$filtered"

filtered=$(filter_signature_noise_lines $'gate / review-bot-gate\tUNKNOWN STEP\t2026-07-02T07:13:54.3733546Z\t^[[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.^[[0m')
signature=$(normalize_signature_line "$filtered")
assert_equals "GH#26308 caret-escaped ANSI comment-only signature normalizes empty" "no_error_signature_detected" "$signature"

signature=$(normalize_signature_line $'^[[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.^[[0m')
assert_equals "GH#26308 caret-escaped ANSI is stripped during normalization" "# rate-limit grace is disabled — they cannot merge on rate-limit-only." "$signature"

signature=$(normalize_signature_line $'\033[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.\033[0m')
assert_equals "GH#26308 raw ANSI is stripped during normalization" "# rate-limit grace is disabled — they cannot merge on rate-limit-only." "$signature"

cluster_json='{"check_name":"Pulse Unbound-Var Lint","signature":"Pulse unbound-var violations found. See PR comment for details.","count":2,"examples":[{"source_kind":"pr","source_ref":"26744","source_url":"https://example.invalid/pull/26744","run_url":"https://example.invalid/actions/runs/1","details_url":"https://example.invalid/actions/runs/1","conclusion":"failure","affected_paths":[],"annotations":[]}]}'
issue_body=$(build_issue_body "$cluster_json" "testpattern" 2 "false")
assert_contains "Pulse unbound-var guidance classifies PR-specific lint" "Pulse Unbound-Var Lint is a PR-specific shell safety gate" "$issue_body"
assert_contains "Pulse unbound-var guidance points workers at PR comment marker" "<!-- pulse-unbound-var-check -->" "$issue_body"
assert_contains "Pulse unbound-var guidance preserves focused verification" ".agents/scripts/pulse-unbound-var-check.sh --scan-files <changed pulse scripts>" "$issue_body"

weak_single_events='[{"repo":"marcusquinn/aidevops","source_kind":"pr","source_ref":"1","source_url":"https://example.invalid/pull/1","check_name":"CI","conclusion":"failure","signature":"infra:runner_log","is_infra":true,"infra_reason":"runner_log"}]'
weak_single_cluster=$(build_infra_advisory_cluster "$weak_single_events" "marcusquinn/aidevops" "2")
assert_equals "one weak log match cannot create an infrastructure advisory" "null" "$weak_single_cluster"

corroborated_events='[{"repo":"marcusquinn/aidevops","source_kind":"pr","source_ref":"1","source_url":"https://example.invalid/pull/1","check_name":"CI","conclusion":"failure","signature":"infra:runner_log","is_infra":true,"infra_reason":"runner_log"},{"repo":"marcusquinn/aidevops","source_kind":"pr","source_ref":"2","source_url":"https://example.invalid/pull/2","check_name":"CI","conclusion":"failure","signature":"infra:runner_log","is_infra":true,"infra_reason":"runner_log"}]'
corroborated_cluster=$(build_infra_advisory_cluster "$corroborated_events" "marcusquinn/aidevops" "2")
assert_equals "weak log evidence requires two distinct sources" "2" "$(printf '%s\n' "$corroborated_cluster" | jq -r '.sources | length')"
infra_body=$(build_infra_issue_body "$corroborated_cluster" "test-infra" "2")
assert_contains "infrastructure body renders observed counts" "2 matching infrastructure log events across 2 sources met the systemic threshold of 2." "$infra_body"
assert_not_contains "infrastructure body omits unsupported simultaneous-failure claim" "All checks failed simultaneously across multiple PRs/commits." "$infra_body"
assert_equals "infrastructure title names events rather than checks" "Infrastructure advisory: 2 events observed" "$(build_issue_title "multiple-checks" "2" "true")"

strong_single_events='[{"repo":"marcusquinn/aidevops","source_kind":"pr","source_ref":"3","source_url":"https://example.invalid/pull/3","check_name":"CI","conclusion":"failure","signature":"infra:billing_annotation","is_infra":true,"infra_reason":"billing_annotation"}]'
strong_single_cluster=$(build_infra_advisory_cluster "$strong_single_events" "marcusquinn/aidevops" "2")
assert_equals "structured billing annotation remains sufficient evidence" "billing_annotation" "$(printf '%s\n' "$strong_single_cluster" | jq -r '.infra_reasons[0]')"

printf '\nTests run: %s, failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	exit 1
fi
exit 0
