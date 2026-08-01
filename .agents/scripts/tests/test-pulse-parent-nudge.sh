#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex/grep patterns are literal by design
#
# test-pulse-parent-nudge.sh — structural tests for t2388 (GH#19927)
#
# Verifies the parent-task decomposition nudge wiring split across the parent
# and action reconciliation modules. The nudge fires when a parent-task-labelled
# issue has ZERO filed children, which is a silent-stuck state: dispatch is
# blocked by the parent-task label, the completion sweep has nothing to sweep,
# and nothing else nudges it forward.
#
# Test strategy: this is a structural test — we grep the source file to
# verify the wiring is present, rather than executing the function (which
# would require gh API stubs for comments + sub-issue graph + label list).
# Functional verification of the idempotency marker and comment posting
# path happens live when the pulse runs against the first eligible parent.
#
# Test coverage:
#   1. Helper function _post_parent_decomposition_nudge exists
#   2. Helper uses the canonical marker <!-- parent-needs-decomposition -->
#   3. Helper performs idempotency check via gh api comments lookup
#   4. Helper posts comment via gh issue comment
#   5. Reconcile function declares total_nudged counter
#   6. Reconcile function declares max_nudges cap
#   7. Reconcile function fetches issue_title from jq
#   8. Reconcile function calls _post_parent_decomposition_nudge when
#      child_nums is empty
#   9. Reconcile function increments total_nudged on successful nudge
#  10. Final log line includes nudged= counter
#  11. Helper file is shellcheck-clean (delegated to CI)

set -u

# Use TEST_-prefixed color vars to avoid colliding with readonly vars
# from shared-constants.sh when the helper is sourced later.
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

assert_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected pattern: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

assert_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qF "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected literal: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

# --- Locate source file ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT_TARGET="$SCRIPT_DIR/pulse-issue-reconcile-parent.sh"
ACTIONS_TARGET="$SCRIPT_DIR/pulse-issue-reconcile-actions.sh"

for target in "$PARENT_TARGET" "$ACTIONS_TARGET"; do
	if [[ ! -f "$target" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $target not found"
		exit 1
	fi
done

echo "${TEST_BLUE}=== t2388: parent-task decomposition nudge structural tests ===${TEST_NC}"
echo ""

# --- Helper function presence ---

assert_grep \
	"1: _post_parent_decomposition_nudge function defined" \
	'^_post_parent_decomposition_nudge\(\) \{' \
	"$PARENT_TARGET"

# --- Marker wiring ---

assert_grep_fixed \
	"2: helper uses canonical marker <!-- parent-needs-decomposition -->" \
	'<!-- parent-needs-decomposition -->' \
	"$PARENT_TARGET"

# --- Idempotency check ---

assert_grep \
	"3: helper queries existing comments via gh api --paginate for idempotency" \
	'gh api --paginate "repos/\$\{slug\}/issues/\$\{parent_num\}/comments"' \
	"$PARENT_TARGET"

# --- Comment posting ---

assert_grep \
	"4: helper posts via gh_issue_comment wrapper" \
	'gh_issue_comment "\$parent_num" --repo "\$slug"' \
	"$PARENT_TARGET"

# --- Reconcile function counter ---

assert_grep \
	"5: reconcile declares total_nudged=0 counter" \
	'local total_nudged=0' \
	"$PARENT_TARGET"

assert_grep \
	"6: reconcile declares max_nudges=5 cap" \
	'local max_nudges=5' \
	"$PARENT_TARGET"

# --- Title extraction ---

assert_grep \
	"7: reconcile extracts issue_title from jq" \
	'issue_title=\$\(printf .* jq -r --argjson i "\$i" .*.title' \
	"$PARENT_TARGET"

# --- Nudge call wiring ---

assert_grep \
	"8: reconcile calls _post_parent_decomposition_nudge with slug+num+title" \
	'_post_parent_decomposition_nudge "\$slug" "\$issue_num" "\$issue_title"' \
	"$ACTIONS_TARGET"

# --- Counter increment ---

assert_grep \
	"9: reconcile increments total_nudged on success" \
	'total_nudged=\$\(\(total_nudged \+ 1\)\)' \
	"$PARENT_TARGET"

# --- Final log line ---

assert_grep \
	"10: final log line includes nudged= counter" \
	'nudged=\$\{total_nudged\}' \
	"$PARENT_TARGET"

# --- Entry conditions ---

# The nudge MUST fire only when child_nums is empty AND both sub-issue
# graph and body-section lookups have been tried. This is enforced by
# placing the nudge AFTER the existing graph/body resolution block and
# BEFORE the silent-continue that previously existed.
assert_grep_fixed \
	"11a: no-child action branch exists after child-source union" \
	'if [[ -z "$child_nums" ]]; then' \
	"$ACTIONS_TARGET"

assert_grep_fixed \
	"11b: nudge remains bounded by the caller-provided action cap" \
	'if [[ "$can_nudge" == "1" ]]; then' \
	"$ACTIONS_TARGET"

# --- Summary ---

echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
