#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-wrapper-zsh-compat.sh — t2688 regression guard (GH#20300).
#
# Asserts that _gh_wrapper_extract_task_id_from_title does NOT emit
# `local:2: bad option: -n` and still extracts task IDs correctly when
# the function body is evaluated by zsh.
#
# Background
# ----------
# The t2436 implementation used `local -n` (bash 4.3+ namerefs) for
# multi-value returns. Namerefs are a bash-only feature — zsh's `local`
# does not accept `-n` and emits `local:N: bad option: -n`, leaving the
# target variables unset (so the t2436 race-closing label-at-creation
# mechanism silently degrades to the async path).
#
# The fix (t2688) replaces namerefs with module-level globals
# (_GH_WRAPPER_EXTRACT_TODO, _GH_WRAPPER_EXTRACT_TITLE), mirroring the
# pattern already in task-brief-helper.sh:643,757 for the same reason.
#
# macOS vs Linux
# --------------
# macOS: /bin/bash is 3.2 and /bin/zsh is the default login shell. The
# re-exec guard in shared-constants.sh transparently re-execs scripts
# under Homebrew bash 4+, but the guard is bash-only — it cannot fire
# when zsh itself is the running shell (e.g., a user sources a helper
# from .zshrc or a zsh subshell invokes the function). This test
# covers that gap.
#
# Linux: /bin/bash is already 4+/5+ so the namerefs "work" on Linux
# bash — but zsh users on Linux hit the same bug. This test runs
# wherever zsh is installed, regardless of OS.
#
# Skip behaviour
# --------------
# If zsh is not installed (rare on macOS; possible on minimal Linux
# CI runners), the test emits a SKIP notice and exits 0 — it is a
# best-effort supplementary guard, not a hard gate. The other t2436
# tests (test-parent-tag-sync.sh scenarios 2b, 2c) already validate
# the bash path.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_YELLOW=$'\033[1;33m'
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

print_skip() {
	local name="$1" reason="$2"
	printf '%sSKIP%s %s (%s)\n' "$TEST_YELLOW" "$TEST_RESET" "$name" "$reason"
	return 0
}

# =============================================================================
# Environment check
# =============================================================================
if ! command -v zsh >/dev/null 2>&1; then
	print_skip "t2688 zsh-compat smoke test" "zsh not installed"
	printf '\n%sTests run: 0, failed: 0 (skipped — zsh unavailable)%s\n' \
		"$TEST_YELLOW" "$TEST_RESET"
	exit 0
fi

# =============================================================================
# Scenario 1 — function body does NOT emit `local -n` error under zsh
# =============================================================================
#
# Extract just the two function definitions from shared-gh-wrappers.sh
# (the full file cannot be sourced by zsh because of top-level BASH_SOURCE
# references). Feed them to a fresh zsh process and invoke with a
# --todo-task-id flag. The extraction path is simple string compare —
# no `=~` / BASH_REMATCH — so it works identically under bash and zsh.

WRAPPERS_FILE="${TEST_SCRIPTS_DIR}/shared-gh-wrappers.sh"
WRAPPERS_CREATE_FILE="${TEST_SCRIPTS_DIR}/shared-gh-wrappers-create.sh"
if [[ ! -f "$WRAPPERS_FILE" ]]; then
	print_result "t2688: shared-gh-wrappers.sh exists" 1 "(missing: $WRAPPERS_FILE)"
	printf '\n%sTests run: %d, failed: %d%s\n' \
		"$TEST_RED" "$TESTS_RUN" "$TESTS_FAILED" "$TEST_RESET"
	exit 1
fi
if [[ ! -f "$WRAPPERS_CREATE_FILE" ]]; then
	print_result "t2688: shared-gh-wrappers-create.sh exists" 1 "(missing: $WRAPPERS_CREATE_FILE)"
	printf '\n%sTests run: %d, failed: %d%s\n' \
		"$TEST_RED" "$TESTS_RUN" "$TESTS_FAILED" "$TEST_RESET"
	exit 1
fi

# Extract the two function bodies using awk. Both start with the function
# name followed by `()` and end with the next top-level `}` at column 0.
extract_function() {
	local fname="$1" file="$2"
	awk -v fn="$fname" '
		$0 ~ "^" fn "\\(\\) \\{" { in_fn=1 }
		in_fn { print }
		in_fn && /^}$/ { in_fn=0 }
	' "$file"
	return 0
}

# t2997: drop .sh — XXXXXX must be at end for BSD mktemp.
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/t2688-zsh-snippet.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT

{
	extract_function _gh_wrapper_extract_task_id_from_title "$WRAPPERS_CREATE_FILE"
	printf '\n'
	extract_function _gh_wrapper_extract_task_id_from_title_step "$WRAPPERS_CREATE_FILE"
	printf '\n'
	# shellcheck disable=SC2016 # Intentional: emit literal $() / $result for zsh to evaluate.
	printf '%s\n' 'result=$(_gh_wrapper_extract_task_id_from_title --todo-task-id t2688 2>&1)'
	# shellcheck disable=SC2016 # Intentional: emit literal $result for zsh to evaluate.
	printf '%s\n' 'echo "$result"'
} >"$TMPFILE"

zsh_output=$(zsh "$TMPFILE" 2>&1)

# Assertion 1a: zsh output does not contain the signature error.
msg_1a="1a: zsh invocation does not emit 'local:N: bad option: -n'"
if [[ "$zsh_output" == *"bad option: -n"* ]]; then
	print_result "$msg_1a" 1 "(zsh output: ${zsh_output})"
else
	print_result "$msg_1a" 0
fi

# Assertion 1b: --todo-task-id extraction returns the expected value.
msg_1b="1b: --todo-task-id extraction returns 't2688' under zsh"
if [[ "$zsh_output" == "t2688" ]]; then
	print_result "$msg_1b" 0
else
	print_result "$msg_1b" 1 "(expected 't2688', got: '${zsh_output}')"
fi

# =============================================================================
# Scenario 2 — _gh_with_timeout detects zsh shell functions directly
# =============================================================================
#
# PR #22359 taught _gh_with_timeout to bypass coreutils timeout when the wrapped
# command is a shell function (test stubs cannot be exec'd by timeout). The first
# implementation used bash-only `type -t`, which silently failed under zsh and
# routed function stubs through timeout anyway. Keep a zsh regression guard for
# the direct function-dispatch path.

{
	extract_function _gh_timeout_path_from_args "$WRAPPERS_FILE"
	printf '\n'
	extract_function _gh_record_timeout_if_needed "$WRAPPERS_FILE"
	printf '\n'
	extract_function _gh_timeout_logical_id "$WRAPPERS_FILE"
	printf '\n'
	extract_function _gh_with_timeout "$WRAPPERS_FILE"
	printf '\n'
	printf '%s\n' '_gh_cooldown_context_from_args(){ return 0; }'
	printf '%s\n' '_gh_record_cooldown_response_if_needed(){ return 0; }'
	# shellcheck disable=SC2016 # Intentional: emit zsh function definitions literally.
	printf '%s\n' 'fake_gh(){ echo "fake-gh-called:$*"; return 0; }'
	# shellcheck disable=SC2016 # If function detection regresses, this captures the timeout route.
	printf '%s\n' 'timeout(){ echo "timeout-called:$*"; return 88; }'
	printf '%s\n' '_gh_with_timeout write fake_gh issue edit 123'
} >"$TMPFILE"

zsh_timeout_output=$(zsh "$TMPFILE" 2>&1)

msg_2="2: _gh_with_timeout calls zsh function stubs directly"
if [[ "$zsh_timeout_output" == "fake-gh-called:issue edit 123" ]]; then
	print_result "$msg_2" 0
else
	print_result "$msg_2" 1 "(expected direct function call, got: '${zsh_timeout_output}')"
fi

# =============================================================================
# Scenario 3 — source guard: no `local -n` anywhere in the two functions
# =============================================================================
#
# Syntactic guard — prevents a future edit from re-introducing namerefs.
# Matches the lines between the two function signatures only, so unrelated
# `local -n` usages elsewhere in the file (if any ever appeared) wouldn't
# affect this assertion.

msg_3="3: no 'local -n' in _gh_wrapper_extract_task_id_from_title{,_step}"
if awk '
	/^_gh_wrapper_extract_task_id_from_title(_step)?\(\) \{/ { in_fn=1 }
	in_fn && /[[:space:]]local -n / { found=1 }
	in_fn && /^}$/ { in_fn=0 }
	END { exit (found ? 1 : 0) }
' "$WRAPPERS_CREATE_FILE"; then
	print_result "$msg_3" 0
else
	print_result "$msg_3" 1 "(found 'local -n' — fix regressed)"
fi

# =============================================================================
# Summary
# =============================================================================
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\n%sTests run: %d, failed: 0%s\n' \
		"$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '\n%sTests run: %d, failed: %d%s\n' \
		"$TEST_RED" "$TESTS_RUN" "$TESTS_FAILED" "$TEST_RESET"
	exit 1
fi
