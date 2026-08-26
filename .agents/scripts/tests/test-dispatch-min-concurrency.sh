#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-min-concurrency.sh — t3418 regression tests for the minimum
# pulse worker concurrency floor under runtime launch throttling.

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

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/headless-runtime"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export STOP_FLAG="${HOME}/.aidevops/logs/stop"
: >"$LOGFILE"

TEST_BIN="${TEST_ROOT}/bin"
mkdir -p "$TEST_BIN"
cat >"${TEST_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "-i" && "$3" == "user" ]]; then
	printf 'HTTP/2 200\r\nx-ratelimit-resource: core\r\nx-ratelimit-limit: 5000\r\nx-ratelimit-remaining: 4999\r\nx-ratelimit-reset: 1789999999\r\n\r\n{}\n'
	exit 0
fi
printf '{}\n'
exit 0
EOF
chmod +x "${TEST_BIN}/gh"
export PATH="${TEST_BIN}:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../pulse-capacity.sh
source "${SCRIPT_DIR}/pulse-capacity.sh"
# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPT_DIR}/pulse-dispatch-worker-launch.sh"

get_max_workers_target() {
	printf '%s\n' "${TEST_MAX_WORKERS:-1}"
	return 0
}

count_active_workers() {
	if [[ -n "${TEST_ACTIVE_WORKERS_SEQUENCE_FILE:-}" && -f "$TEST_ACTIVE_WORKERS_SEQUENCE_FILE" ]]; then
		local next remaining_file
		next=$(awk 'NR==1 {print; exit}' "$TEST_ACTIVE_WORKERS_SEQUENCE_FILE" 2>/dev/null)
		remaining_file="${TEST_ACTIVE_WORKERS_SEQUENCE_FILE}.next"
		awk 'NR>1 {print}' "$TEST_ACTIVE_WORKERS_SEQUENCE_FILE" >"$remaining_file" 2>/dev/null || : >"$remaining_file"
		mv "$remaining_file" "$TEST_ACTIVE_WORKERS_SEQUENCE_FILE"
		[[ -n "$next" ]] || next="${TEST_ACTIVE_WORKERS:-0}"
		printf '%s\n' "$next"
		return 0
	fi
	if [[ -n "${TEST_ACTIVE_WORKERS_SEQUENCE:-}" ]]; then
		local next="${TEST_ACTIVE_WORKERS_SEQUENCE%% *}"
		if [[ "$TEST_ACTIVE_WORKERS_SEQUENCE" == *" "* ]]; then
			TEST_ACTIVE_WORKERS_SEQUENCE="${TEST_ACTIVE_WORKERS_SEQUENCE#* }"
		else
			TEST_ACTIVE_WORKERS_SEQUENCE=""
		fi
		printf '%s\n' "$next"
		return 0
	fi
	printf '%s\n' "${TEST_ACTIVE_WORKERS:-0}"
	return 0
}

reset_capacity_pressure_env() {
	unset PULSE_DISPATCH_CAPACITY_PROVIDER PULSE_DISPATCH_CAPACITY_MODEL PULSE_MODEL || true
	unset PULSE_DISPATCH_STAGGER_LOAD_PER_CPU PULSE_DISPATCH_STAGGER_RECENT_FAILURES || true
	unset PULSE_DISPATCH_STAGGER_RECENT_RATE_LIMITS PULSE_DISPATCH_PROVIDER_BACKOFF_ACTIVE || true
	unset PULSE_DISPATCH_CAPACITY_RECENT_FAILURES PULSE_DISPATCH_CAPACITY_RECENT_RATE_LIMITS || true
	unset PULSE_DISPATCH_CAPACITY_RECENT_SERVICE_INTERRUPTS || true
	unset PULSE_DISPATCH_CAPACITY_RECENT_PROVIDER_5XX || true
	unset PULSE_DISPATCH_CAPACITY_RECENT_PROGRESS_HEARTBEATS || true
	unset PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER PULSE_DISPATCH_OAUTH_POOL_FILE || true
	unset -f config_get 2>/dev/null || true
	rm -f "${HOME}/.aidevops/oauth-pool.json"
	return 0
}

test_capacity_raises_soft_cap_to_floor() {
	reset_capacity_pressure_env
	TEST_MAX_WORKERS=1
	TEST_ACTIVE_WORKERS=2
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	unset _DISPATCH_MIN_WORKER_FLOOR_ACTIVE || true
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "6 2 4" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" == "1" ]]; then
		print_result "capacity: raises max_workers to floor while active below floor" 0
	else
		print_result "capacity: raises max_workers to floor while active below floor" 1 "result=${result} floor_active=${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-unset}"
	fi
	return 0
}

test_capacity_reads_min_floor_from_config_default() {
	reset_capacity_pressure_env
	TEST_MAX_WORKERS=1
	TEST_ACTIVE_WORKERS=2
	unset AIDEVOPS_MIN_WORKER_CONCURRENCY || true
	config_get() {
		local dotpath="$1" default="${2:-}"
		if [[ "$dotpath" == "orchestration.min_worker_concurrency" ]]; then
			printf '7\n'
		else
			printf '%s\n' "$default"
		fi
		return 0
	}
	unset _DISPATCH_MIN_WORKER_FLOOR_ACTIVE || true
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "7 2 5" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" == "1" ]]; then
		print_result "capacity: reads minimum worker floor from config default" 0
	else
		print_result "capacity: reads minimum worker floor from config default" 1 "result=${result} floor_active=${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-unset}"
	fi
	unset -f config_get 2>/dev/null || true
	return 0
}

test_capacity_respects_existing_higher_cap() {
	reset_capacity_pressure_env
	TEST_MAX_WORKERS=10
	TEST_ACTIVE_WORKERS=2
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	unset _DISPATCH_MIN_WORKER_FLOOR_ACTIVE || true
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "10 2 8" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" == "1" ]]; then
		print_result "capacity: existing max cap still wins above floor" 0
	else
		print_result "capacity: existing max cap still wins above floor" 1 "result=${result} floor_active=${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-unset}"
	fi
	return 0
}

test_capacity_high_load_is_advisory_only() {
	reset_capacity_pressure_env
	TEST_MAX_WORKERS=12
	TEST_ACTIVE_WORKERS=1
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	PULSE_DISPATCH_STAGGER_LOAD_PER_CPU=99
	unset _DISPATCH_MIN_WORKER_FLOOR_ACTIVE || true
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "12 1 11" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" == "1" ]]; then
		print_result "capacity: high load remains advisory and preserves healthy floor" 0
	else
		print_result "capacity: high load remains advisory and preserves healthy floor" 1 "result=${result} floor_active=${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-unset}"
	fi
	return 0
}

test_capacity_uses_configured_provider_account_multiplier() {
	reset_capacity_pressure_env
	TEST_MAX_WORKERS=10
	TEST_ACTIVE_WORKERS=1
	AIDEVOPS_MIN_WORKER_CONCURRENCY=0
	PULSE_MODEL="openai/gpt-5.5"
	cat >"${HOME}/.aidevops/oauth-pool.json" <<'JSON'
{"openai":[{"status":"idle"}]}
JSON
	config_get() {
		local dotpath="$1" default="${2:-}"
		if [[ "$dotpath" == "orchestration.provider_account_slot_multiplier" ]]; then
			printf '4\n'
		else
			printf '%s\n' "$default"
		fi
		return 0
	}
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "4 1 3" ]]; then
		print_result "capacity: config multiplier caps provider account slots" 0
	else
		print_result "capacity: config multiplier caps provider account slots" 1 "result=${result}"
	fi
	return 0
}

test_capacity_env_multiplier_overrides_config() {
	reset_capacity_pressure_env
	TEST_MAX_WORKERS=10
	TEST_ACTIVE_WORKERS=1
	AIDEVOPS_MIN_WORKER_CONCURRENCY=0
	PULSE_MODEL="openai/gpt-5.5"
	PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER=3
	cat >"${HOME}/.aidevops/oauth-pool.json" <<'JSON'
{"openai":[{"status":"idle"}]}
JSON
	config_get() {
		local dotpath="$1" default="${2:-}"
		if [[ "$dotpath" == "orchestration.provider_account_slot_multiplier" ]]; then
			printf '4\n'
		else
			printf '%s\n' "$default"
		fi
		return 0
	}
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "3 1 2" ]]; then
		print_result "capacity: env multiplier overrides config multiplier" 0
	else
		print_result "capacity: env multiplier overrides config multiplier" 1 "result=${result}"
	fi
	return 0
}

test_capacity_defaults_single_account_to_max_cap() {
	reset_capacity_pressure_env
	TEST_MAX_WORKERS=24
	TEST_ACTIVE_WORKERS=0
	AIDEVOPS_MIN_WORKER_CONCURRENCY=0
	local provider result capacity_file failures
	failures=0
	for provider in openai anthropic; do
		reset_capacity_pressure_env
		TEST_MAX_WORKERS=24
		TEST_ACTIVE_WORKERS=0
		AIDEVOPS_MIN_WORKER_CONCURRENCY=0
		PULSE_MODEL="${provider}/test-model"
		cat >"${HOME}/.aidevops/oauth-pool.json" <<JSON
{"${provider}":[{"status":"idle"}]}
JSON
		capacity_file=$(mktemp)
		_dispatch_compute_capacity >"$capacity_file"
		result=$(<"$capacity_file")
		rm -f "$capacity_file"
		if [[ "$result" != "24 0 24" ]]; then
			failures=$((failures + 1))
		fi
	done
	if [[ "$failures" -eq 0 ]]; then
		print_result "capacity: one healthy account defaults to max cap for OpenAI and Anthropic" 0
	else
		print_result "capacity: one healthy account defaults to max cap for OpenAI and Anthropic" 1 "failures=${failures} last_result=${result}"
	fi
	return 0
}

test_capacity_recent_service_interruptions_reduce_slots() {
	reset_capacity_pressure_env
	TEST_MAX_WORKERS=12
	TEST_ACTIVE_WORKERS=1
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	PULSE_DISPATCH_CAPACITY_RECENT_SERVICE_INTERRUPTS=1
	unset _DISPATCH_MIN_WORKER_FLOOR_ACTIVE || true
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "6 1 5" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" == "0" ]]; then
		print_result "capacity: service interruption pressure halves launch target" 0
	else
		print_result "capacity: service interruption pressure halves launch target" 1 "result=${result} floor_active=${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-unset}"
	fi
	return 0
}

test_capacity_recent_progress_gets_runway_under_pressure() {
	reset_capacity_pressure_env
	TEST_MAX_WORKERS=12
	TEST_ACTIVE_WORKERS=4
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	PULSE_DISPATCH_CAPACITY_RECENT_SERVICE_INTERRUPTS=1
	PULSE_DISPATCH_CAPACITY_RECENT_PROGRESS_HEARTBEATS=2
	unset _DISPATCH_MIN_WORKER_FLOOR_ACTIVE || true
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "4 4 0" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" == "0" ]]; then
		print_result "capacity: progressing active workers get runway under pressure" 0
	else
		print_result "capacity: progressing active workers get runway under pressure" 1 "result=${result} floor_active=${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-unset}"
	fi
	return 0
}

test_capacity_clamps_provider_cap_below_active_to_zero_available() {
	(
		reset_capacity_pressure_env
		TEST_MAX_WORKERS=8
		TEST_ACTIVE_WORKERS=4
		AIDEVOPS_MIN_WORKER_CONCURRENCY=6
		pulse_apply_provider_load_capacity_cap() {
			printf '1 0\n'
			return 0
		}
		unset _DISPATCH_MIN_WORKER_FLOOR_ACTIVE || true
		local result capacity_file
		capacity_file=$(mktemp)
		_dispatch_compute_capacity >"$capacity_file"
		result=$(<"$capacity_file")
		rm -f "$capacity_file"
		if [[ "$result" == "1 4 0" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" == "0" ]]; then
			return 0
		fi
		printf 'result=%s floor_active=%s\n' "$result" "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-unset}" >"${TEST_ROOT}/capacity-clamp-failure.txt"
		return 1
	)
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "capacity: provider cap below active clamps available to zero" 0
	else
		print_result "capacity: provider cap below active clamps available to zero" 1 "$(<"${TEST_ROOT}/capacity-clamp-failure.txt")"
	fi
	return 0
}

test_throttle_does_not_force_serial_under_floor() {
	reset_capacity_pressure_env
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	: >"$_DISPATCH_THROTTLE_FILE"
	_DISPATCH_MIN_WORKER_FLOOR_ACTIVE=1
	unset DISPATCH_MAX_PARALLEL || true
	local result
	result=$(_dispatch_max_compute_parallel 6)
	rm -f "$_DISPATCH_THROTTLE_FILE"
	if [[ "$result" == "6" ]]; then
		print_result "parallel: throttle remains soft under minimum floor" 0
	else
		print_result "parallel: throttle remains soft under minimum floor" 1 "got=${result}"
	fi
	return 0
}

test_throttle_forces_serial_above_floor() {
	reset_capacity_pressure_env
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	: >"$_DISPATCH_THROTTLE_FILE"
	_DISPATCH_MIN_WORKER_FLOOR_ACTIVE=0
	unset DISPATCH_MAX_PARALLEL || true
	local result
	result=$(_dispatch_max_compute_parallel 6)
	rm -f "$_DISPATCH_THROTTLE_FILE"
	if [[ "$result" == "1" ]]; then
		print_result "parallel: throttle still forces serial outside floor" 0
	else
		print_result "parallel: throttle still forces serial outside floor" 1 "got=${result}"
	fi
	return 0
}

test_canary_preflight_marks_floor_without_cpu_bypass() {
	local fake_helper worker_log
	fake_helper="${TEST_ROOT}/fake-headless-runtime-helper.sh"
	worker_log="${TEST_ROOT}/worker.log"
	cat >"$fake_helper" <<'EOF'
#!/usr/bin/env bash
printf 'skip_overload=%s min_floor=%s\n' \
	"${AIDEVOPS_SKIP_CANARY_OVERLOAD_CHECK:-}" \
	"${AIDEVOPS_MIN_WORKER_FLOOR_BYPASS_ACTIVE:-}"
exit 0
EOF
	chmod +x "$fake_helper"
	HEADLESS_RUNTIME_HELPER="$fake_helper"
	unset AIDEVOPS_SKIP_CANARY_OVERLOAD_CHECK AIDEVOPS_MIN_WORKER_FLOOR_BYPASS_ACTIVE || true
	TEST_ACTIVE_WORKERS=5
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	: >"$worker_log"
	_dlw_canary_preflight 100 "o/r" "$worker_log" "standard" "" >/dev/null 2>&1 || true
	if grep -q 'skip_overload= min_floor=1' "$worker_log" 2>/dev/null; then
		print_result "canary: minimum floor no longer sets CPU/load bypass" 0
	else
		print_result "canary: minimum floor no longer sets CPU/load bypass" 1 "log=$(cat "$worker_log" 2>/dev/null)"
	fi
	unset AIDEVOPS_SKIP_CANARY_OVERLOAD_CHECK AIDEVOPS_MIN_WORKER_FLOOR_BYPASS_ACTIVE || true
	TEST_ACTIVE_WORKERS=6
	: >"$worker_log"
	_dlw_canary_preflight 101 "o/r" "$worker_log" "standard" "" >/dev/null 2>&1 || true
	if grep -q 'skip_overload= min_floor=' "$worker_log" 2>/dev/null; then
		print_result "canary: at floor runs without CPU/load bypass marker" 0
	else
		print_result "canary: at floor runs without CPU/load bypass marker" 1 "log=$(cat "$worker_log" 2>/dev/null)"
	fi
	return 0
}

test_prebootstrap_ignores_deprecated_load_threshold() {
	if (
		_dlw_blocked_by_hard_stop() { return 1; }
		_dlw_opencode_storage_preflight() { return 0; }
		_dlw_hold_repeated_recovery_failures() { return 1; }
		AIDEVOPS_DISPATCH_LOAD_PREFLIGHT=1
		AIDEVOPS_DISPATCH_MAX_LOAD_PER_CPU=0
		_dlw_prebootstrap_gates 104 "o/r" '{}' "$TEST_ROOT"
	); then
		print_result "prebootstrap: deprecated load threshold cannot block dispatch" 0
	else
		print_result "prebootstrap: deprecated load threshold cannot block dispatch" 1
	fi
	return 0
}

test_apply_dispatch_refills_until_active_floor_after_partial_launch() {
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	TEST_ACTIVE_WORKERS_SEQUENCE_FILE="${TEST_ROOT}/active-sequence.txt"
	TEST_DISPATCH_CALLS_FILE="${TEST_ROOT}/dispatch-calls.txt"
	TEST_DISPATCH_RETURNS_FILE="${TEST_ROOT}/dispatch-returns.txt"
	printf '%s\n%s\n' 4 6 >"$TEST_ACTIVE_WORKERS_SEQUENCE_FILE"
	printf '%s\n' 0 >"$TEST_DISPATCH_CALLS_FILE"
	printf '%s\n%s\n' 1 2 >"$TEST_DISPATCH_RETURNS_FILE"
	AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS=1
	STOP_FLAG="${HOME}/.aidevops/logs/stop"
	# shellcheck disable=SC2329  # Override sourced function for this regression.
	dispatch_max() {
		local calls next remaining_file
		calls=$(<"$TEST_DISPATCH_CALLS_FILE")
		[[ "$calls" =~ ^[0-9]+$ ]] || calls=0
		printf '%s\n' "$((calls + 1))" >"$TEST_DISPATCH_CALLS_FILE"
		next=$(awk 'NR==1 {print; exit}' "$TEST_DISPATCH_RETURNS_FILE" 2>/dev/null)
		remaining_file="${TEST_DISPATCH_RETURNS_FILE}.next"
		awk 'NR>1 {print}' "$TEST_DISPATCH_RETURNS_FILE" >"$remaining_file" 2>/dev/null || : >"$remaining_file"
		mv "$remaining_file" "$TEST_DISPATCH_RETURNS_FILE"
		[[ -n "$next" ]] || next=0
		printf '%s\n' "$next"
		return 0
	}
	# shellcheck disable=SC2329  # Override sourced function to keep the test fast.
	_adaptive_launch_settle_wait() {
		return 0
	}

	apply_dispatch_max

	local dispatch_calls
	dispatch_calls=$(<"$TEST_DISPATCH_CALLS_FILE")
	if [[ "$dispatch_calls" -eq 2 ]]; then
		print_result "apply: refills minimum active-worker floor after partial launch" 0
	else
		print_result "apply: refills minimum active-worker floor after partial launch" 1 "dispatch_calls=${dispatch_calls}"
	fi
	unset TEST_ACTIVE_WORKERS_SEQUENCE_FILE TEST_DISPATCH_CALLS_FILE TEST_DISPATCH_RETURNS_FILE AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS
	return 0
}

test_apply_dispatch_skips_refill_when_capacity_cap_disables_floor() {
	(
		AIDEVOPS_MIN_WORKER_CONCURRENCY=6
		TEST_MAX_WORKERS=8
		TEST_ACTIVE_WORKERS=4
		TEST_DISPATCH_CALLS_FILE="${TEST_ROOT}/cap-refill-dispatch-calls.txt"
		printf '%s\n' 0 >"$TEST_DISPATCH_CALLS_FILE"
		STOP_FLAG="${HOME}/.aidevops/logs/stop"
		: >"$LOGFILE"
		pulse_apply_provider_load_capacity_cap() {
			printf '1 0\n'
			return 0
		}
		# shellcheck disable=SC2329  # Override sourced function for this regression.
		dispatch_max() {
			local calls
			calls=$(<"$TEST_DISPATCH_CALLS_FILE")
			[[ "$calls" =~ ^[0-9]+$ ]] || calls=0
			printf '%s\n' "$((calls + 1))" >"$TEST_DISPATCH_CALLS_FILE"
			printf '0\n'
			return 0
		}
		# shellcheck disable=SC2329  # Override sourced function to keep the test fast.
		_adaptive_launch_settle_wait() {
			return 0
		}

		apply_dispatch_max

		local dispatch_calls
		dispatch_calls=$(<"$TEST_DISPATCH_CALLS_FILE")
		if [[ "$dispatch_calls" -eq 1 ]] && ! grep -q 'Minimum worker floor refill:' "$LOGFILE" 2>/dev/null; then
			return 0
		fi
		printf 'dispatch_calls=%s log=%s\n' "$dispatch_calls" "$(<"$LOGFILE")" >"${TEST_ROOT}/cap-refill-failure.txt"
		return 1
	)
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "apply: capacity cap disables minimum floor refill" 0
	else
		print_result "apply: capacity cap disables minimum floor refill" 1 "$(<"${TEST_ROOT}/cap-refill-failure.txt")"
	fi
	unset TEST_DISPATCH_CALLS_FILE
	return 0
}

test_min_worker_floor_refill_uses_precomputed_counts() {
	(
		AIDEVOPS_MIN_WORKER_CONCURRENCY=6
		AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS=1
		STOP_FLAG="${HOME}/.aidevops/logs/stop"
		TEST_GET_MAX_CALLED_FILE="${TEST_ROOT}/precomputed-get-max-called.txt"
		TEST_COUNT_ACTIVE_CALLED_FILE="${TEST_ROOT}/precomputed-count-active-called.txt"
		get_max_workers_target() {
			printf 'called\n' >"$TEST_GET_MAX_CALLED_FILE"
			printf '1\n'
			return 0
		}
		count_active_workers() {
			printf 'called\n' >"$TEST_COUNT_ACTIVE_CALLED_FILE"
			printf '0\n'
			return 0
		}
		dispatch_max() {
			printf 'dispatch_max should not be called with active worker count at floor\n' >"${TEST_ROOT}/precomputed-dispatch-called.txt"
			return 1
		}

		_dispatch_min_worker_floor_refill 8 6

		if [[ ! -f "$TEST_GET_MAX_CALLED_FILE" && ! -f "$TEST_COUNT_ACTIVE_CALLED_FILE" && ! -f "${TEST_ROOT}/precomputed-dispatch-called.txt" ]]; then
			return 0
		fi
		printf 'get_max_called=%s count_active_called=%s dispatch_called=%s\n' \
			"$([[ -f "$TEST_GET_MAX_CALLED_FILE" ]] && printf yes || printf no)" \
			"$([[ -f "$TEST_COUNT_ACTIVE_CALLED_FILE" ]] && printf yes || printf no)" \
			"$([[ -f "${TEST_ROOT}/precomputed-dispatch-called.txt" ]] && printf yes || printf no)" >"${TEST_ROOT}/precomputed-refill-failure.txt"
		return 1
	)
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "refill: precomputed counts skip worker count reads" 0
	else
		print_result "refill: precomputed counts skip worker count reads" 1 "$(<"${TEST_ROOT}/precomputed-refill-failure.txt")"
	fi
	unset TEST_GET_MAX_CALLED_FILE TEST_COUNT_ACTIVE_CALLED_FILE AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS
	return 0
}

test_min_worker_floor_refill_stops_after_triage_only_round() {
	(
		AIDEVOPS_MIN_WORKER_CONCURRENCY=6
		AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS=1
		STOP_FLAG="${HOME}/.aidevops/logs/stop"
		TEST_DISPATCH_CALLS_FILE="${TEST_ROOT}/triage-only-refill-dispatch-calls.txt"
		printf '%s\n' 0 >"$TEST_DISPATCH_CALLS_FILE"
		: >"$LOGFILE"
		pulse_apply_provider_load_capacity_cap() {
			printf '6 1\n'
			return 0
		}
		dispatch_max() {
			local calls
			calls=$(<"$TEST_DISPATCH_CALLS_FILE")
			[[ "$calls" =~ ^[0-9]+$ ]] || calls=0
			printf '%s\n' "$((calls + 1))" >"$TEST_DISPATCH_CALLS_FILE"
			echo "[pulse-wrapper] Dispatch_max complete: implementation_dispatched=0 triage_attempted=2" >>"$LOGFILE"
			printf '0\n'
			return 0
		}

		_dispatch_min_worker_floor_refill 6 2

		local dispatch_calls
		dispatch_calls=$(<"$TEST_DISPATCH_CALLS_FILE")
		if [[ "$dispatch_calls" -eq 1 ]] \
			&& grep -q 'Minimum worker floor refill stopped: dispatch_max returned 0' "$LOGFILE" 2>/dev/null; then
			return 0
		fi
		printf 'dispatch_calls=%s log=%s\n' "$dispatch_calls" "$(<"$LOGFILE")" \
			>"${TEST_ROOT}/triage-only-refill-failure.txt"
		return 1
	)
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "refill: triage-only outcomes do not keep implementation refill alive" 0
	else
		print_result "refill: triage-only outcomes do not keep implementation refill alive" 1 \
			"$(<"${TEST_ROOT}/triage-only-refill-failure.txt")"
	fi
	unset TEST_DISPATCH_CALLS_FILE AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS
	return 0
}

test_apply_dispatch_refill_reuses_initial_worker_counts() {
	(
		AIDEVOPS_MIN_WORKER_CONCURRENCY=6
		AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS=1
		STOP_FLAG="${HOME}/.aidevops/logs/stop"
		TEST_COUNT_ACTIVE_CALLS_FILE="${TEST_ROOT}/apply-precomputed-count-active-calls.txt"
		TEST_GET_MAX_CALLS_FILE="${TEST_ROOT}/apply-precomputed-get-max-calls.txt"
		printf '%s\n' 0 >"$TEST_COUNT_ACTIVE_CALLS_FILE"
		printf '%s\n' 0 >"$TEST_GET_MAX_CALLS_FILE"
		count_active_workers() {
			local calls
			calls=$(<"$TEST_COUNT_ACTIVE_CALLS_FILE")
			[[ "$calls" =~ ^[0-9]+$ ]] || calls=0
			printf '%s\n' "$((calls + 1))" >"$TEST_COUNT_ACTIVE_CALLS_FILE"
			printf '6\n'
			return 0
		}
		get_max_workers_target() {
			local calls
			calls=$(<"$TEST_GET_MAX_CALLS_FILE")
			[[ "$calls" =~ ^[0-9]+$ ]] || calls=0
			printf '%s\n' "$((calls + 1))" >"$TEST_GET_MAX_CALLS_FILE"
			printf '8\n'
			return 0
		}
		dispatch_max() {
			printf '0\n'
			return 0
		}
		_adaptive_launch_settle_wait() {
			return 0
		}

		apply_dispatch_max

		local count_active_calls get_max_calls
		count_active_calls=$(<"$TEST_COUNT_ACTIVE_CALLS_FILE")
		get_max_calls=$(<"$TEST_GET_MAX_CALLS_FILE")
		if [[ "$count_active_calls" -eq 1 && "$get_max_calls" -eq 1 ]]; then
			return 0
		fi
		printf 'count_active_calls=%s get_max_calls=%s\n' "$count_active_calls" "$get_max_calls" >"${TEST_ROOT}/apply-precomputed-failure.txt"
		return 1
	)
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "apply: refill reuses precomputed worker counts" 0
	else
		print_result "apply: refill reuses precomputed worker counts" 1 "$(<"${TEST_ROOT}/apply-precomputed-failure.txt")"
	fi
	unset TEST_COUNT_ACTIVE_CALLS_FILE TEST_GET_MAX_CALLS_FILE AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS
	return 0
}

test_early_exit_refill_reuses_precomputed_active_count() {
	(
		AIDEVOPS_MIN_WORKER_CONCURRENCY=6
		AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS=1
		PULSE_BACKFILL_MAX_ATTEMPTS=1
		PULSE_LAUNCH_GRACE_SECONDS=0
		STOP_FLAG="${HOME}/.aidevops/logs/stop"
		PRE_RUN_STAGE_TIMEOUT=1
		TEST_COUNT_ACTIVE_CALLS_FILE="${TEST_ROOT}/early-precomputed-count-active-calls.txt"
		printf '%s\n' 0 >"$TEST_COUNT_ACTIVE_CALLS_FILE"
		get_max_workers_target() {
			printf '6\n'
			return 0
		}
		count_active_workers() {
			local calls
			calls=$(<"$TEST_COUNT_ACTIVE_CALLS_FILE")
			[[ "$calls" =~ ^[0-9]+$ ]] || calls=0
			printf '%s\n' "$((calls + 1))" >"$TEST_COUNT_ACTIVE_CALLS_FILE"
			printf '1\n'
			return 0
		}
		count_runnable_candidates() {
			printf '8\n'
			return 0
		}
		count_queued_without_worker() {
			printf '0\n'
			return 0
		}
		dispatch_max() {
			printf '5\n'
			return 0
		}

		_run_early_exit_recycle_loop 1

		local count_active_calls
		count_active_calls=$(<"$TEST_COUNT_ACTIVE_CALLS_FILE")
		if [[ "$count_active_calls" -eq 1 ]]; then
			return 0
		fi
		printf 'count_active_calls=%s\n' "$count_active_calls" >"${TEST_ROOT}/early-precomputed-failure.txt"
		return 1
	)
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "early recycle: refill reuses precomputed active count" 0
	else
		print_result "early recycle: refill reuses precomputed active count" 1 "$(<"${TEST_ROOT}/early-precomputed-failure.txt")"
	fi
	unset TEST_COUNT_ACTIVE_CALLS_FILE AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS PULSE_BACKFILL_MAX_ATTEMPTS PULSE_LAUNCH_GRACE_SECONDS PRE_RUN_STAGE_TIMEOUT
	return 0
}

test_active_pulse_refill_uses_min_floor_above_raw_max() {
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	TEST_MAX_WORKERS=1
	TEST_ACTIVE_WORKERS=2
	TEST_DISPATCH_CALLS_FILE="${TEST_ROOT}/active-refill-dispatch-calls.txt"
	printf '%s\n' 0 >"$TEST_DISPATCH_CALLS_FILE"
	STOP_FLAG="${HOME}/.aidevops/logs/stop"
	PULSE_ACTIVE_REFILL_INTERVAL=120
	PULSE_ACTIVE_REFILL_IDLE_MIN=60
	PULSE_ACTIVE_REFILL_STALL_MIN=120
	# shellcheck disable=SC2329  # Override sourced function for this regression.
	count_runnable_candidates() {
		printf '4\n'
		return 0
	}
	# shellcheck disable=SC2329  # Override sourced function for this regression.
	count_queued_without_worker() {
		printf '0\n'
		return 0
	}
	# shellcheck disable=SC2329  # Override sourced function for this regression.
	run_underfill_worker_recycler() {
		return 0
	}
	# shellcheck disable=SC2329  # Override sourced function for this regression.
	dispatch_max() {
		local calls
		calls=$(<"$TEST_DISPATCH_CALLS_FILE")
		[[ "$calls" =~ ^[0-9]+$ ]] || calls=0
		printf '%s\n' "$((calls + 1))" >"$TEST_DISPATCH_CALLS_FILE"
		printf '0\n'
		return 0
	}

	maybe_refill_underfilled_pool_during_active_pulse 0 180 180 true >/dev/null

	local dispatch_calls
	dispatch_calls=$(<"$TEST_DISPATCH_CALLS_FILE")
	if [[ "$dispatch_calls" -ge 1 ]]; then
		print_result "active refill: minimum floor overrides lower raw max target" 0
	else
		print_result "active refill: minimum floor overrides lower raw max target" 1 "dispatch_calls=${dispatch_calls}"
	fi
	unset TEST_DISPATCH_CALLS_FILE
	return 0
}

write_recent_ledger_evidence() {
	local status="$1"
	local ledger_dir timestamp
	ledger_dir="${HOME}/.aidevops/.agent-workspace/tmp"
	mkdir -p "$ledger_dir"
	timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	printf '{"session_key":"test-canary","issue_number":"100","repo_slug":"o/r","pid":"1","dispatched_at":"%s","status":"%s","updated_at":"%s"}\n' \
		"$timestamp" "$status" "$timestamp" >"${ledger_dir}/dispatch-ledger.jsonl"
	return 0
}

test_soft_canary_failure_bypasses_with_recent_worker_evidence() {
	local fake_helper worker_log state_dir
	fake_helper="${TEST_ROOT}/fake-soft-canary.sh"
	worker_log="${TEST_ROOT}/worker-soft.log"
	state_dir="${HOME}/.aidevops/.agent-workspace/headless-runtime"
	cat >"$fake_helper" <<'EOF'
#!/usr/bin/env bash
state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
mkdir -p "$state_dir"
date +%s >"${state_dir}/canary-last-fail"
printf 'timeout\n' >"${state_dir}/canary-last-fail.reason"
exit 124
EOF
	chmod +x "$fake_helper"
	write_recent_ledger_evidence "in-flight"
	HEADLESS_RUNTIME_HELPER="$fake_helper"
	AIDEVOPS_HEADLESS_RUNTIME_DIR="$state_dir"
	TEST_ACTIVE_WORKERS=6
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	if _dlw_canary_preflight 102 "o/r" "$worker_log" "standard" ""; then
		print_result "canary: soft failure bypassed with recent worker evidence" 0
	else
		print_result "canary: soft failure bypassed with recent worker evidence" 1
	fi
	return 0
}

test_hard_canary_failure_blocks_despite_recent_worker_evidence() {
	local fake_helper worker_log state_dir
	fake_helper="${TEST_ROOT}/fake-hard-canary.sh"
	worker_log="${TEST_ROOT}/worker-hard.log"
	state_dir="${HOME}/.aidevops/.agent-workspace/headless-runtime"
	cat >"$fake_helper" <<'EOF'
#!/usr/bin/env bash
state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
mkdir -p "$state_dir"
date +%s >"${state_dir}/canary-last-fail"
printf 'auth_error\n' >"${state_dir}/canary-last-fail.reason"
exit 1
EOF
	chmod +x "$fake_helper"
	write_recent_ledger_evidence "completed"
	HEADLESS_RUNTIME_HELPER="$fake_helper"
	AIDEVOPS_HEADLESS_RUNTIME_DIR="$state_dir"
	TEST_ACTIVE_WORKERS=6
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	_DLW_CANARY_SOFT_BYPASS_REASON="stale"
	if _dlw_canary_preflight 103 "o/r" "$worker_log" "standard" ""; then
		print_result "canary: hard failure blocks despite recent worker evidence" 1 "unexpected success"
	elif [[ -n "${_DLW_CANARY_SOFT_BYPASS_REASON:-}" ]]; then
		print_result "canary: hard failure blocks despite recent worker evidence" 1 \
			"soft_bypass_reason=${_DLW_CANARY_SOFT_BYPASS_REASON}"
	else
		print_result "canary: hard failure blocks despite recent worker evidence" 0
	fi
	return 0
}

test_local_error_canary_failure_stays_hard_under_minimum_floor() {
	local fake_helper worker_log state_dir
	fake_helper="${TEST_ROOT}/fake-local-error-canary.sh"
	worker_log="${TEST_ROOT}/worker-local-error.log"
	state_dir="${HOME}/.aidevops/.agent-workspace/headless-runtime"
	cat >"$fake_helper" <<'EOF'
#!/usr/bin/env bash
state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
mkdir -p "$state_dir"
date +%s >"${state_dir}/canary-last-fail"
printf 'local_error\n' >"${state_dir}/canary-last-fail.reason"
exit 1
EOF
	chmod +x "$fake_helper"
	HEADLESS_RUNTIME_HELPER="$fake_helper"
	AIDEVOPS_HEADLESS_RUNTIME_DIR="$state_dir"
	TEST_ACTIVE_WORKERS=5
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	if _dlw_canary_preflight 105 "o/r" "$worker_log" "standard" ""; then
		print_result "canary: local runtime failure stays hard under minimum floor" 1 "unexpected success"
	else
		print_result "canary: local runtime failure stays hard under minimum floor" 0
	fi
	return 0
}

test_soft_canary_failure_bypasses_under_minimum_floor_without_recent_evidence() {
	local fake_helper worker_log state_dir
	fake_helper="${TEST_ROOT}/fake-floor-canary.sh"
	worker_log="${TEST_ROOT}/worker-floor.log"
	state_dir="${HOME}/.aidevops/.agent-workspace/headless-runtime"
	cat >"$fake_helper" <<'EOF'
#!/usr/bin/env bash
state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
mkdir -p "$state_dir"
date +%s >"${state_dir}/canary-last-fail"
printf 'inconclusive\n' >"${state_dir}/canary-last-fail.reason"
exit 1
EOF
	chmod +x "$fake_helper"
	HEADLESS_RUNTIME_HELPER="$fake_helper"
	AIDEVOPS_HEADLESS_RUNTIME_DIR="$state_dir"
	AIDEVOPS_DISPATCH_LEDGER_DIR="${TEST_ROOT}/empty-ledger"
	mkdir -p "$AIDEVOPS_DISPATCH_LEDGER_DIR"
	TEST_ACTIVE_WORKERS=5
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	if _dlw_canary_preflight 104 "o/r" "$worker_log" "standard" "" && \
		[[ "${_DLW_CANARY_SOFT_BYPASS_REASON:-}" == "inconclusive" ]]; then
		print_result "canary: inconclusive failure bypassed under minimum worker floor" 0
	else
		print_result "canary: inconclusive failure bypassed under minimum worker floor" 1 \
			"soft_bypass_reason=${_DLW_CANARY_SOFT_BYPASS_REASON:-unset}"
	fi
	return 0
}

test_soft_canary_bypass_reason_propagates_to_worker_env() {
	local -a worker_cmd=(env)
	_DLW_CANARY_SOFT_BYPASS_REASON="inconclusive"
	_dlw_append_canary_preflight_env
	if [[ " ${worker_cmd[*]} " == *" AIDEVOPS_WORKER_CANARY_SOFT_BYPASS_REASON=inconclusive "* ]]; then
		print_result "canary: accepted soft reason propagates to detached worker" 0
	else
		print_result "canary: accepted soft reason propagates to detached worker" 1 \
			"worker_cmd=${worker_cmd[*]}"
	fi
	unset _DLW_CANARY_SOFT_BYPASS_REASON
	return 0
}

test_capacity_raises_soft_cap_to_floor
test_capacity_reads_min_floor_from_config_default
test_capacity_respects_existing_higher_cap
test_capacity_high_load_is_advisory_only
test_capacity_uses_configured_provider_account_multiplier
test_capacity_env_multiplier_overrides_config
test_capacity_defaults_single_account_to_max_cap
test_capacity_recent_service_interruptions_reduce_slots
test_capacity_recent_progress_gets_runway_under_pressure
test_capacity_clamps_provider_cap_below_active_to_zero_available
test_throttle_does_not_force_serial_under_floor
test_throttle_forces_serial_above_floor
test_canary_preflight_marks_floor_without_cpu_bypass
test_prebootstrap_ignores_deprecated_load_threshold
test_apply_dispatch_refills_until_active_floor_after_partial_launch
test_apply_dispatch_skips_refill_when_capacity_cap_disables_floor
test_min_worker_floor_refill_uses_precomputed_counts
test_min_worker_floor_refill_stops_after_triage_only_round
test_apply_dispatch_refill_reuses_initial_worker_counts
test_early_exit_refill_reuses_precomputed_active_count
test_active_pulse_refill_uses_min_floor_above_raw_max
test_soft_canary_failure_bypasses_with_recent_worker_evidence
test_hard_canary_failure_blocks_despite_recent_worker_evidence
test_local_error_canary_failure_stays_hard_under_minimum_floor
test_soft_canary_failure_bypasses_under_minimum_floor_without_recent_evidence
test_soft_canary_bypass_reason_propagates_to_worker_env

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
