#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#22399: external issue authors must not dispatch while
# the asynchronous issue-triage GitHub Actions workflow is queued.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
GH_CALLS_FILE=""
TEST_ROOT=""
MOCK_AUTHORITY_RC=1

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_check_external_issue_author_gate\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _check_external_issue_author_gate from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

setup_case() {
	local association="$1"
	local author_type="${2:-User}"
	local approval_result="${3:-}"
	local authority_rc="${4:-1}"
	MOCK_AUTHORITY_RC="$authority_rc"

	TEST_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-gh22399)
	GH_CALLS_FILE="${TEST_ROOT}/gh-calls.log"
	LOGFILE="${TEST_ROOT}/pulse.log"
	AGENTS_DIR="${TEST_ROOT}/agents"
	export TEST_ROOT GH_CALLS_FILE LOGFILE AGENTS_DIR
	mkdir -p "${AGENTS_DIR}/scripts" "${TEST_ROOT}/bin"
	: >"$GH_CALLS_FILE"
	: >"$LOGFILE"

	cat >"${TEST_ROOT}/issue-meta.tsv" <<EOF
${association}|${author_type}|fixture-author
EOF
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "gh $*" >>"$GH_CALLS_FILE"
if [[ "${1:-}" == "api" ]]; then
	cat "${TEST_ROOT}/issue-meta.tsv"
	exit 0
fi
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	PATH="${TEST_ROOT}/bin:$PATH"
	export PATH

	cat >"${AGENTS_DIR}/scripts/approval-helper.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "verify" && "${approval_result}" == "VERIFIED" ]]; then
	printf 'VERIFIED\n'
	exit 0
fi
if [[ "\${1:-}" == "verify" && "${approval_result}" == "NO_KEY" ]]; then
	printf 'NO_KEY\n'
	exit 1
fi
printf 'NO_APPROVAL\n'
exit 1
EOF
	chmod +x "${AGENTS_DIR}/scripts/approval-helper.sh"
	return 0
}

_gh_actor_has_repo_write_authority() {
	local repo_slug="$1"
	local author_login="$2"
	local association="$3"
	[[ -n "$repo_slug" && -n "$association" ]] || return 2
	: "$author_login"
	AIDEVOPS_GH_ACTOR_AUTHORITY_REASON="fixture-authority-${MOCK_AUTHORITY_RC}"
	return "$MOCK_AUTHORITY_RC"
}

cleanup_case() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh_issue_edit_safe() {
	printf 'gh_issue_edit_safe %s\n' "$*" >>"$GH_CALLS_FILE"
	return 0
}

test_external_author_without_approval_blocks_and_applies_nmr() {
	setup_case "CONTRIBUTOR" "User" ""
	if _check_external_issue_author_gate 22390 "owner/repo"; then
		if grep -q -- '--add-label needs-maintainer-review' "$GH_CALLS_FILE"; then
			print_result "external author without approval blocks and applies NMR" 0
			cleanup_case
			return 0
		fi
		print_result "external author without approval blocks and applies NMR" 1 "NMR label was not applied: $(<"$GH_CALLS_FILE")"
		cleanup_case
		return 0
	fi
	print_result "external author without approval blocks and applies NMR" 1 "Expected gate to block"
	cleanup_case
	return 0
}

test_owner_author_allows_dispatch() {
	setup_case "OWNER" "User" "" 0
	if _check_external_issue_author_gate 1 "owner/repo"; then
		print_result "OWNER author bypasses external gate" 1 "Expected gate to allow OWNER"
		cleanup_case
		return 0
	fi
	print_result "OWNER author bypasses external gate" 0
	cleanup_case
	return 0
}

test_collaborator_author_allows_dispatch() {
	setup_case "COLLABORATOR" "User" "" 0
	if _check_external_issue_author_gate 2 "owner/repo"; then
		print_result "COLLABORATOR author bypasses external gate" 1 "Expected gate to allow COLLABORATOR"
		cleanup_case
		return 0
	fi
	print_result "COLLABORATOR author bypasses external gate" 0
	cleanup_case
	return 0
}

test_read_collaborator_without_approval_blocks() {
	setup_case "COLLABORATOR" "User" "" 1
	if _check_external_issue_author_gate 22 "owner/repo"; then
		print_result "read collaborator without approval blocks" 0
	else
		print_result "read collaborator without approval blocks" 1 "Expected gate to block"
	fi
	cleanup_case
	return 0
}

test_collaborator_permission_lookup_failure_blocks() {
	setup_case "COLLABORATOR" "User" "" 2
	if _check_external_issue_author_gate 23 "owner/repo"; then
		print_result "collaborator permission lookup failure blocks" 0
	else
		print_result "collaborator permission lookup failure blocks" 1 "Expected gate to fail closed"
	fi
	cleanup_case
	return 0
}

test_external_author_with_crypto_approval_allows_dispatch() {
	setup_case "CONTRIBUTOR" "User" "VERIFIED"
	if _check_external_issue_author_gate 3 "owner/repo"; then
		print_result "external author with cryptographic approval dispatches" 1 "Expected verified approval to allow dispatch"
		cleanup_case
		return 0
	fi
	print_result "external author with cryptographic approval dispatches" 0
	cleanup_case
	return 0
}

test_external_author_with_unverifiable_approval_blocks_without_reapplying_nmr() {
	setup_case "CONTRIBUTOR" "User" "NO_KEY"
	if _check_external_issue_author_gate 22733 "owner/repo"; then
		if grep -q -- '--add-label needs-maintainer-review' "$GH_CALLS_FILE"; then
			print_result "unverifiable approval marker does not reapply NMR" 1 "NMR label was re-applied: $(<"$GH_CALLS_FILE")"
			cleanup_case
			return 0
		fi
		print_result "unverifiable approval marker does not reapply NMR" 0
		cleanup_case
		return 0
	fi
	print_result "unverifiable approval marker does not reapply NMR" 1 "Expected gate to block dispatch while preserving labels"
	cleanup_case
	return 0
}

test_author_lookup_failure_fails_closed() {
	setup_case "" "" ""
	rm -f "${TEST_ROOT}/issue-meta.tsv"
	if _check_external_issue_author_gate 4 "owner/repo"; then
		if grep -q -- '--add-label needs-maintainer-review' "$GH_CALLS_FILE"; then
			print_result "author lookup failure fails closed with NMR" 0
			cleanup_case
			return 0
		fi
		print_result "author lookup failure fails closed with NMR" 1 "NMR label was not applied"
		cleanup_case
		return 0
	fi
	print_result "author lookup failure fails closed with NMR" 1 "Expected gate to block on lookup failure"
	cleanup_case
	return 0
}

main() {
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_external_author_without_approval_blocks_and_applies_nmr
	test_owner_author_allows_dispatch
	test_collaborator_author_allows_dispatch
	test_read_collaborator_without_approval_blocks
	test_collaborator_permission_lookup_failure_blocks
	test_external_author_with_crypto_approval_allows_dispatch
	test_external_author_with_unverifiable_approval_blocks_without_reapplying_nmr
	test_author_lookup_failure_fails_closed

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
