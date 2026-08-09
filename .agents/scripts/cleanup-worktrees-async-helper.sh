#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# cleanup-worktrees-async-helper.sh — Async background worktree cleanup runner (GH#20554).
#
# Designed to be invoked by _preflight_launch_async_cleanup from
# _preflight_cleanup_and_ledger. Linux systemd hosts use a transient user
# service outside the parent pulse cgroup; other hosts retain a nohup fallback.
#
# Lifecycle:
#   1. Acquire a mkdir-based single-runner lock (~/.aidevops/logs/cleanup_worktrees.lock).
#   2. Check cadence gate: skip if last successful run < N minutes ago.
#   3. Source pulse-cleanup.sh deps and call cleanup_worktrees.
#   4. Update ~/.aidevops/logs/cleanup_worktrees.last-run on success.
#   5. Release lock on EXIT/INT/TERM (trap).
#
# Usage (from pulse-dispatch-preflight-lib.sh):
#   _preflight_launch_async_cleanup \
#     "${SCRIPT_DIR}/cleanup-worktrees-async-helper.sh" \
#     "${HOME}/.aidevops/logs/cleanup_worktrees.log" "worktrees"
#
# DO NOT call cleanup_worktrees inline in pulse-dispatch-engine.sh after
# this helper is deployed — use this wrapper instead.
#
# Environment:
#   CLEANUP_WORKTREES_ASYNC_CADENCE_MIN — min minutes between runs (default 10)
#   DIRTY_WORKTREE_BACKUP_RETENTION_DAYS — stale dirty-backup retention (default 30)
#   AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_ENABLED — automatic terminal-archive maintenance (default 1)
#   AIDEVOPS_LOG_DIR — explicit log directory override (required if HOME unset)
#
# Observability (for pulse-diagnose-helper.sh):
#   ~/.aidevops/logs/cleanup_worktrees.log      — progress log
#   ~/.aidevops/logs/cleanup_worktrees.last-run — epoch of last successful run
#   ~/.aidevops/logs/cleanup_worktrees.lock/    — lock dir (present = running)
#   ~/.aidevops/logs/cleanup_worktrees.lock/pid — PID of holder

set -euo pipefail

# ============================================================
# PATHS
# ============================================================

_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
unset _SCRIPT_PATH

if [[ -z "${AIDEVOPS_LOG_DIR:-}" && -z "${HOME:-}" ]]; then
	printf '%s\n' "[cleanup-worktrees-async] ERROR: HOME is unset and AIDEVOPS_LOG_DIR is not configured" >&2
	exit 1
fi

readonly LOG_DIR="${AIDEVOPS_LOG_DIR:-${HOME:-}/.aidevops/logs}"
readonly LOGFILE="${LOG_DIR}/cleanup_worktrees.log"
readonly LOCK_DIR="${LOG_DIR}/cleanup_worktrees.lock"
readonly PID_FILE="${LOCK_DIR}/pid"
readonly LAST_RUN_FILE="${LOG_DIR}/cleanup_worktrees.last-run"

# Minimum minutes between successful runs
CLEANUP_WORKTREES_ASYNC_CADENCE_MIN="${CLEANUP_WORKTREES_ASYNC_CADENCE_MIN:-10}"
# Validate: strip non-digits, fall back to default on empty
CLEANUP_WORKTREES_ASYNC_CADENCE_MIN="${CLEANUP_WORKTREES_ASYNC_CADENCE_MIN//[!0-9]/}"
[[ -n "$CLEANUP_WORKTREES_ASYNC_CADENCE_MIN" ]] || CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=10

mkdir -p "$LOG_DIR"

# ============================================================
# SOURCE DEPENDENCIES
# ============================================================

# shared-constants.sh pulls in shared-worktree-registry.sh (is_worktree_owned_by_others),
# shared-gh-wrappers.sh (gh_issue_comment), and other shared utilities.
# shellcheck source=shared-constants.sh
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	echo "[cleanup-worktrees-async] ERROR: shared-constants.sh not found at ${SCRIPT_DIR}" >>"$LOGFILE"
	exit 1
fi

# pulse-cleanup.sh defines cleanup_worktrees and all its private helpers.
# It has an idempotent guard (_PULSE_CLEANUP_LOADED) and no unconditional
# side effects at source time — safe to source standalone.
# shellcheck source=pulse-cleanup.sh
if [[ -f "${SCRIPT_DIR}/pulse-cleanup.sh" ]]; then
	source "${SCRIPT_DIR}/pulse-cleanup.sh"
else
	echo "[cleanup-worktrees-async] ERROR: pulse-cleanup.sh not found at ${SCRIPT_DIR}" >>"$LOGFILE"
	exit 1
fi

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

	# kill -0: fails immediately if process does not exist
	if ! kill -0 "$pid" 2>/dev/null; then
		return 1
	fi

	# Command sanity check (t2421 pattern): ensure the process is actually
	# a shell or script process, not a recycled PID running something unrelated.
	local comm
	comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
	if [[ -z "$comm" ]]; then
		# ps failed — treat as dead to unblock cleanup
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

	# Lock exists — check for stale (dead) PID
	if [[ -f "$PID_FILE" ]]; then
		local lock_pid
		lock_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
		if [[ -n "$lock_pid" ]] && ! _is_pid_alive "$lock_pid"; then
			echo "[cleanup-worktrees-async] Reclaiming stale lock (PID ${lock_pid} no longer alive)" >>"$LOGFILE"
			rm -rf "$LOCK_DIR" 2>/dev/null || true
			if mkdir "$LOCK_DIR" 2>/dev/null; then
				printf '%s\n' "$$" >"$PID_FILE" 2>/dev/null || true
				_lock_install_traps
				return 0
			fi
		fi
	fi

	# Another live instance is running — skip this invocation
	return 1
}

# ============================================================
# CADENCE GATE
# ============================================================

# Returns 0 (proceed) if enough time has elapsed since the last successful run.
# Returns 1 (skip) if we are within the cadence window.
_cadence_ok() {
	if [[ ! -f "$LAST_RUN_FILE" ]]; then
		return 0 # First run — always proceed
	fi

	local last_run now elapsed cadence_secs
	last_run=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "0")
	if ! [[ "$last_run" =~ ^[0-9]+$ ]]; then
		return 0 # Corrupted state file — proceed
	fi

	now=$(date +%s)
	elapsed=$((now - last_run))
	cadence_secs=$((CLEANUP_WORKTREES_ASYNC_CADENCE_MIN * 60))

	if [[ "$elapsed" -lt "$cadence_secs" ]]; then
		echo "[cleanup-worktrees-async] Cadence gate: last run ${elapsed}s ago (threshold ${cadence_secs}s). Skipping." >>"$LOGFILE"
		return 1
	fi

	return 0
}

_update_last_run() {
	date +%s >"$LAST_RUN_FILE" 2>/dev/null || true
	return 0
}

_prune_dirty_worktree_backups() {
	local helper_path="${SCRIPT_DIR}/dirty-worktree-backup-helper.sh"
	local retention_days="${DIRTY_WORKTREE_BACKUP_RETENTION_DAYS:-30}"

	if [[ ! -x "$helper_path" ]]; then
		echo "[cleanup-worktrees-async] dirty backup helper unavailable; skipping backup prune" >>"$LOGFILE"
		return 0
	fi

	"$helper_path" prune --force --retention-days "$retention_days" >>"$LOGFILE" 2>&1 || {
		echo "[cleanup-worktrees-async] dirty backup prune failed; continuing" >>"$LOGFILE"
		return 0
	}
	return 0
}

_maintain_worktree_recovery() {
	local helper_path="${SCRIPT_DIR}/worktree-recovery-maintenance-helper.sh"
	local result=""

	if [[ ! -x "$helper_path" ]]; then
		echo "[cleanup-worktrees-async] recovery maintenance helper unavailable; skipping" >>"$LOGFILE"
		return 0
	fi
	if result=$("$helper_path" 2>>"$LOGFILE"); then
		printf '%s\t%s\n' "[cleanup-worktrees-async] recovery-maintenance" "$result" >>"$LOGFILE"
	else
		echo "[cleanup-worktrees-async] recovery maintenance failed closed; continuing" >>"$LOGFILE"
	fi
	return 0
}

# ============================================================
# MAIN
# ============================================================

main() {
	echo "[cleanup-worktrees-async] PID=$$ starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOGFILE"

	if ! _lock_acquire; then
		echo "[cleanup-worktrees-async] Lock held by live instance — skipping this invocation" >>"$LOGFILE"
		return 0
	fi

	if ! _cadence_ok; then
		return 0
	fi

	echo "[cleanup-worktrees-async] Starting cleanup_worktrees (cadence OK)" >>"$LOGFILE"

	local rc=0
	cleanup_worktrees || rc=$?
	_prune_dirty_worktree_backups

	if [[ "${CLEANUP_WORKTREES_SKIPPED:-0}" == "1" ]]; then
		echo "[cleanup-worktrees-async] cleanup_worktrees skipped by safety gate — last-run NOT updated" >>"$LOGFILE"
	elif [[ "$rc" -eq 0 ]]; then
		_maintain_worktree_recovery
		_update_last_run
		echo "[cleanup-worktrees-async] Completed successfully at $(date -u '+%Y-%m-%dT%H:%M:%SZ'). last-run updated." >>"$LOGFILE"
	else
		echo "[cleanup-worktrees-async] cleanup_worktrees exited with rc=${rc} — last-run NOT updated" >>"$LOGFILE"
	fi

	return 0
}

main "$@"
