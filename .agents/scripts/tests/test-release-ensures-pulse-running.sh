#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SETUP_SCRIPT="${REPO_ROOT}/setup.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cleanup() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

load_setup_restart_helper() {
	local helper_definition=""
	helper_definition="$(awk '
		/^_setup_restart_pulse_if_running\(\) \{/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$SETUP_SCRIPT")"

	if [[ -z "$helper_definition" ]]; then
		printf 'failed to load helper from %s\n' "$SETUP_SCRIPT" >&2
		return 1
	fi

	eval "$helper_definition"
	return 0
}

run_restart_helper_with_stub() {
	local skip_value="$1"
	local pulse_enabled="$2"
	local pulse_consent="$3"
	local output_dir="$4"
	local restart_rc="${5:-0}"
	local log_path="${output_dir}/pulse-helper.log"
	local pin_root="${6:-}"
	local stub_pin_rc="${7:-1}"
	local helper_rc=0
	mkdir -p "${output_dir}/.aidevops/agents/scripts"

	(
		HOME="$output_dir"
		AIDEVOPS_SKIP_PULSE_RESTART="$skip_value"
		if [[ "$pulse_enabled" == "unset" ]]; then
			unset PULSE_ENABLED
		else
			PULSE_ENABLED="$pulse_enabled"
		fi
		print_warning() { printf 'warning: %s\n' "$*"; return 0; }
		print_error() { printf 'error: %s\n' "$*" >&2; return 0; }
		_resolve_pulse_consent() { printf '%s' "$pulse_consent"; return 0; }
		resolve_aidevops_runtime_bundle_root() {
			local requested_root="$1"
			printf '%s\n' "$requested_root"
			return 0
		}
		pulse_runtime_pin_resolve() {
			[[ -n "$pin_root" ]] || return "$stub_pin_rc"
			printf '%s\n' "$pin_root"
			return 0
		}
		_restart_pulse_if_running() {
			local activated_root="$1"
			local managed_enabled="$2"
			local active_link="$3"
			printf '%s|%s|%s\n' "$activated_root" "$managed_enabled" "$active_link" >>"$log_path"
			return "$restart_rc"
		}
		load_setup_restart_helper
		_setup_restart_pulse_if_running
	) || helper_rc=$?

	if [[ -f "$log_path" ]]; then
		tr '\n' ' ' <"$log_path"
	fi
	return "$helper_rc"
}

test_release_path_starts_stopped_pulse() {
	local output=""
	output="$(run_restart_helper_with_stub "0" "true" "" "${TEST_DIR}/start-stopped")"

	if [[ "$output" == *"|true|"* ]]; then
		print_result "release deploy reconciles Pulse when its supervisor is enabled" 0
		return 0
	fi

	print_result "release deploy reconciles Pulse when its supervisor is enabled" 1 "helper calls=${output}"
	return 0
}

test_disabled_supervisor_is_forwarded_to_reconcile() {
	local output=""
	output="$(run_restart_helper_with_stub "0" "false" "" "${TEST_DIR}/disabled")"

	if [[ "$output" == *"|false|"* ]]; then
		print_result "release deploy preserves disabled Pulse supervisor state" 0
		return 0
	fi

	print_result "release deploy preserves disabled Pulse supervisor state" 1 "helper calls=${output}"
	return 0
}

test_scoped_deploy_resolves_existing_consent() {
	local output=""
	output="$(run_restart_helper_with_stub "0" "unset" "true" "${TEST_DIR}/scoped")"

	if [[ "$output" == *"|true|"* ]]; then
		print_result "scoped agent deploy preserves enabled Pulse consent" 0
		return 0
	fi

	print_result "scoped agent deploy preserves enabled Pulse consent" 1 "helper calls=${output}"
	return 0
}

test_skip_flag_suppresses_restart_and_start() {
	local output=""
	output="$(run_restart_helper_with_stub "1" "true" "" "${TEST_DIR}/skip-flag")"

	if [[ -z "$output" ]]; then
		print_result "skip flag suppresses release pulse restart and start" 0
		return 0
	fi

	print_result "skip flag suppresses release pulse restart and start" 1 "helper calls=${output}"
	return 0
}

test_active_runtime_pin_overrides_release_bundle() {
	local output=""
	local root="${TEST_DIR}/pinned/.aidevops/runtime-bundles/pinned/agents"
	output="$(run_restart_helper_with_stub "0" "true" "" "${TEST_DIR}/pinned" "0" "$root")"
	if [[ "$output" == "${root}|true|${root} " ]]; then
		print_result "release deploy reconciles Pulse against its active runtime pin" 0
		return 0
	fi
	print_result "release deploy reconciles Pulse against its active runtime pin" 1 "helper calls=${output}"
	return 0
}

test_reconciliation_failure_blocks_setup_success() {
	local output=""
	local rc=0
	output="$(run_restart_helper_with_stub "0" "true" "" "${TEST_DIR}/failure" "1")" || rc=$?

	if [[ "$rc" -eq 1 && "$output" == *"|true|"* ]]; then
		print_result "release deploy fails closed when Pulse runtime proof fails" 0
		return 0
	fi

	print_result "release deploy fails closed when Pulse runtime proof fails" 1 "rc=${rc} helper calls=${output}"
	return 0
}

test_invalid_runtime_pin_blocks_reconciliation() {
	local output=""
	local rc=0
	output="$(run_restart_helper_with_stub "0" "true" "" "${TEST_DIR}/invalid-pin" "0" "" "2")" || rc=$?

	if [[ "$rc" -eq 1 && -z "$output" ]]; then
		print_result "release deploy fails closed on an invalid Pulse runtime pin" 0
		return 0
	fi

	print_result "release deploy fails closed on an invalid Pulse runtime pin" 1 "rc=${rc} helper calls=${output}"
	return 0
}

main() {
	TEST_DIR="$(mktemp -d)"
	trap cleanup EXIT

	test_release_path_starts_stopped_pulse
	test_disabled_supervisor_is_forwarded_to_reconcile
	test_scoped_deploy_resolves_existing_consent
	test_skip_flag_suppresses_restart_and_start
	test_active_runtime_pin_overrides_release_bundle
	test_reconciliation_failure_blocks_setup_success
	test_invalid_runtime_pin_blocks_reconciliation

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
