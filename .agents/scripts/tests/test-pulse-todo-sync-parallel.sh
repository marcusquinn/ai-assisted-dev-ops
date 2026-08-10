#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
TEST_TMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEST_TMP_PARENT"
TEST_ROOT="$(mktemp -d "${TEST_TMP_PARENT}/pulse-todo-sync-parallel-XXXXXX")"

cleanup() {
	rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
export WRAPPER_LOGFILE="${TEST_ROOT}/pulse-wrapper.log"
export LOGFILE="$WRAPPER_LOGFILE"
export REPOS_JSON="${TEST_ROOT}/repos.json"
export SCRIPT_DIR="$SCRIPTS_DIR"
mkdir -p "$HOME" "$AIDEVOPS_TEMP_DIR"
: >"$WRAPPER_LOGFILE"

# shellcheck source=../pulse-wrapper-cycle.sh
source "${SCRIPTS_DIR}/pulse-wrapper-cycle.sh"

repo_json='[]'
for repo_number in 1 2 3 4 5 6; do
	repo_path="${TEST_ROOT}/repo-${repo_number}"
	mkdir -p "$repo_path"
	repo_json=$(jq -cn \
		--argjson repos "$repo_json" \
		--arg slug "owner/repo-${repo_number}" \
		--arg path "$repo_path" \
		'$repos + [{slug:$slug,path:$path,pulse:true,local_only:false}]')
done
jq -cn --argjson repos "$repo_json" '{initialized_repos:$repos}' >"$REPOS_JSON"

ACTIVE_DIR="${TEST_ROOT}/active"
COUNTER_LOCK="${TEST_ROOT}/counter.lock"
CALL_LOG="${TEST_ROOT}/calls.log"
TIMEOUT_LOG="${TEST_ROOT}/timeouts.log"
MAX_ACTIVE_FILE="${TEST_ROOT}/max-active"
mkdir -p "$ACTIVE_DIR"
printf '0\n' >"$MAX_ACTIVE_FILE"
: >"$CALL_LOG"
: >"$TIMEOUT_LOG"

_test_counter_lock_acquire() {
	while ! mkdir "$COUNTER_LOCK" 2>/dev/null; do
		sleep 0.01
	done
	return 0
}

_test_counter_lock_release() {
	rmdir "$COUNTER_LOCK" 2>/dev/null || true
	return 0
}

_test_active_count() {
	local active_file="" active_count=0
	for active_file in "$ACTIVE_DIR"/job.*; do
		[[ -f "$active_file" ]] || continue
		active_count=$((active_count + 1))
	done
	printf '%s\n' "$active_count"
	return 0
}

_pulse_refresh_repo() {
	local repo_path="$1"
	: "$repo_path"
	return 0
}

run_stage_with_timeout() {
	local stage_name="$1"
	local timeout_secs="$2"
	shift 2
	printf '%s|%s\n' "$stage_name" "$timeout_secs" >>"$TIMEOUT_LOG"
	"$@"
	return $?
}

sync_todo_refs_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	local safe_slug="" active_file="" active_count=0 max_active=0
	: "$repo_path"
	safe_slug=$(printf '%s' "$repo_slug" | tr '/' '_')
	active_file="${ACTIVE_DIR}/job.${safe_slug}"
	_test_counter_lock_acquire
	: >"$active_file"
	printf '%s\n' "$repo_slug" >>"$CALL_LOG"
	active_count=$(_test_active_count)
	max_active=$(<"$MAX_ACTIVE_FILE")
	if [[ "$active_count" -gt "$max_active" ]]; then
		printf '%s\n' "$active_count" >"$MAX_ACTIVE_FILE"
	fi
	_test_counter_lock_release
	sleep 0.2
	_test_counter_lock_acquire
	rm -f "$active_file"
	_test_counter_lock_release
	[[ "$repo_slug" != "owner/repo-5" ]]
	return $?
}

export PULSE_TODO_SYNC_PARALLELISM=2
export PULSE_TODO_SYNC_REPO_TIMEOUT=7
export PRE_RUN_STAGE_TIMEOUT=30

unset PULSE_TODO_SYNC_REPO_TIMEOUT
[[ "$(_pulse_todo_sync_repo_timeout)" -eq 30 ]] || {
	printf 'FAIL default per-repo timeout did not inherit the enclosing stage ceiling\n' >&2
	exit 1
}
export PULSE_TODO_SYNC_REPO_TIMEOUT=7

sync_rc=0
sync_todo_refs_all_repos || sync_rc=$?
call_count=$(wc -l <"$CALL_LOG" | tr -d ' ')
timeout_count=$(wc -l <"$TIMEOUT_LOG" | tr -d ' ')
max_active=$(<"$MAX_ACTIVE_FILE")
remaining_active=$(_test_active_count)

[[ "$sync_rc" -eq 1 ]] || {
	printf 'FAIL aggregate sync did not preserve a child failure: rc=%s\n' "$sync_rc" >&2
	exit 1
}
[[ "$call_count" -eq 6 && "$timeout_count" -eq 6 ]] || {
	printf 'FAIL aggregate sync did not run all repositories: calls=%s timeouts=%s\n' \
		"$call_count" "$timeout_count" >&2
	exit 1
}
[[ "$max_active" -eq 2 && "$remaining_active" -eq 0 ]] || {
	printf 'FAIL aggregate sync violated its concurrency bound: max=%s remaining=%s\n' \
		"$max_active" "$remaining_active" >&2
	exit 1
}
if grep -Evq '\|7$' "$TIMEOUT_LOG"; then
	printf 'FAIL aggregate sync did not apply the configured per-repo timeout\n' >&2
	exit 1
fi
grep -q 'scheduled=6 failures=1 parallelism=2 per_repo_timeout=7s' "$WRAPPER_LOGFILE" || {
	printf 'FAIL aggregate sync omitted bounded batch telemetry\n' >&2
	exit 1
}

printf 'PASS TODO reference sync uses bounded parallel jobs and preserves failures\n'
