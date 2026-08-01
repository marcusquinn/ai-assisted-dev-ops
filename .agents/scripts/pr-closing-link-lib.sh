#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared strict resolver for one authoritative GitHub PR closing-issue identity.

[[ -n "${_PR_CLOSING_LINK_LIB_LOADED:-}" ]] && return 0
_PR_CLOSING_LINK_LIB_LOADED=1

# Resolve exactly one same-repository issue from `gh pr view`'s authoritative
# closingIssuesReferences metadata. gh 2.96 requests 100 nodes per page and
# pkg/cmd/pr/shared/finder.go::preloadPrClosingIssuesReferences drains every
# nested page before api/export_pr.go flattens the nodes. Do not pass `gh pr
# list` metadata here: list results do not run that per-PR nested-page preload.
# Text references, quotations, code blocks, cross-repository issues, and
# ambiguous closing identities fail closed.
# Args: $1=PR JSON, $2=expected repository slug
# Output: issue number
_pr_closing_link_issue_from_metadata() {
	local pr_json="$1"
	local repo_slug="$2"
	local repo_owner=""
	local repo_name=""
	local linked_issue=""

	[[ "$repo_slug" =~ ^[^/]+/[^/]+$ ]] || return 1
	repo_owner="${repo_slug%%/*}"
	repo_name="${repo_slug#*/}"
	linked_issue=$(printf '%s' "$pr_json" | jq -er \
		--arg owner "$repo_owner" --arg name "$repo_name" '
		(.closingIssuesReferences // null) as $references |
		select(($references | type) == "array" and ($references | length) == 1) |
		$references[0] |
		select((.number | type) == "number" and .number > 0) |
		select(((.repository.name // "") | ascii_downcase) == ($name | ascii_downcase)) |
		select(((.repository.owner.login // "") | ascii_downcase) == ($owner | ascii_downcase)) |
		.number
	' 2>/dev/null) || return 1
	[[ "$linked_issue" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s' "$linked_issue"
	return 0
}

# Args: $1=PR JSON, $2=expected repository slug, $3=expected issue number
_pr_closing_link_matches_issue() {
	local pr_json="$1"
	local repo_slug="$2"
	local expected_issue="$3"
	local linked_issue=""

	[[ "$expected_issue" =~ ^[1-9][0-9]*$ ]] || return 1
	linked_issue=$(_pr_closing_link_issue_from_metadata "$pr_json" "$repo_slug") || return 1
	[[ "$linked_issue" == "$expected_issue" ]] || return 1
	return 0
}
