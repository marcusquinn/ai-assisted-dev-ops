#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worktree Removal Audit Tests — Manual and Recoverable Cleanup Coverage
# =============================================================================
# Sourced by ../test-worktree-removal-audit.sh.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_WORKTREE_REMOVAL_AUDIT_MANUAL_TESTS_LOADED:-}" ]] && return 0
_WORKTREE_REMOVAL_AUDIT_MANUAL_TESTS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Manual cleanup archives first, removes through native Git, and verifies exact
# metadata absence before ownership is unregistered.
# =============================================================================
test_manual_cleanup_archives_removes_and_prunes() {
	local log_file="${TEST_DIR}/manual-archive-cleanup.log"
	local repo_path="${TEST_DIR}/manual-archive-repo"
	local wt_path="${TEST_DIR}/manual-archive-worktree"
	local trash_destination="${TEST_DIR}/manual-archive-trash"
	local unregister_log="${TEST_DIR}/manual-archive-unregister.log"
	local cleanup_receipt_dir="${TEST_DIR}/manual-cleanup-receipts"
	local cleanup_receipt="${TEST_DIR}/manual-cleanup-receipts/example_repo-321.json"
	local wt_root=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/manual-archive" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
		unset _FULL_LOOP_CLEANUP_RECEIPT_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		SCRIPT_NAME="worktree-helper.sh"
		_WTAR_WH_CALLER="worktree-helper.sh"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		export AIDEVOPS_REAL_GIT_BIN="$GIT_BIN"
		export AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_destination"
		export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir"
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		full_loop_write_cleanup_deferred example/repo 321 "$wt_path" feature/manual-archive \
			"$$" manual-cleanup-test not-requested >/dev/null
		get_repo_root() {
			printf '%s\n' "$repo_path"
			return 0
		}
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		is_registered_canonical() { return 1; }
		unregister_worktree() {
			local removed_path="$1"
			printf '%s\n' "$removed_path" >>"$unregister_log"
			return 0
		}
		localdev_auto_branch_rm() { return 0; }
		preview_proxy_auto_free() { return 0; }
		_remove_cleanup_and_execute "$wt_path"
	); then
		rc=1
	fi
	[[ ! -e "$wt_path" && -d "$trash_destination" ]] || rc=1
	compgen -G "${trash_destination}/aidevops-worktree-cleanup-*/manual-archive-worktree" >/dev/null || rc=1
	if "$GIT_BIN" -C "$repo_path" worktree list --porcelain | grep -Fqx "worktree $wt_root"; then
		rc=1
	fi
	grep -Fxq "$wt_path" "$unregister_log" 2>/dev/null || rc=1
	assert_file_contains "$log_file" "worktree-removed.*manual.*mode=trash" || rc=1
	jq -e '.repository == "example/repo" and .pr_number == 321
		and .resource_cleanup_state == "CLEANED" and .cleanup_lease.state == "released"' \
		"$cleanup_receipt" >/dev/null || rc=1
	print_result "manual_cleanup_archives_removes_and_prunes" "$rc" \
		"Expected archive-first manual cleanup to verify metadata, unregister, and transition its exact receipt"
	return 0
}

# =============================================================================
# Manual targeted cleanup may recover from degraded process-CWD visibility only
# with exact-head merged-PR proof, no open PR, clean state, and an owned lease.
# =============================================================================
test_manual_cleanup_recovers_degraded_visibility_exact_head() {
	local log_file="${TEST_DIR}/manual-degraded-cleanup.log" repo_path="${TEST_DIR}/manual-degraded-repo"
	local wt_path="${TEST_DIR}/manual-degraded-worktree" trash_destination="${TEST_DIR}/manual-degraded-trash"
	local unregister_log="${TEST_DIR}/manual-degraded-unregister.log" branch_name="feature/manual-degraded"
	local head_sha="" metadata="" rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	head_sha=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	if ! (
		cd "$repo_path" || exit 1
		unset _WORKTREE_CMDS_LIB_LOADED _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		SCRIPT_NAME="worktree-helper.sh"
		_WTAR_WH_CALLER="worktree-helper.sh"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		export AIDEVOPS_REAL_GIT_BIN="$GIT_BIN"
		export AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_destination"
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		get_repo_root() {
			printf '%s\n' "$repo_path"
			return 0
		}
		worktree_removal_guard() {
			local candidate="$1"
			local caller="$2"
			local reason="$3"
			WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
			: "$candidate" "$caller" "$reason"
			return 2
		}
		worktree_has_changes() {
			local candidate="$1"
			[[ -n "$("$GIT_BIN" -C "$candidate" status --porcelain 2>/dev/null)" ]]
			return $?
		}
		is_registered_canonical() { return 1; }
		is_worktree_owned_by_others() { return 1; }
		is_worktree_owned_by_others_for_pid() { return 1; }
		worktree_has_exact_owner_contract() { return 0; }
		_branch_has_active_interactive_claim() { return 1; }
		_remove_repo_slug_for_worktree() {
			local candidate="$1"
			: "$candidate"
			printf '%s\n' "example/repository"
			return 0
		}
		gh_pr_list() {
			local all_args="$*"
			case "$all_args" in
			*"--state merged"*)
				printf '[{"number":42,"state":"MERGED","mergedAt":"2026-08-01T00:00:00Z","headRefName":"%s","headRefOid":"%s"}]\n' \
					"$branch_name" "$head_sha"
				;;
			*"--state open"*) printf '%s\n' '[]' ;;
			*) return 1 ;;
			esac
			return 0
		}
		_clean_acquire_removal_lease() {
			local candidate="$1"
			local branch="$2"
			: "$candidate" "$branch"
			return 0
		}
		unregister_worktree_if_owner_pid() { return 0; }
		unregister_worktree_if_owner_contract() {
			local candidate="$1"
			unregister_worktree "$candidate"
			return 0
		}
		unregister_worktree() {
			local removed_path="$1"
			printf '%s\n' "$removed_path" >>"$unregister_log"
			return 0
		}
		localdev_auto_branch_rm() { return 0; }
		preview_proxy_auto_free() { return 0; }
		_remove_resolve_path() {
			local target="$1"
			printf '%s\n' "$target"
			return 0
		}
		cmd_remove "$wt_path"
	); then
		rc=1
	fi
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	[[ ! -e "$wt_path" && -d "$trash_destination" ]] || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "branch refs/heads/${branch_name}" && rc=1
	"$GIT_BIN" -C "$repo_path" show-ref --verify --quiet "refs/heads/${branch_name}" || rc=1
	grep -Fxq "$wt_path" "$unregister_log" 2>/dev/null || rc=1
	assert_file_contains "$log_file" "worktree-removed.*manual.*mode=recoverable-trash.*merged_pr=42.*branch_preserved=true" || rc=1
	print_result "manual_cleanup_recovers_degraded_visibility_exact_head" "$rc" \
		"Expected candidate-local archive-first removal with exact merged proof and branch preservation"
	return 0
}

# =============================================================================
# A degraded cleanup lease is owned by the leaf executor PID, not the stable
# runtime PID used by generic interactive ownership checks. Rechecks after lease
# acquisition require the complete PID/session/task contract and fail closed if
# that evidence is replaced, deleted, or unavailable.
# =============================================================================
test_manual_degraded_recheck_requires_live_exact_lease() {
	local repo_path="${TEST_DIR}/manual-degraded-lease-repo"
	local wt_path="${TEST_DIR}/manual-degraded-lease-worktree"
	local registry_dir="${TEST_DIR}/manual-degraded-lease-registry"
	local branch_name="feature/manual-degraded-lease"
	local head_sha=""
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	head_sha=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED _WORKTREE_CLEAN_LIB_LOADED \
			_SHARED_WORKTREE_REGISTRY_LOADED 2>/dev/null || true
		export WORKTREE_REGISTRY_DIR="$registry_dir"
		export WORKTREE_REGISTRY_DB="${registry_dir}/worktree-registry.db"
		# shellcheck source=../shared-worktree-registry.sh
		source "$REGISTRY_HELPER"
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		sleep 30 &
		local runtime_pid=$!
		trap 'kill "$runtime_pid" 2>/dev/null || true' EXIT
		export OPENCODE_PID="$runtime_pid"
		worktree_has_changes() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		_remove_repo_slug_for_worktree() {
			local candidate="$1"
			: "$candidate"
			printf '%s\n' "example/repository"
			return 0
		}
		gh_pr_list() {
			local all_args="$*"
			case "$all_args" in
			*"--state merged"*)
				printf '[{"number":42,"state":"MERGED","mergedAt":"2026-08-01T00:00:00Z","headRefName":"%s","headRefOid":"%s"}]\n' \
					"$branch_name" "$head_sha"
				;;
			*"--state open"*) printf '%s\n' '[]' ;;
			*) return 1 ;;
			esac
			return 0
		}
		export WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		_clean_acquire_removal_lease "$wt_path" "$branch_name" || exit 1
		is_worktree_owned_by_others "$wt_path" || exit 1
		if is_worktree_owned_by_others_for_pid "$wt_path" "$$"; then
			exit 1
		fi
		_remove_degraded_fallback_allowed "$wt_path" "$$" || exit 1

		local registry_path=""
		registry_path=$(_wt_registry_lookup_path "$wt_path") || exit 1
		sqlite3 "$WORKTREE_REGISTRY_DB" "
			UPDATE worktree_owners
			SET owner_session = 'cleanup-replaced'
			WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
		" || exit 1
		if _remove_degraded_fallback_allowed "$wt_path" "$$"; then
			exit 1
		fi

		sqlite3 "$WORKTREE_REGISTRY_DB" "
			DELETE FROM worktree_owners
			WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
		" || exit 1
		if _remove_degraded_fallback_allowed "$wt_path" "$$"; then
			exit 1
		fi

		WORKTREE_REGISTRY_DB="${registry_dir}/missing.db"
		if _remove_degraded_fallback_allowed "$wt_path" "$$"; then
			exit 1
		fi
		exit 0
	); then
		rc=1
	fi
	print_result "manual_degraded_recheck_requires_live_exact_lease" "$rc" \
		"Expected post-lease checks to accept only the live exact PID/session/task contract"
	return 0
}

test_manual_degraded_recovery_rejects_unsafe_candidates() {
	local repo_path="${TEST_DIR}/manual-degraded-refusal-repo"
	local wt_path="${TEST_DIR}/manual-degraded-refusal-worktree"
	local branch_name="feature/manual-degraded-refusal"
	local head_sha=""
	local proof_mode="head-mismatch"
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	head_sha=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		RED="" NC=""
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		worktree_has_changes() { return 1; }
		is_worktree_owned_by_others() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		_remove_repo_slug_for_worktree() {
			local candidate="$1"
			: "$candidate"
			printf '%s\n' "example/repository"
			return 0
		}
		gh_pr_list() {
			local all_args="$*"
			local proof_head="$head_sha"
			[[ "$proof_mode" != "head-mismatch" ]] || proof_head="0000000000000000000000000000000000000000"
			case "$all_args" in
			*"--state merged"*)
				printf '[{"number":42,"state":"MERGED","mergedAt":"2026-08-01T00:00:00Z","headRefName":"%s","headRefOid":"%s"}]\n' \
					"$branch_name" "$proof_head"
				;;
			*"--state open"*)
				if [[ "$proof_mode" == "open-pr" ]]; then
					printf '[{"number":43,"headRefName":"%s","headRefOid":"%s"}]\n' "$branch_name" "$head_sha"
				else
					printf '%s\n' '[]'
				fi
				;;
			*) return 1 ;;
			esac
			return 0
		}
		WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		proof_mode="open-pr"
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		printf 'dirty\n' >"${wt_path}/untracked.txt"
		worktree_has_changes() {
			local candidate="$1"
			[[ -n "$("$GIT_BIN" -C "$candidate" status --porcelain 2>/dev/null)" ]]
			return $?
		}
		proof_mode="valid"
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		exit 0
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	print_result "manual_degraded_recovery_rejects_unsafe_candidates" "$rc" \
		"Expected head mismatch, open PR, and dirty state to fail closed"
	return 0
}

# =============================================================================
# A recoverable caller cannot rely on stale guard evidence. If a foreign lock
# exists when archive preparation starts, source removal must not start.
# =============================================================================
test_recoverable_cleanup_preserves_lock_acquired_after_guard() {
	local log_file="${TEST_DIR}/recoverable-race-cleanup.log"
	local repo_path="${TEST_DIR}/recoverable-race-repo"
	local wt_path="${TEST_DIR}/recoverable-race-worktree"
	local wt_root=""
	local metadata=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/recoverable-race" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "foreign-race-lock" "$wt_path" || rc=1
	if (
		unset _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${CLEAN_HELPER%/*}"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		_WTAR_WH_CALLER="test.sh"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		worktree_removal_guard() {
			WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
			return 2
		}
		worktree_has_changes() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		_clean_has_exact_removal_lease() { return 0; }
		_clean_remove_classified_worktree "$wt_path" "feature/recoverable-race" \
			"false" "false" "test=context" "$repo_path" \
			"$_WT_CLEAN_MODE_RECOVERABLE" "true"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	printf '%s\n' "$metadata" | grep -Eq '^locked([[:space:]]|$)' || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-worktree-locked.*mode=skipped" || rc=1
	print_result "recoverable_cleanup_preserves_lock_acquired_after_guard" "$rc" \
		"Expected archive preparation to preserve a lock after a stale guard"
	return 0
}

# =============================================================================
# Recoverable cleanup must retain both source and completed archive if its exact
# lease disappears while the archive copy is in progress.
# =============================================================================
test_recoverable_cleanup_preserves_lease_loss_after_archive() {
	local log_file="${TEST_DIR}/recoverable-lease-race-cleanup.log"
	local repo_path="${TEST_DIR}/recoverable-lease-race-repo"
	local wt_path="${TEST_DIR}/recoverable-lease-race-worktree"
	local trash_root="${TEST_DIR}/recoverable-lease-race-trash"
	local metadata=""
	local wt_root=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/recoverable-lease-race" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	if (
		unset _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${CLEAN_HELPER%/*}"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		_WTAR_WH_CALLER="test.sh"
		export AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		worktree_removal_guard() {
			WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
			return 2
		}
		worktree_has_changes() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		local lease_checks=0
		_clean_has_exact_removal_lease() {
			lease_checks=$((lease_checks + 1))
			[[ "$lease_checks" -eq 1 ]]
			return $?
		}
		_clean_remove_classified_worktree "$wt_path" "feature/recoverable-lease-race" \
			"false" "false" "test=context" "$repo_path" \
			"$_WT_CLEAN_MODE_RECOVERABLE" "true"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	compgen -G "${trash_root}/aidevops-worktree-cleanup-*/recoverable-lease-race-worktree" >/dev/null || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*cleanup-lease-changed-after-archive.*mode=skipped" || rc=1
	print_result "recoverable_cleanup_preserves_lease_loss_after_archive" "$rc" \
		"Expected source, metadata, and archive retention after cleanup lease replacement"
	return 0
}
