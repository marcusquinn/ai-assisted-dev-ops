#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shared worktree path policy.
# Default: keep canonical repos under ~/Git and create aidevops linked worktrees
# in one flat, backup-excludable directory:
#   ~/Git/_worktrees/<owner>-<repo>-<branch-slug>
# Root-level personal repositories retain <repo>-<branch-slug>.

[[ -n "${_AIDEVOPS_WORKTREE_PATHS_LOADED:-}" ]] && return 0
_AIDEVOPS_WORKTREE_PATHS_LOADED=1

aidevops_expand_home_path() {
	local path="$1"
	case "$path" in
	\~) printf '%s\n' "${HOME:-}" ;;
	\~/*) printf '%s/%s\n' "${HOME:-}" "${path#\~/}" ;;
	*) printf '%s\n' "$path" ;;
	esac
	return 0
}

aidevops_worktree_base_dir_configured() {
	local repos_json="${AIDEVOPS_REPOS_JSON:-${HOME:-}/.config/aidevops/repos.json}"
	local configured=""
	if [[ -n "${AIDEVOPS_WORKTREE_BASE_DIR:-}" ]]; then
		configured="$AIDEVOPS_WORKTREE_BASE_DIR"
	elif [[ -n "${AIDEVOPS_WORKTREES_DIR:-}" ]]; then
		configured="$AIDEVOPS_WORKTREES_DIR"
	elif [[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		configured=$(jq -r '.worktree_base_dir // .worktrees_dir // empty' "$repos_json" 2>/dev/null || true)
	fi
	if [[ -z "$configured" || "$configured" == "null" ]]; then
		configured="~"'/Git/_worktrees'
	fi
	aidevops_expand_home_path "$configured"
	return 0
}

aidevops_ensure_worktree_base_dir() {
	local base_dir="$1"
	[[ -n "$base_dir" ]] || return 1
	[[ -e "$base_dir" && ! -d "$base_dir" ]] && return 1
	mkdir -p "$base_dir" 2>/dev/null || return 1
	return 0
}

aidevops_worktree_base_dir() {
	local base_dir
	base_dir=$(aidevops_worktree_base_dir_configured)
	aidevops_ensure_worktree_base_dir "$base_dir" || return 1
	printf '%s\n' "$base_dir"
	return 0
}

aidevops_branch_slug() {
	local branch="$1"
	printf '%s\n' "$branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]'
	return 0
}

aidevops_canonical_worktree_path() {
	local repo_path="${1:-.}"
	local main_wt=""
	main_wt=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}' || true)
	if [[ -n "$main_wt" ]]; then
		printf '%s\n' "$main_wt"
		return 0
	fi
	git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$repo_path"
	return 0
}

aidevops_repo_worktree_name() {
	local repo_path="${1:-.}"
	local canonical=""
	local parent_dir=""
	local configured_parent=""
	local relative=""
	local candidate_name=""
	local repos_json="${AIDEVOPS_REPOS_JSON:-${HOME:-}/.config/aidevops/repos.json}"
	canonical=$(aidevops_canonical_worktree_path "$repo_path")

	if [[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		while IFS= read -r configured_parent; do
			[[ -n "$configured_parent" ]] || continue
			parent_dir=$(aidevops_expand_home_path "$configured_parent")
			case "$canonical" in
			"$parent_dir"/*)
				relative="${canonical#"$parent_dir"/}"
				break
				;;
			esac
		done < <(jq -r '.git_parent_dirs[]? // empty' "$repos_json" 2>/dev/null || true)
	fi
	if [[ -z "$relative" && -n "${HOME:-}" ]]; then
		parent_dir="${HOME}/Git"
		case "$canonical" in
		"$parent_dir"/*) relative="${canonical#"$parent_dir"/}" ;;
		esac
	fi

	if [[ "$relative" == */* && "${relative#*/}" != */* ]]; then
		candidate_name="${relative//\//-}"
	else
		candidate_name=$(basename "$canonical")
	fi
	printf '%s\n' "$candidate_name" | tr '[:upper:]' '[:lower:]'
	return 0
}

aidevops_generate_worktree_path() {
	local repo_path="$1"
	local branch="$2"
	local repo_name slug base_dir
	repo_name=$(aidevops_repo_worktree_name "$repo_path")
	slug=$(aidevops_branch_slug "$branch")
	base_dir=$(aidevops_worktree_base_dir) || return 1
	printf '%s/%s-%s\n' "$base_dir" "$repo_name" "$slug"
	return 0
}

aidevops_migrate_repos_json_worktree_base_dir() {
	local repos_json="${1:-${AIDEVOPS_REPOS_JSON:-${HOME:-}/.config/aidevops/repos.json}}"
	local default_value="${2:-~'/Git/_worktrees'}"
	[[ -n "$repos_json" ]] || return 1
	mkdir -p "${repos_json%/*}" 2>/dev/null || return 1
	if [[ ! -f "$repos_json" ]]; then
		printf '{"initialized_repos": [], "git_parent_dirs": ["~/Git"], "worktree_base_dir": "%s"}\n' "$default_value" >"$repos_json"
		return 0
	fi
	command -v jq >/dev/null 2>&1 || return 0
	if jq -e '.worktree_base_dir // .worktrees_dir // empty' "$repos_json" >/dev/null 2>&1; then
		return 0
	fi
	local temp_file="${repos_json}.tmp.$$"
	if jq --arg dir "$default_value" '. + {worktree_base_dir: $dir}' "$repos_json" >"$temp_file"; then
		mv "$temp_file" "$repos_json"
		return 0
	fi
	rm -f "$temp_file" 2>/dev/null || true
	return 1
}
