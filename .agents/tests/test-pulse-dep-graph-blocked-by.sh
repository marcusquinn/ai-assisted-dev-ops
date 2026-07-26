#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression checks for pulse dispatch blocked-by reference parsing.
#
# Usage: bash .agents/tests/test-pulse-dep-graph-blocked-by.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TARGET="${SCRIPT_DIR}/../scripts/pulse-dep-graph.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMP=""

# shellcheck source=/dev/null
source "$TARGET"

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1"
	local reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — ${reason}}"
	return 0
}

_assert_lines_equal() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		_pass "$name"
		return 0
	fi
	_fail "$name" "expected [${expected//$'\n'/,}] got [${actual//$'\n'/,}]"
	return 0
}

_assert_rc() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" -eq "$expected" ]]; then
		_pass "$name"
		return 0
	fi
	_fail "$name" "expected rc ${expected} got ${actual}"
	return 0
}

_setup_blocked_by_resolution_test() {
	TEST_TMP=$(mktemp -d)
	LOGFILE="${TEST_TMP}/pulse.log"
	DEP_GRAPH_CACHE_FILE="${TEST_TMP}/dep-graph.json"
	DEP_GRAPH_CACHE_TTL_SECS=3600
	TEST_GH_RELATIONSHIP_MODE="clear"
	return 0
}

_cleanup_blocked_by_resolution_test() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
	TEST_TMP=""
	return 0
}

gh_issue_list() {
	case "${TEST_GH_ISSUE_LIST_MODE:-empty}" in
		fail)
			return 1
			;;
		closed)
			printf '[{"number":1000,"title":"t1000: blocker","state":"CLOSED"}]\n'
			return 0
			;;
		closed-lower)
			printf '[{"number":1000,"title":"t1000: blocker","state":"closed"}]\n'
			return 0
			;;
		open)
			printf '[{"number":1000,"title":"t1000: blocker","state":"OPEN"}]\n'
			return 0
			;;
		open-lower)
			printf '[{"number":1000,"title":"t1000: blocker","state":"open"}]\n'
			return 0
			;;
		self-open-only)
			printf '[{"number":2000,"title":"Review follow-up with copied t1000 context","state":"OPEN"}]\n'
			return 0
			;;
		self-open-then-canonical-closed)
			printf '[{"number":2000,"title":"Review follow-up with copied t1000 context","state":"OPEN"},{"number":1000,"title":"t1000: canonical blocker","state":"CLOSED"}]\n'
			return 0
			;;
		parent-same-line)
			printf '%s\n' '[{"number":25714,"title":"t18021: Add per-page tours","body":"blocked-by:#25710\nParent: #25707\n\n## Session Origin\nCreated from an interactive planning session. Parent: #25707. Blocked by #25710.","labels":[]}]'
			return 0
			;;
		incidental-open-then-canonical-closed)
			printf '[{"number":3000,"title":"Review follow-up with copied t1000 context","state":"OPEN"},{"number":1000,"title":"t1000: canonical blocker","state":"CLOSED"}]\n'
			return 0
			;;
		repo-json)
			printf '[{"number":1000,"title":"t1000: blocker","body":"","labels":[]}]\n'
			return 0
			;;
		*)
			printf '[]\n'
			return 0
			;;
	esac
}

gh() {
	local command="${1:-}"
	local target="${2:-}"
	if [[ "$command" == "api" && "$target" == "graphql" ]]; then
		case "${TEST_GH_RELATIONSHIP_MODE:-clear}" in
			fail)
				return 1
				;;
			open)
				printf '%s\n' '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[{"number":1000,"state":"OPEN"}],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
				return 0
				;;
			closed)
				printf '%s\n' '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[{"number":1000,"state":"CLOSED"}],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
				return 0
				;;
			unknown)
				printf '%s\n' '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[{"number":1000,"state":null}],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
				return 0
				;;
			*)
				printf '%s\n' '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
				return 0
				;;
		esac
	fi
	if [[ "${TEST_GH_ISSUE_VIEW_MODE:-fail}" == "closed" ]]; then
		printf 'CLOSED\n'
		return 0
	fi
	if [[ "${TEST_GH_ISSUE_VIEW_MODE:-fail}" == "closed-lower" ]]; then
		printf 'closed\n'
		return 0
	fi
	if [[ "${TEST_GH_ISSUE_VIEW_MODE:-fail}" == "open" ]]; then
		printf 'OPEN\n'
		return 0
	fi
	if [[ "${TEST_GH_ISSUE_VIEW_MODE:-fail}" == "open-lower" ]]; then
		printf 'open\n'
		return 0
	fi
	return 1
}

test_native_relationship_open_blocks_empty_body() {
	printf '\n=== native blockedBy relationship ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_RELATIONSHIP_MODE="open"

	local rc=0
	is_blocked_by_unresolved '' 'owner/repo' '2000' || rc=$?
	_assert_rc "native blockedBy open relationship blocks without body marker" 0 "$rc"
	if grep -q 'native relationship #1000' "$LOGFILE"; then
		_pass "native relationship block logs distinct reason"
	else
		_fail "native relationship block logs distinct reason" "missing native relationship log"
	fi
	_cleanup_blocked_by_resolution_test
	return 0
}

test_dep_graph_ignores_parent_reference_on_blocked_by_line() {
	printf '\n=== dep graph blocked-by clause parsing ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_LIST_MODE="parent-same-line"

	local repo_data="" blockers=""
	repo_data=$(_dep_graph_build_repo_data 'owner/repo')
	blockers=$(printf '%s' "$repo_data" | jq -r '.blocked_by["25714"].issue_nums | join(",")')
	_assert_lines_equal "dep graph ignores parent refs before blocked-by clause" "25710" "$blockers"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_native_relationship_clear_allows_empty_body() {
	printf '\n=== native blockedBy clear ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_RELATIONSHIP_MODE="closed"

	local rc=0
	is_blocked_by_unresolved '' 'owner/repo' '2000' || rc=$?
	_assert_rc "native blockedBy closed relationship allows dispatch when no body marker" 1 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_native_relationship_clear_ignores_duplicate_text_marker() {
	printf '\n=== native blockedBy clear overrides duplicate text marker ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_RELATIONSHIP_MODE="closed"
	TEST_GH_ISSUE_LIST_MODE="empty"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "native closed blocker clears despite duplicate text marker" 1 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_native_relationship_open_blocks_duplicate_text_marker() {
	printf '\n=== native blockedBy open blocks duplicate text marker ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_RELATIONSHIP_MODE="open"
	TEST_GH_ISSUE_LIST_MODE="closed"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "native open blocker blocks regardless of text fallback" 0 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_native_relationship_lookup_failure_fails_closed_empty_body() {
	printf '\n=== native blockedBy lookup failure ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_RELATIONSHIP_MODE="fail"

	local rc=0
	is_blocked_by_unresolved '' 'owner/repo' '2000' || rc=$?
	_assert_rc "native blockedBy lookup failure with empty body fails closed" 0 "$rc"
	if grep -q 'native blockedBy lookup unavailable and issue body is empty' "$LOGFILE"; then
		_pass "native lookup failure empty-body log is distinct"
	else
		_fail "native lookup failure empty-body log is distinct" "missing native-unavailable empty-body log"
	fi
	_cleanup_blocked_by_resolution_test
	return 0
}

test_native_relationship_lookup_failure_checks_body_markers() {
	printf '\n=== native blockedBy lookup failure with body marker ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_RELATIONSHIP_MODE="fail"
	TEST_GH_ISSUE_LIST_MODE="open"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "native blockedBy lookup failure still checks body markers" 0 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_task_id_blocker_parsing() {
	printf '\n=== blocked-by task IDs ===\n'
	local namespaced='to01j2abc3def4gh5jkm6npq7rst-42.3'
	_assert_lines_equal "compact comma-separated task IDs" $'t1\nt2\nt3' \
		"$(_blocked_by_extract_tids 'blocked-by:t1,t2,t3')"
	_assert_lines_equal "mixed legacy and namespaced task IDs" $'t325.1\n'"${namespaced}" \
		"$(_blocked_by_extract_tids "Blocked by: t325.1, ${namespaced}")"
	_assert_lines_equal "malformed task IDs fail closed" '__malformed__' \
		"$(_blocked_by_extract_tids 'Blocked by: t01')"
	_assert_lines_equal "alternate malformed task markers fail closed" '__malformed__' \
		"$(_blocked_by_extract_tids 'Blocked by: T7, tXYZ, to81j2abc3def4gh5jkm6npq7rst-1')"
	return 0
}

test_refresh_unknown_or_malformed_task_blocker_fails_closed() {
	printf '\n=== cache refresh fail-closed task blockers ===\n'
	local rc=0
	_refresh_all_blockers_resolved '{"task_ids":["t1000"],"issue_nums":[]}' '{}' '[]' '[]' || rc=$?
	_assert_rc "refresh keeps unmapped canonical blocker blocked" 1 "$rc"
	rc=0
	_refresh_all_blockers_resolved '{"task_ids":["__malformed__"],"issue_nums":[]}' '{}' '[]' '[]' || rc=$?
	_assert_rc "refresh keeps malformed blocker blocked" 1 "$rc"
	return 0
}

test_issue_number_blocker_parsing() {
	printf '\n=== blocked-by issue numbers ===\n'
	_assert_lines_equal "compact comma-separated issue numbers" $'123\n456' \
		"$(_blocked_by_extract_nums 'blocked-by:#123,#456')"
	_assert_lines_equal "spaced issue numbers" $'123\n456' \
		"$(_blocked_by_extract_nums 'Blocked by: #123, #456')"
	_assert_lines_equal "mixed prose issue numbers" $'123\n456' \
		"$(_blocked_by_extract_nums 'Blocked by #123 and #456')"
	return 0
}

test_unknown_task_blocker_fails_closed() {
	printf '\n=== fail-closed task blocker resolution ===\n'
	_setup_blocked_by_resolution_test
	printf '{"built_at":"now","repos":{"owner/repo":{"open_issues":[1],"task_to_issue":{},"blocked_by":{},"defer_flags":{}}}}\n' >"$DEP_GRAPH_CACHE_FILE"
	TEST_GH_ISSUE_LIST_MODE="empty"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "cache miss plus empty live lookup blocks as unknown" 0 "$rc"
	if grep -q 'blocked-by-unresolved-reference t1000' "$LOGFILE"; then
		_pass "unknown task blocker logs distinct reason"
	else
		_fail "unknown task blocker logs distinct reason" "missing blocked-by-unresolved-reference log"
	fi
	_cleanup_blocked_by_resolution_test
	return 0
}

test_live_task_lookup_failure_fails_closed() {
	printf '\n=== live lookup failure ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_LIST_MODE="fail"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "task live lookup failure blocks as unknown" 0 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_closed_task_blocker_is_clear() {
	printf '\n=== positively closed task blocker ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_LIST_MODE="closed"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "closed task blocker is clear" 1 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_lowercase_closed_task_blocker_is_clear() {
	printf '\n=== lowercase closed task blocker ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_LIST_MODE="closed-lower"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "lowercase closed task blocker is clear" 1 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_lowercase_open_task_blocker_blocks() {
	printf '\n=== lowercase open task blocker ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_LIST_MODE="open-lower"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "lowercase open task blocker blocks" 0 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_task_lookup_excludes_current_issue_self_match() {
	printf '\n=== live task lookup excludes current issue self-match ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_LIST_MODE="self-open-then-canonical-closed"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "current issue self-match is ignored when canonical blocker is closed" 1 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_task_lookup_self_only_fails_closed() {
	printf '\n=== live task lookup self-only result fails closed ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_LIST_MODE="self-open-only"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "self-only task lookup remains unknown and blocked" 0 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_task_lookup_prefers_canonical_title() {
	printf '\n=== live task lookup prefers canonical title ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_LIST_MODE="incidental-open-then-canonical-closed"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:t1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "canonical task title wins over incidental open title match" 1 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_issue_number_live_failure_fails_closed() {
	printf '\n=== fail-closed issue-number blocker resolution ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_VIEW_MODE="fail"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:#1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "issue-number live lookup failure blocks as unknown" 0 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_cached_issue_number_absence_requires_live_proof() {
	printf '\n=== cached issue-number absence live verification ===\n'
	_setup_blocked_by_resolution_test
	printf '{"built_at":"now","repos":{"owner/repo":{"open_issues":[1],"task_to_issue":{},"blocked_by":{},"defer_flags":{}}}}\n' >"$DEP_GRAPH_CACHE_FILE"
	TEST_GH_ISSUE_VIEW_MODE="fail"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:#1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "cached issue-number absence blocks when live proof fails" 0 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_lowercase_closed_issue_number_blocker_is_clear() {
	printf '\n=== lowercase closed issue-number blocker ===\n'
	_setup_blocked_by_resolution_test
	TEST_GH_ISSUE_VIEW_MODE="closed-lower"

	local rc=0
	is_blocked_by_unresolved 'blocked-by:#1000' 'owner/repo' '2000' || rc=$?
	_assert_rc "lowercase closed issue-number blocker is clear" 1 "$rc"
	_cleanup_blocked_by_resolution_test
	return 0
}

test_cache_rebuild_preserves_previous_repo_data_on_fetch_failure() {
	printf '\n=== cache rebuild fetch failure preservation ===\n'
	_setup_blocked_by_resolution_test
	DEP_GRAPH_CACHE_TTL_SECS=0
	local old_home="$HOME"
	HOME="${TEST_TMP}/home"
	mkdir -p "${HOME}/.config/aidevops"
	printf '{"initialized_repos":[{"slug":"owner/repo","pulse":true}]}\n' >"${HOME}/.config/aidevops/repos.json"
	printf '{"built_at":"old","repos":{"owner/repo":{"open_issues":[1000],"task_to_issue":{"1000":1000},"blocked_by":{},"defer_flags":{}}}}\n' >"$DEP_GRAPH_CACHE_FILE"
	TEST_GH_ISSUE_LIST_MODE="fail"

	build_dependency_graph_cache
	local preserved
	preserved=$(jq -r '.repos["owner/repo"].task_to_issue["1000"] // empty' "$DEP_GRAPH_CACHE_FILE" 2>/dev/null)
	if [[ "$preserved" == "1000" ]]; then
		_pass "failed rebuild preserves previous repo dependency data"
	else
		_fail "failed rebuild preserves previous repo dependency data" "preserved=${preserved}"
	fi
	HOME="$old_home"
	_cleanup_blocked_by_resolution_test
	return 0
}

main() {
	test_task_id_blocker_parsing
	test_issue_number_blocker_parsing
	test_dep_graph_ignores_parent_reference_on_blocked_by_line
	test_native_relationship_open_blocks_empty_body
	test_native_relationship_clear_allows_empty_body
	test_native_relationship_clear_ignores_duplicate_text_marker
	test_native_relationship_open_blocks_duplicate_text_marker
	test_native_relationship_lookup_failure_fails_closed_empty_body
	test_native_relationship_lookup_failure_checks_body_markers
	test_unknown_task_blocker_fails_closed
	test_refresh_unknown_or_malformed_task_blocker_fails_closed
	test_live_task_lookup_failure_fails_closed
	test_closed_task_blocker_is_clear
	test_lowercase_closed_task_blocker_is_clear
	test_lowercase_open_task_blocker_blocks
	test_task_lookup_excludes_current_issue_self_match
	test_task_lookup_self_only_fails_closed
	test_task_lookup_prefers_canonical_title
	test_issue_number_live_failure_fails_closed
	test_cached_issue_number_absence_requires_live_proof
	test_lowercase_closed_issue_number_blocker_is_clear
	test_cache_rebuild_preserves_previous_repo_data_on_fetch_failure

	printf '\nSummary: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
