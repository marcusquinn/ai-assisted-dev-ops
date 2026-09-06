#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-clear-active-status-on-release-preserves-pr.sh — t2451 regression guard.
#
# Asserts: when `clear_active_status_on_release` is called on an issue that
# has an OPEN linked PR (body contains Resolves/Fixes/Closes #N), the helper:
#
#   1. Does NOT emit --remove-assignee (worker's assignee is preserved)
#   2. Does NOT emit --remove-label status:in-review (label is preserved)
#   3. STILL emits --remove-label for status:queued, status:claimed, status:in-progress
#   4. Removes stale status:available and ensures status:in-review on the issue and PR
#
# Motivation: maintainer-gate.yml Job 1 Check 2 blocks PRs with no assignee.
# Without this behaviour the worker's CLAIM_RELEASED cleanup strands every
# worker PR the moment its exit trap fires — the PR opens, the trap clears
# the assignee, and the gate fires on the next PR push or issue-update event.
#
# Siblings:
#   test-clear-active-status-on-release-preserves-merged-pr.sh (MERGED PR, t2746)
#   test-clear-active-status-on-release-no-pr.sh               (no PR — pre-t2451)
#
# NOTE: not using `set -e` — assertions capture non-zero exits.

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

# Sandbox HOME
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
export GH_CALLS_FILE="${TEST_ROOT}/gh_calls.log"
export GH_VIEW_LABELS="${TEST_ROOT}/gh_view_labels.txt"
export GH_PR_LIST_JSON="${TEST_ROOT}/gh_pr_list.json"

#######################################
# Write a gh stub that:
#   - For `gh issue view --json labels ...` → emits GH_VIEW_LABELS contents
#   - For `gh pr list ...` → emits GH_PR_LIST_JSON contents
#   - For any other gh invocation → records argv and exits 0
#######################################
write_stub_gh() {
	: >"$GH_CALLS_FILE"
	: >"$GH_VIEW_LABELS"
	: >"$GH_PR_LIST_JSON"
cat >"${STUB_DIR}/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == /repos/*/labels\?per_page=100 ]]; then
	printf '%s\t%s\t%s\n' \
		"status:available" "0e8a16" "Task is available for claiming" \
		"status:queued" "fbca04" "Worker dispatched, not yet started" \
		"status:claimed" "f9d0c4" "Interactive implementation is actively claimed" \
		"status:in-progress" "1d76db" "Worker actively running" \
		"status:in-review" "5319e7" "Non-draft PR ready for review/merge" \
		"status:done" "6f42c1" "Task is complete" \
		"status:blocked" "d93f0b" "Partial work blocked; inspect reason and next action"
	exit 0
fi
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	cat "${GH_VIEW_LABELS}" 2>/dev/null || true
	exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
	[[ "${GH_PR_LIST_FAIL:-0}" == "1" ]] && exit 1
	cat "${GH_PR_LIST_JSON}" 2>/dev/null || true
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

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh"

reset_stub() {
	: >"$GH_CALLS_FILE"
	: >"$GH_VIEW_LABELS"
	: >"$GH_PR_LIST_JSON"
	return 0
}

assert_grep() {
	local pattern="$1" label="$2"
	if grep -q -- "$pattern" "$GH_CALLS_FILE" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found in gh calls"
	fi
	return 0
}

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
# Case 1: Resolves #N in body → preserve assignee + in-review
# -------------------------------------------------------------------
reset_stub
	printf '[{"number":20188,"state":"OPEN","isDraft":false,"body":"Some description.\\n\\nResolves #20156"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_grep "remove-label status:queued" "removes queued when PR open"
assert_grep "remove-label status:claimed" "removes claimed when PR open"
assert_grep "remove-label status:in-progress" "removes in-progress when PR open"
assert_grep "remove-label status:available" "removes available when PR open"
assert_grep "add-label status:in-review" "ensures issue in-review when PR open"
assert_not_grep "issue edit 20188 --repo owner/repo" "does not label an already-ready PR"
assert_not_grep "remove-label status:in-review" "preserves in-review when PR open (Resolves)"
assert_not_grep "remove-assignee" "preserves assignee when PR open (Resolves)"

# -------------------------------------------------------------------
# Case 1b: open draft checkpoint is blocked, released, and never review-ready
# -------------------------------------------------------------------
reset_stub
printf '[{"number":20189,"state":"OPEN","isDraft":true,"body":"Resolves #20156"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_grep "add-label status:blocked" "projects open draft as blocked partial work"
assert_grep "remove-assignee alice" "releases draft checkpoint owner"
assert_not_grep "add-label status:in-review" "draft checkpoint is never review-ready"

# -------------------------------------------------------------------
# Case 1c: unavailable PR metadata preserves the prior projection
# -------------------------------------------------------------------
reset_stub
GH_PR_LIST_FAIL=1 clear_active_status_on_release 20156 owner/repo alice
assert_not_grep "issue edit" "unreadable PR metadata performs no lifecycle write"

# -------------------------------------------------------------------
# Case 2: Fixes #N in body → preserve assignee + in-review
# -------------------------------------------------------------------
reset_stub
	printf '[{"number":99,"state":"OPEN","isDraft":false,"body":"Fixes #20156 and adds coverage."}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_not_grep "remove-label status:in-review" "preserves in-review when PR open (Fixes)"
assert_not_grep "remove-assignee" "preserves assignee when PR open (Fixes)"

# -------------------------------------------------------------------
# Case 3: Closes #N in body → preserve assignee + in-review
# -------------------------------------------------------------------
reset_stub
	printf '[{"number":42,"state":"OPEN","isDraft":false,"body":"closes #20156"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_not_grep "remove-label status:in-review" "preserves in-review when PR open (closes, lowercase)"
assert_not_grep "remove-assignee" "preserves assignee when PR open (closes, lowercase)"

# -------------------------------------------------------------------
# Case 4: Case-insensitive keyword matching (RESOLVES, FIXES, CLOSES)
# -------------------------------------------------------------------
reset_stub
	printf '[{"number":7,"state":"OPEN","isDraft":false,"body":"RESOLVES #20156"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_not_grep "remove-assignee" "case-insensitive RESOLVES preserves assignee"

# -------------------------------------------------------------------
# Case 5: Worker_login empty + open PR → no-op on assignee path,
#         still preserves in-review
# -------------------------------------------------------------------
reset_stub
	printf '[{"number":7,"state":"OPEN","isDraft":false,"body":"Resolves #20156"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo ""
assert_not_grep "remove-assignee" "no assignee call when worker_login empty"
assert_not_grep "remove-label status:in-review" "preserves in-review with empty worker_login"
assert_grep "remove-label status:queued" "still removes queued with empty worker_login"

# -------------------------------------------------------------------
# Case 6: Planning reference (For/Ref) does NOT trigger preserve —
#         it's a planning link, not a closing keyword
# -------------------------------------------------------------------
reset_stub
printf '[{"number":7,"state":"OPEN","body":"For #20156 tracking"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_grep "remove-assignee alice" "For #N does NOT trigger preserve (planning keyword)"
assert_grep "remove-label status:in-review" "For #N does NOT preserve in-review (planning keyword)"

reset_stub
printf '[{"number":7,"state":"OPEN","body":"Ref #20156"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_grep "remove-assignee alice" "Ref #N does NOT trigger preserve (planning keyword)"

# -------------------------------------------------------------------
# Case 7: Different issue number in body → does NOT match target
# -------------------------------------------------------------------
reset_stub
printf '[{"number":7,"state":"OPEN","body":"Resolves #99999"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20156 owner/repo alice
assert_grep "remove-assignee alice" "unrelated issue number does not preserve"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
