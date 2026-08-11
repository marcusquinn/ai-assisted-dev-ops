#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for terminal-title-helper.sh
#
# Covers the t2252 guards that prevent the terminal/tab title from being
# clobbered with bare "main"/"master"/"aidevops/main" when the canonical
# repo sits on main (t1990). The guard fires in cmd_sync; cmd_rename with
# an explicit title remains unguarded unless an active OpenCode plugin owns OSC.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../terminal-title-helper.sh"

PASS=0
FAIL=0

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected: $(printf '%q' "$expected")"
		echo "    actual:   $(printf '%q' "$actual")"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_exit() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $test_name (exit=$actual)"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected exit: $expected"
		echo "    actual exit:   $actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# Assert that stdout contains the OSC 0 title-set escape sequence.
# OSC 0 is: ESC ] 0 ; <title> BEL — encoded as \033]0;...\007
assert_has_osc() {
	local test_name="$1"
	local output="$2"
	# Strip ANSI color codes from log output, then look for OSC 0 set-title.
	if printf '%s' "$output" | LC_ALL=C grep -q $'\033\]0;'; then
		echo "  PASS: $test_name (OSC emitted)"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name - expected OSC escape in output"
		echo "    output: $(printf '%q' "$output")"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_no_osc() {
	local test_name="$1"
	local output="$2"
	if printf '%s' "$output" | LC_ALL=C grep -q $'\033\]0;'; then
		echo "  FAIL: $test_name - OSC emitted but should have been skipped"
		echo "    output: $(printf '%q' "$output")"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $test_name (no OSC, skipped)"
		PASS=$((PASS + 1))
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test fixture helpers
# -----------------------------------------------------------------------------

TMPDIR_ROOT=""
REPO_DIR=""

setup_fixture() {
	TMPDIR_ROOT="$(mktemp -d)"
	REPO_DIR="${TMPDIR_ROOT}/fake-repo"

	mkdir -p "$REPO_DIR"
	git -C "$REPO_DIR" init -q -b main
	git -C "$REPO_DIR" config user.email "test@aidevops.sh"
	git -C "$REPO_DIR" config user.name "Test"
	git -C "$REPO_DIR" commit --allow-empty -q -m "init"
	return 0
}

teardown_fixture() {
	if [[ -n "$TMPDIR_ROOT" && -d "$TMPDIR_ROOT" ]]; then
		rm -rf "$TMPDIR_ROOT"
	fi
	return 0
}

# Run a helper command inside the fake repo with the given branch checked out.
# Captures stdout (where the OSC escape is emitted) to a variable.
# Args: $1 = branch, $2 = helper command, $3... = command args
# Extra env vars can be prefixed via EXTRA_ENV before the call.
# Sets: OUTPUT, RC
run_helper_on_branch() {
	local branch="$1"
	shift
	local cmd="$1"
	shift
	OUTPUT=""
	RC=0
	# shellcheck disable=SC2034,SC2086
	OUTPUT=$(
		cd "$REPO_DIR"
		git checkout -q -B "$branch"
		# Force TERMINAL_TITLE_ENABLED=true even if the env disables it elsewhere.
		# Combine stderr into stdout so we can inspect both in one string.
		# `env` interprets VAR=val args as env assignments (variable-expanded
		# prefixes don't act as env assignments syntactically).
		env TERMINAL_TITLE_ENABLED=true ${EXTRA_ENV:-} "$HELPER" "$cmd" "$@" 2>&1
	)
	RC=$?
	return 0
}

# Detached-HEAD variant — some tests need to detach rather than checkout a branch.
run_helper_detached() {
	local cmd="$1"
	shift
	OUTPUT=""
	RC=0
	# shellcheck disable=SC2034
	OUTPUT=$(
		cd "$REPO_DIR"
		git checkout -q --detach HEAD
		env TERMINAL_TITLE_ENABLED=true "$HELPER" "$cmd" "$@" 2>&1
	)
	RC=$?
	return 0
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

echo "=== terminal-title-helper.sh tests ==="
echo ""

trap teardown_fixture EXIT
setup_fixture

# Test 1: sync on main must NOT emit OSC
echo "Test 1: sync on 'main' branch skips OSC emit"
run_helper_on_branch "main" sync
assert_exit "exit 0 on main skip" "0" "$RC"
assert_no_osc "no OSC on main" "$OUTPUT"

# Test 2: sync on master must NOT emit OSC
echo ""
echo "Test 2: sync on 'master' branch skips OSC emit"
run_helper_on_branch "master" sync
assert_exit "exit 0 on master skip" "0" "$RC"
assert_no_osc "no OSC on master" "$OUTPUT"

# Test 3: sync on feature/* emits OSC as normal
echo ""
echo "Test 3: sync on 'feature/x' emits OSC"
run_helper_on_branch "feature/cool-thing" sync
assert_exit "exit 0 on feature branch" "0" "$RC"
assert_has_osc "OSC emitted on feature branch" "$OUTPUT"

# Test 4: sync on feature/* with TERMINAL_TITLE_FORMAT=branch also emits
echo ""
echo "Test 4: sync with format=branch on feature/x emits OSC"
EXTRA_ENV="TERMINAL_TITLE_FORMAT=branch" run_helper_on_branch "feature/format-branch" sync
EXTRA_ENV=""
assert_exit "exit 0 format=branch feature" "0" "$RC"
assert_has_osc "OSC emitted with format=branch" "$OUTPUT"

# Test 5: sync with format=branch on main still skips (guard fires before format check)
echo ""
echo "Test 5: sync with format=branch on main still skips"
EXTRA_ENV="TERMINAL_TITLE_FORMAT=branch" run_helper_on_branch "main" sync
EXTRA_ENV=""
assert_exit "exit 0 format=branch main skip" "0" "$RC"
assert_no_osc "no OSC even with format=branch on main" "$OUTPUT"

# Test 6: explicit rename with "main" is still honoured (manual override)
# The guards apply only to sync (automatic, driven by cwd branch).
# Direct `rename <title>` is a manual user action and stays unrestricted.
echo ""
echo "Test 6: explicit 'rename main' honours user override (no guard)"
run_helper_on_branch "main" rename "main"
assert_exit "exit 0 explicit rename" "0" "$RC"
assert_has_osc "OSC emitted on explicit rename to main" "$OUTPUT"

# Test 7: explicit rename with arbitrary title also emits
echo ""
echo "Test 7: explicit 'rename <custom>' always emits"
run_helper_on_branch "main" rename "investigating auto-compaction bug"
assert_exit "exit 0 custom rename" "0" "$RC"
assert_has_osc "OSC emitted on custom rename" "$OUTPUT"

# Test 8: detached HEAD (empty branch) is treated as default, skipped
echo ""
echo "Test 8: sync in detached HEAD skips OSC"
run_helper_detached sync
assert_exit "exit 0 detached HEAD" "0" "$RC"
assert_no_osc "no OSC in detached HEAD" "$OUTPUT"

# Test 9: child shells inside managed OpenCode sessions yield to the plugin.
echo ""
echo "Test 9: managed OpenCode session suppresses shell OSC writes"
EXTRA_ENV="OPENCODE=1 AIDEVOPS_TERMINAL_TITLE_OWNER=aidevops" run_helper_on_branch "feature/plugin-owner" rename "plugin-owned"
EXTRA_ENV=""
assert_exit "exit 0 when plugin owns title" "0" "$RC"
assert_no_osc "no shell OSC while plugin owns title" "$OUTPUT"

# Test 10: explicit native ownership also keeps one in-TUI OSC writer.
echo ""
echo "Test 10: native title owner suppresses in-TUI shell OSC writes"
EXTRA_ENV="OPENCODE=1 AIDEVOPS_TERMINAL_TITLE_OWNER=native" run_helper_on_branch "feature/native-owner" rename "native-owned"
EXTRA_ENV=""
assert_exit "exit 0 when native path owns title" "0" "$RC"
assert_no_osc "no shell OSC while OpenCode owns the title" "$OUTPUT"

# Test 11: the ownership marker does not disable ordinary shell sessions.
echo ""
echo "Test 11: native owner marker outside OpenCode preserves shell rename"
EXTRA_ENV="OPENCODE=0 AIDEVOPS_TERMINAL_TITLE_OWNER=native" run_helper_on_branch "feature/native-shell" rename "native-shell"
EXTRA_ENV=""
assert_exit "exit 0 outside OpenCode" "0" "$RC"
assert_has_osc "ordinary shell OSC remains available" "$OUTPUT"

# Test 12: reset follows the same in-TUI ownership guard as rename/sync.
echo ""
echo "Test 12: managed OpenCode session suppresses shell reset OSC"
EXTRA_ENV="OPENCODE=1 AIDEVOPS_TERMINAL_TITLE_OWNER=aidevops" run_helper_on_branch "feature/plugin-reset" reset
EXTRA_ENV=""
assert_exit "exit 0 for plugin-owned reset" "0" "$RC"
assert_no_osc "no reset OSC while plugin owns title" "$OUTPUT"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
