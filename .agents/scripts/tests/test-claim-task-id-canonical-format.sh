#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#29425 canonical low-sequence task IDs.

set -u

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../claim-task-id.sh
source "${SCRIPTS_DIR}/claim-task-id.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
	local message="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	printf 'PASS %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	printf 'FAIL %s\n' "$message" >&2
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$message"
		return 0
	fi
	fail "${message}: expected '${expected}', got '${actual}'"
	return 1
}

test_canonical_sequences() {
	local sequence=""
	local expected=""
	local actual=""
	while IFS=' ' read -r sequence expected; do
		actual=$(_format_legacy_task_id "$sequence") || return 1
		assert_equal "$expected" "$actual" "sequence ${sequence} formats canonically" || return 1
		task_identity_validate "$actual" || {
			fail "formatted identity ${actual} is rejected by the canonical codec"
			return 1
		}
	done <<'CASES'
1 t1
4 t4
42 t42
999 t999
1000 t1000
CASES
	return 0
}

test_canonical_range_and_output() {
	local actual=""
	actual=$(_format_task_range 4 6) || return 1
	assert_equal "t4..t6" "$actual" "task ranges use canonical identities" || return 1

	ALLOC_COUNT=1
	actual=$(_main_output_results 4 false "" false "" "") || return 1
	assert_equal $'task_id=t4\nref=none' "$actual" "single allocation output is canonical" || return 1

	ALLOC_COUNT=3
	actual=$(_main_output_results 998 false "" false "" "") || return 1
	assert_equal $'task_id=t998\ntask_id_last=t1000\ntask_count=3\nref=none' "$actual" \
		"batch allocation crosses the former padding boundary" || return 1
	return 0
}

CAPTURED_TITLE_FILE="${TEST_ROOT}/captured-title"

check_cli() {
	local platform="$1"
	[[ "$platform" == "github" ]]
	return $?
}

create_github_issue() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"
	: "$description" "$labels" "$repo_path"
	printf '%s\n' "$title" >"$CAPTURED_TITLE_FILE"
	printf '123\n'
	return 0
}

test_issue_title_and_consumers() {
	local output=""
	local parsed=""
	local what=""

	ALLOC_COUNT=1
	TASK_TITLE="canonical low task"
	TASK_DESCRIPTION="description"
	TASK_LABELS=""
	REPO_PATH="$TEST_ROOT"
	_main_create_issues 4 github >/dev/null || return 1
	assert_equal "t4: canonical low task" "$(<"$CAPTURED_TITLE_FILE")" \
		"issue title receives the exact canonical identity" || return 1

	parsed=$(parse_task_line '- [ ] t4 canonical low task tier:standard') || return 1
	if printf '%s\n' "$parsed" | grep -qx 'task_id=t4'; then
		pass "canonical allocation round-trips through TODO parsing"
	else
		fail "TODO parser did not preserve t4"
		return 1
	fi

	mkdir -p "${TEST_ROOT}/todo/tasks"
	cat >"${TEST_ROOT}/todo/tasks/t4-brief.md" <<'BRIEF'
## What

Canonical low-sequence brief.
BRIEF
	what=$(_read_brief_what_section "t4" "$TEST_ROOT") || return 1
	assert_equal $'\nCanonical low-sequence brief.' "$what" \
		"canonical allocation round-trips through brief lookup" || return 1

	printf '%s\n' '- [x] t004 historical padded task' >"${TEST_ROOT}/TODO.md"
	if _id_exists_in_todo 4 "$TEST_ROOT" && ! task_identity_validate t004; then
		pass "historical padded IDs remain migration-readable but non-canonical"
	else
		fail "historical padded compatibility or canonical rejection changed"
		return 1
	fi

	output=$(task_identity_format legacy "" 4 "") || return 1
	assert_equal "t4" "$output" "allocation helper agrees with the public codec" || return 1
	return 0
}

main() {
	test_canonical_sequences || return 1
	test_canonical_range_and_output || return 1
	test_issue_title_and_consumers || return 1
	if [[ "$FAIL_COUNT" -ne 0 ]]; then
		printf '%d test(s) failed\n' "$FAIL_COUNT" >&2
		return 1
	fi
	printf '%d assertions passed\n' "$PASS_COUNT"
	return 0
}

main "$@"
