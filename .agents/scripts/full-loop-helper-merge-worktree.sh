#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Merge Worktree -- identity and cleanup-target resolution
# =============================================================================
# Resolves GitHub repository identity from worktree remotes and validates that
# the current linked worktree is the exact cleanup target for a merged PR.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-merge-worktree.sh"
#
# Dependencies:
#   - git
#   - Globals: SCRIPT_DIR
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_MERGE_WORKTREE_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_MERGE_WORKTREE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_merge_github_slug_from_remote() {
	local worktree_root="$1"
	local remote_name="$2"
	local remote_url=""
	local repo_slug=""
	[[ -n "$worktree_root" && -n "$remote_name" ]] || return 1

	remote_url=$(git -C "$worktree_root" remote get-url "$remote_name" 2>/dev/null || true)
	case "$remote_url" in
	git@github.com:*) repo_slug="${remote_url#git@github.com:}" ;;
	ssh://git@github.com/*) repo_slug="${remote_url#ssh://git@github.com/}" ;;
	https://github.com/*) repo_slug="${remote_url#https://github.com/}" ;;
	http://github.com/*) repo_slug="${remote_url#http://github.com/}" ;;
	git://github.com/*) repo_slug="${remote_url#git://github.com/}" ;;
	*) return 1 ;;
	esac
	repo_slug="${repo_slug%%\?*}"
	repo_slug="${repo_slug%%#*}"
	repo_slug="${repo_slug%/}"
	repo_slug="${repo_slug%.git}"
	[[ -n "$repo_slug" && "$repo_slug" == */* && "${repo_slug#*/}" != */* ]] || return 1
	printf '%s\n' "$repo_slug"
	return 0
}

_merge_current_github_repo_identity() {
	local worktree_root="$1"
	local origin_slug=""
	origin_slug=$(_merge_github_slug_from_remote "$worktree_root" "origin" 2>/dev/null || true)
	if [[ -n "$origin_slug" ]]; then
		printf '%s\n' "$origin_slug"
		return 0
	fi

	# Local-only test mirrors and migrated checkouts may use a non-GitHub origin.
	# Accept a fallback only when every parseable GitHub remote identifies the
	# same repository; multiple identities are ambiguous and fail closed.
	local remote_names=""
	remote_names=$(git -C "$worktree_root" remote 2>/dev/null || true)
	local remote_name=""
	local remote_slug=""
	local candidate_slug=""
	while IFS= read -r remote_name; do
		[[ -n "$remote_name" && "$remote_name" != "origin" ]] || continue
		remote_slug=$(_merge_github_slug_from_remote "$worktree_root" "$remote_name" 2>/dev/null || true)
		[[ -n "$remote_slug" ]] || continue
		if [[ -n "$candidate_slug" && "$candidate_slug" != "$remote_slug" ]]; then
			return 1
		fi
		candidate_slug="$remote_slug"
	done <<<"$remote_names"
	[[ -n "$candidate_slug" ]] || return 1
	printf '%s\n' "$candidate_slug"
	return 0
}

_merge_worktree_record_matches() {
	local porcelain="$1"
	local current_root="$2"
	local current_branch="$3"
	local current_head="$4"
	local record_root=""
	local record_branch=""
	local record_head=""
	local line=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ -z "$line" ]]; then
			if [[ "$record_root" == "$current_root" && "$record_branch" == "refs/heads/${current_branch}" && "$record_head" == "$current_head" ]]; then
				return 0
			fi
			record_root=""
			record_branch=""
			record_head=""
			continue
		fi
		case "$line" in
		worktree\ *) record_root="${line#worktree }" ;;
		HEAD\ *) record_head="${line#HEAD }" ;;
		branch\ *) record_branch="${line#branch }" ;;
		esac
	done <<<"$porcelain"

	if [[ "$record_root" == "$current_root" && "$record_branch" == "refs/heads/${current_branch}" && "$record_head" == "$current_head" ]]; then
		return 0
	fi
	return 1
}

_merge_current_worktree_cleanup_target() {
	local pr_head_ref="$1"
	local pr_head_oid="$2"
	local pr_head_repo="$3"
	local repo="$4"
	[[ -n "$pr_head_ref" && -n "$pr_head_oid" ]] || return 1

	local current_branch=""
	current_branch=$(git branch --show-current 2>/dev/null || true)
	[[ -n "$current_branch" ]] || return 1

	local current_root=""
	current_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	[[ -n "$current_root" ]] || return 1
	local current_head=""
	current_head=$(git rev-parse --verify "HEAD^{commit}" 2>/dev/null || true)
	[[ -n "$current_head" && "$current_head" == "$pr_head_oid" ]] || return 1

	# Prove this is a linked worktree without depending on discovery of the
	# canonical checkout path. The common Git directory remains authoritative
	# even when the canonical working-tree registration is temporarily absent.
	local git_dir=""
	local common_dir=""
	git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null || true)
	common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
	[[ -n "$git_dir" && -n "$common_dir" && "$git_dir" != "$common_dir" ]] || return 1

	local porcelain=""
	porcelain=$(git worktree list --porcelain 2>/dev/null || true)
	[[ -n "$porcelain" ]] || return 1
	_merge_worktree_record_matches "$porcelain" "$current_root" "$current_branch" "$current_head" || return 1

	local delete_remote_branch="1"
	if [[ "$current_branch" != "$pr_head_ref" ]]; then
		# An alias is accepted only when the linked worktree belongs to the exact
		# PR head repository. The fresh head OID, worktree record, and repository
		# identity jointly prove association without branch-name heuristics.
		[[ -n "$repo" && -n "$pr_head_repo" && "$repo" == "$pr_head_repo" ]] || return 1
		local current_repo=""
		current_repo=$(_merge_current_github_repo_identity "$current_root" 2>/dev/null || true)
		[[ -n "$current_repo" && "$current_repo" == "$repo" ]] || return 1

		# The local repair branch is the cleanup target, but its same-named
		# remote ref is not the PR head and must never be deleted implicitly.
		delete_remote_branch="0"
	fi

	printf '%s\t%s\t%s\n' "$current_root" "$current_branch" "$delete_remote_branch"
	return 0
}
