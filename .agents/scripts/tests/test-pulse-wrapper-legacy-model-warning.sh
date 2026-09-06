#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
PULSE_SCRIPTS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)" || exit 1
readonly TEST_SCRIPT_DIR
readonly PULSE_SCRIPTS_DIR

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

run_config_source() {
	local test_home="$1"
	local stderr_file="$2"
	local headless_models="${3:-}"
	local pulse_model="${4:-}"
	local availability_helper="${5:-${test_home}/missing-model-availability-helper.sh}"

	(
		set -euo pipefail
		export HOME="$test_home"
		export SCRIPT_DIR="$PULSE_SCRIPTS_DIR"
		export MODEL_AVAILABILITY_HELPER="$availability_helper"
		if [[ -n "$headless_models" ]]; then
			export AIDEVOPS_HEADLESS_MODELS="$headless_models"
		else
			unset AIDEVOPS_HEADLESS_MODELS || true
		fi
		if [[ -n "$pulse_model" ]]; then
			export PULSE_MODEL="$pulse_model"
		else
			unset PULSE_MODEL || true
		fi

		config_get() {
			local key="$1"
			local default_value="$2"
			: "$key"
			printf '%s\n' "$default_value"
			return 0
		}

		_validate_int() {
			local var_name="$1"
			local value="$2"
			local default_value="$3"
			local min_value="${4:-}"
			: "$var_name" "$min_value"
			if [[ -n "$value" ]]; then
				printf '%s\n' "$value"
			else
				printf '%s\n' "$default_value"
			fi
			return 0
		}

		# shellcheck source=/dev/null
		source "${PULSE_SCRIPTS_DIR}/pulse-wrapper-config.sh" >/dev/null
		printf '%s' "$PULSE_MODEL" >"${test_home}/resolved-model"
	) 2>"$stderr_file"
	return $?
}

test_inherited_headless_models_without_credentials_export_is_quiet() {
	local test_home
	test_home="$(mktemp -d)"
	local stderr_file="${test_home}/stderr.log"
	mkdir -p "${test_home}/.config/aidevops"
	printf '# export AIDEVOPS_HEADLESS_MODELS=old\n' >"${test_home}/.config/aidevops/credentials.sh"

	run_config_source "$test_home" "$stderr_file" "openai/example" ""

	if [[ -s "$stderr_file" ]]; then
		print_result "inherited AIDEVOPS_HEADLESS_MODELS without active credentials export is quiet" 1 "stderr present"
	else
		print_result "inherited AIDEVOPS_HEADLESS_MODELS without active credentials export is quiet" 0
	fi

	rm -rf "$test_home"
	return 0
}

test_active_headless_models_credentials_export_warns_with_file() {
	local test_home
	test_home="$(mktemp -d)"
	local stderr_file="${test_home}/stderr.log"
	mkdir -p "${test_home}/.config/aidevops"
	printf 'export AIDEVOPS_HEADLESS_MODELS=old\n' >"${test_home}/.config/aidevops/credentials.sh"

	run_config_source "$test_home" "$stderr_file" "openai/example" ""

	if grep -q "AIDEVOPS_HEADLESS_MODELS" "$stderr_file" && grep -q "${test_home}/.config/aidevops/credentials.sh" "$stderr_file"; then
		print_result "active AIDEVOPS_HEADLESS_MODELS credentials export warns with file" 0
	else
		print_result "active AIDEVOPS_HEADLESS_MODELS credentials export warns with file" 1 "expected variable and file in warning"
	fi

	rm -rf "$test_home"
	return 0
}

test_active_pulse_model_assignment_warns_with_file() {
	local test_home
	test_home="$(mktemp -d)"
	local stderr_file="${test_home}/stderr.log"
	mkdir -p "${test_home}/.config/aidevops"
	printf 'PULSE_MODEL=old\n' >"${test_home}/.config/aidevops/credentials.sh"

	run_config_source "$test_home" "$stderr_file" "" "openai/example"

	if grep -q "PULSE_MODEL" "$stderr_file" && grep -q "${test_home}/.config/aidevops/credentials.sh" "$stderr_file"; then
		print_result "active PULSE_MODEL assignment warns with file" 0
	else
		print_result "active PULSE_MODEL assignment warns with file" 1 "expected variable and file in warning"
	fi

	rm -rf "$test_home"
	return 0
}

test_pulse_thinking_resolution_and_failure() {
	local test_home
	test_home="$(mktemp -d)"
	local helper="${test_home}/availability.sh"
	cat >"$helper" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == "resolve thinking --quiet" ]] || exit 1
printf '%s' 'openai/gpt-5.6-sol'
STUB
	chmod +x "$helper"
	run_config_source "$test_home" "${test_home}/stderr.log" "" "" "$helper"
	if [[ "$(<"${test_home}/resolved-model")" == "openai/gpt-5.6-sol" ]]; then
		print_result "pulse resolves the thinking daily driver" 0
	else
		print_result "pulse resolves the thinking daily driver" 1
	fi
	run_config_source "$test_home" "${test_home}/stderr.log"
	if [[ ! -s "${test_home}/resolved-model" ]]; then
		print_result "failed pre-resolution leaves fallback to headless policy" 0
	else
		print_result "failed pre-resolution leaves fallback to headless policy" 1
	fi
	rm -rf "$test_home"
	return 0
}

main() {
	test_inherited_headless_models_without_credentials_export_is_quiet
	test_active_headless_models_credentials_export_warns_with_file
	test_active_pulse_model_assignment_warns_with_file
	test_pulse_thinking_resolution_and_failure

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
