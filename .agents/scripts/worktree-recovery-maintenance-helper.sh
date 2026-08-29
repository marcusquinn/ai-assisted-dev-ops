#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Bounded producer-owned maintenance for terminal worktree recovery archives.

[[ "${_WORKTREE_RECOVERY_MAINTENANCE_HELPER_LOADED:-}" == "1" ]] && return 0
_WORKTREE_RECOVERY_MAINTENANCE_HELPER_LOADED=1

WORKTREE_RECOVERY_MAINTENANCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
# shellcheck source=worktree-recovery-lifecycle-helper.sh
source "${WORKTREE_RECOVERY_MAINTENANCE_DIR}/worktree-recovery-lifecycle-helper.sh"
# shellcheck source=disk-capacity-lib.sh
source "${WORKTREE_RECOVERY_MAINTENANCE_DIR}/disk-capacity-lib.sh"

WORKTREE_RECOVERY_MAINTENANCE_RUN_SCHEMA="aidevops.worktree-recovery-maintenance-run/v1"
WORKTREE_RECOVERY_MAINTENANCE_CYCLE_SCHEMA="aidevops.worktree-recovery-zero-candidate-cycle/v1"
WORKTREE_RECOVERY_MAINTENANCE_LOCK_PATH=""
WORKTREE_RECOVERY_MAINTENANCE_LOCK_TOKEN=""
WORKTREE_RECOVERY_MAINTENANCE_SCANNED=0
WORKTREE_RECOVERY_MAINTENANCE_PROTECTED=0
WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN=0
WORKTREE_RECOVERY_MAINTENANCE_SELECTED=0
WORKTREE_RECOVERY_MAINTENANCE_SELECTED_BYTES=0
WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT=0
WORKTREE_RECOVERY_MAINTENANCE_CURSOR_BEFORE=0
WORKTREE_RECOVERY_MAINTENANCE_CURSOR_AFTER=0
WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_ARCHIVE=0
WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_SIZING=0
WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_CLASSIFICATION=0
WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_AGE=0
WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_EVIDENCE=0
WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_POLICY=0
WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_LIMIT=0
WORKTREE_RECOVERY_MAINTENANCE_INVENTORY_DIGEST=""
WORKTREE_RECOVERY_MAINTENANCE_PRESSURE_ACTIVE=false
WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_CYCLE_SCANNED=0
WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_COMPLETED_CYCLES=0
WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_CYCLE_REASONS_JSON=""
WORKTREE_RECOVERY_MAINTENANCE_REASON_COUNTS_JSON=""
WORKTREE_RECOVERY_MAINTENANCE_CYCLE_REASON_COUNTS_JSON=""
WORKTREE_RECOVERY_MAINTENANCE_CYCLE_SCANNED=0
WORKTREE_RECOVERY_MAINTENANCE_CYCLE_COMPLETE=false
WORKTREE_RECOVERY_MAINTENANCE_COMPLETED_CYCLES=0
WORKTREE_RECOVERY_MAINTENANCE_TEMP_INVENTORY=""
WORKTREE_RECOVERY_MAINTENANCE_TEMP_ORDERED=""
WORKTREE_RECOVERY_MAINTENANCE_TEMP_SELECTED=""
WORKTREE_RECOVERY_MAINTENANCE_TEMP_REASONS=""

_worktree_recovery_maintenance_uint() {
	local value="$1"
	local fallback="$2"
	local minimum="$3"
	local maximum="$4"

	if [[ ! "$value" =~ ^[0-9]+$ || "$value" -lt "$minimum" || "$value" -gt "$maximum" ]]; then
		value="$fallback"
	fi
	printf '%s\n' "$value"
	return 0
}

_worktree_recovery_maintenance_state_dir() {
	local state_dir="${AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR:-${AIDEVOPS_LOG_DIR:-${HOME:-}/.aidevops/logs}/worktree-recovery-maintenance}"

	[[ "$state_dir" == /* && "$state_dir" != */ ]] || return 1
	if [[ -e "$state_dir" || -L "$state_dir" ]]; then
		[[ -d "$state_dir" && ! -L "$state_dir" ]] || return 1
	else
		mkdir -p "$state_dir" || return 1
	fi
	cd "$state_dir" 2>/dev/null && pwd -P
	return $?
}

_worktree_recovery_maintenance_acquire_lock() {
	local state_dir="$1"
	local lock_path="${state_dir}/maintenance.lock"
	local reclaim_path="${lock_path}.reclaim.$$-${RANDOM}"
	local owner_state=""
	local process_lstart=""
	local token=""
	local attempt=0

	WORKTREE_RECOVERY_MAINTENANCE_LOCK_PATH=""
	WORKTREE_RECOVERY_MAINTENANCE_LOCK_TOKEN=""
	token="$$-${RANDOM}-$(date -u '+%Y%m%dT%H%M%SZ')" || return 1
	process_lstart=$(_worktree_recovery_process_lstart "$$") || return 1
	while [[ "$attempt" -lt 2 ]]; do
		if mkdir "$lock_path" 2>/dev/null; then
			if ! printf '%s\n' "$$" >"$lock_path/pid" ||
				! printf '%s\n' "$process_lstart" >"$lock_path/lstart" ||
				! printf '%s\n' "$token" >"$lock_path/token" ||
				! printf '%s\n' "complete" >"$lock_path/initialized"; then
				rm -f "$lock_path/pid" "$lock_path/lstart" "$lock_path/token" \
					"$lock_path/initialized" 2>/dev/null || true
				rmdir "$lock_path" 2>/dev/null || true
				return 1
			fi
			WORKTREE_RECOVERY_MAINTENANCE_LOCK_PATH="$lock_path"
			WORKTREE_RECOVERY_MAINTENANCE_LOCK_TOKEN="$token"
			return 0
		fi
		owner_state=$(_worktree_recovery_lock_owner_state "$lock_path") || return 1
		[[ "$owner_state" == "$_WT_RECOVERY_LOCK_STATE_STALE" ]] || return 1
		mv "$lock_path" "$reclaim_path" 2>/dev/null || return 1
		[[ "$(_worktree_recovery_lock_owner_state "$reclaim_path")" == "$_WT_RECOVERY_LOCK_STATE_STALE" ]] || return 1
		rm -rf "$reclaim_path" || return 1
		attempt=$((attempt + 1))
	done
	return 1
}

_worktree_recovery_maintenance_release_lock() {
	local lock_path="$WORKTREE_RECOVERY_MAINTENANCE_LOCK_PATH"
	local owner_pid=""
	local owner_token=""

	[[ -d "$lock_path" && ! -L "$lock_path" ]] || return 1
	IFS= read -r owner_pid <"$lock_path/pid" || return 1
	IFS= read -r owner_token <"$lock_path/token" || return 1
	[[ "$owner_pid" == "$$" && "$owner_token" == "$WORKTREE_RECOVERY_MAINTENANCE_LOCK_TOKEN" ]] || return 1
	rm -f "$lock_path/initialized" "$lock_path/pid" "$lock_path/lstart" "$lock_path/token" || return 1
	rmdir "$lock_path" || return 1
	WORKTREE_RECOVERY_MAINTENANCE_LOCK_PATH=""
	WORKTREE_RECOVERY_MAINTENANCE_LOCK_TOKEN=""
	return 0
}

_worktree_recovery_maintenance_age_seconds() {
	local entry_json="$1"
	local bucket_path=""
	local created_at=""

	bucket_path=$(printf '%s\n' "$entry_json" | jq -r '.path') || return 1
	created_at=$(printf '%s\n' "$entry_json" | jq -r '.identity.created_at // empty') || return 1
	command -v python3 >/dev/null 2>&1 || return 1
	python3 - "$bucket_path" "$created_at" <<'PY'
import datetime
import pathlib
import sys

bucket = pathlib.Path(sys.argv[1])
created_raw = sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc)
try:
    if created_raw:
        created = datetime.datetime.fromisoformat(created_raw.replace("Z", "+00:00"))
    else:
        created = datetime.datetime.fromtimestamp(bucket.stat().st_mtime, datetime.timezone.utc)
    age = max(0, int((now - created).total_seconds()))
except (OSError, ValueError):
    raise SystemExit(1)
print(age)
PY
	return $?
}

_worktree_recovery_maintenance_measure_store() {
	local recovery_root="$1"
	local timeout_tenths="$2"

	_worktree_recovery_measure_path "$recovery_root" "$timeout_tenths"
	return $?
}

_worktree_recovery_maintenance_pressure_json() {
	local recovery_root="$1"
	local max_store_bytes="$2"
	local minimum_free_kb="$3"
	local minimum_free_percent="$4"
	local aggregate_timeout_tenths="$5"
	local measured=""
	local store_bytes="$WORKTREE_RECOVERY_PLAN_JSON_NULL"
	local confidence="$WORKTREE_RECOVERY_UNAVAILABLE"
	local ignored=""
	local pressure=false
	local reason="none"

	aidevops_disk_capacity_snapshot "$recovery_root" || return 1
	if [[ "$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB" -lt "$minimum_free_kb" ]]; then
		pressure=true
		reason="filesystem-free-kb-soft-limit"
	elif [[ $((AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB * 100)) -lt $((AIDEVOPS_DISK_CAPACITY_TOTAL_KB * minimum_free_percent)) ]]; then
		pressure=true
		reason="filesystem-free-percent-soft-limit"
	fi
	if [[ "$pressure" == "true" ]]; then
		store_bytes="$WORKTREE_RECOVERY_PLAN_JSON_NULL"
	else
		measured=$(_worktree_recovery_maintenance_measure_store "$recovery_root" \
			"$aggregate_timeout_tenths") || return 1
		IFS='|' read -r store_bytes confidence ignored <<<"$measured"
		if [[ "$confidence" == "$WORKTREE_RECOVERY_PLAN_CONFIDENCE_EXACT" && "$store_bytes" =~ ^[0-9]+$ ]]; then
			if [[ "$store_bytes" -gt "$max_store_bytes" ]]; then
				pressure=true
				reason="store-soft-limit"
			fi
		else
			store_bytes="$WORKTREE_RECOVERY_PLAN_JSON_NULL"
			reason="aggregate-size-unavailable"
		fi
	fi
	jq -cn --argjson active "$pressure" --arg reason "$reason" \
		--argjson store_bytes "$store_bytes" \
		--argjson available_kb "$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB" \
		--argjson available_percent "$AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT" \
		'{active:$active,reason:$reason,store_bytes:$store_bytes,
		available_kb:$available_kb,available_percent:$available_percent}'
	return $?
}

_worktree_recovery_maintenance_inventory_file() {
	local output_path="$1"
	local platform="$2"
	local inventory=""
	local raw_record=""
	local record_type=""
	local role=""
	local owner=""
	local state=""
	local path=""

	: >"$output_path" || return 1
	inventory=$(GIT_OPTIONAL_LOCKS=0 worktree_recovery_inventory "$platform") || return 1
	while IFS= read -r raw_record; do
		record_type="${raw_record%%$'\t'*}"
		[[ "$record_type" == "bucket" ]] || continue
		IFS=$'\t' read -r record_type role owner state path <<<"$raw_record"
		[[ "$role" == "current" && "$owner" == "framework" ]] || continue
		printf '%s\t%s\n' "$state" "$path" >>"$output_path" || return 1
	done <<<"$inventory"
	return 0
}

_worktree_recovery_maintenance_order_inventory() {
	local inventory_path="$1"
	local ordered_path="$2"
	local offset="$3"
	local index=0
	local raw_record=""

	: >"$ordered_path" || return 1
	while IFS= read -r raw_record; do
		[[ "$index" -lt "$offset" ]] || printf '%s\n' "$raw_record" >>"$ordered_path" || return 1
		index=$((index + 1))
	done <"$inventory_path"
	index=0
	while IFS= read -r raw_record; do
		[[ "$index" -ge "$offset" ]] || printf '%s\n' "$raw_record" >>"$ordered_path" || return 1
		index=$((index + 1))
	done <"$inventory_path"
	return 0
}

_worktree_recovery_maintenance_zero_reason_counts_json() {
	jq -cn '{unknown_archive:0,sizing_unavailable:0,classification_unavailable:0,
		identity_or_size_changed:0,required_evidence_unavailable:0,
		unrecognised_evidence_state:0,age_unavailable:0,archive_worktree_dirty:0,
		active_git_worktree_reference:0,active_registry_owner:0,active_session_claim:0,
		active_process_reference:0,open_pull_request:0,source_removal_not_complete:0,
		detached_or_unresolved_branch:0,exact_commit_not_merged:0,linked_task_not_closed:0,
		protected_other:0,retention_policy:0,selection_limit:0}'
	return $?
}

_worktree_recovery_maintenance_record_reason() {
	local output_path="$1"
	local disposition="$2"
	local reason="$3"
	local safe_reason=""

	case "$reason" in
		unknown-archive) safe_reason="unknown_archive" ;;
		sizing-unavailable) safe_reason="sizing_unavailable" ;;
		classification-unavailable) safe_reason="classification_unavailable" ;;
		identity-or-size-changed) safe_reason="identity_or_size_changed" ;;
		required-evidence-unavailable) safe_reason="required_evidence_unavailable" ;;
		unrecognised-evidence-state) safe_reason="unrecognised_evidence_state" ;;
		age-unavailable) safe_reason="age_unavailable" ;;
		archive-worktree-dirty) safe_reason="archive_worktree_dirty" ;;
		active-git-worktree-reference) safe_reason="active_git_worktree_reference" ;;
		active-registry-owner) safe_reason="active_registry_owner" ;;
		active-session-claim) safe_reason="active_session_claim" ;;
		active-process-reference) safe_reason="active_process_reference" ;;
		open-pull-request) safe_reason="open_pull_request" ;;
		source-removal-not-complete) safe_reason="source_removal_not_complete" ;;
		detached-or-unresolved-branch) safe_reason="detached_or_unresolved_branch" ;;
		exact-commit-not-merged) safe_reason="exact_commit_not_merged" ;;
		linked-task-not-closed) safe_reason="linked_task_not_closed" ;;
		retention-policy) safe_reason="retention_policy" ;;
		selection-limit) safe_reason="selection_limit" ;;
		*)
			if [[ "$disposition" == "$WORKTREE_RECOVERY_PLAN_DISPOSITION_PROTECTED" ]]; then
				safe_reason="protected_other"
			else
				safe_reason="classification_unavailable"
			fi
			;;
	esac
	printf '%s\n' "$safe_reason" >>"$output_path"
	return $?
}

_worktree_recovery_maintenance_reason_counts_json() {
	local reasons_path="$1"
	local zero_json=""

	zero_json=$(_worktree_recovery_maintenance_zero_reason_counts_json) || return 1
	jq -Rn --argjson zero "$zero_json" '
		reduce inputs as $reason ($zero;
			if has($reason) then .[$reason] += 1
			else .classification_unavailable += 1 end)
	' "$reasons_path"
	return $?
}

_worktree_recovery_maintenance_normalize_reason_counts() {
	local state_path="$1"
	local zero_json=""

	zero_json=$(_worktree_recovery_maintenance_zero_reason_counts_json) || return 1
	jq -ce --argjson zero "$zero_json" '
		.reason_counts as $observed |
		$zero | with_entries(.value = ($observed[.key] // 0)) |
		if ([.[]] | all(type == "number" and floor == . and . >= 0 and . <= 1000000000))
		then . else error("invalid reason count") end
	' "$state_path"
	return $?
}

_worktree_recovery_maintenance_load_cycle_state() {
	local state_dir="$1"
	local cycle_path="${state_dir}/zero-candidate-cycle.json"
	local metadata=""
	local schema=""
	local inventory_digest=""
	local inventory_count=""
	local pressure_active=""
	local scanned_in_cycle=""
	local completed_cycles=""
	local normalized_reasons=""

	WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_CYCLE_SCANNED=0
	WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_COMPLETED_CYCLES=0
	WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_CYCLE_REASONS_JSON=$(
		_worktree_recovery_maintenance_zero_reason_counts_json
	) || return 1
	[[ -e "$cycle_path" || -L "$cycle_path" ]] || return 0
	[[ -f "$cycle_path" && ! -L "$cycle_path" ]] || return 1
	metadata=$(jq -er '[.schema,.inventory_digest,.inventory_count,.pressure_active,
		.scanned_in_cycle,.completed_cycles] | @tsv' "$cycle_path") || return 1
	IFS=$'\t' read -r schema inventory_digest inventory_count pressure_active \
		scanned_in_cycle completed_cycles <<<"$metadata"
	[[ "$schema" == "$WORKTREE_RECOVERY_MAINTENANCE_CYCLE_SCHEMA" &&
		"$inventory_digest" =~ ^[0-9a-f]{64}$ && "$inventory_count" =~ ^[0-9]+$ &&
		"$pressure_active" =~ ^(true|false)$ && "$scanned_in_cycle" =~ ^[0-9]+$ &&
		"$completed_cycles" =~ ^[0-9]+$ && "$completed_cycles" -le 1000000000 ]] || return 1
	normalized_reasons=$(_worktree_recovery_maintenance_normalize_reason_counts "$cycle_path") || return 1
	if [[ "$inventory_digest" != "$WORKTREE_RECOVERY_MAINTENANCE_INVENTORY_DIGEST" ||
		"$inventory_count" != "$WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT" ||
		"$pressure_active" != "$WORKTREE_RECOVERY_MAINTENANCE_PRESSURE_ACTIVE" ]]; then
		return 0
	fi
	[[ "$inventory_count" -eq 0 || "$scanned_in_cycle" -lt "$inventory_count" ]] || return 1
	WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_CYCLE_SCANNED="$scanned_in_cycle"
	WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_COMPLETED_CYCLES="$completed_cycles"
	WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_CYCLE_REASONS_JSON="$normalized_reasons"
	return 0
}

_worktree_recovery_maintenance_replace_cycle_state() {
	local cycle_path="$1"
	local payload="$2"
	local temp_path="${cycle_path}.tmp.$$-${RANDOM}"
	local previous_umask=""

	[[ ! -e "$temp_path" && ! -L "$temp_path" ]] || return 1
	if [[ -e "$cycle_path" || -L "$cycle_path" ]]; then
		[[ -f "$cycle_path" && ! -L "$cycle_path" ]] || return 1
	fi
	previous_umask=$(umask)
	umask 077
	if ! printf '%s\n' "$payload" >"$temp_path"; then
		umask "$previous_umask"
		return 1
	fi
	umask "$previous_umask"
	chmod 600 "$temp_path" || return 1
	mv -f "$temp_path" "$cycle_path" || return 1
	return 0
}

_worktree_recovery_maintenance_update_cycle_state() {
	local state_dir="$1"
	local cycle_path="${state_dir}/zero-candidate-cycle.json"
	local zero_json=""
	local combined_reasons=""
	local state_reasons=""
	local total_scanned=0
	local state_scanned=0
	local completed_cycles=0
	local payload=""

	zero_json=$(_worktree_recovery_maintenance_zero_reason_counts_json) || return 1
	WORKTREE_RECOVERY_MAINTENANCE_CYCLE_REASON_COUNTS_JSON="$WORKTREE_RECOVERY_MAINTENANCE_REASON_COUNTS_JSON"
	WORKTREE_RECOVERY_MAINTENANCE_CYCLE_SCANNED=0
	WORKTREE_RECOVERY_MAINTENANCE_CYCLE_COMPLETE=false
	WORKTREE_RECOVERY_MAINTENANCE_COMPLETED_CYCLES=0
	if [[ "$WORKTREE_RECOVERY_MAINTENANCE_SELECTED" -gt 0 ||
		"$WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT" -eq 0 ]]; then
		if [[ -e "$cycle_path" || -L "$cycle_path" ]]; then
			[[ -f "$cycle_path" && ! -L "$cycle_path" ]] || return 1
			rm -f "$cycle_path" || return 1
		fi
		return 0
	fi
	combined_reasons=$(jq -cn \
		--argjson previous "$WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_CYCLE_REASONS_JSON" \
		--argjson current "$WORKTREE_RECOVERY_MAINTENANCE_REASON_COUNTS_JSON" '
		$previous | with_entries(.value += $current[.key])
	') || return 1
	total_scanned=$((WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_CYCLE_SCANNED + WORKTREE_RECOVERY_MAINTENANCE_SCANNED))
	[[ "$total_scanned" -le "$WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT" ]] || return 1
	completed_cycles="$WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_COMPLETED_CYCLES"
	state_scanned="$total_scanned"
	state_reasons="$combined_reasons"
	if [[ "$total_scanned" -eq "$WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT" ]]; then
		WORKTREE_RECOVERY_MAINTENANCE_CYCLE_COMPLETE=true
		completed_cycles=$((completed_cycles + 1))
		state_scanned=0
		state_reasons="$zero_json"
	fi
	WORKTREE_RECOVERY_MAINTENANCE_CYCLE_REASON_COUNTS_JSON="$combined_reasons"
	WORKTREE_RECOVERY_MAINTENANCE_CYCLE_SCANNED="$total_scanned"
	WORKTREE_RECOVERY_MAINTENANCE_COMPLETED_CYCLES="$completed_cycles"
	payload=$(jq -cn --arg schema "$WORKTREE_RECOVERY_MAINTENANCE_CYCLE_SCHEMA" \
		--arg digest "$WORKTREE_RECOVERY_MAINTENANCE_INVENTORY_DIGEST" \
		--argjson inventory_count "$WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT" \
		--argjson pressure_active "$WORKTREE_RECOVERY_MAINTENANCE_PRESSURE_ACTIVE" \
		--argjson scanned_in_cycle "$state_scanned" \
		--argjson completed_cycles "$completed_cycles" --argjson reason_counts "$state_reasons" \
		'{schema:$schema,inventory_digest:$digest,inventory_count:$inventory_count,
		pressure_active:$pressure_active,scanned_in_cycle:$scanned_in_cycle,
		completed_cycles:$completed_cycles,reason_counts:$reason_counts}') || return 1
	_worktree_recovery_maintenance_replace_cycle_state "$cycle_path" "$payload"
	return $?
}

_worktree_recovery_maintenance_reset_scan_counters() {
	WORKTREE_RECOVERY_MAINTENANCE_SCANNED=0
	WORKTREE_RECOVERY_MAINTENANCE_PROTECTED=0
	WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN=0
	WORKTREE_RECOVERY_MAINTENANCE_SELECTED=0
	WORKTREE_RECOVERY_MAINTENANCE_SELECTED_BYTES=0
	WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_ARCHIVE=0
	WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_SIZING=0
	WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_CLASSIFICATION=0
	WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_AGE=0
	WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_EVIDENCE=0
	WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_POLICY=0
	WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_LIMIT=0
	return 0
}

_worktree_recovery_maintenance_scan() {
	local ordered_path="$1"
	local selected_path="$2"
	local max_scan="$3"
	local max_candidates="$4"
	local max_bytes="$5"
	local retention_seconds="$6"
	local pressure_active="$7"
	local reasons_path="$8"
	local raw_record=""
	local state=""
	local bucket_path=""
	local measured=""
	local bytes=""
	local confidence=""
	local entry_json=""
	local disposition=""
	local primary_reason=""
	local age_seconds=""
	local selected_reason=""

	_worktree_recovery_maintenance_reset_scan_counters || return 1
	: >"$selected_path" || return 1
	while IFS= read -r raw_record; do
		[[ "$WORKTREE_RECOVERY_MAINTENANCE_SCANNED" -lt "$max_scan" ]] || break
		IFS=$'\t' read -r state bucket_path <<<"$raw_record"
		WORKTREE_RECOVERY_MAINTENANCE_SCANNED=$((WORKTREE_RECOVERY_MAINTENANCE_SCANNED + 1))
		if [[ "$state" != "attributed" ]]; then
			WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN + 1))
			WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_ARCHIVE=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_ARCHIVE + 1))
			_worktree_recovery_maintenance_record_reason "$reasons_path" "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" "unknown-archive" || return 1
			continue
		fi
		measured=$(_worktree_recovery_measure_path "$bucket_path") || return 1
		IFS='|' read -r bytes confidence _ <<<"$measured"
		if [[ "$confidence" != "$WORKTREE_RECOVERY_PLAN_CONFIDENCE_EXACT" || ! "$bytes" =~ ^[0-9]+$ ]]; then
			WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN + 1))
			WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_SIZING=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_SIZING + 1))
			_worktree_recovery_maintenance_record_reason "$reasons_path" "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" "sizing-unavailable" || return 1
			continue
		fi
		if ! entry_json=$(_worktree_recovery_plan_attributed_entry_json "current" "$bucket_path" "$bytes"); then
			WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN + 1))
			WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_CLASSIFICATION=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_CLASSIFICATION + 1))
			_worktree_recovery_maintenance_record_reason "$reasons_path" "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" "classification-unavailable" || return 1
			continue
		fi
		disposition=$(printf '%s\n' "$entry_json" | jq -r '.disposition') || return 1
		if [[ "$disposition" == "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" ]]; then
			WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN + 1))
			primary_reason=$(printf '%s\n' "$entry_json" | jq -r '.reasons[0] // empty') || return 1
			if [[ "$primary_reason" == "sizing-unavailable" ]]; then
				WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_SIZING=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_SIZING + 1))
			else
				WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_CLASSIFICATION=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_CLASSIFICATION + 1))
			fi
			_worktree_recovery_maintenance_record_reason "$reasons_path" "$disposition" "$primary_reason" || return 1
			continue
		elif [[ "$disposition" != "$WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE" ]]; then
			WORKTREE_RECOVERY_MAINTENANCE_PROTECTED=$((WORKTREE_RECOVERY_MAINTENANCE_PROTECTED + 1))
			WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_EVIDENCE=$((WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_EVIDENCE + 1))
			primary_reason=$(printf '%s\n' "$entry_json" | jq -r '.reasons[0] // empty') || return 1
			_worktree_recovery_maintenance_record_reason "$reasons_path" "$disposition" "$primary_reason" || return 1
			continue
		fi
		if ! age_seconds=$(_worktree_recovery_maintenance_age_seconds "$entry_json"); then
			WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN + 1))
			WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_AGE=$((WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_AGE + 1))
			_worktree_recovery_maintenance_record_reason "$reasons_path" "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" "age-unavailable" || return 1
			continue
		fi
		selected_reason=""
		if [[ "$age_seconds" -ge "$retention_seconds" ]]; then
			selected_reason="retention"
		elif [[ "$pressure_active" == "true" ]]; then
			selected_reason="pressure"
		fi
		if [[ -z "$selected_reason" ]]; then
			WORKTREE_RECOVERY_MAINTENANCE_PROTECTED=$((WORKTREE_RECOVERY_MAINTENANCE_PROTECTED + 1))
			WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_POLICY=$((WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_POLICY + 1))
			_worktree_recovery_maintenance_record_reason "$reasons_path" "protected" "retention-policy" || return 1
			continue
		fi
		if [[ "$WORKTREE_RECOVERY_MAINTENANCE_SELECTED" -ge "$max_candidates" ||
			$((WORKTREE_RECOVERY_MAINTENANCE_SELECTED_BYTES + bytes)) -gt "$max_bytes" ]]; then
			WORKTREE_RECOVERY_MAINTENANCE_PROTECTED=$((WORKTREE_RECOVERY_MAINTENANCE_PROTECTED + 1))
			WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_LIMIT=$((WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_LIMIT + 1))
			_worktree_recovery_maintenance_record_reason "$reasons_path" "protected" "selection-limit" || return 1
			continue
		fi
		printf '%s\n' "$entry_json" | jq -c --arg reason "$selected_reason" \
			--argjson age_seconds "$age_seconds" \
			'. + {maintenance:{selected_reason:$reason,age_seconds:$age_seconds}}' \
			>>"$selected_path" || return 1
		WORKTREE_RECOVERY_MAINTENANCE_SELECTED=$((WORKTREE_RECOVERY_MAINTENANCE_SELECTED + 1))
		WORKTREE_RECOVERY_MAINTENANCE_SELECTED_BYTES=$((WORKTREE_RECOVERY_MAINTENANCE_SELECTED_BYTES + bytes))
	done <"$ordered_path"
	return 0
}

_worktree_recovery_maintenance_plan_json() {
	local selected_path="$1"
	local policy_json="$2"
	local entries_json=""
	local plan_material=""
	local plan_digest=""
	local plan_id=""
	local generated_at=""
	local plan_json=""
	local authorization=""

	entries_json=$(jq -sc 'sort_by(.maintenance.age_seconds) | reverse' "$selected_path") || return 1
	plan_material=$(jq -cn --arg schema "$WORKTREE_RECOVERY_PLAN_SCHEMA" \
		--argjson entries "$entries_json" --argjson automatic_policy "$policy_json" \
		'{schema:$schema,inventory_complete:true,inventory_error:null,entries:$entries,
		automatic_policy:$automatic_policy}') || return 1
	plan_digest=$(_worktree_recovery_plan_sha256_text "$plan_material") || return 1
	plan_id="sha256:$plan_digest"
	generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	plan_json=$(jq -cn --arg schema "$WORKTREE_RECOVERY_PLAN_SCHEMA" --arg producer "$WORKTREE_RECOVERY_PRODUCER" \
		--arg plan_id "$plan_id" --arg generated_at "$generated_at" \
		--argjson entries "$entries_json" --argjson automatic_policy "$policy_json" '
		def parent_path: .[0:rindex("/")];
		{schema:$schema,producer:$producer,plan_id:$plan_id,generated_at:$generated_at,read_only:true,
		inventory_complete:true,inventory_error:null,source_roots:([$entries[].path | parent_path] | unique),
		entry_count:($entries | length),sized_entry_count:($entries | length),unavailable_size_count:0,
		expected_allocated_bytes:([$entries[].expected_allocated_bytes] | add // 0),
		candidate_count:($entries | length),candidate_bytes:([$entries[].expected_allocated_bytes] | add // 0),
		protected_count:0,protected_bytes:0,unknown_count:0,unknown_bytes:0,
		automatic_policy:$automatic_policy,entries:$entries}') || return 1
	authorization=$(_worktree_recovery_plan_automatic_token "$plan_id" \
		"$(printf '%s\n' "$policy_json" | jq -cS '.')" \
		"$WORKTREE_RECOVERY_MAINTENANCE_SELECTED" "$WORKTREE_RECOVERY_MAINTENANCE_SELECTED_BYTES") || return 1
	printf '%s\n' "$plan_json" | jq -c --arg authorization "$authorization" \
		'. + {confirmation_token:$authorization}'
	return $?
}

_worktree_recovery_maintenance_limits_json() {
	local recovery_root="$1"
	local max_scan=""
	local max_candidates=""
	local max_bytes=""
	local retention_days=""
	local max_store_bytes=""
	local minimum_free_kb=""
	local minimum_free_percent=""
	local aggregate_timeout_tenths=""
	local pressure_json=""

	max_scan=$(_worktree_recovery_maintenance_uint "${AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN:-50}" 50 1 500)
	max_candidates=$(_worktree_recovery_maintenance_uint "${AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_CANDIDATES:-20}" 20 1 100)
	[[ "$max_candidates" -le "$max_scan" ]] || max_candidates="$max_scan"
	max_bytes=$(_worktree_recovery_maintenance_uint "${AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_BYTES:-5368709120}" 5368709120 1 1099511627776)
	retention_days=$(_worktree_recovery_maintenance_uint "${AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS:-7}" 7 1 3650)
	max_store_bytes=$(_worktree_recovery_maintenance_uint "${AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES:-5368709120}" 5368709120 1 1099511627776)
	minimum_free_kb=$(_worktree_recovery_maintenance_uint "${AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB:-10485760}" 10485760 0 1099511627776)
	minimum_free_percent=$(_worktree_recovery_maintenance_uint "${AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT:-10}" 10 0 100)
	aggregate_timeout_tenths=$(_worktree_recovery_maintenance_uint \
		"${AIDEVOPS_WORKTREE_RECOVERY_AGGREGATE_SIZE_TIMEOUT_TENTHS:-20}" 20 1 36000)
	pressure_json=$(_worktree_recovery_maintenance_pressure_json "$recovery_root" "$max_store_bytes" \
		"$minimum_free_kb" "$minimum_free_percent" "$aggregate_timeout_tenths") || return 1
	jq -cn --argjson max_scan "$max_scan" --argjson max_candidates "$max_candidates" \
		--argjson max_bytes "$max_bytes" --argjson retention_days "$retention_days" \
		--argjson max_store_bytes "$max_store_bytes" --argjson minimum_free_kb "$minimum_free_kb" \
		--argjson minimum_free_percent "$minimum_free_percent" --argjson pressure "$pressure_json" \
		'{max_scan:$max_scan,max_candidates:$max_candidates,max_bytes:$max_bytes,
		retention_days:$retention_days,max_store_bytes:$max_store_bytes,
		minimum_free_kb:$minimum_free_kb,minimum_free_percent:$minimum_free_percent,
		pressure:$pressure}'
	return $?
}

_worktree_recovery_maintenance_create_selection_temp_files() {
	local temp_root="${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}"

	WORKTREE_RECOVERY_MAINTENANCE_TEMP_INVENTORY=$(mktemp "${temp_root}/aidevops-recovery-maintenance-inventory.XXXXXX") || return 1
	WORKTREE_RECOVERY_MAINTENANCE_TEMP_ORDERED=$(mktemp "${temp_root}/aidevops-recovery-maintenance-ordered.XXXXXX") || {
		rm -f "$WORKTREE_RECOVERY_MAINTENANCE_TEMP_INVENTORY"
		return 1
	}
	WORKTREE_RECOVERY_MAINTENANCE_TEMP_SELECTED=$(mktemp "${temp_root}/aidevops-recovery-maintenance-selected.XXXXXX") || {
		rm -f "$WORKTREE_RECOVERY_MAINTENANCE_TEMP_INVENTORY" "$WORKTREE_RECOVERY_MAINTENANCE_TEMP_ORDERED"
		return 1
	}
	WORKTREE_RECOVERY_MAINTENANCE_TEMP_REASONS=$(mktemp "${temp_root}/aidevops-recovery-maintenance-reasons.XXXXXX") || {
		rm -f "$WORKTREE_RECOVERY_MAINTENANCE_TEMP_INVENTORY" \
			"$WORKTREE_RECOVERY_MAINTENANCE_TEMP_ORDERED" "$WORKTREE_RECOVERY_MAINTENANCE_TEMP_SELECTED"
		return 1
	}
	return 0
}

_worktree_recovery_maintenance_build_selection_plan() {
	local limits_json="$1"
	local selected_path="$2"
	local policy_json=""

	policy_json=$(printf '%s\n' "$limits_json" | jq -c \
		--arg schema "$WORKTREE_RECOVERY_AUTOMATION_POLICY_SCHEMA" \
		--arg policy_id "$WORKTREE_RECOVERY_AUTOMATION_POLICY_ID" \
		--argjson scanned "$WORKTREE_RECOVERY_MAINTENANCE_SCANNED" \
		--argjson protected "$WORKTREE_RECOVERY_MAINTENANCE_PROTECTED" \
		--argjson unknown "$WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN" '
		{schema:$schema,policy_id:$policy_id,retention_days:.retention_days,max_scan:.max_scan,
		max_candidates:.max_candidates,max_bytes:.max_bytes,max_store_bytes:.max_store_bytes,
		pressure_min_free_kb:.minimum_free_kb,pressure_min_free_percent:.minimum_free_percent,
		pressure_active:.pressure.active,pressure_reason:.pressure.reason,
		store_bytes:.pressure.store_bytes,available_kb:.pressure.available_kb,
		available_percent:.pressure.available_percent,scanned_count:$scanned,
		protected_count:$protected,unknown_count:$unknown}') || return 1
	WORKTREE_RECOVERY_MAINTENANCE_POLICY_JSON="$policy_json"
	if [[ "$WORKTREE_RECOVERY_MAINTENANCE_SELECTED" -gt 0 ]]; then
		WORKTREE_RECOVERY_MAINTENANCE_PLAN_JSON=$(_worktree_recovery_maintenance_plan_json \
			"$selected_path" "$policy_json") || return 1
	fi
	return 0
}

_worktree_recovery_maintenance_prepare_selection() {
	local state_dir="$1"
	local platform="$2"
	local limits_json="$3"
	local inventory_path=""
	local ordered_path=""
	local selected_path=""
	local reasons_path=""
	local cursor_path="${state_dir}/cursor"
	local offset=0
	local bucket_count=0
	local max_scan=""
	local scan_limit=0
	local cycle_remaining=0
	local max_candidates=""
	local max_bytes=""
	local retention_days=""
	local retention_seconds=""
	local pressure_active=""
	WORKTREE_RECOVERY_MAINTENANCE_POLICY_JSON=""
	WORKTREE_RECOVERY_MAINTENANCE_PLAN_JSON=""
	max_scan=$(printf '%s\n' "$limits_json" | jq -r '.max_scan') || return 1
	max_candidates=$(printf '%s\n' "$limits_json" | jq -r '.max_candidates') || return 1
	max_bytes=$(printf '%s\n' "$limits_json" | jq -r '.max_bytes') || return 1
	retention_days=$(printf '%s\n' "$limits_json" | jq -r '.retention_days') || return 1
	retention_seconds=$((retention_days * 86400))
	pressure_active=$(printf '%s\n' "$limits_json" | jq -r '.pressure.active') || return 1
	_worktree_recovery_maintenance_create_selection_temp_files || return 1
	inventory_path="$WORKTREE_RECOVERY_MAINTENANCE_TEMP_INVENTORY"
	ordered_path="$WORKTREE_RECOVERY_MAINTENANCE_TEMP_ORDERED"
	selected_path="$WORKTREE_RECOVERY_MAINTENANCE_TEMP_SELECTED"
	reasons_path="$WORKTREE_RECOVERY_MAINTENANCE_TEMP_REASONS"
	if ! _worktree_recovery_maintenance_inventory_file "$inventory_path" "$platform"; then
		rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
		return 1
	fi
	bucket_count=$(wc -l <"$inventory_path" | tr -d ' ') || bucket_count=""
	if [[ ! "$bucket_count" =~ ^[0-9]+$ ]]; then
		rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
		return 1
	fi
	WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT="$bucket_count"
	WORKTREE_RECOVERY_MAINTENANCE_INVENTORY_DIGEST=$(
		_worktree_recovery_plan_sha256_file "$inventory_path"
	) || {
		rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
		return 1
	}
	WORKTREE_RECOVERY_MAINTENANCE_PRESSURE_ACTIVE="$pressure_active"
	if ! _worktree_recovery_maintenance_load_cycle_state "$state_dir"; then
		rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
		return 1
	fi
	if [[ -e "$cursor_path" || -L "$cursor_path" ]]; then
		if [[ ! -f "$cursor_path" || -L "$cursor_path" ]]; then
			rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
			return 1
		fi
		IFS= read -r offset <"$cursor_path" || offset=0
		[[ "$offset" =~ ^[0-9]+$ ]] || offset=0
	fi
	if [[ "$bucket_count" -gt 0 ]]; then offset=$((offset % bucket_count)); else offset=0; fi
	WORKTREE_RECOVERY_MAINTENANCE_CURSOR_BEFORE="$offset"
	WORKTREE_RECOVERY_MAINTENANCE_CURSOR_AFTER=0
	scan_limit="$max_scan"
	if [[ "$bucket_count" -gt 0 ]]; then
		cycle_remaining=$((bucket_count - WORKTREE_RECOVERY_MAINTENANCE_PREVIOUS_CYCLE_SCANNED))
		[[ "$scan_limit" -le "$cycle_remaining" ]] || scan_limit="$cycle_remaining"
	fi
	if ! _worktree_recovery_maintenance_order_inventory "$inventory_path" "$ordered_path" "$offset" ||
		! _worktree_recovery_maintenance_scan "$ordered_path" "$selected_path" "$scan_limit" \
			"$max_candidates" "$max_bytes" "$retention_seconds" "$pressure_active" "$reasons_path"; then
		rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
		return 1
	fi
	WORKTREE_RECOVERY_MAINTENANCE_REASON_COUNTS_JSON=$(
		_worktree_recovery_maintenance_reason_counts_json "$reasons_path"
	) || {
		rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
		return 1
	}
	if ! _worktree_recovery_maintenance_update_cycle_state "$state_dir"; then
		rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
		return 1
	fi
	if [[ "$bucket_count" -gt 0 ]]; then
		WORKTREE_RECOVERY_MAINTENANCE_CURSOR_AFTER=$(((offset + WORKTREE_RECOVERY_MAINTENANCE_SCANNED) % bucket_count))
		printf '%s\n' "$WORKTREE_RECOVERY_MAINTENANCE_CURSOR_AFTER" >"$cursor_path" || {
			rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
			return 1
		}
	fi
	_worktree_recovery_maintenance_build_selection_plan "$limits_json" "$selected_path" || {
		rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
		return 1
	}
	rm -f "$inventory_path" "$ordered_path" "$selected_path" "$reasons_path"
	return 0
}

_worktree_recovery_maintenance_diagnostics_json() {
	local coverage_complete=false
	local coverage_percent=100

	if [[ "$WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT" -gt 0 ]]; then
		coverage_percent=$((WORKTREE_RECOVERY_MAINTENANCE_SCANNED * 100 / WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT))
		[[ "$coverage_percent" -le 100 ]] || coverage_percent=100
	fi
	if [[ "$WORKTREE_RECOVERY_MAINTENANCE_SCANNED" -ge "$WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT" ]]; then
		coverage_complete=true
	fi
	jq -cn \
		--argjson inventory_count "$WORKTREE_RECOVERY_MAINTENANCE_BUCKET_COUNT" \
		--argjson scanned_count "$WORKTREE_RECOVERY_MAINTENANCE_SCANNED" \
		--argjson cursor_before "$WORKTREE_RECOVERY_MAINTENANCE_CURSOR_BEFORE" \
		--argjson cursor_after "$WORKTREE_RECOVERY_MAINTENANCE_CURSOR_AFTER" \
		--argjson coverage_complete "$coverage_complete" \
		--argjson coverage_percent "$coverage_percent" \
		--argjson unknown_archive "$WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_ARCHIVE" \
		--argjson unknown_sizing "$WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_SIZING" \
		--argjson unknown_classification "$WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_CLASSIFICATION" \
		--argjson unknown_age "$WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN_AGE" \
		--argjson protected_evidence "$WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_EVIDENCE" \
		--argjson protected_policy "$WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_POLICY" \
		--argjson protected_limit "$WORKTREE_RECOVERY_MAINTENANCE_PROTECTED_LIMIT" \
		--argjson classification_reason_counts "$WORKTREE_RECOVERY_MAINTENANCE_REASON_COUNTS_JSON" \
		--argjson cycle_reason_counts "$WORKTREE_RECOVERY_MAINTENANCE_CYCLE_REASON_COUNTS_JSON" \
		--argjson cycle_scanned "$WORKTREE_RECOVERY_MAINTENANCE_CYCLE_SCANNED" \
		--argjson cycle_complete "$WORKTREE_RECOVERY_MAINTENANCE_CYCLE_COMPLETE" \
		--argjson completed_cycles "$WORKTREE_RECOVERY_MAINTENANCE_COMPLETED_CYCLES" \
		'{inventory_count:$inventory_count,scanned_count:$scanned_count,
		cursor_before:$cursor_before,cursor_after:$cursor_after,
		coverage_complete:$coverage_complete,coverage_percent:$coverage_percent,
		reason_counts:{unknown_archive:$unknown_archive,unknown_sizing:$unknown_sizing,
		unknown_classification:$unknown_classification,unknown_age:$unknown_age,
		protected_evidence:$protected_evidence,protected_policy:$protected_policy,
		protected_limit:$protected_limit},classification_reason_counts:$classification_reason_counts,
		zero_candidate_cycle:{scanned_count:$cycle_scanned,completed_this_run:$cycle_complete,
		completed_cycles:$completed_cycles,reason_counts:$cycle_reason_counts}}'
	return $?
}

_worktree_recovery_maintenance_write_new() {
	local output_path="$1"
	local payload="$2"
	local temp_path="${output_path}.tmp.$$-${RANDOM}"
	local previous_umask=""

	[[ ! -e "$output_path" && ! -L "$output_path" ]] || return 1
	previous_umask=$(umask)
	umask 077
	if ! (set -C && printf '%s\n' "$payload" >"$temp_path"); then
		umask "$previous_umask"
		return 1
	fi
	umask "$previous_umask"
	chmod 600 "$temp_path" || return 1
	mv "$temp_path" "$output_path" || return 1
	return 0
}

_worktree_recovery_maintenance_finalize_pending() {
	local state_dir="$1"
	local pending_dir="${state_dir}/pending"
	local plan_path="${pending_dir}/plan.json"
	local receipt_path="${pending_dir}/receipt.json"
	local completed_root="${state_dir}/completed"
	local plan_id=""
	local destination=""

	jq -e '.complete == true' "$receipt_path" >/dev/null 2>&1 || return 1
	plan_id=$(jq -r '.plan_id' "$plan_path") || return 1
	[[ "$plan_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
	mkdir -p "$completed_root" || return 1
	destination="${completed_root}/${plan_id#sha256:}"
	[[ ! -e "$destination" && ! -L "$destination" ]] || return 1
	mv "$pending_dir" "$destination" || return 1
	printf '%s\n' "$destination"
	return 0
}

_worktree_recovery_maintenance_resume_pending() {
	local state_dir="$1"
	local pending_dir="${state_dir}/pending"
	local plan_path="${pending_dir}/plan.json"
	local receipt_path="${pending_dir}/receipt.json"
	local completed_dir=""
	local reclaimed_bytes=""

	[[ -e "$pending_dir" || -L "$pending_dir" ]] || return 2
	[[ -d "$pending_dir" && ! -L "$pending_dir" && -f "$plan_path" && ! -L "$plan_path" ]] || return 1
	worktree_recovery_apply_automatic "$plan_path" "$receipt_path" >/dev/null || return 1
	reclaimed_bytes=$(jq -r '.observed_allocated_bytes' "$receipt_path") || return 1
	completed_dir=$(_worktree_recovery_maintenance_finalize_pending "$state_dir") || return 1
	jq -cn --arg schema "$WORKTREE_RECOVERY_MAINTENANCE_RUN_SCHEMA" \
		--arg outcome "resumed-and-removed" --arg receipt "${completed_dir}/receipt.json" \
		--argjson reclaimed_bytes "$reclaimed_bytes" \
		'{schema:$schema,outcome:$outcome,reclaimed_bytes:$reclaimed_bytes,receipt:$receipt}'
	return 0
}

_worktree_recovery_maintenance_no_candidates_json() {
	local policy_json="$1"
	local diagnostics_json="$2"

	printf '%s\n' "$policy_json" | jq -c \
		--arg schema "$WORKTREE_RECOVERY_MAINTENANCE_RUN_SCHEMA" \
		--argjson diagnostics "$diagnostics_json" \
		'{schema:$schema,outcome:"no-candidates",reclaimed_bytes:0,policy:.,diagnostics:$diagnostics,
		escalation:(if (.pressure_active == true and $diagnostics.zero_candidate_cycle.completed_this_run == true)
		then {required:true,reason:"pressure-zero-candidate-cycle",authority:"read-only",
		command:["worktree-helper.sh","recovery","plan","--output","<absolute-new-path>"]}
		else {required:false,reason:null,authority:null,command:null} end)}'
	return $?
}

_worktree_recovery_maintenance_removed_json() {
	local completed_dir="$1"
	local reclaimed_bytes="$2"
	local diagnostics_json="$3"

	jq -cn --arg schema "$WORKTREE_RECOVERY_MAINTENANCE_RUN_SCHEMA" \
		--arg outcome "removed" --arg receipt "${completed_dir}/receipt.json" \
		--argjson diagnostics "$diagnostics_json" \
		--argjson scanned "$WORKTREE_RECOVERY_MAINTENANCE_SCANNED" \
		--argjson protected "$WORKTREE_RECOVERY_MAINTENANCE_PROTECTED" \
		--argjson unknown "$WORKTREE_RECOVERY_MAINTENANCE_UNKNOWN" \
		--argjson removed "$WORKTREE_RECOVERY_MAINTENANCE_SELECTED" \
		--argjson reclaimed_bytes "$reclaimed_bytes" \
		'{schema:$schema,outcome:$outcome,scanned:$scanned,protected:$protected,
		unknown:$unknown,removed:$removed,reclaimed_bytes:$reclaimed_bytes,receipt:$receipt,
		diagnostics:$diagnostics}'
	return $?
}

worktree_recovery_maintenance_run() {
	local platform=""
	local state_dir=""
	local recovery_root=""
	local limits_json=""
	local policy_json=""
	local plan_json=""
	local pending_dir=""
	local pending_init_dir=""
	local plan_path=""
	local receipt_path=""
	local completed_dir=""
	local reclaimed_bytes=""
	local diagnostics_json=""
	local resume_status=0
	local run_status=0

	if [[ "${AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_ENABLED:-1}" != "1" ]]; then
		jq -cn --arg schema "$WORKTREE_RECOVERY_MAINTENANCE_RUN_SCHEMA" \
			'{schema:$schema,outcome:"disabled",reclaimed_bytes:0}'
		return 0
	fi
	command -v jq >/dev/null 2>&1 || return 1
	platform=$(uname -s 2>/dev/null) || return 1
	if [[ "$platform" == "Darwin" || -n "${AIDEVOPS_WORKTREE_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}" ]]; then
		jq -cn --arg schema "$WORKTREE_RECOVERY_MAINTENANCE_RUN_SCHEMA" \
			'{schema:$schema,outcome:"joint-store-skipped",reclaimed_bytes:0}'
		return 0
	fi
	state_dir=$(_worktree_recovery_maintenance_state_dir) || return 1
	_worktree_recovery_maintenance_acquire_lock "$state_dir" || {
		jq -cn --arg schema "$WORKTREE_RECOVERY_MAINTENANCE_RUN_SCHEMA" \
			'{schema:$schema,outcome:"maintenance-lock-held",reclaimed_bytes:0}'
		return 0
	}
	if _worktree_recovery_maintenance_resume_pending "$state_dir"; then
		_worktree_recovery_maintenance_release_lock || return 1
		return 0
	else
		resume_status=$?
	fi
	if [[ "$resume_status" -ne 2 ]]; then
		_worktree_recovery_maintenance_release_lock || true
		return 1
	fi
	recovery_root=$(_worktree_recovery_store_root "$platform") || run_status=1
	if [[ "$run_status" -eq 0 && ! -d "$recovery_root" ]]; then
		jq -cn --arg schema "$WORKTREE_RECOVERY_MAINTENANCE_RUN_SCHEMA" \
			'{schema:$schema,outcome:"store-absent",reclaimed_bytes:0}'
		_worktree_recovery_maintenance_release_lock || return 1
		return 0
	fi
	[[ "$run_status" -eq 0 && -d "$recovery_root" && ! -L "$recovery_root" ]] || run_status=1
	[[ "$run_status" -ne 0 ]] || limits_json=$(_worktree_recovery_maintenance_limits_json "$recovery_root") || run_status=1
	[[ "$run_status" -ne 0 ]] || _worktree_recovery_maintenance_prepare_selection \
		"$state_dir" "$platform" "$limits_json" || run_status=1
	if [[ "$run_status" -ne 0 ]]; then
		_worktree_recovery_maintenance_release_lock || true
		return 1
	fi
	policy_json="$WORKTREE_RECOVERY_MAINTENANCE_POLICY_JSON"
	diagnostics_json=$(_worktree_recovery_maintenance_diagnostics_json) || {
		_worktree_recovery_maintenance_release_lock || true
		return 1
	}
	if [[ "$WORKTREE_RECOVERY_MAINTENANCE_SELECTED" -eq 0 ]]; then
		_worktree_recovery_maintenance_no_candidates_json "$policy_json" "$diagnostics_json"
		_worktree_recovery_maintenance_release_lock || return 1
		return 0
	fi
	plan_json="$WORKTREE_RECOVERY_MAINTENANCE_PLAN_JSON"
	pending_dir="${state_dir}/pending"
	pending_init_dir="${state_dir}/.pending-init.$$-${RANDOM}"
	[[ ! -e "$pending_dir" && ! -L "$pending_dir" && ! -e "$pending_init_dir" && ! -L "$pending_init_dir" ]] || run_status=1
	[[ "$run_status" -ne 0 ]] || mkdir "$pending_init_dir" || run_status=1
	plan_path="${pending_init_dir}/plan.json"
	receipt_path="${pending_dir}/receipt.json"
	[[ "$run_status" -ne 0 ]] || _worktree_recovery_maintenance_write_new "$plan_path" "$plan_json" || run_status=1
	[[ "$run_status" -ne 0 ]] || mv "$pending_init_dir" "$pending_dir" || run_status=1
	plan_path="${pending_dir}/plan.json"
	if [[ "$run_status" -eq 0 ]]; then
		worktree_recovery_apply_automatic "$plan_path" "$receipt_path" >/dev/null || run_status=1
	fi
	if [[ "$run_status" -eq 0 ]]; then
		reclaimed_bytes=$(jq -r '.observed_allocated_bytes' "$receipt_path") || run_status=1
		completed_dir=$(_worktree_recovery_maintenance_finalize_pending "$state_dir") || run_status=1
	fi
	if [[ -d "$pending_init_dir" && ! -L "$pending_init_dir" ]]; then
		rm -f "${pending_init_dir}/plan.json" 2>/dev/null || true
		rmdir "$pending_init_dir" 2>/dev/null || true
	fi
	_worktree_recovery_maintenance_release_lock || run_status=1
	[[ "$run_status" -eq 0 ]] || return 1
	_worktree_recovery_maintenance_removed_json "$completed_dir" "$reclaimed_bytes" \
		"$diagnostics_json"
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	set -euo pipefail
	worktree_recovery_maintenance_run
fi
