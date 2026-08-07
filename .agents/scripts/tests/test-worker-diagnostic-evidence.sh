#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-worker-diagnostic-evidence.sh — structured worker failure evidence fields
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_FAILED=0
TMPDIR_TEST=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '  %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TMPDIR_TEST=$(mktemp -d)
	export HOME="$TMPDIR_TEST/home"
	mkdir -p "$HOME/.aidevops/logs" "$HOME/.aidevops/cache"
	return 0
}

teardown() {
	[[ -n "$TMPDIR_TEST" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST" || true
	return 0
}

test_runtime_metric_accepts_structured_evidence() {
	local metrics_file="$HOME/.aidevops/logs/headless-runtime-metrics.jsonl"
	local metrics_dir="$HOME/.aidevops/logs"
	local state_dir="$HOME/.aidevops/state"
	mkdir -p "$metrics_dir" "$state_dir"
	SCRIPT_DIR="$AGENTS_SCRIPTS"
	STATE_DIR="$state_dir"
	STATE_DB="$state_dir/headless-runtime.db"
	METRICS_DIR="$metrics_dir"
	METRICS_FILE="$metrics_file"
	export AIDEVOPS_WORKER_ID="worker:child"
	export AIDEVOPS_PARENT_WORKER_ID="worker:parent"
	export AIDEVOPS_ROOT_WORKER_ID="worker:root"
	export AIDEVOPS_CORRELATION_ID="correlation:root"
	export AIDEVOPS_ATTEMPT_ID="attempt:test"
	export AIDEVOPS_RUN_ID="run:test"
	export AIDEVOPS_DISPATCH_TIER="standard"
	export AIDEVOPS_ROUTING_CANDIDATE_INDEX="1"
	export AIDEVOPS_ROUTING_ATTEMPT="2"
	export AIDEVOPS_ROUTING_REASON="same_tier_fallback"
	export AIDEVOPS_ROUTING_ESCALATED="0"
	export AIDEVOPS_ROUTING_VARIANT="high"
	# shellcheck source=../headless-runtime-lib.sh
	source "${AGENTS_SCRIPTS}/headless-runtime-lib.sh"

	append_runtime_metric \
		"worker" "issue-123" "openai/gpt-5.5" "openai" \
		"watchdog_stall_killed" "79" "watchdog_stall_killed" "1" "600000" \
		"123" "owner/repo" "/tmp/worktree" "/tmp/excerpt.log" "ses_test" \
		"" "" "" "worker_exit_diagnostics" "hard_kill_sentinel" \
		"stall_hard_killed" "hard_kill_stall" "redispatch_worker"

	if jq -e 'select(.session_key == "issue-123" and .launch_failure_cause == "stall_hard_killed" and .kill_reason == "hard_kill_stall" and .next_action == "redispatch_worker" and .worker_id == "worker:child" and .parent_worker_id == "worker:parent" and .root_worker_id == "worker:root" and .correlation_id == "correlation:root" and .attempt_id == "attempt:test" and .run_id == "run:test" and .routing_tier == "standard" and .routing_candidate_index == 1 and .routing_attempt == 2 and .routing_reason == "same_tier_fallback" and .routing_escalated == false and .variant == "high")' \
		"$metrics_file" >/dev/null 2>&1; then
		print_result "append_runtime_metric records structured evidence and lineage projection" 0
	else
		print_result "append_runtime_metric records structured evidence and lineage projection" 1 "metrics=$(tr '\n' ' ' <"$metrics_file" 2>/dev/null || true)"
	fi
	return 0
}

test_worker_activity_summary_surfaces_structured_evidence() {
	local metrics_file="$HOME/.aidevops/logs/headless-runtime-metrics.jsonl"
	local now_epoch
	now_epoch=$(date +%s)
	cat >"$metrics_file" <<JSONL
{"ts":${now_epoch},"role":"worker","session_key":"issue-456","session_id":"ses_summary","model":"openai/gpt-5.5","provider":"openai","result":"premature_exit","exit_code":77,"failure_reason":"premature_exit","activity":true,"duration_ms":120000,"issue_number":456,"repo_slug":"owner/repo","launch_failure_cause":"model_stopped_before_completion","kill_reason":"natural","next_action":"resume_session_with_completion_contract"}
JSONL
	local summary_json
	summary_json=$(WAH_METRICS_FILE="$metrics_file" WAH_PULSE_STATS_FILE="$HOME/.aidevops/logs/pulse-stats.json" \
		"${AGENTS_SCRIPTS}/worker-activity-helper.sh" summary --since 1h --json --no-pr-check)
	if printf '%s' "$summary_json" | jq -e '.metrics.failure_groups[] | select(.launch_failure_cause == "model_stopped_before_completion" and .kill_reason == "natural" and .next_action == "resume_session_with_completion_contract")' >/dev/null 2>&1; then
		print_result "worker activity summary surfaces structured evidence" 0
	else
		print_result "worker activity summary surfaces structured evidence" 1 "summary=${summary_json}"
	fi
	return 0
}

setup
trap teardown EXIT
test_runtime_metric_accepts_structured_evidence
test_worker_activity_summary_surfaces_structured_evidence

printf 'Total: %d, Failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
