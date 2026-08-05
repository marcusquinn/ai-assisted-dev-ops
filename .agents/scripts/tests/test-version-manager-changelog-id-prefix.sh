#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$TEST_SCRIPTS_DIR"
REPO_ROOT="$(mktemp -d)"
VERSION_FILE="${REPO_ROOT}/VERSION"
trap 'rm -rf "$REPO_ROOT"' EXIT

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/version-manager-changelog.sh"

assert_classification() {
	local name="$1"
	local subject="$2"
	local expected="$3"
	local actual=""
	actual=$(_classify_commit_to_category "$subject")
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL %s: expected [%s], got [%s]\n' "$name" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

assert_classification 'bracketed feature prefix' \
	'[t18079] feat: add macOS activity cleaner audit' \
	$'added\t- add macOS activity cleaner audit'
assert_classification 'bracketed dotted fix prefix' \
	'[t18080.3] fix: preserve dotted task IDs' \
	$'fixed\t- preserve dotted task IDs'
assert_classification 'colon task prefix' \
	't18081: feat: preserve legacy ID-leading subjects' \
	$'added\t- preserve legacy ID-leading subjects'
assert_classification 'GitHub issue prefix' \
	'GH#26948: fix: classify issue-leading subjects' \
	$'fixed\t- classify issue-leading subjects'
assert_classification 'plain conventional subject' \
	'feat: retain ordinary conventional output' \
	$'added\t- retain ordinary conventional output'
assert_classification 'GH-prefixed feature squash from PR 29531' \
	'GH#29530: feat: Add a Buzz-scoped OpenCode Tabby workspace profile' \
	$'added\t- Add a Buzz-scoped OpenCode Tabby workspace profile'
assert_classification 'ordinary fix subject' \
	'fix: retain ordinary fix output' \
	$'fixed\t- retain ordinary fix output'
assert_classification 'ordinary docs subject' \
	'docs: retain ordinary docs output' \
	$'changed\t- Documentation: retain ordinary docs output'
assert_classification 'ordinary refactor subject' \
	'refactor: retain ordinary refactor output' \
	$'changed\t- Refactor: retain ordinary refactor output'
assert_classification 'ordinary security subject' \
	'security: retain ordinary security output' \
	$'security\t- retain ordinary security output'
assert_classification 'ordinary chore subject' \
	'chore: retain ordinary chore output' \
	$'changed\t- Maintenance: retain ordinary chore output'
assert_classification 'bare GH-prefixed prose remains unclassified' \
	'GH#29530: Add a Buzz-scoped OpenCode Tabby workspace profile' \
	''
assert_classification 'embedded ID-like text remains unclassified' \
	'at18079] feat: do not normalize embedded text' \
	''
