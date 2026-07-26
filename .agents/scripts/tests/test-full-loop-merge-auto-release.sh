#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-merge-auto-release.sh — t2429 regression guard.
#
# Asserts that `release_interactive_claim_on_merge()` from
# shared-claim-lifecycle.sh fires correctly when called from the
# full-loop-helper.sh merge path. Tests the shared library directly
# (sourced, not inlined) to ensure extraction didn't break behaviour.
#
# Production motivation (GH#20067, t2429):
#   full-loop-helper.sh merge did NOT fire _release_interactive_claim_on_merge
#   after a successful gh pr merge. That function was only called from
#   pulse-merge.sh. Result: interactive sessions that merged via
#   full-loop-helper.sh left stale claim stamps and status:in-review labels.
#   The fix extracts the function to shared-claim-lifecycle.sh and calls it
#   from both merge paths.
#
# Tests:
#   1. Happy path: matching stamp exists → release + unassign called and stamp
#      removed by the mocked helper.
#   2. Takeover path: origin:worker provenance + matching stamp → release called.
#   3. No-op: linked_issue empty → stamp untouched, no API calls.
#   4. No-op: worker PR stamp absent → release NOT called.
#   5. Idempotency: calling release twice on same issue → second call is no-op.
#   6. Backward compat: underscore-prefixed alias works identically.
#   7. Mismatched stamp payloads fail closed.
#
# Strategy:
#   Sources shared-claim-lifecycle.sh directly (the real extraction target).
#   Stubs replace `gh` and interactive-session-helper.sh. CLAIM_STAMP_DIR is
#   redirected to a temp directory.
#
# Cross-references: t2413 (original pulse-merge implementation),
#   t2429/GH#20067 (extraction + full-loop-helper parity),
#   test-pulse-merge-auto-release.sh (parallel test for the pulse-merge path).

set -uo pipefail

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

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2429.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/merge.log"
export LOGFILE

CLAIM_STAMP_DIR="${TMP}/interactive-claims"
mkdir -p "$CLAIM_STAMP_DIR"
export CLAIM_STAMP_DIR

# Track release calls — must be exported so the fake helper subprocess can append to it
RELEASE_CALLS="${TMP}/release_calls.log"
export RELEASE_CALLS

# Fake interactive-session-helper.sh that records calls and removes stamp file
FAKE_ISC="${TMP}/interactive-session-helper.sh"
cat >"$FAKE_ISC" <<'FAKE_EOF'
#!/usr/bin/env bash
# Stub for interactive-session-helper.sh used in test-full-loop-merge-auto-release.sh
action="$1"
issue="$2"
slug="$3"
printf '%s\n' "$*" >>"${RELEASE_CALLS}"
if [[ "$action" == "release" ]]; then
	stamp="${CLAIM_STAMP_DIR}/${slug//\//-}-${issue}.json"
	rm -f "$stamp"
fi
exit 0
FAKE_EOF
chmod +x "$FAKE_ISC"

AGENTS_DIR="${TMP}/agents"
mkdir -p "${AGENTS_DIR}/scripts"
cp "$FAKE_ISC" "${AGENTS_DIR}/scripts/interactive-session-helper.sh"
export AGENTS_DIR

write_stamp() {
	local stamp_file="$1"
	local issue="$2"
	local slug="$3"
	jq -cn --argjson issue "$issue" --arg slug "$slug" \
		'{issue:$issue,slug:$slug,pid:1234}' >"$stamp_file"
	return 0
}

# =============================================================================
# gh stub — returns controlled label/body output for pr view queries
# =============================================================================
GH_CALLS="${TMP}/gh_calls.log"
# The labels variable is set per-test to control what labels are returned.
GH_LABELS_RESPONSE=""
# The body variable is set per-test to control what PR body is returned.
# Used by the permissive Ref/For fallback path in Guard 1 (t2811/GH#20757).
GH_BODY_RESPONSE=""

gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"
	if [[ "$1" == "pr" && "$2" == "view" ]]; then
		# Differentiate body vs labels query so tests can control both.
		# The permissive fallback in Guard 1 calls --json body; the label
		# fetch in Guard 2 calls --json labels. (t2811)
		if [[ "$*" == *"--json body"* ]]; then
			printf '%s\n' "$GH_BODY_RESPONSE"
		else
			printf '%s\n' "$GH_LABELS_RESPONSE"
		fi
		return 0
	fi
	return 0
}
export -f gh

# =============================================================================
# Source the REAL shared-claim-lifecycle.sh (the extraction target)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/shared-claim-lifecycle.sh"

# Production reads now use the shared gh_pr_view wrapper. Route those reads
# back through this test's controlled gh fixture instead of live/cache state.
gh_pr_view() {
	gh pr view "$@"
	return $?
}

printf '%sRunning shared-claim-lifecycle / full-loop merge auto-release tests (t2429)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — Happy path: stamp exists + origin:interactive label → release fired
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8801.json"
write_stamp "$STAMP" "8801" "marcusquinn/aidevops"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "50" "marcusquinn/aidevops" "8801"

if grep -q "release 8801 marcusquinn/aidevops" "$RELEASE_CALLS" 2>/dev/null; then
	pass "happy path: release called for origin:interactive PR with stamp"
else
	fail "happy path: release called for origin:interactive PR with stamp" \
		"expected 'release 8801 marcusquinn/aidevops' in release calls — got: $(cat "$RELEASE_CALLS" 2>/dev/null || printf '(empty)')"
fi

if grep -q -- "release 8801 marcusquinn/aidevops --unassign" "$RELEASE_CALLS" 2>/dev/null; then
	pass "happy path: release requests assignee cleanup"
else
	fail "happy path: release requests assignee cleanup" \
		"expected --unassign in release call — got: $(cat "$RELEASE_CALLS" 2>/dev/null || printf '(empty)')"
fi

if [[ ! -f "$STAMP" ]]; then
	pass "happy path: stamp file removed by release"
else
	fail "happy path: stamp file removed by release" \
		"stamp file still exists: $STAMP"
fi

if grep -q "t2413/t2429" "$LOGFILE" 2>/dev/null; then
	pass "happy path: t2413/t2429 log line emitted"
else
	fail "happy path: t2413/t2429 log line emitted" \
		"expected t2413/t2429 in LOGFILE — got: $(cat "$LOGFILE" 2>/dev/null || printf '(empty)')"
fi

# =============================================================================
# Test 2 — Worker provenance with a matching interactive takeover stamp → release
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8802.json"
write_stamp "$STAMP" "8802" "marcusquinn/aidevops"
GH_LABELS_RESPONSE="origin:worker,tier:standard"

release_interactive_claim_on_merge "51" "marcusquinn/aidevops" "8802" "origin:worker,tier:standard"

if [[ ! -f "$STAMP" ]]; then
	pass "origin:worker takeover → matching stamp released"
else
	fail "origin:worker takeover → matching stamp released" \
		"matching takeover stamp was not removed"
fi

if grep -q "release 8802 marcusquinn/aidevops --unassign" "$RELEASE_CALLS" 2>/dev/null; then
	pass "origin:worker takeover → release and unassign called"
else
	fail "origin:worker takeover → release and unassign called" \
		"release was not called for the matching takeover stamp"
fi

# =============================================================================
# Test 3 — No-op: linked_issue empty AND body empty → stamp untouched,
#           release NOT called.
# Note: with the t2811 permissive fallback, one gh pr view --json body call
# IS made to attempt the Ref/For extraction. The assertion here is that
# release is not called (not that zero API calls are made) — the body fetch
# is expected. The stamp and release-not-called assertions remain the key
# guards for the no-op contract.
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8803.json"
write_stamp "$STAMP" "8803" "marcusquinn/aidevops"
GH_BODY_RESPONSE=""
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "52" "marcusquinn/aidevops" ""

if [[ -f "$STAMP" ]]; then
	pass "empty linked_issue + empty body → stamp untouched"
else
	fail "empty linked_issue + empty body → stamp untouched" \
		"stamp was removed when linked_issue and body were both empty"
fi

if ! grep -q "release" "$RELEASE_CALLS" 2>/dev/null; then
	pass "empty linked_issue + empty body → release NOT called"
else
	fail "empty linked_issue + empty body → release NOT called" \
		"release was called when neither linked_issue nor body had a reference"
fi

# =============================================================================
# Test 4 — No-op: worker PR without a takeover stamp → release NOT called
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
MISSING_STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8804.json"
rm -f "$MISSING_STAMP"
GH_LABELS_RESPONSE="origin:worker,tier:standard"

release_interactive_claim_on_merge "53" "marcusquinn/aidevops" "8804" "origin:worker,tier:standard"

if ! grep -q "release" "$RELEASE_CALLS" 2>/dev/null; then
	pass "unstamped worker PR → release NOT called"
else
	fail "unstamped worker PR → release NOT called" \
		"release was called when no takeover stamp existed"
fi

# =============================================================================
# Test 5 — Idempotency: calling release twice → second call is no-op
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8805.json"
write_stamp "$STAMP" "8805" "marcusquinn/aidevops"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "54" "marcusquinn/aidevops" "8805"
release_interactive_claim_on_merge "54" "marcusquinn/aidevops" "8805"

# Count release calls — should be exactly 1 (second call short-circuits on missing stamp)
CALL_COUNT=$(grep -c "release 8805" "$RELEASE_CALLS" 2>/dev/null || true)
if [[ "$CALL_COUNT" -eq 1 ]]; then
	pass "idempotency: release called exactly once on double invocation"
else
	fail "idempotency: release called exactly once on double invocation" \
		"expected 1 release call, got $CALL_COUNT"
fi

# =============================================================================
# Test 6 — Backward compat: underscore-prefixed alias works identically
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8806.json"
write_stamp "$STAMP" "8806" "marcusquinn/aidevops"
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

_release_interactive_claim_on_merge "55" "marcusquinn/aidevops" "8806"

if grep -q "release 8806 marcusquinn/aidevops" "$RELEASE_CALLS" 2>/dev/null; then
	pass "backward compat: underscore-prefixed alias fires release"
else
	fail "backward compat: underscore-prefixed alias fires release" \
		"expected 'release 8806 marcusquinn/aidevops' in release calls — got: $(cat "$RELEASE_CALLS" 2>/dev/null || printf '(empty)')"
fi

if [[ ! -f "$STAMP" ]]; then
	pass "backward compat: stamp file removed by underscore-prefixed alias"
else
	fail "backward compat: stamp file removed by underscore-prefixed alias" \
		"stamp file still exists: $STAMP"
fi

# =============================================================================
# Test 7 — Ref keyword fallback (t2811): linked_issue empty, body has Ref #NNN
#           → Guard 1 permissive extraction fires → release called
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8807.json"
write_stamp "$STAMP" "8807" "marcusquinn/aidevops"
GH_BODY_RESPONSE="Planning pass for t2809. Ref #8807 — keeps issue open until all phases merge."
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "60" "marcusquinn/aidevops" ""

if grep -q "release 8807 marcusquinn/aidevops" "$RELEASE_CALLS" 2>/dev/null; then
	pass "Ref keyword fallback: release called for empty linked_issue with Ref #NNN in body"
else
	fail "Ref keyword fallback: release called for empty linked_issue with Ref #NNN in body" \
		"expected 'release 8807 marcusquinn/aidevops' in release calls — got: $(cat "$RELEASE_CALLS" 2>/dev/null || printf '(empty)')"
fi

if [[ ! -f "$STAMP" ]]; then
	pass "Ref keyword fallback: stamp file removed by release"
else
	fail "Ref keyword fallback: stamp file removed by release" \
		"stamp file still exists: $STAMP"
fi

# =============================================================================
# Test 8 — For keyword fallback (t2811): linked_issue empty, body has For #NNN
#           → Guard 1 permissive extraction fires → release called
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8808.json"
write_stamp "$STAMP" "8808" "marcusquinn/aidevops"
GH_BODY_RESPONSE="For #8808 — planning-only PR per parent-task keyword rule."
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "61" "marcusquinn/aidevops" ""

if grep -q "release 8808 marcusquinn/aidevops" "$RELEASE_CALLS" 2>/dev/null; then
	pass "For keyword fallback: release called for empty linked_issue with For #NNN in body"
else
	fail "For keyword fallback: release called for empty linked_issue with For #NNN in body" \
		"expected 'release 8808 marcusquinn/aidevops' in release calls — got: $(cat "$RELEASE_CALLS" 2>/dev/null || printf '(empty)')"
fi

if [[ ! -f "$STAMP" ]]; then
	pass "For keyword fallback: stamp file removed by release"
else
	fail "For keyword fallback: stamp file removed by release" \
		"stamp file still exists: $STAMP"
fi

# =============================================================================
# Test 9 — No-op: linked_issue empty AND PR body has no issue reference
#           → Guard 1 permissive fallback finds nothing → still short-circuits
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8809.json"
write_stamp "$STAMP" "8809" "marcusquinn/aidevops"
GH_BODY_RESPONSE="This PR has no issue reference in the body at all."
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "62" "marcusquinn/aidevops" ""

if [[ -f "$STAMP" ]]; then
	pass "no body issue ref → stamp untouched"
else
	fail "no body issue ref → stamp untouched" \
		"stamp was removed when body had no issue reference"
fi

if ! grep -q "release" "$RELEASE_CALLS" 2>/dev/null; then
	pass "no body issue ref → release NOT called"
else
	fail "no body issue ref → release NOT called" \
		"release was called when body had no issue reference"
fi

# =============================================================================
# Test 10 — Caller-provided origin:worker labels do not suppress a matching
#            takeover stamp discovered through the Ref/For body fallback.
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8810.json"
write_stamp "$STAMP" "8810" "marcusquinn/aidevops"
GH_BODY_RESPONSE="For #8810 — planning-only PR."
GH_LABELS_RESPONSE="origin:worker,tier:standard"

# Pass pr_labels as 4th argument — caller already knows it's not interactive
release_interactive_claim_on_merge "63" "marcusquinn/aidevops" "" "origin:worker,tier:standard"

if [[ ! -f "$STAMP" ]]; then
	pass "provided origin:worker labels → matching takeover stamp released"
else
	fail "provided origin:worker labels → matching takeover stamp released" \
		"matching takeover stamp remained"
fi

if grep -q -- "--json body" "$GH_CALLS" 2>/dev/null; then
	pass "provided origin:worker labels → body fallback still evaluated"
else
	fail "provided origin:worker labels → body fallback still evaluated" \
		"expected a body lookup — got: $(cat "$GH_CALLS" 2>/dev/null || printf '(empty)')"
fi

if grep -q "release 8810 marcusquinn/aidevops --unassign" "$RELEASE_CALLS" 2>/dev/null; then
	pass "provided origin:worker labels → release called"
else
	fail "provided origin:worker labels → release called" \
		"release was not called for matching takeover ownership"
fi

# =============================================================================
# Test 11 — Word-boundary false-positive prevention (GH#20791):
#            "prefix #NNN" body text should NOT extract NNN via the "fix"
#            keyword. Without \b, "fix" at the tail of "prefix" followed by
#            whitespace+#number would produce a false match.
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8811.json"
write_stamp "$STAMP" "8811" "marcusquinn/aidevops"
GH_BODY_RESPONSE="Update the prefix #8811 to include the new format."
GH_LABELS_RESPONSE="origin:interactive,tier:standard"

release_interactive_claim_on_merge "65" "marcusquinn/aidevops" ""

if [[ -f "$STAMP" ]]; then
	pass "word-boundary: 'fix' inside 'prefix' → stamp untouched (no false match)"
else
	fail "word-boundary: 'fix' inside 'prefix' → stamp untouched (no false match)" \
		"stamp was removed due to false 'fix' match inside 'prefix #8811'"
fi

if ! grep -q "release" "$RELEASE_CALLS" 2>/dev/null; then
	pass "word-boundary: release NOT called due to false 'fix' in 'prefix'"
else
	fail "word-boundary: release NOT called due to false 'fix' in 'prefix'" \
		"release was called from false 'fix' match inside 'prefix'"
fi

# =============================================================================
# Test 12 — Mismatched issue payload fails closed even at the expected path
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8812.json"
write_stamp "$STAMP" "9999" "marcusquinn/aidevops"

release_interactive_claim_on_merge "66" "marcusquinn/aidevops" "8812" "origin:worker"

if [[ -f "$STAMP" ]] && ! grep -q "release" "$RELEASE_CALLS" 2>/dev/null; then
	pass "mismatched stamp issue → release fails closed"
else
	fail "mismatched stamp issue → release fails closed" \
		"mismatched issue stamp was released"
fi

# =============================================================================
# Test 13 — Mismatched repository payload fails closed at the scoped path
# =============================================================================
: >"$GH_CALLS"
: >"$RELEASE_CALLS"
: >"$LOGFILE"
STAMP="${CLAIM_STAMP_DIR}/marcusquinn-aidevops-8813.json"
write_stamp "$STAMP" "8813" "other/repository"

release_interactive_claim_on_merge "67" "marcusquinn/aidevops" "8813" "origin:worker"

if [[ -f "$STAMP" ]] && ! grep -q "release" "$RELEASE_CALLS" 2>/dev/null; then
	pass "mismatched stamp repository → release fails closed"
else
	fail "mismatched stamp repository → release fails closed" \
		"mismatched repository stamp was released"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
