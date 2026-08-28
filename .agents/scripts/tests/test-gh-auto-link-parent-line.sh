#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-auto-link-parent-line.sh — tests for t2738 (GH#20473)
#
# `_gh_auto_link_sub_issue` in `shared-gh-wrappers.sh` fires immediately after
# `gh_create_issue` returns a new issue URL. It attempts to establish a
# GitHub sub-issue relationship between the newly-created child and its
# parent, using two detection methods:
#
#   Method 1 — dot-notation in title: `tNNN.M: foo` → parent `tNNN`,
#              resolved via `gh issue list --search "tNNN: in:title"`.
#
#   Method 2 — `Parent:` line in body: `Parent: #NNN` / `Parent: GH#NNN` /
#              `Parent: tNNN`, plus bold-markdown (`**Parent:**`) and
#              backtick-quoted variants.
#
# Test coverage:
#   1. Dot-notation title fires method 1 (regression — existing behaviour).
#   2. `Parent: #500` in body fires method 2 with raw number.
#   3. `Parent: GH#501` in body fires method 2 with raw number.
#   4. `Parent: t1873` in body fires method 2, resolves via gh issue list.
#   5. `**Parent:** \`t1873\`` (bold + backtick) resolves.
#   6. `--body-file <path>` with `Parent: #502` inside fires method 2.
#   7. No dot-notation and no `Parent:` line → no addSubIssue mutation.
#   8. Dot-notation in title AND `Parent:` in body → method 1 wins.
#   9. Native `gh -R owner/repo` repo selection reaches parent linking.
#
# Strategy mirrors test-backfill-sub-issues.sh: stub `gh` on PATH, record all
# `gh api graphql` calls to a log file, inspect the log after each scenario
# to assert whether `addSubIssue` fired and with which parent.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/shared-gh-wrappers.sh"
CONSTANTS="${SCRIPTS_DIR}/shared-constants.sh"

if [[ ! -f "$HELPER" ]]; then
	printf 'test harness cannot find helper at %s\n' "$HELPER" >&2
	exit 1
fi

TMP=$(mktemp -d -t t2738-auto-link.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Stubbed gh binary
# -----------------------------------------------------------------------------
# The stub records every invocation to $GH_LOG and emits canned responses:
#   gh issue list --search "<prefix>: in:title" ...
#                           → uses GH_LIST_<prefix-safe>_JSON env
#   gh api graphql ... addSubIssue ...
#                           → logs the full arg list, returns success payload
#   gh api graphql ... issue(number ...
#                           → returns a fake node ID string
#   gh repo view ...        → returns "owner/repo"
#   (anything else)         → exits 0 silently
#
# Dots in task IDs cannot appear in bash identifiers, so callers expose
# fixtures under underscore-translated names (e.g. GH_LIST_t1873_JSON).

GH_LOG="${TMP}/gh.log"
export GH_LOG
: >"$GH_LOG"

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

cmd1="${1:-}"
cmd2="${2:-}"

# gh repo view --json nameWithOwner -q .nameWithOwner
if [[ "$cmd1" == "repo" && "$cmd2" == "view" ]]; then
	printf '%s\n' "owner/repo"
	exit 0
fi

# gh issue list --repo ... --search "<prefix>: in:title" ...
# Extract the search value; convert dots to underscores for env-var lookup.
if [[ "$cmd1" == "issue" && "$cmd2" == "list" ]]; then
	prev=""
	search_q=""
	for arg in "$@"; do
		if [[ "$prev" == "--search" ]]; then
			search_q="$arg"
		fi
		prev="$arg"
	done
	# Strip " in:title" suffix and trailing colon: "t1873: in:title" → "t1873"
	prefix="${search_q%%:*}"
	prefix_safe="${prefix//./_}"
	var="GH_LIST_${prefix_safe}_JSON"
	payload="${!var:-[]}"
	printf '%s\n' "$payload"
	exit 0
fi

# gh api graphql -f query=... (node ID lookup or addSubIssue mutation)
if [[ "$cmd1" == "api" && "$cmd2" == "graphql" ]]; then
	for arg in "$@"; do
		if [[ "$arg" == *"addSubIssue"* ]]; then
			# Record the addSubIssue call explicitly so tests can assert on it.
			printf 'ADDSUBISSUE: %s\n' "$*" >>"${GH_LOG:-/dev/null}"
			printf '%s\n' '{"data":{"addSubIssue":{"issue":{"number":1}}}}'
			exit 0
		fi
		if [[ "$arg" == *"issue(number"* ]]; then
			# Emit a fake node ID string — the --jq filter will extract it as-is.
			printf '%s\n' 'NODE_STUB_ID'
			exit 0
		fi
	done
	printf '%s\n' '{}'
	exit 0
fi

# gh auth status and anything else
exit 0
STUB
chmod +x "${TMP}/bin/gh"

# Put the stub first on PATH, then source the helper.
export PATH="${TMP}/bin:${PATH}"

# shared-gh-wrappers.sh expects shared-constants.sh's print_* helpers in scope
# when sourced (see dependency note in the file header). Source it first if
# available, then the wrapper itself.
if [[ -f "$CONSTANTS" ]]; then
	# shellcheck source=../shared-constants.sh
	source "$CONSTANTS" >/dev/null 2>&1 || true
fi
# shellcheck source=../shared-gh-wrappers.sh
source "$HELPER" >/dev/null 2>&1 || true
# Re-prepend in case the sourced files reset PATH
export PATH="${TMP}/bin:${PATH}"

# Fixture: parent t1873 lives at issue #100.
# The stub returns this payload for `gh issue list --search "t1873: in:title"`.
export GH_LIST_t1873_JSON='[{"number":100,"title":"t1873: parent task"}]'
# Parent t2721 lives at #20402 — used to sanity-check the numeric path.
export GH_LIST_t2721_JSON='[{"number":20402,"title":"t2721: parent auto-dispatch"}]'

# Helper: clear the gh log before each scenario so per-test assertions are clean.
reset_log() {
	: >"$GH_LOG"
	return 0
}

# Helper: inspect the log for an addSubIssue call. Returns 0 if found.
saw_addsubissue() {
	if grep -q '^ADDSUBISSUE:' "$GH_LOG"; then
		return 0
	fi
	return 1
}

# Helper: extract the most recent addSubIssue call from the log. Not used for
# strict parent-number assertion (we stub node IDs as a constant), but
# included for future extension.
last_addsubissue_args() {
	grep '^ADDSUBISSUE:' "$GH_LOG" | tail -1
	return 0
}

printf '%sRunning gh auto-link Parent: line tests (t2738)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — dot-notation title fires method 1 (regression)
# =============================================================================
reset_log
_gh_auto_link_sub_issue "https://github.com/owner/repo/issues/200" \
	--repo "owner/repo" \
	--title "t1873.2: child task"
if saw_addsubissue; then
	pass "dot-notation title fires addSubIssue (method 1, regression)"
else
	fail "dot-notation title fires addSubIssue (method 1, regression)" \
		"no ADDSUBISSUE entry in gh log"
fi

# =============================================================================
# Test 9 — native -R repo alias reaches parent linking
# =============================================================================
reset_log
_gh_auto_link_sub_issue "https://github.com/owner/repo/issues/308" \
	-R "owner/repo" \
	--title "plain title" \
	--body "Parent: #503"
if saw_addsubissue; then
	pass "-R repo alias reaches addSubIssue"
else
	fail "-R repo alias reaches addSubIssue" \
		"no ADDSUBISSUE entry in gh log"
fi

# =============================================================================
# Test 2 — Parent: #NNN in body fires method 2
# =============================================================================
reset_log
_gh_auto_link_sub_issue "https://github.com/owner/repo/issues/301" \
	--repo "owner/repo" \
	--title "some plain title without dot-notation" \
	--body "## Session Origin

Follow-up work on the auto-dispatch inventory.

Parent: #500

## What
..."
if saw_addsubissue; then
	pass "Parent: #NNN in body fires addSubIssue (method 2)"
else
	fail "Parent: #NNN in body fires addSubIssue (method 2)" \
		"no ADDSUBISSUE entry in gh log"
fi

# =============================================================================
# Test 3 — Parent: GH#NNN in body fires method 2
# =============================================================================
reset_log
_gh_auto_link_sub_issue "https://github.com/owner/repo/issues/302" \
	--repo "owner/repo" \
	--title "some plain title" \
	--body "Parent: GH#501"
if saw_addsubissue; then
	pass "Parent: GH#NNN in body fires addSubIssue"
else
	fail "Parent: GH#NNN in body fires addSubIssue" \
		"no ADDSUBISSUE entry in gh log"
fi

# =============================================================================
# Test 4 — Parent: tNNN in body resolves via gh issue list
# =============================================================================
reset_log
_gh_auto_link_sub_issue "https://github.com/owner/repo/issues/303" \
	--repo "owner/repo" \
	--title "some plain title" \
	--body "Parent: t1873"
if saw_addsubissue && grep -q 'issue list.*--search t1873' "$GH_LOG"; then
	pass "Parent: tNNN in body resolves via gh issue list + fires addSubIssue"
else
	fail "Parent: tNNN in body resolves via gh issue list + fires addSubIssue" \
		"log missing expected search or addSubIssue entry:
$(cat "$GH_LOG")"
fi

# =============================================================================
# Test 5 — **Parent:** `tNNN` (bold-markdown + backtick) resolves
# =============================================================================
reset_log
_gh_auto_link_sub_issue "https://github.com/owner/repo/issues/304" \
	--repo "owner/repo" \
	--title "some plain title" \
	--body "**Parent:** \`t1873\`"
if saw_addsubissue; then
	pass "bold-markdown **Parent:** \`tNNN\` variant fires addSubIssue"
else
	fail "bold-markdown **Parent:** \`tNNN\` variant fires addSubIssue" \
		"no ADDSUBISSUE entry in gh log"
fi

# =============================================================================
# Test 6 — --body-file with Parent: inside fires method 2
# =============================================================================
reset_log
BODY_FILE="${TMP}/body6.md"
cat >"$BODY_FILE" <<'BODY'
## Session Origin

Some preamble.

Parent: #502

## What
...
BODY
_gh_auto_link_sub_issue "https://github.com/owner/repo/issues/305" \
	--repo "owner/repo" \
	--title "some plain title" \
	--body-file "$BODY_FILE"
if saw_addsubissue; then
	pass "--body-file with Parent: #NNN inside fires addSubIssue"
else
	fail "--body-file with Parent: #NNN inside fires addSubIssue" \
		"no ADDSUBISSUE entry in gh log"
fi

# =============================================================================
# Test 7 — no dot-notation, no Parent: → no mutation (negative)
# =============================================================================
reset_log
_gh_auto_link_sub_issue "https://github.com/owner/repo/issues/306" \
	--repo "owner/repo" \
	--title "plain descriptive title" \
	--body "This body has no parent declaration. It mentions #999 casually but not as Parent."
if saw_addsubissue; then
	fail "no parent signal produces no addSubIssue (negative test)" \
		"unexpected ADDSUBISSUE entry: $(last_addsubissue_args)"
else
	pass "no parent signal produces no addSubIssue (negative test)"
fi

# =============================================================================
# Test 8 — dot-notation in title AND Parent: in body → method 1 wins
# =============================================================================
# Method 1's gh issue list search would use "t2721: in:title" if the parent
# resolution path executed — we assert that it did, and that the body's
# Parent: line was not consulted (no second gh issue list for t1873).
reset_log
_gh_auto_link_sub_issue "https://github.com/owner/repo/issues/307" \
	--repo "owner/repo" \
	--title "t2721.1: phase one" \
	--body "Parent: t1873"
if saw_addsubissue; then
	# Method 1 should have searched t2721; it should not have also searched t1873.
	if grep -q 'issue list.*--search t2721' "$GH_LOG" &&
		! grep -q 'issue list.*--search t1873' "$GH_LOG"; then
		pass "dot-notation title wins over body Parent: (method 1 short-circuits)"
	else
		fail "dot-notation title wins over body Parent:" \
			"unexpected search pattern in gh log:
$(cat "$GH_LOG")"
	fi
else
	fail "dot-notation title wins over body Parent:" \
		"method 1 did not fire addSubIssue"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
printf '%sTests run: %d, failed: %d%s\n' "$TEST_BLUE" "$TESTS_RUN" "$TESTS_FAILED" "$TEST_NC"
if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi
exit 0
