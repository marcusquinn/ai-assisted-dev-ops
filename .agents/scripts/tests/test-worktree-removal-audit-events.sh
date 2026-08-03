#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Focused event-format and idempotency tests for worktree-removal auditing.
# Usage: source from test-worktree-removal-audit-lib.sh after test helpers exist.

[[ -n "${_TEST_WORKTREE_REMOVAL_AUDIT_EVENTS_LOADED:-}" ]] && return 0
_TEST_WORKTREE_REMOVAL_AUDIT_EVENTS_LOADED=1

test_log_writes_one_line() {
	local log_file="${TEST_DIR}/t1-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	log_worktree_removal_event "$_WTAR_REMOVED" "test-caller.sh" "/tmp/test-wt" "manual" "trash"
	local rc=0
	assert_line_count "$log_file" 1 || rc=$?
	print_result "log_writes_one_line" "$rc" "Expected exactly 1 line in log"
	return 0
}

test_log_format_correct() {
	local log_file="${TEST_DIR}/t2-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	log_worktree_removal_event "$_WTAR_SKIPPED" "worktree-helper.sh" "/some/path" "owned-skip" "skipped"
	local pattern='^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] \[worktree-helper\.sh\] worktree-skipped: /some/path — owned-skip — mode=skipped$'
	local rc=0
	assert_file_contains "$log_file" "$pattern" || rc=$?
	print_result "log_format_correct" "$rc" "Log line does not match expected format. Content: $(cat "$log_file" 2>/dev/null)"
	return 0
}

test_custom_log_path() {
	local custom_log="${TEST_DIR}/custom/subdir/audit.log"
	export AIDEVOPS_CLEANUP_LOG="$custom_log"
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	log_worktree_removal_event "$_WTAR_REMOVED" "test.sh" "/wt/path" "age-eligible" "permanent"
	local rc=0
	if [[ -f "$custom_log" ]]; then
		assert_file_contains "$custom_log" "worktree-removed" || rc=$?
	else
		rc=1
		echo "  custom log file not created at $custom_log"
	fi
	print_result "custom_log_path_honoured" "$rc" "Custom AIDEVOPS_CLEANUP_LOG path not written"
	return 0
}

test_all_event_types() {
	local log_file="${TEST_DIR}/t4-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	log_worktree_removal_event "$_WTAR_REMOVED" "s.sh" "/p1" "manual" "trash"
	log_worktree_removal_event "$_WTAR_SKIPPED" "s.sh" "/p2" "grace-period" "skipped"
	log_worktree_removal_event "$_WTAR_FIXTURE_REMOVED" "s.sh" "/p3" "fixture" "fixture"
	local rc=0
	assert_line_count "$log_file" 3 || rc=1
	assert_file_contains "$log_file" "worktree-removed.*p1.*mode=trash" || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*p2.*grace-period.*mode=skipped" || rc=1
	assert_file_contains "$log_file" "worktree-fixture-removed.*p3.*fixture.*mode=fixture" || rc=1
	print_result "all_event_types_logged" "$rc" "Not all event types written correctly"
	return 0
}

test_should_skip_cleanup_owned_skip_logs() {
	local log_file="${TEST_DIR}/t5-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	local wt_path="${TEST_DIR}/fake-wt-$$"
	mkdir -p "$wt_path"
	(
		RED='' NC=''
		is_worktree_owned_by_others() { return 0; }
		check_worktree_owner() {
			echo "99999|session-stub"
			return 0
		}
		worktree_is_in_grace_period() { return 1; }
		get_validated_grace_hours() {
			echo "4"
			return 0
		}
		worktree_has_changes() { return 1; }
		branch_has_zero_commits_ahead() { return 1; }
		export AIDEVOPS_CLEANUP_LOG="$log_file"
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		should_skip_cleanup() {
			local wt_path_sc="$1"
			local wt_branch_sc="$2"
			local default_br_sc="$3"
			local open_pr_list_sc="$4"
			local force_merged_flag_sc="$5"
			if is_worktree_owned_by_others "$wt_path_sc"; then
				local owner_info_sc
				owner_info_sc=$(check_worktree_owner "$wt_path_sc")
				local owner_pid_sc="${owner_info_sc%%|*}"
				echo "  ${wt_branch_sc} (owned by active session PID $owner_pid_sc - skipping)"
				echo "    $wt_path_sc"
				echo ""
				log_worktree_removal_event "$_WTAR_SKIPPED" "worktree-helper.sh" \
					"$wt_path_sc" "owned-skip" "skipped"
				return 0
			fi
			return 1
		}
		should_skip_cleanup "$wt_path" "feature/test" "main" "" "false"
	)
	local rc=0
	assert_file_contains "$log_file" "worktree-skipped.*owned-skip" || rc=$?
	print_result "should_skip_cleanup_owned_skip_logs" "$rc" \
		"Expected worktree-skipped/owned-skip entry. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

test_idempotent_sourcing() {
	local log_file="${TEST_DIR}/t6-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	log_worktree_removal_event "$_WTAR_REMOVED" "test.sh" "/wt" "manual" "trash"
	local rc=0
	assert_line_count "$log_file" 1 || rc=$?
	print_result "idempotent_sourcing" "$rc" "Double-sourcing produced unexpected output"
	return 0
}
