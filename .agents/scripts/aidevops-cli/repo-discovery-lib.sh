#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shared bounded repository discovery for canonical Git workspace roots.

[[ -n "${_AIDEVOPS_REPO_DISCOVERY_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_REPO_DISCOVERY_LIB_LOADED=1

aidevops_discover_canonical_repos() {
	local parent_dir="$1"
	local candidate=""
	local relative=""
	local top_level=""

	[[ -d "$parent_dir" ]] || return 0
	while IFS= read -r -d '' candidate; do
		relative="${candidate#"$parent_dir"/}"
		top_level="${relative%%/*}"
		case "$top_level" in
		.* | _*) continue ;;
		esac

		# Canonical checkouts have a .git directory. This excludes linked
		# worktrees and submodules, whose .git marker is a file.
		[[ -d "$candidate/.git" ]] || continue
		# A depth-two repository below a depth-one repository is a nested repo,
		# not an owner/repo canonical checkout.
		if [[ "$relative" == */* && -d "${candidate%/*}/.git" ]]; then
			continue
		fi
		printf '%s\0' "$candidate"
	done < <(find "$parent_dir" -mindepth 1 -maxdepth 2 -type d -print0 2>/dev/null)
	return 0
}

aidevops_owner_is_personal() {
	local host="$1"
	local owner="$2"
	local repos_json="${3:-${AIDEVOPS_REPOS_JSON:-${HOME:-}/.config/aidevops/repos.json}}"

	[[ -f "$repos_json" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	jq -e --arg host "$host" --arg owner "$owner" '
		((.personal_owners[$host] // []) | if type == "string" then [.] else . end)
		| map(ascii_downcase)
		| index($owner | ascii_downcase) != null
	' "$repos_json" >/dev/null 2>&1
}

aidevops_recommended_repo_path() {
	local parent_dir="$1"
	local host="$2"
	local owner="$3"
	local repo="$4"
	local repos_json="${5:-${AIDEVOPS_REPOS_JSON:-${HOME:-}/.config/aidevops/repos.json}}"
	local normalized_owner=""

	if aidevops_owner_is_personal "$host" "$owner" "$repos_json"; then
		printf '%s/%s\n' "${parent_dir%/}" "$repo"
		return 0
	fi
	normalized_owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
	printf '%s/%s/%s\n' "${parent_dir%/}" "$normalized_owner" "$repo"
	return 0
}
