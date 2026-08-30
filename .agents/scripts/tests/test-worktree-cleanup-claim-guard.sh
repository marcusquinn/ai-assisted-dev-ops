#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-cleanup-claim-guard.sh — t2916/GH#21074 regression guard.
#
# Asserts that worktree cleanup paths consult the interactive-session
# claim-stamp directory before sweeping a worktree. Same source of truth
# as the dispatch-dedup gate.
#
# Tests cover:
#
#   1. _isc_extract_issue_from_branch — pattern matching (gh-NNN, ghNNN,
#      auto-*-ghNNN, t-NNN no-match)
#   2. _isc_branch_has_active_claim — live PID + matching hostname → 0
#   3. _isc_branch_has_active_claim — dead PID → 1
#   4. _isc_branch_has_active_claim — no stamp → 1
#   5. _isc_branch_has_active_claim — cross-host stamp → 0 (trust remote
#      authority for own claims)
#   6. _isc_branch_has_active_claim — unparseable branch (no issue) → 1
#   7. should_skip_cleanup — active claim → skip (regression guard)
#   8. should_skip_cleanup — dead-PID stamp → no skip from claim check
#      (falls through to existing checks)
#   9. should_skip_cleanup — no stamp → existing behaviour preserved
#   10. CLI subcommand `branch-has-active-claim` round-trips correctly
#
# All tests stub `gh` via PATH shim and write real stamp JSON files in a
# sandboxed HOME so no network or real claim state is touched.
#
# Usage:
#   bash .agents/scripts/tests/test-worktree-cleanup-claim-guard.sh

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_PATH="${TEST_SCRIPTS_DIR}/interactive-session-helper.sh"
STAMP_LIB_PATH="${TEST_SCRIPTS_DIR}/interactive-session-helper-stamp.sh"
CLEAN_LIB_PATH="${TEST_SCRIPTS_DIR}/worktree-clean-lib.sh"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

# Keep isolated fixture mutations on native Git. Canonical mutation-guard
# behavior is covered independently and is not part of this claim test.
git() {
	"$GIT_BIN" "$@"
	return $?
}

# NOT readonly — shared-constants.sh declares readonly RED/GREEN/RESET
# and the collision under `set -e` silently kills the test shell.
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

# Sandbox HOME so the stamp dir lands inside the temp root
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/.agent-workspace/interactive-claims"
mkdir -p "${HOME}/.aidevops/logs"

CLAIM_DIR="${HOME}/.aidevops/.agent-workspace/interactive-claims"

# Override WORKER_PROCESS_PATTERN so the test bash process matches when we
# plant a stamp with pid=$$. Default pattern (opencode|claude|Claude) is for
# real worker runtimes; the test process is bash, so we extend it. This must
# be exported so the subprocess CLI invocation (`branch-has-active-claim`)
# inherits it. The shared-constants.sh `[[ -z "${WORKER_PROCESS_PATTERN+x}" ]]`
# guard ensures our value sticks across `source` calls inside the helper.
export WORKER_PROCESS_PATTERN='opencode|claude|Claude|bash'

# -----------------------------------------------------------------------------
# Build a fake git repo for the worktree path so `git -C <path> remote get-url`
# resolves. We use a dummy origin URL pointing at testowner/testrepo.
# -----------------------------------------------------------------------------
FAKE_REPO="${TEST_ROOT}/fake-repo"
mkdir -p "$FAKE_REPO"
(
	cd "$FAKE_REPO" || exit 1
	git init -q -b main 2>/dev/null
	git config user.email "test@test.local"
	git config user.name "Test"
	git remote add origin "https://github.com/testowner/testrepo.git" 2>/dev/null
	# At least one commit so worktree operations don't fail later
	echo "test" >README.md
	git add README.md
	git commit -q -m "init" 2>/dev/null
) || {
	printf '%sFATAL%s could not init fake repo\n' "$TEST_RED" "$TEST_RESET"
	exit 1
}

# Backdate the worktree mtime so `worktree_is_in_grace_period` (4h default)
# returns 1 (outside grace), letting our other safety checks decide. Without
# this, freshly-mkdir'd worktrees fall inside the 4h cliff and trigger a
# grace-period skip, masking the regression-guard signal in tests 8 and 9.
# touch -t YYYYMMDDhhmm — set to ~30h ago.
_old_ts=$(date -u -v-30H +%Y%m%d%H%M 2>/dev/null \
	|| date -u -d "30 hours ago" +%Y%m%d%H%M 2>/dev/null \
	|| echo "202601010000")
touch -t "$_old_ts" "$FAKE_REPO"

# -----------------------------------------------------------------------------
# PATH stub for gh — minimal, just enough for any incidental calls.
# -----------------------------------------------------------------------------
STUB_BIN="${TEST_ROOT}/stub-bin"
mkdir -p "$STUB_BIN"
cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal stub: the claim-guard helper does not call gh, but a transient
# call from a sourced orchestrator would otherwise fail open.
exit 0
STUB
chmod +x "${STUB_BIN}/gh"
export PATH="${STUB_BIN}:${PATH}"

# -----------------------------------------------------------------------------
# Source the orchestrator (which sources stamp.sh, exposing all helpers).
# -----------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$HELPER_PATH" >/dev/null 2>&1
# Helper sets `set -euo pipefail` — drop -e for negative assertions
set +e

# Sanity check
if ! declare -f _isc_extract_issue_from_branch >/dev/null; then
	printf '%sFATAL%s _isc_extract_issue_from_branch not exposed\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi
if ! declare -f _isc_branch_has_active_claim >/dev/null; then
	printf '%sFATAL%s _isc_branch_has_active_claim not exposed\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi

# =============================================================================
# Test 1 — _isc_extract_issue_from_branch pattern matching
# =============================================================================
test_extract_patterns() {
	local rc=0 got
	# gh-NNN with separator
	got=$(_isc_extract_issue_from_branch "feature/gh-21074-active-claim-guard" 2>/dev/null)
	[[ "$got" == "21074" ]] || rc=1
	# ghNNN with separator
	got=$(_isc_extract_issue_from_branch "bugfix/gh18700-foo" 2>/dev/null)
	[[ "$got" == "18700" ]] || rc=1
	# auto-*-ghNNN trailing
	got=$(_isc_extract_issue_from_branch "feature/auto-20260429-062620-gh21074" 2>/dev/null)
	[[ "$got" == "21074" ]] || rc=1
	# t-NNN with separator: structural-only match returns no issue (1)
	_isc_extract_issue_from_branch "feature/t2916-foo" >/dev/null 2>&1
	[[ $? -eq 1 ]] || rc=1
	# Empty branch → 1
	_isc_extract_issue_from_branch "" >/dev/null 2>&1
	[[ $? -eq 1 ]] || rc=1
	print_result "extract_issue_from_branch patterns" "$rc"
}
test_extract_patterns

# =============================================================================
# Test 2 — live PID + matching host → active claim
# =============================================================================
test_live_pid_active() {
	local issue=99001 slug="testowner/testrepo"
	local stamp="${CLAIM_DIR}/testowner-testrepo-${issue}.json"
	local current_host
	current_host=$(hostname 2>/dev/null || echo "unknown")
	# Use the test process's own PID — guaranteed alive.
	jq -n --arg host "$current_host" --argjson pid "$$" '{
		issue: 99001,
		slug: "testowner/testrepo",
		worktree_path: "/tmp/wt-claim-99001",
		claimed_at: "2026-04-29T00:00:00Z",
		pid: $pid,
		hostname: $host,
		user: "testuser"
	}' >"$stamp"

	# We don't have a real worktree-bound branch; the helper derives slug
	# from the worktree path's git remote. Use FAKE_REPO as the worktree
	# arg so slug derivation succeeds.
	_isc_branch_has_active_claim "feature/gh-${issue}-test" --worktree "$FAKE_REPO" >/dev/null 2>&1
	local rc=$?
	rm -f "$stamp"
	if [[ $rc -eq 0 ]]; then
		print_result "live PID + matching host → active claim (exit 0)" 0
	else
		print_result "live PID + matching host → active claim (exit 0)" 1 "(rc=$rc)"
	fi
}
test_live_pid_active

# =============================================================================
# Test 3 — dead PID + matching host → no active claim
# =============================================================================
test_dead_pid_inactive() {
	local issue=99002 slug="testowner/testrepo"
	local stamp="${CLAIM_DIR}/testowner-testrepo-${issue}.json"
	local current_host
	current_host=$(hostname 2>/dev/null || echo "unknown")
	# PID 999999 is overwhelmingly unlikely to be alive.
	jq -n --arg host "$current_host" '{
		issue: 99002,
		slug: "testowner/testrepo",
		worktree_path: "/tmp/wt-claim-99002",
		claimed_at: "2020-01-01T00:00:00Z",
		pid: 999999,
		hostname: $host,
		user: "testuser"
	}' >"$stamp"

	_isc_branch_has_active_claim "feature/gh-${issue}-test" --worktree "$FAKE_REPO" >/dev/null 2>&1
	local rc=$?
	rm -f "$stamp"
	if [[ $rc -eq 1 ]]; then
		print_result "dead PID + matching host → no claim (exit 1)" 0
	else
		print_result "dead PID + matching host → no claim (exit 1)" 1 "(rc=$rc)"
	fi
}
test_dead_pid_inactive

# =============================================================================
# Test 4 — no stamp file → no active claim
# =============================================================================
test_no_stamp() {
	# Ensure no stamp exists for this issue
	rm -f "${CLAIM_DIR}"/testowner-testrepo-99003.json
	_isc_branch_has_active_claim "feature/gh-99003-foo" --worktree "$FAKE_REPO" >/dev/null 2>&1
	local rc=$?
	if [[ $rc -eq 1 ]]; then
		print_result "no stamp → no claim (exit 1)" 0
	else
		print_result "no stamp → no claim (exit 1)" 1 "(rc=$rc)"
	fi
}
test_no_stamp

# =============================================================================
# Test 5 — cross-host stamp → trust remote authority (active claim)
# =============================================================================
test_cross_host_active() {
	local issue=99004
	local stamp="${CLAIM_DIR}/testowner-testrepo-${issue}.json"
	jq -n '{
		issue: 99004,
		slug: "testowner/testrepo",
		worktree_path: "/tmp/wt-claim-99004",
		claimed_at: "2026-04-29T00:00:00Z",
		pid: 999998,
		hostname: "different-host-machine-xyz",
		user: "testuser"
	}' >"$stamp"

	_isc_branch_has_active_claim "feature/gh-${issue}-test" --worktree "$FAKE_REPO" >/dev/null 2>&1
	local rc=$?
	rm -f "$stamp"
	if [[ $rc -eq 0 ]]; then
		print_result "cross-host stamp → trust authority (exit 0)" 0
	else
		print_result "cross-host stamp → trust authority (exit 0)" 1 "(rc=$rc)"
	fi
}
test_cross_host_active

# =============================================================================
# Test 6 — unparseable branch (no issue derivable) → no claim
# =============================================================================
test_unparseable_branch() {
	# `t2916-foo` — t-NNN structural-only path returns no issue; treat as no claim
	_isc_branch_has_active_claim "feature/t2916-active-claim-guard" --worktree "$FAKE_REPO" >/dev/null 2>&1
	local rc=$?
	if [[ $rc -eq 1 ]]; then
		print_result "unparseable branch → no claim (exit 1)" 0
	else
		print_result "unparseable branch → no claim (exit 1)" 1 "(rc=$rc)"
	fi
}
test_unparseable_branch

# =============================================================================
# Test 7 — should_skip_cleanup respects active claim (REGRESSION GUARD)
# =============================================================================
# Source the clean library AND its dependencies. We cannot use sourcing
# directly because worktree-clean-lib.sh expects worktree-helper.sh as the
# orchestrator (provides is_worktree_owned_by_others, log_worktree_removal_event,
# trash_path, etc.). For this regression test we stub those dependencies.
test_should_skip_cleanup_with_claim() {
	# Subshell — keeps function/variable pollution out of subsequent tests.
	local rc
	rc=$(
		set +e
		# Stub deps that worktree-clean-lib.sh expects from its orchestrator
		is_worktree_owned_by_others() { return 1; }   # no other owner
		check_worktree_owner() { echo ""; }
		worktree_is_in_grace_period() { return 1; }   # outside grace
		worktree_has_changes() { return 1; }          # clean
		branch_has_zero_commits_ahead() { return 1; } # has commits
		branch_was_pushed() { return 1; }
		_branch_exists_on_any_remote() { return 0; }
		log_worktree_removal_event() { :; }
		trash_path() { return 0; }
		get_default_branch() { echo "main"; }
		localdev_auto_branch_rm() { :; }
		assert_git_available() { return 0; }
		assert_main_worktree_sane() { return 0; }
		# Fallback colour vars (silence set -u)
		: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
		_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
		_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
		_WTAR_WH_CALLER="${_WTAR_WH_CALLER:-test}"
		export RED GREEN YELLOW BLUE BOLD NC _WTAR_REMOVED _WTAR_SKIPPED _WTAR_WH_CALLER

		# Source the clean lib in this subshell
		# shellcheck source=/dev/null
		source "$CLEAN_LIB_PATH" >/dev/null 2>&1 || exit 9

		# Plant a live-PID stamp for issue 99005
		local issue=99005
		local stamp="${CLAIM_DIR}/testowner-testrepo-${issue}.json"
		local current_host
		current_host=$(hostname 2>/dev/null || echo "unknown")
		jq -n --arg host "$current_host" --argjson pid "$$" '{
			issue: 99005, slug: "testowner/testrepo",
			worktree_path: "'"$FAKE_REPO"'",
			claimed_at: "2026-04-29T00:00:00Z",
			pid: $pid, hostname: $host, user: "testuser"
		}' >"$stamp"

		# Should skip due to active claim. should_skip_cleanup returns 0 = skip.
		should_skip_cleanup "$FAKE_REPO" "feature/gh-${issue}-test" "main" "" "false" >/dev/null 2>&1
		local result=$?
		rm -f "$stamp"
		echo "$result"
	)
	if [[ "$rc" == "0" ]]; then
		print_result "should_skip_cleanup with active claim → skip (regression guard)" 0
	else
		print_result "should_skip_cleanup with active claim → skip (regression guard)" 1 "(rc=$rc)"
	fi
}
test_should_skip_cleanup_with_claim

# =============================================================================
# Test 8 — should_skip_cleanup with DEAD-PID stamp → falls through (no skip
#          from claim check; existing checks may still skip but the claim
#          check itself does not fire).
# =============================================================================
test_should_skip_cleanup_dead_pid() {
	local rc
	rc=$(
		set +e
		is_worktree_owned_by_others() { return 1; }
		check_worktree_owner() { echo ""; }
		worktree_is_in_grace_period() { return 1; }
		worktree_has_changes() { return 1; }
		branch_has_zero_commits_ahead() { return 1; }
		branch_was_pushed() { return 1; }
		_branch_exists_on_any_remote() { return 0; }
		log_worktree_removal_event() { :; }
		trash_path() { return 0; }
		get_default_branch() { echo "main"; }
		localdev_auto_branch_rm() { :; }
		assert_git_available() { return 0; }
		assert_main_worktree_sane() { return 0; }
		: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
		_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
		_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
		_WTAR_WH_CALLER="${_WTAR_WH_CALLER:-test}"
		export RED GREEN YELLOW BLUE BOLD NC _WTAR_REMOVED _WTAR_SKIPPED _WTAR_WH_CALLER

		# shellcheck source=/dev/null
		source "$CLEAN_LIB_PATH" >/dev/null 2>&1 || exit 9

		local issue=99006
		local stamp="${CLAIM_DIR}/testowner-testrepo-${issue}.json"
		local current_host
		current_host=$(hostname 2>/dev/null || echo "unknown")
		jq -n --arg host "$current_host" '{
			issue: 99006, slug: "testowner/testrepo",
			worktree_path: "'"$FAKE_REPO"'",
			claimed_at: "2020-01-01T00:00:00Z",
			pid: 999999, hostname: $host, user: "testuser"
		}' >"$stamp"

		should_skip_cleanup "$FAKE_REPO" "feature/gh-${issue}-test" "main" "" "false" >/dev/null 2>&1
		local result=$?
		rm -f "$stamp"
		echo "$result"
	)
	# All other safety checks stubbed to fall through → expect rc=1 (no skip)
	if [[ "$rc" == "1" ]]; then
		print_result "should_skip_cleanup with dead-PID stamp → no skip from claim check" 0
	else
		print_result "should_skip_cleanup with dead-PID stamp → no skip from claim check" 1 "(rc=$rc)"
	fi
}
test_should_skip_cleanup_dead_pid

# =============================================================================
# Test 9 — should_skip_cleanup with no stamp at all → existing behaviour
#          preserved (regression guard for the no-stamp path).
# =============================================================================
test_should_skip_cleanup_no_stamp() {
	local rc
	rc=$(
		set +e
		is_worktree_owned_by_others() { return 1; }
		check_worktree_owner() { echo ""; }
		worktree_is_in_grace_period() { return 1; }
		worktree_has_changes() { return 1; }
		branch_has_zero_commits_ahead() { return 1; }
		branch_was_pushed() { return 1; }
		_branch_exists_on_any_remote() { return 0; }
		log_worktree_removal_event() { :; }
		trash_path() { return 0; }
		get_default_branch() { echo "main"; }
		localdev_auto_branch_rm() { :; }
		assert_git_available() { return 0; }
		assert_main_worktree_sane() { return 0; }
		: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
		_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
		_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
		_WTAR_WH_CALLER="${_WTAR_WH_CALLER:-test}"
		export RED GREEN YELLOW BLUE BOLD NC _WTAR_REMOVED _WTAR_SKIPPED _WTAR_WH_CALLER

		# shellcheck source=/dev/null
		source "$CLEAN_LIB_PATH" >/dev/null 2>&1 || exit 9

		# No stamp planted; all safety checks stubbed to fall through.
		should_skip_cleanup "$FAKE_REPO" "feature/gh-99007-test" "main" "" "false" >/dev/null 2>&1
		echo "$?"
	)
	if [[ "$rc" == "1" ]]; then
		print_result "should_skip_cleanup with no stamp → existing behaviour preserved" 0
	else
		print_result "should_skip_cleanup with no stamp → existing behaviour preserved" 1 "(rc=$rc)"
	fi
}
test_should_skip_cleanup_no_stamp

# =============================================================================
# Test 10 — CLI subcommand `branch-has-active-claim` round-trips correctly
# =============================================================================
test_cli_subcommand() {
	local issue=99008
	local stamp="${CLAIM_DIR}/testowner-testrepo-${issue}.json"
	local current_host
	current_host=$(hostname 2>/dev/null || echo "unknown")
	jq -n --arg host "$current_host" --argjson pid "$$" '{
		issue: 99008, slug: "testowner/testrepo",
		worktree_path: "'"$FAKE_REPO"'",
		claimed_at: "2026-04-29T00:00:00Z",
		pid: $pid, hostname: $host, user: "testuser"
	}' >"$stamp"

	"$HELPER_PATH" branch-has-active-claim "feature/gh-${issue}-test" --worktree "$FAKE_REPO" >/dev/null 2>&1
	local rc_alive=$?
	local rc_missing_path=0
	(
		cd "$FAKE_REPO" || exit 9
		"$HELPER_PATH" branch-has-active-claim "feature/gh-${issue}-test" \
			--worktree "${TEST_ROOT}/removed-worktree" >/dev/null 2>&1
	) || rc_missing_path=$?

	rm -f "$stamp"
	"$HELPER_PATH" branch-has-active-claim "feature/gh-${issue}-test" --worktree "$FAKE_REPO" >/dev/null 2>&1
	local rc_no_stamp=$?

	# Usage error: no branch arg → rc=2
	"$HELPER_PATH" branch-has-active-claim >/dev/null 2>&1
	local rc_usage=$?

	if [[ $rc_alive -eq 0 && $rc_missing_path -eq 1 && $rc_no_stamp -eq 1 && $rc_usage -eq 2 ]]; then
		print_result "CLI subcommand round-trips" 0
	else
		print_result "CLI subcommand round-trips" 1 \
			"(alive=$rc_alive, missing_path=$rc_missing_path, no_stamp=$rc_no_stamp, usage=$rc_usage)"
	fi
}
test_cli_subcommand

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
