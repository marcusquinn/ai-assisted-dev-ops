#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression test for t2860: the permanent-removal helper must call
# unregister_worktree after destroying a worktree to prevent SQLite
# registry bloat and PID-collision false positives.
#
# Background: pulse-cleanup-worktree-removal.sh destroys worktrees via _trash_or_remove
# but never deregistered them from the worktree_owners SQLite table.
# This left stale rows accumulating forever (815 April entries observed
# for ~7 live worktrees). Stale rows with recycled PIDs could cause
# is_worktree_owned_by_others to return false-positives.
#
# This test:
#   1. Verifies _pc_permanently_remove_eligible_orphan contains the
#      unregister_worktree call (code-level guard).
#   2. Verifies register_worktree + unregister_worktree round-trips
#      correctly against a temp SQLite DB.
#   3. Verifies unregister_worktree is fail-open: non-existent DB or
#      path returns 0 without error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Track failures
declare -i FAIL_COUNT=0

fail() {
	local msg="$1"
	echo "FAIL: $msg" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

pass() {
	local msg="$1"
	echo "PASS: $msg"
	return 0
}

# ============================================================================
# Test 1: Code-level guard — permanent removal calls unregister_worktree.
#
# This is the canonical regression catch: if a future refactor removes the
# unregister_worktree call, this test fails immediately without needing a
# full integration run.
# ============================================================================
echo ""
echo "=== Test 1: permanent removal contains unregister_worktree ==="
(
	# Extract the function body using awk, then check for the call.
	# Strategy: extract lines between the function header and its closing '}'
	# at the top indentation level, then grep for unregister_worktree.
	fn_body=$(awk '
		/^_pc_permanently_remove_eligible_orphan\(\)/ { in_fn=1; brace_depth=0 }
		in_fn {
			print
			# Count braces to find function end
			n = split($0, chars, "")
			for (i=1; i<=n; i++) {
				if (chars[i] == "{") brace_depth++
				if (chars[i] == "}") {
					brace_depth--
					if (brace_depth == 0) { in_fn=0; exit }
				}
			}
		}
	' "$SCRIPT_DIR/pulse-cleanup-worktree-removal.sh")

	if echo "$fn_body" | grep -q 'unregister_worktree'; then
		echo "PASS: unregister_worktree found in permanent-removal helper"
	else
		echo "FAIL: unregister_worktree NOT found in permanent-removal helper"
		exit 1
	fi
) || fail "permanent-removal helper does not call unregister_worktree"

# ============================================================================
# Test 2: Registry round-trip — register then unregister a path.
#
# Uses a temporary DB to isolate from the live registry. Verifies that after
# unregister_worktree the row is gone from worktree_owners.
# ============================================================================
echo ""
echo "=== Test 2: register + unregister round-trip removes registry row ==="
(
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/shared-constants.sh"

	# Skip test if sqlite3 unavailable
	if ! command -v sqlite3 >/dev/null 2>&1; then
		echo "SKIP: sqlite3 not available"
		exit 0
	fi

	# Override registry DB path to a temp file, isolated from live registry.
	TMPDIR_TEST="$(mktemp -d)"
	export WORKTREE_REGISTRY_DB="$TMPDIR_TEST/test-worktree-registry.db"

	# Cleanup on exit
	trap 'rm -rf "$TMPDIR_TEST"' EXIT

	TEST_PATH="/tmp/test-worktree-t2860-$$"

	# Register the path (creates table and row)
	register_worktree "$TEST_PATH" "$$" "test-session" "test-batch" "t2860-test"

	# Verify row exists
	row_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" \
		"SELECT COUNT(*) FROM worktree_owners WHERE worktree_path LIKE '%test-worktree-t2860%';" 2>/dev/null || echo "0")
	if [[ "$row_count" -eq 0 ]]; then
		echo "FAIL: register_worktree did not create a row (prerequisite failed)"
		exit 1
	fi
	echo "  Pre-unregister row count: $row_count (expected 1)"

	# Unregister (the call guarded above in the permanent-removal helper)
	unregister_worktree "$TEST_PATH" 2>/dev/null || true

	# Verify row is gone
	row_count_after=$(sqlite3 "$WORKTREE_REGISTRY_DB" \
		"SELECT COUNT(*) FROM worktree_owners WHERE worktree_path LIKE '%test-worktree-t2860%';" 2>/dev/null || echo "0")
	if [[ "$row_count_after" -ne 0 ]]; then
		echo "FAIL: unregister_worktree did not remove the row (count=$row_count_after)"
		exit 1
	fi
	echo "PASS: registry row removed after unregister_worktree"
) || fail "Registry round-trip failed"

# ============================================================================
# Test 3: Fail-open — unregister_worktree on a missing DB returns 0.
#
# pulse-cleanup.sh uses `unregister_worktree ... 2>/dev/null || true` but
# the function itself already returns 0 when the DB is missing (line 405
# of shared-worktree-registry.sh: [[ ! -f "$WORKTREE_REGISTRY_DB" ]] && return 0).
# This test confirms that contract.
# ============================================================================
echo ""
echo "=== Test 3: unregister_worktree is fail-open (missing DB returns 0) ==="
(
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/shared-constants.sh"

	# Point to a non-existent DB
	export WORKTREE_REGISTRY_DB="/tmp/does-not-exist-t2860-$$.db"

	# Should return 0 without error
	if unregister_worktree "/some/path" 2>/dev/null; then
		echo "PASS: unregister_worktree returns 0 when DB is missing"
	else
		echo "FAIL: unregister_worktree returned non-zero for missing DB"
		exit 1
	fi
) || fail "unregister_worktree not fail-open on missing DB"

# ============================================================================
# Test 4: Sourcing pulse-cleanup.sh in isolation makes unregister_worktree
# available (shared-constants.sh sources shared-worktree-registry.sh).
# ============================================================================
echo ""
echo "=== Test 4: unregister_worktree is available after sourcing pulse-cleanup.sh ==="
(
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/shared-constants.sh"
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/pulse-cleanup.sh"

	if command -v unregister_worktree >/dev/null 2>&1; then
		echo "PASS: unregister_worktree is defined after sourcing chain"
	else
		echo "FAIL: unregister_worktree is NOT defined — sourcing chain is broken"
		exit 1
	fi
) || fail "unregister_worktree not available in pulse-cleanup.sh sourcing chain"

# ============================================================================
# Summary
# ============================================================================
echo ""
if [[ "$FAIL_COUNT" -eq 0 ]]; then
	echo "=== All tests passed ==="
	exit 0
else
	echo "=== $FAIL_COUNT test(s) failed ==="
	exit 1
fi
