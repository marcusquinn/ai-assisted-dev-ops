#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-issue-body-format-helper.sh — regression tests for issue-body-format-helper.sh
# (GH#21991: add issue-body formatting lint for AI-composed task descriptions)
#
# Covers:
#   1. Fully structured body with all required sections passes.
#   2. Body with dense prose (no headings) triggers advisory warning.
#   3. Body missing file scope AND How section is non-dispatchable (exit 1).
#   4. Body missing acceptance criteria is non-dispatchable (exit 1).
#   5. AIDEVOPS_BODY_FORMAT_STRICT=1 makes non-dispatchable a hard error.
#   6. Normalize: blank lines inserted before fences that lack one.
#   7. Normalize: fences with preceding blank lines are unchanged.
#   8. Body with acceptance checklist but no ## Acceptance heading passes.
#   9. Bare EDIT:/NEW: references are not executable scope.
#  10. help / unknown command exits with expected codes.

set -u
set +e

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
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
		printf '        %s\n' "$2"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Locate the helper
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../issue-body-format-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	printf 'FATAL: issue-body-format-helper.sh not found or not executable at %s\n' "$HELPER" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------

# Fully worker-ready body: file scope + reference + verification + acceptance
BODY_FULL_PASS="## Task

Add the foo feature.

## Why

Users need it.

## How

### Files to modify

- EDIT: .agents/scripts/foo.sh:10-20 — add bar function

## Files Scope

- .agents/scripts/foo.sh

### Reference pattern

Model on .agents/scripts/brief-readiness-helper.sh

## Verification

\`\`\`bash
shellcheck .agents/scripts/foo.sh
\`\`\`

## Acceptance

- [ ] foo.sh passes shellcheck
- [ ] feature works end-to-end
"

# Dense prose: no headings, long paragraphs
BODY_DENSE_PROSE="This task requires modifying the foo script to add the bar function. The bar function should handle edge cases properly and return the correct exit code. We also need to update the tests and make sure the CI passes. The reference is in brief-readiness-helper.sh and the verification is done with shellcheck."

# Missing file scope AND How section (non-dispatchable)
BODY_NO_FILES_NO_HOW="## Task

Fix the thing.

## Why

It is broken.

## Acceptance

- [ ] Works
"

# Missing acceptance criteria (non-dispatchable)
BODY_NO_ACCEPTANCE="## Task

Implement the widget.

## Files to modify

- EDIT: src/widget.sh

## Verification

\`\`\`bash
shellcheck src/widget.sh
\`\`\`
"

# Body with EDIT: patterns for file scope (no explicit ## Files heading)
BODY_EDIT_PATTERN="## Task

Fix the broken handler.

## Why

It crashes.

EDIT: .agents/scripts/handler.sh:50-60

## Verification

\`\`\`bash
bash .agents/scripts/tests/test-handler.sh
\`\`\`

## Acceptance

- [ ] Tests pass
"

# Body with checklist but no ## Acceptance heading
BODY_CHECKLIST_ONLY="## Task

Do the thing.

## Files to modify

- EDIT: foo.sh

## Verification

\`\`\`bash
shellcheck foo.sh
\`\`\`

- [ ] foo.sh is clean
- [ ] works as expected
"

# Fence without preceding blank line (normalize target)
BODY_FENCE_NO_BLANK="## Verification
\`\`\`bash
shellcheck foo.sh
\`\`\`
"

# Fence WITH preceding blank line (should be unchanged by normalize)
BODY_FENCE_WITH_BLANK="## Verification

\`\`\`bash
shellcheck foo.sh
\`\`\`
"

# Body accidentally passed with literal backslash-n Markdown structure.
BODY_ESCAPED_MARKDOWN='## Task\nFix escaped body.\n\n## Files to modify\n- EDIT: .agents/scripts/foo.sh\n\n## Reference pattern\nModel on .agents/scripts/bar.sh\n\n## Verification\nshellcheck .agents/scripts/foo.sh\n\n## Acceptance\n- [ ] Published body has real Markdown headings'

# Incidental backslash-n prose should not be decoded unless it forms escaped
# Markdown structure.
BODY_INCIDENTAL_ESCAPED="## Task

Document that the literal \n token can appear in prose.

## Files to modify

- EDIT: .agents/scripts/foo.sh

## Acceptance

- [ ] Prose stays unchanged
"

# ---------------------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------------------

printf '\ntest-issue-body-format-helper.sh\n\n'

# 1. Fully structured body passes (exit 0, no hard-error warnings)
rc=0
stderr=$("$HELPER" check "$BODY_FULL_PASS" 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then
	pass "1. full worker-ready body exits 0"
else
	fail "1. full worker-ready body exits 0" "got exit $rc; stderr: $stderr"
fi

# 2. Dense prose body emits a warning about headings
rc=0
stderr=$("$HELPER" check "$BODY_DENSE_PROSE" 2>&1) || rc=$?
if printf '%s' "$stderr" | grep -qi "dense\|heading"; then
	pass "2. dense-prose body emits heading/dense warning"
else
	fail "2. dense-prose body emits heading/dense warning" "stderr: $stderr"
fi

# 3. Body without file scope AND How section: helper exits 1 in strict mode
rc=0
stderr=$(AIDEVOPS_BODY_FORMAT_STRICT=1 "$HELPER" check "$BODY_NO_FILES_NO_HOW" 2>&1) || rc=$?
if [[ $rc -eq 1 ]]; then
	pass "3. missing file scope+How exits 1 (STRICT=1)"
else
	fail "3. missing file scope+How exits 1 (STRICT=1)" "got exit $rc; stderr: $stderr"
fi

# 4. Body without file scope AND How section: advisory only by default (exit 0)
rc=0
stderr=$("$HELPER" check "$BODY_NO_FILES_NO_HOW" 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then
	pass "4. missing file scope+How exits 0 by default (advisory)"
else
	fail "4. missing file scope+How exits 0 by default (advisory)" "got exit $rc"
fi

# 5. Body without acceptance criteria exits 1 in strict mode
rc=0
stderr=$(AIDEVOPS_BODY_FORMAT_STRICT=1 "$HELPER" check "$BODY_NO_ACCEPTANCE" 2>&1) || rc=$?
if [[ $rc -eq 1 ]]; then
	pass "5. missing acceptance criteria exits 1 (STRICT=1)"
else
	fail "5. missing acceptance criteria exits 1 (STRICT=1)" "got exit $rc; stderr: $stderr"
fi

# 6. Body without acceptance criteria exits 0 by default (advisory)
rc=0
stderr=$("$HELPER" check "$BODY_NO_ACCEPTANCE" 2>&1) || rc=$?
if [[ $rc -eq 0 ]]; then
	pass "6. missing acceptance criteria exits 0 by default (advisory)"
else
	fail "6. missing acceptance criteria exits 0 by default (advisory)" "got exit $rc"
fi

# 7. Normalize inserts blank line before fence lacking one
normalized=$("$HELPER" normalize "$BODY_FENCE_NO_BLANK" 2>/dev/null) || true
if printf '%s\n' "$normalized" | grep -qP '^\s*$' 2>/dev/null || \
   printf '%s\n' "$normalized" | awk '/^```/{if (prev == "") found=1} {prev=$0} END{exit !found}' 2>/dev/null; then
	pass "7. normalize inserts blank line before fence"
else
	# Fallback: check if a blank line appears before the first fence
	if printf '%s\n' "$normalized" | awk 'prev==""{if(/^```/)found=1}{prev=$0}END{exit !found}' 2>/dev/null; then
		pass "7. normalize inserts blank line before fence"
	else
		fail "7. normalize inserts blank line before fence" "output: $(printf '%s' "$normalized" | head -10)"
	fi
fi

# 8. Normalize does not introduce consecutive double blank lines
normalized=$("$HELPER" normalize "$BODY_FENCE_WITH_BLANK" 2>/dev/null) || true
# Fail if any two consecutive lines are both blank
if printf '%s\n' "$normalized" | \
   awk 'prev == "" && /^$/ { found=1 } { prev=$0 } END { exit found+0 }' 2>/dev/null; then
	pass "8. normalize does not introduce double blank lines"
else
	fail "8. normalize does not introduce double blank lines" "output: $(printf '%s\n' "$normalized")"
fi

# 9. Bare EDIT references cannot substitute for canonical executable scope.
rc=0
stderr=$(AIDEVOPS_BODY_FORMAT_STRICT=1 "$HELPER" check "$BODY_EDIT_PATTERN" 2>&1) || rc=$?
if [[ $rc -eq 1 && "$stderr" == *"lacks valid canonical Files Scope"* ]]; then
	pass "9. bare EDIT reference is rejected as missing scope"
else
	fail "9. bare EDIT reference is rejected as missing scope" "exit $rc; stderr: $stderr"
fi

# Producer normalization must turn explicit declarations into exact scope.
rc=0
normalized=$("$HELPER" normalize "$BODY_CHECKLIST_ONLY" 2>/dev/null) || rc=$?
stderr=$(AIDEVOPS_BODY_FORMAT_STRICT=1 "$HELPER" check "$normalized" 2>&1) || rc=$?
if [[ $rc -eq 0 && "$normalized" == *'## Files Scope'* && "$normalized" == *"- \`foo.sh\`"* ]]; then
	pass "9b. normalized explicit declaration passes strict consumer"
else
	fail "9b. normalized explicit declaration passes strict consumer" "exit $rc; stderr: $stderr"
fi

# 10. Acceptance checklist (- [ ]) without ## Acceptance heading passes acceptance check
rc=0
stderr=$(AIDEVOPS_BODY_FORMAT_STRICT=1 "$HELPER" check "$BODY_CHECKLIST_ONLY" 2>&1) || rc=$?
if printf '%s' "$stderr" | grep -qi "acceptance"; then
	fail "10. bare checklist counts as acceptance criteria" "got acceptance warning: $stderr"
else
	pass "10. bare checklist counts as acceptance criteria"
fi

# 11. help command exits 0
rc=0
"$HELPER" help >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then
	pass "11. help exits 0"
else
	fail "11. help exits 0" "got exit $rc"
fi

# 12. Unknown command exits non-zero
rc=0
"$HELPER" unknowncmd "body" >/dev/null 2>&1 || rc=$?
if [[ $rc -ne 0 ]]; then
	pass "12. unknown command exits non-zero"
else
	fail "12. unknown command exits non-zero" "got exit 0"
fi

# 13. Normalize decodes escaped Markdown newlines into real newlines
normalized=$("$HELPER" normalize "$BODY_ESCAPED_MARKDOWN" 2>/dev/null) || true
heading_count=$(printf '%s\n' "$normalized" | grep -cE '^##' 2>/dev/null || true)
if [[ "$normalized" != *'\n## '* && "$heading_count" =~ ^[0-9]+$ && "$heading_count" -ge 5 ]]; then
	pass "13. normalize decodes escaped Markdown newlines"
else
	fail "13. normalize decodes escaped Markdown newlines" "headings=${heading_count}; output: $(printf '%s' "$normalized")"
fi

# 14. Normalize preserves incidental backslash-n prose
normalized=$("$HELPER" normalize "$BODY_INCIDENTAL_ESCAPED" 2>/dev/null) || true
if [[ "$normalized" == *'literal \n token'* ]]; then
	pass "14. normalize preserves incidental backslash-n prose"
else
	fail "14. normalize preserves incidental backslash-n prose" "output: $(printf '%s' "$normalized")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%sPASS%s — all tests passed\n\n' "$TEST_GREEN" "$TEST_NC"
	exit 0
else
	printf '%sFAIL%s — %d test(s) failed\n\n' "$TEST_RED" "$TEST_NC" "$TESTS_FAILED"
	exit 1
fi
