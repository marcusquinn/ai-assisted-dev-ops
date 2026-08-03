#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# PR checkpoint, handoff, and completion-infrastructure tests.

# This file is sourced by test-headless-runtime-helper.sh after the shared test
# harness and headless runtime helper have been initialized.
[[ -n "${_TEST_HEADLESS_RUNTIME_CHECKPOINT_TESTS_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_CHECKPOINT_TESTS_LOADED=1

test_post_pr_handoff_detects_open_pending_pr() {
	local work_dir="${TEST_ROOT}/repo-post-pr-handoff"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head
	expected_head=$(git -C "$work_dir" rev-parse HEAD)

	gh() {
		local args="$*"
		if [[ "$args" == *"pr list"* && "$args" == *"--state all"* && "$args" == *"--head feature/auto-test-issue-99999"* ]]; then
			printf '[{"number":123,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"%s","labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]' "$expected_head"
			return 0
		fi
		if [[ "$args" == *"api --paginate"* && "$args" == *"/issues/123/comments"* ]]; then
			printf '%s' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
			return 0
		fi
		printf '[]'
		return 0
	}

	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		print_result "post-PR watchdog handoff detects open pending PR" 0
	else
		print_result "post-PR watchdog handoff detects open pending PR" 1 \
			"Expected open PR on worker branch to classify as handoff"
	fi

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	return 0
}

test_post_pr_handoff_propagates_classifier_failure() {
	local work_dir="${TEST_ROOT}/repo-post-pr-handoff-classifier-failure"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"

	if (
		DISPATCH_REPO_SLUG="test-owner/test-repo"
		gh() { return 0; }
		_pr_handoff_state_for_branch_or_issue() { printf 'ready|123'; return 1; }
		_worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"
	); then
		print_result "post-PR handoff propagates classifier failure" 1 \
			"Expected classifier failure to override its ready-looking output"
	else
		print_result "post-PR handoff propagates classifier failure" 0
	fi
	return 0
}

test_post_pr_handoff_treats_ci_as_monitoring_state() {
	local work_dir="${TEST_ROOT}/repo-post-pr-handoff-ci-state"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head=""
	expected_head=$(git -C "$work_dir" rev-parse HEAD)
	local rollup_json=""
	local fixture_label=""

	gh() {
		local args="$*"
		if [[ "$args" == *"pr list"* ]]; then
			printf '[{"number":126,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"%s","labels":[{"name":"origin:worker"}],"statusCheckRollup":%s}]' "$expected_head" "$rollup_json"
			return 0
		fi
		if [[ "$args" == *"api --paginate"* && "$args" == *"/issues/126/comments"* ]]; then
			printf '%s' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
			return 0
		fi
		printf '[]'
		return 0
	}

	while IFS=$'\t' read -r fixture_label rollup_json; do
		[[ -n "$fixture_label" ]] || continue
		if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
			print_result "post-PR handoff accepts ${fixture_label} as durable monitoring state" 0
		else
			print_result "post-PR handoff accepts ${fixture_label} as durable monitoring state" 1
		fi
	done <<'EOF'
cancelled plus success	[{"name":"gate","status":"COMPLETED","conclusion":"CANCELLED"},{"name":"gate","status":"COMPLETED","conclusion":"SUCCESS"}]
failure plus success	[{"name":"tests","status":"COMPLETED","conclusion":"FAILURE"},{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS"}]
terminal failure only	[{"name":"tests","status":"COMPLETED","conclusion":"FAILURE"}]
pending only	[{"name":"tests","status":"IN_PROGRESS","conclusion":null}]
EOF

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	return 0
}

test_post_pr_handoff_rejects_mismatched_head_or_missing_summary() {
	local work_dir="${TEST_ROOT}/repo-post-pr-incomplete"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head
	expected_head=$(git -C "$work_dir" rev-parse HEAD)
	local remote_head="different-head"
	local summary_count=1
	local remote_is_draft="false"

	gh() {
		local args="$*"
		if [[ "$args" == *"pr list"* ]]; then
			printf '[{"number":125,"state":"OPEN","isDraft":%s,"mergedAt":null,"headRefOid":"%s","labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]' "$remote_is_draft" "$remote_head"
			return 0
		fi
		if [[ "$args" == *"api --paginate"* ]]; then
			if [[ "$summary_count" -gt 0 ]]; then
				printf '%s' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
			else
				printf '%s' '[[]]'
			fi
			return 0
		fi
		printf '[]'
		return 0
	}

	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		print_result "post-PR watchdog handoff rejects mismatched PR head" 1
	else
		print_result "post-PR watchdog handoff rejects mismatched PR head" 0
	fi
	remote_head="$expected_head"
	summary_count=0
	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		print_result "post-PR watchdog handoff rejects missing MERGE_SUMMARY" 1
	else
		print_result "post-PR watchdog handoff rejects missing MERGE_SUMMARY" 0
	fi
	summary_count=1
	remote_is_draft="true"
	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		print_result "post-PR watchdog handoff rejects draft PR" 1
	else
		print_result "post-PR watchdog handoff rejects draft PR" 0
	fi

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	return 0
}

test_failed_worker_draft_checkpoint_preserves_continuation_without_completion() {
	local result=""
	local escalation_marker="${TEST_ROOT}/draft-checkpoint-escalated"
	rm -f "$escalation_marker"
	result=$(
		(
			DISPATCH_REPO_SLUG="test-owner/test-repo"
			git() {
				if [[ "${*}" == *"rev-parse --abbrev-ref HEAD"* ]]; then
					printf 'feature/auto-test-issue-99999'
				fi
				return 0
			}
			_hrw_resolve_default_branch() { printf 'main'; return 0; }
			_pr_handoff_state_for_branch_or_issue() { printf 'draft_checkpoint|456'; return 0; }
			_release_dispatch_claim() { printf 'release=%s\n' "$2"; return 0; }
			_hrff_resolve_release_runner_login() { printf 'worker-bot'; return 0; }
			set_issue_status() { printf '%s\n' "$*" >"$escalation_marker"; return 0; }
			gh() {
				if [[ "${*}" == *"issue view 99999"* ]]; then
					printf '%s\n' '{"state":"OPEN","labels":[{"name":"status:in-review"},{"name":"needs-maintainer-review"}],"assignees":[{"login":"worker-bot"}]}'
				fi
				return 0
			}
			_recover_worker_output_on_failure "issue-99999" "${TEST_ROOT}"
			printf 'classification=%s\n' "${_HRW_RECOVERY_CLASSIFICATION:-}"
		)
	)
	local transition=""
	transition=$(<"$escalation_marker")
	if [[ "$result" == *"release=worker_draft_checkpoint"* && \
		"$transition" == *"99999 test-owner/test-repo in-review"* && \
		"$transition" != *"needs-maintainer-review"* && \
		"$transition" == *"--add-assignee worker-bot"* && \
		"$result" == *"classification=worker_draft_checkpoint"* ]]; then
		print_result "failed worker draft checkpoint preserves exact-head continuation without worker_complete" 0
	else
		print_result "failed worker draft checkpoint preserves exact-head continuation without worker_complete" 1 "result=${result} transition=${transition}"
	fi
	return 0
}

test_dirty_worktree_checkpoint_is_deferred_not_complete() {
	local result=""
	result=$(
		(
			DISPATCH_REPO_SLUG="test-owner/test-repo"
			WORKER_ISSUE_NUMBER="28313"
			_HRW_TERMINAL_OUTCOME="unset"
			_HRW_FINAL_RUNTIME_EVENT="unset"
			_HRW_FINAL_RUNTIME_STATUS="unset"
			_HRW_FINAL_RUNTIME_CLASSIFICATION="unset"
			_HRW_RECOVERY_CLASSIFICATION=""
			git() {
				if [[ "${*}" == *"rev-parse --abbrev-ref HEAD"* ]]; then
					printf 'feature/auto-test-issue-28313'
				elif [[ "${*}" == *"status --short"* ]]; then
					printf ' M changed-file.txt\n'
				fi
				return 0
			}
			runner_identity_key() { printf 'runner-fixture'; return 0; }
			_push_wip_commits_on_exit() { return 0; }
			_recover_dirty_worker_pr() { return 0; }
			_release_dispatch_claim() { printf 'release=%s\n' "$2"; return 0; }

			_handle_worker_dirty_worktree "manual-cli-28313-1784593858" "$TEST_ROOT"
			printf 'terminal=%s|event=%s|status=%s|classification=%s|recovery=%s\n' \
				"$_HRW_TERMINAL_OUTCOME" "$_HRW_FINAL_RUNTIME_EVENT" \
				"$_HRW_FINAL_RUNTIME_STATUS" "$_HRW_FINAL_RUNTIME_CLASSIFICATION" \
				"$_HRW_RECOVERY_CLASSIFICATION"
		)
	)

	if [[ "$result" == *"release=worker_draft_checkpoint"* && \
		"$result" == *"terminal=deferred|event=worker.deferred|status=checkpointed|classification=worker_draft_checkpoint|recovery=worker_draft_checkpoint"* && \
		"$result" != *"release=worker_complete"* ]]; then
		print_result "dirty-worktree checkpoint is deferred preserved progress, never completion" 0
	else
		print_result "dirty-worktree checkpoint is deferred preserved progress, never completion" 1 "$result"
	fi
	return 0
}

test_exit_trap_dirty_checkpoint_is_deferred_not_complete() {
	local result=""
	result=$(
		(
			_WORKER_DIRTY_WORK_PRESERVED=1
			_push_wip_commits_on_exit() { return 0; }
			_recover_dirty_worker_pr() { return 0; }
			_emit_worker_runtime_event() {
				printf 'event=%s|status=%s|classification=%s\n' "$1" "$2" "$3"
				return 0
			}
			_hrw_record_terminal_outcome() {
				printf 'terminal=%s|reason=%s\n' "$2" "$3"
				return 0
			}
			_cleanup_headless_runtime_temp_paths() { return 0; }
			_release_dispatch_claim() { printf 'release=%s\n' "$2"; return 0; }
			_release_session_lock() { return 0; }
			_update_dispatch_ledger() { return 0; }
			aidevops_runtime_bundle_lease_release() { return 0; }

			_hrff_finalize_exit_trap "manual-cli-28313-1784593858" \
				"process_exit" "1" "0" "0"
		)
	)

	if [[ "$result" == *"event=worker.deferred|status=checkpointed|classification=worker_draft_checkpoint"* && \
		"$result" == *"terminal=deferred|reason=worker_draft_checkpoint"* && \
		"$result" == *"release=worker_draft_checkpoint"* && \
		"$result" != *"worker_complete"* ]]; then
		print_result "exit-trap dirty checkpoint emits deferred preserved progress, never completion" 0
	else
		print_result "exit-trap dirty checkpoint emits deferred preserved progress, never completion" 1 "$result"
	fi
	return 0
}

test_failed_worker_draft_retains_claim_when_block_not_visible() {
	local result=""
	result=$(
		(
			DISPATCH_REPO_SLUG="test-owner/test-repo"
			git() {
				[[ "${*}" == *"rev-parse --abbrev-ref HEAD"* ]] && printf 'feature/auto-test-issue-99999'
				return 0
			}
			_hrw_resolve_default_branch() { printf 'main'; return 0; }
			_pr_handoff_state_for_branch_or_issue() { printf 'draft_checkpoint|456'; return 0; }
			set_issue_status() { return 0; }
			gh() { printf '%s\n' '{"labels":[]}'; return 0; }
			_release_dispatch_claim() { printf 'unexpected-release=%s\n' "$2"; return 0; }
			_recover_worker_output_on_failure "issue-99999" "${TEST_ROOT}"
			printf 'classification=%s\n' "${_HRW_RECOVERY_CLASSIFICATION:-}"
		)
	)
	if [[ "$result" == *"classification=worker_draft_checkpoint_escalation_failed"* && "$result" != *"unexpected-release="* ]]; then
		print_result "draft checkpoint retains claim when continuation read-back fails" 0
	else
		print_result "draft checkpoint retains claim when continuation read-back fails" 1 "$result"
	fi
	return 0
}

test_protected_draft_is_not_mutated_or_completed() {
	local result=""
	result=$(
		(
			DISPATCH_REPO_SLUG="test-owner/test-repo"
			git() {
				[[ "${*}" == *"rev-parse --abbrev-ref HEAD"* ]] && printf 'feature/auto-test-issue-99999'
				return 0
			}
			_hrw_resolve_default_branch() { printf 'main'; return 0; }
			_pr_handoff_state_for_branch_or_issue() { printf 'protected_draft|458'; return 0; }
			set_issue_status() { printf 'unexpected-mutation\n'; return 0; }
			_release_dispatch_claim() { printf 'unexpected-release=%s\n' "$2"; return 0; }
			_recover_worker_output_on_failure "issue-99999" "${TEST_ROOT}"
			printf 'classification=%s\n' "${_HRW_RECOVERY_CLASSIFICATION:-}"
		)
	)
	if [[ "$result" == *"classification=worker_protected_draft"* && "$result" != *"unexpected-mutation"* && "$result" != *"unexpected-release="* ]]; then
		print_result "protected draft is neither mutated nor reported complete" 0
	else
		print_result "protected draft is neither mutated nor reported complete" 1 "$result"
	fi
	return 0
}

test_checkpoint_terminal_telemetry_is_deferred() {
	local fixture_class="draft_checkpoint"
	local expected_reason="worker_draft_checkpoint"
	local result
	result=$(
		(
			_worker_produced_output() { printf '%s' "$fixture_class"; return 0; }
			_escalate_worker_pr_checkpoint() { _HRW_RECOVERY_CLASSIFICATION="$expected_reason"; return 0; }
			_hrw_finish_success_run "issue-99999" "${TEST_ROOT}"
			printf '%s|%s|%s|%s' "$_HRW_TERMINAL_OUTCOME" "$_HRW_FINAL_RUNTIME_EVENT" \
				"$_HRW_FINAL_RUNTIME_STATUS" "$_HRW_FINAL_RUNTIME_CLASSIFICATION"
		)
	)
	if [[ "$result" == "deferred|worker.deferred|checkpointed|${expected_reason}" ]]; then
		print_result "${fixture_class} records deferred checkpoint telemetry" 0
	else
		print_result "${fixture_class} records deferred checkpoint telemetry" 1 "$result"
	fi
	return 0
}

test_failed_ci_ready_pr_is_durable_handoff() {
	local pr_json result
	pr_json='[{"number":457,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"abc123","labels":[{"name":"origin:worker"}],"statusCheckRollup":[{"name":"tests","conclusion":"FAILURE"},{"name":"tests","conclusion":"SUCCESS"}]}]'
	result=$(_pr_handoff_state_from_json "$pr_json" "abc123")
	if [[ "$result" == "ready|457" ]]; then
		print_result "failed or historical CI does not invalidate a ready PR handoff" 0
	else
		print_result "failed or historical CI does not invalidate a ready PR handoff" 1 "$result"
	fi
	return 0
}

test_closed_unmerged_pr_is_failed_not_completed() {
	local result=""
	result=$(
		(
			_worker_produced_output() { printf 'closed_unmerged'; return 0; }
			_release_dispatch_claim() { printf 'release=%s\n' "$2"; return 0; }
			_report_failure_to_fast_fail() { return 0; }
			_hrw_finish_success_run "issue-99999" "${TEST_ROOT}"
			printf 'terminal=%s|%s|%s|%s\n' "$_HRW_TERMINAL_OUTCOME" "$_HRW_FINAL_RUNTIME_EVENT" \
				"$_HRW_FINAL_RUNTIME_STATUS" "$_HRW_FINAL_RUNTIME_CLASSIFICATION"
		)
	)
	if [[ "$result" == *"release=worker_closed_unmerged_pr"* && \
		"$result" == *"terminal=failed|worker.failed|failed|worker_closed_unmerged_pr"* && \
		"$result" != *"release=worker_complete"* ]]; then
		print_result "closed-unmerged PR records failure and never worker_complete" 0
	else
		print_result "closed-unmerged PR records failure and never worker_complete" 1 "$result"
	fi
	return 0
}

test_failed_worker_ready_pr_remains_completed_handoff() {
	local result=""
	result=$(
		(
			DISPATCH_REPO_SLUG="test-owner/test-repo"
			git() {
				[[ "${*}" == *"rev-parse --abbrev-ref HEAD"* ]] && printf 'feature/auto-test-issue-99999'
				return 0
			}
			_hrw_resolve_default_branch() { printf 'main'; return 0; }
			_pr_handoff_state_for_branch_or_issue() { printf 'ready|457'; return 0; }
			_release_dispatch_claim() { printf 'release=%s\n' "$2"; return 0; }
			_recover_worker_output_on_failure "issue-99999" "${TEST_ROOT}"
		)
	)
	if [[ "$result" == *"release=worker_complete"* && "$result" != *"worker_draft_checkpoint"* ]]; then
		print_result "failed worker ready PR remains a completed handoff" 0
	else
		print_result "failed worker ready PR remains a completed handoff" 1 "$result"
	fi
	return 0
}

test_post_pr_handoff_rejects_pre_pr_stall() {
	local work_dir="${TEST_ROOT}/repo-pre-pr-stall"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	gh() {
		printf '[]'
		return 0
	}

	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		print_result "post-PR watchdog handoff rejects pre-PR stall" 1 \
			"Expected no open PR to remain redispatchable"
	else
		print_result "post-PR watchdog handoff rejects pre-PR stall" 0
	fi

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	return 0
}

test_post_pr_handoff_overrides_watchdog_next_action() {
	local work_dir="${TEST_ROOT}/repo-watchdog-next-action"
	mkdir -p "$work_dir"
	init_git_worktree "$work_dir"
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head
	expected_head=$(git -C "$work_dir" rev-parse HEAD)

	gh() {
		local args="$*"
		if [[ "$args" == *"pr list"* && "$args" == *"--state all"* ]]; then
			printf '[{"number":124,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"%s","labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]' "$expected_head"
			return 0
		fi
		if [[ "$args" == *"api --paginate"* && "$args" == *"/issues/124/comments"* ]]; then
			printf '%s' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
			return 0
		fi
		printf '[]'
		return 0
	}

	local evidence_fields="" launch_failure_cause="" next_action=""
	evidence_fields=$(_derive_worker_failure_evidence "watchdog_stall_killed" "79" "1" "hard_kill_stall" "watchdog_stall_killed")
	launch_failure_cause="${evidence_fields%%$'\t'*}"
	next_action="${evidence_fields#*$'\t'}"
	if _worker_post_pr_handoff_confirmed "issue-99999" "$work_dir"; then
		launch_failure_cause="post_pr_pending_ci_handoff"
		next_action="monitor_open_pr"
	fi

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$launch_failure_cause" == "post_pr_pending_ci_handoff" && "$next_action" == "monitor_open_pr" ]]; then
		print_result "post-PR watchdog handoff suppresses redispatch next_action" 0
	else
		print_result "post-PR watchdog handoff suppresses redispatch next_action" 1 \
			"Expected monitor_open_pr, got cause='${launch_failure_cause}' next='${next_action}'"
	fi
	return 0
}

test_completion_infrastructure_resumes_without_implementation_penalty() {
	local reason="" evidence_fields="" launch_failure_cause="" next_action=""
	for reason in github_api_timeout command_policy_timeout prepared_commit_push_blocked completed_locally_remote_completion_blocked; do
		if ! _worker_failure_reason_is_completion_infrastructure "$reason"; then
			print_result "completion infrastructure class ${reason}" 1 "Reason was not classified"
			continue
		fi
		evidence_fields=$(_derive_worker_failure_evidence "blocked" "1" "1" "natural" "$reason")
		launch_failure_cause="${evidence_fields%%$'\t'*}"
		next_action="${evidence_fields#*$'\t'}"
		if [[ "$launch_failure_cause" == "$reason" && "$next_action" == "resume_session_with_completion_contract" ]]; then
			print_result "completion infrastructure class ${reason}" 0
		else
			print_result "completion infrastructure class ${reason}" 1 \
				"cause='${launch_failure_cause}' next='${next_action}'"
		fi
	done
	return 0
}

test_pr_checkpoint_lifecycle_cases() {
	test_post_pr_handoff_detects_open_pending_pr
	test_post_pr_handoff_propagates_classifier_failure
	test_post_pr_handoff_treats_ci_as_monitoring_state
	test_post_pr_handoff_rejects_mismatched_head_or_missing_summary
	test_failed_worker_draft_checkpoint_preserves_continuation_without_completion
	test_dirty_worktree_checkpoint_is_deferred_not_complete
	test_exit_trap_dirty_checkpoint_is_deferred_not_complete
	test_failed_worker_draft_retains_claim_when_block_not_visible
	test_protected_draft_is_not_mutated_or_completed
	test_checkpoint_terminal_telemetry_is_deferred
	test_failed_ci_ready_pr_is_durable_handoff
	test_closed_unmerged_pr_is_failed_not_completed
	test_failed_worker_ready_pr_remains_completed_handoff
	return 0
}
