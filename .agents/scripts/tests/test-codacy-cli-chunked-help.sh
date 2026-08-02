#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
HELPER="${SCRIPT_DIR}/../codacy-cli-chunked.sh"

tests_run=0
tests_failed=0

run_case() {
	local case_name="$1"
	local expected_status="$2"
	local expected_text="$3"
	shift 3
	local output=""
	local status=0

	output=$(bash "$HELPER" "$@" 2>&1) || status=$?
	tests_run=$((tests_run + 1))
	if [[ "$status" -eq "$expected_status" ]] &&
		[[ "$output" == *"$expected_text"* ]] &&
		[[ "$output" != *"unbound variable"* ]]; then
		printf 'PASS: %s\n' "$case_name"
		return 0
	fi

	printf 'FAIL: %s (status=%s, expected=%s)\n%s\n' \
		"$case_name" "$status" "$expected_status" "$output" >&2
	tests_failed=$((tests_failed + 1))
	return 0
}

run_case "no arguments" 0 "Usage:"
run_case "help command" 0 "Usage:" help
run_case "long help flag" 0 "Usage:" --help
run_case "analyze requires a tool" 1 "Tool name required" analyze

printf 'Tests run: %d, failed: %d\n' "$tests_run" "$tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
exit 0
