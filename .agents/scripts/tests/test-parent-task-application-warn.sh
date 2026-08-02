#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-parent-task-application-warn.sh — tests for t2442 Fix #2
#
# Regression tests for _parent_body_has_phase_markers() in
# issue-sync-lib-compose.sh and the warning wiring at the two creation call
# sites (issue-sync-helper.sh cmd_push, claim-task-id.sh create_github_issue
# bare-fallback path).
#
# The function is a pure string check: exit 0 if the body carries a
# decomposition marker the reconciler understands, exit 1 if the body has
# none (so the warning helper is called).
#
# Recognised markers:
#   - `## Children` / `## Child issues` / `## Sub-tasks` / `## Phase[s]` heading
#   - Narrow prose patterns from _extract_children_from_prose (Fix #3):
#     `Phase N #NNNN`, `filed as #NNNN`, `tracks #NNNN`, `blocked by #NNNN`
#
# NOT recognised (correctly — these should trigger a warning):
#   - Plain prose with no headings and no phase-ref patterns
#   - Body with `parent-task` label intent but no structure
#
# IMPORTANT (t2211 memory lesson): the wiring must WARN, never REMOVE the
# parent-task label. parent-task is the ONLY reliable dispatch block
# against auto_approve_maintainer_issues() stripping NMR and dispatching
# the parent.

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

assert_rc() {
	local label="$1" expected_rc="$2" actual_rc="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected_rc" == "$actual_rc" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected rc=$expected_rc, got rc=$actual_rc"
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
	# Use `--` separator so patterns starting with `-` (e.g. `--add-label`)
	# are not interpreted as grep options.
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

# --- Function under test (mirrored from issue-sync-lib-compose.sh) ---

_parent_body_has_phase_markers() {
	local body="$1"
	[[ -n "$body" ]] || return 1

	if printf '%s' "$body" | grep -qE '^##[[:space:]]+(Children|Child [Ii]ssues|Sub-?[Tt]asks|Phases?([[:space:]]+.*)?)[[:space:]]*$' 2>/dev/null; then
		return 0
	fi
	if printf '%s' "$body" | grep -qE '([Pp]hase[[:space:]]+[0-9]+[^#]*#[0-9]+|[Ff]iled[[:space:]]+as[[:space:]]*#[0-9]+|[Tt]racks[[:space:]]+#[0-9]+|[Bb]locked[[:space:]]-?[[:space:]]*by[[:space:]]*:?[[:space:]]*#[0-9]+)' 2>/dev/null; then
		return 0
	fi
	return 1
}

if ! declare -f _parent_body_has_phase_markers >/dev/null 2>&1; then
	echo "${TEST_RED}FATAL${TEST_NC}: _parent_body_has_phase_markers not available"
	exit 1
fi

echo "${TEST_BLUE}=== t2442 Fix #2: _parent_body_has_phase_markers tests ===${TEST_NC}"
echo ""

# ------- Positive cases (body is decomposition-ready → rc=0, no warning) -------

# 1. ## Children heading
BODY_1="## Description
Parent tracker.

## Children

- #100 — child A
- #101 — child B"
_parent_body_has_phase_markers "$BODY_1"
assert_rc "1: ## Children heading recognised" "0" "$?"

# 2. ## Sub-tasks heading
BODY_2="## Sub-tasks

- #200
- #201"
_parent_body_has_phase_markers "$BODY_2"
assert_rc "2: ## Sub-tasks heading recognised" "0" "$?"

# 3. ## Phase heading
BODY_3="## Phase 1
Do the audit.

## Phase 2
Implement fixes."
_parent_body_has_phase_markers "$BODY_3"
assert_rc "3: ## Phase heading recognised" "0" "$?"

# 4. ## Phases heading
BODY_4="## Phases

Phase 1: audit
Phase 2: implement"
_parent_body_has_phase_markers "$BODY_4"
assert_rc "4: ## Phases heading recognised" "0" "$?"

# 5. ## Child issues heading (capital I)
BODY_5="## Child Issues

- #400"
_parent_body_has_phase_markers "$BODY_5"
assert_rc "5: ## Child Issues (capital I) recognised" "0" "$?"

# 6. Prose 'Phase N #NNNN'
BODY_6="Decomposed into Phase 1 split out as #500."
_parent_body_has_phase_markers "$BODY_6"
assert_rc "6: 'Phase N ... #NNNN' prose recognised" "0" "$?"

# 7. Prose 'filed as #NNNN'
BODY_7="Phase 1 was filed as #600."
_parent_body_has_phase_markers "$BODY_7"
assert_rc "7: 'filed as #NNNN' prose recognised" "0" "$?"

# 8. Prose 'tracks #NNNN'
BODY_8="This epic tracks #700."
_parent_body_has_phase_markers "$BODY_8"
assert_rc "8: 'tracks #NNNN' prose recognised" "0" "$?"

# 9. Prose 'Blocked by: #NNNN'
BODY_9="Blocked by: #800"
_parent_body_has_phase_markers "$BODY_9"
assert_rc "9: 'Blocked by: #NNNN' prose recognised" "0" "$?"

# ------- Negative cases (body lacks markers → rc=1, warning posts) -------

# 10. Empty body
_parent_body_has_phase_markers ""
assert_rc "10: empty body → no markers" "1" "$?"

# 11. Plain prose with no headings or phase refs
BODY_11="This is a big epic. We'll break it down later. See #123 for context."
_parent_body_has_phase_markers "$BODY_11"
assert_rc "11: prose with bare #NNN context refs → no markers" "1" "$?"

# 12. Body with closing keywords only (closes/resolves/fixes) — these are
#     GH closing keywords, NOT decomposition markers
BODY_12="This resolves the concerns raised in #100 and closes #101."
_parent_body_has_phase_markers "$BODY_12"
assert_rc "12: closing keywords only → no markers" "1" "$?"

# 13. Body with ## headings that aren't decomposition markers (## Why, ## How, etc.)
BODY_13="## Why

Reasons.

## How

Steps."
_parent_body_has_phase_markers "$BODY_13"
assert_rc "13: unrelated ## headings → no markers" "1" "$?"

# --- Wiring assertions (both call sites post the warning) ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_LIB="$SCRIPT_DIR/issue-sync-lib-compose.sh"

# Helpers exist in the focused compose sub-library sourced by issue-sync-lib.sh.
assert_grep \
	"14: _parent_body_has_phase_markers defined in issue-sync-lib-compose.sh" \
	'^_parent_body_has_phase_markers\(\) \{' \
	"$COMPOSE_LIB"

assert_grep \
	"15: _post_parent_task_no_markers_warning defined in issue-sync-lib-compose.sh" \
	'^_post_parent_task_no_markers_warning\(\) \{' \
	"$COMPOSE_LIB"

# Marker constant is the canonical name
assert_grep_fixed \
	"16: warning helper uses canonical marker" \
	'<!-- parent-task:no-markers-warning -->' \
	"$COMPOSE_LIB"

# Call site 1: issue-sync-helper.sh cmd_push
assert_grep \
	"17: issue-sync-helper cmd_push calls _post_parent_task_no_markers_warning" \
	'_post_parent_task_no_markers_warning "\$repo" "\$_PUSH_CREATED_NUM"' \
	"$SCRIPT_DIR/issue-sync-helper.sh"

# Call site 2: claim-task-id.sh create_github_issue bare-fallback path
assert_grep \
	"18: claim-task-id create_github_issue calls _post_parent_task_no_markers_warning" \
	'_post_parent_task_no_markers_warning "\$_slug_for_warn" "\$issue_num"' \
	"$SCRIPT_DIR/claim-task-id.sh"

# CRITICAL: neither call site REMOVES the parent-task label (t2211 rule).
# The warning is advisory-only — removing the label would defeat
# dispatch-blocking.
TESTS_RUN=$((TESTS_RUN + 1))
if grep -qE 'remove-label.*parent-task|--remove-label[[:space:]]*parent-task' \
	"$SCRIPT_DIR/issue-sync-helper.sh" "$SCRIPT_DIR/claim-task-id.sh" 2>/dev/null; then
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 19: neither call site removes parent-task label (t2211)"
	echo "  found a --remove-label parent-task incantation — this would defeat dispatch-blocking"
else
	echo "${TEST_GREEN}PASS${TEST_NC}: 19: neither call site removes parent-task label (t2211)"
fi

# --- Summary ---
echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
