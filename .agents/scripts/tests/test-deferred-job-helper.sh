#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Fixture-clock coverage for durable deferred jobs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/deferred-job-helper.sh"
# shellcheck source=../shared-constants.sh
source "${REPO_ROOT}/.agents/scripts/shared-constants.sh"

TEST_ROOT=""
TEST_HOME=""
STATE_DIR=""
DISPATCH_LOG=""
HEADLESS_STUB=""
MANUAL_STUB=""
NOW_EPOCH=1784678400
TESTS_RUN=0
TESTS_FAILED=0

result() {
	local name="$1"
	local failed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$failed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name" >&2
	[[ -z "$detail" ]] || printf '     %s\n' "$detail" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

teardown() {
	[[ -z "$TEST_ROOT" ]] || rm -rf "$TEST_ROOT"
	return 0
}

setup_suite() {
	TEST_ROOT=$(mktemp -d)
	TEST_HOME="${TEST_ROOT}/home"
	HEADLESS_STUB="${TEST_ROOT}/headless-runtime-helper.sh"
	MANUAL_STUB="${TEST_ROOT}/dispatch-single-issue-helper.sh"
	mkdir -p "$TEST_HOME" "${TEST_ROOT}/work"
	cat >"$HEADLESS_STUB" <<'STUB'
#!/usr/bin/env bash
printf 'headless %s\n' "$*" >>"$AIDEVOPS_TEST_DISPATCH_LOG"
sleep "${AIDEVOPS_TEST_DISPATCH_SLEEP:-0}"
exit "${AIDEVOPS_TEST_DISPATCH_EXIT:-0}"
STUB
	cat >"$MANUAL_STUB" <<'STUB'
#!/usr/bin/env bash
printf 'manual %s\n' "$*" >>"$AIDEVOPS_TEST_DISPATCH_LOG"
exit "${AIDEVOPS_TEST_DISPATCH_EXIT:-0}"
STUB
	chmod +x "$HEADLESS_STUB" "$MANUAL_STUB"
	trap teardown EXIT
	return 0
}

reset_fixture() {
	local name="$1"
	STATE_DIR="${TEST_ROOT}/${name}-state"
	DISPATCH_LOG="${TEST_ROOT}/${name}-dispatch.log"
	rm -rf "$STATE_DIR"
	: >"$DISPATCH_LOG"
	return 0
}

run_helper_at() {
	local now_epoch="$1"
	shift
	HOME="$TEST_HOME" \
		AIDEVOPS_DEFERRED_JOB_DIR="$STATE_DIR" \
		AIDEVOPS_DEFERRED_NOW_EPOCH="$now_epoch" \
		AIDEVOPS_HEADLESS_RUNTIME_HELPER="$HEADLESS_STUB" \
		AIDEVOPS_MANUAL_DISPATCH_HELPER="$MANUAL_STUB" \
		AIDEVOPS_TEST_DISPATCH_LOG="$DISPATCH_LOG" \
		"$HELPER" "$@"
	return $?
}

queue_prompt_job() {
	local name="$1"
	local after="${2:-1s}"
	local prompt_file="${TEST_ROOT}/${name}.prompt"
	local output=""
	printf 'fixture prompt for %s\n' "$name" >"$prompt_file"
	output=$(run_helper_at "$NOW_EPOCH" once --after "$after" --name "$name" \
		--dir "${TEST_ROOT}/work" --prompt-file "$prompt_file" --tier simple)
	printf '%s\n' "$output" | awk '{print $2}'
	return 0
}

file_mode() {
	local file_path="$1"
	local mode=""
	mode=$(stat -f '%Lp' "$file_path" 2>/dev/null || true)
	[[ -n "$mode" ]] || mode=$(stat -c '%a' "$file_path" 2>/dev/null || true)
	printf '%s\n' "$mode"
	return 0
}

dispatch_count() {
	local count=0
	count=$(wc -l <"$DISPATCH_LOG" | tr -d '[:space:]')
	printf '%s\n' "$count"
	return 0
}

test_queue_status_and_privacy() {
	reset_fixture privacy
	local job_id=""
	local job_file=""
	local prompt_file=""
	local status_json=""
	job_id=$(queue_prompt_job privacy 1h)
	job_file="${STATE_DIR}/jobs/${job_id}.json"
	prompt_file="${STATE_DIR}/prompts/${job_id}.prompt"
	status_json=$(run_helper_at "$NOW_EPOCH" status "$job_id" --json)
	if [[ "$(jq -r '.status' "$job_file")" == "queued" &&
	"$(file_mode "$job_file")" == "600" && "$(file_mode "$prompt_file")" == "600" &&
	"$status_json" != *"${TEST_ROOT}"* && "$status_json" != *"fixture prompt"* &&
	"$(jq -r '.dispatch.prompt_ref' "$job_file")" == "prompts/${job_id}.prompt" ]]; then
		result "queue stores private structured state and sanitized status" 0
	else
		result "queue stores private structured state and sanitized status" 1 "$status_json"
	fi
	return 0
}

test_schedule_validation() {
	reset_fixture validation
	local prompt_file="${TEST_ROOT}/validation.prompt"
	local rc=0
	printf 'safe fixture\n' >"$prompt_file"
	run_helper_at "$NOW_EPOCH" once --after 1h --at 2026-07-22T00:00:00Z \
		--name invalid --dir "${TEST_ROOT}/work" --prompt-file "$prompt_file" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		result "once rejects mutually exclusive time selectors" 0
	else
		result "once rejects mutually exclusive time selectors" 1
	fi
	return 0
}

test_duration_overflow_is_rejected() {
	reset_fixture duration
	local prompt_file="${TEST_ROOT}/duration.prompt"
	local after_rc=0
	local at_rc=0
	printf 'safe fixture\n' >"$prompt_file"
	run_helper_at "$NOW_EPOCH" once --after 999999999999999999d --name invalid-duration \
		--dir "${TEST_ROOT}/work" --prompt-file "$prompt_file" >/dev/null 2>&1 || after_rc=$?
	run_helper_at "$NOW_EPOCH" once --at 2037-07-22T00:00:00Z --name unbounded-at \
		--dir "${TEST_ROOT}/work" --prompt-file "$prompt_file" >/dev/null 2>&1 || at_rc=$?
	if [[ "$after_rc" -eq 2 && "$at_rc" -eq 2 ]]; then
		result "once rejects overflowing or unbounded future schedules" 0
	else
		result "once rejects overflowing or unbounded future schedules" 1 "after_rc=$after_rc at_rc=$at_rc"
	fi
	return 0
}

test_storage_refuses_unowned_root() {
	reset_fixture unowned
	local rc=0
	local mode_before=""
	mkdir "$STATE_DIR"
	printf 'preserve me\n' >"${STATE_DIR}/operator-note.txt"
	mode_before=$(file_mode "$STATE_DIR")
	run_helper_at "$NOW_EPOCH" status >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 && -f "${STATE_DIR}/operator-note.txt" && ! -e "${STATE_DIR}/jobs" &&
		! -e "${STATE_DIR}/.aidevops-deferred-job-root" && "$(file_mode "$STATE_DIR")" == "$mode_before" ]]; then
		result "storage initialization refuses to adopt an existing unowned root" 0
	else
		result "storage initialization refuses to adopt an existing unowned root" 1 "rc=$rc"
	fi
	return 0
}

test_lock_recovery_preserves_live_owner() {
	reset_fixture locks
	local prompt_file="${TEST_ROOT}/locks.prompt"
	local rc=0
	local token_after=""
	local stale_job_id=""
	printf 'safe fixture\n' >"$prompt_file"
	run_helper_at "$NOW_EPOCH" status >/dev/null
	mkdir "${STATE_DIR}/queue.lock"
	printf '%s\n' "$((NOW_EPOCH - 60))" >"${STATE_DIR}/queue.lock/epoch"
	printf '%s\n' "$$" >"${STATE_DIR}/queue.lock/pid"
	printf '%s\n' "live-owner" >"${STATE_DIR}/queue.lock/token"
	HOME="$TEST_HOME" AIDEVOPS_DEFERRED_JOB_DIR="$STATE_DIR" AIDEVOPS_DEFERRED_NOW_EPOCH="$NOW_EPOCH" \
		AIDEVOPS_DEFERRED_LOCK_ATTEMPTS=2 "$HELPER" once --after 1m --name live-lock \
		--dir "${TEST_ROOT}/work" --prompt-file "$prompt_file" >/dev/null 2>&1 || rc=$?
	IFS= read -r token_after <"${STATE_DIR}/queue.lock/token" || token_after=""
	rm -rf "${STATE_DIR}/queue.lock"
	mkdir "${STATE_DIR}/queue.lock"
	printf '%s\n' "$((NOW_EPOCH - 60))" >"${STATE_DIR}/queue.lock/epoch"
	printf '%s\n' "99999999" >"${STATE_DIR}/queue.lock/pid"
	printf '%s\n' "stale-owner" >"${STATE_DIR}/queue.lock/token"
	mkdir "${STATE_DIR}/queue.lock.reclaim"
	printf '%s\n' "$((NOW_EPOCH - 60))" >"${STATE_DIR}/queue.lock.reclaim/epoch"
	printf '%s\n' "99999999" >"${STATE_DIR}/queue.lock.reclaim/pid"
	stale_job_id=$(queue_prompt_job stale-lock 1m)
	if [[ "$rc" -ne 0 && "$token_after" == "live-owner" && "$stale_job_id" == dj-* &&
		! -e "${STATE_DIR}/queue.lock.reclaim" ]]; then
		result "lock recovery preserves live owners and reclaims abandoned locks and guards" 0
	else
		result "lock recovery preserves live owners and reclaims abandoned locks and guards" 1 \
			"rc=$rc token=$token_after stale_job=$stale_job_id"
	fi
	return 0
}

test_cancel_prevents_launch() {
	reset_fixture cancel
	local job_id=""
	local state=""
	job_id=$(queue_prompt_job cancel)
	run_helper_at "$NOW_EPOCH" cancel "$job_id" >/dev/null
	run_helper_at "$((NOW_EPOCH + 10))" run-due >/dev/null
	state=$(run_helper_at "$((NOW_EPOCH + 10))" status "$job_id" --json)
	if [[ "$(printf '%s\n' "$state" | jq -r '.status')" == "cancelled" && "$(dispatch_count)" -eq 0 ]]; then
		result "cancel is terminal and prevents launch" 0
	else
		result "cancel is terminal and prevents launch" 1 "$state"
	fi
	return 0
}

test_overdue_runs_once() {
	reset_fixture overdue
	local job_id=""
	local state=""
	job_id=$(queue_prompt_job overdue)
	run_helper_at "$((NOW_EPOCH + 20))" run-due >/dev/null
	run_helper_at "$((NOW_EPOCH + 30))" run-due >/dev/null
	state=$(run_helper_at "$((NOW_EPOCH + 30))" status "$job_id" --json)
	if [[ "$(printf '%s\n' "$state" | jq -r '.status')" == "success" && "$(dispatch_count)" -eq 1 ]]; then
		result "overdue job executes once across repeated ticks" 0
	else
		result "overdue job executes once across repeated ticks" 1 "$state count=$(dispatch_count)"
	fi
	return 0
}

test_concurrent_ticks_do_not_double_launch() {
	reset_fixture race
	local job_id=""
	local rc1=0
	local rc2=0
	job_id=$(queue_prompt_job race)
	HOME="$TEST_HOME" AIDEVOPS_DEFERRED_JOB_DIR="$STATE_DIR" AIDEVOPS_DEFERRED_NOW_EPOCH="$((NOW_EPOCH + 20))" \
		AIDEVOPS_HEADLESS_RUNTIME_HELPER="$HEADLESS_STUB" AIDEVOPS_MANUAL_DISPATCH_HELPER="$MANUAL_STUB" \
		AIDEVOPS_TEST_DISPATCH_LOG="$DISPATCH_LOG" AIDEVOPS_TEST_DISPATCH_SLEEP=1 "$HELPER" run-due >/dev/null &
	local pid1=$!
	HOME="$TEST_HOME" AIDEVOPS_DEFERRED_JOB_DIR="$STATE_DIR" AIDEVOPS_DEFERRED_NOW_EPOCH="$((NOW_EPOCH + 20))" \
		AIDEVOPS_HEADLESS_RUNTIME_HELPER="$HEADLESS_STUB" AIDEVOPS_MANUAL_DISPATCH_HELPER="$MANUAL_STUB" \
		AIDEVOPS_TEST_DISPATCH_LOG="$DISPATCH_LOG" AIDEVOPS_TEST_DISPATCH_SLEEP=1 "$HELPER" run-due >/dev/null &
	local pid2=$!
	wait "$pid1" || rc1=$?
	wait "$pid2" || rc2=$?
	if [[ "$rc1" -eq 0 && "$rc2" -eq 0 && "$(dispatch_count)" -eq 1 &&
	"$(run_helper_at "$((NOW_EPOCH + 20))" status "$job_id" --json | jq -r '.status')" == "success" ]]; then
		result "atomic claim fences concurrent due ticks" 0
	else
		result "atomic claim fences concurrent due ticks" 1 "rc1=$rc1 rc2=$rc2 count=$(dispatch_count)"
	fi
	return 0
}

test_claim_recovery_and_running_fuse() {
	reset_fixture recovery
	local claimed_id=""
	local running_id=""
	local claimed_file=""
	local running_file=""
	local tmp_file=""
	claimed_id=$(queue_prompt_job claimed)
	claimed_file="${STATE_DIR}/jobs/${claimed_id}.json"
	tmp_file="${claimed_file}.tmp"
	jq '.status="claimed" | .lease={id:"old",expires_epoch:1}' "$claimed_file" >"$tmp_file"
	mv "$tmp_file" "$claimed_file"
	run_helper_at "$((NOW_EPOCH + 20))" run-due >/dev/null
	running_id=$(queue_prompt_job running)
	running_file="${STATE_DIR}/jobs/${running_id}.json"
	tmp_file="${running_file}.tmp"
	jq '.status="running" | .lease={id:"old",expires_epoch:1} | .started_at="2026-07-21T00:00:00Z"' "$running_file" >"$tmp_file"
	mv "$tmp_file" "$running_file"
	run_helper_at "$((NOW_EPOCH + 20))" run-due >/dev/null
	if [[ "$(jq -r '.status' "$claimed_file")" == "success" && "$(jq -r '.recovery_count' "$claimed_file")" -eq 1 &&
	"$(jq -r '.status' "$running_file")" == "failure" &&
	"$(jq -r '.outcome' "$running_file")" == "lease_expired_after_start" && "$(dispatch_count)" -eq 1 ]]; then
		result "expired claims recover while ambiguous running work never replays" 0
	else
		result "expired claims recover while ambiguous running work never replays" 1
	fi
	return 0
}

test_failed_preflight_is_durable() {
	reset_fixture preflight
	local gone_dir="${TEST_ROOT}/gone"
	local prompt_file="${TEST_ROOT}/gone.prompt"
	local output=""
	local job_id=""
	local rc=0
	mkdir -p "$gone_dir"
	printf 'fixture\n' >"$prompt_file"
	output=$(run_helper_at "$NOW_EPOCH" once --after 1s --name gone --dir "$gone_dir" --prompt-file "$prompt_file")
	job_id=$(printf '%s\n' "$output" | awk '{print $2}')
	rmdir "$gone_dir"
	run_helper_at "$((NOW_EPOCH + 20))" run-due >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 && "$(jq -r '.status' "${STATE_DIR}/jobs/${job_id}.json")" == "failure" &&
	"$(jq -r '.outcome' "${STATE_DIR}/jobs/${job_id}.json")" == "failed_preflight" ]]; then
		result "missing dispatch inputs become durable failed preflight" 0
	else
		result "missing dispatch inputs become durable failed preflight" 1 "rc=$rc"
	fi
	return 0
}

test_manual_issue_dispatch_and_scheduler_rendering() {
	reset_fixture issue
	local output=""
	local job_id=""
	local rendered=""
	output=$(run_helper_at "$NOW_EPOCH" once --after 1s --name issue --dir "${TEST_ROOT}/work" \
		--issue 42 --repo owner/repo --agent Build+)
	job_id=$(printf '%s\n' "$output" | awk '{print $2}')
	run_helper_at "$((NOW_EPOCH + 20))" run-due >/dev/null
	rendered=$(run_helper_at "$NOW_EPOCH" render-scheduler all)
	if [[ "$(jq -r '.outcome' "${STATE_DIR}/jobs/${job_id}.json")" == "dispatched" &&
	"$(<"$DISPATCH_LOG")" == *"manual dispatch 42 owner/repo"* &&
	"$rendered" == *"StartInterval"* && "$rendered" == *"Persistent=true"* &&
	"$rendered" == *"aidevops: deferred-jobs"* ]]; then
		result "issue work uses manual ceremony and one scheduler owner renders portably" 0
	else
		result "issue work uses manual ceremony and one scheduler owner renders portably" 1
	fi
	return 0
}

test_deferred_scheduler_preserves_child_survival_exception() {
	reset_fixture scheduler-policy
	local rendered=""
	rendered=$(run_helper_at "$NOW_EPOCH" render-scheduler systemd)
	if [[ "$rendered" == *"KillMode=process"* && "$rendered" != *"KillMode=control-group"* ]]; then
		result "deferred scheduler preserves its explicit child-survival exception" 0
	else
		result "deferred scheduler preserves its explicit child-survival exception" 1 "$rendered"
	fi
	return 0
}

test_purge_removes_only_owned_state() {
	reset_fixture purge
	local job_id=""
	local sentinel="${STATE_DIR}/operator-note.txt"
	job_id=$(queue_prompt_job purge 1h)
	printf 'preserve me\n' >"$sentinel"
	run_helper_at "$NOW_EPOCH" uninstall --purge >/dev/null
	if [[ -f "$sentinel" && ! -e "${STATE_DIR}/jobs" && ! -e "${STATE_DIR}/prompts" &&
		! -e "${STATE_DIR}/logs" && ! -e "${STATE_DIR}/.aidevops-deferred-job-root" && "$job_id" == dj-* ]]; then
		result "purge removes owned state without deleting unrelated root contents" 0
	else
		result "purge removes owned state without deleting unrelated root contents" 1
	fi
	return 0
}

main() {
	setup_suite
	test_queue_status_and_privacy
	test_schedule_validation
	test_duration_overflow_is_rejected
	test_storage_refuses_unowned_root
	test_lock_recovery_preserves_live_owner
	test_cancel_prevents_launch
	test_overdue_runs_once
	test_concurrent_ticks_do_not_double_launch
	test_claim_recovery_and_running_fuse
	test_failed_preflight_is_durable
	test_manual_issue_dispatch_and_scheduler_rendering
	test_deferred_scheduler_preserves_child_survival_exception
	test_purge_removes_only_owned_state
	printf '\n%s/%s tests passed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
