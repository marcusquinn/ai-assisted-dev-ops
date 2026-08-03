#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
STATE_HELPER="${TEST_DIR}/../full-loop-helper-state.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
SCRIPT_DIR="$TEST_ROOT"
GH_CALLS="$TEST_ROOT/gh-calls.log"
AUTHORITY_RC=1
AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="fixture-untrusted"
MOCK_HEADLESS=0
TESTS_RUN=0
TESTS_FAILED=0

helper_source=$(awk '/^_linked_issue_author_allows_start\(\) \{/,/^}/ { print }' "$STATE_HELPER")
gate_source=$(awk '/^_check_linked_issue_gate\(\) \{/,/^}/ { print }' "$STATE_HELPER")
[[ -n "$helper_source" ]] || {
	printf 'FAIL unable to extract linked issue author gate\n' >&2
	exit 1
}
[[ -n "$gate_source" ]] || {
	printf 'FAIL unable to extract linked issue pre-start gate\n' >&2
	exit 1
}
# shellcheck disable=SC1090
eval "$helper_source"
# shellcheck disable=SC1090
eval "$gate_source"

gh() {
	local command="${1:-}"
	: "$command"
	return 1
}

is_headless() {
	[[ "$MOCK_HEADLESS" -eq 1 ]]
	return $?
}

print_error() {
	local message="$1"
	: "$message"
	return 0
}

_gh_actor_has_repo_write_authority() {
	local repo="$1"
	local login="$2"
	local association="$3"
	[[ -n "$repo" && -n "$association" ]] || return 2
	: "$login"
	return "$AUTHORITY_RC"
}

gh_issue_edit_safe() {
	printf '%s\n' "$*" >>"$GH_CALLS"
	return 0
}

write_approval_helper() {
	local result="$1"
	printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '${result}'" >"$SCRIPT_DIR/approval-helper.sh"
	chmod +x "$SCRIPT_DIR/approval-helper.sh"
	return 0
}

check_gate() {
	local name="$1"
	local expected_rc="$2"
	local issue_json="$3"
	local rc=0
	_linked_issue_author_allows_start 28706 owner/repo "$issue_json" || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq "$expected_rc" ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s: expected rc=%s got rc=%s\n' "$name" "$expected_rc" "$rc" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

check_lookup_failure() {
	local name="$1"
	local headless="$2"
	local rc=0
	MOCK_HEADLESS="$headless"
	_check_linked_issue_gate "work on #28706" owner/repo || rc=$?
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 1 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s: expected rc=1 got rc=%s\n' "$name" "$rc" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

main() {
	: >"$GH_CALLS"
	AUTHORITY_RC=0
	write_approval_helper NO_APPROVAL
	check_gate "trusted author bypasses approval" 0 \
		'{"author_association":"OWNER","user":{"login":"owner","type":"User"}}'

	AUTHORITY_RC=1
	write_approval_helper NO_APPROVAL
	check_gate "external author without approval blocks" 1 \
		'{"author_association":"CONTRIBUTOR","user":{"login":"reporter","type":"User"}}'
	if grep -q -- '--add-label needs-maintainer-review' "$GH_CALLS"; then
		printf 'PASS external block attempts containment label\n'
	else
		printf 'FAIL external block did not attempt containment label\n' >&2
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	check_gate "external-origin bot without approval blocks" 1 \
		'{"author_association":"NONE","user":{"login":"github-actions[bot]","type":"Bot"},"labels":[{"name":"external-contributor"}]}'

	: >"$GH_CALLS"
	write_approval_helper VERIFIED
	check_gate "verified external author approval allows start" 0 \
		'{"author_association":"CONTRIBUTOR","user":{"login":"reporter","type":"User"}}'
	[[ ! -s "$GH_CALLS" ]] || TESTS_FAILED=$((TESTS_FAILED + 1))

	write_approval_helper NO_KEY
	check_gate "unverifiable approval blocks" 1 \
		'{"author_association":"CONTRIBUTOR","user":{"login":"reporter","type":"User"}}'

	write_approval_helper NO_APPROVAL
	check_gate "missing author metadata fails closed" 1 '{}'

	check_lookup_failure "headless issue metadata lookup failure blocks" 1
	check_lookup_failure "interactive issue metadata lookup failure blocks" 0

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
