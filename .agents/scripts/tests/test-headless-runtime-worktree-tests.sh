#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Worker worktree ownership, continuation, and launch-path tests.

# This file is sourced by test-headless-runtime-helper.sh after the shared test
# harness and headless runtime helper have been initialized.
[[ -n "${_TEST_HEADLESS_RUNTIME_WORKTREE_TESTS_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_WORKTREE_TESTS_LOADED=1

test_issue_worker_env_contract_rejects_missing_env() {
	unset WORKER_ISSUE_NUMBER WORKER_WORKTREE_PATH 2>/dev/null || true
	local output=""
	local status=0
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-22438" "$TEST_ROOT" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438" 2>&1) || status=$?

	if [[ "$status" -ne 0 && "$output" == *"WORKER_ISSUE_NUMBER unset"* ]]; then
		print_result "issue worker env contract rejects missing WORKER_ISSUE_NUMBER" 0
		return 0
	fi

	print_result "issue worker env contract rejects missing WORKER_ISSUE_NUMBER" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_issue_worker_env_contract_rejects_invalid_or_mismatched_issue() {
	local output=""
	local status=0
	export WORKER_ISSUE_NUMBER="not-an-issue"
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-22438" "$TEST_ROOT" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438" 2>&1) || status=$?
	if [[ "$status" -ne 0 && "$output" == *"WORKER_ISSUE_NUMBER invalid"* ]]; then
		print_result "issue worker env contract rejects a non-numeric issue" 0
	else
		print_result "issue worker env contract rejects a non-numeric issue" 1 \
			"status=$status output=${output:-<empty>}"
	fi

	status=0
	export WORKER_ISSUE_NUMBER="99999"
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-22438" "$TEST_ROOT" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438" 2>&1) || status=$?
	if [[ "$status" -ne 0 && "$output" == *"does not match session issue identity"* ]]; then
		print_result "issue worker env contract rejects mismatched session identity" 0
	else
		print_result "issue worker env contract rejects mismatched session identity" 1 \
			"status=$status output=${output:-<empty>}"
	fi

	status=0
	export WORKER_ISSUE_NUMBER="4"
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-0004" "$TEST_ROOT" "Issue #4: env contract" \
		"/full-loop Implement issue #4" 2>&1) || status=$?
	if [[ "$status" -ne 0 && "$output" == *"does not match session issue identity"* ]]; then
		print_result "issue worker env contract rejects leading-zero session identity" 0
	else
		print_result "issue worker env contract rejects leading-zero session identity" 1 \
			"status=$status output=${output:-<empty>}"
	fi

	status=0
	export WORKER_ISSUE_NUMBER="1"
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-0" "$TEST_ROOT" "Issue #1: env contract" \
		"/full-loop Implement issue #1" 2>&1) || status=$?
	if [[ "$status" -ne 0 && "$output" == *"does not match session issue identity"* ]]; then
		print_result "issue worker env contract rejects zero session identity" 0
	else
		print_result "issue worker env contract rejects zero session identity" 1 \
			"status=$status output=${output:-<empty>}"
	fi
	unset WORKER_ISSUE_NUMBER 2>/dev/null || true
	return 0
}

test_issue_worker_env_contract_rejects_missing_worktree() {
	export WORKER_ISSUE_NUMBER="22438"
	export WORKER_REPO_SLUG="owner/repo"
	unset WORKER_WORKTREE_PATH 2>/dev/null || true
	local output=""
	local status=0
	output=$(_validate_issue_worker_env_contract \
		"worker" "issue-22438" "$TEST_ROOT" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438" 2>&1) || status=$?

	if [[ "$status" -ne 0 && "$output" == *"WORKER_WORKTREE_PATH unset"* ]]; then
		print_result "issue worker env contract rejects missing WORKER_WORKTREE_PATH" 0
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG 2>/dev/null || true
		return 0
	fi

	print_result "issue worker env contract rejects missing WORKER_WORKTREE_PATH" 1 \
		"status=$status output=${output:-<empty>}"
	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG 2>/dev/null || true
	return 0
}

test_issue_worker_env_contract_accepts_valid_precreated_worktree() {
	local worktree_dir="${TEST_ROOT}/precreated-worktree"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_WORKTREE_PATH="$worktree_dir"

	if _validate_issue_worker_env_contract \
		"worker" "issue-22438" "$worktree_dir" "Issue #22438: env contract" \
		"/full-loop Implement issue #22438"; then
		print_result "issue worker env contract accepts valid precreated worktree" 0
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH 2>/dev/null || true
		return 0
	fi

	print_result "issue worker env contract accepts valid precreated worktree" 1
	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH 2>/dev/null || true
	return 0
}

test_triage_env_contract_does_not_require_worker_authority() {
	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH 2>/dev/null || true
	local output=""
	local status=0
	output=$(_validate_issue_worker_env_contract \
		"triage" "triage-review-22438" "$TEST_ROOT" \
		"Sandboxed triage review: Issue #22438" \
		"Review issue #22438 from prefetched context" 2>&1) || status=$?

	if [[ "$status" -eq 0 && -z "$output" ]]; then
		print_result "triage correlation bypasses implementation-worker env contract" 0
		return 0
	fi
	print_result "triage correlation bypasses implementation-worker env contract" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_worker_worktree_claim_transfers_to_runtime_pid() {
	local worktree_dir="${TEST_ROOT}/claim-worktree"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"

	local claimed_path="" claimed_branch="" claimed_session="" claimed_task="" claimed_pid=""
	claim_worktree_ownership() {
		claimed_path="$1"
		claimed_branch="$2"
		shift 2
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--session)
				claimed_session="${2:-}"
				shift 2
				;;
			--task)
				claimed_task="${2:-}"
				shift 2
				;;
			--owner-pid)
				claimed_pid="${2:-}"
				shift 2
				;;
			*) shift ;;
			esac
		done
		return 0
	}

	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null
	local proof_pid="${AIDEVOPS_WORKTREE_OWNER_PID:-}"
	local proof_session="${AIDEVOPS_WORKTREE_OWNER_SESSION:-}"
	local proof_task="${AIDEVOPS_WORKTREE_OWNER_TASK:-}"
	local proof_path="${AIDEVOPS_WORKTREE_OWNER_PATH:-}"
	local expected_proof_path=""
	expected_proof_path=$(cd "$worktree_dir" 2>/dev/null && pwd -P)

	unset -f claim_worktree_ownership 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER AIDEVOPS_WORKTREE_OWNER_PID \
		AIDEVOPS_WORKTREE_OWNER_SESSION AIDEVOPS_WORKTREE_OWNER_TASK \
		AIDEVOPS_WORKTREE_OWNER_PATH 2>/dev/null || true

	if [[ "$claimed_path" == "$worktree_dir" ]] &&
		[[ "$claimed_branch" == "detached" ]] &&
		[[ "$claimed_session" == "issue-22438" ]] &&
		[[ "$claimed_task" == "22438" ]] &&
		[[ "$claimed_pid" == "$$" ]] &&
		[[ "$proof_pid" == "$$" ]] &&
		[[ "$proof_session" == "issue-22438" ]] &&
		[[ "$proof_task" == "22438" ]] &&
		[[ "$proof_path" == "$expected_proof_path" ]]; then
		print_result "worker worktree claim exports exact wrapper ownership proof" 0
		return 0
	fi

	print_result "worker worktree claim exports exact wrapper ownership proof" 1 \
		"path=$claimed_path branch=$claimed_branch session=$claimed_session task=$claimed_task pid=$claimed_pid proof=${proof_pid}|${proof_session}|${proof_task}|${proof_path}"
	return 0
}

test_worker_worktree_claim_reclaims_stale_live_same_task_owner() {
	local worktree_dir="${TEST_ROOT}/claim-stale-live-owner"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS="1"
	local claim_calls=0 transfer_called=0 unregister_called=0
	local live_pid="$$"

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		claim_calls=$((claim_calls + 1))
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		[[ "$claim_calls" -gt 1 ]] && return 0
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "old-session" "" "22438" "2000-01-01T00:00:00Z"
		return 0
	}
	unregister_worktree() {
		local unregister_path="$1"
		[[ -n "$unregister_path" ]] || return 1
		unregister_called=$((unregister_called + 1))
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_called=$((transfer_called + 1))
		return 0
	}

	local status=0
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree \
		transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -eq 0 && "$claim_calls" -eq 2 && "$transfer_called" -eq 1 && "$unregister_called" -eq 0 ]]; then
		print_result "worker worktree claim reclaims stale live same-task owner" 0
		return 0
	fi

	print_result "worker worktree claim reclaims stale live same-task owner" 1 \
		"status=$status calls=$claim_calls transfer=$transfer_called unregister=$unregister_called"
	return 0
}

test_worker_worktree_claim_reclaims_dispatch_precreate_owner() {
	local worktree_dir="${TEST_ROOT}/claim-dispatch-precreate-owner"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS="900"
	local claim_calls=0 transfer_called=0 unregister_called=0
	local live_pid="$$"

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		claim_calls=$((claim_calls + 1))
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		[[ "$claim_calls" -gt 1 ]] && return 0
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "dispatch-precreate-22438" "" "22438" "2099-01-01T00:00:00Z"
		return 0
	}
	unregister_worktree() {
		local unregister_path="$1"
		[[ -n "$unregister_path" ]] || return 1
		unregister_called=$((unregister_called + 1))
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_called=$((transfer_called + 1))
		return 0
	}

	local status=0
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree \
		transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER AIDEVOPS_WORKER_WORKTREE_OWNER_RECLAIM_AGE_SECONDS _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -eq 0 && "$claim_calls" -eq 2 && "$transfer_called" -eq 1 && "$unregister_called" -eq 0 ]]; then
		print_result "worker worktree claim reclaims dispatch precreate owner" 0
		return 0
	fi

	print_result "worker worktree claim reclaims dispatch precreate owner" 1 \
		"status=$status calls=$claim_calls transfer=$transfer_called unregister=$unregister_called"
	return 0
}

test_worker_worktree_claim_transfers_dispatch_precreate_task_state() {
	local state_kind="" worktree_dir="" expected_head="" actual_head=""
	local preserved_status="" ahead_count="" owner_created_at="" transfer_args=""
	local live_pid="$$" claim_calls=0 transfer_calls=0 unregister_calls=0 status=0

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		claim_calls=$((claim_calls + 1))
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		[[ "$claim_calls" -gt 1 ]] && return 0
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "dispatch-precreate-22438" "batch-7" "22438" "$owner_created_at"
		return 0
	}
	unregister_worktree() {
		local unregister_path="$1"
		[[ -n "$unregister_path" ]] || return 1
		unregister_calls=$((unregister_calls + 1))
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		shift 2
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_calls=$((transfer_calls + 1))
		transfer_args="$*"
		return 0
	}

	for state_kind in dirty ahead; do
		worktree_dir="${TEST_ROOT}/claim-dispatch-precreate-${state_kind}"
		mkdir -p "$worktree_dir"
		init_git_worktree "$worktree_dir"
		expected_head=$(git -C "$worktree_dir" rev-parse HEAD)
		if [[ "$state_kind" == "dirty" ]]; then
			printf 'preserve me\n' >"${worktree_dir}/precreate-task-state.txt"
			owner_created_at="2026-07-18T00:00:05Z"
		else
			git -C "$worktree_dir" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
				commit --allow-empty -q -m "precreate checkpoint"
			expected_head=$(git -C "$worktree_dir" rev-parse HEAD)
			owner_created_at="2026-07-18T00:00:06Z"
		fi

		export WORKER_ISSUE_NUMBER="22438"
		claim_calls=0
		transfer_calls=0
		unregister_calls=0
		transfer_args=""
		status=0
		_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?
		preserved_status=$(git -C "$worktree_dir" status --porcelain 2>/dev/null || true)
		actual_head=$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null || true)
		ahead_count=$(git -C "$worktree_dir" rev-list --count origin/main..HEAD 2>/dev/null || true)

		local state_preserved=0
		if [[ "$state_kind" == "dirty" && "$preserved_status" == *"precreate-task-state.txt"* &&
			"$actual_head" == "$expected_head" && "$ahead_count" == "0" ]]; then
			state_preserved=1
		elif [[ "$state_kind" == "ahead" && -z "$preserved_status" &&
			"$actual_head" == "$expected_head" && "$ahead_count" == "1" ]]; then
			state_preserved=1
		fi

		if [[ "$status" -eq 0 && "$claim_calls" -eq 2 && "$transfer_calls" -eq 1 &&
			"$unregister_calls" -eq 0 && "$state_preserved" -eq 1 &&
			"$transfer_args" == *"--expected-session dispatch-precreate-22438"* &&
			"$transfer_args" == *"--expected-batch batch-7"* &&
			"$transfer_args" == *"--expected-task 22438"* ]]; then
			print_result "${state_kind} dispatch-precreate state transfers atomically without data loss" 0
		else
			print_result "${state_kind} dispatch-precreate state transfers atomically without data loss" 1 \
				"status=$status claims=$claim_calls transfers=$transfer_calls unregisters=$unregister_calls preserved=$state_preserved args=${transfer_args:-<empty>}"
		fi
	done

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree \
		transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	return 0
}

test_worker_worktree_claim_rejects_dispatch_precreate_task_mismatch() {
	local worktree_dir="${TEST_ROOT}/claim-dispatch-precreate-task-mismatch"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" transfer_calls=0

	claim_worktree_ownership() {
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "dispatch-precreate-99999" "batch-7" "99999" "2026-07-18T00:00:10Z"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f claim_worktree_ownership check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 0 && "$reason" == "worker_worktree_live_owner" ]]; then
		print_result "dispatch-precreate transfer rejects a different task owner" 0
		return 0
	fi
	print_result "dispatch-precreate transfer rejects a different task owner" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_claim_classifies_dispatch_precreate_concurrent_mutation() {
	local worktree_dir="${TEST_ROOT}/claim-dispatch-precreate-concurrent-mutation"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" transfer_calls=0

	claim_worktree_ownership() {
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "dispatch-precreate-22438" "batch-7" "22438" "2026-07-18T00:00:11Z"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 1
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f claim_worktree_ownership check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 1 &&
		"$reason" == "worker_worktree_owner_concurrent_mutation" ]]; then
		print_result "dispatch-precreate transfer rejects concurrent owner mutation" 0
		return 0
	fi
	print_result "dispatch-precreate transfer rejects concurrent owner mutation" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

set_continuation_transfer_env() {
	local owner_pid="$1"
	local owner_session="$2"
	local owner_batch="$3"
	local owner_task="$4"
	local owner_created_at="$5"
	export AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE="continuation"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID="$owner_pid"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION="$owner_session"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH="$owner_batch"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK="$owner_task"
	export AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT="$owner_created_at"
	return 0
}

clear_continuation_transfer_env() {
	unset AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT \
		WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true
	return 0
}

test_worker_worktree_continuation_transfers_dirty_same_task_owner() {
	local worktree_dir="${TEST_ROOT}/continuation-dirty"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	printf 'preserve me\n' >"${worktree_dir}/continuation.txt"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:00Z"
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
	local claim_calls=0 transfer_calls=0

	claim_worktree_ownership() {
		claim_calls=$((claim_calls + 1))
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 preserved_status=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?
	preserved_status=$(git -C "$worktree_dir" status --porcelain 2>/dev/null || true)

	unset -f claim_worktree_ownership check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -eq 0 && "$claim_calls" -eq 0 && "$transfer_calls" -eq 1 &&
		"$preserved_status" == *"continuation.txt"* ]]; then
		print_result "dirty same-task continuation transfers without discarding edits" 0
		return 0
	fi
	print_result "dirty same-task continuation transfers without discarding edits" 1 \
		"status=$status claim_calls=$claim_calls transfer_calls=$transfer_calls git_status=${preserved_status:-<empty>}"
	return 0
}

test_worker_worktree_continuation_transfers_ahead_same_task_owner() {
	local worktree_dir="${TEST_ROOT}/continuation-ahead"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	git -C "$worktree_dir" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
		commit --allow-empty -q -m "continuation checkpoint"
	local expected_head=""
	expected_head=$(git -C "$worktree_dir" rev-parse HEAD)
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:01Z"
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
	local claim_calls=0 transfer_calls=0

	claim_worktree_ownership() {
		claim_calls=$((claim_calls + 1))
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 actual_head="" ahead_count=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null || status=$?
	actual_head=$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null || true)
	ahead_count=$(git -C "$worktree_dir" rev-list --count origin/main..HEAD 2>/dev/null || true)

	unset -f claim_worktree_ownership check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -eq 0 && "$claim_calls" -eq 0 && "$transfer_calls" -eq 1 &&
		"$actual_head" == "$expected_head" && "$ahead_count" == "1" ]]; then
		print_result "ahead same-task continuation transfers without discarding commits" 0
		return 0
	fi
	print_result "ahead same-task continuation transfers without discarding commits" 1 \
		"status=$status claim_calls=$claim_calls transfer_calls=$transfer_calls head=$actual_head ahead=$ahead_count"
	return 0
}

test_worker_worktree_continuation_classifies_task_mismatch() {
	local worktree_dir="${TEST_ROOT}/continuation-task-mismatch"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:02Z" transfer_calls=0
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "99999" "$owner_created_at"
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "generation-7" "batch-7" "99999" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 0 && "$reason" == "worker_worktree_continuation_task_mismatch" ]]; then
		print_result "same-task continuation rejects registry task mismatch precisely" 0
		return 0
	fi
	print_result "same-task continuation rejects registry task mismatch precisely" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_continuation_classifies_owner_mismatch() {
	local worktree_dir="${TEST_ROOT}/continuation-owner-mismatch"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:03Z" transfer_calls=0
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "competing-generation" "batch-8" "22438" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 0 && "$reason" == "worker_worktree_continuation_owner_mismatch" ]]; then
		print_result "same-task continuation rejects expected-owner mismatch precisely" 0
		return 0
	fi
	print_result "same-task continuation rejects expected-owner mismatch precisely" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_continuation_classifies_concurrent_mutation() {
	local worktree_dir="${TEST_ROOT}/continuation-concurrent-mutation"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$" owner_created_at="2026-07-18T00:00:04Z" transfer_calls=0
	set_continuation_transfer_env "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "generation-7" "batch-7" "22438" "$owner_created_at"
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		transfer_calls=$((transfer_calls + 1))
		return 1
	}

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	unset -f check_worktree_owner transfer_worktree_ownership_if_expected 2>/dev/null || true
	clear_continuation_transfer_env

	if [[ "$status" -ne 0 && "$transfer_calls" -eq 1 && "$reason" == "worker_worktree_continuation_concurrent_mutation" ]]; then
		print_result "same-task continuation rejects concurrent owner mutation precisely" 0
		return 0
	fi
	print_result "same-task continuation rejects concurrent owner mutation precisely" 1 \
		"status=$status transfer_calls=$transfer_calls reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_continuation_classifies_invalid_state() {
	local worktree_dir="${TEST_ROOT}/continuation-invalid-state"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	export AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE="continuation"
	unset AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK \
		AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT 2>/dev/null || true

	local status=0 reason=""
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"
	clear_continuation_transfer_env

	if [[ "$status" -ne 0 && "$reason" == "worker_worktree_continuation_state_rejected" ]]; then
		print_result "same-task continuation rejects incomplete transfer state precisely" 0
		return 0
	fi
	print_result "same-task continuation rejects incomplete transfer state precisely" 1 \
		"status=$status reason=${reason:-<empty>}"
	return 0
}

test_worker_worktree_clean_without_upstream_blocks_local_commits() {
	local worktree_dir="${TEST_ROOT}/claim-local-commits"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	git -C "$worktree_dir" config --unset branch.main.remote 2>/dev/null || true
	git -C "$worktree_dir" config --unset branch.main.merge 2>/dev/null || true
	git -C "$worktree_dir" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
		commit --allow-empty -q -m "local-only"

	local status=0
	_hrw_worktree_clean_for_owner_reclaim "$worktree_dir" >/dev/null || status=$?

	if [[ "$status" -ne 0 ]]; then
		print_result "worker worktree clean check blocks no-upstream local commits" 0
		return 0
	fi

	print_result "worker worktree clean check blocks no-upstream local commits" 1 "status=$status"
	return 0
}

test_worker_worktree_claim_classifies_unreclaimed_live_owner() {
	local worktree_dir="${TEST_ROOT}/claim-live-owner-blocked"
	mkdir -p "$worktree_dir"
	export WORKER_ISSUE_NUMBER="22438"
	local live_pid="$$"

	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		return 1
	}
	check_worktree_owner() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|%s|%s|%s|%s\n' "$live_pid" "active-session" "" "99999" "2000-01-01T00:00:00Z"
		return 0
	}
	unregister_worktree() { local unregister_path="$1"; [[ -n "$unregister_path" ]] || return 1; return 0; }

	local status=0
	_hrw_claim_worker_worktree "issue-22438" "$worktree_dir" >/dev/null 2>&1 || status=$?
	local reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-}"

	unset -f claim_worktree_ownership check_worktree_owner unregister_worktree 2>/dev/null || true
	unset WORKER_ISSUE_NUMBER _WORKER_PRELAUNCH_FAILURE_REASON 2>/dev/null || true

	if [[ "$status" -ne 0 && "$reason" == "worker_worktree_live_owner" ]]; then
		print_result "worker worktree claim classifies unreclaimed live owner" 0
		return 0
	fi

	print_result "worker worktree claim classifies unreclaimed live owner" 1 \
		"status=$status reason=${reason:-<empty>}"
	return 0
}

test_worker_runtime_ownership_fence_rejects_takeover() {
	local ownership_helper="${TEST_ROOT}/runtime-ownership-helper.sh"
	local calls_file="${TEST_ROOT}/runtime-ownership-calls"
	cat >"$ownership_helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${RUNTIME_OWNERSHIP_CALLS:?}"
printf 'WORKER_OWNERSHIP_LOST: interactive takeover\n'
exit 1
EOF
	chmod +x "$ownership_helper"
	export HEADLESS_RUNTIME_OWNERSHIP_HELPER="$ownership_helper"
	export RUNTIME_OWNERSHIP_CALLS="$calls_file"
	export WORKER_ISSUE_NUMBER="22438"
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_GITHUB_LOGIN="expected-runner"
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local output=""
	local status=0
	output=$(_hrw_verify_dispatch_ownership 2>&1) || status=$?
	local calls=""
	calls=$(<"$calls_file")
	unset HEADLESS_RUNTIME_OWNERSHIP_HELPER RUNTIME_OWNERSHIP_CALLS \
		WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_GITHUB_LOGIN 2>/dev/null || true

	if [[ "$status" -eq 1 && "$calls" == "verify-worker-ownership 22438 owner/repo expected-runner" && \
		"$output" == *"worker ownership unavailable"* ]]; then
		print_result "worker runtime ownership fence rejects interactive takeover" 0
		return 0
	fi
	print_result "worker runtime ownership fence rejects interactive takeover" 1 \
		"status=$status calls=${calls:-<empty>} output=${output:-<empty>}"
	return 0
}

test_direct_pr_runtime_target_fence_uses_exact_head_without_runner() {
	local ownership_helper="${TEST_ROOT}/direct-pr-target-helper.sh"
	local calls_file="${TEST_ROOT}/direct-pr-target-calls"
	local expected_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	cat >"$ownership_helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${DIRECT_PR_TARGET_CALLS:?}"
printf 'PR_REPAIR_TARGET_VALID: exact open head\n'
exit 0
EOF
	chmod +x "$ownership_helper"
	export HEADLESS_RUNTIME_OWNERSHIP_HELPER="$ownership_helper"
	export DIRECT_PR_TARGET_CALLS="$calls_file"
	export WORKER_ISSUE_NUMBER="77"
	export WORKER_REPO_SLUG="owner/repo"
	export AIDEVOPS_PR_REPAIR_NUMBER="77"
	export AIDEVOPS_PR_REPAIR_HEAD_SHA="$expected_sha"
	export AIDEVOPS_PR_REPAIR_HEAD_REF="feature/review"
	unset DISPATCH_REPO_SLUG WORKER_GITHUB_LOGIN AIDEVOPS_WORKER_GITHUB_LOGIN 2>/dev/null || true

	local output=""
	local status=0
	output=$(_hrw_verify_dispatch_ownership 2>&1) || status=$?
	local calls=""
	calls=$(<"$calls_file")
	unset HEADLESS_RUNTIME_OWNERSHIP_HELPER DIRECT_PR_TARGET_CALLS \
		WORKER_ISSUE_NUMBER WORKER_REPO_SLUG AIDEVOPS_PR_REPAIR_NUMBER \
		AIDEVOPS_PR_REPAIR_HEAD_SHA AIDEVOPS_PR_REPAIR_HEAD_REF 2>/dev/null || true

	if [[ "$status" -eq 0 && "$calls" == "verify-pr-repair-target 77 owner/repo ${expected_sha} feature/review" && \
		"$output" == *"PR_REPAIR_TARGET_VALID"* ]]; then
		print_result "direct PR runtime fence uses exact head without issue runner" 0
		return 0
	fi
	print_result "direct PR runtime fence uses exact head without issue runner" 1 \
		"status=$status calls=${calls:-<empty>} output=${output:-<empty>}"
	return 0
}

test_direct_pr_runtime_target_fence_fails_closed() {
	local ownership_helper="${TEST_ROOT}/drifted-pr-target-helper.sh"
	local calls_file="${TEST_ROOT}/drifted-pr-target-calls"
	cat >"$ownership_helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${DRIFTED_PR_TARGET_CALLS:?}"
printf 'PR_REPAIR_TARGET_LOST: head drift\n'
exit 1
EOF
	chmod +x "$ownership_helper"
	export HEADLESS_RUNTIME_OWNERSHIP_HELPER="$ownership_helper"
	export DRIFTED_PR_TARGET_CALLS="$calls_file"
	export WORKER_ISSUE_NUMBER="77"
	export WORKER_REPO_SLUG="owner/repo"
	export AIDEVOPS_PR_REPAIR_NUMBER="77"
	export AIDEVOPS_PR_REPAIR_HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	export AIDEVOPS_PR_REPAIR_HEAD_REF="feature/review"
	unset DISPATCH_REPO_SLUG WORKER_GITHUB_LOGIN AIDEVOPS_WORKER_GITHUB_LOGIN 2>/dev/null || true

	local output=""
	local status=0
	output=$(_hrw_verify_dispatch_ownership 2>&1) || status=$?
	unset HEADLESS_RUNTIME_OWNERSHIP_HELPER DRIFTED_PR_TARGET_CALLS \
		WORKER_ISSUE_NUMBER WORKER_REPO_SLUG AIDEVOPS_PR_REPAIR_NUMBER \
		AIDEVOPS_PR_REPAIR_HEAD_SHA AIDEVOPS_PR_REPAIR_HEAD_REF 2>/dev/null || true

	if [[ "$status" -eq 1 && "$output" == *"direct PR repair target unavailable"* && \
		"$output" == *"PR_REPAIR_TARGET_LOST"* ]]; then
		print_result "direct PR runtime fence fails closed on target drift" 0
		return 0
	fi
	print_result "direct PR runtime fence fails closed on target drift" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_triage_prepare_drops_worker_authority_and_skips_ownership_fence() {
	local worktree_dir="${TEST_ROOT}/triage-prepare"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"

	local output=""
	output=$(
		export WORKER_ISSUE_NUMBER="22438"
		export WORKER_REPO_SLUG="owner/repo"
		export WORKER_WORKTREE_PATH="$worktree_dir"
		export WORKER_GITHUB_LOGIN="expected-runner"
		export AIDEVOPS_WORKER_GITHUB_LOGIN="fallback-runner"
		export AIDEVOPS_DISPATCH_LEASE_TOKEN="stale-lease"
		export AIDEVOPS_WORKER_ID="stale-worker-id"
		export AIDEVOPS_WORKTREE_OWNER_PID="999"
		export _WORKER_WORKTREE_PATH="stale-internal-path"
		export WORKER_TARGET_BRANCH="stale-worker-branch"
		_headless_private_workload_enabled() { return 1; }
		_hrw_permission_pending_path() { return 1; }
		_acquire_session_lock() { return 0; }
		_hrw_verify_dispatch_ownership() { printf 'ownership-called\n'; return 1; }
		_hrw_claim_worker_worktree() { printf 'claim-called\n'; return 1; }
		_register_dispatch_ledger() {
			printf 'ledger-called\n'
			return 0
		}

		local prepare_status=0
		_cmd_run_prepare "triage-review-22438" "$worktree_dir" "triage" || prepare_status=$?
		trap - EXIT
		printf 'status=%s vars=%s|%s|%s|%s|%s|%s|%s dispatch=%s\n' "$prepare_status" \
			"${WORKER_ISSUE_NUMBER:-}" "${WORKER_REPO_SLUG:-}" \
			"${WORKER_WORKTREE_PATH:-}" "${WORKER_GITHUB_LOGIN:-}" \
			"${AIDEVOPS_WORKER_GITHUB_LOGIN:-}" "${_WORKER_WORKTREE_PATH:-}" \
			"${WORKER_TARGET_BRANCH:-}" "${DISPATCH_REPO_SLUG:-}"
	)

	if [[ "$output" == *"status=0 vars=|||||| dispatch="* && \
		"$output" != *"ledger-called"* && \
		"$output" != *"ownership-called"* && "$output" != *"claim-called"* ]]; then
		print_result "triage preparation drops worker authority and worker ledger writes" 0
		return 0
	fi
	print_result "triage preparation drops worker authority and worker ledger writes" 1 \
		"output=${output:-<empty>}"
	return 0
}

test_triage_prepare_arms_non_worker_exit_cleanup() {
	local worktree_dir="${TEST_ROOT}/triage-exit-trap"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"

	local output=""
	local status=0
	output=$(
		_headless_private_workload_enabled() { return 1; }
		_hrw_permission_pending_path() { return 1; }
		_acquire_session_lock() { return 0; }
		_register_dispatch_ledger() { return 0; }
		_hrw_non_worker_exit_trap() {
			local session_key="$1"
			printf 'non-worker-exit=%s\n' "$session_key"
			trap - EXIT
			return 0
		}
		_exit_trap_handler() {
			printf 'worker-exit-called\n'
			trap - EXIT
			return 0
		}
		_cmd_run_prepare "triage-review-22438" "$worktree_dir" "triage"
		exit 9
	) || status=$?

	if [[ "$status" -eq 9 && "$output" == *"non-worker-exit=triage-review-22438"* && \
		"$output" != *"worker-exit-called"* ]]; then
		print_result "triage preparation arms non-worker abnormal-exit cleanup" 0
		return 0
	fi
	print_result "triage preparation arms non-worker abnormal-exit cleanup" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_linked_issue_pr_repair_keeps_issue_ownership_fence() {
	local ownership_helper="${TEST_ROOT}/linked-issue-ownership-helper.sh"
	local calls_file="${TEST_ROOT}/linked-issue-ownership-calls"
	cat >"$ownership_helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${LINKED_ISSUE_OWNERSHIP_CALLS:?}"
printf 'WORKER_OWNERSHIP_VALID: linked issue assignment\n'
exit 0
EOF
	chmod +x "$ownership_helper"
	export HEADLESS_RUNTIME_OWNERSHIP_HELPER="$ownership_helper"
	export LINKED_ISSUE_OWNERSHIP_CALLS="$calls_file"
	export WORKER_ISSUE_NUMBER="42"
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_GITHUB_LOGIN="expected-runner"
	export AIDEVOPS_PR_REPAIR_NUMBER="77"
	export AIDEVOPS_PR_REPAIR_HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	export AIDEVOPS_PR_REPAIR_HEAD_REF="feature/review"
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local output=""
	local status=0
	output=$(_hrw_verify_dispatch_ownership 2>&1) || status=$?
	local calls=""
	calls=$(<"$calls_file")
	unset HEADLESS_RUNTIME_OWNERSHIP_HELPER LINKED_ISSUE_OWNERSHIP_CALLS \
		WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_GITHUB_LOGIN \
		AIDEVOPS_PR_REPAIR_NUMBER AIDEVOPS_PR_REPAIR_HEAD_SHA \
		AIDEVOPS_PR_REPAIR_HEAD_REF 2>/dev/null || true

	if [[ "$status" -eq 0 && "$calls" == "verify-worker-ownership 42 owner/repo expected-runner" && \
		"$output" == *"WORKER_OWNERSHIP_VALID"* ]]; then
		print_result "linked-issue PR repair keeps strict issue ownership fence" 0
		return 0
	fi
	print_result "linked-issue PR repair keeps strict issue ownership fence" 1 \
		"status=$status calls=${calls:-<empty>} output=${output:-<empty>}"
	return 0
}

write_permission_pending_marker() {
	local worktree_dir="$1"
	local marker_json="$2"
	local git_dir=""
	git_dir=$(git -C "$worktree_dir" rev-parse --absolute-git-dir) || return 1
	printf '%s\n' "$marker_json" >"${git_dir}/aidevops-permission-pending"
	return 0
}

test_worker_role_context_inherits_matching_pending_permission() {
	local worktree_dir="${TEST_ROOT}/matching-permission-marker"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	write_permission_pending_marker "$worktree_dir" \
		'{"request_id":"perm-matching","issue":22438,"session":"issue-22438"}'

	local output=""
	output=$(
		export WORKER_ISSUE_NUMBER="22438"
		export WORKER_SESSION_KEY="issue-22438"
		export AIDEVOPS_PERMISSION_GRANT_FILE="/stale/grant.json"
		export AIDEVOPS_PERMISSION_REQUEST_ID="perm-stale"
		_hrw_prepare_role_context "worker" "$worktree_dir"
		printf 'request=%s grant=%s\n' \
			"${AIDEVOPS_PERMISSION_REQUEST_ID:-}" "${AIDEVOPS_PERMISSION_GRANT_FILE:-}"
	)

	if [[ "$output" == "request=perm-matching grant=" ]]; then
		print_result "worker role inherits only its matching pending permission request" 0
		return 0
	fi
	print_result "worker role inherits only its matching pending permission request" 1 \
		"output=${output:-<empty>}"
	return 0
}

test_worker_prepare_clears_cross_issue_pending_permission() {
	local worktree_dir="${TEST_ROOT}/cross-issue-permission-marker"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	write_permission_pending_marker "$worktree_dir" \
		'{"request_id":"perm-old-issue","issue":3203,"session":"issue-3203"}'

	local output=""
	output=$(
		export WORKER_ISSUE_NUMBER="3277"
		export WORKER_SESSION_KEY="pr-review-thread-response-owner-repo-3277"
		export WORKER_WORKTREE_PATH="$worktree_dir"
		export DISPATCH_REPO_SLUG="owner/repo"
		export AIDEVOPS_PERMISSION_GRANT_FILE="/stale/grant.json"
		export AIDEVOPS_PERMISSION_REQUEST_ID="perm-stale"
		_headless_private_workload_enabled() { return 1; }
		_acquire_session_lock() { return 0; }
		aidevops_sensitive_temp_root() { return 0; }
		_hrw_verify_dispatch_ownership() { return 0; }
		_hrw_claim_worker_worktree() { return 0; }
		_register_dispatch_ledger() { return 0; }
		_cmd_run_prepare "$WORKER_SESSION_KEY" "$worktree_dir" "worker"
		trap - EXIT
		local marker_state="missing"
		local git_dir=""
		git_dir=$(git -C "$worktree_dir" rev-parse --absolute-git-dir)
		[[ -f "${git_dir}/aidevops-permission-pending" ]] && marker_state="retained"
		printf 'request=%s grant=%s marker=%s\n' \
			"${AIDEVOPS_PERMISSION_REQUEST_ID:-}" "${AIDEVOPS_PERMISSION_GRANT_FILE:-}" "$marker_state"
	)

	if [[ "$output" == "request= grant= marker=retained" ]]; then
		print_result "worker preparation rejects a pending permission owned by another issue" 0
		return 0
	fi
	print_result "worker preparation rejects a pending permission owned by another issue" 1 \
		"output=${output:-<empty>}"
	return 0
}

test_worker_role_context_clears_cross_session_pending_permission() {
	local worktree_dir="${TEST_ROOT}/cross-session-permission-marker"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	write_permission_pending_marker "$worktree_dir" \
		'{"request_id":"perm-old-session","issue":22438,"session":"issue-22438-attempt-1"}'

	local output=""
	output=$(
		export WORKER_ISSUE_NUMBER="22438"
		export WORKER_SESSION_KEY="issue-22438-attempt-2"
		export AIDEVOPS_PERMISSION_GRANT_FILE="/stale/grant.json"
		export AIDEVOPS_PERMISSION_REQUEST_ID="perm-stale"
		_hrw_prepare_role_context "worker" "$worktree_dir"
		printf 'request=%s grant=%s\n' \
			"${AIDEVOPS_PERMISSION_REQUEST_ID:-}" "${AIDEVOPS_PERMISSION_GRANT_FILE:-}"
	)

	if [[ "$output" == "request= grant=" ]]; then
		print_result "worker role rejects a pending permission owned by another session" 0
		return 0
	fi
	print_result "worker role rejects a pending permission owned by another session" 1 \
		"output=${output:-<empty>}"
	return 0
}

test_worker_role_context_rejects_legacy_pending_permission() {
	local worktree_dir="${TEST_ROOT}/legacy-permission-marker"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	write_permission_pending_marker "$worktree_dir" \
		'{"request_id":"perm-legacy","issue":22438}'

	local output=""
	output=$(
		export WORKER_ISSUE_NUMBER="22438"
		export WORKER_SESSION_KEY="issue-22438"
		export AIDEVOPS_PERMISSION_GRANT_FILE="/stale/grant.json"
		export AIDEVOPS_PERMISSION_REQUEST_ID="perm-stale"
		_hrw_prepare_role_context "worker" "$worktree_dir"
		printf 'request=%s grant=%s\n' \
			"${AIDEVOPS_PERMISSION_REQUEST_ID:-}" "${AIDEVOPS_PERMISSION_GRANT_FILE:-}"
	)

	if [[ "$output" == "request= grant=" ]]; then
		print_result "worker role fails closed for a legacy unowned pending permission" 0
		return 0
	fi
	print_result "worker role fails closed for a legacy unowned pending permission" 1 \
		"output=${output:-<empty>}"
	return 0
}

test_triage_finish_skips_worker_claim_and_worktree_release() {
	local output=""
	output=$(
		local _CMD_RUN_ROLE="triage"
		_headless_private_workload_enabled() { return 1; }
		_update_dispatch_ledger() { printf 'ledger-called\n'; return 0; }
		_release_session_lock() { printf 'session-lock-released\n'; return 0; }
		_cleanup_headless_runtime_temp_paths() { printf 'temp-cleaned\n'; return 0; }
		aidevops_runtime_bundle_lease_release() { printf 'bundle-released\n'; return 0; }
		_hrw_release_worker_worktree() { printf 'worker-worktree-release-called\n'; return 0; }
		_hrw_release_dispatch_claim() { printf 'worker-claim-release-called\n'; return 0; }
		_worker_produced_output() { printf 'worker-output-classifier-called\n'; return 0; }
		_cmd_run_finish "triage-review-22438" "complete" "${TEST_ROOT}/triage-finish"
	)

	if [[ "$output" == *"session-lock-released"* && "$output" == *"temp-cleaned"* && \
		"$output" == *"bundle-released"* && "$output" != *"worker-"* && \
		"$output" != *"ledger-called"* ]]; then
		print_result "triage finish skips implementation-worker ledger, claim, and worktree writes" 0
		return 0
	fi
	print_result "triage finish skips implementation-worker ledger, claim, and worktree writes" 1 \
		"output=${output:-<empty>}"
	return 0
}

test_triage_finish_propagates_temp_cleanup_failure() {
	local output=""
	local status=0
	output=$(
		local _CMD_RUN_ROLE="triage"
		_headless_private_workload_enabled() { return 1; }
		_release_session_lock() { printf 'session-lock-released\n'; return 0; }
		_cleanup_headless_runtime_temp_paths() { printf 'temp-cleanup-failed\n'; return 1; }
		aidevops_runtime_bundle_lease_release() { printf 'bundle-released\n'; return 0; }
		_cmd_run_finish "triage-review-28705" "complete" "${TEST_ROOT}/triage-finish"
	) || status=$?

	if [[ "$status" -eq 1 && "$output" == *"temp-cleanup-failed"* && \
		"$output" == *"bundle-released"* ]]; then
		print_result "triage finish propagates temp cleanup failure" 0
		return 0
	fi
	print_result "triage finish propagates temp cleanup failure" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_triage_exit_trap_terminalizes_temp_cleanup_failure() {
	local output=""
	local status=0
	output=$(
		(
			_release_session_lock() { return 0; }
			_cleanup_headless_runtime_temp_paths() { return 1; }
			aidevops_runtime_bundle_lease_release() { return 0; }
			print_warning() {
				local message="$1"
				printf '%s\n' "$message"
				return 0
			}
			trap "_hrw_non_worker_exit_trap 'triage-review-28705'" EXIT
			exit 0
		)
	) || status=$?

	if [[ "$status" -eq 86 && \
		"$output" == *"non_worker_runtime_temp_cleanup_failed"* ]]; then
		print_result "triage exit trap terminalizes temp cleanup failure" 0
		return 0
	fi
	print_result "triage exit trap terminalizes temp cleanup failure" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_worker_prepare_retains_ownership_fence() {
	local worktree_dir="${TEST_ROOT}/worker-prepare-fence"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"

	local output=""
	output=$(
		export WORKER_ISSUE_NUMBER="22438"
		export WORKER_REPO_SLUG="owner/repo"
		export WORKER_WORKTREE_PATH="$worktree_dir"
		export WORKER_GITHUB_LOGIN="expected-runner"
		_headless_private_workload_enabled() { return 1; }
		_hrw_permission_pending_path() { return 1; }
		_acquire_session_lock() { return 0; }
		_hrw_verify_dispatch_ownership() { printf 'ownership-called\n'; return 1; }
		_register_dispatch_ledger() { return 0; }

		local prepare_status=0
		_cmd_run_prepare "issue-22438" "$worktree_dir" "worker" || prepare_status=$?
		trap - EXIT
		printf 'status=%s reason=%s issue=%s\n' "$prepare_status" \
			"${_WORKER_PRELAUNCH_FAILURE_REASON:-}" "${WORKER_ISSUE_NUMBER:-}"
	)

	if [[ "$output" == *"ownership-called"* && \
		"$output" == *"status=1 reason=${_HRW_REASON_OWNERSHIP_LOST} issue=22438"* ]]; then
		print_result "worker preparation retains ownership fence" 0
		return 0
	fi
	print_result "worker preparation retains ownership fence" 1 \
		"output=${output:-<empty>}"
	return 0
}

test_worker_ownership_loss_terminalizes_without_recovery() {
	local output=""
	output=$(
		_headless_private_workload_enabled() { return 1; }
		_hrw_release_dispatch_claim() { printf 'release=%s\n' "$2"; return 0; }
		_hrw_finish_failed_run() { printf 'unexpected-recovery\n'; return 0; }
		_hrw_record_terminal_outcome() { printf 'outcome=%s:%s\n' "$2" "$3"; return 0; }
		_emit_worker_runtime_event() { return 0; }
		_hrw_record_reconciled_outcome() { return 0; }
		_hrw_finish_cleanup() { printf 'cleanup=%s\n' "$2"; return 0; }
		_run_failure_reason="$_HRW_REASON_OWNERSHIP_LOST"
		_run_result_label="$_HRW_REASON_OWNERSHIP_LOST"
		_cmd_run_finish "issue-22438" "$_HRW_STATUS_FAIL" "${TEST_ROOT}/ownership-worktree"
	)

	if [[ "$output" == *"release=${_HRW_REASON_OWNERSHIP_LOST}"* && \
		"$output" == *"outcome=${_HRW_TELEMETRY_FAILED}:${_HRW_REASON_OWNERSHIP_LOST}"* && \
		"$output" == *"cleanup=${_HRW_STATUS_FAIL}"* && "$output" != *"unexpected-recovery"* ]]; then
		print_result "ownership loss terminalizes lease without worker recovery" 0
		return 0
	fi
	print_result "ownership loss terminalizes lease without worker recovery" 1 "output=${output:-<empty>}"
	return 0
}

test_runtime_launch_marker_precedes_invocation() {
	local marker_file="${TEST_ROOT}/runtime-launch-marker.log"
	_WORKER_RUNTIME_LAUNCH_STARTED=0
	_hrw_mark_runtime_launch_started "issue-28060" "opencode" >"$marker_file" 2>&1
	local output=""
	output=$(<"$marker_file")

	local ownership_line="" marker_line="" invoke_line=""
	# shellcheck disable=SC2016 # Match the literal caller variables in source.
	ownership_line=$(grep -n '"$role" == "worker".*_hrw_verify_dispatch_ownership' "$HELPER_SCRIPT" | cut -d: -f1)
	# shellcheck disable=SC2016 # Match the literal caller variables in source.
	marker_line=$(grep -n '_hrw_mark_runtime_launch_started "$session_key" "$runtime"' "$HELPER_SCRIPT" | cut -d: -f1)
	invoke_line=$(grep -n 'claude) _invoke_claude' "$HELPER_SCRIPT" | cut -d: -f1)
	if [[ "$_WORKER_RUNTIME_LAUNCH_STARTED" -eq 1 && "$output" == *"pre_runtime_launch session=issue-28060 runtime=opencode"* &&
		"$ownership_line" =~ ^[0-9]+$ && "$marker_line" =~ ^[0-9]+$ && "$invoke_line" =~ ^[0-9]+$ &&
		"$ownership_line" -lt "$marker_line" && "$marker_line" -lt "$invoke_line" ]]; then
		print_result "runtime launch marker is emitted immediately before invocation" 0
	else
		print_result "runtime launch marker is emitted immediately before invocation" 1 \
			"started=$_WORKER_RUNTIME_LAUNCH_STARTED ownership_line=$ownership_line marker_line=$marker_line invoke_line=$invoke_line output=$output"
	fi
	_WORKER_RUNTIME_LAUNCH_STARTED=0
	return 0
}

test_clean_prelaunch_exit_is_precise_nonzero_failure() {
	local output="" status=0
	set +e
	output=$(
		(
			print_info() { printf '%s\n' "$*"; return 0; }
			print_warning() { printf '%s\n' "$*"; return 0; }
			_push_wip_commits_on_exit() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_cleanup_headless_runtime_temp_paths() { return 0; }
			_release_dispatch_claim() { return 0; }
			_release_session_lock() { return 0; }
			_update_dispatch_ledger() { return 0; }
			_WORKER_RUNTIME_LAUNCH_STARTED=0
			_WORKER_START_EPOCH_MS=0
			AIDEVOPS_DISPATCH_LEASE_TOKEN=""
			trap "_exit_trap_handler 'issue-28060'" EXIT
			exit 0
		)
	) || status=$?
	set -e

	if [[ "$status" -eq 1 && "$output" == *"reason=worker_runtime_not_invoked"* &&
		"$output" != *"worker_noop_zero_output"* ]] &&
		_worker_failure_reason_is_launch_preflight "worker_runtime_not_invoked"; then
		print_result "clean exit before runtime invocation is a precise non-zero prelaunch failure" 0
		return 0
	fi
	print_result "clean exit before runtime invocation is a precise non-zero prelaunch failure" 1 \
		"status=$status output=$output"
	return 0
}

test_deleted_cwd_recovery_uses_worker_worktree() {
	local worktree_dir="${TEST_ROOT}/deleted-cwd-worktree"
	local stale_dir="${TEST_ROOT}/deleted-cwd-stale"
	local output=""
	local status=0
	mkdir -p "$worktree_dir" "$stale_dir"
	export WORKER_WORKTREE_PATH="$worktree_dir"

	set +e
	output=$(
		cd "$stale_dir" || exit 20
		rmdir "$stale_dir" || exit 21
		_recover_deleted_cwd_before_launch "$TEST_ROOT" "test" 2>&1 || exit $?
		pwd -P
	)
	status=$?
	set -e

	unset WORKER_WORKTREE_PATH 2>/dev/null || true
	if [[ "$status" -eq 0 && "$output" == *"recovered_deleted_cwd"* && "$output" == *"$worktree_dir"* ]]; then
		print_result "deleted cwd recovery cd's to worker worktree before launch" 0
		return 0
	fi

	print_result "deleted cwd recovery cd's to worker worktree before launch" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_cmd_run_aborts_issue_worker_before_canary_when_env_missing() {
	unset WORKER_ISSUE_NUMBER WORKER_WORKTREE_PATH 2>/dev/null || true
	local canary_called=0
	_run_canary_test() { canary_called=1; return 0; }

	local output=""
	local status=0
	output=$(cmd_run \
		--role worker \
		--session-key issue-22438 \
		--dir "$TEST_ROOT" \
		--title "Issue #22438: env contract" \
		--prompt "/full-loop Implement issue #22438" 2>&1) || status=$?

	unset -f _run_canary_test 2>/dev/null || true
	if [[ "$status" -ne 0 && "$canary_called" -eq 0 && "$output" == *"WORKER_ISSUE_NUMBER unset"* ]]; then
		print_result "cmd_run aborts issue worker before canary when env missing" 0
		return 0
	fi

	print_result "cmd_run aborts issue worker before canary when env missing" 1 \
		"status=$status canary_called=$canary_called output=${output:-<empty>}"
	return 0
}

test_cmd_run_preserves_worker_origin_overrides_before_canary() {
	local worktree_dir="${TEST_ROOT}/origin-override-worktree"
	local AIDEVOPS_DISPATCH_LEASE_TOKEN=""
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER=23558
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_WORKTREE_PATH="$worktree_dir"
	export AIDEVOPS_SESSION_ORIGIN=interactive
	export AIDEVOPS_HEADLESS=already-set

	choose_model() { printf '%s' 'openai/gpt-5.5'; return 0; }
	_enforce_opencode_version_pin() { return 0; }
	_run_canary_test() {
		if [[ "${AIDEVOPS_SESSION_ORIGIN:-}" == "interactive" && "${AIDEVOPS_HEADLESS:-}" == "already-set" ]]; then
			printf '%s\n' 'canary_saw_origin_overrides'
		fi
		return 1
	}

	local output=""
	local status=0
	output=$(cmd_run \
		--role worker \
		--session-key issue-23558 \
		--dir "$worktree_dir" \
		--title "Issue #23558: origin overrides" \
		--prompt "/full-loop Implement issue #23558" 2>&1) || status=$?

	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH AIDEVOPS_SESSION_ORIGIN AIDEVOPS_HEADLESS 2>/dev/null || true
	unset -f choose_model _enforce_opencode_version_pin _run_canary_test 2>/dev/null || true
	if [[ "$status" -eq 1 && "$output" == *"canary_saw_origin_overrides"* && "$output" == *"Canary failed"* ]]; then
		print_result "cmd_run preserves worker origin env overrides before canary" 0
		return 0
	fi

	print_result "cmd_run preserves worker origin env overrides before canary" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}

test_cmd_run_aborts_before_canary_when_opencode_pin_repair_fails() {
	local worktree_dir="${TEST_ROOT}/pin-repair-failure-worktree"
	local canary_marker="${TEST_ROOT}/pin-repair-failure-canary"
	local AIDEVOPS_DISPATCH_LEASE_TOKEN=""
	local output=""
	local status=0
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	export WORKER_ISSUE_NUMBER=28847
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_WORKTREE_PATH="$worktree_dir"

	choose_model() { printf '%s' 'openai/gpt-5.5'; return 0; }
	_enforce_opencode_version_pin() {
		printf '%s\n' 'pin_repair_failed'
		return 1
	}
	_run_canary_test() {
		: >"$canary_marker"
		return 0
	}

	output=$(cmd_run \
		--role worker \
		--session-key issue-28847 \
		--dir "$worktree_dir" \
		--title "Issue #28847: OpenCode pin repair" \
		--prompt "/full-loop Implement issue #28847" 2>&1) || status=$?

	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH 2>/dev/null || true
	unset -f choose_model _enforce_opencode_version_pin _run_canary_test 2>/dev/null || true
	if [[ "$status" -eq 1 && "$output" == *"pin_repair_failed"* && \
		"$output" == *"version pin enforcement failed"* && ! -e "$canary_marker" ]]; then
		print_result "cmd_run fails closed before canary when OpenCode pin repair fails" 0
		return 0
	fi

	print_result "cmd_run fails closed before canary when OpenCode pin repair fails" 1 \
		"status=$status canary_called=$([[ -e "$canary_marker" ]] && printf y || printf n) output=${output:-<empty>}"
	return 0
}

test_cmd_canary_propagates_opencode_pin_repair_failure() {
	local canary_marker="${TEST_ROOT}/pin-repair-failure-direct-canary"
	local output=""
	local status=0
	choose_model() { printf '%s' 'openai/gpt-5.5'; return 0; }
	_enforce_opencode_version_pin() {
		printf '%s\n' 'direct_pin_repair_failed'
		return 7
	}
	_run_canary_test() {
		: >"$canary_marker"
		return 0
	}

	output=$(cmd_canary --role worker --model openai/gpt-5.5 2>&1) || status=$?
	unset -f choose_model _enforce_opencode_version_pin _run_canary_test 2>/dev/null || true
	if [[ "$status" -eq 7 && "$output" == *"direct_pin_repair_failed"* && ! -e "$canary_marker" ]]; then
		print_result "cmd_canary propagates OpenCode pin repair failure" 0
		return 0
	fi

	print_result "cmd_canary propagates OpenCode pin repair failure" 1 \
		"status=$status canary_called=$([[ -e "$canary_marker" ]] && printf y || printf n) output=${output:-<empty>}"
	return 0
}

test_cmd_run_clears_triage_worker_authority_and_skips_generic_canary() {
	local worktree_dir="${TEST_ROOT}/triage-authority-order"
	local authority_log="${TEST_ROOT}/triage-authority-order.log"
	mkdir -p "$worktree_dir"
	init_git_worktree "$worktree_dir"
	: >"$authority_log"
	export WORKER_ISSUE_NUMBER="28705"
	export WORKER_REPO_SLUG="owner/repo"
	export WORKER_WORKTREE_PATH="$worktree_dir"
	export WORKER_GITHUB_LOGIN="stale-runner"
	export DISPATCH_REPO_SLUG="owner/repo"
	export AIDEVOPS_DISPATCH_LEASE_TOKEN="stale-lease"
	export AIDEVOPS_WORKER_ID="stale-worker"

	choose_model() {
		printf 'model=%s|%s|%s|%s|%s|%s|%s\n' \
			"${WORKER_ISSUE_NUMBER:-}" "${WORKER_REPO_SLUG:-}" \
			"${WORKER_WORKTREE_PATH:-}" "${WORKER_GITHUB_LOGIN:-}" \
			"${DISPATCH_REPO_SLUG:-}" "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" \
			"${AIDEVOPS_WORKER_ID:-}" >>"$authority_log"
		printf '%s' 'openai/gpt-5.5'
		return 0
	}
	_enforce_opencode_version_pin() { return 0; }
	_run_canary_test() {
		printf 'canary=%s|%s|%s|%s|%s|%s|%s\n' \
			"${WORKER_ISSUE_NUMBER:-}" "${WORKER_REPO_SLUG:-}" \
			"${WORKER_WORKTREE_PATH:-}" "${WORKER_GITHUB_LOGIN:-}" \
			"${DISPATCH_REPO_SLUG:-}" "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" \
			"${AIDEVOPS_WORKER_ID:-}" >>"$authority_log"
		return 1
	}
	_prepare_triage_runtime_directory() {
		local result_var="$1"
		: "$result_var"
		printf '%s\n' 'triage_runtime_prepare_called' >>"$authority_log"
		return 1
	}

	local output=""
	local status=0
	output=$(cmd_run \
		--role triage \
		--session-key triage-review-28705 \
		--dir "$worktree_dir" \
		--title "Sandboxed triage review: Issue #28705" \
		--prompt "Review prefetched issue context" 2>&1) || status=$?

	unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH \
		WORKER_GITHUB_LOGIN DISPATCH_REPO_SLUG AIDEVOPS_DISPATCH_LEASE_TOKEN \
		AIDEVOPS_WORKER_ID 2>/dev/null || true
	unset -f choose_model _enforce_opencode_version_pin _run_canary_test \
		_prepare_triage_runtime_directory 2>/dev/null || true
	if [[ "$status" -eq 1 ]] && \
		grep -qx 'model=||||||' "$authority_log" && \
		! grep -q '^canary=' "$authority_log" && \
		grep -qx 'triage_runtime_prepare_called' "$authority_log" && \
		[[ "$output" == *"generic_canary_skipped"* ]] && \
		[[ "$output" == *"Public triage runtime isolation setup failed"* ]]; then
		print_result "cmd_run clears triage worker authority and skips generic canary" 0
		return 0
	fi

	print_result "cmd_run clears triage worker authority and skips generic canary" 1 \
		"status=$status observations=$(<"$authority_log") output=${output:-<empty>}"
	return 0
}

test_deleted_launch_cwd_recovers_to_work_dir() {
	local stale_dir="${TEST_ROOT}/stale-cwd"
	local worktree_dir="${TEST_ROOT}/worker-worktree"
	mkdir -p "$stale_dir" "$worktree_dir"

	local output=""
	local status=0
	output=$(
		cd "$stale_dir" || exit 1
		rmdir "$stale_dir" || exit 1
		_ensure_valid_launch_cwd "$worktree_dir" || exit $?
		pwd -P
	) 2>&1 || status=$?

	if [[ "$status" -eq 0 && "$output" == *"$worktree_dir"* ]]; then
		print_result "deleted launch cwd recovers to worker worktree before runtime startup" 0
		return 0
	fi

	print_result "deleted launch cwd recovers to worker worktree before runtime startup" 1 \
		"status=$status output=${output:-<empty>}"
	return 0
}
