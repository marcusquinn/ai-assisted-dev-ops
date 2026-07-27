#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Durable, external lifecycle receipts for owner-safe full-loop cleanup.
# The receipt survives removal of the linked worktree and lets a later guarded
# cleanup process assume the lease and record the terminal CLEANED transition.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_FULL_LOOP_CLEANUP_RECEIPT_LOADED:-}" ]] && return 0
_FULL_LOOP_CLEANUP_RECEIPT_LOADED=1

_FULL_LOOP_CLEANUP_DEFERRED="CLEANUP_DEFERRED"
_FULL_LOOP_CLEANUP_LEASED="CLEANUP_LEASED"
_FULL_LOOP_CLEANUP_CLEANED="CLEANED"
_FULL_LOOP_EXECUTOR_COMPLETE="COMPLETE"
_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED="published"
_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED="not-requested"
_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED="superseded"
_FULL_LOOP_RECEIPT_LOCK=""

_full_loop_validate_aggregate_evidence() {
	local evidence_path="$1"
	local repo="$2"
	local pr_number="$3"
	jq -e --arg repo "$repo" --arg status "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" --argjson pr "$pr_number" \
		'.repository == $repo and .pr_number == $pr and .status == $status' "$evidence_path" >/dev/null 2>&1
	return $?
}

_full_loop_prepare_migrated_aggregate_evidence() {
	local source_aggregate="$1"
	local destination_aggregate="$2"
	local old_repo="$3"
	local new_repo="$4"
	local now="$5"
	jq --arg repo "$new_repo" --arg old_repo "$old_repo" --arg now "$now" '
		.repository = $repo
		| .migration = {from_repository:$old_repo,to_repository:$repo,migrated_at:$now}
	' "$source_aggregate" >"${destination_aggregate}.tmp.$$"
	return $?
}

_full_loop_migrated_destination_matches() {
	local destination_receipt="$1"
	local destination_release="$2"
	local destination_aggregate="$3"
	local new_repo="$4"
	local old_repo="$5"
	local pr_number="$6"
	local release_status="$7"
	local destination_status=""
	[[ -f "$destination_release" ]] && IFS= read -r destination_status <"$destination_release" || true
	jq -e --arg repo "$new_repo" --arg old_repo "$old_repo" --argjson pr "$pr_number" '
		.repository == $repo and .pr_number == $pr and .migration.from_repository == $old_repo
	' "$destination_receipt" >/dev/null 2>&1 || return 1
	[[ "$destination_status" == "$release_status" ]] || return 1
	[[ "$release_status" != "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" ]] ||
		_full_loop_validate_aggregate_evidence "$destination_aggregate" "$new_repo" "$pr_number"
	return $?
}

_full_loop_migration_source_matches() {
	local source_receipt="$1"
	local source_release="$2"
	local source_aggregate="$3"
	local old_repo="$4"
	local pr_number="$5"
	local release_status="$6"
	local source_status=""
	[[ -f "$source_receipt" && -f "$source_release" ]] || return 1
	jq -e --arg repo "$old_repo" --argjson pr "$pr_number" \
		'.repository == $repo and .pr_number == $pr' "$source_receipt" >/dev/null 2>&1 || return 1
	IFS= read -r source_status <"$source_release" || return 1
	[[ "$source_status" == "$release_status" ]] || return 1
	[[ "$release_status" != "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" ]] ||
		_full_loop_validate_aggregate_evidence "$source_aggregate" "$old_repo" "$pr_number"
	return $?
}

_full_loop_cleanup_receipt_dir() {
	printf '%s\n' "${AIDEVOPS_FULL_LOOP_CLEANUP_DIR:-${HOME}/.aidevops/state/full-loop-cleanup}"
	return 0
}

_full_loop_cleanup_receipt_path() {
	local repo="$1"
	local pr_number="$2"
	local receipt_dir=""
	local safe_repo="${repo//\//_}"

	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 1
	printf '%s/%s-%s.json\n' "$receipt_dir" "$safe_repo" "$pr_number"
	return 0
}

_full_loop_process_identity() {
	local owner_pid="$1"
	local identity=""

	[[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	identity=$(ps -p "$owner_pid" -o lstart= 2>/dev/null || true)
	[[ -n "$identity" ]] || return 1
	printf '%s\n' "$identity"
	return 0
}

_full_loop_receipt_lock_acquire() {
	local receipt_dir=""
	local lock_dir=""
	local owner_pid=""
	local attempt=0
	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 1
	mkdir -p "$receipt_dir" || return 1
	lock_dir="${receipt_dir}/.mutation.lock.d"
	while [[ "$attempt" -lt 200 ]]; do
		if mkdir "$lock_dir" 2>/dev/null; then
			printf '%s\n' "$$" >"${lock_dir}/owner" || {
				rmdir "$lock_dir" 2>/dev/null || true
				return 1
			}
			_FULL_LOOP_RECEIPT_LOCK="$lock_dir"
			return 0
		fi
		owner_pid=""
		[[ -f "${lock_dir}/owner" ]] && IFS= read -r owner_pid <"${lock_dir}/owner" || true
		if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
			rm -f "${lock_dir}/owner" 2>/dev/null || true
			rmdir "$lock_dir" 2>/dev/null || true
			continue
		fi
		sleep 0.05
		attempt=$((attempt + 1))
	done
	return 1
}

_full_loop_receipt_lock_release() {
	[[ -n "$_FULL_LOOP_RECEIPT_LOCK" ]] || return 0
	rm -f "${_FULL_LOOP_RECEIPT_LOCK}/owner" 2>/dev/null || true
	rmdir "$_FULL_LOOP_RECEIPT_LOCK" 2>/dev/null || true
	_FULL_LOOP_RECEIPT_LOCK=""
	return 0
}

full_loop_write_cleanup_deferred() {
	local repo="$1"
	local pr_number="$2"
	local worktree="$3"
	local branch="$4"
	local owner_pid="$5"
	local owner_session="$6"
	local release_status="${7:-pending}"
	local executor_completion_state="${8:-$_FULL_LOOP_EXECUTOR_COMPLETE}"
	local receipt_path=""
	local owner_identity=""
	local now=""

	[[ -n "$worktree" && -n "$branch" && "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	[[ "$executor_completion_state" == "FINALIZATION_PENDING" || "$executor_completion_state" == "$_FULL_LOOP_EXECUTOR_COMPLETE" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	owner_identity=$(_full_loop_process_identity "$owner_pid") || return 1
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${receipt_path%/*}" || return 1
	jq -cn \
		--arg repo "$repo" --argjson pr_number "$pr_number" \
		--arg worktree "$worktree" --arg branch "$branch" \
		--argjson owner_pid "$owner_pid" --arg owner_identity "$owner_identity" \
		--arg owner_session "$owner_session" --arg release_status "$release_status" \
		--arg executor_completion_state "$executor_completion_state" \
		--arg state "$_FULL_LOOP_CLEANUP_DEFERRED" --arg now "$now" \
		'{schema_version:1,repository:$repo,pr_number:$pr_number,worktree:$worktree,branch:$branch,
		  executor_completion_state:$executor_completion_state,resource_cleanup_state:$state,release_status:$release_status,
		  owner:{pid:$owner_pid,process_identity:$owner_identity,session:$owner_session},
		  cleanup_lease:{state:"pending",pid:null,acquired_at:null},created_at:$now,updated_at:$now,cleaned_at:null}' \
		>"${receipt_path}.tmp.$$" || return 1
	mv "${receipt_path}.tmp.$$" "$receipt_path" || return 1
	printf '%s\n' "$receipt_path"
	return 0
}

full_loop_cleanup_receipt_for_worktree() {
	local worktree="$1"
	local receipt_dir=""
	local receipt_path=""
	local selected_path=""
	local selected_created_at=""
	local candidate_created_at=""
	local selected_is_migrated=0
	local candidate_is_migrated=0

	[[ -n "$worktree" ]] || return 1
	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 1
	[[ -d "$receipt_dir" ]] || return 1
	for receipt_path in "$receipt_dir"/*.json; do
		[[ -f "$receipt_path" ]] || continue
		if jq -e --arg worktree "$worktree" '.worktree == $worktree' "$receipt_path" >/dev/null 2>&1; then
			candidate_created_at=$(jq -r '.created_at // empty' "$receipt_path" 2>/dev/null || true)
			candidate_is_migrated=0
			jq -e '.migration.from_repository | type == "string" and length > 0' "$receipt_path" >/dev/null 2>&1 && candidate_is_migrated=1
			if [[ -z "$selected_path" || "$candidate_created_at" > "$selected_created_at" ]] ||
				[[ "$candidate_created_at" == "$selected_created_at" && "$candidate_is_migrated" -eq 1 && "$selected_is_migrated" -ne 1 ]]; then
				selected_path="$receipt_path"
				selected_created_at="$candidate_created_at"
				selected_is_migrated="$candidate_is_migrated"
			fi
		fi
	done
	[[ -n "$selected_path" ]] || return 1
	printf '%s\n' "$selected_path"
	return 0
}

full_loop_cleanup_owner_alive() {
	local receipt_path="$1"
	local owner_pid=""
	local expected_identity=""
	local observed_identity=""

	[[ -f "$receipt_path" ]] || return 1
	owner_pid=$(jq -r '.owner.pid // empty' "$receipt_path" 2>/dev/null || true)
	expected_identity=$(jq -r '.owner.process_identity // empty' "$receipt_path" 2>/dev/null || true)
	[[ "$owner_pid" =~ ^[0-9]+$ && -n "$expected_identity" ]] || return 1
	kill -0 "$owner_pid" 2>/dev/null || return 1
	observed_identity=$(_full_loop_process_identity "$owner_pid") || return 1
	[[ "$observed_identity" == "$expected_identity" ]] || return 1
	return 0
}

full_loop_transition_cleanup_receipt() {
	local receipt_path="$1"
	local target_state="$2"
	local lease_pid="${3:-}"
	local current_state=""
	local now=""

	[[ -f "$receipt_path" ]] || return 1
	_full_loop_receipt_lock_acquire || return 1
	case "$target_state" in
	"$_FULL_LOOP_CLEANUP_DEFERRED" | "$_FULL_LOOP_CLEANUP_LEASED" | "$_FULL_LOOP_CLEANUP_CLEANED") ;;
	*)
		_full_loop_receipt_lock_release
		return 1
		;;
	esac
	current_state=$(jq -r '.resource_cleanup_state // empty' "$receipt_path" 2>/dev/null || true)
	case "${current_state}:${target_state}" in
	"${_FULL_LOOP_CLEANUP_DEFERRED}:${_FULL_LOOP_CLEANUP_DEFERRED}" | \
		"${_FULL_LOOP_CLEANUP_DEFERRED}:${_FULL_LOOP_CLEANUP_LEASED}" | \
		"${_FULL_LOOP_CLEANUP_DEFERRED}:${_FULL_LOOP_CLEANUP_CLEANED}" | \
		"${_FULL_LOOP_CLEANUP_LEASED}:${_FULL_LOOP_CLEANUP_LEASED}" | \
		"${_FULL_LOOP_CLEANUP_LEASED}:${_FULL_LOOP_CLEANUP_CLEANED}" | \
		"${_FULL_LOOP_CLEANUP_CLEANED}:${_FULL_LOOP_CLEANUP_CLEANED}") ;;
	*)
		_full_loop_receipt_lock_release
		return 1
		;;
	esac
	if [[ "$target_state" == "$_FULL_LOOP_CLEANUP_LEASED" ]]; then
		if [[ ! "$lease_pid" =~ ^[0-9]+$ ]]; then
			_full_loop_receipt_lock_release
			return 1
		fi
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
		_full_loop_receipt_lock_release
		return 1
	}
	jq --arg state "$target_state" --arg now "$now" --arg lease_pid "$lease_pid" '
		.resource_cleanup_state = $state
		| .updated_at = $now
		| if $state == "CLEANUP_LEASED" then
			.cleanup_lease = {state:"acquired",pid:($lease_pid | tonumber),acquired_at:$now}
		  elif $state == "CLEANED" then
			.cleanup_lease.state = "released" | .cleaned_at = $now
		  else . end
	' "$receipt_path" >"${receipt_path}.tmp.$$" || {
		_full_loop_receipt_lock_release
		return 1
	}
	mv "${receipt_path}.tmp.$$" "$receipt_path" || {
		_full_loop_receipt_lock_release
		return 1
	}
	_full_loop_receipt_lock_release
	return 0
}

full_loop_finalize_cleanup_receipt() {
	local repo="$1"
	local pr_number="$2"
	local release_status="$3"
	local receipt_path=""
	local current_release=""
	local current_executor=""
	local now=""
	[[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED" ]] || return 1
	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	_full_loop_receipt_lock_acquire || return 1
	if ! jq -e --arg repo "$repo" --argjson pr "$pr_number" \
		'.repository == $repo and .pr_number == $pr' "$receipt_path" >/dev/null 2>&1; then
		_full_loop_receipt_lock_release
		return 1
	fi
	current_executor=$(jq -r '.executor_completion_state // empty' "$receipt_path" 2>/dev/null || true)
	current_release=$(jq -r '.release_status // empty' "$receipt_path" 2>/dev/null || true)
	if [[ "$current_executor" != "FINALIZATION_PENDING" && "$current_executor" != "$_FULL_LOOP_EXECUTOR_COMPLETE" ]]; then
		_full_loop_receipt_lock_release
		return 1
	fi
	if [[ "$current_release" == "$_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED" || "$current_release" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" || "$current_release" == "$_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED" ]] &&
		[[ "$current_release" != "$release_status" ]]; then
		_full_loop_receipt_lock_release
		return 1
	fi
	if [[ "$current_executor" == "$_FULL_LOOP_EXECUTOR_COMPLETE" && "$current_release" == "$release_status" ]]; then
		_full_loop_receipt_lock_release
		return 0
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
		_full_loop_receipt_lock_release
		return 1
	}
	jq --arg release_status "$release_status" --arg now "$now" --arg executor_complete "$_FULL_LOOP_EXECUTOR_COMPLETE" '
		.executor_completion_state = $executor_complete
		| .release_status = $release_status
		| .updated_at = $now
	' "$receipt_path" >"${receipt_path}.tmp.$$" || {
		_full_loop_receipt_lock_release
		return 1
	}
	mv "${receipt_path}.tmp.$$" "$receipt_path" || {
		_full_loop_receipt_lock_release
		return 1
	}
	_full_loop_receipt_lock_release
	return 0
}

full_loop_migrate_cleanup_receipt() {
	local old_repo="$1"
	local new_repo="$2"
	local pr_number="$3"
	local source_release="$4"
	local destination_release="$5"
	local release_status="$6"
	local source_receipt=""
	local destination_receipt=""
	local source_aggregate="${source_release%.status}.aggregate.json"
	local destination_aggregate="${destination_release%.status}.aggregate.json"
	local now=""
	[[ "$old_repo" != "$new_repo" ]] || return 1
	[[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED" ]] || return 1
	source_receipt=$(_full_loop_cleanup_receipt_path "$old_repo" "$pr_number") || return 1
	destination_receipt=$(_full_loop_cleanup_receipt_path "$new_repo" "$pr_number") || return 1
	_full_loop_receipt_lock_acquire || return 1

	if [[ -f "$destination_receipt" ]]; then
		if _full_loop_migrated_destination_matches "$destination_receipt" "$destination_release" "$destination_aggregate" \
			"$new_repo" "$old_repo" "$pr_number" "$release_status"; then
			if [[ -f "$source_receipt" ]] && jq -e --slurpfile destination "$destination_receipt" '
				.worktree == $destination[0].worktree
				and .branch == $destination[0].branch
				and .created_at == $destination[0].created_at
				and .owner.process_identity == $destination[0].owner.process_identity
			' "$source_receipt" >/dev/null 2>&1; then
				rm -f "$source_release" "$source_receipt" "$source_aggregate"
			fi
			_full_loop_receipt_lock_release
			return 0
		fi
		_full_loop_receipt_lock_release
		return 1
	fi
	if ! _full_loop_migration_source_matches "$source_receipt" "$source_release" "$source_aggregate" \
		"$old_repo" "$pr_number" "$release_status"; then
		_full_loop_receipt_lock_release
		return 1
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
		_full_loop_receipt_lock_release
		return 1
	}
	mkdir -p "${destination_release%/*}" || {
		_full_loop_receipt_lock_release
		return 1
	}
	jq --arg repo "$new_repo" --arg old_repo "$old_repo" --arg now "$now" '
		.repository = $repo
		| .updated_at = $now
		| .migration = {from_repository:$old_repo,to_repository:$repo,migrated_at:$now}
	' "$source_receipt" >"${destination_receipt}.tmp.$$" || {
		_full_loop_receipt_lock_release
		return 1
	}
	printf '%s\n' "$release_status" >"${destination_release}.tmp.$$" || {
		rm -f "${destination_receipt}.tmp.$$"
		_full_loop_receipt_lock_release
		return 1
	}
	if [[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" ]]; then
		_full_loop_prepare_migrated_aggregate_evidence \
			"$source_aggregate" "$destination_aggregate" "$old_repo" "$new_repo" "$now" || {
			rm -f "${destination_receipt}.tmp.$$" "${destination_release}.tmp.$$"
			_full_loop_receipt_lock_release
			return 1
		}
		mv "${destination_aggregate}.tmp.$$" "$destination_aggregate" || {
			rm -f "${destination_receipt}.tmp.$$" "${destination_release}.tmp.$$"
			_full_loop_receipt_lock_release
			return 1
		}
	fi
	mv "${destination_receipt}.tmp.$$" "$destination_receipt" || {
		rm -f "${destination_release}.tmp.$$"
		rm -f "$destination_aggregate"
		_full_loop_receipt_lock_release
		return 1
	}
	if ! mv "${destination_release}.tmp.$$" "$destination_release"; then
		rm -f "$destination_receipt" "$destination_aggregate"
		_full_loop_receipt_lock_release
		return 1
	fi
	rm -f "$source_release" "$source_receipt" "$source_aggregate" || {
		_full_loop_receipt_lock_release
		return 1
	}
	_full_loop_receipt_lock_release
	return 0
}

full_loop_update_cleanup_release_status() {
	local repo="$1"
	local pr_number="$2"
	local release_status="$3"
	local receipt_path=""
	local now=""

	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 0
	_full_loop_receipt_lock_acquire || return 1
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
		_full_loop_receipt_lock_release
		return 1
	}
	jq --arg release_status "$release_status" --arg now "$now" \
		'.release_status = $release_status | .updated_at = $now' \
		"$receipt_path" >"${receipt_path}.tmp.$$" || {
		_full_loop_receipt_lock_release
		return 1
	}
	mv "${receipt_path}.tmp.$$" "$receipt_path" || {
		_full_loop_receipt_lock_release
		return 1
	}
	_full_loop_receipt_lock_release
	return 0
}

full_loop_mark_cleanup_cleaned_for_worktree() {
	local worktree="$1"
	local cleanup_log="${2:-${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}}"
	local receipt_path=""

	[[ -n "$worktree" && ! -e "$worktree" && -f "$cleanup_log" ]] || return 1
	grep -Fq "worktree-removed: ${worktree} —" "$cleanup_log" || return 1
	receipt_path=$(full_loop_cleanup_receipt_for_worktree "$worktree") || return 1
	full_loop_transition_cleanup_receipt "$receipt_path" "$_FULL_LOOP_CLEANUP_CLEANED"
	return $?
}

full_loop_reconcile_cleanup_receipts() {
	local receipt_dir=""
	local receipt_path=""
	local worktree=""
	local state=""
	local cleanup_log="${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}"

	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 0
	[[ -d "$receipt_dir" && -f "$cleanup_log" ]] || return 0
	for receipt_path in "$receipt_dir"/*.json; do
		[[ -f "$receipt_path" ]] || continue
		state=$(jq -r '.resource_cleanup_state // empty' "$receipt_path" 2>/dev/null || true)
		[[ "$state" != "$_FULL_LOOP_CLEANUP_CLEANED" ]] || continue
		worktree=$(jq -r '.worktree // empty' "$receipt_path" 2>/dev/null || true)
		[[ -n "$worktree" && ! -e "$worktree" ]] || continue
		grep -Fq "worktree-removed: ${worktree} —" "$cleanup_log" || continue
		full_loop_transition_cleanup_receipt "$receipt_path" "$_FULL_LOOP_CLEANUP_CLEANED" || true
	done
	return 0
}
