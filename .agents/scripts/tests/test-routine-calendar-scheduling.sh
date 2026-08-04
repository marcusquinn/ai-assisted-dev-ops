#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../routine-schedule-helper.sh"
PULSE_ROUTINES="${SCRIPT_DIR}/../pulse-routines.sh"
PASSED=0
FAILED=0
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

iso_epoch() {
	local iso="$1"
	local epoch=""
	epoch=$(date -u -d "$iso" +%s 2>/dev/null) || true
	if [[ -z "$epoch" ]]; then
		epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) || true
	fi
	[[ "$epoch" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$epoch"
	return 0
}

record_result() {
	local description="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual" >&2
	FAILED=$((FAILED + 1))
	return 0
}

assert_due_rc() {
	local description="$1"
	local timezone="$2"
	local now_iso="$3"
	local expression="$4"
	local last_iso="$5"
	local expected_rc="$6"
	local now_epoch=""
	local last_epoch=""
	local actual_rc=0
	now_epoch=$(iso_epoch "$now_iso") || return 1
	if [[ "$last_iso" == "never" ]]; then
		last_epoch=0
	else
		last_epoch=$(iso_epoch "$last_iso") || return 1
	fi
	env AIDEVOPS_SCHEDULE_TIMEZONE="$timezone" AIDEVOPS_SCHEDULE_NOW_EPOCH="$now_epoch" \
		"$HELPER" is-due "$expression" "$last_epoch" >/dev/null 2>&1 || actual_rc=$?
	record_result "$description" "$actual_rc" "$expected_rc"
	return 0
}

assert_next_run() {
	local description="$1"
	local timezone="$2"
	local now_iso="$3"
	local expression="$4"
	local expected="$5"
	local now_epoch=""
	local actual=""
	now_epoch=$(iso_epoch "$now_iso") || return 1
	actual=$(env AIDEVOPS_SCHEDULE_TIMEZONE="$timezone" AIDEVOPS_SCHEDULE_NOW_EPOCH="$now_epoch" \
		"$HELPER" next-run "$expression" 2>/dev/null) || actual="rc:$?"
	record_result "$description" "$actual" "$expected"
	return 0
}

assert_pulse_timezone_policy() {
	ROUTINE_SCHEDULE_HELPER="$HELPER"
	unset _PULSE_ROUTINES_LOADED
	# shellcheck source=../pulse-routines.sh
	source "$PULSE_ROUTINES"

	local parse_rc=0
	if _routine_parse_line '- [x] r-zone Parsed zone repeat:daily(@00:30) ~1m run:scripts/example.sh timezone:Etc/GMT+1'; then
		parse_rc=0
	else
		parse_rc=$?
	fi
	record_result "routine parser accepts IANA timezone token" "$parse_rc" 0
	record_result "routine parser retains timezone override" "$_RPL_TIMEZONE" 'Etc/GMT+1'
	record_result "timezone field terminates routine description" "$_RPL_DESC" 'Parsed zone'

	local malformed_rc=0
	_routine_parse_line '- [x] r-bad-zone Bad zone repeat:daily(@00:30) timezone:Europe/Jersey;' >/dev/null 2>&1 || malformed_rc=$?
	record_result "malformed timezone field fails closed" "$malformed_rc" 1

	local inherited_timezone="not-empty"
	if _routine_parse_line '- [x] r-local-zone Local zone repeat:daily(@00:30) run:scripts/example.sh'; then
		inherited_timezone="$_RPL_TIMEZONE"
	fi
	record_result "routine without override retains inherited timezone mode" "$inherited_timezone" ''

	local now_epoch=""
	local last_epoch=""
	local override_rc=0
	local inherited_rc=0
	now_epoch=$(iso_epoch 2026-07-23T00:45:00Z) || return 1
	last_epoch=$(iso_epoch 2026-07-23T00:00:00Z) || return 1
	(
		export AIDEVOPS_SCHEDULE_TIMEZONE=Europe/Jersey
		export AIDEVOPS_SCHEDULE_NOW_EPOCH="$now_epoch"
		_routine_schedule_is_due 'daily(@00:30)' "$last_epoch" UTC
	) >/dev/null 2>&1 || override_rc=$?
	(
		export AIDEVOPS_SCHEDULE_TIMEZONE=Europe/Jersey
		export AIDEVOPS_SCHEDULE_NOW_EPOCH="$now_epoch"
		_routine_schedule_is_due 'daily(@00:30)' "$last_epoch" "$inherited_timezone"
	) >/dev/null 2>&1 || inherited_rc=$?
	record_result "explicit UTC routine overrides global Europe/Jersey timezone" "$override_rc" 0
	record_result "routine without override inherits global Europe/Jersey timezone" "$inherited_rc" 1
	return 0
}

assert_pulse_state_policy() {
	ROUTINE_STATE_FILE="${TEST_ROOT}/routine-state.json"
	LOGFILE="${TEST_ROOT}/pulse.log"
	# shellcheck source=../pulse-routines.sh
	source "$PULSE_ROUTINES"
	_routine_update_state r001 failure
	local failure_shape=""
	failure_shape=$(jq -r '.r001 | [has("last_run"), .last_status, has("last_attempt")] | @tsv' "$ROUTINE_STATE_FILE")
	record_result "failed run preserves the prior calendar marker" "$failure_shape" $'false\tfailure\ttrue'
	local blocked_rc=0
	_routine_retry_blocked r001 || blocked_rc=$?
	record_result "recent failure observes explicit retry cooldown" "$blocked_rc" 0
	_routine_update_state r001 success
	local success_shape=""
	success_shape=$(jq -r '.r001 | [has("last_run"), .last_status] | @tsv' "$ROUTINE_STATE_FILE")
	record_result "successful run advances the calendar marker" "$success_shape" $'true\tsuccess'

	AIDEVOPS_ROUTINE_NOW_EPOCH=1000
	AIDEVOPS_ROUTINE_FAILURE_RETRY_SECONDS=900
	_routine_update_state r002 failure
	AIDEVOPS_ROUTINE_NOW_EPOCH=1899
	blocked_rc=0
	_routine_retry_blocked r002 || blocked_rc=$?
	record_result "ordinary failure retains generic retry semantics" "$blocked_rc" 0
	AIDEVOPS_ROUTINE_NOW_EPOCH=1900
	blocked_rc=0
	_routine_retry_blocked r002 || blocked_rc=$?
	record_result "ordinary failure retries after generic boundary" "$blocked_rc" 1

	AIDEVOPS_ROUTINE_NOW_EPOCH=2000
	_routine_update_state r003 deferred 2100
	_routine_update_state r003 deferred 2050
	local deferred_shape=""
	deferred_shape=$(jq -r '.r003 | [.last_status, .deferred_until, has("last_run")] | @tsv' "$ROUTINE_STATE_FILE")
	record_result "repeated deferrals preserve the furthest eligibility boundary" "$deferred_shape" $'deferred\t2100\tfalse'
	AIDEVOPS_ROUTINE_NOW_EPOCH=2099
	blocked_rc=0
	_routine_retry_blocked r003 || blocked_rc=$?
	record_result "deferred run remains blocked before reset plus jitter" "$blocked_rc" 0
	AIDEVOPS_ROUTINE_NOW_EPOCH=2100
	blocked_rc=0
	_routine_retry_blocked r003 || blocked_rc=$?
	record_result "deferred run retries at persisted eligibility boundary" "$blocked_rc" 1
	unset AIDEVOPS_ROUTINE_NOW_EPOCH AIDEVOPS_ROUTINE_FAILURE_RETRY_SECONDS
	return 0
}

main() {
	assert_due_rc "off-schedule bootstrap does not suppress next daily boundary" \
		UTC 2026-07-23T13:34:14Z 'daily(@07:10)' 2026-07-22T22:03:25Z 0
	assert_due_rc "run after daily boundary prevents duplicate" \
		UTC 2026-07-23T13:34:14Z 'daily(@07:10)' 2026-07-23T07:10:00Z 1
	assert_due_rc "never-run routine remains immediately due" \
		UTC 2026-07-23T01:00:00Z 'daily(@07:10)' never 0
	assert_due_rc "clock rollback fails closed" \
		UTC 2026-07-23T01:00:00Z 'daily(@07:10)' 2026-07-23T02:00:00Z 1
	assert_due_rc "missed weekly boundary catches up" \
		UTC 2026-07-23T13:34:14Z 'weekly(sun@07:40)' 2026-07-18T12:00:00Z 0
	assert_due_rc "weekly boundary executes once" \
		UTC 2026-07-23T13:34:14Z 'weekly(sun@07:40)' 2026-07-19T07:40:00Z 1
	assert_due_rc "leap-day monthly boundary catches up" \
		UTC 2024-03-01T12:00:00Z 'monthly(29@09:00)' 2024-02-01T12:00:00Z 0
	assert_due_rc "missing day in a short month is skipped" \
		UTC 2026-03-01T12:00:00Z 'monthly(31@09:00)' 2026-01-31T09:00:00Z 1
	assert_due_rc "cron catches a boundary missed after an off-slot run" \
		UTC 2026-07-23T13:34:14Z 'cron(10 7 * * *)' 2026-07-22T22:03:25Z 0

	assert_next_run "UTC daily next-run uses the same boundary" \
		UTC 2026-07-23T13:34:14Z 'daily(@07:10)' 2026-07-24T07:10:00Z
	assert_next_run "Europe/Jersey local schedule converts to BST" \
		Europe/Jersey 2026-07-23T13:34:14Z 'daily(@07:10)' 2026-07-24T06:10:00Z
	assert_next_run "America/New_York local schedule converts to EDT" \
		America/New_York 2026-07-23T13:34:14Z 'daily(@07:10)' 2026-07-24T11:10:00Z
	assert_next_run "monthly next-run uses the next valid calendar date" \
		UTC 2026-03-01T12:00:00Z 'monthly(31@09:00)' 2026-03-31T09:00:00Z
	assert_next_run "cron next-run uses the next matching minute boundary" \
		UTC 2026-07-23T13:34:14Z 'cron(10 7 * * *)' 2026-07-24T07:10:00Z
	assert_next_run "fall-back repeated hour selects its first occurrence" \
		Europe/Jersey 2026-10-24T12:00:00Z 'daily(@01:30)' 2026-10-25T00:30:00Z
	assert_next_run "spring-forward nonexistent local time fails closed" \
		Europe/Jersey 2026-03-28T12:00:00Z 'daily(@01:30)' 'rc:2'
	assert_pulse_timezone_policy
	assert_pulse_state_policy

	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
