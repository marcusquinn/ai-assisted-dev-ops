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
NATIVE_REPO="owner/repo"
NATIVE_HAS_NEXT_PAGE=false
NATIVE_NULL_NODE=false
NATIVE_EXTRA_STATE=""
NATIVE_EXTRA_REPO=""
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

assert_hold() {
	local expected="$1"
	local body="$2"
	local comments="$3"
	local labels="$4"
	local name="$5"
	local actual=0
	_der_has_hold "$body" "$comments" "$labels" && actual=1
	assert_eq "$expected" "$actual" "$name"
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

# Exercise the production GraphQL argument shape before replacing the search
# helper with deterministic candidate fixtures. The deployed gh wrapper rejects
# reusing `query` for both the document and a GraphQL variable.
gh() {
	local command="$1"
	local flag=""
	local value=""
	local document_seen=false
	local search_query_seen=false
	shift
	[[ "$command" == "api" && "${1:-}" == "graphql" ]] || return 1
	shift
	while [[ $# -gt 1 ]]; do
		flag="$1"
		value="$2"
		shift 2
		case "$flag" in
		-f)
			[[ "$value" == query=* ]] && document_seen=true
			;;
		-F)
			[[ "$value" == query=* ]] && return 1
			[[ "$value" == searchQuery=* ]] && search_query_seen=true
			;;
		esac
	done
	[[ "$document_seen" == "true" && "$search_query_seen" == "true" ]] || return 1
	jq -cn '{data:{search:{issueCount:0,pageInfo:{hasNextPage:false},nodes:[]}}}'
	return 0
}

search_transport_status=0
search_transport_result=$(_der_search_issues "owner/repo" "repo:owner/repo is:issue is:open") || search_transport_status=$?
assert_eq 0 "$search_transport_status" "search GraphQL document and variable use distinct form fields"
assert_eq '[]' "$search_transport_result" "search transport preserves parsed empty candidate results"

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
	local nodes=""
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
		if [[ "$NATIVE_NULL_NODE" == "true" ]]; then
			nodes='[null]'
		else
			nodes=$(jq -cn --arg state "$NATIVE_STATE" --arg repo "$NATIVE_REPO" \
				--arg extra_state "$NATIVE_EXTRA_STATE" --arg extra_repo "$NATIVE_EXTRA_REPO" '
              [{number:10,state:$state,repository:{nameWithOwner:$repo}}]
              + (if $extra_state == "" then [] else
                  [{number:11,state:$extra_state,repository:{nameWithOwner:$extra_repo}}]
                end)') || return 1
		fi
		jq -cn --argjson nodes "$nodes" --argjson has_next_page "$NATIVE_HAS_NEXT_PAGE" \
			'{data:{repository:{issue:{blockedBy:{nodes:$nodes,pageInfo:{hasNextPage:$has_next_page}}}}}}'
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

assert_hold 1 "On hold for maintainer" "" "status:blocked" "direct classifier preserves an explicit operational hold"
assert_hold 1 "- **Defer until security review**" "" "status:blocked" "direct classifier preserves a prefixed defer directive"
assert_hold 1 "### On hold for maintainer" "" "status:blocked" "direct classifier preserves an operational hold heading"
assert_hold 1 "Do-not-dispatch: migration active" "" "status:blocked" "direct classifier preserves a do-not-dispatch directive"
assert_hold 1 "Hold for release approval" "" "status:blocked" "direct classifier preserves a hold-for directive"
assert_hold 1 "On hold for maintainer | release manager" "" "status:blocked" "direct classifier preserves an operational hold containing one pipe"
assert_hold 1 "" "Worker result: **BLOCKED** and cannot proceed safely" "status:blocked" "direct classifier preserves worker escalation comments"
assert_hold 1 "" "Worker Watchdog Kill" "status:blocked" "direct classifier preserves watchdog escalation comments"
assert_hold 1 "" "Terminal blocker detected" "status:blocked" "direct classifier preserves terminal blocker comments"
assert_hold 1 "" "ACTION REQUIRED" "status:blocked" "direct classifier preserves action-required comments"
assert_hold 1 "" "HUMAN_UNBLOCK_REQUIRED" "status:blocked" "direct classifier preserves human-unblock markers"
assert_hold 1 "The labels are mentioned descriptively." "" "status:blocked,hold-for-review" "direct classifier preserves exact hold-for-review labels"
assert_hold 1 "" "" "status:blocked,needs-maintainer-review" "direct classifier preserves exact maintainer-review labels"
assert_hold 1 "" "" "status:blocked,no-auto-dispatch" "direct classifier preserves exact no-auto-dispatch labels"
assert_hold 0 "The hold-for-review label is documented here." "" "status:blocked" "direct classifier ignores management-label names in prose"
assert_hold 0 $'| Outcome | Action |\n| unknown_review | Hold for bounded review; no implementation issue |' "" "status:blocked" "direct classifier ignores hold phrases in Markdown tables"
assert_hold 0 $'Example:\n```text\nDo not dispatch\n```' "" "status:blocked" "direct classifier ignores hold phrases in fenced examples"
assert_hold 0 $'Example:\n~~~text\nOn hold for demonstration\n~~~' "" "status:blocked" "direct classifier ignores hold phrases in tilde-fenced examples"
assert_hold 1 $'Example:\n```text\n<!--\nDo not dispatch\n```\nOn hold for maintainer' "" "status:blocked" "fenced comment syntax cannot hide a later operational hold"
assert_hold 1 $'<!--\n```text\n-->\nOn hold for maintainer' "" "status:blocked" "commented fence syntax cannot hide a later operational hold"
assert_hold 0 $'```text\nDo not dispatch\n~~~\nOn hold in the same example\n```' "" "status:blocked" "mismatched fence delimiters cannot expose example holds"
assert_hold 0 $'````text\nDo not dispatch\n```\nOn hold in the same example\n````' "" "status:blocked" "short fence delimiters cannot close longer examples"
assert_hold 1 $'```text\nACTION REQUIRED in generated worker output\n```' "" "status:blocked" "strong machine markers remain authoritative inside examples"
assert_hold 0 "This reference explains why an issue may be on hold for review." "" "status:blocked" "direct classifier ignores explanatory hold prose"
assert_hold 0 $'<!--\nPaused: example only\n-->' "" "status:blocked" "direct classifier ignores hold phrases in HTML comments"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20=$'Blocked by #10\n\n| Outcome | Action |\n|---|---|\n| unknown_review | Hold for bounded review; no implementation issue |'
assert_eq 1 "$(run_reconcile)" "classification table prose does not suppress close-event reconciliation"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20=$'Blocked by #10\n\nThis reference explains why an issue may be on hold for review.'
assert_eq 1 "$(run_reconcile)" "explanatory prose does not suppress close-event reconciliation"

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

NATIVE_REPO="other/repo" NATIVE_EXTRA_STATE="CLOSED" NATIVE_EXTRA_REPO="owner/repo"
completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:t10" || completion_status=$?
assert_eq 0 "$completion_status" "completion accepts closed local and cross-repository native blockers"

NATIVE_EXTRA_STATE="OPEN"
completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:t10" || completion_status=$?
assert_eq "$DER_NOT_READY" "$completion_status" "completion preserves an open cross-repository native blocker"
NATIVE_REPO="owner/repo" NATIVE_EXTRA_STATE="" NATIVE_EXTRA_REPO=""

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

NATIVE_REPO=""
completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:t10" || completion_status=$?
assert_eq 1 "$completion_status" "completion fails closed on a missing native blocker repository"
NATIVE_REPO="owner/repo" NATIVE_STATE="UNKNOWN"
completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:t10" || completion_status=$?
assert_eq 1 "$completion_status" "completion fails closed on an unknown native blocker state"
NATIVE_STATE="CLOSED" NATIVE_HAS_NEXT_PAGE=true
completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:t10" || completion_status=$?
assert_eq 1 "$completion_status" "completion fails closed on paginated native blockers"
NATIVE_HAS_NEXT_PAGE=false NATIVE_NULL_NODE=true
completion_status=0
_der_completion_blockers_closed "owner/repo" 20 "- [ ] t20 delivered blocked-by:t10" || completion_status=$?
assert_eq 1 "$completion_status" "completion fails closed on null native blocker nodes"
NATIVE_NULL_NODE=false

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20="Blocked by #10" COMMENTS='[[]]'
reconcile_stale_blocked_issues owner/repo >/dev/null 2>&1 || true
assert_eq 1 "$EDIT_COUNT" "periodic stale sweep releases issue after missed close event"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20=$'Blocked by #10\n\nExample:\n```text\nDo not dispatch\n```'
reconcile_stale_blocked_issues owner/repo >/dev/null 2>&1 || true
assert_eq 1 "$EDIT_COUNT" "periodic stale sweep ignores fenced hold examples"

EDIT_COUNT=0 REREAD_LABELS="status:blocked" BODY20=$'Blocked by #10\n\n> **Paused: awaiting maintainer**'
reconcile_stale_blocked_issues owner/repo >/dev/null 2>&1 || true
assert_eq 0 "$EDIT_COUNT" "periodic stale sweep preserves prefixed operational hold lines"

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
