#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Worker output, finalization, and orphan-recovery tests.

# This file is sourced by test-headless-runtime-helper.sh after the shared test
# harness and headless runtime helper have been initialized.
[[ -n "${_TEST_HEADLESS_RUNTIME_COMPLETION_TESTS_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_COMPLETION_TESTS_LOADED=1

_setup_test_git_repo() {
	local work_dir="$1"
	local add_commit="${2:-0}"
	mkdir -p "$work_dir"
	git -C "$work_dir" init -q
	git -C "$work_dir" config user.email "test@test.local"
	git -C "$work_dir" config user.name "Test"
	# Create initial commit on main so origin/main reference exists
	touch "$work_dir/README.md"
	git -C "$work_dir" add README.md
	git -C "$work_dir" commit -q -m "init"
	git -C "$work_dir" branch -M main
	# Create remote stub unique to this repo (bare repo alongside work_dir)
	local remote_dir="${work_dir}.remote.git"
	git init -q --bare "$remote_dir"
	git -C "$work_dir" remote add origin "$remote_dir"
	git -C "$work_dir" push -q origin main
	# Switch to feature branch
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	if [[ "$add_commit" -eq 1 ]]; then
		echo "change" >"$work_dir/change.txt"
		git -C "$work_dir" add change.txt
		git -C "$work_dir" commit -q -m "feat: add change"
	fi
	return 0
}

test_worker_produced_output_no_commits_returns_noop() {
	local work_dir="${TEST_ROOT}/repo-no-commits"
	_setup_test_git_repo "$work_dir" 0
	# No gh available in test env, no DISPATCH_REPO_SLUG set — signal 3 skipped
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "noop" ]]; then
		print_result "_worker_produced_output returns 'noop' with zero commits" 0
	else
		print_result "_worker_produced_output returns 'noop' with zero commits" 1 \
			"Expected 'noop' but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_with_commits_returns_pr_exists_failopen() {
	# Commits present but no DISPATCH_REPO_SLUG → cannot confirm PR absence → fail-open (pr_exists)
	local work_dir="${TEST_ROOT}/repo-with-commits"
	_setup_test_git_repo "$work_dir" 1
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' with commits (fail-open no slug)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' with commits (fail-open no slug)" 1 \
			"Expected 'pr_exists' (fail-open) but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_non_worker_session_returns_pr_exists() {
	local work_dir="${TEST_ROOT}/repo-pulse"
	_setup_test_git_repo "$work_dir" 0

	# Non-worker session keys (pulse, triage) must always return pr_exists (fail-open)
	local classification
	classification=$(_worker_produced_output "pulse-main" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for non-worker session" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for non-worker session" 1 \
			"Non-worker session should always return 'pr_exists' (fail-open), got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_invalid_workdir_returns_pr_exists() {
	# Missing / non-git work_dir must fail-open
	local classification
	classification=$(_worker_produced_output "issue-99999" "/nonexistent/path/$$")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for invalid work_dir (fail-open)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for invalid work_dir (fail-open)" 1 \
			"Invalid work_dir should fail-open as 'pr_exists', got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_zero_diff_pushed_branch_returns_noop() {
	# A successful zero-count comparison proves no PR can exist for this head,
	# even when the feature ref was pushed and repo slug context is unavailable.
	local work_dir="${TEST_ROOT}/repo-pushed-noslug"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "noop" ]]; then
		print_result "_worker_produced_output returns 'noop' for a zero-diff pushed branch" 0
	else
		print_result "_worker_produced_output returns 'noop' for a zero-diff pushed branch" 1 \
			"Expected 'noop' after a successful zero-count base comparison, got '${classification}'"
	fi
	return 0
}

# AC#2: pushed branch + confirmed no PR → branch_orphan
test_worker_produced_output_branch_no_pr_returns_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-orphan"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	# Set DISPATCH_REPO_SLUG and stub gh to return 0 PRs
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() { printf '0'; return 0; }

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "branch_orphan" ]]; then
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 0
	else
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 1 \
			"Expected 'branch_orphan' but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_local_branch_no_remote_returns_local_branch_unpushed() {
	local work_dir="${TEST_ROOT}/repo-local-unpushed"
	_setup_test_git_repo "$work_dir" 1
	# Do not push the feature branch: local commits exist, remote branch absent.
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() { printf '0'; return 0; }

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "local_branch_unpushed" ]]; then
		print_result "_worker_produced_output returns 'local_branch_unpushed' for local-only committed branch" 0
	else
		print_result "_worker_produced_output returns 'local_branch_unpushed' for local-only committed branch" 1 \
			"Expected 'local_branch_unpushed' but got '${classification}'"
	fi
	return 0
}

# AC#2 variant: PR confirmed → pr_exists even when branch is pushed
test_worker_produced_output_branch_with_pr_returns_pr_exists() {
	local work_dir="${TEST_ROOT}/repo-pr-exists"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	local expected_head
	expected_head=$(git -C "$work_dir" rev-parse HEAD)
	gh() {
		if [[ "${*}" == *"api --paginate"* && "${*}" == *"/issues/123/comments"* ]]; then
			printf '%s\n' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
		elif [[ "${*}" == *"--head"* && "${*}" == *"statusCheckRollup"* ]]; then
			printf '[{"number":123,"state":"OPEN","isDraft":false,"mergedAt":null,"headRefOid":"%s","labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]\n' "$expected_head"
		else
			printf '%s\n' '[]'
		fi
		return 0
	}

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 1 \
			"Expected 'pr_exists' but got '${classification}'"
	fi
	return 0
}

test_release_dispatch_claim_ignores_non_issue_session_key_digits() {
	local result status gh_called active_called unlock_called output
	result=$(
		unset WORKER_ISSUE_NUMBER 2>/dev/null || true
		DISPATCH_REPO_SLUG="owner/repo"
		WORKER_GITHUB_LOGIN="test-runner"
		gh_called=0
		active_called=0
		unlock_called=0
		gh() { gh_called=$((gh_called + 1)); return 0; }
		clear_active_status_on_release() { active_called=1; return 0; }
		_unlock_issue_after_dispatch_release() { unlock_called=1; return 0; }

		local release_output="" release_status=0
		release_output=$(_release_dispatch_claim "validation-gh3343-positive-review-20260705" "worker_complete" 0 1 2>&1) || release_status=$?
		printf '%s|%s|%s|%s|%s' "$release_status" "$gh_called" "$active_called" "$unlock_called" "$release_output"
	)
	IFS='|' read -r status gh_called active_called unlock_called output <<<"$result"

	if [[ "$status" -eq 0 && "$gh_called" -eq 0 && "$active_called" -eq 0 && "$unlock_called" -eq 0 && -z "$output" ]]; then
		print_result "release claim ignores non-issue session keys ending in digits" 0
		return 0
	fi

	print_result "release claim ignores non-issue session keys ending in digits" 1 \
		"status=$status gh=$gh_called active=$active_called unlock=$unlock_called output=${output:-<empty>}"
	return 0
}

test_session_terminal_reconciliation_preserves_null_issue_scope() {
	local result=""
	local args_file="${TEST_ROOT}/session-terminal-reconcile-args"
	(
		local fake_script_dir="${TEST_ROOT}/session-terminal-reconcile"
		mkdir -p "$fake_script_dir"
		: >"${fake_script_dir}/worker-blocker-log.mjs"
		SCRIPT_DIR="$fake_script_dir"
		DISPATCH_REPO_SLUG="owner/repo"
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG 2>/dev/null || true
		node() {
			local args=("$@")
			local arg=""
			for arg in "${args[@]}"; do printf '<%s>' "$arg"; done >"$args_file"
			return 0
		}
		_hrw_reconcile_session_permission_blockers "routine-r004" "success"
	)
	result=$(<"$args_file")
	if [[ "$result" == *"<resolve-session>"* && "$result" == *"<--repo-slug><owner/repo>"* && \
		"$result" == *"<--issue-number><>"* && "$result" == *"<--session-key><routine-r004>"* && \
		"$result" == *"<--reason><success>"* ]]; then
		print_result "session terminal reconciliation preserves null issue scope" 0
		return 0
	fi
	print_result "session terminal reconciliation preserves null issue scope" 1 "args=${result:-<empty>}"
	return 0
}

test_rate_limit_fast_reconciles_session_blockers() {
	local helper_file="$HELPER_SCRIPT"
	local callback_count=""
	local callback_pattern=''
	# shellcheck disable=SC2016 # Match the literal runtime variable reference.
	callback_pattern='_hrw_reconcile_session_permission_blockers "$session_key"'
	callback_count=$(grep -cF "$callback_pattern" "$helper_file")
	if [[ "$callback_count" == "2" ]]; then
		print_result "rate-limit fast exit reconciles session blockers" 0
		return 0
	fi
	print_result "rate-limit fast exit reconciles session blockers" 1 "callback_count=${callback_count:-0}"
	return 0
}

test_cmd_run_finish_emits_noop_for_zero_output() {
	local work_dir="${TEST_ROOT}/repo-finish-noop"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	# Stub lifecycle functions to capture what was called
	local released_reason="" fast_fail_reason="" fast_fail_crash="" recorded_outcome=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_reason="$2"; fast_fail_crash="$3"; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	if [[ "$released_reason" == "worker_noop" ]]; then
		print_result "_cmd_run_finish emits worker_noop for zero-output exit" 0
	else
		print_result "_cmd_run_finish emits worker_noop for zero-output exit" 1 \
			"Expected released_reason=worker_noop, got '${released_reason}'"
	fi

	if [[ "$fast_fail_reason" == "worker_noop_zero_output" && "$fast_fail_crash" == "no_work" ]]; then
		print_result "_cmd_run_finish increments fast-fail on noop" 0
	else
		print_result "_cmd_run_finish increments fast-fail on noop" 1 \
			"Expected fast_fail reason=worker_noop_zero_output/crash=no_work, got '${fast_fail_reason}'/'${fast_fail_crash}'"
	fi
	if [[ "$recorded_outcome" == "failed" ]]; then
		print_result "_cmd_run_finish records failed telemetry for zero-output exit" 0
	else
		print_result "_cmd_run_finish records failed telemetry for zero-output exit" 1 \
			"Expected failed telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_emits_complete_for_real_output() {
	local work_dir="${TEST_ROOT}/repo-finish-complete"
	_setup_test_git_repo "$work_dir" 1
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local released_reason="" fast_fail_called=0 recorded_outcome=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete for real output" 0
	else
		print_result "_cmd_run_finish emits worker_complete for real output" 1 \
			"Expected released_reason=worker_complete, got '${released_reason}'"
	fi

	if [[ "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish does NOT increment fast-fail for real output" 0
	else
		print_result "_cmd_run_finish does NOT increment fast-fail for real output" 1 \
			"fast-fail should not be called when worker produced real output"
	fi
	if [[ "$recorded_outcome" == "success" ]]; then
		print_result "_cmd_run_finish records success telemetry for real output" 0
	else
		print_result "_cmd_run_finish records success telemetry for real output" 1 \
			"Expected success telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_appends_reconciled_attempt_outcome() {
	local work_dir="${TEST_ROOT}/repo-finish-reconciled"
	local capture_file="${TEST_ROOT}/reconciled-outcome.capture"
	_setup_test_git_repo "$work_dir" 1

	(
		_run_result_label="premature_exit"
		_run_failure_reason="model_stopped_before_completion"
		_release_dispatch_claim() { return 0; }
		_report_failure_to_fast_fail() { return 0; }
		_update_dispatch_ledger() { return 0; }
		_release_session_lock() { return 0; }
		_hrw_record_terminal_outcome() { return 0; }
		_emit_worker_runtime_event() { return 0; }
		_hrw_record_reconciled_outcome() {
			local session_key="$1"
			local raw_result="$2"
			local outcome="$3"
			local status="$4"
			local classification="$5"
			printf '%s|%s|%s|%s|%s\n' "$session_key" "$raw_result" "$outcome" "$status" "$classification" >"$capture_file"
			return 0
		}
		_cmd_run_finish "issue-99999" "complete" "$work_dir"
	)

	local captured=""
	[[ -s "$capture_file" ]] && captured=$(<"$capture_file")
	if [[ "$captured" == "issue-99999|premature_exit|success|premature_exit|model_stopped_before_completion" ]]; then
		print_result "_cmd_run_finish appends the reconciled attempt outcome after final classification" 0
	else
		print_result "_cmd_run_finish appends the reconciled attempt outcome after final classification" 1 \
			"captured=${captured:-<empty>}"
	fi
	return 0
}

test_cmd_run_finish_rejects_unverified_post_pr_handoff() {
	local work_dir="${TEST_ROOT}/repo-finish-unverified-handoff"
	local capture_file="${TEST_ROOT}/unverified-handoff.capture"
	local release_file="${TEST_ROOT}/unverified-handoff.release"
	local ledger_file="${TEST_ROOT}/unverified-handoff.ledger"
	local result_file="${TEST_ROOT}/unverified-handoff.result"
	_setup_test_git_repo "$work_dir" 1

	(
		_run_result_label="post_pr_handoff"
		_run_failure_reason=""
		_release_dispatch_claim() { printf '%s' "$2" >"$release_file"; return 0; }
		_report_failure_to_fast_fail() { return 0; }
		_update_dispatch_ledger() { printf '%s' "$2" >"$ledger_file"; return 0; }
		_release_session_lock() { return 0; }
		_hrw_record_terminal_outcome() { return 0; }
		_emit_worker_runtime_event() { return 0; }
		_worker_post_pr_handoff_confirmed() { return 1; }
		_hrw_record_reconciled_outcome() {
			local session_key="$1"
			local raw_result="$2"
			local outcome="$3"
			local status="$4"
			local classification="$5"
			printf '%s|%s|%s|%s|%s\n' "$session_key" "$raw_result" "$outcome" "$status" "$classification" >"$capture_file"
			return 0
		}
		set +e
		_cmd_run_finish "issue-99999" "complete" "$work_dir"
		printf '%s' "$?" >"$result_file"
		set -e
	)

	local captured="" release_reason="" ledger_status="" finish_result=""
	[[ -s "$capture_file" ]] && captured=$(<"$capture_file")
	[[ -s "$release_file" ]] && release_reason=$(<"$release_file")
	[[ -s "$ledger_file" ]] && ledger_status=$(<"$ledger_file")
	[[ -s "$result_file" ]] && finish_result=$(<"$result_file")
	if [[ "$captured" == "issue-99999|post_pr_handoff|failed|failed|worker_post_pr_handoff_unverified" ]] &&
		[[ "$release_reason" == "worker_post_pr_handoff_unverified" && "$ledger_status" == "fail" && "$finish_result" == "1" ]]; then
		print_result "unverified POST_PR_HANDOFF cannot suppress failure routing" 0
	else
		print_result "unverified POST_PR_HANDOFF cannot suppress failure routing" 1 \
			"captured=${captured:-<empty>} release=${release_reason:-<empty>} ledger=${ledger_status:-<empty>} result=${finish_result:-<empty>}"
	fi
	return 0
}

test_cmd_run_finish_accepts_verified_post_pr_handoff() {
	local work_dir="${TEST_ROOT}/repo-finish-verified-handoff"
	local capture_file="${TEST_ROOT}/verified-handoff.capture"
	local release_file="${TEST_ROOT}/verified-handoff.release"
	local ledger_file="${TEST_ROOT}/verified-handoff.ledger"
	local result_file="${TEST_ROOT}/verified-handoff.result"
	local fast_fail_file="${TEST_ROOT}/verified-handoff.fast-fail"
	_setup_test_git_repo "$work_dir" 1

	(
		_run_result_label="post_pr_handoff"
		_run_failure_reason=""
		_release_dispatch_claim() { printf '%s' "$2" >"$release_file"; return 0; }
		_report_failure_to_fast_fail() { : >"$fast_fail_file"; return 0; }
		_update_dispatch_ledger() { printf '%s' "$2" >"$ledger_file"; return 0; }
		_release_session_lock() { return 0; }
		_hrw_record_terminal_outcome() { return 0; }
		_emit_worker_runtime_event() { return 0; }
		_worker_post_pr_handoff_confirmed() { return 0; }
		_worker_produced_output() { printf 'pr_exists'; return 0; }
		_hrw_record_reconciled_outcome() {
			local session_key="$1"
			local raw_result="$2"
			local outcome="$3"
			local status="$4"
			local classification="$5"
			printf '%s|%s|%s|%s|%s\n' "$session_key" "$raw_result" "$outcome" "$status" "$classification" >"$capture_file"
			return 0
		}
		set +e
		_cmd_run_finish "issue-99999" "complete" "$work_dir"
		printf '%s' "$?" >"$result_file"
		set -e
	)

	local captured="" release_reason="" ledger_status="" finish_result=""
	[[ -s "$capture_file" ]] && captured=$(<"$capture_file")
	[[ -s "$release_file" ]] && release_reason=$(<"$release_file")
	[[ -s "$ledger_file" ]] && ledger_status=$(<"$ledger_file")
	[[ -s "$result_file" ]] && finish_result=$(<"$result_file")
	if [[ "$captured" == "issue-99999|post_pr_handoff|success|post_pr_handoff|" ]] &&
		[[ "$release_reason" == "worker_complete" && "$ledger_status" == "complete" && "$finish_result" == "0" ]] &&
		[[ ! -e "$fast_fail_file" ]]; then
		print_result "verified POST_PR_HANDOFF records success without failure escalation" 0
	else
		print_result "verified POST_PR_HANDOFF records success without failure escalation" 1 \
			"captured=${captured:-<empty>} release=${release_reason:-<empty>} ledger=${ledger_status:-<empty>} result=${finish_result:-<empty>}"
	fi
	return 0
}

test_permission_finish_failure_recovers_draft_and_runs_cleanup() {
	local result=""
	result=$(
		(
			_run_result_label="permission_required"
			_run_failure_reason=""
			local recovery_called=0 cleanup_called=0
			_hrw_finish_permission_required_run() {
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
				return 1
			}
			_worker_external_terminal_complete() { return 1; }
			_recover_worker_output_on_failure() {
				recovery_called=1
				_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_DRAFT_CHECKPOINT"
				return 0
			}
			_report_failure_to_fast_fail() { return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() {
				local session_key="$1"
				local ledger_status="$2"
				cleanup_called=1
				printf "cleanup_ledger=%s\n" "$ledger_status"
				return 0
			}

			local status=0
			_cmd_run_finish "issue-99999" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf "status=%s|recovery=%s|cleanup=%s|terminal=%s|classification=%s|failure=%s\n" \
				"$status" "$recovery_called" "$cleanup_called" "$_HRW_FINAL_RUNTIME_STATUS" \
				"$_HRW_FINAL_RUNTIME_CLASSIFICATION" "$_run_failure_reason"
		)
	)
	if [[ "$result" == *"cleanup_ledger=fail"* && \
		"$result" == *"status=1|recovery=1|cleanup=1|terminal=escalated|classification=worker_draft_checkpoint|failure=permission_request_persistence_failed"* ]]; then
		print_result "permission persistence failure recovers draft and runs common cleanup" 0
	else
		print_result "permission persistence failure recovers draft and runs common cleanup" 1 "$result"
	fi
	return 0
}

test_permission_finish_failure_without_output_releases_and_cleans_up() {
	local result=""
	result=$(
		(
			_run_result_label="permission_required"
			_run_failure_reason=""
			local recovery_called=0 cleanup_called=0 released_reason="" fast_fail_reason=""
			_hrw_finish_permission_required_run() {
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
				return 1
			}
			_worker_external_terminal_complete() { return 1; }
			_recover_worker_output_on_failure() { recovery_called=1; return 1; }
			_release_dispatch_claim() {
				local session_key="$1"
				local reason="$2"
				released_reason="$reason"
				return 0
			}
			_report_failure_to_fast_fail() {
				local session_key="$1"
				local reason="$2"
				fast_fail_reason="$reason"
				return 0
			}
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() { cleanup_called=1; return 0; }

			local status=0
			_cmd_run_finish "issue-99999" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf "status=%s|recovery=%s|cleanup=%s|released=%s|fast_fail=%s|classification=%s\n" \
				"$status" "$recovery_called" "$cleanup_called" "$released_reason" "$fast_fail_reason" \
				"$_HRW_FINAL_RUNTIME_CLASSIFICATION"
		)
	)
	if [[ "$result" == "status=1|recovery=1|cleanup=1|released=worker_failed|fast_fail=permission_request_persistence_failed|classification=permission_request_persistence_failed" ]]; then
		print_result "permission persistence failure without output releases and cleans up" 0
	else
		print_result "permission persistence failure without output releases and cleans up" 1 "$result"
	fi
	return 0
}

test_null_issue_permission_failure_reconciles_terminal_blockers() {
	local result=""
	result=$(
		(
			unset WORKER_ISSUE_NUMBER 2>/dev/null || true
			_run_result_label="permission_required"
			_run_failure_reason=""
			local reconciled=0 reconcile_reason=""
			_hrw_finish_permission_required_run() {
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
				return 1
			}
			_hrw_reconcile_session_permission_blockers() {
				local session_key="$1"
				local terminal_reason="$2"
				reconciled=$((reconciled + 1))
				reconcile_reason="${session_key}|${terminal_reason}"
				return 0
			}
			_worker_external_terminal_complete() { return 1; }
			_recover_worker_output_on_failure() { return 1; }
			_release_dispatch_claim() { return 0; }
			_report_failure_to_fast_fail() { return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() { return 0; }

			local status=0
			_cmd_run_finish "routine-r004" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf 'status=%s|reconciled=%s|reason=%s\n' "$status" "$reconciled" "$reconcile_reason"
		)
	)
	if [[ "$result" == "status=1|reconciled=1|reason=routine-r004|permission_request_persistence_failed" ]]; then
		print_result "null-issue permission failure reconciles terminal blockers" 0
	else
		print_result "null-issue permission failure reconciles terminal blockers" 1 "$result"
	fi
	return 0
}

test_issue_permission_handoff_skips_post_persistence_reconciliation() {
	local result=""
	result=$(
		(
			WORKER_ISSUE_NUMBER="99999"
			export WORKER_ISSUE_NUMBER
			_run_result_label="permission_required"
			local reconciled=0
			_hrw_finish_permission_required_run() { return 0; }
			_hrw_reconcile_session_permission_blockers() { reconciled=$((reconciled + 1)); return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() { return 0; }

			local status=0
			_cmd_run_finish "issue-99999" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf 'status=%s|reconciled=%s\n' "$status" "$reconciled"
		)
	)
	if [[ "$result" == "status=0|reconciled=0" ]]; then
		print_result "issue permission handoff stays active after persistence" 0
	else
		print_result "issue permission handoff stays active after persistence" 1 "$result"
	fi
	return 0
}

test_post_merge_permission_uses_cleanup_receipt_without_blocking_issue() {
	local work_dir="${TEST_ROOT}/repo-post-merge-permission"
	local cleanup_dir="${TEST_ROOT}/post-merge-cleanup-receipts"
	local output_file="${TEST_ROOT}/post-merge-permission.output"
	local permission_file="${TEST_ROOT}/post-merge-permission.request"
	local handle_output_file="${TEST_ROOT}/post-merge-permission.handle-output"
	_setup_test_git_repo "$work_dir" 1
	local expected_head=""
	local resolved_work_dir=""
	expected_head=$(git -C "$work_dir" rev-parse HEAD)
	resolved_work_dir=$(cd "$work_dir" && pwd -P)
	printf '%s\n' '{"type":"text","sessionID":"ses_post_merge","text":"post-merge synchronization"}' >"$output_file"
	printf '%s\n' '{"type":"external_directory","request_id":"perm-post-merge"}' >"$permission_file"

	local result=""
	result=$(
		(
			export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_dir"
			export DISPATCH_REPO_SLUG="owner/repo"
			export WORKER_ISSUE_NUMBER="99999"
			_run_permission_request_file="$permission_file"
			full_loop_write_cleanup_deferred "owner/repo" 123 "$resolved_work_dir" \
				"feature/auto-test-issue-99999" "$$" "ses_post_merge" "pending" "FINALIZATION_PENDING" >/dev/null
			gh_pr_list() {
				printf '[{"number":123,"state":"MERGED","isDraft":false,"mergedAt":"2026-07-30T20:00:00Z","headRefOid":"%s","labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]\n' "$expected_head"
				return 0
			}
			gh() {
				if [[ "${*}" == *"issue view 99999"* ]]; then
					printf 'CLOSED\n'
				elif [[ "${*}" == *"api --paginate"* && "${*}" == *"/issues/123/comments"* ]]; then
					printf '%s\n' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
				elif [[ "${*}" == *"pr view 123"* ]]; then
					printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-30T20:00:00Z","mergeCommit":{"oid":"merge-123"}}'
				else
					return 1
				fi
				return 0
			}
			_store_headless_session_if_allowed() { return 0; }
			local permission_finish_called=0
			local success_finish_called=0
			local reconciled=0
			_hrw_finish_permission_required_run() { permission_finish_called=1; return 0; }
			_hrw_finish_success_run() {
				success_finish_called=1
				_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
				return 0
			}
			_hrw_reconcile_session_permission_blockers() { reconciled=$((reconciled + 1)); return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() { return 0; }

			local handle_status=0
			local handle_output=""
			_handle_run_result 1 "$output_file" "worker" "openai" \
				"issue-99999" "openai/test" "$work_dir" >"$handle_output_file" 2>&1 || handle_status=$?
			handle_output=$(<"$handle_output_file")
			if [[ "$handle_status" -ne 84 ]]; then
				_hrw_reconcile_session_permission_blockers "issue-99999" "$_run_result_label"
				rm -f "$permission_file"
			fi
			_cmd_run_finish "issue-99999" "complete" "$work_dir"
			local receipt_state=""
			receipt_state=$(jq -r '.resource_cleanup_state' "${cleanup_dir}/owner_repo-123.json")
			printf 'handle=%s|result=%s|permission=%s|success=%s|reconciled=%s|request=%s|receipt=%s|diagnostic=%s\n' \
				"$handle_status" "$_run_result_label" "$permission_finish_called" "$success_finish_called" \
				"$reconciled" "$([[ -e "$permission_file" ]] && printf present || printf cleared)" \
				"$receipt_state" "$([[ "$handle_output" == *"cleanup_authority=guarded-supervisor"* ]] && printf present || printf missing)"
		)
	)
	if [[ "$result" == "handle=0|result=post_merge_cleanup_deferred|permission=0|success=1|reconciled=1|request=cleared|receipt=CLEANUP_DEFERRED|diagnostic=present" ]]; then
		print_result "post-merge permission retains cleanup ownership without blocking implementation" 0
	else
		print_result "post-merge permission retains cleanup ownership without blocking implementation" 1 "$result"
	fi
	return 0
}

test_pre_merge_permission_remains_blocking() {
	local work_dir="${TEST_ROOT}/repo-pre-merge-permission"
	local output_file="${TEST_ROOT}/pre-merge-permission.output"
	local permission_file="${TEST_ROOT}/pre-merge-permission.request"
	_setup_test_git_repo "$work_dir" 1
	printf '%s\n' '{"type":"text","sessionID":"ses_pre_merge","text":"implementation in progress"}' >"$output_file"
	printf '%s\n' '{"type":"external_directory","request_id":"perm-pre-merge"}' >"$permission_file"

	local result=""
	result=$(
		(
			export DISPATCH_REPO_SLUG="owner/repo"
			export WORKER_ISSUE_NUMBER="99999"
			_run_permission_request_file="$permission_file"
			gh() {
				if [[ "${*}" == *"issue view 99999"* ]]; then
					printf 'OPEN\n'
					return 0
				fi
				return 1
			}
			_store_headless_session_if_allowed() { return 0; }
			local status=0
			_handle_run_result 1 "$output_file" "worker" "openai" \
				"issue-99999" "openai/test" "$work_dir" >/dev/null 2>&1 || status=$?
			printf 'status=%s|result=%s|request=%s\n' "$status" "$_run_result_label" \
				"$([[ -e "$permission_file" ]] && printf present || printf missing)"
		)
	)
	if [[ "$result" == "status=84|result=permission_required|request=present" ]]; then
		print_result "pre-merge permission remains blocking" 0
	else
		print_result "pre-merge permission remains blocking" 1 "$result"
	fi
	return 0
}

test_begin_worker_runtime_run_refreshes_run_id() {
	local first_run_id="" second_run_id=""
	AIDEVOPS_RUN_ID="run:stale"
	_begin_worker_runtime_run
	first_run_id="$AIDEVOPS_RUN_ID"
	_begin_worker_runtime_run
	second_run_id="$AIDEVOPS_RUN_ID"

	if [[ "$first_run_id" == run:* && "$second_run_id" == run:* ]] &&
		[[ "$first_run_id" != "run:stale" && "$second_run_id" != "$first_run_id" ]]; then
		print_result "each runtime process invocation receives a fresh run ID" 0
	else
		print_result "each runtime process invocation receives a fresh run ID" 1 \
			"first=${first_run_id:-<empty>} second=${second_run_id:-<empty>}"
	fi
	return 0
}

test_internal_opencode_retries_refresh_run_id() {
	local refresh_count=""
	refresh_count=$(python3 - "$HELPER_SCRIPT" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index("_execute_run_attempt() {")
end = source.index("\n#######################################\n# _discover_actual_worktree_dir", start)
body = source[start:end]
print(len(re.findall(r"_begin_worker_runtime_run\s*\n\s*_invoke_opencode", body)))
PY
	)

	if [[ "$refresh_count" == "2" ]]; then
		print_result "internal OpenCode retries refresh run identity before invocation" 0
	else
		print_result "internal OpenCode retries refresh run identity before invocation" 1 \
			"Expected two guarded internal retries, got ${refresh_count:-<empty>}"
	fi
	return 0
}

test_reconciled_outcome_persistence_retries() {
	local fake_helper="${TEST_ROOT}/fake-objective-helper.sh"
	local count_file="${TEST_ROOT}/fake-objective-helper.count"
	local args_file="${TEST_ROOT}/fake-objective-helper.args"
	cat >"$fake_helper" <<'SH'
#!/usr/bin/env bash
set -u
count=0
[[ -f "$AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE" ]] && read -r count <"$AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE"
count=$((count + 1))
printf '%s\n' "$count" >"$AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE"
printf '%s\n' "$*" >"$AIDEVOPS_FAKE_OBJECTIVE_ARGS_FILE"
[[ "$count" -ge 3 ]]
SH
	chmod +x "$fake_helper"

	(
		export OBJECTIVE_RECONCILIATION_HELPER="$fake_helper"
		export AIDEVOPS_FAKE_OBJECTIVE_COUNT_FILE="$count_file"
		export AIDEVOPS_FAKE_OBJECTIVE_ARGS_FILE="$args_file"
		export AIDEVOPS_OBJECTIVE_OUTCOME_WRITE_ATTEMPTS=3
		export AIDEVOPS_ATTEMPT_ID="attempt:retry-test"
		export AIDEVOPS_ATTEMPT_STARTED_AT=700
		export AIDEVOPS_RUN_ID="run:retry-test"
		export WORKER_ISSUE_NUMBER=99999
		export DISPATCH_REPO_SLUG="owner/repo"
		_hrw_record_reconciled_outcome "issue-99999" "premature_exit" \
			"success" "recovered" "worker_complete"
	)

	local call_count="" captured_args=""
	[[ -f "$count_file" ]] && read -r call_count <"$count_file"
	[[ -f "$args_file" ]] && read -r captured_args <"$args_file"
	if [[ "$call_count" == "3" && "$captured_args" == *"--attempt-id attempt:retry-test"* ]] &&
		[[ "$captured_args" == *"--run-id run:retry-test"* ]]; then
		print_result "reconciled outcome persistence retries bounded transient failures" 0
	else
		print_result "reconciled outcome persistence retries bounded transient failures" 1 \
			"calls=${call_count:-<empty>} args=${captured_args:-<empty>}"
	fi
	return 0
}

test_reconciled_outcome_requires_explicit_issue() {
	local fake_helper="${TEST_ROOT}/fake-objective-helper-no-issue.sh"
	local called_file="${TEST_ROOT}/fake-objective-helper-no-issue.called"
	cat >"$fake_helper" <<'SH'
#!/usr/bin/env bash
set -u
printf 'called\n' >"$AIDEVOPS_FAKE_OBJECTIVE_CALLED_FILE"
exit 0
SH
	chmod +x "$fake_helper"

	(
		unset WORKER_ISSUE_NUMBER 2>/dev/null || true
		export OBJECTIVE_RECONCILIATION_HELPER="$fake_helper"
		export AIDEVOPS_FAKE_OBJECTIVE_CALLED_FILE="$called_file"
		export AIDEVOPS_ATTEMPT_ID="attempt:null-issue"
		export DISPATCH_REPO_SLUG="owner/repo"
		_hrw_record_reconciled_outcome "routine-r004" "permission_required" \
			"failed" "failed" "permission_request_persistence_failed"
	)

	if [[ ! -e "$called_file" ]]; then
		print_result "reconciled outcome requires an explicit issue number" 0
	else
		print_result "reconciled outcome requires an explicit issue number" 1 \
			"non-issue session routine-r004 was attributed to issue 4"
	fi
	return 0
}

test_cmd_run_finish_emits_complete_when_no_workdir() {
	# When work_dir is absent (fail paths), behaviour is unchanged: worker_complete
	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }

	_cmd_run_finish "issue-99999" "complete"

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete when no work_dir provided" 0
	else
		print_result "_cmd_run_finish emits worker_complete when no work_dir provided" 1 \
			"Expected worker_complete (fail-open), got '${released_reason}'"
	fi
	return 0
}

# AC#3: orphan-recovery attempts gh pr create with correct args
test_attempt_orphan_recovery_pr_calls_gh_create() {
	local work_dir="${TEST_ROOT}/repo-orphan-recovery"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	printf '{"pr_base_branch":"develop"}\n' >"${work_dir}/.aidevops.json"

	local gh_head="" gh_base="" gh_repo="" gh_labels=""
	local gh_called=0
	gh() {
		# Capture pr create args
		local arg
		for arg in "$@"; do
			case "$_last_flag" in
			"--head") gh_head="$arg" ;;
			"--base") gh_base="$arg" ;;
			"--repo") gh_repo="$arg" ;;
			"--label")
				if [[ -z "$gh_labels" ]]; then
					gh_labels="$arg"
				else
					gh_labels="${gh_labels},${arg}"
				fi
				;;
			esac
			_last_flag="$arg"
		done
		gh_called=1
		return 0
	}
	_last_flag=""

	_attempt_orphan_recovery_pr \
		"issue-99999" "$work_dir" "feature/auto-test-issue-99999" "test-owner/test-repo"

	unset -f gh 2>/dev/null || true

	if [[ "$gh_called" -eq 1 ]]; then
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 0
	else
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 1 \
			"gh was not called"
	fi

	if [[ "$gh_head" == "feature/auto-test-issue-99999" ]]; then
		print_result "_attempt_orphan_recovery_pr passes correct --head" 0
	else
		print_result "_attempt_orphan_recovery_pr passes correct --head" 1 \
			"Expected --head=feature/auto-test-issue-99999, got '${gh_head}'"
	fi

	if [[ ",${gh_labels}," == *",origin:worker-takeover,"* ]]; then
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 0
	else
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 1 \
			"Expected --label=origin:worker-takeover, got '${gh_labels}'"
	fi

	if [[ ",${gh_labels}," == *",status:in-review,"* ]]; then
		print_result "_attempt_orphan_recovery_pr passes --label status:in-review" 0
	else
		print_result "_attempt_orphan_recovery_pr passes --label status:in-review" 1 \
			"Expected --label=status:in-review, got '${gh_labels}'"
	fi

	if [[ "$gh_base" == "develop" ]]; then
		print_result "_attempt_orphan_recovery_pr uses configured PR base" 0
	else
		print_result "_attempt_orphan_recovery_pr uses configured PR base" 1 \
			"Expected --base=develop, got '${gh_base}'"
	fi

	return 0
}

test_attempt_orphan_recovery_pr_uses_authoritative_worker_issue() {
	local work_dir="${TEST_ROOT}/repo-orphan-recovery-authoritative-issue"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	local WORKER_ISSUE_NUMBER="28313"
	local gh_title="" gh_body="" gh_called=0 _last_flag=""

	gh() {
		local arg=""
		for arg in "$@"; do
			case "$_last_flag" in
			"--title") gh_title="$arg" ;;
			"--body") gh_body="$arg" ;;
			esac
			_last_flag="$arg"
		done
		if [[ "${*}" == *"pr list"* ]]; then
			printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
		elif [[ "${*}" == *"repo view"* ]]; then
			printf 'main'
		elif [[ "${*}" == *"pr create"* ]]; then
			gh_called=1
		fi
		return 0
	}

	_attempt_orphan_recovery_pr \
		"manual-cli-28313-1784593858" "$work_dir" \
		"feature/auto-test-issue-99999" "test-owner/test-repo" "draft"
	unset -f gh 2>/dev/null || true

	if [[ "$gh_called" -eq 1 && "$gh_title" == *"#28313"* && \
		"$gh_body" == *"Resolves #28313"* && \
		"$gh_title" != *"1784593858"* && "$gh_body" != *"#1784593858"* ]]; then
		print_result "orphan recovery prefers authoritative worker issue over session timestamp" 0
	else
		print_result "orphan recovery prefers authoritative worker issue over session timestamp" 1 \
			"called=${gh_called} title=${gh_title:-<empty>} body=${gh_body:-<empty>}"
	fi
	return 0
}

test_ensure_orphan_recovery_rejects_empty_branch() {
	local work_dir="${TEST_ROOT}/repo-orphan-recovery-empty-branch"
	_setup_test_git_repo "$work_dir" 1

	local recovery_state=""
	if recovery_state=$(_ensure_orphan_recovery_branch_remote "$work_dir" "" "99999" "test-owner/test-repo"); then
		print_result "_ensure_orphan_recovery_branch_remote rejects empty branch" 1 \
			"Expected failure for empty branch, got '${recovery_state}'"
		return 0
	fi

	if [[ -z "$recovery_state" ]]; then
		print_result "_ensure_orphan_recovery_branch_remote rejects empty branch" 0
	else
		print_result "_ensure_orphan_recovery_branch_remote rejects empty branch" 1 \
			"Expected no state for empty branch, got '${recovery_state}'"
	fi
	return 0
}

test_build_orphan_recovery_pr_body_tolerates_missing_publish_flag() {
	local pr_body=""
	if ! pr_body=$(_build_orphan_recovery_pr_body "issue-99999" "feature/auto-test-issue-99999" "Resolves #99999"); then
		print_result "_build_orphan_recovery_pr_body tolerates missing publish flag" 1 \
			"Function failed when published_local_branch arg was omitted"
		return 0
	fi

	if [[ "$pr_body" == *"worker_branch_orphan"* ]] && [[ "$pr_body" != *"worker_local_branch_unpushed"* ]]; then
		print_result "_build_orphan_recovery_pr_body tolerates missing publish flag" 0
	else
		print_result "_build_orphan_recovery_pr_body tolerates missing publish flag" 1 \
			"Expected default orphan marker, got '${pr_body}'"
	fi
	return 0
}

# AC#4: on auto-PR success, _cmd_run_finish emits worker_complete with orphan note
test_cmd_run_finish_orphan_recovery_success_emits_worker_complete() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-ok"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Stub gh: pr list returns 0 (no PR); pr create succeeds; issue view = OPEN
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"repo view"* ]]; then printf 'main'
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete after successful orphan recovery" 0
	else
		print_result "_cmd_run_finish emits worker_complete after successful orphan recovery" 1 \
			"Expected worker_complete (PR auto-created), got '${released_reason}'"
	fi
	return 0
}

test_cmd_run_finish_local_unpushed_pushes_and_recovers_pr() {
	local work_dir="${TEST_ROOT}/repo-finish-local-unpushed-ok"
	_setup_test_git_repo "$work_dir" 1
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	local gh_head="" gh_base="" gh_called=0
	gh() {
		local arg=""
		for arg in "$@"; do
			case "$_last_flag" in
			"--head") gh_head="$arg" ;;
			"--base") gh_base="$arg" ;;
			esac
			_last_flag="$arg"
		done
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"repo view"* ]]; then printf 'main'
		elif [[ "${*}" == *"pr create"* ]]; then gh_called=1
		fi
		return 0
	}
	_last_flag=""

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	local remote_ref=""
	remote_ref=$(git -C "$work_dir" ls-remote origin "refs/heads/feature/auto-test-issue-99999" 2>/dev/null || true)
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_complete" && "$gh_called" -eq 1 && -n "$remote_ref" ]]; then
		print_result "_cmd_run_finish pushes local branch and recovers PR" 0
	else
		print_result "_cmd_run_finish pushes local branch and recovers PR" 1 \
			"Expected worker_complete, gh pr create, and remote ref; got reason='${released_reason}' gh_called=${gh_called} remote_ref='${remote_ref}'"
	fi

	if [[ "$gh_head" == "feature/auto-test-issue-99999" && "$gh_base" == "main" ]]; then
		print_result "local unpushed recovery creates PR from pushed branch against base" 0
	else
		print_result "local unpushed recovery creates PR from pushed branch against base" 1 \
			"Expected head feature/auto-test-issue-99999 base main, got head='${gh_head}' base='${gh_base}'"
	fi
	return 0
}

test_handle_worker_branch_orphan_empty_branch_issue_search_is_not_complete() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-cleaned"
	mkdir -p "$work_dir"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Empty branch forces issue-search fallback, which is dedup evidence but cannot
	# prove an exact-head completed handoff.
	gh() {
		if [[ "${*}" == *"pr list"* && "${*}" == *"--search #99999 in:body"* ]]; then
			printf '%s\n' '[{"number":123}]'
			return 0
		fi
		printf '%s\n' '[]'
		return 0
	}

	local released_reason=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_increment_orphan_count_stat() { return 0; }

	_handle_worker_branch_orphan "issue-99999" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_branch_orphan" ]]; then
		print_result "_handle_worker_branch_orphan does not complete from issue-search fallback" 0
	else
		print_result "_handle_worker_branch_orphan does not complete from issue-search fallback" 1 \
			"Expected worker_branch_orphan for inconclusive issue search, got '${released_reason}'"
	fi
	return 0
}

# AC#4: on auto-PR failure, _cmd_run_finish emits worker_branch_orphan
test_cmd_run_finish_orphan_recovery_failure_emits_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-fail"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	AIDEVOPS_PR_BASE_BRANCH="develop"

	# Stub gh: pr list returns 0, issue view = OPEN, pr create FAILS
	local posted_body=""
	gh() {
		if [[ "${1:-}" == "api" ]]; then
			local arg=""
			for arg in "$@"; do
				if [[ "$arg" == body=* ]]; then
					posted_body="${arg#body=}"
				fi
			done
			return 0
		elif [[ "${*}" == *"pr list"* ]]; then
			printf '0'
			return 0
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
			return 0
		elif [[ "${*}" == *"repo view"* ]]; then
			printf 'main'
			return 0
		elif [[ "${*}" == *"pr create"* ]]; then
			return 1  # Simulate pr create failure
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset AIDEVOPS_PR_BASE_BRANCH 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_branch_orphan" ]]; then
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 0
	else
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 1 \
			"Expected worker_branch_orphan (PR create failed), got '${released_reason}'"
	fi

	if [[ "$posted_body" == *"gh pr create --head feature/auto-test-issue-99999 --base develop --repo test-owner/test-repo"* ]]; then
		print_result "worker_branch_orphan comment uses configured PR base" 0
	else
		print_result "worker_branch_orphan comment uses configured PR base" 1 \
			"Expected orphan recovery comment with --base develop, got '${posted_body}'"
	fi
	return 0
}

test_cmd_run_finish_local_unpushed_push_failure_emits_distinct_reason() {
	local work_dir="${TEST_ROOT}/repo-finish-local-unpushed-fail"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" remote set-url origin "${TEST_ROOT}/missing-remote.git"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	AIDEVOPS_PR_BASE_BRANCH="develop"

	local posted_body=""
	gh() {
		if [[ "${1:-}" == "api" ]]; then
			local arg=""
			for arg in "$@"; do
				if [[ "$arg" == body=* ]]; then
					posted_body="${arg#body=}"
				fi
			done
			return 0
		elif [[ "${*}" == *"pr list"* ]]; then
			printf '0'
			return 0
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
			return 0
		elif [[ "${*}" == *"repo view"* ]]; then
			printf 'main'
			return 0
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset AIDEVOPS_PR_BASE_BRANCH 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_local_branch_unpushed" ]]; then
		print_result "_cmd_run_finish emits worker_local_branch_unpushed when local push recovery fails" 0
	else
		print_result "_cmd_run_finish emits worker_local_branch_unpushed when local push recovery fails" 1 \
			"Expected worker_local_branch_unpushed, got '${released_reason}'"
	fi

	local expected_push_ref="HE""AD:feature/auto-test-issue-99999"
	if [[ "$posted_body" == *"WORKER_LOCAL_BRANCH_UNPUSHED"* && "$posted_body" == *"git -C ${work_dir} push origin ${expected_push_ref}"* ]]; then
		print_result "local unpushed failure comment is distinct and includes push recovery" 0
	else
		print_result "local unpushed failure comment is distinct and includes push recovery" 1 \
			"Expected local-unpushed recovery comment, got '${posted_body}'"
	fi
	return 0
}

test_cmd_run_finish_fail_recovers_branch_orphan_output() {
	local work_dir="${TEST_ROOT}/repo-fail-orphan-ok"
	local released_reason="" fast_fail_called=0 recorded_outcome=""
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"repo view"* ]]; then printf 'main'
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }
	_cmd_run_finish "issue-99999" "fail" "$work_dir"
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_complete" && "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish fail recovers branch-orphan output" 0
	else
		print_result "_cmd_run_finish fail recovers branch-orphan output" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	if [[ "$recorded_outcome" == "success" ]]; then
		print_result "_cmd_run_finish records success for recovered failed run" 0
	else
		print_result "_cmd_run_finish records success for recovered failed run" 1 \
			"Expected success telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_fail_closed_issue_without_merged_pr_fails() {
	local work_dir="${TEST_ROOT}/repo-fail-issue-closed"
	local released_reason="" fast_fail_called=0 recorded_outcome=""
	_setup_test_git_repo "$work_dir" 0
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"issue view"* ]]; then printf 'CLOSED'
		elif [[ "${*}" == *"pr list"* ]]; then printf ''
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }

	_cmd_run_finish "issue-99999" "fail" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_failed" && "$fast_fail_called" -eq 1 ]]; then
		print_result "_cmd_run_finish fail requires merged PR beyond closed issue" 0
	else
		print_result "_cmd_run_finish fail requires merged PR beyond closed issue" 1 \
			"Expected worker_failed and fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	if [[ "$recorded_outcome" == "failed" ]]; then
		print_result "_cmd_run_finish records failed telemetry for genuine failure" 0
	else
		print_result "_cmd_run_finish records failed telemetry for genuine failure" 1 \
			"Expected failed telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_fail_existing_pr_recovery_remains_complete() {
	local work_dir="${TEST_ROOT}/repo-fail-pr-merged"
	local released_reason="" fast_fail_called=0
	_setup_test_git_repo "$work_dir" 1
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"pr list"* && "${*}" == *"--state merged"* ]]; then printf '1'
		else printf '0'
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "fail" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_complete" && "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish fail still recovers existing PR for open issue" 0
	else
		print_result "_cmd_run_finish fail still recovers existing PR for open issue" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	return 0
}

test_cmd_run_finish_fail_confirmed_terminal_state_releases_complete() {
	local work_dir="${TEST_ROOT}/repo-fail-terminal-complete"
	local released_reason="" fast_fail_called=0
	_setup_test_git_repo "$work_dir" 1
	WORKER_TARGET_BRANCH=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD)
	export WORKER_TARGET_BRANCH
	rm -rf "$work_dir"
	mkdir -p "$work_dir"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() {
		if [[ "${*}" == *"issue view"* ]]; then printf 'CLOSED'
		elif [[ "${*}" == *"pr list"* && "${*}" == *"--head"* && "${*}" == *"--state merged"* ]]; then printf '123'
		elif [[ "${*}" == *"pr list"* && "${*}" == *"--search"* && "${*}" == *"--state merged"* ]]; then printf '123'
		fi
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "fail" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset WORKER_TARGET_BRANCH 2>/dev/null || true
	unset -f gh 2>/dev/null || true
	if [[ "$released_reason" == "worker_complete" && "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish fail uses cached branch when live worktree lookup is invalid" 0
	else
		print_result "_cmd_run_finish fail treats confirmed terminal GitHub state as complete" 1 \
			"Expected worker_complete and no fast-fail, got reason='${released_reason}' fast_fail=${fast_fail_called}"
	fi
	return 0
}
