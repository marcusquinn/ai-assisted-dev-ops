#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# =============================================================================
# Email Filter Helper (t2856)
# =============================================================================
# Sieve-style filter rules for auto-attaching email sources to cases.
# Reads _config/email-filters.json for rules, evaluates against recently
# promoted email sources, attaches matching sources to cases.
#
# Usage:
#   email-filter-helper.sh tick   [<knowledge-root>]    Run filter pass (pulse routine)
#   email-filter-helper.sh add    [<knowledge-root>]    Interactive: add a new rule
#   email-filter-helper.sh test   <rule-name> [<knowledge-root>]  Dry-run rule
#   email-filter-helper.sh list   [<knowledge-root>]    List rules with hit counts
#   email-filter-helper.sh help
#
# Filter config: <knowledge-root>/../_config/email-filters.json
# Filter state:  <knowledge-root>/.email-filter-state.json
# Audit log:     _cases/<case-id>/comms/email-attach.jsonl
#
# Dependencies: jq, python3 (for regex matching), case-helper.sh
# Part of aidevops email channel (P5c / t2856).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

readonly CASE_HELPER="${SCRIPT_DIR}/case-helper.sh"
readonly MATCH_RULES_PY="${SCRIPT_DIR}/email_match_rules.py"
readonly COLLECTION_RECEIPTS_PY="${SCRIPT_DIR}/email_collection_receipts.py"
readonly DEFAULT_FILTER_CONFIG_NAME="_config/email-filters.json"
readonly FILTER_STATE_FILENAME=".email-filter-state.json"
readonly _RULE_OPERATOR_KEY="operator"
readonly _RULE_VALUE_KEY="value"

# =============================================================================
# Root resolution
# =============================================================================

_find_knowledge_root() {
	local dir="$PWD"
	while [[ "$dir" != "/" ]]; do
		if [[ -d "${dir}/_knowledge" ]]; then
			echo "${dir}/_knowledge"
			return 0
		fi
		dir="$(dirname "$dir")"
	done
	return 1
}

_resolve_root() {
	local candidate="${1:-}"
	if [[ -n "$candidate" ]]; then
		echo "$candidate"
		return 0
	fi
	if [[ -n "${KNOWLEDGE_ROOT:-}" ]]; then
		echo "$KNOWLEDGE_ROOT"
		return 0
	fi
	if ! _find_knowledge_root; then
		print_error "No _knowledge/ directory found. Pass <knowledge-root> or set KNOWLEDGE_ROOT."
		return 1
	fi
	return 0
}

_resolve_filter_config() {
	local knowledge_root="$1"
	# Config lives one level up from _knowledge/: <repo>/_config/email-filters.json
	local parent
	parent="$(dirname "$knowledge_root")"
	echo "${parent}/${DEFAULT_FILTER_CONFIG_NAME}"
}

_resolve_filter_state() {
	local knowledge_root="$1"
	echo "${knowledge_root}/${FILTER_STATE_FILENAME}"
}

_resolve_mailbox_config() {
	local knowledge_root="$1"
	local repo_config
	repo_config="$(dirname "$knowledge_root")/_config/mailboxes.json"
	if [[ -f "$repo_config" ]]; then
		printf '%s\n' "$repo_config"
		return 0
	fi
	local global_config="${HOME}/.config/aidevops/mailboxes.json"
	[[ -f "$global_config" ]] && printf '%s\n' "$global_config"
	return 0
}

_rule_account_identities() {
	local rule_json="$1" knowledge_root="$2"
	local mailbox_config
	mailbox_config="$(_resolve_mailbox_config "$knowledge_root")"
	[[ -n "$mailbox_config" ]] || return 0
	local mailbox_ids
	mailbox_ids="$(_jq_c "$rule_json" '.mailboxes // []')"
	jq -r --argjson ids "$mailbox_ids" '
        [.mailboxes[]
         | .id as $id
         | select(($ids | length) == 0 or ($ids | index($id)) != null)
         | ((.identities // []) + [(.user // empty)])[]]
        | unique[]
    ' "$mailbox_config" 2>/dev/null || true
	return 0
}

_resolve_cases_dir() {
	local knowledge_root="$1"
	local parent
	parent="$(dirname "$knowledge_root")"
	echo "${parent}/_cases"
}

# =============================================================================
# Dependency checks
# =============================================================================

_check_deps() {
	local ok=1
	if ! command -v jq &>/dev/null; then
		print_error "jq is required. Install: brew install jq"
		ok=0
	fi
	if ! command -v python3 &>/dev/null; then
		print_error "python3 is required for regex matching."
		ok=0
	fi
	if [[ ! -f "$MATCH_RULES_PY" ]]; then
		print_error "email_match_rules.py is required for version 2 filters."
		ok=0
	fi
	if [[ ! -f "$COLLECTION_RECEIPTS_PY" ]]; then
		print_error "email_collection_receipts.py is required for collection rules."
		ok=0
	fi
	[[ "$ok" -eq 1 ]] && return 0 || return 1
}

# =============================================================================
# jq helpers — centralise repeated jq-pipe-with-error-suppression pattern
# =============================================================================

_jq_r() {
	# _jq_r <json_string> <expr>  — pipe json through jq -r, suppress errors
	local _input="$1" _expr="$2"
	echo "$_input" | jq -r "$_expr" 2>/dev/null || true
}

_jq_c() {
	# _jq_c <json_string> <expr>  — pipe json through jq -c, suppress errors
	local _input="$1" _expr="$2"
	echo "$_input" | jq -c "$_expr" 2>/dev/null || true
}

# =============================================================================
# Filter config I/O
# =============================================================================

_load_filter_config() {
	local config_file="$1"
	if [[ ! -f "$config_file" ]]; then
		echo '{"rules": []}'
		return 0
	fi
	jq '.' "$config_file"
}

_ensure_filter_config_dir() {
	local config_file="$1"
	local dir
	dir="$(dirname "$config_file")"
	mkdir -p "$dir"
}

# =============================================================================
# Filter state I/O (no-double-process guard)
# =============================================================================

_load_filter_state() {
	local state_file="$1"
	if [[ -f "$state_file" ]]; then
		jq -r '.last_processed_source_id // ""' "$state_file" 2>/dev/null || true
	else
		echo ""
	fi
}

_load_filter_state_digest() {
	local state_file="$1"
	if [[ -f "$state_file" ]]; then
		jq -r '.rules_digest // ""' "$state_file" 2>/dev/null || true
	else
		echo ""
	fi
	return 0
}

_load_filter_source_digests() {
	local state_file="$1"
	if [[ -f "$state_file" ]]; then
		jq -c '.source_collection_digests // {}' "$state_file" 2>/dev/null || echo '{}'
	else
		echo '{}'
	fi
	return 0
}

_filter_rules_digest() {
	local filter_json="$1"
	printf '%s' "$filter_json" |
		jq -cS '[.rules[] | select(if has("enabled") then .enabled else true end)]' |
		python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'
	return 0
}

_source_collection_digest() {
	local meta_path="$1"
	jq -cS '.collection_refs // []' "$meta_path" |
		python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'
	return 0
}

_save_filter_state() {
	local state_file="$1" last_id="$2" rules_digest="$3" source_digests="$4"
	local ts
	ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
	jq -n --arg last_id "$last_id" --arg ts "$ts" --arg digest "$rules_digest" \
		--argjson source_digests "$source_digests" \
		'{last_processed_source_id: $last_id, updated_at: $ts, rules_digest: $digest, source_collection_digests: $source_digests}' >"$state_file"
	return 0
}

# =============================================================================
# Source enumeration
# =============================================================================

_list_email_sources() {
	# List source_ids (and their meta.json paths) for email sources under sources/
	local sources_dir="$1"
	if [[ ! -d "$sources_dir" ]]; then
		return 0
	fi
	# Output: source_id<TAB>meta_path, ordered by ingested_at from meta.json
	find "$sources_dir" -name "meta.json" -type f 2>/dev/null |
		while IFS= read -r meta_path; do
			local source_id
			source_id="$(jq -r '.id // ""' "$meta_path" 2>/dev/null || true)"
			[[ -z "$source_id" ]] && source_id="$(dirname "$meta_path" | xargs basename)"
			local ingested_at
			ingested_at="$(jq -r '.ingested_at // ""' "$meta_path" 2>/dev/null || true)"
			printf '%s\t%s\t%s\n' "$source_id" "$meta_path" "$ingested_at"
		done | sort -t$'\t' -k3
}

_get_meta_field() {
	local meta_path="$1" field="$2"
	jq -r --arg f "$field" '.[$f] // ""' "$meta_path" 2>/dev/null || true
}

_rule_is_eligible_for_source() {
	local rule_json="$1"
	local meta_path="$2"
	printf '%s' "$rule_json" |
		python3 "$COLLECTION_RECEIPTS_PY" eligible --meta "$meta_path" >/dev/null
	return $?
}

_rule_collection_mode() {
	local rule_json="$1"
	_jq_r "$rule_json" '
        if has("collection") then .collection
        elif ((.match // {}) | (has("all") or has("any"))) then true
        else false
        end
    '
	return 0
}

# =============================================================================
# Rule matching
# =============================================================================

_lowercase() {
	local value="$1"
	printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
	return 0
}

_match_contains() {
	local haystack="$1" needle="$2"
	local haystack_lower needle_lower
	[[ -z "$needle" ]] && return 0
	haystack_lower="$(_lowercase "$haystack")"
	needle_lower="$(_lowercase "$needle")"
	[[ "$haystack_lower" == *"$needle_lower"* ]] && return 0 || return 1
}

_match_equals() {
	local a="$1" b="$2"
	local a_lower b_lower
	a_lower="$(_lowercase "$a")"
	b_lower="$(_lowercase "$b")"
	[[ "$a_lower" == "$b_lower" ]] && return 0 || return 1
}

_match_subject_contains_any() {
	local subject="$1" values_json="$2"
	if [[ -z "$values_json" || "$values_json" == "null" ]]; then
		return 0
	fi
	# values_json is a JSON array of strings
	while IFS= read -r val; do
		_match_contains "$subject" "$val" && return 0
	done < <(echo "$values_json" | jq -r '.[]' 2>/dev/null || true)
	return 1
}

_match_regex() {
	local value="$1" pattern="$2"
	[[ -z "$pattern" ]] && return 0
	python3 -c "
import re, sys
v = sys.argv[1]
p = sys.argv[2]
sys.exit(0 if re.search(p, v, re.IGNORECASE) else 1)
" "$value" "$pattern" 2>/dev/null && return 0 || return 1
}

_match_has_attachment_kind() {
	local meta_path="$1" kind="$2"
	[[ -z "$kind" ]] && return 0
	# Check attachments array in meta.json
	local count
	count="$(jq -r --arg k "$kind" '[.attachments // [] | .[] | select(.kind == $k)] | length' "$meta_path" 2>/dev/null || echo "0")"
	[[ "$count" -gt 0 ]] && return 0 || return 1
}

# Evaluate a single rule match block against a source meta.json
_read_two_fields() {
	# Concatenate two meta.json fields: _read_two_fields <meta_path> <field1> <field2>
	local meta_path="$1" field1="$2" field2="$3"
	local v1 v2
	v1="$(_get_meta_field "$meta_path" "$field1")"
	v2="$(_get_meta_field "$meta_path" "$field2")"
	printf '%s%s' "$v1" "$v2"
	return 0
}

# Returns 0 (match) or 1 (no match)
_evaluate_rule_match() {
	local match_json="$1" meta_path="$2" identities="${3:-}" collection="${4:-false}"
	local schema_v2
	schema_v2="$(_jq_r "$match_json" 'if (has("all") or has("any")) then "1" else "0" end')"
	if [[ "$schema_v2" == "1" ]]; then
		local identity_args=() identity rule_payload
		while IFS= read -r identity; do
			[[ -n "$identity" ]] && identity_args+=(--account-identity "$identity")
		done <<<"$identities"
		rule_payload="$(jq -cn --argjson match "$match_json" --argjson collection "$collection" \
			'{"id":"post-ingest-rule","collection":$collection,"match":$match}')"
		if printf '%s' "$rule_payload" | python3 "$MATCH_RULES_PY" match-meta --meta "$meta_path" "${identity_args[@]}" >/dev/null; then
			return 0
		fi
		return 1
	fi

	local from subject body
	from="$(_read_two_fields "$meta_path" "from" "sender")"
	subject="$(_read_two_fields "$meta_path" "subject" "title")"
	body="$(_read_two_fields "$meta_path" "body_preview" "body")"

	# from_contains
	local from_contains
	from_contains="$(_jq_r "$match_json" '.from_contains // ""')"
	if [[ -n "$from_contains" ]]; then
		_match_contains "$from" "$from_contains" || return 1
	fi

	# from_equals
	local from_equals
	from_equals="$(_jq_r "$match_json" '.from_equals // ""')"
	if [[ -n "$from_equals" ]]; then
		_match_equals "$from" "$from_equals" || return 1
	fi

	# subject_contains_any
	local subj_any
	subj_any="$(_jq_c "$match_json" '.subject_contains_any // null')"
	if [[ "$subj_any" != "null" && -n "$subj_any" ]]; then
		_match_subject_contains_any "$subject" "$subj_any" || return 1
	fi

	# subject_matches_regex
	local subj_re
	subj_re="$(_jq_r "$match_json" '.subject_matches_regex // ""')"
	if [[ -n "$subj_re" ]]; then
		_match_regex "$subject" "$subj_re" || return 1
	fi

	# body_contains
	local body_contains
	body_contains="$(_jq_r "$match_json" '.body_contains // ""')"
	if [[ -n "$body_contains" ]]; then
		_match_contains "$body" "$body_contains" || return 1
	fi

	# has_attachment_kind
	local att_kind
	att_kind="$(_jq_r "$match_json" '.has_attachment_kind // ""')"
	if [[ -n "$att_kind" ]]; then
		_match_has_attachment_kind "$meta_path" "$att_kind" || return 1
	fi

	return 0
}

_rule_matches_source() {
	local collection="$1"
	local match_json="$2"
	local meta_path="$3"
	local identities="$4"
	# Exact collection provenance already certifies the private transport match.
	if [[ "$collection" == "true" ]]; then
		return 0
	fi
	if _evaluate_rule_match "$match_json" "$meta_path" "$identities" "$collection"; then
		return 0
	fi
	return 1
}

# =============================================================================
# Actions
# =============================================================================

_action_attach_to_case() {
	local source_id="$1" case_id="$2" role="${3:-evidence}" dry_run="${4:-0}"
	if [[ "$dry_run" -eq 1 ]]; then
		print_info "  [dry-run] Would attach ${source_id} to case ${case_id} (role: ${role})"
		return 0
	fi
	if [[ -x "$CASE_HELPER" ]]; then
		"$CASE_HELPER" attach "$case_id" "$source_id" --role "$role" 2>/dev/null || {
			print_warning "  case-helper.sh attach failed for source ${source_id} → case ${case_id}"
		}
	else
		print_warning "  case-helper.sh not found or not executable: ${CASE_HELPER}"
	fi
	return 0
}

_action_set_sensitivity() {
	local source_id="$1" meta_path="$2" sensitivity_level="$3" dry_run="${4:-0}"
	if [[ "$dry_run" -eq 1 ]]; then
		print_info "  [dry-run] Would set sensitivity=${sensitivity_level} on ${source_id}"
		return 0
	fi
	# Update the sensitivity field in meta.json directly
	if [[ -f "$meta_path" ]]; then
		local tmp
		tmp="$(mktemp)"
		jq --arg s "$sensitivity_level" '.sensitivity = $s' "$meta_path" >"$tmp" && mv "$tmp" "$meta_path" || rm -f "$tmp"
	fi
	return 0
}

_write_audit_log() {
	local cases_dir="$1" case_id="$2" source_id="$3" rule_name="$4" dry_run="${5:-0}"
	[[ "$dry_run" -eq 1 ]] && return 0
	local case_comms_dir="${cases_dir}/${case_id}/comms"
	mkdir -p "$case_comms_dir"
	local audit_log="${case_comms_dir}/email-attach.jsonl"
	local ts
	ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
	printf '{"ts":"%s","source_id":"%s","rule":"%s","action":"attached"}\n' \
		"$ts" "$source_id" "$rule_name" >>"$audit_log"
}

# Execute all actions for a matched rule
_execute_rule_actions() {
	local actions_json="$1" source_id="$2" meta_path="$3" cases_dir="$4" rule_name="$5" dry_run="${6:-0}"
	local action_count
	action_count="$(_jq_r "$actions_json" 'length')"

	local i=0
	while [[ "$i" -lt "$action_count" ]]; do
		local action
		action="$(_jq_c "$actions_json" ".[$i]")"

		local attach_to_case role set_sensitivity
		attach_to_case="$(_jq_r "$action" '.attach_to_case // ""')"
		role="$(_jq_r "$action" '.role // "evidence"')"
		set_sensitivity="$(_jq_r "$action" '.set_sensitivity // ""')"

		if [[ -n "$attach_to_case" ]]; then
			_action_attach_to_case "$source_id" "$attach_to_case" "$role" "$dry_run"
			_write_audit_log "$cases_dir" "$attach_to_case" "$source_id" "$rule_name" "$dry_run"
		fi

		if [[ -n "$set_sensitivity" ]]; then
			_action_set_sensitivity "$source_id" "$meta_path" "$set_sensitivity" "$dry_run"
		fi

		i=$((i + 1))
	done
	return 0
}

_process_source_rules() {
	local source_id="$1"
	local meta_path="$2"
	local filter_json="$3"
	local rule_count="$4"
	local knowledge_root="$5"
	local cases_dir="$6"
	local dry_run="$7"
	local matched=1 i=0
	while [[ "$i" -lt "$rule_count" ]]; do
		local rule enabled collection
		rule="$(_jq_c "$filter_json" ".rules[$i]")"
		enabled="$(_jq_r "$rule" 'if has("enabled") then .enabled else true end')"
		collection="$(_rule_collection_mode "$rule")"
		if [[ "$enabled" != "true" ]] || ! _rule_is_eligible_for_source "$rule" "$meta_path"; then
			i=$((i + 1))
			continue
		fi
		local rule_name match_json actions_json identities
		rule_name="$(_jq_r "$rule" '.name // "unnamed"')"
		match_json="$(_jq_c "$rule" '.match // {}')"
		actions_json="$(_jq_c "$rule" '.actions // []')"
		identities="$(_rule_account_identities "$rule" "$knowledge_root")"
		if _rule_matches_source "$collection" "$match_json" "$meta_path" "$identities"; then
			print_info "Match: ${rule_name} → ${source_id}"
			_execute_rule_actions "$actions_json" "$source_id" "$meta_path" \
				"$cases_dir" "$rule_name" "$dry_run"
			matched=0
		fi
		i=$((i + 1))
	done
	return "$matched"
}

# =============================================================================
# tick: main pulse routine — evaluate all rules against unprocessed sources
# =============================================================================

cmd_tick() {
	local knowledge_root="" dry_run=0
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}"
		case "$_cur" in
		--dry-run) dry_run=1 ;;
		-*)
			print_error "Unknown option: ${_cur}"
			return 1
			;;
		*) knowledge_root="$_cur" ;;
		esac
		shift
	done

	knowledge_root="$(_resolve_root "$knowledge_root")" || return 1
	_check_deps || return 1

	local config_file state_file cases_dir sources_dir
	config_file="$(_resolve_filter_config "$knowledge_root")"
	state_file="$(_resolve_filter_state "$knowledge_root")"
	cases_dir="$(_resolve_cases_dir "$knowledge_root")"
	sources_dir="${knowledge_root}/sources"

	local filter_json
	filter_json="$(_load_filter_config "$config_file")"

	local rule_count
	rule_count="$(echo "$filter_json" | jq '.rules | length' 2>/dev/null || echo "0")"

	if [[ "$rule_count" -eq 0 ]]; then
		print_info "No filter rules defined in ${config_file}."
		return 0
	fi

	# Load state: last processed source_id
	local last_id saved_digest rules_digest saved_source_digests
	last_id="$(_load_filter_state "$state_file")"
	saved_digest="$(_load_filter_state_digest "$state_file")"
	saved_source_digests="$(_load_filter_source_digests "$state_file")"
	rules_digest="$(_filter_rules_digest "$filter_json")"
	if [[ -n "$last_id" && "$saved_digest" != "$rules_digest" ]]; then
		last_id=""
		saved_source_digests='{}'
	fi

	# Enumerate email sources, filter to those after last_id
	local matched_any=0 saw_last=0 last_seen_id="" current_source_digests='{}'
	while IFS=$'\t' read -r source_id meta_path _ingested_at; do
		[[ -z "$source_id" || -z "$meta_path" ]] && continue
		local current_source_digest saved_source_digest source_changed=0
		current_source_digest="$(_source_collection_digest "$meta_path")"
		saved_source_digest=$(printf '%s' "$saved_source_digests" |
			jq -r --arg source_id "$source_id" '.[$source_id] // ""')
		current_source_digests=$(printf '%s' "$current_source_digests" |
			jq -c --arg source_id "$source_id" --arg digest "$current_source_digest" \
				'. + {($source_id): $digest}')
		if [[ -n "$saved_source_digest" && "$saved_source_digest" != "$current_source_digest" ]]; then
			source_changed=1
		fi

		# State gate: skip until we've passed last_id
		if [[ -n "$last_id" && "$saw_last" -eq 0 ]]; then
			if [[ "$source_id" == "$last_id" ]]; then
				saw_last=1
			fi
			last_seen_id="$source_id"
			if [[ "$source_changed" -eq 0 ]]; then
				continue
			fi
		fi

		last_seen_id="$source_id"

		if _process_source_rules "$source_id" "$meta_path" "$filter_json" "$rule_count" \
			"$knowledge_root" "$cases_dir" "$dry_run"; then
			matched_any=1
		fi
	done < <(_list_email_sources "$sources_dir")

	# Persist state: record last processed source_id
	if [[ "$dry_run" -eq 0 && -n "$last_seen_id" ]]; then
		_save_filter_state "$state_file" "$last_seen_id" "$rules_digest" "$current_source_digests"
	fi

	if [[ "$matched_any" -eq 0 ]]; then
		print_info "No matches in this tick pass."
	fi
	return 0
}

# =============================================================================
# add: interactive rule addition
# =============================================================================

cmd_add() {
	local knowledge_root=""
	if [[ $# -gt 0 ]]; then
		local _kr="${1:-}"
		knowledge_root="$_kr"
		shift
	fi
	knowledge_root="$(_resolve_root "$knowledge_root")" || return 1
	_check_deps || return 1

	local config_file
	config_file="$(_resolve_filter_config "$knowledge_root")"
	_ensure_filter_config_dir "$config_file"

	print_info "Adding new email filter rule to ${config_file}"

	local rule_name from_contains from_equals subject_contains_any
	local attach_to_case role set_sensitivity

	printf 'Rule name: ' && read -r rule_name
	printf 'from_contains (partial match on From/Sender, leave blank to skip): ' && read -r from_contains
	printf 'from_equals   (exact match on From/Sender, leave blank to skip): ' && read -r from_equals
	printf 'subject_contains_any (comma-separated phrases, leave blank to skip): ' && read -r subject_contains_any
	printf 'attach_to_case (case-id, leave blank to skip): ' && read -r attach_to_case
	printf 'role (evidence|reference, default: evidence): ' && read -r role
	[[ -z "$role" ]] && role="evidence"
	printf 'set_sensitivity (public|internal|confidential|restricted|privileged, leave blank to skip): ' && read -r set_sensitivity

	# Build a version 2 shared matcher block. Interactive rules remain
	# post-ingest routing rules unless collection selectors are added manually.
	local match_json='{"all":[],"any":[]}'
	[[ -n "$from_contains" ]] && match_json="$(echo "$match_json" | jq --arg v "$from_contains" --arg op "$_RULE_OPERATOR_KEY" --arg val "$_RULE_VALUE_KEY" '.all += [{"field":"from",($op):"contains",($val):$v}]')"
	[[ -n "$from_equals" ]] && match_json="$(echo "$match_json" | jq --arg v "$from_equals" --arg op "$_RULE_OPERATOR_KEY" --arg val "$_RULE_VALUE_KEY" '.all += [{"field":"from",($op):"exact_address",($val):$v}]')"
	if [[ -n "$subject_contains_any" ]]; then
		local phrases_json
		phrases_json="$(echo "$subject_contains_any" | python3 -c "
import sys, json
raw = sys.stdin.read().strip()
parts = [p.strip() for p in raw.split(',') if p.strip()]
print(json.dumps(parts))
" 2>/dev/null || echo '[]')"
		match_json="$(echo "$match_json" | jq --argjson a "$phrases_json" --arg op "$_RULE_OPERATOR_KEY" --arg val "$_RULE_VALUE_KEY" '.any += [$a[] | {"field":"subject",($op):"phrase",($val):.}]')"
	fi
	if [[ "$(echo "$match_json" | jq '[.all[], .any[]] | length')" -eq 0 ]]; then
		print_error "At least one match condition is required."
		return 1
	fi

	# Build actions array
	local actions_json="[]"
	if [[ -n "$attach_to_case" ]]; then
		actions_json="$(echo "$actions_json" | jq --arg c "$attach_to_case" --arg r "$role" \
			'. + [{"attach_to_case": $c, "role": $r}]')"
	fi
	if [[ -n "$set_sensitivity" ]]; then
		actions_json="$(echo "$actions_json" | jq --arg s "$set_sensitivity" \
			'. + [{"set_sensitivity": $s}]')"
	fi

	# Build new rule
	local new_rule rule_id
	rule_id="$(printf '%s' "$rule_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')"
	new_rule="$(jq -n --arg id "$rule_id" --arg n "$rule_name" --argjson m "$match_json" --argjson a "$actions_json" \
		'{"id": $id, "name": $n, "collection": false, "match": $m, "actions": $a}')"

	# Load existing config and append
	local existing_config
	existing_config="$(_load_filter_config "$config_file")"
	local updated
	updated="$(echo "$existing_config" | jq --argjson r "$new_rule" '.version = 2 | .rules += [$r]')"
	echo "$updated" >"$config_file"

	print_success "Rule '${rule_name}' added to ${config_file}"
	return 0
}

# =============================================================================
# test: dry-run a rule against last 50 email sources
# =============================================================================

cmd_test() {
	local rule_name="" knowledge_root=""
	if [[ $# -eq 0 ]]; then
		print_error "Usage: email-filter-helper.sh test <rule-name> [knowledge-root]"
		return 1
	fi
	local _rn="${1:-}"
	rule_name="$_rn"
	shift
	if [[ $# -gt 0 ]]; then
		local _kr="${1:-}"
		knowledge_root="$_kr"
		shift
	fi
	knowledge_root="$(_resolve_root "$knowledge_root")" || return 1
	_check_deps || return 1

	local config_file sources_dir
	config_file="$(_resolve_filter_config "$knowledge_root")"
	sources_dir="${knowledge_root}/sources"

	local filter_json
	filter_json="$(_load_filter_config "$config_file")"

	# Find rule by name
	local rule
	rule="$(echo "$filter_json" | jq -c --arg n "$rule_name" \
		'.rules[] | select(.name == $n)' 2>/dev/null | head -1 || true)"
	if [[ -z "$rule" ]]; then
		print_error "Rule '${rule_name}' not found in ${config_file}"
		return 1
	fi

	local match_json actions_json identities collection
	match_json="$(_jq_c "$rule" '.match // {}')"
	actions_json="$(_jq_c "$rule" '.actions // []')"
	identities="$(_rule_account_identities "$rule" "$knowledge_root")"
	collection="$(_rule_collection_mode "$rule")"

	print_info "Testing rule '${rule_name}' against last 50 email sources (dry-run)…"

	local matched=0 tested=0
	# Get last 50 sources by reading tail of sorted list
	local all_sources
	all_sources="$(mktemp)"
	_list_email_sources "$sources_dir" >"$all_sources"
	local tail_sources
	tail_sources="$(tail -50 "$all_sources")"
	rm -f "$all_sources"

	while IFS=$'\t' read -r source_id meta_path _ingested_at; do
		[[ -z "$source_id" || -z "$meta_path" ]] && continue
		tested=$((tested + 1))
		if ! _rule_is_eligible_for_source "$rule" "$meta_path"; then
			continue
		fi
		if _rule_matches_source "$collection" "$match_json" "$meta_path" "$identities"; then
			matched=$((matched + 1))
			print_info "  WOULD MATCH: ${source_id}"
			_execute_rule_actions "$actions_json" "$source_id" "$meta_path" "" "$rule_name" 1
		fi
	done <<<"$tail_sources"

	print_info "Tested ${tested} sources, ${matched} would match (no actions fired)."
	return 0
}

# =============================================================================
# list: show all rules with hit counts
# =============================================================================

cmd_list() {
	local knowledge_root=""
	if [[ $# -gt 0 ]]; then
		local _kr="${1:-}"
		knowledge_root="$_kr"
		shift
	fi
	knowledge_root="$(_resolve_root "$knowledge_root")" || return 1
	_check_deps || return 1

	local config_file
	config_file="$(_resolve_filter_config "$knowledge_root")"
	local filter_json
	filter_json="$(_load_filter_config "$config_file")"

	local rule_count
	rule_count="$(echo "$filter_json" | jq '.rules | length' 2>/dev/null || echo "0")"

	if [[ "$rule_count" -eq 0 ]]; then
		print_info "No filter rules defined in ${config_file}."
		return 0
	fi

	print_info "Rules in ${config_file}:"
	local i=0
	while [[ "$i" -lt "$rule_count" ]]; do
		local rule
		rule="$(_jq_c "$filter_json" ".rules[$i]")"
		local rule_name match_summary actions_summary
		rule_name="$(_jq_r "$rule" '.name // "unnamed"')"
		match_summary="$(_jq_r "$rule" '.match | to_entries | map(.key + "=" + (.value | tostring)) | join(", ")')"
		actions_summary="$(_jq_r "$rule" '[.actions[] | (if .attach_to_case then "attach\u2192" + .attach_to_case else "" end), (if .set_sensitivity then "sensitivity\u2192" + .set_sensitivity else "" end) | select(. != "")] | join(", ")')"
		printf '  [%d] %s\n      match: %s\n      actions: %s\n' \
			"$((i + 1))" "$rule_name" "${match_summary:-<none>}" "${actions_summary:-<none>}"
		i=$((i + 1))
	done

	return 0
}

# =============================================================================
# help
# =============================================================================

cmd_help() {
	cat <<'EOF'
email-filter-helper.sh — Sieve-style email filter rules for auto-attaching to cases

Commands:
  tick   [<knowledge-root>] [--dry-run]    Run filter pass (pulse routine r045)
  add    [<knowledge-root>]                Interactive: add a new rule
  test   <rule-name> [<knowledge-root>]    Dry-run rule against last 50 sources
  list   [<knowledge-root>]                List rules with match summaries
  help                                     Show this help

Environment:
  KNOWLEDGE_ROOT    Override knowledge root path

Filter config:  <repo>/_config/email-filters.json
Filter state:   <knowledge-root>/.email-filter-state.json
Audit log:      <repo>/_cases/<case-id>/comms/email-attach.jsonl

Match predicates (AND semantics — all must match):
  from_contains, from_equals, subject_contains_any, subject_matches_regex,
  body_contains, has_attachment_kind

Actions:
  attach_to_case + role, set_sensitivity

Part of aidevops email channel (t2856 / P5c).
EOF
	return 0
}

# =============================================================================
# main
# =============================================================================

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift

	case "$command" in
	tick) cmd_tick "$@" ;;
	add) cmd_add "$@" ;;
	test) cmd_test "$@" ;;
	list) cmd_list "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		exit 1
		;;
	esac
}

main "$@"
