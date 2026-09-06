#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared mkdir lock for asynchronous and watchdog-bounded worktree cleanup.
# Caller supplies LOCK_DIR, PID_FILE and LOGFILE; source in a dedicated process
# because acquisition owns EXIT/INT/TERM traps for that process only.

_lock_release() {
	local recorded_pid=""
	[[ -f "${_CLEANUP_LOCK_PID_FILE:-}" ]] || return 0
	recorded_pid=$(<"$_CLEANUP_LOCK_PID_FILE")
	[[ "$recorded_pid" == "${_CLEANUP_LOCK_OWNER_PID:-}" ]] || return 0
	rm -f "$_CLEANUP_LOCK_PID_FILE" 2>/dev/null || true
	rmdir "$_CLEANUP_LOCK_PATH" 2>/dev/null || true
	return 0
}

_lock_signal_exit() {
	local exit_code="$1"
	trap - EXIT INT TERM
	_lock_release
	exit "$exit_code"
}

_lock_install_traps() {
	trap '_lock_release' EXIT
	trap '_lock_signal_exit 130' INT
	trap '_lock_signal_exit 143' TERM
	return 0
}

_is_pid_alive() {
	local pid="$1"
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	# A live PID remains protected when process metadata is unavailable.
	return 0
}

_lock_record_owner() {
	# Match the watchdog's Bash 3.2-compatible executor-PID convention; $$ is
	# the outer cycle PID in a subshell and would strand a killed bounded lock.
	_CLEANUP_LOCK_OWNER_PID="${BASHPID:-}"
	if [[ -z "$_CLEANUP_LOCK_OWNER_PID" ]]; then
		_CLEANUP_LOCK_OWNER_PID="$(exec sh -c 'printf "%s" "$PPID"')" || return 1
	fi
	[[ "$_CLEANUP_LOCK_OWNER_PID" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s\n' "$_CLEANUP_LOCK_OWNER_PID" >"$PID_FILE" || return 1
	# Bash 3.2 unwinds function locals before EXIT on explicit exit paths.
	_CLEANUP_LOCK_PID_FILE="$PID_FILE"
	_CLEANUP_LOCK_PATH="$LOCK_DIR"
	_lock_install_traps
	return 0
}

_lock_finish_acquire() {
	if _lock_record_owner; then
		return 0
	fi
	# This process just created the directory. Never strand an ownerless lock
	# when a PID write fails (for example, during the disk-pressure incident).
	rm -f "$PID_FILE" 2>/dev/null || true
	rmdir "$LOCK_DIR" 2>/dev/null || true
	return 1
}

_lock_acquire() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		_lock_finish_acquire
		return $?
	fi
	if [[ -f "$PID_FILE" ]]; then
		local lock_pid=""
		lock_pid=$(<"$PID_FILE")
		if [[ -n "$lock_pid" ]] && ! _is_pid_alive "$lock_pid"; then
			echo "[cleanup-worktrees] Reclaiming stale lock (PID ${lock_pid} no longer alive)" >>"$LOGFILE"
			rm -rf "$LOCK_DIR" 2>/dev/null || true
			if mkdir "$LOCK_DIR" 2>/dev/null; then
				_lock_finish_acquire
				return $?
			fi
		fi
	fi
	return 1
}
