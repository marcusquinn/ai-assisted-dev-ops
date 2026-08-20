#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-consolidation-multi-runner.sh — t2151 regression tests for the
# cross-runner advisory lock on consolidation dispatch.
#
# Covers the race that Phase A (t2144, PR #19411) could not close:
# two pulse runners on different hosts both pass
# _consolidation_child_exists at the same moment, and both create a
# consolidation-task child. Production evidence: parent #19321 dispatched
# #19341 (marcusquinn pulse) and #19367 (alex-solovyev pulse, 55 min later).
#
# Assertions:
#   1. Happy path — single runner acquires the lock, creates the child,
#      releases the lock (label removed + marker deleted).
#   2. Race tiebreaker — two runners post markers; the lexicographically
#      lowest login wins, the loser rolls back its marker and skips dispatch.
#   3. Lock label blocks _consolidation_child_exists — a parent carrying
#      `consolidation-in-progress` is treated as owned even with no open
#      or recently-closed child.
#   4. TTL expiry — a lock whose oldest marker is older than
#      CONSOLIDATION_LOCK_TTL_HOURS is cleared by the backfill sweep.
#   5. Child-close release semantics — after successful child creation, the
#      lock label is removed so _consolidation_child_exists (child-scope)
#      takes over as the blocking signal on subsequent dispatches.
#   6. dispatch-dedup-helper.sh is-assigned treats the lock label as an
#      active claim, so unrelated dispatch paths can't sneak past.
#
# Strategy: source pulse-triage.sh with a capable `gh` stub on PATH that
# branches on subcommand + API path and returns canned responses driven
# by env vars set per test.

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

# =============================================================================
# gh stub — capable enough to drive the lock protocol paths.
# =============================================================================
#
# Env vars consumed per test:
#   GH_SELF_LOGIN                — string returned by `gh api user --jq .login`
#   GH_LOCK_LABEL_PRESENT        — "true" if parent currently has the lock label
#   GH_LOCK_MARKERS_JSON         — JSON array returned by the lock-markers jq query
#   GH_ISSUE_VIEW_LABELS         — CSV returned by --json labels query on parent
#   GH_API_COMMENTS_JSON         — JSON returned by generic comments fetch
#   GH_ISSUE_LIST_CHILD_JSON     — existing dedup-check fixture (open children)
#   GH_ISSUE_LIST_CHILD_CLOSED_JSON — existing dedup-check fixture (closed children)
#   GH_ISSUE_LIST_LOCK_JSON      — issues returned by `--label consolidation-in-progress`
#   GH_ISSUE_CREATE_URL          — URL echoed by `gh issue create` on success
# =============================================================================

# _append_gh_stub_header — shebang + log-every-invocation + cmd1/cmd2 extract.
_append_gh_stub_header() {
	cat >>"${TEST_ROOT}/bin/gh" <<'STUB_HDR'
#!/usr/bin/env bash
# bash 3.2 compatible capable gh stub for t2151 tests.
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

cmd1="${1:-}"
cmd2="${2:-}"
STUB_HDR
}

# _append_gh_stub_api — API branches (user lookup, DELETE comment, fetch).
# Lock-markers fetch is distinguished from the generic comments fetch by
# checking whether the caller's --jq filter references the lock marker regex.
_append_gh_stub_api() {
	cat >>"${TEST_ROOT}/bin/gh" <<'STUB_API'

if [[ "$cmd1" == "api" && "$cmd2" == "user" ]]; then
	printf '%s\n' "${GH_SELF_LOGIN:-testuser}"
	exit 0
fi

if [[ "$cmd1" == "api" && "$cmd2" == "-X" && "${3:-}" == "DELETE" ]]; then
	exit 0
fi

if [[ "$cmd1" == "api" ]]; then
	jq_filter=""; prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then jq_filter="$arg"; fi
		prev="$arg"
	done
	if printf '%s' "$jq_filter" | grep -q 'consolidation-lock'; then
		src_json="${GH_LOCK_MARKERS_JSON:-[]}"
	else
		src_json="${GH_API_COMMENTS_JSON:-[]}"
	fi
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "$src_json" | jq -r "$jq_filter"
	else
		printf '%s\n' "$src_json"
	fi
	exit 0
fi
STUB_API
}

# _append_gh_stub_issue — `gh issue view / list / create / edit / comment`
# plus `gh label create`.
_append_gh_stub_issue() {
	cat >>"${TEST_ROOT}/bin/gh" <<'STUB_ISSUE'

if [[ "$cmd1" == "issue" && "$cmd2" == "view" ]]; then
	shift 2; local_json=""
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
	state,labels,assignees) printf '%s\n' '{"state":"OPEN","labels":[],"assignees":[]}' ;;
	*) printf '\n' ;;
	esac
	exit 0
fi

if [[ "$cmd1" == "issue" && "$cmd2" == "list" ]]; then
	jq_filter=""; state_arg="open"; label_arg=""; prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then jq_filter="$arg"; fi
		if [[ "$prev" == "--state" ]]; then state_arg="$arg"; fi
		if [[ "$prev" == "--label" ]]; then label_arg="$arg"; fi
		prev="$arg"
	done
	case "$label_arg" in
	consolidation-in-progress) src_json="${GH_ISSUE_LIST_LOCK_JSON:-[]}" ;;
	consolidation-task)
		if [[ "$state_arg" == "closed" ]]; then
			src_json="${GH_ISSUE_LIST_CHILD_CLOSED_JSON:-[]}"
		else
			src_json="${GH_ISSUE_LIST_CHILD_JSON:-[]}"
		fi
		;;
	needs-consolidation) src_json="${GH_ISSUE_LIST_NEEDS_JSON:-[]}" ;;
	*) src_json="[]" ;;
	esac
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "$src_json" | jq -r "$jq_filter"
	else
		printf '%s\n' "$src_json"
	fi
	exit 0
fi

if [[ "$cmd1" == "issue" && "$cmd2" == "create" ]]; then
	printf '%s\n' "${GH_ISSUE_CREATE_URL:-https://github.com/owner/repo/issues/999}"
	exit 0
fi
if [[ "$cmd1" == "issue" && "$cmd2" == "edit" ]]; then exit 0; fi
if [[ "$cmd1" == "issue" && "$cmd2" == "comment" ]]; then exit 0; fi
if [[ "$cmd1" == "label" && "$cmd2" == "create" ]]; then exit 0; fi

printf 'gh stub: unhandled: %s\n' "$*" >&2
exit 0
STUB_ISSUE
}

# _write_gh_stub_binary — orchestrator: stitch the header/api/issue sections
# together. Split across three append-helpers to keep every function under
# 100 lines (required by the complexity gate in code-quality.yml).
_write_gh_stub_binary() {
	[[ -n "${TEST_ROOT:-}" ]] || {
		printf 'Error: TEST_ROOT is not set\n' >&2
		return 1
	}
	mkdir -p "${TEST_ROOT}/bin"
	: >"${TEST_ROOT}/bin/gh"
	_append_gh_stub_header
	_append_gh_stub_api
	_append_gh_stub_issue
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

_setup_gh_stub_globals() {
	[[ -n "${TEST_ROOT:-}" ]] || return 1
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_LOG
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"

	export TRIAGE_CACHE_DIR="${TEST_ROOT}/triage-cache"
	mkdir -p "$TRIAGE_CACHE_DIR"
	export ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS=50
	export ISSUE_CONSOLIDATION_COMMENT_THRESHOLD=2
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	printf '{"initialized_repos": []}\n' >"$REPOS_JSON"
	# Tests should never actually sleep during tiebreak re-check.
	export CONSOLIDATION_LOCK_TIEBREAK_WAIT_SEC=0
	# pulse-triage.sh resolves its sub-libraries from SCRIPT_DIR when supplied.
	# Keep the test's own directory separate so it cannot redirect those sources.
	SCRIPT_DIR="${REPO_ROOT}/.agents/scripts"

	# shellcheck disable=SC1091
	source "${REPO_ROOT}/.agents/scripts/pulse-triage.sh"

	# Stub the gh_create_issue wrapper (defined in shared-constants.sh, not
	# sourced here) so _create_consolidation_child_issue reaches the `gh
	# issue create` path. Mirrors test-consolidation-dispatch.sh.
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
		if [[ "$repo_slug" == "owner/repo" || "$repo_slug" == "marcusquinn/aidevops" ]]; then
			return 0
		fi
		return 1
	}
	return 0
}

setup_gh_stub() {
	TEST_ROOT=$(mktemp -d -t t2151-lock.XXXXXX)
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
	unset GH_SELF_LOGIN GH_LOCK_LABEL_PRESENT GH_LOCK_MARKERS_JSON
	unset GH_ISSUE_VIEW_TITLE GH_ISSUE_VIEW_BODY GH_ISSUE_VIEW_LABELS
	unset GH_API_COMMENTS_JSON
	unset GH_ISSUE_LIST_CHILD_JSON GH_ISSUE_LIST_CHILD_CLOSED_JSON
	unset GH_ISSUE_LIST_LOCK_JSON GH_ISSUE_LIST_NEEDS_JSON
	unset GH_ISSUE_CREATE_URL
	unset CONSOLIDATION_LOCK_TTL_HOURS
	return 0
}

# =============================================================================
# Fixture helpers
# =============================================================================

# fixture_two_substantive_comments_t2151 — two human comments clearing the
# substantive threshold. Keeps _dispatch_issue_consolidation on its child-
# creation path (not the "no substantive" short-circuit).
fixture_two_substantive_comments_t2151() {
	cat <<'JSON'
[
  {"user": {"login": "alice", "type": "User"}, "created_at": "2026-04-12T10:00:00Z", "body": "I think we need to add a third failure case for the offline path when the cache is cold."},
  {"user": {"login": "bob", "type": "User"}, "created_at": "2026-04-12T11:30:00Z", "body": "Agree with alice and also the retry policy should back off exponentially rather than linearly."}
]
JSON
}

# fixture_single_marker <runner> <iso> — one lock-marker JSON record
# shaped as returned by _consolidation_lock_markers.
fixture_single_marker() {
	local runner="$1" ts="$2" id="${3:-100}"
	jq -n --arg r "$runner" --arg ts "$ts" --argjson id "$id" '
		[{"id": $id, "body": "<!-- consolidation-lock:runner=\($r) ts=\($ts) -->", "created_at": $ts, "runner": $r}]
	'
}

# fixture_two_markers — two lock markers for race tiebreaker test.
# alice at 10:00:00, bob at 10:00:01. Lexicographic winner = alice.
fixture_two_markers() {
	jq -n '
		[
			{"id": 101, "body": "<!-- consolidation-lock:runner=alice ts=2026-04-16T10:00:00Z -->", "created_at": "2026-04-16T10:00:00Z", "runner": "alice"},
			{"id": 102, "body": "<!-- consolidation-lock:runner=bob ts=2026-04-16T10:00:01Z -->",   "created_at": "2026-04-16T10:00:01Z", "runner": "bob"}
		]
	'
}

# =============================================================================
# Tests
# =============================================================================

# -------------- 1. Happy path: single runner acquires + releases --------------
test_single_runner_acquire_create_release() {
	setup_gh_stub
	export GH_SELF_LOGIN="alice"
	# After the post-marker re-read, only our marker is present.
	export GH_LOCK_MARKERS_JSON
	GH_LOCK_MARKERS_JSON=$(fixture_single_marker "alice" "2026-04-16T10:00:00Z" 101)
	export GH_ISSUE_VIEW_TITLE="test parent"
	export GH_ISSUE_VIEW_BODY="Parent body"
	export GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	export GH_API_COMMENTS_JSON
	GH_API_COMMENTS_JSON=$(fixture_two_substantive_comments_t2151)
	export GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_CREATE_URL="https://github.com/owner/repo/issues/9100"

	local rc=0
	_dispatch_issue_consolidation 100 "owner/repo" "/tmp/fake-path" || rc=$?

	local failures=0 failmsg=""
	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | dispatch returned $rc"
	fi
	if ! grep -qE 'issue edit .* --add-label consolidation-in-progress' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | acquire did not add-label consolidation-in-progress"
	fi
	# Marker comment posted via `gh issue comment --body '<!-- consolidation-lock:...'`
	if ! grep -qE 'issue comment 100 .* consolidation-lock:runner=alice' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | marker comment not posted"
	fi
	if ! grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | child issue was not created"
	fi
	if ! grep -qE 'issue edit .* --remove-label consolidation-in-progress' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | release did not remove-label consolidation-in-progress"
	fi
	if ! grep -qE 'api -X DELETE .*/issues/comments/101' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | release did not delete our marker comment (id=101)"
	fi

	if [[ $failures -eq 0 ]]; then
		print_result "t2151 happy-path: acquire → create child → release" 0
	else
		print_result "t2151 happy-path: acquire → create child → release" 1 "$failmsg"
	fi

	teardown_gh_stub
	return 0
}

# -------------- 2. Race tiebreaker: lexicographically lowest wins --------------
test_race_lexicographic_tiebreaker_loser_yields() {
	setup_gh_stub
	# Self is "bob" — two markers exist (alice+bob), alice wins.
	export GH_SELF_LOGIN="bob"
	export GH_LOCK_MARKERS_JSON
	GH_LOCK_MARKERS_JSON=$(fixture_two_markers)
	export GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	export GH_API_COMMENTS_JSON
	GH_API_COMMENTS_JSON=$(fixture_two_substantive_comments_t2151)
	export GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_CREATE_URL="https://github.com/owner/repo/issues/SHOULD_NOT_BE_CALLED"

	local rc=0
	_dispatch_issue_consolidation 100 "owner/repo" "/tmp/fake-path" || rc=$?

	local failures=0 failmsg=""
	# Loser MUST NOT create the child.
	if grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | loser (bob) created a child despite losing tiebreaker"
	fi
	# Loser MUST delete its own marker (bob's id=102).
	if ! grep -qE 'api -X DELETE .*/issues/comments/102' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | loser did not delete its marker (id=102)"
	fi
	# Loser MUST NOT delete the winner's marker (alice's id=101).
	if grep -qE 'api -X DELETE .*/issues/comments/101' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | loser incorrectly deleted winner's marker (id=101)"
	fi
	# Dispatch MUST still return 0 (yielding is not a failure — parent stays flagged).
	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | dispatch returned $rc (expected 0 on lost-race yield)"
	fi

	if [[ $failures -eq 0 ]]; then
		print_result "t2151 race tiebreaker: lexicographically lowest login wins, loser yields" 0
	else
		print_result "t2151 race tiebreaker: lexicographically lowest login wins, loser yields" 1 "$failmsg"
	fi

	teardown_gh_stub
	return 0
}

# Winner side of the same race — confirms alice both proceeds AND succeeds.
test_race_lexicographic_tiebreaker_winner_proceeds() {
	setup_gh_stub
	export GH_SELF_LOGIN="alice"
	export GH_LOCK_MARKERS_JSON
	GH_LOCK_MARKERS_JSON=$(fixture_two_markers)
	export GH_ISSUE_VIEW_TITLE="test parent"
	export GH_ISSUE_VIEW_BODY="Parent body"
	export GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	export GH_API_COMMENTS_JSON
	GH_API_COMMENTS_JSON=$(fixture_two_substantive_comments_t2151)
	export GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_CREATE_URL="https://github.com/owner/repo/issues/9101"

	local rc=0
	_dispatch_issue_consolidation 100 "owner/repo" "/tmp/fake-path" || rc=$?

	local failures=0 failmsg=""
	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | dispatch returned $rc"
	fi
	if ! grep -q 'issue create' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | winner did not create the child"
	fi
	# Winner (alice) deletes ONLY her own marker (id=101) on release.
	if ! grep -qE 'api -X DELETE .*/issues/comments/101' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | winner did not delete her marker (id=101)"
	fi
	# Winner MUST NOT clear the label (bob's marker still on the parent).
	# The release path calls `issue edit --remove-label` only when no
	# competitor marker remains; GH_LOCK_MARKERS_JSON still contains bob,
	# so no remove-label call should appear in the log.
	if grep -qE 'issue edit .* --remove-label consolidation-in-progress' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | winner cleared lock label despite competitor marker still present"
	fi

	if [[ $failures -eq 0 ]]; then
		print_result "t2151 race tiebreaker: winner proceeds and leaves label for in-flight competitor" 0
	else
		print_result "t2151 race tiebreaker: winner proceeds and leaves label for in-flight competitor" 1 "$failmsg"
	fi

	teardown_gh_stub
	return 0
}

# -------------- 3. Lock label blocks _consolidation_child_exists --------------
test_lock_label_blocks_child_exists() {
	setup_gh_stub
	# No open or closed children, but lock label is on the parent.
	export GH_ISSUE_LIST_CHILD_JSON="[]"
	export GH_ISSUE_LIST_CHILD_CLOSED_JSON="[]"
	export GH_ISSUE_VIEW_LABELS="bug,tier:standard,consolidation-in-progress"

	if _consolidation_child_exists 100 "owner/repo"; then
		print_result "t2151 lock label makes _consolidation_child_exists return 0" 0
	else
		print_result "t2151 lock label makes _consolidation_child_exists return 0" 1 \
			"returned 1 despite consolidation-in-progress label on parent"
	fi

	# Sanity: without the label, the same zero-fixture returns 1 (no-child).
	export GH_ISSUE_VIEW_LABELS="bug,tier:standard"
	if _consolidation_child_exists 100 "owner/repo"; then
		print_result "t2151 no-label sanity check: _consolidation_child_exists returns 1 with no children + no lock" 1 \
			"returned 0 despite empty child lists and no lock label"
	else
		print_result "t2151 no-label sanity check: _consolidation_child_exists returns 1 with no children + no lock" 0
	fi

	teardown_gh_stub
	return 0
}

# -------------- 4. TTL expiry: stuck lock is swept --------------
test_ttl_expiry_clears_stale_lock() {
	setup_gh_stub
	# Set TTL to 1 hour for the test; marker age will be 10 hours.
	export CONSOLIDATION_LOCK_TTL_HOURS=1
	export GH_LOCK_MARKERS_JSON
	local old_ts
	old_ts=$(date -u -d "10 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -v-10H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		printf '%s' "2000-01-01T00:00:00Z")
	GH_LOCK_MARKERS_JSON=$(fixture_single_marker "alice" "$old_ts" 200)

	local rc=0
	_consolidation_ttl_sweep_one "owner/repo" 100 || rc=$?
	# Exit 0 signals "cleared".
	local failures=0 failmsg=""
	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | sweep returned $rc (expected 0 for stale lock)"
	fi
	if ! grep -qE 'issue edit .* --remove-label consolidation-in-progress' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | sweep did not remove label"
	fi
	if ! grep -qE 'api -X DELETE .*/issues/comments/200' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | sweep did not delete stale marker (id=200)"
	fi

	if [[ $failures -eq 0 ]]; then
		print_result "t2151 TTL expiry: stale lock cleared by backfill sweep" 0
	else
		print_result "t2151 TTL expiry: stale lock cleared by backfill sweep" 1 "$failmsg"
	fi

	# Sanity: a fresh marker (recently posted) does NOT get cleared.
	teardown_gh_stub
	setup_gh_stub
	export CONSOLIDATION_LOCK_TTL_HOURS=1
	local fresh_ts
	fresh_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	export GH_LOCK_MARKERS_JSON
	GH_LOCK_MARKERS_JSON=$(fixture_single_marker "alice" "$fresh_ts" 201)

	rc=0
	_consolidation_ttl_sweep_one "owner/repo" 101 || rc=$?
	# Exit 1 signals "lock is fresh".
	if [[ "$rc" -eq 0 ]]; then
		print_result "t2151 TTL expiry: fresh lock is NOT cleared" 1 \
			"sweep returned 0 (cleared) for a freshly-posted marker"
	else
		# Verify no remove-label was emitted.
		if grep -qE 'issue edit .* --remove-label consolidation-in-progress' "$GH_LOG" 2>/dev/null; then
			print_result "t2151 TTL expiry: fresh lock is NOT cleared" 1 \
				"sweep emitted remove-label on a fresh lock"
		else
			print_result "t2151 TTL expiry: fresh lock is NOT cleared" 0
		fi
	fi

	teardown_gh_stub
	return 0
}

# -------------- 5. dispatch-dedup-helper is-assigned honors the lock --------------
#
# dispatch-dedup-helper.sh is designed to be executed as a subprocess, not
# sourced (its tail invokes `main "$@"`, which prints help when sourced with
# no args). We source it in a subshell with output suppressed to extract the
# _has_active_claim function, then unit-test the label recognition logic.
test_is_assigned_honors_lock_label() {
	setup_gh_stub

	# Drive the check via a subshell to contain main's auto-invocation.
	local res_with res_without
	res_with=$(
		# shellcheck disable=SC1091
		source "${REPO_ROOT}/.agents/scripts/dispatch-dedup-helper.sh" >/dev/null 2>&1 || true
		_has_active_claim '{"labels":[{"name":"consolidation-in-progress"}]}'
	)
	res_without=$(
		# shellcheck disable=SC1091
		source "${REPO_ROOT}/.agents/scripts/dispatch-dedup-helper.sh" >/dev/null 2>&1 || true
		_has_active_claim '{"labels":[{"name":"bug"}]}'
	)

	local failures=0 failmsg=""
	if [[ "$res_with" != "true" ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | _has_active_claim with consolidation-in-progress returned '$res_with' (expected 'true')"
	fi
	if [[ "$res_without" != "false" ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | _has_active_claim with no active labels returned '$res_without' (expected 'false')"
	fi

	if [[ $failures -eq 0 ]]; then
		print_result "t2151 dispatch-dedup: _has_active_claim recognises consolidation-in-progress" 0
	else
		print_result "t2151 dispatch-dedup: _has_active_claim recognises consolidation-in-progress" 1 "$failmsg"
	fi

	teardown_gh_stub
	return 0
}

# -------------- 6. Lock release releases label when winner was alone --------------
test_release_clears_label_when_alone() {
	setup_gh_stub
	export GH_SELF_LOGIN="alice"
	# After our release-path re-read, only our marker is present; release
	# should delete our marker AND drop the label.
	export GH_LOCK_MARKERS_JSON
	GH_LOCK_MARKERS_JSON=$(fixture_single_marker "alice" "2026-04-16T10:00:00Z" 301)

	_consolidation_lock_release 100 "owner/repo" "alice"

	local failures=0 failmsg=""
	if ! grep -qE 'api -X DELETE .*/issues/comments/301' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | release did not delete our marker (id=301)"
	fi
	if ! grep -qE 'issue edit .* --remove-label consolidation-in-progress' "$GH_LOG" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | release did not remove label when alone"
	fi

	if [[ $failures -eq 0 ]]; then
		print_result "t2151 release: drops label when no competitor marker remains" 0
	else
		print_result "t2151 release: drops label when no competitor marker remains" 1 "$failmsg"
	fi

	teardown_gh_stub
	return 0
}

main() {
	test_single_runner_acquire_create_release
	test_race_lexicographic_tiebreaker_loser_yields
	test_race_lexicographic_tiebreaker_winner_proceeds
	test_lock_label_blocks_child_exists
	test_ttl_expiry_clears_stale_lock
	test_is_assigned_honors_lock_label
	test_release_clears_label_when_alone

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
