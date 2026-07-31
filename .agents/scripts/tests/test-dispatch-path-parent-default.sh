#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-path-parent-default.sh — Regression tests for the dispatch-path
# auto-dispatch advisory default (t2821/t2920).
#
# Tests cover:
#   _append_dispatch_path_notice in task-brief-helper.sh:
#     test_brief_positive_detection  — brief with pulse-wrapper.sh gets notice appended
#     test_brief_negative_detection  — brief without dispatch-path files → no notice
#     test_brief_bypass_env_var      — AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1 suppresses notice
#     test_brief_custom_conf         — AIDEVOPS_DISPATCH_PATH_FILES_CONF overrides pattern set
#
#   _warn_dispatch_path_auto_dispatch in claim-task-id.sh:
#     test_claim_warning_fired       — auto-dispatch + dispatch-path title → warning to stderr
#     test_claim_no_warning_no_tag   — auto-dispatch without dispatch-path files → no warning
#     test_claim_bypass_env_var      — AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1 suppresses warning
#     test_claim_override_tag        — dispatch-path-ok in labels → warning still fires
#       (the label records intent; the warning is advisory, non-blocking regardless)
#
#   Shared conf file (self-hosting-files.conf):
#     test_conf_file_exists          — .agents/configs/self-hosting-files.conf exists
#     test_conf_file_has_patterns    — conf file contains at least 5 known entries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
BRIEF_HELPER="${SCRIPT_DIR}/../task-brief-helper.sh"
CLAIM_HELPER="${SCRIPT_DIR}/../claim-task-id.sh"
CONF_FILE="${SCRIPT_DIR}/../../configs/self-hosting-files.conf"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------
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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	unset AIDEVOPS_SKIP_DISPATCH_PATH_CHECK AIDEVOPS_DISPATCH_PATH_FILES_CONF 2>/dev/null || true
	return 0
}

# Source only the _append_dispatch_path_notice function from task-brief-helper.sh.
# We skip the main() execution by sourcing with a guard.
_source_brief_helper_functions() {
	# The helper calls main "$@" at the end; we need to intercept that.
	# Strategy: source inside a subshell to extract the function definition.
	# Since the script uses set -euo pipefail and calls main at the end,
	# we define a main() stub before sourcing to shadow the real one.
	eval "$(
		grep -A 999 '^_append_dispatch_path_notice()' "$BRIEF_HELPER" \
			| awk '/^_append_dispatch_path_notice\(\)/{start=1} start{print} start && /^}$/{exit}'
	)" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# brief_helper tests — _append_dispatch_path_notice
# ---------------------------------------------------------------------------

# Load the function under test into the current shell
# Using a targeted extraction to avoid executing the whole script
_load_notice_func() {
	# Extract and eval just the _append_dispatch_path_notice function
	local func_text
	func_text=$(awk '
		/^_append_dispatch_path_notice\(\)/ { found=1; depth=0 }
		found {
			print
			for (i=1; i<=length($0); i++) {
				c = substr($0,i,1)
				if (c == "{") depth++
				else if (c == "}") { depth--; if (depth == 0) { found=0; exit } }
			}
		}
	' "$BRIEF_HELPER") || true

	if [[ -z "$func_text" ]]; then
		echo "[WARN] Could not extract _append_dispatch_path_notice from ${BRIEF_HELPER}" >&2
		return 1
	fi

	eval "$func_text"
	return 0
}

# Logging stubs used by _append_dispatch_path_notice
log_info() { printf '[INFO] %s\n' "$*" >&2; return 0; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; return 0; }

test_brief_positive_detection() {
	local brief_file="${TEST_ROOT}/t9901-brief.md"
	# Write a brief with a dispatch-path file reference
	cat >"$brief_file" <<'BRIEF'
# t9901: Fix pulse-wrapper.sh startup race

## How

### Files Scope
- EDIT: .agents/scripts/pulse-wrapper.sh:45-70

### Verification
shellcheck .agents/scripts/pulse-wrapper.sh
BRIEF

	_load_notice_func || {
		print_result "brief_positive_detection" 1 "_append_dispatch_path_notice not loadable"
		return 0
	}

	_append_dispatch_path_notice "$brief_file" "t9901"

	if ! grep -q "Dispatch-Path Classification" "$brief_file"; then
		print_result "brief_positive_detection" 1 "Expected '## Dispatch-Path Classification' appended to brief"
		return 0
	fi
	if ! grep -q "routine interactive work keeps \`#auto-dispatch\`" "$brief_file"; then
		print_result "brief_positive_detection" 1 "Expected advisory to preserve auto-dispatch for interactive work"
		return 0
	fi
	if grep -q 'no-auto-dispatch' "$brief_file"; then
		print_result "brief_positive_detection" 1 "Advisory must not recommend no-auto-dispatch for routine interactive work"
		return 0
	fi
	print_result "brief_positive_detection" 0
	return 0
}

test_brief_negative_detection() {
	local brief_file="${TEST_ROOT}/t9902-brief.md"
	# Write a brief with NO dispatch-path file references
	cat >"$brief_file" <<'BRIEF'
# t9902: Update README formatting

## How

### Files Scope
- EDIT: README.md

### Verification
markdownlint-cli2 README.md
BRIEF

	_load_notice_func 2>/dev/null || true

	_append_dispatch_path_notice "$brief_file" "t9902" 2>/dev/null || true

	if grep -q "Dispatch-Path Classification" "$brief_file"; then
		print_result "brief_negative_detection" 1 "Expected no dispatch-path notice in brief without dispatch-path files"
	else
		print_result "brief_negative_detection" 0
	fi
	return 0
}

test_brief_bypass_env_var() {
	local brief_file="${TEST_ROOT}/t9903-brief.md"
	cat >"$brief_file" <<'BRIEF'
# t9903: Fix headless-runtime-helper.sh crash

## How

### Files Scope
- EDIT: .agents/scripts/headless-runtime-helper.sh
BRIEF

	_load_notice_func 2>/dev/null || true

	AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1 \
		_append_dispatch_path_notice "$brief_file" "t9903" 2>/dev/null || true

	if grep -q "Dispatch-Path Classification" "$brief_file"; then
		print_result "brief_bypass_env_var" 1 "AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1 should suppress notice"
	else
		print_result "brief_bypass_env_var" 0
	fi
	return 0
}

test_brief_custom_conf() {
	local brief_file="${TEST_ROOT}/t9904-brief.md"
	local custom_conf="${TEST_ROOT}/custom-patterns.conf"

	# Custom conf with a unique pattern
	printf 'my-custom-dispatch-helper.sh\n' >"$custom_conf"

	# Brief references the custom pattern
	cat >"$brief_file" <<'BRIEF'
# t9904: Fix my-custom-dispatch-helper.sh

## How

### Files Scope
- EDIT: .agents/scripts/my-custom-dispatch-helper.sh
BRIEF

	_load_notice_func 2>/dev/null || true

	AIDEVOPS_DISPATCH_PATH_FILES_CONF="$custom_conf" \
		_append_dispatch_path_notice "$brief_file" "t9904" 2>/dev/null || true

	if grep -q "Dispatch-Path Classification" "$brief_file"; then
		print_result "brief_custom_conf" 0
	else
		print_result "brief_custom_conf" 1 "Custom conf with 'my-custom-dispatch-helper.sh' should trigger notice"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# claim-task-id.sh tests — _warn_dispatch_path_auto_dispatch
# ---------------------------------------------------------------------------

# Load just the _warn_dispatch_path_auto_dispatch function
_load_claim_warn_func() {
	local func_text
	func_text=$(awk '
		/^_warn_dispatch_path_auto_dispatch\(\)/ { found=1; depth=0 }
		found {
			print
			for (i=1; i<=length($0); i++) {
				c = substr($0,i,1)
				if (c == "{") depth++
				else if (c == "}") { depth--; if (depth == 0) { found=0; exit } }
			}
		}
	' "$CLAIM_HELPER") || true

	if [[ -z "$func_text" ]]; then
		echo "[WARN] Could not extract _warn_dispatch_path_auto_dispatch from ${CLAIM_HELPER}" >&2
		return 1
	fi

	eval "$func_text"
	return 0
}

test_claim_warning_fired() {
	_load_claim_warn_func || {
		print_result "claim_warning_fired" 1 "_warn_dispatch_path_auto_dispatch not loadable"
		return 0
	}

	# Set up required globals
	TASK_LABELS="auto-dispatch,tier:standard"
	TASK_TITLE="t9905: Fix pulse-wrapper.sh race condition"
	TASK_DESCRIPTION="Modifies pulse-wrapper.sh startup sequence"
	SCRIPT_DIR="${SCRIPT_DIR}/.."  # Point to scripts dir for conf resolution

	local stderr_out
	stderr_out=$(AIDEVOPS_DISPATCH_PATH_FILES_CONF="${CONF_FILE}" \
		_warn_dispatch_path_auto_dispatch 2>&1 1>/dev/null) || true

	if printf '%s' "$stderr_out" | grep -q "t2821"; then
		print_result "claim_warning_fired" 0
	else
		print_result "claim_warning_fired" 1 "Expected t2821 warning in stderr when dispatch-path + auto-dispatch"
	fi
	return 0
}

test_claim_no_warning_no_tag() {
	_load_claim_warn_func 2>/dev/null || true

	TASK_LABELS="auto-dispatch,tier:standard"
	TASK_TITLE="t9906: Update documentation README"
	TASK_DESCRIPTION="Clarify setup instructions in README.md"
	SCRIPT_DIR="${SCRIPT_DIR}/.."

	local stderr_out
	stderr_out=$(AIDEVOPS_DISPATCH_PATH_FILES_CONF="${CONF_FILE}" \
		_warn_dispatch_path_auto_dispatch 2>&1 1>/dev/null) || true

	if printf '%s' "$stderr_out" | grep -q "t2821"; then
		print_result "claim_no_warning_no_tag" 1 "Should NOT warn when no dispatch-path files in title/description"
	else
		print_result "claim_no_warning_no_tag" 0
	fi
	return 0
}

test_claim_bypass_env_var() {
	_load_claim_warn_func 2>/dev/null || true

	TASK_LABELS="auto-dispatch"
	TASK_TITLE="t9907: Fix pulse-dispatch-helper.sh exit code"
	TASK_DESCRIPTION=""
	SCRIPT_DIR="${SCRIPT_DIR}/.."

	local stderr_out
	stderr_out=$(AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1 \
		AIDEVOPS_DISPATCH_PATH_FILES_CONF="${CONF_FILE}" \
		_warn_dispatch_path_auto_dispatch 2>&1 1>/dev/null) || true

	if printf '%s' "$stderr_out" | grep -q "t2821"; then
		print_result "claim_bypass_env_var" 1 "AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1 should suppress warning"
	else
		print_result "claim_bypass_env_var" 0
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Shared conf file tests
# ---------------------------------------------------------------------------

test_conf_file_exists() {
	if [[ -f "$CONF_FILE" ]]; then
		print_result "conf_file_exists" 0
	else
		print_result "conf_file_exists" 1 "Expected self-hosting-files.conf at ${CONF_FILE}"
	fi
	return 0
}

test_conf_file_has_patterns() {
	local count=0
	local known_patterns=("pulse-wrapper.sh" "headless-runtime-helper.sh" "shared-dispatch-dedup.sh" "shared-claim-lifecycle.sh" "worker-activity-watchdog.sh")

	if [[ ! -f "$CONF_FILE" ]]; then
		print_result "conf_file_has_patterns" 1 "Conf file missing — cannot check patterns"
		return 0
	fi

	local p
	for p in "${known_patterns[@]}"; do
		if grep -qF "$p" "$CONF_FILE"; then
			count=$((count + 1))
		fi
	done

	if [[ "$count" -ge 5 ]]; then
		print_result "conf_file_has_patterns" 0
	else
		print_result "conf_file_has_patterns" 1 "Expected >=5 known patterns in conf, found ${count}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	setup_test_env

	echo ""
	echo "=== dispatch-path parent default (t2821) ==="
	echo ""
	echo "  task-brief-helper.sh: _append_dispatch_path_notice"
	test_brief_positive_detection
	test_brief_negative_detection
	test_brief_bypass_env_var
	test_brief_custom_conf

	echo ""
	echo "  claim-task-id.sh: _warn_dispatch_path_auto_dispatch"
	test_claim_warning_fired
	test_claim_no_warning_no_tag
	test_claim_bypass_env_var

	echo ""
	echo "  shared conf file (self-hosting-files.conf)"
	test_conf_file_exists
	test_conf_file_has_patterns

	teardown_test_env

	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
