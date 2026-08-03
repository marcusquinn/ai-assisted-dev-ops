#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-migration-simplification-labels.sh — Unit tests for migrate-simplification-debt-labels.sh
#
# Covers the three classification cases:
#   1. file-size-debt pattern   → "simplification-debt: <path> exceeds N lines"
#   2. function-complexity-debt → "simplification: reduce function complexity in <file>"
#   3. ambiguous title          → skip with warning
#
# Also covers:
#   4. Already-relabeled issues are skipped (idempotent)
#   5. Dry-run prints actions without calling gh issue edit
#
# Test isolation: `gh` is stubbed to record calls without making API calls.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SCRIPT="${SCRIPT_DIR_TEST}/../migrate-simplification-debt-labels.sh"

if [[ ! -f "$MIGRATE_SCRIPT" ]]; then
	echo "ERROR: ${MIGRATE_SCRIPT} not found" >&2
	exit 1
fi

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
TMP=$(mktemp -d -t t2168.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS_LOG="${TMP}/gh_calls.log"
GH_ADD_LABELS_LOG="${TMP}/gh_add_labels.log"
GH_REMOVE_LABELS_LOG="${TMP}/gh_remove_labels.log"
GH_ISSUE_LIST_RESPONSE=""
: >"$GH_CALLS_LOG"
: >"$GH_ADD_LABELS_LOG"
: >"$GH_REMOVE_LABELS_LOG"

# =============================================================================
# Helpers
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

assert_not_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       expected NOT to contain: %q\n' "$needle"
	printf '       actual:                  %q\n' "$haystack"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Reset logs between tests
reset_logs() {
	: >"$GH_CALLS_LOG"
	: >"$GH_ADD_LABELS_LOG"
	: >"$GH_REMOVE_LABELS_LOG"
	return 0
}

# =============================================================================
# Define _classify_title inline for unit testing.
# Copied from migrate-simplification-debt-labels.sh — keep in sync.
# We define it directly here to avoid sourcing the full script (which
# requires REPO_SLUG and gh to be present).
# =============================================================================
_classify_title() {
	local title="$1"
	if printf '%s' "$title" | grep -qE '^(simplification-debt|file-size-debt): .+ exceeds [0-9]+ lines$'; then
		printf 'file-size-debt'
		return 0
	fi
	if printf '%s' "$title" | grep -qE '^simplification: reduce (function complexity|[0-9]+ Qlty smells)'; then
		printf 'function-complexity-debt'
		return 0
	fi
	if printf '%s' "$title" | grep -qE '^simplification: re-queue .+ \(pass [0-9]+'; then
		printf 'function-complexity-debt'
		return 0
	fi
	if printf '%s' "$title" | grep -qiE '(simplification debt stalled|LLM complexity sweep|LLM sweep needed)'; then
		printf 'skip'
		return 0
	fi
	printf 'skip'
	return 0
}

# =============================================================================
# Tests — _classify_title classification logic
# =============================================================================
printf '\n=== test-migration-simplification-labels.sh (t2168) ===\n\n'
printf '%s\n\n' '--- Classification tests ---'

# ---- Test 1: file-size-debt — legacy "simplification-debt: <path> exceeds N lines" ----
result=$(_classify_title "simplification-debt: .agents/scripts/issue-sync-helper.sh exceeds 2000 lines")
assert_eq \
	"legacy simplification-debt title → file-size-debt" \
	"file-size-debt" "$result"

# ---- Test 2: file-size-debt — already-renamed "file-size-debt: <path> exceeds N lines" ----
result=$(_classify_title "file-size-debt: .agents/scripts/pulse-wrapper.sh exceeds 2000 lines")
assert_eq \
	"file-size-debt title → file-size-debt (idempotent)" \
	"file-size-debt" "$result"

# ---- Test 3: function-complexity-debt — "reduce function complexity" ----
result=$(_classify_title "simplification: reduce function complexity in .agents/scripts/foo.sh (2 functions >100 lines)")
assert_eq \
	"reduce function complexity title → function-complexity-debt" \
	"function-complexity-debt" "$result"

# ---- Test 4: function-complexity-debt — "reduce N Qlty smells" ----
result=$(_classify_title "simplification: reduce 17 Qlty smells in pulse-simplification.sh")
assert_eq \
	"Qlty smells title → function-complexity-debt" \
	"function-complexity-debt" "$result"

# ---- Test 5: function-complexity-debt — re-queue ----
result=$(_classify_title "simplification: re-queue .agents/scripts/bar.sh (pass 2, 5 smells remaining)")
assert_eq \
	"re-queue title → function-complexity-debt" \
	"function-complexity-debt" "$result"

# ---- Test 6: skip — LLM sweep meta review ----
result=$(_classify_title "perf: simplification debt stalled — LLM sweep needed (2026-04-01)")
assert_eq \
	"LLM sweep stall title → skip (meta review)" \
	"skip" "$result"

# ---- Test 7: skip — LLM complexity sweep meta review ----
result=$(_classify_title "LLM complexity sweep: review stalled function-complexity debt")
assert_eq \
	"LLM complexity sweep title → skip (meta review)" \
	"skip" "$result"

# ---- Test 8: skip — ambiguous/unmatched title ----
result=$(_classify_title "fix: update authentication logic")
assert_eq \
	"unmatched title → skip" \
	"skip" "$result"

# ---- Test 9: skip — generic simplification title without classification ----
result=$(_classify_title "simplification: general cleanup of foo.sh")
assert_eq \
	"generic simplification title → skip (manual triage needed)" \
	"skip" "$result"

# =============================================================================
# Fake gh binary — used for integration tests (dry-run and live mode).
# Written to a temp dir and prepended to PATH so subshells pick it up.
# =============================================================================
FAKE_GH="${TMP}/fake-gh-bin/gh"
mkdir -p "${TMP}/fake-gh-bin"
cat >"$FAKE_GH" <<'FAKE_GH_SCRIPT'
#!/usr/bin/env bash
# Fake gh that reads GH_ISSUE_LIST_RESPONSE env var for issue list calls
# and logs add/remove label edits to files for assertion.

GH_ADD_LABELS_LOG="${GH_ADD_LABELS_LOG:-/dev/null}"
GH_REMOVE_LABELS_LOG="${GH_REMOVE_LABELS_LOG:-/dev/null}"
GH_CALLS_LOG="${GH_CALLS_LOG:-/dev/null}"

printf 'gh %s\n' "$*" >> "$GH_CALLS_LOG"

case "$1 $2" in
"issue list")
    printf '%s\n' "${GH_ISSUE_LIST_RESPONSE:-[]}"
    exit 0
    ;;
"issue edit")
    prev_arg=""
    for arg in "$@"; do
        case "$prev_arg" in
        "--add-label") printf '%s\n' "$arg" >> "$GH_ADD_LABELS_LOG" ;;
        "--remove-label") printf '%s\n' "$arg" >> "$GH_REMOVE_LABELS_LOG" ;;
        esac
        prev_arg="$arg"
    done
    exit 0
    ;;
"label create"|"issue close"|"issue view")
    exit 0
    ;;
esac
exit 0
FAKE_GH_SCRIPT
chmod +x "$FAKE_GH"

run_migrate() {
	local issue_json="$1"
	shift
	GH_ISSUE_LIST_RESPONSE="$issue_json" \
	GH_ADD_LABELS_LOG="$GH_ADD_LABELS_LOG" \
	GH_REMOVE_LABELS_LOG="$GH_REMOVE_LABELS_LOG" \
	GH_CALLS_LOG="$GH_CALLS_LOG" \
	PATH="${TMP}/fake-gh-bin:$PATH" \
	bash "$MIGRATE_SCRIPT" --repo "test/repo" "$@" 2>&1
	return 0
}

# =============================================================================
# Tests — dry-run mode
# =============================================================================
printf '\n--- Dry-run tests ---\n\n'

# ---- Test 10: dry-run does not call gh issue edit ----
DRY_RUN_ISSUES='[
  {"number":100,"title":"simplification-debt: .agents/scripts/foo.sh exceeds 2000 lines","labels":[{"name":"simplification-debt"}]},
  {"number":101,"title":"simplification: reduce function complexity in .agents/scripts/bar.sh (3 functions >100 lines)","labels":[{"name":"simplification-debt"}]}
]'

reset_logs
out=$(run_migrate "$DRY_RUN_ISSUES" --dry-run)

# In dry-run, no gh issue edit calls should be made
add_labels=$(cat "$GH_ADD_LABELS_LOG" 2>/dev/null) || add_labels=""
assert_eq \
	"dry-run: no gh issue edit --add-label calls made" \
	"" "$add_labels"

assert_contains \
	"dry-run: output mentions file-size-debt classification" \
	"file-size-debt" "$out"

assert_contains \
	"dry-run: output mentions function-complexity-debt classification" \
	"function-complexity-debt" "$out"

# =============================================================================
# Tests — live mode label changes
# =============================================================================
printf '\n--- Live mode tests ---\n\n'

# ---- Test 11: live mode applies correct labels ----
LIVE_ISSUES='[
  {"number":200,"title":"simplification-debt: .agents/scripts/big.sh exceeds 2000 lines","labels":[{"name":"simplification-debt"}]},
  {"number":201,"title":"simplification: reduce function complexity in .agents/scripts/complex.sh (1 functions >100 lines)","labels":[{"name":"simplification-debt"}]},
  {"number":202,"title":"fix: some unrelated fix","labels":[{"name":"simplification-debt"}]}
]'

reset_logs
out=$(run_migrate "$LIVE_ISSUES")

add_labels=$(cat "$GH_ADD_LABELS_LOG" 2>/dev/null) || add_labels=""
remove_labels=$(cat "$GH_REMOVE_LABELS_LOG" 2>/dev/null) || remove_labels=""

assert_contains \
	"live: file-size-debt added for exceeds-lines title" \
	"file-size-debt" "$add_labels"

assert_contains \
	"live: function-complexity-debt added for complexity title" \
	"function-complexity-debt" "$add_labels"

assert_contains \
	"live: simplification-debt removed" \
	"simplification-debt" "$remove_labels"

assert_contains \
	"live: ambiguous issue reported" \
	"ambiguous" "$out"

# ---- Test 12: already-relabeled issues skipped (idempotent) ----
ALREADY_MIGRATED_ISSUES='[
  {"number":300,"title":"simplification-debt: already-migrated.sh exceeds 2000 lines","labels":[{"name":"simplification-debt"},{"name":"file-size-debt"}]}
]'

reset_logs
out=$(run_migrate "$ALREADY_MIGRATED_ISSUES")

add_labels=$(cat "$GH_ADD_LABELS_LOG" 2>/dev/null) || add_labels=""
assert_eq \
	"idempotent: already-relabeled issue not touched" \
	"" "$add_labels"

assert_contains \
	"idempotent: output mentions already relabeled" \
	"already relabeled" "$out"

# =============================================================================
# Summary
# =============================================================================
printf '\n=== Summary: %s passed, %s failed ===\n' \
	"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
