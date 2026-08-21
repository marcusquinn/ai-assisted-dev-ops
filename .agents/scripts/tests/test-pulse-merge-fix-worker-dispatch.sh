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
EVENT_LOG=""

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
	: >"$EVENT_LOG"
	unset DRY_RUN TEST_TIMEOUT_FAIL_PATTERN TEST_FAIL_TRANSITION TEST_FAIL_CLOSE \
		TEST_FAIL_REOPEN TEST_FAIL_BODY_PHASE TEST_FAIL_TERMINAL_LABEL \
		TEST_DRIFT_AFTER_TRANSITION_HEAD TEST_FAIL_PR_SNAPSHOT_AFTER_CLOSE \
		TEST_ADD_NMR_DURING_TRANSITION TEST_ADD_PR_PROTECTION_DURING_TRANSITION
	rm -f "${TEST_ROOT}/pr-close-observed" "${TEST_ROOT}/pr-snapshot-failure-consumed"
	: >"${TEST_ROOT}/issue-body.txt"
	printf '[]\n' >"${TEST_ROOT}/issue-comments.json"
	: >"${TEST_ROOT}/reviews.json"
	: >"${TEST_ROOT}/comments.json"
	printf 'OPEN\n' >"${TEST_ROOT}/pr-state.txt"
	printf 'abc123repairsha\n' >"${TEST_ROOT}/pr-head.txt"
	printf 'origin:worker,auto-dispatch\n' >"${TEST_ROOT}/pr-labels.txt"
	printf 'status:in-review,origin:interactive\n' >"${TEST_ROOT}/issue-labels.txt"
	printf 'stale-owner\n' >"${TEST_ROOT}/issue-assignees.txt"
	# Defaults: populated reviews + comments, empty issue body.
	cat >"${TEST_ROOT}/reviews.json" <<'EOF'
[{"id":1001,"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","body":"## Senior review\n\nBLOCK: missing import.\nFix the worker entry point before merge.","html_url":"https://github.com/owner/repo/pull/100#pullrequestreview-1","submitted_at":"2026-08-03T10:00:00Z","commit_id":"abc123repairsha"}]
EOF
	cat >"${TEST_ROOT}/comments.json" <<'EOF'
[{"id":2001,"user":{"login":"coderabbitai[bot]"},"path":".agents/scripts/pulse-merge.sh","line":650,"original_line":650,"body":"This check has an off-by-one.\nSecond actionable line.","html_url":"https://github.com/owner/repo/pull/100#discussion_r1","updated_at":"2026-08-03T10:01:00Z","commit_id":"abc123repairsha"}]
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
	EVENT_LOG="${TEST_ROOT}/route-events.log"
	: >"$GH_LOG"
	: >"$TIMEOUT_CALL_LOG"
	: >"$EVENT_LOG"
	export TEST_ROOT GH_LOG TIMEOUT_CALL_LOG EVENT_LOG
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
		cat "${TEST_ROOT}/pr-labels.txt"
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
"pr close")
	printf 'pr-close\n' >>"${EVENT_LOG}"
	: >"${TEST_ROOT}/pr-close-observed"
	if [[ "${TEST_FAIL_CLOSE:-0}" == "1" ]]; then
		exit 1
	fi
	printf 'CLOSED\n' >"${TEST_ROOT}/pr-state.txt"
	exit 0
	;;
"issue comment")
	_body=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--body" ]]; then
			_body="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done
	jq --arg body "$_body" '. + [{id: ((map(.id // 0) | max // 0) + 1), body:$body, created_at:"2026-08-21T02:38:02Z", author_association:"MEMBER"}]' "${TEST_ROOT}/issue-comments.json" \
		>"${TEST_ROOT}/issue-comments.json.tmp"
	mv "${TEST_ROOT}/issue-comments.json.tmp" "${TEST_ROOT}/issue-comments.json"
	exit 0
	;;
"pr reopen")
	printf 'pr-reopen\n' >>"${EVENT_LOG}"
	if [[ "${TEST_FAIL_REOPEN:-0}" == "1" ]]; then
		exit 1
	fi
	printf 'OPEN\n' >"${TEST_ROOT}/pr-state.txt"
	exit 0
	;;
GHEOF
	return 0
}

append_gh_mock_pr_edit_cases() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
"pr edit")
	if [[ "$*" == *"--add-label review-routed-to-issue"* \
		|| "$*" == *"--add-label conflict-feedback-routed"* \
		|| "$*" == *"--add-label ci-feedback-routed"* ]]; then
		printf 'pr-terminal-label\n' >>"${EVENT_LOG}"
		if [[ "${TEST_FAIL_TERMINAL_LABEL:-0}" == "1" ]]; then
			exit 1
		fi
	fi
	_labels=$(<"${TEST_ROOT}/pr-labels.txt")
	while [[ $# -gt 0 ]]; do
		_action="$1"
		case "$_action" in
		--add-label)
			shift
			_value="${1:-}"
			if [[ ",${_labels}," != *",${_value},"* ]]; then
				_labels="${_labels:+${_labels},}${_value}"
			fi
			;;
		--remove-label)
			shift
			_value="${1:-}"
			_next=""
			IFS=',' read -r -a _parts <<<"$_labels"
			for _part in "${_parts[@]}"; do
				[[ "$_part" == "$_value" ]] && continue
				_next="${_next:+${_next},}${_part}"
			done
			_labels="$_next"
			;;
		esac
		shift || true
	done
	printf '%s\n' "$_labels" >"${TEST_ROOT}/pr-labels.txt"
	exit 0
	;;
"issue view")
	if [[ "$*" == *"--json assignees"* ]]; then
		cat "${TEST_ROOT}/issue-assignees.txt"
		exit 0
	fi
	if [[ "$*" == *"--json body"* ]]; then
		cat "${TEST_ROOT}/issue-body.txt"
		exit 0
	fi
	exit 0
	;;
GHEOF
	return 0
}

append_gh_mock_issue_edit_cases() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GHEOF'
"issue edit")
	_is_transition=0
	if [[ "$*" == *"--body"* ]]; then
		_body_phase="start"
		if [[ "$*" == *"feedback-route:complete"* ]]; then
			_body_phase="complete"
		fi
		printf 'issue-body-%s\n' "$_body_phase" >>"${EVENT_LOG}"
		if [[ "${TEST_FAIL_BODY_PHASE:-}" == "$_body_phase" ]]; then
			exit 1
		fi
	elif [[ "$*" == *"--add-label status:available"* ]]; then
		_is_transition=1
		printf 'issue-transition\n' >>"${EVENT_LOG}"
		if [[ "${TEST_FAIL_TRANSITION:-0}" == "1" ]]; then
			exit 1
		fi
	fi
	_labels=$(<"${TEST_ROOT}/issue-labels.txt")
	_assignees=$(<"${TEST_ROOT}/issue-assignees.txt")
	while [[ $# -gt 0 ]]; do
		_action="$1"
		if [[ "$_action" == "--body" ]]; then
			shift
			printf '%s' "$1" >"${TEST_ROOT}/issue-body.txt"
		elif [[ "$_action" == "--add-label" ]]; then
			shift
			_value="${1:-}"
			if [[ ",${_labels}," != *",${_value},"* ]]; then
				_labels="${_labels:+${_labels},}${_value}"
			fi
		elif [[ "$_action" == "--remove-label" ]]; then
			shift
			_value="${1:-}"
			_next=""
			IFS=',' read -r -a _parts <<<"$_labels"
			for _part in "${_parts[@]}"; do
				[[ "$_part" == "$_value" ]] && continue
				_next="${_next:+${_next},}${_part}"
			done
			_labels="$_next"
		elif [[ "$_action" == "--remove-assignee" ]]; then
			shift
			_value="${1:-}"
			[[ "$_assignees" == "$_value" ]] && _assignees=""
		fi
		shift || true
	done
	if [[ "${TEST_ADD_NMR_DURING_TRANSITION:-0}" == "1" && "$_is_transition" -eq 1 \
		&& ",${_labels}," != *",needs-maintainer-review,"* ]]; then
		_labels="${_labels:+${_labels},}needs-maintainer-review"
	fi
	printf '%s\n' "$_labels" >"${TEST_ROOT}/issue-labels.txt"
	printf '%s' "$_assignees" >"${TEST_ROOT}/issue-assignees.txt"
	if [[ -n "${TEST_DRIFT_AFTER_TRANSITION_HEAD:-}" && "$_is_transition" -eq 1 ]]; then
		printf '%s\n' "$TEST_DRIFT_AFTER_TRANSITION_HEAD" >"${TEST_ROOT}/pr-head.txt"
	fi
	if [[ -n "${TEST_ADD_PR_PROTECTION_DURING_TRANSITION:-}" && "$_is_transition" -eq 1 ]]; then
		_pr_labels=$(<"${TEST_ROOT}/pr-labels.txt")
		if [[ ",${_pr_labels}," != *",${TEST_ADD_PR_PROTECTION_DURING_TRANSITION},"* ]]; then
			printf '%s,%s\n' "$_pr_labels" "$TEST_ADD_PR_PROTECTION_DURING_TRANSITION" >"${TEST_ROOT}/pr-labels.txt"
		fi
	fi
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
	if [[ "$*" == *"/pulls/"*"/files"* ]]; then
		[[ "${AIDEVOPS_GH_ROUTE_DECISION:-}" == "pulse-pr-files-rest" ]] || exit 1
		printf '%s\n' '.agents/scripts/pulse-merge.sh'
		exit 0
	fi
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
	if [[ "${2:-}" == "repos/owner/repo/pulls/100" ]]; then
		if [[ "${TEST_FAIL_PR_SNAPSHOT_AFTER_CLOSE:-0}" == "1" \
			&& -f "${TEST_ROOT}/pr-close-observed" \
			&& ! -f "${TEST_ROOT}/pr-snapshot-failure-consumed" ]]; then
			: >"${TEST_ROOT}/pr-snapshot-failure-consumed"
			exit 1
		fi
		printf '%s\t%s\t%s\n' "$(<"${TEST_ROOT}/pr-state.txt")" \
			"$(<"${TEST_ROOT}/pr-head.txt")" "$(<"${TEST_ROOT}/pr-labels.txt")"
		exit 0
	fi
	if [[ "${2:-}" == "repos/owner/repo/issues/42" ]]; then
		if [[ "$_jq_filter" == *".body"* ]]; then
			cat "${TEST_ROOT}/issue-body.txt"
		else
			printf '%s\t%s\n' "$(<"${TEST_ROOT}/issue-labels.txt")" "$(<"${TEST_ROOT}/issue-assignees.txt")"
		fi
		exit 0
	fi
	if [[ "${2:-}" == "repos/owner/repo/issues/42/comments?per_page=100" ]]; then
		printf '[%s]\n' "$(<"${TEST_ROOT}/issue-comments.json")"
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
	append_gh_mock_pr_edit_cases
	append_gh_mock_issue_edit_cases
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

# Source the feedback module so its head-bound finalizer dependency is exercised
# exactly as Pulse loads it in production.
define_helpers_under_test() {
	gh_issue_edit_safe() { gh issue edit "$@"; return $?; }
	_pulse_merge_invalidate_pr_list_cache() {
		local repo_slug="$1"
		local reason="$2"
		printf 'pr-cache-invalidate %s %s\n' "$repo_slug" "$reason" >>"$EVENT_LOG"
		return 0
	}
	gh_pr_checks_exact_json() {
		local repo_slug="$1"
		local pr_number="$2"
		local selection_mode="$3"
		printf 'exact-checks %s %s %s\n' "$repo_slug" "$pr_number" "$selection_mode" >>"$GH_LOG"
		printf '%s\n' '[{"name":"Lint","bucket":"fail","state":"FAILURE","link":"https://github.com/owner/repo/actions/runs/123/job/456"}]'
		return 1
	}
	unset _PULSE_MERGE_FEEDBACK_LOADED _PULSE_MERGE_FEEDBACK_FINALIZER_LOADED
	# shellcheck disable=SC1090
	source "$MERGE_SCRIPT"
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
	if [[ "$section" != *"  > BLOCK: missing import."* \
		|| "$section" != *"  > Second actionable line."* ]]; then
		print_result "build section preserves multiline review and inline findings" 1 \
			"Expected Markdown-quoted continuation lines. Got: ${section:0:800}"
		return 0
	fi
	print_result "build section includes header, citations, and reviewer" 0
	return 0
}

test_build_section_bounds_total_output() {
	reset_mock_state
	local long_body=""
	local reviews_json=""
	local section=""
	local original_section_limit="$PULSE_REVIEW_FEEDBACK_SECTION_LIMIT"
	while [[ ${#long_body} -lt 16000 ]]; do
		long_body="${long_body}0123456789abcdef"
	done
	reviews_json=$(jq -cn --arg body "$long_body" \
		'[{author:"reviewer",state:"CHANGES_REQUESTED",body:$body,url:"https://github.com/owner/repo/pull/100#review"}]')
	PULSE_REVIEW_FEEDBACK_SECTION_LIMIT=1000
	section=$(_build_review_feedback_section "100" "owner/repo" "$reviews_json" "[]")
	PULSE_REVIEW_FEEDBACK_SECTION_LIMIT="$original_section_limit"
	if [[ ${#section} -gt 1200 \
		|| "$section" != *"Additional review feedback omitted by the bounded router"* ]]; then
		print_result "build section enforces deterministic total bound" 1 \
			"length=${#section}; test_limit=1000"
		return 0
	fi
	print_result "build section enforces deterministic total bound" 0
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
	if ! grep -qE '<!-- t2093:review-feedback:PR100:EVIDENCE[0-9a-f]{64} -->' "${TEST_ROOT}/issue-body.txt"; then
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
	local actual_events=""
	actual_events=$(<"$EVENT_LOG")
	if [[ "$actual_events" != $'issue-body-start\nissue-transition\npr-close\npr-cache-invalidate owner/repo closed feedback-routed PR #100\nissue-body-complete\npr-terminal-label' ]]; then
		print_result "dispatch commits route phases in safe order" 1 \
			"events=$(tr '\n' ';' <"$EVENT_LOG")"
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

test_paginated_feedback_pages_are_merged() {
	local pages_json='[{"id":"1001"}]
[{"id":"1002"},{"id":"1003"}]'
	local merged_json=""

	merged_json=$(_review_feedback_merge_paginated_arrays "$pages_json") || {
		print_result "paginated feedback preserves every API page" 1 "page merge failed"
		return 0
	}
	if [[ "$(printf '%s' "$merged_json" | jq -r 'length')" == "3" \
		&& "$(printf '%s' "$merged_json" | jq -r 'map(.id) | join(",")')" == "1001,1002,1003" ]]; then
		print_result "paginated feedback preserves every API page" 0
	else
		print_result "paginated feedback preserves every API page" 1 "merged=${merged_json}"
	fi
	return 0
}

test_dispatch_timeout_fails_open_without_routing_empty_feedback() {
	reset_mock_state
	export TEST_TIMEOUT_FAIL_PATTERN="repos/owner/repo/pulls/100/"
	local dispatch_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || dispatch_rc=$?
	unset TEST_TIMEOUT_FAIL_PATTERN
	if [[ "$dispatch_rc" -eq "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" \
		&& "$(<"${TEST_ROOT}/issue-body.txt")" == "Original issue body." ]] &&
		! grep -qF 'gh pr close 100' "$GH_LOG" &&
		[[ "$(grep -c '^read gh api repos/owner/repo/pulls/100/' "$TIMEOUT_CALL_LOG" 2>/dev/null || true)" == "2" ]]; then
		print_result "timed-out feedback reads fail open without closing the PR" 0
	else
		print_result "timed-out feedback reads fail open without closing the PR" 1 \
			"gh=$(tr '\n' ';' <"$GH_LOG"), timeout=$(tr '\n' ';' <"$TIMEOUT_CALL_LOG")"
	fi
	return 0
}

test_dispatch_preserves_ambiguous_legacy_marker() {
	reset_mock_state
	# Pre-seed only the legacy marker, without head-bound start/completion evidence.
	cat >"${TEST_ROOT}/issue-body.txt" <<'EOF'
Original body.

<!-- t2093:review-feedback:PR100 -->
Previously routed feedback content.
EOF
	: >"$GH_LOG"

	local dispatch_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || dispatch_rc=$?

	if grep -qE 'gh issue edit [0-9]+ --repo [^ ]+ --body' "$GH_LOG"; then
		print_result "legacy route marker remains untouched" 1 \
			"Unexpected 'issue edit --body' call. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if [[ "$dispatch_rc" -ne "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" ]] \
		|| grep -qF 'gh pr close 100' "$GH_LOG" \
		|| ! grep -qF -- '--add-label hold-for-review' "$GH_LOG" \
		|| grep -qF -- '--add-label needs-maintainer-review' "$GH_LOG" \
		|| ! grep -qF 'legacy review route marker has no head-bound start evidence' "$LOGFILE"; then
		print_result "ambiguous legacy route is preserved for maintainer review" 1 \
			"rc=${dispatch_rc}; gh=$(tr '\n' ';' <"$GH_LOG"); log=$(tr '\n' ';' <"$LOGFILE")"
		return 0
	fi
	print_result "ambiguous legacy route is preserved for maintainer review" 0
	return 0
}

review_route_is_complete() {
	local start_count=0
	local completion_count=0
	start_count=$(grep -cE '<!-- feedback-route:start:review:PR100:SHAabc123repairsha:EVIDENCE[0-9a-f]{64} -->' \
		"${TEST_ROOT}/issue-body.txt" 2>/dev/null || true)
	completion_count=$(grep -cE '<!-- feedback-route:complete:review:PR100:SHAabc123repairsha:EVIDENCE[0-9a-f]{64} -->' \
		"${TEST_ROOT}/issue-body.txt" 2>/dev/null || true)
	[[ "$start_count" -eq 1 && "$completion_count" -eq 1 ]] || return 1
	[[ "$(<"${TEST_ROOT}/pr-state.txt")" == "CLOSED" ]] || return 1
	[[ ",$(<"${TEST_ROOT}/pr-labels.txt")," == *",review-routed-to-issue,"* ]] || return 1
	return 0
}

test_dispatch_retries_after_transition_failure() {
	reset_mock_state
	export TEST_FAIL_TRANSITION=1
	local first_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || first_rc=$?
	unset TEST_FAIL_TRANSITION

	if [[ "$first_rc" -ne "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "OPEN" \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" != *"feedback-route:start:review:PR100:SHAabc123repairsha"* \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" == *"feedback-route:complete:review:PR100:SHAabc123repairsha"* ]]; then
		print_result "transition failure preserves a resumable started route" 1 \
			"rc=${first_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi

	local retry_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || retry_rc=$?
	if [[ "$retry_rc" -ne 0 ]] || ! review_route_is_complete; then
		print_result "started route resumes after issue transition recovers" 1 \
			"rc=${retry_rc}; body=$(tr '\n' ';' <"${TEST_ROOT}/issue-body.txt"); labels=$(<"${TEST_ROOT}/pr-labels.txt")"
		return 0
	fi
	print_result "transition failure defers and resumes without duplicate start evidence" 0
	return 0
}

test_dispatch_preserves_maintainer_hold_racing_transition() {
	reset_mock_state
	export TEST_ADD_NMR_DURING_TRANSITION=1
	local dispatch_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || dispatch_rc=$?
	unset TEST_ADD_NMR_DURING_TRANSITION

	if [[ "$dispatch_rc" -ne "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "OPEN" \
		|| ",$(<"${TEST_ROOT}/issue-labels.txt")," != *",needs-maintainer-review,"* ]] \
		|| grep -qF 'gh pr close 100' "$GH_LOG"; then
		print_result "maintainer hold racing issue transition blocks close" 1 \
			"rc=${dispatch_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); issue_labels=$(<"${TEST_ROOT}/issue-labels.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi
	print_result "maintainer hold racing issue transition is preserved" 0
	return 0
}

test_dispatch_retries_after_close_failure() {
	reset_mock_state
	export TEST_FAIL_CLOSE=1
	local first_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || first_rc=$?
	unset TEST_FAIL_CLOSE

	if [[ "$first_rc" -ne "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "OPEN" \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" == *"feedback-route:complete:review:PR100:SHAabc123repairsha"* ]]; then
		print_result "close failure preserves an incomplete open route" 1 \
			"rc=${first_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi

	local retry_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || retry_rc=$?
	if [[ "$retry_rc" -ne 0 ]] || ! review_route_is_complete; then
		print_result "open route resumes after PR close recovers" 1 \
			"rc=${retry_rc}; body=$(tr '\n' ';' <"${TEST_ROOT}/issue-body.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi
	print_result "close failure defers and resumes without terminal-state drift" 0
	return 0
}

test_dispatch_reopens_when_close_verification_fails() {
	reset_mock_state
	export TEST_FAIL_PR_SNAPSHOT_AFTER_CLOSE=1
	local first_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || first_rc=$?
	unset TEST_FAIL_PR_SNAPSHOT_AFTER_CLOSE

	if [[ "$first_rc" -ne "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "OPEN" \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" == *"feedback-route:complete:review:PR100:SHAabc123repairsha"* ]] \
		|| ! grep -qF 'pr-reopen' "$EVENT_LOG"; then
		print_result "unverified acknowledged close compensates by reopening" 1 \
			"rc=${first_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi

	local retry_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || retry_rc=$?
	if [[ "$retry_rc" -ne 0 ]] || ! review_route_is_complete; then
		print_result "route resumes after close verification recovers" 1 \
			"rc=${retry_rc}; body=$(tr '\n' ';' <"${TEST_ROOT}/issue-body.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi
	print_result "close verification failure reopens and resumes safely" 0
	return 0
}

test_dispatch_reopens_after_completion_write_failure() {
	reset_mock_state
	export TEST_FAIL_BODY_PHASE="complete"
	local first_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || first_rc=$?
	unset TEST_FAIL_BODY_PHASE

	if [[ "$first_rc" -ne "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "OPEN" \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" == *"feedback-route:complete:review:PR100:SHAabc123repairsha"* \
		|| ! -s "$EVENT_LOG" ]] \
		|| ! grep -qF 'pr-reopen' "$EVENT_LOG"; then
		print_result "post-close completion failure compensates by reopening" 1 \
			"rc=${first_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi

	local retry_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || retry_rc=$?
	if [[ "$retry_rc" -ne 0 ]] || ! review_route_is_complete; then
		print_result "compensated route completes on retry" 1 \
			"rc=${retry_rc}; body=$(tr '\n' ';' <"${TEST_ROOT}/issue-body.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi
	print_result "completion-write failure reopens and resumes safely" 0
	return 0
}

test_dispatch_recovers_terminal_label_failure() {
	reset_mock_state
	export TEST_FAIL_TERMINAL_LABEL=1
	local first_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || first_rc=$?
	unset TEST_FAIL_TERMINAL_LABEL

	if [[ "$first_rc" -ne "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "CLOSED" \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" != *"feedback-route:complete:review:PR100:SHAabc123repairsha"* \
		|| ",$(<"${TEST_ROOT}/pr-labels.txt")," == *",review-routed-to-issue,"* ]]; then
		print_result "terminal-label failure exposes partial completion" 1 \
			"rc=${first_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); labels=$(<"${TEST_ROOT}/pr-labels.txt")"
		return 0
	fi

	# Production routing honors both hold labels before recovery. Simulate the
	# maintainer releasing that explicit hold, then verify the completion marker
	# lets the finalizer recover only the missing terminal label.
	printf 'origin:worker,auto-dispatch\n' >"${TEST_ROOT}/pr-labels.txt"
	printf 'status:in-review,origin:worker,source:review-feedback\n' >"${TEST_ROOT}/issue-labels.txt"
	local retry_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || retry_rc=$?
	if [[ "$retry_rc" -ne 0 ]] || ! review_route_is_complete \
		|| [[ ",$(<"${TEST_ROOT}/issue-labels.txt")," == *",needs-maintainer-review,"* \
			|| ",$(<"${TEST_ROOT}/pr-labels.txt")," == *",needs-maintainer-review,"* \
			|| ",$(<"${TEST_ROOT}/issue-labels.txt")," == *",hold-for-review,"* \
			|| ",$(<"${TEST_ROOT}/pr-labels.txt")," == *",hold-for-review,"* ]]; then
		print_result "completed route recovers a missing terminal label" 1 \
			"rc=${retry_rc}; issue_labels=$(<"${TEST_ROOT}/issue-labels.txt"); pr_labels=$(<"${TEST_ROOT}/pr-labels.txt")"
		return 0
	fi
	print_result "required terminal-label failure recovers after maintainer release" 0
	return 0
}

test_dispatch_holds_on_head_drift() {
	reset_mock_state
	export TEST_DRIFT_AFTER_TRANSITION_HEAD="def456newhead"
	local dispatch_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || dispatch_rc=$?
	unset TEST_DRIFT_AFTER_TRANSITION_HEAD

	if [[ "$dispatch_rc" -ne "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "OPEN" \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" == *"feedback-route:complete:review:PR100:SHAabc123repairsha"* \
		|| ",$(<"${TEST_ROOT}/pr-labels.txt")," != *",hold-for-review,"* \
		|| ",$(<"${TEST_ROOT}/issue-labels.txt")," != *",hold-for-review,"* ]] \
		|| grep -qF -- '--add-label needs-maintainer-review' "$GH_LOG"; then
		print_result "head drift preserves the changed PR for maintainer review" 1 \
			"rc=${dispatch_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); head=$(<"${TEST_ROOT}/pr-head.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi
	print_result "head drift never closes a different PR generation" 0
	return 0
}

test_dispatch_holds_when_ownership_changes_during_transition() {
	reset_mock_state
	export TEST_ADD_PR_PROTECTION_DURING_TRANSITION="no-takeover"
	local dispatch_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || dispatch_rc=$?
	unset TEST_ADD_PR_PROTECTION_DURING_TRANSITION

	if [[ "$dispatch_rc" -ne "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "OPEN" \
		|| ",$(<"${TEST_ROOT}/pr-labels.txt")," != *",no-takeover,"* \
		|| ",$(<"${TEST_ROOT}/pr-labels.txt")," != *",hold-for-review,"* ]] \
		|| grep -qF 'gh pr close 100' "$GH_LOG"; then
		print_result "ownership change during transition preserves the PR" 1 \
			"rc=${dispatch_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); labels=$(<"${TEST_ROOT}/pr-labels.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi
	print_result "ownership labels are revalidated before close" 0
	return 0
}

test_dispatch_holds_prior_ci_head_evidence() {
	reset_mock_state
	cat >"${TEST_ROOT}/issue-body.txt" <<'EOF'
Original issue body.

<!-- feedback-route:start:ci:PR100:SHAold123head -->
<!-- ci-feedback-fallback:PR100:SHAold123head -->
Previously routed CI feedback.
EOF
	local dispatch_rc=0
	_route_ci_repair_fallback "100" "owner/repo" "42" "abc123repairsha" \
		"feature/worker" "fingerprint" "retry budget exhausted" \
		"## CI Failure Feedback" "- **Unit**: failure" || dispatch_rc=$?

	if [[ "$dispatch_rc" -ne "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "OPEN" \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" == *"feedback-route:start:ci:PR100:SHAabc123repairsha"* ]] \
		|| grep -qF 'gh pr close 100' "$GH_LOG" \
		|| ! grep -qF 'different PR head' "$LOGFILE"; then
		print_result "prior CI route evidence blocks a new-head close" 1 \
			"rc=${dispatch_rc}; body=$(tr '\n' ';' <"${TEST_ROOT}/issue-body.txt"); events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi
	print_result "changed-head CI route evidence is preserved for maintainer review" 0
	return 0
}

test_dispatch_does_not_transition_started_merged_route() {
	reset_mock_state
	cat >"${TEST_ROOT}/issue-body.txt" <<'EOF'
Original issue body.

<!-- feedback-route:start:review:PR100:SHAabc123repairsha -->
<!-- t2093:review-feedback:PR100 -->
Previously routed review feedback.
EOF
	printf 'MERGED\n' >"${TEST_ROOT}/pr-state.txt"
	local dispatch_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || dispatch_rc=$?

	if [[ "$dispatch_rc" -ne "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" ]] \
		|| grep -qF 'issue-transition' "$EVENT_LOG" \
		|| grep -qF 'gh pr close 100' "$GH_LOG"; then
		print_result "started merged route remains untouched" 1 \
			"rc=${dispatch_rc}; events=$(tr '\n' ';' <"$EVENT_LOG"); gh=$(tr '\n' ';' <"$GH_LOG")"
		return 0
	fi
	print_result "non-open started route is held before issue transition" 0
	return 0
}

test_terminal_guard_rechecks_current_label() {
	reset_mock_state
	local guard_rc=0
	_feedback_route_guard_existing_terminal_label "100" "owner/repo" "42" "review" || guard_rc=$?

	if [[ "$guard_rc" -ne 0 ]] \
		|| grep -Eq -- '--add-label (needs-maintainer-review|hold-for-review)' "$GH_LOG"; then
		print_result "terminal guard accepts a stale caller label after live removal" 1 \
			"rc=${guard_rc}; labels=$(<"${TEST_ROOT}/pr-labels.txt"); gh=$(tr '\n' ';' <"$GH_LOG")"
		return 0
	fi
	print_result "terminal guard revalidates the live routed label" 0
	return 0
}

test_dispatch_holds_reopened_completed_route() {
	reset_mock_state
	cat >"${TEST_ROOT}/issue-body.txt" <<'EOF'
Original issue body.

<!-- feedback-route:start:review:PR100:SHAabc123repairsha -->
<!-- t2093:review-feedback:PR100 -->
Previously routed feedback.
<!-- feedback-route:complete:review:PR100:SHAabc123repairsha -->
EOF
	printf 'origin:worker,auto-dispatch,review-routed-to-issue\n' >"${TEST_ROOT}/pr-labels.txt"
	local dispatch_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || dispatch_rc=$?

	if [[ "$dispatch_rc" -ne "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "OPEN" ]] \
		|| grep -qF 'gh pr close 100' "$GH_LOG" \
		|| ! grep -Eq 'completed same-head review route was reopened|existing review route generation is incomplete or ambiguous' "$LOGFILE"; then
		print_result "manually reopened completed route remains open" 1 \
			"rc=${dispatch_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); gh=$(tr '\n' ';' <"$GH_LOG")"
		return 0
	fi
	print_result "completed same-head route is never automatically reclosed" 0
	return 0
}

current_review_evidence_fingerprint() {
	local reviews_json=""
	local inline_json=""
	reviews_json=$(jq '[.[] | select(.state == "CHANGES_REQUESTED" or ((.body // "") | length) > 30)
		| {id: (.id // "" | tostring), author: (.user.login // "unknown"), state: .state,
		   body: (.body // ""), url: (.html_url // ""),
		   submitted_at: (.submitted_at // ""), commit_id: (.commit_id // "")}]' \
		<"${TEST_ROOT}/reviews.json") || return 1
	inline_json=$(jq '[.[] | {id: (.id // "" | tostring), author: (.user.login // "unknown"),
		path: (.path // ""), line: (.line // .original_line // 0),
		body: (.body // ""), url: (.html_url // ""),
		updated_at: (.updated_at // ""), commit_id: (.commit_id // "")}]' \
		<"${TEST_ROOT}/comments.json") || return 1
	_review_feedback_evidence_fingerprint "$reviews_json" "$inline_json"
	return $?
}

seed_completed_review_generation() {
	local head_sha="$1"
	local evidence_fingerprint="$2"
	cat >"${TEST_ROOT}/issue-body.txt" <<EOF
Original issue body.

<!-- feedback-route:start:review:PR100:SHA${head_sha}:EVIDENCE${evidence_fingerprint} -->
<!-- t2093:review-feedback:PR100:EVIDENCE${evidence_fingerprint} -->
Previously routed review feedback.
<!-- feedback-route:complete:review:PR100:SHA${head_sha}:EVIDENCE${evidence_fingerprint} -->
EOF
	printf 'origin:worker,auto-dispatch,review-routed-to-issue\n' >"${TEST_ROOT}/pr-labels.txt"
	return 0
}

test_dispatch_skips_identical_evidence_on_same_head() {
	reset_mock_state
	local evidence_fingerprint=""
	evidence_fingerprint=$(current_review_evidence_fingerprint) || {
		print_result "same-head review evidence is fingerprintable" 1 "fingerprint unavailable"
		return 0
	}
	seed_completed_review_generation "abc123repairsha" "$evidence_fingerprint"
	: >"$GH_LOG"
	: >"$LOGFILE"
	_dispatch_pr_fix_worker "100" "owner/repo" "42"
	if grep -qF 'gh pr close 100' "$GH_LOG" \
		|| grep -qE 'gh issue edit 42 --repo owner/repo --body' "$GH_LOG" \
		|| ! grep -qF 'was already routed at head abc123repairsha; leaving reopened PR unchanged' "$LOGFILE"; then
		print_result "identical same-head evidence is a no-op" 1 \
			"gh=$(tr '\n' ';' <"$GH_LOG"); log=$(tr '\n' ';' <"$LOGFILE")"
		return 0
	fi
	print_result "identical same-head evidence is a no-op" 0
	return 0
}

test_dispatch_skips_identical_evidence_on_changed_head() {
	reset_mock_state
	local evidence_fingerprint=""
	evidence_fingerprint=$(current_review_evidence_fingerprint) || {
		print_result "identical review evidence is fingerprintable" 1 "fingerprint unavailable"
		return 0
	}
	seed_completed_review_generation "old123repairsha" "$evidence_fingerprint"
	: >"$GH_LOG"
	: >"$LOGFILE"
	_dispatch_pr_fix_worker "100" "owner/repo" "42"
	if grep -qF 'gh pr close 100' "$GH_LOG" \
		|| grep -qE 'gh issue edit 42 --repo owner/repo --body' "$GH_LOG" \
		|| ! grep -qF 'already routed on another head; skipping duplicate route' "$LOGFILE"; then
		print_result "identical evidence stays idempotent across head changes" 1 \
			"gh=$(tr '\n' ';' <"$GH_LOG"); log=$(tr '\n' ';' <"$LOGFILE")"
		return 0
	fi
	print_result "identical evidence stays idempotent across head changes" 0
	return 0
}

test_dispatch_routes_edited_evidence_on_same_head() {
	reset_mock_state
	local prior_fingerprint=""
	local current_fingerprint=""
	prior_fingerprint=$(current_review_evidence_fingerprint) || {
		print_result "prior review evidence is fingerprintable" 1 "fingerprint unavailable"
		return 0
	}
	seed_completed_review_generation "abc123repairsha" "$prior_fingerprint"
	jq '.[0].body += "\nNew same-head blocking finding."' "${TEST_ROOT}/reviews.json" \
		>"${TEST_ROOT}/reviews.next" || return 1
	mv "${TEST_ROOT}/reviews.next" "${TEST_ROOT}/reviews.json"
	current_fingerprint=$(current_review_evidence_fingerprint) || return 1
	: >"$GH_LOG"
	: >"$EVENT_LOG"
	_dispatch_pr_fix_worker "100" "owner/repo" "42"
	if [[ "$current_fingerprint" == "$prior_fingerprint" \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "CLOSED" ]] \
		|| ! grep -qF "EVIDENCE${current_fingerprint}" "${TEST_ROOT}/issue-body.txt" \
		|| ! grep -qF 'New same-head blocking finding.' "${TEST_ROOT}/issue-body.txt" \
		|| ! grep -qF 'gh pr close 100' "$GH_LOG"; then
		print_result "edited evidence routes a new generation on the same head" 1 \
			"prior=${prior_fingerprint}; current=${current_fingerprint}; events=$(tr '\n' ';' <"$EVENT_LOG")"
		return 0
	fi
	print_result "edited evidence routes a new generation on the same head" 0
	return 0
}

test_dispatch_dry_run_has_no_writes() {
	reset_mock_state
	export DRY_RUN=1
	local review_rc=0
	local conflict_rc=0
	local ci_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || review_rc=$?
	_dispatch_conflict_fix_worker "100" "owner/repo" "42" "Conflict" || conflict_rc=$?
	_route_ci_repair_fallback "100" "owner/repo" "42" "abc123repairsha" \
		"feature/worker" "fingerprint" "retry budget exhausted" \
		"## CI Failure Feedback" "- **Unit**: failure" || ci_rc=$?
	unset DRY_RUN

	if [[ "$review_rc" -ne "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" \
		|| "$conflict_rc" -ne "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" \
		|| "$ci_rc" -ne "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" ]] \
		|| grep -Eq '^gh (label create|issue edit|pr (close|edit|reopen))' "$GH_LOG"; then
		print_result "dry-run feedback routing performs no writes" 1 \
			"review_rc=${review_rc}; conflict_rc=${conflict_rc}; ci_rc=${ci_rc}; gh=$(tr '\n' ';' <"$GH_LOG")"
		return 0
	fi
	print_result "dry-run preserves route state without mutations" 0
	return 0
}

test_conflict_dispatch_uses_shared_finalizer() {
	reset_mock_state
	local dispatch_rc=0
	_dispatch_conflict_fix_worker "100" "owner/repo" "42" "Resolve generated-file conflict" || dispatch_rc=$?

	if [[ "$dispatch_rc" -ne 0 \
		|| "$(<"${TEST_ROOT}/pr-state.txt")" != "CLOSED" \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" != *"feedback-route:start:conflict:PR100:SHAabc123repairsha"* \
		|| "$(<"${TEST_ROOT}/issue-body.txt")" != *"feedback-route:complete:conflict:PR100:SHAabc123repairsha"* \
		|| ",$(<"${TEST_ROOT}/pr-labels.txt")," != *",conflict-feedback-routed,"* ]]; then
		print_result "conflict route uses shared head-bound finalizer" 1 \
			"rc=${dispatch_rc}; state=$(<"${TEST_ROOT}/pr-state.txt"); labels=$(<"${TEST_ROOT}/pr-labels.txt"); body=$(tr '\n' ';' <"${TEST_ROOT}/issue-body.txt")"
		return 0
	fi
	print_result "conflict route uses shared head-bound finalizer" 0
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
"pr view")
	if [[ "$*" == *"headRefOid"* ]]; then
		printf 'abc123head\n'
	fi
	exit 0
	;;
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
	if [[ "$*" == *"/pulls/100"* && "$*" != *"/reviews"* && "$*" != *"/comments"* ]]; then
		printf 'OPEN\tabc123head\t\n'
		exit 0
	fi
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

	local dispatch_rc=0
	_dispatch_pr_fix_worker "100" "owner/repo" "42" || dispatch_rc=$?

	# The clobber marker should NOT exist (issue edit should not have been called)
	if [[ -f "${TEST_ROOT}/clobber-marker.txt" \
		|| "$dispatch_rc" -ne "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" ]]; then
		print_result "t2383: dispatch skips body edit on issue view failure" 1 \
			"gh issue edit was called after gh issue view failure or rc was not deferred (rc=${dispatch_rc})"
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
	local claim_release_count
	claim_release_count=$(grep -cF 'CLAIM_RELEASED reason=feedback_route_ci' "$GH_LOG" 2>/dev/null || true)
	[[ "$body_edit_count" =~ ^[0-9]+$ ]] || body_edit_count=0
	[[ "$pr_close_count" =~ ^[0-9]+$ ]] || pr_close_count=0
	[[ "$claim_release_count" =~ ^[0-9]+$ ]] || claim_release_count=0

	if [[ "$body_edit_count" -ne 2 ]]; then
		print_result "CI repair dispatch writes start and completion evidence once per PR/head" 1 \
			"Expected 2 body edits, got ${body_edit_count}. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if [[ "$pr_close_count" -ne 1 ]]; then
		print_result "CI repair dispatch closes PR exactly once per PR/head" 1 \
			"Expected 1 PR close, got ${pr_close_count}. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if [[ "$claim_release_count" -ne 1 ]]; then
		print_result "CI repair fallback retires the prior dispatch claim exactly once" 1 \
			"Expected 1 CLAIM_RELEASED comment, got ${claim_release_count}. Log: $(cat "$GH_LOG")"
		return 0
	fi
	if ! grep -qF '<!-- ci-feedback-fallback:PR100:SHAabc123repairsha -->' "${TEST_ROOT}/issue-body.txt"; then
		print_result "CI repair fallback stores PR/head marker" 1 \
			"Expected fallback marker in issue body. Body: $(cat "${TEST_ROOT}/issue-body.txt")"
		return 0
	fi
	if ! grep -qF '<!-- feedback-route:start:ci:PR100:SHAabc123repairsha -->' "${TEST_ROOT}/issue-body.txt" \
		|| ! grep -qF '<!-- feedback-route:complete:ci:PR100:SHAabc123repairsha -->' "${TEST_ROOT}/issue-body.txt"; then
		print_result "CI repair fallback stores head-bound start and completion evidence" 1 \
			"Expected transaction markers in issue body. Body: $(cat "${TEST_ROOT}/issue-body.txt")"
		return 0
	fi
	print_result "CI repair fallback dedupes changed evidence per PR/head" 0
	return 0
}

test_feedback_release_reconciles_cross_runner_duplicates() {
	reset_mock_state
	cat >"${TEST_ROOT}/issue-comments.json" <<'EOF'
[{"id":11,"created_at":"2026-08-21T02:38:02Z","author_association":"MEMBER","body":"CLAIM_RELEASED reason=feedback_route_ci runner=pulse ts=2026-08-21T02:37:59Z\n<!-- feedback-route:dispatch-release:ci:PR100:SHAabc123repairsha -->"},{"id":12,"created_at":"2026-08-21T02:38:04Z","author_association":"COLLABORATOR","body":"CLAIM_RELEASED reason=feedback_route_ci runner=pulse ts=2026-08-21T02:38:00Z\n<!-- feedback-route:dispatch-release:ci:PR100:SHAabc123repairsha -->"}]
EOF

	_feedback_route_release_dispatch_claim "ci" "100" "owner/repo" "42" "abc123repairsha"

	if ! grep -qF 'gh api repos/owner/repo/issues/comments/12 --method DELETE' "$GH_LOG" ||
		grep -qF 'gh api repos/owner/repo/issues/comments/11 --method DELETE' "$GH_LOG" ||
		grep -qF 'gh issue comment 42' "$GH_LOG"; then
		print_result "feedback release converges cross-runner duplicate comments" 1 \
			"Expected only newer comment 12 to be deleted. Log: $(cat "$GH_LOG")"
		return 0
	fi
	print_result "feedback release converges cross-runner duplicate comments" 0
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
	test_build_section_bounds_total_output
	test_build_section_empty_when_no_content
	test_dispatch_appends_to_issue_body_and_closes_pr
	test_dispatch_wraps_paginated_feedback_reads
	test_paginated_feedback_pages_are_merged
	test_dispatch_timeout_fails_open_without_routing_empty_feedback
	test_dispatch_preserves_ambiguous_legacy_marker
	test_dispatch_retries_after_transition_failure
	test_dispatch_preserves_maintainer_hold_racing_transition
	test_dispatch_retries_after_close_failure
	test_dispatch_reopens_when_close_verification_fails
	test_dispatch_reopens_after_completion_write_failure
	test_dispatch_recovers_terminal_label_failure
	test_dispatch_holds_on_head_drift
	test_dispatch_holds_when_ownership_changes_during_transition
	test_dispatch_holds_prior_ci_head_evidence
	test_dispatch_does_not_transition_started_merged_route
	test_terminal_guard_rechecks_current_label
	test_dispatch_holds_reopened_completed_route
	test_dispatch_skips_identical_evidence_on_same_head
	test_dispatch_skips_identical_evidence_on_changed_head
	test_dispatch_routes_edited_evidence_on_same_head
	test_dispatch_dry_run_has_no_writes
	test_conflict_dispatch_uses_shared_finalizer
	test_dispatch_noop_when_no_substantive_feedback
	test_dispatch_noop_on_invalid_inputs
	test_dispatch_clears_in_progress_labels_as_fallback
	test_ci_dispatch_dedupes_by_pr_head_marker
	test_feedback_release_reconciles_cross_runner_duplicates
	test_dispatch_skips_body_edit_on_issue_view_failure

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
