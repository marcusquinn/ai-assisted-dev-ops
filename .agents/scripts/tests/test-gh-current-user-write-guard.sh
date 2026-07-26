#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-gh-current-user-write-guard.sh — auth-rotation regression for repo write guard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="${SCRIPT_DIR}/.."

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_LOGIN="owner"
ATTRIBUTION_LOG=$(mktemp)
trap 'rm -f "$ATTRIBUTION_LOG"' EXIT

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS: %s\n' "$name"
		return 0
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL: %s\n' "$name"
	return 0
}

gh() {
	local command_name="${1:-}"
	local target="${2:-}"
	if [[ "$command_name" == "api" && "$target" == "user" ]]; then
		printf '%s\n' "$CURRENT_LOGIN"
		return 0
	fi
	return 1
}

_rest_api_call() {
	local class_name="$1"
	shift
	local command_name="${1:-}"
	local api_subcommand="${2:-}"
	local flag="${3:-}"
	local path="${4:-}"
	printf '%s|%s\n' "${AIDEVOPS_GH_QUOTA_COST:-}" \
		"${AIDEVOPS_GH_ROUTE_DECISION:-}" >>"$ATTRIBUTION_LOG"
	[[ "$class_name" == "read" && "$command_name" == "gh" && "$api_subcommand" == "api" && "$flag" == "-i" ]] || return 1
	if [[ "$path" == */collaborators/owner/permission ]]; then
		printf 'HTTP/2.0 200 OK\n\n{"permission":"write"}\n'
		return 0
	fi
	if [[ "$path" == */collaborators/outsider/permission ]]; then
		printf 'HTTP/2.0 200 OK\n\n{"permission":"read"}\n'
		return 0
	fi
	printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
	return 1
}

# shellcheck source=../shared-gh-collaborator-permission.sh
source "${PARENT_DIR}/shared-gh-collaborator-permission.sh"

if _gh_current_user_allows_repo_write "example/repo"; then
	print_result "owner token with write permission is allowed" 0
else
	print_result "owner token with write permission is allowed" 1
fi

CURRENT_LOGIN="outsider"
if _gh_current_user_allows_repo_write "example/repo"; then
	print_result "rotated outsider token is not allowed after owner token" 1
else
	print_result "rotated outsider token is not allowed after owner token" 0
fi

CURRENT_LOGIN="missing"
if _gh_current_user_allows_repo_write "example/repo"; then
	print_result "missing collaborator remains denied on HTTP 404" 1
else
	print_result "missing collaborator remains denied on HTTP 404" 0
fi

if grep -qF '1|collaborator-permission-rest' "$ATTRIBUTION_LOG"; then
	print_result "collaborator permission lookup declares exact REST cost" 0
else
	print_result "collaborator permission lookup declares exact REST cost" 1
fi

printf '%d test(s), %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
