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
#   graphql | rest | search-graphql | other
_shim_classify_endpoint() {
	local sub1="${1:-}" sub2="${2:-}"
	case "$sub1" in
	search)
		printf 'search-graphql'
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
