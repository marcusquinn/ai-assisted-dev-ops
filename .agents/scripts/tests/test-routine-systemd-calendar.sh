#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Test routine-helper systemd OnCalendar generation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit
ROUTINE_HELPER="${REPO_SCRIPTS_DIR}/routine-helper.sh"

# shellcheck source=../shared-constants.sh
source "${REPO_SCRIPTS_DIR}/shared-constants.sh"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

run_install_systemd() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	local schedule="$1"
	local tmp_home=""
	tmp_home=$(mktemp -d)
	push_cleanup "rm -rf \"${tmp_home}\""

	local output=""
	local rc=0
	if output=$(HOME="$tmp_home" "$ROUTINE_HELPER" install-systemd \
		--name test \
		--schedule "$schedule" \
		--dir "$tmp_home" \
		--prompt 'test prompt' 2>&1); then
		rc=0
	else
		rc=$?
	fi

	rm -rf "$tmp_home"
	tmp_home=""
	printf '%s' "$output"
	return "$rc"
}

test_wildcard_weekday_omits_prefix() {
	local output=""
	output=$(run_install_systemd '0 9 * * *')

	if [[ "$output" == *'OnCalendar=*-*-* 09:00:00'* ]]; then
		print_result "wildcard weekday omits systemd weekday prefix" 0
	else
		print_result "wildcard weekday omits systemd weekday prefix" 1 \
			"Expected OnCalendar=*-*-* 09:00:00, got: $output"
	fi
	return 0
}

test_numeric_weekday_keeps_prefix() {
	local output=""
	output=$(run_install_systemd '0 9 * * 1')

	if [[ "$output" == *'OnCalendar=Mon *-*-* 09:00:00'* ]]; then
		print_result "numeric weekday keeps systemd weekday prefix" 0
	else
		print_result "numeric weekday keeps systemd weekday prefix" 1 \
			"Expected OnCalendar=Mon *-*-* 09:00:00, got: $output"
	fi
	return 0
}

test_step_minutes_supported() {
	local output=""
	output=$(run_install_systemd '*/10 * * * *')

	if [[ "$output" == *'OnCalendar=*-*-* *:0/10:00'* ]]; then
		print_result "step minutes map to systemd calendar" 0
	else
		print_result "step minutes map to systemd calendar" 1 \
			"Expected OnCalendar=*-*-* *:0/10:00, got: $output"
	fi
	return 0
}

test_execstart_uses_systemd_quoting() {
	local tmp_home=""
	local service_file=""
	local exec_start=""
	local expected=""
	tmp_home=$(mktemp -d)
	service_file="${tmp_home}/.config/systemd/user/sh.aidevops.routine-test.service"

	HOME="$tmp_home" "$ROUTINE_HELPER" install-systemd \
		--name test \
		--schedule '0 9 * * *' \
		--dir "$tmp_home" \
		--prompt 'test prompt' >/dev/null 2>&1
	exec_start=$(grep '^ExecStart=' "$service_file")
	expected="ExecStart=/bin/bash -lc \"'${tmp_home}/.aidevops/agents/scripts/headless-runtime-helper.sh' run --role worker --session-key 'routine-test' --dir '${tmp_home}' --agent 'Build+' --title 'Scheduled routine' --prompt-file '${tmp_home}/.aidevops/.agent-workspace/cron/scheduler-prompts/test.prompt'\""

	if [[ "$exec_start" == "$expected" && "$exec_start" != *"opencode run"* ]]; then
		print_result "ExecStart uses the canonical headless wrapper as one systemd argument" 0
	else
		print_result "ExecStart uses the canonical headless wrapper as one systemd argument" 1 \
			"Expected: $expected; got: $exec_start"
	fi
	rm -rf "$tmp_home"
	return 0
}

test_service_uses_control_group_cleanup() {
	local tmp_home=""
	local service_file=""
	local kill_mode=""
	tmp_home=$(mktemp -d)
	service_file="${tmp_home}/.config/systemd/user/sh.aidevops.routine-test.service"

	HOME="$tmp_home" "$ROUTINE_HELPER" install-systemd \
		--name test \
		--schedule '0 9 * * *' \
		--dir "$tmp_home" \
		--prompt 'test prompt' >/dev/null 2>&1
	kill_mode=$(grep '^KillMode=' "$service_file" 2>/dev/null || true)

	if [[ "$kill_mode" == "KillMode=control-group" ]]; then
		print_result "routine service uses control-group cleanup" 0
	else
		print_result "routine service uses control-group cleanup" 1 \
			"Expected KillMode=control-group, got: ${kill_mode:-missing}"
	fi
	rm -rf "$tmp_home"
	return 0
}

test_daily_expression_supported() {
	local output=""
	output=$("${REPO_SCRIPTS_DIR}/routine-schedule-helper.sh" systemd-calendar 'daily(@03:30)')

	if [[ "$output" == '*-*-* 03:30:00' ]]; then
		print_result "daily repeat expression maps to systemd calendar" 0
	else
		print_result "daily repeat expression maps to systemd calendar" 1 \
			"Expected *-*-* 03:30:00, got: $output"
	fi
	return 0
}

test_pulse_step_minutes_supported() {
	local output=""
	output=$("${REPO_SCRIPTS_DIR}/routine-schedule-helper.sh" systemd-calendar 'cron(*/2 * * * *)')

	if [[ "$output" == '*-*-* *:0/2:00' ]]; then
		print_result "two-minute cron step maps to systemd calendar" 0
	else
		print_result "two-minute cron step maps to systemd calendar" 1 \
			"Expected *-*-* *:0/2:00, got: $output"
	fi
	return 0
}

test_empty_schedule_fails_cleanly() {
	local output
	local rc=0
	output=$("${REPO_SCRIPTS_DIR}/routine-schedule-helper.sh" parse '' 2>&1) || rc=$?

	if [[ "$rc" -ne 0 && "$output" != *"unary operator expected"* && "$output" == *"unrecognised schedule expression"* ]]; then
		print_result "empty schedule expression uses clean parse error" 0
	else
		print_result "empty schedule expression uses clean parse error" 1 \
			"Expected clean non-zero parse error, rc=$rc output: $output"
	fi
	return 0
}

main() {
	printf 'Running routine systemd calendar tests...\n\n'

	test_wildcard_weekday_omits_prefix
	test_numeric_weekday_keeps_prefix
	test_step_minutes_supported
	test_execstart_uses_systemd_quoting
	test_service_uses_control_group_cleanup
	test_daily_expression_supported
	test_pulse_step_minutes_supported
	test_empty_schedule_fails_cleanly

	printf '\n%s/%s tests passed.\n' \
		"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
