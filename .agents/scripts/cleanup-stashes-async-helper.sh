#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# cleanup-stashes-async-helper.sh — Async background stash cleanup runner (GH#21997).
#
# Designed to be invoked via nohup from _preflight_cleanup_and_ledger so slow
# stash auditing, including any GitHub API calls made by stash-audit-helper.sh,
# never blocks the pulse's early dispatch path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${HOME}/.aidevops/logs"
readonly LOGFILE="${LOG_DIR}/cleanup_stashes.log"
readonly LOCK_DIR="${LOG_DIR}/cleanup_stashes.lock"
readonly PID_FILE="${LOCK_DIR}/pid"
readonly LAST_RUN_FILE="${LOG_DIR}/cleanup_stashes.last-run"

CLEANUP_STASHES_ASYNC_CADENCE_MIN="${CLEANUP_STASHES_ASYNC_CADENCE_MIN:-10}"
CLEANUP_STASHES_ASYNC_CADENCE_MIN="${CLEANUP_STASHES_ASYNC_CADENCE_MIN//[!0-9]/}"
[[ -n "$CLEANUP_STASHES_ASYNC_CADENCE_MIN" ]] || CLEANUP_STASHES_ASYNC_CADENCE_MIN=10

mkdir -p "$LOG_DIR"

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	printf '[cleanup-stashes-async] ERROR: shared-constants.sh not found at %s\n' "${SCRIPT_DIR}" >>"$LOGFILE"
	exit 1
fi

if [[ -f "${SCRIPT_DIR}/pulse-cleanup.sh" ]]; then
	# shellcheck source=pulse-cleanup.sh
	source "${SCRIPT_DIR}/pulse-cleanup.sh"
else
	printf '[cleanup-stashes-async] ERROR: pulse-cleanup.sh not found at %s\n' "${SCRIPT_DIR}" >>"$LOGFILE"
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
			printf '[cleanup-stashes-async] Reclaiming stale lock (PID %s no longer alive)\n' "$lock_pid" >>"$LOGFILE"
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
	cadence_secs=$((CLEANUP_STASHES_ASYNC_CADENCE_MIN * 60))

	if [[ "$elapsed" -lt "$cadence_secs" ]]; then
		printf '[cleanup-stashes-async] Cadence gate: last run %ss ago (threshold %ss). Skipping.\n' \
			"$elapsed" "$cadence_secs" >>"$LOGFILE"
		return 1
	fi

	return 0
}

_update_last_run() {
	date +%s >"$LAST_RUN_FILE" 2>/dev/null || true
	return 0
}

main() {
	printf '[cleanup-stashes-async] PID=%s starting at %s\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOGFILE"

	if ! _lock_acquire; then
		printf '[cleanup-stashes-async] Lock held by live instance — skipping this invocation\n' >>"$LOGFILE"
		return 0
	fi

	if ! _cadence_ok; then
		return 0
	fi

	printf '[cleanup-stashes-async] Starting cleanup_stashes (cadence OK)\n' >>"$LOGFILE"

	local rc=0
	cleanup_stashes || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		_update_last_run
		printf '[cleanup-stashes-async] Completed successfully at %s. last-run updated.\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOGFILE"
	else
		printf '[cleanup-stashes-async] cleanup_stashes exited with rc=%s — last-run NOT updated\n' "$rc" >>"$LOGFILE"
	fi

	return 0
}

main "$@"
