#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-pass.sh — Deterministic merge-pass checkpoint orchestration
# =============================================================================
# Provides checkpoint, PR cursor, graceful-budget, and all-repository pass
# helpers for pulse-merge-process.sh.
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-pass.sh"
# Part of aidevops framework: https://aidevops.sh

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_MERGE_PASS_LOADED:-}" ]] && return 0
_PULSE_MERGE_PASS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_pmp_pass_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pmp_pass_path" == "${BASH_SOURCE[0]}" ]] && _pmp_pass_path="."
	SCRIPT_DIR="$(cd "$_pmp_pass_path" && pwd)"
	unset _pmp_pass_path
fi

_pmp_write_merge_checkpoint() {
	local checkpoint_file="$1"
	local repo_slug="$2"
	local checkpoint_dir=""

	[[ -n "$checkpoint_file" && -n "$repo_slug" ]] || return 0
	checkpoint_dir="${checkpoint_file%/*}"
	if [[ -n "$checkpoint_dir" && "$checkpoint_dir" != "$checkpoint_file" ]]; then
		mkdir -p "$checkpoint_dir" 2>/dev/null || return 0
	fi
	printf '%s\n' "$repo_slug" >"$checkpoint_file" 2>/dev/null || true
	return 0
}

_pmp_clear_merge_checkpoint() {
	local checkpoint_file="$1"

	[[ -n "$checkpoint_file" ]] || return 0
	rm -f "$checkpoint_file" 2>/dev/null || true
	return 0
}

_pmp_clear_merge_pr_cursor() {
	local cursor_file="$1"

	[[ -n "$cursor_file" ]] || return 0
	rm -f "$cursor_file" 2>/dev/null || true
	return 0
}

_pmp_write_merge_pr_cursor() {
	local cursor_file="$1"
	local repo_slug="$2"
	local next_index="$3"
	local last_pr_number="$4"
	local next_pr_number="$5"

	[[ -n "$cursor_file" && -n "$repo_slug" ]] || return 0
	[[ "$next_index" =~ ^[0-9]+$ ]] || next_index=0
	printf '%s|%s|%s|%s\n' "$repo_slug" "$next_index" "$last_pr_number" "$next_pr_number" >"$cursor_file" 2>/dev/null || true
	return 0
}

_pmp_read_merge_pr_cursor_last() {
	local cursor_file="$1"
	local repo_slug="$2"
	local last_pr_var="$3"
	local cursor_repo="" cursor_next_index="" cursor_last_pr="" cursor_next_pr=""

	[[ "$last_pr_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	if [[ -n "$cursor_file" && -f "$cursor_file" ]]; then
		IFS='|' read -r cursor_repo cursor_next_index cursor_last_pr cursor_next_pr <"$cursor_file" || true
		if [[ "$cursor_repo" == "$repo_slug" ]]; then
			printf -v "$last_pr_var" '%s' "$cursor_last_pr"
			return 0
		fi
	fi
	printf -v "$last_pr_var" '%s' ''
	return 0
}

_pmp_pr_cursor_index_for_number() {
	local pr_json="$1"
	local pr_number="$2"

	[[ -n "$pr_number" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$pr_json" | jq --argjson pr_number "$pr_number" 'map(.number == $pr_number) | index(true) // empty' 2>/dev/null
	return 0
}

_pmp_pr_object_at_index() {
	local pr_json="$1"
	local pr_index="$2"

	[[ "$pr_index" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$pr_json" | jq -c --argjson pr_index "$pr_index" '.[$pr_index]' 2>/dev/null
	return 0
}

_pmp_pr_number_at_index() {
	local pr_json="$1"
	local pr_index="$2"

	[[ "$pr_index" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$pr_json" | jq -r --argjson pr_index "$pr_index" '.[$pr_index].number // empty' 2>/dev/null
	return 0
}

_pmp_prepare_merge_pr_cursor_resume() {
	local repo_slug="$1"
	local pr_json="$2"
	local pr_count="$3"
	local cursor_file="$4"
	local logfile="$5"
	local start_index_var="$6"
	local cursor_repo="" cursor_next_index="" cursor_last_pr="" cursor_next_pr=""
	local start_index=0 located_index=""

	[[ "$start_index_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	if [[ -n "$cursor_file" && -f "$cursor_file" ]]; then
		IFS='|' read -r cursor_repo cursor_next_index cursor_last_pr cursor_next_pr <"$cursor_file" || true
		if [[ "$cursor_repo" == "$repo_slug" ]]; then
			located_index=$(_pmp_pr_cursor_index_for_number "$pr_json" "$cursor_next_pr") || located_index=""
			if [[ "$located_index" =~ ^[0-9]+$ ]]; then
				start_index="$located_index"
			else
				located_index=$(_pmp_pr_cursor_index_for_number "$pr_json" "$cursor_last_pr") || located_index=""
				if [[ "$located_index" =~ ^[0-9]+$ ]]; then
					start_index=$((located_index + 1))
				elif [[ "$cursor_next_index" =~ ^[0-9]+$ ]]; then
					start_index="$cursor_next_index"
				fi
			fi
			if [[ "$start_index" -ge "$pr_count" ]]; then
				_pmp_clear_merge_pr_cursor "$cursor_file"
				start_index=0
			else
				echo "[pulse-wrapper] Merge pass: resuming ${repo_slug} at PR cursor index=${start_index} last_pr=${cursor_last_pr:-none} next_pr=${cursor_next_pr:-none}" >>"$logfile"
			fi
		elif [[ -n "$cursor_repo" ]]; then
			echo "[pulse-wrapper] Merge pass: ignoring stale PR cursor repo=${cursor_repo} while processing ${repo_slug}" >>"$logfile"
			_pmp_clear_merge_pr_cursor "$cursor_file"
		fi
	fi

	printf -v "$start_index_var" '%s' "$start_index"
	return 0
}

_pmp_merge_pass_budget_deadline() {
	local pass_start="$1"
	local budget_seconds="${PULSE_MERGE_GRACEFUL_BUDGET_SECONDS:-}"
	local ceiling_seconds="${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS:-${PRE_RUN_STAGE_TIMEOUT:-0}}"
	local reserve_seconds="${PULSE_MERGE_GRACEFUL_BUDGET_RESERVE_SECONDS:-45}"

	[[ "$pass_start" =~ ^[0-9]+$ ]] || pass_start=0
	[[ "$reserve_seconds" =~ ^[0-9]+$ ]] || reserve_seconds=45
	if [[ -z "$budget_seconds" ]]; then
		[[ "$ceiling_seconds" =~ ^[0-9]+$ ]] || ceiling_seconds=0
		if [[ "$ceiling_seconds" -gt "$reserve_seconds" ]]; then
			budget_seconds=$((ceiling_seconds - reserve_seconds))
		else
			budget_seconds=0
		fi
	fi
	[[ "$budget_seconds" =~ ^[0-9]+$ ]] || budget_seconds=0
	if [[ "$budget_seconds" -gt 0 && "$pass_start" -gt 0 ]]; then
		printf '%s' "$((pass_start + budget_seconds))"
	else
		printf '0'
	fi
	return 0
}

_pmp_merge_pass_budget_exhausted() {
	local deadline_epoch="${_PMP_MERGE_PASS_DEADLINE_EPOCH:-0}"
	local now_epoch=""

	[[ "$deadline_epoch" =~ ^[0-9]+$ ]] || deadline_epoch=0
	[[ "$deadline_epoch" -gt 0 ]] || return 1
	now_epoch=$(_pmp_now_epoch)
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
	[[ "$now_epoch" -ge "$deadline_epoch" ]] || return 1
	return 0
}

#######################################
# Compute a separate graceful deadline for post-primary diagnostics. The
# default consumes at most 30s of the primary pass's 45s reserve and keeps a
# final 15s for summary/cleanup before the routine watchdog.
# Args: $1=overall pass start epoch, $2=diagnostic phase start epoch
# Stdout: deadline epoch (the start epoch means diagnostics are disabled)
#######################################
_pmp_merge_diagnostics_deadline() {
	local pass_start="$1"
	local diagnostics_start="$2"
	local budget_seconds="${PULSE_MERGE_DIAGNOSTIC_BUDGET_SECONDS:-30}"
	local ceiling_seconds="${PULSE_MERGE_ROUTINE_TIMEOUT_SECONDS:-${PRE_RUN_STAGE_TIMEOUT:-0}}"
	local final_reserve_seconds="${PULSE_MERGE_DIAGNOSTIC_FINAL_RESERVE_SECONDS:-15}"
	local deadline_epoch=0 hard_deadline=0

	[[ "$pass_start" =~ ^[0-9]+$ ]] || pass_start=0
	[[ "$diagnostics_start" =~ ^[0-9]+$ ]] || diagnostics_start=0
	[[ "$budget_seconds" =~ ^[0-9]+$ ]] || budget_seconds=30
	[[ "$ceiling_seconds" =~ ^[0-9]+$ ]] || ceiling_seconds=0
	[[ "$final_reserve_seconds" =~ ^[0-9]+$ ]] || final_reserve_seconds=15
	deadline_epoch=$((diagnostics_start + budget_seconds))
	if [[ "$ceiling_seconds" -gt 0 && "$pass_start" -gt 0 ]]; then
		hard_deadline=$((pass_start + ceiling_seconds - final_reserve_seconds))
		[[ "$hard_deadline" -lt "$diagnostics_start" ]] && hard_deadline="$diagnostics_start"
		[[ "$deadline_epoch" -gt "$hard_deadline" ]] && deadline_epoch="$hard_deadline"
	fi
	printf '%s' "$deadline_epoch"
	return 0
}

_pmp_merge_diagnostics_budget_exhausted() {
	local deadline_epoch="${_PMP_MERGE_DIAGNOSTIC_DEADLINE_EPOCH:-0}"
	local now_epoch=""

	[[ "$deadline_epoch" =~ ^[0-9]+$ ]] || deadline_epoch=0
	[[ "$deadline_epoch" -gt 0 ]] || return 1
	now_epoch=$(_pmp_now_epoch)
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
	[[ "$now_epoch" -ge "$deadline_epoch" ]] || return 1
	return 0
}

_pmp_pause_merge_pr_cursor() {
	local repo_slug="$1"
	local pr_json="$2"
	local cursor_index="$3"
	local pause_reason="$4"
	local merged_var="$5"
	local closed_var="$6"
	local failed_var="$7"
	local merged_count="$8"
	local closed_count="$9"
	local failed_count="${10}"
	local required_contexts_cache_dir="${11:-}"
	local author_permission_cache_dir="${12:-}"
	local next_pr="" last_pr=""
	local cursor_file="${PULSE_MERGE_PR_CURSOR_FILE:-}"
	local logfile="${LOGFILE:-/dev/null}"

	next_pr=$(_pmp_pr_number_at_index "$pr_json" "$cursor_index") || next_pr=""
	_pmp_read_merge_pr_cursor_last "$cursor_file" "$repo_slug" last_pr || last_pr=""
	_pmp_write_merge_pr_cursor "$cursor_file" "$repo_slug" "$cursor_index" "$last_pr" "$next_pr"
	case "$pause_reason" in
	budget)
		echo "[pulse-wrapper] Merge pass: graceful time budget exhausted for ${repo_slug}; pausing at PR cursor index=${cursor_index} next_pr=${next_pr:-none}" >>"$logfile"
		;;
	cooldown)
		echo "[pulse-wrapper] Merge pass: GitHub cooldown active for ${repo_slug}; pausing remaining PR processing" >>"$logfile"
		;;
	stop) ;;
	esac
	eval "${merged_var}=${merged_count}; ${closed_var}=${closed_count}; ${failed_var}=${failed_count}"
	[[ -n "$required_contexts_cache_dir" ]] && rm -rf -- "$required_contexts_cache_dir"
	[[ -n "$author_permission_cache_dir" ]] && rm -rf -- "$author_permission_cache_dir"
	return 5
}

_pmp_repo_rows_contain_slug() {
	local repo_rows="$1"
	local checkpoint_slug="$2"
	local row_slug="" row_path=""

	[[ -n "$repo_rows" && -n "$checkpoint_slug" ]] || return 1
	while IFS='|' read -r row_slug row_path; do
		[[ -n "$row_slug" ]] || continue
		if [[ "$row_slug" == "$checkpoint_slug" ]]; then
			return 0
		fi
	done <<<"$repo_rows"
	return 1
}

_pmp_prepare_merge_checkpoint_resume() {
	local repo_rows="$1"
	local checkpoint_file="$2"
	local logfile="$3"
	local checkpoint_var="$4"
	local resume_pending_var="$5"
	local resumed_var="$6"
	local checkpoint=""
	local resume_pending=0
	local resumed=0

	[[ "$checkpoint_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$resume_pending_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$resumed_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1

	if [[ -n "$checkpoint_file" && -f "$checkpoint_file" ]]; then
		IFS= read -r checkpoint <"$checkpoint_file" || [[ -n "$checkpoint" ]] || true
		if [[ -n "$checkpoint" ]]; then
			if _pmp_repo_rows_contain_slug "$repo_rows" "$checkpoint"; then
				resume_pending=1
				resumed=1
				echo "[pulse-wrapper] Deterministic merge pass resuming after checkpoint repo=${checkpoint}" >>"$logfile"
			else
				echo "[pulse-wrapper] Deterministic merge pass ignoring stale checkpoint repo=${checkpoint}" >>"$logfile"
				_pmp_clear_merge_checkpoint "$checkpoint_file"
				checkpoint=""
			fi
		fi
	fi

	printf -v "$checkpoint_var" '%s' "$checkpoint"
	printf -v "$resume_pending_var" '%s' "$resume_pending"
	printf -v "$resumed_var" '%s' "$resumed"
	return 0
}

_pmp_checkpoint_resume_skip_repo() {
	local repo_slug="$1"
	local checkpoint="$2"
	local resume_pending_var="$3"
	local resume_pending=""

	[[ "$resume_pending_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	resume_pending="${!resume_pending_var:-}"
	[[ "$resume_pending" -eq 1 ]] || return 1
	if [[ "$repo_slug" == "$checkpoint" ]]; then
		printf -v "$resume_pending_var" '%s' '0'
	fi
	return 0
}

_pmp_add_counter_var() {
	local counter_var="$1"
	local increment="${2:-0}"
	local current=""

	[[ "$counter_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	current="${!counter_var:-}"
	[[ "$current" =~ ^[0-9]+$ ]] || current=0
	[[ "$increment" =~ ^[0-9]+$ ]] || increment=0
	printf -v "$counter_var" '%s' "$((current + increment))"
	return 0
}

#######################################
# Resolve the pass-local evidence directory for one repository.
# Args: $1=repo slug
# Stdout: directory path
# Returns: 0=available, 1=pass-local evidence disabled/unavailable
#######################################
_pmp_same_pass_repo_dir() {
	local repo_slug="$1"
	local outcome_root="${AIDEVOPS_PULSE_MERGE_OUTCOME_DIR:-}"
	local repo_key=""

	[[ -n "$repo_slug" && -n "$outcome_root" && -d "$outcome_root" ]] || return 1
	repo_key=$(_pmp_cache_key "$repo_slug")
	[[ -n "$repo_key" ]] || return 1
	printf '%s/%s' "$outcome_root" "$repo_key"
	return 0
}

#######################################
# Record the authoritative outcome of one PR processed in this merge pass.
# The key includes repository identity, PR number, and the full head SHA. These
# records are diagnostic-only: merge trust gates never consume them.
# Args: $1=repo slug, $2=PR number, $3=full head SHA, $4=outcome
#######################################
_pmp_record_same_pass_pr_outcome() {
	local repo_slug="$1"
	local pr_number="$2"
	local head_sha="$3"
	local outcome="$4"
	local repo_dir=""
	local sha_key=""

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$head_sha" ]] || return 1
	case "$outcome" in
	merged | progress | eligible-unmerged | deferred | blocked) ;;
	*) return 1 ;;
	esac
	repo_dir=$(_pmp_same_pass_repo_dir "$repo_slug") || return 1
	sha_key=$(_pmp_cache_key "$head_sha")
	[[ -n "$sha_key" ]] || return 1
	mkdir -p "${repo_dir}/outcomes" 2>/dev/null || return 1
	printf '%s\t%s\n' "$pr_number" "$outcome" >"${repo_dir}/outcomes/${pr_number}-${sha_key}.outcome" || return 1
	return 0
}

#######################################
# Mark one repository's same-pass PR outcomes as complete. The marker is only
# written after every PR in a successful list snapshot was processed.
# Args: $1=repo slug
#######################################
_pmp_mark_same_pass_repo_complete() {
	local repo_slug="$1"
	local repo_dir=""

	repo_dir=$(_pmp_same_pass_repo_dir "$repo_slug") || return 1
	mkdir -p "$repo_dir" 2>/dev/null || return 1
	: >"${repo_dir}/complete" || return 1
	return 0
}

#######################################
# Count exact merge-attempt failures from a complete same-pass repository
# snapshot. A return code of 1 means callers must not infer zero eligible PRs.
# Args: $1=repo slug
# Stdout: eligible-unmerged count
#######################################
_pmp_count_same_pass_eligible_unmerged() {
	local repo_slug="$1"
	local repo_dir="" outcome_file="" pr_number="" outcome=""
	local count=0

	repo_dir=$(_pmp_same_pass_repo_dir "$repo_slug") || return 1
	[[ -f "${repo_dir}/complete" ]] || return 1
	for outcome_file in "${repo_dir}/outcomes/"*.outcome; do
		[[ -f "$outcome_file" ]] || continue
		IFS=$'\t' read -r pr_number outcome <"$outcome_file" || return 1
		[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
		case "$outcome" in
		eligible-unmerged) count=$((count + 1)) ;;
		merged | progress | deferred | blocked) ;;
		*) return 1 ;;
		esac
	done
	printf '%s' "$count"
	return 0
}

#######################################
# Preserve normalized current-head check evidence already fetched by the final
# trust gate for later diagnostics in this same pass. This cache is deliberately
# never read by a merge decision.
# Args: $1=repo slug, $2=full head SHA, $3=normalized checks JSON array
#######################################
_pmp_record_same_pass_check_evidence() {
	local repo_slug="$1"
	local head_sha="$2"
	local checks_json="$3"
	local repo_dir=""
	local sha_key=""

	[[ -n "$head_sha" && -n "$checks_json" && "$checks_json" != "null" ]] || return 1
	repo_dir=$(_pmp_same_pass_repo_dir "$repo_slug") || return 1
	sha_key=$(_pmp_cache_key "$head_sha")
	[[ -n "$sha_key" ]] || return 1
	mkdir -p "${repo_dir}/checks" 2>/dev/null || return 1
	printf '%s\n' "$checks_json" >"${repo_dir}/checks/${sha_key}.json" || return 1
	return 0
}

#######################################
# Read normalized current-head check evidence captured earlier in this pass.
# Args: $1=repo slug, $2=full head SHA
# Stdout: normalized checks JSON array
# Returns: 0=valid evidence found, 1=missing/invalid
#######################################
_pmp_same_pass_check_evidence_get() {
	local repo_slug="$1"
	local head_sha="$2"
	local repo_dir=""
	local sha_key=""
	local evidence_file=""
	local checks_json=""

	[[ -n "$head_sha" ]] || return 1
	repo_dir=$(_pmp_same_pass_repo_dir "$repo_slug") || return 1
	sha_key=$(_pmp_cache_key "$head_sha")
	evidence_file="${repo_dir}/checks/${sha_key}.json"
	[[ -s "$evidence_file" ]] || return 1
	checks_json=$(<"$evidence_file")
	printf '%s' "$checks_json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
	printf '%s' "$checks_json"
	return 0
}

#######################################
# Collect the zero-progress denominator from authoritative same-pass outcomes.
# Production callers require this path and never fall back to O(n) network gate
# re-evaluation. Standalone callers of the stuck helper retain its fallback.
# Args: $1=repo rows, $2=log file, $3=total var, $4=complete var
#######################################
_pmp_collect_same_pass_eligible_unmerged() {
	local repo_rows="$1"
	local logfile="$2"
	local total_var="$3"
	local complete_var="$4"
	local total=0 complete=1
	local repo_slug=""
	local repo_path=""
	local repo_eligible=""
	local AIDEVOPS_PULSE_REQUIRE_SAME_PASS_OUTCOME=1

	[[ "$total_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$complete_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	while IFS='|' read -r repo_slug repo_path; do
		[[ -n "$repo_slug" ]] || continue
		if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
			|| ! repo_allows_pulse_write_actions "$repo_slug"; then
			continue
		fi
		if ! declare -F _pms_count_eligible_unmerged_for_repo >/dev/null 2>&1 \
			|| ! repo_eligible=$(_pms_count_eligible_unmerged_for_repo "$repo_slug" 2>/dev/null); then
			complete=0
			echo "[pulse-wrapper] Zero-progress snapshot unavailable for ${repo_slug}; aggregate not advanced" >>"$logfile"
			continue
		fi
		[[ "$repo_eligible" =~ ^[0-9]+$ ]] || { complete=0; continue; }
		total=$((total + repo_eligible))
	done <<<"$repo_rows"
	printf -v "$total_var" '%s' "$total"
	printf -v "$complete_var" '%s' "$complete"
	return 0
}

_pmp_diagnostic_seconds_for_repo() {
	local timing_rows="$1"
	local target_slug="$2"
	local row_slug="" elapsed=""

	while IFS='|' read -r row_slug elapsed; do
		[[ "$row_slug" == "$target_slug" ]] || continue
		[[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0
		printf '%s' "$elapsed"
		return 0
	done <<<"$timing_rows"
	printf '0'
	return 0
}

#######################################
# Run expensive stuck classification only after every primary merge attempt.
# The detector receives the separate deadline and reports whether it completed.
# Args: $1=repo rows, $2=pass start, $3=log file, $4=timing rows var,
#       $5=complete var
#######################################
_pmp_run_stuck_diagnostics_for_repos() {
	local repo_rows="$1"
	local pass_start="$2"
	local logfile="$3"
	local timing_rows_var="$4"
	local complete_var="$5"
	local timing_rows="" complete=1
	local repo_slug=""
	local repo_path=""
	local diagnostics_start=""
	local stuck_start=""
	local stuck_seconds=0 repo_complete=1

	[[ "$timing_rows_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	[[ "$complete_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	diagnostics_start=$(_pmp_now_epoch)
	_PMP_MERGE_DIAGNOSTIC_DEADLINE_EPOCH=$(_pmp_merge_diagnostics_deadline "$pass_start" "$diagnostics_start")
	while IFS='|' read -r repo_slug repo_path; do
		[[ -n "$repo_slug" ]] || continue
		if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
			|| ! repo_allows_pulse_write_actions "$repo_slug"; then
			continue
		fi
		if _pmp_merge_diagnostics_budget_exhausted; then
			complete=0
			echo "[pulse-wrapper] Merge diagnostics: separate graceful budget exhausted before ${repo_slug}; remaining diagnostics deferred" >>"$logfile"
			break
		fi
		stuck_start=$(_pmp_now_epoch)
		repo_complete=1
		if declare -F pulse_merge_stuck_run_pass >/dev/null 2>&1; then
			pulse_merge_stuck_run_pass "$repo_slug" repo_complete || true
		fi
		stuck_seconds=0
		_pmp_add_elapsed_seconds stuck_seconds "$stuck_start"
		timing_rows="${timing_rows}${repo_slug}|${stuck_seconds}"$'\n'
		if [[ "$repo_complete" -ne 1 ]]; then
			complete=0
			break
		fi
	done <<<"$repo_rows"
	printf -v "$timing_rows_var" '%s' "$timing_rows"
	printf -v "$complete_var" '%s' "$complete"
	return 0
}

_pmp_log_repo_timing_rows() {
	local primary_rows="$1"
	local diagnostic_rows="$2"
	local repo_slug="" total_s=0 list_s=0 mergeability_s=0 ruleset_s=0 branch_protection_s=0
	local merged=0 closed=0 failed=0 pr_count=0 stuck_s=0

	while IFS='|' read -r repo_slug total_s list_s mergeability_s ruleset_s branch_protection_s merged closed failed pr_count; do
		[[ -n "$repo_slug" ]] || continue
		stuck_s=$(_pmp_diagnostic_seconds_for_repo "$diagnostic_rows" "$repo_slug")
		[[ "$total_s" =~ ^[0-9]+$ ]] || total_s=0
		total_s=$((total_s + stuck_s))
		_pmp_log_repo_timing_summary "$repo_slug" "$total_s" "$list_s" "$mergeability_s" "$ruleset_s" "$branch_protection_s" "$stuck_s" "$merged" "$closed" "$failed" "$pr_count"
	done <<<"$primary_rows"
	return 0
}

#######################################
# Persist the authoritative zero-progress signal before bounded diagnostics.
# Positive progress is conclusive even for partial/resumed passes; a no-progress
# denominator is valid only for a fresh, complete pass-local outcome snapshot.
# Args: $1=eligible, $2=merged, $3=closed, $4=pass complete,
#       $5=resumed from checkpoint, $6=outcomes complete
#######################################
_pmp_record_pass_zero_progress() {
	local eligible_unmerged="$1"
	local merged="$2"
	local closed="$3"
	local pass_complete="$4"
	local resumed_from_checkpoint="$5"
	local outcomes_complete="$6"

	declare -F pulse_merge_zero_progress_record >/dev/null 2>&1 || return 0
	if [[ "$merged" -gt 0 || "$closed" -gt 0 ]]; then
		pulse_merge_zero_progress_record 0 "$merged" "$closed" || true
		return 0
	fi
	if [[ "$pass_complete" -eq 1 && "$resumed_from_checkpoint" -eq 0 && "$outcomes_complete" -eq 1 ]]; then
		pulse_merge_zero_progress_record "$eligible_unmerged" "$merged" "$closed" || true
	fi
	return 0
}

# Persist conclusive queue-draining progress at the mutation boundary. The
# outer merge routine can be killed by its watchdog before the all-repo pass
# returns, so the end-of-pass aggregate remains a fallback rather than the only
# place that resets the zero-progress streak (GH#28285).
_pmp_record_deterministic_progress_now() {
	local merged_count="$1"
	local progress_count="$2"

	[[ "$merged_count" =~ ^[0-9]+$ ]] || merged_count=0
	[[ "$progress_count" =~ ^[0-9]+$ ]] || progress_count=0
	if [[ "$merged_count" -le 0 && "$progress_count" -le 0 ]]; then
		return 0
	fi
	if declare -F pulse_merge_zero_progress_record >/dev/null 2>&1; then
		pulse_merge_zero_progress_record 0 "$merged_count" "$progress_count" || true
	fi
	return 0
}

_pmp_process_merge_repo_for_pass() {
	local repo_slug="$1"
	local checkpoint_file="$2"
	local logfile="$3"
	local stop_flag="$4"
	local total_merged_var="$5"
	local total_closed_var="$6"
	local total_failed_var="$7"
	local completed_all_var="$8"
	_PMP_LAST_REPO_TIMING_ROW=""

	if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
		|| ! repo_allows_pulse_write_actions "$repo_slug"; then
		echo "[pulse-wrapper] Deterministic merge pass skipped ${repo_slug}: repo role is contributor/read-only" >>"$logfile"
		_pmp_write_merge_checkpoint "$checkpoint_file" "$repo_slug"
		return 0
	fi

	local repo_merged=0 repo_closed=0 repo_failed=0 _mr_repo_pr_count=0
	local _mr_repo_list_s=0 _mr_repo_mergeability_s=0 _mr_repo_ruleset_s=0 _mr_repo_branch_protection_s=0
	local _mr_repo_start _mr_repo_total_s=0
	_mr_repo_start=$(_pmp_now_epoch)

	local _mr_repo_rc=0
	_merge_ready_prs_for_repo "$repo_slug" repo_merged repo_closed repo_failed _mr_repo_pr_count "_mr_repo_" || _mr_repo_rc=$?
	_pmp_add_counter_var "$total_merged_var" "$repo_merged"
	_pmp_add_counter_var "$total_closed_var" "$repo_closed"
	_pmp_add_counter_var "$total_failed_var" "$repo_failed"
	_pmp_add_elapsed_seconds _mr_repo_total_s "$_mr_repo_start"
	_PMP_LAST_REPO_TIMING_ROW="${repo_slug}|${_mr_repo_total_s}|${_mr_repo_list_s}|${_mr_repo_mergeability_s}|${_mr_repo_ruleset_s}|${_mr_repo_branch_protection_s}|${repo_merged}|${repo_closed}|${repo_failed}|${_mr_repo_pr_count}"
	if [[ "$_mr_repo_rc" -eq 5 ]]; then
		echo "[pulse-wrapper] Deterministic merge pass paused mid-repo ${repo_slug}; PR cursor persisted" >>"$logfile"
		printf -v "$completed_all_var" '%s' '0'
		return 0
	fi

	_pmp_write_merge_checkpoint "$checkpoint_file" "$repo_slug"
	_pmp_clear_merge_pr_cursor "${PULSE_MERGE_PR_CURSOR_FILE:-}"

	if [[ -f "$stop_flag" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass: stop flag appeared mid-run" >>"$logfile"
		printf -v "$completed_all_var" '%s' '0'
	fi
	return 0
}

merge_ready_prs_all_repos() {
	# Initialise required env vars with ${VAR:-default} guards so this
	# function can be called standalone from pulse-merge-routine.sh (t2862)
	# without relying on pulse-wrapper.sh having set them in the bootstrap.
	# When called from pulse-wrapper.sh the pre-existing values are kept.
	local _mr_stop_flag="${STOP_FLAG:-${HOME}/.aidevops/logs/pulse-session.stop}"
	local _mr_repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local _mr_logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	local _mr_checkpoint_file="${PULSE_MERGE_CHECKPOINT_FILE:-${HOME}/.aidevops/logs/pulse-merge-checkpoint}"
	PULSE_MERGE_PR_CURSOR_FILE="${PULSE_MERGE_PR_CURSOR_FILE:-${_mr_checkpoint_file}.pr-cursor}"
	PULSE_MERGE_BATCH_LIMIT="${PULSE_MERGE_BATCH_LIMIT:-50}"
	local _mr_pass_start
	_mr_pass_start=$(_pmp_now_epoch)
	_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$_mr_pass_start")

	if [[ -f "$_mr_stop_flag" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: stop flag present" >>"$_mr_logfile"
		return 0
	fi

	if [[ ! -f "$_mr_repos_json" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: repos.json not found" >>"$_mr_logfile"
		return 0
	fi

	local total_merged=0 total_closed=0 total_failed=0

	local total_eligible_unmerged=0
	local AIDEVOPS_PULSE_MERGE_OUTCOME_DIR=""
	local _mr_repo_rows=""
	local _mr_checkpoint=""
	local _mr_resume_pending=0
	local _mr_resumed_from_checkpoint=0
	local _mr_completed_all=1
	local _mr_outcomes_complete=1
	local _mr_diagnostics_complete=1
	local _mr_primary_timing_rows="" _mr_diagnostic_timing_rows=""
	local repo_slug=""
	local repo_path=""
	AIDEVOPS_PULSE_MERGE_OUTCOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-pulse-merge-outcomes.XXXXXX" 2>/dev/null) || AIDEVOPS_PULSE_MERGE_OUTCOME_DIR=""
	if [[ -z "$AIDEVOPS_PULSE_MERGE_OUTCOME_DIR" ]]; then
		echo "[pulse-wrapper] Same-pass merge outcome cache unavailable; zero-progress aggregate will fail closed" >>"$_mr_logfile"
	fi

	_mr_repo_rows=$(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$_mr_repos_json" 2>/dev/null) || _mr_repo_rows=""
	_pmp_prepare_merge_checkpoint_resume "$_mr_repo_rows" "$_mr_checkpoint_file" "$_mr_logfile" \
		_mr_checkpoint _mr_resume_pending _mr_resumed_from_checkpoint || true

	while IFS='|' read -r repo_slug repo_path; do
		[[ -n "$repo_slug" ]] || continue
		if _pmp_checkpoint_resume_skip_repo "$repo_slug" "$_mr_checkpoint" _mr_resume_pending; then
			continue
		fi
		_pmp_process_merge_repo_for_pass "$repo_slug" "$_mr_checkpoint_file" "$_mr_logfile" "$_mr_stop_flag" \
			total_merged total_closed total_failed _mr_completed_all
		if [[ -n "${_PMP_LAST_REPO_TIMING_ROW:-}" ]]; then
			_mr_primary_timing_rows="${_mr_primary_timing_rows}${_PMP_LAST_REPO_TIMING_ROW}"$'\n'
		fi
		if [[ "$_mr_completed_all" -eq 0 ]]; then
			break
		fi
	done <<<"$_mr_repo_rows"

	if [[ "$_mr_completed_all" -eq 1 ]]; then
		_pmp_clear_merge_checkpoint "$_mr_checkpoint_file"
		_pmp_clear_merge_pr_cursor "$PULSE_MERGE_PR_CURSOR_FILE"
	fi
	if [[ "$_mr_completed_all" -eq 1 ]]; then
		if [[ "$_mr_resumed_from_checkpoint" -eq 0 ]]; then
			_pmp_collect_same_pass_eligible_unmerged "$_mr_repo_rows" "$_mr_logfile" \
				total_eligible_unmerged _mr_outcomes_complete || _mr_outcomes_complete=0
		fi
	fi
	# Record the all-repository throughput signal before expensive diagnostics so
	# the watchdog cannot erase a completed primary-pass result (t3193).
	_pmp_record_pass_zero_progress "$total_eligible_unmerged" "$total_merged" "$total_closed" \
		"$_mr_completed_all" "$_mr_resumed_from_checkpoint" "$_mr_outcomes_complete"
	if [[ "$_mr_completed_all" -eq 1 ]]; then
		_pmp_run_stuck_diagnostics_for_repos "$_mr_repo_rows" "$_mr_pass_start" "$_mr_logfile" \
			_mr_diagnostic_timing_rows _mr_diagnostics_complete || _mr_diagnostics_complete=0
	fi
	_pmp_log_repo_timing_rows "$_mr_primary_timing_rows" "$_mr_diagnostic_timing_rows"

	echo "[pulse-wrapper] Deterministic merge pass complete: merged=${total_merged}, closed_conflicting=${total_closed}, failed=${total_failed}, eligible_unmerged=${total_eligible_unmerged}, diagnostics_complete=${_mr_diagnostics_complete}" >>"$_mr_logfile"
	# Write health counter deltas to a temp file (GH#18571, GH#15107).
	# run_stage_with_timeout backgrounds this function in a subshell, so
	# direct updates to _PULSE_HEALTH_* variables are lost on return.
	# The parent process reads this file after the stage completes.
	local _health_delta_file="${TMPDIR:-/tmp}/pulse-health-merge-$$.tmp"
	printf '%s %s %s %s\n' \
		"$total_merged" "$total_closed" \
		"${_PULSE_CYCLE_BLOCKER_KIND:-none}" \
		"${_PULSE_CYCLE_BLOCKER_FINGERPRINT:--}" \
		>"$_health_delta_file" || true
	local _mr_pass_total_s=0
	_pmp_add_elapsed_seconds _mr_pass_total_s "$_mr_pass_start"
	echo "[pulse-wrapper] deterministic_merge_pass timing: total_s=${_mr_pass_total_s} merged=${total_merged} closed_conflicting=${total_closed} failed=${total_failed} eligible_unmerged=${total_eligible_unmerged}" >>"$_mr_logfile"
	[[ -n "$AIDEVOPS_PULSE_MERGE_OUTCOME_DIR" ]] && rm -rf -- "$AIDEVOPS_PULSE_MERGE_OUTCOME_DIR"
	return 0
}
