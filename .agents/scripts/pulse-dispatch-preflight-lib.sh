#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-dispatch-preflight-lib.sh -- Preflight stage helpers for _run_preflight_stages
# =============================================================================
# Sub-library extracted from pulse-dispatch-engine.sh (GH#21738) so the
# orchestrator stays under the 1500-line file-size threshold. Contains all
# `_preflight_*` helper functions that support `_run_preflight_stages`
# (which remains in the orchestrator because its 108-line body would
# re-register as a new function-complexity violation if moved).
#
# Each helper groups one phase of preflight work: asynchronous merge-first,
# cleanup/reap, capacity, early dispatch, label maintenance, trusted NMR
# reconciliation/refill, ownership reconcile, and prefetch+scope.
#
# Usage: source "${SCRIPT_DIR}/pulse-dispatch-preflight-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (LOGFILE, status helpers)
#   - worker-lifecycle-common.sh (cleanup_orphans, count_active_workers, etc.)
#   - run_stage_with_timeout (defined in pulse-wrapper.sh)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_DISPATCH_PREFLIGHT_LIB_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_PREFLIGHT_LIB_LOADED=1

# --- Preflight helper functions (extracted) ---

# -----------------------------------------------------------------------------
# Helpers for _run_preflight_stages (GH#18656)
# -----------------------------------------------------------------------------
# The helpers below group related preflight work so _run_preflight_stages
# stays under 100 lines and each group (merge-first, cleanup/reap, capacity,
# early dispatch, label maintenance, trusted NMR reconciliation/refill, daily
# scans, ownership reconcile, and prefetch/scope) can be read independently.

#######################################
# Give the existing standalone merge routine a non-blocking head start before
# cleanup, capacity calculation, and early dispatch. The routine owns its own
# cross-process lock and timeout, so concurrent launchd/pulse kicks collapse to
# one runner without making dispatch wait for CI, review, or GitHub latency.
#######################################
_preflight_start_merge_first() {
	if [[ "${AIDEVOPS_PULSE_ASYNC_MERGE_FIRST:-1}" != "1" ]]; then
		echo "[pulse-wrapper] merge-first kick disabled by AIDEVOPS_PULSE_ASYNC_MERGE_FIRST" >>"$LOGFILE"
		return 0
	fi

	local merge_routine="${PULSE_MERGE_ROUTINE_HELPER:-${SCRIPT_DIR}/pulse-merge-routine.sh}"
	if [[ ! -x "$merge_routine" ]]; then
		echo "[pulse-wrapper] merge-first kick skipped: routine unavailable at ${merge_routine}" >>"$LOGFILE"
		return 0
	fi

	local kick_log="${PULSE_MERGE_FIRST_KICK_LOG:-${HOME}/.aidevops/logs/pulse-merge-routine-kick.log}"
	mkdir -p "$(dirname "$kick_log")" 2>/dev/null || true
	nohup "$merge_routine" run </dev/null >>"$kick_log" 2>&1 &
	local kick_pid=$!
	disown "$kick_pid" 2>/dev/null || true
	echo "[pulse-wrapper] merge-first kick started asynchronously (pid=${kick_pid})" >>"$LOGFILE"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "pulse_merge_first_kick_started" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Cleanup + zombie reap + ledger maintenance. Runs before worker counting
# so count_active_workers sees accurate slot availability.
#######################################
_preflight_cleanup_and_ledger() {
	run_stage_with_timeout "cleanup_orphans" "$PRE_RUN_STAGE_TIMEOUT" cleanup_orphans || true
	run_stage_with_timeout "cleanup_stale_opencode" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stale_opencode || true
	run_stage_with_timeout "cleanup_stalled_workers" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stalled_workers || true
	if declare -F sweep_closed_auto_dispatch_issues >/dev/null 2>&1; then
		run_stage_with_timeout "sweep_closed_auto_dispatch_issues" "$PRE_RUN_STAGE_TIMEOUT" sweep_closed_auto_dispatch_issues || true
	fi
	# Fast API-free recovery runs synchronously before the long async cleanup.
	# This prevents a stale async lock from leaving the dispatch worktree cap
	# saturated by abandoned detached linter/regression fixtures.
	if declare -F cleanup_stale_temp_worktrees >/dev/null 2>&1; then
		local _temp_cleanup_timeout="${TEMP_WORKTREE_CLEANUP_TIMEOUT:-60}"
		[[ "$_temp_cleanup_timeout" =~ ^[0-9]+$ ]] || _temp_cleanup_timeout=60
		run_stage_with_timeout "cleanup_stale_temp_worktrees" "$_temp_cleanup_timeout" cleanup_stale_temp_worktrees || true
	fi
	# GH#20554: Worktree cleanup is moved to an async background job so a slow
	# cleanup (20+ worktrees × 2-5s gh API calls each) never hits a hard timeout
	# and blocks the pulse cycle. The helper enforces a single-runner lock and
	# a cadence gate (CLEANUP_WORKTREES_ASYNC_CADENCE_MIN, default 10 min) so
	# concurrent pulse invocations do not spawn duplicate cleanup processes.
	# Progress and last-run timestamp: ~/.aidevops/logs/cleanup_worktrees.*
	local _cleanup_async_helper="${SCRIPT_DIR}/cleanup-worktrees-async-helper.sh"
	if [[ -x "$_cleanup_async_helper" ]]; then
		nohup "$_cleanup_async_helper" \
			>>"${HOME}/.aidevops/logs/cleanup_worktrees.log" 2>&1 &
		disown $! 2>/dev/null || true
	else
		# Fallback: synchronous with short timeout (old GH#18979 behaviour)
		run_stage_with_timeout "cleanup_worktrees" 60 cleanup_worktrees || true
	fi
	# GH#21997: Stash cleanup is moved to an async background job so slow
	# stash auditing (including gh API calls inside stash-audit-helper.sh) cannot
	# stall pulse preflight before early dispatch. The helper enforces a
	# single-runner lock and cadence gate (CLEANUP_STASHES_ASYNC_CADENCE_MIN,
	# default 10 min). Progress: ~/.aidevops/logs/cleanup_stashes.*
	local _cleanup_stashes_async_helper="${SCRIPT_DIR}/cleanup-stashes-async-helper.sh"
	if [[ -x "$_cleanup_stashes_async_helper" ]]; then
		nohup "$_cleanup_stashes_async_helper" \
			>>"${HOME}/.aidevops/logs/cleanup_stashes.log" 2>&1 &
		disown $! 2>/dev/null || true
	else
		# Fallback: synchronous with the standard pre-run stage timeout.
		run_stage_with_timeout "cleanup_stashes" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stashes || true
	fi
	# GH#22415: Remote branch cleanup is moved to an async background job so
	# cross-repo branch audits and optional safe deletes do not block preflight.
	# The helper is dry-run by default, enforces a single-runner lock/cadence gate,
	# and skips when GitHub API budget is below the configured floor.
	# Progress: ~/.aidevops/logs/cleanup_remote_branches.*
	local _cleanup_remote_branches_async_helper="${SCRIPT_DIR}/cleanup-remote-branches-async-helper.sh"
	if [[ -x "$_cleanup_remote_branches_async_helper" ]]; then
		nohup "$_cleanup_remote_branches_async_helper" \
			>>"${HOME}/.aidevops/logs/cleanup_remote_branches.log" 2>&1 &
		disown $! 2>/dev/null || true
	fi

	# GH#25136: OpenCode DB archive/VACUUM is heavy SQLite maintenance, not
	# dispatch preflight work. setup_opencode_db_archive installs a dedicated
	# low-priority scheduler for opencode-db-archive-async-helper.sh so archive
	# and VACUUM cadence no longer tracks every pulse cycle.

	# t1751: Reap zombie workers whose PRs have been merged by the deterministic merge pass.
	# Runs before worker counting so count_active_workers sees accurate slot availability.
	run_stage_with_timeout "reap_zombie_workers" "$PRE_RUN_STAGE_TIMEOUT" reap_zombie_workers || true

	# GH#6696: Expire stale in-flight ledger entries and prune old completed/failed ones.
	# This runs before worker counting so count_active_workers sees accurate ledger state.
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$_ledger_helper" ]]; then
		local expired_count
		expired_count=$("$_ledger_helper" expire 2>/dev/null) || expired_count=0
		"$_ledger_helper" prune >/dev/null 2>&1 || true
		if [[ "${expired_count:-0}" -gt 0 ]]; then
			echo "[pulse-wrapper] Dispatch ledger: expired ${expired_count} stale in-flight entries (GH#6696)" >>"$LOGFILE"
		fi
	fi
	return 0
}

#######################################
# Capacity calculation + session count warning. Must run before the first
# dispatch pass so max workers and priority allocations are current.
#######################################
_preflight_capacity() {
	# GH#21470: per-substage timing so slow callers are identifiable in
	# pulse-stage-timings.log. Each _log_substage_timing call writes one TSV
	# record with the same format as run_stage_with_timeout outer records.
	local _ss0=$SECONDS
	calculate_max_workers
	_log_substage_timing "substage:capacity/calculate_max_workers" "$_ss0" 0

	local _ss1=$SECONDS
	calculate_priority_allocations
	_log_substage_timing "substage:capacity/calculate_priority_allocations" "$_ss1" 0

	local _ss2=$SECONDS
	local _session_ct
	_session_ct=$(check_session_count)
	if [[ "${_session_ct:-0}" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "[pulse-wrapper] Session warning: $_session_ct interactive sessions open (threshold: $SESSION_COUNT_WARN). Each consumes 100-440MB + language servers. Consider closing unused tabs." >>"$LOGFILE"
	fi
	_log_substage_timing "substage:capacity/check_session_count" "$_ss2" 0

	return 0
}

#######################################
# Cross-repository needs-* label maintenance. Runs after the first dispatch so
# already-eligible work can boot while these idempotent sweeps expose additional
# candidates for the post-maintenance refill.
#######################################
_preflight_label_maintenance() {
	# GH#21470: preserve per-substage timing while separating these potentially
	# slow GitHub/repository sweeps from the capacity-critical dispatch path.

	# Re-evaluate needs-consolidation labels before the refill. Issues labeled
	# by an earlier (less precise) filter may no longer trigger under the
	# current filter. Auto-clearing here makes them dispatchable in this cycle
	# instead of stuck forever behind a label that list_dispatchable_issue_candidates_json
	# filters out (needs-* exclusion at line 6703).
	local _ss0=$SECONDS
	_reevaluate_consolidation_labels
	_log_substage_timing "substage:label_maintenance/reevaluate_consolidation_labels" "$_ss0" 0

	# t1982: Backfill pass for stuck needs-consolidation issues that never
	# got a consolidation-task child created (pre-t1982 dispatches just
	# labelled and returned). Dispatches a child retroactively so the
	# parent can actually be consolidated instead of sitting forever.
	local _ss1=$SECONDS
	_backfill_stale_consolidation_labels
	_log_substage_timing "substage:label_maintenance/backfill_consolidation_labels" "$_ss1" 0

	local _ss2=$SECONDS
	_reevaluate_simplification_labels
	_log_substage_timing "substage:label_maintenance/reevaluate_simplification_labels" "$_ss2" 0

	return 0
}

#######################################
# Reconcile only NMR holds that pass the authority, provenance, breaker, and
# security gates in auto_approve_maintainer_issues. Running this after the first
# fill but before candidate snapshot invalidation lets newly trusted candidates
# enter the same-cycle refill without delaying already-eligible work.
#######################################
_preflight_trusted_nmr_reconcile() {
	run_stage_with_timeout "auto_approve_maintainer_issues" "$PRE_RUN_STAGE_TIMEOUT" auto_approve_maintainer_issues || true
	return 0
}

#######################################
# Early dispatch pass + routine comment responses.
#
# Fills available worker slots BEFORE heavy housekeeping. Workers take
# 25-30s to cold-start (sandbox-exec + opencode), so dispatching here lets
# them boot in parallel with the remaining housekeeping stages
# (close_issues_with_merged_prs ~260s, prefetch_state ~130s, etc.).
# The main dispatch at the end of the cycle catches any slots freed by
# housekeeping. Without this, workers sit idle for ~7 minutes of cleanup.
#######################################
_preflight_early_dispatch() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag present — skipping early dispatch_max" >>"$LOGFILE"
	else
		# GH#22399: dispatch_max ultimately calls dispatch_with_dedup(), whose
		# external-author gate applies needs-maintainer-review fail-closed before
		# worker launch. Keep that trust-boundary check in the dispatch path rather
		# than depending on the asynchronous issue-triage GitHub Actions workflow.
		echo "[pulse-wrapper] Early dispatch_max: dispatching workers before housekeeping" >>"$LOGFILE"
		# GH#28971: the first fill is a latency-sensitive fast path. Keep blocked
		# children filtered from its fetched snapshot, but defer dependency graph
		# normalization/refetch to the post-label refill below. Pass the mode as an
		# internal argument so it cannot leak into launched worker environments.
		apply_dispatch_max "skip"
	fi

	# Routine comment responses: scan routine-tracking issues for unanswered
	# user comments and dispatch lightweight Haiku workers to respond.
	# Runs before heavy housekeeping so responses are fast.
	dispatch_routine_comment_responses || true
	return 0
}

#######################################
# Refill after label maintenance without repeating routine-comment responses.
# Invalidate the cycle-scoped candidate snapshot first so apply_dispatch_max
# sees labels changed by maintenance while preserving the existing claim,
# ledger, trust, and per-candidate timeout gates across multiple fill passes.
#######################################
_preflight_post_label_refill() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag present — skipping post-label dispatch_max" >>"$LOGFILE"
	else
		if ! _dispatch_invalidate_candidate_snapshot "label_maintenance_complete"; then
			echo "[pulse-wrapper] Post-label dispatch_max skipped: unable to invalidate candidate snapshot" >>"$LOGFILE"
			return 0
		fi
		echo "[pulse-wrapper] Post-label dispatch_max: refilling after label maintenance" >>"$LOGFILE"
		apply_dispatch_max
	fi
	return 0
}

# t2443: _preflight_daily_scans() was removed here. Its children (complexity_scan,
# coderabbit_review, post_merge_scanner, auto_decomposer_scanner, dedup_cleanup,
# fast_fail_prune_expired) are now promoted to top-level stages in
# _run_preflight_stages() with independent timeouts. See the call site below.

#######################################
# Ownership normalization + issue reconciliation stages.
# Ensures active labels reflect ownership (prevents multi-worker overlap),
# closes issues whose linked PRs already merged, and reconciles status:done
# stuck states. Trusted NMR reconciliation runs before the refill instead.
#######################################
_preflight_ownership_reconcile() {
	# GH#21470: per-substage timing for the unwrapped prefetch_contribution_watch
	# call. The three run_stage_with_timeout calls below are already individually
	# timed by that wrapper; prefetch_contribution_watch was the blind spot.
	local _ss0=$SECONDS
	# Contribution watch: lightweight scan of external issues/PRs (t1419).
	prefetch_contribution_watch
	_log_substage_timing "substage:ownership_reconcile/prefetch_contribution_watch" "$_ss0" 0

	# Ensure active labels reflect ownership to prevent multi-worker overlap.
	run_stage_with_timeout "normalize_active_issue_assignments" "$PRE_RUN_STAGE_TIMEOUT" normalize_active_issue_assignments || true

	# t2776: single-pass reconcile — iterates the issue list ONCE per repo and
	# applies all five reconcile checks in sub-stage order (close-merged-PR,
	# stale-done, open-with-merged-PR, parent-task, labelless backfill).
	# Replaces the five sequential stage calls that each had their own per-repo
	# fetch loop; now 5N → N iterations per cycle.
	run_stage_with_timeout "reconcile_issues_single_pass" "$PRE_RUN_STAGE_TIMEOUT" reconcile_issues_single_pass || true

	return 0
}

#######################################
# Prefetch GitHub state + restore persisted PULSE_SCOPE_REPOS.
#
# Returns:
#   0 - prefetch succeeded (or succeeded with warnings)
#   1 - prefetch failed; caller should abort this cycle to avoid stale
#       dispatch decisions
#######################################
_preflight_prefetch_and_scope() {
	# GH#18979 (t2097): clear any stale flag from a previous cycle before
	# prefetch runs. Only the current cycle's prefetch should set the flag —
	# leftover files from a previous cycle would cause false aborts.
	rm -f "$PULSE_RATE_LIMIT_FLAG" 2>/dev/null || true

	if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
		echo "[pulse-wrapper] prefetch_state did not complete successfully — aborting this cycle to avoid stale dispatch decisions" >>"$LOGFILE"
		_PULSE_HEALTH_PREFETCH_ERRORS=$((_PULSE_HEALTH_PREFETCH_ERRORS + 1))
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 1
	fi

	# GH#18979 (t2097): if any prefetch site detected GraphQL rate-limit
	# exhaustion, abort the cycle cleanly. Empty prefetch data is
	# indistinguishable from a genuinely quiet backlog; proceeding would run
	# the deterministic pipeline on stale state while the instance lock is
	# held for the full cycle duration. Existing return-1 path releases the
	# lock and increments the health counter.
	if [[ -f "$PULSE_RATE_LIMIT_FLAG" ]]; then
		local _rl_affected_sites
		_rl_affected_sites=$(wc -l <"$PULSE_RATE_LIMIT_FLAG" 2>/dev/null | tr -d ' ')
		[[ "$_rl_affected_sites" =~ ^[0-9]+$ ]] || _rl_affected_sites="?"
		echo "[pulse-wrapper] Prefetch aborted: GraphQL RATE_LIMIT_EXHAUSTED (${_rl_affected_sites} site(s) affected) — skipping cycle to avoid stale dispatch decisions" >>"$LOGFILE"
		_PULSE_HEALTH_PREFETCH_ERRORS=$((_PULSE_HEALTH_PREFETCH_ERRORS + 1))
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 1
	fi

	if [[ -f "$SCOPE_FILE" ]]; then
		local persisted_scope
		persisted_scope=$(cat "$SCOPE_FILE" 2>/dev/null || echo "")
		if [[ -n "$persisted_scope" ]]; then
			export PULSE_SCOPE_REPOS="$persisted_scope"
			echo "[pulse-wrapper] Restored PULSE_SCOPE_REPOS from ${SCOPE_FILE}" >>"$LOGFILE"
		fi
	fi
	return 0
}
