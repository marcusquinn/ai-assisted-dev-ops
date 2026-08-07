#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gate-pull-before-measure.sh — t2433/GH#20071 regression guard.
#
# Verifies that the large-file gate never measures a stale canonical checkout.
# `_pulse_refresh_repo` uses guarded canonical recovery and may legitimately
# leave a runner stale; the gate must detect that state and defer without issue
# mutations instead of trusting pre-split line counts.
#
# Tests:
#   test_refresh_pulls_before_gate_measures
#       Sandboxed git repo with a 2500-line file committed. A "remote" bare
#       clone has the file shrunk to 500 lines. The local repo has NOT pulled.
#       Calling _pulse_refresh_repo may leave 2500 lines locally, but the
#       remote-default freshness check must reject that checkout.
#
#   test_sentinel_prevents_double_pull
#       After _pulse_refresh_repo is called once for a path, calling it again
#       should NOT call git fetch/pull a second time (sentinel short-circuits).
#
#   test_missing_path_is_noop
#       Empty repo_path argument returns 0 without errors.
#
#   test_nonexistent_path_is_noop
#       Path that is not a git work-tree returns 0 without errors.
#
#   test_triage_refresh_before_issue_targets_large_files
#       Simulates triage after a guarded refresh cannot converge and verifies
#       _issue_targets_large_files blocks for retry before measuring or mutating.
#
# Cross-references: GH#20071 (root cause), t2433 (this fix),
#   GH#19964-#20023 (6 false-positive debt issues triggered by stale local copy)

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-wrapper.sh"
GATE_SCRIPT="${SCRIPT_DIR_TEST}/../pulse-dispatch-large-file-gate.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2433.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
export LOGFILE

LARGE_FILE_LINE_THRESHOLD=2000
export LARGE_FILE_LINE_THRESHOLD

# Disable SSH/GPG signing for all git operations in this test process.
# Exported so all git subprocesses inherit these settings.
# GIT_CONFIG_GLOBAL=/dev/null prevents reading ~/.gitconfig which has
# commit.gpgsign=true and gpg.format=ssh on this machine.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_COMMITTER_NAME="Test"
export GIT_COMMITTER_EMAIL="test@example.com"
export GIT_AUTHOR_NAME="Test"
export GIT_AUTHOR_EMAIL="test@example.com"
# GIT_CONFIG_COUNT overrides to disable signing at process-level
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="commit.gpgsign"
export GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_KEY_1="tag.gpgsign"
export GIT_CONFIG_VALUE_1="false"

# =============================================================================
# Test framework helpers
# =============================================================================
print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$test_name"
		return 0
	fi

	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# =============================================================================
# Git sandbox helpers
# =============================================================================
# Simple git wrapper that adds user identity (required when GIT_CONFIG_GLOBAL
# is /dev/null — no name/email from global config). Signing is disabled via
# exported GIT_CONFIG_COUNT + GIT_CONFIG_GLOBAL=/dev/null above.
_git_test() {
	git -c user.email="test@example.com" -c user.name="Test" "$@"
}

_setup_git_sandbox() {
	local sandbox_dir="$1"
	# Use a unique bare dir per sandbox to avoid conflicts on re-run
	local bare_dir="${sandbox_dir}.bare.git"
	local work_copy="${sandbox_dir}.work-copy"

	mkdir -p "$sandbox_dir"
	_git_test init -q "$sandbox_dir"
	_git_test -C "$sandbox_dir" config commit.gpgsign false
	_git_test -C "$sandbox_dir" config tag.gpgsign false

	# Create a 2500-line file representing a pre-split large file
	local target_file="${sandbox_dir}/large-target.sh"
	local i
	for i in $(seq 1 2500); do
		printf '# line %d\n' "$i"
	done >"$target_file"

	_git_test -C "$sandbox_dir" add large-target.sh
	_git_test -C "$sandbox_dir" commit -q -m "initial: 2500-line file"

	# Create a bare "remote" clone with the file shrunk to 500 lines
	_git_test clone --bare -q "$sandbox_dir" "$bare_dir"

	# Shrink the file in the bare clone by creating a fixup commit
	_git_test clone -q "$bare_dir" "$work_copy"
	_git_test -C "$work_copy" config commit.gpgsign false
	_git_test -C "$work_copy" config tag.gpgsign false
	for i in $(seq 1 500); do
		printf '# line %d\n' "$i"
	done >"${work_copy}/large-target.sh"
	_git_test -C "$work_copy" commit -q -am "split: reduce to 500 lines"
	_git_test -C "$work_copy" push -q

	# Wire sandbox_dir to track the bare remote (simulating a local repo
	# that hasn't pulled the split commit yet).
	# Set up the tracking branch (git clone does this automatically for
	# production repos; we must do it manually for init-based sandboxes).
	_git_test -C "$sandbox_dir" remote add origin "$bare_dir"
	_git_test -C "$sandbox_dir" fetch -q origin
	_git_test -C "$sandbox_dir" branch --set-upstream-to=origin/master master 2>/dev/null || true
	# Deliberately do NOT pull — local HEAD is still the 2500-line version

	return 0
}

# =============================================================================
# Tests
# =============================================================================

test_refresh_pulls_before_gate_measures() {
	local sandbox="${TMP}/sandbox-refresh"
	_setup_git_sandbox "$sandbox" || {
		print_result "test_refresh_pulls_before_gate_measures" 1 "sandbox setup failed"
		return 0
	}

	# Verify stale state: local file is still 2500 lines before pull
	local stale_count
	stale_count=$(wc -l <"${sandbox}/large-target.sh" | tr -d ' ')
	if [[ "$stale_count" -lt 2000 ]]; then
		print_result "test_refresh_pulls_before_gate_measures" 1 \
			"pre-condition: expected stale >2000 lines, got ${stale_count}"
		return 0
	fi

	# Load the pulse and gate helpers in a clean subshell. Guarded canonical
	# recovery may refuse this unregistered sandbox, which is expected.
	# shellcheck disable=SC1090
	local result
	result=$(
		# shellcheck disable=SC1090,SC2030
		source "${WRAPPER_SCRIPT}" --self-check >/dev/null 2>&1 || true
		declare -A _PULSE_REFRESHED_THIS_CYCLE=()
		_pulse_refresh_repo "$sandbox" 2>>"$LOGFILE"
		if _large_file_gate_repo_matches_remote_default "$sandbox"; then
			printf 'fresh\n'
		else
			printf 'stale\n'
		fi
	)

	if [[ "$result" == "stale" ]]; then
		print_result "test_refresh_pulls_before_gate_measures" 0
	else
		print_result "test_refresh_pulls_before_gate_measures" 1 \
			"expected stale checkout rejection, got ${result:-?}"
	fi
	return 0
}

test_sentinel_prevents_double_pull() {
	local sandbox="${TMP}/sandbox-sentinel"
	mkdir -p "$sandbox"
	git -C "$sandbox" init -q
	git -C "$sandbox" config user.email "test@example.com"
	git -C "$sandbox" config user.name "Test"
	printf '# stub\n' >"${sandbox}/stub.sh"
	git -C "$sandbox" add stub.sh
	git -C "$sandbox" commit -q -m "stub"
	git -C "$sandbox" remote add origin "${sandbox}" || true  # Self-remote for testing

	local fetch_count=0
	# Count git fetch calls via a wrapper logged to a file
	local fetch_log="${TMP}/fetch-count.txt"
	printf '0\n' >"$fetch_log"

	# Run in a subshell so the patched git wrapper is scoped
	local rc=0
	(
		# shellcheck disable=SC1090,SC2031
		source "${WRAPPER_SCRIPT}" --self-check >/dev/null 2>&1 || true
		declare -A _PULSE_REFRESHED_THIS_CYCLE=()

		# Override git to count fetch calls
		git() {
			if [[ "${3:-}" == "fetch" ]]; then
				local cur
				cur=$(cat "$fetch_log" 2>/dev/null || echo 0)
				printf '%d\n' "$((cur + 1))" >"$fetch_log"
			fi
			command git "$@"
		}
		export -f git

		_pulse_refresh_repo "$sandbox" 2>>"$LOGFILE"
		_pulse_refresh_repo "$sandbox" 2>>"$LOGFILE"  # second call — should be no-op
		_pulse_refresh_repo "$sandbox" 2>>"$LOGFILE"  # third call — should be no-op
	) || rc=$?

	local count
	count=$(cat "$fetch_log" 2>/dev/null || echo 0)

	if [[ "$count" -le 1 ]]; then
		print_result "test_sentinel_prevents_double_pull" 0
	else
		print_result "test_sentinel_prevents_double_pull" 1 \
			"expected <=1 fetch, got ${count} (sentinel not working)"
	fi
	return 0
}

test_missing_path_is_noop() {
	local rc=0
	(
		# shellcheck disable=SC1090
		source "${WRAPPER_SCRIPT}" --self-check >/dev/null 2>&1 || true
		declare -A _PULSE_REFRESHED_THIS_CYCLE=()
		_pulse_refresh_repo "" 2>>"$LOGFILE"
	) || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "test_missing_path_is_noop" 0
	else
		print_result "test_missing_path_is_noop" 1 \
			"expected exit 0 for empty path, got rc=${rc}"
	fi
	return 0
}

test_nonexistent_path_is_noop() {
	local rc=0
	(
		# shellcheck disable=SC1090
		source "${WRAPPER_SCRIPT}" --self-check >/dev/null 2>&1 || true
		declare -A _PULSE_REFRESHED_THIS_CYCLE=()
		_pulse_refresh_repo "/tmp/no-such-git-repo-t2433" 2>>"$LOGFILE"
	) || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "test_nonexistent_path_is_noop" 0
	else
		print_result "test_nonexistent_path_is_noop" 1 \
			"expected exit 0 for non-git path, got rc=${rc}"
	fi
	return 0
}

test_triage_refresh_before_issue_targets_large_files() {
	local sandbox="${TMP}/sandbox-triage"
	_setup_git_sandbox "$sandbox" || {
		print_result "test_triage_refresh_before_issue_targets_large_files" 1 \
			"sandbox setup failed"
		return 0
	}

	# Simulate triage with a stale pre-split checkout. Metadata reads are stubbed
	# so this remains a local regression test with no GitHub writes.
	local pre_pull_count post_pull_count gate_rc=0
	local measure_marker="${TMP}/stale-measure-called"
	pre_pull_count=$(wc -l <"${sandbox}/large-target.sh" | tr -d ' ')

	# Run refresh in a subshell
	(
		# shellcheck disable=SC1090
		source "${WRAPPER_SCRIPT}" --self-check >/dev/null 2>&1 || true
		declare -A _PULSE_REFRESHED_THIS_CYCLE=()
		_pulse_refresh_repo "$sandbox" 2>>"$LOGFILE"
		_large_file_gate_issue_labels() { printf ''; return 0; }
		_large_file_gate_issue_title() { printf 'Issue 9999'; return 0; }
		_large_file_gate_collect_large_files() {
			printf 'called\n' >"$measure_marker"
			return 0
		}
		_issue_targets_large_files "9999" "owner/repo" \
			"## How"$'\n'"- EDIT: \`large-target.sh\`" "$sandbox" "true"
	)
	gate_rc=$?

	post_pull_count=$(wc -l <"${sandbox}/large-target.sh" | tr -d ' ')

	# Exit 0 blocks/defer-retries the candidate. The stale file remains untouched,
	# and the collection marker proves no local line-count decision was made.
	if [[ "${pre_pull_count:-0}" -ge 2000 && "${post_pull_count:-0}" -ge 2000 \
		&& "$gate_rc" -eq 0 && ! -e "$measure_marker" ]]; then
		print_result "test_triage_refresh_before_issue_targets_large_files" 0
	else
		print_result "test_triage_refresh_before_issue_targets_large_files" 1 \
			"pre=${pre_pull_count} post=${post_pull_count} gate_rc=${gate_rc} — expected stale defer"
	fi
	return 0
}

# =============================================================================
# Main
# =============================================================================
printf 'Running t2433/GH#20071 gate-pull-before-measure tests...\n'

test_missing_path_is_noop
test_nonexistent_path_is_noop
test_refresh_pulls_before_gate_measures
test_sentinel_prevents_double_pull
test_triage_refresh_before_issue_targets_large_files

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
