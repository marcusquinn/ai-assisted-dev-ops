#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#23076: branch-merged cleanup must not remove a
# worktree already classified as protected in the same cleanup pass, and PR or
# branch metadata must not produce permanent deletion without merge-base proof.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEAN_LIB_PATH="${TEST_SCRIPTS_DIR}/worktree-clean-lib.sh"
AUDIT_HELPER_PATH="${TEST_SCRIPTS_DIR}/audit-worktree-removal-helper.sh"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

# Keep isolated fixture mutations on native Git. The repository-level canonical
# guard is tested separately and must not classify temporary main worktrees.
git() {
	"$GIT_BIN" "$@"
	return $?
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME/.aidevops/logs"

TESTS_RUN=0
TESTS_FAILED=0
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_file_contains() {
	local file_path="$1"
	local pattern="$2"
	grep -Eq "$pattern" "$file_path" 2>/dev/null
	return $?
}

setup_repo() {
	local repo_path="$1"
	mkdir -p "$repo_path" || return 1
	git -C "$repo_path" init -q -b main || return 1
	git -C "$repo_path" config user.email "test@test.local" || return 1
	git -C "$repo_path" config user.name "Test" || return 1
	git -C "$repo_path" remote add origin "https://github.com/testowner/testrepo.git" || return 1
	printf 'init\n' >"$repo_path/README.md" || return 1
	git -C "$repo_path" add README.md || return 1
	git -C "$repo_path" commit -q -m "init" || return 1
	return 0
}

source_clean_lib_with_stubs() {
	: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
	_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
	_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
	_WTAR_WH_CALLER="${_WTAR_WH_CALLER:-worktree-helper.sh}"
	
	is_registered_canonical() { return 1; }
	_branch_has_active_interactive_claim() { return 1; }
	is_worktree_owned_by_others() { return 1; }
	check_worktree_owner() { printf '\n'; return 0; }
	worktree_is_in_grace_period() { return 1; }
	worktree_has_changes() { return 1; }
	branch_has_zero_commits_ahead() { return 1; }
	branch_was_pushed() { return 1; }
	_branch_exists_on_any_remote() { return 0; }
	trash_path() { return 0; }
	get_default_branch() { printf '%s\n' "main"; return 0; }
	localdev_auto_branch_rm() { return 0; }
	unregister_worktree() { return 0; }
	unregister_worktree_if_owner_pid() { unregister_worktree "$1"; return 0; }
	unregister_worktree_if_owner_contract() { unregister_worktree "$1"; return 0; }
	worktree_has_exact_owner_contract() { return 0; }
	claim_worktree_ownership() { return 0; }
	assert_git_available() { return 0; }
	assert_main_worktree_sane() { return 0; }
	gh_pr_list() { return 0; }

	# shellcheck source=/dev/null
	source "$AUDIT_HELPER_PATH" || return 1
	# shellcheck source=/dev/null
	source "$CLEAN_LIB_PATH" || return 1
	_branch_has_active_interactive_claim() { return 1; }
	worktree_is_in_grace_period() { return 1; }
	branch_has_zero_commits_ahead() { return 1; }
	# Fixture process-CWD evidence is complete and does not name any worktree.
	# Do not let unrelated host processes turn removal tests into degraded-mode tests.
	capture_worktree_process_cwds() { printf '/\n'; return 0; }
	return 0
}

test_protected_pass_set_blocks_branch_merged_removal() {
	local repo_path="${TEST_ROOT}/repo-protected"
	local wt_path="${TEST_ROOT}/wt-protected"
	local log_file="${TEST_ROOT}/protected-cleanup.log"
	local branch="feature/gh-99021-protected"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'merged\n' >"$repo_path/merged.txt" || rc=1
	git -C "$repo_path" add merged.txt || rc=1
	git -C "$repo_path" commit -q -m "merged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" merge -q --no-ff "$branch" -m "merge branch" || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_protected_mark "$wt_path"
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" "" >/dev/null
	) || rc=1

	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*protected-pass-skip.*mode=skipped.*protected_status=pass-local" || rc=1
	print_result "protected pass-local set blocks branch-merged removal" "$rc" \
		"Expected worktree to survive and protected audit entry in $log_file"
	return 0
}

test_terminal_pr_proof_bypasses_protected_pass_skip() {
	local repo_path="${TEST_ROOT}/repo-terminal-protected"
	local wt_path="${TEST_ROOT}/wt-terminal-protected"
	local log_file="${TEST_ROOT}/terminal-protected-cleanup.log"
	local branch="feature/gh-99032-terminal-protected"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'terminal\n' >"$repo_path/terminal.txt" || rc=1
	git -C "$repo_path" add terminal.txt || rc=1
	git -C "$repo_path" commit -q -m "terminal branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_protected_mark "$wt_path"
		_clean_remove_merged "main" "$repo_path" "false" "$branch" "" "true" "" >/dev/null
	) || rc=1

	[[ ! -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-removed.*branch-merged.*mode=permanent.*merge_proof_result=github-merged-pr" || rc=1
	print_result "terminal PR proof bypasses protected pass skip" "$rc" \
		"Expected terminal PR proof to remove protected-pass worktree. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

test_terminal_pr_cleanup_waits_for_deferred_parent_exit() {
	local repo_path="${TEST_ROOT}/repo-terminal-parent"
	local wt_path="${TEST_ROOT}/wt-terminal-parent"
	local log_file="${TEST_ROOT}/terminal-parent-cleanup.log"
	local branch="feature/gh-99033-terminal-parent"
	local owner_pid=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'terminal parent\n' >"$repo_path/terminal-parent.txt" || rc=1
	git -C "$repo_path" add terminal-parent.txt || rc=1
	git -C "$repo_path" commit -q -m "terminal parent branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1
	mkdir -p "$wt_path/.agents"
	sleep 30 &
	owner_pid=$!
	printf '%s\n' "$owner_pid" >"$wt_path/.agents/.full-loop-cleanup-deferred"

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_file_mtime_epoch() {
			date +%s
			return 0
		}
		_clean_remove_merged "main" "$repo_path" "false" "$branch" "" "true" "" >/dev/null
	) || rc=1
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*parent-runtime-active.*mode=skipped" || rc=1

	kill "$owner_pid" 2>/dev/null || true
	wait "$owner_pid" 2>/dev/null || true
	local registry_release_marker="${TEST_ROOT}/terminal-parent-registry-released"
	(
		cd "$repo_path" || exit 1
		unset _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		source_clean_lib_with_stubs || exit 1
		local registry_owned=1
		is_worktree_owned_by_others() { [[ "$registry_owned" -eq 1 ]]; return $?; }
		unregister_worktree_if_owner_pid() {
			[[ "$2" == "$owner_pid" ]] || return 1
			registry_owned=0
			printf 'released\n' >"$registry_release_marker"
			return 0
		}
		_clean_remove_merged "main" "$repo_path" "false" "$branch" "" "true" "" >/dev/null
	) || rc=1
	[[ ! -d "$wt_path" ]] || rc=1
	[[ -f "$registry_release_marker" ]] || rc=1
	print_result "terminal PR cleanup waits for deferred parent exit" "$rc" \
		"Expected first pulse to defer and second pulse after owner exit to remove worktree"
	return 0
}

test_reused_legacy_marker_pid_expires() {
	local wt_path="${TEST_ROOT}/wt-reused-legacy-pid"
	local marker_path="${wt_path}/.agents/.full-loop-cleanup-deferred"
	local rc=0
	mkdir -p "${wt_path}/.agents" || rc=1
	printf '%s\n' "$$" >"$marker_path" || rc=1

	(
		source_clean_lib_with_stubs || exit 1
		_file_mtime_epoch() {
			printf '%s\n' "1"
			return 0
		}
		_clean_process_age_seconds() {
			printf '%s\n' "1"
			return 0
		}
		local deferred_state=0
		_clean_deferred_parent_alive "$wt_path" || deferred_state=$?
		[[ "$deferred_state" -eq 2 && ! -f "$marker_path" ]]
	) || rc=1

	print_result "legacy marker rejects a process generation newer than the marker" "$rc" \
		"Expected a live recycled PID to expire instead of extending cleanup ownership"
	return 0
}

test_dead_marker_preserves_replacement_owner() {
	local repo_path="${TEST_ROOT}/repo-replacement-owner"
	local wt_path="${TEST_ROOT}/wt-replacement-owner"
	local log_file="${TEST_ROOT}/replacement-owner-cleanup.log"
	local branch="feature/gh-99034-replacement-owner"
	local replacement_pid=""
	local unregister_marker="${TEST_ROOT}/replacement-owner-unregistered"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'replacement owner\n' >"$repo_path/replacement-owner.txt" || rc=1
	git -C "$repo_path" add replacement-owner.txt || rc=1
	git -C "$repo_path" commit -q -m "replacement owner branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1
	mkdir -p "$wt_path/.agents"
	printf '999999\n' >"$wt_path/.agents/.full-loop-cleanup-deferred"
	sleep 30 &
	replacement_pid=$!

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		is_worktree_owned_by_others() { return 0; }
		unregister_worktree_if_owner_pid() { return 1; }
		unregister_worktree() { printf 'unexpected\n' >"$unregister_marker"; return 0; }
		_clean_remove_merged "main" "$repo_path" "false" "$branch" "" "true" "" >/dev/null
	) || rc=1
	[[ -d "$wt_path" ]] || rc=1
	[[ ! -f "$unregister_marker" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*owned-skip.*mode=skipped" || rc=1
	kill "$replacement_pid" 2>/dev/null || true
	wait "$replacement_pid" 2>/dev/null || true
	print_result "dead marker preserves a different replacement owner" "$rc" \
		"Expected mismatched live registry owner to block unregister and removal"
	return 0
}

test_terminal_cleanup_requires_removal_lease() {
	local repo_path="${TEST_ROOT}/repo-cleanup-lease"
	local wt_path="${TEST_ROOT}/wt-cleanup-lease"
	local log_file="${TEST_ROOT}/cleanup-lease.log"
	local branch="feature/gh-99035-cleanup-lease"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'cleanup lease\n' >"$repo_path/cleanup-lease.txt" || rc=1
	git -C "$repo_path" add cleanup-lease.txt || rc=1
	git -C "$repo_path" commit -q -m "cleanup lease branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		is_worktree_owned_by_others() { return 1; }
		claim_worktree_ownership() { return 1; }
		_clean_remove_merged "main" "$repo_path" "false" "$branch" "" "true" "" >/dev/null
	) || rc=1
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*cleanup-lease-skip.*mode=skipped" || rc=1
	print_result "terminal cleanup requires an atomic removal lease" "$rc" \
		"Expected a replacement-owner race to block physical cleanup"
	return 0
}

test_cleanup_lease_released_when_removal_guard_blocks() {
	local repo_path="${TEST_ROOT}/repo-guard-release"
	local wt_path="${TEST_ROOT}/wt-guard-release"
	local branch="feature/gh-99036-guard-release"
	local release_marker="${TEST_ROOT}/guard-lease-released"
	local rc=0
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'guard release\n' >"$repo_path/guard-release.txt" || rc=1
	git -C "$repo_path" add guard-release.txt || rc=1
	git -C "$repo_path" commit -q -m "guard release branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		claim_worktree_ownership() { return 0; }
		worktree_removal_guard() { return 1; }
		unregister_worktree_if_owner_contract() {
			[[ "$2" == "$$" && "$3" == "cleanup:$$" && "$4" == "worktree-removal" ]] || return 1
			printf 'released\n' >"$release_marker"
			return 0
		}
		_clean_remove_merged "main" "$repo_path" "false" "$branch" "" "true" "" >/dev/null
	) || rc=1
	[[ -d "$wt_path" ]] || rc=1
	[[ -f "$release_marker" ]] || rc=1
	print_result "cleanup lease releases when removal guard blocks" "$rc" \
		"Expected guarded skip to conditionally release cleanup PID ownership"
	return 0
}

test_remove_merged_reports_metadata_verification_failure() {
	local repo_path="${TEST_ROOT}/repo-removal-failure-status"
	local wt_path="${TEST_ROOT}/wt-removal-failure-status"
	local log_file="${TEST_ROOT}/removal-failure-status.log"
	local branch="feature/gh-99037-removal-failure-status"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'removal failure status\n' >"$repo_path/removal-failure-status.txt" || rc=1
	git -C "$repo_path" add removal-failure-status.txt || rc=1
	git -C "$repo_path" commit -q -m "removal failure status branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	if (
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		prune_missing_worktree_metadata() { return 1; }
		_clean_remove_merged "main" "$repo_path" "false" "$branch" "" "true" "" >/dev/null
	); then
		rc=1
	fi
	[[ ! -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*metadata-prune-failed.*mode=partial-cleanup" || rc=1
	print_result "remove merged reports metadata verification failure" "$rc" \
		"Expected aggregate cleanup status to retain a destructive-path failure"
	return 0
}

test_squash_merged_pr_without_ancestor_proof_classifies() {
	local repo_path="${TEST_ROOT}/repo-unproven"
	local wt_path="${TEST_ROOT}/wt-unproven"
	local log_file="${TEST_ROOT}/squash-merged-cleanup.log"
	local branch="feature/gh-99022-unproven"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'not ancestor\n' >"$repo_path/unproven.txt" || rc=1
	git -C "$repo_path" add unproven.txt || rc=1
	git -C "$repo_path" commit -q -m "unmerged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "$branch" "" "false" ""
	) || rc=1

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "squash-merged PR metadata does not require ancestor proof" "$rc" \
		"Expected squash-merged classification with GitHub PR-state proof"
	return 0
}

test_prefetched_merged_pr_metadata_skips_exact_head_lookup() {
	local repo_path="${TEST_ROOT}/repo-prefetched-squash-pr"
	local wt_path="${TEST_ROOT}/wt-prefetched-squash-pr"
	local log_file="${TEST_ROOT}/prefetched-squash-pr-cleanup.log"
	local branch="feature/gh-99027-prefetched-squash-pr"
	local gh_called_marker="${TEST_ROOT}/prefetched-gh-called"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'prefetched squash merge head\n' >"$repo_path/prefetched-squash-pr.txt" || rc=1
	git -C "$repo_path" add prefetched-squash-pr.txt || rc=1
	git -C "$repo_path" commit -q -m "prefetched squash-merged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		gh_pr_list() {
			printf 'called\n' >"$gh_called_marker"
			printf '0\n'
			return 0
		}
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "$branch" "" "false" ""
	) || rc=1

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ ! -e "$gh_called_marker" ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "prefetched merged PR metadata skips exact-head lookup" "$rc" \
		"Expected prefetched merged PR list to avoid redundant gh_pr_list lookup"
	return 0
}

test_merged_pr_list_passes_explicit_repo_slug() {
	local repo_path="${TEST_ROOT}/repo-explicit-slug"
	local args_file="${TEST_ROOT}/explicit-slug-args"
	local output=""
	local rc=0
	setup_repo "$repo_path" || rc=1

	output=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		gh_pr_list() {
			printf '%s' "$*" >"$args_file"
			printf 'feature/explicit-repo\n'
			return 0
		}
		_clean_build_merged_pr_branches
	) || rc=1

	[[ "$output" == *"feature/explicit-repo"* ]] || rc=1
	grep -q -- '--repo testowner/testrepo' "$args_file" 2>/dev/null || rc=1
	print_result "merged PR list passes explicit repo slug" "$rc" \
		"Expected --repo testowner/testrepo in gh_pr_list args"
	return 0
}

test_exact_merged_pr_batch_prefetch_covers_worktree_heads() {
	local repo_path="${TEST_ROOT}/repo-batch-prefetch"
	local wt_a="${TEST_ROOT}/wt-batch-prefetch-a"
	local wt_b="${TEST_ROOT}/wt-batch-prefetch-b"
	local branch_a="feature/gh-99040-batch-a"
	local branch_b="feature/gh-99040-batch-b"
	local args_file="${TEST_ROOT}/batch-prefetch-args"
	local output=""
	local rc=0
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" branch "$branch_a" || rc=1
	git -C "$repo_path" branch "$branch_b" || rc=1
	git -C "$repo_path" worktree add -q "$wt_a" "$branch_a" || rc=1
	git -C "$repo_path" worktree add -q "$wt_b" "$branch_b" || rc=1

	output=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_query_exact_merged_pr_batch() {
			printf '%s\n' "$*" >"$args_file"
			printf '%s\n' "$branch_a"
			return 0
		}
		_clean_build_exact_merged_pr_branches "main"
	) || rc=1

	[[ "$output" == "$branch_a" ]] || rc=1
	grep -Fq -- "$branch_a" "$args_file" 2>/dev/null || rc=1
	grep -Fq -- "$branch_b" "$args_file" 2>/dev/null || rc=1
	print_result "exact merged PR batch prefetch covers registered worktree heads" "$rc" \
		"Expected one batch to contain both worktree branch heads"
	return 0
}

test_exact_merged_pr_batch_uses_response_owned_cost() {
	local repo_path="${TEST_ROOT}/repo-batch-cost"
	local args_file="${TEST_ROOT}/batch-cost-args"
	local branch="feature/gh-99043-batch-cost"
	local output=""
	local rc=0
	setup_repo "$repo_path" || rc=1

	output=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_gh_graphql() {
			printf 'response-cost=%s route=%s args=%s\n' \
				"${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" \
				"${AIDEVOPS_GH_ROUTE_DECISION:-}" "$*" >"$args_file"
			printf '%s\n' '{"data":{"repository":{"q0":{"nodes":[{"headRefName":"feature/gh-99043-batch-cost"}]}},"rateLimit":{"cost":2}}}'
			return 0
		}
		_clean_query_exact_merged_pr_batch "testowner" "testrepo" "$branch"
	) || rc=1

	[[ "$output" == "$branch" ]] || rc=1
	grep -Fq 'response-cost=1' "$args_file" 2>/dev/null || rc=1
	grep -Fq 'route=worktree-clean-merged-pr-batch-exact-cost' "$args_file" 2>/dev/null || rc=1
	grep -Fq 'rateLimit{cost}' "$args_file" 2>/dev/null || rc=1
	if grep -Fq -- '--jq' "$args_file" 2>/dev/null; then
		rc=1
	fi
	print_result "exact merged PR batch uses response-owned GraphQL cost" "$rc" \
		"Expected a raw metered response, positive cost validation, and local projection"
	return 0
}

test_exact_merged_pr_batch_rejects_nonpositive_cost() {
	local repo_path="${TEST_ROOT}/repo-batch-invalid-cost"
	local rc=0
	setup_repo "$repo_path" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_gh_graphql() {
			printf '%s\n' '{"data":{"repository":{},"rateLimit":{"cost":0}}}'
			return 0
		}
		if _clean_query_exact_merged_pr_batch "testowner" "testrepo" \
			"feature/gh-99044-invalid-cost" >/dev/null; then
			exit 1
		fi
	) || rc=1

	print_result "exact merged PR batch rejects nonpositive response cost" "$rc" \
		"Expected an unmetered GraphQL response to fail closed"
	return 0
}

test_complete_exact_prefetch_skips_per_head_lookup() {
	local repo_path="${TEST_ROOT}/repo-complete-prefetch"
	local marker="${TEST_ROOT}/complete-prefetch-gh-called"
	local rc=0
	setup_repo "$repo_path" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_WT_CLEAN_EXACT_PR_PREFETCH_COMPLETE=true
		gh_pr_list() {
			printf 'called\n' >"$marker"
			printf '1\n'
			return 0
		}
		if _clean_branch_has_exact_merged_pr "feature/gh-99041-not-merged" ""; then
			exit 1
		fi
	) || rc=1

	[[ ! -e "$marker" ]] || rc=1
	print_result "complete exact merged PR prefetch skips per-head lookup" "$rc" \
		"Expected a complete negative batch result to suppress redundant gh_pr_list calls"
	return 0
}

test_prepared_git_branch_cache_avoids_per_branch_query() {
	local repo_path="${TEST_ROOT}/repo-merged-cache"
	local branch="feature/gh-99042-merged-cache"
	local marker="${TEST_ROOT}/merged-cache-git-called"
	local rc=0
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" branch "$branch" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_prepare_git_branch_caches "main"
		git() {
			printf 'called\n' >"$marker"
			return 1
		}
		_clean_branch_is_locally_merged "$branch" "main"
	) || rc=1

	[[ ! -e "$marker" ]] || rc=1
	print_result "prepared Git branch cache avoids per-branch query" "$rc" \
		"Expected local merged classification to use the scan-level cache"
	return 0
}

test_auto_clean_skips_redundant_preview_scan() {
	local repo_path="${TEST_ROOT}/repo-auto-single-pass"
	local scan_marker="${TEST_ROOT}/auto-single-pass-scan"
	local remove_marker="${TEST_ROOT}/auto-single-pass-remove"
	local rc=0
	setup_repo "$repo_path" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_preflight_main_worktree() { printf '%s\n' "$repo_path"; return 0; }
		_clean_prepare_git_branch_caches() { return 0; }
		_clean_fetch_remotes() { printf 'false\n'; return 0; }
		_clean_build_merged_pr_branches() { return 0; }
		_clean_build_exact_merged_pr_branches() { return 0; }
		_clean_build_open_pr_branches() { return 0; }
		_clean_build_closed_pr_branches() { return 0; }
		_clean_scan_merged() { printf 'called\n' >"$scan_marker"; return 0; }
		_clean_remove_merged() { printf 'called\n' >"$remove_marker"; return 0; }
		cmd_clean --auto --force-merged >/dev/null 2>&1
	) || rc=1

	[[ ! -e "$scan_marker" ]] || rc=1
	[[ -e "$remove_marker" ]] || rc=1
	print_result "automatic cleanup skips redundant preview scan" "$rc" \
		"Expected --auto to classify only in the removal pass"
	return 0
}

test_deleted_squash_merged_pr_metadata_wins_over_remote_deleted() {
	local repo_path="${TEST_ROOT}/repo-deleted-squash-pr"
	local wt_path="${TEST_ROOT}/wt-deleted-squash-pr"
	local log_file="${TEST_ROOT}/deleted-squash-pr-cleanup.log"
	local branch="feature/gh-99025-deleted-squash-pr"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'deleted squash merge head\n' >"$repo_path/deleted-squash-pr.txt" || rc=1
	git -C "$repo_path" add deleted-squash-pr.txt || rc=1
	git -C "$repo_path" commit -q -m "deleted squash-merged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "$branch" "" "false" ""
	) || rc=1

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ "$classification" != *"remote deleted"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "deleted squash-merged PR metadata wins over remote-deleted classification" "$rc" \
		"Expected exact merged PR branch metadata to bypass remote-deleted ancestry proof"
	return 0
}

test_exact_head_merged_pr_proof_wins_when_global_list_misses() {
	local repo_path="${TEST_ROOT}/repo-exact-head-pr"
	local wt_path="${TEST_ROOT}/wt-exact-head-pr"
	local log_file="${TEST_ROOT}/exact-head-pr-cleanup.log"
	local branch="feature/gh-99026-exact-head-pr"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'exact head merged proof\n' >"$repo_path/exact-head-pr.txt" || rc=1
	git -C "$repo_path" add exact-head-pr.txt || rc=1
	git -C "$repo_path" commit -q -m "exact head merged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		gh_pr_list() {
			local args="$*"
			[[ "$args" == *"--state merged"* ]] || return 1
			[[ "$args" == *"--json number"* ]] || return 1
			printf '1\n'
			return 0
		}
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" ""
	) || rc=1

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ "$classification" != *"remote deleted"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "exact-head merged PR proof wins when global merged list misses branch" "$rc" \
		"Expected exact-head merged PR lookup to bypass remote-deleted ancestry proof"
	return 0
}

test_exact_merged_pr_proof_recovers_unproven_traditional_merge() {
	local repo_path="${TEST_ROOT}/repo-unproven-traditional"
	local wt_path="${TEST_ROOT}/wt-unproven-traditional"
	local log_file="${TEST_ROOT}/unproven-traditional-cleanup.log"
	local branch="feature/gh-99028-unproven-traditional"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'traditional false positive\n' >"$repo_path/unproven-traditional.txt" || rc=1
	git -C "$repo_path" add unproven-traditional.txt || rc=1
	git -C "$repo_path" commit -q -m "traditional false-positive branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		git() {
			if [[ "${1:-}" == "branch" && "${2:-}" == "--merged" ]]; then
				printf '  %s\n' "$branch"
				return 0
			fi
			command git "$@"
		}
		gh_pr_list() {
			local args="$*"
			[[ "$args" == *"--state merged"* ]] || return 1
			[[ "$args" == *"--json number"* ]] || return 1
			printf '1\n'
			return 0
		}
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" ""
	) || rc=1

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "exact merged PR proof recovers unproven traditional merge" "$rc" \
		"Expected exact merged PR lookup to override branch-merged-unproven"
	return 0
}

test_closed_pr_without_ancestor_proof_classifies() {
	local repo_path="${TEST_ROOT}/repo-closed-pr"
	local wt_path="${TEST_ROOT}/wt-closed-pr"
	local log_file="${TEST_ROOT}/closed-pr-cleanup.log"
	local branch="feature/gh-99024-closed-pr"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'abandoned closed pr\n' >"$repo_path/closed-pr.txt" || rc=1
	git -C "$repo_path" add closed-pr.txt || rc=1
	git -C "$repo_path" commit -q -m "abandoned branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" "$branch"
	) || rc=1

	[[ "$classification" == *"closed PR"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "closed PR metadata does not require ancestor proof" "$rc" \
		"Expected closed PR classification with GitHub PR-state proof"
	return 0
}

test_remote_deleted_without_ancestor_proof_skips() {
	local repo_path="${TEST_ROOT}/repo-remote-deleted"
	local wt_path="${TEST_ROOT}/wt-remote-deleted"
	local log_file="${TEST_ROOT}/remote-deleted-cleanup.log"
	local branch="feature/gh-99023-remote-deleted"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'not ancestor remote deleted\n' >"$repo_path/remote-deleted.txt" || rc=1
	git -C "$repo_path" add remote-deleted.txt || rc=1
	git -C "$repo_path" commit -q -m "unmerged remote-deleted branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" ""
	) || rc=1

	[[ -z "$classification" ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*branch-merged-unproven.*mode=skipped.*merge_proof_result=not-ancestor" || rc=1
	print_result "remote-deleted metadata without ancestor proof skips" "$rc" \
		"Expected empty classification, surviving worktree, and unproven audit entry"
	return 0
}

test_closed_issue_unproven_branch_removes_worktree_preserves_branch() {
	local repo_path="${TEST_ROOT}/repo-closed-issue-unproven"
	local wt_path="${TEST_ROOT}/wt-closed-issue-unproven"
	local log_file="${TEST_ROOT}/closed-issue-unproven-cleanup.log"
	local branch="feature/auto-20260520-gh99029"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'closed issue unproven\n' >"$repo_path/closed-issue-unproven.txt" || rc=1
	git -C "$repo_path" add closed-issue-unproven.txt || rc=1
	git -C "$repo_path" commit -q -m "closed issue unproven branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		gh() {
			if [[ "${1:-}" == "issue" && "${2:-}" == "view" && "${3:-}" == "99029" ]]; then
				printf '%s\n' "CLOSED"
				return 0
			fi
			return 1
		}
		_clean_remove_merged "main" "$repo_path" "false" "" "" "false" ""
	) || rc=1

	local branch_exists=1
	git -C "$repo_path" rev-parse --verify "refs/heads/${branch}" >/dev/null 2>&1 && branch_exists=0
	[[ ! -d "$wt_path" ]] || rc=1
	[[ "$branch_exists" -eq 0 ]] || rc=1
	assert_file_contains "$log_file" "worktree-removed.*closed-issue-branch-preserved.*mode=branch-preserved.*recovery_path=branch-preserved-closed-issue" || rc=1
	print_result "closed issue unproven branch removes worktree and preserves branch" "$rc" \
		"Expected removed worktree, preserved branch, and branch-preserved audit entry"
	return 0
}

test_fix_numeric_closed_issue_branch_removes_worktree_preserves_branch() {
	local repo_path="${TEST_ROOT}/repo-fix-numeric-closed-issue"
	local wt_path="${TEST_ROOT}/wt-fix-numeric-closed-issue"
	local log_file="${TEST_ROOT}/fix-numeric-closed-issue-cleanup.log"
	local branch="fix/99031-overload-ci"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'fix numeric closed issue\n' >"$repo_path/fix-numeric-closed-issue.txt" || rc=1
	git -C "$repo_path" add fix-numeric-closed-issue.txt || rc=1
	git -C "$repo_path" commit -q -m "fix numeric closed issue branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		gh() {
			if [[ "${1:-}" == "issue" && "${2:-}" == "view" && "${3:-}" == "99031" ]]; then
				printf '%s\n' "CLOSED"
				return 0
			fi
			return 1
		}
		_clean_remove_merged "main" "$repo_path" "false" "" "" "false" ""
	) || rc=1

	local branch_exists=1
	git -C "$repo_path" rev-parse --verify "refs/heads/${branch}" >/dev/null 2>&1 && branch_exists=0
	[[ ! -d "$wt_path" ]] || rc=1
	[[ "$branch_exists" -eq 0 ]] || rc=1
	assert_file_contains "$log_file" "worktree-removed.*closed-issue-branch-preserved.*mode=branch-preserved.*issue=99031" || rc=1
	print_result "fix numeric closed issue branch removes worktree and preserves branch" "$rc" \
		"Expected fix/<issue> branch to parse issue and preserve branch"
	return 0
}

test_closed_issue_dirty_unproven_branch_stashes_and_preserves_branch() {
	local repo_path="${TEST_ROOT}/repo-closed-issue-dirty-unproven"
	local wt_path="${TEST_ROOT}/wt-closed-issue-dirty-unproven"
	local log_file="${TEST_ROOT}/closed-issue-dirty-unproven-cleanup.log"
	local branch="feature/auto-20260520-gh99030"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'closed issue dirty unproven\n' >"$repo_path/closed-issue-dirty-unproven.txt" || rc=1
	git -C "$repo_path" add closed-issue-dirty-unproven.txt || rc=1
	git -C "$repo_path" commit -q -m "closed issue dirty unproven branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1
	printf 'dirty archived state\n' >>"$wt_path/closed-issue-dirty-unproven.txt" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		worktree_has_changes() { git -C "$1" status --porcelain 2>/dev/null | grep -q .; return $?; }
		gh() {
			if [[ "${1:-}" == "issue" && "${2:-}" == "view" && "${3:-}" == "99030" ]]; then
				printf '%s\n' "CLOSED"
				return 0
			fi
			return 1
		}
		_clean_remove_merged "main" "$repo_path" "false" "" "" "false" ""
	) || rc=1

	local branch_exists=1 stash_count=0
	git -C "$repo_path" rev-parse --verify "refs/heads/${branch}" >/dev/null 2>&1 && branch_exists=0
	stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ') || stash_count=0
	[[ ! -d "$wt_path" ]] || rc=1
	[[ "$branch_exists" -eq 0 ]] || rc=1
	[[ "$stash_count" -gt 0 ]] || rc=1
	assert_file_contains "$log_file" "worktree-removed.*closed-issue-branch-preserved.*mode=branch-preserved.*recovery_path=branch-preserved-closed-issue" || rc=1
	print_result "closed issue dirty unproven branch stashes and preserves branch" "$rc" \
		"Expected removed worktree, preserved branch, stash archive, and audit entry"
	return 0
}

test_closed_issue_dirty_lock_race_preserves_files() {
	local repo_path="${TEST_ROOT}/repo-closed-issue-dirty-race"
	local wt_path="${TEST_ROOT}/wt-closed-issue-dirty-race"
	local log_file="${TEST_ROOT}/closed-issue-dirty-race-cleanup.log"
	local wrapper_path="${TEST_ROOT}/closed-issue-dirty-race-git"
	local concurrent_stash_marker="${TEST_ROOT}/closed-issue-dirty-race-concurrent-stash"
	local final_race_marker="${TEST_ROOT}/closed-issue-dirty-race-final"
	local branch="feature/auto-20260520-gh99033"
	local foreign_branch="feature/foreign-concurrent-stash"
	local foreign_wt_path="${TEST_ROOT}/wt-foreign-concurrent-stash"
	local expected_status=""
	local actual_status=""
	local expected_tracked=""
	local expected_untracked=""
	local metadata=""
	local wt_root=""
	local stash_count=0
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'closed issue dirty race\n' >"$repo_path/closed-issue-dirty-race.txt" || rc=1
	git -C "$repo_path" add closed-issue-dirty-race.txt || rc=1
	git -C "$repo_path" commit -q -m "closed issue dirty race branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1
	git -C "$repo_path" worktree add -q -b "$foreign_branch" "$foreign_wt_path" main || rc=1
	wt_root=$(git -C "$wt_path" rev-parse --show-toplevel) || rc=1
	printf 'dirty tracked state\n' >>"$wt_path/closed-issue-dirty-race.txt" || rc=1
	printf 'dirty untracked state\n' >"$wt_path/untracked-race.txt" || rc=1
	printf 'foreign concurrent state\n' >"$foreign_wt_path/foreign-stash.txt" || rc=1
	expected_status=$(git -C "$wt_path" status --porcelain --untracked-files=all) || rc=1
	expected_tracked=$(<"$wt_path/closed-issue-dirty-race.txt")
	expected_untracked=$(<"$wt_path/untracked-race.txt")
	cat >"$wrapper_path" <<'RACE_GIT'
#!/usr/bin/env bash
if [[ "$*" == *"worktree remove"* && ! -e "${RACE_MARKER:?}" ]]; then
	: >"$RACE_MARKER"
	"${REAL_GIT:?}" -C "${RACE_REPO:?}" worktree lock --reason \
		"foreign-after-stash-archive" "${RACE_WORKTREE:?}" || exit 1
fi
exec "${REAL_GIT:?}" "$@"
RACE_GIT
	chmod +x "$wrapper_path" || rc=1

	if (
		cd "$repo_path" || exit 1
		export AIDEVOPS_REAL_GIT_BIN="$wrapper_path"
		export REAL_GIT="$GIT_BIN"
		export RACE_MARKER="$final_race_marker"
		export RACE_REPO="$repo_path"
		export RACE_WORKTREE="$wt_path"
		source_clean_lib_with_stubs || exit 1
		capture_worktree_process_cwds() {
			printf '/unrelated-cwd\n'
			return 0
		}
		worktree_has_changes() {
			local candidate_path="$1"
			git -C "$candidate_path" status --porcelain 2>/dev/null | grep -q .
			return $?
		}
		git() {
			local all_args="$*"
			if [[ "$all_args" == *"-C $wt_path stash push"* && ! -e "$concurrent_stash_marker" ]]; then
				"$GIT_BIN" "$@" || return $?
				: >"$concurrent_stash_marker"
				"$GIT_BIN" -C "$foreign_wt_path" stash push -u \
					-m "foreign concurrent stash" >/dev/null 2>&1 || return 1
				return 0
			fi
			"$GIT_BIN" "$@"
			return $?
		}
		_clean_remove_classified_worktree "$wt_path" "$branch" "true" "true" \
			"test=dirty-lock-race" "$repo_path"
	); then
		rc=1
	fi

	actual_status=$(git -C "$wt_path" status --porcelain --untracked-files=all 2>/dev/null) || rc=1
	metadata=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null) || rc=1
	stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ') || stash_count=0
	[[ -e "$concurrent_stash_marker" && -e "$final_race_marker" && -d "$wt_path" ]] || rc=1
	[[ "$(<"$wt_path/closed-issue-dirty-race.txt")" == "$expected_tracked" ]] || rc=1
	[[ "$(<"$wt_path/untracked-race.txt")" == "$expected_untracked" ]] || rc=1
	[[ "$actual_status" == "$expected_status" ]] || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "locked foreign-after-stash-archive" || rc=1
	[[ "$stash_count" -ge 2 ]] || rc=1
	print_result "closed issue dirty lock race preserves files" "$rc" \
		"Expected exact concurrent stash recovery, restored dirty files, and foreign lock authority"
	return 0
}

test_force_merged_preserves_unreadable_index() {
	local repo_path="${TEST_ROOT}/repo-unreadable-index"
	local wt_path="${TEST_ROOT}/wt-unreadable-index"
	local log_file="${TEST_ROOT}/unreadable-index-cleanup.log"
	local branch="feature/gh-99026-unreadable-index"
	local git_dir=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" branch "$branch" main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1
	git_dir=$(git -C "$wt_path" rev-parse --absolute-git-dir) || rc=1
	: >"${git_dir}/index"

	if (
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_remove_classified_worktree "$wt_path" "$branch" "true" "false" \
			"test=unreadable-index" "$repo_path"
	); then
		rc=1
	fi

	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*unreadable-git-state.*mode=skipped" || rc=1
	print_result "force-merged cleanup preserves unreadable index" "$rc" \
		"Expected unreadable index to block forced merged-worktree removal"
	return 0
}

test_degraded_cleanup_audits_unreadable_index() {
	local repo_path="${TEST_ROOT}/repo-degraded-unreadable-index"
	local wt_path="${TEST_ROOT}/wt-degraded-unreadable-index"
	local log_file="${TEST_ROOT}/degraded-unreadable-index-cleanup.log"
	local branch="feature/gh-99027-degraded-unreadable-index"
	local git_dir=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" branch "$branch" main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1
	git_dir=$(git -C "$wt_path" rev-parse --absolute-git-dir) || rc=1
	: >"${git_dir}/index"

	if (
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		_clean_has_exact_removal_lease() { return 0; }
		_clean_degraded_visibility_fallback_allowed "$wt_path" "$branch" \
			"$_WT_CLEAN_TYPE_CLOSED_PR" "" "$branch" "" \
			"test=degraded-unreadable-index" "main"
	); then
		rc=1
	fi

	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*unreadable-git-state.*mode=skipped" || rc=1
	print_result "degraded cleanup audits unreadable index" "$rc" \
		"Expected unreadable index to block degraded recoverable cleanup"
	return 0
}

echo "=== test-worktree-cleanup-branch-merged-owned-skip.sh ==="
test_protected_pass_set_blocks_branch_merged_removal
test_terminal_pr_proof_bypasses_protected_pass_skip
test_terminal_pr_cleanup_waits_for_deferred_parent_exit
test_reused_legacy_marker_pid_expires
test_dead_marker_preserves_replacement_owner
test_terminal_cleanup_requires_removal_lease
test_cleanup_lease_released_when_removal_guard_blocks
test_remove_merged_reports_metadata_verification_failure
test_squash_merged_pr_without_ancestor_proof_classifies
test_prefetched_merged_pr_metadata_skips_exact_head_lookup
test_merged_pr_list_passes_explicit_repo_slug
test_exact_merged_pr_batch_prefetch_covers_worktree_heads
test_exact_merged_pr_batch_uses_response_owned_cost
test_exact_merged_pr_batch_rejects_nonpositive_cost
test_complete_exact_prefetch_skips_per_head_lookup
test_prepared_git_branch_cache_avoids_per_branch_query
test_auto_clean_skips_redundant_preview_scan
test_deleted_squash_merged_pr_metadata_wins_over_remote_deleted
test_exact_head_merged_pr_proof_wins_when_global_list_misses
test_exact_merged_pr_proof_recovers_unproven_traditional_merge
test_closed_pr_without_ancestor_proof_classifies
test_remote_deleted_without_ancestor_proof_skips
test_closed_issue_unproven_branch_removes_worktree_preserves_branch
test_fix_numeric_closed_issue_branch_removes_worktree_preserves_branch
test_closed_issue_dirty_unproven_branch_stashes_and_preserves_branch
test_closed_issue_dirty_lock_race_preserves_files
test_force_merged_preserves_unreadable_index
test_degraded_cleanup_audits_unreadable_index

printf '\nResults: %d/%d passed, %d failed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
