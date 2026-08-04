#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-wrapper-rest-fallback.sh — t2574 / GH#20243 regression guard.
#
# Asserts that `gh issue *` and `gh pr create|comment|view|list` wrappers in shared-gh-wrappers.sh
# fall back to REST API (`gh api -X POST|PATCH /repos/...`) when:
#   1. the primary `gh issue *` / `gh pr create|comment|view|list` call fails, AND
#   2. `gh api rate_limit --jq .resources.graphql.remaining` returns <= 10.
#
# Production failure (2026-04-21 ~01:00 UTC on marcusquinn/aidevops):
#   GraphQL quota saturated to 0/5000; `gh issue create|edit|comment` all
#   returned HTTP 403 "rate limit exceeded"; `gh api /repos/...` REST
#   endpoints continued to work because the core REST budget (5000/hour)
#   is separate from GraphQL. Workers had no escape hatch — interactive
#   operators pivoted manually; dispatched workers crashed at step 1.
#
# t2579 addendum: gh_create_pr also hit GraphQL exhaustion during PR creation.
# Fix (t2580): extend REST fallback to gh_create_pr via _rest_pr_create.
#
# Fix (t2574): add _rest_should_fallback + _gh_issue_*_rest helpers
# in shared-gh-wrappers-rest-fallback.sh; wrap the 4 entry points
# (gh_create_issue, gh_issue_comment, gh_issue_edit_safe, set_issue_status)
# to retry via REST when primary fails and GraphQL is exhausted.
#
# Stub strategy: define `gh` as a shell function. Shell functions take
# precedence over PATH binaries, so the stub captures all `gh` invocations
# without PATH mutation. Sub-stubs (primary-fail, rate-limit-return) are
# controlled via env vars set per-test.

set -uo pipefail

# Keep the harness hermetic: production pulse sessions may export REST-first
# routing globally, but this test enables it only in the dedicated scenarios.
unset AIDEVOPS_GH_REST_FIRST_READS
unset AIDEVOPS_GH_FORCE_REST_READS
unset AIDEVOPS_GH_PR_VIEW_CACHE
unset AIDEVOPS_GH_PR_VIEW_CACHE_DIR
unset AIDEVOPS_GH_PR_VIEW_CACHE_TTL
unset AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE
unset AIDEVOPS_GH_PR_LIST_CACHE_DIR
unset AIDEVOPS_GH_PR_LIST_CACHE_TTL
unset AIDEVOPS_GH_PR_LIST_CACHE_DISABLE
unset AIDEVOPS_GH_API_LOG

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
TMP=$(mktemp -d -t t2574.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
GH_INFO_OUTPUT="${TMP}/info_output.log"
GH_APP_TOKEN_CALLS="${TMP}/gh_app_token_calls.log"
export AIDEVOPS_GH_API_LOG="${TMP}/gh-api-calls.log"

# Configurable stub behaviour per test via env vars:
#   STUB_RATE_LIMIT_REMAINING  — what gh api rate_limit returns (default: 5000)
#   STUB_PRIMARY_FAIL          — 1 to make gh issue create/comment/edit fail
#   STUB_REST_FAIL             — 1 to make gh api -X POST|PATCH fail
# =============================================================================
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
export -f print_info print_warning print_error print_success log_verbose

export AIDEVOPS_SESSION_ORIGIN=interactive
export AIDEVOPS_SESSION_USER=testuser

# Lock fallback threshold to 10 before source so boundary tests verify
# fallback-when-remaining-≤-threshold logic, not the production default.
export AIDEVOPS_GH_REST_FALLBACK_THRESHOLD=10
export AIDEVOPS_GH_REST_FALLBACK_DISABLE_CACHE=1

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

# Re-override print_* AFTER sourcing — shared-constants.sh defines its own
# that would otherwise shadow our capturing stubs.
# shellcheck disable=SC2317
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
export -f print_info

# Keep wrapper tests inside this shell so the gh() function stub below captures
# both primary and REST paths. The production timeout helper may use an external
# timeout binary, which cannot execute shell functions.
# shellcheck disable=SC2317
_gh_with_timeout() { shift; "$@"; return $?; }
export -f _gh_with_timeout

# Post-source stubs. Shell functions beat PATH binaries.
_stub_jq_filter_arg() {
	local start_index="${1:-}"
	shift
	local args=("$@")
	local i="$start_index"
	local next=0
	while [[ $i -le ${#args[@]} ]]; do
		if [[ "${args[$((i - 1))]}" == "--jq" ]]; then
			next=$((i + 1))
			printf '%s\n' "${args[$((next - 1))]:-}"
			return 0
		fi
		i=$((i + 1))
	done
	printf '\n'
	return 0
}
_stub_gh_api_collaborator_permission() {
	local status="${STUB_COLLAB_STATUS:-200}"
	if [[ "${STUB_COLLAB_FAIL:-0}" == "1" ]]; then
		printf 'HTTP/2.0 %s Forbidden\n\n{"message":"Forbidden"}\n' "$status"
		return 1
	fi
	if [[ "$status" == "404" ]]; then
		printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
		return 1
	fi
	if [[ -n "${STUB_COLLAB_RAW_RESPONSE:-}" ]]; then
		printf '%s\n' "$STUB_COLLAB_RAW_RESPONSE"
		return 0
	fi
	if [[ -n "${STUB_COLLAB_RAW_RESPONSE_FILE:-}" ]]; then
		local raw_response_line=""
		while IFS= read -r raw_response_line || [[ -n "$raw_response_line" ]]; do
			printf '%s\n' "$raw_response_line"
		done <"$STUB_COLLAB_RAW_RESPONSE_FILE"
		return 0
	fi
	printf 'HTTP/2.0 %s OK\n\n{"permission":"%s"}\n' "$status" "${STUB_COLLAB_PERMISSION:-write}"
	return 0
}
_stub_print_fixture_with_jq() {
	local fixture="$1"
	local jq_filter="$2"
	local jq_mode="$3"
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "$fixture" | jq "$jq_mode" "$jq_filter"
		return $?
	fi
	printf '%s\n' "$fixture"
	return 0
}
_stub_gh_api_issues_list() {
	local jq_filter=""
	local fixture='[{"number":22430,"state":"open","title":"Reduce GraphQL list-call pressure","html_url":"https://github.com/owner/repo/issues/22430","updated_at":"2026-05-02T17:52:48Z","labels":[{"name":"auto-dispatch"}],"assignees":[{"login":"worker"}],"user":{"login":"maintainer"}}]'
	fixture="${STUB_ISSUE_LIST_FIXTURE:-$fixture}"
	jq_filter="$(_stub_jq_filter_arg 3 "$@")"
	_stub_print_fixture_with_jq "$fixture" "$jq_filter" -c
	return $?
}
_stub_gh_api_pr_view() {
	local jq_filter=""
	local fixture='{"number":123,"title":"stub PR"}'
	fixture="${STUB_PR_VIEW_FIXTURE:-$fixture}"
	jq_filter="$(_stub_jq_filter_arg 3 "$@")"
	_stub_print_fixture_with_jq "$fixture" "$jq_filter" -r
	return $?
}
_stub_gh_api_pr_list() {
	local path="${1:-}"
	shift
	local jq_filter=""
	local fixture='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"feature/auto-20260502-135611-gh22289"},"base":{"ref":"main"}},{"number":22343,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22343","head":{"ref":"other"},"base":{"ref":"main"}}]'
	jq_filter="$(_stub_jq_filter_arg 3 api "$path" "$@")"
	fixture="${STUB_PR_LIST_FIXTURE:-$fixture}"
	if [[ "$path" == *"head=owner%3Afeature%2Fauto-20260502-135611-gh22289"* ]]; then
		fixture='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"feature/auto-20260502-135611-gh22289"},"base":{"ref":"main"}}]'
	fi
	_stub_print_fixture_with_jq "$fixture" "$jq_filter" -c
	return $?
}
_stub_gh_api_search_issues() {
	local option="$1"
	local path="${2:-$1}"
	local fixture='{"items":[{"number":22430,"state":"open","title":"Reduce GraphQL list-call pressure"}]}'
	if [[ -n "${STUB_SEARCH_RAW_RESPONSE:-}" ]]; then
		printf '%s' "$STUB_SEARCH_RAW_RESPONSE"
		return 0
	fi
	if [[ "${STUB_SEARCH_PAGINATED:-0}" == "1" && "$path" == *"page=1" ]]; then
		fixture=$(jq -cn '{items: [range(1; 101) | {number: ., state: "open", title: "PR", user: {login: "alice"}, pull_request: {merged_at: null}}]}')
	elif [[ "${STUB_SEARCH_PAGINATED:-0}" == "1" && "$path" == *"page=2" ]]; then
		fixture=$(jq -cn '{items: [range(101; 151) | {number: ., state: "open", title: "PR", user: {login: "alice"}, pull_request: {merged_at: null}}]}')
	else
		fixture="${STUB_SEARCH_FIXTURE:-$fixture}"
	fi
	if [[ "$option" == "-i" ]]; then
		printf 'HTTP/2 200\r\nX-RateLimit-Remaining: 29\r\nX-RateLimit-Resource: search\r\nX-GitHub-Request-Id: SEARCH-REQ\r\n\r\n%s\n' "$fixture"
		return 0
	fi
	printf '%s\n' "$fixture"
	return 0
}
_stub_gh_api() {
	local subcommand="${1:-}"
	local path="${2:-}"
	local remaining="${STUB_RATE_LIMIT_REMAINING:-5000}"
	if [[ "$subcommand" == "rate_limit" ]]; then
		printf '{"resources":{"graphql":{"remaining":'
		if [[ "$remaining" =~ ^[0-9]+$ ]]; then
			printf '%s' "$remaining"
		else
			printf '"%s"' "$remaining"
		fi
		printf ',"limit":5000}}}\n'
		return 0
	fi
	if [[ "$subcommand" == "user" ]]; then
		printf 'testuser\n'
		return 0
	fi
	if [[ "$subcommand" == "-i" && "$path" =~ ^/repos/[^/]+/[^/]+/collaborators/[^/]+/permission$ ]]; then
		_stub_gh_api_collaborator_permission
		return $?
	fi
	if [[ "$subcommand" =~ ^/repos/.+/issues/[0-9]+$ ]]; then
		[[ "${STUB_ISSUE_GET_FAIL:-0}" == "1" ]] && return 1
		local jq_filter=""
		local fixture='{"number":42,"state":"open","locked":false,"labels":[{"name":"bug"}],"assignees":[]}'
		fixture="${STUB_ISSUE_VIEW_FIXTURE:-$fixture}"
		jq_filter="$(_stub_jq_filter_arg 3 api "$@")"
		_stub_print_fixture_with_jq "$fixture" "$jq_filter" -r
		return $?
	fi
	if [[ "$subcommand" =~ ^/repos/[^/]+/[^/]+/issues\? ]]; then
		_stub_gh_api_issues_list api "$@"
		return $?
	fi
	if [[ "$subcommand" =~ ^/repos/[^/]+/[^/]+/pulls/[0-9]+$ ]]; then
		_stub_gh_api_pr_view api "$@"
		return $?
	fi
	if [[ "$subcommand" =~ ^/repos/[^/]+/[^/]+/pulls\? ]]; then
		_stub_gh_api_pr_list "$subcommand" "${@:2}"
		return $?
	fi
	if [[ "$subcommand" =~ ^/search/issues || ( "$subcommand" == "-i" && "$path" =~ ^/search/issues ) ]]; then
		_stub_gh_api_search_issues "$subcommand" "$path"
		return 0
	fi
	if [[ "$subcommand" =~ ^/repos/[^/]+/[^/]+$ ]]; then
		printf '%s\n' "${STUB_REPO_DEFAULT_BRANCH:-main}"
		return 0
	fi
	if [[ "$subcommand" == "-X" || "$subcommand" =~ ^-X ]]; then
		if [[ -n "${STUB_REST_FAIL_MATCH:-}" && "$*" == *"${STUB_REST_FAIL_MATCH}"* ]]; then
			printf 'REST stub matched phase failure\n' >&2
			return 1
		fi
		if [[ "${STUB_REST_FAIL:-0}" == "1" ]]; then
			printf 'REST stub forced failure\n' >&2
			return 1
		fi
		printf 'https://github.com/owner/repo/issues/9999\n'
		return 0
	fi
	return 1
}
_stub_gh_issue() {
	local subcommand="${1:-}"
	if [[ "$subcommand" != "create" && "$subcommand" != "comment" && "$subcommand" != "edit" && "$subcommand" != "view" && "$subcommand" != "list" ]]; then
		return 1
	fi
	if [[ "${STUB_PRIMARY_FAIL:-0}" == "1" ]]; then
		printf 'primary stub forced failure (rate limit)\n' >&2
		return 1
	fi
	if [[ "$subcommand" == "create" ]]; then
		printf 'https://github.com/owner/repo/issues/9000\n'
	fi
	return 0
}
_stub_gh_pr() {
	local subcommand="${1:-}"
	if [[ "$subcommand" != "create" && "$subcommand" != "comment" && "$subcommand" != "view" && "$subcommand" != "list" ]]; then
		return 1
	fi
	if [[ "${STUB_PRIMARY_FAIL:-0}" == "1" ]]; then
		printf 'primary stub forced failure (rate limit)\n' >&2
		return 1
	fi
	if [[ "$subcommand" == "create" ]]; then
		printf 'https://github.com/owner/repo/pull/9100\n'
	elif [[ "$subcommand" == "view" ]]; then
		if [[ -n "${STUB_PR_VIEW_STDOUT+x}" ]]; then
			printf '%s' "$STUB_PR_VIEW_STDOUT"
			return 0
		fi
		printf '{"number":9101}\n'
	elif [[ "$subcommand" == "list" ]]; then
		if [[ -n "${STUB_PR_LIST_STDOUT+x}" ]]; then
			printf '%s' "$STUB_PR_LIST_STDOUT"
			return 0
		fi
		printf '[]\n'
	fi
	return 0
}
gh() {
	local command="${1:-}"
	shift || true
	printf '%s\n' "$command${*:+ $*}" >>"${GH_CALLS}"
	[[ -n "${GH_TOKEN:-}" ]] && printf '%s\n' "$GH_TOKEN" >>"${GH_APP_TOKEN_CALLS}"

	if [[ "$command" == "api" ]]; then
		_stub_gh_api "$@"
		return $?
	fi
	if [[ "$command" == "issue" ]]; then
		_stub_gh_issue "$@"
		return $?
	fi
	if [[ "$command" == "pr" ]]; then
		_stub_gh_pr "$@"
		return $?
	fi

	# gh label create / gh pr ready / other - silent success
	return 0
}
export -f gh

# Stub _rest_append_sig as a no-op to prevent gh-signature-helper.sh calls
# during tests. The helper queries the OpenCode SQLite session DB which can
# be slow or blocked when the DB is locked, causing the test to hang after
# the PR fallback cases (GH#22076). The test does not assert on signature
# footer content, so a no-op stub is safe for all existing assertions.
# shellcheck disable=SC2317
_rest_append_sig() { return 0; }
export -f _rest_append_sig

# Stub jq as a shell function so tests can toggle jq failures without hiding
# unrelated system utilities from PATH.
jq() {
	if [[ "${STUB_JQ_FAIL:-0}" == "1" ]]; then
		return 1
	fi
	command jq "$@"
	return $?
}
export -f jq

printf '%sRunning gh-wrapper REST fallback tests (t2574 / GH#20243)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1: _rest_should_fallback returns 0 (true) when remaining <= 10
# =============================================================================
STUB_RATE_LIMIT_REMAINING=0
if _rest_should_fallback; then
	pass "should_fallback returns true when remaining=0"
else
	fail "should_fallback returns true when remaining=0" \
		"expected 0 (true) but got non-zero"
fi

STUB_RATE_LIMIT_REMAINING=10
if _rest_should_fallback; then
	pass "should_fallback returns true when remaining=10 (boundary)"
else
	fail "should_fallback returns true when remaining=10 (boundary)" \
		"expected 0 (true) at boundary"
fi

# =============================================================================
# Test 2: _rest_should_fallback returns 1 (false) when remaining > 10
# =============================================================================
STUB_RATE_LIMIT_REMAINING=100
if ! _rest_should_fallback; then
	pass "should_fallback returns false when remaining=100"
else
	fail "should_fallback returns false when remaining=100" \
		"expected non-zero (false) but got 0 (true)"
fi

# =============================================================================
# Test 3: _rest_should_fallback fail-safe when rate_limit unparseable
# Stub returns non-numeric — fallback should NOT activate (fail-safe: let
# caller see original error rather than running REST call that may also fail).
# =============================================================================
STUB_RATE_LIMIT_REMAINING="unknown"
if ! _rest_should_fallback; then
	pass "should_fallback returns false when rate_limit unparseable (fail-safe)"
else
	fail "should_fallback returns false when rate_limit unparseable (fail-safe)" \
		"expected false but got true — would trigger unnecessary REST fallback"
fi

# Reset for remaining tests
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 4: _rest_issue_create → POST /repos/.../issues with correct args
# =============================================================================
: >"$GH_CALLS"
_rest_issue_create \
	--repo "owner/repo" \
	--title "t9991: test create" \
	--body "test body" \
	--label "bug,auto-dispatch" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'title=t9991: test create' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=bug' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=auto-dispatch' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_create translates to POST /repos/.../issues with labels"
else
	fail "_rest_issue_create translates to POST /repos/.../issues with labels" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 5: _rest_issue_create uses -F body=@file (for newline/unicode safety)
# =============================================================================
: >"$GH_CALLS"
_rest_issue_create \
	--repo "owner/repo" \
	--title "t9992: newline test" \
	--body "line1
line2
line3" >/dev/null 2>&1 || true

if grep -qE 'body=@/.*aidevops-gh-rest-body' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_create uses -F body=@tmpfile for body"
else
	fail "_rest_issue_create uses -F body=@tmpfile for body" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 6: _rest_issue_comment translates --body → POST .../comments
# =============================================================================
: >"$GH_CALLS"
_rest_issue_comment 12345 \
	--repo "owner/repo" \
	--body "test comment" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues/12345/comments' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_comment translates to POST /issues/N/comments"
else
	fail "_rest_issue_comment translates to POST /issues/N/comments" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 7: _rest_issue_comment extracts repo + num from a URL argument
# =============================================================================
: >"$GH_CALLS"
_rest_issue_comment "https://github.com/owner/repo/issues/777" \
	--body "url-form comment" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues/777/comments' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_comment extracts repo+num from URL"
else
	fail "_rest_issue_comment extracts repo+num from URL" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 8: mixed edits use an array-free scalar PATCH and targeted deltas.
# Unrelated metadata in the snapshot models values that concurrent writers may
# retain or add because generic edit never submits replacement arrays.
# =============================================================================
: >"$GH_CALLS"
export STUB_ISSUE_VIEW_FIXTURE='{"labels":[{"name":"bug"},{"name":"external-label"}],"assignees":[{"login":"old-worker"},{"login":"second-worker"}]}'
_rest_issue_edit 42 \
	--repo "owner/repo" \
	--title "Updated title" \
	--add-label "auto-dispatch" \
	--remove-assignee "old-worker" >/dev/null 2>&1
rest_edit_rc=$?

if [[ "$rest_edit_rc" -eq 0 ]] &&
	grep -qE '^api -X PATCH.*/issues/42.*title=Updated title' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api -X POST.*/issues/42/labels.*labels\[\]=auto-dispatch' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api -X DELETE.*/issues/42/assignees.*assignees\[\]=old-worker' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api -X PATCH.*(labels|assignees)\[\]' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api -X (POST|DELETE).*external-label|^api -X (POST|DELETE).*second-worker' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_edit preserves unrelated metadata through targeted deltas"
else
	fail "_rest_issue_edit preserves unrelated metadata through targeted deltas" \
		"rc=${rest_edit_rc}; GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_ISSUE_VIEW_FIXTURE

# =============================================================================
# Test 8a: current-state GET failure is fail-closed and emits no PATCH.
# =============================================================================
: >"$GH_CALLS"
export STUB_ISSUE_GET_FAIL=1
_rest_issue_edit 43 --repo "owner/repo" --remove-label "bug" >/dev/null 2>&1
rest_edit_rc=$?
if [[ "$rest_edit_rc" -ne 0 ]] &&
	! grep -qE '^api -X PATCH.*/repos/owner/repo/issues/43' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_edit fails closed when current-state GET fails"
else
	fail "_rest_issue_edit fails closed when current-state GET fails" \
		"rc=${rest_edit_rc}; GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_ISSUE_GET_FAIL

# =============================================================================
# Test 8b: malformed full-array state is fail-closed and emits no PATCH.
# =============================================================================
: >"$GH_CALLS"
export STUB_ISSUE_VIEW_FIXTURE='{"labels":"malformed","assignees":[]}'
_rest_issue_edit 44 --repo "owner/repo" --remove-label "bug" >/dev/null 2>&1
rest_edit_rc=$?
if [[ "$rest_edit_rc" -ne 0 ]] &&
	! grep -qE '^api -X PATCH.*/repos/owner/repo/issues/44' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_edit fails closed on malformed current arrays"
else
	fail "_rest_issue_edit fails closed on malformed current arrays" \
		"rc=${rest_edit_rc}; GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_ISSUE_VIEW_FIXTURE

# =============================================================================
# Test 8c: removing the final value uses the exact label endpoint and no PATCH.
# =============================================================================
: >"$GH_CALLS"
export STUB_ISSUE_VIEW_FIXTURE='{"labels":[{"name":"bug"}],"assignees":[]}'
_rest_issue_edit 45 --repo "owner/repo" --remove-label "bug" >/dev/null 2>&1
rest_edit_rc=$?
if [[ "$rest_edit_rc" -eq 0 ]] &&
	grep -qE '^api -X DELETE.*/repos/owner/repo/issues/45/labels/bug' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api -X PATCH.*/repos/owner/repo/issues/45' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_edit removes the final label without array replacement"
else
	fail "_rest_issue_edit removes the final label without array replacement" \
		"rc=${rest_edit_rc}; GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_ISSUE_VIEW_FIXTURE

# =============================================================================
# Test 8d: array-only no-op deltas share one GET and emit no write.
# =============================================================================
: >"$GH_CALLS"
export STUB_ISSUE_VIEW_FIXTURE='{"labels":[{"name":"bug"}],"assignees":[{"login":"old-worker"}]}'
_rest_issue_edit 46 --repo "owner/repo" \
	--add-label "bug,bug" --remove-assignee "absent-worker" >/dev/null 2>&1
rest_edit_rc=$?
issue_get_count=$(grep -c '^api /repos/owner/repo/issues/46$' "$GH_CALLS" 2>/dev/null || true)
if [[ "$rest_edit_rc" -eq 0 && "$issue_get_count" -eq 1 ]] &&
	! grep -qE '^api -X (PATCH|POST|DELETE).*/repos/owner/repo/issues/46' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_edit skips all writes for no-op array deltas"
else
	fail "_rest_issue_edit skips all writes for no-op array deltas" \
		"rc=${rest_edit_rc}; gets=${issue_get_count}; GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_ISSUE_VIEW_FIXTURE

# =============================================================================
# Test 8e: scalar-only edits remain one PATCH and skip the snapshot GET.
# =============================================================================
: >"$GH_CALLS"
_rest_issue_edit 47 --repo "owner/repo" --title "Scalar only" --state open >/dev/null 2>&1
rest_edit_rc=$?
if [[ "$rest_edit_rc" -eq 0 ]] &&
	[[ "$(grep -c '^api -X PATCH.*/repos/owner/repo/issues/47' "$GH_CALLS" 2>/dev/null || true)" -eq 1 ]] &&
	! grep -qE '^api /repos/owner/repo/issues/47$' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_edit keeps scalar-only edits to one PATCH"
else
	fail "_rest_issue_edit keeps scalar-only edits to one PATCH" \
		"rc=${rest_edit_rc}; GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 8f: scalar failure prevents all planned deltas and reports the phase.
# =============================================================================
: >"$GH_CALLS"
export STUB_ISSUE_VIEW_FIXTURE='{"labels":[],"assignees":[]}'
export STUB_REST_FAIL_MATCH='PATCH /repos/owner/repo/issues/48'
_rest_issue_edit 48 --repo "owner/repo" --title "Fails" --add-label "planned" >/dev/null 2>&1
rest_edit_rc=$?
if [[ "$rest_edit_rc" -ne 0 && "$_REST_ISSUE_EDIT_FAILURE_STAGE" == "scalar" ]] &&
	! grep -qE '^api -X POST.*/repos/owner/repo/issues/48/labels' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_edit scalar failure emits no deltas"
else
	fail "_rest_issue_edit scalar failure emits no deltas" \
		"rc=${rest_edit_rc}; stage=${_REST_ISSUE_EDIT_FAILURE_STAGE}; GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_REST_FAIL_MATCH

# =============================================================================
# Test 8g: a targeted failure after scalar success is attributable and bounded.
# =============================================================================
: >"$GH_CALLS"
export STUB_REST_FAIL_MATCH='POST /repos/owner/repo/issues/49/labels'
_rest_issue_edit 49 --repo "owner/repo" --title "Persists" \
	--add-label "fails" --add-assignee "must-not-run" >/dev/null 2>&1
rest_edit_rc=$?
if [[ "$rest_edit_rc" -ne 0 && "$_REST_ISSUE_EDIT_FAILURE_STAGE" == "delta" ]] &&
	grep -qE '^api -X PATCH.*/repos/owner/repo/issues/49.*title=Persists' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api -X POST.*/repos/owner/repo/issues/49/labels' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api -X POST.*/repos/owner/repo/issues/49/assignees' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_edit reports bounded partial delta failure"
else
	fail "_rest_issue_edit reports bounded partial delta failure" \
		"rc=${rest_edit_rc}; stage=${_REST_ISSUE_EDIT_FAILURE_STAGE}; GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_REST_FAIL_MATCH

# =============================================================================
# Test 8h: retrying an already-applied add converges without another mutation.
# =============================================================================
: >"$GH_CALLS"
export STUB_ISSUE_VIEW_FIXTURE='{"labels":[],"assignees":[]}'
_rest_issue_edit 50 --repo "owner/repo" --add-label "converged,converged" >/dev/null 2>&1
export STUB_ISSUE_VIEW_FIXTURE='{"labels":[{"name":"converged"}],"assignees":[]}'
_rest_issue_edit 50 --repo "owner/repo" --add-label "converged" >/dev/null 2>&1
mutation_count=$(grep -c '^api -X POST.*/repos/owner/repo/issues/50/labels.*labels\[\]=converged' "$GH_CALLS" 2>/dev/null || true)
if [[ "$mutation_count" -eq 1 ]]; then
	pass "_rest_issue_edit retries converge without duplicate mutations"
else
	fail "_rest_issue_edit retries converge without duplicate mutations" \
		"mutations=${mutation_count}; GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_ISSUE_VIEW_FIXTURE

# =============================================================================
# Test 9: gh_issue_comment → falls back to REST when primary fails AND exhausted
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

gh_issue_comment 5555 --repo "owner/repo" --body "fallback test" >/dev/null 2>&1 || true

# Verify: primary was called AND rate_limit was checked AND REST was called
if grep -qE '^issue comment 5555' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api.*-X POST.*/repos/owner/repo/issues/5555/comments' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_comment falls back to REST when primary fails AND exhausted"
else
	fail "gh_issue_comment falls back to REST when primary fails AND exhausted" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

if grep -qE 'GraphQL exhausted.*falling back to REST' "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "gh_issue_comment emits fallback log line"
else
	fail "gh_issue_comment emits fallback log line" \
		"INFO log: $(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 10: gh_issue_comment → does NOT fall back when primary succeeds
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
gh_issue_comment 6666 --repo "owner/repo" --body "success path" >/dev/null 2>&1 || true

if grep -qE '^issue comment 6666' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/issues/6666' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_comment does NOT fall back when primary succeeds"
else
	fail "gh_issue_comment does NOT fall back when primary succeeds" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 11: gh_issue_comment → does NOT fall back when primary fails but healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=5000

gh_issue_comment 7777 --repo "owner/repo" --body "healthy fail" >/dev/null 2>&1 || true

# Primary should fail; rate_limit checked (returns healthy); NO REST call.
if grep -qE '^issue comment 7777' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/issues/7777' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_comment does NOT fall back when primary fails but healthy"
else
	fail "gh_issue_comment does NOT fall back when primary fails but healthy" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 12: _rest_pr_create → POST /repos/.../pulls with correct args
# =============================================================================
: >"$GH_CALLS"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9993: test PR create" \
	--head "feature/t9993-test" \
	--base "main" \
	--body "PR body" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'title=t9993: test PR create' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'head=feature/t9993-test' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'base=main' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create translates to POST /repos/.../pulls with head/base/title"
else
	fail "_rest_pr_create translates to POST /repos/.../pulls with head/base/title" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 13: _rest_pr_create uses -F body=@file for body
# =============================================================================
: >"$GH_CALLS"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9994: body file test" \
	--head "feature/t9994-body" \
	--base "main" \
	--body "line1
line2
line3" >/dev/null 2>&1 || true

if grep -qE 'body=@/.*aidevops-gh-rest-body' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create uses -F body=@tmpfile for body"
else
	fail "_rest_pr_create uses -F body=@tmpfile for body" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 14: _rest_pr_create applies labels via POST /repos/.../issues/{N}/labels
# The stub returns https://github.com/owner/repo/issues/9999 for REST calls,
# so label call should target issues/9999/labels.
# =============================================================================
: >"$GH_CALLS"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9995: label test" \
	--head "feature/t9995-labels" \
	--base "main" \
	--label "origin:worker,auto-dispatch" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues/[0-9]+/labels' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=origin:worker' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=auto-dispatch' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create applies labels via POST /issues/{N}/labels"
else
	fail "_rest_pr_create applies labels via POST /issues/{N}/labels" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 14b: requested PR labels are verified after application
# =============================================================================
: >"$GH_CALLS"
export STUB_ISSUE_VIEW_FIXTURE='{"labels":[{"name":"origin:worker"},{"name":"auto-dispatch"}],"assignees":[]}'
export AIDEVOPS_GH_REST_LABEL_RETRY_DELAY=0
label_verify_stderr="${TMP}/pr-label-verify-success.stderr"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9995: verified label test" \
	--head "feature/t9995-verified-labels" \
	--base "main" \
	--label "origin:worker,auto-dispatch" >/dev/null 2>"$label_verify_stderr" || true

if grep -qE '^api /repos/owner/repo/issues/[0-9]+ --jq \.labels\[\]\.name' "$GH_CALLS" 2>/dev/null &&
	[[ ! -s "$label_verify_stderr" ]]; then
	pass "_rest_pr_create verifies requested labels after REST application"
else
	fail "_rest_pr_create verifies requested labels after REST application" \
		"GH_CALLS=$(cat "$GH_CALLS"); stderr=$(cat "$label_verify_stderr")"
fi

# =============================================================================
# Test 14c: persistent label failure does not turn an existing PR into a retry
# =============================================================================
: >"$GH_CALLS"
export STUB_REST_FAIL_MATCH='POST /repos/owner/repo/issues/9999/labels'
label_failure_stderr="${TMP}/pr-label-verify-failure.stderr"
label_failure_output=""
label_failure_rc=0
label_failure_output=$(_rest_pr_create \
	--repo "owner/repo" \
	--title "t9995: persistent label failure" \
	--head "feature/t9995-persistent-label-failure" \
	--base "main" \
	--label "origin:worker" 2>"$label_failure_stderr") || label_failure_rc=$?
pull_create_count=$(grep -cE '^api -X POST /repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null || true)
label_apply_count=$(grep -cE '^api -X POST /repos/owner/repo/issues/9999/labels' "$GH_CALLS" 2>/dev/null || true)

if [[ $label_failure_rc -eq 0 && "$label_failure_output" == "https://github.com/owner/repo/issues/9999" &&
	"$pull_create_count" -eq 1 && "$label_apply_count" -eq 3 ]] &&
	grep -q 'created PR #9999 but could not verify requested labels after bounded retries; not retrying creation' "$label_failure_stderr" 2>/dev/null; then
	pass "_rest_pr_create surfaces label failure without risking duplicate PR creation"
else
	fail "_rest_pr_create surfaces label failure without risking duplicate PR creation" \
		"rc=${label_failure_rc}; output=${label_failure_output}; pulls=${pull_create_count}; labels=${label_apply_count}; stderr=$(cat "$label_failure_stderr")"
fi
unset STUB_REST_FAIL_MATCH STUB_ISSUE_VIEW_FIXTURE AIDEVOPS_GH_REST_LABEL_RETRY_DELAY

# =============================================================================
# Test 15: gh_pr_comment → falls back to REST when primary fails AND exhausted
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

gh_pr_comment 8888 --repo "owner/repo" --body "fallback pr comment" >/dev/null 2>&1 || true

if grep -qE '^pr comment 8888' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api.*-X POST.*/repos/owner/repo/issues/8888/comments' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_comment falls back to REST when primary fails AND exhausted"
else
	fail "gh_pr_comment falls back to REST when primary fails AND exhausted" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

if grep -qE 'GraphQL exhausted.*falling back to REST' "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "gh_pr_comment emits fallback log line"
else
	fail "gh_pr_comment emits fallback log line" \
		"INFO log: $(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 16: gh_pr_comment → does NOT fall back when primary succeeds
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
gh_pr_comment 8889 --repo "owner/repo" --body "success pr comment" >/dev/null 2>&1 || true

if grep -qE '^pr comment 8889' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/issues/8889/comments' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_comment does NOT fall back when primary succeeds"
else
	fail "gh_pr_comment does NOT fall back when primary succeeds" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 17: gh_pr_comment → does NOT fall back when primary fails but healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=5000

gh_pr_comment 8890 --repo "owner/repo" --body "healthy pr fail" >/dev/null 2>&1 || true

if grep -qE '^pr comment 8890' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/issues/8890/comments' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_comment does NOT fall back when primary fails but healthy"
else
	fail "gh_pr_comment does NOT fall back when primary fails but healthy" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 18: gh_create_pr → falls back to REST when primary fails AND exhausted
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

gh_create_pr \
	--repo "owner/repo" \
	--title "t9996: fallback test" \
	--head "feature/t9996-fallback" \
	--base "main" \
	--body "fallback body" >/dev/null 2>&1 || true

# Verify: primary was called AND rate_limit was checked AND REST was called
if grep -qE '^pr create' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api.*-X POST.*/repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null; then
	pass "gh_create_pr falls back to REST when primary fails AND exhausted"
else
	fail "gh_create_pr falls back to REST when primary fails AND exhausted" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

if grep -qE 'GraphQL exhausted.*falling back to REST' "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "gh_create_pr emits fallback log line"
else
	fail "gh_create_pr emits fallback log line" \
		"INFO log: $(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 19: gh_create_pr → does NOT fall back when primary succeeds
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"

gh_create_pr \
	--repo "owner/repo" \
	--title "t9997: success test" \
	--head "feature/t9997-success" \
	--base "main" \
	--body "success body" >/dev/null 2>&1 || true

if grep -qE '^pr create' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null; then
	pass "gh_create_pr does NOT fall back when primary succeeds"
else
	fail "gh_create_pr does NOT fall back when primary succeeds" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 20: gh_create_pr → does NOT fall back when primary fails but healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=5000

gh_create_pr \
	--repo "owner/repo" \
	--title "t9998: healthy fail test" \
	--head "feature/t9998-healthy" \
	--base "main" \
	--body "healthy fail" >/dev/null 2>&1 || true

if grep -qE '^pr create' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null; then
	pass "gh_create_pr does NOT fall back when primary fails but healthy"
else
	fail "gh_create_pr does NOT fall back when primary fails but healthy" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 21: _rest_pr_create auto-detects --head from git HEAD when omitted
# Verifies that omitting --head causes the current branch to be used as head.
# =============================================================================
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
: >"$GH_CALLS"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9999: auto-head test" \
	--base "main" \
	--body "auto-detect head body" >/dev/null 2>&1 || true

if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
	pass "_rest_pr_create auto-detects --head skipped in detached HEAD rebase context"
elif [[ -n "$CURRENT_BRANCH" ]] && grep -qE "head=${CURRENT_BRANCH}" "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create auto-detects --head from git HEAD when omitted"
else
	fail "_rest_pr_create auto-detects --head from git HEAD when omitted" \
		"expected head=${CURRENT_BRANCH} in calls; GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 22: _rest_pr_create auto-detects --base from repo default_branch
# Uses STUB_REPO_DEFAULT_BRANCH=develop to verify REST resolution path.
# =============================================================================
: >"$GH_CALLS"
export STUB_REPO_DEFAULT_BRANCH="develop"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9999: auto-base test" \
	--head "feature/t9999-auto-base" \
	--body "auto-detect base body" >/dev/null 2>&1 || true

if grep -qE "base=develop" "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create auto-detects --base from repo default_branch via REST"
else
	fail "_rest_pr_create auto-detects --base from repo default_branch via REST" \
		"expected base=develop in calls; GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_REPO_DEFAULT_BRANCH

# =============================================================================
# Test 20: gh_issue_view routes directly to REST when GraphQL remaining is low
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

gh_issue_view 4242 --repo "owner/repo" --json number --jq '.number' >/dev/null 2>&1 || true

if grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api /repos/owner/repo/issues/4242' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue view 4242' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_view proactively routes to REST when GraphQL budget is low"
else
	fail "gh_issue_view proactively routes to REST when GraphQL budget is low" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# Locked is a direct REST issue field used by Pulse dispatch admission. Keep
# the full state/label/assignee view on REST instead of falling back to GraphQL.
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=5000
export AIDEVOPS_GH_REST_FIRST_READS=1
export STUB_ISSUE_VIEW_FIXTURE='{"state":"open","locked":true,"labels":[{"name":"status:available"}],"assignees":[]}'

issue_locked=$(gh_issue_view 4242 --repo "owner/repo" \
	--json state,labels,assignees,locked --jq '.locked' 2>/dev/null || true)

if [[ "$issue_locked" == "true" ]] &&
	grep -qE '^api /repos/owner/repo/issues/4242' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue view 4242' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_view preserves locked admission state through REST"
else
	fail "gh_issue_view preserves locked admission state through REST" \
		"locked=${issue_locked} GH_CALLS=$(cat "$GH_CALLS")"
fi

# Missing or malformed admission state must never be projected as unlocked.
: >"$GH_CALLS"
export STUB_ISSUE_VIEW_FIXTURE='{"state":"open","locked":null,"labels":[{"name":"status:available"}],"assignees":[]}'
issue_locked=""
issue_locked_rc=0
issue_locked=$(gh_issue_view 4242 --repo "owner/repo" \
	--json state,labels,assignees,locked --jq '.locked' 2>/dev/null) || issue_locked_rc=$?

if [[ "$issue_locked_rc" -ne 0 && -z "$issue_locked" ]] &&
	grep -qE '^api /repos/owner/repo/issues/4242' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue view 4242' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_view fails closed on malformed REST locked state"
else
	fail "gh_issue_view fails closed on malformed REST locked state" \
		"rc=${issue_locked_rc} locked=${issue_locked} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_ISSUE_VIEW_FIXTURE AIDEVOPS_GH_REST_FIRST_READS

# =============================================================================
# Test 21: gh_issue_list keeps the primary path when GraphQL is healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=5000

gh_issue_list --repo "owner/repo" --state open --json number --jq length >/dev/null 2>&1 || true

if grep -qE '^issue list' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/issues\?' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list uses primary path when GraphQL budget is healthy"
else
	fail "gh_issue_list uses primary path when GraphQL budget is healthy" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi
# =============================================================================
# Test 22: gh_issue_list preserves --search by routing low-budget calls to search
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
gh_issue_list --repo "owner/repo" --search "fallback" --state open --json number --jq '.[0].number' >/dev/null 2>&1 || true
if grep -qE '^api (-i )?/search/issues\?' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list proactively routes --search to /search/issues"
else
	fail "gh_issue_list proactively routes --search to /search/issues" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi
# Test 22a: _rest_issue_search captures headers but preserves caller output
: >"$GH_CALLS"; : >"$GH_INFO_OUTPUT"; export STUB_RATE_LIMIT_REMAINING=0
search_output=$(_rest_issue_search --repo "owner/repo" --search "fallback" --state open --json number --jq '.[0].number' 2>/dev/null || true)
if [[ "$search_output" == "22430" ]] && grep -qE '^api -i /search/issues\?' "$GH_CALLS" 2>/dev/null && ! printf '%s\n' "$search_output" | grep -qE '^(HTTP/|X-RateLimit|X-GitHub-Request-Id)'; then
	pass "_rest_issue_search includes headers for diagnostics without leaking them to callers"
else
	fail "_rest_issue_search includes headers for diagnostics without leaking them to callers" \
		"output=${search_output} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# Test 22b: _rest_issue_search returns valid JSON when the response has no body
: >"$GH_CALLS"; : >"$GH_INFO_OUTPUT"; export STUB_RATE_LIMIT_REMAINING=0
STUB_SEARCH_RAW_RESPONSE=$'HTTP/2 204\r\nX-RateLimit-Remaining: 29\r\n\r\n'
search_output=$(_rest_issue_search --repo "owner/repo" --search "fallback" --state open --json number --jq '.[0].number')
unset STUB_SEARCH_RAW_RESPONSE
if [[ "$search_output" == "null" ]] && grep -qE '^api -i /search/issues\?' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_search applies caller jq to an empty result array"
else
	fail "_rest_issue_search applies caller jq to an empty result array" \
		"output=${search_output} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 23: gh_pr_list routes directly to REST when GraphQL remaining is low
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

gh_pr_list --repo "owner/repo" --state open --json number --jq length >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^pr list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list proactively routes to REST when GraphQL budget is low"
else
	fail "gh_pr_list proactively routes to REST when GraphQL budget is low" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 23a: gh_pr_list records exact argv shape telemetry
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
export STUB_RATE_LIMIT_REMAINING=5000

gh_pr_list --repo "owner/repo" --state open --json number --limit 10 >/dev/null 2>&1 || true
gh_pr_list --repo "owner/repo" --state open --json number --limit 10 >/dev/null 2>&1 || true
gh_pr_list --repo "owner/repo" --state open --json number,title --limit 10 >/dev/null 2>&1 || true

shape_total=$(grep -c $'\tgh_pr_list_shape\t' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
shape_unique=$(grep $'\tgh_pr_list_shape\t' "$AIDEVOPS_GH_API_LOG" 2>/dev/null | cut -f6 | sort -u | wc -l | tr -d '[:space:]' || true)
if [[ "$shape_total" == "3" && "$shape_unique" == "2" ]]; then
	pass "gh_pr_list records exact argv shape telemetry for repeated-call analysis"
else
	fail "gh_pr_list records exact argv shape telemetry for repeated-call analysis" \
		"shape_total=${shape_total} shape_unique=${shape_unique} log=$(cat "$AIDEVOPS_GH_API_LOG")"
fi

# =============================================================================
# Test 23b: gh_pr_list REST fallback preserves --head and gh-shaped JSON output
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

pr_list_numbers=$(gh_pr_list --repo "owner/repo" --head "feature/auto-20260502-135611-gh22289" \
	--state all --json number,state,mergedAt,url --jq '.[].number' 2>/dev/null || true)

if [[ "$pr_list_numbers" == "22337" ]] &&
	grep -qE '^api /repos/owner/repo/pulls\?state=all&per_page=30&head=owner%3Afeature%2Fauto-20260502-135611-gh22289' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^pr list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list REST fallback preserves --head and compact --json/--jq shape"
else
	fail "gh_pr_list REST fallback preserves --head and compact --json/--jq shape" \
		"output=${pr_list_numbers} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 23c: gh_pr_list REST fallback translates --state merged to closed+merged_at
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_LIST_FIXTURE='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"open-branch"},"base":{"ref":"main"}},{"number":22338,"state":"closed","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22338","head":{"ref":"closed-branch"},"base":{"ref":"main"}},{"number":22339,"state":"closed","merged_at":"2026-05-20T00:00:00Z","html_url":"https://github.com/owner/repo/pull/22339","head":{"ref":"merged-branch"},"base":{"ref":"main"}}]'

merged_prs=$(gh_pr_list --repo "owner/repo" --state merged --json number,state,mergedAt,headRefName --jq '.' 2>/dev/null || true)
merged_count=$(printf '%s\n' "$merged_prs" | jq 'length' 2>/dev/null || printf '0')
merged_number=$(printf '%s\n' "$merged_prs" | jq -r '.[0].number // empty' 2>/dev/null || true)
merged_state=$(printf '%s\n' "$merged_prs" | jq -r '.[0].state // empty' 2>/dev/null || true)

if [[ "$merged_count" == "1" && "$merged_number" == "22339" && "$merged_state" == "MERGED" ]] &&
	grep -qE '^api /repos/owner/repo/pulls\?state=closed&per_page=30' "$GH_CALLS" 2>/dev/null &&
	! grep -qE 'state=merged' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list REST fallback maps --state merged to closed PRs filtered by merged_at"
else
	fail "gh_pr_list REST fallback maps --state merged to closed PRs filtered by merged_at" \
		"output=${merged_prs} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi
unset STUB_PR_LIST_FIXTURE

# =============================================================================
# Test 23c: gh_issue_list REST fallback preserves gh-shaped JSON output
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

issue_list_title=$(gh_issue_list --repo "owner/repo" --state open \
	--json number,title,url,assignees,labels,updatedAt --jq '.[0].title' 2>/dev/null || true)

if [[ "$issue_list_title" == "Reduce GraphQL list-call pressure" ]] &&
	grep -qE '^api /repos/owner/repo/issues\?state=open&per_page=30' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list REST fallback preserves compact --json/--jq shape"
else
	fail "gh_issue_list REST fallback preserves compact --json/--jq shape" \
		"output=${issue_list_title} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 23d: issue author filters map exactly to the REST creator parameter
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_ISSUE_LIST_FIXTURE='[{"number":22431,"state":"open","title":"Authored issue","html_url":"https://github.com/owner/repo/issues/22431","user":{"login":"alice"}}]'

issue_author=$(gh_issue_list --repo "owner/repo" --state all --author alice \
	--json number,author --jq '.[0].author.login' 2>/dev/null || true)

if [[ "$issue_author" == "alice" ]] &&
	grep -qE '^api /repos/owner/repo/issues\?state=all&per_page=30&creator=alice&page=1' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list preserves --author with REST creator filtering"
else
	fail "gh_issue_list preserves --author with REST creator filtering" \
		"output=${issue_author} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_ISSUE_LIST_FIXTURE

# =============================================================================
# Test 23e: issue author @me resolves before the creator request
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_ISSUE_LIST_FIXTURE='[{"number":22432,"state":"open","title":"Own issue","html_url":"https://github.com/owner/repo/issues/22432","user":{"login":"testuser"}}]'

issue_author=$(gh_issue_list --repo "owner/repo" --state all --author @me \
	--json number,author --jq '.[0].author.login' 2>/dev/null || true)

if [[ "$issue_author" == "testuser" ]] && grep -qE '^api user --jq ' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'creator=testuser' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list resolves --author @me before REST routing"
else
	fail "gh_issue_list resolves --author @me before REST routing" \
		"output=${issue_author} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_ISSUE_LIST_FIXTURE

# =============================================================================
# Test 23f: PR author filters route through exact Search API qualifiers
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_SEARCH_FIXTURE='{"items":[{"number":22433,"state":"closed","title":"Authored PR","html_url":"https://github.com/owner/repo/pull/22433","user":{"login":"alice"},"pull_request":{"merged_at":"2026-05-20T00:00:00Z"}}]}'

pr_author=$(gh_pr_list --repo "owner/repo" --state merged --author alice --limit 30 \
	--json number,state,author,mergedAt --jq '.[0].author.login + ":" + .[0].state' 2>/dev/null || true)

if [[ "$pr_author" == "alice:MERGED" ]] && grep -qE '^api -i /search/issues\?' "$GH_CALLS" 2>/dev/null &&
	grep -q 'author%3Aalice' "$GH_CALLS" 2>/dev/null && grep -q 'is%3Amerged' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^pr list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list preserves --author through Search API qualifiers"
else
	fail "gh_pr_list preserves --author through Search API qualifiers" \
		"output=${pr_author} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_SEARCH_FIXTURE

# =============================================================================
# Test 23g: PR author @me resolves before Search API routing
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_SEARCH_FIXTURE='{"items":[{"number":22434,"state":"open","title":"Own PR","html_url":"https://github.com/owner/repo/pull/22434","user":{"login":"testuser"},"pull_request":{"merged_at":null}}]}'

pr_author=$(gh_pr_list --repo "owner/repo" --state all --author @me --limit 30 \
	--json number,author --jq '.[0].author.login' 2>/dev/null || true)

if [[ "$pr_author" == "testuser" ]] && grep -qE '^api user --jq ' "$GH_CALLS" 2>/dev/null &&
	grep -q 'author%3Atestuser' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list resolves --author @me before Search API routing"
else
	fail "gh_pr_list resolves --author @me before Search API routing" \
		"output=${pr_author} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_SEARCH_FIXTURE

# =============================================================================
# Test 23h: PR Search pagination reaches the requested matching result count
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_SEARCH_PAGINATED=1

pr_author_count=$(_rest_pr_search --repo "owner/repo" --state all --author alice \
	--limit 150 --json number --jq 'length' 2>/dev/null || true)
pr_author_pages=$(grep -cE '^api -i /search/issues\?' "$GH_CALLS" 2>/dev/null || true)

if [[ "$pr_author_count" == "150" && "$pr_author_pages" == "2" ]]; then
	pass "_rest_pr_search paginates to the requested matching result count"
else
	fail "_rest_pr_search paginates to the requested matching result count" \
		"count=${pr_author_count} pages=${pr_author_pages} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_SEARCH_PAGINATED

# =============================================================================
# Test 23i: unsupported low-budget filters fail closed after GraphQL failure
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1

gh_issue_list --repo "owner/repo" --state open --milestone future --json number >/dev/null 2>&1
unsupported_rc=$?

if [[ "$unsupported_rc" -ne 0 ]] && grep -qE '^issue list' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api (/repos/.+/issues\?|(-i )?/search/issues\?)' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list fails closed when REST cannot preserve an unknown filter"
else
	fail "gh_issue_list fails closed when REST cannot preserve an unknown filter" \
		"rc=${unsupported_rc} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PRIMARY_FAIL

# =============================================================================
# Test 24: gh_pr_list routes --search through exact Search API semantics
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

pr_search_count=$(gh_pr_list --repo "owner/repo" --search "fallback" --state open --json number --jq length 2>/dev/null || true)

if [[ "$pr_search_count" == "1" ]] && grep -qE '^api -i /search/issues\?' "$GH_CALLS" 2>/dev/null &&
	grep -q 'fallback%20repo%3Aowner%2Frepo%20is%3Apr%20is%3Aopen' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^(pr list|api /repos/owner/repo/pulls\?)' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list preserves --search through Search API qualifiers without requiring --author"
else
	fail "gh_pr_list preserves --search through Search API qualifiers without requiring --author" \
		"count=${pr_search_count} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# Search-only PR filters must select /search/issues even without --search or
# --author; the direct /pulls endpoint cannot preserve these semantics.
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export AIDEVOPS_GH_PR_LIST_CACHE_DISABLE=1
gh_pr_list --repo "owner/repo" --assignee bob --state open --json number >/dev/null 2>&1 || true
gh_pr_list --repo "owner/repo" --label "needs review" --state open --json number >/dev/null 2>&1 || true
gh_pr_list --repo "owner/repo" --draft --state open --json number >/dev/null 2>&1 || true
search_only_calls=$(grep -cE '^api -i /search/issues\?' "$GH_CALLS" 2>/dev/null || true)
if [[ "$search_only_calls" == "3" ]] && grep -q 'assignee%3Abob' "$GH_CALLS" 2>/dev/null &&
	grep -q 'label%3A%22needs%20review%22' "$GH_CALLS" 2>/dev/null &&
	grep -q 'draft%3Atrue' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^(pr list|api /repos/owner/repo/pulls\?)' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list routes assignee, label, and draft filters through Search API"
else
	fail "gh_pr_list routes assignee, label, and draft filters through Search API" \
		"search_calls=${search_only_calls} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi
unset AIDEVOPS_GH_PR_LIST_CACHE_DISABLE

# =============================================================================
# Test 25: gh_pr_view routes directly to REST when GraphQL remaining is low
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

gh_pr_view 123 --repo "owner/repo" --json number,title --jq '.number' >/dev/null 2>&1 || true

if grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api /repos/owner/repo/pulls/123' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^pr view 123' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_view proactively routes to REST when GraphQL budget is low"
else
	fail "gh_pr_view proactively routes to REST when GraphQL budget is low" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 25a: gh_pr_view maps merged REST fields to gh-compatible JSON
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_VIEW_FIXTURE='{"number":5777,"state":"closed","merged":true,"merged_at":"2026-05-28T01:26:52Z","closed_at":"2026-05-28T01:26:52Z","merge_commit_sha":"7b5aff4a61e0df594cdee103fa651e0d1d52c3fd","merged_by":{"login":"maintainer"}}'

pr_view_merged=$(gh_pr_view 5777 --repo "owner/repo" \
	--json state,closedAt,mergedAt,mergeCommit,merged,mergedBy --jq '.' 2>/dev/null || true)
pr_view_state=$(printf '%s\n' "$pr_view_merged" | jq -r '.state // empty' 2>/dev/null || true)
pr_view_closed_at=$(printf '%s\n' "$pr_view_merged" | jq -r '.closedAt // empty' 2>/dev/null || true)
pr_view_merged_at=$(printf '%s\n' "$pr_view_merged" | jq -r '.mergedAt // empty' 2>/dev/null || true)
pr_view_merge_oid=$(printf '%s\n' "$pr_view_merged" | jq -r '.mergeCommit.oid // empty' 2>/dev/null || true)
pr_view_merged_bool=$(printf '%s\n' "$pr_view_merged" | jq -r '.merged // empty' 2>/dev/null || true)
pr_view_merged_by=$(printf '%s\n' "$pr_view_merged" | jq -r '.mergedBy.login // empty' 2>/dev/null || true)

if [[ "$pr_view_state" == "MERGED" && "$pr_view_closed_at" == "2026-05-28T01:26:52Z" && "$pr_view_merged_at" == "2026-05-28T01:26:52Z" && "$pr_view_merge_oid" == "7b5aff4a61e0df594cdee103fa651e0d1d52c3fd" && "$pr_view_merged_bool" == "true" && "$pr_view_merged_by" == "maintainer" ]]; then
	pass "gh_pr_view REST fallback maps merged fields to gh-compatible JSON"
else
	fail "gh_pr_view REST fallback maps merged fields to gh-compatible JSON" \
		"output=${pr_view_merged} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_VIEW_FIXTURE

# Exact REST-first reads can preserve the volatile mergeable enum from the
# single-PR endpoint without spending GraphQL quota.
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=5000
export AIDEVOPS_GH_REST_FIRST_READS=1
export STUB_PR_VIEW_FIXTURE='{"number":123,"mergeable":false}'

pr_view_mergeable=$(gh_pr_view 123 --repo "owner/repo" --json mergeable --jq '.mergeable' 2>/dev/null || true)

if [[ "$pr_view_mergeable" == "CONFLICTING" ]] &&
	grep -qE '^api /repos/owner/repo/pulls/123( |$)' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^pr view 123' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_view REST-first mode preserves exact mergeable state"
else
	fail "gh_pr_view REST-first mode preserves exact mergeable state" \
		"output=${pr_view_mergeable} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_VIEW_FIXTURE AIDEVOPS_GH_REST_FIRST_READS

# =============================================================================
# Test 25b: REST PR view normalizes REST boolean mergeable to gh GraphQL enum
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_VIEW_FIXTURE='{"number":123,"mergeable":true}'
export STUB_PRIMARY_FAIL=1

pr_view_mergeable=$(gh_pr_view 123 --repo "owner/repo" --json mergeable --jq '.mergeable' 2>/dev/null || true)
unset STUB_PRIMARY_FAIL

if [[ "$pr_view_mergeable" == "MERGEABLE" ]]; then
	pass "gh_pr_view REST fallback normalizes mergeable=true to MERGEABLE"
else
	fail "gh_pr_view REST fallback normalizes mergeable=true to MERGEABLE" \
		"output=${pr_view_mergeable} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_VIEW_FIXTURE

# =============================================================================
# Test 25d: REST PR view normalizes null mergeable to UNKNOWN
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_VIEW_FIXTURE='{"number":123,"mergeable":null}'
export STUB_PRIMARY_FAIL=1

pr_view_mergeable=$(gh_pr_view 123 --repo "owner/repo" --json mergeable --jq '.mergeable' 2>/dev/null || true)
unset STUB_PRIMARY_FAIL

if [[ "$pr_view_mergeable" == "UNKNOWN" ]]; then
	pass "gh_pr_view REST fallback normalizes mergeable=null to UNKNOWN"
else
	fail "gh_pr_view REST fallback normalizes mergeable=null to UNKNOWN" \
		"output=${pr_view_mergeable} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_VIEW_FIXTURE

# =============================================================================
# Test 25e: PR view cache coalesces duplicate REST reads for the same repo#PR
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"cached title","mergeable":true}'
export AIDEVOPS_GH_PR_VIEW_CACHE=1
export AIDEVOPS_GH_PR_VIEW_CACHE_DIR="${TMP}/pr_view_cache"
rm -rf "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR"

pr_view_cached_title=$(gh_pr_view 123 --repo "owner/repo" --json title --jq '.title' 2>/dev/null || true)
export STUB_PRIMARY_FAIL=1
pr_view_cached_mergeable=$(gh_pr_view 123 --repo "owner/repo" --json mergeable --jq '.mergeable' 2>/dev/null || true)
unset STUB_PRIMARY_FAIL
pr_view_rest_calls=$(grep -cE '^api /repos/owner/repo/pulls/123$' "$GH_CALLS" 2>/dev/null || true)

if [[ "$pr_view_cached_title" == "cached title" && "$pr_view_cached_mergeable" == "MERGEABLE" && "$pr_view_rest_calls" == "1" ]]; then
	pass "gh_pr_view cache coalesces duplicate REST reads for same repo#PR"
else
	fail "gh_pr_view cache coalesces duplicate REST reads for same repo#PR" \
		"title=${pr_view_cached_title} mergeable=${pr_view_cached_mergeable} rest_calls=${pr_view_rest_calls} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_VIEW_FIXTURE
unset AIDEVOPS_GH_PR_VIEW_CACHE
unset AIDEVOPS_GH_PR_VIEW_CACHE_DIR

# =============================================================================
# Test 25f: unavailable reviewDecision remains on GraphQL and fails closed
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"review state unavailable from REST"}'
export STUB_PRIMARY_FAIL=1

pr_view_review_decision_rc=0
pr_view_review_decision=$(gh_pr_view 123 --repo "owner/repo" --json reviewDecision --jq '.reviewDecision == null' 2>/dev/null) || pr_view_review_decision_rc=$?
unset STUB_PRIMARY_FAIL

if [[ "$pr_view_review_decision_rc" -ne 0 && -z "$pr_view_review_decision" ]] &&
	grep -qE '^pr view 123 .*--json reviewDecision' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/pulls/123$' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_view fails closed instead of fabricating reviewDecision"
else
	fail "gh_pr_view fails closed instead of fabricating reviewDecision" \
		"rc=${pr_view_review_decision_rc} output=${pr_view_review_decision} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_VIEW_FIXTURE

# =============================================================================
# Test 25c: mergeable stays on GraphQL because list REST omits reliable values
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_LIST_FIXTURE='[{"number":22337,"mergeable":false,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"feature/rest-mergeable"},"base":{"ref":"main"}}]'

pr_list_mergeable=$(gh_pr_list --repo "owner/repo" --state open --json mergeable --jq '.[0].mergeable' 2>/dev/null || true)

if grep -qE '^pr list .*--json mergeable' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list keeps mergeable on GraphQL instead of fabricating REST state"
else
	fail "gh_pr_list keeps mergeable on GraphQL instead of fabricating REST state" \
		"output=${pr_list_mergeable} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_LIST_FIXTURE

# =============================================================================
# Test 25e: missing REST mergeable still stays on GraphQL
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_LIST_FIXTURE='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"feature/rest-mergeable"},"base":{"ref":"main"}}]'

pr_list_mergeable=$(gh_pr_list --repo "owner/repo" --state open --json mergeable --jq '.[0].mergeable' 2>/dev/null || true)

if grep -qE '^pr list .*--json mergeable' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list does not translate unavailable mergeable fields"
else
	fail "gh_pr_list does not translate unavailable mergeable fields" \
		"output=${pr_list_mergeable} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_LIST_FIXTURE

# =============================================================================
# Test 25g: reviewDecision stays on GraphQL instead of becoming synthetic null
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_LIST_FIXTURE='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"feature/rest-review"},"base":{"ref":"main"}}]'

pr_list_review_decision=$(gh_pr_list --repo "owner/repo" --state open --json number,reviewDecision --jq '.[0].reviewDecision == null' 2>/dev/null || true)

if grep -qE '^pr list .*--json number,reviewDecision' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list keeps reviewDecision on GraphQL"
else
	fail "gh_pr_list keeps reviewDecision on GraphQL" \
		"output=${pr_list_review_decision} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_LIST_FIXTURE

# =============================================================================
# Test 26: forced REST read mode routes supported list calls without rate_limit
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=5000
export AIDEVOPS_GH_FORCE_REST_READS=1

gh_issue_list --repo "owner/repo" --state open --json number --jq length >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/issues\?' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue list' "$GH_CALLS" 2>/dev/null; then
	pass "AIDEVOPS_GH_FORCE_REST_READS routes issue list to REST without rate_limit probe"
else
	fail "AIDEVOPS_GH_FORCE_REST_READS routes issue list to REST without rate_limit probe" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi
unset AIDEVOPS_GH_FORCE_REST_READS

# =============================================================================
# Test 27: REST-first read mode shares pools without probing GraphQL budget
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=5000
export AIDEVOPS_GH_REST_FIRST_READS=1

gh_issue_list --repo "owner/repo" --state open --json number --jq length >/dev/null 2>&1 || true
gh_pr_list --repo "owner/repo" --state all --json createdAt --limit 200 >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/issues\?' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^(issue|pr) list' "$GH_CALLS" 2>/dev/null; then
	pass "AIDEVOPS_GH_REST_FIRST_READS routes REST-equivalent reads without rate_limit probe"
else
	fail "AIDEVOPS_GH_REST_FIRST_READS routes REST-equivalent reads without rate_limit probe" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
gh_pr_list --repo "owner/repo" --state open --json number,reviewDecision,headRefOid --limit 30 >/dev/null 2>&1 || true

if grep -qE '^pr list' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null; then
	pass "AIDEVOPS_GH_REST_FIRST_READS leaves GraphQL-only pr list fields on GraphQL"
else
	fail "AIDEVOPS_GH_REST_FIRST_READS leaves GraphQL-only pr list fields on GraphQL" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"rest title","state":"open"}'
export STUB_PR_VIEW_STDOUT='{"statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
mixed_split_value=$(gh_pr_view 123 --repo "owner/repo" --json title,statusCheckRollup --jq '.title + ":" + (.statusCheckRollup[0].conclusion // "")' 2>/dev/null || true)
mixed_split_rest_calls=$(grep -cE '^api /repos/owner/repo/pulls/123( |$)' "$GH_CALLS" 2>/dev/null || true)
mixed_split_gql_subset_calls=$(grep -cE '^pr view 123 --repo owner/repo --json statusCheckRollup$' "$GH_CALLS" 2>/dev/null || true)
mixed_split_full_gql_calls=$(grep -cE '^pr view 123 --repo owner/repo --json title,statusCheckRollup' "$GH_CALLS" 2>/dev/null || true)
mixed_split_records=$(grep -c $'gh_pr_view_split\tgraphql' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
if [[ "$mixed_split_value" == "rest title:SUCCESS" && "$mixed_split_rest_calls" == "1" && "$mixed_split_gql_subset_calls" == "1" && "$mixed_split_full_gql_calls" == "0" && "$mixed_split_records" == "1" ]]; then
	pass "gh_pr_view mixed REST/GQL field set fetches REST fields separately and applies jq"
else
	fail "gh_pr_view mixed REST/GQL field set fetches REST fields separately and applies jq" \
		"value=${mixed_split_value} rest=${mixed_split_rest_calls} gql_subset=${mixed_split_gql_subset_calls} gql_full=${mixed_split_full_gql_calls} split_records=${mixed_split_records} GH_CALLS=$(cat "$GH_CALLS") API_LOG=$(cat "$AIDEVOPS_GH_API_LOG")"
fi
unset STUB_PR_VIEW_FIXTURE STUB_PR_VIEW_STDOUT

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
trailing_json_args=""
trailing_json_args="$(_gh_pr_view_args_for_json_fields "number" 123 --repo "owner/repo" --json 2>"$TMP/trailing-json.err" | tr '\0' ' ')"
if [[ "$trailing_json_args" == "123 --repo owner/repo --json number " && ! -s "$TMP/trailing-json.err" ]]; then
	pass "gh_pr_view arg splitter handles trailing --json without shift error"
else
	fail "gh_pr_view arg splitter handles trailing --json without shift error" \
		"args=${trailing_json_args} stderr=$(cat "$TMP/trailing-json.err")"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
trailing_jq_args=""
trailing_jq_args="$(_gh_pr_view_args_for_json_fields "number" 123 --repo "owner/repo" --jq 2>"$TMP/trailing-jq.err" | tr '\0' ' ')"
if [[ "$trailing_jq_args" == "123 --repo owner/repo --json number " && ! -s "$TMP/trailing-jq.err" ]]; then
	pass "gh_pr_view arg splitter handles trailing --jq without shift error"
else
	fail "gh_pr_view arg splitter handles trailing --jq without shift error" \
		"args=${trailing_jq_args} stderr=$(cat "$TMP/trailing-jq.err")"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"rest title","state":"open"}'
export STUB_PR_VIEW_STDOUT=''
mixed_split_empty_gql_value=$(gh_pr_view 123 --repo "owner/repo" --json title,statusCheckRollup --jq '.title // empty' 2>/dev/null || true)
mixed_split_empty_gql_calls=$(grep -cE '^pr view 123 --repo owner/repo --json statusCheckRollup$' "$GH_CALLS" 2>/dev/null || true)
if [[ "$mixed_split_empty_gql_value" == "rest title" && "$mixed_split_empty_gql_calls" == "1" ]]; then
	pass "gh_pr_view mixed split tolerates successful empty GraphQL stdout"
else
	fail "gh_pr_view mixed split tolerates successful empty GraphQL stdout" \
		"value=${mixed_split_empty_gql_value} gql_calls=${mixed_split_empty_gql_calls} GH_CALLS=$(cat "$GH_CALLS") API_LOG=$(cat "$AIDEVOPS_GH_API_LOG")"
fi
unset STUB_PR_VIEW_FIXTURE STUB_PR_VIEW_STDOUT

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export AIDEVOPS_GH_PR_LIST_CACHE_DIR="$TMP/pr-list-cache"
export AIDEVOPS_GH_PR_LIST_CACHE_TTL=30
gh_pr_list --repo "owner/repo" --state open --json number --jq length --limit 200 >/dev/null 2>&1 || true
gh_pr_list --repo "owner/repo" --state open --json number --jq length --limit 200 >/dev/null 2>&1 || true

pr_pull_calls=$(grep -cE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null || true)
if [[ "$pr_pull_calls" == "1" ]]; then
	pass "gh_pr_list short-lived snapshot cache coalesces identical open PR reads"
else
	fail "gh_pr_list short-lived snapshot cache coalesces identical open PR reads" \
		"pull_calls=${pr_pull_calls} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi
unset AIDEVOPS_GH_PR_LIST_CACHE_DIR AIDEVOPS_GH_PR_LIST_CACHE_TTL

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
export AIDEVOPS_GH_PR_LIST_CACHE_DIR="$TMP/pr-list-repo-invalidation-cache"
export AIDEVOPS_GH_PR_LIST_CACHE_TTL=30
gh_pr_list --repo "owner/repo" --state open --json number --limit 200 >/dev/null 2>&1 || true
gh_pr_list --repo "owner/repo" --state open --json number --limit 200 >/dev/null 2>&1 || true
gh_pr_list --repo "owner/other" --state open --json number --limit 200 >/dev/null 2>&1 || true
gh_pr_list --repo "owner/other" --state open --json number --limit 200 >/dev/null 2>&1 || true
gh_pr_list_cache_invalidate_repo "owner/repo"
gh_pr_list --repo "owner/repo" --state open --json number --limit 200 >/dev/null 2>&1 || true
gh_pr_list --repo "owner/other" --state open --json number --limit 200 >/dev/null 2>&1 || true

invalidated_repo_calls=$(grep -cE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null || true)
preserved_repo_calls=$(grep -cE '^api /repos/owner/other/pulls\?' "$GH_CALLS" 2>/dev/null || true)
list_invalidation_events=$(grep -c $'gh_pr_list_cache\tother\tunknown\tother\tinvalidate' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
if [[ "$invalidated_repo_calls" == "2" && "$preserved_repo_calls" == "1" && "$list_invalidation_events" == "1" ]]; then
	pass "gh_pr_list repo invalidation evicts only the mutated repository"
else
	fail "gh_pr_list repo invalidation evicts only the mutated repository" \
		"invalidated_repo_calls=${invalidated_repo_calls} preserved_repo_calls=${preserved_repo_calls} invalidations=${list_invalidation_events} GH_CALLS=$(cat "$GH_CALLS") API_LOG=$(cat "$AIDEVOPS_GH_API_LOG")"
fi
unset AIDEVOPS_GH_PR_LIST_CACHE_DIR AIDEVOPS_GH_PR_LIST_CACHE_TTL

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
unset AIDEVOPS_GH_REST_FIRST_READS
export AIDEVOPS_GH_PR_LIST_CACHE_DIR="$TMP/pr-list-empty-cache"
export AIDEVOPS_GH_PR_LIST_CACHE_TTL=30
export STUB_PR_LIST_STDOUT=""
empty_list_first=$(gh_pr_list --repo "owner/repo" --state open --json number --jq '.[].number // empty' --limit 200 2>/dev/null || true)
empty_list_second=$(gh_pr_list --repo "owner/repo" --state open --json number --jq '.[].number // empty' --limit 200 2>/dev/null || true)
empty_pr_list_calls=$(grep -cE '^pr list --repo owner/repo --state open --json number --jq' "$GH_CALLS" 2>/dev/null || true)
empty_cache_hits=$(grep -c $'gh_pr_list_cache\tother\tunknown\tother\thit' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
empty_cache_stores=$(grep -c $'gh_pr_list_cache\tother\tunknown\tother\tstore' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
if [[ -z "${empty_list_first}${empty_list_second}" && "$empty_pr_list_calls" == "1" && "$empty_cache_hits" == "1" && "$empty_cache_stores" == "1" ]]; then
	pass "gh_pr_list snapshot cache treats successful empty stdout as a valid hit"
else
	fail "gh_pr_list snapshot cache treats successful empty stdout as a valid hit" \
		"first=${empty_list_first} second=${empty_list_second} calls=${empty_pr_list_calls} hits=${empty_cache_hits} stores=${empty_cache_stores} GH_CALLS=$(cat "$GH_CALLS") API_LOG=$(cat "$AIDEVOPS_GH_API_LOG")"
fi
unset AIDEVOPS_GH_PR_LIST_CACHE_DIR AIDEVOPS_GH_PR_LIST_CACHE_TTL STUB_PR_LIST_STDOUT
export AIDEVOPS_GH_REST_FIRST_READS=1

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
export AIDEVOPS_GH_PR_VIEW_CACHE=1
export AIDEVOPS_GH_PR_VIEW_CACHE_DIR="$TMP/pr-view-cache"
export AIDEVOPS_GH_PR_VIEW_CACHE_TTL=30
gh_pr_view 123 --repo "owner/repo" --json statusCheckRollup --jq '.number // 0' >/dev/null 2>&1 || true
gh_pr_view 123 --repo "owner/repo" --json statusCheckRollup --jq '.number // 0' >/dev/null 2>&1 || true

pr_view_calls=$(grep -cE '^pr view 123 --repo owner/repo --json statusCheckRollup' "$GH_CALLS" 2>/dev/null || true)

exact_cache_misses=$(grep -c $'gh_pr_view_cache\tother\tunknown\tother\tmiss' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
exact_cache_hits=$(grep -c $'gh_pr_view_cache\tother\tunknown\tother\thit' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
exact_cache_stores=$(grep -c $'gh_pr_view_cache\tother\tunknown\tother\tstore' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
if [[ "$pr_view_calls" == "1" && "$exact_cache_misses" == "1" && "$exact_cache_hits" == "1" && "$exact_cache_stores" == "1" ]]; then
	pass "gh_pr_view exact-output cache coalesces identical GraphQL-only PR reads"
else
	fail "gh_pr_view exact-output cache coalesces identical GraphQL-only PR reads" \
		"pr_view_calls=${pr_view_calls} miss=${exact_cache_misses} hit=${exact_cache_hits} store=${exact_cache_stores} GH_CALLS=$(cat "$GH_CALLS") API_LOG=$(cat "$AIDEVOPS_GH_API_LOG") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi
unset AIDEVOPS_GH_PR_VIEW_CACHE AIDEVOPS_GH_PR_VIEW_CACHE_DIR AIDEVOPS_GH_PR_VIEW_CACHE_TTL

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
export STUB_RATE_LIMIT_REMAINING=0
export AIDEVOPS_GH_PR_VIEW_CACHE=1
export AIDEVOPS_GH_PR_VIEW_CACHE_DIR="$TMP/rest-pr-view-cache"
export AIDEVOPS_GH_PR_VIEW_CACHE_TTL=30
rm -rf "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR"
_rest_pr_view 123 --repo "owner/repo" --json title --jq '.title' >/dev/null 2>&1 || true
_rest_pr_view 123 --repo "owner/repo" --json title --jq '.title' >/dev/null 2>&1 || true

rest_pr_view_calls=$(grep -cE '^api /repos/owner/repo/pulls/123( |$)' "$GH_CALLS" 2>/dev/null || true)
rest_cache_misses=$(grep -c $'rest_pr_view_cache\tother\tunknown\tother\tmiss' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
rest_cache_hits=$(grep -c $'rest_pr_view_cache\tother\tunknown\tother\thit' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
rest_cache_stores=$(grep -c $'rest_pr_view_cache\tother\tunknown\tother\tstore' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
if [[ "$rest_pr_view_calls" == "1" && "$rest_cache_misses" == "1" && "$rest_cache_hits" == "1" && "$rest_cache_stores" == "1" ]]; then
	pass "_rest_pr_view repo#PR cache records miss/store/hit for duplicate reads"
else
	fail "_rest_pr_view repo#PR cache records miss/store/hit for duplicate reads" \
		"calls=${rest_pr_view_calls} miss=${rest_cache_misses} hit=${rest_cache_hits} store=${rest_cache_stores} GH_CALLS=$(cat "$GH_CALLS") API_LOG=$(cat "$AIDEVOPS_GH_API_LOG")"
fi
diag_output=$(PULSE_DIAGNOSE_GH_API_LOG="$AIDEVOPS_GH_API_LOG" \
	PULSE_DIAGNOSE_STATS_FILE="$TMP/pulse-stats.json" \
	PULSE_DIAGNOSE_LOGFILE="$TMP/pulse.log" \
	AIDEVOPS_GH_PR_VIEW_CACHE_DIR="$AIDEVOPS_GH_PR_VIEW_CACHE_DIR" \
	"${SCRIPTS_DIR}/pulse-diagnose-helper.sh" api-budget --json 2>/dev/null || true)
if printf '%s' "$diag_output" | grep -q 'rest_pr_view_repo_cache' &&
	printf '%s' "$diag_output" | grep -q 'hit=1 miss=1' &&
	! printf '%s' "$diag_output" | grep -q 'owner/repo' &&
	! printf '%s' "$diag_output" | grep -q "$TMP"; then
	pass "pulse-diagnose api-budget reports sanitized PR view cache counters"
else
	fail "pulse-diagnose api-budget reports sanitized PR view cache counters" \
		"diag=${diag_output}"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
export STUB_RATE_LIMIT_REMAINING=0
export AIDEVOPS_GH_PR_VIEW_CACHE=1
export AIDEVOPS_GH_PR_VIEW_CACHE_DIR="$TMP/rest-pr-view-stale-cache"
export AIDEVOPS_GH_PR_VIEW_CACHE_TTL=1
rm -rf "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR"
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"stale first"}'
_rest_pr_view 123 --repo "owner/repo" --json title --jq '.title' >/dev/null 2>&1 || true
cache_file="$AIDEVOPS_GH_PR_VIEW_CACHE_DIR/owner_repo__123.json"
perl -e 'utime(time - 5, time - 5, @ARGV)' "$cache_file" 2>/dev/null || true
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"fresh second"}'
rest_stale_title=$(_rest_pr_view 123 --repo "owner/repo" --json title --jq '.title' 2>/dev/null || true)
rest_stale_calls=$(grep -cE '^api /repos/owner/repo/pulls/123( |$)' "$GH_CALLS" 2>/dev/null || true)
rest_cache_stales=$(grep -c $'rest_pr_view_cache\tother\tunknown\tother\tstale' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
if [[ "$rest_stale_title" == "fresh second" && "$rest_stale_calls" == "2" && "$rest_cache_stales" == "1" ]]; then
	pass "_rest_pr_view repo#PR cache refetches stale persistent entries"
else
	fail "_rest_pr_view repo#PR cache refetches stale persistent entries" \
		"title=${rest_stale_title} calls=${rest_stale_calls} stale=${rest_cache_stales} GH_CALLS=$(cat "$GH_CALLS") API_LOG=$(cat "$AIDEVOPS_GH_API_LOG")"
fi
unset STUB_PR_VIEW_FIXTURE
unset AIDEVOPS_GH_PR_VIEW_CACHE AIDEVOPS_GH_PR_VIEW_CACHE_DIR AIDEVOPS_GH_PR_VIEW_CACHE_TTL

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
unsupported_pr_view_fields=(authorAssociation statusCheckRollup reviews latestReviews reviewThreads commits files reviewDecision autoMergeRequest mergeStateStatus)
unsupported_preserve_ok=1
for field in "${unsupported_pr_view_fields[@]}"; do
	if _rest_pr_view_can_preserve_args 123 --repo "owner/repo" --json "$field"; then
		unsupported_preserve_ok=0
	fi
	gh_pr_view 123 --repo "owner/repo" --json "$field" >/dev/null 2>&1 || true
done

unsupported_rest_calls=$(grep -cE '^api /repos/owner/repo/pulls/123$' "$GH_CALLS" 2>/dev/null || true)
unsupported_graphql_calls=$(grep -cE '^pr view 123 --repo owner/repo --json ' "$GH_CALLS" 2>/dev/null || true)
if [[ "$unsupported_preserve_ok" == "1" && "$unsupported_rest_calls" == "0" && "$unsupported_graphql_calls" == "${#unsupported_pr_view_fields[@]}" ]]; then
	pass "gh_pr_view freshness classes keep GraphQL-only fields off REST reuse"
else
	fail "gh_pr_view freshness classes keep GraphQL-only fields off REST reuse" \
		"preserve_ok=${unsupported_preserve_ok} rest_calls=${unsupported_rest_calls} graphql_calls=${unsupported_graphql_calls} GH_CALLS=$(cat "$GH_CALLS")"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PRIMARY_FAIL=1
export AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1
unsupported_fallback_output=""
unsupported_fallback_rc=0
unsupported_fallback_output=$(gh_pr_view 123 --repo "owner/repo" --json reviews 2>/dev/null) || unsupported_fallback_rc=$?
unset STUB_PRIMARY_FAIL AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE
export STUB_RATE_LIMIT_REMAINING=5000

unsupported_fallback_rest_calls=$(grep -cE '^api /repos/owner/repo/pulls/123$' "$GH_CALLS" 2>/dev/null || true)
unsupported_fallback_graphql_calls=$(grep -cE '^pr view 123 --repo owner/repo --json reviews$' "$GH_CALLS" 2>/dev/null || true)
if [[ "$unsupported_fallback_rc" -ne 0 && -z "$unsupported_fallback_output" && "$unsupported_fallback_rest_calls" == "0" && "$unsupported_fallback_graphql_calls" == "1" ]]; then
	pass "gh_pr_view exhaustion preserves failure for GraphQL-only fields"
else
	fail "gh_pr_view exhaustion preserves failure for GraphQL-only fields" \
		"rc=${unsupported_fallback_rc} output=${unsupported_fallback_output} rest_calls=${unsupported_fallback_rest_calls} graphql_calls=${unsupported_fallback_graphql_calls} GH_CALLS=$(cat "$GH_CALLS")"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PRIMARY_FAIL=1
unsupported_view_arg_rc=0
gh_pr_view 123 --repo "owner/repo" --web --json number >/dev/null 2>&1 || unsupported_view_arg_rc=$?
unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

if [[ "$unsupported_view_arg_rc" -ne 0 ]] &&
	grep -qE '^pr view 123 .*--web --json number' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/pulls/123$' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_view never rewrites unknown semantic flags to REST"
else
	fail "gh_pr_view never rewrites unknown semantic flags to REST" \
		"rc=${unsupported_view_arg_rc} GH_CALLS=$(cat "$GH_CALLS")"
fi

if _rest_pr_view_can_preserve_args 123 --repo "owner/repo" --json title &&
	_rest_pr_view_can_preserve_args 123 --repo "owner/repo" --json labels,author &&
	_rest_pr_view_can_preserve_args 123 --repo "owner/repo" --json mergeable &&
	_rest_pr_view_can_emergency_fallback_args 123 --repo "owner/repo" --json mergeable &&
	! _rest_pr_view_can_preserve_args 123 --repo "owner/repo" --json labels,author,authorAssociation &&
	! _rest_pr_view_can_emergency_fallback_args 123 --repo "owner/repo" --json reviewDecision; then
	pass "gh_pr_view validators preserve labels,author and reject GraphQL-only fields"
else
	fail "gh_pr_view validators preserve labels,author and reject GraphQL-only fields" \
		"unexpected proactive or emergency field classification"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
export STUB_RATE_LIMIT_REMAINING=0
export AIDEVOPS_GH_PR_VIEW_CACHE=1
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"uncached title"}'
export STUB_JQ_FAIL=1
pr_view_uncached_json=$(_rest_pr_view 123 --repo "owner/repo" || true)
unset STUB_JQ_FAIL
rest_cache_bypasses=$(grep -c $'rest_pr_view_cache\tother\tunknown\tother\tbypass' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
rest_cache_disabled_bypasses=$(grep -c $'rest_pr_view_cache\tother\tunknown\tother\tbypass-disabled' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
if [[ "$pr_view_uncached_json" == *'"uncached title"'* && "$rest_cache_bypasses" == "1" && "$rest_cache_disabled_bypasses" == "0" ]]; then
	pass "AIDEVOPS_GH_PR_VIEW_CACHE unavailable prerequisites record non-disabled REST bypass"
else
	fail "AIDEVOPS_GH_PR_VIEW_CACHE unavailable prerequisites record non-disabled REST bypass" \
		"json=${pr_view_uncached_json} bypass=${rest_cache_bypasses} disabled=${rest_cache_disabled_bypasses} API_LOG=$(cat "$AIDEVOPS_GH_API_LOG")"
fi
unset STUB_PR_VIEW_FIXTURE
unset AIDEVOPS_GH_PR_VIEW_CACHE

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$AIDEVOPS_GH_API_LOG"
export STUB_RATE_LIMIT_REMAINING=0
export AIDEVOPS_GH_PR_VIEW_CACHE=1
export AIDEVOPS_GH_PR_VIEW_CACHE_DIR="$TMP/pr-view-disable-cache"
export AIDEVOPS_GH_PR_VIEW_CACHE_TTL=30
rm -rf "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR"
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"stale title"}'
pr_view_stale_title=$(gh_pr_view 123 --repo "owner/repo" --json title --jq '.title' 2>/dev/null || true)
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"fresh title"}'
pr_view_fresh_title=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh_pr_view 123 --repo "owner/repo" --json title --jq '.title' 2>/dev/null || true)
pr_view_disable_calls=$(grep -cE '^api /repos/owner/repo/pulls/123( |$)' "$GH_CALLS" 2>/dev/null || true)
exact_cache_disabled_bypasses=$(grep -c $'gh_pr_view_cache\tother\tunknown\tother\tbypass-disabled' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
rest_cache_disabled_bypasses=$(grep -c $'rest_pr_view_cache\tother\tunknown\tother\tbypass-disabled' "$AIDEVOPS_GH_API_LOG" 2>/dev/null || true)
if [[ "$pr_view_stale_title" == "stale title" && "$pr_view_fresh_title" == "fresh title" && "$pr_view_disable_calls" == "2" && "$exact_cache_disabled_bypasses" == "1" && "$rest_cache_disabled_bypasses" == "1" ]]; then
	pass "AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE bypasses exact-output and REST-object PR view caches"
else
	fail "AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE bypasses exact-output and REST-object PR view caches" \
		"stale=${pr_view_stale_title} fresh=${pr_view_fresh_title} calls=${pr_view_disable_calls} exact_disabled=${exact_cache_disabled_bypasses} rest_disabled=${rest_cache_disabled_bypasses} GH_CALLS=$(cat "$GH_CALLS") API_LOG=$(cat "$AIDEVOPS_GH_API_LOG")"
fi
unset STUB_PR_VIEW_FIXTURE
unset AIDEVOPS_GH_PR_VIEW_CACHE AIDEVOPS_GH_PR_VIEW_CACHE_DIR AIDEVOPS_GH_PR_VIEW_CACHE_TTL

unset AIDEVOPS_GH_REST_FIRST_READS

# =============================================================================
# Test 28: gh_pr_list combines caller search and exact filter qualifiers
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_SEARCH_FIXTURE='{"items":[{"number":42,"state":"open","title":"Matching draft PR","html_url":"https://github.com/owner/repo/pull/42","draft":true,"assignees":[{"login":"bob"}],"labels":[{"name":"needs review"}],"pull_request":{"merged_at":null}}]}'

filtered_pr_number=$(gh_pr_list --repo "owner/repo" --state open --search "Resolves #42 in:body" \
	--assignee bob --label "needs review" --draft --json number --limit 5 --jq '.[0].number' 2>/dev/null || true)

if [[ "$filtered_pr_number" == "42" ]] && grep -qE '^api -i /search/issues\?' "$GH_CALLS" 2>/dev/null &&
	grep -q 'Resolves%20%2342%20in%3Abody' "$GH_CALLS" 2>/dev/null &&
	grep -q 'assignee%3Abob' "$GH_CALLS" 2>/dev/null && grep -q 'draft%3Atrue' "$GH_CALLS" 2>/dev/null &&
	grep -q 'label%3A%22needs%20review%22' "$GH_CALLS" 2>/dev/null &&
	! grep -q 'author%3A' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^(pr list|api /repos/owner/repo/pulls)' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list combines caller search and exact filters without an author qualifier"
else
	fail "gh_pr_list combines caller search and exact filters without an author qualifier" \
		"number=${filtered_pr_number} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_SEARCH_FIXTURE
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 27: GitHub App auth routes REST-equivalent reads through app token
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$GH_APP_TOKEN_CALLS"
export AIDEVOPS_GITHUB_APP_CACHE_DIR="$TMP/app-cache"
export AIDEVOPS_GITHUB_APP_ENABLED=1
export AIDEVOPS_GITHUB_APP_ID=123
export AIDEVOPS_GITHUB_APP_INSTALLATION_ID=456
export AIDEVOPS_GITHUB_APP_REST_FIRST=1
_github_app_cache_token "456" "cached-app-token" "2099-01-01T00:00:00Z"

gh_issue_view 4243 --repo "owner/repo" --json number --jq '.number' >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/issues/4243' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue view 4243' "$GH_CALLS" 2>/dev/null &&
	grep -q 'cached-app-token' "$GH_APP_TOKEN_CALLS" 2>/dev/null; then
	pass "GitHub App auth routes REST-equivalent issue view through app token"
else
	fail "GitHub App auth routes REST-equivalent issue view through app token" \
		"GH_CALLS=$(cat "$GH_CALLS") | TOKENS=$(cat "$GH_APP_TOKEN_CALLS")"
fi

: >"$GH_CALLS"
: >"$GH_APP_TOKEN_CALLS"
export STUB_COLLAB_PERMISSION=write
collab_perm=""
_gh_collaborator_permission_lookup "owner/repo" "testuser" collab_perm 2>/dev/null || true
if [[ "$collab_perm" == "write" ]] &&
	grep -qE '^api -i /repos/owner/repo/collaborators/testuser/permission' "$GH_CALLS" 2>/dev/null &&
	grep -q 'cached-app-token' "$GH_APP_TOKEN_CALLS" 2>/dev/null; then
	pass "collaborator permission lookup uses GitHub App REST route when available"
else
	fail "collaborator permission lookup uses GitHub App REST route when available" \
		"perm=${collab_perm} GH_CALLS=$(cat "$GH_CALLS") | TOKENS=$(cat "$GH_APP_TOKEN_CALLS")"
fi

unset AIDEVOPS_GITHUB_APP_ENABLED AIDEVOPS_GITHUB_APP_ID AIDEVOPS_GITHUB_APP_INSTALLATION_ID AIDEVOPS_GITHUB_APP_REST_FIRST

: >"$GH_CALLS"
: >"$GH_APP_TOKEN_CALLS"
collab_perm=""
_gh_collaborator_permission_lookup "owner/repo" "testuser" collab_perm 2>/dev/null || true
if [[ "$collab_perm" == "write" ]] &&
	grep -qE '^api -i /repos/owner/repo/collaborators/testuser/permission' "$GH_CALLS" 2>/dev/null &&
	! grep -q 'cached-app-token' "$GH_APP_TOKEN_CALLS" 2>/dev/null; then
	pass "collaborator permission lookup falls back to normal gh auth when App auth is unavailable"
else
	fail "collaborator permission lookup falls back to normal gh auth when App auth is unavailable" \
		"perm=${collab_perm} GH_CALLS=$(cat "$GH_CALLS") | TOKENS=$(cat "$GH_APP_TOKEN_CALLS")"
fi

export STUB_COLLAB_PERMISSION=triage
collab_perm=""
_gh_collaborator_permission_lookup "owner/repo" "testuser" collab_perm 2>/dev/null || true
if [[ "$collab_perm" == "triage" && "${AIDEVOPS_GH_COLLAB_PERMISSION_REASON:-}" == "ok" ]]; then
	pass "collaborator permission lookup accepts triage role"
else
	fail "collaborator permission lookup accepts triage role" \
		"perm=${collab_perm} reason=${AIDEVOPS_GH_COLLAB_PERMISSION_REASON:-unset}"
fi
export STUB_COLLAB_PERMISSION=write

export STUB_COLLAB_STATUS=404
collab_perm=""
_gh_collaborator_permission_lookup "owner/repo" "outsider" collab_perm 2>/dev/null || true
if [[ "$collab_perm" == "none" && "${AIDEVOPS_GH_COLLAB_PERMISSION_HTTP:-}" == "404" ]]; then
	pass "collaborator permission lookup maps 404 to confirmed none"
else
	fail "collaborator permission lookup maps 404 to confirmed none" \
		"perm=${collab_perm} http=${AIDEVOPS_GH_COLLAB_PERMISSION_HTTP:-unset} reason=${AIDEVOPS_GH_COLLAB_PERMISSION_REASON:-unset}"
fi

export STUB_COLLAB_STATUS=403
export STUB_COLLAB_FAIL=1
if ! _gh_collaborator_permission_lookup "owner/repo" "testuser" >/dev/null 2>&1 &&
	[[ "${AIDEVOPS_GH_COLLAB_PERMISSION_HTTP:-}" == "403" && "${AIDEVOPS_GH_COLLAB_PERMISSION_REASON:-}" == "api-failure" ]]; then
	pass "collaborator permission lookup keeps API failure distinct from none"
else
	fail "collaborator permission lookup keeps API failure distinct from none" \
		"http=${AIDEVOPS_GH_COLLAB_PERMISSION_HTTP:-unset} reason=${AIDEVOPS_GH_COLLAB_PERMISSION_REASON:-unset}"
fi
unset STUB_COLLAB_STATUS STUB_COLLAB_FAIL STUB_COLLAB_PERMISSION

STUB_COLLAB_RAW_RESPONSE_FILE="${TMP}/collab-spoof-response.txt"
printf '%s\n' 'HTTP/2.0 200 OK' '' '  "bio":"crafted \"permission\": \"admin\""' '  "permission":"write"' >"$STUB_COLLAB_RAW_RESPONSE_FILE"
export STUB_COLLAB_RAW_RESPONSE_FILE
collab_perm=""
_gh_collaborator_permission_lookup "owner/repo" "testuser" collab_perm 2>/dev/null || true
if [[ "$collab_perm" == "write" ]]; then
	pass "collaborator permission fallback parser ignores nested spoof fields"
else
	fail "collaborator permission fallback parser ignores nested spoof fields" \
		"perm=${collab_perm} reason=${AIDEVOPS_GH_COLLAB_PERMISSION_REASON:-unset}"
fi
unset STUB_COLLAB_RAW_RESPONSE_FILE

# =============================================================================
# Test 39: _rest_split_csv suppresses early-close Broken pipe noise
# =============================================================================
long_csv=""
for i in $(seq 1 5000); do
	if [[ -z "$long_csv" ]]; then
		long_csv="token-${i}"
	else
		long_csv="${long_csv},token-${i}"
	fi
done

early_close_output=""
early_close_stderr=$({
	early_close_output=$(_rest_split_csv "$long_csv" | {
		IFS= read -r first_token || true
		printf '%s\n' "$first_token"
	})
	printf '%s\n' "$early_close_output" >"$TMP/early-close-output.log"
} 2>&1)

if [[ "$(cat "$TMP/early-close-output.log")" == "token-1" && "$early_close_stderr" != *"Broken pipe"* ]]; then
	pass "_rest_split_csv suppresses Broken pipe noise when consumers close early"
else
	fail "_rest_split_csv suppresses Broken pipe noise when consumers close early" \
		"stdout=$(cat "$TMP/early-close-output.log") stderr=${early_close_stderr}"
fi

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
