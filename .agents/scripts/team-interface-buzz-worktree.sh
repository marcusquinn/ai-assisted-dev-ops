#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Resolve one persistent linked worktree for a host-qualified Buzz main agent.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WORKTREE_HELPER="${AIDEVOPS_BUZZ_WORKTREE_MANAGER:-${SCRIPT_DIR}/worktree-helper.sh}"

fail() {
	local message="$1"
	printf 'team-interface-buzz-worktree: %s\n' "$message" >&2
	return 1
}

canonical_git_path() {
	local project_root="$1"
	local selector="$2"
	/usr/bin/git -C "$project_root" rev-parse --path-format=absolute "$selector" 2>/dev/null
	return $?
}

is_linked_worktree() {
	local project_root="$1"
	local git_dir=""
	local common_dir=""
	git_dir=$(canonical_git_path "$project_root" --git-dir) || return 1
	common_dir=$(canonical_git_path "$project_root" --git-common-dir) || return 1
	[[ "$git_dir" != "$common_dir" ]]
	return $?
}

validate_slug() {
	local value="$1"
	local label="$2"
	if [[ ! "$value" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
		fail "$label is invalid"
		return 1
	fi
	return 0
}

validate_resolved_worktree() {
	local canonical_root="$1"
	local worktree="$2"
	local expected_branch="$3"
	local canonical_common=""
	local worktree_common=""
	local actual_branch=""
	[[ -d "$worktree" && ! -L "$worktree" ]] || return 1
	canonical_common=$(canonical_git_path "$canonical_root" --git-common-dir) || return 1
	worktree_common=$(canonical_git_path "$worktree" --git-common-dir) || return 1
	actual_branch=$(/usr/bin/git -C "$worktree" branch --show-current 2>/dev/null) || return 1
	[[ "$canonical_common" == "$worktree_common" && "$actual_branch" == "$expected_branch" ]] || return 1
	return 0
}

resolve_agent_worktree() {
	local project_root="$1"
	local agent_slug="$2"
	local host_slug="$3"
	local canonical_root=""
	local repository_name=""
	local worktree_base=""
	local branch=""
	local worktree=""

	[[ "$project_root" == /* && -d "$project_root" && ! -L "$project_root" ]] || {
		fail "project root must be an absolute non-symlink directory"
		return 1
	}
	canonical_root=$(/usr/bin/git -C "$project_root" rev-parse --show-toplevel 2>/dev/null) || {
		fail "project root is not a Git worktree"
		return 1
	}
	canonical_root=$(cd "$canonical_root" && pwd -P) || return 1
	[[ "$canonical_root" == "$project_root" ]] || {
		fail "project root must be the Git worktree root"
		return 1
	}
	validate_slug "$agent_slug" "agent slug" || return 1
	validate_slug "$host_slug" "host slug" || return 1
	if is_linked_worktree "$canonical_root"; then
		printf '%s\n' "$canonical_root"
		return 0
	fi

	repository_name=$(basename "$canonical_root")
	worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	[[ -d "$worktree_base" && ! -L "$worktree_base" ]] || {
		fail "central worktree directory is unavailable"
		return 1
	}
	branch="buzz/${host_slug}/${agent_slug}"
	worktree="${worktree_base}/${repository_name}-buzz-${host_slug}-${agent_slug}"
	if [[ ! -d "$worktree" ]]; then
		[[ -x "$WORKTREE_HELPER" && ! -L "$WORKTREE_HELPER" ]] || {
			fail "canonical worktree manager is unavailable"
			return 1
		}
		(
			cd "$canonical_root" || exit 1
			AIDEVOPS_SESSION_ORIGIN=interactive "$WORKTREE_HELPER" add "$branch" "$worktree" >&2
		) || return 1
	fi
	validate_resolved_worktree "$canonical_root" "$worktree" "$branch" || {
		fail "resolved agent worktree does not match its repository and branch binding"
		return 1
	}
	(cd "$worktree" && pwd -P)
	return $?
}

main() {
	if (($# != 3)) || [[ "$1" != "resolve" ]]; then
		fail "usage: team-interface-buzz-worktree.sh resolve PROJECT_ROOT AGENT_SLUG"
		return 64
	fi
	resolve_agent_worktree "$2" "$3" "${AIDEVOPS_BUZZ_HOST_SLUG:?AIDEVOPS_BUZZ_HOST_SLUG is required}"
	return $?
}

# Positional contract is intentionally PROJECT_ROOT + AGENT_SLUG; the trusted
# host slug remains an environment binding supplied by the verified runtime.
main "$@"
