#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Regression coverage for dependency-bot review and deterministic Qlty policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 2
CODERABBIT_CONFIG="${REPO_ROOT}/.coderabbit.yaml"
DEPENDABOT_CONFIG="${REPO_ROOT}/.github/dependabot.yml"
CODE_QUALITY_WORKFLOW="${REPO_ROOT}/.github/workflows/code-quality.yml"
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_absent() {
	local test_name="$1"
	local needle="$2"
	local file_path="$3"
	if grep -Fq -- "$needle" "$file_path"; then
		print_result "$test_name" 1
		return 1
	fi
	print_result "$test_name" 0
	return 0
}

assert_present() {
	local test_name="$1"
	local needle="$2"
	local file_path="$3"
	if grep -Fq -- "$needle" "$file_path"; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1
	return 1
}

main() {
	assert_absent "Dependabot remains eligible for strict AI review" \
		'dependabot[bot]' "$CODERABBIT_CONFIG" || true
	assert_absent "Renovate remains eligible for strict AI review" \
		'renovate[bot]' "$CODERABBIT_CONFIG" || true
	assert_present "Dependabot ignores incompatible qlty action release" \
		'dependency-name: "qltysh/qlty-action"' "$DEPENDABOT_CONFIG" || true
	assert_present "Dependabot ignore is bounded to qlty action 2.3.0" \
		'- "2.3.0"' "$DEPENDABOT_CONFIG" || true
	assert_present "Code quality keeps the deterministic Qlty CLI version" \
		'QLTY_VERSION: "0.643.0"' "$CODE_QUALITY_WORKFLOW" || true
	assert_present "Code quality keeps qlty-action install v2.2.0" \
		'qltysh/qlty-action/install@a19242102d17e497f437d7466aa01b528537e899 # v2.2.0' \
		"$CODE_QUALITY_WORKFLOW" || true

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
