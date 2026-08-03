#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worktree Removal Audit Tests — Safety and Process Visibility Coverage
# =============================================================================
# Sourced by ../test-worktree-removal-audit.sh.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_WORKTREE_REMOVAL_AUDIT_SAFETY_TESTS_LOADED:-}" ]] && return 0
_WORKTREE_REMOVAL_AUDIT_SAFETY_TESTS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Skill-update cleanup must not delete the branch or unregister ownership when
# the guarded permanent-removal primitive refuses the worktree.
# =============================================================================
test_skill_cleanup_has_no_removal_failure_fallback() {
	local wt_path="${TEST_DIR}/skill-fallback-worktree"
	local side_effect_log="${TEST_DIR}/skill-fallback-effects.log"
	local rc=0
	mkdir -p "$wt_path"

	if ! (
		unset _SKILL_UPDATE_PR_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${SKILL_PR_HELPER%/*}"
		_WTAR_SU_CALLER="skill-update-helper.sh"
		# shellcheck source=../skill-update-pr-lib.sh
		source "$SKILL_PR_HELPER"
		get_default_branch() {
			printf '%s\n' "main"
			return 0
		}
		git() {
			local all_args="$*"
			case "$all_args" in
			*"rev-list --count main..HEAD"*) printf '%s\n' "0" ;;
			*"worktree remove"* | *"branch -D"*) printf '%s\n' "$all_args" >>"$side_effect_log" ;;
			*) "$GIT_BIN" "$@" || return $? ;;
			esac
			return 0
		}
		is_worktree_owned_by_others() { return 1; }
		worktree_removal_guard() { return 0; }
		remove_worktree_path_permanently() { return 1; }
		log_info() { return 0; }
		log_warning() { return 0; }
		unregister_worktree() {
			local removed_path="$1"
			printf '%s\n' "unregister:$removed_path" >>"$side_effect_log"
			return 0
		}
		_cleanup_worktree "$wt_path" "feature/skill-fallback"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	[[ ! -s "$side_effect_log" ]] || rc=1
	print_result "skill_cleanup_has_no_removal_failure_fallback" "$rc" \
		"Expected failed guarded removal to preserve the path, branch, and registry"
	return 0
}

# =============================================================================
# Shared removal guard treats Git worktree locks as a non-overridable safety
# boundary. Direct permanent deletion must not bypass the lock.
# =============================================================================
test_permanent_helper_preserves_git_locked_worktree() {
	local log_file="${TEST_DIR}/locked-cleanup.log"
	local repo_path="${TEST_DIR}/locked-repo"
	local wt_path="${TEST_DIR}/locked-worktree"
	local wt_root=""
	local metadata=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/locked" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "observation-provenance" "$wt_path" || rc=1
	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain 2>/dev/null) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	printf '%s\n' "$metadata" | grep -Eq '^locked([[:space:]]|$)' || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-worktree-locked.*mode=skipped" || rc=1
	print_result "permanent_helper_preserves_git_locked_worktree" "$rc" \
		"Expected locked worktree path and metadata to remain. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Git metadata failures are not evidence that a worktree is unlocked.
# =============================================================================
test_permanent_helper_fails_closed_on_unreadable_git_metadata() {
	local log_file="${TEST_DIR}/unreadable-cleanup.log"
	local wt_path="${TEST_DIR}/unreadable-worktree"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"
	printf 'gitdir: unavailable\n' >"${wt_path}/.git"

	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		git() {
			return 1
		}
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-metadata-unreadable.*mode=skipped" || rc=1
	print_result "permanent_helper_fails_closed_on_unreadable_git_metadata" "$rc" \
		"Expected unreadable Git metadata to block permanent removal. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# A successful metadata query that omits the exact candidate is ambiguous and
# must not be treated as proof that the candidate is unlocked.
# =============================================================================
test_permanent_helper_fails_closed_on_ambiguous_git_metadata() {
	local log_file="${TEST_DIR}/ambiguous-cleanup.log"
	local wt_path="${TEST_DIR}/ambiguous-worktree"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"
	printf 'gitdir: ambiguous\n' >"${wt_path}/.git"

	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		git() {
			local all_args="$*"
			case "$all_args" in
			*"rev-parse --show-toplevel"*) printf '%s\n' "$wt_path" ;;
			*"worktree list --porcelain -z"*)
				printf 'worktree %s\0HEAD 0123456789abcdef0123456789abcdef01234567\0detached\0\0' \
					"${TEST_DIR}/different-worktree"
				;;
			*) return 1 ;;
			esac
			return 0
		}
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-metadata-unreadable.*mode=skipped" || rc=1
	print_result "permanent_helper_fails_closed_on_ambiguous_git_metadata" "$rc" \
		"Expected ambiguous Git metadata to block permanent removal. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Verified unlocked worktrees remain eligible for the caller's existing policy.
# =============================================================================
test_guard_allows_verified_unlocked_worktree() {
	local repo_path="${TEST_DIR}/unlocked-repo"
	local wt_path="${TEST_DIR}/unlocked-worktree"
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/unlocked" || rc=1
	if ! (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		worktree_removal_guard "$wt_path" "test.sh" "manual" ""
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	print_result "guard_allows_verified_unlocked_worktree" "$rc" \
		"Expected verified unlocked worktree to pass the shared guard"
	return 0
}

# =============================================================================
# Test 10: optional guard context includes predicates needed for safe cleanup audit
# =============================================================================
test_optional_guard_context_logged() {
	local log_file="${TEST_DIR}/t10-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local context="branch=feature/gh23074 issue=23074 owner_guard=clear process_guard=clear recent_session_guard=clear commits=1 pr_state=none recovery_path=none"
	log_worktree_removal_event "$_WTAR_SKIPPED" "pulse-cleanup.sh" "/wt/context" "local-commits-no-pr" "skipped" "$context"
	local branch_merged_context="target_branch=main merge_proof=merge-base-is-ancestor merge_proof_result=ancestor branch=feature/gh23076 owner_guard=clear protected_status=clear"
	log_worktree_removal_event "$_WTAR_REMOVED" "worktree-helper.sh" "/wt/merged" "branch-merged" "permanent" "$branch_merged_context"

	local rc=0
	assert_file_contains "$log_file" "worktree-skipped.*local-commits-no-pr.*mode=skipped.*branch=feature/gh23074.*owner_guard=clear.*process_guard=clear.*recent_session_guard=clear.*commits=1.*pr_state=none.*recovery_path=none" || rc=1
	assert_file_contains "$log_file" "worktree-removed.*branch-merged.*mode=permanent.*target_branch=main.*merge_proof=merge-base-is-ancestor.*merge_proof_result=ancestor.*protected_status=clear" || rc=1
	print_result "optional_guard_context_logged" "$rc" \
		"Expected guard context audit. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 11: process-cwd helper refuses empty paths before glob-like matching
# =============================================================================
test_process_cwd_guard_refuses_empty_paths() {
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local rc=0
	if _worktree_has_process_cwd "" "/tmp/example"; then
		rc=1
	fi
	if _worktree_has_process_cwd "/tmp/example" ""; then
		rc=1
	fi
	print_result "process_cwd_guard_refuses_empty_paths" "$rc" \
		"Expected empty path inputs to return non-match"
	return 0
}

# =============================================================================
# Test 12: snapshot collection failures block removal, while an explicitly
# supplied empty successful snapshot avoids a second platform scan.
# =============================================================================
test_process_cwd_snapshot_failure_is_fail_closed() {
	local log_file="${TEST_DIR}/t12-cleanup.log"
	local wt_path="${TEST_DIR}/snapshot-failure-wt"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	capture_worktree_process_cwds() { return 1; }
	if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
		rc=1
	fi
	assert_file_contains "$log_file" "worktree-skipped.*cwd-visibility-unusable" || rc=1
	if ! worktree_removal_guard "$wt_path" "test.sh" "manual" ""; then
		rc=1
	fi
	print_result "process_cwd_snapshot_failure_is_fail_closed" "$rc" \
		"Expected collection failure to block and explicit empty snapshot to pass"
	return 0
}

# =============================================================================
# Test 13: each platform backend fails closed when it cannot publish any cwd
# target instead of treating an empty snapshot as authoritative.
# =============================================================================
test_snapshot_backend_requires_visible_target() {
	local rc=0
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	if [[ -d /proc ]]; then
		if (
			readlink() { return 1; }
			capture_worktree_process_cwds >/dev/null
		); then
			rc=1
		fi
	else
		if (
			lsof() { return 0; }
			capture_worktree_process_cwds >/dev/null
		); then
			rc=1
		fi
	fi
	print_result "snapshot_backend_requires_visible_target" "$rc" \
		"Expected an empty process-cwd backend result to fail closed"
	return 0
}

# =============================================================================
# The macOS lsof backend distinguishes complete output, partial/permission-
# limited output, and empty unusable output. Absence-only output never proves a
# candidate inactive.
# =============================================================================
test_lsof_snapshot_visibility_states() {
	local output=""
	local capture_status=0
	local rc=0

	if output=$(
		lsof() { return 0; }
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq 1 && -z "$output" ]] || rc=1

	if output=$(
		lsof() {
			printf 'p123\nn/visible-lsof-cwd\n'
			return 1
		}
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-lsof-cwd" ]] || rc=1

	if output=$(
		lsof() {
			printf 'p123\nn/complete-lsof-cwd\n'
			return 0
		}
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq 0 && "$output" == "/complete-lsof-cwd" ]] || rc=1
	print_result "lsof_snapshot_visibility_states" "$rc" \
		"Expected empty lsof to be unusable and partial lsof output to be degraded"
	return 0
}

# =============================================================================
# Test 14: a partially visible /proc snapshot preserves readable evidence and
# reports degraded visibility instead of aliasing it to a total failure.
# =============================================================================
test_proc_snapshot_preserves_degraded_visibility() {
	local proc_root="${TEST_DIR}/fake-proc"
	local output=""
	local capture_status=0
	local rc=0
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /hidden-cwd "${proc_root}/2/cwd"

	if output=$(
		readlink() {
			local link_path="$1"
			if [[ "$link_path" == */1/cwd ]]; then
				printf '/visible-cwd\n'
				return 0
			fi
			return 1
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_preserves_degraded_visibility" "$rc" \
		"Expected unreadable unknown ownership to preserve visible cwd evidence with degraded status"
	return 0
}

# =============================================================================
# Linux /proc entries that are unreadable but provably foreign do not invalidate
# otherwise usable evidence.
# =============================================================================
test_proc_snapshot_skips_foreign_uid_unreadable_entry() {
	local proc_root="${TEST_DIR}/fake-proc-foreign"
	local current_uid=""
	local foreign_uid=""
	local output=""
	local rc=0
	current_uid=$(id -u)
	foreign_uid=$((current_uid + 1))
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /foreign-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$foreign_uid" "$foreign_uid" "$foreign_uid" "$foreign_uid" >"${proc_root}/2/status"

	output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_skips_foreign_uid_unreadable_entry" "$rc" \
		"Expected foreign unreadable cwd to be skipped without hiding visible evidence"
	return 0
}

# =============================================================================
# Same-UID unreadability is explicitly degraded while preserving readable cwd
# evidence for candidate-specific positive matching.
# =============================================================================
test_proc_snapshot_marks_same_uid_unreadable_entry_degraded() {
	local proc_root="${TEST_DIR}/fake-proc-same-uid"
	local current_uid=""
	local output=""
	local capture_status=0
	local rc=0
	current_uid=$(id -u)
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /same-user-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$current_uid" "$current_uid" "$current_uid" "$current_uid" >"${proc_root}/2/status"

	if output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_marks_same_uid_unreadable_entry_degraded" "$rc" \
		"Expected simulated same-UID EACCES to return degraded status with visible evidence intact"
	return 0
}

# =============================================================================
# Degraded visibility is candidate-specific: unrelated readable CWDs require a
# recoverable path, while any readable target inside the candidate hard-blocks.
# =============================================================================
test_degraded_visibility_preserves_positive_candidate_match() {
	local log_file="${TEST_DIR}/degraded-candidate-cleanup.log"
	local wt_path="${TEST_DIR}/degraded-candidate"
	local guard_status=0
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	if worktree_removal_guard "$wt_path" "test.sh" "manual" "/unrelated-readable-cwd" \
		"$_WT_CWD_VISIBILITY_DEGRADED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	[[ "$guard_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "$_WT_CWD_REASON_DEGRADED" ]] || rc=1

	if worktree_removal_guard "$wt_path" "test.sh" "manual" "$wt_path/active-shell" \
		"$_WT_CWD_VISIBILITY_DEGRADED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	[[ "$guard_status" -eq 1 ]] || rc=1
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "active-cwd" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*cwd-visibility-degraded.*mode=recoverable-required" || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*active-cwd.*mode=skipped" || rc=1
	print_result "degraded_visibility_preserves_positive_candidate_match" "$rc" \
		"Expected unrelated denial to be recoverable-only and readable candidate CWD to hard-block"
	return 0
}

# =============================================================================
# Foreign skips alone are not usable evidence: an empty snapshot still blocks
# destructive cleanup.
# =============================================================================
test_proc_snapshot_requires_usable_evidence_after_foreign_skips() {
	local proc_root="${TEST_DIR}/fake-proc-foreign-only"
	local current_uid=""
	local foreign_uid=""
	local rc=0
	current_uid=$(id -u)
	foreign_uid=$((current_uid + 1))
	mkdir -p "${proc_root}/1"
	ln -s /foreign-cwd "${proc_root}/1/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$foreign_uid" "$foreign_uid" "$foreign_uid" "$foreign_uid" >"${proc_root}/1/status"

	if (
		readlink() { return 1; }
		_capture_worktree_proc_cwds "$proc_root" >/dev/null
	); then
		rc=1
	fi
	print_result "proc_snapshot_requires_usable_evidence_after_foreign_skips" "$rc" \
		"Expected zero captured cwd targets to remain fail-closed"
	return 0
}

# =============================================================================
# A process that vanishes during readlink is ignored when other usable evidence
# remains in the snapshot.
# =============================================================================
test_proc_snapshot_ignores_vanished_entry() {
	local proc_root="${TEST_DIR}/fake-proc-vanished"
	local output=""
	local rc=0
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /vanished-cwd "${proc_root}/2/cwd"

	output=$(
		readlink() {
			local link_path="$1"
			if [[ "$link_path" == */1/cwd ]]; then
				printf '/visible-cwd\n'
				return 0
			fi
			rm -f "$link_path"
			return 1
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_ignores_vanished_entry" "$rc" \
		"Expected a vanished process to be ignored without losing visible evidence"
	return 0
}

# =============================================================================
# Guard refusals expose a machine-readable reason without changing the
# exactly-once audit contract.
# =============================================================================
test_guard_reason_is_machine_readable() {
	local log_file="${TEST_DIR}/t15-cleanup.log"
	local wt_path="${TEST_DIR}/reason-wt"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	if worktree_removal_guard "$wt_path" "test.sh" "manual" "$wt_path"; then
		rc=1
	fi
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "active-cwd" ]] || rc=1
	assert_line_count "$log_file" 1 || rc=1
	print_result "guard_reason_is_machine_readable" "$rc" \
		"Expected active-cwd reason and exactly one audit row"
	return 0
}

# =============================================================================
# Test 16: manual removal renders safe actionable diagnostics for each shared
# guard reason. The guard remains the sole audit writer.
# =============================================================================
test_manual_guard_refusal_diagnostics() {
	local output_file="${TEST_DIR}/t16-output.log"
	local log_file="${TEST_DIR}/t16-cleanup.log"
	local rc=0
	local reason=""
	local guard_reason_to_test=""
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
	RED=""
	NC=""
	# shellcheck source=../worktree-helper-cmds.sh
	source "$COMMANDS_HELPER"
	worktree_removal_guard() {
		local path_to_remove="$1"
		local caller="$2"
		local removal_mode="$3"
		WORKTREE_REMOVAL_GUARD_REASON="$guard_reason_to_test"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$path_to_remove" \
			"$guard_reason_to_test" "skipped"
		: "$removal_mode"
		return 1
	}
	for reason in active-cwd current-worktree canonical-skip git-worktree-locked git-metadata-unreadable; do
		guard_reason_to_test="$reason"
		if _remove_validate_path "/safe/example-worktree" 2>>"$output_file"; then
			rc=1
		fi
	done
	assert_file_contains "$output_file" "Reason: active-cwd.*live process" || rc=1
	assert_file_contains "$output_file" "Reason: current-worktree.*inside the target" || rc=1
	assert_file_contains "$output_file" "Reason: canonical-skip.*canonical checkout" || rc=1
	assert_file_contains "$output_file" "Reason: git-worktree-locked.*explicitly locked" || rc=1
	assert_file_contains "$output_file" "Reason: git-metadata-unreadable.*could not prove" || rc=1
	assert_file_contains "$output_file" "cannot bypass this protection" || rc=1
	assert_line_count "$log_file" 5 || rc=1
	print_result "manual_guard_refusal_diagnostics" "$rc" \
		"Expected safe diagnostics and exactly one audit row per refusal"
	return 0
}

# =============================================================================
# Archive publication uses the same exclusive producer lock as recovery apply.
# =============================================================================
test_recoverable_archive_honours_shared_producer_lock() {
	local repo_path="${TEST_DIR}/producer-lock-repo"
	local wt_path="${TEST_DIR}/producer-lock-worktree"
	local recovery_root="${TEST_DIR}/producer-lock-recovery"
	local lock_path="${recovery_root}/${_WT_RECOVERY_PRODUCER_LOCK_NAME}"
	local process_lstart=""
	local archive_path=""
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/producer-lock" || rc=1
	mkdir -p "$recovery_root" "$lock_path" || rc=1
	process_lstart=$(_worktree_recovery_process_lstart "$$") || rc=1
	printf '%s\n' "$$" >"$lock_path/pid" || rc=1
	printf '%s\n' "$process_lstart" >"$lock_path/lstart" || rc=1
	printf '%s\n' "archive-lock-fixture" >"$lock_path/token" || rc=1
	printf '%s\n' "complete" >"$lock_path/initialized" || rc=1
	if AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$wt_path" "test.sh" "producer-lock"; then
		rc=1
	fi
	[[ -d "$wt_path" && -d "$lock_path" ]] || rc=1
	if compgen -G "${recovery_root}/aidevops-worktree-cleanup-*" >/dev/null; then rc=1; fi
	rm -f "$lock_path/pid" "$lock_path/lstart" "$lock_path/token" "$lock_path/initialized" || rc=1
	rmdir "$lock_path" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$wt_path" "test.sh" "producer-lock" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	[[ -d "$archive_path" &&
		-f "${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}" &&
		! -e "$lock_path" ]] || rc=1
	print_result "recoverable_archive_honours_shared_producer_lock" "$rc" \
		"Expected a live apply-compatible lock to block archive publication through its completion marker"
	return 0
}
