#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#31191: classify GitHub REST DELETE commands by
# endpoint risk while preserving standard classification for read-only calls.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HELPER="${REPO_ROOT}/.agents/scripts/verify-operation-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	printf 'FAIL: cannot execute %s\n' "$HELPER" >&2
	exit 1
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_classification() {
	local name="$1"
	local operation="$2"
	local expected_type="$3"
	local expected_tier="$4"
	local output
	output=$("$HELPER" check --operation "$operation")
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$output" == *"type: ${expected_type}"* && "$output" == *"risk_tier: ${expected_tier}"* ]]; then
		printf 'PASS: %s\n' "$name"
		return 0
	fi

	printf 'FAIL: %s\n%s\n' "$name" "$output" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 1
}

assert_classification \
	'long --method issue-comment deletion is critical' \
	'gh api --method DELETE repos/owner/repo/issues/comments/5543339491' \
	'destructive_delete' 'critical' || true
assert_classification \
	'short -X issue-comment deletion is critical' \
	'gh api -X DELETE repos/owner/repo/issues/comments/5543339491' \
	'destructive_delete' 'critical' || true
assert_classification \
	'endpoint before method flag remains critical' \
	'gh api "repos/owner/repo/issues/comments/5543339491" --method DELETE' \
	'destructive_delete' 'critical' || true
assert_classification \
	'quoted endpoint remains critical' \
	"gh api --method DELETE 'repos/owner/repo/issues/comments/5543339491'" \
	'destructive_delete' 'critical' || true
assert_classification \
	'other DELETE endpoints are high risk' \
	'gh api --method DELETE repos/owner/repo/issues/31191' \
	'github_api_delete' 'high' || true
assert_classification \
	'read-only GitHub API call remains standard' \
	'gh api repos/owner/repo/issues/comments/5543339491' \
	'unknown' 'standard' || true

printf '%s tests run, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
