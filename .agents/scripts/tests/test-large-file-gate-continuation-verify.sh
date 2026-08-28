#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-large-file-gate-continuation-verify.sh — t2164 Fix B regression guard.
#
# `_large_file_gate_create_debt_issue()` in pulse-dispatch-large-file-gate.sh
# previously short-circuited as "recently-closed — continuation" whenever a
# closed file-size-debt issue mentioned the file's basename within the
# 30-day reopen window (GH#18960). This had no outcome verification: a
# closed function-complexity-debt issue whose merge PR did NOT reduce the file
# below the file-size threshold would be cited as in-flight continuation,
# permanently stranding the file behind the gate.
#
# Concrete failure (GH#19415):
#   - function-complexity-debt #18706 ("reduce function complexity in
#     issue-sync-helper.sh, 1 functions >100 lines") closed by PR #18715,
#     which decomposed cmd_enrich() but added net +29 lines (file went
#     from ~2165 to 2194 lines).
#   - The large-file gate (file > 2000) then fired on a different parent
#     issue and posted "Simplification issues: #18706 (recently-closed —
#     continuation)" — phantom continuation; nothing was in flight to
#     reduce file size.
#
# Fix (t2164): add a wc -l verification step in the recently-closed branch.
# Only short-circuit as continuation when the file is now under threshold.
# If still over, log and reopen the canonical debt issue. Preserve
# the pre-t2164 behaviour (trust the closed signal) when repo_path is
# missing or the file isn't on disk in this checkout — measurement
# unavailable is safer-as-continuation than safer-as-duplicate.
#
# Tests:
#   1. Closed exists, file UNDER threshold, repo_path provided
#      → returns "(recently-closed — continuation)"
#   2. Closed exists, file OVER threshold, repo_path provided
#      → verifies remote content; reopens only when remote is also over
#   3. Local file OVER threshold but remote file UNDER threshold
#      → keeps the solved canonical issue closed
#   4. Local file OVER threshold but remote verification unavailable
#      → defers reopening
#   5. Closed exists, no repo_path
#      → returns "(recently-closed — continuation)" (backward-compat fallback)
#   6. Closed exists, repo_path set but file not on disk
#      → returns "(recently-closed — continuation)" (measurement unavailable)
#   7. No open, no closed match
#      → returns "(new)"
#   8. Open match exists
#      → returns "(existing)"
#   9. Pulse orchestration sees a stale local default branch
#      → blocks for the cycle without measuring or mutating issue state
#
# Cross-references: GH#19415 / t2152 (the blocked investigation that
# surfaced this bug), GH#18960 (the dedup the bug exists inside),
# GH#19483 / t2164 (this fix).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
GATE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-dispatch-large-file-gate.sh"

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
TMP=$(mktemp -d -t t2164.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
export LOGFILE
LARGE_FILE_LINE_THRESHOLD=2000

# Files that exercise the threshold (over and under)
OVER_FILE="${TMP}/over.sh"
UNDER_FILE="${TMP}/under.sh"
yes ":" 2>/dev/null | head -n 2050 >"$OVER_FILE"
yes ":" 2>/dev/null | head -n 100 >"$UNDER_FILE"

# =============================================================================
# Stub state — writeable by stubs, read by assertions
# =============================================================================
GH_OPEN_RESPONSE=""   # what the open-issue search returns
GH_CLOSED_RESPONSE="" # what the closed-issue search returns
GH_CALLS_LOG="${TMP}/gh_calls.log"
GH_CREATE_RESPONSE_URL=""
GH_REMOTE_CONTENT_RESPONSE=""
GH_REMOTE_CONTENT_FAIL=""
GH_LABELS_RESPONSE=""
: >"$GH_CALLS_LOG"

# =============================================================================
# Stubs — defined AFTER source so they shadow whatever the module loaded
# =============================================================================
# shellcheck source=/dev/null
source "$GATE_SCRIPT"

# t2995: define wrapper stubs so the gate's gh_issue_list calls reach the
# gh() shell-function stub below. Without these, gh_issue_list resolves to
# a missing external command (rc=127), which the old gate code path
# swallowed as "no match" but the new t2995 path correctly treats as
# "lookup failed → defer".
gh_issue_list() {
	gh issue list "$@"
	return $?
}

gh_issue_view() {
	printf '%s' "$GH_LABELS_RESPONSE"
	return 0
}

# t2995: no-op the 2-second retry sleep introduced for search-index lag
# so the test doesn't actually pause.
sleep() { return 0; }

gh() {
	# Log every call for debugging
	printf '%s\n' "gh $*" >>"$GH_CALLS_LOG"

	# Pattern-match on the args we care about.
	# Open file-size-debt search:
	#   gh issue list --repo X --state open --label file-size-debt --search ...
	# Closed file-size-debt search:
	#   gh issue list --repo X --state closed --label file-size-debt --search ...
	local saw_open="false" saw_closed="false"
	local arg
	for arg in "$@"; do
		case "$arg" in
		open) saw_open="true" ;;
		closed) saw_closed="true" ;;
		esac
	done
	if [[ "$1" == "api" && "$2" == "repos/owner/repo" ]]; then
		printf 'main\n'
		return 0
	fi
	if [[ "$1" == "api" && "$2" == "--method" && "$3" == "GET" && "$4" == repos/owner/repo/contents/* ]]; then
		[[ -z "$GH_REMOTE_CONTENT_FAIL" ]] || return 1
		printf '%s\n' "$GH_REMOTE_CONTENT_RESPONSE"
		return 0
	fi
	if [[ "$1" == "issue" && "$2" == "list" && "$saw_open" == "false" && "$saw_closed" == "false" ]]; then
		if [[ -n "$GH_OPEN_RESPONSE" ]]; then
			printf '[{"number":%s,"state":"OPEN","body":"generator=large-file-simplification-gate cited_file=under.sh threshold=2000 generator=large-file-simplification-gate cited_file=over.sh threshold=2000 generator=large-file-simplification-gate cited_file=missing.sh threshold=2000"}]\n' "$GH_OPEN_RESPONSE"
		elif [[ -n "$GH_CLOSED_RESPONSE" ]]; then
			printf '[{"number":%s,"state":"CLOSED","body":"generator=large-file-simplification-gate cited_file=under.sh threshold=2000 generator=large-file-simplification-gate cited_file=over.sh threshold=2000 generator=large-file-simplification-gate cited_file=missing.sh threshold=2000"}]\n' "$GH_CLOSED_RESPONSE"
		else
			printf '[]\n'
		fi
		return 0
	fi

	if [[ "$1" == "issue" && "$2" == "list" ]]; then
		if [[ "$saw_closed" == "true" ]]; then
			if [[ -n "$GH_CLOSED_RESPONSE" ]]; then
				printf '[{"number":%s,"body":"generator=large-file-simplification-gate cited_file=under.sh threshold=2000 generator=large-file-simplification-gate cited_file=over.sh threshold=2000 generator=large-file-simplification-gate cited_file=missing.sh threshold=2000"}]\n' "$GH_CLOSED_RESPONSE"
			else
				printf '[]\n'
			fi
			return 0
		fi
		if [[ "$saw_open" == "true" ]]; then
			if [[ -n "$GH_OPEN_RESPONSE" ]]; then
				printf '[{"number":%s,"body":"generator=large-file-simplification-gate cited_file=under.sh threshold=2000 generator=large-file-simplification-gate cited_file=over.sh threshold=2000 generator=large-file-simplification-gate cited_file=missing.sh threshold=2000"}]\n' "$GH_OPEN_RESPONSE"
			else
				printf '[]\n'
			fi
			return 0
		fi
	fi
	if [[ "$1" == "issue" && "$2" == "reopen" ]]; then
		return 0
	fi
	if [[ "$1" == "issue" && "$2" == "edit" ]]; then
		return 0
	fi

	# label create — silent no-op
	if [[ "$1" == "label" && "$2" == "create" ]]; then
		return 0
	fi

	# Anything else — silent no-op
	return 0
}

_remote_content_json() {
	local file_path="$1"
	local encoded=""
	encoded=$(base64 <"$file_path" | tr -d '\n') || return 1
	jq -cn --arg content "$encoded" '{type:"file",encoding:"base64",content:$content}'
	return 0
}

gh_create_issue() {
	printf '%s\n' "gh_create_issue $*" >>"$GH_CALLS_LOG"
	# Emit a synthetic issue URL so _new_num parsing succeeds
	if [[ -n "$GH_CREATE_RESPONSE_URL" ]]; then
		printf '%s\n' "$GH_CREATE_RESPONSE_URL"
	fi
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

assert_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       expected to contain: %q\n' "$needle"
	printf '       actual:              %q\n' "$haystack"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# =============================================================================
# Tests
# =============================================================================
printf '\n=== test-large-file-gate-continuation-verify.sh (t2164 Fix B) ===\n\n'

# ---- Test 1 — closed exists, file UNDER threshold → continuation ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_CREATE_RESPONSE_URL=""
out=$(_large_file_gate_create_debt_issue "under.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"closed + file under threshold → continuation" \
	"#18706 (recently-closed — continuation)" \
	"$out"

# ---- Test 2 — closed exists, file OVER threshold → reopen canonical ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_CREATE_RESPONSE_URL=""
GH_REMOTE_CONTENT_RESPONSE=$(_remote_content_json "$OVER_FILE")
GH_REMOTE_CONTENT_FAIL=""
GH_LABELS_RESPONSE=""
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"closed + file over threshold → reopen canonical issue" \
	"#18706 (reopened)" \
	"$out"
assert_contains \
	"file-over-threshold path logs canonical reopen" \
	"prior file-size-debt #18706 closed but remote over.sh still 2050 lines" \
	"$(cat "$LOGFILE")"
assert_contains \
	"file-over-threshold path calls gh issue reopen" \
	"gh issue reopen 18706 --repo owner/repo" \
	"$(cat "$GH_CALLS_LOG")"

# A prior terminal closure must not leave the reopened canonical issue
# ineligible for candidate enumeration.
: >"$GH_CALLS_LOG"
GH_LABELS_RESPONSE="duplicate,already-fixed,status:done,not-planned,simplification-incomplete,wontfix"
out=$(_large_file_gate_reopen_debt_issue "18706" "over.sh" "owner/repo")
assert_eq \
	"terminal-labelled canonical issue reopens" \
	"#18706 (reopened)" \
	"$out"
assert_contains \
	"reopened canonical issue removes terminal exclusion labels" \
	"--remove-label duplicate" \
	"$(cat "$GH_CALLS_LOG")"
assert_contains \
	"reopened canonical issue removes already-fixed label" \
	"--remove-label already-fixed" \
	"$(cat "$GH_CALLS_LOG")"
assert_contains \
	"reopened canonical issue restores active lifecycle labels" \
	"--add-label file-size-debt,auto-dispatch" \
	"$(cat "$GH_CALLS_LOG")"

# ---- Test 3 — stale local OVER, remote UNDER → keep solved issue closed ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_REMOTE_CONTENT_RESPONSE=$(_remote_content_json "$UNDER_FILE")
GH_REMOTE_CONTENT_FAIL=""
GH_LABELS_RESPONSE=""
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"stale local over + remote under → continuation" \
	"#18706 (recently-closed — continuation)" \
	"$out"
assert_contains \
	"stale local measurement is diagnosed" \
	"stale local checkout reports over.sh at 2050 lines; remote default branch is 100 lines" \
	"$(cat "$LOGFILE")"

# ---- Test 4 — local OVER, remote unavailable → fail closed without reopen ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_REMOTE_CONTENT_RESPONSE=""
GH_REMOTE_CONTENT_FAIL="1"
GH_LABELS_RESPONSE=""
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"local over + remote unavailable → defer reopen" \
	"#18706 (recently-closed — continuation)" \
	"$out"
assert_contains \
	"remote verification failure is diagnosed" \
	"current remote content could not be verified; deferring canonical debt reopen" \
	"$(cat "$LOGFILE")"

# ---- Test 5 — closed exists, no repo_path → backward-compat continuation ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_CREATE_RESPONSE_URL=""
GH_REMOTE_CONTENT_FAIL=""
GH_LABELS_RESPONSE=""
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo")
assert_eq \
	"closed + no repo_path → continuation (backward-compat fallback)" \
	"#18706 (recently-closed — continuation)" \
	"$out"

# ---- Test 6 — closed exists, repo_path set but file missing → continuation ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_CREATE_RESPONSE_URL=""
GH_LABELS_RESPONSE=""
out=$(_large_file_gate_create_debt_issue "missing.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"closed + file missing on disk → continuation (measurement unavailable)" \
	"#18706 (recently-closed — continuation)" \
	"$out"

# ---- Test 7 — no open, no closed → creates new ----
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE=""
GH_CREATE_RESPONSE_URL="https://github.com/owner/repo/issues/88888"
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"no prior issue → NEW" \
	"#88888 (new)" \
	"$out"

# ---- Test 8 — open exists → existing (short-circuit before continuation logic) ----
GH_OPEN_RESPONSE="55555"
GH_CLOSED_RESPONSE=""
GH_CREATE_RESPONSE_URL=""
out=$(_large_file_gate_create_debt_issue "over.sh" "9999" "owner/repo" "$TMP")
assert_eq \
	"open exists → existing (short-circuit)" \
	"#55555 (existing)" \
	"$out"

# ---- Test 9 — stale pulse checkout → defer before local measurement ----
_pulse_refresh_repo() { return 0; }
_large_file_gate_repo_matches_remote_default() { return 1; }
GH_OPEN_RESPONSE=""
GH_CLOSED_RESPONSE="18706"
GH_REMOTE_CONTENT_RESPONSE=$(_remote_content_json "$UNDER_FILE")
GH_REMOTE_CONTENT_FAIL=""
before_calls=$(wc -l <"$GH_CALLS_LOG" | tr -d ' ')
rc=0
_issue_targets_large_files "9993" "owner/repo" \
	"## How"$'\n'"- EDIT: \`over.sh\`" "$TMP" "false" || rc=$?
after_calls=$(wc -l <"$GH_CALLS_LOG" | tr -d ' ')
assert_eq \
	"stale pulse checkout → dispatch remains blocked for retry" \
	"0" \
	"$rc"
assert_eq \
	"stale pulse checkout → no debt mutation calls" \
	"$before_calls" \
	"$after_calls"
assert_contains \
	"stale pulse checkout → explicit defer diagnostic" \
	"is not at the verified remote default-branch commit" \
	"$(cat "$LOGFILE")"

printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '\n--- gh call log ---\n'
	cat "$GH_CALLS_LOG"
	printf '\n--- pulse log ---\n'
	cat "$LOGFILE"
	exit 1
fi
exit 0
