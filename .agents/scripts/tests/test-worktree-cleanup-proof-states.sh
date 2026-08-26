#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#23883 cleanup PR proof states.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEAN_LIB_PATH="${TEST_SCRIPTS_DIR}/worktree-clean-lib.sh"
REGISTRY_LIB_PATH="${TEST_SCRIPTS_DIR}/shared-worktree-registry.sh"
STATE_LIB_PATH="${TEST_SCRIPTS_DIR}/pulse-cleanup-worktree-state.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

TEST_GREEN=$'\033[0;32m'
TEST_RED=$'\033[0;31m'
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

fixture_git_mock() {
	if [[ "${1:-}" == "-C" && "${3:-}" == "status" && "${4:-}" == "--porcelain" ]]; then
		return 0
	fi
	if [[ "${1:-}" == "remote" && "${2:-}" == "get-url" && "${3:-}" == "origin" ]]; then
		printf '%s\n' 'git@github.com:marcusquinn/aidevops.git'
		return 0
	fi
	if [[ "${1:-}" == "branch" && "${2:-}" == "--merged" ]]; then
		return 0
	fi
	if [[ "${1:-}" == "rev-list" && "${2:-}" == "--left-right" && "${3:-}" == "--count" ]]; then
		case "${4:-}" in
		origin/main...refs/heads/fix/remote-contained | origin/main...refs/heads/fix/remote-dirty)
			printf '%s\n' '3 0'
			return 0
			;;
		origin/main...refs/heads/fix/remote-ahead)
			printf '%s\n' '3 1'
			return 0
			;;
		esac
	fi
	if [[ "${1:-}" == "rev-parse" ]]; then
		printf '%s\n' '0123456789abcdef0123456789abcdef01234567'
		return 0
	fi
	if [[ "${1:-}" == "merge-base" && "${2:-}" == "--is-ancestor" ]]; then
		return 1
	fi
	command git "$@"
	return $?
}

fixture_gh_pr_list_mock() {
	local repo="" state="" head="" jq=""
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--repo)
			repo="${2:-}"
			shift 2
			;;
		--state)
			state="${2:-}"
			shift 2
			;;
		--head)
			head="${2:-}"
			shift 2
			;;
		--jq)
			jq="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	if [[ -z "$repo" ]]; then
		printf '%s\n' '_rest_pr_list: --repo is required' >&2
		return 2
	fi
	if [[ "$mode" == "fail-pr-list" ]]; then
		return 1
	fi
	if [[ "$head" == "fix/exact-merged" && "$state" == "merged" && "$jq" == "length" ]]; then
		printf '%s\n' '1'
		return 0
	fi
	case "$state" in
	merged) printf '%s\n' 'fix/list-merged' ;;
	open) printf '%s\n' 'fix/open-pr' ;;
	closed) printf '%s\n' 'fix/closed-pr' ;;
	esac
	return 0
}

run_fixture() {
	local mode="$1"
	local fixture_code="$2"
	shift
	shift
	(
		set +e
		: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
		_WTAR_REMOVED="removed"
		_WTAR_SKIPPED="skipped"
		_WTAR_WH_CALLER="test"
		export RED GREEN YELLOW BLUE BOLD NC _WTAR_REMOVED _WTAR_SKIPPED _WTAR_WH_CALLER

		git() {
			fixture_git_mock "$@"
			return $?
		}

		gh_pr_list() {
			fixture_gh_pr_list_mock "$@"
			return $?
		}

		command() {
			if [[ "${1:-}" == "-v" && "${2:-}" == "gh" ]]; then
				return 0
			fi
			if [[ "${1:-}" == "-v" && "${2:-}" == "gh_pr_list" ]]; then
				return 0
			fi
			builtin command "$@"
		}

		# shellcheck source=/dev/null
		source "$CLEAN_LIB_PATH" >/dev/null 2>&1 || exit 9

		_branch_has_active_interactive_claim() { return 1; }
		is_worktree_owned_by_others() { return 1; }
		check_worktree_owner() {
			printf '\n'
			return 0
		}
		worktree_is_in_grace_period() { return 1; }
		branch_has_zero_commits_ahead() { return 1; }
		worktree_has_changes() { return 1; }
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		trash_path() { return 0; }
		localdev_auto_branch_rm() { return 0; }
		unregister_worktree() { return 0; }
		worktree_removal_guard() { return 0; }
		remove_worktree_path_permanently() { return 1; }
		log_worktree_removal_event() {
			printf '%s|%s|%s\n' "${4:-}" "${5:-}" "${6:-}" >>"$TEST_ROOT/audit.log"
			return 0
		}

		eval "$fixture_code"
	)
	return 0
}

test_builders_pass_repo() {
	local output
	# shellcheck disable=SC2016 # evaluated inside run_fixture after sourcing the cleanup lib
	output=$(run_fixture ok '_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS=""; printf "m=%s\n" "$(_clean_build_merged_pr_branches)"; printf "o=%s\n" "$(_clean_build_open_pr_branches)"; printf "c=%s\n" "$(_clean_build_closed_pr_branches)"; printf "u=%s\n" "$_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS"')
	if [[ "$output" == *"m=fix/list-merged"* && "$output" == *"o=fix/open-pr"* && "$output" == *"c=fix/closed-pr"* && "$output" == *"u="* ]]; then
		print_result "PR list builders pass explicit repo" 0
	else
		print_result "PR list builders pass explicit repo" 1 "($output)"
	fi
	return 0
}

test_exact_merged_pr_fallback() {
	local output
	# shellcheck disable=SC2016 # evaluated inside run_fixture after sourcing the cleanup lib
	output=$(run_fixture ok '_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS=""; _clean_classify_worktree "/tmp/wt-exact" "fix/exact-merged" "main" "false" "" "" "true" "" >/dev/null; printf "%s\n" "$_WT_CLEAN_LAST_MERGE_TYPE"')
	if [[ "$output" == "squash-merged PR" ]]; then
		print_result "exact-head merged PR classifies under REST fallback" 0
	else
		print_result "exact-head merged PR classifies under REST fallback" 1 "($output)"
	fi
	return 0
}

test_open_pr_protects_worktree() {
	local output
	# shellcheck disable=SC2016 # evaluated inside run_fixture after sourcing the cleanup lib
	output=$(run_fixture ok '_clean_classify_worktree "/tmp/wt-open" "fix/open-pr" "main" "false" "" "fix/open-pr" "true" "" >/dev/null; printf "%s\n" "$_WT_CLEAN_LAST_MERGE_TYPE"')
	if [[ -z "$output" ]]; then
		print_result "open PR proof protects worktree" 0
	else
		print_result "open PR proof protects worktree" 1 "($output)"
	fi
	return 0
}

test_closed_pr_positive_proof() {
	local output
	# shellcheck disable=SC2016 # evaluated inside run_fixture after sourcing the cleanup lib
	output=$(run_fixture ok '_clean_classify_worktree "/tmp/wt-closed" "fix/closed-pr" "main" "false" "" "" "true" "fix/closed-pr" >/dev/null; printf "%s\n" "$_WT_CLEAN_LAST_MERGE_TYPE"')
	if [[ "$output" == "closed PR" ]]; then
		print_result "closed-unmerged PR requires positive proof" 0
	else
		print_result "closed-unmerged PR requires positive proof" 1 "($output)"
	fi
	return 0
}

test_unknown_pr_proof_skips_remote_deleted() {
	local output
	: >"$TEST_ROOT/audit.log"
	# shellcheck disable=SC2016 # evaluated inside run_fixture after sourcing the cleanup lib
	output=$(run_fixture fail-pr-list '_WT_CLEAN_PR_PROOF_UNKNOWN_REASONS=""; _clean_build_merged_pr_branches >/dev/null || _clean_pr_proof_unknown_add "unknown:merged-pr-list-unavailable"; _clean_classify_worktree "/tmp/wt-unknown" "fix/unknown" "main" "false" "" "" "true" "" >/dev/null; printf "%s\n" "$_WT_CLEAN_LAST_MERGE_TYPE"')
	if [[ -z "$output" ]] && grep -q 'unknown:pr-proof-unavailable|skipped' "$TEST_ROOT/audit.log"; then
		print_result "unknown PR proof fails closed" 0
	else
		print_result "unknown PR proof fails closed" 1 "(type=$output audit=$(cat "$TEST_ROOT/audit.log" 2>/dev/null))"
	fi
	return 0
}

test_remote_tracking_default_classifies_clean_branch() {
	local output
	# shellcheck disable=SC2016 # evaluated inside run_fixture after sourcing the cleanup lib
	output=$(run_fixture ok '_WT_CLEAN_REMOTE_DEFAULT_REF="origin/main"; _clean_classify_worktree "/tmp/wt-remote" "fix/remote-contained" "main" "false" "" "" "true" "" >/dev/null; printf "%s|%s\n" "$_WT_CLEAN_LAST_MERGE_TYPE" "$_WT_CLEAN_LAST_AUDIT_CONTEXT"')
	if [[ "$output" == *"merged remote-tracking default"* && "$output" == *"merge_proof=remote-tracking-default-is-ancestor"* && "$output" == *"merge_proof_result=merged-remote-tracking-default"* ]]; then
		print_result "remote-tracking default proof classifies clean contained branch" 0
	else
		print_result "remote-tracking default proof classifies clean contained branch" 1 "($output)"
	fi
	return 0
}

test_remote_tracking_default_preserves_dirty_branch() {
	local output
	# shellcheck disable=SC2016 # evaluated inside run_fixture after sourcing the cleanup lib
	output=$(run_fixture ok '_WT_CLEAN_REMOTE_DEFAULT_REF="origin/main"; worktree_has_changes() { return 0; }; _clean_classify_worktree "/tmp/wt-remote-dirty" "fix/remote-dirty" "main" "true" "" "" "true" "" >/dev/null; printf "%s\n" "$_WT_CLEAN_LAST_MERGE_TYPE"')
	if [[ -z "$output" ]]; then
		print_result "remote-tracking default proof preserves dirty branch" 0
	else
		print_result "remote-tracking default proof preserves dirty branch" 1 "($output)"
	fi
	return 0
}

test_remote_tracking_default_allows_degraded_recovery() {
	local output
	# shellcheck disable=SC2016 # evaluated inside run_fixture after sourcing the cleanup lib
	output=$(run_fixture ok '_WT_CLEAN_REMOTE_DEFAULT_REF="origin/main"; WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"; _clean_has_exact_removal_lease() { return 0; }; if _clean_degraded_visibility_fallback_allowed "/tmp/wt-remote" "fix/remote-contained" "$_WT_CLEAN_TYPE_REMOTE_TRACKING_MERGED" "" "" "" "branch=fix/remote-contained" "main"; then printf "%s\n" allowed; else printf "%s\n" blocked; fi')
	if [[ "$output" == "allowed" ]]; then
		print_result "remote-tracking default proof allows degraded recovery" 0
	else
		print_result "remote-tracking default proof allows degraded recovery" 1 "($output)"
	fi
	return 0
}

test_remote_tracking_default_blocks_dirty_degraded_recovery() {
	local output
	# shellcheck disable=SC2016 # evaluated inside run_fixture after sourcing the cleanup lib
	output=$(run_fixture ok '_WT_CLEAN_REMOTE_DEFAULT_REF="origin/main"; WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"; _clean_has_exact_removal_lease() { return 0; }; worktree_has_changes() { return 0; }; if _clean_degraded_visibility_fallback_allowed "/tmp/wt-remote-dirty" "fix/remote-dirty" "$_WT_CLEAN_TYPE_REMOTE_TRACKING_MERGED" "" "" "" "branch=fix/remote-dirty" "main"; then printf "%s\n" allowed; else printf "%s\n" blocked; fi')
	if [[ "$output" == "blocked" ]]; then
		print_result "remote-tracking degraded recovery preserves dirty branch" 0
	else
		print_result "remote-tracking degraded recovery preserves dirty branch" 1 "($output)"
	fi
	return 0
}

test_recycled_same_command_owner_reaches_cleanup_path() {
	local output=""
	output=$(
		set +e
		export WORKTREE_REGISTRY_DIR="${TEST_ROOT}/owner-registry"
		export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
		LOGFILE="${TEST_ROOT}/owner-cleanup.log"
		_WTAR_SKIPPED="skipped"
		_WTAR_PC_CALLER="test"
		export LOGFILE _WTAR_SKIPPED _WTAR_PC_CALLER
		# shellcheck source=/dev/null
		source "$REGISTRY_LIB_PATH" || exit 9
		# shellcheck source=/dev/null
		source "$STATE_LIB_PATH" || exit 9
		pgrep() { return 1; }
		log_worktree_removal_event() { return 0; }

		local wt_path="${TEST_ROOT}/owner-recycled"
		local owner_pid=""
		mkdir -p "$wt_path"
		sleep 30 &
		owner_pid=$!
		register_worktree "$wt_path" "feature/recycled-owner" --owner-pid "$owner_pid"
		local registry_path=""
		local owner_comm=""
		registry_path=$(_wt_registry_lookup_path "$wt_path")
		owner_comm=$(_get_proc_comm "$owner_pid")
		sqlite3 "$WORKTREE_REGISTRY_DB" "
            UPDATE worktree_owners
            SET owner_comm = '$(_wt_sql_escape "$owner_comm")',
                owner_process_start = 'recycled-process-generation'
            WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
        "
		if _worktree_owner_alive "$wt_path" ""; then
			printf '%s\n' blocked
		elif check_worktree_owner "$wt_path" >/dev/null 2>&1; then
			printf '%s\n' retained
		else
			printf '%s\n' reclaimed
		fi
		kill "$owner_pid" 2>/dev/null || true
		wait "$owner_pid" 2>/dev/null || true
	)
	if [[ "$output" == "reclaimed" ]]; then
		print_result "recycled same-command owner reaches cleanup path" 0
	else
		print_result "recycled same-command owner reaches cleanup path" 1 "($output)"
	fi
	return 0
}

test_builders_pass_repo
test_exact_merged_pr_fallback
test_open_pr_protects_worktree
test_closed_pr_positive_proof
test_unknown_pr_proof_skips_remote_deleted
test_remote_tracking_default_classifies_clean_branch
test_remote_tracking_default_preserves_dirty_branch
test_remote_tracking_default_allows_degraded_recovery
test_remote_tracking_default_blocks_dirty_degraded_recovery
test_recycled_same_command_owner_reaches_cleanup_path

printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
