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
deadline | function-timeout | work-health-failure | work-healthy) STATS_TIMEOUT=60 ;;
*) STATS_TIMEOUT=1 ;;
esac
if [[ "$mode" != "work-health-failure" && "$mode" != "work-healthy" ]]; then
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
fi
_stats_test_slow_function() {
	sleep 30
	return 0
}
case "$mode" in
work-health-failure | work-healthy)
	STATS_TEST_HEALTH_RESULT="$mode"
	cat >"\$HARNESS_TEMP_DIR/stats-functions.sh" <<'STATS_FUNCTIONS'
update_health_issues() {
	printf 'health\n' >>"\$HARNESS_TEMP_DIR/calls"
	if [[ "\$STATS_TEST_HEALTH_RESULT" == "work-health-failure" ]]; then
		return 124
	fi
	return 0
}
run_daily_quality_sweep() {
	printf 'sweep\n' >>"\$HARNESS_TEMP_DIR/calls"
	return 0
}
STATS_FUNCTIONS
	SCRIPT_DIR="\$HARNESS_TEMP_DIR"
	;;
esac
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

test_failed_health_update_still_runs_quality_sweep_once() {
	local temp_dir="" rc="" calls=""
	temp_dir=$(run_harness work-health-failure) || {
		fail "failed health harness starts" "could not create harness"
		return 0
	}
	rc=$(<"$temp_dir/rc")
	calls=$(<"$temp_dir/calls")
	if [[ "$rc" -ne 124 ]]; then
		fail "failed health update preserves its exit status" "got rc=$rc"
	elif [[ "$calls" != $'health\nsweep' ]]; then
		fail "failed health update runs one quality sweep after health" "calls=$calls"
	elif ! grep -q 'HEALTH-DASHBOARD-FAIL exit=124' "$temp_dir/stats.log"; then
		fail "failed health update preserves dashboard diagnostics" "missing health failure log"
	else
		pass "failed health update runs one quality sweep after health"
	fi
	rm -rf "$temp_dir"
	return 0
}

test_healthy_update_runs_health_then_quality_once() {
	local temp_dir="" rc="" calls=""
	temp_dir=$(run_harness work-healthy) || {
		fail "healthy work harness starts" "could not create harness"
		return 0
	}
	rc=$(<"$temp_dir/rc")
	calls=$(<"$temp_dir/calls")
	if [[ "$rc" -ne 0 ]]; then
		fail "healthy work completes" "got rc=$rc"
	elif [[ "$calls" != $'health\nsweep' ]]; then
		fail "healthy work runs health then one quality sweep" "calls=$calls"
	else
		pass "healthy work runs health then one quality sweep"
	fi
	rm -rf "$temp_dir"
	return 0
}

test_resumable_quality_batches() {
	local batch_home
	batch_home=$(mktemp -d "${TMPDIR:-/tmp}/stats-resume.XXXXXX") || return 1
	if (
		export HOME="$batch_home" LOGFILE="$batch_home/stats.log"
		export QUALITY_SWEEP_STATE_DIR="$batch_home/state" QUALITY_SWEEP_LAST_RUN="$batch_home/last-run"
		export QUALITY_SWEEP_REPO_TIMEOUT=3
		local scripts="${SCRIPT_DIR}/.."
		local SCRIPT_DIR="$scripts"
		# shellcheck source=../shared-constants.sh
		source "$scripts/shared-constants.sh"
		# shellcheck source=../worker-lifecycle-common.sh
		source "$scripts/worker-lifecycle-common.sh"
		# shellcheck source=../stats-functions.sh
		source "$scripts/stats-functions.sh"
		_quality_sweep_for_repo() {
			printf '%s\n' "$1" >>"$HOME/attempts"
			if [[ "$1" == owner/a ]]; then
				printf '%s\n' "$TMPDIR" >"$HOME/scratch"
				sleep 30 &
				printf '%s\n' "$!" >"$HOME/descendant"
				wait "$!"
			fi
			return 0
		}
		local entries=$'owner/a|/a\nowner/b|/b\nowner/c|/c' now descendant scratch
		now=$(date +%s)
		_quality_sweep_batch "$entries" tester "$((now + 5))" || exit 1
		[[ ! -f "$QUALITY_SWEEP_LAST_RUN" ]] || exit 2
		jq -e '.remaining == 2 and .complete == false and .visited == ["owner/a|/a"]' "$QUALITY_SWEEP_STATE_DIR/cursor.json" || {
			jq . "$QUALITY_SWEEP_STATE_DIR/cursor.json"
			exit 3
		}
		descendant=$(<"$HOME/descendant")
		if kill -0 "$descendant" 2>/dev/null; then
			# Some hosts briefly retain reparented zombies; they cannot run work.
			[[ "$(ps -p "$descendant" -o stat=)" == *Z* ]] || exit 4
		fi
		scratch=$(<"$HOME/scratch")
		[[ ! -d "$scratch" ]] || exit 5
		grep -q 'rc=124' "$LOGFILE" || exit 6
		# Config changes: retain progress, remove c, and add d without losing it.
		now=$(date +%s)
		_quality_sweep_batch $'owner/a|/a\nowner/b|/b\nowner/d|/d' tester "$((now + 10))" || exit 7
		[[ "$(<"$HOME/attempts")" == $'owner/a\nowner/b\nowner/d' ]] || exit 8
		[[ -s "$QUALITY_SWEEP_LAST_RUN" ]] || exit 9
		jq -e '.complete == true and .remaining == 0' "$QUALITY_SWEEP_STATE_DIR/cursor.json" || exit 10
		# A completed cycle must not skip the next day; corrupt state also resets.
		_quality_sweep_batch 'owner/b|/b' tester "$((now + 10))" || exit 11
		printf 'corrupt\n' >"$QUALITY_SWEEP_STATE_DIR/cursor.json"
		_quality_sweep_batch 'owner/d|/d' tester "$((now + 10))" || exit 12
		[[ "$(<"$HOME/attempts")" == $'owner/a\nowner/b\nowner/d\nowner/b\nowner/d' ]] || exit 13
		_batch_failure() { return 75; }
		local failure=0
		_stats_run_bounded 1 "$((now + 10))" _batch_failure || failure=$?
		[[ "$failure" -eq 75 ]] || exit 14
		# Expired admission must not invoke work or advance the cursor.
		_quality_sweep_batch 'owner/e|/e' tester "$now" || exit 15
		jq -e '.visited == [] and .remaining == 1' "$QUALITY_SWEEP_STATE_DIR/cursor.json" || exit 16
		_test_stats_preflight_deadlines || exit 17
	); then
		pass "quality batches resume, reconcile configuration, bound descendants and retain diagnostics"
	else
		fail "quality batches resume, reconcile configuration, bound descendants and retain diagnostics" "fixture exit=$?"
	fi
	rm -rf "$batch_home"
	return 0
}

_test_stats_preflight_deadlines() {
	local REPOS_JSON="$HOME/repos.json" start elapsed
	local STATS_OPTIONAL_WORK_RESERVE_SECONDS=0 QUALITY_SWEEP_CLEANUP_RESERVE_SECONDS=0
	local QUALITY_SWEEP_OFFPEAK=0 QUALITY_SWEEP_INTERVAL=0 AIDEVOPS_GH_DEADLINE_EPOCH
	# Both public paths must bound raw permission lookups, not just tool runs.
	jq -n --arg path "$HOME" '{initialized_repos:[{slug:"owner/slow",path:$path,pulse:true}]}' >"$REPOS_JSON"
	gh() { return 0; }
	aidevops_repo_state_current_user() { printf 'tester\n'; return 0; }
	aidevops_can_run_repo_routines() { sleep 30; return 0; }
	start=$(date +%s)
	AIDEVOPS_GH_DEADLINE_EPOCH=$((start + 5))
	update_health_issues || return 1
	elapsed=$(($(date +%s) - start))
	[[ "$elapsed" -lt 6 ]] || return 2
	grep -q 'Health dashboard permission preflight deferred/failed' "$LOGFILE" || return 3
	start=$(date +%s)
	AIDEVOPS_GH_DEADLINE_EPOCH=$((start + 5))
	run_daily_quality_sweep || return 4
	elapsed=$(($(date +%s) - start))
	[[ "$elapsed" -lt 6 ]] || return 5
	grep -q 'Quality sweep permission preflight deferred/failed' "$LOGFILE" || return 6
	return 0
}

main_test() {
	test_timeout_kills_work_and_cleans_pidfile
	test_normal_completion_cleans_pidfile
	test_cleanup_preserves_successor_pidfile
	test_stats_child_receives_aggregate_gh_deadline
	test_function_write_times_out_before_outer_ceiling
	test_failed_health_update_still_runs_quality_sweep_once
	test_healthy_update_runs_health_then_quality_once
	test_resumable_quality_batches
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main_test "$@"
