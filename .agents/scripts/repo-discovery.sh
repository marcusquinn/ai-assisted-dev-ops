#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Bounded canonical-repository discovery shared by maintenance helpers.

[[ -n "${_AIDEVOPS_REPO_DISCOVERY_LOADED:-}" ]] && return 0
_AIDEVOPS_REPO_DISCOVERY_LOADED=1

aidevops_repo_discovery_is_reserved() {
	local candidate="$1"
	case "$(basename "$candidate")" in
	_worktrees | _archive | archive) return 0 ;;
	*) return 1 ;;
	esac
}

# Print direct repositories and repositories one owner directory below parent.
# Do not traverse reserved trees, repository contents, linked worktrees, or
# arbitrary depths. A canonical clone has a .git directory; linked worktrees
# have a .git file and are intentionally excluded.
aidevops_discover_canonical_repos() {
	local parent="$1"
	local candidate nested
	[[ -d "$parent" ]] || return 0
	for candidate in "$parent"/*; do
		[[ -d "$candidate" ]] || continue
		aidevops_repo_discovery_is_reserved "$candidate" && continue
		if [[ -d "$candidate/.git" ]]; then
			printf '%s\n' "$candidate"
			continue
		fi
		for nested in "$candidate"/*; do
			[[ -d "$nested" ]] || continue
			[[ -d "$nested/.git" ]] || continue
			printf '%s\n' "$nested"
		done
	done
	return 0
}
