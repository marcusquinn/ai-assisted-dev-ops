#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-parent-decomposition-escalation.sh — tests for t2442 Fix #4
#
# Structural tests for the 7-day escalation path split across the parent and
# action reconciliation modules:
#   1. _compute_parent_nudge_age_hours helper exists and uses GNU+BSD date compat
#   2. _post_parent_decomposition_escalation helper exists with canonical marker
#   3. Escalation uses idempotency marker <!-- parent-needs-decomposition-escalated -->
#   4. Escalation remains advisory-only and does not apply needs-maintainer-review
#   5. Escalation comment lists 4 paths forward (decompose / drop / close / auto-decompose)
#   6. reconcile_completed_parent_tasks declares total_escalated + max_escalations counters
#   7. Reconcile reads PARENT_DECOMPOSITION_ESCALATION_HOURS env override (default 168h)
#   8. Reconcile gates escalation on nudge age >= threshold
#   9. Reconcile increments total_escalated on successful escalation
#  10. Final log line includes escalated= counter
#  11. Escalation is called AFTER nudge-age gate passes (not instead of nudge)
#
# Mirrors test-pulse-parent-nudge.sh (t2388) structurally.

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
	# Use `--` separator so patterns starting with `-` (e.g. `--add-label`,
	# `--remove-label`) are not interpreted as grep options.
	if grep -qF -- "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected literal: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

assert_not_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qF -- "$pattern" "$file" 2>/dev/null; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  unexpected literal: $pattern"
		echo "  in file:            $file"
	else
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARENT_TARGET="$SCRIPT_DIR/pulse-issue-reconcile-parent.sh"
ACTIONS_TARGET="$SCRIPT_DIR/pulse-issue-reconcile-actions.sh"

for target in "$PARENT_TARGET" "$ACTIONS_TARGET"; do
	if [[ ! -f "$target" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $target not found"
		exit 1
	fi
done

echo "${TEST_BLUE}=== t2442 Fix #4: parent-task escalation structural tests ===${TEST_NC}"
echo ""

# --- Helper presence ---

assert_grep \
	"1: _compute_parent_nudge_age_hours function defined" \
	'^_compute_parent_nudge_age_hours\(\) \{' \
	"$ACTIONS_TARGET"

assert_grep \
	"2: _post_parent_decomposition_escalation function defined" \
	'^_post_parent_decomposition_escalation\(\) \{' \
	"$PARENT_TARGET"

# --- Date compat ---

assert_grep \
	"3: nudge-age helper uses GNU/BSD date compat path" \
	'date --version >/dev/null 2>&1' \
	"$ACTIONS_TARGET"

assert_grep_fixed \
	"4: nudge-age helper uses BSD date fallback" \
	'date -j -u -f "%Y-%m-%dT%H:%M:%SZ"' \
	"$ACTIONS_TARGET"

# --- Marker wiring ---

assert_grep_fixed \
	"5: escalation helper uses canonical marker" \
	'<!-- parent-needs-decomposition-escalated -->' \
	"$PARENT_TARGET"

# --- Advisory-only escalation ---

assert_not_grep_fixed \
	"6a: escalation does not apply needs-maintainer-review label" \
	'--add-label "needs-maintainer-review"' \
	"$PARENT_TARGET"

assert_grep_fixed \
	"6b: escalation explicitly describes advisory-only behaviour" \
	'This escalation is advisory only; it does not add another dispatch-blocking label.' \
	"$PARENT_TARGET"

# --- Comment body — 4 paths forward ---

assert_grep_fixed \
	"7a: escalation comment lists path 1 (decompose into children)" \
	'Decompose into children' \
	"$PARENT_TARGET"

assert_grep_fixed \
	"7b: escalation comment lists path 2 (drop parent-task label)" \
	'Drop the parent-task label' \
	"$PARENT_TARGET"

assert_grep_fixed \
	"7c: escalation comment lists path 3 (close)" \
	'Close the issue' \
	"$PARENT_TARGET"

assert_grep_fixed \
	"7d: escalation comment lists path 4 (auto-decomposer)" \
	'auto-decomposer' \
	"$PARENT_TARGET"

# --- Reconcile counter + gate wiring ---

assert_grep \
	"8: reconcile declares total_escalated=0 counter" \
	'local total_escalated=0' \
	"$PARENT_TARGET"

assert_grep \
	"9: reconcile declares max_escalations cap" \
	'local max_escalations=[0-9]+' \
	"$PARENT_TARGET"

assert_grep \
	"10: reconcile reads PARENT_DECOMPOSITION_ESCALATION_HOURS env (default 168)" \
	'PARENT_DECOMPOSITION_ESCALATION_HOURS:-168' \
	"$PARENT_TARGET"

assert_grep \
	"11: reconcile gates escalation on nudge age via _compute_parent_nudge_age_hours" \
	'_compute_parent_nudge_age_hours "\$slug" "\$issue_num"' \
	"$ACTIONS_TARGET"

assert_grep \
	"12: reconcile calls _post_parent_decomposition_escalation with slug+num+title" \
	'_post_parent_decomposition_escalation "\$slug" "\$issue_num" "\$issue_title"' \
	"$ACTIONS_TARGET"

assert_grep \
	"13: reconcile increments total_escalated on success" \
	'total_escalated=\$\(\(total_escalated \+ 1\)\)' \
	"$PARENT_TARGET"

assert_grep \
	"14: final log line includes escalated= counter" \
	'escalated=\$\{total_escalated\}' \
	"$PARENT_TARGET"

# --- Idempotency check present ---

assert_grep_fixed \
	"15: escalation helper queries existing comments for idempotency" \
	'repos/${slug}/issues/${parent_num}/comments' \
	"$PARENT_TARGET"

# --- t2211 constraint: escalation preserves parent-task label ---
# Escalation applies NMR but must NEVER execute a `gh issue edit
# --remove-label parent-task` on the escalated issue — that would
# defeat the dispatch block. The ONLY time `--remove-label parent-task`
# may appear is inside the comment body's markdown code fence as an
# instruction to the maintainer ("Path 2 — drop the parent-task label"),
# which is the correct user-facing remediation.
#
# Strategy: extract the escalation function body, then use the
# quoted-variable distinction to tell executable code from markdown:
#   - Executable bash uses QUOTED var refs: `gh issue edit "$parent_num"`
#   - Markdown code-fence content uses UNQUOTED: `gh issue edit ${parent_num}`
# If we see `gh issue edit "<quoted var>"[ ...] --remove-label parent-task`
# anywhere in the function body, that IS executable and forbidden.

TESTS_RUN=$((TESTS_RUN + 1))
esc_body=$(awk '/^_post_parent_decomposition_escalation\(\) \{/,/^\}$/' "$PARENT_TARGET")
# Match executable `gh issue edit "$VAR"` form followed anywhere on the
# same line by `--remove-label parent-task`. The quoted var ref is the
# executable tell.
if printf '%s' "$esc_body" | grep -qE 'gh issue edit "\$[a-zA-Z_]+".*--remove-label[[:space:]]+parent-task' 2>/dev/null; then
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 16: escalation does NOT execute --remove-label parent-task (t2211)"
	echo "  escalation would strip the only reliable dispatch block — forbidden"
	echo "  offending lines:"
	printf '%s' "$esc_body" | grep -E 'gh issue edit "\$[a-zA-Z_]+".*--remove-label[[:space:]]+parent-task' | sed 's/^/    /'
else
	echo "${TEST_GREEN}PASS${TEST_NC}: 16: escalation does NOT execute --remove-label parent-task (t2211)"
fi

# Complementary positive check: the comment body DOES include the
# remediation instruction so the maintainer knows how to drop the label
# manually (path 2 of 4).
assert_grep_fixed \
	"17: escalation comment includes 'remove-label parent-task' as user instruction" \
	'--remove-label parent-task' \
	"$PARENT_TARGET"

# --- Summary ---
echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
