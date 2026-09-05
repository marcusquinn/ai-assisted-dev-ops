#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-large-file-gate-body.sh — t2371 regression guard.
#
# Verifies that scanner-filed issue bodies contain the four enhancements
# required by t2371:
#
#   1. Link to `.agents/reference/large-file-split.md` (the split playbook)
#   2. Citation of `issue-sync-helper.sh` + `issue-sync-lib.sh` as in-repo precedent
#   3. Pre-declaration of `complexity-bump-ok` / `ratchet-bump` label + `Complexity Bump Justification` section
#   4. The `<!-- aidevops:generator=... -->` marker for pre-dispatch validators
#
# Tests all five scanner body templates:
#   Part 1: `pulse-dispatch-large-file-gate.sh` (file-size-debt bodies)
#   Part 2: `stats-quality-sweep-issues.sh` (_build_simplification_issue_body)
#   Part 3: `pulse-simplification-issues.sh` SH body (_complexity_scan_sh_build_issue_body_with_sig)
#   Part 4: `pulse-simplification-issues.sh` MD body (_complexity_scan_build_md_issue_body)
#   Part 5: `pulse-simplification-state.sh` requeue body (_create_requeue_issue)
#
# Cross-references: GH#19828 / t2371, GH#19699 (the too-thin body),
# t2368 (large-file-split.md playbook), t2367 (generator marker).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
GATE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-dispatch-large-file-gate.sh"
SWEEP_SCRIPT="${SCRIPT_DIR_TEST}/../stats-quality-sweep-issues.sh"
SIMPLIFICATION_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-simplification-issues.sh"
REQUEUE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-simplification-state.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_contains() {
	local test_name="$1"
	local haystack="$2"
	local needle="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	printf '       missing: %s\n' "$needle"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

######################################################################
# Part 1: Large-file gate body (pulse-dispatch-large-file-gate.sh)
#
# The body is constructed inline in _large_file_gate_file_new_debt_issue
# as _create_body. We can't call the function without gh, so we test by
# extracting the body template from source — the template uses shell
# variable interpolation, so we verify the static strings that must appear
# regardless of variable values.
######################################################################

printf '\n=== test-large-file-gate-body.sh (t2371) ===\n\n'
printf '%s\n\n' '--- Part 1: Large-file gate (file-size-debt) body ---'

# Read the gate script body template (the _create_body assignment)
gate_body_section=$(sed -n '/_create_body="/,/^_Created by large-file/p' "$GATE_SCRIPT")

# Test 1.1: Generator marker
assert_contains \
	"large-file: generator marker present" \
	"$gate_body_section" \
	"aidevops:generator=large-file-simplification-gate"

# Test 1.2: Playbook link
assert_contains \
	"large-file: playbook reference" \
	"$gate_body_section" \
	"large-file-split.md"

# Test 1.3: Precedent citation
assert_contains \
	"large-file: issue-sync-helper.sh precedent" \
	"$gate_body_section" \
	"issue-sync-helper.sh"

# Test 1.4: Precedent citation (lib)
assert_contains \
	"large-file: issue-sync-lib.sh precedent" \
	"$gate_body_section" \
	"issue-sync-lib.sh"

# Test 1.5: CI override label
assert_contains \
	"large-file: complexity-bump-ok label mention" \
	"$gate_body_section" \
	"complexity-bump-ok"

# Test 1.6: Justification section requirement
assert_contains \
	"large-file: Complexity Bump Justification section mention" \
	"$gate_body_section" \
	"Complexity Bump Justification"

# Test 1.7: Playbook section reference (Known CI False-Positive Classes)
assert_contains \
	"large-file: playbook section 4 reference" \
	"$gate_body_section" \
	"Known CI False-Positive Classes"

# Test 1.8: headless-runtime-lib.sh complex precedent
assert_contains \
	"large-file: headless-runtime-lib.sh complex precedent" \
	"$gate_body_section" \
	"headless-runtime-lib.sh"

######################################################################
# Part 2: Function-complexity sweep body (stats-quality-sweep.sh)
#
# _build_simplification_issue_body is a pure function that writes to
# stdout. We can source the script and call it directly.
# However, the script sources many pulse dependencies. Instead, we
# extract the function body from the heredoc and test the static
# template strings.
######################################################################

printf '\n%s\n\n' '--- Part 2: Function-complexity sweep body ---'

# Extract the heredoc body from _build_simplification_issue_body
sweep_body_section=$(sed -n '/_build_simplification_issue_body()/,/^BODY$/p' "$SWEEP_SCRIPT")

# Test 2.1: Generator marker
assert_contains \
	"complexity-sweep: generator marker present" \
	"$sweep_body_section" \
	"aidevops:generator=function-complexity-sweep"

# Test 2.2: Playbook link
assert_contains \
	"complexity-sweep: playbook reference" \
	"$sweep_body_section" \
	"large-file-split.md"

# Test 2.3: Precedent citation
assert_contains \
	"complexity-sweep: issue-sync-helper.sh precedent" \
	"$sweep_body_section" \
	"issue-sync-helper.sh"

# Test 2.4: Precedent citation (lib)
assert_contains \
	"complexity-sweep: issue-sync-lib.sh precedent" \
	"$sweep_body_section" \
	"issue-sync-lib.sh"

# Test 2.5: CI override label (ratchet-bump for complexity sweep)
assert_contains \
	"complexity-sweep: ratchet-bump label mention" \
	"$sweep_body_section" \
	"ratchet-bump"

# Test 2.6: Justification section requirement
assert_contains \
	"complexity-sweep: Complexity Bump Justification section mention" \
	"$sweep_body_section" \
	"Complexity Bump Justification"

# Test 2.7: Playbook section reference
assert_contains \
	"complexity-sweep: playbook section 4 reference" \
	"$sweep_body_section" \
	"Known CI False-Positive Classes"

# Test 2.8: headless-runtime-lib.sh complex precedent
assert_contains \
	"complexity-sweep: headless-runtime-lib.sh complex precedent" \
	"$sweep_body_section" \
	"headless-runtime-lib.sh"

# Test 2.9: autonomous brief declares the exact editable path
assert_contains \
	"complexity-sweep: canonical Files Scope heading" \
	"$sweep_body_section" \
	"### Files Scope"
# shellcheck disable=SC2016 # literal generator template expression
assert_contains \
	"complexity-sweep: cited file is editable" \
	"$sweep_body_section" \
	'- EDIT: \`${file_path}\`'

######################################################################
# Part 3: SH complexity scanner body (pulse-simplification.sh)
#
# _complexity_scan_sh_build_issue_body_with_sig builds the body as a
# local variable. Extract the function body from source.
######################################################################

printf '\n%s\n\n' '--- Part 3: SH function-complexity body ---'

sh_body_section=$(sed -n '/_complexity_scan_sh_build_issue_body_with_sig()/,/^}$/p' "$SIMPLIFICATION_SCRIPT")

# Test 3.1: Generator marker
assert_contains \
	"sh-complexity: generator marker present" \
	"$sh_body_section" \
	"aidevops:generator=function-complexity-gate"

# Test 3.2: Playbook link
assert_contains \
	"sh-complexity: playbook reference" \
	"$sh_body_section" \
	"large-file-split.md"

# Test 3.3: Precedent citation
assert_contains \
	"sh-complexity: issue-sync-helper.sh precedent" \
	"$sh_body_section" \
	"issue-sync-helper.sh"

# Test 3.4: CI override label
assert_contains \
	"sh-complexity: complexity-bump-ok label mention" \
	"$sh_body_section" \
	"complexity-bump-ok"

# Test 3.5: Justification section
assert_contains \
	"sh-complexity: Complexity Bump Justification section mention" \
	"$sh_body_section" \
	"Complexity Bump Justification"

# Test 3.6: generated shell brief has an editable canonical scope
assert_contains \
	"sh-complexity: canonical Files Scope heading" \
	"$sh_body_section" \
	"### Files Scope"
# shellcheck disable=SC2016 # literal generator template expression
assert_contains \
	"sh-complexity: cited file is editable" \
	"$sh_body_section" \
	'- EDIT: \`${file_path}\`'

######################################################################
# Part 4: MD agent doc body (pulse-simplification.sh)
#
# _complexity_scan_build_md_issue_body outputs via heredoc.
######################################################################

printf '\n%s\n\n' '--- Part 4: MD agent doc body ---'

md_body_section=$(sed -n '/_complexity_scan_build_md_issue_body()/,/^}$/p' "$SIMPLIFICATION_SCRIPT")

# Test 4.1: Generator marker
assert_contains \
	"md-simplification: generator marker present" \
	"$md_body_section" \
	"aidevops:generator=agent-doc-simplification-gate"

# Test 4.2: Playbook link
assert_contains \
	"md-simplification: playbook reference" \
	"$md_body_section" \
	"large-file-split.md"

# Test 4.3: Precedent citation
assert_contains \
	"md-simplification: issue-sync-helper.sh precedent" \
	"$md_body_section" \
	"issue-sync-helper.sh"

# Test 4.4: CI override label
assert_contains \
	"md-simplification: complexity-bump-ok label mention" \
	"$md_body_section" \
	"complexity-bump-ok"

# Test 4.5: generated Markdown brief has an editable canonical scope
assert_contains \
	"md-simplification: canonical Files Scope heading" \
	"$md_body_section" \
	"### Files Scope"
# shellcheck disable=SC2016 # literal generator template expression
assert_contains \
	"md-simplification: cited file is editable" \
	"$md_body_section" \
	'- EDIT: \`${file_path}\`'

######################################################################
# Part 5: Requeue body (pulse-simplification-state.sh)
#
# _create_requeue_issue calls gh_create_issue. Extract from source.
######################################################################

printf '\n%s\n\n' '--- Part 5: Requeue body ---'

requeue_body_section=$(sed -n '/_create_requeue_issue()/,/^}$/p' "$REQUEUE_SCRIPT")

# Test 5.1: Generator marker
assert_contains \
	"requeue: generator marker present" \
	"$requeue_body_section" \
	"aidevops:generator=function-complexity-gate"

# Test 5.2: Playbook link
assert_contains \
	"requeue: playbook reference" \
	"$requeue_body_section" \
	"large-file-split.md"

# Test 5.3: Precedent citation
assert_contains \
	"requeue: issue-sync-helper.sh precedent" \
	"$requeue_body_section" \
	"issue-sync-helper.sh"

# Test 5.4: CI override label
assert_contains \
	"requeue: complexity-bump-ok label mention" \
	"$requeue_body_section" \
	"complexity-bump-ok"

######################################################################
# Summary
######################################################################

printf '\n=== Results: %d/%d passed ===\n\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '%sFAILED%s — %d test(s) failed\n' "$TEST_RED" "$TEST_NC" "$TESTS_FAILED"
	exit 1
fi

printf '%sALL PASSED%s\n' "$TEST_GREEN" "$TEST_NC"
exit 0
