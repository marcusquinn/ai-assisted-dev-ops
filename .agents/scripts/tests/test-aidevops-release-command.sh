#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Root CLI delegation tests for `aidevops release`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AIDEVOPS_SH="${REPO_ROOT}/aidevops.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/home" "${TEST_ROOT}/agents/scripts" "${TEST_ROOT}/other-repo"
git -C "${TEST_ROOT}/other-repo" init -q

IFS= read -r repo_version <"${REPO_ROOT}/VERSION"
printf '%s\n' "$repo_version" >"${TEST_ROOT}/agents/VERSION"

run_cli() {
	(
		cd "${TEST_ROOT}/other-repo" || exit 1
		HOME="${TEST_ROOT}/home" AIDEVOPS_AGENTS_DIR="${TEST_ROOT}/agents" \
			AIDEVOPS_REPO_PATH="$REPO_ROOT" bash "$AIDEVOPS_SH" "$@"
	)
	return $?
}

help_output=$(run_cli help)
if [[ "$help_output" != *"release <cmd>"* ]]; then
	printf 'FAIL root help does not list release command\n'
	exit 1
fi
printf 'PASS root help lists release command\n'

release_output=$(run_cli release --help)
if [[ "$release_output" != *"aidevops release status SOURCE_PR"* ]] ||
	[[ "$release_output" != *"aidevops release reconcile SOURCE_PR"* ]]; then
	printf 'FAIL release help did not reach the release helper\n'
	exit 1
fi
printf 'PASS release command delegates from an unrelated repository to aidevops\n'

release_rc=0
run_cli release status not-a-pr >/dev/null 2>&1 || release_rc=$?
if [[ "$release_rc" -ne 1 ]]; then
	printf 'FAIL release helper validation exit code was not preserved\n'
	exit 1
fi
printf 'PASS release helper validation exit code is preserved\n'

exit 0
