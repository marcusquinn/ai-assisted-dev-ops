#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pr-supersession-helper.sh — Detect PRs superseded by their current base.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

_psh_log() {
	local msg="$1"
	printf '[pr-supersession] %s\n' "$msg" >&2
	return 0
}

_psh_usage() {
	cat <<'EOF'
pr-supersession-helper.sh — classify whether a PR is superseded by base

Usage:
  pr-supersession-helper.sh classify --repo OWNER/REPO --pr N [--repo-path PATH] [--json]
  pr-supersession-helper.sh help

Output classes:
  fully_superseded     Base already contains the PR deliverable and no meaningful diff remains.
  partially_superseded Base contains some deliverable signals, but PR still has relevant changes.
  stale_baseline_only  Current branch diff no longer overlaps the PR's original changed files.
  still_needed         Deliverable is not present on base, or branch diff still carries it.
  unknown              Required metadata or git comparison was unavailable.

The helper is advisory. It prints a suggested close comment for superseded cases
but never closes the PR.
EOF
	return 0
}

_psh_require_tools() {
	local missing=0
	for tool in gh jq git; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			_psh_log "missing required tool: $tool"
			missing=1
		fi
	done
	[[ "$missing" -eq 0 ]] || return 1
	return 0
}

_psh_compact_lines_json() {
	jq -Rn '[inputs | select(length > 0)]'
	return 0
}

_psh_fetch_pr_json() {
	local repo_slug="$1"
	local pr_number="$2"

	gh pr view "$pr_number" --repo "$repo_slug" \
		--json number,title,body,baseRefName,headRefName,baseRefOid,headRefOid,files,author,url \
		2>/dev/null
	return $?
}

_psh_default_repo_path() {
	local repo_slug="$1"
	local repo_path=""

	if git rev-parse --show-toplevel >/dev/null 2>&1; then
		repo_path=$(git rev-parse --show-toplevel 2>/dev/null) || repo_path=""
		if [[ -n "$repo_path" ]]; then
			printf '%s\n' "$repo_path"
			return 0
		fi
	fi

	repo_path=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[]? | select(.slug == $slug) | .path // empty' \
		"${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}" 2>/dev/null | head -n 1) || repo_path=""
	repo_path="${repo_path/#\~/$HOME}"
	[[ -n "$repo_path" ]] || return 1
	printf '%s\n' "$repo_path"
	return 0
}

_psh_original_files_json() {
	local pr_json="$1"
	printf '%s' "$pr_json" | jq -r '.files[]?.path // empty' 2>/dev/null | _psh_compact_lines_json
	return 0
}

_psh_git_repo_available() {
	local repo_path="$1"
	[[ -n "$repo_path" ]] || return 1
	git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1
	return $?
}

_psh_delete_temp_refs() {
	local repo_path="$1"
	local ref_prefix="$2"
	[[ -n "$ref_prefix" ]] || return 0
	git -C "$repo_path" update-ref -d "${ref_prefix}/base" 2>/dev/null || true
	git -C "$repo_path" update-ref -d "${ref_prefix}/head" 2>/dev/null || true
	return 0
}

_psh_cleanup_temp_refs() {
	# Bash's dynamic scope exposes the caller's local values to RETURN cleanup.
	local repo_path="${1:-${repo_path:-}}"
	local ref_prefix="${2:-${ref_prefix:-}}"
	_psh_delete_temp_refs "$repo_path" "$ref_prefix"
	return 0
}

_psh_diff_files_json() {
	local repo_path="$1"
	local base_ref="$2"
	local head_ref="$3"
	local pr_number="${4:-}"
	local expected_head_oid="${5:-}"
	local base=""
	local head=""
	local candidate=""
	local ref_prefix=""
	local diff_lines=""

	if ! _psh_git_repo_available "$repo_path"; then
		printf '[]\n'
		return 1
	fi

	if git -C "$repo_path" remote get-url origin >/dev/null 2>&1; then
		[[ "$pr_number" =~ ^[0-9]+$ ]] || {
			printf '[]\n'
			return 1
		}
		ref_prefix="refs/aidevops/pr-supersession/${pr_number}-$$"
		_save_cleanup_scope
		trap '_run_cleanups' RETURN
		push_cleanup _psh_cleanup_temp_refs
		if ! git -C "$repo_path" fetch --quiet origin \
			"+refs/heads/${base_ref}:${ref_prefix}/base" 2>/dev/null; then
			_psh_delete_temp_refs "$repo_path" "$ref_prefix"
			printf '[]\n'
			return 1
		fi
		if ! git -C "$repo_path" fetch --quiet origin \
			"+refs/pull/${pr_number}/head:${ref_prefix}/head" 2>/dev/null; then
			_psh_delete_temp_refs "$repo_path" "$ref_prefix"
			printf '[]\n'
			return 1
		fi
		base=$(git -C "$repo_path" rev-parse "${ref_prefix}/base^{commit}" 2>/dev/null) || base=""
		head=$(git -C "$repo_path" rev-parse "${ref_prefix}/head^{commit}" 2>/dev/null) || head=""
		if [[ -z "$base" || -z "$head" ]] || \
			[[ -n "$expected_head_oid" && "$head" != "$expected_head_oid" ]]; then
			_psh_delete_temp_refs "$repo_path" "$ref_prefix"
			printf '[]\n'
			return 1
		fi
	else
		for candidate in "origin/${base_ref}" "$base_ref"; do
			if git -C "$repo_path" rev-parse --verify "${candidate}^{commit}" >/dev/null 2>&1; then
				base="$candidate"
				break
			fi
		done
		for candidate in "origin/${head_ref}" "$head_ref"; do
			if git -C "$repo_path" rev-parse --verify "${candidate}^{commit}" >/dev/null 2>&1; then
				head="$candidate"
				break
			fi
		done
		if [[ -z "$base" || -z "$head" ]]; then
			printf '[]\n'
			return 1
		fi
	fi

	if ! diff_lines=$(git -C "$repo_path" diff --name-only "${base}...${head}" 2>/dev/null); then
		_psh_delete_temp_refs "$repo_path" "$ref_prefix"
		printf '[]\n'
		return 1
	fi
	_psh_delete_temp_refs "$repo_path" "$ref_prefix"
	printf '%s\n' "$diff_lines" | _psh_compact_lines_json
	return 0
}

_psh_extract_deliverable_terms_json() {
	local pr_json="$1"
	local text=""

	text=$(printf '%s' "$pr_json" | jq -r '[.title // "", .body // ""] | join("\n")' 2>/dev/null) || text=""
	printf '%s\n' "$text" \
		| tr '`"' ' ' \
		| tr -cs '[:alnum:]_.-/' '\n' \
		| awk 'length($0) >= 4 && $0 !~ /^(https?|github|com|this|that|with|from|have|will|should|would|when|then|base|branch|pull|request|issue|task|files|edit|new|run|test|tests|helper|detect|current|remaining|summary|stale|superseded)$/ {print}' \
		| sort -u \
		| _psh_compact_lines_json
	return 0
}

_psh_base_term_hits_json() {
	local repo_path="$1"
	local base_ref="$2"
	local terms_json="$3"
	local expected_base_oid="${4:-}"
	local base="$expected_base_oid"
	local candidate=""
	local terms_count
	terms_count=$(printf '%s' "$terms_json" | jq 'length' 2>/dev/null) || terms_count=0
	[[ "$terms_count" =~ ^[0-9]+$ ]] || terms_count=0
	if [[ "$terms_count" -eq 0 ]]; then
		printf '[]\n'
		return 0
	fi
	if ! _psh_git_repo_available "$repo_path"; then
		printf '[]\n'
		return 1
	fi
	if [[ -z "$base" ]] || ! git -C "$repo_path" rev-parse --verify "${base}^{commit}" >/dev/null 2>&1; then
		base=""
		for candidate in "origin/${base_ref}" "$base_ref"; do
			if git -C "$repo_path" rev-parse --verify "${candidate}^{commit}" >/dev/null 2>&1; then
				base="$candidate"
				break
			fi
		done
	fi
	if [[ -z "$base" ]]; then
		printf '[]\n'
		return 1
	fi

	local tmp
	tmp=$(mktemp) || return 1
	printf '%s' "$terms_json" | jq -r '.[]' | while IFS= read -r term; do
		[[ -n "$term" ]] || continue
		if git -C "$repo_path" grep -F --quiet -- "$term" "$base" 2>/dev/null; then
			printf '%s\n' "$term"
		fi
	done >"$tmp"
	_psh_compact_lines_json <"$tmp"
	rm -f "$tmp" 2>/dev/null || true
	return 0
}

_psh_intersection_count() {
	local left_json="$1"
	local right_json="$2"

	jq -n --argjson left "$left_json" --argjson right "$right_json" \
		'[$left[] | select(. as $x | $right | index($x))] | length'
	return 0
}

_psh_build_comment() {
	local classification="$1"
	local pr_number="$2"
	local base_ref="$3"
	local rationale="$4"
	local suggested_action="retain this PR until the remaining diff is reviewed"

	case "$classification" in
	fully_superseded | stale_baseline_only)
		suggested_action="close this PR only after a maintainer verifies the fetched \`${base_ref}\` comparison represents the intended deliverable"
		;;
	esac
	cat <<EOF
Supersession check for PR #${pr_number}: **${classification}**.

Rationale: ${rationale}

Suggested action: ${suggested_action}. This helper is advisory and did not close anything.
EOF
	return 0
}

_psh_extract_closing_issue_from_pr_json() {
	local pr_json="$1"
	local body title body_issue title_issue

	body=$(printf '%s' "$pr_json" | jq -r '.body // empty' 2>/dev/null) || body=""
	title=$(printf '%s' "$pr_json" | jq -r '.title // empty' 2>/dev/null) || title=""
	body_issue=$(printf '%s' "$body" | grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+' | head -1 | grep -oE '[0-9]+') || body_issue=""
	title_issue=$(printf '%s' "$title" | grep -oE 'GH#[0-9]+' | head -1 | grep -oE '[0-9]+') || title_issue=""

	[[ -n "$body_issue" ]] || return 0
	if [[ -n "$title_issue" ]]; then
		printf '%s' "$title_issue"
		return 0
	fi
	printf '%s' "$body_issue"
	return 0
}

_psh_find_merged_closer_for_closed_issue() {
	local repo_slug="$1"
	local issue_number="$2"
	local current_pr="$3"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug#*/}"
	local response=""
	local reported_cost=""
	local closer_number=""

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$current_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
	[[ -n "$owner" && -n "$name" ]] || return 1

	# `closedByPullRequestsReferences` is GraphQL-only. Keep the supersession
	# trust gate on one fixed, response-metered request instead of opaque native
	# issue/PR views. Reject truncated connections and mismatched repositories so
	# an incomplete snapshot can never authorize closing a worker PR.
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub.
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="pulse-supersession-closing-pr-exact-cost" \
		gh api graphql -F owner="$owner" -F name="$name" -F number="$issue_number" -f query='
		query($owner: String!, $name: String!, $number: Int!) {
			repository(owner: $owner, name: $name) {
				nameWithOwner
				issue(number: $number) {
					state
					closedByPullRequestsReferences(first: 100) {
						nodes { number state mergedAt repository { nameWithOwner } }
						pageInfo { hasNextPage }
					}
				}
			}
			rateLimit { cost }
		}' 2>/dev/null) || return 1
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || return 1
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 1
	closer_number=$(printf '%s' "$response" | jq -er \
		--arg repo "$repo_slug" --arg current_pr "$current_pr" '
		.data.repository as $repository
		| select(($repository.nameWithOwner | ascii_downcase) == ($repo | ascii_downcase))
		| $repository.issue as $issue
		| select($issue != null and $issue.state == "CLOSED")
		| $issue.closedByPullRequestsReferences
		| select(.pageInfo.hasNextPage == false)
		| [.nodes[]?
			| select(
				(.repository.nameWithOwner | ascii_downcase) == ($repo | ascii_downcase)
				and (.number | tostring) != $current_pr
				and .state == "MERGED"
				and ((.mergedAt // "") | length) > 0
			)
			| .number]
		| first
		| select(type == "number")
	' 2>/dev/null) || return 1
	[[ "$closer_number" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$closer_number"
	return 0
}

_psh_classify_json() {
	local pr_json="$1"
	local repo_path="$2"
	local as_json="$3"

	local pr_number title base_ref head_ref base_oid head_oid original_files diff_files terms hits
	local comparison_available=1
	pr_number=$(printf '%s' "$pr_json" | jq -r '.number // empty')
	title=$(printf '%s' "$pr_json" | jq -r '.title // empty')
	base_ref=$(printf '%s' "$pr_json" | jq -r '.baseRefName // empty')
	head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // empty')
	base_oid=$(printf '%s' "$pr_json" | jq -r '.baseRefOid // empty')
	head_oid=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty')
	original_files=$(_psh_original_files_json "$pr_json")
	terms=$(_psh_extract_deliverable_terms_json "$pr_json")
	if ! diff_files=$(_psh_diff_files_json "$repo_path" "$base_ref" "$head_ref" \
		"$pr_number" "$head_oid" 2>/dev/null); then
		diff_files="[]"
		comparison_available=0
	fi
	hits=$(_psh_base_term_hits_json "$repo_path" "$base_ref" "$terms" "$base_oid" 2>/dev/null) || hits="[]"

	local original_count diff_count overlap_count classification rationale comment
	original_count=$(printf '%s' "$original_files" | jq 'length')
	diff_count=$(printf '%s' "$diff_files" | jq 'length')
	overlap_count=$(_psh_intersection_count "$original_files" "$diff_files")

	classification="still_needed"
	rationale="the exact current PR diff still carries files from the original deliverable"

	if [[ -z "$base_ref" || -z "$head_ref" ]]; then
		classification="unknown"
		rationale="PR metadata did not include base/head refs"
	elif [[ "$comparison_available" -eq 0 ]]; then
		classification="unknown"
		rationale="the exact current PR head could not be compared with its base; an unavailable comparison is not evidence of an empty diff"
	elif [[ "$diff_count" -eq 0 ]]; then
		classification="fully_superseded"
		rationale="the exact fetched PR head has no diff against the fetched ${base_ref} base"
	elif [[ "$original_count" -gt 0 && "$overlap_count" -eq 0 ]]; then
		classification="stale_baseline_only"
		rationale="the exact current PR diff no longer overlaps any of the PR's original changed files"
	elif [[ "$original_count" -gt 0 && "$overlap_count" -gt 0 && "$overlap_count" -lt "$original_count" ]]; then
		classification="partially_superseded"
		rationale="the exact PR diff retains ${overlap_count}/${original_count} original changed file(s)"
	fi

	comment=$(_psh_build_comment "$classification" "$pr_number" "$base_ref" "$rationale")

	if [[ "$as_json" == "1" ]]; then
		jq -n \
			--arg classification "$classification" \
			--arg rationale "$rationale" \
			--arg comment "$comment" \
			--arg title "$title" \
			--arg base_oid_at_query "$base_oid" \
			--arg head_oid "$head_oid" \
			--argjson pr "${pr_number:-0}" \
			--argjson comparison_available "$comparison_available" \
			--argjson original_files "$original_files" \
			--argjson diff_files "$diff_files" \
			--argjson deliverable_terms "$terms" \
			--argjson base_hits "$hits" \
			'{classification:$classification, rationale:$rationale, suggested_close_comment:$comment, pr:$pr, title:$title, comparison_available:($comparison_available == 1), base_oid_at_query:$base_oid_at_query, compared_head_oid:$head_oid, original_files:$original_files, current_diff_files:$diff_files, deliverable_terms:$deliverable_terms, base_hits:$base_hits}'
	else
		printf 'classification=%s\n' "$classification"
		printf 'rationale=%s\n' "$rationale"
		printf '\n%s\n' "$comment"
	fi
	return 0
}

_psh_cmd_classify() {
	local repo_slug=""
	local pr_number=""
	local repo_path=""
	local as_json=0

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--repo)
				repo_slug="${2:-}"
				shift 2
				;;
			--pr)
				pr_number="${2:-}"
				shift 2
				;;
			--repo-path)
				repo_path="${2:-}"
				shift 2
				;;
			--json)
				as_json=1
				shift
				;;
			*)
				_psh_log "unknown argument: $arg"
				return 2
				;;
		esac
	done

	[[ -n "$repo_slug" && -n "$pr_number" ]] || { _psh_usage; return 2; }
	_psh_require_tools || return 1
	if [[ -z "$repo_path" ]]; then
		repo_path=$(_psh_default_repo_path "$repo_slug" 2>/dev/null) || repo_path=""
	fi

	local pr_json
	pr_json=$(_psh_fetch_pr_json "$repo_slug" "$pr_number") || return 1
	_psh_classify_json "$pr_json" "$repo_path" "$as_json"
	return 0
}

main() {
	local cmd="${1:-help}"
	case "$cmd" in
		classify)
			shift
			_psh_cmd_classify "$@"
			return $?
			;;
		help|--help|-h)
			_psh_usage
			return 0
			;;
		*)
			_psh_usage
			return 2
			;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
