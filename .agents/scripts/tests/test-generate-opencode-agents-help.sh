#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for the observational CLI arguments of the deprecated
# OpenCode agent generator (GH#31108).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="$SCRIPT_DIR/../generate-opencode-agents.sh"
TEST_ROOT="$(mktemp -d "${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/test-generate-opencode-agents-help.XXXXXX")"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
NC=$'\033[0m'
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

assert_equal() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf '%sPASS%s %s\n' "$GREEN" "$NC" "$description"
		((PASS++))
	else
		printf '%sFAIL%s %s (got %s, expected %s)\n' "$RED" "$NC" "$description" "$actual" "$expected"
		((FAIL++))
	fi
	return 0
}

run_observational_case() {
	local argument="$1"
	local expected_status="$2"
	local case_root="$TEST_ROOT/$argument"
	local config_dir="$case_root/.config/opencode"
	local agent_dir="$config_dir/agent"
	local output
	local status

	mkdir -p "$agent_dir" "$case_root/.aidevops/agents"
	printf 'config sentinel\n' >"$config_dir/AGENTS.md"
	printf 'json sentinel\n' >"$config_dir/opencode.json"
	printf 'agent sentinel\n' >"$agent_dir/sentinel.md"

	set +e
	output=$(HOME="$case_root" bash "$GENERATOR" "$argument" 2>&1)
	status=$?

	assert_equal "$argument exits with expected status" "$expected_status" "$status"
	if [[ "$argument" == "--help" || "$argument" == "-h" || "$argument" == "help" ]]; then
		if [[ "$output" == *"Usage: generate-opencode-agents.sh"* && "$output" != *"Generating OpenCode agent configuration"* ]]; then
			printf '%sPASS%s %s prints usage without generation output\n' "$GREEN" "$NC" "$argument"
			((PASS++))
		else
			printf '%sFAIL%s %s did not print observational usage\n' "$RED" "$NC" "$argument"
			((FAIL++))
		fi
	else
		if [[ "$output" == *"unsupported argument: $argument"* && "$output" != *"Generating OpenCode agent configuration"* ]]; then
			printf '%sPASS%s invalid argument is rejected before generation\n' "$GREEN" "$NC"
			((PASS++))
		else
			printf '%sFAIL%s invalid argument was not rejected before generation\n' "$RED" "$NC"
			((FAIL++))
		fi
	fi

	assert_equal "$argument preserves AGENTS.md sentinel" "config sentinel" "$(<"$config_dir/AGENTS.md")"
	assert_equal "$argument preserves opencode.json sentinel" "json sentinel" "$(<"$config_dir/opencode.json")"
	assert_equal "$argument preserves generated-agent sentinel" "agent sentinel" "$(<"$agent_dir/sentinel.md")"
	return 0
}

run_observational_case --help 0
run_observational_case -h 0
run_observational_case help 0
run_observational_case --unsupported 2

printf '\n%s%d passed, %d failed%s\n' "$GREEN" "$PASS" "$FAIL" "$NC"
if [[ "$FAIL" -eq 0 ]]; then
	exit 0
fi
exit 1
