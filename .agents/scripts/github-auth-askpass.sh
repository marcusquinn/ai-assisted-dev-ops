#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TOKEN_HELPER="${SCRIPT_DIR}/worker-token-helper.sh"

_normalize_github_origin() {
	local origin="$1"
	origin="${origin%.git}"
	[[ "$origin" =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]] || return 1
	printf 'https://github.com/%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
	return 0
}

_validate_auth_context() {
	local expected_origin="${AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN:-}"
	local token_file="${AIDEVOPS_GIT_AUTH_TOKEN_FILE:-}"
	local repo_slug="${WORKER_REPO_SLUG:-}"
	local worktree_path="${WORKER_WORKTREE_PATH:-}"
	local expected_normalized="" actual_origin="" actual_normalized=""

	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
	[[ -n "$token_file" && -n "$worktree_path" && -d "$worktree_path" ]] || return 1
	expected_normalized=$(_normalize_github_origin "$expected_origin") || return 1
	[[ "$expected_normalized" == "https://github.com/${repo_slug}" ]] || return 1
	actual_origin=$(git -C "$worktree_path" remote get-url origin 2>/dev/null) || return 1
	actual_normalized=$(_normalize_github_origin "$actual_origin") || return 1
	[[ "$actual_normalized" == "$expected_normalized" ]] || return 1
	[[ -x "$TOKEN_HELPER" ]] || return 1
	# aidevops:trust-boundary — validate canonical path, owner, mode, expiry, and
	# repository binding immediately before exposing the credential to Git.
	"$TOKEN_HELPER" validate --token-file "$token_file" --repo "$repo_slug" --local-only \
		>/dev/null 2>&1 || return 1
	return 0
}

main() {
	local prompt="${1:-}"
	_validate_auth_context || return 1
	case "$prompt" in
	*Username*github.com*)
		printf '%s' 'x-access-token'
		return 0
		;;
	*Password*github.com*)
		local token_file="${AIDEVOPS_GIT_AUTH_TOKEN_FILE:-}"
		[[ -f "$token_file" && ! -L "$token_file" ]] || return 1
		printf '%s' "$(<"$token_file")"
		return 0
		;;
	*) return 1 ;;
	esac
}

main "$@"
