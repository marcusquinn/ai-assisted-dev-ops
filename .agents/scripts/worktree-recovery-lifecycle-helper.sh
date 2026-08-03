#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worktree-recovery-lifecycle-helper.sh — Read-only recovery archive inventory.

[[ "${_WORKTREE_RECOVERY_LIFECYCLE_HELPER_LOADED:-}" == "1" ]] && return 0
_WORKTREE_RECOVERY_LIFECYCLE_HELPER_LOADED=1

WORKTREE_RECOVERY_INVENTORY_SCHEMA="aidevops.worktree-recovery-inventory/v1"
WORKTREE_RECOVERY_INVALID_RECORD="invalid-inventory-record"
WORKTREE_RECOVERY_UNAVAILABLE="unavailable"

WORKTREE_RECOVERY_LIFECYCLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
if [[ -f "$WORKTREE_RECOVERY_LIFECYCLE_DIR/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "$WORKTREE_RECOVERY_LIFECYCLE_DIR/shared-constants.sh"
fi
if ! declare -F worktree_recovery_inventory >/dev/null 2>&1; then
	# shellcheck source=audit-worktree-removal-helper.sh
	source "$WORKTREE_RECOVERY_LIFECYCLE_DIR/audit-worktree-removal-helper.sh"
fi

_worktree_recovery_measure_path() {
	local path="$1"
	local du_command="${AIDEVOPS_WORKTREE_RECOVERY_DU_COMMAND:-${AIDEVOPS_STORAGE_DU_COMMAND:-du}}"
	local timeout_tenths="${AIDEVOPS_WORKTREE_RECOVERY_SIZE_TIMEOUT_TENTHS:-${AIDEVOPS_STORAGE_SIZE_TIMEOUT_TENTHS:-20}}"
	local output_file=""
	local pid=""
	local elapsed=0
	local kib=""
	local ignored=""

	case "$timeout_tenths" in
	'' | *[!0-9]*) timeout_tenths=20 ;;
	esac
	if [[ -L "$path" ]]; then
		printf 'null|unavailable|bucket-is-symlink'
		return 0
	fi
	if [[ ! -d "$path" ]]; then
		printf 'null|unavailable|bucket-is-unavailable'
		return 0
	fi
	if [[ ! -r "$path" ]]; then
		printf 'null|unavailable|bucket-is-unreadable'
		return 0
	fi
	if ! command -v "$du_command" >/dev/null 2>&1; then
		printf 'null|unavailable|sizing-command-unavailable'
		return 0
	fi
	output_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/aidevops-worktree-recovery-size.XXXXXX") || {
		printf 'null|unavailable|temporary-file-unavailable'
		return 0
	}
	LC_ALL=C "$du_command" -sk "$path" >"$output_file" 2>/dev/null &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if [[ "$elapsed" -ge "$timeout_tenths" ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			rm -f "$output_file"
			printf 'null|unavailable|sizing-timeout'
			return 0
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
	done
	if ! wait "$pid"; then
		rm -f "$output_file"
		printf 'null|unavailable|sizing-failed'
		return 0
	fi
	IFS=$'\t ' read -r kib ignored <"$output_file" || kib=""
	rm -f "$output_file"
	case "$kib" in
	'' | *[!0-9]*) printf 'null|unavailable|invalid-size-output' ;;
	*) printf '%s|exact|' "$((kib * 1024))" ;;
	esac
	return 0
}

_worktree_recovery_unavailable_json() {
	local error="$1"
	local display_path="$2"
	jq -cn \
		--arg schema "$WORKTREE_RECOVERY_INVENTORY_SCHEMA" \
		--arg confidence "$WORKTREE_RECOVERY_UNAVAILABLE" \
		--arg error "$error" \
		--arg path "$display_path" \
		'{schema:$schema,store_id:"worktree-recovery",producer:"worktree-helper",path:$path,owner:"unknown",safety_class:"recovery",policy:"manual-review; no deletion authority",total_bytes:null,protected_bytes:null,reclaimable_bytes:0,unknown_bytes:null,protection_reasons:["recovery classification or sizing is unavailable"],sizing_confidence:$confidence,next_action:"Restore HOME and run worktree-helper.sh recovery; leave archives untouched",error:$error,root_count:0,bucket_count:0,protected_count:0,reclaimable_count:0,unknown_count:0,buckets:[]}'
	return 0
}

_worktree_recovery_display_path() {
	local platform="$1"
	local configured_root="${AIDEVOPS_WORKTREE_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}"
	local home_label="~"
	if [[ -n "$configured_root" ]]; then
		printf 'configured worktree recovery root and attributable legacy roots'
	elif [[ "$platform" == "Darwin" ]]; then
		printf '%s/.Trash attributable worktree recovery buckets' "$home_label"
	else
		printf '%s/.aidevops/recovery/worktrees and attributable legacy roots' "$home_label"
	fi
	return 0
}

_worktree_recovery_encode_report() {
	local entries_file="$1"
	local display_path="$2"
	local report_owner="$3"
	local report_error="$4"
	local root_count="$5"
	local bucket_count="$6"
	local protected_count="$7"
	local unknown_count="$8"
	local total_bytes="$9"
	local protected_bytes="${10}"
	local unknown_bytes="${11}"
	local confidence="$WORKTREE_RECOVERY_UNAVAILABLE"

	[[ -n "$report_error" ]] || confidence="exact"
	jq -sc \
		--arg schema "$WORKTREE_RECOVERY_INVENTORY_SCHEMA" \
		--arg path "$display_path" \
		--arg owner "$report_owner" \
		--arg error "$report_error" \
		--arg confidence "$confidence" \
		--argjson root_count "$root_count" \
		--argjson bucket_count "$bucket_count" \
		--argjson protected_count "$protected_count" \
		--argjson unknown_count "$unknown_count" \
		--argjson total_bytes "$total_bytes" \
		--argjson protected_bytes "$protected_bytes" \
		--argjson unknown_bytes "$unknown_bytes" \
		'{schema:$schema,store_id:"worktree-recovery",producer:"worktree-helper",path:$path,owner:$owner,safety_class:"recovery",policy:"manual-review; v1/v2 compatibility; no deletion authority",total_bytes:$total_bytes,protected_bytes:$protected_bytes,reclaimable_bytes:0,unknown_bytes:$unknown_bytes,protection_reasons:["complete attributable archives remain protected; incomplete, malformed, symlinked, or unrecognised archives remain unknown"],sizing_confidence:$confidence,next_action:"Use worktree-helper.sh recovery for bucket details; no cleanup is available in this phase",error:(if $error == "" then null else $error end),root_count:$root_count,bucket_count:$bucket_count,protected_count:$protected_count,reclaimable_count:0,unknown_count:$unknown_count,archive_formats:["aidevops-worktree-recovery-v1","aidevops-worktree-recovery-v2"],buckets:.}' \
		"$entries_file"
	return $?
}

worktree_recovery_lifecycle_json() {
	local platform="${1:-}"
	local display_path="" inventory="" entries_file=""
	local record_type="" store_role="" owner="" state="" path=""
	local extra_one=""
	local extra_two=""
	local measured=""
	local bytes=""
	local confidence=""
	local measure_error=""
	local report_owner="framework"
	local report_error=""
	local root_count=0
	local bucket_count=0
	local protected_count=0
	local unknown_count=0
	local protected_bytes=0
	local unknown_bytes=0
	local total_bytes=0
	local jq_status=0

	if [[ -z "$platform" ]]; then
		platform=$(uname -s 2>/dev/null) || platform="unknown"
	fi
	display_path=$(_worktree_recovery_display_path "$platform") || return 1
	if [[ -z "${HOME:-}" ]]; then
		_worktree_recovery_unavailable_json "home-unavailable" "$display_path"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		printf '{"schema":"%s","error":"jq-unavailable"}\n' "$WORKTREE_RECOVERY_INVENTORY_SCHEMA"
		return 1
	fi
	if ! inventory=$(worktree_recovery_inventory "$platform"); then
		_worktree_recovery_unavailable_json "classification-unavailable" "$display_path"
		return 0
	fi
	entries_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/aidevops-worktree-recovery-inventory.XXXXXX") || {
		_worktree_recovery_unavailable_json "temporary-file-unavailable" "$display_path"
		return 0
	}
	while IFS=$'\t' read -r record_type store_role owner state path extra_one extra_two; do
		case "$record_type" in
		store)
			root_count=$((root_count + 1))
			[[ "$owner" != "joint" ]] || report_owner="joint"
			if [[ "$extra_one" == "$WORKTREE_RECOVERY_UNAVAILABLE" ]]; then
				report_error="root-unavailable"
			fi
			case "$extra_two" in
			*$'\t'*) report_error="$WORKTREE_RECOVERY_INVALID_RECORD" ;;
			esac
			;;
		bucket)
			bucket_count=$((bucket_count + 1))
			if [[ -n "$extra_one" || -n "$extra_two" ]]; then
				report_error="$WORKTREE_RECOVERY_INVALID_RECORD"
				continue
			fi
			measured=$(_worktree_recovery_measure_path "$path")
			IFS='|' read -r bytes confidence measure_error <<<"$measured"
			if [[ "$bytes" == "null" ]]; then
				report_error="${measure_error:-sizing-unavailable}"
				unknown_count=$((unknown_count + 1))
			else
				total_bytes=$((total_bytes + bytes))
				case "$state" in
				attributed | attributed-legacy)
					protected_count=$((protected_count + 1))
					protected_bytes=$((protected_bytes + bytes))
					;;
				*)
					unknown_count=$((unknown_count + 1))
					unknown_bytes=$((unknown_bytes + bytes))
					;;
				esac
			fi
			jq -cn --arg role "$store_role" --arg state "$state" --arg path "$path" \
				--arg confidence "$confidence" --arg error "$measure_error" --argjson bytes "$bytes" \
				'{role:$role,state:$state,path:$path,bytes:$bytes,sizing_confidence:$confidence,error:(if $error == "" then null else $error end)}' \
				>>"$entries_file" || report_error="entry-encoding-failed"
			;;
		'') ;;
		*) report_error="$WORKTREE_RECOVERY_INVALID_RECORD" ;;
		esac
	done <<<"$inventory"
	if [[ -n "$report_error" ]]; then
		total_bytes=null
		protected_bytes=null
		unknown_bytes=null
	fi
	_worktree_recovery_encode_report "$entries_file" "$display_path" "$report_owner" "$report_error" \
		"$root_count" "$bucket_count" "$protected_count" "$unknown_count" \
		"$total_bytes" "$protected_bytes" "$unknown_bytes"
	jq_status=$?
	rm -f "$entries_file"
	return "$jq_status"
}

_worktree_recovery_format_bytes() {
	local bytes="$1"
	if [[ "$bytes" == "null" ]]; then
		printf 'unavailable'
	elif [[ "$bytes" -ge 1073741824 ]]; then
		printf '%s.%s GiB' "$((bytes / 1073741824))" "$(((bytes % 1073741824) * 10 / 1073741824))"
	elif [[ "$bytes" -ge 1048576 ]]; then
		printf '%s.%s MiB' "$((bytes / 1048576))" "$(((bytes % 1048576) * 10 / 1048576))"
	elif [[ "$bytes" -ge 1024 ]]; then
		printf '%s.%s KiB' "$((bytes / 1024))" "$(((bytes % 1024) * 10 / 1024))"
	else
		printf '%s B' "$bytes"
	fi
	return 0
}

worktree_recovery_lifecycle_status() {
	local platform="${1:-}"
	local report=""
	local total_bytes=""
	local protected_bytes=""
	local unknown_bytes=""

	report=$(worktree_recovery_lifecycle_json "$platform") || return 1
	total_bytes=$(printf '%s\n' "$report" | jq -r '.total_bytes') || return 1
	protected_bytes=$(printf '%s\n' "$report" | jq -r '.protected_bytes') || return 1
	unknown_bytes=$(printf '%s\n' "$report" | jq -r '.unknown_bytes') || return 1
	printf 'Worktree Recovery Inventory (read-only)\n'
	printf '  buckets: %s protected, %s unknown, %s total\n' \
		"$(printf '%s\n' "$report" | jq -r '.protected_count')" \
		"$(printf '%s\n' "$report" | jq -r '.unknown_count')" \
		"$(printf '%s\n' "$report" | jq -r '.bucket_count')"
	printf '  bytes:   %s protected, %s unknown, %s total\n' \
		"$(_worktree_recovery_format_bytes "$protected_bytes")" \
		"$(_worktree_recovery_format_bytes "$unknown_bytes")" \
		"$(_worktree_recovery_format_bytes "$total_bytes")"
	printf '%s\n' "$report" | jq -r '.buckets[] | "  [\(.state)] \(.role): \(.path) (\(if .bytes == null then "size unavailable" else (.bytes | tostring) + " bytes" end))"'
	printf 'No cleanup was performed. OpenCode session history may aid recovery, but never authorizes deletion.\n'
	return 0
}

_worktree_recovery_lifecycle_usage() {
	printf '%s\n' 'Usage: worktree-recovery-lifecycle-helper.sh [status|json]'
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	case "${1:-status}" in
	json) worktree_recovery_lifecycle_json ;;
	status) worktree_recovery_lifecycle_status ;;
	help | --help | -h) _worktree_recovery_lifecycle_usage ;;
	*)
		_worktree_recovery_lifecycle_usage >&2
		exit 1
		;;
	esac
fi
