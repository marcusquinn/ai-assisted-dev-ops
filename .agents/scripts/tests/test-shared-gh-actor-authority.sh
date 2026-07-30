#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../shared-gh-collaborator-permission.sh
source "${SCRIPT_DIR}/../shared-gh-collaborator-permission.sh"

TESTS_RUN=0
TESTS_FAILED=0
MOCK_PERMISSION="write"
MOCK_PERMISSION_RC=0
MOCK_LOOKUPS=0
MOCK_REPOSITORY_JSON='{"full_name":"owner/repo","owner":{"login":"owner","type":"User"}}'
MOCK_REPOSITORY_RC=0

_rest_api_call() {
	local operation="$1"
	local cli="$2"
	local command="$3"
	local endpoint="$4"
	[[ "$operation" == "read" && "$cli" == "gh" && "$command" == "api" && "$endpoint" == /repos/* ]] || return 2
	[[ "$MOCK_REPOSITORY_RC" -eq 0 ]] || return "$MOCK_REPOSITORY_RC"
	printf '%s\n' "$MOCK_REPOSITORY_JSON"
	return 0
}

_gh_collaborator_permission_lookup() {
	local repo_slug="$1"
	local user="$2"
	local out_var="${3:-}"
	[[ -n "$repo_slug" && -n "$user" ]] || return 2
	MOCK_LOOKUPS=$((MOCK_LOOKUPS + 1))
	if [[ "$MOCK_PERMISSION_RC" -ne 0 ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="fixture-failure"
		return "$MOCK_PERMISSION_RC"
	fi
	printf -v "$out_var" '%s' "$MOCK_PERMISSION"
	return 0
}

check_result() {
	local name="$1"
	local expected_rc="$2"
	local expected_reason="$3"
	shift 3
	local rc=0
	"$@" || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq "$expected_rc" && "$AIDEVOPS_GH_ACTOR_AUTHORITY_REASON" == "$expected_reason" ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s: rc=%s reason=%s\n' "$name" "$rc" "$AIDEVOPS_GH_ACTOR_AUTHORITY_REASON" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

main() {
	check_result "OWNER association is authoritative without a lookup" 0 "trusted-association" \
		_gh_actor_has_repo_write_authority "" "" OWNER
	[[ "$MOCK_LOOKUPS" -eq 0 ]] || TESTS_FAILED=$((TESTS_FAILED + 1))

	MOCK_PERMISSION="none"
	MOCK_PERMISSION_RC=0
	check_result "repository owner login is authoritative despite collaborator metadata" 0 "trusted-repository-owner" \
		_gh_actor_has_repo_write_authority owner/repo owner COLLABORATOR
	[[ "$MOCK_LOOKUPS" -eq 1 && "$AIDEVOPS_GH_REPO_OWNER_REASON" == "matched" ]] || TESTS_FAILED=$((TESTS_FAILED + 1))

	check_result "repository owner identity comparison is case-insensitive" 0 "trusted-repository-owner" \
		_gh_actor_has_repo_write_authority Owner/Repo owner COLLABORATOR

	MOCK_REPOSITORY_JSON='{"full_name":"new-owner/repo","owner":{"login":"new-owner","type":"User"}}'
	check_result "redirected stale owner slug is not authoritative" 1 "insufficient-permission:none" \
		_gh_actor_has_repo_write_authority owner/repo owner COLLABORATOR

	MOCK_REPOSITORY_JSON='{"full_name":"owner/repo","owner":{"login":"owner","type":"Organization"}}'
	check_result "organization owner text does not authorize a user" 1 "insufficient-permission:none" \
		_gh_actor_has_repo_write_authority owner/repo owner COLLABORATOR

	check_result "malformed repository slug fails closed" 2 "repository-owner-lookup-failed:invalid-repository-identity" \
		_gh_actor_has_repo_write_authority owner/repo/extra owner COLLABORATOR

	MOCK_REPOSITORY_JSON='{"full_name":"owner/repo","owner":{"login":"owner","type":"User"}}'

	MOCK_PERMISSION="write"
	MOCK_PERMISSION_RC=0
	check_result "write collaborator is authoritative" 0 "trusted-permission" \
		_gh_actor_has_repo_write_authority owner/repo writer COLLABORATOR

	MOCK_PERMISSION="read"
	check_result "read collaborator is not authoritative" 1 "insufficient-permission:read" \
		_gh_actor_has_repo_write_authority owner/repo reader COLLABORATOR

	MOCK_PERMISSION_RC=2
	check_result "collaborator lookup failure remains unknown" 2 "permission-lookup-failed:fixture-failure" \
		_gh_actor_has_repo_write_authority owner/repo unknown COLLABORATOR

	MOCK_PERMISSION_RC=0
	MOCK_LOOKUPS=0
	check_result "contributor is untrusted without spending a permission lookup" 1 "untrusted-association:CONTRIBUTOR" \
		_gh_actor_has_repo_write_authority owner/repo contributor CONTRIBUTOR
	[[ "$MOCK_LOOKUPS" -eq 0 ]] || TESTS_FAILED=$((TESTS_FAILED + 1))

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
