#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23677 / t3700: pulse orphan cleanup must NOT
# permanently remove a worktree that has dirty (uncommitted) content,
# even when the fast-path's other conditions (0 commits, no open PR,
# past 30m grace) are satisfied.
#
# Real-world incident: an interactive OpenCode session with three WIP
# commits later reset back to the default-branch tip left the
# worktree showing commits_ahead=0 dirty=5 age=35m. The fast-path then
# matched and called remove_worktree_path_permanently → 3 hours of
# editor work plus local WIP commit evidence were destroyed with no recovery
# path (mode=permanent, branch deleted, no Trash backing).
#
# Key cleanup scenarios covered:
#   1. zero commits + dirty + past grace → skip (fast-path now requires clean)
#   2. reachable unpushed commit + past grace → skip
#      (defence-in-depth: HEAD --not --remotes)

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULSE_CLEANUP="${SCRIPT_DIR}/../pulse-cleanup.sh"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

# Keep temporary fixture repositories on native Git; canonical mutation-guard
# behavior is covered by its dedicated tests.
git() {
	"$GIT_BIN" "$@"
	return $?
}

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Create a repo + worktree with the .git file mtime aged to N hours ago so
# the cleanup logic considers it past the 30m grace period.
setup_repo_with_worktree_aged() {
	local repo_dir="$1"
	local wt_path="$2"
	local branch_name="$3"
	local hours_ago="${4:-2}"

	mkdir -p "$repo_dir"
	(
		cd "$repo_dir" || exit 1
		git init -q -b main
		git config user.email "test@example.invalid"
		git config user.name "Test Editor"
		printf 'base\n' >README.md
		git add README.md
		git commit -q -m "init"
		git worktree add -q -b "$branch_name" "$wt_path" main
	)
	# touch -t reads local time, so date must also produce local time
	# (no -u flag). GNU touch -d accepts free-form relative offsets;
	# BSD touch needs the -t form. Try -d first, fall back to -t.
	if ! touch -d "${hours_ago} hours ago" "$wt_path/.git" 2>/dev/null; then
		local old_ts
		old_ts=$(date -v-"${hours_ago}"H +%Y%m%d%H%M 2>/dev/null \
			|| date -d "${hours_ago} hours ago" +%Y%m%d%H%M 2>/dev/null \
			|| printf '202601010000\n')
		touch -t "$old_ts" "$wt_path/.git"
	fi
	return 0
}

source_pulse_cleanup_with_stubs() {
	LOGFILE="${TEST_ROOT}/pulse.log"
	export LOGFILE
	AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup.log"
	export AIDEVOPS_CLEANUP_LOG
	ORPHAN_WORKTREE_GRACE_SECS=1800
	export ORPHAN_WORKTREE_GRACE_SECS

	is_worktree_owned_by_others() { return 1; }
	unregister_worktree() { local wt_path="$1"; : "$wt_path"; return 0; }
	gh_pr_list() { return 0; }
	recover_failed_launch_state() { return 0; }
	gh_issue_comment() { return 0; }

	unset _PULSE_CLEANUP_LOADED 2>/dev/null || true
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../portable-stat.sh
	source "${SCRIPT_DIR}/../portable-stat.sh"
	# shellcheck source=../pulse-cleanup.sh
	source "$PULSE_CLEANUP"
	return 0
}

# Scenario 1: zero commits + dirty file + past grace → MUST skip.
# Reproduces the exact preamble-truncation incident shape:
# commits=0 dirty>0 age>30m no-PR no-owner → fast-path matched +
# remove_worktree_path_permanently destroyed dirty edits.
test_dirty_worktree_past_grace_skips_removal() {
	local repo_dir="${TEST_ROOT}/repo-dirty"
	local wt_path="${TEST_ROOT}/wt-dirty"
	local branch_name="fix/dirty-uncommitted-work"
	setup_repo_with_worktree_aged "$repo_dir" "$wt_path" "$branch_name" 1 || return 1
	source_pulse_cleanup_with_stubs || return 1

	# Introduce uncommitted dirty content — simulating an active editor session.
	(
		cd "$wt_path" || exit 1
		printf 'uncommitted work in progress\n' >wip-edit.txt
		printf 'more uncommitted edits\n' >>README.md
	)

	local now_epoch
	now_epoch=$(date +%s)
	AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/missing-metrics.jsonl"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 1 ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	[[ -f "$wt_path/wip-edit.txt" ]] || rc=1
	# The fast-path now requires dirty_count==0, so the dirty worktree should
	# not even enter the removal pipeline at this age. It falls through to
	# the 6h dirty rule (not yet eligible at 1h), so the audit log must
	# either skip entirely or show one of the safety reasons.
	if ! grep -qE 'worktree-skipped|dirty-content-protect' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null; then
		# Acceptable alternative: no removal event logged at all (worktree was
		# never deemed eligible by _evaluate_worktree_removal).
		if grep -q 'worktree-removed' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null; then
			rc=1
		fi
	fi
	print_result "dirty worktree past 30m grace is NOT permanently removed" "$rc" \
		"cleanup_rc=$cleanup_rc dir_exists=$([[ -d "$wt_path" ]] && echo y || echo n) log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

# Scenario 2: even past 6h, a dirty worktree must be REFUSED permanent
# removal by the _cleanup_single_worktree defence-in-depth check. The 6h
# rule used to discard dirty workers; we now treat dirty as "could be an
# editor session that pgrep missed" and leave the directory alone.
test_dirty_worktree_past_6h_still_skips() {
	local repo_dir="${TEST_ROOT}/repo-dirty-old"
	local wt_path="${TEST_ROOT}/wt-dirty-old"
	local branch_name="fix/old-dirty-uncommitted"
	setup_repo_with_worktree_aged "$repo_dir" "$wt_path" "$branch_name" 7 || return 1
	source_pulse_cleanup_with_stubs || return 1

	(
		cd "$wt_path" || exit 1
		printf 'long-running uncommitted edits\n' >slow-edit.txt
	)

	local now_epoch
	now_epoch=$(date +%s)
	AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/missing-metrics.jsonl"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 1 ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	[[ -f "$wt_path/slow-edit.txt" ]] || rc=1
	grep -q 'dirty-content-protect' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "dirty worktree past 6h refused by defence-in-depth" "$rc" \
		"cleanup_rc=$cleanup_rc dir_exists=$([[ -d "$wt_path" ]] && echo y || echo n) log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

# Scenario 3: a worktree with WIP commits still reachable from HEAD but not
# present on any remote is protected by the "commits not on any remote" check.
# This does not claim to recover reflog-only commits after HEAD is reset away
# from them; cleanup can only inspect reachable state without a separate reflog
# walk.
test_reachable_unpushed_commits_protected() {
	local repo_dir="${TEST_ROOT}/repo-unpushed"
	local wt_path="${TEST_ROOT}/wt-unpushed"
	local branch_name="fix/reachable-unpushed-wip"
	setup_repo_with_worktree_aged "$repo_dir" "$wt_path" "$branch_name" 1 || return 1
	source_pulse_cleanup_with_stubs || return 1

	# Create a WIP commit and leave HEAD on it. `rev-list HEAD --not --remotes`
	# reports it as local-only, so cleanup must refuse permanent removal.
	(
		cd "$wt_path" || exit 1
		printf 'wip change\n' >wip.txt
		git add wip.txt
		git -c user.email=t@test -c user.name=T commit -q -m "wip: editor edit"
	)

	local now_epoch
	now_epoch=$(date +%s)
	AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/missing-metrics.jsonl"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 1 ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	# Expect either local-commits-no-pr (commits_ahead via primary path) OR
	# commits-not-on-remote (defence-in-depth path) — both are correct
	# refusals. The worktree must survive.
	if ! grep -qE 'local-commits-no-pr|commits-not-on-remote' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null; then
		grep -q 'worktree-removed' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null && rc=1
	fi
	print_result "worktree with reachable unpushed commit is preserved" "$rc" \
		"cleanup_rc=$cleanup_rc dir_exists=$([[ -d "$wt_path" ]] && echo y || echo n) log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

# Scenario 4: an unreadable index must produce an audited skip. Cleanup cannot
# prove that uncommitted work is absent, so it must preserve the worktree.
test_unreadable_index_is_preserved_and_audited() {
	local repo_dir="${TEST_ROOT}/repo-unreadable-index"
	local wt_path="${TEST_ROOT}/wt-unreadable-index"
	local branch_name="fix/unreadable-index"
	setup_repo_with_worktree_aged "$repo_dir" "$wt_path" "$branch_name" 7 || return 1
	source_pulse_cleanup_with_stubs || return 1

	local git_dir=""
	git_dir=$(git -C "$wt_path" rev-parse --absolute-git-dir) || return 1
	: >"${git_dir}/index"

	local now_epoch
	now_epoch=$(date +%s)
	AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/missing-metrics.jsonl"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 1 ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	grep -q 'unreadable-git-state.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "unreadable worktree index is preserved and audited" "$rc" \
		"cleanup_rc=$cleanup_rc dir_exists=$([[ -d "$wt_path" ]] && echo y || echo n) log=$(<"$AIDEVOPS_CLEANUP_LOG")"
	return 0
}

# Scenario 5: pulse-cleanup must source cleanly under `set -u` — the
# previous `unset _PULSE_CLEANUP_SCRIPT_DIR` left line ~251 with an
# unbound variable. This test catches regression of the unset.
test_sources_under_set_u() {
	(
		set -u
		LOGFILE="${TEST_ROOT}/pulse-u.log"
		export LOGFILE
		AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup-u.log"
		export AIDEVOPS_CLEANUP_LOG
		unset _PULSE_CLEANUP_LOADED 2>/dev/null || true
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../pulse-cleanup.sh
		source "$PULSE_CLEANUP" || exit 7
		# Force-evaluate the previously-broken code path; failure would be an
		# unbound-variable abort, not a function return.
		if declare -F _cleanup_merged_prs_for_all_repos >/dev/null 2>&1; then
			# We don't actually run the function (it needs jq + repos.json);
			# referencing the variable directly is enough to catch unset.
			: "${_PULSE_CLEANUP_SCRIPT_DIR:?missing _PULSE_CLEANUP_SCRIPT_DIR}"
		else
			exit 6
		fi
		exit 0
	)
	local sub_rc=$?
	local rc=0
	[[ "$sub_rc" -eq 0 ]] || rc=1
	print_result "pulse-cleanup.sh sources cleanly under set -u" "$rc" "subshell_rc=$sub_rc"
	return 0
}

TEST_ROOT=$(mktemp -d)
trap teardown EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

echo "=== test-pulse-cleanup-preserves-dirty.sh ==="
test_dirty_worktree_past_grace_skips_removal
test_dirty_worktree_past_6h_still_skips
test_reachable_unpushed_commits_protected
test_unreadable_index_is_preserved_and_audited
test_sources_under_set_u

echo ""
echo "Results: $((TESTS_RUN - TESTS_FAILED))/${TESTS_RUN} passed, ${TESTS_FAILED} failed."

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
