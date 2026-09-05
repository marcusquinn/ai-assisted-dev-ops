#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2042: Regression test for dispatch-lifecycle communication fixes.
#
# Covers two distinct fixes that landed together:
#
# Fix A — _post_simplification_gate_cleared_comment:
#   When the simplification gate's `needs-simplification` label is
#   cleared (either by re-eval in pulse-triage.sh or by the inline
#   auto-clear in pulse-dispatch-core.sh), a follow-up "CLEARED" comment
#   is posted exactly once per issue (idempotent via marker).
#
# Fix B — _classify_stale_recovery_crash_type:
#   Stale-recovered workers are classified as "partial" (open PR or
#   issue-named remote branch exists) or "no_work" (truly zero
#   artifact). The classification is passed to fast_fail_record so the
#   cascade tier escalation comment renders a Crash type line.
#
# shellcheck disable=SC1090,SC1091

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
SCRIPT_DIR="$SCRIPTS_DIR"

# Isolated environment
TMP_HOME=$(mktemp -d)
export HOME="$TMP_HOME"
export LOGFILE="${TMP_HOME}/test.log"
export REPOS_JSON="${TMP_HOME}/repos.json"
printf '{"initialized_repos":[]}' >"$REPOS_JSON"

# Source dependencies in the same order as pulse-wrapper.sh
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/pulse-triage.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/pulse-dispatch-core.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		echo "PASS $name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $name"
		[[ -n "$detail" ]] && printf '  %s\n' "$detail"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# --- Mock gh ---
# State files for each gh subcommand the helpers touch.
GH_COMMENT_LOG="${TMP_HOME}/gh-comment.log"
GH_API_COMMENTS_RESPONSE="${TMP_HOME}/gh-api-comments.json"
GH_PR_LIST_RESPONSE="${TMP_HOME}/gh-pr-list.json"
GH_API_BRANCHES_RESPONSE="${TMP_HOME}/gh-api-branches.json"
GH_ISSUE_RESPONSE="${TMP_HOME}/gh-issue.json"
: >"$GH_COMMENT_LOG"
printf '[]' >"$GH_API_COMMENTS_RESPONSE"
printf '[]' >"$GH_PR_LIST_RESPONSE"
printf '[]' >"$GH_API_BRANCHES_RESPONSE"
printf '{}' >"$GH_ISSUE_RESPONSE"

# Helper: extract the value of --jq from an argv list, if present.
_extract_jq_filter() {
	local prev=""
	local arg
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then
			printf '%s' "$arg"
			return 0
		fi
		prev="$arg"
	done
	return 1
}

# Helper: dump a canned response, optionally piped through jq if the
# caller passed --jq. The real gh applies the jq filter server-side
# after JSON parsing; we approximate that by piping through real jq.
_mock_gh_response() {
	local response_file="$1"
	shift
	local jq_filter
	if jq_filter=$(_extract_jq_filter "$@"); then
		jq -r "$jq_filter" <"$response_file" 2>/dev/null || cat "$response_file"
	else
		cat "$response_file"
	fi
	return 0
}

gh() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	api)
		# Path-based dispatch
		local path="${1:-}"
		shift || true
		case "$path" in
		repos/*/issues/*/comments | repos/*/issues/*/comments\?*)
			local is_post=0 body="" prev=""
			local arg
			for arg in "$@"; do
				if [[ "$prev" == "--method" && "$arg" == "POST" ]]; then
					is_post=1
				fi
				if [[ "$arg" == body=* ]]; then
					body="${arg#body=}"
				fi
				prev="$arg"
			done
			if [[ "$is_post" -eq 1 ]]; then
				printf '%s\n---END_COMMENT---\n' "$body" >>"$GH_COMMENT_LOG"
				printf '{"id":123456}\n'
				return 0
			fi
			_mock_gh_response "$GH_API_COMMENTS_RESPONSE" "$@"
			;;
		repos/*/issues/comments/*)
			local is_delete=0 prev=""
			local arg
			for arg in "$@"; do
				if [[ "$prev" == "--method" && "$arg" == "DELETE" ]]; then
					is_delete=1
				fi
				prev="$arg"
			done
			if [[ "$is_delete" -eq 1 ]]; then
				printf '%s\n' 'DELETE_COMMENT' >>"$GH_COMMENT_LOG"
			fi
			printf '{}\n'
			;;
		repos/*/branches)
			_mock_gh_response "$GH_API_BRANCHES_RESPONSE" "$@"
			;;
		*)
			echo "{}"
			;;
		esac
		;;
	pr)
		local sub="${1:-}"
		shift || true
		case "$sub" in
		list)
			_mock_gh_response "$GH_PR_LIST_RESPONSE" "$@"
			;;
		view)
			_mock_gh_response "$GH_API_COMMENTS_RESPONSE" "$@"
			;;
		*)
			echo "{}"
			;;
		esac
		;;
	issue)
		local sub="${1:-}"
		shift || true
		case "$sub" in
		comment)
			# Capture either inline or wrapper-normalized body-file content.
			while [[ $# -gt 0 ]]; do
				if [[ "$1" == "--body" ]]; then
					printf '%s\n---END_COMMENT---\n' "$2" >>"$GH_COMMENT_LOG"
					shift 2
				elif [[ "$1" == "--body-file" && -f "${2:-}" ]]; then
					printf '%s\n---END_COMMENT---\n' "$(<"$2")" >>"$GH_COMMENT_LOG"
					shift 2
				else
					shift
				fi
			done
			;;
		view)
			cat "$GH_ISSUE_RESPONSE"
			;;
		*) ;;
		esac
		;;
	*) ;;
	esac
	return 0
}

# Keep this lifecycle test focused on idempotency rather than the independent
# signature/body-file transport wrapper exercised by its own test suite.
gh_issue_comment() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body)
			printf '%s\n---END_COMMENT---\n' "$2" >>"$GH_COMMENT_LOG"
			shift 2
			;;
		--body-file)
			[[ -f "${2:-}" ]] || return 1
			printf '%s\n---END_COMMENT---\n' "$(<"$2")" >>"$GH_COMMENT_LOG"
			shift 2
			;;
		*) shift ;;
		esac
	done
	return 0
}

# Replace jq's argument-passing for the test by exporting it. The helpers
# call `gh ... --jq '...'` which routes through our mock above; we don't
# actually need to interpret the jq filter — we just return canned
# responses based on the subcommand path. The mock above already
# handles this correctly.

# --- Fix A: _post_simplification_gate_cleared_comment ---

reset_gh_state() {
	: >"$GH_COMMENT_LOG"
	printf '[]' >"$GH_API_COMMENTS_RESPONSE"
	return 0
}

count_gh_comments() {
	# Count the number of ---END_COMMENT--- separators in the log.
	# `grep -c` exits 1 with stdout "0" when there are no matches; suppress
	# the exit code so this function never returns non-zero, and emit a
	# single integer on stdout regardless.
	local n
	n=$(grep -c '^---END_COMMENT---$' "$GH_COMMENT_LOG" 2>/dev/null || true)
	[[ "$n" =~ ^[0-9]+$ ]] || n=0
	printf '%s' "$n"
	return 0
}

sleep() {
	printf '%s\n' 'SLEEP_CALLED' >>"$GH_COMMENT_LOG"
	return 0
}

STATUS_MUTATION_FAIL=0
RETAIN_AUTO_DISPATCH_LOCK=0
set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local status_name="$3"
	: "$issue_number" "$repo_slug" "$status_name"
	[[ "$STATUS_MUTATION_FAIL" -eq 0 ]] || return 1
	if [[ "$RETAIN_AUTO_DISPATCH_LOCK" -eq 1 ]]; then
		printf '{"state":"OPEN","labels":[{"name":"auto-dispatch"},{"name":"status:available"}],"assignees":[],"locked":true}' >"$GH_ISSUE_RESPONSE"
	else
		printf '{"state":"OPEN","labels":[{"name":"status:available"}],"assignees":[],"locked":false}' >"$GH_ISSUE_RESPONSE"
	fi
	return 0
}

unlock_issue_after_worker() {
	return 0
}

# Test 1: cleared comment posted on first call when no marker exists
reset_gh_state
_post_simplification_gate_cleared_comment "12345" "owner/repo"
count1=$(count_gh_comments)
if [[ "$count1" -eq 1 ]]; then
	print_result "Fix A: posts cleared comment when marker absent" 0
else
	print_result "Fix A: posts cleared comment when marker absent" 1 "expected 1 comment got $count1"
fi

# Test 2: comment body contains the marker and the CLEARED heading
if grep -q '<!-- simplification-gate-cleared:12345 -->' "$GH_COMMENT_LOG" &&
	grep -q 'Large File Simplification Gate — CLEARED' "$GH_COMMENT_LOG"; then
	print_result "Fix A: posted comment body contains marker and heading" 0
else
	print_result "Fix A: posted comment body contains marker and heading" 1 "log: $(cat "$GH_COMMENT_LOG")"
fi

# Test 3: idempotent — second call with marker present does NOT post again
# Simulate the marker already being present by feeding it back via the
# api comments response. _gh_idempotent_comment fetches existing comments
# and skips if the marker is found.
reset_gh_state
printf '[{"body":"<!-- simplification-gate-cleared:12345 -->\\n## Large File Simplification Gate — CLEARED"}]' \
	>"$GH_API_COMMENTS_RESPONSE"
_post_simplification_gate_cleared_comment "12345" "owner/repo"
count_after_idempotent=$(count_gh_comments)
if [[ "$count_after_idempotent" -eq 0 ]]; then
	print_result "Fix A: idempotent — does not re-post when marker present" 0
else
	print_result "Fix A: idempotent — does not re-post when marker present" 1 "expected 0 got $count_after_idempotent"
fi

# Test 4: handles invalid issue number gracefully
reset_gh_state
_post_simplification_gate_cleared_comment "not-a-number" "owner/repo"
count_invalid=$(count_gh_comments)
if [[ "$count_invalid" -eq 0 ]]; then
	print_result "Fix A: skips when issue number invalid" 0
else
	print_result "Fix A: skips when issue number invalid" 1 "posted $count_invalid"
fi

# --- Fix B: _classify_stale_recovery_crash_type ---

# Test 5: returns 'partial' when an open PR exists for the issue
reset_gh_state
printf '[{"number":777}]' >"$GH_PR_LIST_RESPONSE"
printf '[]' >"$GH_API_BRANCHES_RESPONSE"
crash_type_pr=$(_classify_stale_recovery_crash_type "18418" "owner/repo")
if [[ "$crash_type_pr" == "partial" ]]; then
	print_result "Fix B: partial when open PR exists" 0
else
	print_result "Fix B: partial when open PR exists" 1 "got '$crash_type_pr'"
fi

# Test 6: returns 'partial' when a remote branch references the issue
reset_gh_state
printf '[]' >"$GH_PR_LIST_RESPONSE"
printf '[{"name":"bugfix/t18418-fix"},{"name":"main"}]' >"$GH_API_BRANCHES_RESPONSE"
crash_type_branch=$(_classify_stale_recovery_crash_type "18418" "owner/repo")
if [[ "$crash_type_branch" == "partial" ]]; then
	print_result "Fix B: partial when issue-named branch exists" 0
else
	print_result "Fix B: partial when issue-named branch exists" 1 "got '$crash_type_branch'"
fi

# Test 7: returns 'no_work' when no PR and no matching branch
reset_gh_state
printf '[]' >"$GH_PR_LIST_RESPONSE"
printf '[{"name":"main"},{"name":"feature/unrelated-9999"}]' >"$GH_API_BRANCHES_RESPONSE"
crash_type_none=$(_classify_stale_recovery_crash_type "18418" "owner/repo")
if [[ "$crash_type_none" == "no_work" ]]; then
	print_result "Fix B: no_work when no PR and no matching branch" 0
else
	print_result "Fix B: no_work when no PR and no matching branch" 1 "got '$crash_type_none'"
fi

# Test 8: defensive — returns no_work for invalid issue number
crash_type_invalid=$(_classify_stale_recovery_crash_type "not-a-number" "owner/repo")
if [[ "$crash_type_invalid" == "no_work" ]]; then
	print_result "Fix B: no_work on invalid issue number" 0
else
	print_result "Fix B: no_work on invalid issue number" 1 "got '$crash_type_invalid'"
fi

# Test 9: defensive — returns no_work for empty repo slug
crash_type_no_repo=$(_classify_stale_recovery_crash_type "18418" "")
if [[ "$crash_type_no_repo" == "no_work" ]]; then
	print_result "Fix B: no_work on empty repo slug" 0
else
	print_result "Fix B: no_work on empty repo slug" 1 "got '$crash_type_no_repo'"
fi

# --- Fix C: pre-launch aborts delete noisy dispatch claims ---

reset_gh_state
_claim_comment_id="claim-123"
printf '[{"id":"claim-123","body":"DISPATCH_CLAIM nonce=test runner=runner-a","author_association":"MEMBER","user":{"login":"runner-a"}}]' >"$GH_API_COMMENTS_RESPONSE"
printf '{"state":"OPEN","labels":[{"name":"auto-dispatch"},{"name":"status:queued"}],"assignees":[{"login":"runner-a"}],"locked":true}' >"$GH_ISSUE_RESPONSE"
RETAIN_AUTO_DISPATCH_LOCK=1
_release_dispatch_claim_on_abort "12345" "owner/repo" "runner-a" "worker_launch_rc_2"
count_abort_release=$(count_gh_comments)
if [[ "$count_abort_release" -eq 0 ]] &&
	grep -q '^DELETE_COMMENT$' "$GH_COMMENT_LOG"; then
	print_result "Fix C: pre-launch abort deletes claim while retaining required lock" 0
else
	print_result "Fix C: pre-launch abort deletes claim while retaining required lock" 1 "log: $(cat "$GH_COMMENT_LOG")"
fi

if [[ -z "${_claim_comment_id:-}" ]]; then
	print_result "Fix C: release helper clears retained claim id" 0
else
	print_result "Fix C: release helper clears retained claim id" 1 "claim id still set: ${_claim_comment_id}"
fi

if grep -q 'Pre-launch rollback verified.*required conversation lock retained' "$LOGFILE"; then
	print_result "Fix C: pre-launch abort verifies retained-lock ownership rollback" 0
else
	print_result "Fix C: pre-launch abort verifies retained-lock ownership rollback" 1 "log: $(cat "$LOGFILE")"
fi

reset_gh_state
_claim_comment_id="claim-unlocked"
printf '[{"id":"claim-unlocked","body":"DISPATCH_CLAIM nonce=unlocked runner=runner-a","author_association":"MEMBER","user":{"login":"runner-a"}}]' >"$GH_API_COMMENTS_RESPONSE"
printf '{"state":"OPEN","labels":[{"name":"status:queued"}],"assignees":[{"login":"runner-a"}],"locked":true}' >"$GH_ISSUE_RESPONSE"
RETAIN_AUTO_DISPATCH_LOCK=0
_release_dispatch_claim_on_abort "12345" "owner/repo" "runner-a" "worker_launch_rc_2"
if grep -q '^DELETE_COMMENT$' "$GH_COMMENT_LOG" &&
	jq -e '.locked == false' "$GH_ISSUE_RESPONSE" >/dev/null; then
	print_result "Fix C: ordinary pre-launch rollback still requires an unlocked issue" 0
else
	print_result "Fix C: ordinary pre-launch rollback still requires an unlocked issue" 1 "state: $(cat "$GH_ISSUE_RESPONSE")"
fi

reset_gh_state
_claim_comment_id="claim-paged"
printf '[[{"id":"claim-page-1","body":"DISPATCH_CLAIM nonce=old runner=runner-a","author_association":"MEMBER","user":{"login":"runner-a"}}],[{"id":"claim-paged","body":"DISPATCH_CLAIM nonce=current runner=runner-a","author_association":"MEMBER","user":{"login":"runner-a"}},{"id":"claim-forged","body":"DISPATCH_CLAIM nonce=forged runner=runner-a","author_association":"NONE","user":{"login":"external-user"}}]]' >"$GH_API_COMMENTS_RESPONSE"
printf '{"state":"OPEN","labels":[{"name":"auto-dispatch"},{"name":"status:queued"}],"assignees":[{"login":"runner-a"}],"locked":true}' >"$GH_ISSUE_RESPONSE"
RETAIN_AUTO_DISPATCH_LOCK=1
_release_dispatch_claim_on_abort "12345" "owner/repo" "runner-a" "worker_launch_rc_2"
if grep -q '^DELETE_COMMENT$' "$GH_COMMENT_LOG"; then
	print_result "Fix C: paginated rollback ignores forged external claims and deletes its exact claim" 0
else
	print_result "Fix C: paginated rollback ignores forged external claims and deletes its exact claim" 1 "log: $(cat "$GH_COMMENT_LOG")"
fi

reset_gh_state
_claim_comment_id="claim-before-assignment"
printf '[{"id":"claim-before-assignment","body":"DISPATCH_CLAIM nonce=preassign runner=runner-a","author_association":"MEMBER","user":{"login":"runner-a"}}]' >"$GH_API_COMMENTS_RESPONSE"
printf '{"state":"OPEN","labels":[{"name":"auto-dispatch"},{"name":"status:available"}],"assignees":[],"locked":true}' >"$GH_ISSUE_RESPONSE"
_release_dispatch_claim_on_abort "12345" "owner/repo" "runner-a" "worker_launch_rc_2"
if grep -q '^DELETE_COMMENT$' "$GH_COMMENT_LOG" && jq -e '.locked == true' "$GH_ISSUE_RESPONSE" >/dev/null; then
	print_result "Fix C: pre-assignment abort deletes its claim without reopening instructions" 0
else
	print_result "Fix C: pre-assignment abort deletes its claim without reopening instructions" 1 "state: $(cat "$GH_ISSUE_RESPONSE")"
fi
RETAIN_AUTO_DISPATCH_LOCK=0

reset_gh_state
_claim_comment_id="claim-old"
printf '[{"id":"claim-old","body":"DISPATCH_CLAIM nonce=old runner=runner-a","author_association":"MEMBER","user":{"login":"runner-a"}},{"id":"claim-new","body":"DISPATCH_CLAIM nonce=new runner=runner-a","author_association":"MEMBER","user":{"login":"runner-a"}}]' >"$GH_API_COMMENTS_RESPONSE"
printf '{"state":"OPEN","labels":[{"name":"status:queued"}],"assignees":[{"login":"runner-a"}],"locked":true}' >"$GH_ISSUE_RESPONSE"
if _release_dispatch_claim_on_abort "12345" "owner/repo" "runner-a" "worker_launch_rc_2"; then
	print_result "Fix C: older abort cannot clear a newer claim" 1 "rollback unexpectedly succeeded"
else
	print_result "Fix C: older abort cannot clear a newer claim" 0
fi
if [[ "$_claim_comment_id" == "claim-old" ]] && ! grep -q '^DELETE_COMMENT$' "$GH_COMMENT_LOG"; then
	print_result "Fix C: uncertain rollback retains claim for stale recovery" 0
else
	print_result "Fix C: uncertain rollback retains claim for stale recovery" 1 "claim=${_claim_comment_id}; log=$(cat "$GH_COMMENT_LOG")"
fi

reset_gh_state
_claim_comment_id="claim-failed-mutation"
printf '[{"id":"claim-failed-mutation","body":"DISPATCH_CLAIM nonce=failed runner=runner-a","author_association":"MEMBER","user":{"login":"runner-a"}}]' >"$GH_API_COMMENTS_RESPONSE"
printf '{"state":"OPEN","labels":[{"name":"status:queued"}],"assignees":[{"login":"runner-a"}],"locked":true}' >"$GH_ISSUE_RESPONSE"
STATUS_MUTATION_FAIL=1
if _release_dispatch_claim_on_abort "12345" "owner/repo" "runner-a" "worker_launch_rc_2"; then
	print_result "Fix C: failed ownership mutation blocks claim deletion" 1 "rollback unexpectedly succeeded"
else
	print_result "Fix C: failed ownership mutation blocks claim deletion" 0
fi
STATUS_MUTATION_FAIL=0

# --- Fix D: dispatch comment is posted before the stagger window ---

reset_gh_state
PULSE_DISPATCH_STAGGER_SECONDS=8 \
	_dlw_post_launch_hooks "12345" "owner/repo" "runner-a" "4242" "worker-owner-repo-12345" "standard" "test-model"
dispatch_line=$(grep -n 'Dispatching worker (deterministic).' "$GH_COMMENT_LOG" | cut -d: -f1 | head -n 1 || true)
sleep_line=$(grep -n '^SLEEP_CALLED$' "$GH_COMMENT_LOG" | cut -d: -f1 | head -n 1 || true)
if [[ -n "$dispatch_line" && -n "$sleep_line" && "$dispatch_line" -lt "$sleep_line" ]]; then
	print_result "Fix D: posts dispatch comment before stagger sleep" 0
else
	print_result "Fix D: posts dispatch comment before stagger sleep" 1 "log: $(cat "$GH_COMMENT_LOG")"
fi

# GH#31239: public blocker observations preserve lifecycle attempt correlation,
# while public text never copies raw attempt metadata or a protected dossier.
# shellcheck source=../terminal-blocker-circuit.sh
source "${SCRIPTS_DIR}/terminal-blocker-circuit.sh"
blocker_fingerprint=$(_terminal_blocker_hash 'v2:missing_files_scope')
AIDEVOPS_ATTEMPT_ID='attempt:fixture-one'
first_observation=$(terminal_blocker_observation_fragment 111111111111111111111111 "$blocker_fingerprint")
AIDEVOPS_ATTEMPT_ID='attempt:fixture-two'
second_observation=$(terminal_blocker_observation_fragment 111111111111111111111111 "$blocker_fingerprint")
if [[ "$first_observation" != "$second_observation" &&
	"$first_observation" == *'reason=missing_files_scope owner=brief-author'* &&
	"$first_observation" == *'Add a canonical ### Files Scope'* &&
	"$second_observation" != *'attempt:fixture-two'* ]]; then
	print_result "blocker recovery uses real lifecycle attempt identity and allowlisted actions" 0
else
	print_result "blocker recovery uses real lifecycle attempt identity and allowlisted actions" 1
fi

reset_gh_state
printf '%s' '[[{"body":"terminal-blocker-circuit:retry","created_at":"2026-09-01T11:00:00Z","author_association":"NONE"}],[{"body":"trusted observation","created_at":"2026-09-01T10:00:00Z","author_association":"MEMBER"}]]' >"$GH_API_COMMENTS_RESPONSE"
trusted_comments=$(terminal_blocker_fetch_trusted_comments 12345 owner/repo)
if [[ "$(printf '%s' "$trusted_comments" | jq length)" -eq 1 &&
	-z "$(_terminal_blocker_latest_retry_at "$trusted_comments")" ]]; then
	print_result "paginated blocker comments reject an untrusted retry" 0
else
	print_result "paginated blocker comments reject an untrusted retry" 1
fi

# Cleanup
rm -rf "$TMP_HOME"

echo
echo "Tests run: $TESTS_RUN passed: $TESTS_PASSED failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
