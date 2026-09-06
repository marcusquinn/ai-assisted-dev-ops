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
if [[ -f "${SCRIPT_DIR}/audit-worktree-removal-helper.sh" ]]; then
	# shellcheck source=audit-worktree-removal-helper.sh
	source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
fi

# ============================================================
# LOCK MANAGEMENT (mkdir-based — POSIX atomic, macOS-safe)
# ============================================================

# shellcheck source=cleanup-worktrees-lock.sh
source "${SCRIPT_DIR}/cleanup-worktrees-lock.sh"

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

_reconcile_worktree_registry() {
	if ! declare -F prune_worktree_registry >/dev/null 2>&1; then
		echo "[cleanup-worktrees-async] registry prune unavailable; skipping reconciliation" >>"$LOGFILE"
		return 0
	fi
	if ! prune_worktree_registry >>"$LOGFILE" 2>&1; then
		echo "[cleanup-worktrees-async] registry reconciliation failed closed; continuing guarded cleanup" >>"$LOGFILE"
		return 0
	fi
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

_prune_current_repo_missing_worktree_metadata() {
	local repo_context=""
	local field=""
	local wt_path=""
	local prunable_path=""

	declare -F prune_missing_worktree_metadata >/dev/null 2>&1 || return 0
	command -v git >/dev/null 2>&1 || return 0
	repo_context=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
	[[ -n "$repo_context" && -d "$repo_context" ]] || return 0

	while IFS= read -r -d '' field; do
		case "$field" in
		worktree\ *)
			wt_path="${field#worktree }"
			;;
		prunable\ *)
			if [[ -n "$wt_path" && ! -e "$wt_path" ]]; then
				prunable_path="$wt_path"
				break
			fi
			;;
		"")
			wt_path=""
			;;
		esac
	done < <(git -C "$repo_context" worktree list --porcelain -z 2>/dev/null || true)

	[[ -n "$prunable_path" ]] || return 0
	if prune_missing_worktree_metadata "$repo_context" "$prunable_path"; then
		echo "[cleanup-worktrees-async] pruned missing worktree metadata from current repo" >>"$LOGFILE"
	else
		echo "[cleanup-worktrees-async] missing worktree metadata prune failed closed; continuing" >>"$LOGFILE"
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
	_reconcile_worktree_registry

	local rc=0
	local outcome="success"
	local removed_count="0"
	local archived_count="0"
	local archive_failed_count="0"
	cleanup_worktrees || rc=$?
	_prune_dirty_worktree_backups

	if [[ "${CLEANUP_WORKTREES_SKIPPED:-0}" == "1" ]]; then
		outcome="safety-skip"
		echo "[cleanup-worktrees-async] cleanup_worktrees skipped by safety gate — last-run NOT updated" >>"$LOGFILE"
	elif [[ "$rc" -eq 0 ]]; then
		_prune_current_repo_missing_worktree_metadata
		_maintain_worktree_recovery
		_update_last_run
		echo "[cleanup-worktrees-async] Completed successfully at $(date -u '+%Y-%m-%dT%H:%M:%SZ'). last-run updated." >>"$LOGFILE"
	else
		outcome="failed"
		echo "[cleanup-worktrees-async] cleanup_worktrees exited with rc=${rc} — last-run NOT updated" >>"$LOGFILE"
	fi
	removed_count="${CLEANUP_WORKTREES_REMOVED_COUNT:-0}"
	archived_count="${CLEANUP_WORKTREES_ARCHIVED_COUNT:-0}"
	archive_failed_count="${CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT:-0}"
	[[ "$removed_count" =~ ^[0-9]+$ ]] || removed_count=0
	[[ "$archived_count" =~ ^[0-9]+$ ]] || archived_count=0
	[[ "$archive_failed_count" =~ ^[0-9]+$ ]] || archive_failed_count=0
	printf '%s\n' "[cleanup-worktrees-async] outcome=${outcome} removed=${removed_count} archived=${archived_count} archive_failed=${archive_failed_count}" >>"$LOGFILE"

	return 0
}

main "$@"
