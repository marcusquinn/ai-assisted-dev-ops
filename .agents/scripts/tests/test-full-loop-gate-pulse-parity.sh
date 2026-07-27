#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-gate-pulse-parity.sh — t2890 regression guard.
#
# Asserts that `_check_linked_issue_gate` in `.agents/scripts/full-loop-helper-state.sh`
# inherits the pulse-side structural dispatch gates via
# `_linked_issue_structural_blocker_reasons`, which calls `dispatch-dedup-helper.sh
# enumerate-blockers` and translates PARENT_TASK_BLOCKED and HOLD_FOR_REVIEW_BLOCKED
# into hard blocks. NO_AUTO_DISPATCH_BLOCKED remains a worker-dispatch hold, but an
# explicitly marked interactive implementation may proceed without removing it.
#
# Background: pre-t2890, the interactive `/full-loop` path only checked
# needs-maintainer-review + missing assignee. The pulse meanwhile honored
# parent-task and no-auto-dispatch via dispatch-dedup-helper.sh. A user typing
# /full-loop on a parent-task or hold-for-review issue would bypass those gates
# entirely, while issue-started interactive work was incorrectly blocked by a
# worker-only no-auto-dispatch hold. This test prevents either asymmetry.
#
# This is a static structural check — runtime behaviour is verified at install
# time via the smoke flow documented in todo/tasks/t2890-brief.md. CI is the
# authoritative runtime test (the gate is exercised whenever any worker runs
# /full-loop on a real issue).
#
# NOTE: not using `set -e` — assertions capture non-zero exits.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Resolve the helper file relative to the test (tests live in .agents/scripts/tests/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HELPER_FILE="${REPO_ROOT}/.agents/scripts/full-loop-helper-state.sh"

if [[ ! -f "$HELPER_FILE" ]]; then
	print_result "helper file exists" 1 "not found: $HELPER_FILE"
	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi
print_result "helper file exists" 0

# Extract just the _check_linked_issue_gate function body so per-check
# assertions only see the function we care about.
GATE_BODY=$(awk '/^_check_linked_issue_gate\(\) \{/,/^}/' "$HELPER_FILE")
TRUST_HELPER_BODY=$(awk '/^_linked_issue_trust_blocks_start\(\) \{/,/^}/' "$HELPER_FILE")
STRUCTURAL_HELPER_BODY=$(awk '/^_linked_issue_structural_blocker_reasons\(\) \{/,/^}/' "$HELPER_FILE")
AUTO_CLAIM_BODY=$(awk '/^_auto_claim_interactive\(\) \{/,/^}/' "$HELPER_FILE")

if [[ -z "$GATE_BODY" ]]; then
	print_result "extract _check_linked_issue_gate function body" 1 "function not found in $HELPER_FILE"
	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi
print_result "extract _check_linked_issue_gate function body" 0

if [[ -z "$TRUST_HELPER_BODY" ]]; then
	print_result "extract _linked_issue_trust_blocks_start function body" 1 "function not found in $HELPER_FILE"
	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi
print_result "extract _linked_issue_trust_blocks_start function body" 0

if [[ -z "$STRUCTURAL_HELPER_BODY" ]]; then
	print_result "extract _linked_issue_structural_blocker_reasons function body" 1 "function not found in $HELPER_FILE"
	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi
print_result "extract _linked_issue_structural_blocker_reasons function body" 0

if [[ -z "$AUTO_CLAIM_BODY" ]]; then
	print_result "extract _auto_claim_interactive function body" 1 "function not found in $HELPER_FILE"
	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	exit 1
fi
print_result "extract _auto_claim_interactive function body" 0

assert_in_gate() {
	local pattern="$1" label="$2"
	if printf '%s\n' "$GATE_BODY" | grep -qE -- "$pattern"; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found in _check_linked_issue_gate body"
	fi
	return 0
}

assert_in_structural_helper() {
	local pattern="$1" label="$2"
	if printf '%s\n' "$STRUCTURAL_HELPER_BODY" | grep -qE -- "$pattern"; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found in _linked_issue_structural_blocker_reasons body"
	fi
	return 0
}

assert_in_trust_helper() {
	local pattern="$1" label="$2"
	if printf '%s\n' "$TRUST_HELPER_BODY" | grep -qE -- "$pattern"; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found in _linked_issue_trust_blocks_start body"
	fi
	return 0
}

assert_in_auto_claim() {
	local pattern="$1" label="$2"
	if printf '%s\n' "$AUTO_CLAIM_BODY" | grep -qE -- "$pattern"; then
		print_result "$label" 0
	else
		print_result "$label" 1 "pattern '${pattern}' not found in _auto_claim_interactive body"
	fi
	return 0
}

# -------------------------------------------------------------------
# Assertion A: gate calls dispatch-dedup-helper.sh::enumerate-blockers (t2894)
# -------------------------------------------------------------------
assert_in_gate \
	'_linked_issue_structural_blocker_reasons' \
	"_check_linked_issue_gate calls structural blocker helper"
assert_in_structural_helper \
	'dispatch-dedup-helper\.sh' \
	"structural blocker helper references dispatch-dedup-helper.sh"
assert_in_structural_helper \
	'enumerate-blockers' \
	"structural blocker helper calls enumerate-blockers subcommand (t2894)"

# -------------------------------------------------------------------
# Assertion B: PARENT_TASK_BLOCKED case translates to a block
# -------------------------------------------------------------------
assert_in_structural_helper \
	'PARENT_TASK_BLOCKED' \
	"structural blocker helper matches PARENT_TASK_BLOCKED signal"
assert_in_structural_helper \
	'parent-task' \
	"structural blocker helper mentions parent-task label in user-facing message"

# -------------------------------------------------------------------
# Assertion C: NO_AUTO_DISPATCH_BLOCKED remains a worker hold but explicitly
# marked interactive implementation bypasses that one signal only.
# -------------------------------------------------------------------
assert_in_structural_helper \
	'NO_AUTO_DISPATCH_BLOCKED' \
	"structural blocker helper matches NO_AUTO_DISPATCH_BLOCKED signal"
assert_in_structural_helper \
	'no-auto-dispatch' \
	"structural blocker helper mentions no-auto-dispatch label in user-facing message"
assert_in_structural_helper \
	'AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION' \
	"structural blocker helper recognizes explicit interactive implementation"
assert_in_structural_helper \
	'! is_headless' \
	"structural blocker helper keeps no-auto-dispatch enforced for headless workers"

# The second claim performed by full-loop must preserve the same explicit
# implementation authority as interactive-start-helper.sh's first claim.
assert_in_auto_claim \
	'AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION' \
	"auto claim reads the interactive implementation marker"
assert_in_auto_claim \
	'--implementing' \
	"auto claim forwards --implementing for issue-started work"

# -------------------------------------------------------------------
# Assertion C2: HOLD_FOR_REVIEW_BLOCKED case translates to a block
# -------------------------------------------------------------------
assert_in_structural_helper \
	'HOLD_FOR_REVIEW_BLOCKED' \
	"structural blocker helper matches HOLD_FOR_REVIEW_BLOCKED signal"
assert_in_structural_helper \
	'hold-for-review' \
	"structural blocker helper mentions hold-for-review label in user-facing message"

# -------------------------------------------------------------------
# Assertion C3: trusted maintainer-only interactive NMR path exists
# -------------------------------------------------------------------
assert_in_gate \
	'_linked_issue_trust_blocks_start' \
	"_check_linked_issue_gate calls linked-issue trust helper"
assert_in_trust_helper \
	'_issue_thread_is_trusted_maintainer_only' \
	"linked-issue trust helper checks trusted maintainer-only NMR threads"
assert_in_trust_helper \
	'not a trusted maintainer-only interactive thread' \
	"linked-issue trust helper keeps NMR blocking untrusted or headless flows"
assert_in_trust_helper \
	'_linked_issue_author_allows_start' \
	"linked-issue trust helper verifies live author authority when NMR is absent"
assert_in_trust_helper \
	'cannot begin merely because the review label is absent' \
	"linked-issue trust helper blocks missing-label trust bypasses"

# -------------------------------------------------------------------
# Assertion D: fail-open pattern present (matches existing gh-api fail-open)
# -------------------------------------------------------------------
assert_in_structural_helper \
	'\|\| true' \
	"structural blocker helper uses fail-open pattern (|| true) on dedup call"

# -------------------------------------------------------------------
# Assertion E: gate sets blocked=true on hard-block signals
# -------------------------------------------------------------------
assert_in_gate \
	'blocked=true' \
	"_check_linked_issue_gate sets blocked=true on hard-block signals"

# -------------------------------------------------------------------
# Assertion F (GH#22854): missing assignee remains a headless-only block
# -------------------------------------------------------------------
assert_in_gate \
	'! is_headless' \
	"_check_linked_issue_gate exempts interactive sessions from missing-assignee block (GH#22854)"
assert_in_gate \
	'headless workers' \
	"_check_linked_issue_gate documents headless-only missing-assignee enforcement (GH#22854)"

# -------------------------------------------------------------------
# Assertion G (t2894): gate iterates over enumerate-blockers output
# with a loop so ALL blockers are reported (not just the first).
# -------------------------------------------------------------------
assert_in_structural_helper \
	'while.*read.*_blocker_line' \
	"structural blocker helper iterates enumerate-blockers output with a loop (t2894)"
assert_in_structural_helper \
	'done.*dedup_out' \
	"structural blocker helper loop reads from dedup_out heredoc string (t2894)"

# -------------------------------------------------------------------
# Assertion H: full-loop-helper-state.sh shellcheck-clean
# -------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck "$HELPER_FILE" >/dev/null 2>&1; then
		print_result "full-loop-helper-state.sh passes shellcheck" 0
	else
		print_result "full-loop-helper-state.sh passes shellcheck" 1 "shellcheck reported violations"
	fi
else
	# Linter binary unavailable in the runner — skip without failing.
	printf '%sSKIP%s shellcheck (binary not on PATH)\n' "$TEST_GREEN" "$TEST_RESET"
fi

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
