#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#23516: issue-sync must not treat a merged PR whose
# title merely starts with a task ID as completion evidence. Completion requires
# explicit proof in TODO.md (`pr:#NNN`, `verified:YYYY-MM-DD`, cancellation state)
# and unresolved `blocked-by:*` markers veto close/proof-log automation.
set -euo pipefail

PASS=0
FAIL=0

pass() {
	local msg="$1"
	PASS=$((PASS + 1))
	printf 'PASS: %s\n' "$msg"
	return 0
}

fail() {
	local msg="$1"
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s\n' "$msg"
	return 0
}

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_PATH="${TEST_DIR}/../issue-sync-helper-close.sh"

print_warning() { return 0; }
print_info() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
gh_find_merged_pr() {
	local repo="$1" task_id="$2"
	: "$task_id"
	printf '%s\n' "42|https://github.com/${repo}/pull/42"
	return 0
}
gh() {
	local args="$*"
	if [[ "$args" == *"issues/125/comments"* ]]; then
		printf '%s\n' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
		return 1
	fi
	if [[ "$args" == *"issues/126/comments"* ]]; then
		printf '%s\n' 'not-a-timestamp'
		return 0
	fi
	if [[ "$args" == *"api repos/owner/repo/issues/123"* && "$args" != *"/comments"* ]]; then
		[[ "${AIDEVOPS_GH_ROUTE_DECISION:-}" == "issue-sync-completion-issue-rest" ]] || return 1
		printf '%s\n' '{"state":"closed","state_reason":"completed","closed_at":"2026-06-30T01:53:39Z","body":"Completed interactively.\n<!-- aidevops:sig -->"}'
		return 0
	fi
	if [[ "$args" == *"api repos/owner/repo/issues/124"* && "$args" != *"/comments"* ]]; then
		[[ "${AIDEVOPS_GH_ROUTE_DECISION:-}" == "issue-sync-completion-issue-rest" ]] || return 1
		printf '%s\n' '{"state":"closed","state_reason":"completed","closed_at":"2026-06-30T01:53:39Z","body":"Closed without aidevops evidence."}'
		return 0
	fi
	if [[ "$args" == *"api repos/owner/repo/issues/127"* && "$args" != *"/comments"* ]]; then
		[[ "${AIDEVOPS_GH_ROUTE_DECISION:-}" == "issue-sync-completion-issue-rest" ]] || return 1
		printf '%s\n' '{"state":"closed","state_reason":"completed","closed_at":"not-a-timestamp","body":"<!-- aidevops:sig -->"}'
		return 0
	fi
	if [[ "$args" == *"api repos/owner/repo/issues/128"* && "$args" != *"/comments"* ]]; then
		[[ "${AIDEVOPS_GH_ROUTE_DECISION:-}" == "issue-sync-completion-issue-rest" ]] || return 1
		printf '%s\n' '{"state":"closed","state_reason":"completed","closed_at":"2026-07-01T02:03:04Z","body":"Completion evidence is in a later comment page."}'
		return 0
	fi
	case "$args" in
	*"api --paginate --slurp repos/owner/repo/issues/123/comments?per_page=100"* | \
		*"api --paginate --slurp repos/owner/repo/issues/124/comments?per_page=100"* | \
		*"api --paginate --slurp repos/owner/repo/issues/127/comments?per_page=100"*)
		[[ "${AIDEVOPS_GH_ROUTE_DECISION:-}" == "issue-sync-completion-comments-rest" ]] || return 1
		printf '%s\n' '[[]]'
		return 0
		;;
	*"api --paginate --slurp repos/owner/repo/issues/128/comments?per_page=100"*)
		[[ "${AIDEVOPS_GH_ROUTE_DECISION:-}" == "issue-sync-completion-comments-rest" ]] || return 1
		printf '%s\n' '[[],[{"body":"Completed via PR #999"}]]'
		return 0
		;;
	esac
	return 1
}
export -f print_warning print_info print_error print_success log_verbose gh_find_merged_pr gh

# shellcheck source=../issue-sync-helper-close.sh
source "$HELPER_PATH"

metadata_only_task='- [ ] t9001 keep closeout open tier:standard'
if _has_evidence "$metadata_only_task" "t9001" "owner/repo"; then
	fail "title-only merged PR lookup is not accepted as evidence"
else
	pass "title-only merged PR lookup is not accepted as evidence"
fi

if _find_closing_pr "$metadata_only_task" "t9001" "owner/repo" >/dev/null; then
	fail "title-only merged PR lookup is not returned as closing PR"
else
	pass "title-only merged PR lookup is not returned as closing PR"
fi

explicit_task='- [ ] t9002 fixed implementation pr:#77 tier:standard'
if _has_evidence "$explicit_task" "t9002" "owner/repo"; then
	pass "explicit pr proof remains valid evidence"
else
	fail "explicit pr proof should remain valid evidence"
fi

blocked_task='- [ ] t9003 blocked implementation pr:#78 tier:standard blocked-by:t9002'
_der_completion_blockers_closed() {
	local repo="$1"
	local issue_number="$2"
	local dependency_text="$3"
	: "$repo" "$issue_number"
	[[ "$dependency_text" == *"blocked-by:t9002"* ]]
	return $?
}
if _has_evidence "$blocked_task" "t9003" "owner/repo" "9003"; then
	pass "resolved blocked-by provenance permits explicit PR evidence"
else
	fail "resolved blocked-by provenance should not veto explicit PR evidence"
fi

open_blocked_task='- [ ] t9011 blocked implementation pr:#83 tier:standard blocked-by:t9999'
if _has_evidence "$open_blocked_task" "t9011" "owner/repo" "9011"; then
	fail "unresolved blocked-by marker must veto explicit PR evidence"
else
	pass "unresolved blocked-by marker still vetoes explicit PR evidence"
fi

historical_note_task='- [ ] t9004 fixed implementation pr:#79 tier:standard
  - Historical note: earlier attempt was blocked-by:t9003 before the dependency landed.'
if _has_evidence "$historical_note_task" "t9004" "owner/repo"; then
	pass "blocked-by mention in task notes does not veto current task line"
else
	fail "blocked-by mention in task notes should not veto current task line"
fi

historical_cancelled_note_task='- [ ] t9005 incomplete implementation tier:standard
  - Historical note: earlier scope was cancelled:2026-01-01 before being reopened.'
if _has_evidence "$historical_cancelled_note_task" "t9005" "owner/repo"; then
	fail "cancelled marker in task notes is not accepted as completion evidence"
else
	pass "cancelled marker in task notes is not accepted as completion evidence"
fi

unexpected_marker_cancelled_note_task='- [~] t9006 incomplete implementation tier:standard
  - Historical note: earlier scope was cancelled:2026-01-01 before being reopened.'
if _has_evidence "$unexpected_marker_cancelled_note_task" "t9006" "owner/repo"; then
	fail "unexpected task marker still ignores cancelled marker in task notes"
else
	pass "unexpected task marker still ignores cancelled marker in task notes"
fi

unexpected_marker_proof_task='- [~] t9007 fixed implementation pr:#80 tier:standard
  - Historical note: earlier attempt was blocked-by:t9006 before the dependency landed.'
if _has_evidence "$unexpected_marker_proof_task" "t9007" "owner/repo"; then
	pass "unexpected task marker accepts proof on the task line"
else
	fail "unexpected task marker should accept proof on the task line"
fi

precomputed_clean_task_line='- [ ] t9008 fixed implementation pr:#81 tier:standard'
precomputed_note_block='- [ ] t9008 fixed implementation pr:#81 tier:standard
  - Historical note: earlier attempt was blocked-by:t9007 before the dependency landed.'
if _has_unresolved_blocker "$precomputed_note_block" "t9008" "$precomputed_clean_task_line"; then
	fail "precomputed clean task line skips blocker mentions in notes"
else
	pass "precomputed clean task line skips blocker mentions in notes"
fi

precomputed_blocked_task_line='- [ ] t9009 fixed implementation pr:#82 tier:standard blocked-by:t9008'
if _has_unresolved_blocker "- [ ] t9009 fixed implementation pr:#82 tier:standard" "t9009" "$precomputed_blocked_task_line"; then
	pass "precomputed blocked task line without resolution context fails closed"
else
	fail "precomputed blocked task line without resolution context should fail closed"
fi

if completed_date=$(_closed_issue_aidevops_complete_date "owner/repo" "123"); then
	if [[ "$completed_date" == "2026-06-30" ]]; then
		pass "closed aidevops-signed issue is completion evidence for TODO refresh"
	else
		fail "closed aidevops-signed issue returned wrong completion date"
	fi
else
	fail "closed aidevops-signed issue should be completion evidence"
fi

if _closed_issue_aidevops_complete_date "owner/repo" "124" >/dev/null; then
	fail "closed issue without aidevops evidence is not completion evidence"
else
	pass "closed issue without aidevops evidence is not completion evidence"
fi

if completed_date=$(_closed_issue_aidevops_complete_date "owner/repo" "128"); then
	if [[ "$completed_date" == "2026-07-01" ]]; then
		pass "paginated REST comments provide later-page completion evidence"
	else
		fail "paginated REST completion evidence returned wrong completion date"
	fi
else
	fail "later-page REST comment should provide completion evidence"
fi

if completed_date=$(_closed_issue_worker_complete_date "owner/repo" "125"); then
	fail "failed GitHub lookup is not worker completion evidence"
elif [[ -n "$completed_date" ]]; then
	fail "failed GitHub lookup must not emit its JSON response body"
else
	pass "failed GitHub lookup emits no worker completion date"
fi

if _closed_issue_worker_complete_date "owner/repo" "126" >/dev/null; then
	fail "malformed worker timestamp is not completion evidence"
else
	pass "malformed worker timestamp is rejected"
fi

if _closed_issue_aidevops_complete_date "owner/repo" "127" >/dev/null; then
	fail "malformed issue close timestamp is not completion evidence"
else
	pass "malformed issue close timestamp is rejected"
fi

todo_file=$(mktemp)
printf '%s\n' '- [ ] t9010 retry failed completion lookup ref:GH#125' >"$todo_file"
todo_before=$(<"$todo_file")
_reopen_find_merged_pr() {
	return 1
}
if _reopen_mark_if_completed "owner/repo" "t9010" "125" "$todo_file"; then
	fail "failed completion lookup does not mark reopened task complete"
elif [[ "$(<"$todo_file")" != "$todo_before" ]]; then
	fail "failed completion lookup changed reopened TODO content"
else
	pass "failed completion lookup leaves reopened TODO content unchanged"
fi
rm -f "$todo_file"

if [[ "$FAIL" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$PASS"
	exit 0
fi

exit 1
