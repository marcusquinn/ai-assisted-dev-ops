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

test_attempt_observability_correlates_logs_and_state() {
	local state_root="$HOME/.aidevops/.agent-workspace/pr-review-thread-response"
	local state_file="$state_root/owner-repo-123-attempt-test.attempt.json"
	local lifecycle_output=""
	local exit_output=""
	mkdir -p "$state_root"
	export AIDEVOPS_ATTEMPT_ID="attempt:test"
	export AIDEVOPS_ATTEMPT_STARTED_AT="700"
	export AIDEVOPS_RUN_ID="run:test"
	export AIDEVOPS_ATTEMPT_STATE_ROOT="$state_root"
	export AIDEVOPS_ATTEMPT_STATE_FILE="$state_file"
	# shellcheck source=../shared-constants.sh
	source "${AGENTS_SCRIPTS}/shared-constants.sh"
	# shellcheck source=../worker-lifecycle-common.sh
	source "${AGENTS_SCRIPTS}/worker-lifecycle-common.sh"

	lifecycle_output=$(print_info "[lifecycle] post_worker_prepare session=issue-123 pid=456" 2>&1)
	print_error "[lifecycle] _prepare_run_attempt_command failed rc=17 session=issue-123" >/dev/null 2>&1
	exit_output=$(print_warning "[exit-trap] runtime invocation never started exit=17 reason=worker_runtime_not_invoked" 2>&1)
	if [[ "$lifecycle_output" == *"attempt_id=attempt:test"* && "$lifecycle_output" == *" ts="* &&
		"$exit_output" == *"attempt_id=attempt:test"* && "$exit_output" == *" ts="* ]] &&
		jq -e '
			.attempt_id == "attempt:test" and
			.run_id == "run:test" and
			.last_lifecycle_stage == "_prepare_run_attempt_command" and
			.last_completed_stage == "post_worker_prepare" and
			.exit_path == "worker_runtime_not_invoked" and
			.status == "17" and
			.logged_pid == "456"
		' "$state_file" >/dev/null 2>&1; then
		print_result "worker attempt logs carry correlation fields and persist last-stage state" 0
	else
		print_result "worker attempt logs carry correlation fields and persist last-stage state" 1 \
			"lifecycle=${lifecycle_output}; exit=${exit_output}; state=$(tr '\n' ' ' <"$state_file" 2>/dev/null || true)"
	fi
	return 0
}

test_overlapping_attempts_keep_distinct_logs_and_state() {
	local state_root="$HOME/.aidevops/.agent-workspace/pr-review-thread-response"
	local first_state="$state_root/owner-repo-123-outcome-one.attempt.json"
	local second_state="$state_root/owner-repo-123-outcome-two.attempt.json"
	local shared_log="$TMPDIR_TEST/overlapping-attempts.log"
	local first_pid=""
	local second_pid=""
	local lifecycle_count=0
	local attributable="true"
	local line=""
	mkdir -p "$state_root"
	(
		export AIDEVOPS_ATTEMPT_ID="outcome-one"
		export AIDEVOPS_ATTEMPT_STARTED_AT="701"
		export AIDEVOPS_RUN_ID="run-one"
		export AIDEVOPS_ATTEMPT_STATE_ROOT="$state_root"
		export AIDEVOPS_ATTEMPT_STATE_FILE="$first_state"
		print_info "[lifecycle] pre_model_select session=issue-123 pid=701"
		sleep 0.1
		print_info "[lifecycle] post_model_select session=issue-123 pid=701"
	) 2>>"$shared_log" &
	first_pid="$!"
	(
		export AIDEVOPS_ATTEMPT_ID="outcome-two"
		export AIDEVOPS_ATTEMPT_STARTED_AT="702"
		export AIDEVOPS_RUN_ID="run-two"
		export AIDEVOPS_ATTEMPT_STATE_ROOT="$state_root"
		export AIDEVOPS_ATTEMPT_STATE_FILE="$second_state"
		print_info "[lifecycle] pre_canary session=issue-123 pid=702"
		sleep 0.1
		print_info "[lifecycle] post_canary session=issue-123 pid=702"
	) 2>>"$shared_log" &
	second_pid="$!"
	wait "$first_pid"
	wait "$second_pid"
	while IFS= read -r line; do
		[[ "$line" == *"[lifecycle]"* ]] || continue
		lifecycle_count=$((lifecycle_count + 1))
		if [[ "$line" != *" ts="* || \
			( "$line" != *" attempt_id=outcome-one"* && "$line" != *" attempt_id=outcome-two"* ) ]]; then
			attributable="false"
		fi
	done <"$shared_log"
	if [[ "$lifecycle_count" -eq 4 && "$attributable" == "true" ]] &&
		jq -e '.attempt_id == "outcome-one" and .last_completed_stage == "post_model_select"' \
			"$first_state" >/dev/null 2>&1 &&
		jq -e '.attempt_id == "outcome-two" and .last_completed_stage == "post_canary"' \
			"$second_state" >/dev/null 2>&1; then
		print_result "overlapping attempts retain distinct correlation and state" 0
	else
		print_result "overlapping attempts retain distinct correlation and state" 1 \
			"count=${lifecycle_count} attributable=${attributable} log=$(tr '\n' ' ' <"$shared_log" 2>/dev/null || true)"
	fi
	return 0
}

test_sigkill_retains_last_completed_stage() {
	local state_root="$HOME/.aidevops/.agent-workspace/pr-review-thread-response"
	local state_file="$state_root/owner-repo-123-outcome-killed.attempt.json"
	local ready_file="$TMPDIR_TEST/sigkill-ready"
	local worker_pid=""
	local wait_count=0
	mkdir -p "$state_root"
	(
		export AIDEVOPS_ATTEMPT_ID="outcome-killed"
		export AIDEVOPS_ATTEMPT_STARTED_AT="703"
		export AIDEVOPS_RUN_ID="run-killed"
		export AIDEVOPS_ATTEMPT_STATE_ROOT="$state_root"
		export AIDEVOPS_ATTEMPT_STATE_FILE="$state_file"
		print_info "[lifecycle] post_worker_prepare session=issue-123 pid=703"
		: >"$ready_file"
		sleep 30
		print_info "[lifecycle] post_canary session=issue-123 pid=703"
	) >/dev/null 2>&1 &
	worker_pid="$!"
	while [[ ! -e "$ready_file" && "$wait_count" -lt 100 ]]; do
		sleep 0.02
		wait_count=$((wait_count + 1))
	done
	kill -9 "$worker_pid" 2>/dev/null || true
	wait "$worker_pid" 2>/dev/null || true
	if [[ -e "$ready_file" ]] &&
		jq -e '
			.attempt_id == "outcome-killed" and
			.last_lifecycle_stage == "post_worker_prepare" and
			.last_completed_stage == "post_worker_prepare" and
			.exit_path == "running"
		' "$state_file" >/dev/null 2>&1; then
		print_result "SIGKILL leaves the exact last completed lifecycle stage" 0
	else
		print_result "SIGKILL leaves the exact last completed lifecycle stage" 1 \
			"ready=$([[ -e "$ready_file" ]] && printf true || printf false) state=$(tr '\n' ' ' <"$state_file" 2>/dev/null || true)"
	fi
	return 0
}

test_stale_checkpoint_lock_is_reclaimed() {
	local state_root="$HOME/.aidevops/.agent-workspace/pr-review-thread-response"
	local state_file="$state_root/owner-repo-123-outcome-stale-lock.attempt.json"
	local lock_dir="${state_file}.lock"
	mkdir -p "$state_root" "$lock_dir"
	touch -t 200001010000 "$lock_dir"
	export AIDEVOPS_ATTEMPT_ID="outcome-stale-lock"
	export AIDEVOPS_ATTEMPT_STARTED_AT="704"
	export AIDEVOPS_RUN_ID="run-stale-lock"
	export AIDEVOPS_ATTEMPT_STATE_ROOT="$state_root"
	export AIDEVOPS_ATTEMPT_STATE_FILE="$state_file"
	print_info "[lifecycle] post_worker_prepare session=issue-123 pid=704" >/dev/null 2>&1
	if [[ ! -e "$lock_dir" ]] &&
		jq -e '
			.attempt_id == "outcome-stale-lock" and
			.last_completed_stage == "post_worker_prepare"
		' "$state_file" >/dev/null 2>&1; then
		print_result "stale checkpoint lock is reclaimed before state update" 0
	else
		print_result "stale checkpoint lock is reclaimed before state update" 1 \
			"lock_present=$([[ -e "$lock_dir" ]] && printf true || printf false) state=$(tr '\n' ' ' <"$state_file" 2>/dev/null || true)"
	fi
	return 0
}

test_attempt_initialization_rejects_mismatched_state() {
	local state_root="$HOME/.aidevops/.agent-workspace/pr-review-thread-response"
	local state_file="$state_root/owner-repo-123-outcome-collision.attempt.json"
	mkdir -p "$state_root"
	printf '%s\n' '{"schema":"aidevops-worker-attempt/v1","attempt_id":"other-outcome"}' >"$state_file"
	if ! worker_attempt_observability_initialize \
		"$state_root" "$state_file" "outcome-collision" "issue-123" &&
		jq -e '.attempt_id == "other-outcome"' "$state_file" >/dev/null 2>&1; then
		print_result "attempt initialization rejects mismatched existing state" 0
	else
		print_result "attempt initialization rejects mismatched existing state" 1 \
			"state=$(tr '\n' ' ' <"$state_file" 2>/dev/null || true)"
	fi
	return 0
}

setup
trap teardown EXIT
test_runtime_metric_accepts_structured_evidence
test_worker_activity_summary_surfaces_structured_evidence
test_attempt_observability_correlates_logs_and_state
test_overlapping_attempts_keep_distinct_logs_and_state
test_sigkill_retains_last_completed_stage
test_stale_checkpoint_lock_is_reclaimed
test_attempt_initialization_rejects_mismatched_state

printf 'Total: %d, Failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
