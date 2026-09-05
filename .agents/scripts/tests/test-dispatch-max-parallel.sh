#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-max-parallel.sh — t3005 regression test for parallel fill_floor.
#
# Validates the parallel-dispatch loop in pulse-dispatch-engine.sh against
# the contract that the issue (#21438) sets out:
#
#   1. _dispatch_max_loop processes candidates concurrently up to
#      max_parallel and respects the effective_slots budget.
#   2. _dispatch_max_aggregate_outcomes correctly re-derives _DISPATCH_ROUND_DISPATCHED
#      and _DISPATCH_ROUND_NO_WORKER_FAILURES from the outcomes file.
#   3. _dispatch_max_compute_parallel honours DISPATCH_MAX_PARALLEL,
#      caps at effective_slots, and forces 1 (serial) when the throttle
#      file is present.
#   4. _dispatch_max_count_outcomes correctly tallies success/fail outcomes.
#
# The test stubs _dispatch_process_candidate so the loop body completes without
# real gh API / worktree operations — this isolates the parallel loop logic
# from the dispatch dependencies. Real dispatch behaviour is exercised by
# the existing pulse integration suite.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/headless-runtime"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export STOP_FLAG="${HOME}/.aidevops/logs/stop"
: >"$LOGFILE"

# Source the dispatch engine. The header guard `_PULSE_DISPATCH_ENGINE_LOADED`
# means a single source is sufficient; subsequent attempts are no-ops.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"

# Keep REST launch checks isolated from live GitHub evidence. Dedicated cases
# below override these stubs to exercise reserve serialization and loop stops.
pulse_rest_core_priority_snapshot() {
	printf 'disabled ? ? 0 0 0 ?\n'
	return 0
}
_dispatch_rest_core_progress_allows_next() {
	return 0
}

# Keep loop tests isolated from live API budget evidence. The dedicated budget
# gate case below overrides this helper to verify the stop path explicitly.
_dispatch_graphql_budget_allows_next() {
	return 0
}

# =============================================================================
# Test 1: _dispatch_max_compute_parallel honours DISPATCH_MAX_PARALLEL
# =============================================================================
test_compute_max_parallel_default() {
	# GH#29234: unset defaults to the conservative ceremony cap of 6 rather
	# than treating the full worker-slot budget as safe launch parallelism.
	unset DISPATCH_MAX_PARALLEL || true
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	# effective_slots=24 → expect the default ceremony cap of 6.
	result=$(_dispatch_max_compute_parallel 24)
	if [[ "$result" == "6" ]]; then
		print_result "compute_max_parallel: default=6 when unset" 0
	else
		print_result "compute_max_parallel: default=6 when unset" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_default_caps_at_slots() {
	unset DISPATCH_MAX_PARALLEL || true
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 3)
	if [[ "$result" == "3" ]]; then
		print_result "compute_max_parallel: default caps at effective_slots (3)" 0
	else
		print_result "compute_max_parallel: default caps at effective_slots (3)" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_override() {
	export DISPATCH_MAX_PARALLEL=10
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 24)
	if [[ "$result" == "10" ]]; then
		print_result "compute_max_parallel: explicit positive override wins" 0
	else
		print_result "compute_max_parallel: explicit positive override wins" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_caps_at_slots() {
	export DISPATCH_MAX_PARALLEL=10
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 3)
	if [[ "$result" == "3" ]]; then
		print_result "compute_max_parallel: caps at effective_slots (3)" 0
	else
		print_result "compute_max_parallel: caps at effective_slots (3)" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_throttle_forces_serial() {
	export DISPATCH_MAX_PARALLEL=6
	: >"$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 24)
	rm -f "$_DISPATCH_THROTTLE_FILE"
	if [[ "$result" == "1" ]]; then
		print_result "compute_max_parallel: throttle forces serial (1)" 0
	else
		print_result "compute_max_parallel: throttle forces serial (1)" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_invalid_var() {
	# Invalid input follows the same conservative default as unset input.
	export DISPATCH_MAX_PARALLEL="not-a-number"
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 24)
	if [[ "$result" == "6" ]]; then
		print_result "compute_max_parallel: invalid env falls back to 6" 0
	else
		print_result "compute_max_parallel: invalid env falls back to 6" 1 "got=${result}"
	fi
	unset DISPATCH_MAX_PARALLEL || true
	return 0
}

test_compute_max_parallel_rest_reserve_forces_serial() {
	export DISPATCH_MAX_PARALLEL=6
	rm -f "$_DISPATCH_THROTTLE_FILE"
	pulse_rest_core_priority_snapshot() {
		printf 'normal 700 5000 200 500 100 9999999999\n'
		return 0
	}
	local reserve_result healthy_result
	reserve_result=$(_dispatch_max_compute_parallel 24)
	pulse_rest_core_priority_snapshot() {
		printf 'normal 751 5000 200 500 100 9999999999\n'
		return 0
	}
	healthy_result=$(_dispatch_max_compute_parallel 24)
	pulse_rest_core_priority_snapshot() {
		printf 'disabled ? ? 0 0 0 ?\n'
		return 0
	}
	if [[ "$reserve_result" == "1" && "$healthy_result" == "6" ]]; then
		print_result "compute_max_parallel: REST reserve-adjacent zone forces serial" 0
	else
		print_result "compute_max_parallel: REST reserve-adjacent zone forces serial" 1 "reserve=${reserve_result} healthy=${healthy_result}"
	fi
	return 0
}

# =============================================================================
# Test 2: _dispatch_max_count_outcomes correctly tallies outcome lines
# =============================================================================
test_count_outcomes_success_and_fail() {
	local outcomes_file
	outcomes_file=$(mktemp)
	cat >"$outcomes_file" <<'EOF'
success|100
success|101
fail|102|rc=1|reason=skip
success|103
fail|104|rc=2|reason=no_worker_process
EOF
	local s f
	s=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	f=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
	rm -f "$outcomes_file"
	if [[ "$s" == "3" && "$f" == "2" ]]; then
		print_result "count_outcomes: success=3 fail=2" 0
	else
		print_result "count_outcomes: success=3 fail=2" 1 "got success=${s} fail=${f}"
	fi
	return 0
}

test_count_outcomes_empty_file() {
	local outcomes_file
	outcomes_file=$(mktemp)
	: >"$outcomes_file"
	local s
	s=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	rm -f "$outcomes_file"
	if [[ "$s" == "0" ]]; then
		print_result "count_outcomes: empty file -> 0" 0
	else
		print_result "count_outcomes: empty file -> 0" 1 "got=${s}"
	fi
	return 0
}

test_wait_tracked_pids_suppresses_stale_child() {
	local stale_pid stderr_file rc stderr_output
	stderr_file=$(mktemp)
	(
		exit 0
	) &
	stale_pid=$!
	wait "$stale_pid" 2>/dev/null || true
	rc=0
	_dispatch_max_wait_tracked_pids "$stale_pid" 2>"$stderr_file" || rc=$?
	stderr_output=$(cat "$stderr_file" 2>/dev/null || true)
	rm -f "$stderr_file"
	if [[ "$rc" -eq 0 && -z "$stderr_output" ]]; then
		print_result "wait_tracked_pids: suppresses stale child stderr" 0
	else
		print_result "wait_tracked_pids: suppresses stale child stderr" 1 "rc=${rc} stderr=${stderr_output}"
	fi
	return 0
}

# =============================================================================
# Test 3: _dispatch_max_aggregate_outcomes populates module-globals + invalidates cache
# =============================================================================
test_aggregate_outcomes_basic() {
	local outcomes_file
	outcomes_file=$(mktemp)
	cat >"$outcomes_file" <<'EOF'
success|100
success|101
fail|102|rc=1|reason=skip
success|103
EOF
	_DISPATCH_ROUND_DISPATCHED=0
	_DISPATCH_ROUND_NO_WORKER_FAILURES=0
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DISPATCH_CANARY_CACHE="${HOME}/.aidevops/.agent-workspace/headless-runtime/canary-last-pass"
	rm -f "$_DISPATCH_THROTTLE_FILE" "$_DISPATCH_CANARY_CACHE"
	: >"$_DISPATCH_CANARY_CACHE"
	_dispatch_max_aggregate_outcomes "$outcomes_file"
	rm -f "$outcomes_file"
	# 3 success + 1 fail = 4 dispatched, 0 no_worker failures
	if [[ "$_DISPATCH_ROUND_DISPATCHED" == "4" && "$_DISPATCH_ROUND_NO_WORKER_FAILURES" == "0" ]]; then
		print_result "aggregate_outcomes: dispatched=4 no_worker=0" 0
	else
		print_result "aggregate_outcomes: dispatched=4 no_worker=0" 1 \
			"got dispatched=${_DISPATCH_ROUND_DISPATCHED} no_worker=${_DISPATCH_ROUND_NO_WORKER_FAILURES}"
	fi
	# Cache should NOT be invalidated (only 0 no_worker failures)
	if [[ -f "$_DISPATCH_CANARY_CACHE" ]]; then
		print_result "aggregate_outcomes: canary cache preserved on no failures" 0
	else
		print_result "aggregate_outcomes: canary cache preserved on no failures" 1 "cache was removed"
	fi
	return 0
}

test_aggregate_outcomes_invalidates_canary_cache() {
	local outcomes_file
	outcomes_file=$(mktemp)
	cat >"$outcomes_file" <<'EOF'
fail|100|rc=1|reason=no_worker_process
fail|101|rc=1|reason=no_worker_process
fail|102|rc=1|reason=no_worker_process
fail|103|rc=1|reason=cli_usage
EOF
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DISPATCH_CANARY_CACHE="${HOME}/.aidevops/.agent-workspace/headless-runtime/canary-last-pass"
	rm -f "$_DISPATCH_THROTTLE_FILE"
	: >"$_DISPATCH_CANARY_CACHE"
	_dispatch_max_aggregate_outcomes "$outcomes_file"
	rm -f "$outcomes_file"
	# 3 no_worker failures → cache invalidated
	if [[ ! -f "$_DISPATCH_CANARY_CACHE" ]]; then
		print_result "aggregate_outcomes: canary invalidated on >=3 no_worker_process" 0
	else
		print_result "aggregate_outcomes: canary invalidated on >=3 no_worker_process" 1 "cache still present"
	fi
	# no_worker_failures should be 3 (not 4 — cli_usage doesn't count)
	if [[ "$_DISPATCH_ROUND_NO_WORKER_FAILURES" == "3" ]]; then
		print_result "aggregate_outcomes: no_worker count distinguishes reasons" 0
	else
		print_result "aggregate_outcomes: no_worker count distinguishes reasons" 1 \
			"got=${_DISPATCH_ROUND_NO_WORKER_FAILURES}"
	fi
	return 0
}

test_aggregate_outcomes_clears_throttle_on_success() {
	local outcomes_file
	outcomes_file=$(mktemp)
	cat >"$outcomes_file" <<'EOF'
success|100
EOF
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DISPATCH_CANARY_CACHE="${HOME}/.aidevops/.agent-workspace/headless-runtime/canary-last-pass"
	: >"$_DISPATCH_THROTTLE_FILE"
	_dispatch_max_aggregate_outcomes "$outcomes_file"
	rm -f "$outcomes_file"
	if [[ ! -f "$_DISPATCH_THROTTLE_FILE" ]]; then
		print_result "aggregate_outcomes: throttle cleared on any success" 0
	else
		print_result "aggregate_outcomes: throttle cleared on any success" 1 "throttle still set"
	fi
	return 0
}

# =============================================================================
# Test 4: _dispatch_max_loop — end-to-end with stubbed candidate proc
# =============================================================================
test_parallel_loop_end_to_end() {
	# Stub _dispatch_process_candidate to simulate work without real dispatch
	# deps. Candidates with even numbers succeed; odd numbers fail.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		local candidate_json="$1"
		# Simulate ~50ms of work so parallel makes a measurable difference
		# vs the bash tick (allows the timing assertion below to be robust
		# even on slow CI runners).
		local issue_num
		issue_num=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
		sleep 0.05
		if (( issue_num % 2 == 0 )); then
			return 0
		fi
		_PULSE_LAST_LAUNCH_FAILURE="no_worker_process"
		return 1
	}

	# Build a candidate file with 6 issues — 3 even (success), 3 odd (fail)
	local candidate_file outcomes_file
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	cat >"$candidate_file" <<'EOF'
{"number":100,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":101,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":102,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":103,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":104,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":105,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
EOF
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	# Run parallel loop with effective_slots=10 (no budget cap), max_parallel=3
	local result
	result=$(_dispatch_max_loop "$candidate_file" 10 10 "test_user" 3 "$outcomes_file")

	# Expected: 3 successes (even numbers), 3 fails (odd numbers)
	local s f
	s=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	f=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
	rm -f "$candidate_file" "$outcomes_file"

	# Result should be "3 6" (dispatched=3, processed=6)
	if [[ "$result" == "3 6" && "$s" == "3" && "$f" == "3" ]]; then
		print_result "parallel_loop: end-to-end 3 success + 3 fail" 0
	else
		print_result "parallel_loop: end-to-end 3 success + 3 fail" 1 \
			"got result='${result}' s=${s} f=${f}"
	fi
	return 0
}

test_parallel_loop_respects_budget() {
	# Stub: every candidate succeeds
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		sleep 0.02
		return 0
	}

	local candidate_file outcomes_file
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	# 10 candidates available
	local i
	for i in 200 201 202 203 204 205 206 207 208 209; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	# effective_slots=4, max_parallel=4 — should stop after 4 successes
	local result
	result=$(_dispatch_max_loop "$candidate_file" 4 4 "test_user" 4 "$outcomes_file")
	local s
	s=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	rm -f "$candidate_file" "$outcomes_file"

	# Pending ceremonies reserve capacity, so a successful four-slot wave launches
	# exactly four workers rather than overshooting while outcomes are in flight.
	if [[ "$s" == "4" ]]; then
		print_result "parallel_loop: respects effective_slots=4 budget (got s=${s})" 0
	else
		print_result "parallel_loop: respects effective_slots=4 budget" 1 "got s=${s}"
	fi
	# Result first field should match s
	local result_dispatched
	result_dispatched=$(printf '%s' "$result" | awk '{print $1}')
	if [[ "$result_dispatched" == "$s" ]]; then
		print_result "parallel_loop: result.dispatched matches outcomes file" 0
	else
		print_result "parallel_loop: result.dispatched matches outcomes file" 1 \
			"result=${result_dispatched} outcomes=${s}"
	fi
	return 0
}

test_parallel_loop_refills_rejected_reservation() {
	# The first success and slow rejection consume both reservations. The final
	# candidate must be retried after the rejection frees its slot.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		local candidate_json="$1" issue_num
		issue_num=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
		if [[ "$issue_num" == "801" ]]; then
			sleep 0.15
			_PULSE_LAST_LAUNCH_FAILURE="no_worker_process"
			return 1
		fi
		sleep 0.02
		return 0
	}

	local candidate_file outcomes_file result successes failures
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	cat >"$candidate_file" <<'EOF'
{"number":800,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
{"number":801,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
{"number":802,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
EOF
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	result=$(_dispatch_max_loop "$candidate_file" 2 2 "test_user" 2 "$outcomes_file")
	successes=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	failures=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
	rm -f "$candidate_file" "$outcomes_file"

	if [[ "$result" == "2 3" && "$successes" == "2" && "$failures" == "1" ]]; then
		print_result "parallel_loop: refills a rejected reservation in the same round" 0
	else
		print_result "parallel_loop: refills a rejected reservation in the same round" 1 \
			"result=${result} successes=${successes} failures=${failures}"
	fi
	return 0
}

test_parallel_loop_all_rejections_finish() {
	# Reconciliation must consume a finite queue of rejected ceremonies without
	# spinning after each reservation is released.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		sleep 0.02
		_PULSE_LAST_LAUNCH_FAILURE="no_worker_process"
		return 1
	}

	local candidate_file outcomes_file result failures
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	cat >"$candidate_file" <<'EOF'
{"number":810,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
{"number":811,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
{"number":812,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
EOF
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	result=$(_dispatch_max_loop "$candidate_file" 2 2 "test_user" 2 "$outcomes_file")
	failures=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
	rm -f "$candidate_file" "$outcomes_file"

	if [[ "$result" == "0 3" && "$failures" == "3" ]]; then
		print_result "parallel_loop: all rejected candidates finish without spinning" 0
	else
		print_result "parallel_loop: all rejected candidates finish without spinning" 1 \
			"result=${result} failures=${failures}"
	fi
	return 0
}

test_parallel_loop_stop_flag_aborts() {
	# Stub: pre-create the STOP flag so the first candidate aborts the loop
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		return 0
	}

	local candidate_file outcomes_file
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	for i in 300 301 302 303; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"
	: >"$outcomes_file"

	# Pre-create STOP flag — loop must break on the first iteration
	: >"$STOP_FLAG"
	local result
	result=$(_dispatch_max_loop "$candidate_file" 10 10 "test_user" 4 "$outcomes_file")
	rm -f "$STOP_FLAG" "$candidate_file" "$outcomes_file"

	# Expected: 0 dispatches because we hit STOP before any subshell launch
	local result_dispatched
	result_dispatched=$(printf '%s' "$result" | awk '{print $1}')
	if [[ "$result_dispatched" == "0" ]]; then
		print_result "parallel_loop: stop flag aborts dispatch" 0
	else
		print_result "parallel_loop: stop flag aborts dispatch" 1 "got=${result_dispatched}"
	fi
	return 0
}

test_parallel_loop_graphql_budget_aborts() {
	# Stub: every candidate would succeed if the budget gate allowed launch.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		return 0
	}
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_graphql_budget_allows_next() {
		return 1
	}

	local candidate_file outcomes_file
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	for i in 320 321 322 323; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	local result
	result=$(_dispatch_max_loop "$candidate_file" 10 10 "test_user" 4 "$outcomes_file")
	rm -f "$candidate_file" "$outcomes_file"
	# Restore the default test isolation stub for later loop cases.
	_dispatch_graphql_budget_allows_next() {
		return 0
	}

	if [[ "$result" == "0 1" ]]; then
		print_result "parallel_loop: GraphQL budget gate aborts before launch" 0
	else
		print_result "parallel_loop: GraphQL budget gate aborts before launch" 1 "got=${result}"
	fi
	return 0
}

test_parallel_loop_rest_budget_aborts() {
	_dispatch_process_candidate() {
		return 0
	}
	_dispatch_rest_core_progress_allows_next() {
		return 1
	}

	local candidate_file outcomes_file result
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	printf '%s\n' '{"number":325,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}' >"$candidate_file"
	: >"$outcomes_file"
	rm -f "$STOP_FLAG"
	result=$(_dispatch_max_loop "$candidate_file" 10 10 "test_user" 4 "$outcomes_file")
	rm -f "$candidate_file" "$outcomes_file"
	_dispatch_rest_core_progress_allows_next() {
		return 0
	}

	if [[ "$result" == "0 1" ]]; then
		print_result "parallel_loop: REST launch gate aborts before launch" 0
	else
		print_result "parallel_loop: REST launch gate aborts before launch" 1 "got=${result}"
	fi
	return 0
}

test_dispatch_with_timeout_noop_outcome() {
	local capture_dir old_path rc capture
	capture_dir=$(mktemp -d)
	old_path="$PATH"
	cat >"${capture_dir}/dispatch-timing-helper.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DISPATCH_TIMING_CAPTURE}"
exit 0
EOF
	chmod +x "${capture_dir}/dispatch-timing-helper.sh"
	export PATH="${capture_dir}:$PATH"
	export DISPATCH_TIMING_CAPTURE="${capture_dir}/capture.txt"
	export DISPATCH_TIMING_ADAPTIVE=0
	export DISPATCH_PER_CANDIDATE_TIMEOUT=5
	export DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR=1
	# shellcheck disable=SC2317  # called via _dispatch_with_timeout
	dispatch_with_dedup() {
		return 2
	}
	# shellcheck disable=SC2317  # called via _dispatch_with_timeout
	run_stage_with_timeout() {
		shift 2
		"$@"
		return $?
	}

	rc=0
	_dispatch_with_timeout 330 "o/r" "Issue #330" "title" "me" "/tmp/repo" "prompt" "issue-330" "" || rc=$?
	capture=$(cat "$DISPATCH_TIMING_CAPTURE" 2>/dev/null || true)
	PATH="$old_path"
	export PATH
	unset DISPATCH_TIMING_CAPTURE DISPATCH_TIMING_ADAPTIVE DISPATCH_PER_CANDIDATE_TIMEOUT DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR
	unset -f dispatch_with_dedup run_stage_with_timeout
	rm -rf "$capture_dir"

	if [[ "$rc" -eq 2 && "$capture" == *"--outcome noop"* ]]; then
		print_result "dispatch_with_timeout: rc=2 records noop outcome" 0
	else
		print_result "dispatch_with_timeout: rc=2 records noop outcome" 1 "rc=${rc} capture=${capture}"
	fi
	return 0
}

# =============================================================================
# Test 5: serial loop preserves existing behavior (regression escape hatch)
# =============================================================================
test_serial_loop_basic() {
	# Stub: even numbers succeed, odd fail
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		local candidate_json="$1"
		local issue_num
		issue_num=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
		if (( issue_num % 2 == 0 )); then
			return 0
		fi
		return 1
	}

	local candidate_file
	candidate_file=$(mktemp)
	for i in 400 401 402 403 404; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"

	rm -f "$STOP_FLAG"
	_DISPATCH_THROTTLE_CLEARED=0
	# effective_slots=10 — no budget cap. 5 candidates → 3 even = 3 successes, 2 odd = 2 fails
	local result
	result=$(_dispatch_floor_loop "$candidate_file" 10 10 "test_user")
	rm -f "$candidate_file"

	# Expect "3 5" — dispatched=3, processed=5
	if [[ "$result" == "3 5" ]]; then
		print_result "serial_loop: 3 success + 2 fail = dispatched=3 processed=5" 0
	else
		print_result "serial_loop: 3 success + 2 fail = dispatched=3 processed=5" 1 "got=${result}"
	fi
	return 0
}

test_serial_loop_isolates_candidate_stdout() {
	# Stub: simulate noisy lower helpers before a successful launch. The serial
	# loop must log that output instead of corrupting the count-only stdout
	# consumed by pulse-dispatch-engine.sh.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		local candidate_json="$1"
		printf 'lower-helper stdout before count for %s\n' "$candidate_json"
		return 0
	}

	local candidate_file
	candidate_file=$(mktemp)
	printf '%s\n' '{"number":600,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}' >"$candidate_file"

	rm -f "$STOP_FLAG"
	_DISPATCH_THROTTLE_CLEARED=0
	local result
	result=$(_dispatch_floor_loop "$candidate_file" 10 10 "test_user")
	rm -f "$candidate_file"

	if [[ "$result" == "1 1" ]]; then
		print_result "serial_loop: isolates candidate stdout from count output" 0
	else
		print_result "serial_loop: isolates candidate stdout from count output" 1 "got=${result}"
	fi
	return 0
}

test_serial_loop_budget_cap() {
	# Stub: every candidate succeeds
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		return 0
	}

	local candidate_file
	candidate_file=$(mktemp)
	for i in 500 501 502 503 504; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"

	rm -f "$STOP_FLAG"
	# effective_slots=2 → loop must break after 2 successes (3rd iter starts but dispatched=2 stops it)
	local result
	result=$(_dispatch_floor_loop "$candidate_file" 2 5 "test_user")
	rm -f "$candidate_file"

	# Expect dispatched=2; processed depends on where the budget check fires.
	# Loop: iter 1 (process) → dispatched=1 → iter 2 (process) → dispatched=2 → iter 3 (start)
	# → check dispatched(2) >= effective_slots(2) → break. So processed=3.
	local result_dispatched
	result_dispatched=$(printf '%s' "$result" | awk '{print $1}')
	if [[ "$result_dispatched" == "2" ]]; then
		print_result "serial_loop: respects effective_slots=2 budget" 0
	else
		print_result "serial_loop: respects effective_slots=2 budget" 1 "got=${result_dispatched}"
	fi
	return 0
}

test_serial_loop_allows_unset_stop_flag() {
	# Stub: every candidate succeeds. The serial loop must treat an unset
	# STOP_FLAG as "no stop flag" under set -u, matching the parallel loop and
	# capacity pre-check guards.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		return 0
	}

	local candidate_file old_stop_flag result
	candidate_file=$(mktemp)
	printf '%s\n' '{"number":700,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}' >"$candidate_file"

	old_stop_flag="$STOP_FLAG"
	unset STOP_FLAG || true
	_DISPATCH_THROTTLE_CLEARED=0
	result=$(_dispatch_floor_loop "$candidate_file" 10 10 "test_user")
	export STOP_FLAG="$old_stop_flag"
	rm -f "$candidate_file"

	if [[ "$result" == "1 1" ]]; then
		print_result "serial_loop: unset STOP_FLAG defaults to no stop flag" 0
	else
		print_result "serial_loop: unset STOP_FLAG defaults to no stop flag" 1 "got=${result}"
	fi
	return 0
}

# Exercise reservation admission through the real serial and parallel loops.
test_priority_reservations() {
	local mode="$1" parallel="$2" expected_product="$3" expected_total="$4"
	local candidate_file="" outcomes="" result="" products=0 total=0 complete=true
	local TOOLING_STARTED="${TEST_ROOT}/tooling-${mode}-${parallel}.ready"
	local ACTIVITY="${TEST_ROOT}/priority-${mode}-${parallel}.activity"
	rm -f "$TOOLING_STARTED"
	: >"$ACTIVITY"
	candidate_file=$(mktemp)
	outcomes=$(mktemp)
	jq -nc --arg mode "$mode" '
		[range(1;5) | {number:., repo_slug:"o/tooling", repo_priority:"tooling", labels:
			(if $mode == "urgent" then ["priority:high"] else [] end), simulated_outcome:"success"}] +
		(if $mode == "empty" or $mode == "incomplete" then [] else
		 [range(1;5) | {number:., repo_slug:"o/product", repo_priority:"product", labels:[], simulated_outcome:
			(if $mode == "ineligible" or $mode == "unknown" then $mode
			 elif $mode == "mixed" and . == 1 then "ineligible" else "success" end)}] end) | .[]
	' >"$candidate_file"
	# shellcheck disable=SC2317 # called through the real phase/dispatch loops
	_dispatch_process_candidate() {
		local candidate_json="$1" outcome="" priority="" waits=0
		_DISPATCH_THROTTLE_CLEARED=0
		printf 'start\n' >>"$ACTIVITY"
		outcome=$(jq -r '.simulated_outcome' <<<"$candidate_json")
		priority=$(jq -r '.repo_priority' <<<"$candidate_json")
		if [[ "$mode" == concurrent && "$priority" == product ]]; then
			while [[ ! -f "$TOOLING_STARTED" && "$waits" -lt 300 ]]; do
				sleep 0.01
				waits=$((waits + 1))
			done
			[[ -f "$TOOLING_STARTED" ]] || outcome=unknown
		elif [[ "$priority" == tooling ]]; then
			: >"$TOOLING_STARTED"
		fi
		_DISPATCH_CANDIDATE_ELIGIBILITY="$outcome"
		printf 'end\n' >>"$ACTIVITY"
		[[ "$outcome" == success ]] && return 0
		return 1
	}
	[[ "$mode" != incomplete ]] || complete=false
	result=$(_dispatch_priority_loop "$candidate_file" 4 test_user "$parallel" "$outcomes" 2 "$complete")
	read -r products _ < <(_dispatch_priority_product_outcomes "$outcomes")
	total=$(_dispatch_max_count_outcomes "$outcomes")
	if [[ "$products" == "$expected_product" && "$total" == "$expected_total" && "${result%% *}" == "$total" ]]; then
		print_result "priority_loop: ${mode} parallel=${parallel} product=${products} total=${total}" 0
	else
		print_result "priority_loop: ${mode} parallel=${parallel}" 1 "result=${result} product=${products} total=${total}"
	fi
	local duplicate=0
	duplicate=$(awk -F'|' '{ repo=""; for(i=3;i<=NF;i++) if($i ~ /^repo=/) repo=$i; if(seen[repo "|" $2]++) n++ } END { print n+0 }' "$outcomes")
	if [[ "$duplicate" == 0 ]]; then
		print_result "priority_loop: ${mode} preserves repository identity without duplicate attempts" 0
	else
		print_result "priority_loop: ${mode} duplicate attempts" 1 "duplicates=${duplicate}"
	fi
	local peak=0
	peak=$(awk '$0=="start" { n++; if(n>peak) peak=n } $0=="end" { n-- } END { print peak+0 }' "$ACTIVITY")
	((peak <= parallel)) && print_result "priority_loop: ${mode} combined concurrency is bounded" 0 ||
		print_result "priority_loop: ${mode} exceeded shared parallelism" 1 "peak=${peak} cap=${parallel}"
	rm -f "$candidate_file" "$outcomes"
	return 0
}

test_priority_verified_occupancy() {
	local REPOS_JSON="${TEST_ROOT}/priority-repos.json"
	local AIDEVOPS_DISPATCH_LEDGER_DIR="${TEST_ROOT}/priority-ledger"
	local PRODUCT_RESERVATION_PCT=60
	mkdir -p "$AIDEVOPS_DISPATCH_LEDGER_DIR"
	printf '%s\n' '{"initialized_repos":[{"slug":"o/product","pulse":true,"priority":"product"}]}' >"$REPOS_JSON"
	jq -nc --argjson pid "$$" --argjson expires "$(($(date +%s) + 600))" '
		{session_key:"active",pid:$pid,owner_process_start:"fixture-start",status:"in-flight",lease_phase:"ready",lease_expires_at:$expires,repo_slug:"o/product"} as $row |
		$row, ($row + {session_key:"duplicate-pid"}), ($row + {session_key:"reused-pid",owner_process_start:"wrong"}),
		($row + {session_key:"dead",pid:99999999}), ($row + {session_key:"finished",status:"completed"})
	' >"$AIDEVOPS_DISPATCH_LEDGER_DIR/dispatch-ledger.jsonl"
	_process_start_token() { local pid="$1"; : "$pid"; printf 'fixture-start\n'; return 0; }
	local slots=""
	slots=$(_dispatch_product_reservation_slots 10 3 7)
	if [[ "$slots" == 5 ]]; then
		print_result "priority_capacity: subtracts verified distinct live product workers only" 0
	else
		print_result "priority_capacity: verified occupancy" 1 "slots=${slots} expected=5"
	fi
	slots=$(_dispatch_product_reservation_slots 10 0 4)
	[[ "$slots" == 4 ]] && print_result "priority_capacity: clamps reservations to available capacity" 0 ||
		print_result "priority_capacity: available clamp" 1 "slots=${slots}"
	PRODUCT_RESERVATION_PCT=0
	slots=$(_dispatch_product_reservation_slots 10 3 7)
	[[ "$slots" == 0 ]] && print_result "priority_capacity: honours disabled reservation" 0 ||
		print_result "priority_capacity: zero percent" 1 "slots=${slots}"
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================
test_compute_max_parallel_default
test_compute_max_parallel_default_caps_at_slots
test_compute_max_parallel_override
test_compute_max_parallel_caps_at_slots
test_compute_max_parallel_throttle_forces_serial
test_compute_max_parallel_invalid_var
test_compute_max_parallel_rest_reserve_forces_serial
test_count_outcomes_success_and_fail
test_count_outcomes_empty_file
test_wait_tracked_pids_suppresses_stale_child
test_aggregate_outcomes_basic
test_aggregate_outcomes_invalidates_canary_cache
test_aggregate_outcomes_clears_throttle_on_success
test_parallel_loop_end_to_end
test_parallel_loop_respects_budget
test_parallel_loop_refills_rejected_reservation
test_parallel_loop_all_rejections_finish
test_parallel_loop_stop_flag_aborts
test_parallel_loop_graphql_budget_aborts
test_parallel_loop_rest_budget_aborts
test_dispatch_with_timeout_noop_outcome
test_serial_loop_basic
test_serial_loop_isolates_candidate_stdout
test_serial_loop_budget_cap
test_serial_loop_allows_unset_stop_flag
test_priority_reservations normal 1 2 4
test_priority_reservations normal 3 2 4
test_priority_reservations concurrent 3 2 4
test_priority_reservations mixed 3 2 4
test_priority_reservations ineligible 3 0 4
test_priority_reservations unknown 3 0 2
test_priority_reservations empty 3 0 4
test_priority_reservations incomplete 3 0 2
test_priority_reservations urgent 3 0 4
test_priority_verified_occupancy

# Final summary
echo ""
echo "===================="
echo "Tests run: $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"
echo "===================="
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
else
	exit 1
fi
