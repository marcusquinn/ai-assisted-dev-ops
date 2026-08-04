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
_FULL_LOOP_EXECUTOR_FINALIZATION_PENDING="FINALIZATION_PENDING"
_FULL_LOOP_CLEANUP_LEASE_PENDING="pending"
_FULL_LOOP_OWNER_SESSION_FALLBACK="full-loop-lifecycle"
_FULL_LOOP_RECEIPT_RELEASE_AUTHORIZED="authorized"
_FULL_LOOP_RECEIPT_RELEASE_PENDING="$_FULL_LOOP_CLEANUP_LEASE_PENDING"
_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED="published"
_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED="not-requested"
_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED="superseded"
_FULL_LOOP_RECEIPT_PATH_RECREATED="SUPERSEDED_BY_PATH_RECREATION"
_FULL_LOOP_RECEIPT_JSON_NUMBER_TYPE="number"
_FULL_LOOP_RECEIPT_JSON_STRING_TYPE="string"
_FULL_LOOP_RECEIPT_SHA40_REGEX='^[0-9a-f]{40}$'
_FULL_LOOP_RECEIPT_TIMESTAMP_REGEX='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
_FULL_LOOP_RECEIPT_VERSION_TAG_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+$'
_FULL_LOOP_RECREATED_RECEIPT_TRANSACTION_SCHEMA="aidevops.full-loop.recreated-receipts.transaction/v1"
_FULL_LOOP_RECEIPT_LOCK=""
_FULL_LOOP_CLEANUP_OWNER_PID=""

_full_loop_validate_superseded_evidence() {
	local evidence_path="$1"
	local repo="$2"
	local pr_number="$3"
	local evidence_kind=""
	case "$evidence_path" in
	*.aggregate.json) evidence_kind="aggregate" ;;
	*.successor.json) evidence_kind="successor" ;;
	*) return 1 ;;
	esac
	jq -e --arg repo "$repo" --arg status "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" \
		--arg evidence_kind "$evidence_kind" --arg sha_regex "$_FULL_LOOP_RECEIPT_SHA40_REGEX" \
		--arg tag_regex "$_FULL_LOOP_RECEIPT_VERSION_TAG_REGEX" \
		--arg timestamp_regex "$_FULL_LOOP_RECEIPT_TIMESTAMP_REGEX" \
		--arg number_type "$_FULL_LOOP_RECEIPT_JSON_NUMBER_TYPE" \
		--arg string_type "$_FULL_LOOP_RECEIPT_JSON_STRING_TYPE" --argjson pr "$pr_number" '
		. as $e
		| $e.repository == $repo and $e.pr_number == $pr and $e.status == $status
		and ($e.recorded_at | type == $string_type and test($timestamp_regex))
		and if $evidence_kind == "aggregate" then
			$e.schema_version == 1
			and ($e.source_merge | type == $string_type and test($sha_regex))
			and ($e.aggregate_pr | type == $number_type and . > 0 and floor == .)
			and ($e.aggregate_merge | type == $string_type and test($sha_regex))
			and ($e.release_tag | type == $string_type and test($tag_regex))
			and ($e.release_commit | type == $string_type and test($sha_regex))
		else $e.source_pr == $pr
			and ($e.source_merge | type == $string_type and test($sha_regex))
			and ($e.source_release_tag | type == $string_type and test($tag_regex))
			and ($e.source_release_commit | type == $string_type and test($sha_regex))
			and ($e.successor_pr | type == $number_type and . > 0 and floor == . and . != $pr)
			and ($e.successor_merge | type == $string_type and test($sha_regex))
			and ($e.release_tag | type == $string_type and test($tag_regex))
			and $e.release_tag != $e.source_release_tag
			and ($e.release_commit | type == $string_type and test($sha_regex))
			and $e.release_commit != $e.source_release_commit
			and ($e.release_workflow_run | type == $number_type and . > 0 and floor == .)
			and if $e.schema_version == 1 and $e.evidence_type == "post-publication-supersession" then
				($e.source_workflow_run | type == $number_type and . > 0 and floor == .)
				and $e.release_workflow_run != $e.source_workflow_run
			else $e.schema_version == 2 and $e.evidence_type == "protected-predecessor-supersession"
				and ($e.source_release_tag_object | type == $string_type and test($sha_regex))
				and ($e.source_protected_pr | type == $number_type and . > 0 and floor == .)
				and ($e.source_protected_pr_head | type == $string_type and test($sha_regex))
				and ($e.source_protected_pr_merged_at | type == $string_type and test($timestamp_regex))
			end
		end
	' "$evidence_path" >/dev/null 2>&1
	return $?
}

_full_loop_superseded_migration_evidence_path() {
	local release_path="$1"
	local repo="$2"
	local pr_number="$3"
	local aggregate_path="${release_path%.status}.aggregate.json"
	local successor_path="${release_path%.status}.successor.json"
	local evidence_path=""
	if [[ -f "$aggregate_path" ]]; then
		_full_loop_validate_superseded_evidence "$aggregate_path" "$repo" "$pr_number" || return 1
		evidence_path="$aggregate_path"
	fi
	if [[ -f "$successor_path" ]]; then
		[[ -z "$evidence_path" ]] || return 1
		_full_loop_validate_superseded_evidence "$successor_path" "$repo" "$pr_number" || return 1
		evidence_path="$successor_path"
	fi
	[[ -n "$evidence_path" ]] || return 1
	printf '%s\n' "$evidence_path"
	return 0
}

_full_loop_prepare_migrated_superseded_evidence() {
	local source_evidence="$1"
	local destination_evidence="$2"
	local old_repo="$3"
	local new_repo="$4"
	local now="$5"
	jq --arg repo "$new_repo" --arg old_repo "$old_repo" --arg now "$now" '
		.repository = $repo
		| .migration = {from_repository:$old_repo,to_repository:$repo,migrated_at:$now}
	' "$source_evidence" >"${destination_evidence}.tmp.$$"
	return $?
}

_full_loop_migrated_cleanup_receipt_matches_source() {
	local source_receipt="$1"
	local destination_receipt="$2"
	local old_repo="$3"
	local new_repo="$4"
	local pr_number="$5"
	[[ -f "$source_receipt" && ! -L "$source_receipt" ]] || return 1
	[[ -f "$destination_receipt" && ! -L "$destination_receipt" ]] || return 1
	jq -e --slurpfile destination "$destination_receipt" \
		--arg old_repo "$old_repo" --arg new_repo "$new_repo" \
		--arg string_type "$_FULL_LOOP_RECEIPT_JSON_STRING_TYPE" \
		--arg timestamp_regex "$_FULL_LOOP_RECEIPT_TIMESTAMP_REGEX" --argjson pr "$pr_number" '
		.repository == $old_repo and .pr_number == $pr
		and ($destination | length) == 1
		and $destination[0].repository == $new_repo and $destination[0].pr_number == $pr
		and $destination[0].migration.from_repository == $old_repo
		and $destination[0].migration.to_repository == $new_repo
		and ($destination[0].migration.migrated_at | type == $string_type and test($timestamp_regex))
		and (del(.repository,.updated_at,.migration)
			== ($destination[0] | del(.repository,.updated_at,.migration)))
	' "$source_receipt" >/dev/null 2>&1
	return $?
}

_full_loop_migrated_evidence_matches_source() {
	local source_evidence="$1"
	local destination_evidence="$2"
	local old_repo="$3"
	local new_repo="$4"
	local pr_number="$5"
	_full_loop_validate_superseded_evidence "$source_evidence" "$old_repo" "$pr_number" || return 1
	_full_loop_validate_superseded_evidence "$destination_evidence" "$new_repo" "$pr_number" || return 1
	jq -e --slurpfile destination "$destination_evidence" \
		--arg old_repo "$old_repo" --arg new_repo "$new_repo" \
		--arg string_type "$_FULL_LOOP_RECEIPT_JSON_STRING_TYPE" \
		--arg timestamp_regex "$_FULL_LOOP_RECEIPT_TIMESTAMP_REGEX" '
		($destination | length) == 1
		and $destination[0].migration.from_repository == $old_repo
		and $destination[0].migration.to_repository == $new_repo
		and ($destination[0].migration.migrated_at | type == $string_type and test($timestamp_regex))
		and (del(.repository,.migration) == ($destination[0] | del(.repository,.migration)))
	' "$source_evidence" >/dev/null 2>&1
	return $?
}

_full_loop_migrated_destination_matches() {
	local destination_receipt="$1"
	local destination_release="$2"
	local new_repo="$3"
	local old_repo="$4"
	local pr_number="$5"
	local release_status="$6"
	local destination_status=""
	local destination_evidence=""
	local aggregate_path="${destination_release%.status}.aggregate.json"
	local successor_path="${destination_release%.status}.successor.json"
	[[ -f "$destination_receipt" && ! -L "$destination_receipt" ]] || return 1
	[[ -f "$destination_release" && ! -L "$destination_release" ]] || return 1
	IFS= read -r destination_status <"$destination_release" || return 1
	jq -e --arg repo "$new_repo" --arg old_repo "$old_repo" \
		--arg string_type "$_FULL_LOOP_RECEIPT_JSON_STRING_TYPE" \
		--arg timestamp_regex "$_FULL_LOOP_RECEIPT_TIMESTAMP_REGEX" --argjson pr "$pr_number" '
		.repository == $repo and .pr_number == $pr
		and .migration.from_repository == $old_repo and .migration.to_repository == $repo
		and (.migration.migrated_at | type == $string_type and test($timestamp_regex))
	' "$destination_receipt" >/dev/null 2>&1 || return 1
	[[ "$destination_status" == "$release_status" ]] || return 1
	if [[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" ]]; then
		destination_evidence=$(_full_loop_superseded_migration_evidence_path \
			"$destination_release" "$new_repo" "$pr_number") || return 1
		[[ -f "$destination_evidence" && ! -L "$destination_evidence" ]] || return 1
	elif [[ -e "$aggregate_path" || -L "$aggregate_path" || -e "$successor_path" || -L "$successor_path" ]]; then
		return 1
	fi
	return 0
}

_full_loop_migration_source_matches() {
	local source_receipt="$1"
	local source_release="$2"
	local old_repo="$3"
	local pr_number="$4"
	local release_status="$5"
	local source_status=""
	local source_evidence=""
	local aggregate_path="${source_release%.status}.aggregate.json"
	local successor_path="${source_release%.status}.successor.json"
	[[ -f "$source_receipt" && ! -L "$source_receipt" ]] || return 1
	[[ -f "$source_release" && ! -L "$source_release" ]] || return 1
	jq -e --arg repo "$old_repo" --argjson pr "$pr_number" \
		'.repository == $repo and .pr_number == $pr' "$source_receipt" >/dev/null 2>&1 || return 1
	IFS= read -r source_status <"$source_release" || return 1
	[[ "$source_status" == "$release_status" ]] || return 1
	if [[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" ]]; then
		source_evidence=$(_full_loop_superseded_migration_evidence_path \
			"$source_release" "$old_repo" "$pr_number") || return 1
		[[ -f "$source_evidence" && ! -L "$source_evidence" ]] || return 1
	elif [[ -e "$aggregate_path" || -L "$aggregate_path" || -e "$successor_path" || -L "$successor_path" ]]; then
		return 1
	fi
	return 0
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

_full_loop_recreated_receipt_transaction_path_is_safe() {
	local receipt_dir="$1"
	local transaction_dir="$2"

	[[ -n "$receipt_dir" && -n "$transaction_dir" ]] || return 1
	case "$transaction_dir" in
	"${receipt_dir}"/.recreated-receipts.*) ;;
	*) return 1 ;;
	esac
	[[ -d "$transaction_dir" && ! -L "$transaction_dir" ]] || return 1
	return 0
}

_full_loop_remove_recreated_receipt_transaction() {
	local receipt_dir="$1"
	local transaction_dir="$2"

	_full_loop_recreated_receipt_transaction_path_is_safe "$receipt_dir" "$transaction_dir" || return 1
	rm -rf "$transaction_dir" || return 1
	[[ ! -e "$transaction_dir" && ! -L "$transaction_dir" ]] || return 1
	return 0
}

_full_loop_recreated_receipt_transaction_state() {
	local transaction_dir="$1"
	local marker=""
	local marker_path=""
	local selected_state="none"
	local state_count=0

	[[ -d "$transaction_dir" && ! -L "$transaction_dir" ]] || return 1
	for marker in prepared committed rolled-back; do
		marker_path="${transaction_dir}/state.${marker}"
		[[ ! -L "$marker_path" ]] || return 1
		if [[ -f "$marker_path" ]]; then
			selected_state="$marker"
			state_count=$((state_count + 1))
		elif [[ -e "$marker_path" ]]; then
			return 1
		fi
	done
	[[ "$state_count" -le 1 ]] || return 1
	printf '%s\n' "$selected_state"
	return 0
}

_full_loop_recreated_receipt_transaction_schema_matches() {
	local transaction_dir="$1"
	local schema_path="${transaction_dir}/schema"
	local schema=""

	[[ -f "$schema_path" && ! -L "$schema_path" ]] || return 1
	IFS= read -r schema <"$schema_path" || return 1
	[[ "$schema" == "$_FULL_LOOP_RECREATED_RECEIPT_TRANSACTION_SCHEMA" ]] || return 1
	return 0
}

_full_loop_receipt_file_is_json_object() {
	local receipt_path="$1"

	jq -e 'type == "object"' "$receipt_path" >/dev/null 2>&1
	return $?
}

_full_loop_validate_recreated_receipt_transaction() {
	local receipt_dir="$1"
	local transaction_dir="$2"
	local backup_dir="${transaction_dir}/backup"
	local staged_dir="${transaction_dir}/staged"
	local publish_dir="${transaction_dir}/publish"
	local restore_dir="${transaction_dir}/restore"
	local required_dir=""
	local backup_path=""
	local staged_path=""
	local destination_path=""
	local receipt_name=""
	local receipt_count=0

	_full_loop_recreated_receipt_transaction_path_is_safe "$receipt_dir" "$transaction_dir" || return 1
	_full_loop_recreated_receipt_transaction_schema_matches "$transaction_dir" || return 1
	for required_dir in "$backup_dir" "$staged_dir" "$publish_dir" "$restore_dir"; do
		[[ -d "$required_dir" && ! -L "$required_dir" ]] || return 1
	done
	for backup_path in "$backup_dir"/*.json; do
		[[ -e "$backup_path" || -L "$backup_path" ]] || continue
		[[ -f "$backup_path" && ! -L "$backup_path" ]] || return 1
		receipt_name="${backup_path##*/}"
		staged_path="${staged_dir}/${receipt_name}"
		destination_path="${receipt_dir}/${receipt_name}"
		[[ -f "$staged_path" && ! -L "$staged_path" ]] || return 1
		[[ ! -L "$destination_path" ]] || return 1
		[[ ! -e "$destination_path" || -f "$destination_path" ]] || return 1
		_full_loop_receipt_file_is_json_object "$backup_path" || return 1
		_full_loop_receipt_file_is_json_object "$staged_path" || return 1
		receipt_count=$((receipt_count + 1))
	done
	[[ "$receipt_count" -gt 0 ]] || return 1
	for staged_path in "$staged_dir"/*.json; do
		[[ -e "$staged_path" || -L "$staged_path" ]] || continue
		[[ -f "$staged_path" && ! -L "$staged_path" ]] || return 1
		receipt_name="${staged_path##*/}"
		[[ -f "${backup_dir}/${receipt_name}" && ! -L "${backup_dir}/${receipt_name}" ]] || return 1
	done
	return 0
}

_full_loop_rollback_recreated_receipt_transaction() {
	local receipt_dir="$1"
	local transaction_dir="$2"
	local backup_dir="${transaction_dir}/backup"
	local restore_dir="${transaction_dir}/restore"
	local backup_path=""
	local restore_path=""
	local destination_path=""
	local receipt_name=""
	local transaction_state=""

	_full_loop_validate_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" || return 1
	transaction_state=$(_full_loop_recreated_receipt_transaction_state "$transaction_dir") || return 1
	[[ "$transaction_state" == "prepared" ]] || return 1
	for backup_path in "$backup_dir"/*.json; do
		[[ -f "$backup_path" && ! -L "$backup_path" ]] || return 1
		receipt_name="${backup_path##*/}"
		restore_path="${restore_dir}/${receipt_name}"
		destination_path="${receipt_dir}/${receipt_name}"
		rm -f "$restore_path" || return 1
		cp "$backup_path" "$restore_path" || return 1
		cmp -s "$backup_path" "$restore_path" || return 1
		if ! mv "$restore_path" "$destination_path"; then
			rm -f "$restore_path" || true
			return 1
		fi
		cmp -s "$backup_path" "$destination_path" || return 1
	done
	if ! mv "${transaction_dir}/state.prepared" "${transaction_dir}/state.rolled-back"; then
		return 1
	fi
	_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
	return 0
}

_full_loop_recover_recreated_receipt_transactions() {
	local receipt_dir="$1"
	local transaction_dir=""
	local transaction_state=""

	[[ -d "$receipt_dir" && ! -L "$receipt_dir" ]] || return 1
	for transaction_dir in "$receipt_dir"/.recreated-receipts.*; do
		[[ -e "$transaction_dir" || -L "$transaction_dir" ]] || continue
		_full_loop_recreated_receipt_transaction_path_is_safe "$receipt_dir" "$transaction_dir" || return 1
		transaction_state=$(_full_loop_recreated_receipt_transaction_state "$transaction_dir") || return 1
		case "$transaction_state" in
		prepared)
			_full_loop_rollback_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" || return 1
			;;
		committed | rolled-back | none)
			_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" || return 1
			;;
		*) return 1 ;;
		esac
	done
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
			if declare -F _full_loop_recover_recreated_receipt_transactions >/dev/null 2>&1 &&
				! _full_loop_recover_recreated_receipt_transactions "$receipt_dir"; then
				_full_loop_receipt_lock_release
				return 1
			fi
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

_full_loop_cleanup_deferred_matches() {
	local receipt_path="$1"
	local repo="$2"
	local pr_number="$3"
	local worktree="$4"
	local branch="$5"
	local owner_pid="$6"
	local owner_identity="$7"
	local owner_session="$8"
	local release_status="$9"
	local executor_completion_state="${10}"

	jq -e \
		--arg repo "$repo" --argjson pr_number "$pr_number" \
		--arg worktree "$worktree" --arg branch "$branch" \
		--argjson owner_pid "$owner_pid" --arg owner_identity "$owner_identity" \
		--arg owner_session "$owner_session" --arg release_status "$release_status" \
		--arg executor_completion_state "$executor_completion_state" \
		--arg cleanup_deferred "$_FULL_LOOP_CLEANUP_DEFERRED" \
		--arg cleanup_lease_pending "$_FULL_LOOP_CLEANUP_LEASE_PENDING" '
		.schema_version == 1
		and .repository == $repo and .pr_number == $pr_number
		and .worktree == $worktree and .branch == $branch
		and .executor_completion_state == $executor_completion_state
		and .resource_cleanup_state == $cleanup_deferred
		and .release_status == $release_status
		and .owner.pid == $owner_pid
		and .owner.process_identity == $owner_identity
		and .owner.session == $owner_session
		and .cleanup_lease == {state:$cleanup_lease_pending,pid:null,acquired_at:null}
	' "$receipt_path" >/dev/null 2>&1
	return $?
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
	local temp_path=""

	[[ -n "$worktree" && -n "$branch" && "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	[[ "$executor_completion_state" == "$_FULL_LOOP_EXECUTOR_FINALIZATION_PENDING" || "$executor_completion_state" == "$_FULL_LOOP_EXECUTOR_COMPLETE" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	_full_loop_receipt_lock_acquire || return 1
	kill -0 "$owner_pid" 2>/dev/null || {
		_full_loop_receipt_lock_release
		return 1
	}
	owner_identity=$(_full_loop_process_identity "$owner_pid") || {
		_full_loop_receipt_lock_release
		return 1
	}
	if [[ -f "$receipt_path" ]]; then
		if _full_loop_cleanup_deferred_matches "$receipt_path" "$repo" "$pr_number" "$worktree" "$branch" \
			"$owner_pid" "$owner_identity" "$owner_session" "$release_status" "$executor_completion_state"; then
			_full_loop_receipt_lock_release
			printf '%s\n' "$receipt_path"
			return 0
		fi
		_full_loop_receipt_lock_release
		return 1
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
		_full_loop_receipt_lock_release
		return 1
	}
	temp_path="${receipt_path}.tmp.$$"
	jq -cn \
		--arg repo "$repo" --argjson pr_number "$pr_number" \
		--arg worktree "$worktree" --arg branch "$branch" \
		--argjson owner_pid "$owner_pid" --arg owner_identity "$owner_identity" \
		--arg owner_session "$owner_session" --arg release_status "$release_status" \
		--arg executor_completion_state "$executor_completion_state" \
		--arg state "$_FULL_LOOP_CLEANUP_DEFERRED" --arg now "$now" \
		--arg cleanup_lease_pending "$_FULL_LOOP_CLEANUP_LEASE_PENDING" \
		'{schema_version:1,repository:$repo,pr_number:$pr_number,worktree:$worktree,branch:$branch,
		  executor_completion_state:$executor_completion_state,resource_cleanup_state:$state,release_status:$release_status,
		  owner:{pid:$owner_pid,process_identity:$owner_identity,session:$owner_session},
		  cleanup_lease:{state:$cleanup_lease_pending,pid:null,acquired_at:null},created_at:$now,updated_at:$now,cleaned_at:null}' \
		>"$temp_path" || {
		_full_loop_receipt_lock_release
		return 1
	}
	mv "$temp_path" "$receipt_path" || {
		rm -f "$temp_path"
		_full_loop_receipt_lock_release
		return 1
	}
	_full_loop_receipt_lock_release
	printf '%s\n' "$receipt_path"
	return 0
}

_full_loop_cleanup_receipt_for_worktree_unlocked_fallback() {
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
		if jq -e --arg worktree "$worktree" --arg superseded "$_FULL_LOOP_RECEIPT_PATH_RECREATED" '
			.worktree == $worktree
			and ((.receipt_disposition.state // "") != $superseded)
		' "$receipt_path" >/dev/null 2>&1; then
			candidate_created_at=$(jq -r '.created_at // empty' "$receipt_path" 2>/dev/null || true)
			candidate_is_migrated=0
			jq -e --arg string_type "$_FULL_LOOP_RECEIPT_JSON_STRING_TYPE" \
				'.migration.from_repository | type == $string_type and length > 0' \
				"$receipt_path" >/dev/null 2>&1 && candidate_is_migrated=1
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

_full_loop_cleanup_receipt_for_worktree_unlocked() {
	local worktree="$1"
	local receipt_dir=""
	local selected_path=""
	local lookup_status=0

	[[ -n "$worktree" ]] || return 1
	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 1
	[[ -d "$receipt_dir" ]] || return 1
	# A cleanup pass can perform this lookup hundreds of times. Process every
	# receipt in one jq invocation instead of launching jq once to three times
	# per file. Malformed JSON falls back to the conservative per-file scan,
	# which preserves the previous skip-invalid-file behaviour.
	selected_path=$(jq -nr \
		--arg worktree "$worktree" \
		--arg superseded "$_FULL_LOOP_RECEIPT_PATH_RECREATED" \
		--arg string_type "$_FULL_LOOP_RECEIPT_JSON_STRING_TYPE" '
		reduce (
			inputs
			| select(type == "object")
			| select(.worktree == $worktree)
			| select((.receipt_disposition.state // "") != $superseded)
			| {
				path: input_filename,
				created_at: (.created_at // ""),
				is_migrated: (
					if (((.migration.from_repository? // null) | type) == $string_type
						and ((.migration.from_repository? // "") | length) > 0)
					then 1 else 0 end
				)
			}
		) as $candidate (
			null;
			if . == null
				or $candidate.created_at > .created_at
				or ($candidate.created_at == .created_at
					and $candidate.is_migrated == 1 and .is_migrated != 1)
			then $candidate else . end
		)
		| .path // empty
	' "$receipt_dir"/*.json 2>/dev/null) || lookup_status=$?
	if [[ "$lookup_status" -ne 0 ]]; then
		_full_loop_cleanup_receipt_for_worktree_unlocked_fallback "$worktree"
		return $?
	fi
	[[ -n "$selected_path" ]] || return 1
	printf '%s\n' "$selected_path"
	return 0
}

full_loop_cleanup_receipt_for_worktree() {
	local worktree="$1"
	local receipt_dir=""
	local selected_path=""
	local lookup_status=0

	[[ -n "$worktree" ]] || return 1
	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 1
	[[ -d "$receipt_dir" ]] || return 1
	_full_loop_receipt_lock_acquire || return 1
	selected_path=$(_full_loop_cleanup_receipt_for_worktree_unlocked "$worktree") || lookup_status=$?
	_full_loop_receipt_lock_release
	[[ "$lookup_status" -eq 0 && -n "$selected_path" ]] || return 1
	printf '%s\n' "$selected_path"
	return 0
}

_full_loop_valid_receipt_file_count() {
	local receipt_dir="$1"
	local receipt_path=""
	local receipt_file_count=0

	for receipt_path in "$receipt_dir"/*.json; do
		[[ -f "$receipt_path" ]] || continue
		[[ ! -L "$receipt_path" ]] || return 1
		_full_loop_receipt_file_is_json_object "$receipt_path" || return 1
		receipt_file_count=$((receipt_file_count + 1))
	done
	printf '%s\n' "$receipt_file_count"
	return 0
}

_full_loop_recreated_worktree_identity_matches() {
	local worktree="$1"
	local branch="$2"
	local head_sha="$3"
	local expected_root=""
	local actual_root=""
	local actual_branch=""
	local actual_head=""

	expected_root=$(cd "$worktree" 2>/dev/null && pwd -P) || return 1
	actual_root=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || return 1
	actual_root=$(cd "$actual_root" 2>/dev/null && pwd -P) || return 1
	actual_branch=$(git -C "$worktree" branch --show-current 2>/dev/null) || return 1
	actual_head=$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null) || return 1
	[[ "$actual_root" == "$expected_root" && "$actual_branch" == "$branch" && "$actual_head" == "$head_sha" ]] || return 1
	return 0
}

_full_loop_active_recreated_receipts_are_cleaned() {
	local receipt_dir="$1"
	local worktree="$2"
	local receipt_path=""
	local state=""
	local matching_count=0

	for receipt_path in "$receipt_dir"/*.json; do
		[[ -f "$receipt_path" ]] || continue
		if ! jq -e --arg worktree "$worktree" --arg superseded "$_FULL_LOOP_RECEIPT_PATH_RECREATED" '
			.worktree == $worktree
			and ((.receipt_disposition.state // "") != $superseded)
		' "$receipt_path" >/dev/null 2>&1; then
			continue
		fi
		state=$(jq -r '.resource_cleanup_state // empty' "$receipt_path" 2>/dev/null) || return 1
		[[ "$state" == "$_FULL_LOOP_CLEANUP_CLEANED" ]] || return 1
		matching_count=$((matching_count + 1))
	done
	[[ "$matching_count" -gt 0 ]] || return 1
	return 0
}

_full_loop_initialize_recreated_receipt_transaction() {
	local receipt_dir="$1"
	local transaction_dir=""

	transaction_dir=$(mktemp -d "${receipt_dir}/.recreated-receipts.XXXXXX") || return 1
	chmod 700 "$transaction_dir" || {
		_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
		return 1
	}
	printf '%s\n' "$_FULL_LOOP_RECREATED_RECEIPT_TRANSACTION_SCHEMA" >"${transaction_dir}/schema" || {
		_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
		return 1
	}
	mkdir -p "${transaction_dir}/backup" "${transaction_dir}/staged" \
		"${transaction_dir}/publish" "${transaction_dir}/restore" || {
		_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
		return 1
	}
	printf '%s\n' "$transaction_dir"
	return 0
}

_full_loop_stage_recreated_receipt_file() {
	local receipt_path="$1"
	local transaction_dir="$2"
	local worktree="$3"
	local branch="$4"
	local head_sha="$5"
	local owner_pid="$6"
	local owner_session="$7"
	local now="$8"
	local generation_id="$9"
	local receipt_name="${receipt_path##*/}"
	local backup_path="${transaction_dir}/backup/${receipt_name}"
	local staged_path="${transaction_dir}/staged/${receipt_name}"

	cp "$receipt_path" "$backup_path" || return 1
	cmp -s "$receipt_path" "$backup_path" || return 1
	jq --arg disposition "$_FULL_LOOP_RECEIPT_PATH_RECREATED" \
		--arg now "$now" --arg generation_id "$generation_id" \
		--arg worktree "$worktree" --arg branch "$branch" --arg head "$head_sha" \
		--argjson owner_pid "$owner_pid" --arg owner_session "$owner_session" '
		.receipt_disposition = {
			state:$disposition,
			reason:"worktree-path-recreated",
			superseded_at:$now,
			replacement_generation:{
				id:$generation_id,
				worktree:$worktree,
				branch:$branch,
				head:$head,
				owner:{pid:$owner_pid,session:$owner_session}
			}
		}
		| .updated_at = $now
	' "$receipt_path" >"$staged_path" || return 1
	jq -e --arg disposition "$_FULL_LOOP_RECEIPT_PATH_RECREATED" \
		--arg generation_id "$generation_id" --arg worktree "$worktree" \
		--arg branch "$branch" --arg head "$head_sha" --argjson owner_pid "$owner_pid" \
		--arg owner_session "$owner_session" '
		.receipt_disposition.state == $disposition
		and .receipt_disposition.replacement_generation.id == $generation_id
		and .receipt_disposition.replacement_generation.worktree == $worktree
		and .receipt_disposition.replacement_generation.branch == $branch
		and .receipt_disposition.replacement_generation.head == $head
		and .receipt_disposition.replacement_generation.owner.pid == $owner_pid
		and .receipt_disposition.replacement_generation.owner.session == $owner_session
	' "$staged_path" >/dev/null 2>&1 || return 1
	return 0
}

_full_loop_prepare_recreated_receipt_transaction() {
	local receipt_dir="$1"
	local worktree="$2"
	local branch="$3"
	local head_sha="$4"
	local owner_pid="$5"
	local owner_session="$6"
	local now="$7"
	local generation_id="${head_sha}:${owner_pid}:${now}"
	local transaction_dir=""
	local receipt_path=""
	local matching_count=0

	transaction_dir=$(_full_loop_initialize_recreated_receipt_transaction "$receipt_dir") || return 1
	for receipt_path in "$receipt_dir"/*.json; do
		[[ -f "$receipt_path" ]] || continue
		if [[ -L "$receipt_path" ]]; then
			_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
			return 1
		fi
		if ! jq -e --arg worktree "$worktree" --arg cleaned "$_FULL_LOOP_CLEANUP_CLEANED" \
			--arg superseded "$_FULL_LOOP_RECEIPT_PATH_RECREATED" '
			.worktree == $worktree
			and .resource_cleanup_state == $cleaned
			and ((.receipt_disposition.state // "") != $superseded)
		' "$receipt_path" >/dev/null 2>&1; then
			continue
		fi
		if ! _full_loop_stage_recreated_receipt_file "$receipt_path" "$transaction_dir" \
			"$worktree" "$branch" "$head_sha" "$owner_pid" "$owner_session" "$now" "$generation_id"; then
			_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
			return 1
		fi
		matching_count=$((matching_count + 1))
	done
	if [[ "$matching_count" -eq 0 ]] ||
		! _full_loop_validate_recreated_receipt_transaction "$receipt_dir" "$transaction_dir"; then
		_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
		return 1
	fi
	: >"${transaction_dir}/state.prepared.tmp" || {
		_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
		return 1
	}
	if ! mv "${transaction_dir}/state.prepared.tmp" "${transaction_dir}/state.prepared"; then
		_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
		return 1
	fi
	printf '%s\n' "$transaction_dir"
	return 0
}

_full_loop_publish_recreated_receipt_file() {
	local receipt_dir="$1"
	local transaction_dir="$2"
	local receipt_name="$3"
	local staged_path="${transaction_dir}/staged/${receipt_name}"
	local publish_path="${transaction_dir}/publish/${receipt_name}"
	local destination_path="${receipt_dir}/${receipt_name}"

	rm -f "$publish_path" || return 1
	cp "$staged_path" "$publish_path" || return 1
	cmp -s "$staged_path" "$publish_path" || return 1
	mv "$publish_path" "$destination_path" || return 1
	cmp -s "$staged_path" "$destination_path" || return 1
	return 0
}

_full_loop_publish_recreated_receipt_transaction() {
	local receipt_dir="$1"
	local transaction_dir="$2"
	local backup_path=""
	local receipt_name=""
	local transaction_state=""

	_full_loop_validate_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" || return 1
	transaction_state=$(_full_loop_recreated_receipt_transaction_state "$transaction_dir") || return 1
	[[ "$transaction_state" == "prepared" ]] || return 1
	for backup_path in "$transaction_dir"/backup/*.json; do
		receipt_name="${backup_path##*/}"
		if ! _full_loop_publish_recreated_receipt_file "$receipt_dir" "$transaction_dir" "$receipt_name"; then
			_full_loop_rollback_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
			return 1
		fi
	done
	if mv "${transaction_dir}/state.prepared" "${transaction_dir}/state.committed"; then
		_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
		return 0
	fi
	transaction_state=$(_full_loop_recreated_receipt_transaction_state "$transaction_dir" 2>/dev/null || true)
	if [[ "$transaction_state" == "committed" ]]; then
		_full_loop_remove_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
		return 0
	fi
	_full_loop_rollback_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" >/dev/null 2>&1 || true
	return 1
}

_full_loop_supersede_recreated_receipt_files() {
	local receipt_dir="$1"
	local worktree="$2"
	local branch="$3"
	local head_sha="$4"
	local owner_pid="$5"
	local owner_session="$6"
	local now="$7"
	local transaction_dir=""

	transaction_dir=$(_full_loop_prepare_recreated_receipt_transaction "$receipt_dir" "$worktree" "$branch" \
		"$head_sha" "$owner_pid" "$owner_session" "$now") || return 1
	_full_loop_publish_recreated_receipt_transaction "$receipt_dir" "$transaction_dir" || return 1
	return 0
}

# Preserve terminal cleanup history while retiring it as active lifecycle
# evidence when a manual add creates a new worktree generation at the same path.
# Every unsuperseded receipt for the path must already be CLEANED; an active
# non-terminal lifecycle is a conflict and fails closed.
# Args: $1=worktree, $2=branch, $3=head SHA, $4=owner PID, $5=owner session
# Prints the previously selected receipt path on success.
# Returns: 0 superseded, 1 conflict/mutation failure, 2 no matching receipt.
full_loop_supersede_cleaned_receipts_for_recreated_worktree() {
	local worktree="$1"
	local branch="$2"
	local head_sha="$3"
	local owner_pid="$4"
	local owner_session="$5"
	local receipt_dir=""
	local selected_path=""
	local now=""
	local receipt_file_count=0

	[[ -d "$worktree" && ! -L "$worktree" && -n "$branch" ]] || return 1
	[[ "$head_sha" =~ ^[0-9a-fA-F]{40,64}$ && "$owner_pid" =~ ^[0-9]+$ ]] || return 1
	receipt_dir=$(_full_loop_cleanup_receipt_dir) || return 1
	[[ -d "$receipt_dir" ]] || return 2
	command -v git >/dev/null 2>&1 || return 1
	command -v jq >/dev/null 2>&1 || return 1
	_full_loop_recreated_worktree_identity_matches "$worktree" "$branch" "$head_sha" || return 1
	_full_loop_receipt_lock_acquire || return 1
	receipt_file_count=$(_full_loop_valid_receipt_file_count "$receipt_dir") || {
		_full_loop_receipt_lock_release
		return 1
	}
	if [[ "$receipt_file_count" -eq 0 ]]; then
		_full_loop_receipt_lock_release
		return 2
	fi
	selected_path=$(_full_loop_cleanup_receipt_for_worktree_unlocked "$worktree" 2>/dev/null) || {
		_full_loop_receipt_lock_release
		return 2
	}
	if ! _full_loop_recreated_worktree_identity_matches "$worktree" "$branch" "$head_sha" ||
		! _full_loop_active_recreated_receipts_are_cleaned "$receipt_dir" "$worktree"; then
		_full_loop_receipt_lock_release
		return 1
	fi

	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || {
		_full_loop_receipt_lock_release
		return 1
	}
	if ! _full_loop_supersede_recreated_receipt_files "$receipt_dir" "$worktree" "$branch" \
		"$head_sha" "$owner_pid" "$owner_session" "$now"; then
		_full_loop_receipt_lock_release
		return 1
	fi
	_full_loop_receipt_lock_release
	printf '%s\n' "$selected_path"
	return 0
}

full_loop_cleanup_owner_alive() {
	local receipt_path="$1"
	local owner_pid=""
	local expected_identity=""
	local observed_identity=""
	local owner_record=""
	_FULL_LOOP_CLEANUP_OWNER_PID=""

	[[ -f "$receipt_path" ]] || return 1
	owner_record=$(jq -r '[.owner.pid // "", .owner.process_identity // ""] | @tsv' "$receipt_path" 2>/dev/null || true)
	IFS=$'\t' read -r owner_pid expected_identity <<<"$owner_record"
	_FULL_LOOP_CLEANUP_OWNER_PID="$owner_pid"
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
	jq --arg state "$target_state" --arg cleaned "$_FULL_LOOP_CLEANUP_CLEANED" \
		--arg now "$now" --arg lease_pid "$lease_pid" '
		.resource_cleanup_state = $state
		| .updated_at = $now
		| if $state == "CLEANUP_LEASED" then
			.cleanup_lease = {state:"acquired",pid:($lease_pid | tonumber),acquired_at:$now}
		  elif $state == $cleaned then
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
	local expected_worktree="${4:-}"
	local expected_branch="${5:-}"
	local expected_owner_pid="${6:-}"
	local expected_owner_session="${7:-}"
	local receipt_path=""
	local current_release=""
	local current_executor=""
	local expected_owner_identity=""
	local require_exact_evidence=0
	local now=""
	[[ $# -eq 3 || $# -eq 7 ]] || return 1
	[[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED" ]] || return 1
	if [[ $# -eq 7 ]]; then
		[[ -n "$expected_worktree" && -n "$expected_branch" && "$expected_owner_pid" =~ ^[0-9]+$ ]] || return 1
		expected_owner_identity=$(_full_loop_process_identity "$expected_owner_pid") || return 1
		require_exact_evidence=1
	fi
	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	_full_loop_receipt_lock_acquire || return 1
	if [[ "$require_exact_evidence" -eq 1 ]]; then
		if ! jq -e \
			--arg repo "$repo" --argjson pr "$pr_number" \
			--arg worktree "$expected_worktree" --arg branch "$expected_branch" \
			--argjson owner_pid "$expected_owner_pid" --arg owner_identity "$expected_owner_identity" \
			--arg owner_session "$expected_owner_session" --arg release_status "$release_status" \
			--arg release_pending "$_FULL_LOOP_RECEIPT_RELEASE_PENDING" \
			--arg release_authorized "$_FULL_LOOP_RECEIPT_RELEASE_AUTHORIZED" \
			--arg release_not_requested "$_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED" \
			--arg cleanup_deferred "$_FULL_LOOP_CLEANUP_DEFERRED" \
			--arg executor_complete "$_FULL_LOOP_EXECUTOR_COMPLETE" \
			--arg executor_pending "$_FULL_LOOP_EXECUTOR_FINALIZATION_PENDING" \
			--arg cleanup_lease_pending "$_FULL_LOOP_CLEANUP_LEASE_PENDING" '
			.schema_version == 1
			and .repository == $repo and .pr_number == $pr
			and .worktree == $worktree and .branch == $branch
			and (.executor_completion_state == $executor_pending or .executor_completion_state == $executor_complete)
			and .resource_cleanup_state == $cleanup_deferred
			and (
				.release_status == $release_status
				or .release_status == $release_pending
				or (.release_status == $release_authorized and $release_status != $release_not_requested)
			)
			and .owner.pid == $owner_pid
			and .owner.process_identity == $owner_identity
			and .owner.session == $owner_session
			and .cleanup_lease == {state:$cleanup_lease_pending,pid:null,acquired_at:null}
		' "$receipt_path" >/dev/null 2>&1; then
			_full_loop_receipt_lock_release
			return 1
		fi
	elif ! jq -e --arg repo "$repo" --argjson pr "$pr_number" \
		'.repository == $repo and .pr_number == $pr' "$receipt_path" >/dev/null 2>&1; then
		_full_loop_receipt_lock_release
		return 1
	fi
	current_executor=$(jq -r '.executor_completion_state // empty' "$receipt_path" 2>/dev/null || true)
	current_release=$(jq -r '.release_status // empty' "$receipt_path" 2>/dev/null || true)
	if [[ "$current_executor" != "$_FULL_LOOP_EXECUTOR_FINALIZATION_PENDING" && "$current_executor" != "$_FULL_LOOP_EXECUTOR_COMPLETE" ]]; then
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

_full_loop_reconcile_complete_migration() {
	local old_repo="$1"
	local new_repo="$2"
	local pr_number="$3"
	local source_receipt="$4"
	local source_release="$5"
	local destination_receipt="$6"
	local destination_release="$7"
	local release_status="$8"
	local source_status=""
	local source_evidence=""
	local destination_evidence=""
	local source_aggregate="${source_release%.status}.aggregate.json"
	local source_successor="${source_release%.status}.successor.json"

	[[ -f "$destination_receipt" && ! -L "$destination_receipt" ]] || return 2
	_full_loop_migrated_destination_matches "$destination_receipt" "$destination_release" \
		"$new_repo" "$old_repo" "$pr_number" "$release_status" || return 2
	if [[ -e "$source_receipt" || -L "$source_receipt" ]]; then
		[[ -f "$source_receipt" && ! -L "$source_receipt" ]] || return 1
		_full_loop_migrated_cleanup_receipt_matches_source "$source_receipt" "$destination_receipt" \
			"$old_repo" "$new_repo" "$pr_number" || return 3
	fi
	if [[ -e "$source_release" || -L "$source_release" ]]; then
		[[ -f "$source_release" && ! -L "$source_release" ]] || return 1
		IFS= read -r source_status <"$source_release" || return 1
		[[ "$source_status" == "$release_status" ]] || return 1
	fi
	if [[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" ]]; then
		[[ ! -L "$source_aggregate" && ! -L "$source_successor" ]] || return 1
		destination_evidence=$(_full_loop_superseded_migration_evidence_path \
			"$destination_release" "$new_repo" "$pr_number") || return 1
		if [[ -e "$source_aggregate" || -e "$source_successor" ]]; then
			source_evidence=$(_full_loop_superseded_migration_evidence_path \
				"$source_release" "$old_repo" "$pr_number") || return 1
			_full_loop_migrated_evidence_matches_source "$source_evidence" "$destination_evidence" \
				"$old_repo" "$new_repo" "$pr_number" || return 1
		fi
	elif [[ -e "$source_aggregate" || -L "$source_aggregate" || -e "$source_successor" || -L "$source_successor" ]]; then
		return 1
	fi
	rm -f "$source_receipt" "$source_release" "$source_aggregate" "$source_successor"
	return $?
}

_full_loop_prepare_partial_migration_retry() {
	local old_repo="$1"
	local new_repo="$2"
	local pr_number="$3"
	local source_receipt="$4"
	local source_evidence="$5"
	local destination_receipt="$6"
	local destination_release="$7"
	local destination_evidence="$8"
	local release_status="$9"
	local destination_status=""
	local aggregate_path="${destination_release%.status}.aggregate.json"
	local successor_path="${destination_release%.status}.successor.json"
	local artifacts_present=0

	if [[ -e "$destination_receipt" || -L "$destination_receipt" ||
		-e "$destination_release" || -L "$destination_release" ||
		-e "$aggregate_path" || -L "$aggregate_path" ||
		-e "$successor_path" || -L "$successor_path" ]]; then
		artifacts_present=1
	fi
	[[ "$artifacts_present" -eq 1 ]] || return 0
	if [[ -e "$destination_receipt" || -L "$destination_receipt" ]]; then
		_full_loop_migrated_cleanup_receipt_matches_source "$source_receipt" "$destination_receipt" \
			"$old_repo" "$new_repo" "$pr_number" || return 1
	fi
	if [[ -e "$destination_release" || -L "$destination_release" ]]; then
		[[ -f "$destination_release" && ! -L "$destination_release" ]] || return 1
		IFS= read -r destination_status <"$destination_release" || return 1
		[[ "$destination_status" == "$release_status" ]] || return 1
	fi
	if [[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" ]]; then
		[[ -n "$source_evidence" && -n "$destination_evidence" ]] || return 1
		case "$destination_evidence" in
		*.aggregate.json) [[ ! -e "$successor_path" && ! -L "$successor_path" ]] || return 1 ;;
		*.successor.json) [[ ! -e "$aggregate_path" && ! -L "$aggregate_path" ]] || return 1 ;;
		*) return 1 ;;
		esac
		if [[ -e "$destination_evidence" || -L "$destination_evidence" ]]; then
			_full_loop_migrated_evidence_matches_source "$source_evidence" "$destination_evidence" \
				"$old_repo" "$new_repo" "$pr_number" || return 1
		fi
	elif [[ -e "$aggregate_path" || -L "$aggregate_path" || -e "$successor_path" || -L "$successor_path" ]]; then
		return 1
	fi
	rm -f "$destination_receipt" "$destination_release" "$aggregate_path" "$successor_path"
	return $?
}

_full_loop_write_migrated_cleanup_receipt() {
	local old_repo="$1"
	local new_repo="$2"
	local release_status="$3"
	local source_receipt="$4"
	local destination_receipt="$5"
	local destination_release="$6"
	local source_evidence="$7"
	local destination_evidence="$8"
	local now=""

	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	mkdir -p "${destination_release%/*}" || return 1
	jq --arg repo "$new_repo" --arg old_repo "$old_repo" --arg now "$now" '
		.repository = $repo
		| .updated_at = $now
		| .migration = {from_repository:$old_repo,to_repository:$repo,migrated_at:$now}
	' "$source_receipt" >"${destination_receipt}.tmp.$$" || return 1
	printf '%s\n' "$release_status" >"${destination_release}.tmp.$$" || {
		rm -f "${destination_receipt}.tmp.$$"
		return 1
	}
	if [[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" ]]; then
		_full_loop_prepare_migrated_superseded_evidence \
			"$source_evidence" "$destination_evidence" "$old_repo" "$new_repo" "$now" || {
			rm -f "${destination_receipt}.tmp.$$" "${destination_release}.tmp.$$" "${destination_evidence}.tmp.$$"
			return 1
		}
		mv "${destination_evidence}.tmp.$$" "$destination_evidence" || {
			rm -f "${destination_receipt}.tmp.$$" "${destination_release}.tmp.$$" "${destination_evidence}.tmp.$$"
			return 1
		}
	fi
	mv "${destination_receipt}.tmp.$$" "$destination_receipt" || {
		rm -f "${destination_release}.tmp.$$"
		[[ -z "$destination_evidence" ]] || rm -f "$destination_evidence"
		return 1
	}
	if ! mv "${destination_release}.tmp.$$" "$destination_release"; then
		rm -f "$destination_receipt"
		[[ -z "$destination_evidence" ]] || rm -f "$destination_evidence"
		return 1
	fi
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
	local source_evidence=""
	local destination_evidence=""
	local existing_destination_rc=0
	[[ "$old_repo" != "$new_repo" ]] || return 1
	[[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED" ]] || return 1
	source_receipt=$(_full_loop_cleanup_receipt_path "$old_repo" "$pr_number") || return 1
	destination_receipt=$(_full_loop_cleanup_receipt_path "$new_repo" "$pr_number") || return 1
	_full_loop_receipt_lock_acquire || return 1

	_full_loop_reconcile_complete_migration "$old_repo" "$new_repo" "$pr_number" \
		"$source_receipt" "$source_release" "$destination_receipt" "$destination_release" \
		"$release_status" || existing_destination_rc=$?
	case "$existing_destination_rc" in
	0)
		_full_loop_receipt_lock_release
		return 0
		;;
	2) ;;
	3)
		_full_loop_receipt_lock_release
		return 0
		;;
	*)
		_full_loop_receipt_lock_release
		return 1
		;;
	esac
	if ! _full_loop_migration_source_matches "$source_receipt" "$source_release" \
		"$old_repo" "$pr_number" "$release_status"; then
		_full_loop_receipt_lock_release
		return 1
	fi
	if [[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" ]]; then
		source_evidence=$(_full_loop_superseded_migration_evidence_path \
			"$source_release" "$old_repo" "$pr_number") || {
			_full_loop_receipt_lock_release
			return 1
		}
		case "$source_evidence" in
		*.aggregate.json) destination_evidence="${destination_release%.status}.aggregate.json" ;;
		*.successor.json) destination_evidence="${destination_release%.status}.successor.json" ;;
		*)
			_full_loop_receipt_lock_release
			return 1
			;;
		esac
	fi
	if ! _full_loop_prepare_partial_migration_retry "$old_repo" "$new_repo" "$pr_number" \
		"$source_receipt" "$source_evidence" "$destination_receipt" "$destination_release" \
		"$destination_evidence" "$release_status"; then
		_full_loop_receipt_lock_release
		return 1
	fi
	if ! _full_loop_write_migrated_cleanup_receipt \
		"$old_repo" "$new_repo" "$release_status" "$source_receipt" \
		"$destination_receipt" "$destination_release" "$source_evidence" "$destination_evidence"; then
		_full_loop_receipt_lock_release
		return 1
	fi
	rm -f "$source_release" "$source_receipt" "$source_evidence" || {
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
	local current_release=""
	local now=""

	[[ "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED" || "$release_status" == "$_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED" ]] || return 1
	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 0
	_full_loop_receipt_lock_acquire || return 1
	if ! jq -e --arg repo "$repo" --argjson pr "$pr_number" \
		'.repository == $repo and .pr_number == $pr' "$receipt_path" >/dev/null 2>&1; then
		_full_loop_receipt_lock_release
		return 1
	fi
	current_release=$(jq -r '.release_status // empty' "$receipt_path" 2>/dev/null || true)
	case "${current_release}:${release_status}" in
	"pending:${_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED}" | \
		"pending:${_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED}" | \
		"pending:${_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED}" | \
		"authorized:${_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED}" | \
		"authorized:${_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED}" | \
		"${_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED}:${_FULL_LOOP_RECEIPT_RELEASE_PUBLISHED}" | \
		"${_FULL_LOOP_RECEIPT_RELEASE_NOT_REQUESTED}:${_FULL_LOOP_RECEIPT_RELEASE_SUPERSEDED}" | \
		"${release_status}:${release_status}") ;;
	*)
		_full_loop_receipt_lock_release
		return 1
		;;
	esac
	if [[ "$current_release" == "$release_status" ]]; then
		_full_loop_receipt_lock_release
		return 0
	fi
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

full_loop_mark_cleanup_receipt_cleaned() {
	local receipt_path="$1"
	local worktree="$2"
	local cleanup_log="${3:-${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}}"

	[[ -f "$receipt_path" && -n "$worktree" && ! -e "$worktree" && -f "$cleanup_log" ]] || return 1
	grep -Fq "worktree-removed: ${worktree} —" "$cleanup_log" || return 1
	jq -e --arg worktree "$worktree" '.worktree == $worktree' "$receipt_path" >/dev/null 2>&1 || return 1
	full_loop_transition_cleanup_receipt "$receipt_path" "$_FULL_LOOP_CLEANUP_CLEANED"
	return $?
}

full_loop_mark_cleanup_cleaned_for_identity() {
	local repo="$1"
	local pr_number="$2"
	local worktree="$3"
	local cleanup_log="${4:-${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}}"
	local receipt_path=""

	receipt_path=$(_full_loop_cleanup_receipt_path "$repo" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	jq -e --arg repo "$repo" --argjson pr_number "$pr_number" --arg worktree "$worktree" '
		.repository == $repo and .pr_number == $pr_number and .worktree == $worktree
	' "$receipt_path" >/dev/null 2>&1 || return 1
	full_loop_mark_cleanup_receipt_cleaned "$receipt_path" "$worktree" "$cleanup_log"
	return $?
}

full_loop_mark_cleanup_cleaned_for_worktree() {
	local worktree="$1"
	local cleanup_log="${2:-${AIDEVOPS_CLEANUP_LOG:-${HOME}/.aidevops/logs/cleanup_worktrees.log}}"
	local receipt_path=""

	receipt_path=$(full_loop_cleanup_receipt_for_worktree "$worktree") || return 1
	full_loop_mark_cleanup_receipt_cleaned "$receipt_path" "$worktree" "$cleanup_log"
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
