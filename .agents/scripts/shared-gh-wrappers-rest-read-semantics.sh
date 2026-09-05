#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Exact argument validation and Search API translation for gh REST reads.

[[ -n "${_SHARED_GH_WRAPPERS_REST_READ_SEMANTICS_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_REST_READ_SEMANTICS_LOADED=1

_REST_READ_STATE_OPEN="open"
_REST_READ_MODE_SEARCH="search"

_rest_args_have_author() {
	local arg=""
	for arg in "$@"; do
		case "$arg" in
		--author|--author=*|-A) return 0 ;;
		esac
	done
	return 1
}

_rest_pr_list_requires_search() {
	local arg=""
	for arg in "$@"; do
		case "$arg" in
		--author|--author=*|-A|--assignee|--assignee=*|-a|--label|--label=*|-l|--search|--search=*|-S|--draft|-d) return 0 ;;
		esac
	done
	return 1
}

_rest_pr_list_prefers_native_filter() {
	local state="open" arg=""
	_rest_pr_list_requires_search "$@" && return 1
	while [[ $# -gt 0 ]]; do
		arg="$1"
		shift
		case "$arg" in
		--state|-s) [[ $# -gt 0 ]] || return 1; state="$1"; shift ;;
		--state=*) state="${arg#--state=}" ;;
		--repo|-R|--json|--jq|-q|--head|-H|--base|-B|--limit|-L)
			[[ $# -gt 0 ]] || return 1
			shift
			;;
		esac
	done
	# REST /pulls?state=closed includes merged PRs. Filtering them locally can
	# walk the entire merged history just to establish there are no unmerged PRs.
	# Native GraphQL applies CLOSED server-side. Keep REST as a quota fallback,
	# not the preferred healthy-budget route for this low-selectivity query.
	[[ "$state" == closed ]] || return 1
	return 0
}

_rest_resolve_actor_filter() {
	local actor="$1"
	if [[ "$actor" == "@me" ]]; then
		if command -v _gh_with_timeout >/dev/null 2>&1; then
			actor=$(_gh_with_timeout read gh api user --jq '.login // ""' 2>/dev/null) || actor=""
		else
			actor=$(gh api user --jq '.login // ""' 2>/dev/null) || actor=""
		fi
	fi
	# GitHub.com user logins use alphanumerics and hyphens; Enterprise Managed
	# Users may include an underscore suffix, and app identities use [bot].
	if [[ ! "$actor" =~ ^[A-Za-z0-9_-]+(\[bot\])?$ ]]; then
		printf '_rest_resolve_actor_filter: unable to resolve a concrete login\n' >&2
		return 1
	fi
	printf '%s' "$actor"
	return 0
}

_rest_repo_slug_supported() {
	local repo="$1"
	[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
	return $?
}

_rest_jq_actor_projection() {
	printf '(if . == null then null else {id: .node_id, is_bot: (.type == "Bot"), login: .login, name: (.name // null)} end)'
	return 0
}

_rest_jq_assignees_projection() {
	printf '[.[] | {databaseId: .id, id: .node_id, login: .login, name: (.name // null)}]'
	return 0
}

_rest_jq_labels_projection() {
	printf '[.[] | {id: .node_id, name: .name, description: .description, color: .color}]'
	return 0
}

_rest_limit_array_json() {
	local limit="$1"
	jq -c ".[:${limit}]"
	return $?
}

_rest_search_quoted_qualifier() {
	local name="$1"
	local value="$2"
	[[ "$name" =~ ^[a-z]+$ && -n "$value" ]] || return 1
	case "$value" in
	*\"* | *\\* | *$'\n'* | *$'\r'*) return 1 ;;
	esac
	printf '%s:"%s"' "$name" "$value"
	return 0
}

_rest_issue_list_fields_supported() {
	local fields="$1"
	local field=""
	while IFS= read -r field; do
		case "$field" in
		number|state|url|title|body|createdAt|updatedAt|closedAt|labels|assignees|author|stateReason|closed) ;;
		*) return 1 ;;
		esac
	done < <(_rest_split_csv "$fields")
	return 0
}

_rest_issue_list_can_preserve_args() {
	local has_json=0
	local has_search=0
	local repo=""
	local fields=""
	local limit=30
	local state="$_REST_READ_STATE_OPEN"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo|-R)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			repo="$2"
			shift 2
			;;
		--label|-l|--assignee|-a|--author|-A|--jq|-q)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			shift 2
			;;
		--state|-s)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			state="$2"
			shift 2
			;;
		--limit|-L)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			limit="$2"
			shift 2
			;;
		--search|-S)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			has_search=1
			shift 2
			;;
		--json)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			has_json=1
			fields="$2"
			shift 2
			;;
		--repo=*)
			repo="${arg#--repo=}"
			[[ -n "$repo" ]] || return 1
			shift
			;;
		--label=*|--assignee=*|--author=*|--jq=*|-q=*)
			[[ -n "${arg#*=}" ]] || return 1
			shift
			;;
		--state=*) state="${arg#--state=}"; shift ;;
		--limit=*) limit="${arg#--limit=}"; shift ;;
		--search=*)
			[[ -n "${arg#--search=}" ]] || return 1
			has_search=1
			shift
			;;
		--json=*)
			fields="${arg#--json=}"
			[[ -n "$fields" ]] || return 1
			has_json=1
			shift
			;;
		*) return 1 ;;
		esac
	done
	_rest_repo_slug_supported "$repo" || return 1
	[[ "$has_json" -eq 1 ]] || return 1
	[[ "$state" == "$_REST_READ_STATE_OPEN" || "$state" == "closed" || "$state" == "all" ]] || return 1
	[[ "$limit" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ "$has_search" -eq 0 || "$limit" -le 1000 ]] || return 1
	_rest_issue_list_fields_supported "$fields" || return 1
	return 0
}

_rest_issue_view_fields_supported() {
	local fields="$1"
	local field=""
	while IFS= read -r field; do
		case "$field" in
		id|number|state|url|title|body|createdAt|updatedAt|closedAt|labels|assignees|author|stateReason|closed|locked) ;;
		*) return 1 ;;
		esac
	done < <(_rest_split_csv "$fields")
	return 0
}

_rest_view_reference_supported() {
	local reference="$1"
	[[ "$reference" =~ ^[0-9]+$ || "$reference" =~ ^https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[0-9]+ ]]
	return $?
}

_rest_view_args_supported() {
	local operation="$1"
	local field_mode="$2"
	shift 2
	local reference="${1:-}"
	_rest_view_reference_supported "$reference" || return 1
	shift
	local has_json=0
	local fields=""
	local repo=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo|-R)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			repo="$2"
			shift 2
			;;
		--jq|-q)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			shift 2
			;;
		--json)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			has_json=1
			fields="$2"
			shift 2
			;;
		--repo=*)
			repo="${arg#--repo=}"
			[[ -n "$repo" ]] || return 1
			shift
			;;
		--jq=*|-q=*)
			[[ -n "${arg#*=}" ]] || return 1
			shift
			;;
		--json=*)
			fields="${arg#--json=}"
			[[ -n "$fields" ]] || return 1
			has_json=1
			shift
			;;
		*) return 1 ;;
		esac
	done
	[[ "$has_json" -eq 1 ]] || return 1
	if [[ "$reference" =~ ^[0-9]+$ ]]; then
		_rest_repo_slug_supported "$repo" || return 1
	elif [[ -n "$repo" ]]; then
		_rest_repo_slug_supported "$repo" || return 1
	fi
	case "${operation}:${field_mode}" in
	issue:*) _rest_issue_view_fields_supported "$fields" ;;
	pr:structural) return 0 ;;
	pr:*) _rest_pr_view_fields_supported "$field_mode" "$fields" ;;
	*) return 1 ;;
	esac
	return $?
}

_rest_issue_view_can_preserve_args() {
	_rest_view_args_supported issue exact "$@"
	return $?
}

_rest_pr_list_fields_supported() {
	local mode="$1"
	local fields="$2"
	local field=""
	while IFS= read -r field; do
		case "$mode:$field" in
		direct:number|direct:state|direct:isDraft|direct:labels|direct:mergedAt|direct:url|direct:title|direct:body|direct:createdAt|direct:updatedAt|direct:closedAt|direct:baseRefName|direct:headRefName|direct:headRefOid|direct:author|direct:assignees) ;;
		search:number|search:state|search:isDraft|search:labels|search:mergedAt|search:url|search:title|search:body|search:createdAt|search:updatedAt|search:closedAt|search:author|search:assignees) ;;
		*) return 1 ;;
		esac
	done < <(_rest_split_csv "$fields")
	return 0
}

_rest_pr_view_fields_supported() {
	local mode="$1"
	local fields="$2"
	local field=""
	while IFS= read -r field; do
		case "$field" in
		number|state|merged|mergedAt|closedAt|mergeCommit|mergedBy|mergeable|isDraft|labels|author|title|body|url|createdAt|updatedAt|baseRefName|headRefName|headRefOid) ;;
		*) return 1 ;;
		esac
	done < <(_rest_split_csv "$fields")
	return 0
}

_rest_pr_view_args_supported() {
	local mode="${1:-exact}"
	shift
	_rest_view_args_supported pr "$mode" "$@"
	return $?
}

_rest_pr_view_can_preserve_args() {
	_rest_pr_view_args_supported exact "$@"
	return $?
}

_rest_pr_view_can_emergency_fallback_args() {
	_rest_pr_view_args_supported emergency "$@"
	return $?
}

_rest_pr_list_can_preserve_args() {
	local mode="direct"
	local has_json=0
	local repo=""
	local fields=""
	local limit=30
	local state="$_REST_READ_STATE_OPEN"
	_rest_pr_list_requires_search "$@" && mode="$_REST_READ_MODE_SEARCH"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo|-R)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			repo="$2"
			shift 2
			;;
		--base|-B|--head|-H|--jq|-q)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			shift 2
			;;
		--state|-s)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			state="$2"
			shift 2
			;;
		--limit|-L)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			limit="$2"
			shift 2
			;;
		--json)
			[[ $# -ge 2 && -n "${2:-}" ]] || return 1
			has_json=1
			fields="$2"
			shift 2
			;;
		--author|-A|--assignee|-a|--label|-l|--search|-S)
			[[ "$mode" == "$_REST_READ_MODE_SEARCH" && $# -ge 2 && -n "${2:-}" ]] || return 1
			shift 2
			;;
		--draft|-d)
			[[ "$mode" == "$_REST_READ_MODE_SEARCH" ]] || return 1
			shift
			;;
		--repo=*)
			repo="${arg#--repo=}"
			[[ -n "$repo" ]] || return 1
			shift
			;;
		--base=*|--head=*|--jq=*|-q=*)
			[[ -n "${arg#*=}" ]] || return 1
			shift
			;;
		--state=*) state="${arg#--state=}"; shift ;;
		--limit=*) limit="${arg#--limit=}"; shift ;;
		--json=*)
			fields="${arg#--json=}"
			[[ -n "$fields" ]] || return 1
			has_json=1
			shift
			;;
		--author=*|--assignee=*|--label=*|--search=*)
			[[ "$mode" == "$_REST_READ_MODE_SEARCH" && -n "${arg#*=}" ]] || return 1
			shift
			;;
		*) return 1 ;;
		esac
	done
	_rest_repo_slug_supported "$repo" || return 1
	[[ "$has_json" -eq 1 ]] || return 1
	[[ "$state" == "$_REST_READ_STATE_OPEN" || "$state" == "closed" || "$state" == "merged" || "$state" == "all" ]] || return 1
	[[ "$limit" =~ ^[1-9][0-9]*$ ]] || return 1
	if [[ "$mode" == "$_REST_READ_MODE_SEARCH" ]]; then
		[[ "$limit" -le 1000 ]] || return 1
	fi
	_rest_pr_list_fields_supported "$mode" "$fields" || return 1
	return 0
}

_rest_search_response_body() {
	local raw_response="$1"
	local body=""
	body="$(awk 'BEGIN { body = 0 } { line = $0; sub(/\r$/, "", line); if (body) { print; next } if (line == "") { body = 1 } }' <<<"$raw_response")"
	[[ -z "$body" && "$raw_response" != HTTP/* ]] && body="$raw_response"
	[[ -n "$body" ]] || body='{"items":[]}'
	printf '%s' "$body"
	return 0
}

_rest_pr_list_collect_pages() {
	local repo="$1"
	local query="$2"
	local state="$3"
	local limit="$4"
	local page_size="$5"
	local page=1
	local raw_page=""
	local raw_count=0
	local match_count=0
	local page_matches='[]'
	local combined='[]'
	while [[ "$match_count" -lt "$limit" ]]; do
		raw_page=$(_rest_api_call read gh api "/repos/${repo}/pulls?${query}&page=${page}") || return 1
		raw_count=$(printf '%s' "$raw_page" | jq 'length' 2>/dev/null) || return 1
		case "$state" in
		merged) page_matches=$(printf '%s' "$raw_page" | jq -c '[.[] | select(.merged_at != null)]') || return 1 ;;
		closed) page_matches=$(printf '%s' "$raw_page" | jq -c '[.[] | select(.merged_at == null)]') || return 1 ;;
		*) page_matches="$raw_page" ;;
		esac
		combined=$(printf '%s\n%s\n' "$combined" "$page_matches" | jq -sc '.[0] + .[1]') || return 1
		match_count=$(printf '%s' "$combined" | jq 'length' 2>/dev/null) || return 1
		[[ "$raw_count" -ge "$page_size" ]] || break
		page=$((page + 1))
	done
	printf '%s' "$combined" | _rest_limit_array_json "$limit"
	return $?
}

_rest_issue_list_collect_pages() {
	local repo="$1"
	local query="$2"
	local limit="$3"
	local page_size="$4"
	local page=1
	local raw_page=""
	local raw_count=0
	local issue_count=0
	local combined='[]'
	while [[ "$issue_count" -lt "$limit" ]]; do
		raw_page=$(_rest_api_call read gh api "/repos/${repo}/issues?${query}&page=${page}") || return 1
		raw_count=$(printf '%s' "$raw_page" | jq 'length' 2>/dev/null) || return 1
		combined=$(printf '%s\n%s\n' "$combined" "$raw_page" | jq -sc \
			'.[0] + [.[1][] | select(.pull_request == null)]') || return 1
		issue_count=$(printf '%s' "$combined" | jq 'length' 2>/dev/null) || return 1
		[[ "$raw_count" -ge "$page_size" ]] || break
		page=$((page + 1))
	done
	printf '%s' "$combined" | _rest_limit_array_json "$limit"
	return $?
}

_rest_search_collect_items() {
	local base_path="$1"
	local limit="$2"
	[[ "$limit" =~ ^[1-9][0-9]*$ && "$limit" -le 1000 ]] || return 1
	local page_size="$limit"
	[[ "$page_size" -le 100 ]] || page_size=100
	local page=1
	local count=0
	local page_count=0
	local combined='[]'
	while [[ "$count" -lt "$limit" ]]; do
		local raw_response=""
		local body=""
		raw_response=$(_rest_api_call read gh api -i "${base_path}&per_page=${page_size}&page=${page}") || return 1
		body="$(_rest_search_response_body "$raw_response")" || return 1
		page_count=$(printf '%s' "$body" | jq '.items | length' 2>/dev/null) || return 1
		combined=$(printf '%s\n%s\n' "$combined" "$body" | jq -sc '.[0] + (.[1].items // [])') || return 1
		count=$(printf '%s' "$combined" | jq 'length' 2>/dev/null) || return 1
		[[ "$page_count" -ge "$page_size" ]] || break
		page=$((page + 1))
	done
	printf '%s' "$combined" | _rest_limit_array_json "$limit"
	return $?
}

_rest_issue_search() {
	gh_record_call search-rest _rest_issue_search 2>/dev/null || true
	local repo="" state="$_REST_READ_STATE_OPEN" author="" assignee="" search="" limit=30
	local json_fields="" jq_expr=""
	local -a labels
	local token=""
	labels=()
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo | -R) [[ $# -ge 2 ]] || return 2; repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${arg#--repo=}"; shift ;;
		--state | -s) [[ $# -ge 2 ]] || return 2; state="${2:-}"; shift 2 ;;
		--state=*) state="${arg#--state=}"; shift ;;
		--author | -A) [[ $# -ge 2 ]] || return 2; author="${2:-}"; shift 2 ;;
		--author=*) author="${arg#--author=}"; shift ;;
		--assignee | -a) [[ $# -ge 2 ]] || return 2; assignee="${2:-}"; shift 2 ;;
		--assignee=*) assignee="${arg#--assignee=}"; shift ;;
		--label | -l)
			[[ $# -ge 2 ]] || return 2
			while IFS= read -r token; do
				[[ -n "$token" ]] && labels+=("$token")
			done < <(_rest_split_csv "${2:-}")
			shift 2
			;;
		--label=*)
			while IFS= read -r token; do
				[[ -n "$token" ]] && labels+=("$token")
			done < <(_rest_split_csv "${arg#--label=}")
			shift
			;;
		--search | -S) [[ $# -ge 2 ]] || return 2; search="${2:-}"; shift 2 ;;
		--search=*) search="${arg#--search=}"; shift ;;
		--limit | -L) [[ $# -ge 2 ]] || return 2; limit="${2:-}"; shift 2 ;;
		--limit=*) limit="${arg#--limit=}"; shift ;;
		--json) [[ $# -ge 2 ]] || return 2; json_fields="${2:-}"; shift 2 ;;
		--json=*) json_fields="${arg#--json=}"; shift ;;
		--jq | -q) [[ $# -ge 2 ]] || return 2; jq_expr="${2:-}"; shift 2 ;;
		--jq=* | -q=*) jq_expr="${arg#*=}"; shift ;;
		*) printf '_rest_issue_search: unsupported argument: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	[[ -n "$repo" && -n "$search" && "$limit" =~ ^[1-9][0-9]*$ && "$limit" -le 1000 ]] &&
		_rest_repo_slug_supported "$repo" || {
		printf '_rest_issue_search: --repo, --search, and a limit <= 1000 are required\n' >&2
		return 1
	}
	if [[ -n "$json_fields" ]] && ! _rest_issue_list_fields_supported "$json_fields"; then
		printf '_rest_issue_search: unsupported JSON field set: %s\n' "$json_fields" >&2
		return 2
	fi
	[[ -z "$author" ]] || author="$(_rest_resolve_actor_filter "$author")" || return 1
	[[ -z "$assignee" ]] || assignee="$(_rest_resolve_actor_filter "$assignee")" || return 1
	local query="${search} repo:${repo} is:issue"
	case "$state" in
	open | closed) query="${query} is:${state}" ;;
	all) ;;
	*) printf '_rest_issue_search: unsupported state: %s\n' "$state" >&2; return 2 ;;
	esac
	[[ -z "$author" ]] || query="${query} author:${author}"
	[[ -z "$assignee" ]] || query="${query} assignee:${assignee}"
	local label=""
	local qualifier=""
	for label in "${labels[@]}"; do
		qualifier="$(_rest_search_quoted_qualifier label "$label")" || return 2
		query="${query} ${qualifier}"
	done
	local encoded=""
	encoded=$(jq -rn --arg value "$query" '$value | @uri') || return 1
	local items=""
	items="$(_rest_search_collect_items "/search/issues?q=${encoded}" "$limit")" || return 1
	local projection='[.[] | select(.pull_request == null)]'
	if [[ -n "$json_fields" ]]; then
		projection="$(_rest_issue_list_json_jq "$json_fields" "")" || return 1
	fi
	local result=""
	result=$(printf '%s' "$items" | jq -c "$projection") || return 1
	if [[ -n "$jq_expr" ]]; then
		printf '%s' "$result" | jq -r "$jq_expr"
		return $?
	fi
	printf '%s\n' "$result"
	return 0
}

_rest_pr_search_json_jq() {
	local fields="$1"
	local user_jq="$2"
	local projection=""
	local field=""
	local actor_projection=""
	local assignees_projection=""
	local labels_projection=""
	actor_projection="$(_rest_jq_actor_projection)"
	assignees_projection="$(_rest_jq_assignees_projection)"
	labels_projection="$(_rest_jq_labels_projection)"
	while IFS= read -r field; do
		case "$field" in
		number) projection="${projection}${projection:+,}number: .number" ;;
		state) projection="${projection}${projection:+,}state: (if .pull_request.merged_at != null then \"MERGED\" else (.state | ascii_upcase) end)" ;;
		isDraft) projection="${projection}${projection:+,}isDraft: (.draft // false)" ;;
		labels) projection="${projection}${projection:+,}labels: ((.labels // []) | ${labels_projection})" ;;
		mergedAt) projection="${projection}${projection:+,}mergedAt: .pull_request.merged_at" ;;
		url) projection="${projection}${projection:+,}url: .html_url" ;;
		title) projection="${projection}${projection:+,}title: .title" ;;
		body) projection="${projection}${projection:+,}body: (.body // \"\")" ;;
		createdAt) projection="${projection}${projection:+,}createdAt: .created_at" ;;
		updatedAt) projection="${projection}${projection:+,}updatedAt: .updated_at" ;;
		closedAt) projection="${projection}${projection:+,}closedAt: .closed_at" ;;
		author) projection="${projection}${projection:+,}author: (.user | ${actor_projection})" ;;
		assignees) projection="${projection}${projection:+,}assignees: ((.assignees // []) | ${assignees_projection})" ;;
		*) return 1 ;;
		esac
	done < <(_rest_split_csv "$fields")
	local filter="[.[] | {${projection}}]"
	[[ -n "$user_jq" ]] && filter="${filter} | ${user_jq}"
	printf '%s' "$filter"
	return 0
}

_rest_pr_search() {
	gh_record_call search-rest _rest_pr_search 2>/dev/null || true
	local repo="" state="$_REST_READ_STATE_OPEN" author="" assignee="" search="" limit=30
	local base_branch="" head_branch="" json_fields="" jq_expr="" draft=0
	local -a labels
	local tok=""
	labels=()
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo | -R) [[ $# -ge 2 ]] || return 2; repo="${2:-}"; shift 2 ;; --repo=*) repo="${arg#--repo=}"; shift ;;
		--state | -s) [[ $# -ge 2 ]] || return 2; state="${2:-}"; shift 2 ;; --state=*) state="${arg#--state=}"; shift ;;
		--author | -A) [[ $# -ge 2 ]] || return 2; author="${2:-}"; shift 2 ;; --author=*) author="${arg#--author=}"; shift ;;
		--assignee | -a) [[ $# -ge 2 ]] || return 2; assignee="${2:-}"; shift 2 ;; --assignee=*) assignee="${arg#--assignee=}"; shift ;;
		--label | -l) [[ $# -ge 2 ]] || return 2; while IFS= read -r tok; do [[ -n "$tok" ]] && labels+=("$tok"); done < <(_rest_split_csv "${2:-}"); shift 2 ;;
		--label=*) while IFS= read -r tok; do [[ -n "$tok" ]] && labels+=("$tok"); done < <(_rest_split_csv "${arg#--label=}"); shift ;;
		--search | -S) [[ $# -ge 2 ]] || return 2; search="${2:-}"; shift 2 ;; --search=*) search="${arg#--search=}"; shift ;;
		--base | -B) [[ $# -ge 2 ]] || return 2; base_branch="${2:-}"; shift 2 ;; --base=*) base_branch="${arg#--base=}"; shift ;;
		--head | -H) [[ $# -ge 2 ]] || return 2; head_branch="${2:-}"; shift 2 ;; --head=*) head_branch="${arg#--head=}"; shift ;;
		--draft | -d) draft=1; shift ;;
		--limit | -L) [[ $# -ge 2 ]] || return 2; limit="${2:-}"; shift 2 ;; --limit=*) limit="${arg#--limit=}"; shift ;;
		--json) [[ $# -ge 2 ]] || return 2; json_fields="${2:-}"; shift 2 ;; --json=*) json_fields="${arg#--json=}"; shift ;;
		--jq | -q) [[ $# -ge 2 ]] || return 2; jq_expr="${2:-}"; shift 2 ;; --jq=* | -q=*) jq_expr="${arg#*=}"; shift ;;
		*) printf '_rest_pr_search: unsupported argument: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	[[ -n "$repo" && "$limit" =~ ^[1-9][0-9]*$ && "$limit" -le 1000 ]] &&
		_rest_repo_slug_supported "$repo" || {
		printf '_rest_pr_search: --repo and a limit <= 1000 are required\n' >&2
		return 1
	}
	if [[ -n "$json_fields" ]] && ! _rest_pr_list_fields_supported search "$json_fields"; then
		printf '_rest_pr_search: unsupported JSON field set: %s\n' "$json_fields" >&2
		return 2
	fi
	[[ -z "$author" ]] || author="$(_rest_resolve_actor_filter "$author")" || return 1
	[[ -z "$assignee" ]] || assignee="$(_rest_resolve_actor_filter "$assignee")" || return 1
	local query="${search}${search:+ }repo:${repo} is:pr"
	case "$state" in
	open) query="${query} is:open" ;;
	closed) query="${query} is:closed is:unmerged" ;;
	merged) query="${query} is:merged" ;;
	all) ;;
	*) printf '_rest_pr_search: unsupported state: %s\n' "$state" >&2; return 2 ;;
	esac
	[[ -z "$author" ]] || query="${query} author:${author}"
	[[ -z "$assignee" ]] || query="${query} assignee:${assignee}"
	local qualifier=""
	if [[ -n "$base_branch" ]]; then
		qualifier="$(_rest_search_quoted_qualifier base "$base_branch")" || return 2
		query="${query} ${qualifier}"
	fi
	if [[ -n "$head_branch" ]]; then
		qualifier="$(_rest_search_quoted_qualifier head "$head_branch")" || return 2
		query="${query} ${qualifier}"
	fi
	[[ "$draft" -eq 0 ]] || query="${query} draft:true"
	local label=""
	for label in "${labels[@]}"; do
		qualifier="$(_rest_search_quoted_qualifier label "$label")" || return 2
		query="${query} ${qualifier}"
	done
	local encoded=""
	encoded=$(jq -rn --arg value "$query" '$value | @uri') || return 1
	local items=""
	items="$(_rest_search_collect_items "/search/issues?q=${encoded}" "$limit")" || return 1
	if [[ -n "$json_fields" ]]; then
		jq_expr="$(_rest_pr_search_json_jq "$json_fields" "$jq_expr")" || return 1
	fi
	[[ -n "$jq_expr" ]] && { printf '%s' "$items" | jq -r "$jq_expr"; return $?; }
	printf '%s\n' "$items"
	return 0
}

_rest_pr_list_dispatch() {
	if _rest_pr_list_requires_search "$@"; then
		_rest_pr_search "$@"
	else
		_rest_pr_list "$@"
	fi
	return $?
}

_rest_issue_list_dispatch() {
	if _rest_args_have_search "$@"; then
		_rest_issue_search "$@"
	else
		_rest_issue_list "$@"
	fi
	return $?
}

return 0
