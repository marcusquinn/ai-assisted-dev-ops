#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-create-issue-auto-dispatch-skip.sh — t2406 regression guard.
#
# Asserts that `gh_create_issue()` does NOT pass `--assignee` to
# `gh issue create` when the caller's --label set includes `auto-dispatch`.
#
# Production failure (GH#19991, t2406):
#   gh_create_issue() unconditionally self-assigned the caller when the
#   session was interactive, even when auto-dispatch was among the labels.
#   This created the (origin:interactive + assigned + active status) combo
#   that GH#18352/t1996 treats as a permanent dispatch block, stranding
#   the issue until manual unassign or the 1h STAMPLESS_INTERACTIVE_AGE_THRESHOLD
#   safety net (t2148, threshold reduced from 24h to 1h in t2942).
#
# Fix (t2406): early check in gh_create_issue — if the resolved --label set
# contains auto-dispatch, skip self-assignment and emit an [INFO] log line
# matching issue-sync-helper.sh _push_auto_assign_interactive() style.
# origin:interactive label is still applied (t2200 — independent axes).
#
# Tests:
#   1. auto-dispatch in labels → --assignee NOT passed to gh issue create
#   2. auto-dispatch absent    → --assignee IS passed (regression guard)
#   3. auto-dispatch in labels → [INFO] skip log emitted
#   4. auto-dispatch in comma-separated list → --assignee NOT passed
#   5. caller passes explicit --assignee → always forwarded (no override)
#   6. auto-dispatch creation locks and verifies the issue conversation
#
# Stub strategy: define `gh` as a shell function AFTER sourcing the helper.
# Shell functions take precedence over PATH binaries, so the stub captures
# all `gh issue create` invocations without touching PATH.
# _gh_wrapper_auto_sig is fail-open when gh-signature-helper.sh is absent.
#
# Cross-references: GH#19991 / t2406 (fix), GH#19453 / t2157 (rule),
# GH#18352 / t1996 (dedup rule), t2148 (STAMPLESS age threshold).

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
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2406.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
GH_INFO_OUTPUT="${TMP}/info_output.log"

# =============================================================================
# Source shared-constants.sh with quiet stubs to suppress noise.
# Re-override print_* as functions after sourcing — functions beat PATH binaries.
# =============================================================================
print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
export -f print_info print_warning print_error print_success log_verbose

export AIDEVOPS_SESSION_ORIGIN=interactive
export AIDEVOPS_SESSION_USER=testuser

# BASH_SOURCE guard in shared-constants.sh prevents main() from running when sourced
# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

_gh_collaborator_permission_lookup() {
	local _repo_slug="$1"
	local _username="$2"
	local out_var="$3"
	printf -v "$out_var" '%s' "write"
	return 0
}

# =============================================================================
# Post-source stubs.
#
# gh stub: records all calls to GH_CALLS; returns canned responses:
#   gh issue create  → issue URL (so caller gets a valid response)
#   gh api user      → "testuser" (so _gh_wrapper_auto_assignee resolves a user)
#   gh label create  → silent success (ensure_labels_exist path)
#   everything else  → silent success
#
# print_info stub: writes to GH_INFO_OUTPUT so we can assert skip messages.
# =============================================================================
gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"
	if [[ "$1" == "api" && "$2" == "user" ]]; then
		printf '"testuser"\n'
		return 0
	fi
	if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/9991" ]]; then
		printf 'true\n'
		return 0
	fi
	if [[ "$1" == "api" && "$2" == "repos/owner/repo" ]]; then
		printf 'false\n'
		return 0
	fi
	if [[ "$1" == "issue" && "$2" == "create" ]]; then
		printf 'https://github.com/owner/repo/issues/9991\n'
		return 0
	fi
	if [[ "$1" == "issue" && "$2" == "edit" && "${GH_EDIT_FAIL:-0}" == "1" ]]; then
		return 1
	fi
	return 0
}
export -f gh

# shellcheck disable=SC2317
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
export -f print_info

printf '%sRunning gh_create_issue auto-dispatch skip tests (t2406)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — auto-dispatch in labels → --assignee NOT passed to gh issue create
# =============================================================================
: >"$GH_CALLS"
gh_create_issue \
	--repo "owner/repo" \
	--title "t9991: test task" \
	--body "test body" \
	--label "bug,auto-dispatch,tier:standard" >/dev/null 2>&1 || true

# Note: signature footer appended to body adds newlines, so gh issue create args
# may span multiple lines in GH_CALLS. Check the whole file for --assignee.
if ! grep -q -- "--assignee" "$GH_CALLS" 2>/dev/null; then
	pass "auto-dispatch in labels → --assignee NOT passed"
else
	fail "auto-dispatch in labels → --assignee NOT passed" \
		"gh was called with --assignee when auto-dispatch was present"
fi

if grep -q -- "issue lock 9991 --repo owner/repo --reason resolved" "$GH_CALLS" 2>/dev/null &&
	grep -q -- "api repos/owner/repo/issues/9991 --jq .locked == true" "$GH_CALLS" 2>/dev/null; then
	pass "auto-dispatch creation freezes and verifies the issue conversation"
else
	fail "auto-dispatch creation freezes and verifies the issue conversation" \
		"expected issue lock plus independent locked-state read"
fi

# =============================================================================
# Test 2 — auto-dispatch absent → post-create assignment is attempted
# =============================================================================
: >"$GH_CALLS"
gh_create_issue \
	--repo "owner/repo" \
	--title "t9992: test task" \
	--body "test body" \
	--label "bug,tier:standard" >/dev/null 2>&1 || true

# Check whole file: --assignee may appear on a continuation line due to sig footer newlines
if grep -q -- "issue edit 9991 --repo owner/repo --add-assignee testuser" "$GH_CALLS" 2>/dev/null &&
	! grep -q -- "issue create.*--assignee" "$GH_CALLS" 2>/dev/null; then
	pass "no auto-dispatch → durable create then best-effort assignment"
else
	fail "no auto-dispatch → durable create then best-effort assignment" \
		"expected issue edit --add-assignee after an unassigned create"
fi

# =============================================================================
# Test 3 — auto-dispatch in labels → [INFO] skip message emitted
# =============================================================================
: >"$GH_INFO_OUTPUT"
: >"$GH_CALLS"
gh_create_issue \
	--repo "owner/repo" \
	--title "t9993: test task" \
	--body "test body" \
	--label "auto-dispatch" >/dev/null 2>&1 || true

if grep -q "skipping self-assignment per t2157" "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "auto-dispatch → [INFO] skip message logged"
else
	fail "auto-dispatch → [INFO] skip message logged" \
		"expected 'skipping self-assignment per t2157' — got: $(cat "$GH_INFO_OUTPUT" 2>/dev/null || printf '(empty)')"
fi

# =============================================================================
# Test 4 — auto-dispatch as only label → --assignee NOT passed
# =============================================================================
: >"$GH_CALLS"
gh_create_issue \
	--repo "owner/repo" \
	--title "t9994: test task" \
	--body "test body" \
	--label "auto-dispatch" >/dev/null 2>&1 || true

if ! grep -q -- "--assignee" "$GH_CALLS" 2>/dev/null; then
	pass "auto-dispatch only label → --assignee NOT passed"
else
	fail "auto-dispatch only label → --assignee NOT passed" \
		"gh was called with --assignee when auto-dispatch was the only label"
fi

# =============================================================================
# Test 5 — caller passes explicit --assignee → always forwarded unchanged
# =============================================================================
: >"$GH_CALLS"
gh_create_issue \
	--repo "owner/repo" \
	--title "t9995: test task" \
	--body "test body" \
	--label "auto-dispatch,tier:standard" \
	--assignee "explicit-user" >/dev/null 2>&1 || true

# Caller-supplied --assignee should pass through (not auto-assigned, but caller-set)
if grep -q -- "--assignee explicit-user" "$GH_CALLS" 2>/dev/null; then
	pass "explicit --assignee with auto-dispatch → caller assignee forwarded"
else
	fail "explicit --assignee with auto-dispatch → caller assignee forwarded" \
		"expected --assignee explicit-user in gh call"
fi

# =============================================================================
# Test 6 — failed best-effort assignment preserves durable creation success
# =============================================================================
: >"$GH_CALLS"
issue_output=""
issue_rc=0
issue_output=$(GH_EDIT_FAIL=1 gh_create_issue \
	--repo "owner/repo" \
	--title "t9996: durable issue" \
	--body "test body" \
	--label "bug") || issue_rc=$?

if [[ "$issue_rc" -eq 0 && "$issue_output" == *"/issues/9991"* ]] &&
	grep -q -- "issue edit 9991 --repo owner/repo --add-assignee testuser" "$GH_CALLS" 2>/dev/null; then
	pass "assignment failure preserves created issue URL and success status"
else
	fail "assignment failure preserves created issue URL and success status" \
		"rc=${issue_rc}, output=${issue_output}"
fi

# =============================================================================
# Test 7 — confirmed non-collaborator creates without assignment mutation
# =============================================================================
_gh_collaborator_permission_lookup() {
	local _repo_slug="$1"
	local _username="$2"
	local out_var="$3"
	printf -v "$out_var" '%s' "none"
	return 0
}
: >"$GH_CALLS"
gh_create_issue \
	--repo "owner/repo" \
	--title "t9997: contributor issue" \
	--body "test body" \
	--label "bug" >/dev/null 2>&1 || true

if ! grep -q -- "issue edit .*--add-assignee" "$GH_CALLS" 2>/dev/null; then
	pass "non-collaborator creates durable issue without assignment"
else
	fail "non-collaborator creates durable issue without assignment" \
		"unexpected assignment call: $(<"$GH_CALLS")"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
