#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-cleanup-worktrees-async.sh — Unit tests for cleanup-worktrees-async-helper.sh (GH#20554)
#
# Tests cover the core lifecycle behaviours from the acceptance criteria:
#   1. lock-held     — second invocation skips when lock is held by a live PID
#   2. cadence-gate  — invocation skips when last-run is within the cadence window
#   3. cold-start    — first invocation runs when no lock and no last-run file
#   4. stale-PID     — lock reclamation when the holder PID is dead
#   5. signal-exit   — TERM stops the helper and releases its singleton lock
#
# Tests do NOT call the real cleanup_worktrees (which calls gh and git across
# all repos). Instead they inject a mock via CLEANUP_WORKTREES_ASYNC_TEST_MOCK.
#
# Usage:
#   bash .agents/scripts/tests/test-cleanup-worktrees-async.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../cleanup-worktrees-async-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

# Run the helper under a test environment where:
#   - HOME is redirected to TEST_DIR so no real ~/.aidevops state is touched
#   - cleanup_worktrees is replaced with a stub that exits $MOCK_CLEANUP_EXIT (default 0)
#     and writes "MOCK_RAN" to ${TEST_DIR}/mock-ran marker
#   - CLEANUP_WORKTREES_ASYNC_CADENCE_MIN is set to 10 (default)
#
# Caller sets env vars before calling (e.g. MOCK_CLEANUP_EXIT=0 run_helper_in_isolation).
# All env vars are inherited by the subshell via env; no positional args needed.
run_helper_in_isolation() {
	# Build a thin wrapper script that:
	#   1. Stubs out sourcing of shared-constants.sh (no-op)
	#   2. Stubs out sourcing of pulse-cleanup.sh, defines a mock cleanup_worktrees
	#   3. Sources the real helper functions (_lock_acquire, _cadence_ok, main, etc.)
	#
	# We achieve this by creating stub scripts in TEST_DIR/scripts/ that the
	# helper will source instead of the real ones (SCRIPT_DIR is overridden).

	local stub_dir="${TEST_DIR}/scripts"
	mkdir -p "$stub_dir"

	# Stub shared-constants.sh — defines nothing, just marks it was sourced
	cat >"${stub_dir}/shared-constants.sh" <<'STUB'
# stub shared-constants.sh
STUB

	# Stub pulse-cleanup.sh — defines mock cleanup_worktrees.
	# Use literal return 0 / return 1 (not a variable) so the pre-commit
	# return-statement ratchet doesn't flag the heredoc-embedded function.
	local mock_ran_file="${TEST_DIR}/mock-ran"
	local maintenance_ran_file="${TEST_DIR}/maintenance-ran"
	if [[ "${MOCK_CLEANUP_SKIPPED:-0}" -eq 1 ]]; then
		cat >"${stub_dir}/pulse-cleanup.sh" <<STUB
# stub pulse-cleanup.sh
cleanup_worktrees() {
	printf 'MOCK_RAN\n' >>"${mock_ran_file}"
	CLEANUP_WORKTREES_SKIPPED=1
	return 0
}
STUB
	elif [[ "${MOCK_CLEANUP_EXIT:-0}" -ne 0 ]]; then
		cat >"${stub_dir}/pulse-cleanup.sh" <<STUB
# stub pulse-cleanup.sh
_mock_cleanup_worktrees() {
	printf 'MOCK_RAN\n' >>"${mock_ran_file}"
	return 1
}
alias cleanup_worktrees='_mock_cleanup_worktrees'
cleanup_worktrees() { _mock_cleanup_worktrees; return 1; }
STUB
	else
		cat >"${stub_dir}/pulse-cleanup.sh" <<STUB
# stub pulse-cleanup.sh
cleanup_worktrees() {
	printf 'MOCK_RAN\n' >>"${mock_ran_file}"
	return 0
}
STUB
	fi
	cat >>"${stub_dir}/pulse-cleanup.sh" <<STUB
CLEANUP_WORKTREES_REMOVED_COUNT="${MOCK_REMOVED_COUNT:-0}"
CLEANUP_WORKTREES_ARCHIVED_COUNT="${MOCK_ARCHIVED_COUNT:-0}"
CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT="${MOCK_ARCHIVE_FAILED_COUNT:-0}"
STUB

	# Copy the helper into stub_dir so that when it runs, BASH_SOURCE[0] points
	# to stub_dir and dirname "${BASH_SOURCE[0]}" resolves to stub_dir. This
	# makes the helper source stubs instead of the real shared-constants.sh and
	# pulse-cleanup.sh (the helper re-calculates SCRIPT_DIR from BASH_SOURCE[0]
	# so injecting SCRIPT_DIR via env does not work).
	cp "$HELPER" "${stub_dir}/cleanup-worktrees-async-helper.sh"
	chmod +x "${stub_dir}/cleanup-worktrees-async-helper.sh"
	cat >"${stub_dir}/worktree-recovery-maintenance-helper.sh" <<STUB
#!/usr/bin/env bash
printf 'MAINTENANCE_RAN\\n' >>"${maintenance_ran_file}"
printf '{"schema":"test","outcome":"no-candidates"}\\n'
STUB
	chmod +x "${stub_dir}/worktree-recovery-maintenance-helper.sh"

	if [[ "${RUN_HELPER_UNSET_HOME:-0}" -eq 1 ]]; then
		env -u HOME \
			AIDEVOPS_LOG_DIR="${AIDEVOPS_LOG_DIR:-${TEST_DIR}/custom-logs}" \
			CLEANUP_WORKTREES_ASYNC_CADENCE_MIN="${CLEANUP_WORKTREES_ASYNC_CADENCE_MIN:-10}" \
			bash "${stub_dir}/cleanup-worktrees-async-helper.sh" 2>/dev/null || true
	else
		env HOME="$TEST_DIR" \
			CLEANUP_WORKTREES_ASYNC_CADENCE_MIN="${CLEANUP_WORKTREES_ASYNC_CADENCE_MIN:-10}" \
			bash "${stub_dir}/cleanup-worktrees-async-helper.sh" 2>/dev/null || true
	fi
	return 0
}

# ============================================================
# TEST 1: cold-start — helper runs when no lock and no last-run
# ============================================================
test_cold_start() {
	local mock_ran="${TEST_DIR}/mock-ran"
	rm -f "$mock_ran"

	MOCK_CLEANUP_EXIT=0 run_helper_in_isolation || true

	if [[ -f "$mock_ran" ]] && grep -q "MOCK_RAN" "$mock_ran"; then
		print_result "cold-start: cleanup_worktrees runs on first invocation" 0
	else
		print_result "cold-start: cleanup_worktrees runs on first invocation" 1 \
			"mock-ran marker not created; cleanup_worktrees was not called"
	fi
	return 0
}

# ============================================================
# TEST 2: last-run updated after successful run
# ============================================================
test_last_run_updated() {
	local last_run_file="${TEST_DIR}/.aidevops/logs/cleanup_worktrees.last-run"
	rm -f "$last_run_file"

	MOCK_CLEANUP_EXIT=0 run_helper_in_isolation || true

	if [[ -f "$last_run_file" ]]; then
		local val
		val=$(cat "$last_run_file")
		if [[ "$val" =~ ^[0-9]+$ ]]; then
			print_result "last-run updated on success" 0
		else
			print_result "last-run updated on success" 1 "last-run file contains non-numeric: $val"
		fi
	else
		print_result "last-run updated on success" 1 "last-run file not created"
	fi
	return 0
}

# ============================================================
# TEST 3: cadence-gate — helper skips when last-run is recent
# ============================================================
test_cadence_gate() {
	local logs_dir="${TEST_DIR}/.aidevops/logs"
	mkdir -p "$logs_dir"
	local last_run_file="${logs_dir}/cleanup_worktrees.last-run"
	local mock_ran="${TEST_DIR}/mock-ran"
	rm -f "$mock_ran"

	# Write a recent last-run timestamp (30 seconds ago) — well within 10-min cadence
	local recent_epoch=$(($(date +%s) - 30))
	printf '%s\n' "$recent_epoch" >"$last_run_file"

	MOCK_CLEANUP_EXIT=0 CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=10 \
		run_helper_in_isolation || true

	if [[ ! -f "$mock_ran" ]] || ! grep -q "MOCK_RAN" "$mock_ran" 2>/dev/null; then
		print_result "cadence-gate: skips when last run is recent" 0
	else
		print_result "cadence-gate: skips when last run is recent" 1 \
			"cleanup_worktrees was called despite recent last-run (cadence gate failed)"
	fi
	return 0
}

# ============================================================
# TEST 4: lock-held — second invocation skips when live lock held
# ============================================================
test_lock_held() {
	local logs_dir="${TEST_DIR}/.aidevops/logs"
	mkdir -p "$logs_dir"
	local lock_dir="${logs_dir}/cleanup_worktrees.lock"
	local pid_file="${lock_dir}/pid"
	local mock_ran="${TEST_DIR}/mock-ran"
	rm -f "$mock_ran"

	# Create a lock held by our own PID (which is alive)
	mkdir -p "$lock_dir"
	printf '%s\n' "$$" >"$pid_file"

	MOCK_CLEANUP_EXIT=0 run_helper_in_isolation || true

	# Lock dir should still exist (we didn't remove it), mock should NOT have run
	if [[ ! -f "$mock_ran" ]] || ! grep -q "MOCK_RAN" "$mock_ran" 2>/dev/null; then
		print_result "lock-held: skips when live lock is held" 0
	else
		print_result "lock-held: skips when live lock is held" 1 \
			"cleanup_worktrees was called despite live lock being held"
	fi

	# Cleanup
	rm -rf "$lock_dir" 2>/dev/null || true
	return 0
}

# ============================================================
# TEST 5: stale-PID — lock is reclaimed when holder PID is dead
# ============================================================
test_stale_pid_reclaim() {
	local logs_dir="${TEST_DIR}/.aidevops/logs"
	mkdir -p "$logs_dir"
	local lock_dir="${logs_dir}/cleanup_worktrees.lock"
	local pid_file="${lock_dir}/pid"
	local mock_ran="${TEST_DIR}/mock-ran"
	rm -f "$mock_ran"

	# Create a lock with a PID that cannot exist (PID 99999999 on most systems)
	mkdir -p "$lock_dir"
	printf '%s\n' "99999999" >"$pid_file"

	MOCK_CLEANUP_EXIT=0 run_helper_in_isolation || true

	# cleanup_worktrees SHOULD have been called (lock was reclaimed)
	if [[ -f "$mock_ran" ]] && grep -q "MOCK_RAN" "$mock_ran"; then
		print_result "stale-PID: lock reclaimed and cleanup runs" 0
	else
		print_result "stale-PID: lock reclaimed and cleanup runs" 1 \
			"cleanup_worktrees was not called after stale-PID reclaim"
	fi
	return 0
}

# ============================================================
# TEST 6: failed cleanup — last-run NOT updated on non-zero exit
# ============================================================
test_failed_cleanup_no_last_run_update() {
	local logs_dir="${TEST_DIR}/.aidevops/logs"
	local last_run_file="${logs_dir}/cleanup_worktrees.last-run"
	local maintenance_ran="${TEST_DIR}/maintenance-ran"
	rm -f "$last_run_file"

	# Mock cleanup_worktrees exits non-zero
	MOCK_CLEANUP_EXIT=1 run_helper_in_isolation || true

	if [[ ! -f "$last_run_file" && ! -f "$maintenance_ran" ]]; then
		print_result "failed-cleanup: last-run and maintenance skipped on non-zero exit" 0
	else
		print_result "failed-cleanup: last-run and maintenance skipped on non-zero exit" 1 \
			"last_run=$([[ -f "$last_run_file" ]] && printf yes || printf no) maintenance=$([[ -f "$maintenance_ran" ]] && printf yes || printf no)"
	fi
	return 0
}

# ============================================================
# TEST 7: skipped cleanup — last-run NOT updated on safety skip
# ============================================================
test_skipped_cleanup_no_last_run_update() {
	local logs_dir="${TEST_DIR}/.aidevops/logs"
	local last_run_file="${logs_dir}/cleanup_worktrees.last-run"
	local maintenance_ran="${TEST_DIR}/maintenance-ran"
	rm -f "$last_run_file"

	MOCK_CLEANUP_SKIPPED=1 run_helper_in_isolation || true

	if [[ ! -f "$last_run_file" && ! -f "$maintenance_ran" ]]; then
		print_result "skipped-cleanup: last-run and maintenance skipped on safety skip" 0
	else
		print_result "skipped-cleanup: last-run and maintenance skipped on safety skip" 1 \
			"last_run=$([[ -f "$last_run_file" ]] && printf yes || printf no) maintenance=$([[ -f "$maintenance_ran" ]] && printf yes || printf no)"
	fi
	return 0
}

# ============================================================
# TEST 8: lock released on exit (no orphaned lock after run)
# ============================================================
test_lock_released_after_run() {
	local logs_dir="${TEST_DIR}/.aidevops/logs"
	local lock_dir="${logs_dir}/cleanup_worktrees.lock"
	rm -rf "$lock_dir"

	MOCK_CLEANUP_EXIT=0 run_helper_in_isolation || true

	if [[ ! -d "$lock_dir" ]]; then
		print_result "lock-cleanup: lock dir removed after successful run" 0
	else
		print_result "lock-cleanup: lock dir removed after successful run" 1 \
			"lock dir still exists after run: $lock_dir"
	fi
	return 0
}

# ============================================================
# TEST 9: TERM exits the helper instead of only releasing its lock
# ============================================================
test_term_exits_and_releases_lock() {
	local stub_dir="${TEST_DIR}/scripts"
	local logs_dir="${TEST_DIR}/.aidevops/logs"
	local lock_dir="${logs_dir}/cleanup_worktrees.lock"
	local pid_file="${lock_dir}/pid"
	local mock_ran="${TEST_DIR}/mock-ran"
	local helper_pid=""
	local attempts=0
	mkdir -p "$stub_dir"
	rm -rf "$lock_dir"
	rm -f "$mock_ran"

	cat >"${stub_dir}/shared-constants.sh" <<'STUB'
# stub shared-constants.sh
STUB
	cat >"${stub_dir}/pulse-cleanup.sh" <<STUB
# stub pulse-cleanup.sh
cleanup_worktrees() {
	printf 'MOCK_RAN\n' >>"${mock_ran}"
	while :; do
		sleep 1
	done
	return 0
}
STUB
	cp "$HELPER" "${stub_dir}/cleanup-worktrees-async-helper.sh"
	chmod +x "${stub_dir}/cleanup-worktrees-async-helper.sh"

	env HOME="$TEST_DIR" CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=10 \
		bash "${stub_dir}/cleanup-worktrees-async-helper.sh" >/dev/null 2>&1 &
	helper_pid=$!
	while [[ ! -s "$pid_file" && "$attempts" -lt 50 ]]; do
		sleep 0.1
		attempts=$((attempts + 1))
	done
	if [[ ! -s "$pid_file" ]]; then
		kill -KILL "$helper_pid" 2>/dev/null || true
		wait "$helper_pid" 2>/dev/null || true
		print_result "signal-exit: helper acquires lock before TERM" 1 "lock PID file was not created"
		return 0
	fi

	kill -TERM "$helper_pid"
	attempts=0
	while kill -0 "$helper_pid" 2>/dev/null && [[ "$attempts" -lt 50 ]]; do
		sleep 0.1
		attempts=$((attempts + 1))
	done
	if kill -0 "$helper_pid" 2>/dev/null; then
		kill -KILL "$helper_pid" 2>/dev/null || true
		wait "$helper_pid" 2>/dev/null || true
		print_result "signal-exit: TERM stops helper and releases lock" 1 "helper remained alive after TERM"
		return 0
	fi
	wait "$helper_pid" 2>/dev/null || true

	if [[ ! -d "$lock_dir" ]]; then
		print_result "signal-exit: TERM stops helper and releases lock" 0
	else
		print_result "signal-exit: TERM stops helper and releases lock" 1 "lock remained after helper exited"
	fi
	return 0
}

# ============================================================
# TEST 10: sibling async lock helpers use the same terminating traps
# ============================================================
test_async_lock_helpers_install_terminating_traps() {
	local scripts_dir="${SCRIPT_DIR}/.."
	local helper_name=""
	local helper_path=""
	local invalid_helpers=""
	for helper_name in \
		cleanup-worktrees-async-helper.sh \
		cleanup-stashes-async-helper.sh \
		cleanup-remote-branches-async-helper.sh \
		opencode-db-archive-async-helper.sh; do
		helper_path="${scripts_dir}/${helper_name}"
		if ! grep -Fq "trap '_lock_signal_exit 130' INT" "$helper_path" ||
			! grep -Fq "trap '_lock_signal_exit 143' TERM" "$helper_path"; then
			invalid_helpers="${invalid_helpers}${invalid_helpers:+, }${helper_name}"
		fi
	done
	if [[ -z "$invalid_helpers" ]]; then
		print_result "signal-exit: all async lock helpers install terminating traps" 0
	else
		print_result "signal-exit: all async lock helpers install terminating traps" 1 "missing terminating traps: ${invalid_helpers}"
	fi
	return 0
}

# ============================================================
# TEST 11: HOME unset — explicit log dir avoids set -u unbound errors
# ============================================================
test_home_unset_uses_explicit_log_dir() {
	local custom_log_dir="${TEST_DIR}/custom-logs"
	local last_run_file="${custom_log_dir}/cleanup_worktrees.last-run"
	local mock_ran="${TEST_DIR}/mock-ran"
	rm -rf "$custom_log_dir"
	rm -f "$mock_ran"

	RUN_HELPER_UNSET_HOME=1 AIDEVOPS_LOG_DIR="$custom_log_dir" MOCK_CLEANUP_EXIT=0 \
		run_helper_in_isolation || true

	if [[ -f "$mock_ran" && -f "$last_run_file" ]]; then
		print_result "home-unset: explicit log dir avoids unbound HOME" 0
	else
		print_result "home-unset: explicit log dir avoids unbound HOME" 1 \
			"mock or last-run file missing when HOME was unset"
	fi
	return 0
}

test_recovery_maintenance_runs_once_per_cleanup() {
	local maintenance_ran="${TEST_DIR}/maintenance-ran"
	local run_count=""
	rm -f "$maintenance_ran"

	MOCK_CLEANUP_EXIT=0 run_helper_in_isolation || true
	run_count=$(wc -l <"$maintenance_ran" | tr -d ' ') || run_count=0
	if [[ "$run_count" == "1" ]]; then
		print_result "recovery-maintenance: runs once per async cleanup, not per candidate" 0
	else
		print_result "recovery-maintenance: runs once per async cleanup, not per candidate" 1 \
			"maintenance helper invocation count was ${run_count:-0}"
	fi
	return 0
}

test_archive_outcome_summary_is_logged() {
	local cleanup_log="${TEST_DIR}/.aidevops/logs/cleanup_worktrees.log"
	rm -f "$cleanup_log"

	MOCK_CLEANUP_EXIT=0 MOCK_REMOVED_COUNT=3 MOCK_ARCHIVED_COUNT=2 \
		MOCK_ARCHIVE_FAILED_COUNT=1 run_helper_in_isolation || true
	if grep -q 'outcome=success removed=3 archived=2 archive_failed=1' "$cleanup_log" 2>/dev/null; then
		print_result "archive-summary: async cleanup reports archive/delete outcomes" 0
	else
		print_result "archive-summary: async cleanup reports archive/delete outcomes" 1 \
			"structured archive outcome summary missing"
	fi
	return 0
}

# ============================================================
# MAIN
# ============================================================

main() {
	echo "Running cleanup-worktrees-async-helper.sh tests"
	echo "================================================"

	if [[ ! -f "$HELPER" ]]; then
		echo "ERROR: Helper not found at $HELPER"
		exit 1
	fi

	setup

	test_cold_start
	test_last_run_updated

	# Must re-setup between tests that share state
	teardown
	setup
	test_cadence_gate

	teardown
	setup
	test_lock_held

	teardown
	setup
	test_stale_pid_reclaim

	teardown
	setup
	test_failed_cleanup_no_last_run_update

	teardown
	setup
	test_skipped_cleanup_no_last_run_update

	teardown
	setup
	test_lock_released_after_run

	teardown
	setup
	test_term_exits_and_releases_lock

	teardown
	setup
	test_async_lock_helpers_install_terminating_traps

	teardown
	setup
	test_home_unset_uses_explicit_log_dir

	teardown
	setup
	test_recovery_maintenance_runs_once_per_cleanup

	teardown
	setup
	test_archive_outcome_summary_is_logged

	echo ""
	echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
