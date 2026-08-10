#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Relationships — Invocation Batching and Diagnostics
# =============================================================================
# Provides invocation-scoped caches, operation timing, and bounded multi-alias
# addBlockedBy mutations for issue-sync-relationships.sh.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_ISSUE_SYNC_RELATIONSHIP_BATCH_LOADED:-}" ]] && return 0
_ISSUE_SYNC_RELATIONSHIP_BATCH_LOADED=1

_REL_BATCH_JSON_TRUE="true"
_RELATIONSHIP_NATIVE_CACHE_FILE=""
_RELATIONSHIP_STATUS_SYNCED_FILE=""
_RELATIONSHIP_OPERATION_TIMING_FILE=""

_init_relationship_batch_state() {
	_init_issue_sync_repository_id_cache || return 1
	_RELATIONSHIP_NATIVE_CACHE_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-relationship-native.XXXXXX") || return 1
	_RELATIONSHIP_STATUS_SYNCED_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-relationship-status.XXXXXX") || return 1
	_RELATIONSHIP_OPERATION_TIMING_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-relationship-timing.XXXXXX") || return 1
	return 0
}

_cleanup_relationship_batch_state() {
	rm -f "${_RELATIONSHIP_NATIVE_CACHE_FILE:-}" \
		"${_RELATIONSHIP_STATUS_SYNCED_FILE:-}" \
		"${_RELATIONSHIP_OPERATION_TIMING_FILE:-}" \
		"${_ISSUE_SYNC_REPOSITORY_ID_CACHE_FILE:-}"
	_RELATIONSHIP_NATIVE_CACHE_FILE=""
	_RELATIONSHIP_STATUS_SYNCED_FILE=""
	_RELATIONSHIP_OPERATION_TIMING_FILE=""
	_ISSUE_SYNC_REPOSITORY_ID_CACHE_FILE=""
	return 0
}

_register_relationship_batch_cleanup() {
	push_cleanup "rm -f '${_RELATIONSHIP_NATIVE_CACHE_FILE}'"
	push_cleanup "rm -f '${_RELATIONSHIP_STATUS_SYNCED_FILE}'"
	push_cleanup "rm -f '${_RELATIONSHIP_OPERATION_TIMING_FILE}'"
	push_cleanup "rm -f '${_ISSUE_SYNC_REPOSITORY_ID_CACHE_FILE}'"
	return 0
}

_relationship_run_timed() {
	local operation_class="$1"
	shift
	local started_at="0" finished_at="0" rc=0
	started_at=$(date +%s 2>/dev/null || printf '0')
	AIDEVOPS_GH_OPERATION_CLASS="$operation_class" "$@" || rc=$?
	finished_at=$(date +%s 2>/dev/null || printf '%s' "$started_at")
	if [[ -f "${_RELATIONSHIP_OPERATION_TIMING_FILE:-}" ]]; then
		printf '%s:%s\n' "$operation_class" "$((finished_at - started_at))" \
			>>"$_RELATIONSHIP_OPERATION_TIMING_FILE"
	fi
	return "$rc"
}

_relationship_operation_seconds() {
	local operation_class="$1"
	local line="" recorded_class="" seconds="0" total="0"
	[[ -f "${_RELATIONSHIP_OPERATION_TIMING_FILE:-}" ]] || { printf '0\n'; return 0; }
	while IFS= read -r line; do
		recorded_class="${line%%:*}"
		seconds="${line#*:}"
		[[ "$recorded_class" == "$operation_class" && "$seconds" =~ ^[0-9]+$ ]] || continue
		total=$((total + seconds))
	done <"$_RELATIONSHIP_OPERATION_TIMING_FILE"
	printf '%s\n' "$total"
	return 0
}

_relationship_backend_call_count_for() {
	local operation_class="$1"
	local count="0"
	[[ -f "${_RELATIONSHIP_BACKEND_CALL_FILE:-}" ]] || { printf '0\n'; return 0; }
	count=$(grep -cFx -- "$operation_class" "$_RELATIONSHIP_BACKEND_CALL_FILE" 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s\n' "$count"
	return 0
}

_relationship_native_cache_invalidate() {
	local blocked_id="$1"
	local cache_file="${_RELATIONSHIP_NATIVE_CACHE_FILE:-}"
	local temp_file="" line=""
	[[ -n "$blocked_id" && -f "$cache_file" ]] || return 0
	temp_file="${cache_file}.tmp.$$"
	: >"$temp_file" || return 1
	while IFS= read -r line; do
		[[ "$line" == "${blocked_id}|"* ]] || printf '%s\n' "$line" >>"$temp_file"
	done <"$cache_file"
	mv "$temp_file" "$cache_file"
	return $?
}

_relationship_status_was_synced() {
	local issue_num="$1"
	[[ -f "${_RELATIONSHIP_STATUS_SYNCED_FILE:-}" ]] || return 1
	grep -Fxq -- "$issue_num" "$_RELATIONSHIP_STATUS_SYNCED_FILE"
	return $?
}

_relationship_mark_status_synced() {
	local issue_num="$1"
	[[ -f "${_RELATIONSHIP_STATUS_SYNCED_FILE:-}" ]] || return 0
	_relationship_status_was_synced "$issue_num" || printf '%s\n' "$issue_num" >>"$_RELATIONSHIP_STATUS_SYNCED_FILE"
	return 0
}

_relationship_batch_alias_success() {
	local payload="$1" alias_name="$2"
	printf '%s' "$payload" | jq -e --arg alias "$alias_name" \
		'.data[$alias].issue.number | type == "number"' >/dev/null 2>&1
	return $?
}

_relationship_batch_alias_duplicate() {
	local payload="$1" alias_name="$2"
	printf '%s' "$payload" | jq -e --arg alias "$alias_name" '
		any(.errors[]?;
			((.path[0] // "") == $alias) and
			((.message // "") | test("already been taken"; "i"))))
	' >/dev/null 2>&1
	return $?
}

_relationship_batch_alias_failure() {
	local payload="$1" alias_name="$2" scoped_result=""
	if ! scoped_result=$(printf '%s' "$payload" | jq -c --arg alias "$alias_name" '
		[.errors[]? |
			select((((.path // []) | length) == 0) or ((.path[0] // "") == $alias))] |
		if length > 0 then {errors: .} else empty end
	' 2>/dev/null); then
		scoped_result="$payload"
	fi
	printf '%s' "$scoped_result"
	return 0
}

_relationship_batch_query() {
	local pair_count="$1"
	local declarations="" fields="" index=0
	for ((index = 0; index < pair_count; index++)); do
		declarations="${declarations}${declarations:+,}\$blocked${index}:ID!,\$blocking${index}:ID!"
		fields="${fields} e${index}:addBlockedBy(input:{issueId:\$blocked${index},blockingIssueId:\$blocking${index}}){issue{number}}"
	done
	printf 'mutation(%s){%s }\n' "$declarations" "$fields"
	return 0
}

_relationship_snapshot_alias_index() {
	local target_index="$1"
	shift
	local pairs=("$@") blocked_id="" index=0
	blocked_id="${pairs[target_index]%%|*}"
	for ((index = 0; index < target_index; index++)); do
		if [[ "${pairs[index]%%|*}" == "$blocked_id" ]]; then
			printf '%s\n' "$index"
			return 0
		fi
	done
	printf '%s\n' "$target_index"
	return 0
}

_relationship_snapshot_query() {
	local pairs=("$@") declarations="" fields="" index=0 alias_index=0
	for ((index = 0; index < ${#pairs[@]}; index++)); do
		alias_index=$(_relationship_snapshot_alias_index "$index" "${pairs[@]}")
		[[ "$alias_index" -eq "$index" ]] || continue
		declarations="${declarations}${declarations:+,}\$blocked${alias_index}:ID!"
		fields="${fields} q${alias_index}:node(id:\$blocked${alias_index}){... on Issue{blockedBy(first:100){nodes{id} pageInfo{hasNextPage}}}}"
	done
	printf 'query(%s){%s rateLimit{cost}}\n' "$declarations" "$fields"
	return 0
}

_relationship_fetch_batch_snapshot() {
	local operation_class="$1"
	shift
	local pairs=("$@")
	local query="" triple="" payload="" reported_cost=""
	local blocked_id blocking_id blocked_num
	local index=0 alias_index=0 snapshot_args=()
	query=$(_relationship_snapshot_query "${pairs[@]}") || return 2
	for ((index = 0; index < ${#pairs[@]}; index++)); do
		triple="${pairs[index]}"
		IFS='|' read -r blocked_id blocking_id blocked_num <<<"$triple"
		alias_index=$(_relationship_snapshot_alias_index "$index" "${pairs[@]}")
		[[ "$alias_index" -eq "$index" ]] || continue
		snapshot_args+=(-f "blocked${alias_index}=${blocked_id}")
	done
	payload=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-blocked-by-batch-read-exact-cost" \
		_relationship_run_timed "$operation_class" _gh_with_timeout read gh api graphql \
		-f query="$query" "${snapshot_args[@]}" 2>/dev/null) || return 2
	reported_cost=$(printf '%s' "$payload" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || reported_cost=""
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 2
	printf '%s\n' "$payload"
	return 0
}

_relationship_batch_snapshot_contains() {
	local payload="$1" index="$2" blocking_id="$3"
	local alias_name="q${index}" contains="" has_next=""
	contains=$(printf '%s' "$payload" | jq -r --arg alias "$alias_name" --arg id "$blocking_id" \
		'any(.data[$alias].blockedBy.nodes[]?; .id == $id)' 2>/dev/null) || return 2
	[[ "$contains" == "$_REL_BATCH_JSON_TRUE" ]] && return 0
	has_next=$(printf '%s' "$payload" | jq -r --arg alias "$alias_name" \
		'.data[$alias].blockedBy.pageInfo.hasNextPage | if type == "boolean" then tostring else "unknown" end' \
		2>/dev/null) || return 2
	[[ "$has_next" == "false" ]] && return 1
	return 2
}

_relationship_apply_batch_chunk() {
	local repo="$1"
	shift
	local pairs=("$@")
	local pair_count="${#pairs[@]}" query="" result="" mutation_rc=0
	local verify_payload="" verify_rc=0 index=0 alias_index=0 triple="" contains_rc=0 alias_result=""
	local blocked_id blocking_id blocked_num
	local rels_set=0 retryable_errors=0 alias_name="" alias_success=false alias_duplicate=false
	local mutation_args=()
	query=$(_relationship_batch_query "$pair_count") || return 1
	for ((index = 0; index < pair_count; index++)); do
		triple="${pairs[index]}"
		IFS='|' read -r blocked_id blocking_id blocked_num <<<"$triple"
		mutation_args+=(-f "blocked${index}=${blocked_id}" -f "blocking${index}=${blocking_id}")
	done
	if _relationship_deadline_expired; then
		for ((index = 0; index < pair_count; index++)); do
			_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
		done
		printf '0:%s\n' "$pair_count"
		return 0
	fi
	result=$(AIDEVOPS_GH_QUOTA_COST="$pair_count" \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-add-blocked-by-batch-exact-cost" \
		_relationship_run_timed mutation _gh_with_timeout write gh api graphql \
		-f query="$query" "${mutation_args[@]}" 2>&1) || mutation_rc=$?
	verify_payload=$(_relationship_fetch_batch_snapshot verify "${pairs[@]}") || verify_rc=$?
	for ((index = 0; index < pair_count; index++)); do
		triple="${pairs[index]}"
		IFS='|' read -r blocked_id blocking_id blocked_num <<<"$triple"
		alias_name="e${index}"
		alias_index=$(_relationship_snapshot_alias_index "$index" "${pairs[@]}")
		alias_success=false
		alias_duplicate=false
		_relationship_batch_alias_success "$result" "$alias_name" && alias_success=true
		_relationship_batch_alias_duplicate "$result" "$alias_name" && alias_duplicate=true
		contains_rc="$verify_rc"
		if [[ "$verify_rc" -eq 0 ]]; then
			_relationship_batch_snapshot_contains "$verify_payload" "$alias_index" "$blocking_id" || contains_rc=$?
		fi
		if [[ "$alias_success" == "$_REL_BATCH_JSON_TRUE" ]]; then
			_relationship_record_outcome "$_REL_OUTCOME_CREATED"
		elif [[ "$alias_duplicate" == "$_REL_BATCH_JSON_TRUE" || "$contains_rc" -eq 0 ]]; then
			_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
		else
			alias_result=$(_relationship_batch_alias_failure "$result" "$alias_name")
			_relationship_record_mutation_failure "$mutation_rc" "$alias_result"
			retryable_errors=$((retryable_errors + 1))
			_hold_dependency_sync_retry "$blocked_num" "$repo" "native_relationship_batch_failed"
			continue
		fi
		rels_set=$((rels_set + 1))
		if ! _ensure_dependency_status_blocked "$blocked_num" "$repo" "native_relationship_linked"; then
			retryable_errors=$((retryable_errors + 1))
		fi
	done
	printf '%s:%s\n' "$rels_set" "$retryable_errors"
	return 0
}

_relationship_plan_batch_chunk() {
	local repo="$1"
	shift
	local pairs=("$@") payload="" result="" triple=""
	local blocked_id blocking_id blocked_num
	local snapshot_rc=0 contains_rc=0 index=0 alias_index=0 rels_set=0 retryable_errors=0 batch_rels=0 batch_errors=0
	local missing_pairs=()
	payload=$(_relationship_fetch_batch_snapshot snapshot "${pairs[@]}") || snapshot_rc=$?
	for ((index = 0; index < ${#pairs[@]}; index++)); do
		triple="${pairs[index]}"
		IFS='|' read -r blocked_id blocking_id blocked_num <<<"$triple"
		contains_rc="$snapshot_rc"
		if [[ "$snapshot_rc" -eq 0 ]]; then
			alias_index=$(_relationship_snapshot_alias_index "$index" "${pairs[@]}")
			_relationship_batch_snapshot_contains "$payload" "$alias_index" "$blocking_id" || contains_rc=$?
		fi
		case "$contains_rc" in
		0)
			_relationship_record_outcome "$_REL_OUTCOME_ALREADY_PRESENT"
			rels_set=$((rels_set + 1))
			_ensure_dependency_status_blocked "$blocked_num" "$repo" "native_relationship_already_present" || \
				retryable_errors=$((retryable_errors + 1))
			;;
		1) missing_pairs+=("$triple") ;;
		*)
			_relationship_record_outcome "$_REL_OUTCOME_FAILED_RESOLUTION"
			retryable_errors=$((retryable_errors + 1))
			_hold_dependency_sync_retry "$blocked_num" "$repo" "native_relationship_read_failed"
			;;
		esac
	done
	if [[ ${#missing_pairs[@]} -gt 0 ]]; then
		result=$(_relationship_apply_batch_chunk "$repo" "${missing_pairs[@]}")
		IFS=':' read -r batch_rels batch_errors <<<"$result"
		rels_set=$((rels_set + batch_rels))
		retryable_errors=$((retryable_errors + batch_errors))
	fi
	printf '%s:%s\n' "$rels_set" "$retryable_errors"
	return 0
}

_relationship_apply_planned_batches() {
	local repo="$1"
	shift
	local pairs=("$@") batch_size="${AIDEVOPS_RELATIONSHIP_MUTATION_BATCH_SIZE:-20}"
	local offset=0 result="" chunk_rels=0 chunk_errors=0 rels_set=0 retryable_errors=0
	[[ "$batch_size" =~ ^[1-9][0-9]*$ && "$batch_size" -le 20 ]] || batch_size=20
	while [[ "$offset" -lt "${#pairs[@]}" ]]; do
		if _relationship_deadline_expired; then
			for ((; offset < ${#pairs[@]}; offset++)); do
				_relationship_record_outcome "$_REL_OUTCOME_DEFERRED_DEADLINE"
				retryable_errors=$((retryable_errors + 1))
			done
			break
		fi
		result=$(_relationship_plan_batch_chunk "$repo" "${pairs[@]:offset:batch_size}")
		IFS=':' read -r chunk_rels chunk_errors <<<"$result"
		rels_set=$((rels_set + chunk_rels))
		retryable_errors=$((retryable_errors + chunk_errors))
		offset=$((offset + batch_size))
	done
	printf '%s:%s\n' "$rels_set" "$retryable_errors"
	return 0
}
