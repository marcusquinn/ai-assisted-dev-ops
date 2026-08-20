#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-consolidation-dispatch.sh — regression tests for t1982
#
# Covers the fix for the half-built consolidation flow:
#   1. _dispatch_issue_consolidation creates a self-contained child issue
#   2. Child body contains parent title, body, and substantive comments inline
#   3. Child body includes a @-mention cc line for all unique comment authors
#   4. Dedup: calling twice on the same parent does not create a second child
#   5. _issue_needs_consolidation returns 1 when a child already exists
#   6. _consolidation_child_exists correctly detects existing children
#
# Strategy: source pulse-triage.sh with a stubbed `gh` binary on PATH that
# records every invocation and returns canned responses driven by the test.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${TEST_SCRIPT_DIR}/../../.." && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

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

# _write_gh_stub_binary: write the stubbed gh binary to TEST_ROOT/bin/gh.
# Requires TEST_ROOT to be set. Called by setup_gh_stub.
_write_gh_stub_binary() {
	if [[ -z "${TEST_ROOT:-}" ]]; then
		printf 'Error: TEST_ROOT is not set\n' >&2
		return 1
	fi
	mkdir -p "${TEST_ROOT}/bin"
	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal `gh` stub for consolidation tests.
# Records the call line and returns canned output.
# bash 3.2 compatible — no ;;& fall-through.
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

# _stub_parse_args: scan argv for `--jq <filter>` and `--state <state>`,
# emit them on stdout as `JQ=<f>;STATE=<s>` so the caller can eval. Empty
# values when absent. Used by the issue-list and pr-list branches.
_stub_parse_args() {
	local prev="" jq="" state="open" arg
	for arg in "$@"; do
		[[ "$prev" == "--jq" ]] && jq="$arg"
		[[ "$prev" == "--state" ]] && state="$arg"
		prev="$arg"
	done
	printf 'JQ=%s\nSTATE=%s\n' "$jq" "$state"
	return 0
}

# _stub_emit: print $1 raw or piped through `jq -r $2` if filter non-empty.
_stub_emit() {
	if [[ -n "$2" ]]; then printf '%s\n' "$1" | jq -r "$2"; else printf '%s\n' "$1"; fi
	return 0
}

case "${1:-}-${2:-}" in
issue-view)
	shift 2
	local_json=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json) local_json="$2"; shift 2 ;;
		--jq) shift 2 ;;
		*) shift ;;
		esac
	done
	case "$local_json" in
	title) printf '%s\n' "${GH_ISSUE_VIEW_TITLE:-Parent Title}" ;;
	body) printf '%s\n' "${GH_ISSUE_VIEW_BODY:-Parent body}" ;;
	labels) printf '%s\n' "${GH_ISSUE_VIEW_LABELS:-bug,tier:standard}" ;;
	state,labels,assignees)
		if [[ -n "${GH_ISSUE_META_JSON:-}" ]]; then
			printf '%s\n' "$GH_ISSUE_META_JSON"
		else
			printf '%s\n' '{"state":"OPEN","labels":[],"assignees":[]}'
		fi
		;;
	state,closedAt)
		[[ "${GH_ISSUE_VIEW_STATE_FAIL:-0}" == "1" ]] && exit 1
		if [[ -n "${GH_ISSUE_VIEW_STATE_JSON:-}" ]]; then
			printf '%s\n' "$GH_ISSUE_VIEW_STATE_JSON"
		else
			printf '%s\n' '{"state":"CLOSED","closedAt":"2020-01-01T00:00:00Z"}'
		fi
		;;
	*) printf '\n' ;;
	esac
	;;
issue-list)
	if [[ "${GH_ISSUE_LIST_FAIL:-0}" == "1" ]]; then
		exit 1
	fi
	# t2144: --state dispatch so tests can fixture open and closed child
	# lists independently (grace-window regression tests).
	eval "$(_stub_parse_args "$@")"
	list_json="${GH_ISSUE_LIST_CHILD_JSON:-[]}"
	[[ "$STATE" == "closed" ]] && list_json="${GH_ISSUE_LIST_CHILD_CLOSED_JSON:-[]}"
	_stub_emit "$list_json" "$JQ"
	;;
pr-list)
	# t2161: drives off GH_PR_LIST_RESOLVING_JSON. Honours --jq if used
	# (current production caller does NOT — it pipes raw JSON through jq).
	eval "$(_stub_parse_args "$@")"
	_stub_emit "${GH_PR_LIST_RESOLVING_JSON:-[]}" "$JQ"
	;;
issue-create) printf '%s\n' "${GH_ISSUE_CREATE_URL:-https://github.com/owner/repo/issues/999}" ;;
api-*) printf '%s\n' "${GH_API_COMMENTS_JSON:-[]}" ;;
issue-edit | issue-comment | label-create) ;;
*) printf 'gh stub: unhandled: %s\n' "$*" >&2 ;;
esac
exit 0
STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# _setup_gh_stub_globals: export PATH and pulse-triage globals, then source the script.
# Requires TEST_ROOT and GH_LOG to be set. Called by setup_gh_stub.
_setup_gh_stub_globals() {
	if [[ -z "${TEST_ROOT:-}" ]]; then
		printf 'Error: TEST_ROOT is not set\n' >&2
		return 1
	fi
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_LOG
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"

	# Minimal globals expected by pulse-triage.sh
	export TRIAGE_CACHE_DIR="${TEST_ROOT}/triage-cache"
	mkdir -p "$TRIAGE_CACHE_DIR"
	export ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS=50
	export ISSUE_CONSOLIDATION_COMMENT_THRESHOLD=2
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	printf '{"initialized_repos": []}\n' >"$REPOS_JSON"

	# Source pulse-triage.sh in isolation — it's intended to be sourced
	# from pulse-wrapper.sh but the consolidation helpers are self-contained.
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/.agents/scripts/pulse-triage.sh"

	# t2144: stub the gh_create_issue wrapper (defined in shared-constants.sh,
	# not sourced here) so _create_consolidation_child_issue actually reaches
	# the stubbed `gh issue create` on PATH. Without this, the wrapper is
	# undefined and the dispatch path silently fails — which has been a
	# pre-existing test flake since t2115 introduced the wrapper. Mirrors
	# the stub in tests/test-gh-wrapper-guard.sh.
	gh_create_issue() {
		gh issue create "$@"
		return $?
	}
	gh_issue_comment() {
		gh issue comment "$@"
		return $?
	}
	gh_issue_list() {
		gh issue list "$@"
		return $?
	}
	gh_pr_list() {
		gh pr list "$@"
		return $?
	}
	repo_allows_pulse_write_actions() {
		local repo_slug="$1"
		case "$repo_slug" in
		owner/repo | marcusquinn/aidevops) return 0 ;;
		*) return 1 ;;
		esac
	}
	return 0
}

# Create a stubbed `gh` binary on PATH. Canned responses are driven by
# environment variables set per test:
#   GH_ISSUE_VIEW_TITLE — string returned by `gh issue view --json title --jq .title`
#   GH_ISSUE_VIEW_BODY — string for body
#   GH_ISSUE_VIEW_LABELS — CSV returned by `--json labels --jq '[.labels[].name] | join(",")'`
#   GH_API_COMMENTS_JSON — raw JSON returned by `gh api .../comments`
#   GH_ISSUE_LIST_CHILD_JSON — JSON array used for dedup lookups
#   GH_ISSUE_CREATE_URL — URL echoed by `gh issue create` on success
setup_gh_stub() {
	TEST_ROOT=$(mktemp -d -t t1982-consol.XXXXXX)
	GH_LOG="${TEST_ROOT}/gh.log"
	: >"$GH_LOG"
	_write_gh_stub_binary
	_setup_gh_stub_globals
	return 0
}

teardown_gh_stub() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	GH_LOG=""
	unset GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS GH_ISSUE_VIEW_STATE_JSON GH_ISSUE_VIEW_STATE_FAIL GH_ISSUE_META_JSON
	unset GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON GH_ISSUE_CREATE_URL
	unset GH_ISSUE_LIST_FAIL
	unset GH_PR_LIST_RESOLVING_JSON
	unset CONSOLIDATION_RECENT_CLOSE_GRACE_MIN
	return 0
}

fixture_two_substantive_comments() {
	# Two substantive comments from alice and bob plus one bot noise.
	# Each comment body is ~60 chars to clear min_chars=50.
	cat <<'JSON'
[
  {"user": {"login": "alice", "type": "User"}, "created_at": "2026-04-12T10:00:00Z", "body": "I think we need to add a third failure case for the offline path when the cache is cold."},
  {"user": {"login": "bob", "type": "User"}, "created_at": "2026-04-12T11:30:00Z", "body": "Agree with alice and also the retry policy should back off exponentially rather than linearly."},
  {"user": {"login": "github-actions", "type": "Bot"}, "created_at": "2026-04-12T12:00:00Z", "body": "Dispatching worker for issue #123 at 2026-04-12T12:00:00Z via /full-loop Implement it"}
]
JSON
}

test_dispatch_creates_child_issue() {
	setup_gh_stub
	GH_ISSUE_VIEW_TITLE="test: example parent issue"
	GH_ISSUE_VIEW_BODY="Original parent body describing the problem in detail."
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_API_COMMENTS_JSON=$(fixture_two_substantive_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_CREATE_URL="https://github.com/owner/repo/issues/9001"
	export GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	export GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_CREATE_URL

	local rc=0
	_dispatch_issue_consolidation 123 "owner/repo" "/tmp/fake-path" || rc=$?

	if [[ "$rc" -eq 0 ]] && grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		print_result "dispatch creates consolidation-task child issue" 0
	elif [[ "$rc" -ne 0 ]]; then
		print_result "dispatch creates consolidation-task child issue" 1 \
			"_dispatch_issue_consolidation returned $rc"
	else
		print_result "dispatch creates consolidation-task child issue" 1 \
			"gh issue create was not invoked"
	fi

	teardown_gh_stub
	return 0
}

test_child_body_contains_parent_content_and_authors() {
	setup_gh_stub
	GH_ISSUE_VIEW_TITLE="test: parent title"
	GH_ISSUE_VIEW_BODY="VERBATIM_PARENT_BODY_MARKER"
	GH_ISSUE_VIEW_LABELS="bug"
	local fixture
	fixture=$(fixture_two_substantive_comments)
	local authors
	authors=$(printf '%s' "$fixture" | jq -r '[.[] | select(.user.type != "Bot") | .user.login] | unique | map("@" + .) | join(" ")')

	local body
	body=$(_compose_consolidation_child_body \
		123 "owner/repo" "test: parent title" "VERBATIM_PARENT_BODY_MARKER" \
		"$(printf '%s' "$fixture" | jq '[.[] | select(.user.type != "Bot") | {login: .user.login, created_at: .created_at, body: .body}]')" \
		"$authors" "bug")

	local failures=0
	local failmsg=""

	if ! printf '%s' "$body" | grep -q 'Consolidation target: #123'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | missing consolidation-target marker"
	fi
	if ! printf '%s' "$body" | grep -q 'VERBATIM_PARENT_BODY_MARKER'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | parent body not inlined verbatim"
	fi
	if ! printf '%s' "$body" | grep -q '@alice'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | @alice not mentioned"
	fi
	if ! printf '%s' "$body" | grep -q '@bob'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | @bob not mentioned"
	fi
	if ! printf '%s' "$body" | grep -q 'You do \*\*NOT\*\* need to read'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | missing self-contained warning"
	fi
	if ! printf '%s' "$body" | grep -qF -- '--label "consolidated,origin:worker,auto-dispatch,<copy relevant labels from parent, excluding needs-consolidation, consolidation-task, and origin:interactive>"'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | consolidated successor instructions omit auto-dispatch handoff"
	fi
	if printf '%s' "$body" | grep -q 'github-actions'; then
		failures=$((failures + 1))
		failmsg="${failmsg} | bot comment leaked into child body"
	fi

	if [[ $failures -eq 0 ]]; then
		print_result "child body contains parent content + @-mentions + no bot leakage" 0
	else
		print_result "child body contains parent content + @-mentions + no bot leakage" 1 "$failmsg"
	fi

	teardown_gh_stub
	return 0
}

test_dedup_skips_when_child_exists() {
	setup_gh_stub
	GH_ISSUE_VIEW_TITLE="test: parent"
	GH_ISSUE_VIEW_BODY="body"
	GH_ISSUE_VIEW_LABELS="bug"
	GH_API_COMMENTS_JSON="[]"
	# Simulate dedup: child list returns one entry
	# shellcheck disable=SC2089
	GH_ISSUE_LIST_CHILD_JSON='[{"number": 9002}]'
	GH_ISSUE_CREATE_URL="https://github.com/owner/repo/issues/SHOULD_NOT_BE_CALLED"
	export GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	# shellcheck disable=SC2090
	export GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_CREATE_URL

	_dispatch_issue_consolidation 123 "owner/repo" "/tmp/fake-path" || true

	if grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		print_result "dedup skips child creation when one already exists" 1 \
			"gh issue create was invoked despite existing child"
	else
		print_result "dedup skips child creation when one already exists" 0
	fi

	teardown_gh_stub
	return 0
}

test_consolidation_child_exists_detects_existing() {
	setup_gh_stub
	# shellcheck disable=SC2089
	GH_ISSUE_LIST_CHILD_JSON='[{"number": 9003}]'
	# shellcheck disable=SC2090
	export GH_ISSUE_LIST_CHILD_JSON

	if _consolidation_child_exists 123 "owner/repo"; then
		print_result "_consolidation_child_exists returns 0 when child present" 0
	else
		print_result "_consolidation_child_exists returns 0 when child present" 1 \
			"returned non-zero with non-empty child list"
	fi

	GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_JSON
	if _consolidation_child_exists 123 "owner/repo"; then
		print_result "_consolidation_child_exists returns 1 when no child" 1 \
			"returned 0 with empty child list"
	else
		print_result "_consolidation_child_exists returns 1 when no child" 0
	fi

	teardown_gh_stub
	return 0
}

test_consolidation_child_exists_detects_parent_dispatch_comment_on_later_page() {
	setup_gh_stub
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_API_COMMENTS_JSON=$(jq -n '[[{"body":"old operational comment"}],[{"body":"## Issue Consolidation Dispatched\n\nA consolidation task has been filed as **#9005**."}]]')
	# shellcheck disable=SC2089
	GH_ISSUE_VIEW_STATE_JSON='{"state":"OPEN","closedAt":null}'
	# shellcheck disable=SC2090
	export GH_ISSUE_LIST_CHILD_JSON GH_API_COMMENTS_JSON GH_ISSUE_VIEW_STATE_JSON

	if _consolidation_child_exists 123 "owner/repo"; then
		print_result "_consolidation_child_exists verifies paginated marker's open child" 0
	else
		print_result "_consolidation_child_exists verifies paginated marker's open child" 1 \
			"returned non-zero despite directly verified open child"
	fi

	teardown_gh_stub
	return 0
}

test_consolidation_child_exists_fails_closed_on_search_error() {
	setup_gh_stub
	GH_API_COMMENTS_JSON="[]"
	GH_ISSUE_LIST_FAIL=1
	export GH_API_COMMENTS_JSON GH_ISSUE_LIST_FAIL

	if _consolidation_child_exists 123 "owner/repo"; then
		print_result "_consolidation_child_exists fails closed on child search error" 0
	else
		print_result "_consolidation_child_exists fails closed on child search error" 1 \
			"returned non-zero despite child search API failure"
	fi

	teardown_gh_stub
	return 0
}

test_idempotent_comment_reads_paginated_issue_comments() {
	setup_gh_stub
	GH_API_COMMENTS_JSON=$(jq -n '[[{"body":"older page"}],[{"body":"## Issue Consolidation Dispatched\n\nA consolidation task exists."}]]')
	export GH_API_COMMENTS_JSON

	_gh_idempotent_comment 123 "owner/repo" \
		"## Issue Consolidation Dispatched" \
		"## Issue Consolidation Dispatched

Duplicate body should not post."

	if grep -q 'issue comment' "$GH_LOG" 2>/dev/null; then
		print_result "_gh_idempotent_comment skips marker on paginated issue comments" 1 \
			"gh issue comment was invoked despite marker on later page"
	else
		print_result "_gh_idempotent_comment skips marker on paginated issue comments" 0
	fi

	teardown_gh_stub
	return 0
}

test_idempotent_pr_comment_uses_paginated_rest_comments() {
	setup_gh_stub
	GH_API_COMMENTS_JSON=$(jq -n '[[{"body":"older page"}],[{"body":"## PR Gate Marker\n\nA gate comment already exists."}]]')
	export GH_API_COMMENTS_JSON

	_gh_idempotent_comment 456 "owner/repo" \
		"## PR Gate Marker" \
		"## PR Gate Marker

Duplicate body should not post." "pr"

	if grep -qF 'api repos/owner/repo/issues/456/comments?per_page=100 --paginate --slurp' "$GH_LOG" 2>/dev/null &&
		! grep -qE '^(pr view|pr comment)' "$GH_LOG" 2>/dev/null; then
		print_result "_gh_idempotent_comment reads PR conversation comments through paginated REST" 0
	else
		print_result "_gh_idempotent_comment reads PR conversation comments through paginated REST" 1 \
			"unexpected gh calls: $(cat "$GH_LOG")"
	fi

	teardown_gh_stub
	return 0
}

test_needs_consolidation_skips_with_child() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	# Simulate: a consolidation-task child exists
	# shellcheck disable=SC2089
	GH_ISSUE_LIST_CHILD_JSON='[{"number": 9004}]'
	# shellcheck disable=SC2090
	export GH_ISSUE_VIEW_LABELS GH_ISSUE_LIST_CHILD_JSON

	# _issue_needs_consolidation returns 1 when child already exists.
	if _issue_needs_consolidation 123 "owner/repo"; then
		print_result "_issue_needs_consolidation skips when child exists" 1 \
			"returned 0 (consolidation needed) despite existing child"
	else
		print_result "_issue_needs_consolidation skips when child exists" 0
	fi

	teardown_gh_stub
	return 0
}

# ----------------------------------------------------------------------
# t2144 regression tests — consolidation cascade fix
#
# Reference evidence: GH#19347 (investigation), cascades observed on
# 2026-04-16 where #19321 → #19341 + #19367 and #19275 → #19277 + #19359.
# ----------------------------------------------------------------------

# Fixture: two WORKER_SUPERSEDED comments of the exact length and shape
# seen in production (#19321). Before t2144 these passed the filter
# because the `^(\*\*)?Stale assignment recovered` anchor was a no-op —
# bodies start with the `<!-- WORKER_SUPERSEDED ...` HTML marker.
fixture_two_worker_superseded_comments() {
	local pad='x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x x'
	local body1="<!-- WORKER_SUPERSEDED runners=marcusquinn ts=2026-04-16T17:06:24Z -->
**Stale assignment recovered** — prior worker exited without updating status. ${pad}"
	local body2="<!-- WORKER_SUPERSEDED runners=alex-solovyev ts=2026-04-16T17:35:29Z -->
**Stale assignment recovered** — prior worker exited without updating status. ${pad}"
	jq -n --arg b1 "$body1" --arg b2 "$body2" '
		[
			{"user": {"login": "marcusquinn", "type": "User"}, "created_at": "2026-04-16T17:06:25Z", "body": $b1},
			{"user": {"login": "marcusquinn", "type": "User"}, "created_at": "2026-04-16T17:35:30Z", "body": $b2}
		]
	'
}

# Fixture: TWO stale-recovery-tick comments — both must be filtered.
# CodeRabbit flagged (PR #19411): a single-comment fixture is vacuous
# against THRESHOLD=2 — the test would pass even without the filter fix
# because 1 comment never meets the threshold. Two comments that clear
# min_chars BUT are filtered by the ^<!-- stale-recovery-tick prefix
# exercise the filter directly: pre-t2144 they'd have counted as
# substantive (substantive_count=2 == threshold=2 → dispatch); post-t2144
# they're filtered out (substantive_count=0 < threshold → no dispatch).
fixture_stale_recovery_tick_comments() {
	cat <<'JSON'
[
  {"user": {"login": "marcusquinn", "type": "User"}, "created_at": "2026-04-16T17:06:16Z", "body": "<!-- stale-recovery-tick:1 -->\nStale recovery tick 1/2 (t2008). This padding exists only so the body length clears the test-harness threshold of 50 chars without adding any real scope change."},
  {"user": {"login": "marcusquinn", "type": "User"}, "created_at": "2026-04-16T17:21:30Z", "body": "<!-- stale-recovery-tick:2 -->\nStale recovery tick 2/2 (t2008). This padding exists only so the body length clears the test-harness threshold of 50 chars without adding any real scope change."}
]
JSON
}

# Fixture: TWO cost-circuit-breaker comments — both must be filtered. These are
# operational diagnostics and must not trigger or leak into issue consolidation.
fixture_cost_circuit_breaker_comments() {
	cat <<'JSON'
[
  {"user": {"login": "marcusquinn", "type": "User"}, "created_at": "2026-05-02T19:27:10Z", "body": "<!-- cost-circuit-breaker:fired tier=standard spent=248726 budget=100000 -->\nCost circuit breaker fired. This diagnostic comment is intentionally long enough to clear the consolidation min-char threshold."},
  {"user": {"login": "marcusquinn", "type": "User"}, "created_at": "2026-05-02T19:42:10Z", "body": "<!-- cost-circuit-breaker:fired tier=standard spent=350000 budget=100000 -->\nCost circuit breaker fired again. This diagnostic comment is intentionally long enough to clear the consolidation min-char threshold."}
]
JSON
	return 0
}

# Operational workflow comments reproduced from GH#28564-#28566. Both are
# user-authored and exceed the production length threshold, but neither changes
# issue scope and neither belongs in consolidation decisions or child bodies.
fixture_operational_review_comments() {
	cat <<'JSON'
[
  {"user": {"login": "maintainer-one", "type": "User"}, "created_at": "2026-07-24T10:00:00Z", "body": "<!-- triage-escalation -->\nAutomated triage escalation metadata and decision context. This operational body is intentionally long enough to clear the consolidation threshold without representing human scope discussion."},
  {"user": {"login": "maintainer-one", "type": "User"}, "created_at": "2026-07-24T10:05:00Z", "body": "## Review: Recommendation: Approve\n\nStructured maintainer review evidence. This canonical workflow body is intentionally long enough to clear the consolidation threshold without representing human scope discussion."}
]
JSON
	return 0
}

fixture_review_feedback_supersession_comments() {
	cat <<'JSON'
[
  {"user": {"login": "alice", "type": "User"}, "created_at": "2026-07-24T11:00:00Z", "body": "A genuine scope-changing comment with enough implementation detail to clear the configured consolidation threshold."},
  {"user": {"login": "maintainer-one", "type": "User"}, "created_at": "2026-07-24T11:05:00Z", "body": "<!-- review-feedback-supersession-ambiguous -->\n## Possible review-feedback supersession\nThis pulse-generated operational comment is intentionally long enough to clear the consolidation threshold."}
]
JSON
	return 0
}

fixture_one_substantive_comment() {
	cat <<'JSON'
{"user": {"login": "alice", "type": "User"}, "created_at": "2026-07-24T11:00:00Z", "body": "A genuine scope-changing comment with enough implementation detail to clear the configured consolidation threshold."}
JSON
	return 0
}

# Fixture: gh api --paginate --jq '.' emits one JSON array per page. The
# consolidation filter must slurp and combine those pages before counting.
fixture_paginated_substantive_comments() {
	cat <<'JSON'
[
  {"user": {"login": "maintainer-one", "type": "User"}, "created_at": "2026-05-03T19:00:00Z", "body": "First substantive maintainer comment with enough detail to clear the configured consolidation threshold."}
]
[
  {"user": {"login": "maintainer-two", "type": "User"}, "created_at": "2026-05-03T19:05:00Z", "body": "Second substantive maintainer comment with enough detail to clear the configured consolidation threshold."}
]
JSON
	return 0
}

test_paginated_comments_are_combined_for_consolidation() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_API_COMMENTS_JSON=$(fixture_paginated_substantive_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _issue_needs_consolidation 25000 "marcusquinn/aidevops"; then
		print_result "paginated comments are slurped before consolidation count" 0
	else
		print_result "paginated comments are slurped before consolidation count" 1 \
			"_issue_needs_consolidation returned 1 despite two substantive comments across pages"
	fi

	local substantive_json
	substantive_json=$(_consolidation_substantive_comments 25000 "marcusquinn/aidevops")
	local substantive_count
	substantive_count=$(printf '%s' "$substantive_json" | jq -r 'length') || substantive_count=0
	if [[ "$substantive_count" -eq 2 ]]; then
		print_result "paginated comments are slurped for consolidation body" 0
	else
		print_result "paginated comments are slurped for consolidation body" 1 \
			"(substantive_count=${substantive_count}; substantive_json=${substantive_json})"
	fi

	teardown_gh_stub
	return 0
}

# t2144 A1 regression: WORKER_SUPERSEDED comments must NOT count as substantive.
test_worker_superseded_comments_are_filtered() {
	setup_gh_stub
	# Restore production-realistic thresholds for this test. The default
	# stub sets min_chars=50; WORKER_SUPERSEDED comments are ~530 chars so
	# they'd pass the length gate at either setting. Threshold stays at 2.
	export ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS=200
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_API_COMMENTS_JSON=$(fixture_two_worker_superseded_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	# Before t2144 this returned 0 (needs consolidation) because two 530-char
	# recovery comments passed the filter. After t2144 the ^<!-- WORKER_SUPERSEDED
	# pattern filters them out, substantive_count drops to 0, and the helper
	# returns 1 (no dispatch).
	if _issue_needs_consolidation 19321 "marcusquinn/aidevops"; then
		print_result "t2144: WORKER_SUPERSEDED comments are filtered (no false consolidation)" 1 \
			"_issue_needs_consolidation returned 0 despite only WORKER_SUPERSEDED noise"
	else
		print_result "t2144: WORKER_SUPERSEDED comments are filtered (no false consolidation)" 0
	fi

	teardown_gh_stub
	return 0
}

# t2144 A1 regression: stale-recovery-tick comments must NOT count.
test_stale_recovery_tick_comments_are_filtered() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_API_COMMENTS_JSON=$(fixture_stale_recovery_tick_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _issue_needs_consolidation 19999 "marcusquinn/aidevops"; then
		print_result "t2144: stale-recovery-tick comments are filtered" 1 \
			"_issue_needs_consolidation returned 0 despite only stale-recovery-tick noise"
	else
		print_result "t2144: stale-recovery-tick comments are filtered" 0
	fi

	teardown_gh_stub
	return 0
}

# Cost-circuit-breaker diagnostics must not count as substantive comments and
# must not be included in the consolidation-task child body.
test_cost_circuit_breaker_comments_are_filtered() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_API_COMMENTS_JSON=$(fixture_cost_circuit_breaker_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _issue_needs_consolidation 22462 "marcusquinn/aidevops"; then
		print_result "cost-circuit-breaker comments are filtered from consolidation trigger" 1 \
			"_issue_needs_consolidation returned 0 despite only cost-circuit-breaker noise"
	else
		print_result "cost-circuit-breaker comments are filtered from consolidation trigger" 0
	fi

	local substantive_json
	substantive_json=$(_consolidation_substantive_comments 22462 "marcusquinn/aidevops")
	if [[ "$substantive_json" == "[]" ]]; then
		print_result "cost-circuit-breaker comments are excluded from consolidation body input" 0
	else
		print_result "cost-circuit-breaker comments are excluded from consolidation body input" 1 \
			"(substantive_json=$substantive_json)"
	fi

	teardown_gh_stub
	return 0
}

test_operational_review_comments_are_filtered() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard,needs-consolidation"
	GH_API_COMMENTS_JSON=$(fixture_operational_review_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _issue_needs_consolidation 28564 "marcusquinn/aidevops"; then
		print_result "operational review comments do not trigger consolidation" 1 \
			"_issue_needs_consolidation returned 0 for triage escalation and canonical review noise"
	else
		print_result "operational review comments do not trigger consolidation" 0
	fi

	local substantive_json
	substantive_json=$(_consolidation_substantive_comments 28564 "marcusquinn/aidevops")
	if [[ "$substantive_json" == "[]" ]]; then
		print_result "operational review comments are excluded from consolidation body input" 0
	else
		print_result "operational review comments are excluded from consolidation body input" 1 \
			"(substantive_json=$substantive_json)"
	fi

	if grep -qE 'issue edit .* --remove-label needs-consolidation' "$GH_LOG" 2>/dev/null; then
		print_result "operational-only comments auto-clear needs-consolidation" 0
	else
		print_result "operational-only comments auto-clear needs-consolidation" 1 \
			"expected remove-label call not found in gh log"
	fi

	local operational_index
	for operational_index in 0 1; do
		GH_ISSUE_VIEW_LABELS="bug,tier:standard"
		GH_API_COMMENTS_JSON=$(jq -n \
			--argjson operational "$(fixture_operational_review_comments)" \
			--argjson substantive "$(fixture_one_substantive_comment)" \
			--argjson index "$operational_index" \
			'[$operational[$index], $substantive]')
		export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON

		if _issue_needs_consolidation 28565 "marcusquinn/aidevops"; then
			print_result "operational comment ${operational_index} is excluded individually" 1 \
				"operational comment plus one genuine comment met threshold=2"
		else
			print_result "operational comment ${operational_index} is excluded individually" 0
		fi

		substantive_json=$(_consolidation_substantive_comments 28565 "marcusquinn/aidevops")
		if [[ "$(printf '%s' "$substantive_json" | jq -r 'length')" -eq 1 ]]; then
			print_result "operational comment ${operational_index} is excluded individually from body input" 0
		else
			print_result "operational comment ${operational_index} is excluded individually from body input" 1 \
				"(substantive_json=$substantive_json)"
		fi
	done

	GH_API_COMMENTS_JSON=$(fixture_two_substantive_comments)
	export GH_API_COMMENTS_JSON
	if _issue_needs_consolidation 28566 "marcusquinn/aidevops"; then
		print_result "two genuine human comments still trigger consolidation" 0
	else
		print_result "two genuine human comments still trigger consolidation" 1 \
			"_issue_needs_consolidation returned 1 for two substantive comments"
	fi

	teardown_gh_stub
	return 0
}

test_review_feedback_markers_are_filtered() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard,needs-consolidation"
	GH_API_COMMENTS_JSON=$(fixture_review_feedback_supersession_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _issue_needs_consolidation 30428 "marcusquinn/aidevops"; then
		print_result "review-feedback marker does not trigger consolidation" 1 \
			"one human comment plus operational marker met threshold=2"
	else
		print_result "review-feedback marker does not trigger consolidation" 0
	fi

	local substantive_json
	substantive_json=$(_consolidation_substantive_comments 30428 "marcusquinn/aidevops")
	if [[ "$(printf '%s' "$substantive_json" | jq -r 'length')" -eq 1 ]] &&
		! printf '%s' "$substantive_json" | jq -e '.[].body | contains("review-feedback-supersession")' >/dev/null; then
		print_result "review-feedback marker is excluded from consolidation body" 0
	else
		print_result "review-feedback marker is excluded from consolidation body" 1 \
			"substantive_json=${substantive_json}"
	fi

	if grep -qE 'issue edit .* --remove-label needs-consolidation' "$GH_LOG" 2>/dev/null; then
		print_result "review-feedback marker allows stale consolidation label cleanup" 0
	else
		print_result "review-feedback marker allows stale consolidation label cleanup" 1
	fi

	teardown_gh_stub
	return 0
}

test_expired_dispatch_comment_releases_parent() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard,needs-consolidation"
	GH_API_COMMENTS_JSON=$(jq -n '[[{"body":"## Issue Consolidation Dispatched\n\nA consolidation task has been filed as **#9005**."}]]')
	# shellcheck disable=SC2089
	GH_ISSUE_VIEW_STATE_JSON='{"state":"CLOSED","closedAt":"2020-01-01T00:00:00Z"}'
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	# shellcheck disable=SC2090
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON GH_ISSUE_VIEW_STATE_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _issue_needs_consolidation 30427 "marcusquinn/aidevops"; then
		print_result "expired dispatch comment releases parent" 1 \
			"historical marker still owned parent"
	elif grep -qE 'issue edit .* --remove-label needs-consolidation' "$GH_LOG" 2>/dev/null; then
		print_result "expired dispatch comment releases parent" 0
	else
		print_result "expired dispatch comment releases parent" 1 \
			"stale label was not cleared after ownership expired"
	fi

	teardown_gh_stub
	return 0
}

test_dispatch_comment_keeps_open_child_owner() {
	setup_gh_stub
	GH_API_COMMENTS_JSON=$(jq -n '[[{"body":"## Issue Consolidation Dispatched\n\nA consolidation task has been filed as **#9005**."}]]')
	# shellcheck disable=SC2089
	GH_ISSUE_VIEW_STATE_JSON='{"state":"OPEN","closedAt":null}'
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	# shellcheck disable=SC2090
	export GH_API_COMMENTS_JSON GH_ISSUE_VIEW_STATE_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _consolidation_child_exists 30427 "marcusquinn/aidevops"; then
		print_result "dispatch comment keeps directly verified open child owner" 0
	else
		print_result "dispatch comment keeps directly verified open child owner" 1
	fi

	teardown_gh_stub
	return 0
}

test_dispatch_comment_state_failure_fails_closed() {
	setup_gh_stub
	GH_API_COMMENTS_JSON=$(jq -n '[[{"body":"## Issue Consolidation Dispatched\n\nA consolidation task has been filed as **#9005**."}]]')
	GH_ISSUE_VIEW_STATE_FAIL=1
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_API_COMMENTS_JSON GH_ISSUE_VIEW_STATE_FAIL GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _consolidation_child_exists 30427 "marcusquinn/aidevops"; then
		print_result "dispatch comment state uncertainty fails closed" 0
	else
		print_result "dispatch comment state uncertainty fails closed" 1
	fi

	teardown_gh_stub
	return 0
}

test_active_consolidation_lock_keeps_parent_owner() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard,needs-consolidation,consolidation-in-progress"
	GH_API_COMMENTS_JSON="[]"
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON

	if _issue_needs_consolidation 30427 "marcusquinn/aidevops"; then
		print_result "active consolidation lock keeps parent owned" 1
	elif grep -qE 'issue edit .* --remove-label needs-consolidation' "$GH_LOG" 2>/dev/null; then
		print_result "active consolidation lock keeps parent owned" 1 \
			"active ownership cleared needs-consolidation"
	else
		print_result "active consolidation lock keeps parent owned" 0
	fi

	teardown_gh_stub
	return 0
}

# t2144 A4 regression: a recently-closed child within the grace window
# still "owns" the parent — _consolidation_child_exists must return 0.
test_recently_closed_child_blocks_redispatch_within_grace() {
	setup_gh_stub
	# Child closed "now" — well inside the 30-min default window.
	export GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON='[{"number": 19341}]'

	if _consolidation_child_exists 19321 "marcusquinn/aidevops"; then
		print_result "t2144: recently-closed child blocks re-dispatch within grace window" 0
	else
		print_result "t2144: recently-closed child blocks re-dispatch within grace window" 1 \
			"_consolidation_child_exists returned 1 despite recently-closed child"
	fi

	teardown_gh_stub
	return 0
}

# t2144 A4 regression: grace_minutes=0 disables the window — backward-compat
# check that the legacy open-only semantics are reachable (no breakage for
# callers that don't want the grace window).
test_grace_zero_restores_open_only_semantics() {
	setup_gh_stub
	export GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON='[{"number": 19341}]'

	# Third arg 0 disables grace — closed child must not count.
	if _consolidation_child_exists 19321 "marcusquinn/aidevops" 0; then
		print_result "t2144: grace_minutes=0 ignores closed children" 1 \
			"_consolidation_child_exists returned 0 with grace=0 despite only-closed child"
	else
		print_result "t2144: grace_minutes=0 ignores closed children" 0
	fi

	teardown_gh_stub
	return 0
}

# t2144 A3 regression: backfill auto-clears `needs-consolidation` when the
# parent also carries `consolidated` (race artefact) and does NOT dispatch.
test_backfill_clears_stale_label_on_consolidated_parent() {
	setup_gh_stub
	# Open issue list returns one labelled parent that ALSO has consolidated.
	export GH_ISSUE_LIST_CHILD_JSON='[{"number": 19321, "labels": [{"name": "needs-consolidation"}, {"name": "consolidated"}]}]'
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"

	# repos.json with a single pulse-enabled repo pointing at our stub slug.
	cat >"${TEST_ROOT}/repos.json" <<'JSON'
{
  "initialized_repos": [
    {"slug": "marcusquinn/aidevops", "path": "/tmp/fake-path", "pulse": true}
  ]
}
JSON
	export REPOS_JSON="${TEST_ROOT}/repos.json"

	_backfill_stale_consolidation_labels || true

	# Verify: no `gh issue create` (no child dispatched).
	if grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		print_result "t2144: backfill skips dispatch on consolidated parent" 1 \
			"gh issue create was invoked despite consolidated label"
	else
		print_result "t2144: backfill skips dispatch on consolidated parent" 0
	fi

	# Verify: `gh issue edit --remove-label needs-consolidation` was called.
	if grep -qE 'issue edit .* --remove-label needs-consolidation' "$GH_LOG" 2>/dev/null; then
		print_result "t2144: backfill auto-clears stale needs-consolidation label" 0
	else
		print_result "t2144: backfill auto-clears stale needs-consolidation label" 1 \
			"expected remove-label call not found in gh log"
	fi

	teardown_gh_stub
	return 0
}

# ----------------------------------------------------------------------
# t2161 regression tests — in-flight PR skip safety net
#
# Reference evidence: GH#19448 → #19469 → #19471 cascade on 2026-04-17.
# A contributor runner on pre-t2144 code falsely tripped consolidation
# on #19448 (THRESHOLD=2 satisfied by two ~530-char WORKER_SUPERSEDED
# bodies that bypassed the stale `^(\*\*)?Stale assignment recovered`
# anchor) while PR #19466 was already mergeable. Result: #19469 created;
# the consolidation worker then created #19471 — 5 seconds AFTER #19466
# merged. t2144 fixed the filter; t2161 adds defence-in-depth so the
# cascade is blocked even if version drift re-introduces the regression.
# ----------------------------------------------------------------------

# Helper: PR list payload with one open PR whose body resolves the parent.
fixture_open_pr_resolving() {
	local parent_num="$1"
	jq -n --arg n "$parent_num" '
		[
			{
				"number": 19466,
				"body": ("## Summary\n\nFix the thing.\n\nResolves #" + $n + "\n\n## Testing\n...")
			}
		]
	'
}

# Helper: PR list payload with one open PR that REFERENCES the parent
# but does NOT use a closing keyword (e.g. "For #N", "Ref #N", bare `#N`).
fixture_open_pr_non_closing() {
	local parent_num="$1"
	jq -n --arg n "$parent_num" '
		[
			{
				"number": 19467,
				"body": ("## Summary\n\nDocs-only follow-up that mentions #" + $n + " for context.\n\nFor #" + $n + "\n\n## Testing\n...")
			}
		]
	'
}

# t2161 A1 regression: helper returns 0 when an open PR has Resolves #N.
test_resolving_pr_helper_detects_closing_keyword() {
	setup_gh_stub
	GH_PR_LIST_RESOLVING_JSON=$(fixture_open_pr_resolving 19448)
	export GH_PR_LIST_RESOLVING_JSON

	if _consolidation_resolving_pr_exists 19448 "marcusquinn/aidevops"; then
		print_result "t2161: helper detects open PR with Resolves keyword" 0
	else
		print_result "t2161: helper detects open PR with Resolves keyword" 1 \
			"_consolidation_resolving_pr_exists returned 1 with closing keyword present"
	fi

	teardown_gh_stub
	return 0
}

# t2161 A1 regression: helper returns 1 when only non-closing references exist.
# `For #N`, `Ref #N`, and bare `#N` mentions must NOT be treated as resolving.
test_resolving_pr_helper_ignores_non_closing_reference() {
	setup_gh_stub
	GH_PR_LIST_RESOLVING_JSON=$(fixture_open_pr_non_closing 19448)
	export GH_PR_LIST_RESOLVING_JSON

	if _consolidation_resolving_pr_exists 19448 "marcusquinn/aidevops"; then
		print_result "t2161: helper ignores 'For #N' / bare '#N' references" 1 \
			"_consolidation_resolving_pr_exists returned 0 for non-closing reference"
	else
		print_result "t2161: helper ignores 'For #N' / bare '#N' references" 0
	fi

	teardown_gh_stub
	return 0
}

# t2161 A2 regression: _issue_needs_consolidation must skip dispatch when
# an in-flight PR resolves the parent — even when the substantive-comment
# count would otherwise meet the threshold. This is the GH#19448 cascade
# scenario: pre-t2144 filter was satisfied (two WORKER_SUPERSEDED bodies
# passed it), PR #19466 was open with `Resolves #19448` — t2161 must
# block consolidation.
test_needs_consolidation_skips_with_inflight_resolving_pr() {
	setup_gh_stub
	# Threshold-meeting fixture (would trip pre-t2144 filter), but t2161's
	# in-flight PR check should fire first and override.
	export ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS=200
	GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	GH_API_COMMENTS_JSON=$(fixture_two_worker_superseded_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	GH_PR_LIST_RESOLVING_JSON=$(fixture_open_pr_resolving 19448)
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON
	export GH_PR_LIST_RESOLVING_JSON

	if _issue_needs_consolidation 19448 "marcusquinn/aidevops"; then
		print_result "t2161: needs_consolidation skips when in-flight PR resolves parent" 1 \
			"_issue_needs_consolidation returned 0 despite open PR with Resolves keyword"
	else
		print_result "t2161: needs_consolidation skips when in-flight PR resolves parent" 0
	fi

	teardown_gh_stub
	return 0
}

# t2152 regression: a single github-actions[bot] comment (type: "Bot", 216 chars)
# at near-creation time must NOT trigger consolidation. Reproduces GH#19415
# (issue #19275 was falsely labeled needs-consolidation with only one bot
# comment). Root cause: pre-t2142 code had no defensive defaults on
# ISSUE_CONSOLIDATION_COMMENT_THRESHOLD — on Bash 5.x, [[ 0 -ge "" ]]
# evaluates TRUE, silently opening the gate for ALL issues.
# This test verifies the current code filters the bot comment correctly
# via both .user.type != "Bot" AND body length < min_chars.
fixture_single_bot_comment_near_creation() {
	cat <<'JSON'
[
  {"user": {"login": "github-actions[bot]", "type": "Bot"}, "created_at": "2026-04-16T11:36:26Z", "body": "<!-- origin-worker-protection-notice -->\nThe `origin:worker` label was removed automatically. This label is reserved for issues created by the automation pipeline and cannot be applied by non-maintainer contributors."}
]
JSON
}

test_single_bot_comment_does_not_trigger_consolidation() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,tier:standard,review-followup"
	GH_API_COMMENTS_JSON=$(fixture_single_bot_comment_near_creation)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	GH_PR_LIST_RESOLVING_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_API_COMMENTS_JSON
	export GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON
	export GH_PR_LIST_RESOLVING_JSON

	# The single 216-char github-actions[bot] comment (type: Bot) must be
	# excluded by the .user.type != "Bot" filter. substantive_count should
	# be 0, well below threshold=2 → function must return 1.
	if _issue_needs_consolidation 19275 "marcusquinn/aidevops"; then
		print_result "t2152: single bot comment at near-creation time does not trigger consolidation (GH#19415)" 1 \
			"_issue_needs_consolidation returned 0 despite only a single github-actions[bot] comment"
	else
		print_result "t2152: single bot comment at near-creation time does not trigger consolidation (GH#19415)" 0
	fi

	teardown_gh_stub
	return 0
}

# GH#27853: terminal retry breakers must delegate to the existing dispatcher
# rather than creating labels, comments, or child issues through a parallel
# path. Existing child/lock tests above provide the idempotency coverage.
test_terminal_breaker_bridge_delegates_to_dispatcher() {
	setup_gh_stub
	GH_ISSUE_VIEW_TITLE="test: terminal breaker parent"
	GH_ISSUE_VIEW_BODY="Original terminal breaker parent body."
	GH_ISSUE_VIEW_LABELS="bug,tier:standard,needs-maintainer-review"
	GH_API_COMMENTS_JSON="[]"
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	GH_PR_LIST_RESOLVING_JSON="[]"
	GH_ISSUE_CREATE_URL="https://github.com/owner/repo/issues/9002"
	export GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	export GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON
	export GH_PR_LIST_RESOLVING_JSON GH_ISSUE_CREATE_URL

	local rc=0
	_route_terminal_breaker_to_consolidation \
		123 "owner/repo" "fast-fail-hard-stop" "reason=runtime" || rc=$?

	if [[ "$rc" -eq 0 ]] && grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		print_result "GH#27853: terminal breaker bridge delegates to idempotent dispatcher" 0
	else
		print_result "GH#27853: terminal breaker bridge delegates to idempotent dispatcher" 1 \
			"rc=${rc}; expected gh issue create through _dispatch_issue_consolidation"
	fi

	teardown_gh_stub
	return 0
}

# t2161 A2 regression: _dispatch_issue_consolidation must short-circuit
# when an in-flight PR resolves the parent — even when no consolidation
# child exists yet. Covers the path where _backfill_stale_consolidation_labels
# bypasses the gate and reaches dispatch directly.
test_dispatch_skips_with_inflight_resolving_pr() {
	setup_gh_stub
	GH_ISSUE_VIEW_TITLE="test: parent with mergeable fix in flight"
	GH_ISSUE_VIEW_BODY="Original parent body."
	GH_ISSUE_VIEW_LABELS="bug,tier:standard,needs-consolidation"
	GH_API_COMMENTS_JSON=$(fixture_two_substantive_comments)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	GH_PR_LIST_RESOLVING_JSON=$(fixture_open_pr_resolving 19448)
	GH_ISSUE_CREATE_URL="https://github.com/owner/repo/issues/SHOULD_NOT_BE_CALLED"
	export GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	export GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON
	export GH_PR_LIST_RESOLVING_JSON GH_ISSUE_CREATE_URL

	_dispatch_issue_consolidation 19448 "marcusquinn/aidevops" "/tmp/fake-path" || true

	if grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		print_result "t2161: dispatch skips child creation when in-flight PR resolves parent" 1 \
			"gh issue create was invoked despite open PR with Resolves keyword"
	else
		print_result "t2161: dispatch skips child creation when in-flight PR resolves parent" 0
	fi

	teardown_gh_stub
	return 0
}

fixture_live_interactive_claim() {
	local claim_time
	claim_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	jq -n --arg timestamp "$claim_time" '[{
		"created_at": $timestamp,
		"user": {"login": "interactive-owner", "type": "User"},
		"body": "<!-- aidevops-interactive-claim/v1 -->\n<!-- ops:start -->\n> Interactive session claimed by @interactive-owner.\n<!-- ops:end -->"
	}]'
	return 0
}

test_live_interactive_claim_blocks_classification_and_clears_stale_label() {
	setup_gh_stub
	GH_ISSUE_VIEW_LABELS="bug,needs-consolidation,status:in-review"
	GH_ISSUE_META_JSON=$(jq -n '{state: "OPEN", labels: [{name: "status:in-review"}], assignees: [{login: "interactive-owner"}]}')
	GH_API_COMMENTS_JSON=$(fixture_live_interactive_claim)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_VIEW_LABELS GH_ISSUE_META_JSON GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON

	if _issue_needs_consolidation 30461 "marcusquinn/aidevops"; then
		print_result "live interactive claim blocks consolidation classification" 1
	elif grep -qE 'issue edit .* --remove-label needs-consolidation' "$GH_LOG" 2>/dev/null; then
		print_result "live interactive claim blocks consolidation classification and clears stale label" 0
	else
		print_result "live interactive claim blocks consolidation classification and clears stale label" 1 \
			"expected stale needs-consolidation cleanup"
	fi

	teardown_gh_stub
	return 0
}

test_live_interactive_claim_appearing_after_classification_blocks_dispatch() {
	setup_gh_stub
	GH_ISSUE_META_JSON=$(jq -n '{state: "OPEN", labels: [{name: "status:in-review"}], assignees: [{login: "interactive-owner"}]}')
	GH_API_COMMENTS_JSON=$(fixture_live_interactive_claim)
	GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_META_JSON GH_API_COMMENTS_JSON GH_ISSUE_LIST_CHILD_JSON

	_dispatch_issue_consolidation 30461 "marcusquinn/aidevops" "/tmp/fake-path" || true

	if grep -qE 'issue (create|edit|comment)' "$GH_LOG" 2>/dev/null; then
		print_result "late live interactive claim blocks dispatch without mutation" 1 \
			"dispatch emitted a visible issue mutation"
	else
		print_result "late live interactive claim blocks dispatch without mutation" 0
	fi

	teardown_gh_stub
	return 0
}

main() {
	test_dispatch_creates_child_issue
	test_child_body_contains_parent_content_and_authors
	test_dedup_skips_when_child_exists
	test_consolidation_child_exists_detects_existing
	test_consolidation_child_exists_detects_parent_dispatch_comment_on_later_page
	test_consolidation_child_exists_fails_closed_on_search_error
	test_idempotent_comment_reads_paginated_issue_comments
	test_idempotent_pr_comment_uses_paginated_rest_comments
	test_needs_consolidation_skips_with_child

	# t2144 regression suite
	test_paginated_comments_are_combined_for_consolidation
	test_worker_superseded_comments_are_filtered
	test_stale_recovery_tick_comments_are_filtered
	test_cost_circuit_breaker_comments_are_filtered
	test_operational_review_comments_are_filtered
	test_review_feedback_markers_are_filtered
	test_expired_dispatch_comment_releases_parent
	test_dispatch_comment_keeps_open_child_owner
	test_dispatch_comment_state_failure_fails_closed
	test_active_consolidation_lock_keeps_parent_owner
	test_recently_closed_child_blocks_redispatch_within_grace
	test_grace_zero_restores_open_only_semantics
	test_backfill_clears_stale_label_on_consolidated_parent

	# t2152 regression (GH#19415): single bot comment must not trigger
	test_single_bot_comment_does_not_trigger_consolidation
	test_terminal_breaker_bridge_delegates_to_dispatcher

	# t2161 regression suite
	test_resolving_pr_helper_detects_closing_keyword
	test_resolving_pr_helper_ignores_non_closing_reference
	test_needs_consolidation_skips_with_inflight_resolving_pr
	test_dispatch_skips_with_inflight_resolving_pr
	test_live_interactive_claim_blocks_classification_and_clears_stale_label
	test_live_interactive_claim_appearing_after_classification_blocks_dispatch

	echo
	echo "============================================"
	printf 'Tests run:    %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	echo "============================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
