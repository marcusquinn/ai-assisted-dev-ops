#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-worker-exited-kill-reason.sh — Exercise classify_worker_kill_reason (t3063)
# =============================================================================
# Covers all six classification paths of the kill_reason classifier:
#   1. Explicit ${exit_code_file}.kill_reason sentinel (highest precedence)
#   2. ${exit_code_file}.watchdog_stall_killed → hard_kill_stall
#   3. ${exit_code_file}.watchdog_killed → no_output_stall
#   4. ${exit_code_file}.rate_limit_fast → rate_limit_fast
#   5. wait_status > 128 with no sentinel → unknown
#   6. wait_status == 0 (or other non-signal) → natural
#
# Plus structural assertions on the [lifecycle] worker_exited line emission
# in headless-runtime-helper.sh::_invoke_opencode (the consumer site).
#
# Usage: bash tests/test-worker-exited-kill-reason.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TMPDIR_TEST=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '  %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_eq() {
	local test_name="$1"
	local got="$2"
	local want="$3"
	if [[ "$got" == "$want" ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "got='${got}' want='${want}'"
	fi
	return 0
}

assert_grep() {
	local test_name="$1"
	local pattern="$2"
	local file="$3"
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "pattern '${pattern}' not found in ${file}"
	fi
	return 0
}

setup() {
	TMPDIR_TEST=$(mktemp -d)
	# Stub print_warning/print_info so headless-runtime-failure.sh can be
	# sourced without pulling in shared-constants.sh (matches the convention
	# used by test-worker-exit-classifier.sh).
	print_warning() { return 0; }
	print_info()    { return 0; }
	export -f print_warning print_info

	# shellcheck source=../headless-runtime-failure.sh
	source "${AGENTS_SCRIPTS}/headless-runtime-failure.sh"
	return 0
}

teardown() {
	[[ -n "$TMPDIR_TEST" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST" || true
	return 0
}

_fresh_exit_code_file() {
	local f
	f=$(mktemp -p "$TMPDIR_TEST")
	# Worker subshell normally writes exit code here; tests don't care about content.
	printf '0' >"$f"
	printf '%s' "$f"
	return 0
}

# ---------------------------------------------------------------------------
# Tests — classifier behaviour
# ---------------------------------------------------------------------------

# Path 1: explicit .kill_reason sentinel takes precedence over inference.
test_explicit_kill_reason_sentinel() {
	local f
	f=$(_fresh_exit_code_file)
	printf 'wall_clock_stale' >"${f}.kill_reason"
	# Also write a competing inference sentinel — explicit must still win.
	touch "${f}.watchdog_killed"
	local result
	result=$(classify_worker_kill_reason "$f" 143)
	assert_eq "explicit .kill_reason sentinel wins over .watchdog_killed" "$result" "wall_clock_stale"
	return 0
}

test_explicit_kill_reason_strips_trailing_newline() {
	local f
	f=$(_fresh_exit_code_file)
	# Real callers (printf 'foo\n' >file) commonly leave a trailing newline.
	printf 'idle_timeout\n' >"${f}.kill_reason"
	local result
	result=$(classify_worker_kill_reason "$f" 143)
	assert_eq ".kill_reason trailing newline is stripped" "$result" "idle_timeout"
	return 0
}

test_explicit_kill_reason_empty_falls_through() {
	local f
	f=$(_fresh_exit_code_file)
	# Empty sentinel must NOT win — must fall through to inference path.
	: >"${f}.kill_reason"
	touch "${f}.watchdog_stall_killed"
	local result
	result=$(classify_worker_kill_reason "$f" 143)
	assert_eq "empty .kill_reason falls through to .watchdog_stall_killed" "$result" "hard_kill_stall"
	return 0
}

test_explicit_kill_reason_whitespace_falls_through() {
	local f
	f=$(_fresh_exit_code_file)
	# Whitespace-only content (spaces/tabs/CRLF) must also fall through.
	printf '  \t\r\n' >"${f}.kill_reason"
	touch "${f}.rate_limit_fast"
	local result
	result=$(classify_worker_kill_reason "$f" 143)
	assert_eq "whitespace .kill_reason falls through to .rate_limit_fast" "$result" "rate_limit_fast"
	return 0
}

# Path 2: hard-kill stall sentinel.
test_watchdog_stall_killed_sentinel() {
	local f
	f=$(_fresh_exit_code_file)
	# Real watchdog writes BOTH .watchdog_killed and .watchdog_stall_killed
	# on a hard kill. Verify stall_killed wins.
	touch "${f}.watchdog_killed"
	touch "${f}.watchdog_stall_killed"
	local result
	result=$(classify_worker_kill_reason "$f" 143)
	assert_eq ".watchdog_stall_killed wins over .watchdog_killed" "$result" "hard_kill_stall"
	return 0
}

# Path 3: passive watchdog kill (no_output_stall).
test_watchdog_killed_only_sentinel() {
	local f
	f=$(_fresh_exit_code_file)
	touch "${f}.watchdog_killed"
	local result
	result=$(classify_worker_kill_reason "$f" 143)
	assert_eq ".watchdog_killed alone classifies as no_output_stall" "$result" "no_output_stall"
	return 0
}

# Path 4: rate_limit_fast monitor sentinel.
test_rate_limit_fast_sentinel() {
	local f
	f=$(_fresh_exit_code_file)
	touch "${f}.rate_limit_fast"
	local result
	result=$(classify_worker_kill_reason "$f" 143)
	assert_eq ".rate_limit_fast classifies as rate_limit_fast" "$result" "rate_limit_fast"
	return 0
}

# Path 5: signal-killed with no sentinel → unknown (acceptance target: 0%).
test_sigterm_no_sentinel_unknown() {
	local f
	f=$(_fresh_exit_code_file)
	# wait_status=143 = 128 + 15 (SIGTERM)
	local result
	result=$(classify_worker_kill_reason "$f" 143)
	assert_eq "wait_status=143 with no sentinel → unknown" "$result" "unknown"
	return 0
}

test_sigkill_no_sentinel_unknown() {
	local f
	f=$(_fresh_exit_code_file)
	# wait_status=137 = 128 + 9 (SIGKILL — OOM, parent kill)
	local result
	result=$(classify_worker_kill_reason "$f" 137)
	assert_eq "wait_status=137 with no sentinel → unknown" "$result" "unknown"
	return 0
}

# Path 6: clean exit and voluntary failure exit → natural.
test_clean_exit_natural() {
	local f
	f=$(_fresh_exit_code_file)
	local result
	result=$(classify_worker_kill_reason "$f" 0)
	assert_eq "wait_status=0 with no sentinel → natural" "$result" "natural"
	return 0
}

test_voluntary_failure_natural() {
	local f
	f=$(_fresh_exit_code_file)
	# Worker exit 1 (e.g. tests failed inside opencode, voluntary error).
	# Below the signal threshold (128), so kill_reason is "natural".
	local result
	result=$(classify_worker_kill_reason "$f" 1)
	assert_eq "wait_status=1 with no sentinel → natural" "$result" "natural"
	return 0
}

# Edge: missing exit_code_file path argument.
test_missing_exit_code_file_path() {
	# Empty path — classifier must still work (cannot inspect sentinels, falls
	# back to wait_status interpretation).
	local result
	result=$(classify_worker_kill_reason "" 143)
	assert_eq "empty exit_code_file + signal → unknown" "$result" "unknown"
	result=$(classify_worker_kill_reason "" 0)
	assert_eq "empty exit_code_file + clean → natural" "$result" "natural"
	return 0
}

# Edge: non-existent exit_code_file path (sentinels obviously missing).
test_nonexistent_exit_code_file() {
	local result
	result=$(classify_worker_kill_reason "${TMPDIR_TEST}/does-not-exist" 143)
	assert_eq "nonexistent exit_code_file + signal → unknown" "$result" "unknown"
	return 0
}

# Edge: non-numeric wait_status (defensive — caller bug).
test_non_numeric_wait_status() {
	local f
	f=$(_fresh_exit_code_file)
	local result
	# Garbage string for wait_status; numeric guard must reject it and
	# fall through to the natural default rather than treating as signal.
	result=$(classify_worker_kill_reason "$f" "garbage")
	assert_eq "non-numeric wait_status → natural (defensive default)" "$result" "natural"
	return 0
}

# Durable exit classification must consult kill-site sentinels before treating
# a persisted wrapper status as a natural or signal-derived process exit.
test_worker_exit_prefers_explicit_kill_reason_over_zero_status() {
	local f result
	f=$(_fresh_exit_code_file)
	printf 'hard_kill_stall' >"${f}.kill_reason"
	result=$(classify_worker_exit 0 0 "" "$f")
	assert_eq "durable exit classification prefers .kill_reason over status 0" \
		"$result" "hard_kill_stall"
	return 0
}

test_worker_exit_prefers_watchdog_sentinel_over_zero_status() {
	local f result
	f=$(_fresh_exit_code_file)
	touch "${f}.watchdog_stall_killed"
	result=$(classify_worker_exit 0 0 "" "$f")
	assert_eq "durable exit classification prefers watchdog sentinel over status 0" \
		"$result" "hard_kill_stall"
	return 0
}

test_worker_exit_preserves_natural_and_signal_fallbacks() {
	local f result
	f=$(_fresh_exit_code_file)
	result=$(classify_worker_exit 0 0 "" "$f")
	assert_eq "durable exit classification preserves natural status 0" "$result" "clean"
	result=$(classify_worker_exit 143 0 "" "$f")
	assert_eq "durable exit classification preserves signal fallback" \
		"$result" "signal_killed:15"
	return 0
}

test_exit_trap_classifies_completed_zero_status_sentinel() {
	local f
	f=$(_fresh_exit_code_file)
	printf '0' >"${f}.wait_status"
	printf 'hard_kill_stall' >"${f}.kill_reason"
	_WORKER_EXIT_CODE_FILE=""
	_WORKER_LAST_EXIT_CODE_FILE="$f"
	_WORKER_RUNTIME_LAUNCH_STARTED=1
	_WORKER_PRELAUNCH_FAILURE_REASON=""
	_WORKER_START_EPOCH_MS=0
	DISPATCH_LEDGER_HELPER=""
	AIDEVOPS_DISPATCH_LEASE_TOKEN=""
	TEST_TRAP_RESULT=""
	_hrff_finalize_exit_trap() {
		local session_key="$1"
		local reason="$2"
		local exit_status="$3"
		local session_count="$4"
		local force_nonzero_exit="$5"
		TEST_TRAP_RESULT="${session_key}|${reason}|${exit_status}|${session_count}|${force_nonzero_exit}"
		return 0
	}
	_exit_trap_handler "test-session"
	assert_eq "exit trap preserves sentinel classification after finalization and status 0" \
		"$TEST_TRAP_RESULT" "test-session|hard_kill_stall|0|0|0"
	unset -f _hrff_finalize_exit_trap
	return 0
}

# ---------------------------------------------------------------------------
# Tests — structural assertions on the consumer site (headless-runtime-helper.sh)
# ---------------------------------------------------------------------------

# t3063 acceptance: the worker_exited log line must carry the kill_reason field.
test_worker_exited_line_carries_kill_reason() {
	local helper="${AGENTS_SCRIPTS}/headless-runtime-helper.sh"
	# Match the print_info call literal — kill_reason= must appear on the
	# same line as wait_status= (single-line classification, the whole point of t3063).
	assert_grep "worker_exited line emits kill_reason= alongside wait_status=" \
		'\[lifecycle\] worker_exited.*wait_status=.*kill_reason=' \
		"$helper"
	return 0
}

test_exit_trap_prefers_dispatch_terminal_reason() {
	assert_grep "exit trap reads lease-bound dispatch terminal reason" \
		'terminal-reason --session-key' \
		"${SCRIPT_DIR}/../headless-runtime-failure.sh"
	# shellcheck disable=SC2016 # Match the literal variable reference in source.
	assert_grep "dispatch terminal reason takes precedence over generic exit classification" \
		'if \[\[ -n "\$ledger_terminal_reason" \]\]; then' \
		"${SCRIPT_DIR}/../headless-runtime-failure.sh"
	return 0
}

test_exit_trap_retains_completed_attempt_sentinel_path() {
	# shellcheck disable=SC2016 # Match literal variable references in source.
	assert_grep "runtime invocation retains completed attempt sentinel path" \
		'_WORKER_LAST_EXIT_CODE_FILE="\$exit_code_file"' \
		"${AGENTS_SCRIPTS}/headless-runtime-invoke.sh"
	assert_grep "exit trap resolves the durable attempt sentinel path" \
		'_durable_exit_code_file=\$\(_hrff_durable_exit_code_file\)' \
		"${AGENTS_SCRIPTS}/headless-runtime-failure.sh"
	return 0
}

# t3063 acceptance: classify_worker_kill_reason is invoked at the exit point.
test_invoke_opencode_calls_classifier() {
	local helper="${AGENTS_SCRIPTS}/headless-runtime-helper.sh"
	assert_grep "_invoke_opencode invokes classify_worker_kill_reason" \
		'classify_worker_kill_reason' \
		"$helper"
	return 0
}

# t3063 acceptance: classifier function exists in the failure library.
test_classifier_function_defined() {
	local lib="${AGENTS_SCRIPTS}/headless-runtime-failure.sh"
	assert_grep "classify_worker_kill_reason() defined in headless-runtime-failure.sh" \
		'^classify_worker_kill_reason\(\)' \
		"$lib"
	return 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

main() {
	setup
	trap teardown EXIT

	# Classifier paths
	test_explicit_kill_reason_sentinel
	test_explicit_kill_reason_strips_trailing_newline
	test_explicit_kill_reason_empty_falls_through
	test_explicit_kill_reason_whitespace_falls_through
	test_watchdog_stall_killed_sentinel
	test_watchdog_killed_only_sentinel
	test_rate_limit_fast_sentinel
	test_sigterm_no_sentinel_unknown
	test_sigkill_no_sentinel_unknown
	test_clean_exit_natural
	test_voluntary_failure_natural
	test_missing_exit_code_file_path
	test_nonexistent_exit_code_file
	test_non_numeric_wait_status
	test_worker_exit_prefers_explicit_kill_reason_over_zero_status
	test_worker_exit_prefers_watchdog_sentinel_over_zero_status
	test_worker_exit_preserves_natural_and_signal_fallbacks
	test_exit_trap_classifies_completed_zero_status_sentinel

	# Structural assertions on consumer site
	test_worker_exited_line_carries_kill_reason
	test_exit_trap_prefers_dispatch_terminal_reason
	test_exit_trap_retains_completed_attempt_sentinel_path
	test_invoke_opencode_calls_classifier
	test_classifier_function_defined

	printf '\n%d tests run, %d passed, %d failed\n' \
		"$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
