#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-release-label-mutation.sh — t2420 regression guard.
#
# Asserts the `clear_active_status_on_release` helper in shared-constants.sh:
#
#   1. Removes the 4 active-lifecycle status labels (queued, claimed,
#      in-progress, in-review) in a single gh issue edit call
#   2. Preserves terminal states — NEVER emits --remove-label for
#      status:done, status:blocked, or status:available
#   3. Adds status:available when no linked PR owns the issue
#   4. Removes the worker_login as assignee when provided
#   5. Skips assignee mutation when worker_login is empty
#   6. Cleans valid worker claims on interactive-origin auto-dispatch issues
#      because origin labels are provenance, not workflow permission
#   7. Returns 0 on empty issue_num or repo_slug (idempotent no-op)
#
# Failure history motivating this test: production observation 2026-04-20
# of #19864 and #19738 pinned as status:queued/claimed for 40+ minutes
# after worker completion because _release_dispatch_claim only posted
# a CLAIM_RELEASED comment without clearing the labels that block the
# t1996 combined-signal dedup guard.
#
# NOTE: not using `set -e` — assertions rely on capturing non-zero exits.

set -uo pipefail

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
	return 0
}

# Sandbox HOME so sourcing shared-constants.sh is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
export GH_CALLS_FILE="${TEST_ROOT}/gh_calls.log"
export GH_VIEW_LABELS="${TEST_ROOT}/gh_view_labels.txt"

#######################################
# Write a gh stub that:
#   - For `gh issue view ... --json labels ...` → prints the contents of
#     GH_VIEW_LABELS (empty string = no labels, simulating a fresh issue)
#   - For any other gh invocation (e.g. `gh issue edit ...`) → records the
#     argv to GH_CALLS_FILE and exits 0
#######################################
write_stub_gh() {
	: >"$GH_CALLS_FILE"
	: >"$GH_VIEW_LABELS"
	cat >"${STUB_DIR}/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Stub gh — serves `gh issue view --json labels` from GH_VIEW_LABELS,
# and records all other calls to GH_CALLS_FILE.
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	# Emit whatever the test put in GH_VIEW_LABELS (jq output string form)
	cat "${GH_VIEW_LABELS}" 2>/dev/null || true
	exit 0
fi
printf '%s\n' "$*" >>"${GH_CALLS_FILE}"
exit 0
STUBEOF
	chmod +x "${STUB_DIR}/gh"
	return 0
}

export PATH="${STUB_DIR}:${PATH}"
write_stub_gh

# Locate the script tree the same way the sibling tests do.
TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh"

#######################################
# Reset the gh stub state between cases.
#######################################
reset_stub() {
	: >"$GH_CALLS_FILE"
	: >"$GH_VIEW_LABELS"
	return 0
}

#######################################
# Assert a pattern is present in the recorded gh invocation argv.
#######################################
assert_grep() {
	local pattern="$1" label="$2"
	if grep -q -- "$pattern" "$GH_CALLS_FILE" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found in gh calls"
	fi
	return 0
}

#######################################
# Assert a pattern is ABSENT from the recorded gh invocation argv.
#######################################
assert_not_grep() {
	local pattern="$1" label="$2"
	if grep -q -- "$pattern" "$GH_CALLS_FILE" 2>/dev/null; then
		print_result "$label" 1 "pattern '${pattern}' unexpectedly present"
	else
		print_result "$label" 0
	fi
	return 0
}

# -------------------------------------------------------------------
# Case 1: removes all 4 active labels, preserves terminal labels
# -------------------------------------------------------------------
reset_stub
clear_active_status_on_release 20026 owner/repo worker1
assert_grep "remove-label status:queued" "removes status:queued"
assert_grep "remove-label status:claimed" "removes status:claimed"
assert_grep "remove-label status:in-progress" "removes status:in-progress"
assert_grep "remove-label status:in-review" "removes status:in-review"
assert_grep "add-label status:available" "adds status:available when no linked PR"
assert_not_grep "remove-label status:done" "preserves status:done"
assert_not_grep "remove-label status:blocked" "preserves status:blocked"
assert_not_grep "remove-label status:available" "preserves status:available"

# -------------------------------------------------------------------
# Case 2: removes the worker_login assignee when provided
# -------------------------------------------------------------------
reset_stub
clear_active_status_on_release 20026 owner/repo alice
assert_grep "remove-assignee alice" "removes worker_login assignee"

# -------------------------------------------------------------------
# Case 3: skips assignee mutation when worker_login is empty
# -------------------------------------------------------------------
reset_stub
clear_active_status_on_release 20026 owner/repo ""
assert_not_grep "remove-assignee" "no assignee mutation when empty"
# Labels should still be cleared
assert_grep "remove-label status:queued" "labels still cleared when worker_login empty"

# -------------------------------------------------------------------
# Case 4: cleans a worker claim on an interactive-origin auto-dispatch issue
# -------------------------------------------------------------------
reset_stub
printf 'auto-dispatch,bug,origin:interactive,status:in-progress,tier:standard' >"$GH_VIEW_LABELS"
clear_active_status_on_release 20026 owner/repo alice
assert_grep "remove-label status:in-progress" "clears worker status on interactive-origin auto-dispatch issue"
assert_grep "add-label status:available" "requeues interactive-origin auto-dispatch issue"
assert_grep "remove-assignee alice" "removes worker from interactive-origin auto-dispatch issue"

# -------------------------------------------------------------------
# Case 5: empty issue_num returns 0 without gh call
# -------------------------------------------------------------------
reset_stub
clear_active_status_on_release "" owner/repo alice
rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q "issue edit" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "empty issue_num is idempotent no-op" 0
else
	print_result "empty issue_num is idempotent no-op" 1 "rc=$rc or edit called"
fi

# -------------------------------------------------------------------
# Case 6: empty repo_slug returns 0 without gh call
# -------------------------------------------------------------------
reset_stub
clear_active_status_on_release 20026 "" alice
rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q "issue edit" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "empty repo_slug is idempotent no-op" 0
else
	print_result "empty repo_slug is idempotent no-op" 1 "rc=$rc or edit called"
fi

# -------------------------------------------------------------------
# Case 7: worker-takeover provenance follows the same release cleanup path
# -------------------------------------------------------------------
reset_stub
printf 'bug,origin:worker-takeover,tier:standard' >"$GH_VIEW_LABELS"
clear_active_status_on_release 20026 owner/repo alice
assert_grep "remove-label status:queued" "clears labels on origin:worker-takeover (not interactive)"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
