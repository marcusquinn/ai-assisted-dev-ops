#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Intentionally using /bin/bash (not /usr/bin/env bash) for headless compatibility.
# Some MCP/headless runners provide a stripped PATH where env cannot resolve bash.
# Keep this exception aligned with issue #2610 and t135.14 standardization context.
# shellcheck disable=SC2016,SC2155
# =============================================================================
# aidevops Issue Sync — Relationships & Backfill (GH#19502)
# =============================================================================
# Extracted from issue-sync-helper.sh to reduce the main file below the 2000-line
# gate. Contains two cohesive functional areas:
#
#   1. Relationships (t1889) — sync blocked-by/blocks and subtask hierarchy to
#      GitHub's native issue relationships via GraphQL mutations.
#   2. Backfill sub-issues (t2114, GH#19093) — detect and link parent-child
#      issue relationships from GitHub state alone (title + body), without
#      requiring a TODO.md entry or brief file.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-relationships.sh"
#
# Dependencies (all available when sourced from issue-sync-helper.sh):
#   - shared-constants.sh (print_error, print_info)
#   - issue-sync-lib.sh (parse_task_line, resolve_task_gh_number,
#     detect_parent_task_id, resolve_gh_node_id, strip_code_fences, _escape_ere)
#   - issue-sync-helper.sh globals: log_verbose, _init_cmd, DRY_RUN, VERBOSE
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced — would affect caller)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — prevents double-loading when sourced from multiple paths.
[[ -n "${_ISSUE_SYNC_RELATIONSHIPS_LOADED:-}" ]] && return 0
_ISSUE_SYNC_RELATIONSHIPS_LOADED=1

# =============================================================================
# Relationships — GitHub Issue Dependencies & Hierarchy (t1889)
# =============================================================================
# Syncs TODO.md blocked-by:/blocks: and subtask hierarchy to GitHub's native
# issue relationships via GraphQL mutations.

# Node ID cache: avoids repeated API calls for the same issue number.
# Uses a temp file (bash 3.2 compatible — no associative arrays).
# Format: one "number=node_id" per line. Populated by _cached_node_id().
_NODE_ID_CACHE_FILE=""

# Rate-limited flag file: written by _cached_node_id when GraphQL is exhausted
# AND the REST fallback also fails. Uses a file (not a bash variable) so that
# the signal survives bash subshell boundaries — callers invoke _cached_node_id
# via $() which spawns a subshell, so bash variable writes inside would be lost.
# Callers check via _node_id_was_rate_limited. Reset to empty at each call.
_NODE_ID_RATE_LIMITED_FILE=""

# Invocation-scoped native-edge set. A file is required because relationship
# helpers are commonly called through command substitutions; file writes
# survive those subshell boundaries while Bash variables do not.
_RELATIONSHIP_EDGE_SEEN_FILE=""
_RELATIONSHIP_RESULT_FILE=""
_RELATIONSHIP_RETRY_RESULT="RELS:0 RETRYABLE:1"
_RELATIONSHIP_SYNC_SCOPE_ACTIVE=0
_RELATIONSHIP_SYNC_DEADLINE_EPOCH=
_REL_OUTCOME_CREATED="created"
_REL_OUTCOME_ALREADY_PRESENT="already-present"
_REL_OUTCOME_FAILED_RESOLUTION="failed:resolution"
_REL_OUTCOME_FAILED_UNKNOWN="failed:unknown"
_REL_OUTCOME_DEFERRED_DEADLINE="deferred:deadline"

_init_relationship_sync_state() {
	_init_node_id_cache
	if [[ -z "$_RELATIONSHIP_EDGE_SEEN_FILE" ]]; then
		_RELATIONSHIP_EDGE_SEEN_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-relationship-edges.XXXXXX") || return 1
	fi
	if [[ -z "$_RELATIONSHIP_RESULT_FILE" ]]; then
		_RELATIONSHIP_RESULT_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-relationship-results.XXXXXX") || return 1
	fi
	: >"$_RELATIONSHIP_EDGE_SEEN_FILE"
	: >"$_RELATIONSHIP_RESULT_FILE"
	return 0
}

_cleanup_relationship_sync_state() {
	if [[ -n "$_RELATIONSHIP_EDGE_SEEN_FILE" ]]; then
		rm -f "$_RELATIONSHIP_EDGE_SEEN_FILE"
		_RELATIONSHIP_EDGE_SEEN_FILE=""
	fi
	if [[ -n "$_RELATIONSHIP_RESULT_FILE" ]]; then
		rm -f "$_RELATIONSHIP_RESULT_FILE"
		_RELATIONSHIP_RESULT_FILE=""
	fi
	return 0
}

_begin_relationship_sync_scope() {
	[[ "$_RELATIONSHIP_SYNC_SCOPE_ACTIVE" -eq 1 ]] && return 0
	_init_relationship_sync_state || return 1
	_RELATIONSHIP_SYNC_DEADLINE_EPOCH=
	_RELATIONSHIP_SYNC_SCOPE_ACTIVE=1
	return 0
}

_ensure_relationship_sync_deadline() {
	if [[ ! "$_RELATIONSHIP_SYNC_DEADLINE_EPOCH" =~ ^[1-9][0-9]*$ ]]; then
		_RELATIONSHIP_SYNC_DEADLINE_EPOCH=$(_relationship_sync_deadline_epoch) || return 1
	fi
	return 0
}

_end_relationship_sync_scope() {
	_cleanup_relationship_sync_state
	_RELATIONSHIP_SYNC_SCOPE_ACTIVE=0
	_RELATIONSHIP_SYNC_DEADLINE_EPOCH=
	return 0
}

_register_relationship_sync_cleanup() {
	push_cleanup "rm -f '${_RELATIONSHIP_EDGE_SEEN_FILE}'"
	push_cleanup "rm -f '${_RELATIONSHIP_RESULT_FILE}'"
	return 0
}

_relationship_record_outcome() {
	local outcome="$1"
	case "$outcome" in
	"$_REL_OUTCOME_CREATED" | "$_REL_OUTCOME_ALREADY_PRESENT" | failed:auth | failed:graphql | "$_REL_OUTCOME_FAILED_RESOLUTION" | failed:timeout-uncertain | failed:transport | "$_REL_OUTCOME_FAILED_UNKNOWN" | deferred:cooldown | "$_REL_OUTCOME_DEFERRED_DEADLINE") ;;
	*) return 1 ;;
	esac
	[[ -f "${_RELATIONSHIP_RESULT_FILE:-}" ]] || return 0
	printf '%s\n' "$outcome" >>"$_RELATIONSHIP_RESULT_FILE"
	return 0
}

_relationship_record_mutation_failure() {
	local mutation_rc="$1"
	local result="$2"
	if [[ "$mutation_rc" -eq 75 ]] || printf '%s' "$result" | grep -qiE 'secondary rate limit|abuse detection|retry-after|cooldown'; then
		_relationship_record_outcome "deferred:cooldown"
	elif [[ "$mutation_rc" -eq 124 ]] || printf '%s' "$result" | grep -qiE 'timed out|timeout'; then
		_relationship_record_outcome "failed:timeout-uncertain"
	elif printf '%s' "$result" | grep -qiE 'HTTP (401|403)|authentication|bad credentials'; then
		_relationship_record_outcome "failed:auth"
	elif printf '%s' "$result" | grep -qiE 'connection|network|TLS|unexpected EOF'; then
		_relationship_record_outcome "failed:transport"
	elif printf '%s' "$result" | grep -qiE 'graphql|"errors"|could not resolve'; then
		_relationship_record_outcome "failed:graphql"
	else
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_UNKNOWN"
	fi
	return 0
}

_relationship_outcome_count() {
	local outcome_prefix="$1"
	local count="0"
	[[ -f "${_RELATIONSHIP_RESULT_FILE:-}" ]] || { printf '0\n'; return 0; }
	count=$(grep -cE "^${outcome_prefix}(:|$)" "$_RELATIONSHIP_RESULT_FILE" 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s\n' "$count"
	return 0
}

_relationship_first_incomplete_outcome() {
	local outcome=""
	[[ -f "${_RELATIONSHIP_RESULT_FILE:-}" ]] || { printf 'none\n'; return 0; }
	outcome=$(grep -E '^(failed|deferred):' "$_RELATIONSHIP_RESULT_FILE" 2>/dev/null | head -1 || true)
	printf '%s\n' "${outcome:-none}"
	return 0
}

_relationship_print_summary() {
	local attempted="$1" complete="$2" total="$3" retryable_total="$4" deadline_exhausted="$5"
	local created already_present failed deferred first_incomplete
	created=$(_relationship_outcome_count "$_REL_OUTCOME_CREATED")
	already_present=$(_relationship_outcome_count "$_REL_OUTCOME_ALREADY_PRESENT")
	failed=$(_relationship_outcome_count "failed")
	deferred=$(_relationship_outcome_count "deferred")
	first_incomplete=$(_relationship_first_incomplete_outcome)
	printf '\n=== Relationships Sync ===\nEdges: created=%d already-present=%d failed=%d deferred=%d\n' \
		"$created" "$already_present" "$failed" "$deferred"
	printf 'Tasks: attempted=%d complete=%d/%d | Retryable: %d | Deadline exhausted: %s\n' \
		"$attempted" "$complete" "$total" "$retryable_total" "$deadline_exhausted"
	printf 'Failure: %s\n' "$first_incomplete"
	[[ "$retryable_total" -eq 0 ]] || printf 'Recovery: rerun .agents/scripts/issue-sync-helper.sh relationships\n'
	return 0
}

_relationship_print_progress() {
	local attempted="$1"
	local total="$2"
	if [[ $((attempted % 25)) -eq 0 || "$attempted" -eq "$total" ]]; then
		printf "\r  Progress: %d/%d tasks..." "$attempted" "$total" >&2
	fi
	return 0
}

run_relationship_scoped_command() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	_begin_relationship_sync_scope || return 1
	_register_relationship_sync_cleanup
	local rc=0
	"$@" || rc=$?
	_end_relationship_sync_scope
	return "$rc"
}

_relationship_sync_deadline_epoch() {
	# Keep automatic post-create work below common 120-second outer worker
	# ceilings. Callers may override this documented aggregate budget.
	local budget="${AIDEVOPS_RELATIONSHIP_SYNC_TIMEOUT:-90}"
	local now_epoch=""
	[[ "$budget" =~ ^[1-9][0-9]*$ ]] || budget=90
	now_epoch=$(date +%s 2>/dev/null) || return 1
	printf '%s\n' "$((now_epoch + budget))"
	return 0
}

_relationship_deadline_expired() {
	local deadline_epoch="${AIDEVOPS_GH_DEADLINE_EPOCH:-0}"
	local now_epoch=""
	[[ "$deadline_epoch" =~ ^[1-9][0-9]*$ ]] || return 1
	now_epoch=$(date +%s 2>/dev/null) || return 0
	[[ "$now_epoch" -ge "$deadline_epoch" ]]
	return $?
}

_relationship_edge_should_attempt() {
	local blocked_num="$1"
	local blocker_num="$2"
	local edge_key="${blocked_num}|${blocker_num}"
	[[ -f "${_RELATIONSHIP_EDGE_SEEN_FILE:-}" ]] || return 1
	if grep -Fxq -- "$edge_key" "$_RELATIONSHIP_EDGE_SEEN_FILE"; then
		return 1
	fi
	printf '%s\n' "$edge_key" >>"$_RELATIONSHIP_EDGE_SEEN_FILE"
	return 0
}

_init_node_id_cache() {
	if [[ -z "$_NODE_ID_CACHE_FILE" ]]; then
		_NODE_ID_CACHE_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-node-cache.XXXXXX")
		_NODE_ID_RATE_LIMITED_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-ratelimited.XXXXXX")
		# Chain onto any existing EXIT trap rather than replacing it.
		local _prev_trap
		_prev_trap=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")
		# shellcheck disable=SC2064
		trap "rm -f '$_NODE_ID_CACHE_FILE' '$_NODE_ID_RATE_LIMITED_FILE'${_prev_trap:+; $_prev_trap}" EXIT
	fi
	return 0
}

# Return 0 (true) if the most recent _cached_node_id call was rate-limited.
# Reads the flag file written by the subshell — bash variables set inside $()
# are discarded when the subshell exits, but file writes persist.
_node_id_was_rate_limited() {
	[[ -n "${_NODE_ID_RATE_LIMITED_FILE:-}" ]] && \
		[[ "$(cat "$_NODE_ID_RATE_LIMITED_FILE" 2>/dev/null)" == "1" ]]
	return $?
}

_cached_node_id() {
	local num="$1" repo="$2"
	[[ -z "$num" ]] && return 0
	_init_node_id_cache
	# Reset the rate-limited flag for this resolution. Runs inside the subshell
	# spawned by callers' $() — the file truncation IS visible to the parent.
	[[ -n "$_NODE_ID_RATE_LIMITED_FILE" ]] && : >"$_NODE_ID_RATE_LIMITED_FILE"

	# Check cache file
	local cached
	cached=$(grep -m1 "^${num}=" "$_NODE_ID_CACHE_FILE" 2>/dev/null | cut -d= -f2- || echo "")
	if [[ -n "$cached" ]]; then
		echo "$cached"
		return 0
	fi

	local nid
	nid=$(resolve_gh_node_id "$num" "$repo")
	if [[ -n "$nid" ]]; then
		echo "${num}=${nid}" >>"$_NODE_ID_CACHE_FILE"
		echo "$nid"
		return 0
	fi

	# GraphQL returned empty. If rate-limited, try REST path (t2739).
	# REST: GET /repos/{owner}/{repo}/issues/{number} → .node_id
	# Uses the same core-pool 5000/hr budget that the t2574 write-path fallbacks use.
	if _rest_should_fallback; then
		local rest_nid
		rest_nid=$(_gh_with_timeout read gh api "/repos/${repo}/issues/${num}" --jq '.node_id // ""' 2>/dev/null || echo "")
		if [[ -n "$rest_nid" ]]; then
			echo "${num}=${rest_nid}" >>"$_NODE_ID_CACHE_FILE"
			echo "$rest_nid"
			return 0
		fi
		# Both GraphQL and REST failed — write flag so callers can emit RATE_LIMITED.
		[[ -n "$_NODE_ID_RATE_LIMITED_FILE" ]] && echo "1" >"$_NODE_ID_RATE_LIMITED_FILE"
	fi
	return 0
}

# Add a blocked-by relationship between two issues.
# issueId = the blocked issue, blockingIssueId = the blocker.
# Suppresses "already taken" errors (idempotent semantics).
# Arguments:
#   $1 - blocked_node_id (the issue that IS blocked)
#   $2 - blocking_node_id (the issue that BLOCKS)
# Returns: 0=success/already-exists, 1=error. The invocation ledger retains
# whether this call created, observed, failed, or deferred the edge.
_gh_add_blocked_by() {
	local blocked_id="$1" blocking_id="$2"
	local result="" contains_rc=0 mutation_rc=0
	_gh_native_blocked_by_contains "$blocked_id" "$blocking_id" || contains_rc=$?
	case "$contains_rc" in
		0)
			log_verbose "  blocked-by relationship already exists"
			_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
			return 0
			;;
		1) ;;
		*)
			_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
			return 1
			;;
	esac
	# GitHub exposes rateLimit on Query, not Mutation. This fixed mutation has
	# no connections and consumes one GraphQL point, accounted at transport.
	result=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-add-blocked-by-exact-cost" \
		_gh_with_timeout write gh api graphql -f query='
mutation($blocked:ID!,$blocking:ID!) {
  addBlockedBy(input: {issueId:$blocked, blockingIssueId:$blocking}) {
    issue { number }
  }
}' -f blocked="$blocked_id" -f blocking="$blocking_id" 2>&1) || mutation_rc=$?
	if [[ "$mutation_rc" -eq 0 ]] && \
		printf '%s' "$result" | jq -e \
		'((.errors // []) | length) == 0 and (.data.addBlockedBy.issue.number | type == "number")' \
		>/dev/null 2>&1; then
		_relationship_record_outcome "$_REL_OUTCOME_CREATED"
		return 0
	fi
	if echo "$result" | grep -qi 'already been taken'; then
		log_verbose "  blocked-by relationship already exists"
		_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
		return 0
	fi
	_relationship_record_mutation_failure "$mutation_rc" "$result"
	log_verbose "  addBlockedBy error: ${result:0:200}"
	return 1
}

# Remove a deterministic break edge from an already-materialized native cycle.
# Absence is idempotent success; lookup or mutation uncertainty remains retryable.
_gh_remove_blocked_by() {
	local blocked_id="$1"
	local blocking_id="$2"
	local contains_rc=0 mutation_rc=0 result=""
	_gh_native_blocked_by_contains "$blocked_id" "$blocking_id" || contains_rc=$?
	case "$contains_rc" in
		1) return 0 ;;
		2) return 1 ;;
	esac
	result=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-remove-blocked-by-exact-cost" \
		_gh_with_timeout write gh api graphql -f query='
mutation($blocked:ID!,$blocking:ID!) {
  removeBlockedBy(input: {issueId:$blocked, blockingIssueId:$blocking}) {
    issue { number }
  }
}' -f blocked="$blocked_id" -f blocking="$blocking_id" 2>&1) || mutation_rc=$?
	if [[ "$mutation_rc" -eq 0 ]] && \
		printf '%s' "$result" | jq -e \
		'((.errors // []) | length) == 0 and (.data.removeBlockedBy.issue.number | type == "number")' \
		>/dev/null 2>&1; then
		return 0
	fi
	log_verbose "  removeBlockedBy error: ${result:0:200}"
	return 1
}

# Keep dependency status normalization from overwriting active lifecycle state.
_dependency_sync_has_active_status() {
	local labels_csv="$1"
	local padded_labels=",${labels_csv},"
	[[ "$padded_labels" == *",status:queued,"* ||
		"$padded_labels" == *",status:claimed,"* ||
		"$padded_labels" == *",status:in-progress,"* ||
		"$padded_labels" == *",status:in-review,"* ||
		"$padded_labels" == *",status:done,"* ]]
	return $?
}

_relationship_task_line() {
	local task_id="$1" todo_file="$2" task_id_ere=""
	task_id_ere=$(_escape_ere "$task_id")
	strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || true
	return 0
}

# Move an inactive dependency-bearing issue out of the available queue. This is
# intentionally label-only: auto-dispatch remains attached so Pulse can promote
# the issue after every native blocker closes.
_ensure_dependency_status_blocked() {
	local issue_num="$1"
	local repo="$2"
	local reason="$3"
	local current_labels=""

	[[ "$issue_num" =~ ^[0-9]+$ && "$repo" == */* ]] || return 1
	current_labels=$(_gh_with_timeout read gh issue view "$issue_num" --repo "$repo" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || {
		log_verbose "$issue_num: dependency_status_sync_failed reason=${reason}_status_read_failed"
		return 1
	}
	[[ ",${current_labels}," == *",status:available,"* ]] || return 0
	_dependency_sync_has_active_status "$current_labels" && return 0
	if ! _gh_with_timeout write gh issue edit "$issue_num" --repo "$repo" \
		--remove-label "status:available" --add-label "status:blocked" >/dev/null 2>&1; then
		log_verbose "$issue_num: dependency_status_sync_failed reason=${reason}_status_write_failed"
		return 1
	fi
	# A dispatcher may have advanced state between the read and edit. Repair any
	# resulting sibling conflict immediately; active lifecycle state wins.
	current_labels=$(_gh_with_timeout read gh issue view "$issue_num" --repo "$repo" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""
	if _dependency_sync_has_active_status "$current_labels" && \
		[[ ",${current_labels}," == *",status:blocked,"* ]]; then
		_gh_with_timeout write gh issue edit "$issue_num" --repo "$repo" --remove-label "status:blocked" >/dev/null 2>&1 || true
	fi
	log_verbose "$issue_num: dependency_status_blocked reason=${reason}"
	return 0
}

# Keep a dependency-bearing issue out of the available queue when native
# relationship repair cannot complete. The next relationship pass can repair
# the edge, while Pulse supplies the positive proof required to unblock it.
_hold_dependency_sync_retry() {
	local issue_num="$1"
	local repo="$2"
	local reason="$3"
	if ! _ensure_dependency_status_blocked "$issue_num" "$repo" "$reason"; then
		log_verbose "$issue_num: dependency_relationship_sync_retryable reason=${reason}_status_sync_failed"
		return 1
	fi
	log_verbose "$issue_num: dependency_relationship_sync_retryable reason=${reason}"
	return 0
}

# Add a sub-issue (parent-child) relationship.
# Suppresses "duplicate sub-issues" and "only have one parent" errors.
# Emit the Cartesian product of blocked and blocker issue-number lists while
# rejecting self edges. Kept separate so the prose parser stays below the
# repository nesting-depth gate.
_emit_phase_dependency_pairs() {
	local blocked_nums="$1"
	local blocker_nums="$2"
	local blocked_num="" blocker_num=""
	while IFS= read -r blocked_num; do
		[[ -n "$blocked_num" ]] || continue
		while IFS= read -r blocker_num; do
			[[ -n "$blocker_num" && "$blocked_num" != "$blocker_num" ]] || continue
			printf 'PAIR:%s:%s\n' "$blocked_num" "$blocker_num"
		done <<<"$blocker_nums"
	done <<<"$blocked_nums"
	return 0
}

_RELATIONSHIP_EDGE_CACHE_FILE=""
_RELATIONSHIP_EDGE_CACHE=""

# Emit declared task dependency edges as blocked-task|blocking-task pairs.
_relationship_declared_edges() {
	local todo_file="$1"
	local task_line="" task_id="" parsed="" key="" value=""
	local blocked_by="" blocks="" dep_task_id="" saved_ifs=""
	while IFS= read -r task_line; do
		task_id=$(printf '%s\n' "$task_line" | grep -oE 't[0-9]+(\.[0-9a-z]+)*' | head -1 || true)
		[[ -n "$task_id" ]] || continue
		parsed=$(parse_task_line "$task_line")
		blocked_by=""
		blocks=""
		while IFS='=' read -r key value; do
			case "$key" in
			blocked_by) blocked_by="$value" ;;
			blocks) blocks="$value" ;;
			esac
		done <<<"$parsed"
		saved_ifs="$IFS"
		IFS=','
		for dep_task_id in $blocked_by; do
			dep_task_id="${dep_task_id// /}"
			[[ -n "$dep_task_id" && "$dep_task_id" != "$task_id" ]] || continue
			printf '%s|%s\n' "$task_id" "$dep_task_id"
		done
		for dep_task_id in $blocks; do
			dep_task_id="${dep_task_id// /}"
			[[ -n "$dep_task_id" && "$dep_task_id" != "$task_id" ]] || continue
			printf '%s|%s\n' "$dep_task_id" "$task_id"
		done
		IFS="$saved_ifs"
	done < <(strip_code_fences <"$todo_file" | grep -E '^[[:space:]]*- \[.\] t[0-9]+(\.[0-9a-z]+)* ' || true)
	return 0
}

_relationship_edges_for_file() {
	local todo_file="$1"
	if [[ "$_RELATIONSHIP_EDGE_CACHE_FILE" != "$todo_file" ]]; then
		_RELATIONSHIP_EDGE_CACHE=$(_relationship_declared_edges "$todo_file")
		_RELATIONSHIP_EDGE_CACHE_FILE="$todo_file"
	fi
	printf '%s\n' "$_RELATIONSHIP_EDGE_CACHE"
	return 0
}

_declared_dependency_path_exists() {
	local current_task="$1"
	local target_task="$2"
	local edges="$3"
	local seen_tasks="$4"
	local edge_from="" edge_to=""
	[[ "$current_task" == "$target_task" ]] && return 0
	printf '%s\n' "$seen_tasks" | grep -Fxq -- "$current_task" && return 1
	seen_tasks="${seen_tasks}${current_task}"$'\n'
	while IFS='|' read -r edge_from edge_to; do
		[[ "$edge_from" == "$current_task" && -n "$edge_to" ]] || continue
		_declared_dependency_path_exists "$edge_to" "$target_task" "$edges" "$seen_tasks" && return 0
	done <<<"$edges"
	return 1
}

# Break declared cycles deterministically before native mutation. At least one
# edge in every numeric issue cycle ascends, so dropping ascending cycle edges
# preserves useful ordering without leaving the whole component deadlocked.
_dependency_cycle_should_skip_edge() {
	local blocked_task="$1"
	local blocker_task="$2"
	local blocked_num="$3"
	local blocker_num="$4"
	local todo_file="$5"
	local edges=""
	edges=$(_relationship_edges_for_file "$todo_file")
	_declared_dependency_path_exists "$blocker_task" "$blocked_task" "$edges" "" || return 1
	if [[ "$blocked_num" =~ ^[0-9]+$ && "$blocker_num" =~ ^[0-9]+$ ]] &&
		((blocked_num < blocker_num)); then
		log_verbose "$blocked_task (#$blocked_num): ignoring circular blocked-by edge to $blocker_task (#$blocker_num)"
		return 0
	fi
	return 1
}

# Arguments: $1=parent_node_id, $2=child_node_id
# Returns: 0=success/already-exists, 1=error
_gh_add_sub_issue() {
	local parent_id="$1" child_id="$2"
	local result="" contains_rc=0 mutation_rc=0
	_gh_native_sub_issue_contains "$parent_id" "$child_id" || contains_rc=$?
	case "$contains_rc" in
		0)
			log_verbose "  sub-issue relationship already exists"
			_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
			return 0
			;;
		1) ;;
		*)
			_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
			return 1
			;;
	esac
	result=$(AIDEVOPS_GH_QUOTA_COST=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-add-sub-issue-exact-cost" \
		_gh_with_timeout write gh api graphql -f query='
mutation($parent:ID!,$child:ID!) {
  addSubIssue(input: {issueId:$parent, subIssueId:$child}) {
    issue { number }
  }
}' -f parent="$parent_id" -f child="$child_id" 2>&1) || mutation_rc=$?
	if [[ "$mutation_rc" -eq 0 ]] && \
		printf '%s' "$result" | jq -e \
		'((.errors // []) | length) == 0 and (.data.addSubIssue.issue.number | type == "number")' \
		>/dev/null 2>&1; then
		_relationship_record_outcome "$_REL_OUTCOME_CREATED"
		return 0
	fi
	if echo "$result" | grep -qi 'duplicate sub-issues\|only have one parent'; then
		log_verbose "  sub-issue relationship already exists"
		_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
		return 0
	fi
	_relationship_record_mutation_failure "$mutation_rc" "$result"
	log_verbose "  addSubIssue error: ${result:0:200}"
	return 1
}


_sync_declared_blocked_by_edges() {
	local task_id="$1" todo_file="$2" repo="$3" this_gh_num="$4" this_node_id="$5" blocked_by="$6"
	local dep_task_id="" dep_gh_num="" dep_node_id="" rels_set=0 retryable_errors=0
	local saved_ifs="$IFS"
	IFS=','
	for dep_task_id in $blocked_by; do
			if _relationship_deadline_expired; then
				_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
				retryable_errors=$((retryable_errors + 1))
				break
			fi
			dep_task_id="${dep_task_id// /}"
			[[ -z "$dep_task_id" ]] && continue
			if [[ "$dep_task_id" == "$task_id" ]]; then
				log_verbose "$task_id: ignoring self-referential blocked-by edge"
				continue
			fi
			local dep_gh_num
			dep_gh_num=$(resolve_task_gh_number "$dep_task_id" "$todo_file" "$repo" || true)
			[[ -z "$dep_gh_num" ]] && {
				log_verbose "$task_id: blocked-by $dep_task_id has no ref:GH#"
				_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
				retryable_errors=$((retryable_errors + 1))
				continue
			}
			if [[ "$dep_gh_num" == "$this_gh_num" ]]; then
				log_verbose "$task_id: ignoring blocked-by edge that resolves back to #$this_gh_num"
				continue
			fi
			if ! _relationship_edge_should_attempt "$this_gh_num" "$dep_gh_num"; then
				log_verbose "$task_id: skipping duplicate native edge #$this_gh_num blocked-by #$dep_gh_num"
				if [[ "$DRY_RUN" != "true" ]] && ! _ensure_dependency_status_blocked \
					"$this_gh_num" "$repo" "native_relationship_already_attempted"; then
					retryable_errors=$((retryable_errors + 1))
				fi
				continue
			fi
			local dep_node_id
			dep_node_id=$(_cached_node_id "$dep_gh_num" "$repo")
			if [[ -z "$dep_node_id" ]]; then
				_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
				retryable_errors=$((retryable_errors + 1))
				_hold_dependency_sync_retry "$this_gh_num" "$repo" "blocking_node_unresolved"
				continue
			fi

			if _dependency_cycle_should_skip_edge "$task_id" "$dep_task_id" "$this_gh_num" "$dep_gh_num" "$todo_file"; then
				if [[ "$DRY_RUN" == "true" ]]; then
					print_info "[DRY-RUN] Would remove circular #$this_gh_num blocked-by #$dep_gh_num ($task_id <- $dep_task_id)"
				elif ! _gh_remove_blocked_by "$this_node_id" "$dep_node_id"; then
					_relationship_record_outcome "$_REL_OUTCOME_FAILED_UNKNOWN"
					retryable_errors=$((retryable_errors + 1))
				else
					log_verbose "$task_id (#$this_gh_num): normalized circular native edge to $dep_task_id (#$dep_gh_num)"
				fi
				continue
			elif [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would set #$this_gh_num blocked-by #$dep_gh_num ($task_id <- $dep_task_id)"
				rels_set=$((rels_set + 1))
			elif _gh_add_blocked_by "$this_node_id" "$dep_node_id"; then
				log_verbose "$task_id (#$this_gh_num) blocked-by $dep_task_id (#$dep_gh_num) ✓"
				rels_set=$((rels_set + 1))
				if ! _ensure_dependency_status_blocked \
					"$this_gh_num" "$repo" "native_relationship_linked"; then
					retryable_errors=$((retryable_errors + 1))
				fi
			else
				retryable_errors=$((retryable_errors + 1))
				_hold_dependency_sync_retry "$this_gh_num" "$repo" "native_relationship_write_failed"
			fi
	done
	IFS="$saved_ifs"
	printf '%s:%s\n' "$rels_set" "$retryable_errors"
	return 0
}

_sync_declared_blocks_edges() {
	local task_id="$1" todo_file="$2" repo="$3" this_gh_num="$4" this_node_id="$5" blocks="$6"
	local dep_task_id="" dep_gh_num="" dep_node_id="" rels_set=0 retryable_errors=0
	local saved_ifs="$IFS"
	IFS=','
	for dep_task_id in $blocks; do
			if _relationship_deadline_expired; then
				_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
				retryable_errors=$((retryable_errors + 1))
				break
			fi
			dep_task_id="${dep_task_id// /}"
			[[ -z "$dep_task_id" ]] && continue
			if [[ "$dep_task_id" == "$task_id" ]]; then
				log_verbose "$task_id: ignoring self-referential blocks edge"
				continue
			fi
			local dep_gh_num
			dep_gh_num=$(resolve_task_gh_number "$dep_task_id" "$todo_file" "$repo" || true)
			[[ -z "$dep_gh_num" ]] && {
				log_verbose "$task_id: blocks $dep_task_id has no ref:GH#"
				_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
				retryable_errors=$((retryable_errors + 1))
				continue
			}
			[[ "$dep_gh_num" == "$this_gh_num" ]] && continue
			if ! _relationship_edge_should_attempt "$dep_gh_num" "$this_gh_num"; then
				log_verbose "$task_id: skipping duplicate native edge #$dep_gh_num blocked-by #$this_gh_num"
				if [[ "$DRY_RUN" != "true" ]] && ! _ensure_dependency_status_blocked \
					"$dep_gh_num" "$repo" "native_relationship_already_attempted"; then
					retryable_errors=$((retryable_errors + 1))
				fi
				continue
			fi
			local dep_node_id
			dep_node_id=$(_cached_node_id "$dep_gh_num" "$repo")
			if [[ -z "$dep_node_id" ]]; then
				_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
				retryable_errors=$((retryable_errors + 1))
				_hold_dependency_sync_retry "$dep_gh_num" "$repo" "blocking_node_unresolved"
				continue
			fi

			if _dependency_cycle_should_skip_edge "$dep_task_id" "$task_id" "$dep_gh_num" "$this_gh_num" "$todo_file"; then
				if [[ "$DRY_RUN" == "true" ]]; then
					print_info "[DRY-RUN] Would remove circular #$dep_gh_num blocked-by #$this_gh_num ($dep_task_id <- $task_id)"
				elif ! _gh_remove_blocked_by "$dep_node_id" "$this_node_id"; then
					_relationship_record_outcome "$_REL_OUTCOME_FAILED_UNKNOWN"
					retryable_errors=$((retryable_errors + 1))
					_hold_dependency_sync_retry "$dep_gh_num" "$repo" "circular_native_edge_remove_failed"
				else
					log_verbose "$dep_task_id (#$dep_gh_num): normalized circular native edge to $task_id (#$this_gh_num)"
				fi
				continue
			elif [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would set #$dep_gh_num blocked-by #$this_gh_num ($dep_task_id <- $task_id)"
				rels_set=$((rels_set + 1))
			elif _gh_add_blocked_by "$dep_node_id" "$this_node_id"; then
				log_verbose "$dep_task_id (#$dep_gh_num) blocked-by $task_id (#$this_gh_num) ✓"
				rels_set=$((rels_set + 1))
				if ! _ensure_dependency_status_blocked \
					"$dep_gh_num" "$repo" "native_relationship_linked"; then
					retryable_errors=$((retryable_errors + 1))
				fi
			else
				retryable_errors=$((retryable_errors + 1))
				_hold_dependency_sync_retry "$dep_gh_num" "$repo" "native_relationship_write_failed"
			fi
	done
	IFS="$saved_ifs"
	printf '%s:%s\n' "$rels_set" "$retryable_errors"
	return 0
}

# Sync blocked-by and blocks relationships for a single task.
_sync_blocked_by_for_task() {
	local task_id="$1" todo_file="$2" repo="$3"
	local task_line="" parsed="" key="" value="" blocked_by="" blocks=""
	local this_gh_num="" this_node_id="" result="" edge_rels=0 edge_errors=0
	local rels_set=0 retryable_errors=0 current_retry_errors=0
	task_line=$(_relationship_task_line "$task_id" "$todo_file")
	[[ -z "$task_line" ]] && return 0
	parsed=$(parse_task_line "$task_line")
	while IFS='=' read -r key value; do
		case "$key" in
		blocked_by) blocked_by="$value" ;;
		blocks) blocks="$value" ;;
		esac
	done <<<"$parsed"
	[[ -z "$blocked_by" && -z "$blocks" ]] && return 0
	this_gh_num=$(resolve_task_gh_number "$task_id" "$todo_file" "$repo" || true)
	[[ -z "$this_gh_num" ]] && { log_verbose "$task_id: no ref:GH# — skipping relationships"; return 0; }
	this_node_id=$(_cached_node_id "$this_gh_num" "$repo")
	if [[ -z "$this_node_id" ]]; then
		log_verbose "$task_id: could not resolve node ID for #$this_gh_num"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		_hold_dependency_sync_retry "$this_gh_num" "$repo" "blocked_issue_node_unresolved"
		echo "RELS:0 RETRYABLE:1"
		return 0
	fi
	if [[ -n "$blocked_by" ]]; then
		result=$(_sync_declared_blocked_by_edges "$task_id" "$todo_file" "$repo" "$this_gh_num" "$this_node_id" "$blocked_by")
		IFS=':' read -r edge_rels edge_errors <<<"$result"
		rels_set=$((rels_set + edge_rels)); retryable_errors=$((retryable_errors + edge_errors))
		current_retry_errors="$edge_errors"
	fi
	if [[ -n "$blocks" ]]; then
		result=$(_sync_declared_blocks_edges "$task_id" "$todo_file" "$repo" "$this_gh_num" "$this_node_id" "$blocks")
		IFS=':' read -r edge_rels edge_errors <<<"$result"
		rels_set=$((rels_set + edge_rels)); retryable_errors=$((retryable_errors + edge_errors))
	fi

	if [[ "$current_retry_errors" -gt 0 ]]; then
		_hold_dependency_sync_retry "$this_gh_num" "$repo" "declared_dependency_repair_failed"
	fi
	echo "RELS:$rels_set RETRYABLE:$retryable_errors"
	return 0
}

# Link a single child issue as a sub-issue of a parent issue.
# Resolves task IDs to GitHub node IDs and calls the addSubIssue mutation.
# Arguments:
#   $1 - child_task_id
#   $2 - parent_task_id
#   $3 - todo_file path
#   $4 - repo slug
# Returns: 0 if linked (or would-link in dry-run), 1 if skipped
_link_sub_issue_pair() {
	local child_id="$1" parent_id="$2" todo_file="$3" repo="$4"

	local child_gh_num
	child_gh_num=$(resolve_task_gh_number "$child_id" "$todo_file" "$repo" || true)
	[[ -z "$child_gh_num" ]] && {
		log_verbose "$child_id: no ref:GH# — skipping sub-issue"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		return 1
	}
	local parent_gh_num
	parent_gh_num=$(resolve_task_gh_number "$parent_id" "$todo_file" "$repo" || true)
	[[ -z "$parent_gh_num" ]] && {
		log_verbose "$child_id: parent $parent_id has no ref:GH# — skipping sub-issue"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		return 1
	}

	local child_node_id
	child_node_id=$(_cached_node_id "$child_gh_num" "$repo")
	[[ -z "$child_node_id" ]] && { _relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"; return 1; }
	local parent_node_id
	parent_node_id=$(_cached_node_id "$parent_gh_num" "$repo")
	[[ -z "$parent_node_id" ]] && { _relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"; return 1; }

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would set #$child_gh_num as sub-issue of #$parent_gh_num ($child_id -> $parent_id)"
		return 0
	fi

	if _gh_add_sub_issue "$parent_node_id" "$child_node_id"; then
		log_verbose "$child_id (#$child_gh_num) sub-issue of $parent_id (#$parent_gh_num) ✓"
		return 0
	fi
	return 1
}

# Check if a task ID has the #parent / #parent-task / #meta tag in TODO.md.
# Arguments:
#   $1 - task_id to check
#   $2 - todo_file path
# Returns: 0 if parent-tagged, 1 otherwise
_is_parent_tagged_task() {
	local task_id="$1" todo_file="$2"
	local task_line
	task_line=$(_relationship_task_line "$task_id" "$todo_file")
	[[ -z "$task_line" ]] && return 1

	# Check for #parent, #parent-task, or #meta tags
	if echo "$task_line" | grep -qE '#parent\b|#parent-task\b|#meta\b'; then
		return 0
	fi
	return 1
}

# Sync parent-child (sub-issue) relationships for a task.
# Detects hierarchy through explicit parent metadata, dot notation, or a legacy
# blocked-by edge to a parent-tagged task. Distinct candidates fail closed.
# Arguments:
#   $1 - task_id
#   $2 - todo_file path
#   $3 - repo slug
# Returns: "RELS:N" with count of relationships set
_sync_subtask_hierarchy_for_task() {
	local task_id="$1" todo_file="$2" repo="$3"
	local rels_set=0 retryable_errors=0
	local key="" value="" dep_task_id="" explicit_parent="" blocked_by=""
	local parent_candidates="" parent_id="" candidate_count=0
	local dot_parent
	dot_parent=$(detect_parent_task_id "$task_id")
	local task_line
	task_line=$(_relationship_task_line "$task_id" "$todo_file")
	if [[ -n "$task_line" ]]; then
		local parsed
		if ! parsed=$(parse_task_line "$task_line"); then
			print_warning "$task_id: invalid parent or dependency metadata"
			_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
			echo "$_RELATIONSHIP_RETRY_RESULT"
			return 0
		fi
		while IFS='=' read -r key value; do
			case "$key" in
			blocked_by) blocked_by="$value" ;;
			parent) explicit_parent="$value" ;;
			esac
		done <<<"$parsed"
	fi

	for parent_id in "$explicit_parent" "$dot_parent"; do
		[[ -n "$parent_id" ]] || continue
		if ! printf '%s' "$parent_candidates" | grep -Fxq -- "$parent_id"; then
			parent_candidates="${parent_candidates}${parent_id}"$'\n'
		fi
	done

	if [[ -n "$blocked_by" ]]; then
		local saved_ifs="$IFS"
		IFS=','
		for dep_task_id in $blocked_by; do
			dep_task_id="${dep_task_id// /}"
			[[ -n "$dep_task_id" ]] || continue
			if _is_parent_tagged_task "$dep_task_id" "$todo_file" &&
				! printf '%s' "$parent_candidates" | grep -Fxq -- "$dep_task_id"; then
				parent_candidates="${parent_candidates}${dep_task_id}"$'\n'
			fi
		done
		IFS="$saved_ifs"
	fi

	candidate_count=$(printf '%s' "$parent_candidates" | grep -cE '.+' || true)
	if [[ "$candidate_count" -gt 1 ]]; then
		print_warning "$task_id: conflicting parent declarations"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		echo "$_RELATIONSHIP_RETRY_RESULT"
		return 0
	fi
	parent_id=$(printf '%s' "$parent_candidates" | grep -E '.+' | head -1 || true)
	[[ -n "$parent_id" ]] || {
		echo "RELS:0 RETRYABLE:0"
		return 0
	}
	if [[ "$parent_id" == "$task_id" ]]; then
		print_warning "$task_id: parent declaration is self-referential"
		_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
		echo "$_RELATIONSHIP_RETRY_RESULT"
		return 0
	fi
	if _relationship_deadline_expired; then
		_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
		retryable_errors=$((retryable_errors + 1))
	elif _link_sub_issue_pair "$task_id" "$parent_id" "$todo_file" "$repo"; then
		rels_set=$((rels_set + 1))
	else
		retryable_errors=$((retryable_errors + 1))
	fi

	echo "RELS:$rels_set RETRYABLE:$retryable_errors"
	return 0
}

# Sync all relationships for a single task (blocked-by + subtask hierarchy).
# Convenience wrapper called after push/enrich operations.
# Arguments:
#   $1 - task_id
#   $2 - todo_file path
#   $3 - repo slug
sync_relationships_for_task() {
	local task_id="$1" todo_file="$2" repo="$3"
	local owns_scope=0
	if [[ "$_RELATIONSHIP_SYNC_SCOPE_ACTIVE" -ne 1 ]]; then
		_save_cleanup_scope
		trap '_run_cleanups' RETURN
		_begin_relationship_sync_scope || return 1
		_register_relationship_sync_cleanup
		owns_scope=1
	fi
	_ensure_relationship_sync_deadline || {
		[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
		return 1
	}
	local AIDEVOPS_GH_DEADLINE_EPOCH="$_RELATIONSHIP_SYNC_DEADLINE_EPOCH"
	local result="" retryable_total=0 count=""
	result=$(_sync_blocked_by_for_task "$task_id" "$todo_file" "$repo" 2>/dev/null || echo "$_RELATIONSHIP_RETRY_RESULT")
	count=$(echo "$result" | grep -oE 'RETRYABLE:[0-9]+' | head -1 | sed 's/RETRYABLE://' || echo "0")
	retryable_total=$((retryable_total + count))
	if ! _relationship_deadline_expired; then
		result=$(_sync_subtask_hierarchy_for_task "$task_id" "$todo_file" "$repo" 2>/dev/null || echo "$_RELATIONSHIP_RETRY_RESULT")
		count=$(echo "$result" | grep -oE 'RETRYABLE:[0-9]+' | head -1 | sed 's/RETRYABLE://' || echo "0")
		retryable_total=$((retryable_total + count))
	else
		_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
		retryable_total=$((retryable_total + 1))
	fi
	if [[ "$retryable_total" -gt 0 ]] || _relationship_deadline_expired; then
		print_warning "$task_id: relationship sync pending; retry with: .agents/scripts/issue-sync-helper.sh relationships $task_id"
		[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
		return 1
	fi
	[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
	return 0
}

# Bulk relationship sync command.
# Scans TODO.md for tasks with relationship metadata or subtask patterns,
# resolves to GitHub node IDs, and sets relationships via GraphQL.
# Arguments:
#   $1 - optional target task_id (if empty, processes all)
cmd_relationships() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"

	local tasks=()
	if [[ -n "$target_task" ]]; then
		tasks=("$target_task")
	else
		# Collect tasks with relationship metadata or subtask IDs (contain a dot)
		while IFS= read -r line; do
			local tid
			tid=$(_task_id_from_todo_line "$line" 2>/dev/null || true)
			[[ -z "$tid" ]] && continue
			# Include if it has dependencies, an explicit parent, or is a subtask
			local dominated=false
			echo "$line" | grep -qE 'blocked-by:|blocks:|parent:' && dominated=true
			[[ "$tid" == *"."* ]] && dominated=true
			[[ "$dominated" == "true" ]] && tasks+=("$tid")
		done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[.\] t[0-9]+.*ref:GH#[0-9]+' || true)
	fi

	[[ ${#tasks[@]} -eq 0 ]] && {
		print_info "No tasks with relationships to sync"
		return 0
	}
	local owns_scope=0
	if [[ "$_RELATIONSHIP_SYNC_SCOPE_ACTIVE" -ne 1 ]]; then
		_save_cleanup_scope
		trap '_run_cleanups' RETURN
		_begin_relationship_sync_scope || return 1
		_register_relationship_sync_cleanup
		owns_scope=1
	fi
	_ensure_relationship_sync_deadline || {
		[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
		return 1
	}
	local AIDEVOPS_GH_DEADLINE_EPOCH="$_RELATIONSHIP_SYNC_DEADLINE_EPOCH"

	# Deduplicate (bash 3.2 compatible — no associative arrays)
	local seen_list=""
	local unique_tasks=()
	local t
	for t in "${tasks[@]}"; do
		if ! printf '%s' "$seen_list" | grep -Fxq -- "$t"; then
			unique_tasks+=("$t")
			seen_list="${seen_list}${t}"$'\n'
		fi
	done

	local total="${#unique_tasks[@]}"
	print_info "Syncing relationships for $total task(s) in $repo"

	local blocked_set=0 sub_set=0 attempted=0 complete=0 retryable_total=0 deadline_exhausted=false
	for task_id in "${unique_tasks[@]}"; do
		if _relationship_deadline_expired; then
			deadline_exhausted=true
			_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
			retryable_total=$((retryable_total + 1))
			break
		fi
		attempted=$((attempted + 1))
		local task_retryable=0
		_relationship_print_progress "$attempted" "$total"

		local result

		# Blocked-by / blocks
		result=$(_sync_blocked_by_for_task "$task_id" "$todo_file" "$repo" 2>/dev/null || echo "RELS:0")
		local n
		n=$(echo "$result" | grep -oE 'RELS:[0-9]+' | head -1 | sed 's/RELS://' || echo "0")
		blocked_set=$((blocked_set + n))
		n=$(echo "$result" | grep -oE 'RETRYABLE:[0-9]+' | head -1 | sed 's/RETRYABLE://' || echo "0")
		retryable_total=$((retryable_total + n))
		task_retryable=$((task_retryable + n))

		# Sub-issue hierarchy
		if _relationship_deadline_expired; then
			deadline_exhausted=true
			_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
			retryable_total=$((retryable_total + 1))
			task_retryable=$((task_retryable + 1))
		else
			result=$(_sync_subtask_hierarchy_for_task "$task_id" "$todo_file" "$repo" 2>/dev/null || echo "$_RELATIONSHIP_RETRY_RESULT")
			n=$(echo "$result" | grep -oE 'RELS:[0-9]+' | head -1 | sed 's/RELS://' || echo "0")
			sub_set=$((sub_set + n))
			n=$(echo "$result" | grep -oE 'RETRYABLE:[0-9]+' | head -1 | sed 's/RETRYABLE://' || echo "0")
			retryable_total=$((retryable_total + n))
			task_retryable=$((task_retryable + n))
		fi
		[[ "$task_retryable" -ne 0 ]] || complete=$((complete + 1))
	done
	[[ $total -gt 25 ]] && printf "\n" >&2

	_relationship_print_summary "$attempted" "$complete" "${#unique_tasks[@]}" "$retryable_total" "$deadline_exhausted"
	[[ "$owns_scope" -eq 0 ]] || _end_relationship_sync_scope
	[[ "$retryable_total" -eq 0 ]] || return 1
	return 0
}

# =============================================================================
# Backfill sub-issue links from GitHub state alone (t2114 — GH#19093)
# =============================================================================
# Unlike `cmd_relationships`, which is TODO-driven, and `_gh_auto_link_sub_issue`,
# which is wrapper-driven, `cmd_backfill_sub_issues` operates purely on GitHub
# state — title and body of each issue — without requiring a TODO entry or a
# brief file. It closes the "issue already exists, no TODO, wrapper bypassed"
# gap that leaves decomposition issues unlinked to their parents.
#
# Detection precedence (first match wins):
#   1. Dot-notation in title — `^(t\d+)\.\d+: ` → parent `t\1` (resolved via
#      gh search in the same repo). Used when a decomposition child was filed
#      with the t<parent>.<n> convention.
#   2. Explicit `Parent:` line in body — `Parent: tNNN` / `Parent: GH#NNN` /
#      `Parent: #NNN`. Bold-markdown (`**Parent:**`) and backtick-quoted refs
#      are accepted. Used when the filer names the parent directly.
#   3. `Blocked by: tNNN` where the referenced task carries the `parent-task`
#      label on GitHub. This is the only case where the parent-task label
#      gates the detection — the label indicates the blocker is a roadmap
#      parent, not a peer dependency.

# Resolve a top-level task ID (e.g., t1873) to its GitHub issue number by
# searching the repo. Matches only titles of the form "tNNN:" or "tNNN " —
# subtasks like "tNNN.2:" are deliberately excluded so that parent resolution
# can never return a sibling.
#
# Arguments:
#   $1 - task_id (e.g., t1873)
#   $2 - repo slug
# Echo: issue number on stdout, empty if not found
_resolve_task_id_via_gh_search() {
	local task_id="$1" repo="$2"
	[[ -z "$task_id" || -z "$repo" ]] && return 0
	# Dotted IDs (e.g. t2114.1) are the legitimate parent of a deeper child
	# like t2114.1.2. Previously the helper force-collapsed any dotted input
	# to its top-level root, which made multi-level dot-notation parent
	# resolution impossible — callers always got back t2114 instead of
	# t2114.1. We now accept dotted IDs and escape the dots in the jq regex
	# so the anchored match still rejects sibling subtasks (e.g. t2114.12).

	local matches
	# gh search is tokenised by whitespace; passing `t2114.1` still surfaces
	# the right candidates because the dot is a separator in the search
	# query. We filter strictly via jq below.
	matches=$(gh search issues "$task_id" --repo "$repo" --state all \
		--json number,title --limit 10 2>/dev/null || echo "[]")

	# Escape dots for the jq regex so `t2114.1` does not accidentally match
	# `t21141:` (where `.` would match any char in PCRE). Bash replacement
	# `\\.` resolves to a literal `\.` (single backslash + dot) in the
	# resulting string, which is what jq's test() needs to match a literal.
	local tid_escaped="${task_id//./\\.}"

	local num
	num=$(printf '%s' "$matches" | jq -r --arg tid "$tid_escaped" \
		'.[] | select(.title | test("^" + $tid + "([: ]|$)")) | .number' 2>/dev/null | head -1 || echo "")
	echo "$num"
	return 0
}

# Check whether an issue carries the `parent-task` label.
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns: 0 if labelled, 1 otherwise
_issue_has_parent_task_label() {
	local num="$1" repo="$2"
	[[ -z "$num" || -z "$repo" ]] && return 1

	local has
	has=$(_gh_with_timeout read gh issue view "$num" --repo "$repo" --json labels \
		--jq '[.labels[].name] | any(. == "parent-task")' 2>/dev/null || echo "${REL_FALSE}")
	[[ "$has" == "true" ]] && return 0
	return 1
}

# Detect a parent issue reference from an issue's title and body alone.
# No TODO.md or brief file is consulted — this is the purely-GH-driven path.
#
# Arguments:
#   $1 - issue title
#   $2 - issue body
#   $3 - repo slug
# Echo: parent issue number on stdout, empty if no parent detected
_detect_parent_from_gh_state() {
	local title="$1" body="$2" repo="$3"
	local parent_num=""

	# Method 1: dot-notation in title. Handles any depth of nesting:
	#   t1873.2:       → parent t1873
	#   t1873.2.1:     → parent t1873.2
	#   t2114.1.3.7:   → parent t2114.1.3
	# The previous single-level regex `^(t[0-9]+)\.[0-9]+:` silently dropped
	# every multi-level child because the ":" anchor never matched past the
	# first dotted segment.
	#
	# The regex captures the full dotted prefix up to — but excluding — the
	# final ".N:" segment; _resolve_task_id_via_gh_search is tolerant of
	# dotted IDs (it accepts intermediate levels as search targets).
	if [[ "$title" =~ ^(t[0-9]+(\.[0-9]+)*)\.[0-9]+:[[:space:]] ]]; then
		local dot_parent_tid="${BASH_REMATCH[1]}"
		parent_num=$(_resolve_task_id_via_gh_search "$dot_parent_tid" "$repo")
		if [[ -n "$parent_num" ]]; then
			echo "$parent_num"
			return 0
		fi
	fi

	# Method 2: "Parent:" line in body. Accepts plain ("Parent: tNNN"),
	# bold-markdown ("**Parent:** `tNNN`"), and either a task ID, a raw
	# GitHub number ("#NNN"), or the aidevops GH#NNN notation.
	local parent_ref
	# shellcheck disable=SC2016  # sed regex contains literal backticks and asterisks, no expansion wanted
	parent_ref=$(printf '%s\n' "$body" |
		sed -nE 's/^[[:space:]]*\**Parent:\**[[:space:]]*`?(t[0-9]+|GH#[0-9]+|#[0-9]+)`?.*/\1/p' |
		head -1 || true)
	if [[ -n "$parent_ref" ]]; then
		if [[ "$parent_ref" =~ ^#([0-9]+)$ ]]; then
			echo "${BASH_REMATCH[1]}"
			return 0
		elif [[ "$parent_ref" =~ ^GH#([0-9]+)$ ]]; then
			echo "${BASH_REMATCH[1]}"
			return 0
		elif [[ "$parent_ref" =~ ^(t[0-9]+)$ ]]; then
			parent_num=$(_resolve_task_id_via_gh_search "${BASH_REMATCH[1]}" "$repo")
			if [[ -n "$parent_num" ]]; then
				echo "$parent_num"
				return 0
			fi
		fi
	fi

	# Method 3: "Blocked by:" line listing task IDs; parent-task label on the
	# blocker is required. Supports comma-separated multi-blocker lists; the
	# first parent-tagged blocker wins.
	local blocker_list
	# shellcheck disable=SC2016  # sed regex contains literal backticks and asterisks, no expansion wanted
	blocker_list=$(printf '%s\n' "$body" |
		sed -nE 's/^[[:space:]]*\**Blocked by:\**[[:space:]]*`?([t0-9.,[:space:]]+)`?.*/\1/p' |
		head -1 || true)
	if [[ -n "$blocker_list" ]]; then
		# Normalise separators so whitespace-tolerant input (comma or space)
		# parses the same way.
		local normalised="${blocker_list//,/ }"
		local blocker_id
		for blocker_id in $normalised; do
			blocker_id="${blocker_id// /}"
			[[ -z "$blocker_id" ]] && continue
			[[ "$blocker_id" =~ ^t[0-9]+$ ]] || continue
			local candidate
			candidate=$(_resolve_task_id_via_gh_search "$blocker_id" "$repo")
			[[ -z "$candidate" ]] && continue
			if _issue_has_parent_task_label "$candidate" "$repo"; then
				echo "$candidate"
				return 0
			fi
		done
	fi

	return 0
}

# Link a single child issue as a sub-issue of a detected parent, operating
# purely on GitHub state (title + body). Idempotent — `_gh_add_sub_issue`
# suppresses duplicate-relationship errors.
#
# Arguments:
#   $1 - child issue number
#   $2 - repo slug
#   $3 - (optional) pre-fetched title — avoids redundant gh API call
#   $4 - (optional) pre-fetched body — must be provided alongside $3
# Returns: 0 on success/skip, 1 on unexpected failure
# Echoes one of: "LINKED <child>:<parent>", "SKIPPED <child>", "DRY <child>:<parent>"
_backfill_one_issue() {
	local num="$1" repo="$2" prefetched_title="${3:-}" prefetched_body="${4:-}"
	local backfill_skipped="SKIPPED"
	[[ -z "$num" || -z "$repo" ]] && {
		echo "$backfill_skipped $num"
		return 0
	}

	# Accept optional pre-fetched title/body to avoid redundant API calls
	# when called from cmd_backfill_sub_issues outer loop (GH#19942).
	local title body
	if [[ -n "$prefetched_title" ]]; then
		title="$prefetched_title"
		body="$prefetched_body"
	else
		local meta
		meta=$(_gh_with_timeout read gh issue view "$num" --repo "$repo" --json title,body 2>/dev/null || echo "{}")
		title=$(printf '%s' "$meta" | jq -r '.title // ""' 2>/dev/null)
		body=$(printf '%s' "$meta" | jq -r '.body // ""' 2>/dev/null)
	fi
	if [[ -z "$title" ]]; then
		echo "$backfill_skipped $num"
		return 0
	fi

	local parent_num
	parent_num=$(_detect_parent_from_gh_state "$title" "$body" "$repo")
	if [[ -z "$parent_num" || "$parent_num" == "$num" ]]; then
		echo "$backfill_skipped $num"
		return 0
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would link #$num as sub-issue of #$parent_num"
		echo "DRY $num:$parent_num"
		return 0
	fi

	local child_node parent_node _rate_limited=0
	child_node=$(_cached_node_id "$num" "$repo")
	_node_id_was_rate_limited && _rate_limited=1
	parent_node=$(_cached_node_id "$parent_num" "$repo")
	_node_id_was_rate_limited && _rate_limited=1
	if [[ -z "$child_node" || -z "$parent_node" ]]; then
		log_verbose "#$num: could not resolve node IDs for $num / $parent_num"
		if [[ "$_rate_limited" == "1" ]]; then
			echo "RATE_LIMITED $num"
		else
			echo "$backfill_skipped $num"
		fi
		return 0
	fi

	if _gh_add_sub_issue "$parent_node" "$child_node"; then
		log_verbose "#$num linked as sub-issue of #$parent_num ✓"
		echo "LINKED $num:$parent_num"
		return 0
	fi
	echo "$backfill_skipped $num"
	return 0
}

# =============================================================================
# Parent-Side Detection — Umbrella-Style Parent-Task Backfill (GH#19942)
# =============================================================================
# Extends backfill-sub-issues with parent-side detection: when an issue carries
# the `parent-task` label, parse its body for a children section and link every
# referenced child as a sub-issue. Complements the existing child-side path
# that detects parents from child title/body.

# Extract the children section from an issue body. Matches headings:
#   ## Children, ## Child Issues, ## Sub-issues, ## Phases
# (case-insensitive). Returns content from the heading to the next ## heading
# or end of body.
#
# Arguments:
#   $1 - issue body text
# Echo: section content (may be empty if no matching heading found)
_extract_children_section() {
	local body="$1"
	[[ -z "$body" ]] && return 0

	printf '%s\n' "$body" | awk '
		BEGIN { in_section = 0 }
		{
			lower = tolower($0)
			if (lower ~ /^##[[:space:]]+(children|child issues|sub-issues|phases)/) {
				in_section = 1
				next
			}
			if (/^##[[:space:]]/) {
				if (in_section) exit
			}
			if (in_section) print
		}
	'
	return 0
}

# Extract child issue references from a children section. Only matches #NNN
# and GH#NNN references on lines starting with list markers (-, +, *) or
# table cell delimiters (|) to avoid false positives from prose mentions.
#
# Arguments:
#   $1 - children section text (output of _extract_children_section)
# Echo: one issue number per line (deduplicated, sorted numerically)
_extract_child_references() {
	local section="$1"
	[[ -z "$section" ]] && return 0

	printf '%s\n' "$section" |
		grep -E '^[[:space:]]*[-+*|]' |
		grep -oE '(GH)?#[0-9]+' |
		sed -E 's/^(GH)?#//' |
		sort -un
	return 0
}

# Link children listed in a parent-task issue's body section. Parses the body
# for a ## Children (or alias) heading and links every #NNN reference found
# in list items or table cells within that section.
#
# Arguments:
#   $1 - parent issue number
#   $2 - repo slug
#   $3 - issue body (pre-fetched to avoid redundant API calls)
# Echo: "PARENT_LINKED <num>:<count>" or "PARENT_DRY <num>:<count>" or
#       "PARENT_SKIPPED <num>:0"
# Returns: 0 always (errors are logged, not propagated)
_backfill_parent_children() {
	local num="$1" repo="$2" body="$3"
	local _skip_tag="PARENT_SKIPPED"

	[[ -z "$num" || -z "$repo" ]] && {
		echo "${_skip_tag} ${num:-0}:0"
		return 0
	}

	local children_section
	children_section=$(_extract_children_section "$body")
	if [[ -z "$children_section" ]]; then
		log_verbose "#$num: no children section found in body"
		echo "${_skip_tag} $num:0"
		return 0
	fi

	local child_nums_raw
	child_nums_raw=$(_extract_child_references "$children_section")
	if [[ -z "$child_nums_raw" ]]; then
		log_verbose "#$num: children section present but no issue references found"
		echo "${_skip_tag} $num:0"
		return 0
	fi

	# Read into array (bash 3.2 compatible — no mapfile)
	local child_nums=()
	local _cn
	while IFS= read -r _cn; do
		[[ -n "$_cn" ]] && child_nums+=("$_cn")
	done <<< "$child_nums_raw"

	if [[ ${#child_nums[@]} -eq 0 ]]; then
		echo "${_skip_tag} $num:0"
		return 0
	fi

	local linked=0
	local parent_node=""
	local _link_desc="sub-issue of #$num (parent-side)"

	for _cn in "${child_nums[@]}"; do
		# Skip self-references
		[[ "$_cn" == "$num" ]] && continue

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would link #$_cn as ${_link_desc}"
			linked=$((linked + 1))
			continue
		fi

		# Lazy-resolve parent node ID (once, on first real link)
		if [[ -z "$parent_node" ]]; then
			parent_node=$(_cached_node_id "$num" "$repo")
			if [[ -z "$parent_node" ]]; then
				if _node_id_was_rate_limited; then
					log_verbose "#$num: parent node ID resolution hit rate limit"
					echo "PARENT_RATE_LIMITED $num:0"
				else
					log_verbose "#$num: could not resolve parent node ID"
					echo "${_skip_tag} $num:0"
				fi
				return 0
			fi
		fi

		local child_node
		child_node=$(_cached_node_id "$_cn" "$repo")
		if [[ -z "$child_node" ]]; then
			log_verbose "#$_cn: could not resolve child node ID for parent #$num"
			continue
		fi

		if _gh_add_sub_issue "$parent_node" "$child_node"; then
			log_verbose "#$_cn linked as ${_link_desc}"
			linked=$((linked + 1))
		fi
	done

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "PARENT_DRY $num:$linked"
	else
		echo "PARENT_LINKED $num:$linked"
	fi
	return 0
}

# Parse the --issue flag from cmd_backfill_sub_issues arguments.
# Prints the target issue number to stdout (empty string if not supplied).
# Returns 1 on parse error.
_backfill_parse_target_issue() {
	local _arg
	while [[ $# -gt 0 ]]; do
		_arg="$1"
		case "$_arg" in
		--issue)
			if [[ -z "${2:-}" ]]; then
				print_error "backfill-sub-issues: --issue requires an issue number"
				return 1
			fi
			printf '%s' "$2"
			return 0
			;;
		*)
			shift
			;;
		esac
	done
	printf ''
	return 0
}

# Fetch the list of open issue numbers for a repo, or return a single number.
# Usage: _backfill_fetch_issue_numbers <target_issue> <repo>
# Prints one number per line to stdout; returns 1 on gh failure.
_backfill_fetch_issue_numbers() {
	local target_issue="$1"
	local repo="$2"

	if [[ -n "$target_issue" ]]; then
		printf '%s\n' "$target_issue"
		return 0
	fi

	# Fail fast on gh errors. Previously an auth/network failure turned
	# into `[]` and the run reported "No issues to backfill" — success
	# with no work done, which silently skipped every real candidate
	# and made the pulse t2112 reconcile path believe it had already
	# backfilled an unblessed issue. Any non-zero exit now aborts the
	# command with a clear error and propagates the gh stderr.
	local list_json list_err list_rc
	list_err=$(mktemp) || {
		print_error "backfill-sub-issues: mktemp failed"
		return 1
	}
	list_json=$(_gh_with_timeout read gh issue list --repo "$repo" --state open --limit 500 \
		--json number 2>"$list_err")
	list_rc=$?
	if [[ "$list_rc" -ne 0 ]]; then
		print_error "backfill-sub-issues: gh issue list failed for $repo (rc=${list_rc})"
		sed 's/^/  /' "$list_err" >&2 || true
		rm -f "$list_err"
		return 1
	fi
	rm -f "$list_err"
	printf '%s' "$list_json" | jq -r '.[].number' 2>/dev/null || true
	return 0
}

# Process a list of issue numbers, linking sub-issue relationships.
# Usage: _backfill_process_loop <repo> <issue_numbers_array_name>
# Prints a summary line and returns 0.
_backfill_process_loop() {
	local repo="$1"
	shift
	local issue_numbers=("$@")
	local total="${#issue_numbers[@]}"

	print_info "Backfilling sub-issue links for $total issue(s) in $repo"

	# Initialise the node-ID cache in the parent process so all subshells inherit
	# the same _NODE_ID_CACHE_FILE and _NODE_ID_RATE_LIMITED_FILE paths.
	# Without this, each _cached_node_id() subshell creates its own temp file and
	# cache hits between issues are lost.
	_init_node_id_cache
	# Clear cache to prevent cross-repo poisoning in long-lived processes.
	# Cache key is just the issue number (e.g. "123=node_id") — without repo
	# qualification, stale entries from a prior repo would be returned for
	# same-numbered issues in a different repo.
	: >"$_NODE_ID_CACHE_FILE"

	local linked
	local skipped
	local rate_limited
	local processed
	linked=0
	skipped=0
	rate_limited=0
	processed=0
	local _num result meta _title _body _has_parent _pcount
	for _num in "${issue_numbers[@]}"; do
		processed=$((processed + 1))
		if [[ $((processed % 25)) -eq 0 || $processed -eq $total ]]; then
			printf "\r  Progress: %d/%d issues..." "$processed" "$total" >&2
		fi

		# Pre-fetch issue data (title, body, labels) for routing (GH#19942).
		# A single API call per issue avoids double-fetch in both paths.
		meta=$(_gh_with_timeout read gh issue view "$_num" --repo "$repo" --json title,body,labels 2>/dev/null || echo "{}")
		_title=$(printf '%s' "$meta" | jq -r '.title // ""' 2>/dev/null)
		_body=$(printf '%s' "$meta" | jq -r '.body // ""' 2>/dev/null)
		_has_parent=$(printf '%s' "$meta" | jq -r '[.labels[].name] | any(. == "parent-task")' 2>/dev/null || echo "${REL_FALSE}")

		if [[ "$_has_parent" == "true" ]]; then
			# Parent-side: parse body for children section and link downward
			result=$(_backfill_parent_children "$_num" "$repo" "$_body" | tail -1)
		else
			# Child-side: detect parent from title/body and link upward
			result=$(_backfill_one_issue "$_num" "$repo" "$_title" "$_body" | tail -1)
		fi

		case "$result" in
		LINKED*) linked=$((linked + 1)) ;;
		DRY*) linked=$((linked + 1)) ;;
		PARENT_LINKED* | PARENT_DRY*)
			_pcount="${result##*:}"
			linked=$((linked + _pcount))
			;;
		# RATE_LIMITED / PARENT_RATE_LIMITED: node ID could not be resolved due to
		# GraphQL exhaustion and REST also failing. Counted separately so callers
		# (pulse t2112 reconciler) can re-enqueue rather than treating as permanent.
		RATE_LIMITED* | PARENT_RATE_LIMITED*) rate_limited=$((rate_limited + 1)) ;;
		*) skipped=$((skipped + 1)) ;;
		esac
	done
	[[ $total -gt 25 ]] && printf "\n" >&2

	printf "\n=== Backfill Sub-Issues ===\nLinked: %d | Skipped: %d | Rate-limited: %d | Issues processed: %d\n" \
		"$linked" "$skipped" "$rate_limited" "$total"
	return 0
}

# =============================================================================
# Cross-Phase Blocked-By Backfill (t2877 — GH#20972)
# =============================================================================
# Parses prose dependency declarations from parent-task issue bodies (e.g.,
# "P1 children blocked by P0a + P0b") and emits the corresponding GitHub
# addBlockedBy relationships. Closes the gap identified in t2875: decomposition
# parents encode rich dependency graphs in narrative prose that the existing
# relationship-sync (which only reads explicit blocked-by:tNNN from TODO.md)
# cannot reach.
#
# Three helpers compose the pipeline:
#   _resolve_single_phase_ref  — resolves one phase ID (exact or prefix match)
#   _expand_phase_refs_to_nums — tokenises a raw ref string and resolves each
#   _parse_parent_phase_deps   — full parser: phases table + dep section → PAIR lines
# Plus cmd_backfill_cross_phase_blocked_by — the public entry point.

# Resolve a single phase reference to one or more issue numbers using a
# pre-built phase_map (one "phase_id=issue_num" per line).
#
# Two resolution modes:
#   - Specific (trailing letter, e.g. P0a, P0.5b): exact key lookup.
#   - Bare (no trailing letter, e.g. P1, P4, P0.5): prefix match returns all
#     children whose ID starts with the given prefix followed by a letter.
#     The prefix's dots are escaped to avoid regex ambiguity (P0.5 → P0\.5).
#
# Arguments:
#   $1 - phase ref (e.g., P0a, P1, P0.5)
#   $2 - phase_map text
# Echo: issue numbers — one per line (zero or more)
# Returns: 0 always
_resolve_single_phase_ref() {
	local ref="$1" phase_map="$2"
	[[ -z "$ref" || -z "$phase_map" ]] && return 0

	if [[ "$ref" =~ [a-z]$ ]]; then
		# Specific child — exact key lookup (grep -F to treat as fixed string)
		local num
		num=$(printf '%s' "$phase_map" | grep -F "${ref}=" | head -1 | cut -d= -f2- || true)
		[[ -n "$num" ]] && printf '%s\n' "$num"
	else
		# Bare phase — prefix match: Pn or Pn.m followed by exactly one letter
		local escaped_ref
		escaped_ref=$(printf '%s' "$ref" | sed 's/\./\\./g')
		printf '%s' "$phase_map" | grep -E "^${escaped_ref}[a-z]=" | cut -d= -f2- || true
	fi
	return 0
}

# Expand slash notation (e.g., P0.5b/c or P4a/P4b) to issue numbers.
#
# Parts after the first that do not start with 'P' inherit the numeric prefix
# of the first part (all characters before its trailing letter). Examples:
#   P0.5b/c  → P0.5b, P0.5c
#   P4a/P4b  → P4a, P4b  (both start with P, no inheritance needed)
#   P2a/b    → P2a, P2b
#
# Arguments:
#   $1 - slash token (e.g., P0.5b/c)
#   $2 - phase_map text
# Echo: issue numbers — one per line
# Returns: 0 always
_expand_slash_notation() {
	local token="$1" phase_map="$2"
	[[ -z "$token" ]] && return 0

	# Numeric prefix of the first part — used when subsequent parts lack 'P'
	local first_part
	first_part=$(printf '%s' "$token" | cut -d/ -f1)
	local numeric_prefix
	numeric_prefix=$(printf '%s' "$first_part" | sed -E 's/[a-z]+$//')

	# Iterate over slash-separated parts (tr splits cleanly in bash 3.2)
	local _part
	while IFS= read -r _part; do
		[[ -z "$_part" ]] && continue
		if [[ "$_part" =~ ^P ]]; then
			_resolve_single_phase_ref "$_part" "$phase_map"
		else
			_resolve_single_phase_ref "${numeric_prefix}${_part}" "$phase_map"
		fi
	done < <(printf '%s\n' "$token" | tr '/' '\n')
	return 0
}

# Expand a raw phase reference string to a list of issue numbers.
#
# Handles separators (+ and ,) between phase refs, and slash notation within
# individual refs. Examples:
#   "P0a + P0b"        → (issue for P0a, issue for P0b)
#   "P4 + P1c + P0.5b/c" → (all P4 issues, P1c issue, P0.5b issue, P0.5c issue)
#   "P1 children"      → all P1 children (strip "children" first)
#
# Arguments:
#   $1 - raw phase ref string (may contain +, comma, slash)
#   $2 - phase_map text
# Echo: issue numbers — one per line (may contain duplicates if phase_map has them)
# Returns: 0 always
_expand_phase_refs_to_nums() {
	local raw="$1" phase_map="$2"
	[[ -z "$raw" || -z "$phase_map" ]] && return 0

	# Normalise: strip "children" keyword, replace + and , with spaces
	local normalised
	normalised=$(printf '%s' "$raw" \
		| sed 's/[[:space:]]*children[[:space:]]*//' \
		| sed 's/+/ /g' \
		| sed 's/,/ /g')

	# Iterate over whitespace-separated tokens.
	# Word-split is intentional here (IFS=default, no quoting).
	local token
	# shellcheck disable=SC2086
	for token in $normalised; do
		token=$(printf '%s' "$token" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
		[[ -z "$token" ]] && continue

		if printf '%s' "$token" | grep -q '/'; then
			_expand_slash_notation "$token" "$phase_map"
		else
			_resolve_single_phase_ref "$token" "$phase_map"
		fi
	done
	return 0
}

# Parse cross-phase dependency declarations from a parent-task issue body and
# resolve them to (child_issue_num, blocker_issue_num) pairs.
#
# Parsing pipeline:
#   1. Scan the full body for table rows of the form
#      "| tNNN / #MMM | PXYz: description |" and build a phase_id → issue_num
#      map (e.g. "P0a=20896").
#   2. Extract the "## Cross-Phase Dependencies" section (or heading variations
#      matching "cross.phase dep", "phase dep", or "dependencies").
#   3. For each list item in the section that contains "blocked by" (and does NOT
#      contain "in parallel"), split into (left/blocked, right/blocker) sides,
#      expand each via _expand_phase_refs_to_nums, and emit pairs.
#
# Handled line shapes (all 8+ patterns from t2840 / #20892):
#   - "P0.5 children blocked by P0a"
#   - "P1 children blocked by P0a + P0b"
#   - "P2c blocked by P0.5a + P0.5c"
#   - "P2d blocked by P2c"
#   - "P4 children blocked by P0a + P0b + P0.5a"
#   - "P5 children blocked by P0a + P0b + P1a"
#   - "P5c blocked by P4a + P4b"
#   - "P6 blocked by P4 + P1c + P0.5b/c"
#   (Lines containing "in parallel" are intentionally skipped.)
#
# Arguments:
#   $1 - issue body text
# Echo: "PAIR:child_num:blocker_num" lines (zero or more; may have duplicates
#        that callers should tolerate — _gh_add_blocked_by is idempotent)
# Returns: 0 always
_parse_parent_phase_deps() {
	local body="$1"
	[[ -z "$body" ]] && return 0

	# --- Step 1: Build phase_id → issue_num map from table rows ---
	# Table row format: | tNNN / #MMM | PXYz: description |
	# We scan the entire body (not just the Phases section) so that
	# split-across-sections tables still resolve correctly.
	local phase_map=""
	while IFS= read -r tline; do
		# Quick pre-filter: must start with | and contain / #
		[[ "$tline" =~ ^\|[[:space:]]* ]] || continue
		printf '%s' "$tline" | grep -q '/ #' || continue

		local _iss_num _phase_id
		_iss_num=$(printf '%s' "$tline" | sed -nE \
			's/^[[:space:]]*\|[[:space:]]*t[0-9]+[[:space:]]*\/[[:space:]]*#([0-9]+)[[:space:]]*\|.*/\1/p' \
			| head -1 || true)
		_phase_id=$(printf '%s' "$tline" | sed -nE \
			's/^[[:space:]]*\|[^|]+\|[[:space:]]*(P[0-9]+(\.[0-9]+)*[a-z]).*/\1/p' \
			| head -1 || true)
		[[ -z "$_iss_num" || -z "$_phase_id" ]] && continue
		phase_map+="${_phase_id}=${_iss_num}"$'\n'
	done < <(printf '%s\n' "$body")

	[[ -z "$phase_map" ]] && return 0

	# --- Step 2: Extract cross-phase dependency section ---
	# Matches headings (case-insensitive) containing:
	#   "cross-phase dep…", "cross phase dep…", "phase dep…", or "dependencies"
	local dep_section
	dep_section=$(printf '%s\n' "$body" | awk '
		BEGIN { in_sec = 0 }
		{
			lc = tolower($0)
			if (lc ~ /^##[[:space:]]+(cross.phase[[:space:]]+dep|cross[[:space:]]+phase[[:space:]]+dep|phase[[:space:]]+dep)/ ||
			    lc ~ /^##[[:space:]]+dependencies/) {
				in_sec = 1; next
			}
			if (/^##[[:space:]]/) { if (in_sec) exit }
			if (in_sec) print
		}
	')
	[[ -z "$dep_section" ]] && return 0

	# --- Step 3: Parse dep lines and emit PAIR:child:blocker ---
	while IFS= read -r dep_line; do
		printf '%s' "$dep_line" | grep -qi "blocked by" || continue
		printf '%s' "$dep_line" | grep -qi "in parallel" && continue
		[[ "$dep_line" =~ ^[[:space:]]*- ]] || continue

		# Normalise "Blocked by" / "blocked By" → "blocked by" for sed extraction
		local norm_line
		norm_line=$(printf '%s' "$dep_line" \
			| sed 's/[Bb][Ll][Oo][Cc][Kk][Ee][Dd][[:space:]]\{1,\}[Bb][Yy]/blocked by/g')

		# Left side: text between "- " and " blocked by", strip trailing "children"
		local _left _right
		_left=$(printf '%s' "$norm_line" | sed -nE \
			's/^[[:space:]]*-[[:space:]]+([^(]+)[[:space:]]+blocked by.*/\1/p' \
			| sed -E 's/[[:space:]]*(children)?[[:space:]]*$//' \
			| head -1 || true)
		# Right side: text after "blocked by ", up to "(" (optional trailing comment)
		_right=$(printf '%s' "$norm_line" | sed -nE \
			's/^.*blocked by[[:space:]]+([^(]+).*/\1/p' \
			| sed -E 's/[[:space:]]*$//' \
			| head -1 || true)

		[[ -z "$_left" || -z "$_right" ]] && continue

		# Resolve left (blocked) and right (blocker) to issue numbers
		local blocked_nums blocker_nums
		blocked_nums=$(_expand_phase_refs_to_nums "$_left" "$phase_map")
		blocker_nums=$(_expand_phase_refs_to_nums "$_right" "$phase_map")

		[[ -z "$blocked_nums" || -z "$blocker_nums" ]] && continue

		_emit_phase_dependency_pairs "$blocked_nums" "$blocker_nums"
	done < <(printf '%s\n' "$dep_section")

	return 0
}

# Backfill cross-phase blocked-by relationships for a single parent-task issue.
# Parses the issue body for prose dependency declarations and calls
# addBlockedBy for each resolved (child, blocker) pair. Idempotent —
# _gh_add_blocked_by silently ignores already-existing relationships.
#
# Usage:
#   cmd_backfill_cross_phase_blocked_by --issue N
#
# --issue N is mandatory; this command is designed for per-issue invocation
# from the pulse reconcile loop (t2877 stage, mirroring t2838 sub-issue
# backfill).
#
# Returns: 0 on success, 1 on setup error
cmd_backfill_cross_phase_blocked_by() {
	local target_issue=""
	while [[ $# -gt 0 ]]; do
		local _cbb_arg="$1"
		case "$_cbb_arg" in
		--issue)
			target_issue="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	_init_cmd || return 1
	local repo="$_CMD_REPO"

	if [[ -z "$target_issue" ]]; then
		print_error "backfill-cross-phase-blocked-by: --issue N is required"
		return 1
	fi

	# Fetch the parent issue body
	local body
	body=$(_gh_with_timeout read gh issue view "$target_issue" --repo "$repo" \
		--json body --jq '.body // ""' 2>/dev/null) || body=""

	if [[ -z "$body" ]]; then
		log_verbose "#$target_issue: empty body — no cross-phase deps to backfill"
		printf '\n=== Cross-Phase Blocked-By Backfill ===\nPairs: 0\n'
		return 0
	fi

	# Initialise node-ID cache for this invocation
	_init_node_id_cache

	# Parse dependency pairs from the body
	local pairs
	pairs=$(_parse_parent_phase_deps "$body")

	if [[ -z "$pairs" ]]; then
		log_verbose "#$target_issue: no cross-phase dependency declarations found"
		printf '\n=== Cross-Phase Blocked-By Backfill ===\nPairs: 0\n'
		return 0
	fi

	local pairs_set=0 pairs_skipped=0
	local _bn _lr child_node blocker_node

	while IFS= read -r pair_line; do
		[[ "$pair_line" =~ ^PAIR:([0-9]+):([0-9]+)$ ]] || continue
		_bn="${BASH_REMATCH[1]}"
		_lr="${BASH_REMATCH[2]}"

		child_node=$(_cached_node_id "$_bn" "$repo")
		blocker_node=$(_cached_node_id "$_lr" "$repo")

		if [[ -z "$child_node" || -z "$blocker_node" ]]; then
			log_verbose "#$_bn blocked-by #$_lr: could not resolve node IDs — skipping"
			pairs_skipped=$((pairs_skipped + 1))
			continue
		fi

		if _backfill_cross_phase_pair "$_bn" "$_lr" "$child_node" "$blocker_node" "$repo"; then
			pairs_set=$((pairs_set + 1))
		else
			pairs_skipped=$((pairs_skipped + 1))
		fi
	done <<< "$pairs"

	printf '\n=== Cross-Phase Blocked-By Backfill ===\nPairs set: %d | Skipped: %d\n' \
		"$pairs_set" "$pairs_skipped"
	return 0
}

_backfill_cross_phase_pair() {
	local blocked_num="$1" blocker_num="$2" child_node="$3" blocker_node="$4"
	local repo="$5"
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would set #$blocked_num blocked-by #$blocker_num"
		return 0
	fi
	if _gh_add_blocked_by "$child_node" "$blocker_node"; then
		log_verbose "#$blocked_num blocked-by #$blocker_num ✓"
		if ! _ensure_dependency_status_blocked \
			"$blocked_num" "$repo" "cross_phase_native_relationship_linked"; then
			return 1
		fi
		return 0
	fi
	return 1
}

# Backfill sub-issue parent-child links for issues in the current repo.
# Detects parents from title/body only — no TODO.md or brief file required.
#
# Usage:
#   cmd_backfill_sub_issues [--issue N]
#
# Without --issue, enumerates open issues in the repo (up to 500) and attempts
# to link each one to its parent. With --issue, operates on a single issue —
# this is the entry point used by the t2112 reconciler for one-issue backfill.
cmd_backfill_sub_issues() {
	local target_issue
	target_issue=$(_backfill_parse_target_issue "$@") || return 1

	_init_cmd || return 1
	local repo="$_CMD_REPO"

	local issue_numbers=()
	while IFS= read -r _n; do
		[[ -n "$_n" ]] && issue_numbers+=("$_n")
	done < <(_backfill_fetch_issue_numbers "$target_issue" "$repo") || return 1

	local total="${#issue_numbers[@]}"
	if [[ $total -eq 0 ]]; then
		print_info "No issues to backfill in $repo"
		return 0
	fi

	_backfill_process_loop "$repo" "${issue_numbers[@]}"
	return 0
}
