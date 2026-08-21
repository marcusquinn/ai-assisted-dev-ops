#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#29836 and GH#30546: stats-wrapper.sh must enforce its
# hard ceiling within the current scheduler invocation, propagate an aggregate
# GitHub deadline, and preserve successor PID ownership during EXIT cleanup.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../stats-wrapper.sh"

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

run_harness() {
	local mode="$1"
	local harness="" output="" rc=0
	harness=$(mktemp "${TMPDIR:-/tmp}/stats-wrapper-timeout-XXXXXX") || return 1
	cat >"$harness" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail
source "$WRAPPER_SCRIPT"
STATS_PIDFILE="\$1/stats.pid"
STATS_LOGFILE="\$1/stats.log"
HARNESS_TEMP_DIR="\$1"
case "$mode" in
deadline | function-timeout) STATS_TIMEOUT=60 ;;
*) STATS_TIMEOUT=1 ;;
esac
_stats_wrapper_run_work() {
	case "$mode" in
	timeout)
		printf '%s\\n' "\$BASHPID" >"\$HARNESS_TEMP_DIR/child.pid"
		sleep 30
		;;
	normal)
		return 0
		;;
	deadline)
		printf '%s\n' "\${AIDEVOPS_GH_DEADLINE_EPOCH:-}" >"\$HARNESS_TEMP_DIR/gh-deadline"
		return 0
		;;
	function-timeout)
		AIDEVOPS_GH_WRITE_TIMEOUT=1 _gh_with_timeout write _stats_test_slow_function
		return \$?
		;;
	esac
	return 0
}
_stats_test_slow_function() {
	sleep 30
	return 0
}
main
HARNESS
	chmod +x "$harness"
	local temp_dir=""
	temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/stats-wrapper-timeout-dir-XXXXXX") || {
		rm -f "$harness"
		return 1
	}
	output=$(timeout 12 bash "$harness" "$temp_dir" 2>&1) || rc=$?
	printf '%s\n' "$rc" >"$temp_dir/rc"
	printf '%s\n' "$output" >"$temp_dir/output"
	printf '%s\n' "$temp_dir"
	rm -f "$harness"
	return 0
}

test_timeout_kills_work_and_cleans_pidfile() {
	local temp_dir="" rc="" child_pid=""
	temp_dir=$(run_harness timeout) || {
		fail "timeout harness starts" "could not create harness"
		return 0
	}
	rc=$(<"$temp_dir/rc")
	if [[ "$rc" -ne 124 ]]; then
		fail "timeout returns 124" "got rc=$rc"
	elif [[ -f "$temp_dir/stats.pid" ]]; then
		fail "timeout cleans its PID file" "pidfile remains"
	elif ! grep -q 'STATS-TIMEOUT' "$temp_dir/stats.log" || ! grep -q 'HEALTH-DASHBOARD-FAIL exit=124' "$temp_dir/stats.log"; then
		fail "timeout emits terminal diagnostics" "missing timeout or EXIT-trap record"
	elif [[ ! -f "$temp_dir/child.pid" ]]; then
		fail "timeout starts bounded child" "child PID was not recorded"
	else
		child_pid=$(<"$temp_dir/child.pid")
		if kill -0 "$child_pid" 2>/dev/null; then
			fail "timeout terminates wrapper child" "child $child_pid remains alive"
		else
			pass "timeout kills work, cleans PID file, and records terminal diagnostics"
		fi
	fi
	rm -rf "$temp_dir"
	return 0
}

test_normal_completion_cleans_pidfile() {
	local temp_dir="" rc=""
	temp_dir=$(run_harness normal) || {
		fail "normal harness starts" "could not create harness"
		return 0
	}
	rc=$(<"$temp_dir/rc")
	if [[ "$rc" -eq 0 ]] && [[ ! -f "$temp_dir/stats.pid" ]] && grep -q 'Finished' "$temp_dir/stats.log"; then
		pass "healthy run completes and cleans its PID file"
	else
		fail "healthy run completes and cleans its PID file" "rc=$rc, pidfile=$([[ -f "$temp_dir/stats.pid" ]] && printf present || printf absent)"
	fi
	rm -rf "$temp_dir"
	return 0
}

test_cleanup_preserves_successor_pidfile() {
	local temp_dir=""
	temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/stats-wrapper-ownership-XXXXXX") || {
		fail "ownership harness starts" "could not create temp directory"
		return 0
	}
	if bash -c "source '$WRAPPER_SCRIPT'; STATS_PIDFILE='$temp_dir/stats.pid'; printf '%s %s\\n' 999999 1 >\"\$STATS_PIDFILE\"; _stats_wrapper_remove_own_pidfile; test -f \"\$STATS_PIDFILE\""; then
		pass "EXIT cleanup preserves a successor PID file"
	else
		fail "EXIT cleanup preserves a successor PID file" "cleanup removed a foreign PID file"
	fi
	rm -rf "$temp_dir"
	return 0
}

test_stats_child_receives_aggregate_gh_deadline() {
	local temp_dir="" rc="" deadline="" now=""
	temp_dir=$(run_harness deadline) || {
		fail "deadline harness starts" "could not create harness"
		return 0
	}
	rc=$(<"$temp_dir/rc")
	deadline=$(<"$temp_dir/gh-deadline")
	now=$(date +%s)
	if [[ "$rc" -ne 0 ]]; then
		fail "stats child receives aggregate GitHub deadline" "got rc=$rc"
	elif [[ ! "$deadline" =~ ^[0-9]+$ ]]; then
		fail "stats child receives aggregate GitHub deadline" "deadline is not numeric: $deadline"
	elif [[ "$deadline" -le "$now" || "$deadline" -gt $((now + 35)) ]]; then
		fail "stats child receives aggregate GitHub deadline" "deadline $deadline is outside the reserved budget"
	else
		pass "stats child receives aggregate GitHub deadline"
	fi
	rm -rf "$temp_dir"
	return 0
}

test_function_write_times_out_before_outer_ceiling() {
	local temp_dir="" rc=""
	temp_dir=$(run_harness function-timeout) || {
		fail "function-timeout harness starts" "could not create harness"
		return 0
	}
	rc=$(<"$temp_dir/rc")
	if [[ "$rc" -ne 124 ]]; then
		fail "function write respects per-operation timeout" "got rc=$rc"
	elif grep -q 'STATS-TIMEOUT' "$temp_dir/stats.log"; then
		fail "function write respects per-operation timeout" "outer stats ceiling fired"
	else
		pass "function write respects per-operation timeout"
	fi
	rm -rf "$temp_dir"
	return 0
}

main_test() {
	test_timeout_kills_work_and_cleans_pidfile
	test_normal_completion_cleans_pidfile
	test_cleanup_preserves_successor_pidfile
	test_stats_child_receives_aggregate_gh_deadline
	test_function_write_times_out_before_outer_ceiling
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main_test "$@"
