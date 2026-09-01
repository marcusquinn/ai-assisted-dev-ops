#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Exact-manifest mutation boundary for worktree recovery archives.

[[ "${_WORKTREE_RECOVERY_APPLY_HELPER_LOADED:-}" == "1" ]] && return 0
_WORKTREE_RECOVERY_APPLY_HELPER_LOADED=1

WORKTREE_RECOVERY_APPLY_RECEIPT_SCHEMA="aidevops.worktree-recovery-apply-receipt/v1"
WORKTREE_RECOVERY_APPLY_RESERVATION_SCHEMA="aidevops.worktree-recovery-apply-reservation/v1"
WORKTREE_RECOVERY_APPLY_TRANSACTION_SCHEMA="aidevops.worktree-recovery-apply-transaction/v1"
WORKTREE_RECOVERY_APPLY_STATE_PLANNED="planned"
WORKTREE_RECOVERY_APPLY_STATE_STAGED="staged"
WORKTREE_RECOVERY_APPLY_STATE_REMOVED="removed"
WORKTREE_RECOVERY_APPLY_OUTCOME_PENDING="pending"
WORKTREE_RECOVERY_APPLY_OUTCOME_REMOVED="$WORKTREE_RECOVERY_APPLY_STATE_REMOVED"
WORKTREE_RECOVERY_APPLY_JSON_TYPE_NUMBER="number"
WORKTREE_RECOVERY_APPLY_JSON_TYPE_OBJECT="object"
WORKTREE_RECOVERY_APPLY_JSON_TYPE_STRING="string"
WORKTREE_RECOVERY_APPLY_TRASH_SEGMENT="/.retention-trash/"
WORKTREE_RECOVERY_APPLY_VALIDATED_METADATA=""
WORKTREE_RECOVERY_APPLY_VALIDATED_PLAN_JSON=""
WORKTREE_RECOVERY_APPLY_RECEIPT_COMPLETION_PATH=""

_worktree_recovery_apply_canonical_path() {
	local path="$1"
	local parent_path=""
	local parent_real=""
	local base_name=""

	[[ "$path" == /* && "$path" != */ ]] || return 1
	parent_path="${path%/*}"
	base_name="${path##*/}"
	[[ -n "$parent_path" && -n "$base_name" && -d "$parent_path" && ! -L "$parent_path" ]] || return 1
	parent_real=$(cd "$parent_path" 2>/dev/null && pwd -P) || return 1
	printf '%s/%s\n' "$parent_real" "$base_name"
	return 0
}

_worktree_recovery_apply_plan_material_json() {
	local plan_json="$1"

	printf '%s\n' "$plan_json" | jq -c \
		--arg object_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_OBJECT" '
		{schema:.schema,inventory_complete:.inventory_complete,
		inventory_error:.inventory_error} +
		(if has("classification_complete")
		then {classification_complete:.classification_complete,
			classified_entry_count:.classified_entry_count,
			deferred_entry_count:.deferred_entry_count,
			classification_offset:.classification_offset,
			next_classification_offset:.next_classification_offset,
			classification_deadline_seconds:.classification_deadline_seconds,
			classification_deadline_exhausted:.classification_deadline_exhausted}
		else {} end) + {entries:.entries} +
		(if (.automatic_policy | type) == $object_type
		then {automatic_policy:.automatic_policy} else {} end)'
	return $?
}

_worktree_recovery_apply_plan_material() {
	local plan_path="$1"
	local plan_json=""

	[[ -f "$plan_path" && ! -L "$plan_path" && -r "$plan_path" ]] || return 1
	plan_json=$(<"$plan_path")
	[[ -n "$plan_json" ]] || return 1
	_worktree_recovery_apply_plan_material_json "$plan_json"
	return $?
}

_worktree_recovery_apply_validate_candidate_roots() {
	local plan_json="$1"
	local current_root=""
	local current_real=""
	local legacy_root=""
	local legacy_real=""

	current_root=$(_worktree_recovery_store_root) || return 1
	[[ -d "$current_root" && ! -L "$current_root" ]] || return 1
	current_real=$(cd "$current_root" 2>/dev/null && pwd -P) || return 1
	if legacy_root=$(_worktree_legacy_recovery_root 2>/dev/null); then
		if [[ -d "$legacy_root" && ! -L "$legacy_root" ]]; then
			legacy_real=$(cd "$legacy_root" 2>/dev/null && pwd -P) || return 1
		fi
	fi
	printf '%s\n' "$plan_json" | jq -e --arg candidate "$WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE" \
		--arg current "$current_real" --arg legacy "$legacy_real" '
		all(.entries[] | select(.disposition == $candidate);
			.path as $candidate_path |
			$candidate_path[0:($candidate_path | rindex("/"))] as $candidate_root |
			$candidate_root == $current or ($legacy != "" and $candidate_root == $legacy))
	' >/dev/null 2>&1
	return $?
}

_worktree_recovery_apply_validate_control_path_scope() {
	local control_path="$1"
	local plan_json="$2"
	local canonical_control=""

	canonical_control=$(_worktree_recovery_apply_canonical_path "$control_path") || return 1
	printf '%s\n' "$plan_json" | jq -e --arg control "$canonical_control" \
		--arg candidate "$WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE" '
		all(.entries[] | select(.disposition == $candidate);
			.path as $candidate_path |
			$control != $candidate_path and
			($control | startswith($candidate_path + "/") | not))
	' >/dev/null 2>&1
	return $?
}

_worktree_recovery_apply_validate_plan_shape() {
	local plan_json="$1"

	printf '%s\n' "$plan_json" | jq -e --arg schema "$WORKTREE_RECOVERY_PLAN_SCHEMA" \
		--arg producer "$WORKTREE_RECOVERY_PRODUCER" \
		--arg candidate "$WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE" \
		--arg protected "$WORKTREE_RECOVERY_PLAN_DISPOSITION_PROTECTED" \
		--arg unknown "$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" \
		--arg number_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_NUMBER" \
		--arg object_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_OBJECT" \
		--arg string_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_STRING" '
		.entries as $entries |
		.source_roots as $source_roots |
		type == $object_type and .schema == $schema and .producer == $producer and
		.read_only == true and .inventory_complete == true and .inventory_error == null and
		(.generated_at | type == $string_type) and
		(.plan_id | test("^sha256:[0-9a-f]{64}$")) and
		(.confirmation_token | test("^apply-sha256:[0-9a-f]{64}$")) and
		($source_roots | type == "array") and
		([$source_roots[] | select(type != $string_type or (startswith("/") | not) or
			test("[\u0000-\u001f\u007f]"))] | length == 0) and
		($entries | type == "array") and .entry_count == ($entries | length) and
		([.entry_count,.sized_entry_count,.unavailable_size_count,.expected_allocated_bytes,
			.candidate_count,.candidate_bytes,.protected_count,.protected_bytes,
			.unknown_count,.unknown_bytes] |
			all(type == $number_type and . >= 0 and . == floor)) and
		.entry_count == (.sized_entry_count + .unavailable_size_count) and
		.entry_count == (.candidate_count + .protected_count + .unknown_count) and
		.candidate_count > 0 and .candidate_count == ([$entries[] | select(.disposition == $candidate)] | length) and
		.protected_count == ([$entries[] | select(.disposition == $protected)] | length) and
		.unknown_count == ([$entries[] | select(.disposition == $unknown)] | length) and
		.candidate_bytes == ([$entries[] | select(.disposition == $candidate) | .expected_allocated_bytes] | add // 0) and
		.protected_bytes == ([$entries[] | select(.disposition == $protected) | .expected_allocated_bytes | numbers] | add // 0) and
		.unknown_bytes == ([$entries[] | select(.disposition == $unknown) | .expected_allocated_bytes | numbers] | add // 0) and
		.expected_allocated_bytes == ([$entries[].expected_allocated_bytes | numbers] | add // 0) and
		.sized_entry_count == ([$entries[] | select(.expected_allocated_bytes | type == $number_type)] | length) and
		.unavailable_size_count == ([$entries[] | select(.expected_allocated_bytes == null)] | length) and
		([$entries[] | select(
			(.path | type != $string_type) or (.path | startswith("/") | not) or
			(.path | endswith("/")) or (.path | test("[\u0000-\u001f\u007f]")) or
			((.expected_allocated_bytes | type) | IN($number_type, "null") | not) or
			(.disposition | IN($candidate, $protected, $unknown) | not))] | length == 0) and
		([$entries[] | select(.disposition == $candidate) | . as $entry |
			select(($entry.path | type != $string_type) or ($entry.path | startswith("/") | not) or
			($entry.path | test("/aidevops-worktree-cleanup-[A-Za-z0-9._-]+$") | not) or
			($entry.archive_path | type != $string_type) or
			($entry.archive_path | test("[\u0000-\u001f\u007f]")) or
			($entry.archive_path[0:($entry.archive_path | rindex("/"))] != $entry.path) or
			($entry.expected_allocated_bytes | type != $number_type) or $entry.expected_allocated_bytes <= 0 or
			($entry.identity | type != $object_type) or ($entry.evidence | type != $object_type) or
			($entry.identity.bucket_path != $entry.path) or
			($entry.identity.archive_path != $entry.archive_path) or
			($entry.reasons != ["all-required-evidence-clear"]) or
			($entry.identity.identity_digest | test("^sha256:[0-9a-f]{64}$") | not))] | length == 0) and
		($source_roots == ([$entries[] | .path as $entry_path |
			$entry_path[0:($entry_path | rindex("/"))]] | unique)) and
		([$entries[].path] as $entry_paths |
			($entry_paths | length) == ($entry_paths | unique | length)) and
		([$entries[] | .identity.identity_digest? // empty] as $entry_identities |
			($entry_identities | length) == ($entry_identities | unique | length))
	' >/dev/null 2>&1
	return $?
}

_worktree_recovery_apply_validate_automatic_plan_shape() {
	local plan_json="$1"
	local manual_shape=""
	local placeholder="apply-sha256:0000000000000000000000000000000000000000000000000000000000000000"
	local selected_retention="retention"
	local selected_pressure="pressure"
	local reason_aggregate_unavailable="aggregate-size-unavailable"
	local reason_filesystem_kb="filesystem-free-kb-soft-limit"
	local reason_filesystem_percent="filesystem-free-percent-soft-limit"

	manual_shape=$(printf '%s\n' "$plan_json" | jq -c --arg placeholder "$placeholder" \
		'.confirmation_token = $placeholder') || return 1
	_worktree_recovery_apply_validate_plan_shape "$manual_shape" || return 1
	printf '%s\n' "$plan_json" | jq -e \
		--arg policy_schema "$WORKTREE_RECOVERY_AUTOMATION_POLICY_SCHEMA" \
		--arg policy_id "$WORKTREE_RECOVERY_AUTOMATION_POLICY_ID" \
		--arg candidate "$WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE" \
		--arg number_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_NUMBER" \
		--arg object_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_OBJECT" \
		--arg selected_retention "$selected_retention" \
		--arg selected_pressure "$selected_pressure" \
		--arg reason_aggregate_unavailable "$reason_aggregate_unavailable" \
		--arg reason_filesystem_kb "$reason_filesystem_kb" \
		--arg reason_filesystem_percent "$reason_filesystem_percent" '
		.automatic_policy as $policy |
		($policy | type == $object_type) and
		($policy | keys | sort) == (["available_kb","available_percent","max_bytes",
			"max_candidates","max_scan","max_store_bytes","policy_id","pressure_active",
			"pressure_min_free_kb","pressure_min_free_percent","pressure_reason",
			"protected_count","retention_days","scanned_count","schema","store_bytes",
			"unknown_count"] | sort) and
		$policy.schema == $policy_schema and $policy.policy_id == $policy_id and
		([ $policy.retention_days,$policy.max_scan,$policy.max_candidates,$policy.max_bytes,
			$policy.max_store_bytes,$policy.pressure_min_free_kb,
			$policy.pressure_min_free_percent,$policy.available_kb,
			$policy.available_percent,$policy.scanned_count,$policy.protected_count,
			$policy.unknown_count ] |
			all(type == $number_type and . >= 0 and . == floor)) and
		(($policy.store_bytes | type == $number_type and . >= 0 and . == floor) or
			($policy.store_bytes == null and
				(if $policy.pressure_active
				then $policy.pressure_reason | IN($reason_aggregate_unavailable,
					$reason_filesystem_kb,$reason_filesystem_percent)
				else $policy.pressure_reason == $reason_aggregate_unavailable end))) and
		$policy.retention_days > 0 and $policy.max_scan > 0 and
		$policy.max_candidates > 0 and $policy.max_bytes > 0 and
		$policy.max_store_bytes > 0 and $policy.pressure_min_free_percent <= 100 and
		($policy.pressure_active | type == "boolean") and
		($policy.pressure_reason | type == "string") and
		(.confirmation_token | test("^automatic-sha256:[0-9a-f]{64}$")) and
		.entry_count == .candidate_count and .protected_count == 0 and .unknown_count == 0 and
		.candidate_count <= $policy.max_candidates and .candidate_bytes <= $policy.max_bytes and
		$policy.scanned_count <= $policy.max_scan and
		all(.entries[];
			.disposition == $candidate and (.maintenance | type == $object_type) and
			(.maintenance.age_seconds | type == $number_type and . >= 0 and . == floor) and
			(.maintenance.selected_reason | IN($selected_retention,$selected_pressure)) and
			(if .maintenance.selected_reason == $selected_retention
			then .maintenance.age_seconds >= ($policy.retention_days * 86400)
			else $policy.pressure_active == true end)) and
		(if $policy.pressure_active then true
		else all(.entries[]; .maintenance.selected_reason == $selected_retention) end)
	' >/dev/null 2>&1
	return $?
}

_worktree_recovery_apply_validate_automatic_candidate_roots() {
	local plan_json="$1"
	local platform=""
	local current_root=""
	local current_real=""

	[[ -z "${AIDEVOPS_WORKTREE_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}" ]] || return 1
	platform=$(uname -s 2>/dev/null) || return 1
	[[ "$platform" != "Darwin" ]] || return 1
	current_root=$(_worktree_recovery_store_root "$platform") || return 1
	[[ -d "$current_root" && ! -L "$current_root" ]] || return 1
	current_real=$(cd "$current_root" 2>/dev/null && pwd -P) || return 1
	printf '%s\n' "$plan_json" | jq -e --arg candidate "$WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE" \
		--arg current "$current_real" '
		all(.entries[] | select(.disposition == $candidate);
			.path[0:(.path | rindex("/"))] == $current)
	' >/dev/null 2>&1
	return $?
}

_worktree_recovery_apply_validate_plan() {
	local plan_path="$1"
	local supplied_confirmation="$2"
	local canonical_plan=""
	local plan_json=""
	local plan_material=""
	local plan_id_digest=""
	local expected_plan_id=""
	local plan_id=""
	local candidate_count=""
	local candidate_bytes=""
	local expected_confirmation=""
	local plan_file_digest=""
	local apply_metadata=""

	WORKTREE_RECOVERY_APPLY_VALIDATED_METADATA=""
	WORKTREE_RECOVERY_APPLY_VALIDATED_PLAN_JSON=""
	canonical_plan=$(_worktree_recovery_apply_canonical_path "$plan_path") || return 1
	[[ -f "$canonical_plan" && ! -L "$canonical_plan" && -r "$canonical_plan" ]] || return 1
	plan_json=$(<"$canonical_plan")
	[[ -n "$plan_json" ]] || return 1
	_worktree_recovery_apply_validate_plan_shape "$plan_json" || return 1
	_worktree_recovery_apply_validate_candidate_roots "$plan_json" || return 1
	_worktree_recovery_apply_validate_control_path_scope \
		"$canonical_plan" "$plan_json" || return 1
	plan_material=$(_worktree_recovery_apply_plan_material_json "$plan_json") || return 1
	plan_id_digest=$(_worktree_recovery_plan_sha256_text "$plan_material") || return 1
	expected_plan_id="sha256:$plan_id_digest"
	plan_id=$(printf '%s\n' "$plan_json" | jq -r '.plan_id') || return 1
	[[ "$plan_id" == "$expected_plan_id" ]] || return 1
	candidate_count=$(printf '%s\n' "$plan_json" | jq -r '.candidate_count') || return 1
	candidate_bytes=$(printf '%s\n' "$plan_json" | jq -r '.candidate_bytes') || return 1
	expected_confirmation=$(_worktree_recovery_plan_confirmation_token \
		"$plan_id" "$candidate_count" "$candidate_bytes") || return 1
	[[ "$(printf '%s\n' "$plan_json" | jq -r '.confirmation_token')" == "$expected_confirmation" &&
	"$supplied_confirmation" == "$expected_confirmation" ]] || return 1
	plan_file_digest=$(_worktree_recovery_plan_sha256_text "$plan_json") || return 1
	apply_metadata=$(jq -cn --arg plan_path "$canonical_plan" --arg plan_id "$plan_id" \
		--arg plan_digest "sha256:$plan_file_digest" --arg confirmation "$expected_confirmation" \
		--argjson candidate_count "$candidate_count" --argjson candidate_bytes "$candidate_bytes" \
		'{plan_path:$plan_path,plan_id:$plan_id,plan_digest:$plan_digest,
		confirmation:$confirmation,candidate_count:$candidate_count,candidate_bytes:$candidate_bytes}') || return 1
	WORKTREE_RECOVERY_APPLY_VALIDATED_METADATA="$apply_metadata"
	WORKTREE_RECOVERY_APPLY_VALIDATED_PLAN_JSON="$plan_json"
	return 0
}

_worktree_recovery_apply_validate_automatic_plan() {
	local plan_path="$1"
	local canonical_plan=""
	local plan_json=""
	local plan_material=""
	local plan_id_digest=""
	local expected_plan_id=""
	local plan_id=""
	local candidate_count=""
	local candidate_bytes=""
	local policy_json=""
	local expected_authorization=""
	local plan_file_digest=""
	local apply_metadata=""

	WORKTREE_RECOVERY_APPLY_VALIDATED_METADATA=""
	WORKTREE_RECOVERY_APPLY_VALIDATED_PLAN_JSON=""
	canonical_plan=$(_worktree_recovery_apply_canonical_path "$plan_path") || return 1
	[[ -f "$canonical_plan" && ! -L "$canonical_plan" && -r "$canonical_plan" ]] || return 1
	plan_json=$(<"$canonical_plan")
	[[ -n "$plan_json" ]] || return 1
	_worktree_recovery_apply_validate_automatic_plan_shape "$plan_json" || return 1
	_worktree_recovery_apply_validate_automatic_candidate_roots "$plan_json" || return 1
	_worktree_recovery_apply_validate_control_path_scope \
		"$canonical_plan" "$plan_json" || return 1
	plan_material=$(_worktree_recovery_apply_plan_material_json "$plan_json") || return 1
	plan_id_digest=$(_worktree_recovery_plan_sha256_text "$plan_material") || return 1
	expected_plan_id="sha256:$plan_id_digest"
	plan_id=$(printf '%s\n' "$plan_json" | jq -r '.plan_id') || return 1
	[[ "$plan_id" == "$expected_plan_id" ]] || return 1
	candidate_count=$(printf '%s\n' "$plan_json" | jq -r '.candidate_count') || return 1
	candidate_bytes=$(printf '%s\n' "$plan_json" | jq -r '.candidate_bytes') || return 1
	policy_json=$(printf '%s\n' "$plan_json" | jq -cS '.automatic_policy') || return 1
	expected_authorization=$(_worktree_recovery_plan_automatic_token \
		"$plan_id" "$policy_json" "$candidate_count" "$candidate_bytes") || return 1
	[[ "$(printf '%s\n' "$plan_json" | jq -r '.confirmation_token')" == "$expected_authorization" ]] || return 1
	plan_file_digest=$(_worktree_recovery_plan_sha256_text "$plan_json") || return 1
	apply_metadata=$(jq -cn --arg plan_path "$canonical_plan" --arg plan_id "$plan_id" \
		--arg plan_digest "sha256:$plan_file_digest" --arg confirmation "$expected_authorization" \
		--argjson candidate_count "$candidate_count" --argjson candidate_bytes "$candidate_bytes" \
		--argjson automatic_policy "$policy_json" \
		'{plan_path:$plan_path,plan_id:$plan_id,plan_digest:$plan_digest,
		confirmation:$confirmation,candidate_count:$candidate_count,candidate_bytes:$candidate_bytes,
		automatic_policy:$automatic_policy}') || return 1
	WORKTREE_RECOVERY_APPLY_VALIDATED_METADATA="$apply_metadata"
	WORKTREE_RECOVERY_APPLY_VALIDATED_PLAN_JSON="$plan_json"
	return 0
}

_worktree_recovery_apply_validate_receipt_replay() {
	local receipt_path="$1"
	local apply_metadata="$2"
	local plan_id=""
	local plan_digest=""
	local confirmation=""
	local candidate_count=""
	local candidate_bytes=""
	local automatic_policy=""

	_worktree_recovery_apply_canonical_path "$receipt_path" >/dev/null || return 1
	[[ -f "$receipt_path" && ! -L "$receipt_path" && -r "$receipt_path" ]] || return 1
	plan_id=$(printf '%s\n' "$apply_metadata" | jq -r '.plan_id') || return 1
	plan_digest=$(printf '%s\n' "$apply_metadata" | jq -r '.plan_digest') || return 1
	confirmation=$(printf '%s\n' "$apply_metadata" | jq -r '.confirmation') || return 1
	candidate_count=$(printf '%s\n' "$apply_metadata" | jq -r '.candidate_count') || return 1
	candidate_bytes=$(printf '%s\n' "$apply_metadata" | jq -r '.candidate_bytes') || return 1
	automatic_policy=$(printf '%s\n' "$apply_metadata" | jq -c '.automatic_policy // null') || return 1
	jq -e --arg schema "$WORKTREE_RECOVERY_APPLY_RECEIPT_SCHEMA" \
		--arg plan_id "$plan_id" --arg plan_digest "$plan_digest" \
		--arg confirmation "$confirmation" --argjson candidate_count "$candidate_count" \
		--argjson candidate_bytes "$candidate_bytes" --argjson automatic_policy "$automatic_policy" \
		--arg removed "$WORKTREE_RECOVERY_APPLY_OUTCOME_REMOVED" '
		.schema == $schema and .complete == true and .plan_id == $plan_id and
		.plan_digest == $plan_digest and .confirmation == $confirmation and
		.candidate_count == $candidate_count and .expected_allocated_bytes == $candidate_bytes and
		.observed_allocated_bytes == $candidate_bytes and
		(.automatic_policy // null) == $automatic_policy and (.entries | length == $candidate_count) and
		([.entries[] | select(.outcome != $removed)] | length == 0)
	' "$receipt_path" >/dev/null 2>&1
	return $?
}

_worktree_recovery_apply_new_receipt_path() {
	local receipt_path="$1"

	_worktree_recovery_apply_canonical_path "$receipt_path" >/dev/null || return 1
	[[ ! -e "$receipt_path" && ! -L "$receipt_path" && -w "${receipt_path%/*}" ]] || return 1
	return 0
}

_worktree_recovery_apply_reservation_json() {
	local apply_metadata="$1"
	local transaction_id="$2"
	local completion_path="$3"
	local reserved_at=""

	reserved_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	printf '%s\n' "$apply_metadata" | jq -c \
		--arg schema "$WORKTREE_RECOVERY_APPLY_RESERVATION_SCHEMA" \
		--arg transaction_id "$transaction_id" --arg reserved_at "$reserved_at" \
		--arg completion_path "$completion_path" \
		--arg object_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_OBJECT" '
		({schema:$schema,complete:false,plan_id:.plan_id,plan_digest:.plan_digest,
		confirmation:.confirmation,candidate_count:.candidate_count,
		expected_allocated_bytes:.candidate_bytes,transaction_id:$transaction_id,
		reserved_at:$reserved_at,completion_path:$completion_path} +
		(if (.automatic_policy | type) == $object_type
		then {automatic_policy:.automatic_policy} else {} end))'
	return $?
}

_worktree_recovery_apply_validate_reservation() {
	local receipt_path="$1"
	local apply_metadata="$2"
	local transaction_id="$3"
	local canonical_receipt=""
	local completion_path=""

	WORKTREE_RECOVERY_APPLY_RECEIPT_COMPLETION_PATH=""
	canonical_receipt=$(_worktree_recovery_apply_canonical_path "$receipt_path") || return 1
	[[ -f "$receipt_path" && ! -L "$receipt_path" && -r "$receipt_path" ]] || return 1
	jq -e --argjson expected "$apply_metadata" \
		--arg schema "$WORKTREE_RECOVERY_APPLY_RESERVATION_SCHEMA" \
		--arg transaction_id "$transaction_id" \
		--arg string_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_STRING" \
		--arg object_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_OBJECT" '
		type == $object_type and
		(keys | sort) == ((["candidate_count","complete","completion_path","confirmation",
			"expected_allocated_bytes","plan_digest","plan_id","reserved_at","schema",
			"transaction_id"] + (if ($expected.automatic_policy | type) == $object_type
			then ["automatic_policy"] else [] end)) | sort) and
		.schema == $schema and .complete == false and
		.plan_id == $expected.plan_id and .plan_digest == $expected.plan_digest and
		.confirmation == $expected.confirmation and
		.candidate_count == $expected.candidate_count and
		.expected_allocated_bytes == $expected.candidate_bytes and
		(.automatic_policy // null) == ($expected.automatic_policy // null) and
		.transaction_id == $transaction_id and (.reserved_at | type == $string_type) and
		(.completion_path | type == $string_type)
	' "$receipt_path" >/dev/null 2>&1 || return 1
	completion_path=$(jq -r '.completion_path' "$receipt_path") || return 1
	[[ "$completion_path" == "${canonical_receipt%/*}/.${canonical_receipt##*/}.apply."* &&
		-f "$completion_path" && ! -L "$completion_path" && -w "$completion_path" ]] || return 1
	WORKTREE_RECOVERY_APPLY_RECEIPT_COMPLETION_PATH="$completion_path"
	return 0
}

_worktree_recovery_apply_allocate_receipt_completion() {
	local receipt_path="$1"
	local parent_path="${receipt_path%/*}"
	local base_name="${receipt_path##*/}"
	local completion_path=""
	local previous_umask=""

	previous_umask=$(umask)
	umask 077
	completion_path=$(mktemp "${parent_path}/.${base_name}.apply.XXXXXX") || {
		umask "$previous_umask"
		return 1
	}
	umask "$previous_umask"
	chmod 600 "$completion_path" || {
		rm -f "$completion_path"
		return 1
	}
	printf '%s\n' "$completion_path"
	return 0
}

# Reserve the caller-selected receipt path before any archive mutation. Return 2
# only when an exact completed receipt proves this plan already finished.
_worktree_recovery_apply_ensure_receipt_reservation() {
	local receipt_path="$1"
	local apply_metadata="$2"
	local transaction_id="$3"
	local reservation_json=""
	local completion_path=""

	if [[ -e "$receipt_path" || -L "$receipt_path" ]]; then
		if _worktree_recovery_apply_validate_receipt_replay "$receipt_path" "$apply_metadata"; then
			return 2
		fi
		_worktree_recovery_apply_validate_reservation \
			"$receipt_path" "$apply_metadata" "$transaction_id" || return 1
		return 0
	fi
	_worktree_recovery_apply_new_receipt_path "$receipt_path" || return 1
	completion_path=$(_worktree_recovery_apply_allocate_receipt_completion "$receipt_path") || return 1
	reservation_json=$(_worktree_recovery_apply_reservation_json \
		"$apply_metadata" "$transaction_id" "$completion_path") || {
		rm -f "$completion_path"
		return 1
	}
	_worktree_recovery_apply_publish_new "$receipt_path" "$reservation_json" || {
		rm -f "$completion_path"
		return 1
	}
	_worktree_recovery_apply_validate_reservation \
		"$receipt_path" "$apply_metadata" "$transaction_id"
	return $?
}

_worktree_recovery_apply_publish_reserved_receipt() {
	local receipt_path="$1"
	local apply_metadata="$2"
	local transaction_id="$3"
	local receipt_json="$4"
	local completion_path=""

	_worktree_recovery_apply_validate_reservation \
		"$receipt_path" "$apply_metadata" "$transaction_id" || return 1
	completion_path="$WORKTREE_RECOVERY_APPLY_RECEIPT_COMPLETION_PATH"
	printf '%s\n' "$receipt_json" >"$completion_path" || return 1
	chmod 600 "$completion_path" || return 1
	_worktree_recovery_apply_validate_reservation \
		"$receipt_path" "$apply_metadata" "$transaction_id" || return 1
	[[ "$completion_path" == "$WORKTREE_RECOVERY_APPLY_RECEIPT_COMPLETION_PATH" ]] || return 1
	mv "$completion_path" "$receipt_path" || return 1
	_worktree_recovery_apply_validate_receipt_replay "$receipt_path" "$apply_metadata"
	return $?
}

_worktree_recovery_apply_transaction_entries() {
	local plan_json="$1"
	local transaction_id="$2"

	printf '%s\n' "$plan_json" | jq -c --arg candidate "$WORKTREE_RECOVERY_PLAN_DISPOSITION_CANDIDATE" \
		--arg transaction_id "$transaction_id" \
		--arg trash_segment "$WORKTREE_RECOVERY_APPLY_TRASH_SEGMENT" \
		--arg planned "$WORKTREE_RECOVERY_APPLY_STATE_PLANNED" \
		--arg pending "$WORKTREE_RECOVERY_APPLY_OUTCOME_PENDING" '
		def parent_path: .[0:rindex("/")];
		def base_name: .[rindex("/") + 1:];
		[.entries[] | select(.disposition == $candidate)] | to_entries | map(
			.key as $index | .value as $entry |
			{index:$index,role:$entry.role,original_path:$entry.path,
			staged_path:(($entry.path | parent_path) + $trash_segment + $transaction_id +
				"/candidate-" + ($index | tostring) + "-" + ($entry.path | base_name)),
			archive_name:($entry.archive_path | base_name),
			expected_allocated_bytes:$entry.expected_allocated_bytes,
			identity:$entry.identity,evidence:$entry.evidence,reasons:$entry.reasons,
			maintenance:($entry.maintenance // null),
			state:$planned,observed_allocated_bytes:null,staged_at:null,removed_at:null,outcome:$pending})
	'
	return $?
}

_worktree_recovery_apply_atomic_replace() {
	local output_path="$1"
	local payload="$2"
	local parent_path="${output_path%/*}"
	local base_name="${output_path##*/}"
	local temp_path="${parent_path}/.${base_name}.next"
	local previous_umask=""

	[[ -d "$parent_path" && ! -L "$parent_path" ]] || return 1
	if [[ -e "$temp_path" || -L "$temp_path" ]]; then
		[[ -f "$temp_path" && ! -L "$temp_path" ]] || return 1
		rm -f "$temp_path" || return 1
	fi
	previous_umask=$(umask)
	umask 077
	if ! (set -C && printf '%s\n' "$payload" >"$temp_path"); then
		umask "$previous_umask"
		return 1
	fi
	umask "$previous_umask"
	if ! chmod 600 "$temp_path"; then
		rm -f "$temp_path"
		return 1
	fi
	if [[ "$base_name" == "journal.json" &&
		"${AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_JOURNAL_NEXT:-0}" == "1" ]]; then
		return 1
	fi
	if ! mv "$temp_path" "$output_path"; then
		rm -f "$temp_path"
		return 1
	fi
	return 0
}

_worktree_recovery_apply_publish_new() {
	local output_path="$1"
	local payload="$2"
	local parent_path="${output_path%/*}"
	local base_name="${output_path##*/}"
	local temp_path=""
	local previous_umask=""

	[[ ! -e "$output_path" && ! -L "$output_path" ]] || return 1
	previous_umask=$(umask)
	umask 077
	temp_path=$(mktemp "${parent_path}/.${base_name}.tmp.XXXXXX") || {
		umask "$previous_umask"
		return 1
	}
	umask "$previous_umask"
	if ! printf '%s\n' "$payload" >"$temp_path" || ! chmod 600 "$temp_path" ||
		! ln "$temp_path" "$output_path" 2>/dev/null; then
		rm -f "$temp_path"
		return 1
	fi
	rm -f "$temp_path"
	return 0
}

_worktree_recovery_apply_prepare_transaction_dir() {
	local source_root="$1"
	local transaction_id="$2"
	local trash_root="${source_root}/.retention-trash"
	local transaction_dir="${trash_root}/${transaction_id}"

	[[ -d "$source_root" && ! -L "$source_root" ]] || return 1
	if [[ -e "$trash_root" || -L "$trash_root" ]]; then
		[[ -d "$trash_root" && ! -L "$trash_root" ]] || return 1
	else
		mkdir "$trash_root" || return 1
	fi
	if [[ -e "$transaction_dir" || -L "$transaction_dir" ]]; then
		[[ -d "$transaction_dir" && ! -L "$transaction_dir" ]] || return 1
	else
		mkdir "$transaction_dir" || return 1
	fi
	return 0
}

_worktree_recovery_apply_discard_next_file() {
	local output_path="$1"
	local next_path="${output_path%/*}/.${output_path##*/}.next"

	[[ -e "$next_path" || -L "$next_path" ]] || return 0
	[[ -f "$next_path" && ! -L "$next_path" ]] || return 1
	rm -f "$next_path"
	return $?
}

_worktree_recovery_apply_validate_uninitialized_transaction_dirs() {
	local recovery_root="$1"
	local entries_json="$2"
	local transaction_id="$3"
	local journal_path="$4"
	local journal_next="${journal_path%/*}/.${journal_path##*/}.next"
	local transaction_dir=""
	local artifact=""
	local transaction_dirs=""

	transaction_dirs=$(printf '%s\n' "$entries_json" | jq -c \
		--arg recovery_root "$recovery_root" --arg transaction_id "$transaction_id" \
		--arg trash_segment "$WORKTREE_RECOVERY_APPLY_TRASH_SEGMENT" '
		([$recovery_root] + [.[] | .original_path as $original_path |
			$original_path[0:($original_path | rindex("/"))]]) | unique |
		map(. + $trash_segment + $transaction_id)
	') || return 1
	while IFS= read -r transaction_dir; do
		[[ -e "$transaction_dir" || -L "$transaction_dir" ]] || continue
		[[ -d "$transaction_dir" && ! -L "$transaction_dir" ]] || return 1
		for artifact in "$transaction_dir"/.* "$transaction_dir"/*; do
			[[ -e "$artifact" || -L "$artifact" ]] || continue
			case "${artifact##*/}" in
			. | ..) continue ;;
			esac
			[[ "$artifact" == "$journal_next" && -f "$artifact" && ! -L "$artifact" ]] || return 1
		done
	done < <(printf '%s\n' "$transaction_dirs" | jq -r '.[]')
	_worktree_recovery_apply_discard_next_file "$journal_path"
	return $?
}

_worktree_recovery_apply_expected_journal() {
	local transaction_id="$1"
	local apply_metadata="$2"
	local entries_json="$3"
	local started_at="$4"

	printf '%s\n' "$entries_json" | jq -c --arg schema "$WORKTREE_RECOVERY_APPLY_TRANSACTION_SCHEMA" \
		--arg transaction_id "$transaction_id" \
		--arg plan_id "$(printf '%s\n' "$apply_metadata" | jq -r '.plan_id')" \
		--arg plan_digest "$(printf '%s\n' "$apply_metadata" | jq -r '.plan_digest')" \
		--arg confirmation "$(printf '%s\n' "$apply_metadata" | jq -r '.confirmation')" \
		--arg started_at "$started_at" \
		--argjson automatic_policy "$(printf '%s\n' "$apply_metadata" | jq -c '.automatic_policy // null')" \
		'. as $entries | ({schema:$schema,transaction_id:$transaction_id,plan_id:$plan_id,
		plan_digest:$plan_digest,confirmation:$confirmation,started_at:$started_at,entries:$entries} +
		(if $automatic_policy == null then {} else {automatic_policy:$automatic_policy} end))'
	return $?
}

_worktree_recovery_apply_validate_existing_journal() {
	local journal_path="$1"
	local expected_journal="$2"

	[[ -f "$journal_path" && ! -L "$journal_path" ]] || return 1
	printf '%s\n' "$expected_journal" | jq -e --slurpfile actual "$journal_path" \
		--arg planned "$WORKTREE_RECOVERY_APPLY_STATE_PLANNED" \
		--arg staged "$WORKTREE_RECOVERY_APPLY_STATE_STAGED" \
		--arg removed "$WORKTREE_RECOVERY_APPLY_STATE_REMOVED" \
		--arg string_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_STRING" '
		. as $expected | $actual[0] |
		.schema == $expected.schema and .transaction_id == $expected.transaction_id and
		.plan_id == $expected.plan_id and .plan_digest == $expected.plan_digest and
		.confirmation == $expected.confirmation and (.started_at | type == $string_type) and
		(.automatic_policy // null) == ($expected.automatic_policy // null) and
		([.entries[] | .state] | all(. == $planned or . == $staged or . == $removed)) and
		([.entries[] | {index,role,original_path,staged_path,archive_name,
			expected_allocated_bytes,identity,evidence,reasons,maintenance}] ==
			 [$expected.entries[] | {index,role,original_path,staged_path,archive_name,
			expected_allocated_bytes,identity,evidence,reasons,maintenance}])
	' >/dev/null 2>&1
	return $?
}

_worktree_recovery_apply_validate_transaction_scope() {
	local journal_path="$1"
	local transaction_dir=""
	local artifact=""

	jq -e --arg string_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_STRING" \
		--arg trash_segment "$WORKTREE_RECOVERY_APPLY_TRASH_SEGMENT" '
		.transaction_id as $transaction_id |
		all(.entries[];
			.original_path as $original_path | .staged_path as $staged_path |
			($staged_path | type == $string_type) and
			($staged_path[0:($staged_path | rindex("/"))] ==
				($original_path[0:($original_path | rindex("/"))] +
				$trash_segment + $transaction_id)))
	' "$journal_path" >/dev/null 2>&1 || return 1
	while IFS= read -r transaction_dir; do
		[[ -d "$transaction_dir" && ! -L "$transaction_dir" ]] || return 1
		for artifact in "$transaction_dir"/.* "$transaction_dir"/*; do
			[[ -e "$artifact" || -L "$artifact" ]] || continue
			case "${artifact##*/}" in
			. | ..) continue ;;
			journal.json)
				[[ "$artifact" == "$journal_path" && -f "$artifact" && ! -L "$artifact" ]] || return 1
				;;
			*)
				jq -e --arg artifact "$artifact" \
					'any(.entries[]; .staged_path == $artifact)' "$journal_path" >/dev/null 2>&1 || return 1
				;;
			esac
		done
	done < <(jq -r --arg journal_dir "${journal_path%/*}" '
		([.entries[] | .staged_path as $staged_path |
			$staged_path[0:($staged_path | rindex("/"))]] + [$journal_dir]) | unique[]
	' "$journal_path")
	return 0
}

_worktree_recovery_apply_expected_entry() {
	local row_json="$1"

	printf '%s\n' "$row_json" | jq -c '
		{role:.role,path:.original_path,archive_path:.identity.archive_path,
		expected_allocated_bytes:.expected_allocated_bytes,identity:.identity,evidence:.evidence,
		disposition:"candidate",reasons:.reasons}'
	return $?
}

_worktree_recovery_apply_validate_original_entry() {
	local row_json="$1"
	local role=""
	local original_path=""
	local staged_path=""
	local expected_bytes=""
	local current_entry=""
	local expected_entry=""

	role=$(printf '%s\n' "$row_json" | jq -r '.role') || return 1
	original_path=$(printf '%s\n' "$row_json" | jq -r '.original_path') || return 1
	staged_path=$(printf '%s\n' "$row_json" | jq -r '.staged_path') || return 1
	expected_bytes=$(printf '%s\n' "$row_json" | jq -r '.expected_allocated_bytes') || return 1
	[[ -d "$original_path" && ! -L "$original_path" && ! -e "$staged_path" && ! -L "$staged_path" ]] || return 1
	current_entry=$(_worktree_recovery_plan_attributed_entry_json \
		"$role" "$original_path" "$expected_bytes") || return 1
	expected_entry=$(_worktree_recovery_apply_expected_entry "$row_json") || return 1
	[[ "$(printf '%s\n' "$current_entry" | jq -cS '.')" == "$(printf '%s\n' "$expected_entry" | jq -cS '.')" ]] || return 1
	return 0
}

_worktree_recovery_apply_validate_staged_entry() {
	local row_json="$1"
	local original_path=""
	local staged_path=""
	local archive_name=""
	local expected_bytes=""
	local measured=""
	local measured_bytes=""
	local confidence=""
	local staged_recovery=""
	local expected_value=""
	local actual_value=""
	local digest=""
	local process_snapshot=""
	local identity_field=""

	original_path=$(printf '%s\n' "$row_json" | jq -r '.original_path') || return 1
	staged_path=$(printf '%s\n' "$row_json" | jq -r '.staged_path') || return 1
	archive_name=$(printf '%s\n' "$row_json" | jq -r '.archive_name') || return 1
	expected_bytes=$(printf '%s\n' "$row_json" | jq -r '.expected_allocated_bytes') || return 1
	[[ ! -e "$original_path" && ! -L "$original_path" && -d "$staged_path" && ! -L "$staged_path" ]] || return 1
	measured=$(_worktree_recovery_measure_path "$staged_path") || return 1
	IFS='|' read -r measured_bytes confidence _ <<<"$measured"
	[[ "$confidence" == "$WORKTREE_RECOVERY_PLAN_CONFIDENCE_EXACT" && "$measured_bytes" == "$expected_bytes" ]] || return 1
	staged_recovery="${staged_path}/${_WT_RECOVERY_DIR_NAME}"
	[[ -d "$staged_recovery" && ! -L "$staged_recovery" &&
		-d "${staged_path}/${archive_name}" && ! -L "${staged_path}/${archive_name}" ]] || return 1
	for identity_field in format source-real head branch; do
		expected_value=$(printf '%s\n' "$row_json" | jq -r --arg field "$identity_field" '
			if $field == "source-real" then .identity.source_path else .identity[$field] end') || return 1
		actual_value=$(_worktree_recovery_plan_read_line "$staged_recovery/$identity_field") || return 1
		[[ "$actual_value" == "$expected_value" ]] || return 1
	done
	digest=$(_worktree_recovery_plan_sha256_file "$staged_recovery/admin/index") || return 1
	[[ "sha256:$digest" == "$(printf '%s\n' "$row_json" | jq -r '.identity.index_digest')" ]] || return 1
	expected_value=$(printf '%s\n' "$row_json" | jq -r '.identity.completion_digest') || return 1
	if [[ "$expected_value" == "legacy-marker-absent" ]]; then
		[[ ! -e "$staged_recovery/${_WT_RECOVERY_COMPLETE_MARKER}" ]] || return 1
	else
		digest=$(_worktree_recovery_plan_sha256_file \
			"$staged_recovery/${_WT_RECOVERY_COMPLETE_MARKER}") || return 1
		[[ "sha256:$digest" == "$expected_value" ]] || return 1
	fi
	process_snapshot=$(capture_worktree_process_cwds) || return 1
	if _worktree_cwd_snapshot_contains_path "$staged_path" "$staged_path" "$process_snapshot"; then
		return 1
	fi
	return 0
}

_worktree_recovery_apply_preflight_journal() {
	local journal_path="$1"
	local row_json=""
	local state=""
	local original_path=""
	local staged_path=""

	while IFS= read -r row_json; do
		state=$(printf '%s\n' "$row_json" | jq -r '.state') || return 1
		original_path=$(printf '%s\n' "$row_json" | jq -r '.original_path') || return 1
		staged_path=$(printf '%s\n' "$row_json" | jq -r '.staged_path') || return 1
		case "$state" in
		"$WORKTREE_RECOVERY_APPLY_STATE_PLANNED")
			_worktree_recovery_apply_validate_original_entry "$row_json" || return 1
			;;
		"$WORKTREE_RECOVERY_APPLY_STATE_STAGED")
			_worktree_recovery_apply_validate_staged_entry "$row_json" || return 1
			;;
		"$WORKTREE_RECOVERY_APPLY_STATE_REMOVED")
			[[ ! -e "$original_path" && ! -L "$original_path" &&
				! -e "$staged_path" && ! -L "$staged_path" ]] || return 1
			;;
		*) return 1 ;;
		esac
	done < <(jq -c '.entries[]' "$journal_path")
	return 0
}

_worktree_recovery_apply_update_entry() {
	local journal_path="$1"
	local index="$2"
	local state="$3"
	local observed_bytes="$4"
	local timestamp="$5"
	local outcome="$6"
	local updated=""

	updated=$(jq -c --argjson index "$index" --arg state "$state" \
		--argjson observed_bytes "$observed_bytes" --arg timestamp "$timestamp" \
		--arg outcome "$outcome" --arg staged "$WORKTREE_RECOVERY_APPLY_STATE_STAGED" \
		--arg removed "$WORKTREE_RECOVERY_APPLY_STATE_REMOVED" '
		.entries[$index].state = $state |
		.entries[$index].observed_allocated_bytes = $observed_bytes |
		.entries[$index].outcome = $outcome |
		if $state == $staged then .entries[$index].staged_at = $timestamp
		elif $state == $removed then .entries[$index].removed_at = $timestamp
		else . end
	' "$journal_path") || return 1
	_worktree_recovery_apply_atomic_replace "$journal_path" "$updated"
	return $?
}

_worktree_recovery_apply_reconcile_interrupted_entries() {
	local journal_path="$1"
	local row_json=""
	local state=""
	local index=""
	local original_path=""
	local staged_path=""
	local expected_bytes=""
	local timestamp=""

	while IFS= read -r row_json; do
		state=$(printf '%s\n' "$row_json" | jq -r '.state') || return 1
		index=$(printf '%s\n' "$row_json" | jq -r '.index') || return 1
		original_path=$(printf '%s\n' "$row_json" | jq -r '.original_path') || return 1
		staged_path=$(printf '%s\n' "$row_json" | jq -r '.staged_path') || return 1
		expected_bytes=$(printf '%s\n' "$row_json" | jq -r '.expected_allocated_bytes') || return 1
		if [[ "$state" == "$WORKTREE_RECOVERY_APPLY_STATE_PLANNED" &&
			! -e "$original_path" && ! -L "$original_path" &&
			-d "$staged_path" && ! -L "$staged_path" ]]; then
			_worktree_recovery_apply_validate_staged_entry "$row_json" || return 1
			timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
			_worktree_recovery_apply_update_entry "$journal_path" "$index" \
				"$WORKTREE_RECOVERY_APPLY_STATE_STAGED" "$expected_bytes" \
				"$timestamp" "$WORKTREE_RECOVERY_APPLY_OUTCOME_PENDING" || return 1
		elif [[ "$state" == "$WORKTREE_RECOVERY_APPLY_STATE_STAGED" &&
			! -e "$original_path" && ! -L "$original_path" &&
			! -e "$staged_path" && ! -L "$staged_path" ]]; then
			timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
			_worktree_recovery_apply_update_entry "$journal_path" "$index" \
				"$WORKTREE_RECOVERY_APPLY_STATE_REMOVED" "$expected_bytes" \
				"$timestamp" "$WORKTREE_RECOVERY_APPLY_OUTCOME_REMOVED" || return 1
		fi
	done < <(jq -c '.entries[]' "$journal_path")
	return 0
}

_worktree_recovery_apply_stage_candidates() {
	local journal_path="$1"
	local row_json=""
	local state=""
	local index=""
	local original_path=""
	local staged_path=""
	local expected_bytes=""
	local timestamp=""

	while IFS= read -r row_json; do
		state=$(printf '%s\n' "$row_json" | jq -r '.state') || return 1
		[[ "$state" == "$WORKTREE_RECOVERY_APPLY_STATE_PLANNED" ]] || continue
		index=$(printf '%s\n' "$row_json" | jq -r '.index') || return 1
		original_path=$(printf '%s\n' "$row_json" | jq -r '.original_path') || return 1
		staged_path=$(printf '%s\n' "$row_json" | jq -r '.staged_path') || return 1
		expected_bytes=$(printf '%s\n' "$row_json" | jq -r '.expected_allocated_bytes') || return 1
		_worktree_recovery_apply_validate_original_entry "$row_json" || return 1
		mv "$original_path" "$staged_path" || return 1
		if [[ "${AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_MOVE:-0}" == "1" ]]; then
			return 1
		fi
		timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
		_worktree_recovery_apply_update_entry "$journal_path" "$index" \
			"$WORKTREE_RECOVERY_APPLY_STATE_STAGED" "$expected_bytes" \
			"$timestamp" "$WORKTREE_RECOVERY_APPLY_OUTCOME_PENDING" || return 1
	done < <(jq -c '.entries[]' "$journal_path")
	return 0
}

_worktree_recovery_apply_validate_all_staged() {
	local journal_path="$1"
	local row_json=""
	local state=""

	while IFS= read -r row_json; do
		state=$(printf '%s\n' "$row_json" | jq -r '.state') || return 1
		case "$state" in
		"$WORKTREE_RECOVERY_APPLY_STATE_STAGED")
			_worktree_recovery_apply_validate_staged_entry "$row_json" || return 1
			;;
		"$WORKTREE_RECOVERY_APPLY_STATE_REMOVED") ;;
		*) return 1 ;;
		esac
	done < <(jq -c '.entries[]' "$journal_path")
	return 0
}

_worktree_recovery_apply_remove_staged() {
	local journal_path="$1"
	local row_json=""
	local state=""
	local index=""
	local staged_path=""
	local expected_bytes=""
	local timestamp=""
	local removed_this_run=0

	while IFS= read -r row_json; do
		state=$(printf '%s\n' "$row_json" | jq -r '.state') || return 1
		[[ "$state" == "$WORKTREE_RECOVERY_APPLY_STATE_STAGED" ]] || continue
		index=$(printf '%s\n' "$row_json" | jq -r '.index') || return 1
		staged_path=$(printf '%s\n' "$row_json" | jq -r '.staged_path') || return 1
		expected_bytes=$(printf '%s\n' "$row_json" | jq -r '.expected_allocated_bytes') || return 1
		_worktree_recovery_apply_validate_staged_entry "$row_json" || return 1
		rm -rf -- "$staged_path" || return 1
		[[ ! -e "$staged_path" && ! -L "$staged_path" ]] || return 1
		if [[ "${AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_DELETE:-0}" == "1" ]]; then
			return 1
		fi
		timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
		_worktree_recovery_apply_update_entry "$journal_path" "$index" \
			"$WORKTREE_RECOVERY_APPLY_STATE_REMOVED" "$expected_bytes" \
			"$timestamp" "$WORKTREE_RECOVERY_APPLY_OUTCOME_REMOVED" || return 1
		removed_this_run=$((removed_this_run + 1))
		if [[ "${AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_REMOVE:-0}" == "1" &&
			"$removed_this_run" -eq 1 ]]; then
			return 1
		fi
	done < <(jq -c '.entries[]' "$journal_path")
	return 0
}

_worktree_recovery_apply_receipt_json() {
	local journal_path="$1"
	local apply_metadata="$2"
	local completed_at=""

	completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	jq -c --arg schema "$WORKTREE_RECOVERY_APPLY_RECEIPT_SCHEMA" \
		--arg completed_at "$completed_at" \
		--argjson metadata "$apply_metadata" \
		--arg removed "$WORKTREE_RECOVERY_APPLY_OUTCOME_REMOVED" \
		--arg object_type "$WORKTREE_RECOVERY_APPLY_JSON_TYPE_OBJECT" '
		({schema:$schema,complete:true,plan_id:.plan_id,plan_digest:.plan_digest,
		confirmation:.confirmation,transaction_id:.transaction_id,
		started_at:.started_at,completed_at:$completed_at,
		candidate_count:(.entries | length),
		expected_allocated_bytes:([.entries[].expected_allocated_bytes] | add // 0),
		observed_allocated_bytes:([.entries[].observed_allocated_bytes] | add // 0),
		entries:[.entries[] | {original_path,staged_path,identity,maintenance,
			expected_allocated_bytes,observed_allocated_bytes,outcome,staged_at,removed_at}]} +
		(if (.automatic_policy | type) == $object_type
		then {automatic_policy:.automatic_policy} else {} end)) |
		select(.plan_id == $metadata.plan_id and .plan_digest == $metadata.plan_digest and
			.confirmation == $metadata.confirmation and .candidate_count == $metadata.candidate_count and
			.expected_allocated_bytes == $metadata.candidate_bytes and
			.observed_allocated_bytes == $metadata.candidate_bytes and
			([.entries[] | select(.outcome != $removed)] | length == 0))
	' "$journal_path"
	return $?
}

_worktree_recovery_apply_cleanup_transaction() {
	local journal_path="$1"
	local transaction_dir=""
	local trash_root=""
	local dirs_json=""

	dirs_json=$(jq -c --arg journal_dir "${journal_path%/*}" '
		([.entries[] | .staged_path as $staged_path |
			$staged_path[0:($staged_path | rindex("/"))]] + [$journal_dir]) | unique
	' "$journal_path") || return 1
	rm -f "$journal_path" || return 1
	while IFS= read -r transaction_dir; do
		rmdir "$transaction_dir" 2>/dev/null || true
		trash_root="${transaction_dir%/*}"
		rmdir "$trash_root" 2>/dev/null || true
	done < <(printf '%s\n' "$dirs_json" | jq -r '.[]')
	return 0
}

_worktree_recovery_apply_under_lock() {
	local plan_path="$1"
	local receipt_path="$2"
	local supplied_confirmation="$3"
	local recovery_root="$4"
	local authorization_mode="${5:-manual}"
	local apply_metadata=""
	local plan_json=""
	local plan_digest=""
	local transaction_id=""
	local entries_json=""
	local transaction_dir=""
	local journal_path=""
	local expected_journal=""
	local started_at=""
	local journal_json=""
	local source_root=""
	local receipt_json=""
	local receipt_status=0

	case "$authorization_mode" in
	manual) _worktree_recovery_apply_validate_plan "$plan_path" "$supplied_confirmation" || return 1 ;;
	automatic) _worktree_recovery_apply_validate_automatic_plan "$plan_path" || return 1 ;;
	*) return 1 ;;
	esac
	apply_metadata="$WORKTREE_RECOVERY_APPLY_VALIDATED_METADATA"
	plan_json="$WORKTREE_RECOVERY_APPLY_VALIDATED_PLAN_JSON"
	_worktree_recovery_apply_validate_control_path_scope \
		"$receipt_path" "$plan_json" || return 1
	plan_digest=$(printf '%s\n' "$apply_metadata" | jq -r '.plan_digest | sub("^sha256:"; "")') || return 1
	transaction_id="apply-${plan_digest}"
	entries_json=$(_worktree_recovery_apply_transaction_entries "$plan_json" "$transaction_id") || return 1
	transaction_dir="${recovery_root}/.retention-trash/${transaction_id}"
	journal_path="${transaction_dir}/journal.json"
	_worktree_recovery_apply_ensure_receipt_reservation \
		"$receipt_path" "$apply_metadata" "$transaction_id" || receipt_status=$?
	if [[ "$receipt_status" -eq 2 ]]; then
		return 0
	fi
	[[ "$receipt_status" -eq 0 ]] || return "$receipt_status"
	if [[ "${AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_RECEIPT_RESERVATION:-0}" == "1" ]]; then
		return 1
	fi
	if [[ -f "$journal_path" && ! -L "$journal_path" ]]; then
		started_at=$(jq -r '.started_at // empty' "$journal_path") || return 1
	else
		[[ ! -e "$journal_path" && ! -L "$journal_path" ]] || return 1
		_worktree_recovery_apply_validate_uninitialized_transaction_dirs \
			"$recovery_root" "$entries_json" "$transaction_id" "$journal_path" || return 1
		started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	fi
	expected_journal=$(_worktree_recovery_apply_expected_journal \
		"$transaction_id" "$apply_metadata" "$entries_json" "$started_at") || return 1
	if [[ -f "$journal_path" ]]; then
		_worktree_recovery_apply_validate_existing_journal "$journal_path" "$expected_journal" || return 1
		_worktree_recovery_apply_discard_next_file "$journal_path" || return 1
	else
		_worktree_recovery_apply_prepare_transaction_dir "$recovery_root" "$transaction_id" || return 1
		while IFS= read -r source_root; do
			_worktree_recovery_apply_prepare_transaction_dir "$source_root" "$transaction_id" || return 1
		done < <(printf '%s\n' "$entries_json" | jq -r '
			[.[] | .original_path as $original_path |
				$original_path[0:($original_path | rindex("/"))]] | unique[]
		')
		if [[ "${AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_TRANSACTION_DIR:-0}" == "1" ]]; then
			return 1
		fi
		journal_json="$expected_journal"
		_worktree_recovery_apply_atomic_replace "$journal_path" "$journal_json" || return 1
	fi
	_worktree_recovery_apply_validate_transaction_scope "$journal_path" || return 1
	_worktree_recovery_apply_reconcile_interrupted_entries "$journal_path" || return 1
	_worktree_recovery_apply_preflight_journal "$journal_path" || return 1
	_worktree_recovery_apply_stage_candidates "$journal_path" || return 1
	if [[ "${AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_STAGE:-0}" == "1" ]]; then
		return 1
	fi
	_worktree_recovery_apply_validate_all_staged "$journal_path" || return 1
	_worktree_recovery_apply_remove_staged "$journal_path" || return 1
	receipt_json=$(_worktree_recovery_apply_receipt_json "$journal_path" "$apply_metadata") || return 1
	_worktree_recovery_apply_publish_reserved_receipt \
		"$receipt_path" "$apply_metadata" "$transaction_id" "$receipt_json" || return 1
	_worktree_recovery_apply_cleanup_transaction "$journal_path" || return 1
	return 0
}

worktree_recovery_apply() {
	local plan_path="$1"
	local receipt_path="$2"
	local supplied_confirmation="$3"
	local plan_json=""
	local recovery_root=""
	local recovery_root_real=""
	local apply_status=0

	command -v jq >/dev/null 2>&1 || return 1
	_worktree_recovery_apply_validate_plan "$plan_path" "$supplied_confirmation" || return 1
	plan_json="$WORKTREE_RECOVERY_APPLY_VALIDATED_PLAN_JSON"
	receipt_path=$(_worktree_recovery_apply_canonical_path "$receipt_path") || return 1
	_worktree_recovery_apply_validate_control_path_scope \
		"$receipt_path" "$plan_json" || return 1
	recovery_root=$(_worktree_recovery_store_root) || return 1
	[[ -d "$recovery_root" && ! -L "$recovery_root" ]] || return 1
	recovery_root_real=$(cd "$recovery_root" 2>/dev/null && pwd -P) || return 1
	_worktree_recovery_acquire_producer_lock "$recovery_root_real" || return 1
	_worktree_recovery_apply_under_lock "$plan_path" "$receipt_path" \
		"$supplied_confirmation" "$recovery_root_real" "manual" || apply_status=$?
	_worktree_recovery_release_producer_lock || apply_status=1
	[[ "$apply_status" -eq 0 ]] || return "$apply_status"
	printf '%s\n' "$receipt_path"
	return 0
}

worktree_recovery_apply_automatic() {
	local plan_path="$1"
	local receipt_path="$2"
	local plan_json=""
	local recovery_root=""
	local recovery_root_real=""
	local apply_status=0

	command -v jq >/dev/null 2>&1 || return 1
	_worktree_recovery_apply_validate_automatic_plan "$plan_path" || return 1
	plan_json="$WORKTREE_RECOVERY_APPLY_VALIDATED_PLAN_JSON"
	receipt_path=$(_worktree_recovery_apply_canonical_path "$receipt_path") || return 1
	_worktree_recovery_apply_validate_control_path_scope \
		"$receipt_path" "$plan_json" || return 1
	recovery_root=$(_worktree_recovery_store_root) || return 1
	[[ -d "$recovery_root" && ! -L "$recovery_root" ]] || return 1
	recovery_root_real=$(cd "$recovery_root" 2>/dev/null && pwd -P) || return 1
	_worktree_recovery_acquire_producer_lock "$recovery_root_real" || return 1
	_worktree_recovery_apply_under_lock "$plan_path" "$receipt_path" \
		"" "$recovery_root_real" "automatic" || apply_status=$?
	_worktree_recovery_release_producer_lock || apply_status=1
	[[ "$apply_status" -eq 0 ]] || return "$apply_status"
	printf '%s\n' "$receipt_path"
	return 0
}
