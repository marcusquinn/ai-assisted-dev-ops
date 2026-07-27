#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pid-liveness-reuse.sh — t2421 PID liveness reuse regression test.
#
# Verifies that _is_process_alive_and_matches() correctly distinguishes between:
#   1. Alive PID with matching command → passes (exit 0).
#   2. Alive PID with NON-matching command (simulate Brave Browser case) → fails (exit 1).
#   3. Dead PID → fails (exit 1).
#   4. PID with stored argv_hash mismatching current → fails (exit 1).
#   5. Empty/zero/non-numeric PID → fails (exit 1).
#   6. _compute_argv_hash produces a stable 12-char hex hash.
#   7. A process-start token must match exactly when supplied.
#
# Run: bash .agents/scripts/tests/test-pid-liveness-reuse.sh
# Expected: all tests PASS.

# NOTE: not using `set -e` intentionally — negative assertions rely on
# capturing non-zero exits. Each assertion explicitly captures exit codes.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
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

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

# Source shared-constants.sh to get _is_process_alive_and_matches and _compute_argv_hash
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || {
	echo "FATAL: Could not source shared-constants.sh"
	exit 1
}

echo "=== t2421: PID liveness reuse regression tests ==="
echo ""

# -------------------------------------------------------------------------
# Test 1: Alive PID with matching command → passes
# Use our own PID ($$) which is running bash
# -------------------------------------------------------------------------
_is_process_alive_and_matches "$$" "bash"
rc=$?
print_result "1. Alive PID with matching command (our own bash process)" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"

# -------------------------------------------------------------------------
# Test 2: Alive PID with NON-matching command → fails
# Use our own PID but expect a completely different pattern
# -------------------------------------------------------------------------
_is_process_alive_and_matches "$$" "Brave Browser Helper" 2>/dev/null
rc=$?
print_result "2. Alive PID with non-matching command (Brave Browser pattern)" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

# -------------------------------------------------------------------------
# Test 3: Dead PID → fails
# Use PID 99998 which is very unlikely to be alive, or find a guaranteed dead PID
# -------------------------------------------------------------------------
dead_pid=99998
# Make sure it's actually dead
while kill -0 "$dead_pid" 2>/dev/null; do
	dead_pid=$((dead_pid - 1))
done
_is_process_alive_and_matches "$dead_pid" "bash" 2>/dev/null
rc=$?
print_result "3. Dead PID ($dead_pid) → fails" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

# -------------------------------------------------------------------------
# Test 4: PID with stored argv_hash mismatching current → fails
# Use our own PID but provide a fake stored hash
# -------------------------------------------------------------------------
_is_process_alive_and_matches "$$" "bash" "000000000000" 2>/dev/null
rc=$?
print_result "4. Alive PID + matching command + WRONG argv hash → fails" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

# -------------------------------------------------------------------------
# Test 5: PID with matching stored argv_hash → passes
# Compute our own hash and verify it matches
# -------------------------------------------------------------------------
our_hash=$(_compute_argv_hash "$$" 2>/dev/null || echo "")
if [[ -n "$our_hash" ]]; then
	_is_process_alive_and_matches "$$" "bash" "$our_hash"
	rc=$?
	print_result "5. Alive PID + matching command + CORRECT argv hash → passes" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"
else
	print_result "5. Alive PID + matching command + CORRECT argv hash → passes" 1 "(SKIP: no hash tool available)"
fi

# -------------------------------------------------------------------------
# Test 6: Empty PID → fails
# -------------------------------------------------------------------------
_is_process_alive_and_matches "" "bash" 2>/dev/null
rc=$?
print_result "6. Empty PID → fails" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

# -------------------------------------------------------------------------
# Test 7: PID 0 → fails
# -------------------------------------------------------------------------
_is_process_alive_and_matches "0" "bash" 2>/dev/null
rc=$?
print_result "7. PID 0 → fails" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

# -------------------------------------------------------------------------
# Test 8: Non-numeric PID → fails
# -------------------------------------------------------------------------
_is_process_alive_and_matches "abc" "bash" 2>/dev/null
rc=$?
print_result "8. Non-numeric PID → fails" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

# -------------------------------------------------------------------------
# Test 9: Empty pattern → falls back to bare kill -0 (alive PID passes)
# -------------------------------------------------------------------------
_is_process_alive_and_matches "$$" ""
rc=$?
print_result "9. Alive PID + empty pattern → passes (bare kill -0 fallback)" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"

# -------------------------------------------------------------------------
# Test 10: _compute_argv_hash produces stable 12-char hex output
# -------------------------------------------------------------------------
hash1=$(_compute_argv_hash "$$" 2>/dev/null || echo "")
hash2=$(_compute_argv_hash "$$" 2>/dev/null || echo "")
if [[ -n "$hash1" ]]; then
	hash_ok=1
	# Check length = 12
	[[ ${#hash1} -eq 12 ]] || hash_ok=0
	# Check hex chars only
	[[ "$hash1" =~ ^[0-9a-f]+$ ]] || hash_ok=0
	# Check stable (same PID, same hash)
	[[ "$hash1" == "$hash2" ]] || hash_ok=0
	print_result "10. _compute_argv_hash: stable 12-char hex (${hash1})" "$([[ $hash_ok -eq 1 ]] && echo 0 || echo 1)"
else
	print_result "10. _compute_argv_hash: stable 12-char hex" 1 "(SKIP: no hash tool available)"
fi

# -------------------------------------------------------------------------
# Test 11: _compute_argv_hash for dead PID → fails (exit 1)
# -------------------------------------------------------------------------
_compute_argv_hash "$dead_pid" >/dev/null 2>&1
rc=$?
print_result "11. _compute_argv_hash for dead PID → fails" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"

# -------------------------------------------------------------------------
# Tests 12-13: process-start identity matches exactly and rejects PID reuse.
# -------------------------------------------------------------------------
our_process_start=$(_process_start_token "$$" 2>/dev/null || echo "")
if [[ -n "$our_process_start" ]]; then
	_is_process_alive_and_matches "$$" "bash" "" "$our_process_start"
	rc=$?
	print_result "12. Alive PID + matching process-start token → passes" "$([[ $rc -eq 0 ]] && echo 0 || echo 1)"
	_is_process_alive_and_matches "$$" "bash" "" "not-${our_process_start}" 2>/dev/null
	rc=$?
	print_result "13. Alive same-command PID + wrong process-start token → fails" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
else
	print_result "12. Alive PID + matching process-start token → passes" 1 "(process start unavailable)"
	print_result "13. Alive same-command PID + wrong process-start token → fails" 1 "(process start unavailable)"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo ""
echo "=== Results: ${TESTS_RUN} run, ${TESTS_FAILED} failed ==="
if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi
exit 0
