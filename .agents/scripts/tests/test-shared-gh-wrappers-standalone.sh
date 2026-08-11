#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-shared-gh-wrappers-standalone.sh — GH#20486 regression guard.
#
# Asserts that sourcing shared-gh-wrappers.sh ALONE (without shared-constants.sh)
# does NOT emit 'command not found: print_info' or 'command not found: print_warning',
# and that all major wrapper functions are defined after standalone sourcing.
#
# Root cause (GH#20486, discovered during t2744 / PR #20483):
#   Sourcing shared-gh-wrappers.sh in a fresh shell (without also sourcing
#   shared-constants.sh) caused gh_create_pr to fail silently with:
#     bash: print_info: command not found
#   The caller fell back to raw `gh pr create`, which created a PR WITHOUT
#   the `origin:interactive` label, breaking the maintainer gate state.
#
# Fix (t2743, PR #20490, shipped 2026-04-22):
#   shared-gh-wrappers.sh now defines guarded print_info / print_warning
#   stubs at load time using `if ! command -v print_X >/dev/null 2>&1`.
#   Stubs are minimal fprintf wrappers; the canonical implementations from
#   shared-constants.sh override them transparently when that file is also
#   sourced.
#
# Test scenarios:
#   1. bash: standalone source emits no 'command not found' stderr
#   2. bash: print_info is defined (as stub) after standalone sourcing
#   3. bash: print_warning is defined (as stub) after standalone sourcing
#   4. bash: all major wrapper functions defined after standalone sourcing
#   5. bash: sourcing both files (constants first) keeps canonical print_info
#   6. zsh:  standalone source emits no 'command not found' stderr (skip if no zsh)
#   7. zsh:  print_info + print_warning defined after standalone sourcing (skip if no zsh)
#   8. zsh:  all major wrapper functions defined after standalone sourcing (skip if no zsh)
#   9. zsh:  gh_create_pr --help emits no cleanup/trap errors (skip if no zsh)

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_YELLOW=$'\033[1;33m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_YELLOW="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

skip() {
	printf '  %sSKIP%s %s (%s)\n' "$TEST_YELLOW" "$TEST_NC" "$1" "${2:-}"
	return 0
}

WRAPPERS_FILE="${SCRIPTS_DIR}/shared-gh-wrappers.sh"
CONSTANTS_FILE="${SCRIPTS_DIR}/shared-constants.sh"

if [[ ! -f "$WRAPPERS_FILE" ]]; then
	printf '%sFATAL%s shared-gh-wrappers.sh not found at %s\n' \
		"$TEST_RED" "$TEST_NC" "$WRAPPERS_FILE"
	exit 1
fi

printf '%sRunning shared-gh-wrappers standalone-source tests (GH#20486)%s\n' \
	"$TEST_GREEN" "$TEST_NC"

# =============================================================================
# Test 1: bash — standalone source emits no 'command not found' stderr
# =============================================================================
printf '\n=== bash standalone source tests ===\n'

bash_stderr=$(LC_ALL=C bash -c 'source "$1"' -- "${WRAPPERS_FILE}" 2>&1 >/dev/null)
bash_exit=$?
if [[ $bash_exit -ne 0 ]] && [[ -n "$bash_stderr" ]] && ! printf '%s\n' "$bash_stderr" | grep -q 'command not found'; then
	fail "1: bash standalone source emits no 'command not found'" \
		"execution failed: $bash_stderr"
elif printf '%s\n' "$bash_stderr" | grep -q 'command not found'; then
	fail "1: bash standalone source emits no 'command not found'" \
		"stderr: $bash_stderr"
else
	pass "1: bash standalone source emits no 'command not found'"
fi

# =============================================================================
# Test 2: bash — print_info defined (as stub) after standalone sourcing
# =============================================================================
bash_print_info=$(bash -c "
source '${WRAPPERS_FILE}' 2>/dev/null
if command -v print_info >/dev/null 2>&1; then
    printf 'DEFINED\n'
else
    printf 'MISSING\n'
fi
" 2>&1)

if [[ "$bash_print_info" == *"DEFINED"* ]]; then
	pass "2: bash: print_info defined after standalone sourcing"
else
	fail "2: bash: print_info defined after standalone sourcing" \
		"output: $(printf '%q' "$bash_print_info")"
fi

# =============================================================================
# Test 3: bash — print_warning defined (as stub) after standalone sourcing
# =============================================================================
bash_print_warning=$(bash -c "
source '${WRAPPERS_FILE}' 2>/dev/null
if command -v print_warning >/dev/null 2>&1; then
    printf 'DEFINED\n'
else
    printf 'MISSING\n'
fi
" 2>&1)

if [[ "$bash_print_warning" == *"DEFINED"* ]]; then
	pass "3: bash: print_warning defined after standalone sourcing"
else
	fail "3: bash: print_warning defined after standalone sourcing" \
		"output: $(printf '%q' "$bash_print_warning")"
fi

# =============================================================================
# Test 4: bash — all major wrapper functions defined after standalone sourcing
# =============================================================================
bash_wrappers=$(bash -c "
source '${WRAPPERS_FILE}' 2>/dev/null
missing=''
for fn in gh_create_issue gh_create_pr gh_issue_comment gh_pr_comment gh_issue_edit_safe set_issue_status; do
    if ! command -v \"\$fn\" >/dev/null 2>&1; then
        missing=\"\$missing \$fn\"
    fi
done
if [[ -z \"\$missing\" ]]; then
    printf 'OK\n'
else
    printf 'MISSING:%s\n' \"\$missing\"
fi
" 2>&1)

if [[ "$bash_wrappers" == *"OK"* ]]; then
	pass "4: bash: all major wrapper functions defined after standalone sourcing"
else
	fail "4: bash: all major wrapper functions defined after standalone sourcing" \
		"output: $(printf '%q' "$bash_wrappers")"
fi

# =============================================================================
# Test 4b: caller-owned SCRIPT_DIR cannot skip the public-write privacy guard.
# =============================================================================
bash_privacy_guard=$(SCRIPT_DIR="${SCRIPT_DIR_TEST}/missing-caller-dir" bash -c "
source '${WRAPPERS_FILE}' 2>/dev/null
if command -v privacy_guard_public_write >/dev/null 2>&1; then
    printf 'DEFINED\\n'
else
    printf 'MISSING\\n'
fi
" 2>&1)
if [[ "$bash_privacy_guard" == *"DEFINED"* ]]; then
	pass "4b: bash: caller SCRIPT_DIR cannot skip public-write privacy dependency"
else
	fail "4b: bash: caller SCRIPT_DIR cannot skip public-write privacy dependency" \
		"output: $(printf '%q' "$bash_privacy_guard")"
fi

# =============================================================================
# Test 5: bash — sourcing constants FIRST then wrappers keeps canonical print_info
#          (stubs do NOT override the canonical implementation)
# =============================================================================
if [[ -f "$CONSTANTS_FILE" ]]; then
	bash_canonical=$(bash -c "
source '${CONSTANTS_FILE}' 2>/dev/null
# Capture full function definition before sourcing wrappers
before_def=\$(declare -f print_info)
source '${WRAPPERS_FILE}' 2>/dev/null
after_def=\$(declare -f print_info)
# Both should be identical if the stub did not override the canonical
if [[ \"\$before_def\" == \"\$after_def\" ]]; then
    printf 'CONSISTENT\n'
else
    printf 'CHANGED: definition was modified\n'
fi
" 2>&1)
	if [[ "$bash_canonical" == *"CONSISTENT"* ]]; then
		pass "5: bash: canonical print_info from shared-constants.sh not overridden by stubs"
	else
		fail "5: bash: canonical print_info from shared-constants.sh not overridden by stubs" \
			"output: $(printf '%q' "$bash_canonical")"
	fi
else
	skip "5: bash: canonical print_info not overridden by stubs" "shared-constants.sh not found"
fi

# =============================================================================
# Tests 6-8: zsh
# =============================================================================
printf '\n=== zsh standalone source tests ===\n'

if ! command -v zsh >/dev/null 2>&1; then
	skip "6: zsh standalone source emits no 'command not found'" "zsh not installed"
	skip "7: zsh: print_info + print_warning defined after standalone sourcing" "zsh not installed"
	skip "8: zsh: all major wrapper functions defined after standalone sourcing" "zsh not installed"
else
	# Test 6: zsh — standalone source emits no 'command not found' stderr
	zsh_stderr=$(LC_ALL=C zsh -c 'source "$1"' -- "${WRAPPERS_FILE}" 2>&1 >/dev/null)
	zsh_exit=$?
	if [[ $zsh_exit -ne 0 ]] && [[ -n "$zsh_stderr" ]] && ! printf '%s\n' "$zsh_stderr" | grep -q 'command not found'; then
		fail "6: zsh standalone source emits no 'command not found'" \
			"execution failed: $zsh_stderr"
	elif printf '%s\n' "$zsh_stderr" | grep -q 'command not found'; then
		fail "6: zsh standalone source emits no 'command not found'" \
			"stderr: $zsh_stderr"
	else
		pass "6: zsh standalone source emits no 'command not found'"
	fi

	# Test 7: zsh — print_info and print_warning defined after standalone sourcing
	zsh_stubs=$(zsh -c "
source '${WRAPPERS_FILE}' 2>/dev/null
missing=''
if ! (( \${+functions[print_info]} )); then missing=\"\$missing print_info\"; fi
if ! (( \${+functions[print_warning]} )); then missing=\"\$missing print_warning\"; fi
if [[ -z \"\$missing\" ]]; then
    printf 'DEFINED\n'
else
    printf 'MISSING:%s\n' \"\$missing\"
fi
" 2>&1)
	if [[ "$zsh_stubs" == *"DEFINED"* ]]; then
		pass "7: zsh: print_info + print_warning defined after standalone sourcing"
	else
		fail "7: zsh: print_info + print_warning defined after standalone sourcing" \
			"output: $(printf '%q' "$zsh_stubs")"
	fi

	# Test 8: zsh — all major wrapper functions defined after standalone sourcing
	zsh_wrappers=$(zsh -c "
source '${WRAPPERS_FILE}' 2>/dev/null
missing=''
for fn in gh_create_issue gh_create_pr gh_issue_comment gh_pr_comment gh_issue_edit_safe set_issue_status; do
    if ! (( \${+functions[\$fn]} )); then
        missing=\"\$missing \$fn\"
    fi
done
if [[ -z \"\$missing\" ]]; then
    printf 'OK\n'
else
    printf 'MISSING:%s\n' \"\$missing\"
fi
" 2>&1)
	if [[ "$zsh_wrappers" == *"OK"* ]]; then
		pass "8: zsh: all major wrapper functions defined after standalone sourcing"
	else
		fail "8: zsh: all major wrapper functions defined after standalone sourcing" \
			"output: $(printf '%q' "$zsh_wrappers")"
	fi

	# Test 8b: zsh must also load the privacy guard with a caller-owned SCRIPT_DIR.
	zsh_privacy_guard=$(SCRIPT_DIR="${SCRIPT_DIR_TEST}/missing-caller-dir" zsh -c "
source '${WRAPPERS_FILE}' 2>/dev/null
if (( \${+functions[privacy_guard_public_write]} )); then
    printf 'DEFINED\\n'
else
    printf 'MISSING\\n'
fi
" 2>&1)
	if [[ "$zsh_privacy_guard" == *"DEFINED"* ]]; then
		pass "8b: zsh: caller SCRIPT_DIR cannot skip public-write privacy dependency"
	else
		fail "8b: zsh: caller SCRIPT_DIR cannot skip public-write privacy dependency" \
			"output: $(printf '%q' "$zsh_privacy_guard")"
	fi

	# Test 9: zsh — gh_create_pr --help should exercise the wrapper entry path
	# without bash-only cleanup helper or RETURN trap errors.
	zsh_help_output=$(zsh -c "
source '${WRAPPERS_FILE}'
gh(){ printf 'gh-called:%s\\n' \"\$*\"; return 0; }
gh_create_pr --help
" 2>&1)
	if [[ "$zsh_help_output" == *"_save_cleanup_scope"* ]] || [[ "$zsh_help_output" == *"undefined signal: RETURN"* ]]; then
		fail "9: zsh: gh_create_pr --help emits no cleanup/trap errors" \
			"output: $(printf '%q' "$zsh_help_output")"
	else
		pass "9: zsh: gh_create_pr --help emits no cleanup/trap errors"
	fi
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s%d/%d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
