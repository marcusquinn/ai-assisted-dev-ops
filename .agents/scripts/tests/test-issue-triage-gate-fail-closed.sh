#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WORKFLOW="${TEST_DIR}/../../../.github/workflows/issue-triage-gate.yml"
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
	local first_add="" first_create="" persistent_guard="" trusted_cleanup=""
	first_add=$(grep -n 'await github\.rest\.issues\.addLabels' "$WORKFLOW" | head -1 | cut -d: -f1)
	first_create=$(grep -n 'await github\.rest\.issues\.createLabel' "$WORKFLOW" | head -1 | cut -d: -f1)
	persistent_guard=$(grep -n "issueLabels\.has('persistent')" "$WORKFLOW" | head -1 | cut -d: -f1)
	trusted_cleanup=$(grep -n 'if (authorIsTrusted)' "$WORKFLOW" | head -1 | cut -d: -f1)
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$first_add" =~ ^[0-9]+$ && "$first_create" =~ ^[0-9]+$ && "$first_add" -lt "$first_create" ]]; then
		printf 'PASS critical label application precedes label creation\n'
	else
		printf 'FAIL critical label application does not precede label creation\n' >&2
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$trusted_cleanup" =~ ^[0-9]+$ && "$persistent_guard" =~ ^[0-9]+$ && "$trusted_cleanup" -lt "$persistent_guard" ]]; then
		printf 'PASS trusted-author NMR cleanup precedes persistent non-task guard\n'
	else
		printf 'FAIL persistent non-task guard still bypasses trusted-author cleanup\n' >&2
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$persistent_guard" =~ ^[0-9]+$ && "$first_add" =~ ^[0-9]+$ && "$persistent_guard" -lt "$first_add" ]]; then
		printf 'PASS persistent non-task guard precedes triage label application\n'
	else
		printf 'FAIL persistent non-task guard does not precede triage label application\n' >&2
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi

	check_pattern "if \(!\[404, 422\]\.includes\(addError\.status\)\)" \
		"transient and quota failures are rethrown"
	check_pattern "lookupError\.status === 404" \
		"label creation requires an independent missing-label confirmation"
	check_pattern "const trustedRoles = \['OWNER', 'MEMBER'\]" \
		"bare collaborator association is excluded from trusted roles"
	check_pattern "collaborators/\{username\}/permission" \
		"collaborator authority uses the repository permission endpoint"
	check_pattern "Run trusted-author cleanup first" \
		"persistent bypass documents trusted cleanup ordering"
	check_pattern "if \(!issueLabels\.has\(label\)\)" \
		"absent cleanup labels do not spend removal requests"
	check_pattern "Review label is applied but welcome comment failed" \
		"non-critical comment failure cannot undo the trust label"

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
