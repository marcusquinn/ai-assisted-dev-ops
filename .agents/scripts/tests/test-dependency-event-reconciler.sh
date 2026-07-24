#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
# shellcheck source=../dependency-event-reconciler.sh
source "${SCRIPTS_DIR}/dependency-event-reconciler.sh"

PASS=0
FAIL=0
EDIT_COUNT=0
REREAD_LABELS="status:blocked"
COMMENTS='[[]]'
NATIVE_STATE="CLOSED"
NATIVE_DIRECT=true
SEARCH_AMBIGUOUS=false
EXPLICIT_LABEL=true
BODY20="Blocked by #10"
CLOSED_TITLE="t10: blocker"
CONTEXT_REPO="owner/repo"
CONTEXT_STATE="CLOSED"
CONTEXT_HAS_NEXT_PAGE=false
CLOSED_LIVE_STATE="CLOSED"
BLOCKER_RECONCILE_FAIL=false
BLOCKER_RECONCILE_LOG=$(mktemp)
trap 'rm -f "$BLOCKER_RECONCILE_LOG"' EXIT

pass() {
	printf 'PASS: %s\n' "$1"
	PASS=$((PASS + 1))
	return 0
}
fail() {
	printf 'FAIL: %s\n' "$1"
	FAIL=$((FAIL + 1))
	return 0
}
assert_eq() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	[[ "$expected" == "$actual" ]] && pass "$name" || fail "$name (expected $expected, got $actual)"
	return 0
}

candidate() {
	local number="$1"
	local state="$2"
	local title="$3"
	local body="$4"
	local labels="$5"
	printf '%s' "$labels" | jq -Rsc --argjson number "$number" --arg state "$state" --arg title "$title" --arg body "$body" '
      split("\n") | map(select(length > 0) | {name:.})
      | {__typename:"Issue",number:$number,state:$state,title:$title,body:$body,
          repository:{nameWithOwner:"owner/repo"},labels:{nodes:.,pageInfo:{hasNextPage:false}}}'
	return 0
}

_der_fetch_closed_context() {
	local native='[]'
	if [[ "$NATIVE_DIRECT" == "true" ]]; then
		native=$(candidate 20 OPEN "t20: direct" "$BODY20" $'status:blocked\nblocked-by:#10' | jq -sc '.')
	fi
	jq -cn --arg title "$CLOSED_TITLE" --arg repo "$CONTEXT_REPO" \
		--arg state "$CONTEXT_STATE" --argjson native "$native" \
		--argjson has_next_page "$CONTEXT_HAS_NEXT_PAGE" '
      {data:{repository:{nameWithOwner:$repo,issue:{number:10,state:$state,title:$title,
        blocking:{nodes:$native,pageInfo:{hasNextPage:$has_next_page}}}}}}'
	return 0
}

_der_reconcile_terminal_worker_blockers() {
	local repo="$1"
	local issue_number="$2"
	printf '%s#%s\n' "$repo" "$issue_number" >>"$BLOCKER_RECONCILE_LOG"
	if [[ "$BLOCKER_RECONCILE_FAIL" == "true" ]]; then
		return 1
	fi
	return 0
}

reset_blocker_reconcile_log() {
	: >"$BLOCKER_RECONCILE_LOG"
	return 0
}

blocker_reconcile_count() {
	local count=0
	count=$(wc -l <"$BLOCKER_RECONCILE_LOG")
	printf '%s\n' "${count//[[:space:]]/}"
	return 0
}

_der_search_issues() {
	local repo="$1"
	local query="$2"
	local labels="status:blocked"
	[[ "$EXPLICIT_LABEL" == "true" ]] && labels=$'status:blocked\nblocked-by:#10'
	[[ "$repo" == "owner/repo" ]] || return 1
	[[ "$SEARCH_AMBIGUOUS" == "false" ]] || return 1
	if [[ "$query" == *"in:title"* ]]; then
		candidate 10 CLOSED "$CLOSED_TITLE" "" "" | jq -sc '.'
	elif [[ "$query" == *"#10"* || "$query" == *"t10"* ]]; then
		candidate 20 OPEN "t20: direct" "$BODY20" "$labels" | jq -sc '.'
	else
		printf '[]\n'
	fi
	return 0
}

gh() {
	local command="$1"
	shift
	case "$command $1" in
	"issue view")
		if [[ "$*" == *"--json state"* ]]; then
			[[ "$*" == "view 11 "* ]] && printf 'OPEN\n' || printf '%s\n' "$CLOSED_LIVE_STATE"
		else
			printf '%s\n' "$REREAD_LABELS"
		fi
		return 0
		;;
	"issue edit")
		EDIT_COUNT=$((EDIT_COUNT + 1))
		REREAD_LABELS="status:available"
		return 0
		;;
	"api graphql")
		jq -cn --arg state "$NATIVE_STATE" '{data:{repository:{issue:{blockedBy:{nodes:[{number:10,state:$state,repository:{nameWithOwner:"owner/repo"}}],pageInfo:{hasNextPage:false}}}}}}'
		return 0
		;;
	"api --paginate")
		if [[ "$*" == *"/issues?state=open"* ]]; then
			jq -cn --arg body "$BODY20" '[[{number:20,state:"open",title:"t20: direct",body:$body,labels:[{name:"status:blocked"},{name:"blocked-by:#10"}]}]]'
		else
			printf '%s\n' "$COMMENTS"
		fi
		return 0
		;;
	esac
	return 1
}

run_reconcile() {
	local before="$EDIT_COUNT"
	reconcile_dependants_after_verified_closure "owner/repo" 10 >/dev/null 2>&1 || true
	printf '%s\n' "$((EDIT_COUNT - before))"
	return 0
}

reset_blocker_reconcile_log
assert_eq 1 "$(run_reconcile)" "repository with 27000 unrelated issues still reconciles targeted child"
assert_eq 1 "$(blocker_reconcile_count)" "verified terminal issue reconciles its worker blocker identities"
assert_eq "owner/repo#10" "$(cat "$BLOCKER_RECONCILE_LOG")" "worker blocker reconciliation preserves exact issue identity"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" CONTEXT_HAS_NEXT_PAGE=true
reset_blocker_reconcile_log
assert_eq 0 "$(run_reconcile)" "incomplete closure context blocks dependant mutation"
assert_eq 0 "$(blocker_reconcile_count)" "incomplete closure context cannot resolve worker blockers"
CONTEXT_HAS_NEXT_PAGE=false

EDIT_COUNT=0 REREAD_LABELS="status:blocked" CONTEXT_REPO="other/repo"
reset_blocker_reconcile_log
assert_eq 0 "$(run_reconcile)" "closure context repository mismatch blocks dependant mutation"
assert_eq 0 "$(blocker_reconcile_count)" "repository mismatch cannot resolve worker blockers"
CONTEXT_REPO="owner/repo"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" CLOSED_LIVE_STATE="OPEN"
reset_blocker_reconcile_log
assert_eq 0 "$(run_reconcile)" "non-terminal live state blocks dependant mutation"
assert_eq 0 "$(blocker_reconcile_count)" "non-terminal live state cannot resolve worker blockers"
CLOSED_LIVE_STATE="CLOSED"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BLOCKER_RECONCILE_FAIL=true
reset_blocker_reconcile_log
assert_eq 1 "$(run_reconcile)" "blocker logger failure remains fail-open for dependency reconciliation"
assert_eq 1 "$(blocker_reconcile_count)" "fail-open dependency reconciliation attempts blocker resolution once"
BLOCKER_RECONCILE_FAIL=false

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20="Blocked by #10 and #11"
assert_eq 0 "$(run_reconcile)" "multiple blockers remain blocked when one is open"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20="Blocked by #10" SEARCH_AMBIGUOUS=true
assert_eq 0 "$(run_reconcile)" "targeted search count or pagination ambiguity fails closed"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" SEARCH_AMBIGUOUS=false BODY20=$'Blocked by: **#10**\nOn hold for maintainer'
assert_eq 0 "$(run_reconcile)" "markdown dependency variant is found while non-dependency hold is preserved"

EDIT_COUNT=0 REREAD_LABELS="status:done,status:blocked" BODY20="Blocked by #10"
assert_eq 0 "$(run_reconcile)" "status done is preserved"

EDIT_COUNT=0 REREAD_LABELS="status:available"
assert_eq 0 "$(run_reconcile)" "already reconciled state is idempotent"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" COMMENTS='not-json'
assert_eq 0 "$(run_reconcile)" "comment API ambiguity fails closed"

COMMENTS='[[]]' EDIT_COUNT=0 REREAD_LABELS="status:blocked" NATIVE_DIRECT=false EXPLICIT_LABEL=false BODY20="Reference #10 without a dependency declaration"
assert_eq 0 "$(run_reconcile)" "search hit without dependency ownership is not mutated"

EXPLICIT_LABEL=true
namespaced="to01j2abc3def4gh5jkm6npq7rst-42.3"
assert_eq "$namespaced" "$(_der_task_refs "Blocked by: ${namespaced}")" "namespaced hierarchical task ID uses canonical codec"

NATIVE_DIRECT=true CLOSED_TITLE="${namespaced}: blocker" BODY20="blocked-by:${namespaced}" EDIT_COUNT=0 REREAD_LABELS="status:blocked"
assert_eq 1 "$(run_reconcile)" "namespaced task declaration resolves through exact title lookup"

NATIVE_STATE="CLOSED" CLOSED_TITLE="t10: blocker"
completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:t10" || completion_status=$?
assert_eq 0 "$completion_status" "completion accepts a positively closed task dependency"

completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:#10,#11" || completion_status=$?
assert_eq "$DER_NOT_READY" "$completion_status" "completion preserves a mixed closed and open dependency set"

completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:t10,not-a-task" || completion_status=$?
assert_eq 1 "$completion_status" "completion fails closed on malformed dependency tokens"

NATIVE_STATE="OPEN"
completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:t10" || completion_status=$?
assert_eq "$DER_NOT_READY" "$completion_status" "completion preserves an open native dependency"
NATIVE_STATE="CLOSED"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20="Blocked by #10" COMMENTS='[[]]'
reconcile_stale_blocked_issues owner/repo >/dev/null 2>&1 || true
assert_eq 1 "$EDIT_COUNT" "periodic stale sweep releases issue after missed close event"
EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20="Blocked by #10 and #11"
stale_sweep_status=0
reconcile_stale_blocked_issues owner/repo >/dev/null 2>&1 || stale_sweep_status=$?
assert_eq 0 "$EDIT_COUNT" "periodic stale sweep preserves another open blocker"
assert_eq 0 "$stale_sweep_status" "periodic stale sweep treats an open blocker as healthy"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20="Blocked by #10" COMMENTS='not-json'
stale_sweep_status=0
reconcile_stale_blocked_issues owner/repo >/dev/null 2>&1 || stale_sweep_status=$?
assert_eq 1 "$stale_sweep_status" "periodic stale sweep still reports API ambiguity"

if grep -q 'issues(first:100,states:' "${SCRIPTS_DIR}/dependency-event-reconciler.sh"; then
	fail "reconciler must not enumerate latest repository issues"
else
	pass "reconciler avoids broad repository issue enumeration"
fi
if grep -A25 'if ! _merge_verify_completed_state' "${SCRIPTS_DIR}/full-loop-helper-merge.sh" | grep -q '_merge_finalize_post_merge' &&
	grep -A30 '^_merge_reconcile_closing_issues()' "${SCRIPTS_DIR}/full-loop-helper-merge.sh" | grep -q 'reconcile_dependants_after_verified_closure'; then
	pass "full-loop hook follows verified merge state"
else
	fail "full-loop hook follows verified merge state"
fi
if grep -A4 'if _gh_with_timeout write gh issue close' "${SCRIPTS_DIR}/pulse-merge.sh" | grep -q 'reconcile_dependants_after_verified_closure'; then
	pass "pulse hook runs only after close command success"
else
	fail "pulse hook runs only after close command success"
fi
if grep -A8 "if gh \"\${close_args\[\@\]}\"" "${SCRIPTS_DIR}/issue-sync-helper-close.sh" | grep -q 'reconcile_dependants_after_verified_closure'; then
	pass "managed direct-close hook runs only after close success"
else
	fail "managed direct-close hook runs only after close success"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
exit $?
