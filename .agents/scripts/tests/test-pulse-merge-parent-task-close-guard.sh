#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for t2099 / GH#19032: pulse-merge.sh _handle_post_merge_actions
# must NOT call `gh issue close` on linked issues that carry the
# `parent-task` label. Phase-child PRs against parent-roadmap issues
# (t2046) were silently closing their parents on merge because
# _extract_linked_issue falls back to matching "GH#NNN:" in the PR title —
# which is the canonical title format for every phase PR.
#
# Root cause: the t2046 parent-task-keyword-guard prevents the PR body
# from containing Closes/Resolves/Fixes, but the deterministic merge pass
# (pulse-merge.sh:_handle_post_merge_actions) closes the linked issue
# unconditionally after posting the closing comment — there was no
# parent-task label check on that path.
#
# Strategy: extract _handle_post_merge_actions from pulse-merge.sh,
# eval it, and exercise it against a mock `gh` stub that records every
# subcommand invocation. Assert that `gh issue close` is only called
# when the linked issue is NOT parent-task.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
readonly _PM_PARENT_TASK_LABEL_NEEDLE=",parent-task,"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Prepare a mock `gh` that:
#   - Returns the label set from $TEST_LINKED_LABELS when asked for issue metadata
#   - Records every top-level gh invocation to $GH_CALL_LOG
#   - Stays silent for everything else
setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export TEST_LINKED_LABELS="parent-task,refactor"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"

	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh for test-pulse-merge-parent-task-close-guard.sh
# Records every invocation and returns canned data for label queries.
printf '%s\n' "$*" >>"${GH_CALL_LOG}"

# gh api repos/OWNER/REPO/issues/NNN --jq '[.labels[].name] | join(",")'
if [[ "$1" == "api" && "$*" == *"/issues/"* && "$*" == *"labels"* && "$*" != *"/comments"* ]]; then
	printf '%s\n' "${TEST_LINKED_LABELS:-}"
	exit 0
fi

# gh api repos/OWNER/REPO/pulls/NNN  (superseded-PR lookup)
if [[ "$1" == "api" && "$*" == *"/pulls/"* ]]; then
	exit 1
fi

# gh api repos/OWNER/REPO/issues/NNN/comments  (dedup check)
if [[ "$1" == "api" && "$*" == *"/comments"* ]]; then
	printf '[]\n'
	exit 0
fi

# gh issue view/comment/close/pr comment — silent success
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"

	# Stub external helpers the function calls. _release_interactive_claim_on_merge
	# lives in shared-claim-lifecycle.sh (added to the call chain by t2413, and now
	# unguarded — no `|| true` — so the test must stub it explicitly).
	# auto_file_next_phase has `|| true` and invalidate_footprint_cache_for_issue
	# is gated on `declare -F`, so neither needs stubbing.
	unlock_issue_after_worker() { return 0; }
	fast_fail_reset() { return 0; }
	_release_interactive_claim_on_merge() { return 0; }
	set_solved_label() { return 0; }
	auto_file_next_phase() { return 0; }
	_pm_handle_partial_parent_closeout() { return 0; }
	_pm_routing_feedback() { return 1; }
	clear_terminal_issue_dispatch_labels() { return 0; }
	solved_actor_from_pr_labels() { return 1; }
	set_issue_status() { return 0; }
	reconcile_dependants_after_verified_closure() { return 0; }
	_gh_with_timeout() {
		local access_mode="$1"
		shift
		[[ -n "$access_mode" ]] || return 1
		"$@"
		return $?
	}
	export -f unlock_issue_after_worker fast_fail_reset _release_interactive_claim_on_merge \
		set_solved_label auto_file_next_phase _pm_handle_partial_parent_closeout _pm_routing_feedback \
		clear_terminal_issue_dispatch_labels solved_actor_from_pr_labels set_issue_status \
		reconcile_dependants_after_verified_closure _gh_with_timeout 2>/dev/null || true

	# Shim shared-gh-wrappers.sh wrappers → gh binary stub. The function was
	# refactored post-GH#21595 to use gh_pr_comment / gh_issue_comment instead
	# of `gh pr comment` / `gh issue comment` directly. Without these shims,
	# wrapper calls vanish into "command not found" and never reach $GH_CALL_LOG.
	gh_pr_comment() { gh pr comment "$@"; }
	gh_issue_comment() { gh issue comment "$@"; }
	export -f gh_pr_comment gh_issue_comment 2>/dev/null || true

	# gh-signature-helper.sh is invoked via $_sig_helper — stub it to empty.
	export AGENTS_DIR="${TEST_ROOT}"
	mkdir -p "${AGENTS_DIR}/scripts"
	cat >"${AGENTS_DIR}/scripts/gh-signature-helper.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${AGENTS_DIR}/scripts/gh-signature-helper.sh"

	export PULSE_START_EPOCH
	PULSE_START_EPOCH=$(date +%s)
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract the function under test (and its _pm_issue_api dependency, also
# in pulse-merge.sh) and eval them. _pm_issue_api is the module-level helper
# that _handle_post_merge_actions calls to fetch issue metadata; without it
# the eval'd function fails with "_pm_issue_api: command not found"
# (post-GH#21595 helper introduction, t3030).
define_function_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_pm_issue_api\(\) \{/,/^}$/ { print }
		/^_pm_build_closing_comment\(\) \{/,/^}$/ { print }
		/^_pm_select_pr_closeout_comment_id\(\) \{/,/^}$/ { print }
		/^_pm_reconcile_pr_closeout_comments\(\) \{/,/^}$/ { print }
		/^_pm_upsert_pr_closing_comment\(\) \{/,/^}$/ { print }
		/^_pm_resolve_superseded_original_issue\(\) \{/,/^}$/ { print }
		/^_pm_close_primary_linked_issue\(\) \{/,/^}$/ { print }
		/^_pm_close_superseded_original_issue\(\) \{/,/^}$/ { print }
		/^_handle_post_merge_actions\(\) \{/,/^}$/ { print }
		/^_unblock_circuit_breaker_meta_pr\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract _handle_post_merge_actions from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$fn_src"
	return 0
}

# Assert that the gh call log contains / does not contain a pattern.
assert_gh_call_contains() {
	local pattern="$1"
	local label="$2"
	if grep -q -- "$pattern" "$GH_CALL_LOG" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected gh call matching: $pattern"
	fi
	return 0
}

assert_gh_call_not_contains() {
	local pattern="$1"
	local label="$2"
	if grep -q -- "$pattern" "$GH_CALL_LOG" 2>/dev/null; then
		print_result "$label" 1 "Unexpected gh call matching: $pattern"
	else
		print_result "$label" 0
	fi
	return 0
}

test_parent_task_issue_close_is_skipped() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export TEST_LINKED_LABELS="parent-task,refactor,tier:standard"

	_handle_post_merge_actions "19028" "marcusquinn/aidevops" "18735" "phase 1 merged"

	# Closing comment still posted (the comment doubles as a phase-merged status update).
	assert_gh_call_contains "issue comment 18735" \
		"parent-task: closing comment posted to parent on phase merge"

	# gh issue close MUST NOT run against the parent.
	assert_gh_call_not_contains "issue close 18735" \
		"parent-task: gh issue close NOT called on parent"

	# The skip must be logged so operators can audit the merge pass.
	if grep -q "skipping close of parent-task issue #18735" "$LOGFILE"; then
		print_result "parent-task: skip reason logged" 0
	else
		print_result "parent-task: skip reason logged" 1 \
			"Expected 'skipping close of parent-task issue #18735' in $LOGFILE"
	fi
	return 0
}

test_non_parent_issue_close_still_runs() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export TEST_LINKED_LABELS="bug,tier:simple,tooling"

	_handle_post_merge_actions "19028" "marcusquinn/aidevops" "19032" "leaf fix merged"

	# Closing comment posted.
	assert_gh_call_contains "issue comment 19032" \
		"non-parent: closing comment posted"

	# gh issue close MUST run for normal leaf issues (regression guard).
	assert_gh_call_contains "issue close 19032" \
		"non-parent: gh issue close called as before"
	return 0
}

test_empty_labels_does_not_trigger_guard() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export TEST_LINKED_LABELS=""

	_handle_post_merge_actions "19028" "marcusquinn/aidevops" "19999" "no-label issue"

	# Empty label set is not parent-task → close still runs (default behaviour).
	assert_gh_call_contains "issue close 19999" \
		"empty labels: close still runs (not accidentally treated as parent)"
	return 0
}

test_parent_task_substring_false_positive() {
	# Ensure the guard matches the exact label, not a substring.
	# `parent-task-something` should NOT trigger the guard.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export TEST_LINKED_LABELS="parent-task-deprecated,refactor"

	_handle_post_merge_actions "19028" "marcusquinn/aidevops" "19998" "deprecated label"

	# `parent-task-deprecated` is NOT `parent-task` — close should still run.
	assert_gh_call_contains "issue close 19998" \
		"parent-task substring: close still runs (exact-match required)"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_function_under_test; then
		printf 'FATAL: function extraction failed\n' >&2
		return 1
	fi

	test_parent_task_issue_close_is_skipped
	test_non_parent_issue_close_still_runs
	test_empty_labels_does_not_trigger_guard
	test_parent_task_substring_false_positive

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
