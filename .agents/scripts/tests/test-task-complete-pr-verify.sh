#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-task-complete-pr-verify.sh — regression tests for GH#22075
#
# Verifies that verify_pr_merged() in task-complete-helper.sh accepts merged
# PRs regardless of the state string returned by the GitHub API.
#
# Root cause (GH#22075):
#   The GitHub GraphQL API returns state=MERGED; the REST API returns
#   state=closed (lowercase) for the same merged PR. The original check
#   required state=="MERGED" exactly, so REST-fallback responses failed even
#   when mergedAt was populated.
#
# Tests:
#   1. state=MERGED  + mergedAt populated → passes (happy-path regression)
#   2. state=closed  + mergedAt populated → passes (the GH#22075 bug fix)
#   3. state=CLOSED  + mergedAt populated → passes (REST fallback regression)
#   4. state=closed  + mergedAt empty + REST merged=true / merged_at → passes
#   5. state=CLOSED  + mergedAt empty     → fails  (genuinely unmerged PR)
#   6. state=OPEN    + mergedAt empty     → fails  (open PR)
#
# Strategy:
#   - Create a real git repo in a temp dir (script needs git add/commit).
#   - Write a minimal fixture TODO.md for each test.
#   - Place a mock 'gh' binary earlier in PATH that emits controlled output.
#   - Call task-complete-helper.sh with --pr (no --skip-merge-check).
#   - Assert exit code and TODO.md state.

set -u

# Fixture repositories are disposable; use native Git rather than the runtime
# canonical-worktree guard shim that protects the actual source checkout.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

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
HELPER="${SCRIPTS_DIR}/task-complete-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf 'test harness cannot find helper at %s\n' "$HELPER" >&2
	exit 1
fi

TMP=$(mktemp -d -t gh22075-pr-verify.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Minimal fixture TODO.md used by every test
# -----------------------------------------------------------------------------
FIXTURE_TODO='## Format

- [ ] tXXX Description #tag

## Routines

## Ready

- [ ] t999 verify-pr-test task #tag ~1h ref:GH#999 logged:2026-01-01

## Backlog

## In Progress

## In Review

## Done

## Declined
'

# -----------------------------------------------------------------------------
# setup_repo: create a minimal git repo with fixture TODO.md
# Sets REPO_PATH.
# -----------------------------------------------------------------------------
setup_repo() {
	local repo_name="${1:-repo}"
	local repo_dir="$TMP/$repo_name"
	mkdir -p "$repo_dir"
	printf '%s\n' "$FIXTURE_TODO" >"$repo_dir/TODO.md"
	git -C "$repo_dir" init -q
	git -C "$repo_dir" config user.email "test@test.com"
	git -C "$repo_dir" config user.name "Test"
	git -C "$repo_dir" config commit.gpgsign false
	git -C "$repo_dir" config tag.gpgsign false
	git -C "$repo_dir" add TODO.md
	git -C "$repo_dir" commit -q -m "initial"
	REPO_PATH="$repo_dir"
	return 0
}

# -----------------------------------------------------------------------------
# make_mock_gh: write a mock 'gh' binary into a temp dir.
# The mock intercepts 'gh pr view ... --json ... --jq ...' calls and emits
# a tab-separated "state\tmergedAt" line matching what the real gh+jq produces.
#
# Arguments:
#   $1  - output directory for the mock binary
#   $2  - state string to return  (e.g. "MERGED", "closed", "CLOSED", "OPEN")
#   $3  - mergedAt value to return (e.g. "2026-04-30T12:00:00Z" or "")
#   $4  - REST merged boolean to return (default: false)
#   $5  - REST merged_at value to return (default: empty)
#   $6  - REST state string to return (default: closed)
# -----------------------------------------------------------------------------
make_mock_gh() {
	local mock_dir="$1"
	local mock_state="$2"
	local mock_merged_at="$3"
	local mock_rest_merged="${4:-false}"
	local mock_rest_merged_at="${5:-}"
	local mock_rest_state="${6:-closed}"

	mkdir -p "$mock_dir"
	# Use printf to avoid heredoc quoting issues with embedded variables.
	{
		printf '#!/usr/bin/env bash\n'
		printf '# Mock gh for PR verification regression tests\n'
		# SC2016: single quotes are intentional — we're writing shell code to a file,
		# not expanding ${1:-} or ${2:-} in this process.
		# shellcheck disable=SC2016
		printf 'if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then\n'
		printf '  while [[ "$#" -gt 0 ]]; do\n'
		# shellcheck disable=SC2016
		printf '    if [[ "${1:-}" == "--json" ]]; then\n'
		# shellcheck disable=SC2016
		printf '      if [[ "${2:-}" == *merged* && "${2:-}" != "state,mergedAt" ]]; then\n'
		printf '        printf '"'"'Unknown JSON field: merged\n'"'"' >&2\n'
		printf '        exit 1\n'
		printf '      fi\n'
		printf '    fi\n'
		printf '    shift\n'
		printf '  done\n'
		printf '  printf '"'"'%%s\t%%s\n'"'"' "%s" "%s"\n' "$mock_state" "$mock_merged_at"
		printf '  exit 0\n'
		printf 'fi\n'
		# shellcheck disable=SC2016
		printf 'if [[ "${1:-}" == "api" && "${2:-}" == repos/*/pulls/* ]]; then\n'
		printf '  printf '"'"'%%s\t%%s\t%%s\n'"'"' "%s" "%s" "%s"\n' "$mock_rest_state" "$mock_rest_merged" "$mock_rest_merged_at"
		printf '  exit 0\n'
		printf 'fi\n'
		# Forward non-pr-view calls to the real gh so git operations are not broken.
		# shellcheck disable=SC2016
		printf 'exec "$(PATH=$(echo "$PATH" | sed '"'"'s|[^:]*mock[^:]*:||g'"'"') which gh 2>/dev/null || echo /usr/bin/gh)" "$@"\n'
	} >"$mock_dir/gh"
	chmod +x "$mock_dir/gh"
	return 0
}

printf '%sRunning verify_pr_merged tests (GH#22075)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1: state=MERGED, mergedAt populated — should pass (regression guard)
# =============================================================================
printf '\nTest 1: state=MERGED + mergedAt populated → task marked complete\n'

MOCK_DIR_1="$TMP/mock1"
make_mock_gh "$MOCK_DIR_1" "MERGED" "2026-04-30T12:00:00Z"
setup_repo "repo1"

if PATH="$MOCK_DIR_1:$PATH" "$HELPER" t999 --pr 9001 --gh-repo owner/repo \
	--no-push --repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "exits 0 (state=MERGED, mergedAt populated)"
else
	fail "exits 0 (state=MERGED, mergedAt populated)" "helper unexpectedly failed"
fi

if grep -qE "\- \[x\] t999" "$REPO_PATH/TODO.md"; then
	pass "t999 marked [x] in TODO.md"
else
	fail "t999 marked [x] in TODO.md" "task was not marked complete"
fi

# =============================================================================
# Test 2: state=closed (REST fallback), mergedAt populated — should PASS (bug fix)
# =============================================================================
printf '\nTest 2: state=closed + mergedAt populated → task marked complete (GH#22075 fix)\n'

MOCK_DIR_2="$TMP/mock2"
make_mock_gh "$MOCK_DIR_2" "closed" "2026-04-30T12:00:00Z"
setup_repo "repo2"

if PATH="$MOCK_DIR_2:$PATH" "$HELPER" t999 --pr 9002 --gh-repo owner/repo \
	--no-push --repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "exits 0 (state=closed, mergedAt populated)"
else
	fail "exits 0 (state=closed, mergedAt populated)" \
		"helper failed — GH#22075 bug still present (state=closed rejected despite mergedAt)"
fi

if grep -qE "\- \[x\] t999" "$REPO_PATH/TODO.md"; then
	pass "t999 marked [x] in TODO.md"
else
	fail "t999 marked [x] in TODO.md" "task was not marked complete even though helper exited 0"
fi

# =============================================================================
# Test 3: state=CLOSED, mergedAt populated — should PASS (REST fallback)
# =============================================================================
printf '\nTest 3: state=CLOSED + mergedAt populated → task marked complete without unsupported merged field\n'

MOCK_DIR_3="$TMP/mock3"
make_mock_gh "$MOCK_DIR_3" "CLOSED" "2026-04-30T12:00:00Z"
setup_repo "repo3"

if PATH="$MOCK_DIR_3:$PATH" "$HELPER" t999 --pr 9003 --gh-repo owner/repo \
	--no-push --repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "exits 0 (state=CLOSED, mergedAt populated)"
else
	fail "exits 0 (state=CLOSED, mergedAt populated)" \
		"helper failed — mergedAt evidence rejected or unsupported merged field requested"
fi

if grep -qE "\- \[x\] t999" "$REPO_PATH/TODO.md"; then
	pass "t999 marked [x] in TODO.md"
else
	fail "t999 marked [x] in TODO.md" "task was not marked complete even though mergedAt was populated"
fi

# =============================================================================
# Test 4: state=closed, mergedAt empty, REST merged=true + merged_at — should PASS
# =============================================================================
printf '\nTest 4: state=closed + mergedAt empty + REST merged=true/merged_at → task marked complete\n'

MOCK_DIR_4="$TMP/mock4"
make_mock_gh "$MOCK_DIR_4" "closed" "" "true" "2026-05-01T16:11:09Z" "closed"
setup_repo "repo4"

if PATH="$MOCK_DIR_4:$PATH" "$HELPER" t999 --pr 9004 --gh-repo owner/repo \
	--no-push --repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "exits 0 (state=closed, mergedAt empty, REST merged=true/merged_at populated)"
else
	fail "exits 0 (state=closed, mergedAt empty, REST merged=true/merged_at populated)" \
		"helper failed — REST merged evidence was not accepted"
fi

if grep -qE "\- \[x\] t999" "$REPO_PATH/TODO.md"; then
	pass "t999 marked [x] in TODO.md"
else
	fail "t999 marked [x] in TODO.md" "task was not marked complete even though REST merged evidence was populated"
fi

# =============================================================================
# Test 5: state=CLOSED, mergedAt empty, merged=false — should FAIL (unmerged closed PR)
# =============================================================================
printf '\nTest 5: state=CLOSED + mergedAt empty + merged=false → task NOT marked complete\n'

MOCK_DIR_5="$TMP/mock5"
make_mock_gh "$MOCK_DIR_5" "CLOSED" ""
setup_repo "repo5"

if ! PATH="$MOCK_DIR_5:$PATH" "$HELPER" t999 --pr 9005 --gh-repo owner/repo \
	--no-push --repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "exits non-zero (state=CLOSED, mergedAt empty, merged=false)"
else
	fail "exits non-zero (state=CLOSED, mergedAt empty, merged=false)" \
		"helper unexpectedly succeeded for unmerged closed PR"
fi

if grep -qE "\- \[ \] t999" "$REPO_PATH/TODO.md"; then
	pass "t999 remains open in TODO.md"
else
	fail "t999 remains open in TODO.md" "task was incorrectly marked complete"
fi

# =============================================================================
# Test 6: state=OPEN, mergedAt empty, merged=false — should FAIL (open PR)
# =============================================================================
printf '\nTest 6: state=OPEN + mergedAt empty + merged=false → task NOT marked complete\n'

MOCK_DIR_6="$TMP/mock6"
make_mock_gh "$MOCK_DIR_6" "OPEN" ""
setup_repo "repo6"

if ! PATH="$MOCK_DIR_6:$PATH" "$HELPER" t999 --pr 9006 --gh-repo owner/repo \
	--no-push --repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "exits non-zero (state=OPEN, mergedAt empty, merged=false)"
else
	fail "exits non-zero (state=OPEN, mergedAt empty, merged=false)" \
		"helper unexpectedly succeeded for an open PR"
fi

if grep -qE "\- \[ \] t999" "$REPO_PATH/TODO.md"; then
	pass "t999 remains open in TODO.md"
else
	fail "t999 remains open in TODO.md" "task was incorrectly marked complete"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%s----%s\n' "$TEST_BLUE" "$TEST_NC"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests FAILED%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
