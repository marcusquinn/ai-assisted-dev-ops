#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-routine.sh — Standalone fast-cadence merge routine (t2862, GH#20919)
#
# Decouples `merge_ready_prs_all_repos()` from the monolithic pulse cycle so
# green PRs are merged within ~3 min of CI completion regardless of how long
# the preflight stack takes (typically 5-10 min for a full pulse cycle).
#
# Problem: the pulse cycle's preflight stack
# (`preflight_cleanup_and_ledger` + `preflight_capacity_and_labels` +
# `preflight_early_dispatch` + `complexity_scan` etc.) often takes 5+ min
# before `deterministic_merge_pass` starts. In a 24h sample, the merge pass
# ran only ~7 times despite ~40+ pulse cycles. Green `origin:interactive` +
# OWNER PRs sat unmerged for 10+ minutes; the workaround was `gh pr merge
# --admin --squash`, which works but should not be the primary path.
#
# Solution: run merge_ready_prs_all_repos() as a fast independent routine on
# a 120s launchd/cron schedule. The in-cycle merge call in pulse-wrapper.sh
# is kept as defense-in-depth but short-circuits when this routine ran within
# the last 60s (file-timestamp marker at PULSE_MERGE_ROUTINE_LAST_RUN).
#
# Architecture: modelled on complexity-scan-runner.sh (t2903) — independent
# file-based lock (mkdir, PID stale-reclaim), runner-level log, minimal
# source chain, --dry-run / --repo / --pr spot-check flags.
#
# Usage:
#   pulse-merge-routine.sh [run]           Run the merge pass (default; called by launchd)
#   pulse-merge-routine.sh --dry-run       Dry-run: print what would be merged, no side effects
#   pulse-merge-routine.sh --repo SLUG     Limit to a single repo
#   pulse-merge-routine.sh --pr N          Spot-check one PR (requires --repo)
#   pulse-merge-routine.sh help            Show usage
#
# Lock:       ~/.aidevops/.agent-workspace/locks/pulse-merge-routine.lock
# Runner log: ~/.aidevops/logs/pulse-merge-routine.log
# Last-run:   ~/.aidevops/logs/pulse-merge-routine-last-run
#             (also written as PULSE_MERGE_ROUTINE_LAST_RUN; read by pulse-wrapper.sh
#             short-circuit)
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# PATH normalisation for launchd/cron environments where PATH is minimal.
_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

# SCRIPT_DIR resolution — uses BASH_SOURCE[0]:-$0 for zsh portability (GH#3931).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -r "${SCRIPT_DIR}/pulse-runtime-pin.sh" ]]; then
	# shellcheck source=./pulse-runtime-pin.sh
	source "${SCRIPT_DIR}/pulse-runtime-pin.sh"
	pulse_runtime_pin_reexec "${SCRIPT_DIR%/scripts}" "scripts/pulse-merge-routine.sh" "$@" || exit $?
fi
AIDEVOPS_AGENTS_DIR="${SCRIPT_DIR%/scripts}"
AGENTS_DIR="$AIDEVOPS_AGENTS_DIR"
export AIDEVOPS_AGENTS_DIR AGENTS_DIR

# GH#24900: launchd/cron PATH repair must not bypass the aidevops gh shim.
# Keep the framework script directory first so standalone merge runs inherit
# GraphQL instrumentation, REST routing, and signature/write safeguards.
export PATH="${SCRIPT_DIR}:${PATH}"

# =============================================================================
# Source pulse libraries
# =============================================================================
# Order matters (mirrors complexity-scan-runner.sh):
#   1. shared-constants.sh  — bash 4+ re-exec guard fires here at depth 1; also
#                             auto-sources shared-gh-wrappers.sh.
#   2. config-helper.sh     — provides config_get used by pulse-wrapper-config.sh.
#   3. worker-lifecycle-common.sh — provides _validate_int used by pulse-wrapper-config.sh.
#   4. credentials.sh       — picks up gh tokens / API keys before merge calls gh.
#   5. pulse-wrapper-config.sh — defines LOGFILE, REPOS_JSON, STOP_FLAG, etc.
#   6. pulse-repo-meta.sh   — get_repo_role_by_slug, get_repo_path_by_slug.
#   7. dependency-event-reconciler.sh — provides closure reconciliation called
#                             from pulse-merge.sh after a linked issue closes.
#   8. pulse-triage-cache.sh — provides the idempotent comment primitive used by
#                             conflict and stuck-PR escalation paths.
#   9. pulse-dispatch-core.sh — provides unlock_issue_after_worker (called from
#                             pulse-merge.sh:338,385 in _handle_post_merge_actions
#                             and _handle_post_close_actions). Without this,
#                             stderr emits 'unlock_issue_after_worker: command not
#                             found' on every merged/closed PR (t3036).
#  10. pulse-fast-fail.sh   — provides fast_fail_reset (called from pulse-merge.sh:383
#                             in _handle_post_close_actions). Without this, stderr
#                             emits 'fast_fail_reset: command not found' on every
#                             closed PR (t3036).
#  11. pulse-merge.sh       — merge_ready_prs_all_repos + gate helpers; also
#                             transitively sources shared-claim-lifecycle.sh and
#                             shared-phase-filing.sh.
#  12. pulse-merge-conflict.sh — conflict handling, interactive PR handover.
#  13. pulse-merge-feedback.sh — CI/conflict/review feedback routing to linked issues.
#  14. pulse-merge-stuck.sh — stuck-PR detection and idempotent escalation.
#
# pulse-merge.sh normally requires PULSE_MERGE_BATCH_LIMIT and PULSE_START_EPOCH
# to be set by the pulse-wrapper.sh bootstrap (lines 180, 727). They are
# initialised below in the env-var defaults section before any function is
# called (see also the ${VAR:-default} guards added to merge_ready_prs_all_repos
# itself in t2862 — belt-and-suspenders).

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
	# shellcheck source=/dev/null
	. "${HOME}/.config/aidevops/credentials.sh" 2>/dev/null || true
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-wrapper-config.sh"
# shellcheck source=./pulse-rate-limit-circuit-breaker.sh
source "${SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-repo-meta.sh"
# GH#28207: pulse-merge.sh reconciles dependants after verified issue closure,
# while conflict/stuck paths post through the triage cache's idempotent helper.
# These required providers must precede every consumer in the standalone chain;
# source them without an optional fallback so startup fails before processing
# merges if either provider cannot load.
# shellcheck source=./dependency-event-reconciler.sh
source "${SCRIPT_DIR}/dependency-event-reconciler.sh"
# shellcheck source=./pulse-triage-cache.sh
source "${SCRIPT_DIR}/pulse-triage-cache.sh"
# t3036 (GH#21616): pulse-dispatch-core defines unlock_issue_after_worker;
# pulse-fast-fail defines fast_fail_reset. Both are called from
# _handle_post_merge_actions / _handle_post_close_actions in pulse-merge.sh.
# Without these, every successful merge/close emits 'command not found'
# stderr noise. Source defensively before pulse-merge.sh.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dispatch-core.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-fast-fail.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-conflict.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-feedback.sh"
# t3193: stuck-merge detector module — sourced after the conflict/feedback
# downstream modules so its functions resolve via bash lazy lookup.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-stuck.sh"

# =============================================================================
# Env-var defaults (belt-and-suspenders — also guarded inside the function)
# =============================================================================

# PULSE_MERGE_BATCH_LIMIT is normally set by pulse-wrapper.sh:727. Keep the
# standalone routine's per-repository enrichment set bounded even when an
# inherited environment requests a full-repository scan.
PULSE_MERGE_BATCH_LIMIT="${PULSE_MERGE_BATCH_LIMIT:-50}"
PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX="${PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX:-50}"
[[ "$PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX" =~ ^[1-9][0-9]*$ ]] || PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX=50
[[ "$PULSE_MERGE_BATCH_LIMIT" =~ ^[1-9][0-9]*$ ]] || PULSE_MERGE_BATCH_LIMIT="$PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX"
if [[ "$PULSE_MERGE_BATCH_LIMIT" -gt "$PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX" ]]; then
	PULSE_MERGE_BATCH_LIMIT="$PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX"
fi
export PULSE_MERGE_BATCH_LIMIT PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX

# Match the normal pulse bootstrap's durable REST PR-view cache. Standalone
# scheduler launches are separate processes, so the wrapper's PID-scoped
# fallback would otherwise start cold on every cycle. Mutation-sensitive reads
# continue to bypass this cache at their existing call sites.
AIDEVOPS_GH_PR_VIEW_CACHE="${AIDEVOPS_GH_PR_VIEW_CACHE:-1}"
AIDEVOPS_GH_PR_VIEW_CACHE_DIR="${AIDEVOPS_GH_PR_VIEW_CACHE_DIR:-${AIDEVOPS_PULSE_PR_VIEW_CACHE_DIR:-${HOME}/.aidevops/cache/pulse-pr-view-cache}}"
AIDEVOPS_GH_PR_VIEW_CACHE_TTL="${AIDEVOPS_GH_PR_VIEW_CACHE_TTL:-${AIDEVOPS_PULSE_PR_VIEW_CACHE_TTL:-3600}}"
if [[ "$AIDEVOPS_GH_PR_VIEW_CACHE" == "1" ]] && ! mkdir -p "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR"; then
	printf 'pulse-merge-routine: failed to create persistent PR view cache: %s\n' "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR" >&2
	AIDEVOPS_GH_PR_VIEW_CACHE=0
fi
export AIDEVOPS_GH_PR_VIEW_CACHE AIDEVOPS_GH_PR_VIEW_CACHE_DIR AIDEVOPS_GH_PR_VIEW_CACHE_TTL

# PULSE_START_EPOCH is normally set by pulse-wrapper.sh. Shared bootstrap keeps
# standalone runners safe under `set -u` and exports the value for helpers that
# append GitHub signature footers (t3036/GH#21616, complexity runner parity).
aidevops_ensure_pulse_start_epoch

# STOP_FLAG / REPOS_JSON: normally set by pulse-wrapper-config.sh; the
# ${VAR:-default} guards below are defence-in-depth for edge-case sourcing
# order issues (e.g. unit test harnesses that source a subset of the chain).
STOP_FLAG="${STOP_FLAG:-${HOME}/.aidevops/logs/pulse-session.stop}"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

# Hard ceiling on routine runtime (t3041, GH#21708). The merge routine has
# historically hung for 30+ hours with green PRs sitting unmerged. Root cause
# could not be reliably reproduced on the canonical marcusquinn/aidevops repo
# (Phase 1, PR #21643), so a defence-in-depth timeout ceiling is the
# durability fix: whatever the underlying hang site (gh API call without
# timeout, flock deadlock, infinite retry loop on transient network error,
# wait on dead PID), the routine cannot run longer than this ceiling.
#
# Default: 600s (10 min). Typical run on a healthy aidevops state with 5+ open
# PRs completes in <60s. Set higher only if you have repos with many PRs
# requiring extended remote ops; set lower for testing/CI.
#
# Watchdog interaction: launchd respawns the routine every 120s. If a single
# invocation runs longer than 120s the next launchd tick will short-circuit
# on the lock owned by the still-running PID — only one runner is ever active.
# A 600s ceiling is well below the 30+ hour symptom and well above the
# typical run duration, leaving headroom for slow remote round-trips.
PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS="${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS:-600}"
# Validate — non-numeric or zero means a config error; clamp to default.
[[ "$PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS=600
[[ "$PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS" -lt 1 ]] && PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS=600

# =============================================================================
# Runner-level state files
# =============================================================================

RUNNER_LOG_FILE="${HOME}/.aidevops/logs/pulse-merge-routine.log"
LOCK_DIR="${HOME}/.aidevops/.agent-workspace/locks/pulse-merge-routine.lock"
PULSE_MERGE_ROUTINE_LAST_RUN="${HOME}/.aidevops/logs/pulse-merge-routine-last-run"
PULSE_MERGE_ROUTINE_TARGET_REPO=""
PULSE_MERGE_ROUTINE_TARGET_PR=""

mkdir -p "$(dirname "$RUNNER_LOG_FILE")" "$(dirname "$LOCK_DIR")"

# =============================================================================
# Logging
# =============================================================================

_pmr_log() {
	local level="$1"
	shift
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '[%s] [%s] %s\n' "$timestamp" "$level" "$*" >>"$RUNNER_LOG_FILE"
	return 0
}

_pmr_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

_pmr_graphql_remaining() {
	local remaining="${AIDEVOPS_PULSE_GRAPHQL_BUDGET_REMAINING:-}"
	if [[ "$remaining" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$remaining"
		return 0
	fi
	# The REST rate_limit endpoint reports the independent GraphQL pool without
	# consuming primary quota, and unlike a native GraphQL probe has exact
	# zero-cost attribution in transport telemetry.
	remaining=$(_pmr_gh_read gh api rate_limit \
		--jq '.resources.graphql.remaining // 0' 2>/dev/null) || remaining="0"
	[[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
	printf '%s\n' "$remaining"
	return 0
}

_pmr_graphql_budget_allows_run() {
	local threshold="${AIDEVOPS_PULSE_MERGE_GRAPHQL_MIN_REMAINING:-500}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=500
	local remaining=""
	remaining=$(_pmr_graphql_remaining)
	[[ "$remaining" =~ ^[0-9]+$ ]] || remaining=0
	if [[ "$remaining" -lt "$threshold" ]]; then
		_pmr_log WARN "GraphQL budget depleted (${remaining} remaining < ${threshold}); deferring merge pass to next cycle (GH#24904)"
		return 1
	fi
	return 0
}

# Unknown quota evidence remains fail-closed until a later authoritative probe
# succeeds; unlike a known floor, it is logged as an availability/evidence fault.
_pmr_rest_core_progress_allows_run() {
	local progress_rc=0
	if declare -F pulse_rest_core_priority_allows >/dev/null 2>&1; then
		pulse_rest_core_priority_allows progress || progress_rc=$?
	elif declare -F pulse_rest_core_reserve_allows >/dev/null 2>&1; then
		pulse_rest_core_reserve_allows || progress_rc=$?
	else
		return 0
	fi
	case "$progress_rc" in
	0)
		return 0
		;;
	1)
		_pmr_log WARN "Known REST-core progress floor reached (rc=1); deferring merge pass until a later authoritative probe allows progress while preserving critical maintainer quota (GH#29742)"
		;;
	2)
		_pmr_log WARN "REST-core quota evidence unavailable (rc=2); deferring merge pass fail-closed until a later authoritative probe succeeds while preserving critical maintainer quota (GH#29742)"
		;;
	*)
		_pmr_log WARN "Unexpected REST-core progress decision (rc=${progress_rc}); deferring merge pass fail-closed while preserving critical maintainer quota (GH#29742)"
		;;
	esac
	return 1
}

_pmr_require_gh_auth() {
	local token=""
	if ! token=$(gh auth token 2>/dev/null) || [[ -z "$token" ]]; then
		_pmr_log ERROR "GitHub authentication unavailable; aborting merge routine before API access to prevent unauthenticated requests"
		printf '%s\n' 'pulse-merge-routine: GitHub authentication unavailable; refusing unauthenticated API access' >&2
		return 1
	fi
	unset token
	return 0
}

# =============================================================================
# File-based lock (mkdir-based for bash 3.2 + macOS portability)
# =============================================================================
# mkdir is atomic on POSIX filesystems and works without flock (Linux-only) or
# any FD-inheritance gotchas. PID-based stale detection lets the next runner
# reclaim the lock if the previous instance crashed.

_pmr_release_lock() {
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	return 0
}

# =============================================================================
# Hard timeout ceiling (t3041, GH#21708)
# =============================================================================
# Background a function/command in a subshell and kill its process tree if it
# exceeds $1 seconds. Returns:
#   0   — child completed successfully
#   124 — timeout exceeded (matches GNU coreutils `timeout` exit convention)
#   N>0 — child's own non-zero exit
#
# Uses _kill_tree / _force_kill_tree from worker-lifecycle-common.sh (already
# sourced by this routine on line 87). Polling at 2s — same cadence as
# run_stage_with_timeout in pulse-watchdog.sh, which is the reference pattern
# this implementation mirrors. Inlined here (rather than sourcing
# pulse-watchdog.sh) to keep the routine's dependency graph minimal — the
# watchdog module pulls in PRE_RUN_STAGE_TIMEOUT, PULSE_STAGE_TIMINGS_LOG,
# and several pulse-cycle-specific globals this standalone routine doesn't
# need.
#
# Args:
#   $1 — timeout in seconds (positive integer)
#   $@ — command and arguments (after shift); may be a function name
_pmr_run_with_timeout() {
	local timeout_seconds="$1"
	shift
	if [[ -z "${1:-}" ]]; then
		_pmr_log ERROR "_pmr_run_with_timeout: missing command"
		return 2
	fi
	[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=600
	[[ "$timeout_seconds" -lt 1 ]] && timeout_seconds=1

	local _start_epoch
	_start_epoch=$(date +%s)

	# Background the function/command in a subshell.
	"$@" &
	local _child_pid=$!

	# Poll for child completion or timeout. sleep 2 keeps the loop cheap;
	# overshoot is bounded by 2s.
	while kill -0 "$_child_pid" 2>/dev/null; do
		local _now="" _elapsed=""
		_now=$(date +%s)
		_elapsed=$((_now - _start_epoch))
		if [[ "$_elapsed" -gt "$timeout_seconds" ]]; then
			_pmr_log ERROR "Merge routine body timed out after ${_elapsed}s (ceiling=${timeout_seconds}s, pid=${_child_pid}); killing process tree"
			# Use _kill_tree if available (sourced from worker-lifecycle-common.sh);
			# fall back to direct kill if the helper is missing (e.g. test harness
			# that didn't source the full chain).
			if command -v _kill_tree >/dev/null 2>&1; then
				_kill_tree "$_child_pid" || true
				sleep 2
				if kill -0 "$_child_pid" 2>/dev/null; then
					if command -v _force_kill_tree >/dev/null 2>&1; then
						_force_kill_tree "$_child_pid" || true
					else
						kill -9 "$_child_pid" 2>/dev/null || true
					fi
				fi
			else
				kill "$_child_pid" 2>/dev/null || true
				sleep 2
				if kill -0 "$_child_pid" 2>/dev/null; then
					kill -9 "$_child_pid" 2>/dev/null || true
				fi
			fi
			wait "$_child_pid" 2>/dev/null || true
			return 124
		fi
		sleep 2
	done

	wait "$_child_pid"
	return $?
}

_pmr_acquire_lock() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"${LOCK_DIR}/pid"
		trap '_pmr_release_lock' EXIT INT TERM
		return 0
	fi

	# Lock dir exists — check if owner is alive.
	local owner_pid=""
	if [[ -f "${LOCK_DIR}/pid" ]]; then
		owner_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
	fi
	if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
		_pmr_log INFO "Skipping: previous instance still running (pid=${owner_pid})"
		return 1
	fi

	# Stale lock — reclaim. mkdir again after rm to confirm we won the race.
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"${LOCK_DIR}/pid"
		trap '_pmr_release_lock' EXIT INT TERM
		_pmr_log WARN "Reclaimed stale lock (was pid=${owner_pid:-unknown})"
		return 0
	fi
	_pmr_log WARN "Could not acquire lock after stale-reclaim attempt"
	return 1
}

# =============================================================================
# Commands
# =============================================================================

_pmr_run_merge_scope() {
	if [[ -z "$PULSE_MERGE_ROUTINE_TARGET_PR" ]]; then
		merge_ready_prs_all_repos
		return $?
	fi

	local process_exit=0
	process_pr "$PULSE_MERGE_ROUTINE_TARGET_REPO" "$PULSE_MERGE_ROUTINE_TARGET_PR" || process_exit=$?
	case "$process_exit" in
	0)
		if [[ "${DRY_RUN:-0}" == "1" ]]; then
			_pmr_log INFO "Spot-check result: repo=${PULSE_MERGE_ROUTINE_TARGET_REPO} pr=${PULSE_MERGE_ROUTINE_TARGET_PR} disposition=would-merge"
		else
			_pmr_log INFO "Spot-check result: repo=${PULSE_MERGE_ROUTINE_TARGET_REPO} pr=${PULSE_MERGE_ROUTINE_TARGET_PR} disposition=merged"
		fi
		;;
	1)
		_pmr_log INFO "Spot-check result: repo=${PULSE_MERGE_ROUTINE_TARGET_REPO} pr=${PULSE_MERGE_ROUTINE_TARGET_PR} disposition=skipped reason=merge-gate"
		;;
	2)
		_pmr_log INFO "Spot-check result: repo=${PULSE_MERGE_ROUTINE_TARGET_REPO} pr=${PULSE_MERGE_ROUTINE_TARGET_PR} disposition=closed-conflicting"
		;;
	3)
		_pmr_log ERROR "Spot-check result: repo=${PULSE_MERGE_ROUTINE_TARGET_REPO} pr=${PULSE_MERGE_ROUTINE_TARGET_PR} disposition=merge-failed"
		return 3
		;;
	4)
		_pmr_log INFO "Spot-check result: repo=${PULSE_MERGE_ROUTINE_TARGET_REPO} pr=${PULSE_MERGE_ROUTINE_TARGET_PR} disposition=deferred"
		;;
	*)
		_pmr_log ERROR "Spot-check result: repo=${PULSE_MERGE_ROUTINE_TARGET_REPO} pr=${PULSE_MERGE_ROUTINE_TARGET_PR} disposition=unexpected exit=${process_exit}"
		return "$process_exit"
		;;
	esac
	return 0
}

cmd_run() {
	_pmr_log INFO "Starting merge routine (pid=$$, timeout=${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS}s)"
	if ! _pmr_acquire_lock; then
		exit 0
	fi
	if ! _pmr_require_gh_auth; then
		return 1
	fi
	if ! _pmr_graphql_budget_allows_run; then
		date +%s >"$PULSE_MERGE_ROUTINE_LAST_RUN" 2>/dev/null || true
		return 0
	fi
	if ! _pmr_rest_core_progress_allows_run; then
		date +%s >"$PULSE_MERGE_ROUTINE_LAST_RUN" 2>/dev/null || true
		return 0
	fi

	# Wrap merge_ready_prs_all_repos with a hard timeout ceiling (t3041, GH#21708).
	# Whatever the underlying hang site (gh API call, flock deadlock, infinite
	# retry loop, dead-PID wait), the routine cannot exceed this ceiling. On
	# timeout, _pmr_run_with_timeout returns 124 (matching GNU `timeout`).
	local merge_exit=0
	_pmr_run_with_timeout "$PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS" _pmr_run_merge_scope || merge_exit=$?

	# Always write the last-run marker so pulse-wrapper.sh short-circuit can
	# compare elapsed time (consistent with DIRTY_PR_SWEEP_LAST_RUN pattern).
	# This runs even on timeout — we still completed our scheduled tick.
	date +%s >"$PULSE_MERGE_ROUTINE_LAST_RUN" 2>/dev/null || true

	if [[ "$merge_exit" -eq 124 ]]; then
		_pmr_log ERROR "Merge routine completed via TIMEOUT (exit=124, ceiling=${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS}s)"
	else
		_pmr_log INFO "Merge routine completed (exit=${merge_exit})"
	fi
	return "$merge_exit"
}

cmd_help() {
	cat <<EOF
pulse-merge-routine.sh — Standalone fast-cadence merge routine (t2862, GH#20919)

Usage:
  pulse-merge-routine.sh [run]         Run the merge pass (default; called by launchd)
  pulse-merge-routine.sh --dry-run     Dry-run: print what would be merged, no side effects
  pulse-merge-routine.sh --repo SLUG   Limit to a single repo
  pulse-merge-routine.sh --pr N        Spot-check one PR (requires --repo)
  pulse-merge-routine.sh help          Show this help

Scheduled via launchd: sh.aidevops.pulse-merge-routine (every 120s, RunAtLoad=true).
Install via setup.sh / setup_pulse_merge_routine in .agents/scripts/setup/modules/schedulers.sh.

Paths:
  Lock dir:    ${LOCK_DIR}
  Runner log:  ${RUNNER_LOG_FILE}
  Pulse log:   ${LOGFILE:-~/.aidevops/logs/pulse.log}
  Last-run:    ${PULSE_MERGE_ROUTINE_LAST_RUN}

The underlying pass (merge_ready_prs_all_repos in pulse-merge.sh) processes all
pulse-enabled repos from REPOS_JSON (${REPOS_JSON}). The in-cycle merge call
in pulse-wrapper.sh short-circuits when this routine ran within the last 60s.

Env overrides:
  PULSE_MERGE_BATCH_LIMIT=${PULSE_MERGE_BATCH_LIMIT}              Max PRs fetched per repo per run.
  PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX=${PULSE_MERGE_ROUTINE_BATCH_LIMIT_MAX}  Standalone hard ceiling.
  AIDEVOPS_GH_PR_VIEW_CACHE=1             Reuse non-mutation PR views across runs.
  AIDEVOPS_GH_PR_VIEW_CACHE_TTL=3600      Persistent PR-view cache TTL in seconds.
  PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS=600 Hard ceiling on routine runtime (t3041).
                                          Process tree killed on overrun. Min 1s.
  DRY_RUN=1                               Same as --dry-run.
EOF
	return 0
}

# Dry-run: set DRY_RUN=1 so merge_ready_prs_all_repos logs "would merge" but
# skips actual gh pr merge calls. The underlying function checks DRY_RUN via
# the shared wrapper helpers.
cmd_dry_run() {
	export DRY_RUN=1
	_pmr_log INFO "DRY-RUN mode: merge routine (pid=$$, timeout=${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS}s)"
	if ! _pmr_acquire_lock; then
		exit 0
	fi
	if ! _pmr_require_gh_auth; then
		return 1
	fi
	if ! _pmr_graphql_budget_allows_run; then
		return 0
	fi
	if ! _pmr_rest_core_progress_allows_run; then
		return 0
	fi

	# Same timeout protection as cmd_run (t3041, GH#21708).
	local merge_exit=0
	_pmr_run_with_timeout "$PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS" _pmr_run_merge_scope || merge_exit=$?

	if [[ "$merge_exit" -eq 124 ]]; then
		_pmr_log ERROR "DRY-RUN merge routine TIMED OUT (exit=124, ceiling=${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS}s)"
	else
		_pmr_log INFO "DRY-RUN merge routine completed (exit=${merge_exit})"
	fi
	return "$merge_exit"
}

# =============================================================================
# Entry point
# =============================================================================

_pmr_main() {
	local _subcommand="run"
	local _repo_filter=""
	local _pr_filter=""

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		local _next="${2:-}"
		case "$_arg" in
		run | --run | "")
			_subcommand="run"
			shift
			;;
		--dry-run | dry-run)
			_subcommand="dry-run"
			shift
			;;
		--repo)
			if [[ -z "$_next" || "$_next" == --* ]]; then
				printf '%s\n' 'Option --repo requires a repository slug.' >&2
				return 2
			fi
			_repo_filter="$_next"
			shift 2
			;;
		--repo=*)
			_repo_filter="${_arg#--repo=}"
			shift
			;;
		--pr)
			if [[ -z "$_next" || "$_next" == --* ]]; then
				printf '%s\n' 'Option --pr requires a pull request number.' >&2
				return 2
			fi
			_pr_filter="$_next"
			shift 2
			;;
		--pr=*)
			_pr_filter="${_arg#--pr=}"
			shift
			;;
		help | -h | --help)
			_subcommand="help"
			shift
			;;
		*)
			printf 'Unknown option: %s\n' "$_arg" >&2
			printf "Run '%s help' for usage.\n" "$0" >&2
			return 2
			;;
		esac
	done

	if [[ -n "$_pr_filter" && -z "$_repo_filter" ]]; then
		printf '%s\n' 'Option --pr requires --repo.' >&2
		return 2
	fi
	if [[ -n "$_pr_filter" && ! "$_pr_filter" =~ ^[1-9][0-9]*$ ]]; then
		printf 'Invalid pull request number: %s\n' "$_pr_filter" >&2
		return 2
	fi

	# Single-repo or single-PR spot mode: override REPOS_JSON with a synthetic
	# single-entry repo list so merge_ready_prs_all_repos only processes that repo.
	if [[ -n "$_repo_filter" ]]; then
		local _SPOT_REPOS_JSON
		_SPOT_REPOS_JSON="$(mktemp)"
		# shellcheck disable=SC2064
		trap "rm -f '$_SPOT_REPOS_JSON' 2>/dev/null || true" EXIT INT TERM
		printf '{"initialized_repos":[{"slug":"%s","pulse":true,"local_only":false,"path":""}]}\n' \
			"$_repo_filter" >"$_SPOT_REPOS_JSON"
		REPOS_JSON="$_SPOT_REPOS_JSON"
		if [[ -n "$_pr_filter" ]]; then
			_pmr_log INFO "Spot-check: --repo=${_repo_filter} --pr=${_pr_filter}"
			PULSE_MERGE_ROUTINE_TARGET_REPO="$_repo_filter"
			PULSE_MERGE_ROUTINE_TARGET_PR="$_pr_filter"
		else
			_pmr_log INFO "Spot-check: --repo=${_repo_filter}"
		fi
	fi

	case "$_subcommand" in
	run)
		cmd_run
		;;
	dry-run)
		cmd_dry_run
		;;
	help)
		cmd_help
		;;
	*)
		printf 'Unknown command: %s\n' "$_subcommand" >&2
		printf "Run '%s help' for usage.\n" "$0" >&2
		return 2
		;;
	esac
	return 0
}

_pmr_main "$@"
exit $?
