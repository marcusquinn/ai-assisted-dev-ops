#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-issue-read-rest-fallback.sh — t2689 / GH#20309 regression guard.
#
# Asserts that `gh issue view` and `gh issue list` wrappers in shared-gh-wrappers.sh
# fall back to REST API (`gh api GET /repos/...`) when:
#   1. the primary `gh issue view` / `gh issue list` call fails, AND
#   2. `gh api rate_limit --jq .resources.graphql.remaining` returns <= 10.
#
# Context (GH#20301, 2026-04-21):
#   GraphQL quota saturated to 0/5000 for ~45 min. t2574 added REST fallback
#   for CREATE/EDIT/COMMENT paths but NOT for READ paths. During exhaustion,
#   `gh issue view` and `gh issue list` still returned non-zero exit codes.
#   Callers that treated failure as "not found" created duplicate issues.
#   t2687 (PR #20308) patched ONE call site (stats-health-dashboard.sh). This
#   task (t2689) adds framework-wide fallback so every caller benefits.
#
# Tests:
#   1. _rest_issue_view → GET /repos/.../issues/N (correct REST path)
#   2. _rest_issue_view → applies --jq expression to REST response
#   3. _rest_issue_view → accepts --json flag without error (compat, ignored)
#   4. _rest_issue_view → returns error when issue number or repo missing
#   5. _rest_issue_list → GET /repos/.../issues?state=open&per_page=N
#   6. _rest_issue_list → includes label filter in query string
#   7. _rest_issue_list → handles multiple --label flags (comma-joined)
#   8. _rest_issue_list → applies --jq expression
#   9. _rest_issue_list → filters pull requests returned by REST /issues
#  10. _rest_issue_list → includes --assignee in query string
#  11. _rest_issue_list → handles response bodies larger than ARG_MAX
#  11. _rest_issue_list → returns error when --repo is missing
#  12. gh_issue_view falls back to REST when primary fails AND GraphQL exhausted
#  13. gh_issue_view does NOT fall back when primary succeeds
#  14. gh_issue_view does NOT fall back when primary fails but GraphQL healthy
#  15. gh_issue_list falls back to REST when primary fails AND GraphQL exhausted
#  16. gh_issue_list does NOT fall back when primary succeeds
#  17. gh_issue_list does NOT fall back when primary fails but GraphQL healthy
#  18. _rest_issue_list rejects unsupported search and unknown semantic flags
#
# Stub strategy: define `gh` as a shell function. Shell functions take
# precedence over PATH binaries, so the stub captures all `gh` invocations
# without PATH mutation.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2689.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
GH_INFO_OUTPUT="${TMP}/info_output.log"

# Configurable stub behaviour per test via env vars:
#   STUB_RATE_LIMIT_REMAINING  — what gh api rate_limit returns (default: 5000)
#   STUB_PRIMARY_FAIL          — 1 to make gh issue view/list fail
#   STUB_REST_FAIL             — 1 to make gh api GET calls fail
#   STUB_VIEW_RESULT           — JSON string returned by primary gh issue view
#   STUB_LIST_RESULT           — JSON string returned by primary gh issue list
#   STUB_REST_VIEW_RESULT      — JSON string returned by REST gh api /issues/N
#   STUB_REST_LIST_RESULT      — JSON string returned by REST gh api /issues?...
# =============================================================================
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
export -f print_info print_warning print_error print_success log_verbose

export AIDEVOPS_SESSION_ORIGIN=interactive
export AIDEVOPS_SESSION_USER=testuser
export AIDEVOPS_GH_REST_FALLBACK_DISABLE_CACHE=1

stub_rest_list_result() {
	local path="$1"
	if [[ "${STUB_REST_PAGINATED:-0}" == "1" && "$path" == *"page=1" ]]; then
		jq -cn '[range(1; 101) | {number:., title:"PR", pull_request:{url:"stub"}}]'
		return 0
	fi
	if [[ "${STUB_REST_PAGINATED:-0}" == "1" ]]; then
		printf '%s\n' '[{"number":27154,"title":"Blocked issue","labels":[]}]'
		return 0
	fi
	if [[ "${STUB_REST_LARGE_BODY:-0}" == "1" ]]; then
		jq -cn '[{number:27463, title:"Large issue", body:("x" * 3000000), labels:[]}]'
		return 0
	fi
	if [[ -n "${STUB_REST_LIST_RESULT:-}" ]]; then
		printf '%s\n' "$STUB_REST_LIST_RESULT"
		return 0
	fi
	printf '%s\n' '[{"number":1,"title":"Issue one","labels":[]},{"number":2,"title":"Issue two","labels":[]}]'
	return 0
}

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

# Re-override print_* AFTER sourcing — shared-constants.sh defines its own.
# shellcheck disable=SC2317
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
export -f print_info

# Post-source stubs. Shell functions beat PATH binaries.
gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"

	# gh api rate_limit — returns configurable value
	if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
		local remaining="${STUB_RATE_LIMIT_REMAINING:-5000}"
		printf '{"resources":{"graphql":{"remaining":%s,"limit":5000,"reset":0}}}\n' "$remaining"
		return 0
	fi

	# gh api user — returns testuser
	if [[ "$1" == "api" && "$2" == "user" ]]; then
		printf 'testuser\n'
		return 0
	fi

	# gh api /repos/.../issues/N — REST issue view
	if [[ "$1" == "api" && "$2" =~ ^/repos/.+/issues/[0-9]+ && "${STUB_REST_FAIL:-0}" != "1" ]]; then
		# Apply --jq if present in args
		local _jq_expr=""
		local _i=3
		while [[ $_i -le $# ]]; do
			local _v="${!_i}"
			if [[ "$_v" == "--jq" ]]; then
				_i=$((_i + 1))
				_jq_expr="${!_i}"
				break
			fi
			_i=$((_i + 1))
		done
		local _result="${STUB_REST_VIEW_RESULT:-}"
		if [[ -z "$_result" ]]; then
			_result='{"state":"OPEN","number":42,"title":"Test issue","body":"body text","labels":[{"name":"bug"}],"assignees":[]}'
		fi
		if [[ -n "$_jq_expr" ]]; then
			printf '%s\n' "$_result" | jq -r "$_jq_expr" 2>/dev/null || return 1
		else
			printf '%s\n' "$_result"
		fi
		return 0
	fi

	# gh api /repos/.../issues?... — REST issue list
	if [[ "$1" == "api" && "$2" =~ ^/repos/.+/issues\? && "${STUB_REST_FAIL:-0}" != "1" ]]; then
		local _jq_expr=""
		local _i=3
		while [[ $_i -le $# ]]; do
			local _v="${!_i}"
			if [[ "$_v" == "--jq" ]]; then
				_i=$((_i + 1))
				_jq_expr="${!_i}"
				break
			fi
			_i=$((_i + 1))
		done
		local _result=""
		_result=$(stub_rest_list_result "$2")
		if [[ -n "$_jq_expr" ]]; then
			printf '%s\n' "$_result" | jq -r "$_jq_expr" 2>/dev/null
		else
			printf '%s\n' "$_result"
		fi
		return 0
	fi

	# gh api -X POST|PATCH ... (write REST) — for other wrappers
	if [[ "$1" == "api" && ("$2" == "-X" || "$2" =~ ^-X) ]]; then
		if [[ "${STUB_REST_FAIL:-0}" == "1" ]]; then
			printf 'REST stub forced failure\n' >&2
			return 1
		fi
		printf 'https://github.com/owner/repo/issues/9999\n'
		return 0
	fi

	# gh issue view — primary path
	if [[ "$1" == "issue" && "$2" == "view" ]]; then
		if [[ "${STUB_PRIMARY_FAIL:-0}" == "1" ]]; then
			printf 'primary stub forced failure (rate limit)\n' >&2
			return 1
		fi
		local _result="${STUB_VIEW_RESULT:-{\"state\":\"OPEN\",\"number\":42,\"title\":\"Test issue\"}}"
		printf '%s\n' "$_result"
		return 0
	fi

	# gh issue list — primary path
	if [[ "$1" == "issue" && "$2" == "list" ]]; then
		if [[ "${STUB_PRIMARY_FAIL:-0}" == "1" ]]; then
			printf 'primary stub forced failure (rate limit)\n' >&2
			return 1
		fi
		local _result="${STUB_LIST_RESULT:-[{\"number\":1,\"title\":\"Issue one\"},{\"number\":2,\"title\":\"Issue two\"}]}"
		printf '%s\n' "$_result"
		return 0
	fi

	# gh issue create/comment/edit and other calls — silent success
	return 0
}
export -f gh

printf '%sRunning gh-wrapper READ REST fallback tests (t2689 / GH#20309)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1: _rest_issue_view calls GET /repos/.../issues/N
# =============================================================================
: >"$GH_CALLS"

_rest_issue_view 42 --repo "owner/repo" >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/issues/42' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_view calls GET /repos/owner/repo/issues/42"
else
	fail "_rest_issue_view calls GET /repos/owner/repo/issues/42" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 2: _rest_issue_view applies --jq expression
# =============================================================================
: >"$GH_CALLS"
export STUB_REST_VIEW_RESULT='{"state":"OPEN","number":42,"title":"Hello world"}'

result=$(_rest_issue_view 42 --repo "owner/repo" --jq '.title' 2>/dev/null)

if [[ "$result" == "Hello world" ]]; then
	pass "_rest_issue_view applies --jq '.title' correctly"
else
	fail "_rest_issue_view applies --jq '.title' correctly" \
		"expected 'Hello world', got '${result}'"
fi
unset STUB_REST_VIEW_RESULT

# =============================================================================
# Test 3: _rest_issue_view projects supported --json fields exactly
# =============================================================================
: >"$GH_CALLS"
export STUB_REST_VIEW_RESULT='{"state":"open"}'

_result=$(_rest_issue_view 42 --repo "owner/repo" --json state 2>&1)
_rc=$?

if [[ $_rc -eq 0 ]]; then
	pass "_rest_issue_view accepts --json flag without error"
else
	fail "_rest_issue_view accepts --json flag without error" \
		"rc=${_rc} output=${_result}"
fi

export STUB_REST_VIEW_RESULT='{"node_id":"I_kwDOFixture42","number":42,"state":"open","updated_at":"2026-07-28T19:38:58Z"}'
_result=$(_rest_issue_view 42 --repo "owner/repo" --json id,number,state,updatedAt 2>/dev/null)
if jq -e '.id == "I_kwDOFixture42" and .number == 42 and .state == "OPEN" and .updatedAt == "2026-07-28T19:38:58Z"' \
	>/dev/null 2>&1 <<<"$_result"; then
	pass "_rest_issue_view maps GraphQL id exactly from REST node_id"
else
	fail "_rest_issue_view maps GraphQL id exactly from REST node_id" "output=${_result}"
fi

_result=$(_rest_issue_view 42 --repo "owner/repo" --json id --jq '.id' 2>/dev/null)
if [[ "$_result" == "I_kwDOFixture42" ]]; then
	pass "_rest_issue_view preserves scalar jq output for id"
else
	fail "_rest_issue_view preserves scalar jq output for id" "output=${_result}"
fi

export STUB_REST_VIEW_RESULT='{"node_id":null,"number":42,"state":"open"}'
_result=$(_rest_issue_view 42 --repo "owner/repo" --json id,number 2>&1)
_rc=$?
if [[ "$_rc" -ne 0 ]]; then
	pass "_rest_issue_view rejects a missing REST node_id"
else
	fail "_rest_issue_view rejects a missing REST node_id" "output=${_result}"
fi
unset STUB_REST_VIEW_RESULT

# =============================================================================
# Test 4: _rest_issue_view returns error when issue number or repo missing
# =============================================================================
_err_output=$(_rest_issue_view 42 2>&1)
_rc=$?
if [[ $_rc -ne 0 ]]; then
	pass "_rest_issue_view returns error when --repo is missing"
else
	fail "_rest_issue_view returns error when --repo is missing" \
		"expected non-zero rc but got 0"
fi

_err_output=$(_rest_issue_view --repo "owner/repo" 2>&1)
_rc=$?
if [[ $_rc -ne 0 ]]; then
	pass "_rest_issue_view returns error when issue number is missing"
else
	fail "_rest_issue_view returns error when issue number is missing" \
		"expected non-zero rc but got 0"
fi

# =============================================================================
# Test 5: _rest_issue_list builds correct query (state + per_page)
# =============================================================================
: >"$GH_CALLS"

_rest_issue_list --repo "owner/repo" --state open --limit 50 >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/issues\?state=open&per_page=50' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list builds correct query with state=open&per_page=50"
else
	fail "_rest_issue_list builds correct query with state=open&per_page=50" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 6: _rest_issue_list includes label filter in query string
# =============================================================================
: >"$GH_CALLS"

_rest_issue_list --repo "owner/repo" --state open --label "bug" >/dev/null 2>&1 || true

if grep -qE 'labels=bug' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list includes label=bug in query string"
else
	fail "_rest_issue_list includes label=bug in query string" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 7: _rest_issue_list handles multiple --label flags (comma-joined)
# =============================================================================
: >"$GH_CALLS"

_rest_issue_list --repo "owner/repo" --label "supervisor" --label "alice" >/dev/null 2>&1 || true

if grep -qE 'labels=supervisor(%2C|,)alice' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list joins multiple --label flags as comma-separated"
else
	fail "_rest_issue_list joins multiple --label flags as comma-separated" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 8: _rest_issue_list applies --jq expression
# =============================================================================
: >"$GH_CALLS"
export STUB_REST_LIST_RESULT='[{"number":7,"title":"Alpha"},{"number":8,"title":"Beta"}]'

result=$(_rest_issue_list --repo "owner/repo" --state open --jq '.[0].title' 2>/dev/null)

if [[ "$result" == "Alpha" ]]; then
	pass "_rest_issue_list applies --jq '.[0].title' correctly"
else
	fail "_rest_issue_list applies --jq '.[0].title' correctly" \
		"expected 'Alpha', got '${result}'"
fi
unset STUB_REST_LIST_RESULT

# =============================================================================
# Test 9: _rest_issue_list filters pull requests returned by REST /issues
# =============================================================================
: >"$GH_CALLS"
export STUB_REST_LIST_RESULT='[{"number":7,"title":"Issue","html_url":"https://github.com/owner/repo/issues/7"},{"number":8,"title":"PR","html_url":"https://github.com/owner/repo/pull/8","pull_request":{"url":"https://api.github.com/repos/owner/repo/pulls/8"}}]'

result=$(_rest_issue_list --repo "owner/repo" --state open --json number,title,url --jq 'map(.number) | join(",")' 2>/dev/null)

if [[ "$result" == "7" ]]; then
	pass "_rest_issue_list filters pull requests returned by REST /issues"
else
	fail "_rest_issue_list filters pull requests returned by REST /issues" \
		"expected '7', got '${result}'"
fi
unset STUB_REST_LIST_RESULT

# =============================================================================
# Test 10: _rest_issue_list paginates beyond a PR-only first REST page
# =============================================================================
: >"$GH_CALLS"
export STUB_REST_PAGINATED=1

result=$(_rest_issue_list --repo "owner/repo" --state all --limit 500 --json number --jq 'map(.number) | join(",")' 2>/dev/null)

if [[ "$result" == "27154" ]] && grep -q 'page=2' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list paginates past PR-only REST pages"
else
	fail "_rest_issue_list paginates past PR-only REST pages" \
		"expected issue 27154 from page 2; got '${result}'; calls=$(cat "$GH_CALLS")"
fi
unset STUB_REST_PAGINATED

# =============================================================================
# Test 11: _rest_issue_list handles a REST response larger than ARG_MAX
# =============================================================================
: >"$GH_CALLS"
export STUB_REST_LARGE_BODY=1

result=$(_rest_issue_list --repo "owner/repo" --state open --limit 1 --json number --jq '.[0].number' 2>/dev/null)

if [[ "$result" == "27463" ]]; then
	pass "_rest_issue_list streams large REST pages to jq without argv overflow"
else
	fail "_rest_issue_list streams large REST pages to jq without argv overflow" \
		"expected issue 27463, got '${result}'"
fi
unset STUB_REST_LARGE_BODY

# =============================================================================
# Test 12: _rest_issue_list includes --assignee in query string
# =============================================================================
: >"$GH_CALLS"

_rest_issue_list --repo "owner/repo" --state open --assignee "alice" >/dev/null 2>&1 || true

if grep -qE 'assignee=alice' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list includes assignee=alice in query string"
else
	fail "_rest_issue_list includes assignee=alice in query string" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 13: _rest_issue_list preserves author as the REST creator filter
# =============================================================================
: >"$GH_CALLS"

_rest_issue_list --repo "owner/repo" --state all --author "alice" >/dev/null 2>&1 || true

if grep -qE 'creator=alice' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list maps --author to creator"
else
	fail "_rest_issue_list maps --author to creator" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 14: _rest_issue_list resolves --author @me before REST translation
# =============================================================================
: >"$GH_CALLS"

_rest_issue_list --repo "owner/repo" --state all --author "@me" >/dev/null 2>&1 || true

if grep -qE '^api user --jq ' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'creator=testuser' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list resolves --author @me"
else
	fail "_rest_issue_list resolves --author @me" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 15: concrete bot identities remain valid author filters
# =============================================================================
: >"$GH_CALLS"

_rest_issue_list --repo "owner/repo" --state all --author "dependabot[bot]" >/dev/null 2>&1 || true

if grep -qE 'creator=dependabot%5Bbot%5D' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list preserves bot author logins"
else
	fail "_rest_issue_list preserves bot author logins" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 11: _rest_issue_list returns error when --repo is missing
# =============================================================================
_err_output=$(_rest_issue_list --state open 2>&1)
_rc=$?
if [[ $_rc -ne 0 ]]; then
	pass "_rest_issue_list returns error when --repo is missing"
else
	fail "_rest_issue_list returns error when --repo is missing" \
		"expected non-zero rc but got 0"
fi

# =============================================================================
# Test 11: gh_issue_view routes proactively when GraphQL is exhausted
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

gh_issue_view 42 --repo "owner/repo" --json state --jq '.state' >/dev/null 2>&1 || true

if grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api /repos/owner/repo/issues/42' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue view' "$GH_CALLS" 2>/dev/null &&
	grep -q 'GraphQL budget low.*issue view' "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "gh_issue_view proactively routes to REST when exhausted"
else
	fail "gh_issue_view proactively routes to REST when exhausted" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 12: gh_issue_view does NOT fall back when primary succeeds
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"

gh_issue_view 42 --repo "owner/repo" --json state >/dev/null 2>&1 || true

if grep -qE '^issue view' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/issues/42' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_view does NOT fall back when primary succeeds"
else
	fail "gh_issue_view does NOT fall back when primary succeeds" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 13: gh_issue_view does NOT fall back when primary fails but GraphQL healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=5000

gh_issue_view 42 --repo "owner/repo" --json state >/dev/null 2>&1 || true

if grep -qE '^issue view' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/issues/42' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_view does NOT fall back when primary fails but GraphQL healthy"
else
	fail "gh_issue_view does NOT fall back when primary fails but GraphQL healthy" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 14: gh_issue_list routes proactively when GraphQL is exhausted
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

gh_issue_list --repo "owner/repo" --state open --json number >/dev/null 2>&1 || true

if grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api /repos/owner/repo/issues\?' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue list' "$GH_CALLS" 2>/dev/null &&
	grep -q 'GraphQL budget low.*issue list' "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "gh_issue_list proactively routes to REST when exhausted"
else
	fail "gh_issue_list proactively routes to REST when exhausted" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 15: gh_issue_list does NOT fall back when primary succeeds
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"

gh_issue_list --repo "owner/repo" --state open >/dev/null 2>&1 || true

if grep -qE '^issue list' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/issues\?' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list does NOT fall back when primary succeeds"
else
	fail "gh_issue_list does NOT fall back when primary succeeds" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 16: gh_issue_list does NOT fall back when primary fails but GraphQL healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=5000

gh_issue_list --repo "owner/repo" --state open >/dev/null 2>&1 || true

if grep -qE '^issue list' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/issues\?' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list does NOT broaden a non-JSON primary failure"
else
	fail "gh_issue_list does NOT broaden a non-JSON primary failure" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 17: _rest_issue_list rejects search instead of silently broadening
# =============================================================================
: >"$GH_CALLS"

_result=$(_rest_issue_list --repo "owner/repo" --state open \
	--search "in:title [Supervisor:" 2>&1)
_rc=$?

if [[ $_rc -ne 0 ]] && ! grep -qE '^api /repos/.+/issues\?' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list rejects --search instead of silently dropping it"
else
	fail "_rest_issue_list rejects --search instead of silently dropping it" \
		"rc=${_rc} output=${_result}"
fi

# =============================================================================
# Test 18: _rest_issue_list rejects unknown flag-value pairs before API access
# =============================================================================
: >"$GH_CALLS"

_result=$(_rest_issue_list --repo "owner/repo" --state open \
	--milestone "future" 2>&1)
_rc=$?

if [[ $_rc -ne 0 ]] && ! grep -qE '^api /repos/.+/issues\?' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_list fails closed for unknown semantic flags"
else
	fail "_rest_issue_list fails closed for unknown semantic flags" \
		"rc=${_rc} output=${_result} calls=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 19: direct issue view rejects unknown semantic flags before API access
# =============================================================================
: >"$GH_CALLS"

_result=$(_rest_issue_view 42 --repo "owner/repo" --comments --json number 2>&1)
_rc=$?

if [[ $_rc -ne 0 ]] && ! grep -qE '^api /repos/.+/issues/42' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_view fails closed for unknown semantic flags"
else
	fail "_rest_issue_view fails closed for unknown semantic flags" \
		"rc=${_rc} output=${_result} calls=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 20: low-budget issue view keeps unsupported shapes on native GraphQL
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

unsupported_view_rc=0
gh_issue_view 42 --repo "owner/repo" --comments --json number >/dev/null 2>&1 || unsupported_view_rc=$?

if [[ "$unsupported_view_rc" -ne 0 ]] && grep -qE '^issue view' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/.+/issues/42' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_view never rewrites unsupported arguments to REST"
else
	fail "gh_issue_view never rewrites unsupported arguments to REST" \
		"rc=${unsupported_view_rc} calls=$(cat "$GH_CALLS")"
fi
unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s%d/%d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
