#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-clear-active-status-on-release-preserves-merged-pr.sh — t2746/GH#20520
# regression guard.
#
# Asserts: when `clear_active_status_on_release` is called on an issue whose
# linked PR has already MERGED (so the issue is also already closed), the
# helper preserves the worker's assignee — preserving the closing-time
# audit trail on the issues list.
#
#   1. MERGED linked PR (Resolves/Fixes/Closes) → preserve assignee + in-review
#   2. CLOSED-not-merged linked PR → full cleanup (work didn't complete)
#   3. Planning keywords (Ref/For) still do NOT trigger preserve
#   4. MERGED PR for a different issue → full cleanup
#   5. Mixed OPEN + MERGED PR list → preserve (either state qualifies)
#
# Motivation: workers run on user machines, so the assignee identifies WHICH
# runner's worker completed the work. A closed issue with a preserved
# assignee is the canonical "worker PR merged" audit row on the issues list.
# Without this, a fast merge (CI green before the worker exit trap fires —
# observed as 16s in GH#20484) races the unassign and erases the audit
# trail.
#
# Siblings:
#   test-clear-active-status-on-release-preserves-pr.sh     (OPEN PR case, t2451)
#   test-clear-active-status-on-release-no-pr.sh            (no PR case, pre-t2451)
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
# Case 1: MERGED PR with Resolves #N → preserve assignee + in-review
# -------------------------------------------------------------------
reset_stub
printf '[{"number":20484,"state":"MERGED","body":"Summary.\\n\\nResolves #20520"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo alice
assert_grep "remove-label status:queued" "removes queued when PR merged"
assert_grep "remove-label status:claimed" "removes claimed when PR merged"
assert_grep "remove-label status:in-progress" "removes in-progress when PR merged"
assert_grep "add-label status:done" "projects merged PR as done (Resolves)"
assert_not_grep "remove-assignee" "preserves assignee when PR merged (Resolves)"

# -------------------------------------------------------------------
# Case 2: MERGED PR with Fixes #N → preserve
# -------------------------------------------------------------------
reset_stub
printf '[{"number":99,"state":"MERGED","body":"Fixes #20520 end-to-end."}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo alice
assert_grep "add-label status:done" "projects merged PR as done (Fixes)"
assert_not_grep "remove-assignee" "preserves assignee when PR merged (Fixes)"

# -------------------------------------------------------------------
# Case 3: MERGED PR with closes (lowercase) → preserve
# -------------------------------------------------------------------
reset_stub
printf '[{"number":42,"state":"MERGED","body":"closes #20520"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo alice
assert_not_grep "remove-assignee" "preserves assignee when PR merged (closes, lowercase)"

# -------------------------------------------------------------------
# Case 4: MERGED PR with CASE-INSENSITIVE RESOLVES → preserve
# -------------------------------------------------------------------
reset_stub
printf '[{"number":7,"state":"MERGED","body":"RESOLVES #20520"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo alice
assert_not_grep "remove-assignee" "case-insensitive RESOLVES preserves assignee when merged"

# -------------------------------------------------------------------
# Case 5: CLOSED-not-merged PR with Resolves → DO NOT preserve
#         (work didn't complete; assignee must be cleared so future
#          dispatch isn't blocked by the combined-signal dedup rule)
# -------------------------------------------------------------------
reset_stub
printf '[{"number":123,"state":"CLOSED","body":"Resolves #20520"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo alice
assert_grep "remove-assignee alice" "CLOSED-not-merged PR does NOT preserve assignee"
assert_grep "remove-label status:in-review" "CLOSED-not-merged PR does NOT preserve in-review"

# -------------------------------------------------------------------
# Case 6: MERGED PR with planning keyword (Ref/For) → DO NOT preserve
#         (planning references are tracked as audit links, not as
#          closing keywords — see t2046 PR keyword rule)
# -------------------------------------------------------------------
reset_stub
printf '[{"number":7,"state":"MERGED","body":"For #20520 — phase 1 of tracker"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo alice
assert_grep "remove-assignee alice" "For #N does NOT preserve even when merged"

reset_stub
printf '[{"number":7,"state":"MERGED","body":"Ref #20520"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo alice
assert_grep "remove-assignee alice" "Ref #N does NOT preserve even when merged"

# -------------------------------------------------------------------
# Case 7: MERGED PR referencing a DIFFERENT issue → DO NOT preserve
# -------------------------------------------------------------------
reset_stub
printf '[{"number":7,"state":"MERGED","body":"Resolves #99999"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo alice
assert_grep "remove-assignee alice" "MERGED PR for different issue does NOT preserve"

# -------------------------------------------------------------------
# Case 8: Mixed list with CLOSED-not-merged + MERGED → preserve
#         (any qualifying state is sufficient)
# -------------------------------------------------------------------
reset_stub
printf '[{"number":1,"state":"CLOSED","body":"Resolves #20520"},{"number":2,"state":"MERGED","body":"Resolves #20520"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo alice
assert_not_grep "remove-assignee" "mixed list with MERGED preserves assignee"

# -------------------------------------------------------------------
# Case 9: MERGED PR but worker_login empty → no assignee call,
#         still preserves in-review
# -------------------------------------------------------------------
reset_stub
printf '[{"number":7,"state":"MERGED","body":"Resolves #20520"}]' >"$GH_PR_LIST_JSON"
clear_active_status_on_release 20520 owner/repo ""
assert_not_grep "remove-assignee" "no assignee call when worker_login empty (merged PR)"
assert_grep "add-label status:done" "projects merged PR as done with empty worker_login"
assert_grep "remove-label status:queued" "still removes queued with empty worker_login (merged PR)"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
