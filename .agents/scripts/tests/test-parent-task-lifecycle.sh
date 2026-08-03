#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex/grep patterns are literal by design
#
# test-parent-task-lifecycle.sh — tests for t2786 (GH#20703)
#
# Regression tests for the declared-vs-filed guard added to
# _try_close_parent_tracker in pulse-issue-reconcile.sh (Phase 2 of #20559).
#
# The guard prevents premature parent close when a parent body declares more
# phases in a ## Phases section than have been filed as child issues.
#
# Test strategy:
#   Part A — unit tests for _parse_phases_section (pure string processing).
#             Inline the function definition; no gh stubs required.
#   Part B — structural tests (grep) verifying the guard wiring in
#             _try_close_parent_tracker and _post_parent_phases_unfiled_nudge.
#             These check code structure rather than executing the function
#             (which would require full gh API stubs).
#
# Test coverage:
#   A1. Body with ## Phases + 3 declared phases → section extracted, count=3
#   A2. Body with no ## Phases heading → empty result (backward compat)
#   A3. Body with ## Phases where all phases have #NNN refs (all filed)
#   A4. Body with ## Phases where some phases have #NNN refs (mixed)
#   A5. ## Phases at end of file (no trailing ## heading) → still extracted
#   A6. Empty body → empty result
#   B1. _parse_phases_section function defined in source file
#   B2. _post_parent_phases_unfiled_nudge function defined in source file
#   B3. Guard uses the canonical marker <!-- parent-declared-phases-unfiled -->
#   B4. Guard queries existing comments for idempotency
#   B5. Guard posts via gh_issue_comment wrapper
#   B6. _try_close_parent_tracker accepts parent_body as 5th parameter
#   B7. Close contract blocks declared/unfiled work while preserving legacy
#       complete single-child closure
#   B8. _action_cpt_single passes issue_body to _try_close_parent_tracker
#   B9. _action_cpt_single bootstraps phase-only parents before advisory nudges

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

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: $(printf '%q' "$expected")"
		echo "  actual:   $(printf '%q' "$actual")"
	fi
	return 0
}

assert_empty() {
	local label="$1" actual="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -z "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: (empty)"
		echo "  actual:   $(printf '%q' "$actual")"
	fi
	return 0
}

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to contain: $needle"
		echo "  actual: $(printf '%q' "$haystack")"
	fi
	return 0
}

assert_not_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected NOT to contain: $needle"
		echo "  actual: $(printf '%q' "$haystack")"
	fi
	return 0
}

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

# --- Inline function under test (pure string processing — no gh required) ---
# Mirrors the definition in pulse-issue-reconcile.sh.
_parse_phases_section() {
	local body="$1"
	printf '%s' "$body" | awk '
		BEGIN { in_section = 0 }
		/^##[[:space:]]+Phases[[:space:]]*$/ {
			in_section = 1; next
		}
		in_section && /^##[[:space:]]/ { exit }
		in_section { print }
	'
	return 0
}

# --- Locate source file for structural tests ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$SCRIPT_DIR/pulse-issue-reconcile.sh"
ACTIONS_TARGET="$SCRIPT_DIR/pulse-issue-reconcile-actions.sh"
PARENT_TARGET="$SCRIPT_DIR/pulse-issue-reconcile-parent.sh"
WRAPPER_TARGET="$SCRIPT_DIR/shared-gh-wrappers-create.sh"

if [[ ! -f "$TARGET" || ! -f "$ACTIONS_TARGET" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: reconcile source files not found"
	exit 1
fi

# ============================================================
echo "${TEST_BLUE}=== Part A: _parse_phases_section unit tests ===${TEST_NC}"
echo ""

# --- A1: Body with ## Phases + 3 declared phases ---
BODY_A1="## What

This parent tracks the decomposition of #20559.

## Phases

Phase 1: audit (this issue)
Phase 2: implement guard — filed as #20685
Phase 3: add tests — filed as #20703

## Acceptance

All phases merged."

result=$(_parse_phases_section "$BODY_A1")
count=$(printf '%s' "$result" | grep -cE '(^|[[:space:]])Phase[[:space:]]+[0-9]+' 2>/dev/null || true)
[[ "$count" =~ ^[0-9]+$ ]] || count=0
assert_eq "A1a: 3 declared phases detected" "3" "$count"
assert_contains "A1b: Phase 1 line present in section" "Phase 1" "$result"
assert_contains "A1c: Phase 3 line present in section" "Phase 3" "$result"
assert_not_contains "A1d: ## What heading NOT in section" "## What" "$result"

# --- A2: Body with no ## Phases heading ---
BODY_A2="## What

This parent has children but no Phases heading.

## Children

- #100 — child one
- #101 — child two

## Acceptance

Done."

result=$(_parse_phases_section "$BODY_A2")
assert_empty "A2: no ## Phases heading → empty result (backward compat)" "$result"

# --- A3: Body with ## Phases where ALL phases have #NNN refs (all filed) ---
BODY_A3="## Phases

- Phase 1: Description — filed as #19996
- Phase 2: Description — filed as #20001
- Phase 3: Description — filed as #20685

## Children

- #19996 — phase 1 issue
- #20001 — phase 2 issue
- #20685 — phase 3 issue"

result=$(_parse_phases_section "$BODY_A3")
# All 3 phases have #NNN refs
filed=$(printf '%s' "$result" | grep -E '(^|[[:space:]])Phase[[:space:]]+[0-9]+' | grep -cE '#[0-9]+' 2>/dev/null || true)
[[ "$filed" =~ ^[0-9]+$ ]] || filed=0
assert_eq "A3a: all 3 phases have #NNN refs (filed)" "3" "$filed"
# None unfiled
unfiled=$(printf '%s' "$result" | grep -E '(^|[[:space:]])Phase[[:space:]]+[0-9]+' | grep -cvE '#[0-9]+' 2>/dev/null || true)
[[ "$unfiled" =~ ^[0-9]+$ ]] || unfiled=0
assert_eq "A3b: zero unfiled phases" "0" "$unfiled"

# --- A4: Body with ## Phases where some phases have #NNN (mixed) ---
BODY_A4="## Phases

Phase 1: split out as #19996
Phase 2: filed as #20001
Phase 3: not yet started
Phase 4: planning in progress

## Notes

See parent #20559 for background."

result=$(_parse_phases_section "$BODY_A4")
total=$(printf '%s' "$result" | grep -cE '(^|[[:space:]])Phase[[:space:]]+[0-9]+' 2>/dev/null || true)
[[ "$total" =~ ^[0-9]+$ ]] || total=0
assert_eq "A4a: 4 declared phases total" "4" "$total"
filed=$(printf '%s' "$result" | grep -E '(^|[[:space:]])Phase[[:space:]]+[0-9]+' | grep -cE '#[0-9]+' 2>/dev/null || true)
[[ "$filed" =~ ^[0-9]+$ ]] || filed=0
assert_eq "A4b: 2 filed phases (with #NNN refs)" "2" "$filed"
unfiled_text=$(printf '%s' "$result" | grep -E '(^|[[:space:]])Phase[[:space:]]+[0-9]+' | grep -vE '#[0-9]+' || true)
assert_contains "A4c: unfiled list includes Phase 3" "Phase 3" "$unfiled_text"
assert_contains "A4d: unfiled list includes Phase 4" "Phase 4" "$unfiled_text"
assert_not_contains "A4e: ## Notes NOT in phases section" "## Notes" "$result"

# --- A5: ## Phases at end of file (no trailing ## heading) ---
BODY_A5="## What

Some description.

## Phases

Phase 1: alpha — #10001
Phase 2: beta"

result=$(_parse_phases_section "$BODY_A5")
count=$(printf '%s' "$result" | grep -cE '(^|[[:space:]])Phase[[:space:]]+[0-9]+' 2>/dev/null || true)
[[ "$count" =~ ^[0-9]+$ ]] || count=0
assert_eq "A5: ## Phases at EOF extracts both phases" "2" "$count"

# --- A6: Empty body ---
result=$(_parse_phases_section "")
assert_empty "A6: empty body → empty result" "$result"

# ============================================================
echo ""
echo "${TEST_BLUE}=== Part B: structural wiring tests ===${TEST_NC}"
echo ""

# B1: GH#20871 — _parse_phases_section is now canonically defined in
# shared-phase-filing.sh (structured row parser). pulse-issue-reconcile.sh
# previously defined its own raw-section extractor under the same name; the
# duplicate over-counted by including ### subsections, defeating the t2786
# declared-vs-filed close guard. Verify (a) the local override is gone, and
# (b) the shared parser is sourced as a dependency so the test harness sees
# the canonical version.
SHARED_TARGET="$SCRIPT_DIR/shared-phase-filing.sh"

# B1a: local _parse_phases_section override is REMOVED from reconcile module
TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '^_parse_phases_section\(\) \{' "$TARGET" 2>/dev/null; then
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: B1a: local _parse_phases_section override should be removed from $TARGET"
else
	echo "${TEST_GREEN}PASS${TEST_NC}: B1a: local _parse_phases_section override removed from reconcile module"
fi

# B1b: canonical _parse_phases_section is defined in shared-phase-filing.sh
assert_grep \
	"B1b: _parse_phases_section canonically defined in shared-phase-filing.sh" \
	'^_parse_phases_section\(\) \{' \
	"$SHARED_TARGET"

# B1c: reconcile module sources shared-phase-filing.sh as an explicit dep
assert_grep_fixed \
	"B1c: reconcile module sources shared-phase-filing.sh dependency" \
	'shared-phase-filing.sh' \
	"$TARGET"

# B2: _post_parent_phases_unfiled_nudge defined
assert_grep \
	"B2: _post_parent_phases_unfiled_nudge function defined in source" \
	'^_post_parent_phases_unfiled_nudge\(\) \{' \
	"$ACTIONS_TARGET"

# B3: canonical marker present
assert_grep_fixed \
	"B3: canonical marker <!-- parent-declared-phases-unfiled --> present" \
	'<!-- parent-declared-phases-unfiled -->' \
	"$ACTIONS_TARGET"

# B4: idempotency check via gh api --paginate
assert_grep \
	"B4: nudge function queries comments via gh api --paginate for idempotency" \
	'gh api --paginate "repos/\$\{slug\}/issues/\$\{parent_num\}/comments"' \
	"$ACTIONS_TARGET"

# B5: nudge posts via gh_issue_comment wrapper
assert_grep \
	"B5: nudge posts via gh_issue_comment wrapper" \
	'gh_issue_comment "\$parent_num" --repo "\$slug"' \
	"$ACTIONS_TARGET"

# B6: _try_close_parent_tracker accepts 5th param parent_body
assert_grep_fixed \
	"B6: _try_close_parent_tracker signature includes parent_body 5th param" \
	'local slug="$1" parent_num="$2" child_nums="$3" child_source="$4" parent_body="${5:-}"' \
	"$ACTIONS_TARGET"

# B7: deterministic close contract separates "known children terminal" from
# "parent objective complete". Legacy parents without deterministic blockers
# remain compatible, including genuine single-child trackers.
assert_grep_fixed \
	'B7a: close-contract predicate exists' \
	'_parent_close_contract_incomplete() {' \
	"$ACTIONS_TARGET"
assert_grep_fixed \
	'B7b: close path checks the contract after child terminality' \
	'if _parent_close_contract_incomplete "$parent_body" "$child_count"; then' \
	"$ACTIONS_TARGET"
assert_grep_fixed \
	'B7c: incomplete canonical phases post the idempotent phase nudge' \
	'_post_parent_phases_unfiled_nudge "$slug" "$parent_num"' \
	"$ACTIONS_TARGET"
# B7d-vacuous: close path requires child_count > 0
# alongside all_closed. Pre-fix, a parent referencing only PRs/external
# refs would skip the per-child loop, leave child_count=0, all_closed
# defaulting to "true", and produce "All 0 declared child task(s) are
# resolved." Verify the guard is in place.
assert_grep_fixed \
	'B7d: close gate requires child_count > 0 (no vacuous-truth close)' \
	'[[ "$all_closed" == "true" && "$child_count" -gt 0 ]] || return 1' \
	"$ACTIONS_TARGET"
# B7e: the `child_count >= 2` short-circuit MUST remain removed.
# Single-filed-child parents are legitimate (incremental phase rollout);
# the prior `[[ "$child_count" -ge 2 ]] || return 1` blocked them from
# both closing AND from receiving the declared-vs-filed nudge, causing
# silent rot. Verify the source no longer carries the literal guard.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE '\[\[[[:space:]]+"\$child_count"[[:space:]]+-ge[[:space:]]+2[[:space:]]+\]\][[:space:]]+\|\|[[:space:]]+return[[:space:]]+1' "$ACTIONS_TARGET" 2>/dev/null; then
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: B7e: child_count >= 2 short-circuit must be removed from $ACTIONS_TARGET"
else
	echo "${TEST_GREEN}PASS${TEST_NC}: B7e: child_count >= 2 short-circuit removed (complete single-child parents can close)"
fi

assert_grep_fixed \
	'B7f: closing-comment heading reflects declared child completion' \
	'## All declared child tasks completed' \
	"$ACTIONS_TARGET"
assert_grep_fixed \
	'B7g: unchecked parent criteria are deterministic close blockers' \
	'_PARENT_CLOSE_CONTRACT_REASON="unchecked-criteria"' \
	"$ACTIONS_TARGET"
assert_grep_fixed \
	'B7h: incomplete parent close contracts use an explicit review hold' \
	'_mark_parent_review_hold "$slug" "$parent_num"' \
	"$ACTIONS_TARGET"
assert_grep_fixed \
	'B7i: parent review hold applies hold-for-review' \
	'--add-label "hold-for-review"' \
	"$ACTIONS_TARGET"

# B8: call site passes issue_body as 5th arg
assert_grep_fixed \
	"B8: _action_cpt_single passes issue_body to _try_close_parent_tracker" \
	'_try_close_parent_tracker "$slug" "$issue_num" "$child_nums" "$child_source" "$issue_body"' \
	"$ACTIONS_TARGET"

# B9: phase-only parent bootstrap runs before advisory-only nudge/escalation
assert_grep_fixed \
	"B9a: _action_cpt_single calls phase-only bootstrap helper" \
	'auto_file_next_unfiled_parent_phase "$issue_num" "$slug"' \
	"$ACTIONS_TARGET"
assert_grep_fixed \
	"B9b: shared phase bootstrap helper is defined" \
	'auto_file_next_unfiled_parent_phase() {' \
	"$SHARED_TARGET"

# B10: parent actions remain behind cached and live maintainer hold barriers.
assert_grep_fixed \
	"B10a: live parent mutation gate is defined" \
	'_pir_parent_mutation_is_allowed() {' \
	"$ACTIONS_TARGET"
assert_grep_fixed \
	"B10b: single-pass parent action forwards current labels" \
	'"$cpt_esc_hours" "OPEN" "$labels_csv"' \
	"$TARGET"
assert_grep_fixed \
	"B10c: legacy parent pass forwards current state and labels" \
	'"$escalation_threshold_hours" "$issue_state" "$issue_labels"' \
	"$PARENT_TARGET"
TESTS_RUN=$((TESTS_RUN + 1))
hold_guard_count=$(grep -Fc '_pir_parent_mutation_is_allowed "$slug" "$issue_num"' "$ACTIONS_TARGET" 2>/dev/null || true)
if [[ "$hold_guard_count" -ge 6 ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: B10d: every parent mutation class has a live hold recheck"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: B10d: expected at least 6 live parent hold checks, found $hold_guard_count"
fi

# B11: parent creation stamps a machine-readable contract before signing.
assert_grep_fixed \
	"B11a: parent creation contract helper is defined" \
	'_gh_ci_prepare_parent_close_contract() {' \
	"$WRAPPER_TARGET"
assert_grep_fixed \
	"B11b: phase-plan contract marker is generated" \
	'<!-- parent-close-contract: phase-plan -->' \
	"$WRAPPER_TARGET"
assert_grep_fixed \
	"B11c: child-count contract marker is generated" \
	'<!-- parent-close-contract: expected-children=${children_count} -->' \
	"$WRAPPER_TARGET"
assert_grep_fixed \
	"B11d: undecomposed parents receive a fail-closed marker" \
	'<!-- parent-close-contract: needs-decomposition -->' \
	"$WRAPPER_TARGET"

# Exercise inline-body mutation directly. Sourcing defines the helper without
# invoking any GitHub operations; body-file cleanup is covered by wrapper tests.
# shellcheck source=/dev/null
source "$WRAPPER_TARGET"
_gh_ci_prepare_parent_close_contract 1 --body $'## Phases\n\n- Phase 1 - deliver #101' --label parent-task
contract_args=$(printf '%s\n' "${_GH_CI_CONTRACT_ARGS[@]}")
assert_contains "B11e: canonical phase body receives phase-plan contract" \
	'<!-- parent-close-contract: phase-plan -->' "$contract_args"

_gh_ci_prepare_parent_close_contract 1 --body $'## Children\n\n- #101\n- #102' --label parent-task
contract_args=$(printf '%s\n' "${_GH_CI_CONTRACT_ARGS[@]}")
assert_contains "B11f: children body records expected child count" \
	'<!-- parent-close-contract: expected-children=2 -->' "$contract_args"

_gh_ci_prepare_parent_close_contract 0 --body 'ordinary leaf issue' --label bug
contract_args=$(printf '%s\n' "${_GH_CI_CONTRACT_ARGS[@]}")
assert_not_contains "B11g: non-parent issue body remains unstamped" \
	'<!-- parent-close-contract:' "$contract_args"

_gh_ci_prepare_parent_close_contract 1 --body $'## Children\n\nNo children filed yet.' --label parent-task
contract_args=$(printf '%s\n' "${_GH_CI_CONTRACT_ARGS[@]}")
assert_contains "B11h: empty children section remains safe under pipefail" \
	'<!-- parent-close-contract: needs-decomposition -->' "$contract_args"

assert_grep_fixed \
	"B11i: close-contract nudge marker varies with the blocking reason" \
	'<!-- parent-close-contract-incomplete:${_PARENT_CLOSE_CONTRACT_REASON} -->' \
	"$ACTIONS_TARGET"

# ============================================================
echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
