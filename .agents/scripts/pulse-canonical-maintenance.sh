#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-canonical-maintenance.sh — Periodic canonical diagnostics and stale worktree sweep.
#
# GH#19949: consolidated pulse stage combining two housekeeping tasks:
#   1. Diagnose canonical repos that differ from origin/main without modifying them
#   2. Sweep stale worktrees whose branches are merged or PRs are closed
#
# Cadence: ~30 min (1800s), not per-cycle. Both operations are deterministic
# and safe — fail-open on dirty trees, skip on active sessions, per-repo timeout.
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _canonical_maintenance_run_with_timeout
#   - _canonical_maintenance_check_cadence
#   - _canonical_maintenance_has_active_session
#   - _canonical_maintenance_audit_log
#   - _canonical_ff_should_skip_repo
#   - _canonical_ff_single_repo
#   - _canonical_fast_forward
#   - _stale_worktree_sweep_single_repo
#   - _stale_worktree_sweep
#   - run_canonical_maintenance

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_CANONICAL_MAINTENANCE_LOADED:-}" ]] && return 0
_PULSE_CANONICAL_MAINTENANCE_LOADED=1

# Source canonical-guard-helper.sh for assert_git_available / is_registered_canonical
# (t2559 Layer 3 — fail-loud when git is missing from PATH before any cleanup).
# Guard missing-file so older deployments that lack the helper fail open.
_PULSE_CM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || _PULSE_CM_SCRIPT_DIR=""
if [[ -n "$_PULSE_CM_SCRIPT_DIR" && -f "$_PULSE_CM_SCRIPT_DIR/canonical-guard-helper.sh" ]]; then
	# shellcheck source=/dev/null
	source "$_PULSE_CM_SCRIPT_DIR/canonical-guard-helper.sh"
fi
unset _PULSE_CM_SCRIPT_DIR

# ---------------------------------------------------------------------------
# _canonical_maintenance_run_with_timeout
#
# Runs a command with a timeout, falling back to running directly if the
# `timeout` utility is not available (common on stock macOS without coreutils).
# Arguments: $1 - timeout_seconds, $2.. - command and args
# ---------------------------------------------------------------------------
_canonical_maintenance_run_with_timeout() {
	local timeout_seconds="$1"
	shift
	if command -v timeout &>/dev/null; then
		timeout "$timeout_seconds" "$@"
	else
		"$@"
	fi
	return $?
}

# ---------------------------------------------------------------------------
# Configuration constants (overridable via env)
# ---------------------------------------------------------------------------
CANONICAL_MAINTENANCE_CADENCE="${CANONICAL_MAINTENANCE_CADENCE:-1800}"       # 30 min
CANONICAL_MAINTENANCE_LAST_RUN="${CANONICAL_MAINTENANCE_LAST_RUN:-${HOME}/.aidevops/.agent-workspace/pulse-canonical-maintenance-last-run}"
CANONICAL_MAINTENANCE_TIMEOUT="${CANONICAL_MAINTENANCE_TIMEOUT:-60}"         # 60s per-repo hard timeout
CANONICAL_MAINTENANCE_CLAIM_STAMP_DIR="${CANONICAL_MAINTENANCE_CLAIM_STAMP_DIR:-${HOME}/.aidevops/.agent-workspace/interactive-claims}"

# ---------------------------------------------------------------------------
# _get_default_branch_for_repo
#
# Detect the default remote branch for a repo by reading the remote HEAD
# symbolic ref. This avoids hardcoding "main" and prevents
# `fatal: ambiguous argument 'origin/main'` errors on repos that use a
# different default branch (master, develop, etc.) or that have not had
# `git remote set-head origin --auto` run.
#
# Arguments: $1 - repo_path (absolute path to a git checkout)
# Outputs: branch name (e.g. "main", "master") on stdout
# Returns: 0 on success, 1 if the remote HEAD symbolic ref is not set
#          (caller should skip and log instead of assuming a branch name)
# ---------------------------------------------------------------------------
_get_default_branch_for_repo() {
	local repo_path="$1"
	local default_ref
	default_ref=$(git -C "$repo_path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
	[[ -n "$default_ref" ]] || return 1
	printf '%s\n' "${default_ref#origin/}"
	return 0
}

# ---------------------------------------------------------------------------
# _canonical_maintenance_check_cadence
#
# Returns 0 if enough time has elapsed since the last run, 1 otherwise.
# Arguments: $1 - now_epoch (current epoch seconds)
# ---------------------------------------------------------------------------
_canonical_maintenance_check_cadence() {
	local now_epoch="$1"
	if [[ ! -f "$CANONICAL_MAINTENANCE_LAST_RUN" ]]; then
		return 0
	fi
	local last_run
	last_run=$(cat "$CANONICAL_MAINTENANCE_LAST_RUN" 2>/dev/null || echo "0")
	[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
	local elapsed=$((now_epoch - last_run))
	if [[ "$elapsed" -lt "$CANONICAL_MAINTENANCE_CADENCE" ]]; then
		local remaining_min=$(((CANONICAL_MAINTENANCE_CADENCE - elapsed) / 60))
		echo "[pulse-canonical-maintenance] Not due yet (${remaining_min}m remaining)" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _canonical_maintenance_has_active_session
#
# Check whether a repo has an active interactive session claim stamp.
# Arguments: $1 - repo_path
# Returns: 0 if an active session is detected (skip this repo), 1 if safe.
# ---------------------------------------------------------------------------
_canonical_maintenance_has_active_session() {
	local repo_path="$1"
	local stamp_dir="$CANONICAL_MAINTENANCE_CLAIM_STAMP_DIR"
	[[ -d "$stamp_dir" ]] || return 1

	local stamp
	for stamp in "$stamp_dir"/*.json; do
		[[ -f "$stamp" ]] || continue
		local stamp_worktree=""
		stamp_worktree=$(jq -r '.worktree // ""' "$stamp" 2>/dev/null) || continue
		if [[ -n "$stamp_worktree" ]] && [[ "$stamp_worktree" == "$repo_path"* ]]; then
			local stamp_pid=""
			stamp_pid=$(jq -r '.pid // ""' "$stamp" 2>/dev/null) || continue
			# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse.
			local stamp_hash=""
			stamp_hash=$(jq -r '.owner_argv_hash // empty' "$stamp" 2>/dev/null || echo "")
			if [[ -n "$stamp_pid" ]] && [[ "$stamp_pid" =~ ^[0-9]+$ ]] && \
			   _is_process_alive_and_matches "$stamp_pid" "${WORKER_PROCESS_PATTERN:-}" "$stamp_hash"; then
				return 0
			fi
		fi
	done
	return 1
}

# ---------------------------------------------------------------------------
# _canonical_maintenance_audit_log
#
# Emit an audit log entry if the helper is available.
# Arguments: $1 - message
# ---------------------------------------------------------------------------
_canonical_maintenance_audit_log() {
	local message="$1"
	local _audit_helper="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}/audit-log-helper.sh"
	[[ -x "$_audit_helper" ]] && "$_audit_helper" log config.change "$message" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# _canonical_ff_should_skip_repo
#
# Pre-flight checks for a single repo. Returns 0 if the repo should be
# skipped, 1 if it's safe to fast-forward. Prints skip reason to LOGFILE.
# Arguments: $1 - repo_path
# ---------------------------------------------------------------------------
_canonical_ff_should_skip_repo() {
	local repo_path="$1"

	# Skip if dirty tree
	local porcelain_output=""
	porcelain_output=$(git -C "$repo_path" status --porcelain 2>/dev/null) || return 0
	if [[ -n "$porcelain_output" ]]; then
		echo "[pulse-canonical-maintenance] Skipping ${repo_path} — dirty tree" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	# Skip if non-empty stash
	local stash_output=""
	stash_output=$(git -C "$repo_path" stash list 2>/dev/null) || stash_output=""
	if [[ -n "$stash_output" ]]; then
		echo "[pulse-canonical-maintenance] Skipping ${repo_path} — non-empty stash" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	# Skip if active session
	if _canonical_maintenance_has_active_session "$repo_path"; then
		echo "[pulse-canonical-maintenance] Skipping ${repo_path} — active session detected" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	# Skip if remote HEAD is not set — we cannot determine the default branch
	# safely, so skip rather than assume "main" and risk a fatal: ambiguous
	# argument error if origin/main does not exist in this repo.
	local main_branch
	if ! main_branch=$(_get_default_branch_for_repo "$repo_path"); then
		echo "[pulse-canonical-maintenance] Skipping ${repo_path} — no origin/HEAD set (run 'git remote set-head origin --auto')" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	# Skip if not on the default branch
	local current_branch
	current_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null) || current_branch=""
	if [[ "$current_branch" != "$main_branch" ]]; then
		echo "[pulse-canonical-maintenance] Skipping ${repo_path} — not on ${main_branch} (on ${current_branch})" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	# All checks passed — do not skip
	return 1
}

# ---------------------------------------------------------------------------
# _canonical_ff_single_repo
#
# Fast-forward a single repo. Called from the per-repo loop in
# _canonical_fast_forward. Returns 0=fast-forwarded, 1=skipped/failed.
# Arguments: $1 - repo_path, $2 - dry_run ("1" or "0")
# ---------------------------------------------------------------------------
_canonical_ff_single_repo() {
	local repo_path="$1"
	local dry_run="$2"

	# Determine default branch — skip rather than assume if origin/HEAD is not set.
	local main_branch
	if ! main_branch=$(_get_default_branch_for_repo "$repo_path"); then
		echo "[pulse-canonical-maintenance] Skipping ${repo_path} — no origin/HEAD set" >>"${LOGFILE:-/dev/null}"
		return 1
	fi

	# Human canonical checkouts are diagnostic-only. Query the remote without
	# updating refs, HEAD, index, tracked files, or untracked files.
	if [[ "$dry_run" == "1" ]]; then
		echo "[DRY_RUN] Would diagnose origin for ${repo_path}"
	else
		local remote_sha=""
		remote_sha=$(_canonical_maintenance_run_with_timeout "$CANONICAL_MAINTENANCE_TIMEOUT" git -C "$repo_path" ls-remote origin "refs/heads/${main_branch}" 2>/dev/null | awk 'NR == 1 {print $1}') || {
			echo "[pulse-canonical-maintenance] Remote diagnostic failed/timed out for ${repo_path}" >>"${LOGFILE:-/dev/null}"
			return 1
		}
		if [[ -z "$remote_sha" ]]; then
			echo "[pulse-canonical-maintenance] Skipping ${repo_path} — remote ${main_branch} not found" >>"${LOGFILE:-/dev/null}"
			return 1
		fi
		local local_sha=""
		local_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)
		if [[ "$local_sha" == "$remote_sha" ]]; then
			echo "[pulse-canonical-maintenance] ${repo_path} — already up to date" >>"${LOGFILE:-/dev/null}"
			return 1
		fi
		echo "[pulse-canonical-maintenance] Diagnostic: ${repo_path} differs from origin/${main_branch}; human checkout left unchanged" >>"${LOGFILE:-/dev/null}"
		return 0
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _canonical_fast_forward
#
# For each maintained repository, run the remote diagnostic pass. Safety
# worktree cleanup below deliberately keeps a broader all-registered scope.
# checks and fast-forward if behind origin.
# Arguments: $1 - dry_run ("1" for dry run, "0" for real)
# Returns: 0 always (fail-open per repo)
# ---------------------------------------------------------------------------
_canonical_fast_forward() {
	local dry_run="${1:-0}"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	[[ -f "$repos_json" ]] && command -v jq &>/dev/null || return 0

	local -a _repo_list=()
	mapfile -t _repo_list < <(jq -r '.initialized_repos[] | select(.maintenance != false) | select((.pulse // false) == true) | select((.local_only // false) == false) | .path // ""' "$repos_json" 2>/dev/null)

	local repo_path ff_count=0 skip_count=0
	for repo_path in "${_repo_list[@]}"; do
		[[ -z "$repo_path" ]] && continue
		[[ ! -d "$repo_path/.git" ]] && continue

		if _canonical_ff_should_skip_repo "$repo_path"; then
			skip_count=$((skip_count + 1))
			continue
		fi

		if _canonical_ff_single_repo "$repo_path" "$dry_run"; then
			ff_count=$((ff_count + 1))
		fi
	done

	echo "[pulse-canonical-maintenance] Diagnostic pass: ${ff_count} repos stale/diverged, ${skip_count} skipped" >>"${LOGFILE:-/dev/null}"
	return 0
}

# ---------------------------------------------------------------------------
# _stale_worktree_sweep_single_repo
#
# Sweep stale worktrees for a single repo.
# Arguments: $1 - repo_path, $2 - dry_run, $3 - worktree_helper path
# Outputs: number of removed worktrees to stdout
# Returns: 0 always
# ---------------------------------------------------------------------------
_stale_worktree_sweep_single_repo() {
	local repo_path="$1"
	local dry_run="$2"
	local worktree_helper="$3"
	local _wt_prefix="^worktree "

	if [[ "$dry_run" == "1" ]]; then
		local wt_count=0
		wt_count=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null | safe_grep_count "$_wt_prefix")
		[[ "$wt_count" -gt 0 ]] && wt_count=$((wt_count - 1))
		echo "[DRY_RUN] Would sweep worktrees for ${repo_path} (${wt_count} linked worktrees)"
		printf '0'
		return 0
	fi

	local before_count=0
	before_count=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null | safe_grep_count "$_wt_prefix")

	# t2559: redirect worktree-helper.sh clean stdout to the logfile. Previously
	# the colored "Checking for worktrees..." banner and "Removing ..." table
	# leaked into the captured output of this function, concatenated with the
	# `printf '%d' "$removed"` at the end, and poisoned the caller's arithmetic
	# (see _stale_worktree_sweep). That was the ANSI-bleed half of the 2026-04-20
	# canonical-trash incident. Route output to the logfile instead of /dev/null
	# so operators can still diagnose sweep failures.
	local sweep_rc=0
	(
		cd -- "$repo_path" || exit 125
		_canonical_maintenance_run_with_timeout "$CANONICAL_MAINTENANCE_TIMEOUT" "$worktree_helper" clean --auto --force-merged
	) >>"${LOGFILE:-/dev/null}" 2>&1 || sweep_rc=$?
	if [[ "$sweep_rc" -ne 0 ]]; then
		if [[ "$sweep_rc" -eq 124 ]]; then
			echo "[pulse-canonical-maintenance] Worktree sweep timed out for ${repo_path}" >>"${LOGFILE:-/dev/null}"
		else
			echo "[pulse-canonical-maintenance] Worktree sweep skipped for ${repo_path} (helper exited ${sweep_rc})" >>"${LOGFILE:-/dev/null}"
		fi
		printf '0'
		return 0
	fi

	local after_count=0
	after_count=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null | safe_grep_count "$_wt_prefix")
	# Sanitise both sides of the arithmetic — either git output or grep -c can
	# return unexpected strings under hostile conditions; without this guard a
	# malformed count would crash the pulse with set -e.
	before_count="${before_count//[^0-9]/}"
	after_count="${after_count//[^0-9]/}"
	before_count="${before_count:-0}"
	after_count="${after_count:-0}"
	local removed=$((before_count - after_count))
	[[ "$removed" -lt 0 ]] && removed=0
	if [[ "$removed" -gt 0 ]]; then
		echo "[pulse-canonical-maintenance] Swept ${removed} worktrees for ${repo_path}" >>"${LOGFILE:-/dev/null}"
		_canonical_maintenance_audit_log "canonical-maintenance: swept ${removed} worktrees for ${repo_path}"
	fi
	printf '%d' "$removed"
	return 0
}

# ---------------------------------------------------------------------------
# _stale_worktree_sweep
#
# For each registered, non-local_only repo: invoke worktree-helper.sh
# clean --auto --force-merged with a per-repo hard timeout.
# Arguments: $1 - dry_run ("1" for dry run, "0" for real)
# Returns: 0 always (fail-open per repo)
# ---------------------------------------------------------------------------
_stale_worktree_sweep() {
	local dry_run="${1:-0}"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	[[ -f "$repos_json" ]] && command -v jq &>/dev/null || return 0

	# t2559 Layer 3: fail-loud if git is missing from PATH. Without git,
	# `git worktree list` returns empty, which the downstream guard in
	# worktree-helper.sh cmd_clean used to reduce to "!= empty" (always
	# true) and would trash canonical. Belt-and-braces here in case the
	# helper-level guards are bypassed.
	if command -v assert_git_available >/dev/null 2>&1; then
		if ! assert_git_available; then
			echo "[pulse-canonical-maintenance] refusing stale worktree sweep — git not in PATH" >>"${LOGFILE:-/dev/null}"
			return 0
		fi
	fi

	local worktree_helper="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}/worktree-helper.sh"
	if [[ ! -x "$worktree_helper" ]]; then
		echo "[pulse-canonical-maintenance] worktree-helper.sh not found or not executable" >>"${LOGFILE:-/dev/null}"
		return 0
	fi

	local -a _repo_list=()
	mapfile -t _repo_list < <(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path // ""' "$repos_json" 2>/dev/null)

	local repo_path sweep_count=0
	for repo_path in "${_repo_list[@]}"; do
		[[ -z "$repo_path" ]] && continue
		if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
			echo "[pulse-canonical-maintenance] Skipping ${repo_path} — not a git repository" >>"${LOGFILE:-/dev/null}"
			continue
		fi
		local removed=0
		removed=$(_stale_worktree_sweep_single_repo "$repo_path" "$dry_run" "$worktree_helper")
		# t2559 defense-in-depth: sanitise the captured count before arithmetic.
		# Even with the stdout fix in _stale_worktree_sweep_single_repo, guard
		# against future regressions where stray text might leak into $removed.
		# A non-numeric value here previously crashed the pulse with set -e.
		removed="${removed//[^0-9]/}"
		removed="${removed:-0}"
		sweep_count=$((sweep_count + removed))
	done

	echo "[pulse-canonical-maintenance] Worktree sweep: ${sweep_count} total removed" >>"${LOGFILE:-/dev/null}"
	return 0
}

# ---------------------------------------------------------------------------
# run_canonical_maintenance
#
# Top-level entry point called from the deterministic pipeline.
# Checks cadence, runs both passes, writes cadence state file.
# Arguments: none (reads --dry-run from $1 if called directly)
# Returns: 0 always
# ---------------------------------------------------------------------------
run_canonical_maintenance() {
	local dry_run=0
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=1
	fi

	local now_epoch
	now_epoch=$(date +%s)

	# Cadence gate (skip in dry-run mode to always show output)
	if [[ "$dry_run" -eq 0 ]] && ! _canonical_maintenance_check_cadence "$now_epoch"; then
		return 0
	fi

	echo "[pulse-canonical-maintenance] Starting canonical maintenance pass" >>"${LOGFILE:-/dev/null}"

	_canonical_fast_forward "$dry_run"
	_stale_worktree_sweep "$dry_run"

	# Update cadence state file
	if [[ "$dry_run" -eq 0 ]]; then
		mkdir -p "$(dirname "$CANONICAL_MAINTENANCE_LAST_RUN")" 2>/dev/null || true
		echo "$now_epoch" >"$CANONICAL_MAINTENANCE_LAST_RUN"
	fi

	echo "[pulse-canonical-maintenance] Canonical maintenance pass complete" >>"${LOGFILE:-/dev/null}"
	return 0
}
