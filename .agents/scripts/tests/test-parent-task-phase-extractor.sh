#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-parent-task-phase-extractor.sh — structural + unit tests for t2771
#
# Verifies:
#   1.  parent-task-phase-extractor.sh is executable and shellcheck-clean
#   2.  help subcommand works and documents all three subcommands
#   3.  Unknown subcommand returns non-zero
#   4.  Detection: well-formed body with 2+ phases → eligible
#   5.  Detection: body with EDIT:/NEW: missing → ineligible
#   6.  Detection: body with **Reference pattern:** missing → ineligible
#   7.  Detection: body with **Verification:** missing → ineligible
#   8.  Detection: body with **Acceptance:** missing → ineligible
#   9.  Detection: body with **Acceptance:** present but no bullet → ineligible
#   10. Detection: only 1 qualifying phase (below min threshold) → ineligible
#   11. Detection: mixed body — one complete phase, one incomplete → ineligible (all-or-nothing)
#   12. Detection: canonical #20622-shaped body with 4 phases → eligible
#   13. Extractor carries generator marker compatible with pre-dispatch validators
#   14. Extractor uses For #NNN (not Closes/Resolves) per parent-task PR keyword rule
#   15. Extractor child label set includes auto-dispatch, tier:standard, origin:worker
#   16. Extractor skips no-auto-dispatch parents (dispatch guard)
#   17. Wiring: pulse-issue-reconcile.sh calls phase-extractor before nudge/escalation
#   18. Wiring: call in reconcile uses _PIR_SCRIPT_DIR path for extractor
#
# This is a structural + unit test — no live GitHub API calls are made.
# Detection logic is tested via function sourcing and synthetic bodies.

set -u

if [ -t 1 ]; then
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
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected pattern: %s\n' "$pattern"
		printf '  in file:          %s\n' "$file"
	fi
	return 0
}

assert_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qF -- "$pattern" "$file" 2>/dev/null; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected literal: %s\n' "$pattern"
		printf '  in file:          %s\n' "$file"
	fi
	return 0
}

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$expected" = "$actual" ]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected rc=%s, got rc=%s\n' "$expected" "$actual"
	fi
	return 0
}

assert_true() {
	local label="$1" condition="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$condition" = "0" ]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s (condition returned %s)\n' "$TEST_RED" "$TEST_NC" "$label" "$condition"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
EXTRACTOR="$SCRIPT_DIR/parent-task-phase-extractor.sh"
RECONCILE_ACTIONS="$SCRIPT_DIR/pulse-issue-reconcile-actions.sh"

for required in "$EXTRACTOR" "$RECONCILE_ACTIONS"; do
	if [ ! -f "$required" ]; then
		printf '%sFATAL%s: %s not found\n' "$TEST_RED" "$TEST_NC" "$required"
		exit 1
	fi
done

printf '%s=== t2771: parent-task phase extractor tests ===%s\n\n' "$TEST_BLUE" "$TEST_NC"

# ─── 1. Executable ────────────────────────────────────────────────────────────

TESTS_RUN=$((TESTS_RUN + 1))
if [ -x "$EXTRACTOR" ]; then
	printf '%sPASS%s: 1: extractor is executable\n' "$TEST_GREEN" "$TEST_NC"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s: 1: extractor is NOT executable\n' "$TEST_RED" "$TEST_NC"
fi

# ─── 2. Help subcommand ───────────────────────────────────────────────────────

help_output=$("$EXTRACTOR" help 2>&1)
help_rc=$?
assert_rc "2a: 'help' returns 0" "0" "$help_rc"

TESTS_RUN=$((TESTS_RUN + 1))
case "$help_output" in
*"run"*"check"*"help"*)
	printf '%sPASS%s: 2b: help output lists run / check / help subcommands\n' "$TEST_GREEN" "$TEST_NC"
	;;
*)
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s: 2b: help output is malformed\n' "$TEST_RED" "$TEST_NC"
	;;
esac

TESTS_RUN=$((TESTS_RUN + 1))
case "$help_output" in
*"PHASE_EXTRACTOR_DRY_RUN"*"PHASE_EXTRACTOR_MIN_PHASES"*)
	printf '%sPASS%s: 2c: help output documents env vars\n' "$TEST_GREEN" "$TEST_NC"
	;;
*)
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s: 2c: help output missing env var documentation\n' "$TEST_RED" "$TEST_NC"
	;;
esac

# ─── 3. Unknown subcommand ────────────────────────────────────────────────────

"$EXTRACTOR" bogus 2>/dev/null
bogus_rc=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$bogus_rc" -ne 0 ]; then
	printf '%sPASS%s: 3: unknown subcommand returns non-zero (rc=%s)\n' "$TEST_GREEN" "$TEST_NC" "$bogus_rc"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s: 3: unknown subcommand should return non-zero\n' "$TEST_RED" "$TEST_NC"
fi

# ─── Source extractor for unit tests ─────────────────────────────────────────
# Source the extractor in a subshell context so its functions are available
# without triggering main(). We use BASH_SOURCE source-guard.
# shellcheck source=/dev/null
source "$EXTRACTOR" 2>/dev/null || true

# Build a canonical well-formed phase block (all 5 required sub-sections present)
_canonical_phase() {
	local n="$1" desc="${2:-Do the work}"
	cat <<PHASE
### Phase ${n}: ${desc}

- EDIT: \`some-script.sh\` — replace old pattern with new pattern

**Reference pattern:** See \`shared-constants.sh\` function \`safe_grep_count\`.

**Verification:**
\`\`\`bash
shellcheck .agents/scripts/some-script.sh
\`\`\`

**Acceptance:**
- some-script.sh passes shellcheck
- old pattern no longer present
PHASE
	return 0
}

# Build a body with N canonical phases separated by blank lines
_body_with_phases() {
	local n="$1"
	local i=1
	while [ "$i" -le "$n" ]; do
		_canonical_phase "$i" "Phase $i task"
		printf '\n'
		i=$((i + 1))
	done
	return 0
}

# ─── 4. Well-formed body with 2+ phases is eligible ──────────────────────────

body_2_phases=$(_body_with_phases 2)
if _body_is_eligible "$body_2_phases"; then
	eligible_rc=0
else
	eligible_rc=1
fi
assert_rc "4: well-formed 2-phase body → eligible" "0" "$eligible_rc"

# ─── 5. Missing EDIT:/NEW: lines → ineligible ────────────────────────────────
# Using single-quoted multi-line string (no heredoc-in-subshell).

body_no_edit='### Phase 1: Some work

**Reference pattern:** See `shared-constants.sh`.

**Verification:**
```bash
echo ok
```

**Acceptance:**
- criteria met

### Phase 2: More work

**Reference pattern:** See `shared-constants.sh`.

**Verification:**
```bash
echo ok
```

**Acceptance:**
- criteria met'

if _body_is_eligible "$body_no_edit"; then
	no_edit_rc=0
else
	no_edit_rc=1
fi
assert_rc "5: body missing EDIT:/NEW: → ineligible" "1" "$no_edit_rc"

# ─── 6. Missing **Reference pattern:** → ineligible ──────────────────────────

body_no_ref='### Phase 1: Some work

- EDIT: `some-script.sh` — fix it

**Verification:**
```bash
echo ok
```

**Acceptance:**
- criteria met

### Phase 2: More work

- EDIT: `other-script.sh` — fix it

**Verification:**
```bash
echo ok
```

**Acceptance:**
- criteria met'

if _body_is_eligible "$body_no_ref"; then
	no_ref_rc=0
else
	no_ref_rc=1
fi
assert_rc "6: body missing **Reference pattern:** → ineligible" "1" "$no_ref_rc"

# ─── 7. Missing **Verification:** → ineligible ────────────────────────────────

body_no_verify='### Phase 1: Some work

- EDIT: `some-script.sh` — fix it

**Reference pattern:** See `shared-constants.sh`.

**Acceptance:**
- criteria met

### Phase 2: More work

- EDIT: `other-script.sh` — fix it

**Reference pattern:** See `shared-constants.sh`.

**Acceptance:**
- criteria met'

if _body_is_eligible "$body_no_verify"; then
	no_verify_rc=0
else
	no_verify_rc=1
fi
assert_rc "7: body missing **Verification:** → ineligible" "1" "$no_verify_rc"

# ─── 8. Missing **Acceptance:** → ineligible ─────────────────────────────────

body_no_accept='### Phase 1: Some work

- EDIT: `some-script.sh` — fix it

**Reference pattern:** See `shared-constants.sh`.

**Verification:**
```bash
echo ok
```

### Phase 2: More work

- EDIT: `other-script.sh` — fix it

**Reference pattern:** See `shared-constants.sh`.

**Verification:**
```bash
echo ok
```'

if _body_is_eligible "$body_no_accept"; then
	no_accept_rc=0
else
	no_accept_rc=1
fi
assert_rc "8: body missing **Acceptance:** → ineligible" "1" "$no_accept_rc"

# ─── 9. **Acceptance:** present but no bullet → ineligible ───────────────────

body_accept_no_bullet='### Phase 1: Some work

- EDIT: `some-script.sh` — fix it

**Reference pattern:** See `shared-constants.sh`.

**Verification:**
```bash
echo ok
```

**Acceptance:**
(no bullets here, just prose)

### Phase 2: More work

- EDIT: `other-script.sh` — fix it

**Reference pattern:** See `shared-constants.sh`.

**Verification:**
```bash
echo ok
```

**Acceptance:**
also no bullets'

if _body_is_eligible "$body_accept_no_bullet"; then
	accept_no_bullet_rc=0
else
	accept_no_bullet_rc=1
fi
assert_rc "9: **Acceptance:** without bullets → ineligible" "1" "$accept_no_bullet_rc"

# ─── 10. Only 1 qualifying phase → ineligible (below min threshold) ───────────

body_1_phase=$(_canonical_phase 1 "Only phase")
if _body_is_eligible "$body_1_phase"; then
	one_phase_rc=0
else
	one_phase_rc=1
fi
assert_rc "10: only 1 qualifying phase → ineligible" "1" "$one_phase_rc"

# ─── 11. Mixed: one complete, one incomplete → ineligible (all-or-nothing) ────
# Build with string concatenation instead of $(cat <<BODY) to avoid bash32 violation.

_incomplete_phase2='### Phase 2: Incomplete phase (missing Verification)

- EDIT: `some-script.sh` — fix it

**Reference pattern:** See `shared-constants.sh`.

**Acceptance:**
- criteria met'

body_mixed="$(_canonical_phase 1 "Complete phase")

${_incomplete_phase2}"

if _body_is_eligible "$body_mixed"; then
	mixed_rc=0
else
	mixed_rc=1
fi
assert_rc "11: mixed body (one incomplete phase) → ineligible" "1" "$mixed_rc"

# ─── 12. Canonical 4-phase body (#20622-shaped) → eligible ───────────────────

body_4_phases=$(_body_with_phases 4)
if _body_is_eligible "$body_4_phases"; then
	four_phase_rc=0
else
	four_phase_rc=1
fi
assert_rc "12: canonical 4-phase body → eligible" "0" "$four_phase_rc"

# ─── 13. Generator marker ─────────────────────────────────────────────────────

assert_grep_fixed \
	"13: extractor emits pre-dispatch-validator-friendly generator marker" \
	'aidevops:generator=phase-extractor' \
	"$EXTRACTOR"

# ─── 14. Parent-task PR keyword rule: uses For #NNN not Closes/Resolves ───────

assert_grep_fixed \
	"14a: child body uses 'For #' (not Closes/Resolves per parent-task keyword rule)" \
	'For #${parent_num}' \
	"$EXTRACTOR"

TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -qF 'Closes #${parent_num}' "$EXTRACTOR" && \
   ! grep -qF 'Resolves #${parent_num}' "$EXTRACTOR"; then
	printf '%sPASS%s: 14b: child body does NOT use Closes/Resolves\n' "$TEST_GREEN" "$TEST_NC"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s: 14b: child body incorrectly uses Closes/Resolves\n' "$TEST_RED" "$TEST_NC"
fi

# ─── 15. Child label set ──────────────────────────────────────────────────────

assert_grep_fixed "15a: child labels include auto-dispatch" 'auto-dispatch' "$EXTRACTOR"
assert_grep_fixed "15b: child labels include tier:standard" 'tier:standard' "$EXTRACTOR"
assert_grep_fixed "15c: child labels include origin:worker" 'origin:worker' "$EXTRACTOR"

# ─── 16. no-auto-dispatch dispatch guard ─────────────────────────────────────

assert_grep_fixed \
	"16: extractor skips no-auto-dispatch parents (dispatch guard)" \
	'no-auto-dispatch' \
	"$EXTRACTOR"

# ─── 17. Wiring: action module calls extractor before nudge/escalation ────────

assert_grep \
	"17a: action module calls phase-extractor (t2771)" \
	'parent-task-phase-extractor\.sh' \
	"$RECONCILE_ACTIONS"

assert_grep \
	"17b: action module skips nudge/escalation when extractor fires" \
	'_phase_extractor.*run.*issue_num' \
	"$RECONCILE_ACTIONS"

assert_grep_fixed \
	"17c: action module references t2771 in the phase-extractor integration comment" \
	't2771' \
	"$RECONCILE_ACTIONS"

# ─── 18. Wiring: reconcile uses _PIR_SCRIPT_DIR for extractor path ────────────

assert_grep_fixed \
	"18: action module uses _PIR_SCRIPT_DIR to locate extractor" \
	'_PIR_SCRIPT_DIR' \
	"$RECONCILE_ACTIONS"

# ─── Shellcheck ───────────────────────────────────────────────────────────────

if command -v shellcheck >/dev/null 2>&1; then
	TESTS_RUN=$((TESTS_RUN + 1))
	if shellcheck "$EXTRACTOR" >/dev/null 2>&1; then
		printf '%sPASS%s: 19: extractor is shellcheck-clean\n' "$TEST_GREEN" "$TEST_NC"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: 19: extractor has shellcheck violations\n' "$TEST_RED" "$TEST_NC"
		shellcheck "$EXTRACTOR" || true
	fi
else
	printf '%sSKIP%s: 19: shellcheck not installed\n' "$TEST_BLUE" "$TEST_NC"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

printf '\n%s=== Results: %s tests, %s failed ===%s\n' \
	"$TEST_BLUE" "$TESTS_RUN" "$TESTS_FAILED" "$TEST_NC"

if [ "$TESTS_FAILED" -gt 0 ]; then
	exit 1
fi

exit 0
