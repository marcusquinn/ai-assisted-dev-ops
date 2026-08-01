#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# opencode-db-archive-async-helper.sh — Async background OpenCode DB archive runner (GH#21105).
#
# Designed to be invoked by the dedicated opencode-db-archive scheduler
# installed by setup_opencode_db_archive, so archive/VACUUM work stays outside
# the pulse dispatch preflight path.
#
# Background (GH#21105):
#   The synchronous call `opencode-db-archive.sh archive --max-duration-seconds 30`
#   was consuming its full 30s time budget every preflight cycle, contributing
#   ~30s to the parent stage's 60-133s total. GH#25136 moved the async trigger
#   out of pulse preflight entirely. Archiving is catch-up work, not dispatch
#   work; this helper preserves the single-runner lock for the dedicated
#   scheduler while leaving cadence control to systemd/launchd/cron.
#
# Lifecycle:
#   1. Acquire a mkdir-based single-runner lock (~/.aidevops/logs/opencode-db-archive.lock).
#   2. Invoke opencode-db-archive.sh archive with the configured budget.
#   3. Update ~/.aidevops/logs/opencode-db-archive.last-run on success.
#   4. Release lock on EXIT/INT/TERM (trap).
#
# Usage (normally installed by setup.sh):
#   opencode-db-archive-async-helper.sh
#
# Environment:
#   OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC  — seconds per run (default 60; was 30 inline)
#
# Observability (for pulse-diagnose-helper.sh):
#   ~/.aidevops/logs/opencode-db-archive.log      — progress log
#   ~/.aidevops/logs/opencode-db-archive.last-run — epoch of last successful run
#   ~/.aidevops/logs/opencode-db-archive.lock/    — lock dir (present = running)
#   ~/.aidevops/logs/opencode-db-archive.lock/pid — PID of holder

set -euo pipefail

# ============================================================
# PATHS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${HOME}/.aidevops/logs"
readonly LOGFILE="${LOG_DIR}/opencode-db-archive.log"
readonly LOCK_DIR="${LOG_DIR}/opencode-db-archive.lock"
readonly PID_FILE="${LOCK_DIR}/pid"
readonly LAST_RUN_FILE="${LOG_DIR}/opencode-db-archive.last-run"
readonly ARCHIVE_HELPER="${SCRIPT_DIR}/opencode-db-archive.sh"

# Per-run time budget. Larger than the inline 30s default — async runs are not
# on the critical path, so we let each invocation make more progress.
OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC="${OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC:-60}"
OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC="${OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC//[!0-9]/}"
[[ -n "$OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC" ]] || OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC=60

mkdir -p "$LOG_DIR"

# ============================================================
# LOCK MANAGEMENT (mkdir-based — POSIX atomic, macOS-safe)
# ============================================================

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

# Check whether the PID that holds the lock is still alive.
# Uses kill -0 (existence) + ps comm= (command-aware, guards against PID reuse).
# Returns 0 if alive, 1 if dead or indeterminate.
_is_pid_alive() {
	local pid="$1"
	[[ -z "$pid" ]] && return 1
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1

	if ! kill -0 "$pid" 2>/dev/null; then
		return 1
	fi

	local comm
	comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
	if [[ -z "$comm" ]]; then
		return 1
	fi

	return 0
}

# Attempt to acquire the lock directory. On success, writes PID file and
# registers a trap. Returns 1 (skip this run) if another live instance holds
# the lock. Reclaims the lock if the holder PID is dead (crash recovery).
_lock_acquire() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"$PID_FILE" 2>/dev/null || true
		_lock_install_traps
		return 0
	fi

	if [[ -f "$PID_FILE" ]]; then
		local lock_pid
		lock_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
		if [[ -n "$lock_pid" ]] && ! _is_pid_alive "$lock_pid"; then
			echo "[opencode-db-archive-async] Reclaiming stale lock (PID ${lock_pid} no longer alive)" >>"$LOGFILE"
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

_update_last_run() {
	date +%s >"$LAST_RUN_FILE" 2>/dev/null || true
	return 0
}

# ============================================================
# MAIN
# ============================================================

main() {
	echo "[opencode-db-archive-async] PID=$$ starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOGFILE"

	if [[ ! -x "$ARCHIVE_HELPER" ]]; then
		echo "[opencode-db-archive-async] ERROR: $ARCHIVE_HELPER not found or not executable — skipping" >>"$LOGFILE"
		return 0
	fi

	if ! _lock_acquire; then
		echo "[opencode-db-archive-async] Lock held by live instance — skipping this invocation" >>"$LOGFILE"
		return 0
	fi

	echo "[opencode-db-archive-async] Starting archive (budget=${OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC}s)" >>"$LOGFILE"

	local rc=0
	"$ARCHIVE_HELPER" archive --max-duration-seconds "$OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC" >>"$LOGFILE" 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		_update_last_run
		echo "[opencode-db-archive-async] Completed successfully at $(date -u '+%Y-%m-%dT%H:%M:%SZ'). last-run updated." >>"$LOGFILE"
	elif [[ "$rc" -eq 2 ]]; then
		echo "[opencode-db-archive-async] Protected skip: active holder, changing WAL, or incomplete checkpoint evidence — last-run NOT updated" >>"$LOGFILE"
	elif [[ "$rc" -eq 3 ]]; then
		echo "[opencode-db-archive-async] Unsupported OpenCode schema — active data left untouched and last-run NOT updated" >>"$LOGFILE"
	else
		echo "[opencode-db-archive-async] archive exited with rc=${rc} — last-run NOT updated" >>"$LOGFILE"
	fi

	return 0
}

main "$@"
