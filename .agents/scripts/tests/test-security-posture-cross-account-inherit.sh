#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for the cross-account secrets:inherit detector (GH#30452).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0
STUB_WORKFLOW_CONTENT=""
STUB_GH_FAILURE="false"

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	local detail="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL: %s — %s\n' "$message" "$detail" >&2
	return 0
}

gh() {
	if [[ "$STUB_GH_FAILURE" == "true" ]]; then
		return 1
	fi

	printf '%s' "$STUB_WORKFLOW_CONTENT" | base64
	return 0
}

# shellcheck source=../security-posture-helper-repo.sh
source "${SCRIPTS_DIR}/security-posture-helper-repo.sh"

assert_detector_result() {
	local expected="$1"
	local description="$2"
	local actual=0

	_detect_cross_account_inherit "consumer/repo" || actual=$?
	if [[ "$actual" -eq "$expected" ]]; then
		pass "$description"
	else
		fail "$description" "expected return $expected, got $actual"
	fi
	return 0
}

STUB_WORKFLOW_CONTENT="jobs:
  sync:
    uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@main
    # GH#20976: secrets: inherit only works within the same GitHub account/org.
    # Cross-account callers receive no secret when using secrets: inherit.
    secrets:
      SYNC_PAT: \${{ secrets.SYNC_PAT }}"
assert_detector_result 1 "canonical comments with explicit SYNC_PAT mapping are clean"

STUB_WORKFLOW_CONTENT='jobs:
  sync:
    uses: marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml@main
    secrets: inherit'
assert_detector_result 0 "active secrets: inherit mapping remains detected"

STUB_WORKFLOW_CONTENT=""
assert_detector_result 2 "empty workflow response remains unfetchable"

STUB_GH_FAILURE="true"
assert_detector_result 2 "failed workflow fetch remains unfetchable"

printf '\nTests: %d, failures: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
