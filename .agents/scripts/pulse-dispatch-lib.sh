#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-dispatch-lib.sh -- Fill-floor helpers for dispatch_max
# =============================================================================
# Sub-library extracted from pulse-dispatch-engine.sh (GH#21738) so the
# orchestrator stays under the 1500-line file-size threshold. Contains all
# `_dispatch_*` helper functions plus the shared debug logger that supports
# `dispatch_max` (which remains in the orchestrator
# because its 110-line body would re-register as a new function-complexity
# violation if moved).
#
# Module-level `_DISPATCH_*` round-state counters are defined here so the helpers
# and orchestrator share a single source of truth via the `_DISPATCH_` prefix
# (avoids bash 4.3+ namerefs).
#
# Usage: source "${SCRIPT_DIR}/pulse-dispatch-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (LOGFILE, color/status helpers, gh wrappers)
#   - worker-lifecycle-common.sh (capacity helpers, model resolution)
#   - portable-stat.sh (legacy scratch age checks)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_DISPATCH_FILL_FLOOR_LIB_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_FILL_FLOOR_LIB_LOADED=1

_PULSE_DISPATCH_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_PULSE_DISPATCH_LIB_DIR" == "${BASH_SOURCE[0]}" ]] && _PULSE_DISPATCH_LIB_DIR="."
# shellcheck source=shared-runner-identity.sh
source "${_PULSE_DISPATCH_LIB_DIR}/shared-runner-identity.sh"
if ! command -v _file_mtime_epoch >/dev/null 2>&1; then
	# shellcheck source=portable-stat.sh
	source "${_PULSE_DISPATCH_LIB_DIR}/portable-stat.sh"
fi

# --- Helper functions and module-level round-state vars (extracted) ---

# -----------------------------------------------------------------------------
# Helpers for dispatch_max (GH#18656)
# -----------------------------------------------------------------------------
# The helpers below are split out so the orchestrator stays under 100 lines
# and each discrete responsibility (capacity planning, pre-passes, per-candidate
# skip checks, launch-outcome tracking, post-round throttle) can be read and
# reviewed in isolation. Behavior is byte-for-byte equivalent to the pre-split
# monolithic function — see git log for the refactor commit.
#
# The round-state counters (_round_dispatched, _round_no_worker_failures,
# _consecutive_no_worker) are module-level with a `_DISPATCH_` prefix so the
# helpers can update them without needing bash 4.3+ namerefs.

_DISPATCH_ROUND_DISPATCHED=0
_DISPATCH_ROUND_NO_WORKER_FAILURES=0
_DISPATCH_CONSECUTIVE_NO_WORKER=0
_DISPATCH_THROTTLE_FILE=""
_DISPATCH_CANARY_CACHE=""
_DISPATCH_BENIGN_BLOCKS_FILE=""
_DISPATCH_BENIGN_BLOCKS_FILE_OWNED="0"
_DISPATCH_BENIGN_BLOCKS_SCRATCH_DIR=""
_DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS="${AIDEVOPS_PULSE_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS:-3600}"
[[ "$_DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS" =~ ^[0-9]+$ ]] || _DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS=3600
_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP="skip"
# Out-parameter set by _dispatch_process_candidate when a successful launch clears
# the throttle file. The orchestrator loop reads this and restores
# _effective_slots to the unthrottled available_slots value.
_DISPATCH_THROTTLE_CLEARED=0
_DISPATCH_TRIAGE_OUTCOME_SCHEMA="aidevops.pulse-triage-outcome/v1"

_dispatch_cycle_cache_path() {
	local kind="$1"
	local suffix="${2:-}"
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local cycle_key="${_PULSE_CYCLE_ID:-pid-$$}"
	[[ "$temp_root" == /* ]] || return 1
	if [[ ! -d "$temp_root" ]]; then
		(umask 077 && mkdir -p "$temp_root") 2>/dev/null || return 1
	fi
	[[ -d "$temp_root" && ! -L "$temp_root" ]] || return 1
	cycle_key=$(printf '%s' "$cycle_key" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
	[[ -n "$cycle_key" ]] || return 1
	printf '%s/%s.%s%s\n' "$temp_root" "$kind" "$cycle_key" "$suffix"
	return 0
}

_dispatch_candidate_snapshot_path() {
	local per_repo_limit="${1:-${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}}"
	local dependency_normalization_mode="${2:-normalize}"
	local mode_suffix=""
	[[ "$per_repo_limit" =~ ^[0-9]+$ ]] || per_repo_limit=1000
	[[ "$dependency_normalization_mode" == "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP" ]] || dependency_normalization_mode="normalize"
	[[ "$dependency_normalization_mode" == "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP" ]] && mode_suffix=".skip"
	_dispatch_cycle_cache_path "pulse-dispatch-candidates" ".${per_repo_limit}${mode_suffix}.json"
	return $?
}

_dispatch_cleanup_cycle_cache() {
	local per_repo_limit="${1:-${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}}"
	local candidate_file="" skip_candidate_file="" triage_file="" cache_file=""
	candidate_file=$(_dispatch_candidate_snapshot_path "$per_repo_limit" 2>/dev/null || true)
	skip_candidate_file=$(_dispatch_candidate_snapshot_path "$per_repo_limit" "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP" 2>/dev/null || true)
	triage_file=$(_dispatch_cycle_cache_path "pulse-triage-prepass" ".done" 2>/dev/null || true)
	for cache_file in "$candidate_file" "$skip_candidate_file" "$triage_file"; do
		[[ -n "$cache_file" && ( -f "$cache_file" || -L "$cache_file" ) ]] || continue
		rm -f "$cache_file" 2>/dev/null || true
	done
	return 0
}

_dispatch_invalidate_candidate_snapshot() {
	local reason="${1:-state_mutation}"
	local per_repo_limit="${2:-${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}}"
	local snapshot_file="" dependency_normalization_mode="" removed_snapshot=0
	for dependency_normalization_mode in normalize "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP"; do
		snapshot_file=$(_dispatch_candidate_snapshot_path "$per_repo_limit" "$dependency_normalization_mode") || continue
		if [[ -f "$snapshot_file" && ! -L "$snapshot_file" ]]; then
			rm -f "$snapshot_file" 2>/dev/null || return 1
			removed_snapshot=1
		fi
	done
	if [[ "$removed_snapshot" -eq 1 ]]; then
		echo "[pulse-wrapper] Dispatch candidate snapshot invalidated: reason=${reason}" >>"$LOGFILE"
	fi
	return 0
}

_dispatch_ranked_candidates_json() {
	local per_repo_limit="${1:-${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}}"
	local dependency_normalization_mode="${2:-normalize}"
	local snapshot_file="" snapshot_tmp="" candidates_json="[]"
	[[ "$per_repo_limit" =~ ^[0-9]+$ ]] || per_repo_limit=1000
	[[ "$dependency_normalization_mode" == "$_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP" ]] || dependency_normalization_mode="normalize"
	if [[ "${PULSE_DISPATCH_CANDIDATE_SNAPSHOT_ENABLED:-1}" == "0" ]]; then
		build_ranked_dispatch_candidates_json "$per_repo_limit" "$dependency_normalization_mode"
		return $?
	fi
	snapshot_file=$(_dispatch_candidate_snapshot_path "$per_repo_limit" "$dependency_normalization_mode") || {
		build_ranked_dispatch_candidates_json "$per_repo_limit" "$dependency_normalization_mode"
		return $?
	}
	if [[ -f "$snapshot_file" && ! -L "$snapshot_file" ]] && jq -e 'type == "array"' "$snapshot_file" >/dev/null 2>&1; then
		printf '%s\n' "$(<"$snapshot_file")"
		_dispatch_stats_increment "dispatch_candidate_snapshot_hit"
		return 0
	fi
	if [[ -L "$snapshot_file" ]]; then
		rm -f "$snapshot_file" 2>/dev/null || {
			build_ranked_dispatch_candidates_json "$per_repo_limit" "$dependency_normalization_mode"
			return $?
		}
	fi
	candidates_json=$(build_ranked_dispatch_candidates_json "$per_repo_limit" "$dependency_normalization_mode") || candidates_json='[]'
	if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$candidates_json"; then
		candidates_json='[]'
	fi
	snapshot_tmp=$(mktemp "${snapshot_file}.tmp.XXXXXX" 2>/dev/null || true)
	if [[ -n "$snapshot_tmp" ]] && (umask 077 && printf '%s\n' "$candidates_json" >"$snapshot_tmp") 2>/dev/null; then
		mv "$snapshot_tmp" "$snapshot_file" 2>/dev/null || rm -f "$snapshot_tmp" 2>/dev/null || true
	elif [[ -n "$snapshot_tmp" ]]; then
		rm -f "$snapshot_tmp" 2>/dev/null || true
	fi
	_dispatch_stats_increment "dispatch_candidate_snapshot_miss"
	printf '%s\n' "$candidates_json"
	return 0
}

_dispatch_triage_outcome_is_valid() {
	local outcome_json="$1"
	jq -e --arg schema "$_DISPATCH_TRIAGE_OUTCOME_SCHEMA" '
		type == "object"
		and .schema == $schema
		and ([.attempted, .posted, .review_failed, .infrastructure_failed, .preparation_failed]
			| all(type == "number" and floor == . and . >= 0))
		and .attempted == (.posted + .review_failed + .infrastructure_failed)
	' >/dev/null 2>&1 <<<"$outcome_json"
	return $?
}

_dispatch_triage_fallback_outcome() {
	local infrastructure_failed="$1"
	jq -cn \
		--arg schema "$_DISPATCH_TRIAGE_OUTCOME_SCHEMA" \
		--argjson infrastructure_failed "$infrastructure_failed" \
		'{schema:$schema, attempted:$infrastructure_failed, posted:0, review_failed:0, infrastructure_failed:$infrastructure_failed, preparation_failed:0}'
	return $?
}

_dispatch_triage_outcomes_sum() {
	local prior_outcome="$1"
	local current_outcome="$2"
	jq -cn \
		--arg schema "$_DISPATCH_TRIAGE_OUTCOME_SCHEMA" \
		--argjson prior "$prior_outcome" \
		--argjson current "$current_outcome" \
		'{schema:$schema,
		attempted:($prior.attempted + $current.attempted),
		posted:($prior.posted + $current.posted),
		review_failed:($prior.review_failed + $current.review_failed),
		infrastructure_failed:($prior.infrastructure_failed + $current.infrastructure_failed),
		preparation_failed:($prior.preparation_failed + $current.preparation_failed)}'
	return $?
}

_dispatch_triage_marker_refresh_is_due() {
	local triage_marker="$1"
	local refresh_interval="${PULSE_TRIAGE_REFRESH_INTERVAL_SECONDS:-300}"
	local marker_mtime=0 now_epoch=0 marker_age=0
	[[ "$refresh_interval" =~ ^[0-9]+$ ]] || refresh_interval=300
	[[ -f "$triage_marker" && ! -L "$triage_marker" ]] || return 0
	marker_mtime=$(_file_mtime_epoch "$triage_marker" 2>/dev/null) || return 0
	now_epoch=$(date +%s 2>/dev/null) || return 1
	[[ "$marker_mtime" =~ ^[0-9]+$ ]] || return 0
	marker_age=$((now_epoch - marker_mtime))
	[[ "$marker_age" -ge "$refresh_interval" ]]
	return $?
}

_dispatch_write_triage_marker() {
	local triage_marker="$1"
	local triage_outcome="$2"
	local triage_marker_tmp=""
	[[ -n "$triage_marker" && ! -L "$triage_marker" ]] || return 1
	triage_marker_tmp=$(mktemp "${triage_marker}.tmp.XXXXXX" 2>/dev/null) || return 1
	if (umask 077 && printf '%s\n' "$triage_outcome" >"$triage_marker_tmp") 2>/dev/null && \
		mv "$triage_marker_tmp" "$triage_marker" 2>/dev/null; then
		return 0
	fi
	rm -f "$triage_marker_tmp" 2>/dev/null || true
	return 1
}

#######################################
# Emit per-candidate debug output for the dispatch_max (GH#18804).
#
# Always writes to LOGFILE (so the operator sees it in pulse.log). When
# PULSE_DEBUG is set to a truthy value, the message is prefixed with DEBUG:
# and emitted unconditionally — useful for one-off operator runs that need
# verbose per-candidate visibility into label state, dedup probes, and skip
# decisions.
#
# Arguments:
#   $1 - message body (plain text, no leading prefix)
# Returns: 0 always
#######################################
pulse_dispatch_debug_log() {
	local message="$1"
	case "${PULSE_DEBUG:-}" in
	1 | true | TRUE | yes | YES | on | ON)
		echo "[pulse-wrapper] DFF DEBUG: ${message}" >>"$LOGFILE"
		;;
	esac
	return 0
}

#######################################
# Increment a pulse-stats counter when the stats helper is loaded.
#
# Arguments:
#   $1 - counter name
# Returns: 0 always (telemetry must never block dispatch).
#######################################
_dispatch_stats_increment() {
	local counter_name="$1"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "$counter_name" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Increment the aggregate dispatch-candidate failure counter plus a stable
# reason-coded counter.
#
# Arguments:
#   $1 - low-cardinality reason token
# Returns: 0 always (telemetry must never block dispatch).
#######################################
_dispatch_stats_increment_candidate_failed() {
	local reason="$1"
	case "$reason" in
		blocked_by_native_lookup_unavailable | blocked_by_unresolved | canary_failed | consolidated | cooldown_no_worker_process | cost_budget_exceeded | dedup_active_claim | dirty_worktree_recovery | ever_nmr_without_approval | footprint_overlap | graphql_circuit_breaker | healthy_pr_backlog | interactive_review_hold | issue_closed | launch_error | local_capacity_gate | missing_worker_context | no_auto_dispatch | no_dispatchable_evidence | no_recent_log_evidence | parent_task | policy_gate | pr_target_not_dispatchable | provider_rate_limit_pressure | renovate_dependency_dashboard | repeated_failure_pressure | runner_health_circuit_breaker | unclassified_signal)
			;;
		*)
			reason="unclassified_signal"
			;;
	esac
	_dispatch_stats_increment "dispatch_candidate_failed"
	_dispatch_stats_increment "dispatch_candidate_failed_reason_${reason}"
	return 0
}

#######################################
# Classify a failed dispatch_with_dedup return using recent candidate log lines.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - dispatch rc
# Stdout: low-cardinality reason token
#######################################
_dispatch_candidate_failure_reason() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_rc="$3"
	local recent_lines=""
	local reason="no_recent_log_evidence"

	if [[ "$dispatch_rc" -eq 124 ]]; then
		printf 'launch_error\n'
		return 0
	fi
	if [[ "$dispatch_rc" -eq 2 ]]; then
		printf 'canary_failed\n'
		return 0
	fi

	if [[ -n "${LOGFILE:-}" && -f "$LOGFILE" ]]; then
		recent_lines=$(awk -v issue="#${issue_number}" -v repo="$repo_slug" '
			index($0, issue) && index($0, repo) { lines[++n] = $0 }
			END {
				start = n - 20
				if (start < 1) { start = 1 }
				for (i = start; i <= n; i++) { print lines[i] }
			}
		' "$LOGFILE" 2>/dev/null) || recent_lines=""
	fi

	if [[ "$recent_lines" == *"has active dispatch comment"* || "$recent_lines" == *"active claim"* ]]; then
		printf 'dedup_active_claim\n'
		return 0
	fi

	if [[ "$recent_lines" == *"DISPATCH_BLOCK_REASON reason="* ]]; then
		reason=$(printf '%s\n' "$recent_lines" | awk '
			match($0, /DISPATCH_BLOCK_REASON reason=[a-z_]+/) {
				reason = substr($0, RSTART, RLENGTH)
				sub(/^DISPATCH_BLOCK_REASON reason=/, "", reason)
			}
			END { if (reason != "") { print reason } }
		') || reason="unclassified_signal"
		[[ -n "$reason" ]] || reason="unclassified_signal"
		printf '%s\n' "$reason"
		return 0
	fi

	if [[ -x "${SCRIPT_DIR:-}/dispatch-dedup-helper.sh" && -n "$recent_lines" ]]; then
		reason=$("${SCRIPT_DIR}/dispatch-dedup-helper.sh" classify-blocker "$recent_lines" 2>/dev/null) || reason="unclassified_signal"
		[[ -n "$reason" ]] || reason="unclassified_signal"
	fi

	printf '%s\n' "$reason"
	return 0
}

#######################################
# Return success when a dispatch candidate reason is an expected benign block.
#
# Arguments:
#   $1 - low-cardinality reason token
# Returns:
#   0 - benign block reason
#   1 - not a benign block reason
#######################################
_dispatch_candidate_benign_block_reason() {
	local reason="$1"
	case "$reason" in
		blocked_by_unresolved | consolidated | dedup_active_claim | dirty_worktree_recovery | footprint_overlap | interactive_review_hold | issue_closed | no_auto_dispatch | parent_task | pr_target_not_dispatchable | renovate_dependency_dashboard)
			return 0
			;;
	esac
	return 1
}

#######################################
# Detect unresolved recent worker-dirty-worktree recovery markers on an issue.
#
# A dirty marker means a worker edited local files but crashed before it could
# commit or open a PR. Redispatching another worker before recovery duplicates
# effort and can overwrite the only useful evidence. Hold briefly unless a later
# maintainer/worker comment explicitly marks recovery as resolved.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - recent unresolved dirty-worktree marker exists
#   1 - no active marker, expired marker, disabled, or API unavailable
#######################################
_dispatch_recent_dirty_worktree_marker_active() {
	local issue_number="$1"
	local repo_slug="$2"
	local hold_seconds="${DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS:-900}"
	_DISPATCH_DIRTY_MARKER_STATE="clear"

	[[ "$hold_seconds" =~ ^[0-9]+$ ]] || hold_seconds="900"
	[[ "$hold_seconds" -gt 0 ]] || return 1

	local comments_json=""
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" 2>/dev/null) || return 1
	[[ -n "$comments_json" ]] || return 1

	local marker_state=""
	marker_state=$(printf '%s' "$comments_json" | \
		python3 "${_PULSE_DISPATCH_LIB_DIR}/pulse-dirty-worktree-marker.py" \
			"$hold_seconds" "${AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH:-}") || marker_state=""
	_DISPATCH_DIRTY_MARKER_STATE="${marker_state:-clear}"

	[[ "$marker_state" == block:* ]] || return 1
	return 0
}

#######################################
# Parse the creator PID from an exact framework-managed benign-ledger name.
#
# Arguments:
#   $1 - file basename
# Stdout: creator PID
# Returns: 0 for an exact managed name, 1 otherwise
#######################################
_dispatch_benign_blocks_owner_pid() {
	local basename="$1"
	if [[ "$basename" =~ ^benign-blocks\.([1-9][0-9]*)\.([[:alnum:]]{6}|[0-9]{1,5})$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

#######################################
# Remove exact framework-managed ledgers whose creator PID is no longer alive.
# Live-owner files, symlinks, foreign-owned files, and near-matches survive.
#
# Arguments:
#   $1 - private managed scratch directory
# Returns: 0 on a safe scan, 1 when the directory boundary is unsafe
#######################################
_dispatch_cleanup_managed_benign_blocks() {
	local scratch_dir="$1"
	local candidate=""
	local basename=""
	local owner_pid=""
	[[ -d "$scratch_dir" && ! -L "$scratch_dir" && -O "$scratch_dir" ]] || return 1
	for candidate in "$scratch_dir"/benign-blocks.*.*; do
		[[ -f "$candidate" && ! -L "$candidate" && -O "$candidate" ]] || continue
		basename="${candidate##*/}"
		owner_pid=$(_dispatch_benign_blocks_owner_pid "$basename") || continue
		if ! kill -0 "$owner_pid" 2>/dev/null; then
			rm -f "$candidate" 2>/dev/null || true
		fi
	done
	return 0
}

#######################################
# Remove age-qualified legacy ledgers whose old names carry no reliable owner.
# The exact historical mktemp and numeric-fallback grammars are the only files
# eligible for migration cleanup.
#
# Returns: 0 always; migration cleanup must never block pulse startup
#######################################
_dispatch_cleanup_legacy_benign_blocks() {
	local logs_dir="${HOME}/.aidevops/logs"
	local candidate=""
	local basename=""
	local modified=""
	local now=""
	local age=0
	[[ -d "$logs_dir" ]] || return 0
	command -v _file_mtime_epoch >/dev/null 2>&1 || return 0
	now=$(date +%s 2>/dev/null) || return 0
	[[ "$now" =~ ^[0-9]+$ ]] || return 0
	for candidate in "$logs_dir"/pulse-dispatch-benign-blocks.*; do
		[[ -f "$candidate" && ! -L "$candidate" && -O "$candidate" ]] || continue
		basename="${candidate##*/}"
		if [[ "$basename" =~ ^pulse-dispatch-benign-blocks\.[[:alnum:]]{6}$ ]]; then
			:
		elif [[ "$basename" =~ ^pulse-dispatch-benign-blocks\.[1-9][0-9]*\.[0-9]{1,5}$ ]]; then
			:
		else
			continue
		fi
		modified=$(_file_mtime_epoch "$candidate") || continue
		[[ "$modified" =~ ^[0-9]+$ && "$now" -ge "$modified" ]] || continue
		age=$((now - modified))
		[[ "$age" -ge "$_DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS" ]] || continue
		rm -f "$candidate" 2>/dev/null || true
	done
	return 0
}

#######################################
# Reap stale managed and legacy benign ledgers at the exclusive startup gate.
#
# Returns: 0 always; stale-file cleanup is best effort
#######################################
_dispatch_cleanup_stale_benign_blocks() {
	local scratch_dir="${HOME}/.aidevops/logs/.pulse-dispatch-benign-blocks"
	if [[ -d "$scratch_dir" && ! -L "$scratch_dir" && -O "$scratch_dir" ]]; then
		_dispatch_cleanup_managed_benign_blocks "$scratch_dir" || true
	fi
	_dispatch_cleanup_legacy_benign_blocks || true
	return 0
}

#######################################
# Prepare the private scratch boundary used by framework-managed ledgers.
#
# Returns: 0 when the directory is safe, 1 otherwise
#######################################
_dispatch_prepare_benign_blocks_scratch_dir() {
	local logs_dir="${HOME}/.aidevops/logs"
	local scratch_dir="${logs_dir}/.pulse-dispatch-benign-blocks"
	if ! mkdir -p "$logs_dir"; then
		return 1
	fi
	if [[ ! -e "$scratch_dir" && ! -L "$scratch_dir" ]]; then
		if ! (umask 077 && mkdir "$scratch_dir" 2>/dev/null); then
			[[ -d "$scratch_dir" && ! -L "$scratch_dir" ]] || return 1
		fi
	fi
	[[ -d "$scratch_dir" && ! -L "$scratch_dir" && -O "$scratch_dir" ]] || return 1
	chmod 0700 "$scratch_dir" 2>/dev/null || return 1
	_DISPATCH_BENIGN_BLOCKS_SCRATCH_DIR="$scratch_dir"
	_dispatch_cleanup_managed_benign_blocks "$scratch_dir" || return 1
	return 0
}

#######################################
# Start a cycle-local benign block ledger. Reinitializing the ledger for every
# dispatch_max cycle prevents stale active-claim blocks from a long-running
# pulse-wrapper process from suppressing later cycles after the claim clears.
#
# Stdout: file path
# Returns: 0 always
#######################################
_dispatch_begin_benign_blocks_cycle() {
	local ledger_file=""
	local ledger_managed_by_dispatch="0"
	local owner_pid="${BASHPID:-$$}"
	if [[ -n "${AIDEVOPS_PULSE_BENIGN_BLOCKS_FILE:-}" ]]; then
		ledger_file="$AIDEVOPS_PULSE_BENIGN_BLOCKS_FILE"
	else
		ledger_managed_by_dispatch="1"
		[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || owner_pid="$$"
		if ! _dispatch_prepare_benign_blocks_scratch_dir; then
			printf 'Failed to prepare benign block ledger scratch directory: %s\n' "${HOME}/.aidevops/logs/.pulse-dispatch-benign-blocks" >&2
		else
			ledger_file=$(mktemp "${_DISPATCH_BENIGN_BLOCKS_SCRATCH_DIR}/benign-blocks.${owner_pid}.XXXXXX" 2>/dev/null || printf '%s\n' "${_DISPATCH_BENIGN_BLOCKS_SCRATCH_DIR}/benign-blocks.${owner_pid}.${RANDOM}")
		fi
	fi
	if [[ -z "$ledger_file" ]]; then
		printf 'Failed to resolve benign block ledger file path\n' >&2
		_DISPATCH_BENIGN_BLOCKS_FILE=""
		_DISPATCH_BENIGN_BLOCKS_FILE_OWNED="0"
		return 0
	fi
	if [[ "$ledger_managed_by_dispatch" == "0" && "$ledger_file" == */* ]]; then
		local parent_dir
		parent_dir="${ledger_file%/*}"
		if [[ -n "$parent_dir" ]] && ! mkdir -p -- "$parent_dir"; then
			printf 'Failed to create benign block ledger parent directory: %s\n' "$parent_dir" >&2
		fi
	fi
	if ! : >"$ledger_file"; then
		printf 'Failed to initialize benign block ledger file: %s\n' "$ledger_file" >&2
	fi
	if [[ "$ledger_managed_by_dispatch" == "1" ]] && ! chmod 0600 "$ledger_file" 2>/dev/null; then
		printf 'Failed to secure benign block ledger file: %s\n' "$ledger_file" >&2
	fi
	_DISPATCH_BENIGN_BLOCKS_FILE="$ledger_file"
	_DISPATCH_BENIGN_BLOCKS_FILE_OWNED="$ledger_managed_by_dispatch"
	export _DISPATCH_BENIGN_BLOCKS_FILE
	printf '%s\n' "$_DISPATCH_BENIGN_BLOCKS_FILE"
	return 0
}

#######################################
# Remove the cycle-local benign block ledger once the dispatch loop has read it.
#
# Returns: 0 always
#######################################
_dispatch_cleanup_benign_blocks_cycle() {
	local ledger_file="${_DISPATCH_BENIGN_BLOCKS_FILE:-}"
	local ledger_owned="${_DISPATCH_BENIGN_BLOCKS_FILE_OWNED:-0}"
	if [[ -n "$ledger_file" && "$ledger_owned" == "1" ]] && ! rm -f "$ledger_file"; then
		printf 'Failed to remove benign block ledger file: %s\n' "$ledger_file" >&2
	fi
	_DISPATCH_BENIGN_BLOCKS_FILE=""
	_DISPATCH_BENIGN_BLOCKS_FILE_OWNED="0"
	return 0
}

#######################################
# Return the current cycle-local benign block ledger path, creating a default
# when the orchestrator has not explicitly started a ledger.
#
# Stdout: file path
# Returns: 0 always
#######################################
_dispatch_benign_blocks_file() {
	if [[ -z "${_DISPATCH_BENIGN_BLOCKS_FILE:-}" ]]; then
		_dispatch_begin_benign_blocks_cycle >/dev/null
	fi
	printf '%s\n' "$_DISPATCH_BENIGN_BLOCKS_FILE"
	return 0
}

#######################################
# Record a candidate that hit a benign dispatch block in the current pulse.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - benign reason token
# Returns: 0 always
#######################################
_dispatch_mark_benign_blocked_candidate() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local ledger_file
	ledger_file=$(_dispatch_benign_blocks_file)
	mkdir -p "${ledger_file%/*}" 2>/dev/null || true
	printf '%s\t%s\t%s\n' "$issue_number" "$repo_slug" "$reason" >>"$ledger_file" 2>/dev/null || true
	return 0
}

#######################################
# Check whether a candidate already hit a benign dispatch block this pulse.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Stdout: benign reason token when present
# Returns:
#   0 - candidate is blocked for this pulse
#   1 - candidate is not blocked
#######################################
_dispatch_benign_blocked_candidate_reason() {
	local issue_number="$1"
	local repo_slug="$2"
	local ledger_file
	local reason=""
	ledger_file=$(_dispatch_benign_blocks_file)
	[[ -f "$ledger_file" ]] || return 1
	reason=$(awk -F '\t' -v issue="$issue_number" -v repo="$repo_slug" '
		$1 == issue && $2 == repo { reason = $3 }
		END { if (reason != "") { print reason } }
	' "$ledger_file" 2>/dev/null) || return 1
	[[ -n "$reason" ]] || return 1
	printf '%s\n' "$reason"
	return 0
}

#######################################
# Run a dispatch candidate under the stage watchdog while preserving benign
# block return codes without emitting generic Stage failed noise.
#
# Arguments:
#   $1 - file path where the raw dispatch rc should be written
#   $2.. - command and arguments to execute
# Returns:
#   0 for success or benign expected block rc=3; otherwise the command rc.
#######################################
_dispatch_stage_rc_adapter() {
	local rc_file="$1"
	shift

	local raw_rc=0
	"$@" || raw_rc=$?
	if ! printf '%s\n' "$raw_rc" >"$rc_file"; then
		printf 'Failed to write dispatch rc to %s\n' "$rc_file" >&2
		return "$raw_rc"
	fi
	if [[ "$raw_rc" -eq 3 ]]; then
		return 0
	fi
	return "$raw_rc"
}

#######################################
# Set a pulse-stats gauge when the stats helper is loaded.
#
# Arguments:
#   $1 - gauge name
#   $2 - integer value
# Returns: 0 always (telemetry must never block dispatch).
#######################################
_dispatch_stats_gauge() {
	local gauge_name="$1"
	local gauge_value="${2:-0}"
	if declare -F pulse_stats_set_gauge >/dev/null 2>&1; then
		pulse_stats_set_gauge "$gauge_name" "$gauge_value" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Count recent worker failure/rate-limit metrics for launch pacing.
#
# Stdout: "<failures> <rate_limits>".
#######################################
_dispatch_recent_worker_pressure_counts() {
	local failure_override="${PULSE_DISPATCH_STAGGER_RECENT_FAILURES:-}"
	local rate_limit_override="${PULSE_DISPATCH_STAGGER_RECENT_RATE_LIMITS:-}"
	if [[ "$failure_override" =~ ^[0-9]+$ || "$rate_limit_override" =~ ^[0-9]+$ ]]; then
		[[ "$failure_override" =~ ^[0-9]+$ ]] || failure_override=0
		[[ "$rate_limit_override" =~ ^[0-9]+$ ]] || rate_limit_override=0
		printf '%s %s\n' "$failure_override" "$rate_limit_override"
		return 0
	fi

	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_limit="${AIDEVOPS_OBJECTIVE_EVIDENCE_LIMIT:-2000}"
	local ttl_seconds="${PULSE_DISPATCH_STAGGER_FAILURE_WINDOW_SECONDS:-900}"
	local health_helper="${_PULSE_DISPATCH_LIB_DIR}/worker-terminal-health.py"
	[[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=900
	[[ "$evidence_limit" =~ ^[1-9][0-9]*$ ]] || evidence_limit=2000
	[[ -f "$metrics_file" ]] || { printf '0 0\n'; return 0; }
	local health_counts="" successes="" failures="" rate_limits="" service_interruptions="" provider_5xx="" progress=""
	health_counts=$(python3 "$health_helper" "$metrics_file" "$evidence_file" "$ttl_seconds" "$evidence_limit") || health_counts="0 3 0 0 0 0"
	read -r successes failures rate_limits service_interruptions provider_5xx progress <<<"$health_counts"
	printf '%s %s\n' "$failures" "$rate_limits"
	return 0
}

#######################################
# Return cached GraphQL remaining budget for launch pacing.
#
# Stdout: integer remaining budget, or blank when unavailable.
#######################################
_dispatch_graphql_remaining_cached() {
	if [[ -n "${PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING:-}" ]]; then
		printf '%s\n' "$PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING"
		return 0
	fi
	if [[ -n "${_DISPATCH_STAGGER_GRAPHQL_REMAINING:-}" ]]; then
		printf '%s\n' "$_DISPATCH_STAGGER_GRAPHQL_REMAINING"
		return 0
	fi
	_DISPATCH_STAGGER_GRAPHQL_REMAINING=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null || printf '\n')
	printf '%s\n' "$_DISPATCH_STAGGER_GRAPHQL_REMAINING"
	return 0
}

_dispatch_failure_pressure_points() {
	local recent_failures="$1"
	[[ "$recent_failures" =~ ^[0-9]+$ ]] || recent_failures=0
	if ((recent_failures >= 3)); then
		printf '4\n'
		return 0
	fi
	if ((recent_failures >= 1)); then
		printf '2\n'
		return 0
	fi
	printf '0\n'
	return 0
}

_dispatch_provider_pressure_points() {
	local recent_rate_limits="$1"
	local provider_backoff_active="${PULSE_DISPATCH_PROVIDER_BACKOFF_ACTIVE:-0}"
	[[ "$recent_rate_limits" =~ ^[0-9]+$ ]] || recent_rate_limits=0
	if [[ "$provider_backoff_active" == "1" || "$recent_rate_limits" -gt 0 || -f "${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}" ]]; then
		printf '6\n'
		return 0
	fi
	printf '0\n'
	return 0
}

_dispatch_graphql_pressure_points() {
	local graphql_remaining="" graphql_low="" graphql_critical=""
	graphql_remaining=$(_dispatch_graphql_remaining_cached)
	graphql_low="${PULSE_DISPATCH_STAGGER_GRAPHQL_LOW:-1250}"
	graphql_critical="${PULSE_DISPATCH_STAGGER_GRAPHQL_CRITICAL:-750}"
	[[ "$graphql_low" =~ ^[0-9]+$ ]] || graphql_low=1250
	[[ "$graphql_critical" =~ ^[0-9]+$ ]] || graphql_critical=750
	if [[ "$graphql_remaining" =~ ^[0-9]+$ ]]; then
		if ((graphql_remaining < graphql_critical)); then
			printf '4\n'
			return 0
		fi
		if ((graphql_remaining < graphql_low)); then
			printf '2\n'
			return 0
		fi
	fi
	printf '0\n'
	return 0
}

_dispatch_finalize_stagger_delay() {
	local pressure_points="$1"
	local launches_so_far="$2"
	local candidate_index="$3"
	local candidate_json="$4"
	[[ "$pressure_points" =~ ^[0-9]+$ ]] || pressure_points=0
	if ((pressure_points <= 0)); then
		printf '0\n'
		return 0
	fi
	local issue_number="" jitter_max="" jitter="" delay="" cap=""
	issue_number=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
	[[ "$issue_number" =~ ^[0-9]+$ ]] || issue_number=0
	jitter_max="${PULSE_DISPATCH_STAGGER_JITTER_MAX_SECONDS:-3}"
	cap="${PULSE_DISPATCH_STAGGER_MAX_SECONDS:-20}"
	[[ "$jitter_max" =~ ^[0-9]+$ ]] || jitter_max=3
	[[ "$cap" =~ ^[0-9]+$ ]] || cap=20
	jitter=0
	if ((jitter_max > 0)); then
		jitter=$(((issue_number + candidate_index + launches_so_far) % (jitter_max + 1)))
	fi
	delay=$((pressure_points + jitter))
	((delay > cap)) && delay="$cap"
	_dispatch_stats_gauge "dispatch_inter_launch_delay_seconds" "$delay"
	printf '%d\n' "$delay"
	return 0
}

#######################################
# Compute adaptive inter-launch delay for parallel worker dispatch.
#
# Arguments:
#   $1 - launches already started in this round
#   $2 - candidate index in this loop
#   $3 - candidate JSON
#   $4 - max parallelism for this round
# Stdout: integer seconds to sleep before launching this candidate.
#######################################
_dispatch_inter_launch_delay() {
	local launches_so_far="${1:-0}"
	local candidate_index="${2:-0}"
	local candidate_json="${3:-}"
	local max_parallel="${4:-1}"
	[[ "$launches_so_far" =~ ^[0-9]+$ ]] || launches_so_far=0
	[[ "$candidate_index" =~ ^[0-9]+$ ]] || candidate_index=0
	[[ "$max_parallel" =~ ^[0-9]+$ ]] || max_parallel=1
	if [[ "${PULSE_DISPATCH_STAGGER_ADAPTIVE:-1}" == "0" || "$launches_so_far" -eq 0 ]]; then
		printf '0\n'
		return 0
	fi

	local pressure_points=0
	local recent_failures="" recent_rate_limits="" pressure_line=""
	pressure_line=$(_dispatch_recent_worker_pressure_counts)
	read -r recent_failures recent_rate_limits <<<"$pressure_line"
	[[ "$recent_failures" =~ ^[0-9]+$ ]] || recent_failures=0
	[[ "$recent_rate_limits" =~ ^[0-9]+$ ]] || recent_rate_limits=0
	pressure_points=$((pressure_points + $(_dispatch_failure_pressure_points "$recent_failures")))
	pressure_points=$((pressure_points + $(_dispatch_provider_pressure_points "$recent_rate_limits")))
	pressure_points=$((pressure_points + $(_dispatch_graphql_pressure_points)))

	if ((max_parallel >= 4 && launches_so_far >= 4 && pressure_points > 0)); then
		pressure_points=$((pressure_points + 1))
	fi
	_dispatch_finalize_stagger_delay "$pressure_points" "$launches_so_far" "$candidate_index" "$candidate_json"
	return 0
}

_dispatch_ramp_now() {
	if [[ "${AIDEVOPS_PULSE_DISPATCH_RAMP_NOW:-}" =~ ^[0-9]+$ ]]; then
		printf '%s' "$AIDEVOPS_PULSE_DISPATCH_RAMP_NOW"
		return 0
	fi
	date +%s
	return 0
}

_dispatch_ramp_system_boot_ts() {
	local boot_ts="${1:-}"
	if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
		printf '%s' "$boot_ts"
		return 0
	fi
	if declare -F _gh_secondary_system_boot_ts >/dev/null 2>&1; then
		boot_ts="$(_gh_secondary_system_boot_ts 2>/dev/null || true)"
		if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
			printf '%s' "$boot_ts"
			return 0
		fi
	fi
	if [[ -r /proc/stat ]]; then
		boot_ts=$(sed -nE 's/^btime[[:space:]]+([0-9]+).*/\1/p' /proc/stat 2>/dev/null | sed -n '1p')
		if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
			printf '%s' "$boot_ts"
			return 0
		fi
	fi
	if command -v sysctl >/dev/null 2>&1; then
		boot_ts=$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/.*sec = ([0-9]+).*/\1/p' | sed -n '1p')
		if [[ "$boot_ts" =~ ^[0-9]+$ ]]; then
			printf '%s' "$boot_ts"
			return 0
		fi
	fi
	return 1
}

_dispatch_ramp_cooldown_expires_at() {
	local expires="${1:-}"
	local file="${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE:-${HOME}/.aidevops/cache/gh-secondary-cooldown.json}"
	if [[ "$expires" =~ ^[0-9]+$ ]]; then
		printf '%s' "$expires"
		return 0
	fi
	if declare -F _gh_secondary_cooldown_expires_at >/dev/null 2>&1; then
		expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
		if [[ "$expires" =~ ^[0-9]+$ ]]; then
			printf '%s' "$expires"
			return 0
		fi
	fi
	[[ -f "$file" ]] || return 1
	if command -v jq >/dev/null 2>&1; then
		expires=$(jq -r '.expires_at // 0' "$file" 2>/dev/null || true)
	else
		expires=$(sed -nE 's/.*"expires_at"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$file" | sed -n '1p')
	fi
	if [[ "$expires" =~ ^[0-9]+$ ]]; then
		printf '%s' "$expires"
		return 0
	fi
	return 1
}

_dispatch_ramp_phase_start() {
	local now=""
	local boot_ts="${1:-}"
	local expires="${2:-}"
	local boot_secs="${AIDEVOPS_PULSE_DISPATCH_RAMP_BOOT_SECS:-${AIDEVOPS_GH_READ_RAMP_BOOT_SECS:-180}}"
	local recovery_secs="${AIDEVOPS_PULSE_DISPATCH_RAMP_RECOVERY_SECS:-${AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS:-300}}"
	if [[ "${AIDEVOPS_PULSE_DISPATCH_RAMP_START_EPOCH:-}" =~ ^[0-9]+$ ]]; then
		printf '%s %s\n' "${AIDEVOPS_PULSE_DISPATCH_RAMP_PHASE:-manual}" "$AIDEVOPS_PULSE_DISPATCH_RAMP_START_EPOCH"
		return 0
	fi
	now="$(_dispatch_ramp_now)"
	if [[ "$boot_secs" =~ ^[0-9]+$ && "$boot_secs" -gt 0 ]]; then
		if [[ ! "$boot_ts" =~ ^[0-9]+$ ]]; then
			boot_ts="$(_dispatch_ramp_system_boot_ts "" 2>/dev/null || true)"
		fi
		if [[ "$boot_ts" =~ ^[0-9]+$ && "$now" -ge "$boot_ts" && $((now - boot_ts)) -lt "$boot_secs" ]]; then
			printf 'boot %s\n' "$boot_ts"
			return 0
		fi
	fi
	if [[ "$recovery_secs" =~ ^[0-9]+$ && "$recovery_secs" -gt 0 ]]; then
		if [[ ! "$expires" =~ ^[0-9]+$ ]]; then
			expires="$(_dispatch_ramp_cooldown_expires_at "" 2>/dev/null || true)"
		fi
		if [[ "$expires" =~ ^[0-9]+$ && "$now" -ge "$expires" && $((now - expires)) -lt "$recovery_secs" ]]; then
			printf 'cooldown-recovery %s\n' "$expires"
			return 0
		fi
	fi
	return 1
}

_dispatch_apply_startup_capacity_ramp() {
	local max_workers="$1"
	local active_workers="$2"
	local slot_secs="${AIDEVOPS_PULSE_DISPATCH_RAMP_SLOT_SECS:-120}"
	local boot_ts="${3:-}"
	local expires="${4:-}"
	local now=""
	local phase_line=""
	local phase=""
	local start_ts=""
	local elapsed=0
	local ramp_cap=1
	[[ "${AIDEVOPS_PULSE_DISPATCH_RAMP_ENABLED:-1}" == "1" ]] || {
		printf '%s\n' "$max_workers"
		return 0
	}
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$slot_secs" =~ ^[0-9]+$ && "$slot_secs" -gt 0 ]] || slot_secs=120
	phase_line="$(_dispatch_ramp_phase_start "$boot_ts" "$expires" 2>/dev/null || true)"
	[[ -n "$phase_line" ]] || {
		printf '%s\n' "$max_workers"
		return 0
	}
	read -r phase start_ts <<<"$phase_line"
	[[ "$start_ts" =~ ^[0-9]+$ ]] || {
		printf '%s\n' "$max_workers"
		return 0
	}
	now="$(_dispatch_ramp_now)"
	if [[ "$now" =~ ^[0-9]+$ && "$now" -ge "$start_ts" ]]; then
		elapsed=$((now - start_ts))
	fi
	ramp_cap=$((1 + (elapsed / slot_secs)))
	((ramp_cap < 1)) && ramp_cap=1
	if ((ramp_cap < max_workers)); then
		echo "[pulse-wrapper] Dispatch_ramp active: phase=${phase} cap=${ramp_cap} max_workers=${max_workers} active=${active_workers} step_seconds=${slot_secs}" >>"${LOGFILE:-/dev/null}"
		printf '%s\n' "$ramp_cap"
		return 0
	fi
	printf '%s\n' "$max_workers"
	return 0
}

#######################################
# Compute the dispatch capacity for this round.
#
# Stdout: "<max_workers> <active_workers> <available_slots>" on success.
# Returns:
#   0 - capacity computed (caller checks available_slots > 0 before dispatch)
#   1 - stop flag present; caller should short-circuit
#######################################
_dispatch_compute_capacity() {
	_DISPATCH_MIN_WORKER_FLOOR_ACTIVE=0
	if [[ -f "${STOP_FLAG:-}" ]]; then
		echo "[pulse-wrapper] Dispatch_max skipped: stop flag present" >>"$LOGFILE"
		return 1
	fi

	# t2690/t3424: Proactive rate-limit circuit breaker — pause dispatch when
	# GraphQL budget is nearly exhausted unless REST-backed dispatch fallback is
	# active and REST core has enough headroom for issue/comment/label calls.
	if declare -F is_graphql_budget_sufficient >/dev/null 2>&1; then
		local _cb_rc=0
		is_graphql_budget_sufficient || _cb_rc=$?
		if [[ "$_cb_rc" -eq 1 ]]; then
			echo "[pulse-wrapper] Dispatch_max skipped: GraphQL rate-limit circuit breaker tripped (t2690)" >>"$LOGFILE"
			_dispatch_stats_increment "dispatch_graphql_circuit_blocked"
			return 1
		fi
		# _cb_rc == 2 means API error — fail-open, proceed with dispatch.
	fi

	local max_workers="" active_workers="" available_slots=""
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0

	# t3418/GH#23038: Keep a minimum implementation worker floor eligible only
	# while provider/account health and host load are good enough. The pressure
	# helper caps the final target by OAuth account availability, recent
	# provider failures, load, and long-session runway before dispatch slots are
	# exposed to the candidate loop.
	local min_worker_floor="${AIDEVOPS_MIN_WORKER_CONCURRENCY:-}"
	if [[ -z "$min_worker_floor" ]] && declare -F config_get >/dev/null 2>&1; then
		min_worker_floor=$(config_get "orchestration.min_worker_concurrency" "6")
	fi
	[[ -n "$min_worker_floor" ]] || min_worker_floor=6
	if ! [[ "$min_worker_floor" =~ ^[0-9]+$ ]]; then
		min_worker_floor=6
	fi
	if declare -F pulse_apply_provider_load_capacity_cap >/dev/null 2>&1; then
		local capacity_cap_line=""
		capacity_cap_line=$(pulse_apply_provider_load_capacity_cap "$max_workers" "$active_workers" "$min_worker_floor") || capacity_cap_line="${max_workers} 0"
		read -r max_workers _DISPATCH_MIN_WORKER_FLOOR_ACTIVE <<<"$capacity_cap_line"
		[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
		[[ "$_DISPATCH_MIN_WORKER_FLOOR_ACTIVE" =~ ^[0-9]+$ ]] || _DISPATCH_MIN_WORKER_FLOOR_ACTIVE=0
	elif ((min_worker_floor > 0 && active_workers < min_worker_floor)); then
		_DISPATCH_MIN_WORKER_FLOOR_ACTIVE=1
		if ((max_workers < min_worker_floor)); then
			echo "[pulse-wrapper] Dispatch_min_floor active: max_workers=${max_workers} raised to ${min_worker_floor} while active=${active_workers}" >>"$LOGFILE"
			max_workers="$min_worker_floor"
		fi
	fi
	max_workers="$(_dispatch_apply_startup_capacity_ramp "$max_workers" "$active_workers")"
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	available_slots=$((max_workers - active_workers))

	local guardrail_line=""
	guardrail_line=$(_dispatch_apply_current_state_guardrails "$max_workers" "$active_workers" "$available_slots" "$_DISPATCH_MIN_WORKER_FLOOR_ACTIVE") || guardrail_line="${max_workers} ${active_workers} ${available_slots}"
	read -r max_workers active_workers available_slots <<<"$guardrail_line"
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$available_slots" =~ ^-?[0-9]+$ ]] || available_slots=0
	if ((available_slots < 0)); then
		available_slots=0
	fi

	printf '%s %s %s\n' "$max_workers" "$active_workers" "$available_slots"
	return 0
}

#######################################
# Run triage under one cumulative Pulse-cycle budget, refreshing stale triage
# state at bounded intervals while unspent attempts remain. Typed outcomes never
# reduce worker slots or count as live implementation launches.
#
# Arguments:
#   $1 - available slots before pre-passes
# Stdout: "<remaining_slots> <triage_attempted> <triage_infrastructure_failed>"
#######################################
_dispatch_run_prepasses() {
	local available_slots="$1"

	local triage_outcome="" prior_outcome="" cumulative_outcome=""
	local triage_attempted=0 triage_posted=0 triage_infrastructure_failed=0
	local prior_attempted=0 remaining_budget=0 marker_exists=0 run_triage=0 refresh_state=0
	local triage_budget="${PULSE_TRIAGE_BUDGET_PER_CYCLE:-2}" triage_marker=""
	triage_outcome=$(_dispatch_triage_fallback_outcome 0)
	prior_outcome=$(_dispatch_triage_fallback_outcome 0)
	[[ "$triage_budget" =~ ^[0-9]+$ ]] || triage_budget=2
	triage_marker=$(_dispatch_cycle_cache_path "pulse-triage-prepass" ".done" 2>/dev/null || true)
	if [[ -n "$triage_marker" && -L "$triage_marker" ]]; then
		rm -f "$triage_marker" 2>/dev/null || triage_marker=""
	elif [[ -n "$triage_marker" && -f "$triage_marker" ]]; then
		marker_exists=1
		prior_outcome=$(<"$triage_marker")
		if ! _dispatch_triage_outcome_is_valid "$prior_outcome"; then
			echo "[pulse-wrapper] Dispatch_max: invalid cumulative triage marker — rebuilding it" >>"$LOGFILE"
			prior_outcome=$(_dispatch_triage_fallback_outcome 0)
			marker_exists=0
		fi
	fi
	prior_attempted=$(printf '%s' "$prior_outcome" | jq -r '.attempted // 0' 2>/dev/null || printf '0')
	[[ "$prior_attempted" =~ ^[0-9]+$ ]] || prior_attempted=0
	remaining_budget=$((triage_budget - prior_attempted))
	((remaining_budget < 0)) && remaining_budget=0

	if [[ "$marker_exists" -eq 0 ]]; then
		run_triage=1
	elif [[ "$remaining_budget" -gt 0 ]] && _dispatch_triage_marker_refresh_is_due "$triage_marker"; then
		run_triage=1
		refresh_state=1
	elif [[ "$remaining_budget" -le 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: triage prepass already consumed this cycle's independent budget" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Dispatch_max: triage prepass snapshot is still fresh" >>"$LOGFILE"
	fi

	if [[ "$run_triage" -eq 1 ]]; then
		if [[ "$refresh_state" -eq 1 ]] && \
			{ ! command -v refresh_triage_review_state >/dev/null 2>&1 || ! refresh_triage_review_state; }; then
			echo "[pulse-wrapper] Dispatch_max: triage state refresh failed — preserving prior snapshot and recording one infrastructure failure" >>"$LOGFILE"
			triage_outcome=$(_dispatch_triage_fallback_outcome 1)
		else
			triage_outcome=$(dispatch_triage_reviews "$remaining_budget" 2>>"$LOGFILE") || triage_outcome=$(_dispatch_triage_fallback_outcome 1)
		fi
		if ! _dispatch_triage_outcome_is_valid "$triage_outcome"; then
			echo "[pulse-wrapper] Dispatch_max: invalid triage outcome envelope — recording one infrastructure failure" >>"$LOGFILE"
			triage_outcome=$(_dispatch_triage_fallback_outcome 1)
		fi
		cumulative_outcome=$(_dispatch_triage_outcomes_sum "$prior_outcome" "$triage_outcome") || cumulative_outcome="$triage_outcome"
		[[ -z "$triage_marker" ]] || _dispatch_write_triage_marker "$triage_marker" "$cumulative_outcome" || true
	fi
	triage_attempted=$(printf '%s' "$triage_outcome" | jq -r '.attempted // 0' 2>/dev/null || printf '0')
	triage_posted=$(printf '%s' "$triage_outcome" | jq -r '.posted // 0' 2>/dev/null || printf '0')
	triage_infrastructure_failed=$(printf '%s' "$triage_outcome" | jq -r '.infrastructure_failed // 0' 2>/dev/null || printf '0')
	[[ "$triage_attempted" =~ ^[0-9]+$ ]] || triage_attempted=0
	[[ "$triage_posted" =~ ^[0-9]+$ ]] || triage_posted=0
	[[ "$triage_infrastructure_failed" =~ ^[0-9]+$ ]] || triage_infrastructure_failed=0
	if [[ "$triage_attempted" -gt 0 || "$triage_infrastructure_failed" -gt 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: triage attempted=${triage_attempted} posted=${triage_posted} infrastructure_failed=${triage_infrastructure_failed} implementation_slots_consumed=0 implementation_slots_available=${available_slots}" >>"$LOGFILE"
	fi
	if [[ "$triage_posted" -gt 0 ]]; then
		_dispatch_invalidate_candidate_snapshot "triage_state_changed" || true
	fi

	local enrichment_remaining
	enrichment_remaining=$(dispatch_enrichment_workers "$available_slots" 2>>"$LOGFILE") || enrichment_remaining="$available_slots"
	[[ "$enrichment_remaining" =~ ^[0-9]+$ ]] || enrichment_remaining="$available_slots"
	local enrichment_dispatched=$((available_slots - enrichment_remaining))
	if [[ "$enrichment_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: dispatched ${enrichment_dispatched} enrichment worker(s), ${enrichment_remaining} slots remaining for implementation" >>"$LOGFILE"
	fi
	available_slots="$enrichment_remaining"

	printf '%s %s %s\n' "$available_slots" "$triage_attempted" "$triage_infrastructure_failed"
	return 0
}

#######################################
# Per-candidate skip checks: terminal blockers (t1888), fast-fail (t1888), and
# placeholder/empty issue body (t1899/t1937). Emits the same skip log lines
# the monolithic function used so operator tooling that greps $LOGFILE keeps
# working.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should proceed to dispatch
#######################################
_dispatch_should_skip_candidate() {
	local issue_number="$1"
	local repo_slug="$2"

	pulse_dispatch_debug_log "evaluating skip checks for #${issue_number} (${repo_slug})"

	if _dispatch_skip_for_benign_block "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_terminal_blocker "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_dirty_worktree_recovery "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_fast_fail "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_backoff "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_issue_body "$issue_number" "$repo_slug"; then
		return 0
	fi

	pulse_dispatch_debug_log "#${issue_number}: passed all skip checks — proceeding to dispatch"
	return 1
}

#######################################
# Skip candidates with a recent unresolved worker-dirty-worktree marker.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_dirty_worktree_recovery() {
	local issue_number="$1"
	local repo_slug="$2"

	if _dispatch_recent_dirty_worktree_marker_active "$issue_number" "$repo_slug"; then
		local marker_runner_key=""
		if [[ "${_DISPATCH_DIRTY_MARKER_STATE:-}" == *":runner_key="* ]]; then
			marker_runner_key="${_DISPATCH_DIRTY_MARKER_STATE##*runner_key=}"
		fi
		local local_runner_key=""
		if declare -F runner_identity_key >/dev/null 2>&1; then
			local_runner_key=$(runner_identity_key)
		fi
		if [[ -n "$marker_runner_key" && "$marker_runner_key" == "$local_runner_key" ]]; then
			echo "[pulse-wrapper] Dispatch_max: resuming #${issue_number} (${repo_slug}) on owning runner with preserved dirty worktree" >>"$LOGFILE"
			_dispatch_stats_increment "dispatch_candidate_dirty_worktree_same_runner_resume"
			return 1
		fi
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — recent worker dirty-worktree recovery marker is unresolved" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_dirty_worktree_recovery"
		return 0
	fi
	if [[ "${_DISPATCH_DIRTY_MARKER_STATE:-}" == expired:* ]]; then
		local resolution_body=""
		resolution_body=$(printf '<!-- ops:start -->\n<!-- worker-dirty-worktree:resolved -->\nWORKER_DIRTY_WORKTREE_RESOLVED reason=owning-runner-window-expired ts=%s\n\nThe bounded same-runner recovery window expired without a pushed checkpoint. The runner-local ledger/archive remains the audit record; this marker is cleared once so cross-runner redispatch can proceed deterministically.\n<!-- ops:end -->' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
		gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
			--method POST \
			--field body="$resolution_body" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Dispatch_max: cleared expired dirty-worktree marker for #${issue_number} (${repo_slug}); cross-runner takeover may proceed" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_dirty_worktree_recovery_expired"
	fi
	return 1
}

#######################################
# Skip candidates that are benignly blocked by current assignment/block state.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_benign_block() {
	local issue_number="$1"
	local repo_slug="$2"

	local benign_block_reason=""
	if benign_block_reason=$(_dispatch_benign_blocked_candidate_reason "$issue_number" "$repo_slug"); then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — skip:already_assigned blocked:${benign_block_reason} from current pulse cycle" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_blocked_${benign_block_reason}"
		return 0
	fi
	return 1
}

#######################################
# Skip candidates with terminal blockers.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_terminal_blocker() {
	local issue_number="$1"
	local repo_slug="$2"

	# GH#18804: previously this call used `>/dev/null 2>&1` which suppressed
	# the helper's own log lines AND, more dangerously, masked silent
	# false-positive matches across every candidate in a round. The only
	# observable symptom was `candidates=N` followed immediately by
	# `Adaptive settle wait: 0 dispatches` with nothing between.
	#
	# The set -e-safe capture idiom here is REQUIRED, not stylistic:
	# `_dispatch_should_skip_candidate` runs inside the dispatch loop, which
	# itself runs inside the `dispatch_max` subshell
	# created by `fill_dispatched=$(dispatch_max)`.
	# Under `set -euo pipefail` an unguarded `if helper; then` is fine,
	# but ANY internal capture or assignment that fails would abort the
	# subshell silently. Capturing the rc explicitly keeps the failure
	# mode visible in LOGFILE rather than swallowed by the outer `||`.
	# Same bug class as GH#18770, GH#18784, GH#18786 — see
	# `.agents/reference/bash-compat.md` pre-merge checklist item 4.
	local terminal_rc=0
	check_terminal_blockers "$issue_number" "$repo_slug" >>"$LOGFILE" 2>&1 || terminal_rc=$?
	pulse_dispatch_debug_log "#${issue_number}: check_terminal_blockers rc=${terminal_rc}"
	if [[ "$terminal_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — terminal blocker detected (check_terminal_blockers rc=0)" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_terminal_blocker"
		return 0
	fi
	return 1
}

#######################################
# Skip candidates at the fast-fail threshold after applying age-out repair.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_fast_fail() {
	local issue_number="$1"
	local repo_slug="$2"

	# t2397: Age-out HARD STOP'd issues that have been quiet for >=24h so
	# transient failures (model availability, CI flakes, stale framework bugs)
	# don't permanently strand issues. Called before fast_fail_is_skipped so
	# a just-reset counter allows dispatch in the same cycle.
	fast_fail_age_out "$issue_number" "$repo_slug" || true

	if fast_fail_is_skipped "$issue_number" "$repo_slug"; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — fast-fail threshold reached" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_fast_fail"
		return 0
	fi
	return 1
}

#######################################
# Skip candidates that are under per-issue dispatch backoff.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_backoff() {
	local issue_number="$1"
	local repo_slug="$2"

	# t2781: Per-issue rate_limit backoff — graduated cooldown based on recent
	# rate_limit exits in headless-runtime-metrics.jsonl. Prevents repeated dispatch
	# of issues where every account in the pool rate-limits (the existing fast_fail
	# rate_limit path does an immediate retry when other accounts are available,
	# producing 0s cooldown. This gate adds a per-issue floor independent of pool state).
	if declare -F check_dispatch_backoff >/dev/null 2>&1; then
		local _backoff_output="" _backoff_rc=0
		_backoff_output=$(check_dispatch_backoff "$issue_number" "$repo_slug" 2>&1 >/dev/null) || _backoff_rc=$?
		if [[ "$_backoff_rc" -eq 1 ]]; then
			echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — ${_backoff_output}" >>"$LOGFILE"
			_dispatch_stats_increment "dispatch_candidate_skipped_backoff"
			# Record the extended cooldown once at the 4th+ failure threshold.
			if printf '%s' "$_backoff_output" | grep -q 'BACKOFF_NOTICE_REQUIRED'; then
				local _backoff_count=""
				_backoff_count=$(printf '%s' "$_backoff_output" | grep -oE 'count=[0-9]+' | head -1 | cut -d= -f2)
				[[ "$_backoff_count" =~ ^[0-9]+$ ]] || _backoff_count="${DISPATCH_BACKOFF_NMR_THRESHOLD:-4}"
				declare -F _db_record_extended_backoff_notice >/dev/null 2>&1 && \
					_db_record_extended_backoff_notice "$issue_number" "$repo_slug" "$_backoff_count" || true
			fi
			return 0
		fi
		# rc=2 → error; fail-open (log warning, continue to dispatch)
		if [[ "$_backoff_rc" -eq 2 ]]; then
			echo "[pulse-wrapper] Dispatch_max: backoff check error for #${issue_number} — proceeding (fail-open)" >>"$LOGFILE"
		fi
	fi
	return 1
}

#######################################
# Skip candidates whose issue body is empty, placeholder, or explicitly lacks
# worker-ready implementation context.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through dispatch
#######################################
_dispatch_skip_for_issue_body() {
	local issue_number="$1"
	local repo_slug="$2"

	# t1899/t1937: Skip issues with placeholder/empty bodies — dispatching a
	# worker to an undescribed issue wastes a session. Use REST here instead of
	# `gh issue view --json body`: this pre-dedup fast-fail runs once per
	# candidate, so a GraphQL-backed CLI read can drain the shared GraphQL budget
	# before workers ever launch.
	local issue_body
	declare -F gh_record_call >/dev/null 2>&1 && gh_record_call rest "pulse-dispatch-lib.sh" || true
	issue_body=$(gh api "repos/${repo_slug}/issues/${issue_number}" --jq '.body // ""' 2>/dev/null) || issue_body=""
	pulse_dispatch_debug_log "#${issue_number}: body length=${#issue_body}"
	if [[ -z "$issue_body" || "$issue_body" == "Task created via claim-task-id.sh" ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — placeholder/empty issue body, needs enrichment before dispatch" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_empty_body"
		return 0
	fi
	if [[ "$issue_body" == *"no description provided — enrich before dispatch"* ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — claim-task-id.sh stub body, needs enrichment before dispatch" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_empty_body"
		return 0
	fi
	if _dispatch_issue_body_missing_worker_context "$issue_body"; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — missing Worker Guidance/How implementation context, needs enrichment before dispatch" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_missing_worker_context"
		return 0
	fi
	return 1
}

#######################################
# Detect issue bodies that explicitly say implementation context is missing and
# would therefore deterministically make /full-loop stop with BLOCKED before
# implementation. Do not reject every body that lacks Worker Guidance here:
# dispatch_with_dedup has a later brief-enrichment layer that can repair older
# issue bodies when a local task brief exists.
#
# Arguments:
#   $1 - issue body
# Returns:
#   0 - body is missing worker implementation context
#   1 - body appears dispatchable
#######################################
_dispatch_issue_body_missing_worker_context() {
	local issue_body="$1"

	if [[ -z "$issue_body" ]]; then
		return 0
	fi
	case "$issue_body" in
	*"needs enrichment before dispatch"* | *"Needs enrichment before dispatch"* | \
		*"missing Worker Guidance/How implementation context"* | \
		*"Missing Worker Guidance/How implementation context"* | \
		*"needs implementation context before dispatch"* | \
		*"Needs implementation context before dispatch"* | \
		*"no implementation details provided"* | \
		*"No implementation details provided"* | \
		*"no implementation details for a worker"* | \
		*"No implementation details for a worker"* | \
		*"no worker guidance provided"* | *"No worker guidance provided"*)
		return 0
		;;
	esac
	return 1
}

#######################################
# Record a check_worker_launch failure. Updates the round counters and, on
# three consecutive no_worker_process failures, invalidates the canary cache
# so the next dispatch forces a re-test instead of trusting a stale "passed N
# minutes ago" signal (t1959).
#######################################
_dispatch_record_launch_failure() {
	if [[ "$_PULSE_LAST_LAUNCH_FAILURE" == "no_worker_process" ]]; then
		_DISPATCH_ROUND_NO_WORKER_FAILURES=$((_DISPATCH_ROUND_NO_WORKER_FAILURES + 1))
		_DISPATCH_CONSECUTIVE_NO_WORKER=$((_DISPATCH_CONSECUTIVE_NO_WORKER + 1))
		if [[ "$_DISPATCH_CONSECUTIVE_NO_WORKER" -ge 3 ]]; then
			if [[ -f "$_DISPATCH_CANARY_CACHE" ]]; then
				rm -f "$_DISPATCH_CANARY_CACHE"
				echo "[pulse-wrapper] Canary cache invalidated after ${_DISPATCH_CONSECUTIVE_NO_WORKER} consecutive no_worker_process failures in round — next dispatch will re-run canary" >>"$LOGFILE"
			fi
			_DISPATCH_CONSECUTIVE_NO_WORKER=0
		fi
	else
		# cli_usage_output or other launch-class failure: don't count toward
		# the consecutive no_worker_process streak.
		_DISPATCH_CONSECUTIVE_NO_WORKER=0
	fi
	return 0
}

#######################################
# t2989: Run dispatch_with_dedup with a per-candidate wall-clock timeout.
#
# Wraps the call in run_stage_with_timeout (default 30s, env override
# DISPATCH_PER_CANDIDATE_TIMEOUT). On timeout, kills the entire process
# tree, emits a distinct log line, and bumps the
# dispatch_per_candidate_timeout counter in pulse-stats.json so cycle
# cadence regressions are visible to operators without a deep log dive.
#
# GH#18804 isolation contract preserved: dispatch_with_dedup has no
# shared-variable contract with the caller; it only mutates GitHub state
# via gh API and fork-execs the worker via nohup, both of which survive
# subshell isolation. run_stage_with_timeout backgrounds the call via
# "$@ &" — strictly stronger isolation than the previous (...) subshell
# while still capturing rc via ||.
#
# Arguments:
#   $1 - issue_number (used for stage name + log lines AND passed through)
#   $2 - repo_slug    (used for log lines AND passed through)
#   $3..$9 - remaining dispatch_with_dedup positional args (dispatch_title,
#            issue_title, self_login, repo_path, prompt, dedup_key,
#            model_override). All "$@" forwarded verbatim to
#            dispatch_with_dedup.
#
# Returns:
#   0     - dispatch_with_dedup completed successfully
#   124   - per-candidate timeout (already logged + counter bumped)
#   other - dispatch_with_dedup non-zero rc (failed dedup check, etc.)
#######################################
_dispatch_with_timeout() {
	local issue_number="$1"
	local repo_slug="$2"

	# t3003: adaptive per-candidate timeout. When DISPATCH_TIMING_ADAPTIVE=1
	# (default), dispatch-timing-helper.sh recommends a budget based on the
	# EWMA + p95 of recent successful dispatches; on timeouts it switches to
	# probe mode (2x last_timeout). Old fixed DISPATCH_PER_CANDIDATE_TIMEOUT
	# is preserved as the legacy fallback when the helper is unavailable or
	# DISPATCH_TIMING_ADAPTIVE=0.
	local timeout_seconds="$DISPATCH_PER_CANDIDATE_TIMEOUT"
	local timeout_ms=$((timeout_seconds * 1000))
	local probe_mode="false"
	if [[ "${DISPATCH_TIMING_ADAPTIVE:-1}" == "1" ]] && command -v dispatch-timing-helper.sh >/dev/null 2>&1; then
		local recommended_output
		recommended_output=$(dispatch-timing-helper.sh recommend --repo "$repo_slug" 2>/dev/null || echo "")
		# Output is two lines: timeout_ms and probe_bool
		local recommended_ms="" probe_bool="false"
		mapfile -t -n 2 < <(printf '%s\n' "$recommended_output")
		recommended_ms="${MAPFILE[0]:-}"
		probe_bool="${MAPFILE[1]:-false}"
		if [[ "$recommended_ms" =~ ^[0-9]+$ ]] && ((recommended_ms > 0)); then
			timeout_ms="$recommended_ms"
			timeout_seconds=$((recommended_ms / 1000))
			((timeout_seconds < 1)) && timeout_seconds=1
			probe_mode="$probe_bool"
		fi
	fi

	# t3026: floor per-candidate timeout to cover full ceremony cost.
	# Pulse dispatch ceremony (gh issue view + brief check + eligibility +
	# pre-dispatch validators + CLAIM_WON audit comment + body composition
	# with footer + worker spawn / npm install / node startup) takes ~75-160s
	# baseline; with backpressure it adds 20-40s. The adaptive helper's MIN
	# (DISPATCH_TIMING_MIN_TIMEOUT_MS, default 30s) is sized for the simplest
	# case (dedup-skip path that returns in <5s) and is too low for the full
	# ceremony — when adaptive recommended drops below ceremony cost, EVERY
	# candidate timeouts at rc=124 and dispatched=0/N. Canonical failure:
	# 2026-04-28 dispatch cycle iter=62, 148 candidates, dispatched=0,
	# adaptive timeout collapsed to 180s. Floor at 360s was insufficient
	# (post-t3040 evidence: ceremony_total avg=341s, max=341s — every
	# candidate hit rc=124 timeout). t3043 raises to 600s to give the
	# 419s avg ceremony (gh_issue_view 3s + dedup_check 134s + assign 35s
	# + precreate_worktree 75s + lock 7s + eligibility 11s + predispatch 8s
	# + tier 4s + worker_launch 142s) ~50% headroom for tail variance.
	# Follow-up t3043 (#21659) targets reducing per-stage cost to <60s.
	local floor_seconds="${DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR:-600}"
	if [[ "$floor_seconds" =~ ^[0-9]+$ ]] && ((timeout_seconds < floor_seconds)); then
		timeout_seconds="$floor_seconds"
		timeout_ms=$((floor_seconds * 1000))
	fi

	local start_ms dispatch_rc=0 outcome elapsed_ms
	local stage_rc=0 raw_rc_file=""
	raw_rc_file=$(mktemp 2>/dev/null || printf '/tmp/aidevops-dispatch-raw-rc.%s.%s' "$$" "$issue_number")
	start_ms=$(_dispatch_now_ms)
	run_stage_with_timeout "dispatch_candidate_${issue_number}" "$timeout_seconds" \
		_dispatch_stage_rc_adapter "$raw_rc_file" dispatch_with_dedup "$@" || stage_rc=$?
	if [[ -s "$raw_rc_file" ]]; then
		read -r dispatch_rc <"$raw_rc_file" || dispatch_rc="$stage_rc"
	else
		dispatch_rc="$stage_rc"
	fi
	rm -f "$raw_rc_file" 2>/dev/null || true
	elapsed_ms=$(($(_dispatch_now_ms) - start_ms))
	echo "[pulse-wrapper] Dispatch_max: dispatch_with_dedup returned rc=${dispatch_rc} for #${issue_number} elapsed_ms=${elapsed_ms} timeout_used_ms=${timeout_ms}" >>"$LOGFILE"

	if [[ "$dispatch_rc" -eq 124 ]]; then
		outcome="timeout"
		# t2989 + t3003: per-candidate timeout — log distinctly, bump counter,
		# record outcome so the next recommendation enters probe mode.
		# t3056 / GH#21781: Structured lifecycle line for kill-reason telemetry
		printf '[lifecycle] worker_killed pid=dispatch reason=wait_loop_timeout_%ss trigger_age=%sms session=issue-%s ts=%s\n' \
			"$timeout_seconds" "$elapsed_ms" "$issue_number" \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			>>"${LOGFILE:-/dev/null}" 2>/dev/null || true
		echo "[pulse-wrapper] Dispatch_max: per-candidate timeout (${timeout_seconds}s) on #${issue_number} (${repo_slug}) — killing candidate, continuing loop" >>"$LOGFILE"
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "dispatch_per_candidate_timeout" 2>/dev/null || true
		fi
	elif [[ "$dispatch_rc" -eq 0 ]]; then
		outcome="success"
	elif [[ "$dispatch_rc" -eq 2 ]]; then
		outcome="noop"
	else
		outcome="skip"
	fi

	# t3003: record outcome for adaptive timing. Non-fatal — never block the
	# dispatch loop on a recording failure. Pass --probe flag when escalated.
	if command -v dispatch-timing-helper.sh >/dev/null 2>&1; then
		dispatch-timing-helper.sh record \
			--repo "$repo_slug" --issue "$issue_number" --outcome "$outcome" \
			--elapsed-ms "$elapsed_ms" --timeout-used-ms "$timeout_ms" \
			--probe "$probe_mode" \
			>/dev/null 2>&1 || true
	fi

	return "$dispatch_rc"
}

#######################################
# Stop dispatch loops when the GraphQL reserve is already below the circuit
# breaker threshold. The rate_limit endpoint is free, so this protects the
# high-fanout loop without spending additional GraphQL points.
#
# Returns:
#   0 — budget is sufficient, unavailable, or checker is not loaded
#   1 — budget is below threshold; caller should stop the loop
#######################################
_dispatch_graphql_budget_allows_next() {
	if ! declare -F is_graphql_budget_sufficient >/dev/null 2>&1; then
		return 0
	fi

	local _budget_rc=0
	is_graphql_budget_sufficient >/dev/null 2>&1 || _budget_rc=$?
	if [[ "$_budget_rc" -eq 1 ]]; then
		_dispatch_stats_increment "dispatch_graphql_circuit_blocked"
		_dispatch_stats_increment_candidate_failed "graphql_circuit_breaker"
		return 1
	fi
	return 0
}

#######################################
# t3003: bash 3.2-compatible millisecond timestamp.
# GNU date supports %N (nanoseconds); macOS BSD date does not. We strip the
# trailing 6 digits to convert ns→ms when GNU date is present, otherwise fall
# back to seconds×1000 (sufficient resolution for ≥1s timeouts).
#######################################
_dispatch_now_ms() {
	local ns
	ns=$(date +%s%N 2>/dev/null)
	if [[ "$ns" =~ ^[0-9]+$ ]] && ((${#ns} >= 13)); then
		# GNU date: epoch_seconds + 9-digit nanoseconds → strip 6 → ms
		echo "${ns%??????}"
	else
		# BSD date or unsupported %N — fall back to second resolution
		echo $(($(date +%s) * 1000))
	fi
	return 0
}

#######################################
# t3022: Per-model concurrency cap guard.
#
# Prevents 429 rate-limit cascades when multiple thinking-tier workers are
# launched simultaneously. A single Anthropic account sustains many
# concurrent sonnet workers but only ~3-4 concurrent opus before hitting
# 429s that make workers 20-min zombies (observed: 3 opus-4-6 workers
# killed at the same minute with rate_limit, ts=1777397345-1777397359).
#
# Counts in-flight opus workers by probing the process list for opencode's
# '-m anthropic/claude-opus' flag (the literal flag opencode receives from
# _build_run_cmd in headless-runtime-model.sh). Returns 1 (deferred) when
# the candidate's model is opus and inflight >= cap. Sonnet/haiku and
# auto-routed candidates (empty model_override) always return 0.
#
# Deferred candidates are retried next pulse cycle — they are NOT NMR'd
# or fast-fail penalised. This is a temporary yield, not a block.
#
# Cap resolution order (highest to lowest):
#   1. AIDEVOPS_OPUS_CONCURRENCY_CAP env var
#   2. OPUS_CONCURRENCY_CAP in .agents/configs/dispatch-model-caps.conf
#   3. Built-in default (4)
#
# Arguments:
#   $1 - issue_number (for logging)
#   $2 - repo_slug (for logging)
#   $3 - resolved_model (e.g. "anthropic/claude-opus-4-6" or "" for auto)
# Returns:
#   0 - proceed with dispatch (not opus, or inflight < cap)
#   1 - deferred (opus inflight >= cap); caller should `return 1`
#######################################
_dispatch_check_model_concurrency_cap() {
	local issue_number="$1"
	local repo_slug="$2"
	local resolved_model="$3"

	# Empty model = auto round-robin (no explicit model:* label) — skip cap check.
	[[ -z "$resolved_model" ]] && return 0

	# Only cap thinking-tier work; standard and simple are unaffected.
	case "$resolved_model" in
	*claude-opus*) ;;  # fall through to cap enforcement below
	*) return 0 ;;
	esac

	# Load per-model caps from config with inline defaults.
	# Defaults match the documented values in dispatch-model-caps.conf.
	local OPUS_CONCURRENCY_CAP=4
	local _caps_conf="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../configs/dispatch-model-caps.conf"
	if [[ -f "$_caps_conf" ]]; then
		# shellcheck disable=SC1090
		source "$_caps_conf" 2>/dev/null || true
	fi
	# Env var takes highest precedence (overrides both default and conf file).
	local opus_cap="${AIDEVOPS_OPUS_CONCURRENCY_CAP:-${OPUS_CONCURRENCY_CAP}}"

	# Count in-flight opus workers from the process list.
	# opencode is launched with '-m anthropic/claude-opus-4-6' (or -4-7) by
	# _build_run_cmd in headless-runtime-model.sh:412. pgrep -f matches the
	# full cmdline so it catches both 4-6 and 4-7 variants in one probe.
	#
	# pgrep exits 1 with no output when no processes match — perfectly normal.
	# Assign to a variable first with || true to avoid triggering set -o pipefail.
	local _opus_pids=""
	_opus_pids=$(pgrep -f 'opencode.*-m anthropic/claude-opus' 2>/dev/null) || true
	local opus_inflight=0
	if [[ -n "$_opus_pids" ]]; then
		opus_inflight=$(printf '%s\n' "$_opus_pids" | wc -l | tr -d ' ')
		[[ "$opus_inflight" =~ ^[0-9]+$ ]] || opus_inflight=0
	fi

	pulse_dispatch_debug_log "#${issue_number}: opus_concurrency_cap check inflight=${opus_inflight} cap=${opus_cap} model=${resolved_model}"

	if ((opus_inflight >= opus_cap)); then
		echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) deferred — opus_concurrency_cap: inflight=${opus_inflight} cap=${opus_cap} model=${resolved_model} (retry next cycle)" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_deferred_model_cap"
		return 1
	fi
	return 0
}

#######################################
# Record a non-zero dispatch_with_dedup outcome for one candidate.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - dispatch_with_dedup return code
# Returns: 0 always (caller handles the skip/continue decision).
#######################################
_dispatch_record_nonzero_dispatch_result() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_rc="$3"
	local recent_lines=""

	echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — dispatch_with_dedup returned rc=${dispatch_rc}" >>"$LOGFILE"
	if [[ "$dispatch_rc" -eq 2 ]]; then
		if [[ -n "${LOGFILE:-}" && -f "$LOGFILE" ]]; then
			recent_lines=$(awk -v issue="#${issue_number}" -v repo="$repo_slug" '
				index($0, issue) && index($0, repo) { lines[++n] = $0 }
				END {
					start = n - 20
					if (start < 1) { start = 1 }
					for (i = start; i <= n; i++) { print lines[i] }
				}
			' "$LOGFILE" 2>/dev/null) || recent_lines=""
		fi
		if [[ "$recent_lines" == *"blocked_by_native_lookup_unavailable"* ]]; then
			echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) pre-launch failure reason=blocked_by_native_lookup_unavailable" >>"$LOGFILE"
			_dispatch_stats_increment_candidate_failed "blocked_by_native_lookup_unavailable"
			return 0
		fi
		_dispatch_stats_increment "dispatch_candidate_noop"
		return 0
	fi

	local failure_reason
	failure_reason=$(_dispatch_candidate_failure_reason "$issue_number" "$repo_slug" "$dispatch_rc")
	if _dispatch_candidate_benign_block_reason "$failure_reason"; then
		_dispatch_mark_benign_blocked_candidate "$issue_number" "$repo_slug" "$failure_reason"
		echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) blocked:${failure_reason} benign dispatch block" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_blocked_${failure_reason}"
		return 0
	fi

	echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) pre-launch failure reason=${failure_reason}" >>"$LOGFILE"
	_dispatch_stats_increment_candidate_failed "$failure_reason"
	return 0
}

#######################################
# Process a single dispatch candidate: extract fields, skip if ineligible,
# dispatch via dispatch_with_dedup, verify worker launch, and track the
# outcome for adaptive batch throttling.
#
# Arguments:
#   $1 - candidate JSON object (one line of `jq -c '.[]'`)
#   $2 - self_login (GitHub user for dedup)
#   $3 - available_slots (for throttle-clear log message)
#
# Returns:
#   0 - candidate dispatched and launch verified (caller should increment
#       dispatched_count; if _DISPATCH_THROTTLE_CLEARED=1 also restore
#       _effective_slots)
#   1 - candidate skipped or dispatch failed (caller should `continue`)
#
# Side effects:
#   - Updates _DISPATCH_ROUND_DISPATCHED / _DISPATCH_ROUND_NO_WORKER_FAILURES /
#     _DISPATCH_CONSECUTIVE_NO_WORKER for the round.
#   - Clears _DISPATCH_THROTTLE_FILE and sets _DISPATCH_THROTTLE_CLEARED=1 on a
#     successful launch while throttle was active.
#######################################
_dispatch_process_candidate() {
	local candidate_json="$1"
	local self_login="$2"
	local available_slots="$3"
	_DISPATCH_THROTTLE_CLEARED=0

	local issue_number="" repo_slug="" repo_path="" issue_url="" issue_title="" dispatch_title="" prompt="" labels_csv="" model_override=""
	issue_number=$(printf '%s' "$candidate_json" | jq -r '.number // empty' 2>/dev/null)
	repo_slug=$(printf '%s' "$candidate_json" | jq -r '.repo_slug // empty' 2>/dev/null)
	repo_path=$(printf '%s' "$candidate_json" | jq -r '.repo_path // empty' 2>/dev/null)
	issue_url=$(printf '%s' "$candidate_json" | jq -r '.url // empty' 2>/dev/null)
	issue_title=$(printf '%s' "$candidate_json" | jq -r '.title // empty' 2>/dev/null | tr '\n' ' ')
	labels_csv=$(printf '%s' "$candidate_json" | jq -r '(.labels // []) | join(",")' 2>/dev/null)

	# GH#18804: previously the next two checks silently `return 1`-ed without
	# logging. Operators saw `candidates=N` but no per-candidate skip lines,
	# making malformed candidate JSON impossible to diagnose from pulse.log.
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping malformed candidate — issue_number='${issue_number}' is not numeric (candidate_json prefix: ${candidate_json:0:120})" >>"$LOGFILE"
		return 1
	fi
	if [[ -z "$repo_slug" || -z "$repo_path" ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} — missing repo_slug='${repo_slug}' or repo_path='${repo_path}'" >>"$LOGFILE"
		return 1
	fi

	pulse_dispatch_debug_log "processing #${issue_number} (${repo_slug}) labels=[${labels_csv}]"

	if _dispatch_should_skip_candidate "$issue_number" "$repo_slug"; then
		return 1
	fi

	dispatch_title="Issue #${issue_number}"
	prompt="/full-loop Implement issue #${issue_number}"
	if [[ -n "$issue_url" ]]; then
		prompt="${prompt} (${issue_url})"
	fi
	model_override=$(resolve_dispatch_model_for_labels "$labels_csv")
	pulse_dispatch_debug_log "#${issue_number}: model_override=${model_override:-<auto>} — calling dispatch_with_dedup"

	# t3022: Defer opus candidates when the per-model concurrency cap is reached.
	# Prevents 429 cascades from simultaneous opus worker launches. Sonnet/haiku
	# candidates are unaffected. Deferred candidates retry next pulse cycle.
	local _concurrency_cap_rc=0
	_dispatch_check_model_concurrency_cap "$issue_number" "$repo_slug" "$model_override" >>"$LOGFILE" 2>&1 || _concurrency_cap_rc=$?
	if [[ "$_concurrency_cap_rc" -ne 0 ]]; then
		return 1
	fi

	# t2433/GH#20071: Refresh the repo before the large-file gate (inside
	# dispatch_with_dedup → _dispatch_dedup_check_layers → _issue_targets_large_files)
	# measures file sizes. Sentinel prevents multiple pulls for the same repo
	# within a single dispatch_max subshell execution.
	_pulse_refresh_repo "$repo_path"

	# GH#18804 + t2989: dispatch with isolation + per-candidate timeout.
	# Detail (subshell isolation, hang signature, 30s default rationale):
	# see _dispatch_with_timeout doc comment above.
	local dispatch_rc=0
	_dispatch_with_timeout "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$prompt" "issue-${issue_number}" "$model_override" || dispatch_rc=$?
	if [[ "$dispatch_rc" -ne 0 ]]; then
		_dispatch_record_nonzero_dispatch_result "$issue_number" "$repo_slug" "$dispatch_rc"
		return 1
	fi

	# Count every successful dispatch attempt as a round denominator (t1959)
	_DISPATCH_ROUND_DISPATCHED=$((_DISPATCH_ROUND_DISPATCHED + 1))
	_PULSE_LAST_LAUNCH_FAILURE=""

	local launch_rc=0
	check_worker_launch "$issue_number" "$repo_slug" >/dev/null 2>&1 || launch_rc=$?
	if [[ "$launch_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) launch validation failed (rc=${launch_rc}, last_failure='${_PULSE_LAST_LAUNCH_FAILURE}')" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_worker_launch_failed"
		_dispatch_record_launch_failure
		return 1
	fi
	_dispatch_stats_increment "dispatch_worker_spawned"

	# Launch confirmed. Reset consecutive streak and clear throttle if active.
	_DISPATCH_CONSECUTIVE_NO_WORKER=0
	# t1959: A single successful launch proves the runtime is back.
	# Restore full batch immediately — do not wait for N successes.
	if [[ -f "$_DISPATCH_THROTTLE_FILE" ]]; then
		rm -f "$_DISPATCH_THROTTLE_FILE"
		echo "[pulse-wrapper] Dispatch throttle CLEARED: launch success in throttled mode — restoring full batch=${available_slots}" >>"$LOGFILE"
		_DISPATCH_THROTTLE_CLEARED=1
	fi
	return 0
}

#######################################
# After the dispatch loop finishes, compute the no_worker_process failure
# ratio for this round. If >80% of dispatches ended with no_worker_process,
# engage the adaptive batch throttle so the next round is limited to batch=1
# to avoid wasted dispatch cycles during runtime breakage (t1959).
#######################################
_dispatch_maybe_engage_throttle() {
	if [[ "$_DISPATCH_ROUND_DISPATCHED" -gt 0 ]]; then
		local ratio_pct=$((_DISPATCH_ROUND_NO_WORKER_FAILURES * 100 / _DISPATCH_ROUND_DISPATCHED))
		if [[ "$ratio_pct" -gt 80 ]]; then
			echo "1" >"$_DISPATCH_THROTTLE_FILE" 2>/dev/null || true
			echo "[pulse-wrapper] Dispatch throttle ENGAGED: ${ratio_pct}% no_worker_process in round (${_DISPATCH_ROUND_NO_WORKER_FAILURES}/${_DISPATCH_ROUND_DISPATCHED}) — next round limited to batch=1" >>"$LOGFILE"
		fi
	fi
	return 0
}

#######################################
# t3005/t3014/GH#29234: Decide the parallelism level for dispatch_max.
#
# Defaults to DISPATCH_MAX_PARALLEL when set to a positive integer.
# When unset, empty, or non-numeric, defaults to 6 (GH#29234), then clamps to
# effective_slots. Worker slots represent settled worker capacity, not the safe
# number of concurrent API/worktree/runtime-start ceremony process trees. An
# explicit positive override remains available for larger or smaller hosts.
#
# Always capped at the effective slot budget — never schedule more concurrent
# dispatches than slots we'd consume. Forced to 1 when the adaptive throttle
# file is present (degraded runtime — the existing serial throttle behavior is
# preserved as the regression escape hatch and the "test the waters" semantics).
#
# Arguments:
#   $1 - effective_slots (already throttle-aware: 1 in throttle mode)
# Stdout: integer parallelism level (>= 1)
#######################################
_dispatch_max_compute_parallel() {
	local effective_slots="$1"
	# t3015 back-compat: honour deprecated DISPATCH_FILL_FLOOR_PARALLEL name.
	# Operators who set the old name in their environment / launchd plist
	# before upgrading should not silently lose their override. Bridge the
	# value into DISPATCH_MAX_PARALLEL on first invocation. Removed in v4.0.
	if [[ -n "${DISPATCH_FILL_FLOOR_PARALLEL:-}" && -z "${DISPATCH_MAX_PARALLEL:-}" ]]; then
		echo "[pulse-wrapper] WARNING: DISPATCH_FILL_FLOOR_PARALLEL is deprecated — use DISPATCH_MAX_PARALLEL (t3015)" >&2
		DISPATCH_MAX_PARALLEL="$DISPATCH_FILL_FLOOR_PARALLEL"
		export DISPATCH_MAX_PARALLEL
	fi
	# GH#29234: use a conservative ceremony cap when unset/empty/invalid. An env
	# override still wins when it is a positive integer; the effective-slot cap
	# below remains authoritative.
	local max_parallel="${DISPATCH_MAX_PARALLEL:-}"
	if ! [[ "$max_parallel" =~ ^[1-9][0-9]*$ ]]; then
		max_parallel=6
	fi
	if ((max_parallel > effective_slots)); then
		max_parallel="$effective_slots"
	fi
	# In throttle mode, _effective_slots is already 1 → max_parallel=1 (serial).
	# t3418/t3558: when the minimum worker floor is active, launch throttles
	# are soft signals; keep parallelism eligible until the floor is reached.
	# Defensive: also short-circuit on direct file presence in case caller
	# passes a non-throttled effective_slots while throttle is active.
	if [[ -f "$_DISPATCH_THROTTLE_FILE" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" != "1" ]]; then
		max_parallel=1
	fi
	((max_parallel < 1)) && max_parallel=1
	printf '%d\n' "$max_parallel"
	return 0
}

#######################################
# t3005: Serial dispatch loop (original behavior, refactored into a helper).
#
# Iterates candidates one at a time, calling _dispatch_process_candidate inline.
# Module-global state mutations (_DISPATCH_ROUND_DISPATCHED, _DISPATCH_THROTTLE_CLEARED,
# _PULSE_LAST_LAUNCH_FAILURE, _DISPATCH_CONSECUTIVE_NO_WORKER) propagate normally
# because the loop runs in the parent shell, not a backgrounded subshell.
#
# Arguments:
#   $1 - candidate_file (one JSON candidate per line)
#   $2 - effective_slots (slot budget at loop start, may be throttled to 1)
#   $3 - available_slots (unthrottled slot budget — restored if throttle clears)
#   $4 - self_login (GitHub login for dedup)
# Stdout: "<dispatched_count> <processed_count>"
#######################################
_dispatch_floor_loop() {
	local candidate_file="$1"
	local effective_slots="$2"
	local available_slots="$3"
	local self_login="$4"

	local dispatched_count=0 processed_count=0 candidate_json
	while IFS= read -r candidate_json; do
		[[ -n "$candidate_json" ]] || continue
		processed_count=$((processed_count + 1))
		echo "[pulse-wrapper] Dispatch_max: loop iter=${processed_count} — entering body" >>"$LOGFILE"
		if [[ "$dispatched_count" -ge "$effective_slots" ]]; then
			echo "[pulse-wrapper] Dispatch_max: loop iter=${processed_count} — stopping (dispatched=${dispatched_count} >= effective_slots=${effective_slots})" >>"$LOGFILE"
			break
		fi
		if [[ -f "${STOP_FLAG:-}" ]]; then
			echo "[pulse-wrapper] Dispatch_max stopping early: stop flag appeared" >>"$LOGFILE"
			break
		fi
		if ! _dispatch_graphql_budget_allows_next; then
			echo "[pulse-wrapper] Dispatch_max stopping early: GraphQL circuit breaker tripped during serial loop" >>"$LOGFILE"
			break
		fi
		local _dispatch_proc_rc=0
		_dispatch_process_candidate "$candidate_json" "$self_login" "$available_slots" >>"$LOGFILE" 2>&1 || _dispatch_proc_rc=$?
		echo "[pulse-wrapper] Dispatch_max: loop iter=${processed_count} — _dispatch_process_candidate rc=${_dispatch_proc_rc}" >>"$LOGFILE"
		if [[ "$_dispatch_proc_rc" -eq 0 ]]; then
			dispatched_count=$((dispatched_count + 1))
			# Throttle cleared mid-round by a successful launch — restore
			# the unthrottled slot budget so subsequent iterations dispatch.
			if [[ "$_DISPATCH_THROTTLE_CLEARED" -eq 1 ]]; then
				effective_slots="$available_slots"
			fi
		fi
	done <"$candidate_file"
	printf '%d %d\n' "$dispatched_count" "$processed_count"
	return 0
}

#######################################
# t3005: Parallel dispatch loop with bounded concurrency and outcomes file.
#
# Each candidate is dispatched in a backgrounded subshell. Module-global
# mutations inside _dispatch_process_candidate are isolated to the subshell and
# lost — we re-derive aggregate state from an outcomes file written by each
# subshell on completion. POSIX O_APPEND guarantees atomic short-line writes
# (lines are <100 bytes, well under PIPE_BUF=512 on macOS / 4096 on Linux).
#
# Concurrency cap is enforced via `wait -n` (bash 4.3+). A modern bash is
# guaranteed at runtime by setup.sh's bash-upgrade-helper.sh + the
# shared-constants.sh re-exec guard.
#
# Each candidate's outcome line format:
#   success|<issue>           — dispatched + launch validated
#   fail|<issue>|rc=<n>|<reason>  — pre-skip, dispatch failure, or launch failure
#
# Arguments:
#   $1 - candidate_file
#   $2 - effective_slots (slot budget — never throttled in this path)
#   $3 - available_slots (passed through to _dispatch_process_candidate)
#   $4 - self_login
#   $5 - max_parallel (bounded concurrency level)
#   $6 - outcomes_file (created by caller, parent reads it post-loop)
# Stdout: "<dispatched_count> <processed_count>"
#######################################
_dispatch_max_loop() {
	local candidate_file="$1"
	local effective_slots="$2"
	local available_slots="$3"
	local self_login="$4"
	local max_parallel="$5"
	local outcomes_file="$6"

	local processed_count=0 candidate_json
	local _pids=()
	while IFS= read -r candidate_json; do
		[[ -n "$candidate_json" ]] || continue
		processed_count=$((processed_count + 1))
		echo "[pulse-wrapper] Dispatch_max: parallel iter=${processed_count} — entering body" >>"$LOGFILE"

		_dispatch_max_refresh_pids _pids
		_dispatch_max_wait_for_capacity _pids "$max_parallel"

		local successes_so_far=0
		successes_so_far=$(_dispatch_max_count_outcomes "$outcomes_file")
		if _dispatch_max_should_stop "$processed_count" "$successes_so_far" "$effective_slots" "${#_pids[@]}"; then
			break
		fi

		_dispatch_max_apply_inter_launch_delay "$successes_so_far" "${#_pids[@]}" "$processed_count" "$candidate_json" "$max_parallel"
		_dispatch_max_spawn_candidate "$candidate_json" "$self_login" "$available_slots" "$outcomes_file" &
		_pids+=($!)
	done <"$candidate_file"

	# Wait only for tracked in-flight dispatches. A bare wait can repeat
	# stale child diagnostics into pulse-wrapper.log after another wait site
	# has already reaped a child (GH#22919).
	_dispatch_max_wait_tracked_pids "${_pids[@]+${_pids[@]}}"
	_pids=()
	local dispatched_count
	dispatched_count=$(_dispatch_max_count_outcomes "$outcomes_file")
	printf '%d %d\n' "$dispatched_count" "$processed_count"
	return 0
}

#######################################
# Refresh an array variable of tracked PIDs by removing children that already
# finished.
#
# Arguments:
#   $1 - nameref-style array variable name
#######################################
_dispatch_max_refresh_pids() {
	local target_array_name="$1"
	local pid
	local _alive_pids=()
	local _current_pids=()
	eval "_current_pids=(\"\${${target_array_name}[@]+\${${target_array_name}[@]}}\")"
	while IFS= read -r pid; do
		[[ -n "$pid" ]] && _alive_pids+=("$pid")
	done < <(_dispatch_max_reap_pids "${_current_pids[@]+${_current_pids[@]}}")
	eval "${target_array_name}=(\"\${_alive_pids[@]+\${_alive_pids[@]}}\")"
	return 0
}

#######################################
# Wait until tracked PIDs fall below the parallel dispatch concurrency cap.
#
# Arguments:
#   $1 - nameref-style array variable name
#   $2 - max parallel workers
#######################################
_dispatch_max_wait_for_capacity() {
	local target_array_name="$1"
	local max_parallel="$2"
	local current_count=0

	eval "current_count=\${#${target_array_name}[@]}"
	while ((current_count >= max_parallel)); do
		_dispatch_max_refresh_pids "$target_array_name"
		eval "current_count=\${#${target_array_name}[@]}"
		((current_count >= max_parallel)) || break

		# GH#21729: if wait -n fails, remaining PIDs are stale (PID reuse: kill
		# -0 succeeds for another process, but it is not this shell's child).
		if ! wait -n 2>/dev/null; then
			echo "[pulse-wrapper] Dispatch_max: wait -n found no children, purging ${current_count} stale PIDs from _pids (GH#21729)" >>"$LOGFILE"
			eval "${target_array_name}=()"
			sleep 1
		fi
		eval "current_count=\${#${target_array_name}[@]}"
	done
	return 0
}

#######################################
# Check whether the parallel dispatch loop should stop before launching another
# candidate.
#
# Arguments:
#   $1 - processed count
#   $2 - successes so far
#   $3 - effective slot budget
#   $4 - in-flight dispatch count
# Returns:
#   0 - stop the loop
#   1 - continue dispatching
#######################################
_dispatch_max_should_stop() {
	local processed_count="$1"
	local successes_so_far="$2"
	local effective_slots="$3"
	local in_flight_count="$4"

	if ((successes_so_far + in_flight_count >= effective_slots)); then
		echo "[pulse-wrapper] Dispatch_max: parallel iter=${processed_count} — stopping (successes=${successes_so_far} + in_flight=${in_flight_count} >= effective_slots=${effective_slots})" >>"$LOGFILE"
		return 0
	fi
	if [[ -f "${STOP_FLAG:-}" ]]; then
		echo "[pulse-wrapper] Dispatch_max stopping early: stop flag appeared" >>"$LOGFILE"
		return 0
	fi
	if ! _dispatch_graphql_budget_allows_next; then
		echo "[pulse-wrapper] Dispatch_max stopping early: GraphQL circuit breaker tripped during parallel loop" >>"$LOGFILE"
		return 0
	fi
	return 1
}

#######################################
# Apply adaptive inter-launch delay before spawning another dispatch worker.
#
# Arguments:
#   $1 - successes so far
#   $2 - in-flight dispatch count
#   $3 - processed count
#   $4 - candidate JSON
#   $5 - max parallel workers
#######################################
_dispatch_max_apply_inter_launch_delay() {
	local successes_so_far="$1"
	local in_flight_count="$2"
	local processed_count="$3"
	local candidate_json="$4"
	local max_parallel="$5"

	local launched_so_far=$((successes_so_far + in_flight_count))
	local inter_launch_delay
	inter_launch_delay=$(_dispatch_inter_launch_delay "$launched_so_far" "$processed_count" "$candidate_json" "$max_parallel")
	[[ "$inter_launch_delay" =~ ^[0-9]+$ ]] || inter_launch_delay=0
	if ((inter_launch_delay > 0)); then
		local issue_num_for_delay
		issue_num_for_delay=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
		_dispatch_stats_increment "dispatch_inter_launch_staggered"
		echo "[pulse-wrapper] Dispatch_max: adaptive inter-launch stagger issue=#${issue_num_for_delay} delay=${inter_launch_delay}s launched_so_far=${launched_so_far} max_parallel=${max_parallel}" >>"$LOGFILE"
		sleep "$inter_launch_delay"
	fi
	return 0
}

#######################################
# Dispatch one candidate and append its outcome to the parallel loop outcomes
# file. Intended to be backgrounded by _dispatch_max_loop.
#
# Arguments:
#   $1 - candidate JSON
#   $2 - self login
#   $3 - available slot budget
#   $4 - outcomes file
#######################################
_dispatch_max_spawn_candidate() {
	local candidate_json="$1"
	local self_login="$2"
	local available_slots="$3"
	local outcomes_file="$4"
	local _rc=0

	_dispatch_process_candidate "$candidate_json" "$self_login" "$available_slots" >>"$LOGFILE" 2>&1 || _rc=$?
	local issue_num
	issue_num=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
	if [[ "$_rc" -eq 0 ]]; then
		printf 'success|%s\n' "$issue_num" >>"$outcomes_file"
	else
		printf 'fail|%s|rc=%d|reason=%s\n' "$issue_num" "$_rc" "${_PULSE_LAST_LAUNCH_FAILURE:-none}" >>"$outcomes_file"
	fi
	return 0
}

#######################################
# t3005/GH#22919: Wait only for tracked parallel-dispatch children.
#
# Avoids bare `wait`, which can emit repeated "pid is not a child" diagnostics
# when tracked PIDs were already reaped by earlier cap-loop cleanup.
#
# Arguments: $@ - pids to wait for
#######################################
_dispatch_max_wait_tracked_pids() {
	local pid
	for pid in "$@"; do
		[[ -n "$pid" ]] || continue
		wait "$pid" 2>/dev/null || true
	done
	return 0
}

#######################################
# t3005: Count outcome lines of a given type in the parallel-dispatch
# outcomes file. Extracted to avoid repeating the awk literal across
# call sites (the pre-commit string-literal validator counts "success"
# inside awk scripts as a shell-level repeated literal).
#
# Arguments:
#   $1 - outcomes_file
#   $2 - outcome type to count (literal match on field 1, default "success")
# Stdout: integer count (0 if file missing or empty)
#######################################
_dispatch_max_count_outcomes() {
	local outcomes_file="$1"
	local outcome_type="${2:-success}"
	local count
	count=$(awk -F'|' -v t="$outcome_type" '$1==t{c++} END{print c+0}' "$outcomes_file" 2>/dev/null)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%d\n' "$count"
	return 0
}

#######################################
# t3005: Reap completed pids — return only those still alive.
#
# Bash 3.2-safe array passing: handles empty input via the
# "${arr[@]+${arr[@]}}" idiom (set -u safe). Echoes alive pids one per line.
#
# Arguments: $@ - pids to check
# Stdout: alive pids (whitespace-separated)
#######################################
_dispatch_max_reap_pids() {
	local pid
	for pid in "$@"; do
		[[ -n "$pid" ]] || continue
		if kill -0 "$pid" 2>/dev/null; then
			printf '%s\n' "$pid"
		fi
	done
	return 0
}

#######################################
# t3005: Aggregate parallel-dispatch outcomes into module-global counters.
#
# After the parallel loop returns, _DISPATCH_ROUND_DISPATCHED and
# _DISPATCH_ROUND_NO_WORKER_FAILURES are still 0 because the subshells couldn't
# mutate them. Re-derive both from the outcomes file.
#
# Also handles canary-cache invalidation (parallel approximation of the
# serial path's "3 consecutive no_worker_process" rule — uses total count
# in the round). Idempotent file removal: invalidating an already-gone
# cache is a no-op.
#
# Arguments:
#   $1 - outcomes_file
# Side effects:
#   - Sets _DISPATCH_ROUND_DISPATCHED, _DISPATCH_ROUND_NO_WORKER_FAILURES
#   - Removes _DISPATCH_CANARY_CACHE if no_worker_failures >= 3
#   - Removes _DISPATCH_THROTTLE_FILE if any successes (parallel can only run when
#     throttle was already off, but defensive cleanup is cheap)
#######################################
_dispatch_max_aggregate_outcomes() {
	local outcomes_file="$1"
	local successes="" fails="" no_worker_failures=""
	successes=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	fails=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
	# no_worker_process is identified via the reason field embedded in the
	# fail line — match the substring rather than adding another field.
	no_worker_failures=$(awk -F'|' -v t="fail" '$1==t && /no_worker_process/{c++} END{print c+0}' "$outcomes_file" 2>/dev/null)
	[[ "$no_worker_failures" =~ ^[0-9]+$ ]] || no_worker_failures=0

	_DISPATCH_ROUND_DISPATCHED=$((successes + fails))
	_DISPATCH_ROUND_NO_WORKER_FAILURES="$no_worker_failures"

	if ((no_worker_failures >= 3)); then
		if [[ -f "$_DISPATCH_CANARY_CACHE" ]]; then
			rm -f "$_DISPATCH_CANARY_CACHE"
			echo "[pulse-wrapper] Canary cache invalidated after ${no_worker_failures} no_worker_process failures in parallel round — next dispatch will re-run canary" >>"$LOGFILE"
		fi
	fi

	if ((successes > 0)) && [[ -f "$_DISPATCH_THROTTLE_FILE" ]]; then
		rm -f "$_DISPATCH_THROTTLE_FILE"
		echo "[pulse-wrapper] Dispatch throttle CLEARED: parallel round had ${successes} successful launches" >>"$LOGFILE"
	fi
	return 0
}
