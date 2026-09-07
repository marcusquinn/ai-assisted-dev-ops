#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME="${ROOT}/home"
PULSE_DIR="${HOME}/.aidevops/.agent-workspace/supervisor"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
LOCKDIR="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
REPOS_JSON="${HOME}/.config/aidevops/repos.json"
mkdir -p "$PULSE_DIR" "$(dirname "$LOGFILE")" "$(dirname "$REPOS_JSON")"
printf '{"initialized_repos":[]}\n' >"$REPOS_JSON"
PULSE_FORCE_LLM=0

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-instance-lock.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-wrapper-cycle.sh"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	return 1
}

safe_emit_output=$(
	set -euo pipefail
	for i in $(seq 1 20000); do
		_emit_stdout_line_safely "$i"
	done | sed -n '1p'
)
[[ "$safe_emit_output" == "1" ]] || fail "SIGPIPE-safe emit returned ${safe_emit_output}"

PULSE_LLM_DAILY_INTERVAL=100
PULSE_LLM_FAILURE_RETRY_INTERVAL=60
now_epoch=$(date +%s)
printf '%s\n' "$((now_epoch - 1000))" >"${PULSE_DIR}/last_llm_success_epoch"
printf '%s\n' "$((now_epoch - 10))" >"${PULSE_DIR}/last_llm_attempt_epoch"
if _should_run_llm_supervisor || [[ -f "${PULSE_DIR}/llm_trigger_mode" ]]; then
	fail "recent failed LLM attempt did not apply retry cooldown"
fi

llm_lockdir="${LOCKDIR}.llm"
dead_pid=999987
while ps -p "$dead_pid" >/dev/null 2>&1; do
	dead_pid=$((dead_pid + 1))
done
mkdir -p "$llm_lockdir"
printf '%s\n' "$dead_pid" >"${llm_lockdir}/pid"
_pulse_maybe_run_llm_supervisor || fail "skip-cycle stale LLM lock cleanup returned non-zero"
[[ ! -d "$llm_lockdir" ]] || fail "skip-cycle stale LLM lock cleanup left a reclaimed lock behind"
grep -q "Stale LLM lockdir detected (owner PID ${dead_pid} is dead)" "$WRAPPER_LOGFILE" || fail "skip-cycle stale LLM lock cleanup did not log stale owner"

printf '%s\n' "$((now_epoch - 120))" >"${PULSE_DIR}/last_llm_attempt_epoch"
_should_run_llm_supervisor || fail "old failed LLM attempt did not permit retry"
[[ "$(cat "${PULSE_DIR}/llm_trigger_mode")" == "daily_sweep" ]] || fail "retry trigger was not daily_sweep"

rm -f "${PULSE_DIR}/last_llm_attempt_epoch" "${PULSE_DIR}/last_llm_success_epoch" "${PULSE_DIR}/last_llm_run_epoch"
_pulse_record_llm_attempt "daily_sweep"
_pulse_record_llm_failure "daily_sweep" "7"
[[ -f "${PULSE_DIR}/last_llm_attempt_epoch" ]] || fail "attempt timestamp missing"
[[ ! -f "${PULSE_DIR}/last_llm_success_epoch" && ! -f "${PULSE_DIR}/last_llm_run_epoch" ]] || fail "failure wrote success timestamp"
_pulse_record_llm_success "daily_sweep"
[[ -f "${PULSE_DIR}/last_llm_success_epoch" && -f "${PULSE_DIR}/last_llm_run_epoch" ]] || fail "success timestamps missing"

now_epoch=$(date +%s)
daily_epoch=$((now_epoch - 1000))
printf '%s\n' "$daily_epoch" >"${PULSE_DIR}/last_daily_sweep_success_epoch"
printf '%s 0 0\n' "$now_epoch" >"${PULSE_DIR}/backlog_snapshot.txt"
_pulse_record_llm_success "stall"
_should_run_llm_supervisor || fail "successful stall run postponed an overdue daily sweep"
[[ "$(<"${PULSE_DIR}/llm_trigger_mode")" == daily_sweep ]] || fail "overdue sweep did not select daily mode"
[[ "$(<"${PULSE_DIR}/last_daily_sweep_success_epoch")" == "$daily_epoch" ]] || fail "stall changed daily completion evidence"
_pulse_record_llm_success "first_run"
[[ "$(<"${PULSE_DIR}/last_daily_sweep_success_epoch")" == "$daily_epoch" ]] || fail "first-run changed daily completion evidence"
_pulse_record_llm_failure "daily_sweep" 7
[[ "$(<"${PULSE_DIR}/last_daily_sweep_success_epoch")" == "$daily_epoch" ]] || fail "failed daily sweep advanced completion evidence"
mv "${PULSE_DIR}/last_llm_success_epoch" "${PULSE_DIR}/saved-success"
mkdir "${PULSE_DIR}/last_llm_success_epoch"
if _pulse_record_llm_success "daily_sweep" 2>/dev/null; then
	fail "generic success write failure was ignored"
fi
[[ "$(<"${PULSE_DIR}/last_daily_sweep_success_epoch")" == "$daily_epoch" ]] || fail "partial state write advanced daily cadence"
rmdir "${PULSE_DIR}/last_llm_success_epoch"
mv "${PULSE_DIR}/saved-success" "${PULSE_DIR}/last_llm_success_epoch"
_pulse_record_llm_success "daily_sweep"
[[ "$(<"${PULSE_DIR}/last_daily_sweep_success_epoch")" -ge "$now_epoch" ]] || fail "successful daily sweep did not advance its own clock"
if _should_run_llm_supervisor; then
	fail "recent daily success triggered another sweep with unchanged fresh backlog"
fi

# Migration may reuse a positively identified daily completion, not a stall.
rm -f "${PULSE_DIR}/last_daily_sweep_success_epoch"
if _should_run_llm_supervisor; then
	fail "known legacy daily completion was ignored"
fi
_pulse_record_llm_success "stall"
_should_run_llm_supervisor || fail "legacy stall completion suppressed first independently tracked daily sweep"

printf 'PASS pulse SIGPIPE and LLM state regressions\n'
