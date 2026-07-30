#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression test for GH#27263: write-side gh calls in shared wrappers and the
# pulse merge close paths must use the bounded timeout helper.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# These are literal source fragments; shell variables must not expand here.
# shellcheck disable=SC2016
expected_calls=(
	'_gh_with_timeout write gh api -X DELETE'
	'_gh_with_timeout write gh api -X POST'
	'_gh_with_timeout write gh "$gh_cmd" edit'
	'_gh_with_timeout write gh label create "solved:worker"'
	'_gh_with_timeout write gh label create "solved:interactive"'
	'_gh_with_timeout write gh api graphql -f query='
	'_gh_with_timeout write "$gh_command" issue comment "$@"'
	'_gh_with_timeout write gh pr comment "$@"'
	'_gh_with_timeout write gh label create "origin:worker"'
	'_gh_with_timeout write gh label create "origin:interactive"'
	'_gh_with_timeout write gh label create "origin:worker-takeover"'
	'_gh_with_timeout write gh issue close "$linked_issue"'
	'_gh_with_timeout write gh issue close "$_superseded_original_issue"'
	'_gh_with_timeout write gh pr close "$pr_number"'
)

combined_sources=(
	"${SCRIPTS_DIR}/shared-gh-wrappers.sh"
	"${SCRIPTS_DIR}/shared-gh-wrappers-create.sh"
	"${SCRIPTS_DIR}/pulse-merge.sh"
)
for expected_call in "${expected_calls[@]}"; do
	if ! grep -Fq -- "$expected_call" "${combined_sources[@]}"; then
		printf 'FAIL: missing timeout-wrapped call: %s\n' "$expected_call" >&2
		exit 1
	fi
done

printf 'PASS: GH#27263 write-side gh calls use timeout wrappers\n'
