#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh shim native transport library
# =============================================================================
# Native gh resolution, endpoint classification, and instrumented transport.
# Usage: source "${_SHIM_DIR}/gh-native-transport-lib.sh"

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_GH_NATIVE_TRANSPORT_LIB_LOADED:-}" ]] && return 0
_GH_NATIVE_TRANSPORT_LIB_LOADED=1

if [[ -z "${_SHIM_DIR:-}" ]]; then
	_gh_native_transport_path="${BASH_SOURCE[0]%/*}"
	[[ "$_gh_native_transport_path" == "${BASH_SOURCE[0]}" ]] && _gh_native_transport_path="."
	_SHIM_DIR="$(cd "$_gh_native_transport_path" && pwd)"
	unset _gh_native_transport_path
fi

_shim_is_aidevops_gh() {
	local candidate_real="$1"
	case "$candidate_real" in
	*/.aidevops/agents/scripts/gh | \
		*/.aidevops/bin/gh | \
		*/.aidevops/runtime-bundles/*/agents/scripts/gh | \
		*/runtime-bundles/*/agents/scripts/gh | \
		*/aidevops/.agents/scripts/gh | \
		*/.agents/scripts/gh | \
		*/.agents/scripts/safe-bin/gh | \
		*/agents/scripts/gh) return 0 ;;
	esac
	return 1
}

_shim_canonical_path() {
	local candidate="$1"
	local candidate_dir=""
	local candidate_name=""
	local link_dir=""
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate" 2>/dev/null
		return $?
	fi
	while [[ -L "$candidate" ]]; do
		link_dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
		candidate=$(readlink "$candidate") || return 1
		[[ "$candidate" == /* ]] || candidate="${link_dir}/${candidate}"
	done
	candidate_dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
	candidate_name=$(basename "$candidate")
	printf '%s/%s\n' "$candidate_dir" "$candidate_name"
	return 0
}

# Resolve a trusted native gh executable. Merely excluding this shim's own
# directory is insufficient: hot deployment can leave several aidevops shim
# generations on PATH, each of which would otherwise select the next one.
_find_real_gh() {
	local path_dir=""
	local candidate=""
	local candidate_real=""
	local IFS=:
	for path_dir in $PATH; do
		[[ -n "$path_dir" ]] || path_dir="."
		candidate="${path_dir}/gh"
		[[ -x "$candidate" ]] || continue
		candidate_real=$(_shim_canonical_path "$candidate" 2>/dev/null || true)
		[[ -n "$candidate_real" ]] || continue
		[[ "$candidate_real" -ef "$_SHIM_SOURCE" ]] && continue
		_shim_is_aidevops_gh "$candidate_real" && continue
		printf '%s\n' "$candidate_real"
		return 0
	done
	for candidate in /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do
		[[ -x "$candidate" ]] || continue
		candidate_real=$(_shim_canonical_path "$candidate" 2>/dev/null || true)
		[[ -n "$candidate_real" ]] || continue
		_shim_is_aidevops_gh "$candidate_real" && continue
		printf '%s\n' "$candidate_real"
		return 0
	done
	return 1
}

# _shim_classify_endpoint <sub1> [<sub2>]
# Classify a gh invocation for instrumentation. Returns one of:
#   graphql | rest | search-rest | other
_shim_classify_endpoint() {
	local sub1="${1:-}" sub2="${2:-}"
	case "$sub1" in
	search)
		printf 'search-rest'
		return 0
		;;
	api)
		if [[ "$sub2" == "graphql" || "$sub2" == graphql/* ]]; then
			printf 'graphql'
		else
			printf 'rest'
		fi
		return 0
		;;
	*)
		printf 'graphql'
		return 0
		;;
	esac
}

_shim_caller_label() {
	local sub1="${1:-}" sub2="${2:-}"
	case "${sub1}:${sub2}" in
	issue:list) printf 'gh_issue_list' ;;
	issue:view) printf 'gh_issue_view' ;;
	pr:list) printf 'gh_pr_list' ;;
	pr:view) printf 'gh_pr_view' ;;
	api:graphql | api:graphql/*) printf 'gh_api_graphql' ;;
	api:*) printf 'gh_api_rest' ;;
	search:issues) printf 'gh_search_issues' ;;
	search:prs) printf 'gh_search_prs' ;;
	search:*) printf 'gh_search' ;;
	*) printf 'gh_%s%s' "${sub1:-unknown}" "${sub2:+_${sub2}}" ;;
	esac
	return 0
}

_shim_framework_caller_label() {
	local candidate="${1:-}"
	candidate="${candidate##*/}"
	[[ -n "${_SHIM_DIR:-}" ]] || return 1
	[[ "$candidate" =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
	[[ -f "${_SHIM_DIR}/${candidate}" ]] || return 1
	printf '%s' "$candidate"
	return 0
}

_shim_parent_framework_caller() {
	local parent_command=""
	local word=""
	local executable_name=""
	local caller=""
	local -a parent_words=()
	parent_command=$(ps -p "$PPID" -o command= 2>/dev/null) || parent_command=""
	[[ -n "$parent_command" ]] || return 1
	read -r -a parent_words <<<"$parent_command"
	[[ ${#parent_words[@]} -gt 0 ]] || return 1
	if caller=$(_shim_framework_caller_label "${parent_words[0]}"); then
		printf '%s' "$caller"
		return 0
	fi
	executable_name="${parent_words[0]##*/}"
	case "$executable_name" in
	env | bash | dash | ksh | sh | zsh) ;;
	*) return 1 ;;
	esac
	for word in "${parent_words[@]:1}"; do
		case "$word" in
		-* | *=*) continue ;;
		esac
		case "${word##*/}" in
		env | bash | dash | ksh | sh | zsh) continue ;;
		esac
		if caller=$(_shim_framework_caller_label "$word"); then
			printf '%s' "$caller"
			return 0
		fi
	done
	return 1
}

_shim_transport_caller_label() {
	local sub1="${1:-}"
	local sub2="${2:-}"
	local caller=""
	if caller=$(_shim_framework_caller_label "${AIDEVOPS_GH_CALLER:-}"); then
		printf '%s' "$caller"
		return 0
	fi
	if caller=$(_shim_parent_framework_caller); then
		printf '%s' "$caller"
		return 0
	fi
	_shim_caller_label "$sub1" "$sub2"
	return 0
}

# Return a reviewed, bounded gh JSON field list or fail closed. Future gh fields
# remain classified as dynamic until added here so arbitrary pre-validation
# argument values can never influence telemetry digests.
_shim_read_json_fields() {
	local sub1="$1"
	local sub2="$2"
	local fields="$3"
	local field=""
	local -a field_list=()
	[[ -n "$fields" && ${#fields} -le 1024 ]] || return 1
	[[ "$fields" != ,* && "$fields" != *, && "$fields" != *,,* ]] || return 1
	IFS=',' read -r -a field_list <<<"$fields"
	[[ ${#field_list[@]} -gt 0 ]] || return 1
	for field in "${field_list[@]}"; do
		case "${sub1}:${sub2}:${field}" in
		issue:list:assignees | issue:list:author | issue:list:blockedBy | issue:list:blocking | \
			issue:list:body | issue:list:closed | issue:list:closedAt | issue:list:closedByPullRequestsReferences | \
			issue:list:comments | issue:list:createdAt | issue:list:id | issue:list:isPinned | issue:list:issueType | \
			issue:list:labels | issue:list:milestone | issue:list:number | issue:list:parent | issue:list:projectCards | \
			issue:list:projectItems | issue:list:reactionGroups | issue:list:state | issue:list:stateReason | \
			issue:list:subIssues | issue:list:subIssuesSummary | issue:list:title | issue:list:updatedAt | issue:list:url | \
			issue:view:assignees | issue:view:author | issue:view:blockedBy | issue:view:blocking | \
			issue:view:body | issue:view:closed | issue:view:closedAt | issue:view:closedByPullRequestsReferences | \
			issue:view:comments | issue:view:createdAt | issue:view:id | issue:view:isPinned | issue:view:issueType | \
			issue:view:labels | issue:view:milestone | issue:view:number | issue:view:parent | issue:view:projectCards | \
			issue:view:projectItems | issue:view:reactionGroups | issue:view:state | issue:view:stateReason | \
			issue:view:subIssues | issue:view:subIssuesSummary | issue:view:title | issue:view:updatedAt | issue:view:url | \
			pr:list:additions | pr:list:assignees | pr:list:author | pr:list:autoMergeRequest | pr:list:baseRefName | \
			pr:list:baseRefOid | pr:list:body | pr:list:changedFiles | pr:list:closed | pr:list:closedAt | \
			pr:list:closingIssuesReferences | pr:list:comments | pr:list:commits | pr:list:createdAt | pr:list:deletions | \
			pr:list:files | pr:list:fullDatabaseId | pr:list:headRefName | pr:list:headRefOid | pr:list:headRepository | \
			pr:list:headRepositoryOwner | pr:list:id | pr:list:isCrossRepository | pr:list:isDraft | pr:list:labels | \
			pr:list:latestReviews | pr:list:maintainerCanModify | pr:list:mergeCommit | pr:list:mergeStateStatus | \
			pr:list:mergeable | pr:list:mergedAt | pr:list:mergedBy | pr:list:milestone | pr:list:number | \
			pr:list:potentialMergeCommit | pr:list:projectCards | pr:list:projectItems | pr:list:reactionGroups | \
			pr:list:reviewDecision | pr:list:reviewRequests | pr:list:reviews | pr:list:state | \
			pr:list:statusCheckRollup | pr:list:title | pr:list:updatedAt | pr:list:url | \
			pr:view:additions | pr:view:assignees | pr:view:author | pr:view:autoMergeRequest | pr:view:baseRefName | \
			pr:view:baseRefOid | pr:view:body | pr:view:changedFiles | pr:view:closed | pr:view:closedAt | \
			pr:view:closingIssuesReferences | pr:view:comments | pr:view:commits | pr:view:createdAt | pr:view:deletions | \
			pr:view:files | pr:view:fullDatabaseId | pr:view:headRefName | pr:view:headRefOid | pr:view:headRepository | \
			pr:view:headRepositoryOwner | pr:view:id | pr:view:isCrossRepository | pr:view:isDraft | pr:view:labels | \
			pr:view:latestReviews | pr:view:maintainerCanModify | pr:view:mergeCommit | pr:view:mergeStateStatus | \
			pr:view:mergeable | pr:view:mergedAt | pr:view:mergedBy | pr:view:milestone | pr:view:number | \
			pr:view:potentialMergeCommit | pr:view:projectCards | pr:view:projectItems | pr:view:reactionGroups | \
			pr:view:reviewDecision | pr:view:reviewRequests | pr:view:reviews | pr:view:state | \
			pr:view:statusCheckRollup | pr:view:title | pr:view:updatedAt | pr:view:url) ;;
		*) return 1 ;;
		esac
	done
	printf '%s' "$fields"
	return 0
}

# Return a stable, privacy-safe digest for one native issue/pr read shape.
# Repository names, references, jq/template expressions, and other argument
# values never enter the digest input. JSON field names are retained because
# they define the transport contract and are bounded gh identifiers.
_shim_read_shape_digest() {
	local sub1="${1:-}"
	local sub2="${2:-}"
	shift 2 2>/dev/null || true
	local json_fields="none"
	local has_jq=0
	local has_template=0
	local has_comments=0
	local has_web=0
	local unknown_flags=0
	local positional_count=0
	local expect_value=""
	local arg=""
	local shape=""
	local digest=""

	while [[ $# -gt 0 ]]; do
		arg="$1"
		shift
		if [[ -n "$expect_value" ]]; then
			case "$expect_value" in
			json)
				json_fields=$(_shim_read_json_fields "$sub1" "$sub2" "$arg" 2>/dev/null) || json_fields="dynamic"
				;;
			jq) has_jq=1 ;;
			template) has_template=1 ;;
			esac
			expect_value=""
			continue
		fi
		case "$arg" in
		--repo | -R) expect_value="private" ;;
		--repo=* | -R?*) ;;
		--json) expect_value="json" ;;
		--json=*)
			json_fields=$(_shim_read_json_fields "$sub1" "$sub2" "${arg#--json=}" 2>/dev/null) || json_fields="dynamic"
			;;
		--jq | -q) expect_value="jq" ;;
		--jq=* | -q=*) has_jq=1 ;;
		--template | -t) expect_value="template" ;;
		--template=* | -t=*) has_template=1 ;;
		--comments | -c) has_comments=1 ;;
		--web | -w) has_web=1 ;;
		-*) unknown_flags=$((unknown_flags + 1)) ;;
		*) positional_count=$((positional_count + 1)) ;;
		esac
	done
	shape="${sub1}:${sub2}:json=${json_fields}:jq=${has_jq}:template=${has_template}:comments=${has_comments}:web=${has_web}:unknown_flags=${unknown_flags}:positionals=${positional_count}"
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$shape" | shasum -a 256 2>/dev/null) || return 1
		digest="${digest%% *}"
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$shape" | sha256sum 2>/dev/null) || return 1
		digest="${digest%% *}"
	elif command -v openssl >/dev/null 2>&1; then
		digest=$(printf '%s' "$shape" | openssl dgst -sha256 2>/dev/null) || return 1
		digest="${digest##* }"
	else
		return 1
	fi
	[[ "$digest" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
	printf 'shape-%s' "${digest:0:12}"
	return 0
}

_shim_transport_page() {
	local arg=""
	local page=1
	if [[ "${AIDEVOPS_GH_PAGE_NUMBER:-}" =~ ^[0-9]+$ && "${AIDEVOPS_GH_PAGE_NUMBER}" -gt 0 ]]; then
		printf '%s' "$AIDEVOPS_GH_PAGE_NUMBER"
		return 0
	fi
	for arg in "$@"; do
		if [[ "$arg" == "--paginate" ]]; then
			printf '0'
			return 0
		fi
		if [[ "$arg" =~ (^|[?\&])page=([0-9]+)($|\&) ]]; then
			page="${BASH_REMATCH[2]}"
		fi
	done
	printf '%s' "$page"
	return 0
}

_shim_graphql_query_requests_rate_limit_cost() {
	local -a arguments=("$@")
	local command_name="${arguments[0]:-}"
	local subcommand="${arguments[1]:-}"
	local arg=""
	local query=""
	local cost_pattern='rateLimit[[:space:]]*(\([^)]*\)[[:space:]]*)?\{[^}]*cost([[:space:]}(]|$)'
	[[ "$command_name" == "api" && "$subcommand" == "graphql" ]] || return 1
	for arg in "${arguments[@]:2}"; do
		case "$arg" in
		--include | --paginate | --silent | --slurp | -i | -q | --jq | -t | --template) return 1 ;;
		--jq=* | --template=* | -q?* | -t?*) return 1 ;;
		query=*) query="${arg#query=}" ;;
		-fquery=* | -Fquery=* | --field=query=* | --raw-field=query=*) query="${arg#*=}" ;;
		esac
	done
	[[ -n "$query" && "$query" =~ $cost_pattern ]] || return 1
	return 0
}

_shim_run_response_metered_graphql() {
	local response_rc=0
	(
		local executable="$1"; shift
		local path="$1"; shift
		local caller="$1"; shift
		local retry="$1"; shift
		local temp_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
		local output_file="" start_ms="" end_ms="" elapsed_ms="" quota_cost=""
		local quota_state_file="" quota_lock_dir=""
		local rc=0 replay_rc=0 outcome="success"

		[[ "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-0}" == "1" && "$path" == "graphql" ]] || return 125
		_shim_graphql_query_requests_rate_limit_cost "$@" || return 125
		declare -F gh_record_attempt >/dev/null 2>&1 || return 125
		declare -F _ghqa_prepare_private_dir >/dev/null 2>&1 || return 125
		declare -F _ghqa_response_meter_lock_acquire >/dev/null 2>&1 || return 125
		declare -F _ghqa_response_meter_lock_invalidate_release >/dev/null 2>&1 || return 125
		command -v jq >/dev/null 2>&1 || return 125
		_ghqa_response_meter_lock_acquire "$executable" "$@" || return 125
		quota_state_file="$_GHQA_RESPONSE_METER_STATE_FILE"
		quota_lock_dir="$_GHQA_RESPONSE_METER_LOCK_DIR"
		trap '_ghqa_response_meter_lock_invalidate_release "$quota_state_file" "$quota_lock_dir"; [[ -z "$output_file" ]] || rm -f -- "$output_file" 2>/dev/null || true' EXIT
		_ghqa_prepare_private_dir "$temp_dir" || return 125
		output_file=$(mktemp "${temp_dir}/gh-graphql-cost-response.XXXXXX" 2>/dev/null) || return 125
		trap 'exit 129' HUP
		trap 'exit 130' INT
		trap 'exit 143' TERM
		chmod 0600 "$output_file" 2>/dev/null || return 125

		start_ms=$(_gh_now_ms 2>/dev/null || true)
		if "$executable" "$@" >"$output_file"; then
			rc=0
		else
			rc=$?
			outcome="error"
		fi
		end_ms=$(_gh_now_ms 2>/dev/null || true)
		elapsed_ms=$(_ghqa_elapsed_ms "$start_ms" "$end_ms" 2>/dev/null || true)
		quota_cost=$(jq -r 'try (.data.rateLimit.cost // empty) catch empty' "$output_file" 2>/dev/null) || quota_cost=""
		[[ "$quota_cost" =~ ^[0-9]+$ ]] || quota_cost=""

		command cat "$output_file" || replay_rc=$?
		gh_record_attempt graphql "$caller" "$AIDEVOPS_GH_LOGICAL_ID" "" 1 "$retry" "$outcome" \
			"" "$elapsed_ms" "$quota_cost" "${AIDEVOPS_GH_AUTH_MODE:-}" graphql \
			"${AIDEVOPS_GH_ROUTE_DECISION:-graphql-response-metered}" "" 2>/dev/null || true
		[[ "$rc" -ne 0 ]] && return "$rc"
		[[ "$replay_rc" -ne 0 ]] && return "$replay_rc"
		return 0
	) || response_rc=$?
	return "$response_rc"
}

_shim_run_single_transport() {
	local executable="$1"; shift
	local path="$1"; shift
	local caller="$1"; shift
	local retry="$1"; shift
	if declare -F _ghqa_command_is_local_only >/dev/null 2>&1 && _ghqa_command_is_local_only "$executable" "$@"; then
		"$executable" "$@"
		return $?
	fi
	if declare -F _gh_transport_preflight >/dev/null 2>&1; then
		_gh_transport_preflight "$@" || return $?
	fi
	if declare -F _gh_transport_run_rest >/dev/null 2>&1; then
		local governed_rc=0
		_gh_transport_run_rest "$executable" "$path" "$caller" "$retry" "$@" || governed_rc=$?
		[[ "${_GHGT_HANDLED:-0}" -eq 0 && "$governed_rc" -eq 125 ]] || return "$governed_rc"
	fi
	local page=1
	local decision="${AIDEVOPS_GH_ROUTE_DECISION:-}"
	local exact_success_cost=""
	page=$(_shim_transport_page "$@")
	if [[ "$page" == "0" ]]; then
		decision="native-pagination-opaque"
	fi
	local response_metered_rc=0
	_shim_run_response_metered_graphql "$executable" "$path" "$caller" "$retry" "$@" || response_metered_rc=$?
	if [[ "$response_metered_rc" -ne 125 ]]; then
		return "$response_metered_rc"
	fi
	exact_success_cost=$(_ghqa_exact_success_cost "$path" "$@" 2>/dev/null || true)
	AIDEVOPS_GH_ROUTE_DECISION="$decision" \
		AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS="$exact_success_cost" gh_run_transport_attempt \
		"$path" "$caller" "$AIDEVOPS_GH_LOGICAL_ID" "$page" "$retry" -- "$executable" "$@"
	return $?
}

_shim_run_transport() {
	local executable="$1"; shift
	local path="$1"; shift
	local caller="$1"; shift
	local retry="$1"; shift
	local rc=0
	local -a transport_args=("$@")
	if [[ "$_GHRP_LOADED" -eq 1 ]] && _ghrp_prepare "$path" "${transport_args[@]}"; then
		_ghrp_run "$executable" "$path" "$caller" "$retry" "${transport_args[@]}"
		rc=$?
		if [[ "$rc" -eq 125 && "${_GHRP_FALLBACK_SAFE:-0}" -eq 1 ]]; then
			_shim_run_single_transport "$executable" "$path" "$caller" "$retry" "${transport_args[@]}"
			return $?
		fi
		return "$rc"
	fi
	if [[ "${_GHRP_PREFLIGHT_ONLY:-0}" -eq 1 ]]; then
		"$executable" "${transport_args[@]}"
		return $?
	fi
	_shim_run_single_transport "$executable" "$path" "$caller" "$retry" "${transport_args[@]}"
	return $?
}
