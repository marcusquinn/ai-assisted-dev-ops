#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
export PULSE_STATE_DIR="${TEST_ROOT}/state"
export AIDEVOPS_LOG_DIR="${TEST_ROOT}/logs"
export LOGFILE="${TEST_ROOT}/pulse.log"
mkdir -p "${HOME}/.config/aidevops" "$PULSE_STATE_DIR"
printf '{"initialized_repos":[]}\n' >"${HOME}/.config/aidevops/repos.json"
CALLS="${TEST_ROOT}/calls"
CLOCK="${TEST_ROOT}/clock"
printf '100\n' >"$CLOCK"

# shellcheck source=../pulse-cleanup-progress.sh
source "${SCRIPT_DIR}/pulse-cleanup-progress.sh"
_pc_log_local_only_worktree_skips() { return 0; }
_pc_cleanup_fixture_passes() { printf '0\n'; return 0; }
gh() { printf '1000\n'; return 0; }
date() { command cat "$CLOCK"; return 0; }
_pc_progress_jobs() {
	printf '["merged","slow"]\n["orphan","slow"]\n["merged","later"]\n'
	return 0
}
_pc_progress_run_job() {
	printf '%s\n' "$1" >>"$CALLS"
	if [[ "$1" == '["merged","slow"]' ]]; then printf '110\n' >"$CLOCK"; fi
	return 0
}

# Missing Git fails before fixture cleanup, inventory, or cursor persistence.
rc=0
guard_output=$(
	_pc_cleanup_fixture_passes() { exit 99; }
	_pc_progress_checkpoint() { exit 99; }
	PATH="${TEST_ROOT}/missing-bin" _pc_cleanup_resumable 5 2>&1
) || rc=$?
[[ "$rc" == 1 && "$guard_output" == *"git not available in PATH"* ]]
[[ ! -e "${PULSE_STATE_DIR}/worktree-cleanup-next.json" && ! -e "$CALLS" ]]

# A slow first repository consumes the budget. Next invocation starts at its
# orphan phase, reaches the later repo, and only then rotates back to slow work.
_pc_cleanup_resumable 5
[[ "$(wc -l <"$CALLS" | tr -d ' ')" == 1 ]]
[[ "$(<"${PULSE_STATE_DIR}/worktree-cleanup-next.json")" == '["orphan","slow"]' ]]
printf '100\n' >"$CLOCK"
_pc_cleanup_resumable 5
[[ "$(wc -l <"$CALLS" | tr -d ' ')" == 4 ]]
[[ "$(sed -n '2p' "$CALLS")" == '["orphan","slow"]' ]]
[[ "$(sed -n '3p' "$CALLS")" == '["merged","later"]' ]]

# Abrupt termination after entering a job leaves its successor durably recorded.
printf '100\n' >"$CLOCK"
rm -f "${PULSE_STATE_DIR}/worktree-cleanup-next.json"
rc=0
(
	_pc_progress_run_job() { exit 124; }
	_pc_cleanup_resumable 5
) || rc=$?
[[ "$rc" == 124 ]]
[[ "$(<"${PULSE_STATE_DIR}/worktree-cleanup-next.json")" == '["orphan","slow"]' ]]
[[ ! -d "${AIDEVOPS_LOG_DIR}/cleanup_worktrees.lock" ]]

# Malformed/stale progress cannot introduce an operation outside fresh inventory.
printf '["invented","untrusted"]\n' >"${PULSE_STATE_DIR}/worktree-cleanup-next.json"
printf '100\n' >"$CLOCK"
_pc_cleanup_resumable 5
[[ "$(tail -n 1 "$CALLS")" == '["merged","slow"]' ]]

# Failure to persist progress fails closed before invoking any cleanup job.
before=$(wc -l <"$CALLS" | tr -d ' ')
printf '100\n' >"$CLOCK"
rc=0
(
	_pc_progress_checkpoint() { return 1; }
	_pc_cleanup_resumable 5
) || rc=$?
[[ "$rc" == 1 ]]
[[ "$(wc -l <"$CALLS" | tr -d ' ')" == "$before" ]]
[[ ! -d "${AIDEVOPS_LOG_DIR}/cleanup_worktrees.lock" ]]

# Restore production inventory for the following parser checks.
source "${SCRIPT_DIR}/pulse-cleanup-progress.sh"

# Exercise the production NUL-delimited inventory parser, live remote slug,
# detached candidates, paths with spaces, and local-only repository exclusion.
git() {
	[[ "$*" != *"/hidden"* ]] || exit 1
	case "$*" in
	*"rev-parse --git-dir") printf '.git\n' ;;
	*"remote get-url origin") printf 'git@github.com:owner/live.git\n' ;;
	*"symbolic-ref --short refs/remotes/origin/HEAD") printf 'origin/trunk\n' ;;
	*"worktree list --porcelain -z") printf 'worktree /canonical\0HEAD abc\0branch refs/heads/trunk\0\0worktree /linked path\0HEAD def\0detached\0\0' ;;
	*) return 1 ;;
	esac
	return 0
}
printf '{"initialized_repos":[{"path":"/canonical","slug":"stale/name"},{"path":"/hidden","local_only":true}]}\n' >"${HOME}/.config/aidevops/repos.json"
inventory=$(_pc_progress_jobs "${HOME}/.config/aidevops/repos.json")
jq -es '.[1] == ["orphan","/canonical","owner/live","/linked path","","trunk"] and length == 4' <<<"$inventory" >/dev/null
aliased_inventory=$(_pc_progress_repo_jobs /alias)
jq -es '[.[] | select(.[0] == "orphan") | .[3]] == ["/linked path"]' <<<"$aliased_inventory" >/dev/null

# The API-free fixture pass still executes on every invocation at low quota.
_pc_cleanup_fixture_passes() { printf '1\n'; return 0; }
gh() { printf '99\n'; return 0; }
printf '100\n' >"$CLOCK"
_pc_cleanup_resumable 5
[[ "$CLEANUP_WORKTREES_REMOVED_COUNT" == 1 && "$CLEANUP_WORKTREES_SKIPPED" == 1 ]]

# Real overlapping processes share the asynchronous runner's lock namespace.
gh() { printf '1000\n'; return 0; }
_pc_cleanup_fixture_passes() { printf '0\n'; return 0; }
_pc_progress_jobs() { printf '["merged","one"]\n["merged","two"]\n'; return 0; }
_pc_progress_run_job() {
	printf '%s\n' "$1" >>"${TEST_ROOT}/concurrent-calls"
	: >"${TEST_ROOT}/holder-ready"
	while [[ ! -e "${TEST_ROOT}/holder-release" ]]; do sleep 0.05; done
	return 0
}
_pc_cleanup_resumable 10 &
holder=$!
for ((attempt = 0; attempt < 100; attempt++)); do
	[[ ! -e "${TEST_ROOT}/holder-ready" ]] || break
	sleep 0.05
done
if [[ ! -e "${TEST_ROOT}/holder-ready" ]]; then
	: >"${TEST_ROOT}/holder-release"
	wait "$holder" || true
	printf 'FAIL cleanup holder did not start\n' >&2
	exit 1
fi
before_cursor=$(<"${PULSE_STATE_DIR}/worktree-cleanup-next.json")
concurrency_rc=0
_pc_cleanup_resumable 10 || concurrency_rc=1
[[ "$CLEANUP_WORKTREES_SKIPPED" == 1 ]] || concurrency_rc=1
[[ "$(<"${PULSE_STATE_DIR}/worktree-cleanup-next.json")" == "$before_cursor" ]] || concurrency_rc=1
[[ "$(wc -l <"${TEST_ROOT}/concurrent-calls" | tr -d ' ')" == 1 ]] || concurrency_rc=1
: >"${TEST_ROOT}/holder-release"
wait "$holder" || concurrency_rc=1
[[ "$concurrency_rc" == 0 && ! -d "${AIDEVOPS_LOG_DIR}/cleanup_worktrees.lock" ]]

# After all job mocks, restore the executor and verify real refusal accounting.
source "${SCRIPT_DIR}/pulse-cleanup-progress.sh"
mkdir -p "${TEST_ROOT}/linked path"
_cleanup_single_worktree() {
	[[ "$2" == "${TEST_ROOT}/linked path" ]] || exit 1
	return 1
}
CLEANUP_WORKTREES_REMOVED_COUNT=0
job=$(jq -cn --arg path "${TEST_ROOT}/linked path" '["orphan","/canonical","owner/repo",$path,"","main"]')
_pc_progress_run_job "$job" "${HOME}/.config/aidevops/repos.json"
[[ "$CLEANUP_WORKTREES_REMOVED_COUNT" == 0 ]]

# Owner-write failure rolls back both newly acquired and reclaimed directories.
(
	# shellcheck source=../cleanup-worktrees-lock.sh
	source "${SCRIPT_DIR}/cleanup-worktrees-lock.sh"
	LOCK_DIR="${TEST_ROOT}/owner-write.lock"
	PID_FILE="${LOCK_DIR}/pid"
	_lock_record_owner() { : >"$PID_FILE"; return 1; }
	if _lock_acquire; then exit 1; fi
	[[ ! -d "$LOCK_DIR" ]]
	mkdir "$LOCK_DIR"
	printf '99999999\n' >"$PID_FILE"
	_is_pid_alive() { return 1; }
	if _lock_acquire; then exit 1; fi
	[[ ! -d "$LOCK_DIR" ]]
	# Restore the real owner writer and show that the next invocation succeeds.
	source "${SCRIPT_DIR}/cleanup-worktrees-lock.sh"
	_lock_acquire
	[[ -s "$PID_FILE" ]]
)
[[ ! -d "${TEST_ROOT}/owner-write.lock" ]]
printf 'PASS bounded cleanup fairness, timeout continuation, cursor validation, fail-closed persistence and guard refusal\n'
