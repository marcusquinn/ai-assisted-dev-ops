#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Helper — Enrich Command
# =============================================================================
# Enrichment of existing GitHub issues from TODO.md metadata: label sync,
# title/body updates, rate-limit probes, batch prefetch, and the cmd_enrich
# entry point.
#
# Note: _enrich_process_task is kept in the orchestrator (issue-sync-helper.sh)
# to preserve its (file, fname) identity key for the function-complexity gate.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-helper-enrich.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, print_success,
#     gh_issue_edit_safe)
#   - issue-sync-lib.sh (strip_code_fences, parse_task_line, map_tags_to_labels,
#     compose_issue_body, _extract_tier_from_brief, _validate_tier_checklist,
#     sync_relationships_for_task)
#   - issue-sync-helper-labels.sh (ensure_labels_exist, gh_find_issue_by_title,
#     _apply_tier_label_replace, _reconcile_labels)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_HELPER_ENRICH_LOADED:-}" ]] && return 0
_ISSUE_SYNC_HELPER_ENRICH_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Enrich Helpers
# =============================================================================

_enrich_print_gh_error() {
	local context="$1" err_file="$2" status="${3:-}"
	local detail=""
	if [[ -n "$err_file" && -f "$err_file" ]]; then
		detail=$(tr '\n' ' ' <"$err_file" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-500)
	fi
	if [[ -n "$detail" ]]; then
		print_error "${context} failed (rc=${status:-unknown}): ${detail}"
	else
		print_error "${context} failed (rc=${status:-unknown}); gh produced no stderr"
	fi
	return 0
}

_enrich_run_issue_edit_safe() {
	local err_file="$1"
	shift
	if [[ -n "$err_file" ]]; then
		gh_issue_edit_safe "$@" 2>"$err_file"
		return $?
	fi
	gh_issue_edit_safe "$@" 2>/dev/null
	return $?
}

_enrich_is_nonnegative_int() {
	local value="$1"
	[[ "$value" =~ ^[0-9]+$ ]]
	return $?
}

_enrich_resolve_bounds() {
	local target_task="$1"
	ENRICH_MAX_ISSUES_RESOLVED="${AIDEVOPS_ENRICH_MAX_ISSUES:-${ENRICH_MAX_ISSUES:-0}}"
	ENRICH_MAX_SECONDS_RESOLVED="${AIDEVOPS_ENRICH_MAX_SECONDS:-${ENRICH_MAX_SECONDS:-0}}"
	if ! _enrich_is_nonnegative_int "$ENRICH_MAX_ISSUES_RESOLVED"; then
		print_warning "Ignoring invalid enrich issue bound: $ENRICH_MAX_ISSUES_RESOLVED"
		ENRICH_MAX_ISSUES_RESOLVED="0"
	fi
	if ! _enrich_is_nonnegative_int "$ENRICH_MAX_SECONDS_RESOLVED"; then
		print_warning "Ignoring invalid enrich seconds bound: $ENRICH_MAX_SECONDS_RESOLVED"
		ENRICH_MAX_SECONDS_RESOLVED="0"
	fi
	if [[ -n "$target_task" ]]; then
		ENRICH_MAX_ISSUES_RESOLVED="0"
		ENRICH_MAX_SECONDS_RESOLVED="0"
	fi
	export ENRICH_MAX_ISSUES_RESOLVED ENRICH_MAX_SECONDS_RESOLVED
	return 0
}

_enrich_log_bounds_if_active() {
	local max_issues="${1:-0}" max_seconds="${2:-0}"
	if [[ "$max_issues" -gt 0 || "$max_seconds" -gt 0 ]]; then
		print_info "Bounded enrich active: max_issues=${max_issues}, max_seconds=${max_seconds}"
	fi
	return 0
}

_enrich_should_stop_for_bounds() {
	local max_issues="${1:-0}" max_seconds="${2:-0}" processed="${3:-0}" total="${4:-0}" started_at="${5:-0}"
	if [[ "$max_issues" -gt 0 && "$processed" -ge "$max_issues" ]]; then
		print_warning "Stopping bounded enrich after ${processed} issue(s); ${total} were eligible"
		return 0
	fi
	if [[ "$max_seconds" -gt 0 ]]; then
		local now elapsed
		now=$(date +%s || echo "0")
		elapsed=$((${now:-0} - ${started_at:-0}))
		if [[ "$elapsed" -ge "$max_seconds" ]]; then
			print_warning "Stopping bounded enrich after ${elapsed}s and ${processed} issue(s); ${total} were eligible"
			return 0
		fi
	fi
	return 1
}

# _enrich_build_task_list: collect task IDs to enrich — single target or all
# TODO tasks that already have a ref:GH# number. Outputs one task ID per line.
_enrich_build_task_list() {
	local target_task="$1" todo_file="$2"
	if [[ -n "$target_task" ]]; then
		echo "$target_task"
		return 0
	fi
	while IFS= read -r line; do
		local tid
		tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -n "$tid" ]] && echo "$tid"
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[ \] t[0-9]+.*ref:GH#[0-9]+' || true)
	return 0
}

# _enrich_apply_labels: add labels, reconcile stale ones, then apply tier label
# via replace-not-append (t2012). Skips add when labels is empty.
# add_ok gates reconciliation to avoid destructive removal after transient API
# failures (GH#17402 CR fix).
_enrich_apply_labels() {
	local repo="$1" num="$2" labels="$3" tier_label="$4" current_labels_csv="${5:-}"
	local add_ok=true
	if [[ -n "$labels" ]]; then
		ensure_labels_exist "$labels" "$repo"
		# t2165: skip the add API call when every desired label is already
		# present in the issue's current labels. gh issue edit --add-label
		# is idempotent but still round-trips ~1.5s per task; at ~145 open
		# tasks this is the bulk of the 10-minute enrich budget.
		local all_present=false
		if [[ -n "$current_labels_csv" ]]; then
			all_present=true
			local _saved_ifs_chk="$IFS"
			IFS=','
			local _lbl_chk _found_chk
			for _lbl_chk in $labels; do
				[[ -z "$_lbl_chk" ]] && continue
				_found_chk=false
				local _saved_ifs_in="$IFS"
				IFS=','
				local _existing
				for _existing in $current_labels_csv; do
					if [[ "$_existing" == "$_lbl_chk" ]]; then
						_found_chk=true
						break
					fi
				done
				IFS="$_saved_ifs_in"
				if [[ "$_found_chk" != "true" ]]; then
					all_present=false
					break
				fi
			done
			IFS="$_saved_ifs_chk"
		fi
		if [[ "$all_present" != "true" ]]; then
			# Build add args and check exit status — _gh_edit_labels masks failures
			# via || true, so we call gh issue edit directly here.
			local -a add_args=()
			local _saved_ifs_add="$IFS"
			IFS=','
			for _lbl in $labels; do [[ -n "$_lbl" ]] && add_args+=("--add-label" "$_lbl"); done
			IFS="$_saved_ifs_add"
			if [[ ${#add_args[@]} -gt 0 ]]; then
				local _labels_err _labels_rc=0
				_labels_err=$(mktemp /tmp/enrich-labels-XXXXXX 2>/dev/null || echo "")
				if [[ -n "$_labels_err" ]]; then
					gh issue edit "$num" --repo "$repo" "${add_args[@]}" 2>"$_labels_err" || _labels_rc=$?
					if [[ $_labels_rc -ne 0 ]]; then
						add_ok=false
						_enrich_print_gh_error "Failed to add labels on #$num" "$_labels_err" "$_labels_rc"
					fi
					rm -f "$_labels_err" 2>/dev/null || true
				else
					gh issue edit "$num" --repo "$repo" "${add_args[@]}" 2>/dev/null || add_ok=false
				fi
			fi
		fi
	fi
	# Reconcile: remove tag-derived labels no longer in desired set (GH#17402).
	# t2165: forward the pre-fetched labels so _reconcile_labels skips its
	# own gh issue view call when we already have the state.
	[[ "$add_ok" == "true" ]] && _reconcile_labels "$repo" "$num" "$labels" "$current_labels_csv"
	# Apply tier label via replace-not-append — protected-prefix rule prevents
	# _reconcile_labels from cleaning up stale tier:* labels on its own.
	if [[ -n "$tier_label" ]]; then
		_apply_tier_label_replace "$repo" "$num" "$tier_label" "$current_labels_csv"
	fi
	return 0
}

# _enrich_update_issue: brief-first authoritative body policy (t2063).
#
# Body update decision tree (in priority order):
#   1. FORCE_ENRICH=true          -> always update body
#   2. Brief file exists on disk  -> brief is authoritative, update body unless
#                                    current == composed (no-op skip)
#   3. No brief + has sentinel    -> previously framework-synced, update on diff
#                                    (existing GH#18411 behaviour)
#   4. No brief + no sentinel     -> genuine external content, preserve body
#                                    (existing GH#18411 behaviour)
#
# Returns 0 on successful edit, 1 on failure.
_enrich_update_issue() {
	local repo="$1" num="$2" task_id="$3" title="$4" body="$5"
	# t2165: accept pre-fetched current_title/current_body as optional 6th/7th
	# args. When present, skip the per-helper gh issue view call. Fall back to
	# fetching when empty — preserves isolated-test behaviour.
	local current_title="${6:-}" current_body="${7:-}"
	local do_body_update=true

	# Layer 2 (t2377): never-delete invariant. Regardless of FORCE_ENRICH or any
	# other env override, refuse to write an empty title or empty body. These
	# are never a legitimate target state — `gh issue edit --title "" --body ""`
	# is pure data loss (observed on #19778/#19779/#19780). This guard runs
	# BEFORE any FORCE_ENRICH bypass and cannot be disabled.
	if [[ -z "$title" ]]; then
		print_error "_enrich_update_issue refused empty title for #$num ($task_id) — data loss guard (t2377)"
		return 1
	fi
	if [[ -z "$body" ]]; then
		print_error "_enrich_update_issue refused empty body for #$num ($task_id) — data loss guard (t2377)"
		return 1
	fi
	# Layer 2 (t2377): stub title ("tNNN: " or "tNNN:  " with trailing whitespace)
	# is the symptom seen on #19778/#19779/#19780. Refuse even when non-empty.
	if [[ "$title" =~ ^t[0-9]+:[[:space:]]*$ ]]; then
		print_error "_enrich_update_issue refused stub title '$title' for #$num ($task_id) — data loss guard (t2377)"
		return 1
	fi

	if [[ "$FORCE_ENRICH" == "true" ]]; then
		print_info "FORCE_ENRICH active — skipping content-preservation gate for #$num ($task_id) (GH#20146 audit)"
	fi
	if [[ "$FORCE_ENRICH" != "true" ]]; then
		if [[ -z "$current_body" ]]; then
			current_body=$(gh issue view "$num" --repo "$repo" --json body -q '.body // ""' 2>/dev/null || echo "")
		fi

		# t2063: brief-file presence is the authoritative signal.
		# Resolve project root from the shared PROJECT_ROOT variable if set
		# (normal sync path) or from git rev-parse as a fallback.
		local _project_root="${PROJECT_ROOT:-}"
		[[ -z "$_project_root" ]] && _project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
		local _brief_file=""
		[[ -n "$_project_root" ]] && _brief_file="${_project_root}/todo/tasks/${task_id}-brief.md"

		if [[ -n "$_brief_file" && -f "$_brief_file" ]]; then
			# Case 2: brief exists -> authoritative. Refresh unless no-op.
			if [[ "$current_body" == "$body" ]]; then
				print_info "Body unchanged on #$num ($task_id), skipping API call"
				do_body_update=false
			else
				print_info "Refreshing body on #$num ($task_id) — brief file is authoritative (t2063)"
			fi
		elif [[ "$current_body" == *"Synced from TODO.md by issue-sync-helper.sh"* ]]; then
			# Case 3: no brief, has sentinel -> framework-synced, refresh on diff
			if [[ "$current_body" == "$body" ]]; then
				print_info "Body unchanged on #$num ($task_id), skipping API call"
				do_body_update=false
			fi
		else
			# Case 4: no brief, no sentinel -> genuine external content, preserve
			print_info "Preserving external body on #$num ($task_id) — no brief file, no sentinel (use --force to override)"
			do_body_update=false
		fi
	fi

	if [[ "$do_body_update" == "true" ]]; then
		local _body_err _body_rc=0
		_body_err=$(mktemp /tmp/enrich-body-XXXXXX 2>/dev/null || echo "")
		_enrich_run_issue_edit_safe "$_body_err" "$num" --repo "$repo" --title "$title" --body "$body" || _body_rc=$?
		if [[ $_body_rc -eq 0 ]]; then
			[[ -n "$_body_err" ]] && rm -f "$_body_err" 2>/dev/null || true
			return 0
		fi
		_enrich_print_gh_error "Failed to enrich body on #$num ($task_id)" "$_body_err" "$_body_rc"
		[[ -n "$_body_err" ]] && rm -f "$_body_err" 2>/dev/null || true
		return 1
	fi
	# t2165: when the title also already matches, skip the title-only API
	# call entirely. The previous implementation always issued at least one
	# gh issue edit per task even when nothing had changed — on a
	# steady-state TODO.md this was the dominant per-task cost.
	if [[ -n "$current_title" && "$current_title" == "$title" ]]; then
		print_info "Title unchanged on #$num ($task_id), skipping API call"
		return 0
	fi
	# Still update title even when body is preserved/skipped (GH#18411).
	local _title_err _title_rc=0
	_title_err=$(mktemp /tmp/enrich-title-XXXXXX 2>/dev/null || echo "")
	_enrich_run_issue_edit_safe "$_title_err" "$num" --repo "$repo" --title "$title" || _title_rc=$?
	if [[ $_title_rc -eq 0 ]]; then
		[[ -n "$_title_err" ]] && rm -f "$_title_err" 2>/dev/null || true
		return 0
	fi
	_enrich_print_gh_error "Failed to enrich title on #$num ($task_id)" "$_title_err" "$_title_rc"
	[[ -n "$_title_err" ]] && rm -f "$_title_err" 2>/dev/null || true
	return 1
}

# _enrich_check_rate_limit: probe GitHub GraphQL rate limit before the enrich
# loop. If remaining points are below ENRICH_RATE_LIMIT_THRESHOLD (default 250),
# emit a ::warning:: with the reset time and return 0 (caller should skip the
# enrich step entirely). Returns 1 if rate limit is healthy (proceed).
#
# Approach B from GH#20129. At 0 remaining, calling gh issue view 192 times
# produces 162 GUARD_UNCERTAIN warnings with zero value — this probe detects
# the exhausted state before the loop and avoids the wasted calls.
_enrich_check_rate_limit() {
	local threshold="${ENRICH_RATE_LIMIT_THRESHOLD:-250}"
	local _rl_json _rl_remaining _rl_reset _rc=0
	_rl_json=$(gh api rate_limit 2>/dev/null) || _rc=$?
	# Fail-open: if rate_limit probe itself fails, proceed with the enrich.
	[[ $_rc -ne 0 || -z "$_rl_json" ]] && return 1
	_rl_remaining=$(printf '%s' "$_rl_json" | jq -r '.resources.graphql.remaining // 9999' 2>/dev/null || echo "9999")
	if [[ "$_rl_remaining" -ge "$threshold" ]]; then
		return 1  # healthy — proceed
	fi
	_rl_reset=$(printf '%s' "$_rl_json" | jq -r '.resources.graphql.reset // 0' 2>/dev/null || echo "0")
	local _reset_time
	_reset_time=$(date -d "@${_rl_reset}" '+%H:%M:%SZ' 2>/dev/null \
		|| TZ=UTC date -r "$_rl_reset" '+%H:%M:%SZ' 2>/dev/null \
		|| echo "unknown")
	echo "::warning::GraphQL rate-limit too low for enrich, skipping this cycle (remaining=${_rl_remaining}, reset=${_reset_time}, threshold=${threshold}) — GH#20129"
	return 0  # tell caller to skip
}

# _enrich_prefetch_issues_map: fetch all open issues in one batch call and
# write the JSON array to a temp file. Sets ENRICH_PREFETCH_FILE to the path.
# Returns 0 on success, 1 on failure (caller should fall back to per-task calls).
#
# Approach A from GH#20129. One GraphQL call returning N issues costs far fewer
# rate-limit points than N individual gh issue view calls.
_enrich_prefetch_issues_map() {
	local repo="$1"
	local _limit="${ENRICH_PREFETCH_LIMIT:-500}"
	local _rc=0
	local _result
	_result=$(gh issue list --repo "$repo" --state open \
		--json number,title,body,labels,state,assignees \
		--limit "$_limit" 2>/dev/null) || _rc=$?
	if [[ $_rc -ne 0 || -z "$_result" || "$_result" == "[]" ]]; then
		print_warning "Batch prefetch failed (rc=$_rc), falling back to per-task gh issue view (GH#20129)"
		return 1
	fi
	# Write to temp file so the enrich loop can read it per-task without
	# passing a large string through every subshell invocation.
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	ENRICH_PREFETCH_FILE=$(mktemp /tmp/enrich-prefetch-XXXXXX 2>/dev/null || echo "")
	if [[ -z "$ENRICH_PREFETCH_FILE" ]]; then
		return 1
	fi
	printf '%s' "$_result" >"$ENRICH_PREFETCH_FILE"
	local _count
	_count=$(printf '%s' "$_result" | jq 'length' 2>/dev/null || echo "?")
	print_info "Batch prefetched ${_count} open issues for enrich (GH#20129)"
	export ENRICH_PREFETCH_FILE
	return 0
}

# _enrich_check_active_claim: GH#19856 cross-runner dedup guard for the enrich
# path. Before ANY destructive enrich operation (labels, title, body), check if
# another runner holds an active claim on this issue. Returns 0 if an active
# claim is detected (caller should abort enrich), 1 if safe to proceed.
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - task_id (for logging)
#   $4 - (optional) pre-fetched issue JSON (forwarded via ISSUE_META_JSON to
#        is_assigned to avoid a redundant gh issue view call; GH#19922)
_enrich_check_active_claim() {
	local num="$1" repo="$2" task_id="$3" pre_fetched_json="${4:-}"
	local _dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	if [[ -x "$_dedup_helper" ]]; then
		# GH#19922: resolve runner login so the assignment guard can apply the self-login
		# exemption — without it the runner blocks its own enrichment when it is
		# also an assignee (e.g. single-user setups).
		local _user="${AIDEVOPS_ENRICH_ACTOR:-${AIDEVOPS_SESSION_USER:-}}"
		local _dedup_result=""
		# GH#19922: pass pre-fetched JSON via ISSUE_META_JSON env var to avoid
		# a redundant metadata read. GH#28498: inspection must never invoke stale
		# recovery, which can mutate a live interactive owner's claim.
		_dedup_result=$(ISSUE_META_JSON="$pre_fetched_json" "$_dedup_helper" is-assigned-read-only "$num" "$repo" "$_user" 2>/dev/null) || true
		if [[ -n "$_dedup_result" ]]; then
			print_warning "Skipping enrich for #$num ($task_id) — active claim detected: $_dedup_result (GH#19856)"
			return 0
		fi
	fi
	return 1
}

_enrich_resolve_actor() {
	[[ "${AIDEVOPS_ENRICH_ACTOR_RESOLVED:-}" == "1" ]] && return 0
	AIDEVOPS_ENRICH_ACTOR="${AIDEVOPS_SESSION_USER:-}"
	if [[ -z "$AIDEVOPS_ENRICH_ACTOR" ]]; then
		AIDEVOPS_ENRICH_ACTOR=$(gh api user --jq '.login // ""' 2>/dev/null || echo "")
	fi
	AIDEVOPS_ENRICH_ACTOR_RESOLVED=1
	export AIDEVOPS_ENRICH_ACTOR AIDEVOPS_ENRICH_ACTOR_RESOLVED
	return 0
}

# =============================================================================
# cmd_enrich
# =============================================================================

cmd_enrich() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO" project_root="$_CMD_ROOT"
	# Keep the actor cache scoped to this command invocation, even when callers
	# source the helper and invoke cmd_enrich more than once in the same shell.
	unset AIDEVOPS_ENRICH_ACTOR AIDEVOPS_ENRICH_ACTOR_RESOLVED

	local tasks=()
	while IFS= read -r tid; do
		[[ -n "$tid" ]] && tasks+=("$tid")
	done < <(_enrich_build_task_list "$target_task" "$todo_file")
	[[ ${#tasks[@]} -eq 0 ]] && {
		print_info "No tasks to enrich"
		return 0
	}
	print_info "Enriching ${#tasks[@]} issue(s) in $repo"

	_enrich_resolve_bounds "$target_task"
	local max_issues="$ENRICH_MAX_ISSUES_RESOLVED" max_seconds="$ENRICH_MAX_SECONDS_RESOLVED"
	_enrich_log_bounds_if_active "$max_issues" "$max_seconds"

	# GH#20129 Approach B: rate-limit probe — skip the entire enrich step if the
	# GraphQL bucket is below threshold (default 250). Avoids 162 GUARD_UNCERTAIN
	# warnings when the rate limit was exhausted before the loop started.
	# Skipped for single-task enrichment (target_task set) — the per-task call
	# is the cheapest path when enriching only one issue.
	if [[ -z "$target_task" ]] && _enrich_check_rate_limit; then
		return 0
	fi

	# Resolve identity once for the invocation. Per-task processing occurs in
	# command substitutions, so export the bounded result for every child.
	_enrich_resolve_actor

	# GH#20129 Approach A: batch prefetch — issue ONE gh issue list call for all
	# open issues instead of per-task gh issue view calls. The prefetch JSON is
	# written to a temp file and referenced via ENRICH_PREFETCH_FILE. Each call
	# to _enrich_process_task reads from the file, falling back to per-task view
	# only on cache miss (e.g. issues not in the open list).
	local _prefetch_ok=false
	ENRICH_PREFETCH_FILE=""
	if [[ -z "$target_task" ]]; then
		if _enrich_prefetch_issues_map "$repo"; then
			_prefetch_ok=true
		fi
	fi

	local enriched=0
	local processed=0
	local started_at
	started_at=$(date +%s || echo "0")
	for task_id in "${tasks[@]}"; do
		if _enrich_should_stop_for_bounds "$max_issues" "$max_seconds" "$processed" "${#tasks[@]}" "$started_at"; then
			break
		fi
		local result
		result=$(_enrich_process_task "$task_id" "$repo" "$todo_file" "$project_root")
		processed=$((processed + 1))
		[[ "$result" == *"ENRICHED"* ]] && enriched=$((enriched + 1))
	done
	print_info "Enrich complete: $enriched updated (${processed}/${#tasks[@]} processed)"

	# Clean up prefetch temp file
	if [[ "$_prefetch_ok" == "true" && -n "${ENRICH_PREFETCH_FILE:-}" && -f "$ENRICH_PREFETCH_FILE" ]]; then
		rm -f "$ENRICH_PREFETCH_FILE" 2>/dev/null || true
		ENRICH_PREFETCH_FILE=""
	fi
	return 0
}
