#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-reeval-stale-continuation.sh — t2170 Fix E regression guard.
#
# Tests TWO fixes shipped in t2170:
#
# PRIMARY (pulse-dispatch-large-file-gate.sh line 654):
#   When _large_file_gate_extract_paths returns empty AND the issue carries
#   needs-simplification, the gate must auto-clear the label and return 1
#   instead of early-returning without clearing. Empirical evidence: GH#19415
#   received a CLEARED comment but the label persisted until manual removal.
#
# SECONDARY (_reevaluate_stale_continuations in pulse-triage.sh):
#   When _issue_targets_large_files returns 0 (file still targeted), the
#   re-evaluation pass checks whether ALL cited "recently-closed — continuation"
#   issues are stale. If yes, clears the label to break the deadlock.
#
# Tests:
#   PRIMARY (pulse-dispatch-large-file-gate.sh primary fix):
#   1. Empty extraction + labeled issue → label cleared, return 1
#   2. Empty extraction + unlabeled issue → no clear, return 1
#   3. Non-empty extraction + large file → gate applies (return 0)
#   4. Stale prefetched gate label → fresh lifecycle state wins
#   5. Label edit failure → gate remains applied, no false CLEARED comment
#   6. Unconfirmed label removal → gate remains applied, no false CLEARED comment
#
#   SECONDARY (_reevaluate_stale_continuations):
#   7. No gate comment → label preserved (safe fallback)
#   8. Open continuation → label preserved (work in progress)
#   9. Closed + simplification-incomplete → label cleared (no wc-l needed)
#   10. Closed + file over threshold → label cleared (stale citation)
#   11. Closed + file under threshold → label preserved (prior work effective)
#   12. Multiple continuations, all stale → label cleared
#   13. Multiple continuations, one open → label preserved (short-circuit)
#
# Cross-references: GH#19415 (stuck label), GH#19499/t2170 (this fix),
#   t2164 (Fix A/B), t2169 (Fix D — simplification-incomplete label)

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
GATE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-dispatch-large-file-gate.sh"
TRIAGE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-triage.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2170.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
export LOGFILE
export REPOS_JSON="${TMP}/repos.json"
LARGE_FILE_LINE_THRESHOLD=2000
export LARGE_FILE_LINE_THRESHOLD

# Files for threshold tests — relative to TMP so resolve_path finds them
OVER_BASENAME="large-over.sh"
UNDER_BASENAME="large-under.sh"
yes ":" 2>/dev/null | head -n 2050 >"${TMP}/${OVER_BASENAME}"
yes ":" 2>/dev/null | head -n 100 >"${TMP}/${UNDER_BASENAME}"

# =============================================================================
# Stub state — writeable by stubs, read by assertions
# =============================================================================
GH_CALLS_LOG="${TMP}/gh_calls.log"
: >"$GH_CALLS_LOG"

# Per-test state reset via reset_state()
GH_LABEL_REMOVED=""
GH_VIEW_JSON=""     # JSON for plain gh issue view (no --comments)
GH_COMMENTS_JSON="" # gh-shaped comment fixture ({"comments":[...]})
GH_EDIT_RC=0
GH_EDIT_KEEP_LABEL="false"

# =============================================================================
# Source gate first (defines _large_file_gate_* and _issue_targets_large_files)
# =============================================================================
# shellcheck source=/dev/null
source "$GATE_SCRIPT"
# shellcheck source=/dev/null
source "$TRIAGE_SCRIPT"

# =============================================================================
# Stubs — defined AFTER source so they shadow the sourced implementations.
# The gh stub forwards --jq filters through actual jq so callers that use
# the `gh ... --json fields --jq filter` pattern get processed output.
# =============================================================================
gh() {
	printf '%s\n' "gh $*" >>"$GH_CALLS_LOG"

	# gh issue edit --remove-label
	if [[ "$1" == "issue" && "$2" == "edit" ]]; then
		local arg
		for arg in "$@"; do
			if [[ "$arg" == "--remove-label" ]]; then
				[[ "$GH_EDIT_RC" -eq 0 ]] || return "$GH_EDIT_RC"
				GH_LABEL_REMOVED="true"
				if [[ "$GH_EDIT_KEEP_LABEL" != "true" ]]; then
					GH_VIEW_JSON=$(printf '%s' "$GH_VIEW_JSON" | jq -c '.labels = [.labels[]? | select(.name != "needs-simplification")]' 2>/dev/null) || true
				fi
				return 0
			fi
			[[ "$arg" == "--add-label" ]] && return 0
		done
		return 0
	fi

	# gh issue view — detect --comments and --jq
	if [[ "$1" == "issue" && "$2" == "view" ]]; then
		local saw_comments="false"
		local jq_filter=""
		local next_is_jq="false"
		local arg
		for arg in "$@"; do
			if [[ "$next_is_jq" == "true" ]]; then
				jq_filter="$arg"
				next_is_jq="false"
			elif [[ "$arg" == "--comments" ]]; then
				saw_comments="true"
			elif [[ "$arg" == "--jq" ]]; then
				next_is_jq="true"
			fi
		done

		if [[ "$saw_comments" == "true" ]]; then
			if [[ -n "$jq_filter" ]]; then
				printf '%s\n' "$GH_COMMENTS_JSON" | jq -r "$jq_filter" 2>/dev/null
			else
				printf '%s\n' "$GH_COMMENTS_JSON"
			fi
			return 0
		fi

		if [[ -n "$jq_filter" ]]; then
			printf '%s\n' "$GH_VIEW_JSON" | jq -r "$jq_filter" 2>/dev/null
		else
			printf '%s\n' "$GH_VIEW_JSON"
		fi
		return 0
	fi

	# gh issue list — return view JSON (labels check for precheck)
	if [[ "$1" == "issue" && "$2" == "list" ]]; then
		local jq_filter=""
		local next_is_jq="false"
		local arg
		for arg in "$@"; do
			if [[ "$next_is_jq" == "true" ]]; then
				jq_filter="$arg"
				next_is_jq="false"
			elif [[ "$arg" == "--jq" ]]; then
				next_is_jq="true"
			fi
		done
		if [[ -n "$jq_filter" ]]; then
			printf '%s\n' "$GH_VIEW_JSON" | jq -r "$jq_filter" 2>/dev/null
		else
			printf '%s\n' "$GH_VIEW_JSON"
		fi
		return 0
	fi

	# gh label create — silent no-op
	[[ "$1" == "label" && "$2" == "create" ]] && return 0

	# gh api issue comments — convert the gh-shaped fixture to paginated REST.
	if [[ "$1" == "api" && "${2:-}" == repos/*/issues/*/comments\?per_page=100 ]]; then
		printf '%s\n' "$GH_COMMENTS_JSON" | jq -c '[.comments // []]'
		return 0
	fi
	[[ "$1" == "api" ]] && printf '[]' && return 0

	# gh issue comment — no-op
	[[ "$1" == "issue" && "$2" == "comment" ]] && return 0

	return 0
}

gh_issue_view() {
	gh issue view "$@"
	return $?
}

gh_issue_list() {
	if [[ "$*" == *"--json number,body,state"* ]]; then
		printf '[]\n'
		return 0
	fi
	gh issue list "$@"
	return $?
}

gh_create_issue() {
	printf '%s\n' "gh_create_issue $*" >>"$GH_CALLS_LOG"
	return 0
}

_gh_idempotent_comment() {
	printf '%s\n' "_gh_idempotent_comment $*" >>"$GH_CALLS_LOG"
	return 0
}

_post_simplification_gate_cleared_comment() {
	printf '%s\n' "_post_simplification_gate_cleared_comment $*" >>"$GH_CALLS_LOG"
	return 0
}

# =============================================================================
# Assertions
# =============================================================================
assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       expected: %q\n' "$expected"
	printf '       actual:   %q\n' "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

reset_state() {
	GH_LABEL_REMOVED=""
	GH_VIEW_JSON=""
	GH_COMMENTS_JSON=""
	GH_EDIT_RC=0
	GH_EDIT_KEEP_LABEL="false"
	: >"$GH_CALLS_LOG"
	: >"$LOGFILE"
}

# =============================================================================
# PRIMARY fix tests: _issue_targets_large_files empty-extraction auto-clear
# =============================================================================
printf '\n=== PRIMARY fix: _issue_targets_large_files empty-extraction auto-clear ===\n\n'

# ---- Test 1: empty extraction + labeled → label cleared, return 1 ----
reset_state
# View returns labeled JSON; the code's --jq filter will extract label names
GH_VIEW_JSON='{"labels":[{"name":"needs-simplification"}]}'
# Body with NO intent markers (only backtick refs — pre-Fix-A matched these)
empty_body="See \`pulse-triage.sh\` for context."
rc=0
_issue_targets_large_files "9999" "owner/repo" "$empty_body" "$TMP" "true" || rc=$?
assert_eq \
	"empty extraction + labeled → returns 1 (no large files)" \
	"1" "$rc"
assert_eq \
	"empty extraction + labeled → label cleared" \
	"true" "${GH_LABEL_REMOVED:-false}"

# ---- Test 2: empty extraction + unlabeled → no clear, return 1 ----
reset_state
GH_VIEW_JSON='{"labels":[]}'
rc=0
_issue_targets_large_files "9998" "owner/repo" "$empty_body" "$TMP" "true" || rc=$?
assert_eq \
	"empty extraction + unlabeled → returns 1 (no large files)" \
	"1" "$rc"
assert_eq \
	"empty extraction + unlabeled → label NOT cleared" \
	"" "${GH_LABEL_REMOVED}"

# ---- Test 3: non-empty extraction + large file → gate applies (return 0) ----
reset_state
GH_VIEW_JSON='{"labels":[]}'
# Use a relative-path .sh file in a backtick EDIT: line so the extractor
# picks it up and _large_file_gate_evaluate_target resolves it via ${TMP}/${path}
large_body="EDIT: \`${OVER_BASENAME}\`"
rc=0
_issue_targets_large_files "9997" "owner/repo" "$large_body" "$TMP" "true" || rc=$?
assert_eq \
	"non-empty extraction + large file → returns 0 (gate applies)" \
	"0" "$rc"

# ---- Test 4: stale prefetched gate label is refreshed before blocking ----
reset_state
GH_VIEW_JSON='{"labels":[{"name":"status:queued"}],"title":"active worker"}'
stale_meta='{"labels":[{"name":"needs-simplification"}],"title":"stale gate snapshot"}'
rc=0
_issue_targets_large_files "9996" "owner/repo" "$large_body" "$TMP" "false" "$stale_meta" || rc=$?
assert_eq \
	"stale prefetched needs-simplification label → fresh active lifecycle wins" \
	"1" "$rc"

# ---- Test 5: failed stale-label removal keeps the gate applied ----
reset_state
GH_VIEW_JSON='{"labels":[{"name":"needs-simplification"}]}'
GH_EDIT_RC=1
rc=0
_issue_targets_large_files "9995" "owner/repo" "$empty_body" "$TMP" "true" || rc=$?
assert_eq \
	"failed stale-label removal → gate remains applied" \
	"0" "$rc"
if grep -qF '_post_simplification_gate_cleared_comment' "$GH_CALLS_LOG"; then
	assert_eq "failed stale-label removal → no false CLEARED comment" "absent" "present"
else
	assert_eq "failed stale-label removal → no false CLEARED comment" "absent" "absent"
fi

# ---- Test 6: unconfirmed stale-label removal keeps the gate applied ----
reset_state
GH_VIEW_JSON='{"labels":[{"name":"needs-simplification"}]}'
GH_EDIT_KEEP_LABEL="true"
rc=0
_issue_targets_large_files "9994" "owner/repo" "$empty_body" "$TMP" "true" || rc=$?
assert_eq \
	"unconfirmed stale-label removal → gate remains applied" \
	"0" "$rc"
if grep -qF '_post_simplification_gate_cleared_comment' "$GH_CALLS_LOG"; then
	assert_eq "unconfirmed stale-label removal → no false CLEARED comment" "absent" "present"
else
	assert_eq "unconfirmed stale-label removal → no false CLEARED comment" "absent" "absent"
fi

# =============================================================================
# SECONDARY fix tests: _reevaluate_stale_continuations
# =============================================================================
printf '\n=== SECONDARY fix: _reevaluate_stale_continuations ===\n\n'

GATE_COMMENT_BODY="## Large File Simplification Gate

This issue references file(s) exceeding 2000 lines.

**Simplification issues:** PLACEHOLDER"

make_gate_comments() {
	local issues_line="$1"
	local body="${GATE_COMMENT_BODY/PLACEHOLDER/${issues_line}}"
	jq -cn --arg body "$body" '{"comments":[{"body":$body}]}'
}

# ---- Test 7: no gate comment → label preserved ----
reset_state
GH_COMMENTS_JSON='{"comments":[]}'
GH_VIEW_JSON='{"state":"OPEN","labels":[],"title":"some issue"}'
rc=0
_reevaluate_stale_continuations "100" "owner/repo" "$TMP" || rc=$?
assert_eq \
	"no gate comment → return 1 (label preserved)" \
	"1" "$rc"
assert_eq \
	"no gate comment → label NOT removed" \
	"" "${GH_LABEL_REMOVED}"
rest_comment_reads=$(grep -cF 'gh api repos/owner/repo/issues/100/comments?per_page=100 --paginate --slurp' "$GH_CALLS_LOG" 2>/dev/null || true)
native_comment_reads=$(grep -cE '^gh issue view 100 .*--comments' "$GH_CALLS_LOG" 2>/dev/null || true)
assert_eq \
	"gate comment lookup uses paginated REST" \
	"1:0" "${rest_comment_reads}:${native_comment_reads}"

# ---- Test 8: open continuation → label preserved ----
reset_state
GH_COMMENTS_JSON=$(make_gate_comments "#42 (recently-closed — continuation)")
# gh issue view #42 returns state=OPEN
GH_VIEW_JSON='{"state":"OPEN","labels":[],"title":"file-size-debt: large-over.sh exceeds 2000 lines"}'
rc=0
_reevaluate_stale_continuations "100" "owner/repo" "$TMP" || rc=$?
assert_eq \
	"open continuation → return 1 (label preserved)" \
	"1" "$rc"
assert_eq \
	"open continuation → label NOT removed" \
	"" "${GH_LABEL_REMOVED}"

# ---- Test 9: closed + simplification-incomplete → label cleared (no wc-l) ----
reset_state
GH_COMMENTS_JSON=$(make_gate_comments "#43 (recently-closed — continuation)")
GH_VIEW_JSON='{"state":"CLOSED","labels":[{"name":"simplification-incomplete"}],"title":"file-size-debt: large-over.sh exceeds 2000 lines"}'
rc=0
_reevaluate_stale_continuations "100" "owner/repo" "$TMP" || rc=$?
assert_eq \
	"simplification-incomplete → return 0 (cleared, no wc-l needed)" \
	"0" "$rc"
assert_eq \
	"simplification-incomplete → label removed" \
	"true" "${GH_LABEL_REMOVED:-false}"

# ---- Test 10: closed + file over threshold → label cleared (stale citation) ----
reset_state
GH_COMMENTS_JSON=$(make_gate_comments "#44 (recently-closed — continuation)")
GH_VIEW_JSON=$(jq -cn \
	--arg path "${OVER_BASENAME}" \
	'{"state":"CLOSED","labels":[],"title": ("file-size-debt: " + $path + " exceeds 2000 lines")}')
rc=0
_reevaluate_stale_continuations "100" "owner/repo" "$TMP" || rc=$?
assert_eq \
	"closed + file over threshold → return 0 (label cleared, citation stale)" \
	"0" "$rc"
assert_eq \
	"closed + file over threshold → label removed" \
	"true" "${GH_LABEL_REMOVED:-false}"

# ---- Test 11: closed + file under threshold → label preserved (work effective) ----
reset_state
GH_COMMENTS_JSON=$(make_gate_comments "#45 (recently-closed — continuation)")
GH_VIEW_JSON=$(jq -cn \
	--arg path "${UNDER_BASENAME}" \
	'{"state":"CLOSED","labels":[],"title": ("file-size-debt: " + $path + " exceeds 2000 lines")}')
rc=0
_reevaluate_stale_continuations "100" "owner/repo" "$TMP" || rc=$?
assert_eq \
	"closed + file under threshold → return 1 (label preserved, work effective)" \
	"1" "$rc"
assert_eq \
	"closed + file under threshold → label NOT removed" \
	"" "${GH_LABEL_REMOVED}"

# ---- Test 12: multiple continuations, all stale → label cleared ----
reset_state
OVER_BASENAME2="large-over2.sh"
yes ":" 2>/dev/null | head -n 2050 >"${TMP}/${OVER_BASENAME2}"
GH_COMMENTS_JSON=$(make_gate_comments "#46 (recently-closed — continuation), #47 (recently-closed — continuation)")

# Both continuation issues closed + over-threshold; alternate per call
_t9_call=0
gh() {
	printf '%s\n' "gh $*" >>"$GH_CALLS_LOG"
	if [[ "$1" == "issue" && "$2" == "edit" ]]; then
		local arg
		for arg in "$@"; do
			[[ "$arg" == "--remove-label" ]] && GH_LABEL_REMOVED="true" && return 0
		done
		return 0
	fi
	if [[ "$1" == "issue" && "$2" == "view" ]]; then
		local saw_comments="false"
		local jq_filter=""
		local next_is_jq="false"
		local arg
		for arg in "$@"; do
			if [[ "$next_is_jq" == "true" ]]; then
				jq_filter="$arg"
				next_is_jq="false"
			elif [[ "$arg" == "--comments" ]]; then
				saw_comments="true"
			elif [[ "$arg" == "--jq" ]]; then
				next_is_jq="true"
			fi
		done
		if [[ "$saw_comments" == "true" ]]; then
			if [[ -n "$jq_filter" ]]; then
				printf '%s\n' "$GH_COMMENTS_JSON" | jq -r "$jq_filter" 2>/dev/null
			else
				printf '%s\n' "$GH_COMMENTS_JSON"
			fi
			return 0
		fi
		_t9_call=$((_t9_call + 1))
		local resp
		if ((_t9_call % 2 == 1)); then
			resp=$(jq -cn --arg p "$OVER_BASENAME" \
				'{"state":"CLOSED","labels":[],"title":("file-size-debt: "+$p+" exceeds 2000 lines")}')
		else
			resp=$(jq -cn --arg p "$OVER_BASENAME2" \
				'{"state":"CLOSED","labels":[],"title":("file-size-debt: "+$p+" exceeds 2000 lines")}')
		fi
		if [[ -n "$jq_filter" ]]; then
			printf '%s\n' "$resp" | jq -r "$jq_filter" 2>/dev/null
		else
			printf '%s\n' "$resp"
		fi
		return 0
	fi
	[[ "$1" == "label" && "$2" == "create" ]] && return 0
	if [[ "$1" == "api" && "${2:-}" == repos/*/issues/*/comments\?per_page=100 ]]; then
		printf '%s\n' "$GH_COMMENTS_JSON" | jq -c '[.comments // []]'
		return 0
	fi
	[[ "$1" == "api" ]] && printf '[]' && return 0
	[[ "$1" == "issue" && "$2" == "comment" ]] && return 0
	[[ "$1" == "issue" && "$2" == "list" ]] && printf '%s\n' "$GH_VIEW_JSON" && return 0
	return 0
}

rc=0
_reevaluate_stale_continuations "100" "owner/repo" "$TMP" || rc=$?
assert_eq \
	"all-stale multi-continuation → return 0 (label cleared)" \
	"0" "$rc"
assert_eq \
	"all-stale multi-continuation → label removed" \
	"true" "${GH_LABEL_REMOVED:-false}"

# Restore standard stub
gh() {
	printf '%s\n' "gh $*" >>"$GH_CALLS_LOG"
	if [[ "$1" == "issue" && "$2" == "edit" ]]; then
		local arg
		for arg in "$@"; do
			[[ "$arg" == "--remove-label" ]] && GH_LABEL_REMOVED="true" && return 0
		done
		return 0
	fi
	if [[ "$1" == "issue" && "$2" == "view" ]]; then
		local saw_comments="false"
		local jq_filter=""
		local next_is_jq="false"
		local arg
		for arg in "$@"; do
			if [[ "$next_is_jq" == "true" ]]; then
				jq_filter="$arg"
				next_is_jq="false"
			elif [[ "$arg" == "--comments" ]]; then
				saw_comments="true"
			elif [[ "$arg" == "--jq" ]]; then
				next_is_jq="true"
			fi
		done
		if [[ "$saw_comments" == "true" ]]; then
			if [[ -n "$jq_filter" ]]; then
				printf '%s\n' "$GH_COMMENTS_JSON" | jq -r "$jq_filter" 2>/dev/null
			else
				printf '%s\n' "$GH_COMMENTS_JSON"
			fi
			return 0
		fi
		if [[ -n "$jq_filter" ]]; then
			printf '%s\n' "$GH_VIEW_JSON" | jq -r "$jq_filter" 2>/dev/null
		else
			printf '%s\n' "$GH_VIEW_JSON"
		fi
		return 0
	fi
	if [[ "$1" == "issue" && "$2" == "list" ]]; then
		local jq_filter=""
		local next_is_jq="false"
		local arg
		for arg in "$@"; do
			if [[ "$next_is_jq" == "true" ]]; then
				jq_filter="$arg"
				next_is_jq="false"
			elif [[ "$arg" == "--jq" ]]; then
				next_is_jq="true"
			fi
		done
		if [[ -n "$jq_filter" ]]; then
			printf '%s\n' "$GH_VIEW_JSON" | jq -r "$jq_filter" 2>/dev/null
		else
			printf '%s\n' "$GH_VIEW_JSON"
		fi
		return 0
	fi
	[[ "$1" == "label" && "$2" == "create" ]] && return 0
	if [[ "$1" == "api" && "${2:-}" == repos/*/issues/*/comments\?per_page=100 ]]; then
		printf '%s\n' "$GH_COMMENTS_JSON" | jq -c '[.comments // []]'
		return 0
	fi
	[[ "$1" == "api" ]] && printf '[]' && return 0
	[[ "$1" == "issue" && "$2" == "comment" ]] && return 0
	return 0
}

# ---- Test 13: one open continuation → label preserved (short-circuit) ----
reset_state
GH_COMMENTS_JSON=$(make_gate_comments "#48 (recently-closed — continuation), #49 (recently-closed — continuation)")
# Both view calls return OPEN → first citation valid → should short-circuit
GH_VIEW_JSON='{"state":"OPEN","labels":[],"title":"file-size-debt: large-over.sh exceeds 2000 lines"}'
rc=0
_reevaluate_stale_continuations "100" "owner/repo" "$TMP" || rc=$?
assert_eq \
	"one open continuation → return 1 (label preserved, short-circuit on valid)" \
	"1" "$rc"
assert_eq \
	"one open continuation → label NOT removed" \
	"" "${GH_LABEL_REMOVED}"

# =============================================================================
# Summary
# =============================================================================
printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '\n--- gh call log ---\n'
	cat "$GH_CALLS_LOG"
	printf '\n--- pulse log ---\n'
	cat "$LOGFILE"
	exit 1
fi
exit 0
