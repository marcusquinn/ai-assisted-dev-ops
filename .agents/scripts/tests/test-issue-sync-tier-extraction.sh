#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-issue-sync-tier-extraction.sh — regression tests for t2012
#
# Two related fixes that prevent issue-sync from creating tier label collisions:
#
#   1. _extract_tier_from_brief() in issue-sync-lib.sh now parses the explicit
#      `**Selected tier:**` line first. Before t2012 it grep-anywhere'd the
#      whole brief and took head -1, which matched commentary text like
#      "use `tier:standard` or higher" or rank-order lines BEFORE the actual
#      Selected tier line — returning the wrong tier.
#
#   2. _apply_tier_label_replace() in issue-sync-helper.sh is the new tier
#      label application path. It removes any existing tier:* labels before
#      adding the new one — closing the collision class observed in t1997
#      where multiple tier:* labels could coexist.
#
# Tests:
#   Class A: _extract_tier_from_brief
#     1. Selected tier wins over commentary mentions (the canonical bug)
#     2. Fallback to grep-anywhere when **Selected tier:** missing (warns)
#     3. Real t1993 brief fixture exhibits the original bug (now passes)
#     4. Empty/missing brief returns empty string (no crash)
#
#   Class B: _apply_tier_label_replace
#     5. Removes existing tier:simple before adding tier:standard
#     6. No-op when the issue already has the correct tier label (no remove)
#     7. Refuses to apply non-tier labels (defence-in-depth)
#
# Strategy:
#   - Source issue-sync-lib.sh after stubbing print_warning/print_info etc.
#   - For Class B, install a stubbed `gh` binary on PATH that records calls
#     and returns canned label JSON, then source issue-sync-helper.sh.

set -u

# Use TEST_-prefixed color vars so we don't collide with the readonly RED/GREEN
# defined by shared-constants.sh when the helper is sourced later.
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

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPTS_DIR}/../.." && pwd)" || exit 1
LIB="${SCRIPTS_DIR}/issue-sync-lib.sh"
HELPER="${SCRIPTS_DIR}/issue-sync-helper.sh"

if [[ ! -f "$LIB" ]]; then
	printf 'test harness cannot find lib at %s\n' "$LIB" >&2
	exit 1
fi
if [[ ! -f "$HELPER" ]]; then
	printf 'test harness cannot find helper at %s\n' "$HELPER" >&2
	exit 1
fi

TMP=$(mktemp -d -t t2012-tier.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Stubs for sourcing issue-sync-lib.sh standalone
# -----------------------------------------------------------------------------

print_warning() { :; }
print_info() { :; }
print_error() { :; }
print_success() { :; }
log_verbose() { :; }
export -f print_warning print_info print_error print_success log_verbose

# Source the lib (we only need _extract_tier_from_brief from it for Class A).
# shellcheck source=../issue-sync-lib.sh
source "$LIB" >/dev/null 2>&1 || true

printf '%sRunning issue-sync tier extraction + replace tests (t2012)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Class A: _extract_tier_from_brief parser correctness
# =============================================================================

# -----------------------------------------------------------------------------
# Test 1: Selected tier wins over commentary mentions
# -----------------------------------------------------------------------------
cat >"$TMP/brief-with-commentary.md" <<'BRIEF'
# Some task

## Tier

### Tier checklist (verify before assigning)

If any answer is "no", use `tier:standard` or higher. Rank order is
`tier:thinking` > `tier:standard` > `tier:simple`.

- [x] all checks pass
- [x] all checks pass

**Selected tier:** `tier:simple`
BRIEF

result=$(_extract_tier_from_brief "$TMP/brief-with-commentary.md" 2>/dev/null)
if [[ "$result" == "tier:simple" ]]; then
	pass "extract returns Selected tier (not first commentary mention)"
else
	fail "extract returns Selected tier (not first commentary mention)" \
		"expected tier:simple, got '$result'"
fi

# -----------------------------------------------------------------------------
# Test 2: Fallback to grep-anywhere when **Selected tier:** missing
# -----------------------------------------------------------------------------
cat >"$TMP/brief-no-selected-line.md" <<'BRIEF'
# Some task

## Estimate

This needs tier:standard for the work involved.
BRIEF

result=$(_extract_tier_from_brief "$TMP/brief-no-selected-line.md" 2>/dev/null)
if [[ "$result" == "tier:standard" ]]; then
	pass "extract falls back to first mention when **Selected tier:** missing"
else
	fail "extract falls back to first mention when **Selected tier:** missing" \
		"expected tier:standard, got '$result'"
fi

# -----------------------------------------------------------------------------
# Test 3: Real t1993 brief fixture (the canonical bug repro)
# -----------------------------------------------------------------------------
T1993_BRIEF="${REPO_ROOT}/todo/tasks/t1993-brief.md"
if [[ -f "$T1993_BRIEF" ]]; then
	result=$(_extract_tier_from_brief "$T1993_BRIEF" 2>/dev/null)
	# t1993's brief had Selected tier: tier:simple. The validator override is
	# a separate concern — the extractor should return the SELECTED tier, and
	# leave the override to _validate_tier_checklist.
	if [[ "$result" == "tier:simple" ]]; then
		pass "extract correctly handles real t1993 brief (returns Selected tier)"
	else
		fail "extract correctly handles real t1993 brief" \
			"expected tier:simple, got '$result' — extractor still buggy"
	fi
else
	# Synthetic equivalent — exact structure of the real t1993 brief
	cat >"$TMP/brief-t1993-synthetic.md" <<'BRIEF'
# t1993: synthetic equivalent of the real t1993 brief

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** → yes
- [x] **Complete code blocks for every edit?** → yes
- [ ] **No judgment or design decisions?** → no
- [x] **No error handling or fallback logic to design?** → yes
- [x] **Estimate 1h or less?** → yes
- [ ] **4 or fewer acceptance criteria?** → no

**Selected tier:** `tier:simple`

**Tier rationale:** rank order `tier:thinking` > `tier:standard` > `tier:simple`.
BRIEF
	result=$(_extract_tier_from_brief "$TMP/brief-t1993-synthetic.md" 2>/dev/null)
	if [[ "$result" == "tier:simple" ]]; then
		pass "extract correctly handles synthetic t1993-equivalent brief"
	else
		fail "extract correctly handles synthetic t1993-equivalent brief" \
			"expected tier:simple, got '$result'"
	fi
fi

# -----------------------------------------------------------------------------
# Test 4: Empty/missing brief returns empty string
# -----------------------------------------------------------------------------
result=$(_extract_tier_from_brief "$TMP/does-not-exist.md" 2>/dev/null)
if [[ -z "$result" ]]; then
	pass "extract returns empty for missing brief"
else
	fail "extract returns empty for missing brief" "got '$result'"
fi

# Empty brief
: >"$TMP/empty-brief.md"
result=$(_extract_tier_from_brief "$TMP/empty-brief.md" 2>/dev/null)
if [[ -z "$result" ]]; then
	pass "extract returns empty for empty brief"
else
	fail "extract returns empty for empty brief" "got '$result'"
fi

# =============================================================================
# Class B: _apply_tier_label_replace removes existing tier labels
# =============================================================================

# Set up a stubbed `gh` binary on PATH that records calls and returns canned
# label JSON via env vars. The stub is intentionally minimal.

GH_LOG="${TMP}/gh.log"
export GH_LOG
: >"$GH_LOG"
mkdir -p "${TMP}/bin"

cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

cmd1="${1:-}"
cmd2="${2:-}"

if [[ "$cmd1" == "issue" && "$cmd2" == "view" ]]; then
	# Honour --jq if present so the helper sees real label CSV output.
	jq_filter=""
	prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then
			jq_filter="$arg"
		fi
		prev="$arg"
	done
	if [[ -n "$jq_filter" ]]; then
		printf '%s\n' "${GH_VIEW_LABELS_JSON:-{\"labels\":[]}}" | jq -r "$jq_filter"
	else
		printf '%s\n' "${GH_VIEW_LABELS_JSON:-{\"labels\":[]}}"
	fi
	exit 0
fi

if [[ "$cmd1" == "issue" && "$cmd2" == "edit" ]]; then
	exit 0
fi

# Default: no-op success
exit 0
STUB
chmod +x "${TMP}/bin/gh"

# Source the helper so _apply_tier_label_replace is in scope.
# Note: we set PATH AFTER sourcing because issue-sync-helper.sh resets PATH at
# the top to "/usr/local/bin:/usr/bin:/bin:${PATH:-}", which would push our
# stub bin to the back of the PATH and let the real `gh` win.
# shellcheck source=../issue-sync-helper.sh
source "$HELPER" >/dev/null 2>&1 || true
export PATH="${TMP}/bin:${PATH}"

# -----------------------------------------------------------------------------
# Test 5: Removes existing tier:simple before adding tier:standard
# -----------------------------------------------------------------------------
: >"$GH_LOG"
export GH_VIEW_LABELS_JSON='{"labels":[{"name":"bug"},{"name":"tier:simple"},{"name":"auto-dispatch"}]}'

_apply_tier_label_replace "owner/repo" 123 "tier:standard" >/dev/null 2>&1

if grep -q 'remove-label tier:simple' "$GH_LOG" && grep -q 'add-label tier:standard' "$GH_LOG"; then
	pass "_apply_tier_label_replace removes tier:simple and adds tier:standard"
else
	fail "_apply_tier_label_replace removes tier:simple and adds tier:standard" \
		"gh.log: $(tr '\n' '|' <"$GH_LOG")"
fi

# -----------------------------------------------------------------------------
# Test 6: No remove call when issue already has the correct tier label
# -----------------------------------------------------------------------------
: >"$GH_LOG"
export GH_VIEW_LABELS_JSON='{"labels":[{"name":"bug"},{"name":"tier:standard"}]}'

_apply_tier_label_replace "owner/repo" 124 "tier:standard" >/dev/null 2>&1

# Positive guard: the function MUST have called gh issue view (proves it ran).
# Negative assertion: NO --remove-label tier:* call (current state is correct).
if ! grep -q 'issue view 124' "$GH_LOG"; then
	fail "_apply_tier_label_replace does not remove when already correct" \
		"helper did not call gh issue view (function may not have run)"
elif grep -q 'remove-label tier:' "$GH_LOG"; then
	fail "_apply_tier_label_replace does not remove when already correct" \
		"unexpected remove call: $(tr '\n' '|' <"$GH_LOG")"
else
	pass "_apply_tier_label_replace does not remove when already correct"
fi

# -----------------------------------------------------------------------------
# Test 7: Refuses to apply non-tier labels (defence-in-depth)
# -----------------------------------------------------------------------------
: >"$GH_LOG"
export GH_VIEW_LABELS_JSON='{"labels":[]}'

_apply_tier_label_replace "owner/repo" 125 "bug" >/dev/null 2>&1

# Positive guard: the function should refuse BEFORE calling gh at all.
# So neither `issue view 125` nor `add-label bug` should appear.
if grep -q 'add-label bug' "$GH_LOG" || grep -q 'issue view 125' "$GH_LOG"; then
	fail "_apply_tier_label_replace refuses non-tier labels" \
		"helper invoked gh for non-tier label: $(tr '\n' '|' <"$GH_LOG")"
else
	pass "_apply_tier_label_replace refuses non-tier labels"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "============================================"
printf 'Tests run:    %d\n' "$TESTS_RUN"
printf 'Tests failed: %d\n' "$TESTS_FAILED"
echo "============================================"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
