#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worktree-recovery-lifecycle-helper.sh — Read-only recovery archive inventory.

[[ "${_WORKTREE_RECOVERY_LIFECYCLE_HELPER_LOADED:-}" == "1" ]] && return 0
_WORKTREE_RECOVERY_LIFECYCLE_HELPER_LOADED=1

WORKTREE_RECOVERY_INVENTORY_SCHEMA="aidevops.worktree-recovery-inventory/v1"
WORKTREE_RECOVERY_INVALID_RECORD="invalid-inventory-record"
WORKTREE_RECOVERY_UNAVAILABLE="unavailable"
WORKTREE_RECOVERY_PLAN_SCHEMA="aidevops.worktree-recovery-plan/v2"
WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE="candidate"
WORKTREE_RECOVERY_PLAN_DISPOSITION_PROTECTED="protected"
WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN="unknown"
WORKTREE_RECOVERY_PLAN_STATE_ACTIVE="active"
WORKTREE_RECOVERY_PLAN_STATE_CLEAR="clear"
WORKTREE_RECOVERY_PLAN_CONFIDENCE_EXACT="exact"
WORKTREE_RECOVERY_PLAN_JSON_NULL="null"
WORKTREE_RECOVERY_PRODUCER="worktree-helper"
WORKTREE_RECOVERY_AUTOMATION_POLICY_SCHEMA="aidevops.worktree-recovery-automation-policy/v1"
WORKTREE_RECOVERY_AUTOMATION_POLICY_ID="bounded-terminal-evidence-v1"

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
		--arg producer "$WORKTREE_RECOVERY_PRODUCER" \
		--arg unknown "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" \
		--arg confidence "$WORKTREE_RECOVERY_UNAVAILABLE" \
		--arg error "$error" \
		--arg path "$display_path" \
		'{schema:$schema,store_id:"worktree-recovery",producer:$producer,path:$path,owner:$unknown,safety_class:"recovery",policy:"manual-review; no deletion authority",total_bytes:null,protected_bytes:null,reclaimable_bytes:0,unknown_bytes:null,protection_reasons:["recovery classification or sizing is unavailable"],sizing_confidence:$confidence,next_action:"Restore HOME and run worktree-helper.sh recovery; leave archives untouched",error:$error,root_count:0,bucket_count:0,protected_count:0,reclaimable_count:0,unknown_count:0,buckets:[]}'
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

	[[ -n "$report_error" ]] || confidence="$WORKTREE_RECOVERY_PLAN_CONFIDENCE_EXACT"
	jq -sc \
		--arg schema "$WORKTREE_RECOVERY_INVENTORY_SCHEMA" \
		--arg producer "$WORKTREE_RECOVERY_PRODUCER" \
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
		'{schema:$schema,store_id:"worktree-recovery",producer:$producer,path:$path,owner:$owner,safety_class:"recovery",policy:"aggregate inventory grants no deletion authority; exact manual and automatic plans are separate",total_bytes:$total_bytes,protected_bytes:$protected_bytes,reclaimable_bytes:0,unknown_bytes:$unknown_bytes,protection_reasons:["aggregate reporting conservatively protects attributable archives; incomplete, malformed, symlinked, or unrecognised archives remain unknown"],sizing_confidence:$confidence,next_action:"Use worktree-helper.sh recovery for bucket details; bounded maintenance independently revalidates exact terminal candidates",error:(if $error == "" then null else $error end),root_count:$root_count,bucket_count:$bucket_count,protected_count:$protected_count,reclaimable_count:0,unknown_count:$unknown_count,archive_formats:["aidevops-worktree-recovery-v1","aidevops-worktree-recovery-v2"],buckets:.}' \
		"$entries_file"
	return $?
}

worktree_recovery_lifecycle_json() {
	local platform="${1:-}"
	local display_path="" inventory="" entries_file="" raw_record=""
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
		platform=$(uname -s 2>/dev/null) || platform="$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN"
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
	if ! inventory=$(GIT_OPTIONAL_LOCKS=0 worktree_recovery_inventory "$platform"); then
		_worktree_recovery_unavailable_json "classification-unavailable" "$display_path"
		return 0
	fi
	entries_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/aidevops-worktree-recovery-inventory.XXXXXX") || {
		_worktree_recovery_unavailable_json "temporary-file-unavailable" "$display_path"
		return 0
	}
	while IFS= read -r raw_record; do
		record_type="${raw_record%%$'\t'*}"
		store_role=""
		owner=""
		state=""
		path=""
		extra_one=""
		extra_two=""
		case "$record_type" in
		store)
			IFS=$'\t' read -r record_type store_role owner state path extra_one extra_two <<<"$raw_record"
			root_count=$((root_count + 1))
			[[ "$owner" != "joint" ]] || report_owner="joint"
			if [[ "$extra_one" == "$WORKTREE_RECOVERY_UNAVAILABLE" ]]; then
				report_error="root-unavailable"
			fi
			;;
		bucket)
			IFS=$'\t' read -r record_type store_role owner state path <<<"$raw_record"
			bucket_count=$((bucket_count + 1))
			measured=$(_worktree_recovery_measure_path "$path")
			IFS='|' read -r bytes confidence measure_error <<<"$measured"
			if [[ "$bytes" == "$WORKTREE_RECOVERY_PLAN_JSON_NULL" ]]; then
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

_worktree_recovery_plan_sha256_text() {
	local payload="$1"
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$payload" | shasum -a 256 2>/dev/null) || return 1
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$payload" | sha256sum 2>/dev/null) || return 1
	else
		return 1
	fi
	digest="${digest%%[[:space:]]*}"
	[[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
	printf '%s\n' "$digest" | tr '[:upper:]' '[:lower:]'
	return 0
}

_worktree_recovery_plan_sha256_file() {
	local file_path="$1"
	local digest=""
	[[ -f "$file_path" && ! -L "$file_path" ]] || return 1
	if command -v shasum >/dev/null 2>&1; then
		digest=$(shasum -a 256 "$file_path" 2>/dev/null) || return 1
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(sha256sum "$file_path" 2>/dev/null) || return 1
	else
		return 1
	fi
	digest="${digest%%[[:space:]]*}"
	[[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
	printf '%s\n' "$digest" | tr '[:upper:]' '[:lower:]'
	return 0
}

_worktree_recovery_plan_confirmation_token() {
	local plan_id="$1"
	local candidate_count="$2"
	local candidate_bytes="$3"
	local confirmation_material=""
	local confirmation_digest=""

	[[ "$plan_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
	case "$candidate_count:$candidate_bytes" in
	*[!0-9:]*) return 1 ;;
	esac
	confirmation_material=$(printf '%s\n' \
		"schema=$WORKTREE_RECOVERY_PLAN_SCHEMA" \
		"plan-id=$plan_id" \
		"candidate-count=$candidate_count" \
		"candidate-bytes=$candidate_bytes" \
		"action=permanently-delete-exact-candidates") || return 1
	confirmation_digest=$(_worktree_recovery_plan_sha256_text "$confirmation_material") || return 1
	printf 'apply-sha256:%s\n' "$confirmation_digest"
	return 0
}

_worktree_recovery_plan_automatic_token() {
	local plan_id="$1"
	local policy_json="$2"
	local candidate_count="$3"
	local candidate_bytes="$4"
	local policy_digest=""
	local authorization_material=""
	local authorization_digest=""

	[[ "$plan_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
	case "$candidate_count:$candidate_bytes" in
	*[!0-9:]*) return 1 ;;
	esac
	printf '%s\n' "$policy_json" | jq -e --arg schema "$WORKTREE_RECOVERY_AUTOMATION_POLICY_SCHEMA" \
		--arg policy_id "$WORKTREE_RECOVERY_AUTOMATION_POLICY_ID" \
		'type == "object" and .schema == $schema and .policy_id == $policy_id' \
		>/dev/null 2>&1 || return 1
	policy_json=$(printf '%s\n' "$policy_json" | jq -cS '.') || return 1
	policy_digest=$(_worktree_recovery_plan_sha256_text "$policy_json") || return 1
	authorization_material=$(printf '%s\n' \
		"schema=$WORKTREE_RECOVERY_PLAN_SCHEMA" \
		"plan-id=$plan_id" \
		"policy-id=$WORKTREE_RECOVERY_AUTOMATION_POLICY_ID" \
		"policy-digest=sha256:$policy_digest" \
		"candidate-count=$candidate_count" \
		"candidate-bytes=$candidate_bytes" \
		"action=automatically-delete-exact-terminal-candidates") || return 1
	authorization_digest=$(_worktree_recovery_plan_sha256_text "$authorization_material") || return 1
	printf 'automatic-sha256:%s\n' "$authorization_digest"
	return 0
}

_worktree_recovery_plan_read_line() {
	local file_path="$1"
	local value=""
	[[ -f "$file_path" && ! -L "$file_path" ]] || return 1
	IFS= read -r value <"$file_path" || return 1
	_worktree_recovery_line_payload_is_valid "$value" || return 1
	printf '%s\n' "$value"
	return 0
}

_worktree_recovery_plan_archive_path() {
	local bucket_path="$1"
	local recovery_dir="${bucket_path}/${_WT_RECOVERY_DIR_NAME}"
	local recorded_gitdir=""
	local archive_path=""

	recorded_gitdir=$(_worktree_recovery_plan_read_line "$recovery_dir/admin/gitdir") || return 1
	case "$recorded_gitdir" in
	"$bucket_path"/*/.git) archive_path="${recorded_gitdir%/.git}" ;;
	*) return 1 ;;
	esac
	[[ "${archive_path%/*}" == "$bucket_path" ]] || return 1
	printf '%s\n' "$archive_path"
	return 0
}

_worktree_recovery_plan_identity_json() {
	local bucket_path="$1"
	local bucket_real="" archive_path="" recovery_dir="" format=""
	local source_real="" source_inode="" admin_real="" admin_inode=""
	local common_real="" head="" created_at="" producer=""
	local branch=""
	local producer_context="" session_id="" source_outcome="legacy-v1"
	local index_digest="" completion_digest="legacy-marker-absent"
	local identity_material="" identity_digest=""

	[[ -d "$bucket_path" && ! -L "$bucket_path" ]] || return 1
	bucket_real=$(cd "$bucket_path" 2>/dev/null && pwd -P) || return 1
	[[ "$bucket_real" == "$bucket_path" ]] || return 1
	archive_path=$(_worktree_recovery_plan_archive_path "$bucket_path") || return 1
	GIT_OPTIONAL_LOCKS=0 _worktree_recovery_archive_is_valid "$archive_path" || return 1
	recovery_dir="${bucket_path}/${_WT_RECOVERY_DIR_NAME}"
	format=$(_worktree_recovery_plan_read_line "$recovery_dir/format") || return 1
	source_real=$(_worktree_recovery_plan_read_line "$recovery_dir/source-real") || return 1
	source_inode=$(_worktree_recovery_plan_read_line "$recovery_dir/source-inode") || return 1
	admin_real=$(_worktree_recovery_plan_read_line "$recovery_dir/admin-real") || return 1
	admin_inode=$(_worktree_recovery_plan_read_line "$recovery_dir/admin-inode") || return 1
	common_real=$(_worktree_recovery_plan_read_line "$recovery_dir/common-real") || return 1
	head=$(_worktree_recovery_plan_read_line "$recovery_dir/head") || return 1
	branch=$(_worktree_recovery_plan_read_line "$recovery_dir/branch") || return 1
	if [[ "$format" == "$_WT_RECOVERY_FORMAT_V2" ]]; then
		created_at=$(_worktree_recovery_plan_read_line "$recovery_dir/created-at") || return 1
		producer=$(_worktree_recovery_plan_read_line "$recovery_dir/producer") || return 1
		producer_context=$(_worktree_recovery_plan_read_line "$recovery_dir/producer-context") || return 1
		session_id=$(_worktree_recovery_plan_read_line "$recovery_dir/session-id") || return 1
		source_outcome=$(_worktree_recovery_plan_read_line "$recovery_dir/source-removal-outcome") || return 1
	fi
	index_digest=$(_worktree_recovery_plan_sha256_file "$recovery_dir/admin/index") || return 1
	if [[ -f "$recovery_dir/${_WT_RECOVERY_COMPLETE_MARKER}" ]]; then
		completion_digest=$(_worktree_recovery_plan_sha256_file \
			"$recovery_dir/${_WT_RECOVERY_COMPLETE_MARKER}") || return 1
	fi
	identity_material=$(printf '%s\n' \
		"format=$format" "bucket=$bucket_real" "archive=$archive_path" \
		"source-real=$source_real" "source-inode=$source_inode" \
		"admin-real=$admin_real" "admin-inode=$admin_inode" \
		"common-real=$common_real" "head=$head" "branch=$branch" \
		"created-at=$created_at" "producer=$producer" \
		"producer-context=$producer_context" "session-id=$session_id" \
		"source-outcome=$source_outcome" "index-digest=$index_digest" \
		"completion-digest=$completion_digest") || return 1
	identity_digest=$(_worktree_recovery_plan_sha256_text "$identity_material") || return 1
	jq -cn \
		--arg bucket_path "$bucket_real" --arg archive_path "$archive_path" \
		--arg format "$format" --arg identity_digest "sha256:$identity_digest" \
		--arg source_path "$source_real" --arg source_inode "$source_inode" \
		--arg admin_path "$admin_real" --arg admin_inode "$admin_inode" \
		--arg common_path "$common_real" --arg head "$head" --arg branch "$branch" \
		--arg created_at "$created_at" --arg producer "$producer" \
		--arg producer_context "$producer_context" --arg session_id "$session_id" \
		--arg source_outcome "$source_outcome" --arg index_digest "sha256:$index_digest" \
		--arg completion_digest "$completion_digest" \
		'{bucket_path:$bucket_path,archive_path:$archive_path,format:$format,identity_digest:$identity_digest,index_digest:$index_digest,completion_digest:(if ($completion_digest | startswith("legacy-")) then $completion_digest else "sha256:" + $completion_digest end),source_path:$source_path,source_inode:$source_inode,admin_path:$admin_path,admin_inode:$admin_inode,common_path:$common_path,head:$head,branch:$branch,created_at:(if $created_at == "" then null else $created_at end),producer:(if $producer == "" then null else $producer end),producer_context:(if $producer_context == "" then null else $producer_context end),session_id:(if $session_id == "" then null else $session_id end),source_removal_outcome:$source_outcome}'
	return $?
}

_worktree_recovery_plan_git_state() {
	local identity_json="$1"
	local archive_path=""
	local status_file=""
	local status_rc=0

	archive_path=$(printf '%s\n' "$identity_json" | jq -r '.archive_path') || return 1
	status_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/aidevops-worktree-recovery-status.XXXXXX") || {
		printf '%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE"
		return 0
	}
	GIT_OPTIONAL_LOCKS=0 git -C "$archive_path" status --porcelain=v1 -z \
		--untracked-files=all --ignored=matching >"$status_file" 2>/dev/null || status_rc=$?
	if [[ "$status_rc" -ne 0 ]]; then
		printf '%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE"
	elif [[ -s "$status_file" ]]; then
		printf '%s\n' "dirty"
	else
		printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR"
	fi
	rm -f "$status_file"
	return 0
}

_worktree_recovery_plan_worktree_reference_state() {
	local identity_json="$1"
	local archive_path="" source_path="" listing=""
	local branch=""
	local line=""

	archive_path=$(printf '%s\n' "$identity_json" | jq -r '.archive_path') || return 1
	source_path=$(printf '%s\n' "$identity_json" | jq -r '.source_path') || return 1
	branch=$(printf '%s\n' "$identity_json" | jq -r '.branch') || return 1
	if ! listing=$(GIT_OPTIONAL_LOCKS=0 git -C "$archive_path" worktree list --porcelain 2>/dev/null); then
		printf '%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE"
		return 0
	fi
	while IFS= read -r line; do
		case "$line" in
		"worktree $source_path" | "branch $branch")
			printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_ACTIVE"
			return 0
			;;
		esac
	done <<<"$listing"
	printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR"
	return 0
}

_worktree_recovery_plan_registry_state() {
	local identity_json="$1"
	local source_path="" escaped_path="" owner_count=""

	source_path=$(printf '%s\n' "$identity_json" | jq -r '.source_path') || return 1
	if [[ ! -e "${WORKTREE_REGISTRY_DB:-}" ]]; then
		printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR"
		return 0
	fi
	if ! command -v sqlite3 >/dev/null 2>&1 || [[ ! -f "$WORKTREE_REGISTRY_DB" || -L "$WORKTREE_REGISTRY_DB" ]]; then
		printf '%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE"
		return 0
	fi
	escaped_path="${source_path//\'/\'\'}"
	owner_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" \
		"SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = '${escaped_path}';" 2>/dev/null) || {
		printf '%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE"
		return 0
	}
	case "$owner_count" in
	0) printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ;;
	*[!0-9]* | '') printf '%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE" ;;
	*) printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_ACTIVE" ;;
	esac
	return 0
}

_worktree_recovery_plan_claim_state() {
	local identity_json="$1"
	local source_path="" helper="" claim_rc=0
	local branch=""

	source_path=$(printf '%s\n' "$identity_json" | jq -r '.source_path') || return 1
	branch=$(printf '%s\n' "$identity_json" | jq -r '.branch') || return 1
	[[ "$branch" == refs/heads/* ]] || {
		printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_ACTIVE"
		return 0
	}
	if [[ -x "$WORKTREE_RECOVERY_LIFECYCLE_DIR/interactive-session-helper.sh" ]]; then
		helper="$WORKTREE_RECOVERY_LIFECYCLE_DIR/interactive-session-helper.sh"
	elif [[ -x "${HOME:-}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
	else
		printf '%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE"
		return 0
	fi
	"$helper" branch-has-active-claim "${branch#refs/heads/}" --worktree "$source_path" \
		>/dev/null 2>&1 || claim_rc=$?
	case "$claim_rc" in
	0) printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_ACTIVE" ;;
	1) printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ;;
	*) printf '%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE" ;;
	esac
	return 0
}

_worktree_recovery_plan_process_state() {
	local identity_json="$1"
	local source_path="" archive_path="" bucket_path="" snapshot=""
	local snapshot_rc=0

	source_path=$(printf '%s\n' "$identity_json" | jq -r '.source_path') || return 1
	archive_path=$(printf '%s\n' "$identity_json" | jq -r '.archive_path') || return 1
	bucket_path=$(printf '%s\n' "$identity_json" | jq -r '.bucket_path') || return 1
	if snapshot=$(capture_worktree_process_cwds); then
		snapshot_rc=0
	else
		snapshot_rc=$?
	fi
	if _worktree_cwd_snapshot_contains_path "$source_path" "$source_path" "$snapshot" ||
		_worktree_cwd_snapshot_contains_path "$archive_path" "$archive_path" "$snapshot" ||
		_worktree_cwd_snapshot_contains_path "$bucket_path" "$bucket_path" "$snapshot"; then
		printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_ACTIVE"
	elif [[ "$snapshot_rc" -eq 0 ]]; then
		printf '%s\n' "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR"
	else
		printf '%s\n' "$WORKTREE_RECOVERY_UNAVAILABLE"
	fi
	return 0
}

_worktree_recovery_plan_repo_slug() {
	local archive_path="$1"
	local remote_url="" repo_slug=""

	remote_url=$(GIT_OPTIONAL_LOCKS=0 git -C "$archive_path" remote get-url origin 2>/dev/null) || return 1
	case "$remote_url" in
	https://github.com/*) repo_slug="${remote_url#https://github.com/}" ;;
	git@github.com:*) repo_slug="${remote_url#git@github.com:}" ;;
	ssh://git@github.com/*) repo_slug="${remote_url#ssh://git@github.com/}" ;;
	*) return 1 ;;
	esac
	repo_slug="${repo_slug%.git}"
	[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	printf '%s\n' "$repo_slug"
	return 0
}

_worktree_recovery_plan_issue_number() {
	local branch="$1"
	branch="${branch#refs/heads/}"
	if [[ "$branch" =~ gh[-]?([0-9]+) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ "$branch" =~ (^|/)fix/([0-9]{3,})([-/]|$) ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

_worktree_recovery_plan_external_evidence_json() {
	local identity_json="$1"
	local archive_path="" branch_name="" head="" repo_slug=""
	local branch=""
	local issue_number="" pr_json="" issue_state="" issue_state_normalized=""
	local open_count="" merged_count=""

	archive_path=$(printf '%s\n' "$identity_json" | jq -r '.archive_path') || return 1
	branch=$(printf '%s\n' "$identity_json" | jq -r '.branch') || return 1
	head=$(printf '%s\n' "$identity_json" | jq -r '.head') || return 1
	branch_name="${branch#refs/heads/}"
	repo_slug=$(_worktree_recovery_plan_repo_slug "$archive_path") || {
		jq -cn --arg unavailable "$WORKTREE_RECOVERY_UNAVAILABLE" \
			'{commit:$unavailable,open_pr:$unavailable,task:$unavailable,issue_number:null,repo:null}'
		return 0
	}
	issue_number=$(_worktree_recovery_plan_issue_number "$branch" 2>/dev/null || true)
	if ! command -v gh >/dev/null 2>&1; then
		jq -cn --arg repo "$repo_slug" --arg issue "$issue_number" \
			--arg unavailable "$WORKTREE_RECOVERY_UNAVAILABLE" \
			'{commit:$unavailable,open_pr:$unavailable,task:$unavailable,issue_number:(if $issue == "" then null else $issue end),repo:$repo}'
		return 0
	fi
	if ! pr_json=$(gh pr list --repo "$repo_slug" --head "$branch_name" --state all \
		--limit 100 --json number,state,mergedAt,headRefOid 2>/dev/null) ||
		! printf '%s\n' "$pr_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
		jq -cn --arg repo "$repo_slug" --arg issue "$issue_number" \
			--arg unavailable "$WORKTREE_RECOVERY_UNAVAILABLE" \
			'{commit:$unavailable,open_pr:$unavailable,task:$unavailable,issue_number:(if $issue == "" then null else $issue end),repo:$repo}'
		return 0
	fi
	open_count=$(printf '%s\n' "$pr_json" | jq '[.[] | select(.state == "OPEN")] | length') || return 1
	merged_count=$(printf '%s\n' "$pr_json" | jq --arg head "$head" \
		'[.[] | select(.mergedAt != null and .headRefOid == $head)] | length') || return 1
	if [[ -n "$issue_number" ]]; then
		issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json state --jq '.state // empty' 2>/dev/null) || issue_state="$WORKTREE_RECOVERY_UNAVAILABLE"
	else
		issue_state="unlinked"
	fi
	issue_state_normalized=$(printf '%s' "$issue_state" | tr '[:upper:]' '[:lower:]') || return 1
	jq -cn --arg repo "$repo_slug" --arg issue "$issue_number" \
		--arg commit "$([[ "$merged_count" -gt 0 ]] && printf merged || printf unproven)" \
		--arg open_pr "$([[ "$open_count" -gt 0 ]] && printf '%s' "$WORKTREE_RECOVERY_PLAN_STATE_ACTIVE" || printf '%s' "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR")" \
		--arg task "$issue_state_normalized" \
		'{commit:$commit,open_pr:$open_pr,task:$task,issue_number:(if $issue == "" then null else $issue end),repo:$repo}'
	return $?
}

_worktree_recovery_plan_evidence_json() {
	local identity_json="$1"
	local git_state="" worktree_state="" registry_state="" claim_state=""
	local process_state="" external_json=""

	git_state=$(_worktree_recovery_plan_git_state "$identity_json") || return 1
	worktree_state=$(_worktree_recovery_plan_worktree_reference_state "$identity_json") || return 1
	registry_state=$(_worktree_recovery_plan_registry_state "$identity_json") || return 1
	claim_state=$(_worktree_recovery_plan_claim_state "$identity_json") || return 1
	process_state=$(_worktree_recovery_plan_process_state "$identity_json") || return 1
	external_json=$(_worktree_recovery_plan_external_evidence_json "$identity_json") || return 1
	printf '%s\n' "$external_json" | jq -e \
		--arg clear "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" \
		--arg unavailable "$WORKTREE_RECOVERY_UNAVAILABLE" '
		type == "object" and
		(.commit | IN("merged","unproven",$unavailable)) and
		(.open_pr | IN("active",$clear,$unavailable)) and
		(.task | type == "string")
	' >/dev/null 2>&1 || return 1
	jq -cn \
		--arg git "$git_state" --arg worktree "$worktree_state" \
		--arg registry "$registry_state" --arg claim "$claim_state" \
		--arg process "$process_state" --argjson external "$external_json" \
		'{git:$git,worktree:$worktree,registry:$registry,claim:$claim,process:$process,external:$external}'
	return $?
}

_worktree_recovery_plan_classification_json() {
	local identity_json="$1"
	local evidence_json="$2"
	local stable="$3"

	jq -cn \
		--arg candidate "$WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE" \
		--arg protected "$WORKTREE_RECOVERY_PLAN_DISPOSITION_PROTECTED" \
		--arg unknown "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" \
		--arg active "$WORKTREE_RECOVERY_PLAN_STATE_ACTIVE" \
		--arg clear "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" \
		--arg unavailable "$WORKTREE_RECOVERY_UNAVAILABLE" \
		--argjson identity "$identity_json" --argjson evidence "$evidence_json" \
		--argjson stable "$stable" '
		if $stable != true then {disposition:$unknown,reasons:["identity-or-size-changed"]}
		elif $evidence.git == "dirty" then {disposition:$protected,reasons:["archive-worktree-dirty"]}
		elif $evidence.worktree == $active then {disposition:$protected,reasons:["active-git-worktree-reference"]}
		elif $evidence.registry == $active then {disposition:$protected,reasons:["active-registry-owner"]}
		elif $evidence.claim == $active then {disposition:$protected,reasons:["active-session-claim"]}
		elif $evidence.process == $active then {disposition:$protected,reasons:["active-process-reference"]}
		elif $evidence.external.open_pr == $active then {disposition:$protected,reasons:["open-pull-request"]}
		elif $identity.source_removal_outcome != "removed" then {disposition:$protected,reasons:["source-removal-not-complete"]}
		elif ($identity.branch | startswith("refs/heads/") | not) then {disposition:$protected,reasons:["detached-or-unresolved-branch"]}
		elif ([ $evidence.git,$evidence.worktree,$evidence.registry,$evidence.claim,$evidence.process,
			$evidence.external.commit,$evidence.external.open_pr,$evidence.external.task ] | index($unavailable)) != null
		then {disposition:$unknown,reasons:["required-evidence-unavailable"]}
		elif $evidence.external.commit != "merged" then {disposition:$protected,reasons:["exact-commit-not-merged"]}
		elif $evidence.external.task != "closed" then {disposition:$protected,reasons:["linked-task-not-closed"]}
		elif ([ $evidence.git,$evidence.worktree,$evidence.registry,$evidence.claim,$evidence.process ] | all(. == $clear))
		then {disposition:$candidate,reasons:["all-required-evidence-clear"]}
		else {disposition:$unknown,reasons:["unrecognised-evidence-state"]}
		end'
	return $?
}

_worktree_recovery_plan_attributed_entry_json() {
	local role="$1"
	local bucket_path="$2"
	local expected_bytes="$3"
	local identity_before="" identity_after="" evidence_json="" measured_after=""
	local bytes_after="" confidence_after="" measure_error_after="" stable=false
	local classification_json=""

	identity_before=$(_worktree_recovery_plan_identity_json "$bucket_path") || return 1
	evidence_json=$(_worktree_recovery_plan_evidence_json "$identity_before") || return 1
	identity_after=$(_worktree_recovery_plan_identity_json "$bucket_path") || return 1
	measured_after=$(_worktree_recovery_measure_path "$bucket_path") || return 1
	IFS='|' read -r bytes_after confidence_after measure_error_after <<<"$measured_after"
	if [[ "$identity_before" == "$identity_after" &&
		"$confidence_after" == "$WORKTREE_RECOVERY_PLAN_CONFIDENCE_EXACT" &&
		"$bytes_after" == "$expected_bytes" ]]; then
		stable=true
	fi
	classification_json=$(_worktree_recovery_plan_classification_json \
		"$identity_after" "$evidence_json" "$stable") || return 1
	jq -cn --arg role "$role" --argjson bytes "$expected_bytes" \
		--argjson identity "$identity_after" --argjson evidence "$evidence_json" \
		--argjson classification "$classification_json" \
		'{role:$role,path:$identity.bucket_path,archive_path:$identity.archive_path,expected_allocated_bytes:$bytes,identity:$identity,evidence:$evidence,disposition:$classification.disposition,reasons:$classification.reasons}'
	return $?
}

_worktree_recovery_plan_unknown_entry_json() {
	local role="$1"
	local bucket_path="$2"
	local bytes="$3"
	local reason="$4"

	jq -cn --arg role "$role" --arg path "$bucket_path" --arg reason "$reason" \
		--arg unknown "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" --argjson bytes "$bytes" \
		'{role:$role,path:$path,archive_path:null,expected_allocated_bytes:$bytes,identity:null,evidence:null,disposition:$unknown,reasons:[$reason]}'
	return $?
}

_worktree_recovery_plan_entries_json() {
	local platform="$1"
	local inventory_json="" inventory_error="" entries_file="" rows_file=""
	local entry_json="" entries_json=""
	local row_json="" role="" state="" bucket_path="" bytes="" confidence=""
	local result_status=0

	inventory_json=$(worktree_recovery_lifecycle_json "$platform") || return 1
	inventory_error=$(printf '%s\n' "$inventory_json" | jq -r '.error // empty') || return 1
	entries_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/aidevops-worktree-recovery-plan-entries.XXXXXX") || return 1
	rows_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/aidevops-worktree-recovery-plan-rows.XXXXXX") || {
		rm -f "$entries_file"
		return 1
	}
	if ! printf '%s\n' "$inventory_json" | jq -c '.buckets[]' \
		>"$rows_file"; then
		rm -f "$entries_file" "$rows_file"
		return 1
	fi
	while IFS= read -r row_json; do
		role=$(printf '%s\n' "$row_json" | jq -r '.role') || result_status=1
		state=$(printf '%s\n' "$row_json" | jq -r '.state') || result_status=1
		bucket_path=$(printf '%s\n' "$row_json" | jq -r '.path') || result_status=1
		bytes=$(printf '%s\n' "$row_json" | jq -r --arg null_value "$WORKTREE_RECOVERY_PLAN_JSON_NULL" '.bytes // $null_value') || result_status=1
		confidence=$(printf '%s\n' "$row_json" | jq -r '.sizing_confidence') || result_status=1
		[[ "$result_status" -eq 0 ]] || break
		if [[ -n "$inventory_error" ]]; then
			entry_json=$(_worktree_recovery_plan_unknown_entry_json \
				"$role" "$bucket_path" "$bytes" "inventory-report-incomplete") || result_status=1
		elif [[ "$state" == "attributed" || "$state" == "attributed-legacy" ]]; then
			if [[ "$bytes" == "$WORKTREE_RECOVERY_PLAN_JSON_NULL" ||
				"$confidence" != "$WORKTREE_RECOVERY_PLAN_CONFIDENCE_EXACT" ]]; then
				entry_json=$(_worktree_recovery_plan_unknown_entry_json \
					"$role" "$bucket_path" "$bytes" "sizing-unavailable") || result_status=1
			elif ! entry_json=$(_worktree_recovery_plan_attributed_entry_json \
				"$role" "$bucket_path" "$bytes"); then
				entry_json=$(_worktree_recovery_plan_unknown_entry_json \
					"$role" "$bucket_path" "$bytes" "classification-unavailable") || result_status=1
			fi
		else
			entry_json=$(_worktree_recovery_plan_unknown_entry_json \
				"$role" "$bucket_path" "$bytes" "archive-unrecognised-or-incomplete") || result_status=1
		fi
		[[ "$result_status" -eq 0 ]] || break
		printf '%s\n' "$entry_json" >>"$entries_file" || {
			result_status=1
			break
		}
	done <"$rows_file"
	if [[ "$result_status" -eq 0 ]]; then
		entries_json=$(jq -sc 'sort_by(.path)' "$entries_file") || result_status=1
	fi
	if [[ "$result_status" -eq 0 ]]; then
		jq -cn --arg error "$inventory_error" --argjson entries "$entries_json" \
			'{inventory_complete:($error == ""),inventory_error:(if $error == "" then null else $error end),entries:$entries}' || result_status=1
	fi
	rm -f "$entries_file" "$rows_file"
	return "$result_status"
}

worktree_recovery_plan_json() {
	local platform="${1:-}"
	local entries_bundle="" entries_json="" inventory_complete="" inventory_error=""
	local plan_material="" plan_digest="" generated_at="" plan_json=""
	local candidate_count="" candidate_bytes="" confirmation_token=""

	command -v jq >/dev/null 2>&1 || return 1
	if [[ -z "$platform" ]]; then
		platform=$(uname -s 2>/dev/null) || platform="$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN"
	fi
	entries_bundle=$(_worktree_recovery_plan_entries_json "$platform") || return 1
	entries_json=$(printf '%s\n' "$entries_bundle" | jq -c '.entries') || return 1
	inventory_complete=$(printf '%s\n' "$entries_bundle" | jq -c '.inventory_complete') || return 1
	inventory_error=$(printf '%s\n' "$entries_bundle" | jq -r '.inventory_error // empty') || return 1
	plan_material=$(jq -cn --arg schema "$WORKTREE_RECOVERY_PLAN_SCHEMA" \
		--arg error "$inventory_error" --argjson complete "$inventory_complete" \
		--argjson entries "$entries_json" \
		'{schema:$schema,inventory_complete:$complete,inventory_error:(if $error == "" then null else $error end),entries:$entries}') || return 1
	plan_digest=$(_worktree_recovery_plan_sha256_text "$plan_material") || return 1
	generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	plan_json=$(jq -cn --arg schema "$WORKTREE_RECOVERY_PLAN_SCHEMA" \
		--arg plan_id "sha256:$plan_digest" --arg generated_at "$generated_at" \
		--arg producer "$WORKTREE_RECOVERY_PRODUCER" \
		--arg candidate "$WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE" \
		--arg protected "$WORKTREE_RECOVERY_PLAN_DISPOSITION_PROTECTED" \
		--arg unknown "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" \
		--arg error "$inventory_error" --argjson complete "$inventory_complete" \
		--argjson entries "$entries_json" '
		def parent_path: .[0:rindex("/")];
		{schema:$schema,producer:$producer,plan_id:$plan_id,generated_at:$generated_at,read_only:true,
		inventory_complete:$complete,inventory_error:(if $error == "" then null else $error end),
		source_roots:([$entries[].path | parent_path] | unique),
		entry_count:($entries | length),
		sized_entry_count:([$entries[] | select(.expected_allocated_bytes | type == "number")] | length),
		unavailable_size_count:([$entries[] | select(.expected_allocated_bytes == null)] | length),
		expected_allocated_bytes:([$entries[].expected_allocated_bytes | numbers] | add // 0),
		candidate_count:([$entries[] | select(.disposition == $candidate)] | length),
		candidate_bytes:([$entries[] | select(.disposition == $candidate) | .expected_allocated_bytes] | add // 0),
		protected_count:([$entries[] | select(.disposition == $protected)] | length),
		protected_bytes:([$entries[] | select(.disposition == $protected) | .expected_allocated_bytes | numbers] | add // 0),
		unknown_count:([$entries[] | select(.disposition == $unknown)] | length),
		unknown_bytes:([$entries[] | select(.disposition == $unknown) | .expected_allocated_bytes | numbers] | add // 0),
		entries:$entries}') || return 1
	candidate_count=$(printf '%s\n' "$plan_json" | jq -r '.candidate_count') || return 1
	candidate_bytes=$(printf '%s\n' "$plan_json" | jq -r '.candidate_bytes') || return 1
	confirmation_token=$(_worktree_recovery_plan_confirmation_token \
		"sha256:$plan_digest" "$candidate_count" "$candidate_bytes") || return 1
	printf '%s\n' "$plan_json" | jq -c --arg confirmation_token "$confirmation_token" \
		'. + {confirmation_token:$confirmation_token}'
	return $?
}

worktree_recovery_plan_write() {
	local output_path="$1"
	local parent_path="" parent_real="" base_name="" canonical_output=""
	local temp_path="" plan_json=""
	local previous_umask=""

	[[ "$output_path" == /* && "$output_path" != */ ]] || return 1
	[[ ! -e "$output_path" && ! -L "$output_path" ]] || return 1
	parent_path="${output_path%/*}"
	base_name="${output_path##*/}"
	[[ -n "$parent_path" && -n "$base_name" && -d "$parent_path" && ! -L "$parent_path" ]] || return 1
	parent_real=$(cd "$parent_path" 2>/dev/null && pwd -P) || return 1
	[[ -w "$parent_real" ]] || return 1
	canonical_output="${parent_real}/${base_name}"
	[[ ! -e "$canonical_output" && ! -L "$canonical_output" ]] || return 1
	plan_json=$(worktree_recovery_plan_json) || return 1
	previous_umask=$(umask)
	umask 077
	temp_path=$(mktemp "${parent_real}/.${base_name}.tmp.XXXXXX") || {
		umask "$previous_umask"
		return 1
	}
	umask "$previous_umask"
	if ! printf '%s\n' "$plan_json" >"$temp_path" || ! chmod 600 "$temp_path" ||
		! jq -e --arg schema "$WORKTREE_RECOVERY_PLAN_SCHEMA" \
			'.schema == $schema and .read_only == true' "$temp_path" >/dev/null 2>&1 ||
		! ln "$temp_path" "$canonical_output" 2>/dev/null; then
		rm -f "$temp_path"
		return 1
	fi
	rm -f "$temp_path"
	printf '%s\n' "$output_path"
	return 0
}

if [[ -f "$WORKTREE_RECOVERY_LIFECYCLE_DIR/worktree-recovery-apply-helper.sh" ]]; then
	# shellcheck source=worktree-recovery-apply-helper.sh
	source "$WORKTREE_RECOVERY_LIFECYCLE_DIR/worktree-recovery-apply-helper.sh"
fi

_worktree_recovery_lifecycle_usage() {
	printf '%s\n' 'Usage: worktree-recovery-lifecycle-helper.sh [status|json|plan --output <absolute-path>|apply --plan <absolute-path> --receipt <absolute-new-path> --confirm <manifest-token>]'
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	case "${1:-status}" in
	json) worktree_recovery_lifecycle_json ;;
	plan)
		[[ "$#" -eq 3 && "$2" == "--output" ]] || {
			_worktree_recovery_lifecycle_usage >&2
			exit 1
		}
		worktree_recovery_plan_write "$3"
		;;
	apply)
		[[ "$#" -eq 7 && "$2" == "--plan" && "$4" == "--receipt" && "$6" == "--confirm" ]] || {
			_worktree_recovery_lifecycle_usage >&2
			exit 1
		}
		declare -F worktree_recovery_apply >/dev/null 2>&1 || exit 1
		worktree_recovery_apply "$3" "$5" "$7"
		;;
	status) worktree_recovery_lifecycle_status ;;
	help | --help | -h) _worktree_recovery_lifecycle_usage ;;
	*)
		_worktree_recovery_lifecycle_usage >&2
		exit 1
		;;
	esac
fi
