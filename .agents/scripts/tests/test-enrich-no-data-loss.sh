#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-enrich-no-data-loss.sh — regression tests for t2377
#
# Asserts that the 5-layer defence-in-depth against the enrich-path data-loss
# bug (GH#19847) holds. The incident: #19778/#19779/#19780 had their titles
# reduced to "tNNN: " stubs and bodies emptied by issue-sync-helper.sh enrich
# when a brief existed on disk but no TODO.md entry referenced it.
#
# Layer coverage:
#
#   1. _enrich_process_task checks compose_issue_body exit code and skips
#      rather than forwarding an empty body.
#
#   2. _enrich_update_issue refuses to run `gh issue edit` with an empty title,
#      empty body, or stub "tNNN: " title regardless of FORCE_ENRICH.
#
#   3. _build_title returns non-zero on empty description (prevents the stub
#      emission that feeds layer 2's rejection path).
#
#   4. _ensure_issue_body_has_brief recognises `## What` + `## How` style
#      bodies AND the 500-char length heuristic as already-enriched.
#
#   5. _ensure_issue_body_has_brief skips force-enrich when TODO.md has no
#      entry for the task — brief-without-TODO is legitimate, not a stub.
#
# Strategy:
#   - Source issue-sync-helper.sh with stubbed logging.
#   - Stub `gh` to FAIL the test loudly if any destructive edit is attempted.
#   - For each layer, construct the minimal fixture and assert on either the
#     return code or the absence of a gh call.

set -u
set +e

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
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

section() {
	local title="$1"
	printf '\n%s%s%s\n' "$TEST_BLUE" "$title" "$TEST_NC"
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/issue-sync-helper.sh"
DISPATCH_CORE="${SCRIPTS_DIR}/pulse-dispatch-core.sh"

for f in "$HELPER" "$DISPATCH_CORE"; do
	if [[ ! -f "$f" ]]; then
		printf 'test harness cannot find %s\n' "$f" >&2
		exit 1
	fi
done

TMP=$(mktemp -d -t t2377-enrich-no-data-loss.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Track whether any destructive gh call fired during the test run.
export T2377_DESTRUCTIVE_CALL_LOG="${TMP}/destructive-calls.log"
: >"$T2377_DESTRUCTIVE_CALL_LOG"

# Install a stub `gh` that records destructive invocations. A destructive
# invocation is `gh issue edit --title "" ...` or `gh issue edit --body ""`
# or `gh issue edit --title "tNNN: " ...`. Any such call is a regression.
GH_STUB_BIN="${TMP}/bin/gh"
mkdir -p "${TMP}/bin"
cat >"$GH_STUB_BIN" <<'STUB'
#!/usr/bin/env bash
# t2377 test stub — records destructive gh issue edit calls.
LOG="${T2377_DESTRUCTIVE_CALL_LOG:-/dev/null}"

# For `gh issue view` — return a JSON body consistent with the fixture env.
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
	# Use the fixture-provided body if set, else empty.
	echo "${T2377_FIXTURE_BODY:-}"
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
	ALL_ARGS="$*"
	# Destructive patterns:
	#   --body "" (empty body)
	#   --body-file /dev/null
	#   --title "" (empty title)
	#   --title "tNNN: " (stub title)
	# We scan positional args because bash doesn't give us the quoted form.
	destructive=0
	reason=""
	prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--body" && -z "$arg" ]]; then
			destructive=1
			reason="empty --body"
		fi
		if [[ "$prev" == "--title" && -z "$arg" ]]; then
			destructive=1
			reason="empty --title"
		fi
		if [[ "$prev" == "--title" && "$arg" =~ ^t[0-9]+:[[:space:]]*$ ]]; then
			destructive=1
			reason="stub --title '$arg'"
		fi
		if [[ "$prev" == "--body-file" && "$arg" == "/dev/null" ]]; then
			destructive=1
			reason="--body-file /dev/null"
		fi
		prev="$arg"
	done
	if [[ $destructive -eq 1 ]]; then
		printf 'DESTRUCTIVE: %s (args: %s)\n' "$reason" "$ALL_ARGS" >>"$LOG"
	fi
	# Always succeed so test continues.
	exit 0
fi

# Default: no-op success.
exit 0
STUB
chmod +x "$GH_STUB_BIN"
export PATH="${TMP}/bin:$PATH"

# Stub logging helpers so sourcing the lib does not clobber stderr with colour
# codes during tests.
print_info() { :; return 0; }
print_warning() { :; return 0; }
print_error() { printf 'print_error: %s\n' "$*" >>"${TMP}/errors.log"; return 0; }
print_success() { :; return 0; }
export -f print_info print_warning print_error print_success

# Source the helper so we can invoke its private functions directly.
# shellcheck disable=SC1090
source "$HELPER" 2>/dev/null || {
	printf 'failed to source %s\n' "$HELPER" >&2
	exit 1
}
# The sourced helper re-enables set -euo pipefail. Disable again so the test
# can invoke functions expected to return non-zero without aborting the run.
set +e
set +u
set +o pipefail

# Re-stub print_error after sourcing — the helper re-defined it. We need our
# stub that writes to the errors.log so Layer 2 tests can check for guard
# evidence without polluting stdout.
print_error() { printf 'print_error: %s\n' "$*" >>"${TMP}/errors.log"; return 0; }
export -f print_error

destructive_count() { wc -l <"$T2377_DESTRUCTIVE_CALL_LOG" | tr -d ' '; return 0; }

reset_destructive_log() { : >"$T2377_DESTRUCTIVE_CALL_LOG"; return 0; }

# ----------------------------------------------------------------------------
# Layer 3: _build_title refuses empty description
# ----------------------------------------------------------------------------
section "Layer 3: _build_title refuses empty description"

reset_destructive_log
if _build_title "t9999" "" >/dev/null 2>&1; then
	fail "_build_title with empty desc should return non-zero"
else
	pass "_build_title with empty desc returns non-zero"
fi

if title=$(_build_title "t9999" "real description" 2>/dev/null); then
	if [[ "$title" == "t9999: real description" ]]; then
		pass "_build_title with valid desc returns expected title"
	else
		fail "_build_title valid desc" "got: '$title', expected: 't9999: real description'"
	fi
else
	fail "_build_title with valid desc should succeed"
fi

# Stub title (tNNN:) must NOT be emitted as output even through helpers.
output=$(_build_title "t9999" "" 2>&1 || true)
if [[ "$output" == *"t9999: "* && "$output" != *"refusing to emit stub title"* ]]; then
	fail "_build_title emitted stub title '$output'"
else
	pass "_build_title did not emit stub title on empty desc"
fi

# ----------------------------------------------------------------------------
# Layer 2: _enrich_update_issue refuses empty title/body/stub title
# ----------------------------------------------------------------------------
section "Layer 2: _enrich_update_issue never-delete invariant"

# Case: empty title
reset_destructive_log
FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "" "body with content" >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
	pass "_enrich_update_issue refused empty title (rc=$rc)"
else
	fail "_enrich_update_issue should refuse empty title under FORCE_ENRICH"
fi
if [[ $(destructive_count) -eq 0 ]]; then
	pass "no destructive gh edit called for empty title"
else
	fail "destructive gh edit fired for empty title"
fi

# Case: empty body
reset_destructive_log
FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "t9999: title" "" >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
	pass "_enrich_update_issue refused empty body (rc=$rc)"
else
	fail "_enrich_update_issue should refuse empty body under FORCE_ENRICH"
fi
if [[ $(destructive_count) -eq 0 ]]; then
	pass "no destructive gh edit called for empty body"
else
	fail "destructive gh edit fired for empty body"
fi

# Case: stub "tNNN: " title (even if non-empty)
reset_destructive_log
FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "t9999: " "body with content" >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
	pass "_enrich_update_issue refused stub title 't9999: ' (rc=$rc)"
else
	fail "_enrich_update_issue should refuse stub title"
fi
if [[ $(destructive_count) -eq 0 ]]; then
	pass "no destructive gh edit called for stub title"
else
	fail "destructive gh edit fired for stub title"
fi

# Case: valid title + body → passes the guard (even though downstream path
# may fail in other ways under the test stub; we only care the guard accepted).
# We look for the error-log evidence that our guards did NOT block the call.
: >"${TMP}/errors.log"
FORCE_ENRICH=true _enrich_update_issue "test/test" 9999 "t9999" "t9999: real title" "real body content" >/dev/null 2>&1 || true
if ! grep -q "data loss guard (t2377)" "${TMP}/errors.log"; then
	pass "_enrich_update_issue guard did not fire on valid title+body"
else
	fail "_enrich_update_issue guard fired on valid title+body (should not)" "$(cat "${TMP}/errors.log")"
fi

# ----------------------------------------------------------------------------
# Layer 4: _ensure_issue_body_has_brief broader marker check
# ----------------------------------------------------------------------------
section "Layer 4: _ensure_issue_body_has_brief broader marker check"

# Source pulse-dispatch-core.sh is complex (many cross-sources). Instead test
# the layer 4 patterns by direct string assertion on the file content — this
# is an effective regression check against the narrow-marker revert.

if grep -q "## What" "$DISPATCH_CORE" && grep -q "## How" "$DISPATCH_CORE" && grep -qE "current_body.*500" "$DISPATCH_CORE"; then
	pass "_ensure_issue_body_has_brief recognises ## What + ## How + length heuristic"
else
	fail "_ensure_issue_body_has_brief missing broader marker check"
fi

# ----------------------------------------------------------------------------
# Layer 5: _ensure_issue_body_has_brief requires TODO entry before force-enrich
# ----------------------------------------------------------------------------
section "Layer 5: _ensure_issue_body_has_brief requires TODO entry"

if grep -q "no TODO.md entry.*skipping force-enrich" "$DISPATCH_CORE"; then
	pass "_ensure_issue_body_has_brief skips force-enrich when TODO entry missing"
else
	fail "_ensure_issue_body_has_brief missing TODO-entry precheck"
fi

# ----------------------------------------------------------------------------
# Layer 1: _enrich_process_task exit-code check on compose_issue_body
# ----------------------------------------------------------------------------
section "Layer 1: _enrich_process_task compose_issue_body exit code"

# Structural check — composition failure must propagate instead of reporting a
# successful skip after refusing the write.
if grep -qE "compose_issue_body .*\\|\\| _compose_rc" "$HELPER" &&
	grep -q "Refusing enrich.*issue body composition failed" "$HELPER"; then
	pass "_enrich_process_task fails closed on compose_issue_body errors"
else
	fail "_enrich_process_task missing fail-closed compose_issue_body handling"
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
section "Summary"

printf '\nRan %d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ $TESTS_FAILED -gt 0 ]]; then
	printf '%sFAILED%s\n' "$TEST_RED" "$TEST_NC"
	exit 1
fi
printf '%sOK%s\n' "$TEST_GREEN" "$TEST_NC"
exit 0
