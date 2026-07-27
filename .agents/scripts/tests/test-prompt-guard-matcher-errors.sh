#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPT_GUARD="${SCRIPT_DIR}/prompt-guard-helper.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/prompt-guard-matcher-errors.XXXXXX")
readonly PROBE_CONTENT="ordinary matcher-error probe"
readonly EXPECTED_ERROR="Prompt-injection pattern scan failed"
passed=0
failed=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

INVALID_PATTERNS="${TEST_ROOT}/invalid-patterns.txt"
VALID_YAML="${TEST_ROOT}/valid-patterns.yaml"
MALFORMED_YAML="${TEST_ROOT}/malformed-patterns.yaml"
MISSING_CUSTOM="${TEST_ROOT}/missing-custom-patterns.txt"
PROBE_FILE="${TEST_ROOT}/probe.txt"
cat >"$INVALID_PATTERNS" <<'PATTERNS'
HIGH|test|Invalid regular expression|(
PATTERNS
cat >"$VALID_YAML" <<'YAML'
test:
  - severity: HIGH
    description: "Valid non-matching test pattern"
    pattern: 'MATCHER_ERROR_TEST_SENTINEL'
YAML
cat >"$MALFORMED_YAML" <<'YAML'
test:
  - severity: HIGH
    description: "Missing pattern field"
YAML
printf '%s\n' "$PROBE_CONTENT" >"$PROBE_FILE"

run_guard() {
	PROMPT_GUARD_CUSTOM_PATTERNS="$INVALID_PATTERNS" \
		PROMPT_GUARD_YAML_PATTERNS="$VALID_YAML" \
		PROMPT_GUARD_LOG_DIR="${TEST_ROOT}/logs" \
		PROMPT_GUARD_PERSIST_CONTENT=false \
		PROMPT_GUARD_QUIET=true \
		"$PROMPT_GUARD" "$@"
	return $?
}

run_guard_with_malformed_yaml() {
	PROMPT_GUARD_CUSTOM_PATTERNS="" \
		PROMPT_GUARD_YAML_PATTERNS="$MALFORMED_YAML" \
		PROMPT_GUARD_LOG_DIR="${TEST_ROOT}/logs" \
		PROMPT_GUARD_PERSIST_CONTENT=false \
		PROMPT_GUARD_QUIET=true \
		"$PROMPT_GUARD" "$@"
	return $?
}

run_guard_with_missing_custom() {
	PROMPT_GUARD_CUSTOM_PATTERNS="$MISSING_CUSTOM" \
		PROMPT_GUARD_YAML_PATTERNS="$VALID_YAML" \
		PROMPT_GUARD_LOG_DIR="${TEST_ROOT}/logs" \
		PROMPT_GUARD_PERSIST_CONTENT=false \
		PROMPT_GUARD_QUIET=true \
		"$PROMPT_GUARD" "$@"
	return $?
}

assert_fails_closed() {
	local description="$1"
	local expected_exit="$2"
	shift 2
	local output=""
	local actual_exit=0
	output=$(run_guard "$@" 2>&1) || actual_exit=$?
	if [[ "$actual_exit" -eq "$expected_exit" && "$output" == *"$EXPECTED_ERROR"* && \
		"$output" != *CLEAN* && "$output" != *ALLOW* ]]; then
		printf 'PASS %s\n' "$description"
		passed=$((passed + 1))
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s output=%s)\n' \
		"$description" "$expected_exit" "$actual_exit" "$output" >&2
	failed=$((failed + 1))
	return 0
}

assert_stdin_fails_closed() {
	local description="$1"
	local output=""
	local actual_exit=0
	output=$(printf '%s\n' "$PROBE_CONTENT" | run_guard scan-stdin 2>&1) || actual_exit=$?
	if [[ "$actual_exit" -eq 1 && "$output" == *"$EXPECTED_ERROR"* && \
		"$output" != *CLEAN* && "$output" != *ALLOW* ]]; then
		printf 'PASS %s\n' "$description"
		passed=$((passed + 1))
		return 0
	fi
	printf 'FAIL %s (actual=%s output=%s)\n' "$description" "$actual_exit" "$output" >&2
	failed=$((failed + 1))
	return 0
}

assert_yaml_source_fails_closed() {
	local description="$1"
	local output=""
	local actual_exit=0
	output=$(run_guard_with_malformed_yaml check "$PROBE_CONTENT" 2>&1) || actual_exit=$?
	if [[ "$actual_exit" -eq 1 && "$output" == *"YAML pattern loading failed"* && \
		"$output" == *"$EXPECTED_ERROR"* && "$output" != *CLEAN* && "$output" != *ALLOW* ]]; then
		printf 'PASS %s\n' "$description"
		passed=$((passed + 1))
		return 0
	fi
	printf 'FAIL %s (actual=%s output=%s)\n' "$description" "$actual_exit" "$output" >&2
	failed=$((failed + 1))
	return 0
}

assert_custom_source_fails_closed() {
	local description="$1"
	local output=""
	local actual_exit=0
	output=$(run_guard_with_missing_custom check "$PROBE_CONTENT" 2>&1) || actual_exit=$?
	if [[ "$actual_exit" -eq 1 && "$output" == *"custom prompt-injection patterns are unavailable"* && \
		"$output" == *"$EXPECTED_ERROR"* && "$output" != *CLEAN* && "$output" != *ALLOW* ]]; then
		printf 'PASS %s\n' "$description"
		passed=$((passed + 1))
		return 0
	fi
	printf 'FAIL %s (actual=%s output=%s)\n' "$description" "$actual_exit" "$output" >&2
	failed=$((failed + 1))
	return 0
}

assert_fails_closed "check blocks matcher errors" 1 check "$PROBE_CONTENT"
assert_fails_closed "scan rejects matcher errors" 1 scan "$PROBE_CONTENT"
assert_fails_closed "score rejects matcher errors" 1 score "$PROBE_CONTENT"
assert_fails_closed "check-file blocks matcher errors" 1 check-file "$PROBE_FILE"
assert_fails_closed "scan-file rejects matcher errors" 1 scan-file "$PROBE_FILE"
assert_fails_closed "sanitize rejects matcher errors" 1 sanitize "<system>${PROBE_CONTENT}</system>"
assert_fails_closed "deep classification reports matcher errors" 2 classify-deep "$PROBE_CONTENT"
assert_stdin_fails_closed "scan-stdin rejects matcher errors"
assert_yaml_source_fails_closed "check blocks malformed YAML pattern sources"
assert_custom_source_fails_closed "check blocks unavailable custom pattern sources"

printf '\nResults: %s passed, %s failed\n' "$passed" "$failed"
if [[ "$failed" -gt 0 ]]; then
	exit 1
fi
exit 0
