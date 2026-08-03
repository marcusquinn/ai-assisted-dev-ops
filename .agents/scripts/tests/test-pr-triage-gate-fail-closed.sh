#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify PR triage does not trust a read-only COLLABORATOR association.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WORKFLOW="${TEST_DIR}/../../../.github/workflows/pr-triage-gate.yml"
TESTS_RUN=0
TESTS_FAILED=0

check_pattern() {
	local pattern="$1"
	local name="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE -- "$pattern" "$WORKFLOW"; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

main() {
	check_pattern "const trustedRoles = \['OWNER', 'MEMBER'\]" \
		"bare collaborator association is excluded from trusted PR roles"
	check_pattern "association === 'COLLABORATOR'" \
		"collaborator PR authority uses a separate verification path"
	check_pattern "collaborators/\{username\}/permission" \
		"collaborator PR authority uses the repository permission endpoint"
	check_pattern "\['admin', 'maintain', 'write'\]\.includes" \
		"write-level collaborator permissions bypass external triage"
	check_pattern "preserving PR triage gate" \
		"permission lookup uncertainty fails closed"
	check_pattern "labels: \['needs-maintainer-review', 'external-contributor'\]" \
		"untrusted PRs receive the external authority gate"

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
