#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Shared classification for Renovate Dependency Dashboard tracking issues.

[[ -n "${_RENOVATE_DEPENDENCY_DASHBOARD_HELPER_LOADED:-}" ]] && return 0
_RENOVATE_DEPENDENCY_DASHBOARD_HELPER_LOADED=1

# Return success only for Renovate's metadata-only Dependency Dashboard issue.
# Args: $1 = issue JSON containing .author.login and .title
_is_renovate_dependency_dashboard_issue() {
	local issue_meta_json="$1"
	local author_login="" issue_title="" title_lower=""

	[[ -n "$issue_meta_json" ]] || return 1
	author_login=$(printf '%s' "$issue_meta_json" | jq -r '.author.login // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]') || author_login=""
	issue_title=$(printf '%s' "$issue_meta_json" | jq -r '.title // empty' 2>/dev/null) || issue_title=""
	title_lower=$(printf '%s' "$issue_title" | tr '[:upper:]' '[:lower:]')

	[[ "$author_login" == "renovate[bot]" ]] || return 1
	[[ "$title_lower" == *"dependency dashboard"* ]] || return 1
	return 0
}

return 0
