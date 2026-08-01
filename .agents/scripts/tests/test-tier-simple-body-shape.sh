#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC1090  # dynamic source of helper under test is intentional
# shellcheck disable=SC2016  # single-quoted fixture bodies are heredoc-like literals
#
# test-tier-simple-body-shape.sh — fixture tests for t2389 (GH#19929)
#
# Exercises the explicit checklist and execution-contract checks in
# tier-simple-body-shape-helper.sh with positive and negative fixtures.
#
# Strategy: source the helper's check functions into a subshell (the
# helper has a `if [[ BASH_SOURCE == $0 ]]; then main; fi` guard so
# sourcing doesn't execute main), then call each _check_* function
# directly with fixture body strings. No gh/jq stubs needed — these
# functions are pure string processing.
#
# The cmd_check orchestrator and _apply_downgrade (which make gh API
# calls) are NOT tested here — they are exercised live on the first
# dispatch of a disqualified tier:simple issue. A structural test
# verifies the wiring is in place.
#
# Test coverage includes complete/incomplete/absent checklists, all canonical
# contract forms, unpaired replacements, missing contracts, and regressions that
# prove counts, estimates, and isolated keywords are no longer automatic gates.

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

assert_pass() {
	local label="$1" fn="$2" body="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	DISQUALIFIER_REASON=""
	DISQUALIFIER_EVIDENCE=""
	local rc=0
	"$fn" "$body" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: pass (rc=0)"
		echo "  actual:   rc=${rc}, reason=${DISQUALIFIER_REASON}"
	fi
	return 0
}

assert_fail() {
	local label="$1" fn="$2" body="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	DISQUALIFIER_REASON=""
	DISQUALIFIER_EVIDENCE=""
	local rc=0
	"$fn" "$body" || rc=$?
	if [[ "$rc" -eq 10 ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label (reason: ${DISQUALIFIER_REASON})"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: fail (rc=10)"
		echo "  actual:   rc=${rc}"
	fi
	return 0
}

# --- Source the helper ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$SCRIPT_DIR/tier-simple-body-shape-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $HELPER not found"
	exit 1
fi

# The helper uses `if [[ BASH_SOURCE == $0 ]]; then main; fi` so we can
# source safely without triggering main execution. Disable strict set -e
# during source since shared-constants.sh may have lenient expectations.
# shellcheck source=/dev/null
set +e
source "$HELPER"
set -e

# Sanity check the functions we expect are available
for fn in _check_tier_checklist _check_execution_contract cmd_check cmd_help; do
	if ! declare -f "$fn" >/dev/null 2>&1; then
		echo "${TEST_RED}FATAL${TEST_NC}: function $fn not available after source"
		exit 1
	fi
done

echo "${TEST_BLUE}=== t2389: tier-simple execution-contract tests ===${TEST_NC}"
echo ""

# -----------------------------------------------------------------------
# Explicit checklist
# -----------------------------------------------------------------------

BODY_1A='### Tier checklist (verify before assigning)

- [x] Exact execution contract supplied?
- [x] Targets and reference pattern verified?
- [x] No semantic or design decision remains?

**Selected tier:** `tier:simple`'

assert_pass "1a: complete tier checklist passes" _check_tier_checklist "$BODY_1A"

BODY_1B='### Tier checklist (verify before assigning)

- [x] Exact execution contract supplied?
- [ ] No semantic or design decision remains?

**Selected tier:** `tier:simple`'

assert_fail "1b: incomplete tier checklist fails" _check_tier_checklist "$BODY_1B"
assert_pass "1c: legacy body without checklist passes checklist check" \
	_check_tier_checklist "## How
Apply the exact contract below."

# -----------------------------------------------------------------------
# Exact execution contracts
# -----------------------------------------------------------------------

BODY_2A='### Edit 1: exact replacement

**oldString:**
```
old
```

**newString:**
```
new
```'
assert_pass "2a: matched oldString/newString passes" _check_execution_contract "$BODY_2A"

BODY_2B='**oldString:**
```
old
```'
assert_fail "2b: unpaired replacement fails" _check_execution_contract "$BODY_2B"

BODY_2C='### New file 1

**Full content:**
```text
complete content
```'
assert_pass "2c: complete new-file content passes" _check_execution_contract "$BODY_2C"

BODY_2D='### Exact transform 1

**Exact transform:** `rename source.txt to destination.txt`'
assert_pass "2d: exact deterministic transform passes" _check_execution_contract "$BODY_2D"

assert_fail "2e: descriptive prose without a contract fails" \
	_check_execution_contract "Update the file using the existing pattern."

# -----------------------------------------------------------------------
# Retired proxy regressions
# -----------------------------------------------------------------------

BODY_3A='## How

- EDIT: `a.sh`
- EDIT: `b.sh`
- EDIT: `c.sh`
- EDIT: `d.sh`

Estimate: ~2h. Add fallback wording exactly as supplied.

## Acceptance

- [ ] one
- [ ] two
- [ ] three
- [ ] four
- [ ] five
- [ ] six

**Exact transform:** `replace token_old with token_new in each listed file`'

assert_pass "3a: file, estimate, criteria, and keyword counts are not gates" \
	_check_execution_contract "$BODY_3A"
assert_pass "3b: retired proxies do not affect absent-checklist handling" \
	_check_tier_checklist "$BODY_3A"

# -----------------------------------------------------------------------
# Structural / help
# -----------------------------------------------------------------------

TESTS_RUN=$((TESTS_RUN + 1))
if cmd_help 2>&1 | grep -q "tier-simple-body-shape-helper.sh"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 4: cmd_help prints usage"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 4: cmd_help did not print expected usage"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if declare -f cmd_check >/dev/null 2>&1; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 5: cmd_check function declared"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 5: cmd_check function missing"
fi

# -----------------------------------------------------------------------
# Integration — dispatch-core wiring
# -----------------------------------------------------------------------

DISPATCH_CORE="$SCRIPT_DIR/pulse-dispatch-core.sh"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q "_run_tier_simple_body_shape_check" "$DISPATCH_CORE"; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 6: pulse-dispatch-core.sh wires _run_tier_simple_body_shape_check"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 6: pulse-dispatch-core.sh missing wiring"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------

echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
