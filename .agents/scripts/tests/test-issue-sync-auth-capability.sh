#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."

# shellcheck source=../issue-sync-helper.sh
source "${SCRIPTS_DIR}/issue-sync-helper.sh"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

AUTH_STATUS="failed"
API_STATUS="failed"
GH_CALLS=0
gh() {
	local group="$1"
	local action="${2:-}"
	GH_CALLS=$((GH_CALLS + 1))
	if [[ "$group" == "auth" && "$action" == "status" ]]; then
		[[ "$AUTH_STATUS" == "healthy" ]]
		return $?
	fi
	if [[ "$group" == "api" && "$action" == "graphql" ]]; then
		[[ "$API_STATUS" == "healthy" ]] && printf 'fixture-user\n'
		[[ "$API_STATUS" == "healthy" ]]
		return $?
	fi
	return 1
}

GH_TOKEN="fixture-token" GITHUB_TOKEN="" verify_gh_cli || fail "explicit GH_TOKEN was rejected"
GITHUB_TOKEN="fixture-token" GH_TOKEN="" verify_gh_cli || fail "explicit GITHUB_TOKEN was rejected"

unset GH_TOKEN GITHUB_TOKEN
AUTH_STATUS="healthy"
API_STATUS="failed"
verify_gh_cli || fail "healthy keyring authentication was rejected"

AUTH_STATUS="failed"
API_STATUS="healthy"
verify_gh_cli || fail "authenticated API capability was rejected after stale keyring status"

AUTH_STATUS="failed"
API_STATUS="failed"
auth_error=""
if auth_error=$(verify_gh_cli 2>&1); then
	fail "total authentication failure was accepted"
fi
[[ "$auth_error" == *"cannot authenticate an API request"* ]] || fail "authentication failure was not sanitized"
[[ "$auth_error" != *"fixture-token"* ]] || fail "authentication failure exposed a token"

printf 'PASS: issue sync accepts keyring, token, or authenticated API capability\n'
