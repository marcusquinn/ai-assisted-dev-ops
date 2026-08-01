#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# cleanup-remote-branches-async-helper.sh — Async background remote branch cleanup runner (GH#22415).
#
# Invoked from pulse preflight so remote branch audits and optional safe deletes
# never block dispatch. Default mode is dry-run. Deletion requires the explicit
# AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY=1 opt-in and still delegates safety
# classification to remote-branch-cleanup-helper.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${HOME}/.aidevops/logs"
readonly LOGFILE="${LOG_DIR}/cleanup_remote_branches.log"
readonly LOCK_DIR="${LOG_DIR}/cleanup_remote_branches.lock"
readonly PID_FILE="${LOCK_DIR}/pid"
readonly LAST_RUN_FILE="${LOG_DIR}/cleanup_remote_branches.last-run"

CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN="${CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN:-360}"
CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN="${CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN//[!0-9]/}"
[[ -n "$CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN" ]] || CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN=360

AIDEVOPS_REMOTE_BRANCH_CLEANUP_MIN_GH_REMAINING="${AIDEVOPS_REMOTE_BRANCH_CLEANUP_MIN_GH_REMAINING:-1000}"
AIDEVOPS_REMOTE_BRANCH_CLEANUP_MIN_GH_REMAINING="${AIDEVOPS_REMOTE_BRANCH_CLEANUP_MIN_GH_REMAINING//[!0-9]/}"
[[ -n "$AIDEVOPS_REMOTE_BRANCH_CLEANUP_MIN_GH_REMAINING" ]] || AIDEVOPS_REMOTE_BRANCH_CLEANUP_MIN_GH_REMAINING=1000

mkdir -p "$LOG_DIR"

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	printf '[cleanup-remote-branches-async] ERROR: shared-constants.sh not found at %s\n' "${SCRIPT_DIR}" >>"$LOGFILE"
	exit 1
fi

_lock_release() {
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	return 0
}

_lock_signal_exit() {
	local exit_code="$1"
	trap - EXIT INT TERM
	_lock_release
	exit "$exit_code"
	return 1
}

_lock_install_traps() {
	trap '_lock_release' EXIT
	trap '_lock_signal_exit 130' INT
	trap '_lock_signal_exit 143' TERM
	return 0
}

_is_pid_alive() {
	local pid="$1"
	[[ -z "$pid" ]] && return 1
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1

	if ! kill -0 "$pid" 2>/dev/null; then
		return 1
	fi

	local comm
	comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
	[[ -n "$comm" ]] || return 1
	return 0
}

_lock_acquire() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"$PID_FILE" 2>/dev/null || true
		_lock_install_traps
		return 0
	fi

	if [[ -f "$PID_FILE" ]]; then
		local lock_pid
		IFS= read -r lock_pid <"$PID_FILE" 2>/dev/null || lock_pid=""
		if [[ -n "$lock_pid" ]] && ! _is_pid_alive "$lock_pid"; then
			printf '[cleanup-remote-branches-async] Reclaiming stale lock (PID %s no longer alive)\n' "$lock_pid" >>"$LOGFILE"
			rm -rf "$LOCK_DIR" 2>/dev/null || true
			if mkdir "$LOCK_DIR" 2>/dev/null; then
				printf '%s\n' "$$" >"$PID_FILE" 2>/dev/null || true
				_lock_install_traps
				return 0
			fi
		fi
	fi

	return 1
}

_cadence_ok() {
	if [[ ! -f "$LAST_RUN_FILE" ]]; then
		return 0
	fi

	local last_run now elapsed cadence_secs
	IFS= read -r last_run <"$LAST_RUN_FILE" 2>/dev/null || last_run=""
	if ! [[ "$last_run" =~ ^[0-9]+$ ]]; then
		return 0
	fi

	now=$(date +%s)
	elapsed=$((now - last_run))
	cadence_secs=$((CLEANUP_REMOTE_BRANCHES_ASYNC_CADENCE_MIN * 60))

	if [[ "$elapsed" -lt "$cadence_secs" ]]; then
		printf '[cleanup-remote-branches-async] Cadence gate: last run %ss ago (threshold %ss). Skipping.\n' \
			"$elapsed" "$cadence_secs" >>"$LOGFILE"
		return 1
	fi

	return 0
}

_update_last_run() {
	date +%s >"$LAST_RUN_FILE" 2>/dev/null || true
	return 0
}

_gh_budget_ok() {
	if [[ "${AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_RATE_LIMIT:-0}" == "1" ]]; then
		return 0
	fi
	if [[ "${AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH:-0}" == "1" ]]; then
		return 0
	fi
	if ! command -v gh >/dev/null 2>&1; then
		printf '[cleanup-remote-branches-async] gh unavailable; skipping to avoid unsafe open-PR classification gaps\n' >>"$LOGFILE"
		return 1
	fi

	local remaining_core remaining_graphql min_remaining
	min_remaining="$AIDEVOPS_REMOTE_BRANCH_CLEANUP_MIN_GH_REMAINING"
	remaining_core=$(gh api rate_limit --jq '.resources.core.remaining // 0' 2>/dev/null || printf '0\n')
	remaining_graphql=$(gh api rate_limit --jq '.resources.graphql.remaining // 0' 2>/dev/null || printf '0\n')
	[[ "$remaining_core" =~ ^[0-9]+$ ]] || remaining_core=0
	[[ "$remaining_graphql" =~ ^[0-9]+$ ]] || remaining_graphql=0

	if [[ "$remaining_core" -lt "$min_remaining" || "$remaining_graphql" -lt "$min_remaining" ]]; then
		printf '[cleanup-remote-branches-async] GitHub API budget low (core=%s graphql=%s min=%s); skipping.\n' \
			"$remaining_core" "$remaining_graphql" "$min_remaining" >>"$LOGFILE"
		return 1
	fi

	return 0
}

_repo_paths() {
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" && -x "$(command -v jq 2>/dev/null || true)" ]]; then
		jq -r '.initialized_repos[]? | select(.local_only != true) | (.path // .repo_path // empty)' "$repos_json" 2>/dev/null |
			while IFS= read -r repo_path; do
				[[ -z "$repo_path" ]] && continue
				repo_path="${repo_path/#\~/$HOME}"
				[[ -d "$repo_path/.git" || -f "$repo_path/.git" ]] || continue
				printf '%s\n' "$repo_path"
			done
		return 0
	fi

	if git rev-parse --show-toplevel >/dev/null 2>&1; then
		git rev-parse --show-toplevel
	fi
	return 0
}

_run_cleanup_for_repo() {
	local repo_path="$1"
	local helper="${SCRIPT_DIR}/remote-branch-cleanup-helper.sh"
	local apply_args=()

	if [[ ! -x "$helper" ]]; then
		printf '[cleanup-remote-branches-async] ERROR: helper not executable at %s\n' "$helper" >>"$LOGFILE"
		return 1
	fi

	if [[ "${AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY:-0}" == "1" ]]; then
		apply_args+=(--apply)
	fi
	if [[ "${AIDEVOPS_REMOTE_BRANCH_CLEANUP_INCLUDE_CLOSED_PR:-0}" == "1" ]]; then
		apply_args+=(--include-closed-pr)
	fi

	printf '[cleanup-remote-branches-async] Auditing repo=%s mode=%s\n' \
		"$repo_path" "$([[ "${AIDEVOPS_REMOTE_BRANCH_CLEANUP_APPLY:-0}" == "1" ]] && printf apply || printf dry-run)" >>"$LOGFILE"
	"$helper" --repo "$repo_path" "${apply_args[@]}" >>"$LOGFILE" 2>&1
	return $?
}

main() {
	printf '[cleanup-remote-branches-async] PID=%s starting at %s\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOGFILE"

	if ! _lock_acquire; then
		printf '[cleanup-remote-branches-async] Lock held by live instance — skipping this invocation\n' >>"$LOGFILE"
		return 0
	fi

	if ! _cadence_ok; then
		return 0
	fi

	if ! _gh_budget_ok; then
		return 0
	fi

	local repo_path rc failures scanned
	rc=0
	failures=0
	scanned=0
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" ]] && continue
		scanned=$((scanned + 1))
		if ! _run_cleanup_for_repo "$repo_path"; then
			failures=$((failures + 1))
			rc=1
		fi
	done < <(_repo_paths)

	if [[ "$rc" -eq 0 ]]; then
		_update_last_run
		printf '[cleanup-remote-branches-async] Completed successfully at %s. repos=%s last-run updated.\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$scanned" >>"$LOGFILE"
	else
		printf '[cleanup-remote-branches-async] Completed with failures=%s repos=%s — last-run NOT updated\n' \
			"$failures" "$scanned" >>"$LOGFILE"
	fi

	return 0
}

main "$@"
