#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-fix-the-fixer-observability.sh — Structural tests for t3077.
#
# Verifies:
#   1. pulse-fix-the-fixer-detector.sh exists, is executable, and passes
#      a static-analysis smoke check.
#   2. The detector help subcommand emits the canonical synopsis.
#   3. dispatch-dedup-helper.sh exposes the has-fix-the-fixer-label
#      subcommand and its help mentions the contract.
#   4. headless-runtime-helper.sh defines _t3077_setup_fix_the_fixer_observability
#      and _t3077_write_preflight_sentinel.
#   5. worker-lifecycle-common.sh defines _emit_verbose_checkpoint and
#      _start_verbose_lifecycle_watcher.
#   6. _emit_verbose_checkpoint is a no-op when AIDEVOPS_VERBOSE_LIFECYCLE != 1
#      (idempotency / opt-in invariant).
#   7. _emit_verbose_checkpoint emits a structured marker when
#      AIDEVOPS_VERBOSE_LIFECYCLE=1.
#   8. _t3077_write_preflight_sentinel is a no-op when
#      AIDEVOPS_WORKER_PREFLIGHT_SENTINEL != 1.
#   9. _t3077_write_preflight_sentinel writes a sentinel and returns 0
#      when AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=1.
#  10. pulse-wrapper.sh defines _pulse_run_fix_the_fixer_detector_if_stale
#      and the sentinel-gate is hourly by default.
#  11. All four touched scripts pass shellcheck.
#
# Tests are structural — no live GitHub API calls and no LLM invocations.

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

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	# Use bash native glob match to avoid pipe + pipefail SIGPIPE issues
	# when sourced helpers (e.g. headless-runtime-helper.sh) enable
	# `set -o pipefail`. Pipe-based `printf | grep -q` exits 141 if grep
	# closes its stdin early on a large haystack, causing false negatives.
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to find: $(printf '%q' "$needle")"
		echo "  in output:        $(printf '%q' "${haystack:0:200}")"
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
		echo "  expected NOT to find: $(printf '%q' "$needle")"
		echo "  in output:            $(printf '%q' "${haystack:0:200}")"
	fi
	return 0
}

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected exit code: $expected"
		echo "  actual:             $actual"
	fi
	return 0
}

assert_file_exists() {
	local label="$1" path="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -f "$path" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  missing path: $path"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Resolve repo + script paths.
# ---------------------------------------------------------------------------
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"

DETECTOR_SH="$SCRIPTS_DIR/pulse-fix-the-fixer-detector.sh"
DEDUP_SH="$SCRIPTS_DIR/dispatch-dedup-helper.sh"
RUNTIME_SH="$SCRIPTS_DIR/headless-runtime-helper.sh"
LIFECYCLE_SH="$SCRIPTS_DIR/worker-lifecycle-common.sh"
LIFECYCLE_VERBOSE_SH="$SCRIPTS_DIR/worker-lifecycle-verbose.sh"
WRAPPER_SH="$SCRIPTS_DIR/pulse-wrapper.sh"
WRAPPER_CYCLE_GATES_SH="$SCRIPTS_DIR/pulse-wrapper-cycle-gates.sh"

# Capture all source files up front via cat — sourcing any of these helpers
# in later tests may inherit set -e / pipefail / readonly globals that
# would otherwise contaminate $(<file) reads done after the source.
detector_src=""
dedup_src=""
runtime_src=""
lifecycle_src=""
lifecycle_verbose_src=""
wrapper_src=""
wrapper_cycle_gates_src=""
[[ -r "$DETECTOR_SH" ]] && detector_src="$(cat "$DETECTOR_SH")"
[[ -r "$DEDUP_SH" ]] && dedup_src="$(cat "$DEDUP_SH")"
[[ -r "$RUNTIME_SH" ]] && runtime_src="$(cat "$RUNTIME_SH")"
[[ -r "$LIFECYCLE_SH" ]] && lifecycle_src="$(cat "$LIFECYCLE_SH")"
[[ -r "$LIFECYCLE_VERBOSE_SH" ]] && lifecycle_verbose_src="$(cat "$LIFECYCLE_VERBOSE_SH")"
[[ -r "$WRAPPER_SH" ]] && wrapper_src="$(cat "$WRAPPER_SH")"
[[ -r "$WRAPPER_CYCLE_GATES_SH" ]] && wrapper_cycle_gates_src="$(cat "$WRAPPER_CYCLE_GATES_SH")"

echo "${TEST_BLUE}== test-fix-the-fixer-observability.sh (t3077) ==${TEST_NC}"
echo "  repo: $REPO_ROOT"

# ---------------------------------------------------------------------------
# Test 1: detector script exists and is executable.
# ---------------------------------------------------------------------------
assert_file_exists "detector script exists" "$DETECTOR_SH"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -x "$DETECTOR_SH" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: detector is executable"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: detector is not executable"
fi

# ---------------------------------------------------------------------------
# Test 2: detector help subcommand prints synopsis.
# ---------------------------------------------------------------------------
help_out="$("$DETECTOR_SH" help 2>&1 || true)"
assert_contains "detector help mentions run subcommand" "run" "$help_out"
assert_contains "detector help mentions check subcommand" "check" "$help_out"
assert_contains "detector help mentions fix-the-fixer label" "fix-the-fixer" "$help_out"

# ---------------------------------------------------------------------------
# Test 3: dispatch-dedup-helper.sh exposes the new subcommand.
# ---------------------------------------------------------------------------
dedup_help="$("$DEDUP_SH" --help 2>&1 || "$DEDUP_SH" help 2>&1 || true)"
assert_contains "dedup help advertises has-fix-the-fixer-label" \
	"has-fix-the-fixer-label" "$dedup_help"
assert_contains "dedup script defines has_fix_the_fixer_label function" \
	"has_fix_the_fixer_label()" "$dedup_src"

# ---------------------------------------------------------------------------
# Test 4: headless-runtime-helper.sh defines the t3077 helpers.
# ---------------------------------------------------------------------------
assert_contains "runtime defines _t3077_setup_fix_the_fixer_observability" \
	"_t3077_setup_fix_the_fixer_observability()" "$runtime_src"
assert_contains "runtime defines _t3077_write_preflight_sentinel" \
	"_t3077_write_preflight_sentinel()" "$runtime_src"
assert_contains "runtime calls verbose checkpoint at worker_started" \
	"_emit_verbose_checkpoint worker_started" "$runtime_src"

# ---------------------------------------------------------------------------
# Test 5: worker-lifecycle-common.sh sources the verbose lifecycle helpers.
# ---------------------------------------------------------------------------
assert_contains "lifecycle sources verbose checkpoint module" \
	"worker-lifecycle-verbose.sh" "$lifecycle_src"
assert_contains "lifecycle defines _emit_verbose_checkpoint" \
	"_emit_verbose_checkpoint()" "$lifecycle_verbose_src"
assert_contains "lifecycle defines _start_verbose_lifecycle_watcher" \
	"_start_verbose_lifecycle_watcher()" "$lifecycle_verbose_src"
assert_contains "lifecycle defines _cleanup_verbose_lifecycle_watcher" \
	"_cleanup_verbose_lifecycle_watcher()" "$lifecycle_verbose_src"

# ---------------------------------------------------------------------------
# Test 6 + 7: _emit_verbose_checkpoint is opt-in (no-op without env flag,
# emits structured line when env=1).
# ---------------------------------------------------------------------------
test_emit_optin() {
	# shellcheck source=/dev/null
	source "$LIFECYCLE_SH"
	# Off-state: no output.
	local out_off
	out_off=$( (AIDEVOPS_VERBOSE_LIFECYCLE=0 _emit_verbose_checkpoint test_event "k=v") 2>&1)
	if [[ -z "$out_off" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: _emit_verbose_checkpoint silent when AIDEVOPS_VERBOSE_LIFECYCLE=0"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: _emit_verbose_checkpoint silent when AIDEVOPS_VERBOSE_LIFECYCLE=0"
		echo "  unexpected output: $(printf '%q' "${out_off:0:200}")"
	fi
	TESTS_RUN=$((TESTS_RUN + 1))

	# On-state: structured emit on stderr containing event token.
	local out_on
	out_on=$( (AIDEVOPS_VERBOSE_LIFECYCLE=1 _emit_verbose_checkpoint test_event "k=v") 2>&1)
	assert_contains "_emit_verbose_checkpoint emits event token when ON" "test_event" "$out_on"
	assert_contains "_emit_verbose_checkpoint emits lifecycle prefix when ON" "[lifecycle]" "$out_on"
	assert_contains "_emit_verbose_checkpoint emits supplied metadata when ON" "k=v" "$out_on"
	return 0
}
test_emit_optin

# ---------------------------------------------------------------------------
# Test 8 + 9: _t3077_write_preflight_sentinel is opt-in.
# ---------------------------------------------------------------------------
test_preflight_sentinel() {
	# Source the runtime helper (which sources its dependencies).
	# Use a temp HOME to avoid polluting the developer's cache.
	local _tmp_home
	_tmp_home="$(mktemp -d)"
	# shellcheck source=/dev/null
	HOME="$_tmp_home" source "$RUNTIME_SH" >/dev/null 2>&1 || true

	# Off-state: no sentinel write.
	local rc_off
	(AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=0 HOME="$_tmp_home" _t3077_write_preflight_sentinel) && rc_off=0 || rc_off=$?
	assert_rc "preflight sentinel no-op exits 0 when env=0" "0" "$rc_off"
	if [[ -z "$(find "$_tmp_home/.aidevops/cache/worker-preflight" -type f 2>/dev/null)" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: preflight sentinel does NOT write when env=0"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: preflight sentinel wrote a file when env=0"
	fi
	TESTS_RUN=$((TESTS_RUN + 1))

	# On-state: writes sentinel and exits 0.
	local rc_on
	(AIDEVOPS_WORKER_PREFLIGHT_SENTINEL=1 HOME="$_tmp_home" _t3077_write_preflight_sentinel) && rc_on=0 || rc_on=$?
	assert_rc "preflight sentinel exits 0 when env=1" "0" "$rc_on"
	if [[ -n "$(find "$_tmp_home/.aidevops/cache/worker-preflight" -type f 2>/dev/null)" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: preflight sentinel writes a file when env=1"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: preflight sentinel did NOT write when env=1"
	fi
	TESTS_RUN=$((TESTS_RUN + 1))

	rm -rf "$_tmp_home" 2>/dev/null || true
	return 0
}
test_preflight_sentinel

# ---------------------------------------------------------------------------
# Test 10: pulse-wrapper.sh wires the detector helper.
# ---------------------------------------------------------------------------
assert_contains "wrapper defines _pulse_run_fix_the_fixer_detector_if_stale" \
	"_pulse_run_fix_the_fixer_detector_if_stale()" "$wrapper_cycle_gates_src"
assert_contains "wrapper main calls the detector" \
	"_pulse_run_fix_the_fixer_detector_if_stale" "$wrapper_src"
assert_contains "wrapper sentinel uses canonical path token" \
	"pulse-fix-the-fixer-last-run" "$wrapper_cycle_gates_src"
assert_contains "wrapper default cadence is 3600s (hourly)" \
	"3600" "$wrapper_src"

# ---------------------------------------------------------------------------
# Test 11: shellcheck on all five touched scripts.
# ---------------------------------------------------------------------------
for f in "$DETECTOR_SH" "$DEDUP_SH" "$RUNTIME_SH" "$LIFECYCLE_SH" "$WRAPPER_SH"; do
	TESTS_RUN=$((TESTS_RUN + 1))
	# Run shellcheck if available; tolerate pre-existing info-level findings
	# (the ratchet validators are the source of truth — this is a smoke
	# pass that catches new SC2*/SC1*-class breakage).
	if ! command -v shellcheck >/dev/null 2>&1; then
		echo "${TEST_BLUE}SKIP${TEST_NC}: shellcheck not installed (smoke pass on $(basename "$f"))"
		continue
	fi
	if shellcheck --severity=warning "$f" >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: shellcheck warnings clean on $(basename "$f")"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: shellcheck warnings on $(basename "$f")"
		shellcheck --severity=warning "$f" 2>&1 | head -10 | sed 's/^/  /'
	fi
done

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo
echo "${TEST_BLUE}== summary ==${TEST_NC}"
echo "  tests run:    $TESTS_RUN"
echo "  tests failed: $TESTS_FAILED"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	echo "${TEST_GREEN}OK${TEST_NC}: all tests passed"
	exit 0
fi
echo "${TEST_RED}FAIL${TEST_NC}: $TESTS_FAILED test(s) failed"
exit 1
