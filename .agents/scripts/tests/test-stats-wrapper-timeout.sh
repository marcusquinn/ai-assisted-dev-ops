#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#29836: stats-wrapper.sh must enforce its hard
# ceiling within the current scheduler invocation and preserve successor PID
# ownership during EXIT-trap cleanup.

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
STATS_TIMEOUT=1
_stats_wrapper_run_work() {
	case "$mode" in
	timeout)
		printf '%s\\n' "\$BASHPID" >"\$HARNESS_TEMP_DIR/child.pid"
		sleep 30
		;;
	normal)
		return 0
		;;
	esac
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

main_test() {
	test_timeout_kills_work_and_cleans_pidfile
	test_normal_completion_cleans_pidfile
	test_cleanup_preserves_successor_pidfile
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main_test "$@"
