#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _dispatch_pr_fix_worker() and _build_review_feedback_section()
# (t2093).
#
# When a review bot posts CHANGES_REQUESTED on an open worker-authored PR,
# the pulse merge pass must route the feedback to the linked issue and close
# the PR so the dispatch queue can re-pick the task. Before t2093, such PRs
# accumulated indefinitely.
#
# These tests exercise the helpers in isolation with a mock `gh` stub. No
# real repository is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-feedback.sh"  # GH#19836: feedback-routing helpers extracted here

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""
TIMEOUT_CALL_LOG=""

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

# Mock state that each test resets before running.
reset_mock_state() {
	: >"$GH_LOG"
	: >"$TIMEOUT_CALL_LOG"
	unset TEST_TIMEOUT_FAIL_PATTERN
	: >"${TEST_ROOT}/issue-body.txt"
	: >"${TEST_ROOT}/reviews.json"
	: >"${TEST_ROOT}/comments.json"
	# Defaults: populated reviews + comments, empty issue body.
	cat >"${TEST_ROOT}/reviews.json" <<'EOF'
[{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","body":"Two issues in the new helper. Please address before merge.","html_url":"https://github.com/owner/repo/pull/100#pullrequestreview-1"}]
EOF
	cat >"${TEST_ROOT}/comments.json" <<'EOF'
[{"user":{"login":"coderabbitai[bot]"},"path":".agents/scripts/pulse-merge.sh","line":650,"original_line":650,"body":"This check has an off-by-one.","html_url":"https://github.com/owner/repo/pull/100#discussion_r1"}]
EOF
	echo 'Original issue body.' >"${TEST_ROOT}/issue-body.txt"
}

setup_test_paths() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	TIMEOUT_CALL_LOG="${TEST_ROOT}/timeout-calls.log"
	: >"$GH_LOG"
	: >"$TIMEOUT_CALL_LOG"
	export TEST_ROOT GH_LOG TIMEOUT_CALL_LOG
	return 0
}

_gh_with_timeout() {
	local operation="$1"
	shift
	printf '%s %s\n' "$operation" "$*" >>"$TIMEOUT_CALL_LOG"
	if [[ -n "${TEST_TIMEOUT_FAIL_PATTERN:-}" && "$*" == *"$TEST_TIMEOUT_FAIL_PATTERN"* ]]; then
		return 124
	fi
	"$@"
	return $?
}

write_gh_mock_command_cases() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

# Save the full positional arg array before any shifts.
_all_args=("$@")
_subcmd="${1:-} ${2:-}"

case "$_subcmd" in
"label create")
	exit 0
	;;
"pr view")
	if [[ "$*" == *"--json labels"* ]]; then
		printf '%s\n' "origin:worker,auto-dispatch"
		exit 0
	fi
	if [[ "$*" == *"headRefOid,headRefName,isCrossRepository,maintainerCanModify"* ]]; then
		printf 'abc123repairsha\tfix/worker-branch\tfalse\ttrue\n'
		exit 0
	fi
	if [[ "$*" == *"--json headRefName"* ]]; then
		printf 'fix/worker-branch\n'
		exit 0
	fi
	if [[ "$*" == *"--json headRefOid"* ]]; then
		printf 'abc123repairsha\n'
		exit 0
	fi
	exit 0
	;;
"pr checks")
	if [[ "$*" == *"| .name]"* ]]; then
		printf '%s\n' 'Lint'
		exit 0
	fi
	if [[ "$*" == *"conclusion"* ]]; then
		printf '%s\n' 'Unknown JSON field: "conclusion"' >&2
		exit 1
	fi
	if [[ "$*" == *"--json name,bucket,state,link"* ]]; then
		printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
		exit 0
	fi
	exit 0
	;;
"pr close" | "pr edit")
	exit 0
	;;
"issue view")
	if [[ "$*" == *"--json assignees"* ]]; then
		printf '%s\n' 'stale-owner'
		exit 0
	fi
	if [[ "$*" == *"--json body"* ]]; then
		cat "${TEST_ROOT}/issue-body.txt"
		exit 0
	fi
	exit 0
	;;
"issue edit")
	# Capture the --body argument so subsequent views see the updated body.
	while [[ $# -gt 0 ]]; do
		if [[ "$1" == "--body" ]]; then
			shift
			printf '%s' "$1" >"${TEST_ROOT}/issue-body.txt"
			break
		fi
		shift
	done
	exit 0
	;;
esac
GHEOF
	return 0
}

append_gh_mock_api_cases() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
# `gh api repos/...` uses the URL as $2, so the simple `case "$1 $2"`
# pattern above can't match it. Handle api separately.
if [[ "${1:-}" == "api" ]]; then
	# Extract the --jq filter so we can simulate real gh's server-side jq.
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ "$*" == *"/pulls/"*"/reviews"* ]]; then
		if [[ -n "$_jq_filter" ]]; then
			jq "$_jq_filter" <"${TEST_ROOT}/reviews.json"
		else
			cat "${TEST_ROOT}/reviews.json"
		fi
		exit 0
	fi
	if [[ "$*" == *"/pulls/"*"/comments"* ]]; then
		if [[ -n "$_jq_filter" ]]; then
			jq "$_jq_filter" <"${TEST_ROOT}/comments.json"
		else
			cat "${TEST_ROOT}/comments.json"
		fi
		exit 0
	fi
fi

exit 0
GHEOF
	return 0
}

setup_test_env() {
	setup_test_paths

	# Mock gh: logs every call and returns canned data based on the
	# subcommand. Reads/writes to files under TEST_ROOT so tests can
	# inspect/alter state between runs.
	write_gh_mock_command_cases
	append_gh_mock_api_cases
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract helpers under test and eval them in this shell. Same pattern
# as test-pulse-merge-rebase-nudge.sh.
#
# GH#20057: _dispatch_pr_fix_worker now delegates to three shared helpers
# (_append_feedback_to_issue, _transition_issue_for_redispatch,
# _close_and_label_feedback_pr). All four must be eval'd into the test shell
# for the dispatch tests to reach their assertions.
define_helpers_under_test() {
	local fn fn_src
	gh_issue_edit_safe() { gh issue edit "$@"; return $?; }
	gh_pr_checks_exact_json() {
		local repo_slug="$1"
		local pr_number="$2"
		local selection_mode="$3"
		printf 'exact-checks %s %s %s\n' "$repo_slug" "$pr_number" "$selection_mode" >>"$GH_LOG"
		printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
		return 1
	}
	# Functions to extract, in source order. _build_review_feedback_section
	# is used by the "build section" tests; the three shared helpers are
	# required by the refactored _dispatch_pr_fix_worker body.
	local fns=(
		_build_review_feedback_section
		_append_feedback_to_issue
		_transition_issue_for_redispatch
		_close_and_label_feedback_pr
		_ci_check_url_has_infra_failure_log
		_ci_actionable_failed_checks_markdown
		_ci_terminal_failed_check_results
		_build_ci_feedback_section
		_ci_repair_required_checks_json
		_route_ci_repair_fallback
		_ci_repair_hash_text
		_dispatch_ci_fix_worker
		_dispatch_pr_fix_worker
	)
	for fn in "${fns[@]}"; do
		fn_src=$(awk -v name="$fn" '
			$0 ~ "^" name "\\(\\) \\{" { capture = 1 }
			capture { print }
			capture && /^}$/ { capture = 0; exit }
		' "$MERGE_SCRIPT")
		if [[ -z "$fn_src" ]]; then
			printf 'ERROR: could not extract %s from %s\n' "$fn" "$MERGE_SCRIPT" >&2
			return 1
		fi
		# shellcheck disable=SC1090
		eval "$fn_src"
	done
	_classify_ci_failures_by_pattern() { return 0; }
	return 0
}

# =============================================================================
# Tests
# =============================================================================

test_build_section_includes_marker_and_citations() {
	reset_mock_state
	local reviews_json comments_json section
	reviews_json=$(jq '[.[] | {author: .user.login, state: .state, body: .body, url: .html_url}]' <"${TEST_ROOT}/reviews.json")
	comments_json=$(jq '[.[] | {author: .user.login, path: .path, line: (.line // .original_line), body: .body, url: .html_url}]' <"${TEST_ROOT}/comments.json")

	section=$(_build_review_feedback_section "100" "owner/repo" "$reviews_json" "$comments_json")

	if [[ "$section" != *"Review Feedback routed from PR #100"* ]]; then
		print_result "build section includes header with PR number" 1 \
			"Expected 'Review Feedback routed from PR #100' in section"
		return 0
	fi
	if [[ "$section" != *"pulse-merge.sh\`:650"* ]]; then
		print_result "build section includes file:line citation" 1 \
			"Expected 'pulse-merge.sh:650' citation in section. Got: ${section:0:500}"
		return 0
	fi
	if [[ "$section" != *"coderabbitai[bot]"* ]]; then
		print_result "build section includes reviewer login" 1 \
			"Expected 'coderabbitai[bot]' in section"
		return 0
	fi
	if [[ "$section" != *"CHANGES_REQUESTED"* ]]; then
		print_result "build section includes review state" 1 \
			"Expected 'CHANGES_REQUESTED' in section"
		return 0
	fi
	print_result "build section includes header, citations, and reviewer" 0
	return 0
}

test_build_section_empty_when_no_content() {
	reset_mock_state
	local section
	section=$(_build_review_feedback_section "100" "owner/repo" "[]" "[]")
	if [[ -n "$section" ]]; then
		print_result "build section returns empty when no reviews or comments" 1 \
			"Expected empty, got: ${section:0:200}"
		return 0
	fi
	print_result "build section returns empty when no reviews or comments" 0
	return 0
}

test_dispatch_appends_to_issue_body_and_closes_pr() {
	reset_mock_state
	_dispatch_pr_fix_worker "100" "owner/repo" "42"

	# Verify issue body was updated with the marker.
	if ! grep -qF "<!-- t2093:review-feedback:PR100 -->" "${TEST_ROOT}/issue-body.txt"; then
		print_result "dispatch appends marker to issue body" 1 \
			"Expected marker in issue-body.txt. Content: $(cat "${TEST_ROOT}/issue-body.txt")"
		return 0
	fi
	# Verify the original body is preserved above the marker.
	if ! grep -qF "Original issue body." "${TEST_ROOT}/issue-body.txt"; then
		print_result "dispatch preserves original body" 1 \
			"Original body missing after append"
		return 0
	fi
	# Verify PR close was called.
	if ! grep -qF 'gh pr close 100' "$GH_LOG"; then
		print_result "dispatch calls gh pr close on stuck PR" 1 \
			"Expected 'gh pr close 100' in call log"
		return 0
	fi
	# Verify review-routed-to-issue label added to PR.
	if ! grep -qF 'review-routed-to-issue' "$GH_LOG"; then
		print_result "dispatch adds review-routed-to-issue label to PR" 1 \
			"Expected 'review-routed-to-issue' label add in call log"
		return 0
	fi
	# Verify source:review-feedback label added to issue.
	if ! grep -qF 'source:review-feedback' "$GH_LOG"; then
		print_result "dispatch adds source:review-feedback label to issue" 1 \
			"Expected 'source:review-feedback' label add in call log"
		return 0
	fi
	# Verify status transition to available (clears active claim labels).
	if ! grep -qF 'status:available' "$GH_LOG"; then
		print_result "dispatch transitions issue status to available" 1 \
			"Expected 'status:available' in call log"
		return 0
	fi
	if ! grep -qF 'origin:worker' "$GH_LOG"; then
		print_result "dispatch marks issue as worker-owned for redispatch" 1 \
			"Expected 'origin:worker' in call log"
		return 0
	fi
	if ! grep -qF -- '--remove-label origin:interactive' "$GH_LOG"; then
		print_result "dispatch clears stale interactive origin on redispatch" 1 \
			"Expected '--remove-label origin:interactive' in call log"
		return 0
	fi
	if ! grep -qF -- '--remove-assignee stale-owner' "$GH_LOG"; then
		print_result "dispatch removes stale assignee on redispatch" 1 \
			"Expected '--remove-assignee stale-owner' in call log"
		return 0
	fi
	print_result "dispatch appends body, closes PR, transitions labels" 0
	return 0
}

test_dispatch_wraps_paginated_feedback_reads() {
	reset_mock_state
	_dispatch_pr_fix_worker "100" "owner/repo" "42"
	if grep -Fq 'read gh api repos/owner/repo/pulls/100/reviews --paginate' "$TIMEOUT_CALL_LOG" &&
		grep -Fq 'read gh api repos/owner/repo/pulls/100/comments --paginate' "$TIMEOUT_CALL_LOG"; then
		print_result "dispatch wraps paginated review and inline-comment reads" 0
	else
		print_result "dispatch wraps paginated review and inline-comment reads" 1 \
			"timeout calls=$(tr '\n' ';' <"$TIMEOUT_CALL_LOG")"
	fi
	return 0
}

test_dispatch_timeout_fails_open_without_routing_empty_feedback() {
	reset_mock_state
	export TEST_TIMEOUT_FAIL_PATTERN="repos/owner/repo/pulls/100/"
	_dispatch_pr_fix_worker "100" "owner/repo" "42"
	unset TEST_TIMEOUT_FAIL_PATTERN
	if [[ "$(<"${TEST_ROOT}/issue-body.txt")" == "Original issue body." ]] &&
		! grep -qF 'gh pr close 100' "$GH_LOG" &&
		[[ "$(grep -c '^read gh api repos/owner/repo/pulls/100/' "$TIMEOUT_CALL_LOG" 2>/dev/null || true)" == "2" ]]; then
		print_result "timed-out feedback reads fail open without closing the PR" 0
	else
		print_result "timed-out feedback reads fail open without closing the PR" 1 \
			"gh=$(tr '\n' ';' <"$GH_LOG"), timeout=$(tr '\n' ';' <"$TIMEOUT_CALL_LOG")"
	fi
	return 0
}

test_dispatch_idempotent_when_marker_already_present() {
	reset_mock_state
	# Pre-seed the issue body with the marker.
	cat >"${TEST_ROOT}/issue-body.txt" <<'EOF'
Original body.

<!-- t2093:review-feedback:PR100 -->
Previously routed feedback content.
EOF
	: >"$GH_LOG"

	_dispatch_pr_fix_worker "100" "owner/repo" "42"

	# The body should not have been edited again (issue edit --body should
	# not appear in call log). The PR close + label ops still fire —
	# idempotency is scoped to the body append only.
	if grep -qE 'gh issue edit [0-9]+ --repo [^ ]+ --body' "$GH_LOG"; then
		print_result "dispatch skips body update when marker already present" 1 \
			"Unexpected 'issue edit --body' call. Log: $(cat "$GH_LOG")"
		return 0
	fi
	# Sanity check: the marker call path was taken (log entry should mention it).
	if ! grep -qF 'already has routed feedback marker' "$LOGFILE"; then
		print_result "dispatch skips body update when marker already present" 1 \
			"Expected idempotency log message in $LOGFILE"
		return 0
	fi
	print_result "dispatch skips body update when marker already present" 0
	return 0
}

test_dispatch_noop_when_no_substantive_feedback() {
	reset_mock_state
	# Empty reviews and comments -> _build_review_feedback_section returns empty.
	echo '[]' >"${TEST_ROOT}/reviews.json"
	echo '[]' >"${TEST_ROOT}/comments.json"
	: >"$GH_LOG"

	_dispatch_pr_fix_worker "100" "owner/repo" "42"

	# Issue body should be untouched.
	if [[ "$(cat "${TEST_ROOT}/issue-body.txt")" != "Original issue body." ]]; then
		print_result "dispatch leaves issue body untouched when no substantive feedback" 1 \
			"Issue body was modified. Content: $(cat "${TEST_ROOT}/issue-body.txt")"
		return 0
	fi
	# PR close should NOT be called.
	if grep -qF 'gh pr close 100' "$GH_LOG"; then
		print_result "dispatch does not close PR when no substantive feedback" 1 \
			"Unexpected 'gh pr close' in call log"
		return 0
	fi
	print_result "dispatch is a no-op when no substantive feedback" 0
	return 0
}

test_dispatch_noop_on_invalid_inputs() {
	reset_mock_state
	: >"$GH_LOG"

	_dispatch_pr_fix_worker "not-a-number" "owner/repo" "42"
	_dispatch_pr_fix_worker "100" "" "42"
	_dispatch_pr_fix_worker "100" "owner/repo" "not-a-number"
	_dispatch_pr_fix_worker "100" "owner/repo" ""

	# None of the above should have made any gh calls.
	if [[ -s "$GH_LOG" ]]; then
		print_result "dispatch no-ops on invalid inputs" 1 \
			"Expected zero gh calls. Got: $(wc -l <"$GH_LOG") lines"
		return 0
	fi
	print_result "dispatch no-ops on invalid inputs" 0
	return 0
}

test_dispatch_clears_in_progress_labels_as_fallback() {
	reset_mock_state
	: >"$GH_LOG"
	# Force the fallback path: unset set_issue_status for this call.
	unset -f set_issue_status 2>/dev/null || true

	_dispatch_pr_fix_worker "100" "owner/repo" "42"

	if ! grep -qF -- '--remove-label status:in-progress' "$GH_LOG"; then
		print_result "dispatch fallback clears status:in-progress" 1 \
			"Expected '--remove-label status:in-progress' in call log when set_issue_status unavailable"
		return 0
	fi
	if ! grep -qF -- '--remove-label status:in-review' "$GH_LOG"; then
		print_result "dispatch fallback clears status:in-review" 1 \
			"Expected '--remove-label status:in-review' in call log"
		return 0
	fi
	print_result "dispatch fallback clears active-claim status labels" 0
	return 0
}

# ---------------------------------------------------------------
# t2383 Fix 5: _dispatch_pr_fix_worker skips body edit on issue view failure
# When `gh issue view` fails, the function must NOT proceed to
# `gh issue edit` (which would clobber the body with only the feedback).
# ---------------------------------------------------------------
test_dispatch_skips_body_edit_on_issue_view_failure() {
	reset_mock_state

	# Override gh stub to fail on `issue view`
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

_all_args=("$@")
_subcmd="${1:-} ${2:-}"

case "$_subcmd" in
"label create") exit 0 ;;
"pr view") exit 0 ;;
"pr close" | "pr edit") exit 0 ;;
"issue view") exit 1 ;;
"issue edit")
	# Should NOT be reached — if it is, the test fails
	printf 'CLOBBERED' >"${TEST_ROOT}/clobber-marker.txt"
	exit 0
	;;
esac

if [[ "${1:-}" == "api" ]]; then
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	if [[ "$*" == *"/pulls/"*"/reviews"* ]]; then
		if [[ -n "$_jq_filter" ]]; then
			jq "$_jq_filter" <"${TEST_ROOT}/reviews.json"
		else
			cat "${TEST_ROOT}/reviews.json"
		fi
		exit 0
	fi
	if [[ "$*" == *"/pulls/"*"/comments"* ]]; then
		if [[ -n "$_jq_filter" ]]; then
			jq "$_jq_filter" <"${TEST_ROOT}/comments.json"
		else
			cat "${TEST_ROOT}/comments.json"
		fi
		exit 0
	fi
fi
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	: >"$GH_LOG"
	: >"$LOGFILE"
	rm -f "${TEST_ROOT}/clobber-marker.txt"

	_dispatch_pr_fix_worker "100" "owner/repo" "42"

	# The clobber marker should NOT exist (issue edit should not have been called)
	if [[ -f "${TEST_ROOT}/clobber-marker.txt" ]]; then
		print_result "t2383: dispatch skips body edit on issue view failure" 1 \
			"gh issue edit was called after gh issue view failure — data loss risk"
		return 0
	fi

	if ! grep -q "failed to fetch issue.*body.*skipping body edit.*prevent data loss" "$LOGFILE"; then
		print_result "t2383: dispatch logs skip reason on issue view failure" 1 \
			"Expected data-loss prevention log. Got: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "t2383: dispatch skips body edit on issue view failure (data loss guard)" 0
	return 0
}

test_ci_dispatch_dedupes_by_pr_head_marker() {
	reset_mock_state
	: >"$GH_LOG"

	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	_dispatch_ci_fix_worker "100" "owner/repo" "42"
	_route_ci_repair_fallback "100" "owner/repo" "42" "abc123repairsha" "feature/worker" \
		"changed-fingerprint" "retry budget exhausted" "## CI Failure Feedback" "- **Unit**: failure"
	_route_ci_repair_fallback "100" "owner/repo" "42" "abc123repairsha" "feature/worker" \
		"another-fingerprint" "retry budget exhausted" "## CI Failure Feedback" "- **Unit**: failure"

	local body_edit_count pr_close_count
	body_edit_count=$(grep -cE 'gh issue edit 42 --repo owner/repo --body' "$GH_LOG" 2>/dev/null || true)
	pr_close_count=$(grep -cF 'gh pr close 100' "$GH_LOG" 2>/dev/null || true)
	[[ "$body_edit_count" =~ ^[0-9]+$ ]] || body_edit_count=0
	[[ "$pr_close_count" =~ ^[0-9]+$ ]] || pr_close_count=0

	if [[ "$body_edit_count" -ne 1 ]]; then
		print_result "CI repair dispatch writes issue body exactly once per PR/head" 1 \
			"Expected 1 body edit, got ${body_edit_count}. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if [[ "$pr_close_count" -ne 1 ]]; then
		print_result "CI repair dispatch closes PR exactly once per PR/head" 1 \
			"Expected 1 PR close, got ${pr_close_count}. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF '<!-- ci-feedback-fallback:PR100:SHAabc123repairsha -->' "${TEST_ROOT}/issue-body.txt"; then
		print_result "CI repair fallback stores PR/head marker" 1 \
			"Expected fallback marker in issue body. Body: $(cat "${TEST_ROOT}/issue-body.txt")"
		return 0
	fi
	if ! grep -qF 'already has CI repair fallback marker' "$LOGFILE"; then
		print_result "CI repair dispatch logs duplicate skip" 1 \
			"Expected duplicate skip log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "CI repair fallback dedupes changed evidence per PR/head" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_build_section_includes_marker_and_citations
	test_build_section_empty_when_no_content
	test_dispatch_appends_to_issue_body_and_closes_pr
	test_dispatch_wraps_paginated_feedback_reads
	test_dispatch_timeout_fails_open_without_routing_empty_feedback
	test_dispatch_idempotent_when_marker_already_present
	test_dispatch_noop_when_no_substantive_feedback
	test_dispatch_noop_on_invalid_inputs
	test_dispatch_clears_in_progress_labels_as_fallback
	test_ci_dispatch_dedupes_by_pr_head_marker
	test_dispatch_skips_body_edit_on_issue_view_failure

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
