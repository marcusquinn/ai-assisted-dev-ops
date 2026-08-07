#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-interactive-session-post-merge.sh — Regression tests for the post-merge subcommand (t2225)
#
# Covers:
#   1. Positive t2219: For #X + OPEN + status:done → removes status:done, adds status:available
#   2. Temporal hold: For #X + OPEN + status:done + hold body → restores status:blocked
#   3. Negative t2219: Closes #X + OPEN + status:done → NOT touched (legitimate close)
#   4. Positive t2218: For #X + OPEN + origin:interactive + auto-dispatch + assignee=author → unassigns
#   5. Negative t2218: For #X + OPEN + origin:interactive + auto-dispatch + status:in-review → NOT unassigned
#   6. Idempotency: second run on already-healthy PR makes no edits
#   7. Fail-open: unmerged PR → returns 0 without editing
#   8. Both heals fire in same run when applicable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../interactive-session-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_EDIT_LOG=""
GH_COMMENT_LOG=""

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	GH_EDIT_LOG="${TEST_ROOT}/gh_edit.log"
	GH_COMMENT_LOG="${TEST_ROOT}/gh_comment.log"

	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	# Point HOME to TEST_ROOT so no real gh auth is attempted
	export HOME="${TEST_ROOT}"
	mkdir -p "${TEST_ROOT}/.config/aidevops"

	# Stub git for slug resolution fallback
	cat >"${TEST_ROOT}/bin/git" <<'GITEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "remote" && "${2:-}" == "get-url" ]]; then
	printf 'https://github.com/testorg/testrepo.git\n'
	exit 0
fi
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--show-toplevel" ]]; then
	printf '/home/user/Git/testrepo\n'
	exit 0
fi
exit 0
GITEOF
	chmod +x "${TEST_ROOT}/bin/git"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Build a JSON array of single-key objects: [{key:v1},{key:v2},...]
# Args: $1=key $2=csv-values
# Prints the JSON array to stdout.
_build_obj_json_array() {
	local key="$1"
	local csv="$2"
	local result="[" first=1 item
	IFS=',' read -ra _arr <<<"$csv"
	for item in "${_arr[@]}"; do
		item="${item#"${item%%[![:space:]]*}"}"
		item="${item%"${item##*[![:space:]]}"}"
		[[ -n "$item" ]] || continue
		if [[ $first -eq 1 ]]; then
			result+='{"'"$key"'":"'"$item"'"}'
			first=0
		else
			result+=',{"'"$key"'":"'"$item"'"}'
		fi
	done
	result+="]"
	printf '%s' "$result"
	return 0
}

# Create a gh stub that returns constructed PR and issue responses.
#
# Args:
#   pr_body      — PR body text (string)
#   pr_state     — MERGED or OPEN (default MERGED)
#   pr_author    — PR author login (default testauthor)
#   issue_num    — which issue number the stub responds to (default 42)
#   issue_state  — OPEN or CLOSED (default OPEN)
#   issue_labels — comma-separated label names (default "status:available")
#   issue_assignees — comma-separated assignee logins (default "")
#   issue_body    — issue body text (default "")
create_gh_stub() {
	local pr_body="${1:-}"
	local pr_state="${2:-MERGED}"
	local pr_author="${3:-testauthor}"
	local issue_num="${4:-42}"
	local issue_state="${5:-OPEN}"
	local issue_labels_csv="${6:-status:available}"
	local issue_assignees_csv="${7:-}"
	local issue_body="${8:-}"

	local labels_json assignees_json
	labels_json=$(_build_obj_json_array "name" "$issue_labels_csv")
	assignees_json=$(_build_obj_json_array "login" "$issue_assignees_csv")

	# Escape the PR body for embedding in the shell heredoc
	local escaped_body escaped_issue_body
	escaped_body=$(printf '%s' "$pr_body" | sed "s/'/'\\''/g")
	escaped_issue_body=$(printf '%s' "$issue_body" | sed "s/'/'\\''/g")

	local merged_at=""
	if [[ "$pr_state" == "MERGED" ]]; then
		merged_at="2026-04-18T12:00:00Z"
	fi

	local gh_edit_log_path="$GH_EDIT_LOG"
	local gh_comment_log_path="$GH_COMMENT_LOG"

	cat >"${TEST_ROOT}/bin/gh" <<GHEOF
#!/usr/bin/env bash
set -euo pipefail

GH_EDIT_LOG="${gh_edit_log_path}"
GH_COMMENT_LOG="${gh_comment_log_path}"

# auth status — succeed so _isc_gh_reachable passes
if [[ "\${1:-}" == "auth" && "\${2:-}" == "status" ]]; then
	exit 0
fi

# api user — return a user login
if [[ "\${1:-}" == "api" && "\${2:-}" == "user" ]]; then
	printf '{"login":"testauthor"}\n'
	exit 0
fi

# pr view — return PR metadata
if [[ "\${1:-}" == "pr" && "\${2:-}" == "view" ]]; then
	printf '%s\n' '{"state":"${pr_state}","mergedAt":"${merged_at}","body":"${escaped_body}","author":{"login":"${pr_author}"}}'
	exit 0
fi

# issue view — return issue metadata for any issue number
if [[ "\${1:-}" == "issue" && "\${2:-}" == "view" ]]; then
	printf '%s\n' '{"state":"${issue_state}","labels":${labels_json},"assignees":${assignees_json},"body":"${escaped_issue_body}"}'
	exit 0
fi

# issue edit — log the invocation, succeed
if [[ "\${1:-}" == "issue" && "\${2:-}" == "edit" ]]; then
	printf '%s\n' "\$*" >> "\$GH_EDIT_LOG"
	exit 0
fi

# issue comment — log the invocation, succeed
if [[ "\${1:-}" == "issue" && "\${2:-}" == "comment" ]]; then
	printf '%s\n' "\$*" >> "\$GH_COMMENT_LOG"
	exit 0
fi

printf 'unsupported gh invocation in stub: %s\n' "\$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	# Clear logs for each test
	: >"$GH_EDIT_LOG"
	: >"$GH_COMMENT_LOG"
	return 0
}

# ─── Test 1: Positive t2219 — For #X + OPEN + status:done → healed ─────────
test_t2219_for_ref_open_statusdone_healed() {
	local pr_body="For #42"
	create_gh_stub "$pr_body" "MERGED" "testauthor" "42" "OPEN" "status:done,auto-dispatch"

	bash "$HELPER_SCRIPT" post-merge 100 testorg/testrepo >/dev/null 2>&1 || true

	if grep -q "\-\-remove-label status:done" "$GH_EDIT_LOG" && grep -q "\-\-add-label status:available" "$GH_EDIT_LOG"; then
		print_result "t2219: ordinary For #42 false-positive → status:available" 0
	else
		print_result "t2219: ordinary For #42 false-positive → status:available" 1 \
			"Expected status:done → status:available edit; got: $(cat "$GH_EDIT_LOG")"
	fi
	return 0
}

# ─── Test 2: Temporal hold restores status:blocked ───────────────────────────
test_t2219_temporal_hold_restores_blocked() {
	local pr_body="For #42"
	create_gh_stub "$pr_body" "MERGED" "testauthor" "42" "OPEN" \
		"status:done,auto-dispatch" "" "Do not dispatch until 2026-09-01."

	bash "$HELPER_SCRIPT" post-merge 100 testorg/testrepo >/dev/null 2>&1 || true

	if grep -q "\-\-remove-label status:done" "$GH_EDIT_LOG" &&
		grep -q "\-\-add-label status:blocked" "$GH_EDIT_LOG" &&
		grep -q 'status:blocked' "$GH_COMMENT_LOG"; then
		print_result "t2219: explicit temporal hold → status:blocked" 0
	else
		print_result "t2219: explicit temporal hold → status:blocked" 1 \
			"Expected blocked restoration and audit comment; edit=$(cat "$GH_EDIT_LOG") comment=$(cat "$GH_COMMENT_LOG")"
	fi
	return 0
}

# ─── Test 3: Negative t2219 — Closes #X + OPEN + status:done → NOT touched ──
test_t2219_closes_open_statusdone_not_touched() {
	local pr_body="Closes #42"
	create_gh_stub "$pr_body" "MERGED" "testauthor" "42" "OPEN" "status:done,auto-dispatch"

	bash "$HELPER_SCRIPT" post-merge 100 testorg/testrepo >/dev/null 2>&1 || true

	# t2219 heal only fires on For/Ref — Closes must NOT trigger it
	if grep -q "status:done" "$GH_EDIT_LOG" 2>/dev/null; then
		print_result "t2219: Closes #42 + status:done → NOT touched (legitimate close)" 1 \
			"gh issue edit was called with status:done despite Closes keyword"
	else
		print_result "t2219: Closes #42 + status:done → NOT touched (legitimate close)" 0
	fi
	return 0
}

# ─── Test 4: Positive t2218 — For #42 + origin:interactive + auto-dispatch + assignee → unassigned ─
test_t2218_for_ref_interactive_autodispatch_healed() {
	local pr_body="For #42"
	create_gh_stub "$pr_body" "MERGED" "testauthor" "42" "OPEN" \
		"origin:interactive,auto-dispatch,status:queued" "testauthor"

	bash "$HELPER_SCRIPT" post-merge 100 testorg/testrepo >/dev/null 2>&1 || true

	if grep -q "\-\-remove-assignee" "$GH_EDIT_LOG"; then
		print_result "t2218: auto-dispatch + self-assigned + no active status → unassigned" 0
	else
		print_result "t2218: auto-dispatch + self-assigned + no active status → unassigned" 1 \
			"Expected gh issue edit --remove-assignee; got: $(cat "$GH_EDIT_LOG")"
	fi
	return 0
}

# ─── Test 5: Negative t2218 — status:in-review present → NOT unassigned ─────
test_t2218_in_review_not_unassigned() {
	local pr_body="For #42"
	create_gh_stub "$pr_body" "MERGED" "testauthor" "42" "OPEN" \
		"origin:interactive,auto-dispatch,status:in-review" "testauthor"

	bash "$HELPER_SCRIPT" post-merge 100 testorg/testrepo >/dev/null 2>&1 || true

	if grep -q "\-\-remove-assignee" "$GH_EDIT_LOG" 2>/dev/null; then
		print_result "t2218: status:in-review present → NOT unassigned" 1 \
			"gh issue edit --remove-assignee was called despite status:in-review"
	else
		print_result "t2218: status:in-review present → NOT unassigned" 0
	fi
	return 0
}

# ─── Test 6: Idempotency — no status:done, no stale assign → no edits ────────
test_idempotency_no_edits_needed() {
	local pr_body="For #42"
	# Clean issue: no status:done, no stale self-assign (not assigned at all)
	create_gh_stub "$pr_body" "MERGED" "testauthor" "42" "OPEN" \
		"origin:interactive,auto-dispatch,status:available" ""

	bash "$HELPER_SCRIPT" post-merge 100 testorg/testrepo >/dev/null 2>&1 || true

	local edit_count comment_count
	edit_count=$(wc -l <"$GH_EDIT_LOG" 2>/dev/null || echo "0")
	comment_count=$(wc -l <"$GH_COMMENT_LOG" 2>/dev/null || echo "0")

	# Trim whitespace from wc output
	edit_count="${edit_count// /}"
	comment_count="${comment_count// /}"

	if [[ "${edit_count:-0}" -eq 0 && "${comment_count:-0}" -eq 0 ]]; then
		print_result "idempotency: already-healthy PR makes no edits" 0
	else
		print_result "idempotency: already-healthy PR makes no edits" 1 \
			"Expected 0 edits/comments; got edits=$edit_count comments=$comment_count"
	fi
	return 0
}

# ─── Test 7: Fail-open — unmerged PR → exit 0, no edits ─────────────────────
test_failopen_unmerged_pr() {
	local pr_body="For #42"
	create_gh_stub "$pr_body" "OPEN" "testauthor" "42" "OPEN" "status:done"

	local exit_code=0
	bash "$HELPER_SCRIPT" post-merge 100 testorg/testrepo >/dev/null 2>&1 || exit_code=$?

	local edit_count
	edit_count=$(wc -l <"$GH_EDIT_LOG" 2>/dev/null || echo "0")
	edit_count="${edit_count// /}"

	if [[ "$exit_code" -eq 0 && "${edit_count:-0}" -eq 0 ]]; then
		print_result "fail-open: unmerged PR → exit 0, no edits" 0
	else
		print_result "fail-open: unmerged PR → exit 0, no edits" 1 \
			"exit_code=$exit_code edits=$edit_count (expected 0 and 0)"
	fi
	return 0
}

# ─── Test 8: Both heals fire in same run ─────────────────────────────────────
test_both_heals_fire_together() {
	# PR references same issue via For #42; issue has BOTH status:done AND is
	# self-assigned with auto-dispatch + origin:interactive (no active status)
	local pr_body="For #42"
	create_gh_stub "$pr_body" "MERGED" "testauthor" "42" "OPEN" \
		"status:done,origin:interactive,auto-dispatch" "testauthor"

	bash "$HELPER_SCRIPT" post-merge 100 testorg/testrepo >/dev/null 2>&1 || true

	local has_status_edit has_assignee_edit
	has_status_edit=0
	has_assignee_edit=0
	grep -q "status:done" "$GH_EDIT_LOG" 2>/dev/null && has_status_edit=1
	grep -q "\-\-remove-assignee" "$GH_EDIT_LOG" 2>/dev/null && has_assignee_edit=1

	if [[ $has_status_edit -eq 1 && $has_assignee_edit -eq 1 ]]; then
		print_result "both heals fire in same run (t2219 + t2218)" 0
	else
		print_result "both heals fire in same run (t2219 + t2218)" 1 \
			"status_edit=$has_status_edit assignee_edit=$has_assignee_edit (expected both 1)"
	fi
	return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
	setup_test_env

	printf 'Running post-merge regression tests (t2225)...\n\n'

	test_t2219_for_ref_open_statusdone_healed
	test_t2219_temporal_hold_restores_blocked
	test_t2219_closes_open_statusdone_not_touched
	test_t2218_for_ref_interactive_autodispatch_healed
	test_t2218_in_review_not_unassigned
	test_idempotency_no_edits_needed
	test_failopen_unmerged_pr
	test_both_heals_fire_together

	printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"

	teardown_test_env

	if [[ $TESTS_FAILED -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
