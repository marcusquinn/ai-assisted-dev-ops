#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-registry-session-claim.sh — GH#26950 regression guard.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REGISTRY_LIB="${SCRIPT_DIR}/../shared-worktree-registry.sh"
TEST_ROOT=$(mktemp -d)
WORKTREE_REGISTRY_DIR="${TEST_ROOT}/registry"
WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
export WORKTREE_REGISTRY_DIR WORKTREE_REGISTRY_DB

TESTS_RUN=0
TESTS_FAILED=0
OWNER_PID=""
CLAIM_PID=""

cleanup() {
	[[ -n "$OWNER_PID" ]] && kill "$OWNER_PID" >/dev/null 2>&1 || true
	[[ -n "$CLAIM_PID" ]] && kill "$CLAIM_PID" >/dev/null 2>&1 || true
	wait "$OWNER_PID" "$CLAIM_PID" 2>/dev/null || true
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

# shellcheck source=../shared-worktree-registry.sh
source "$REGISTRY_LIB"

print_result() {
	local name="$1"
	local rc="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

start_live_pids() {
	sleep 30 &
	OWNER_PID=$!
	sleep 30 &
	CLAIM_PID=$!
	return 0
}

reset_registry() {
	rm -rf "$WORKTREE_REGISTRY_DIR"
	return 0
}

owner_info() {
	local wt_path="$1"
	check_worktree_owner "$wt_path" 2>/dev/null || true
	return 0
}

create_linked_worktree_fixture() {
	local canonical_path="$1"
	local linked_path="$2"
	local branch="$3"

	mkdir -p "$canonical_path"
	/usr/bin/git -C "$canonical_path" init -q -b main || return 1
	/usr/bin/git -C "$canonical_path" config user.name Test || return 1
	/usr/bin/git -C "$canonical_path" config user.email test@example.invalid || return 1
	/usr/bin/git -C "$canonical_path" config commit.gpgsign false || return 1
	printf 'seed\n' >"${canonical_path}/README.md" || return 1
	/usr/bin/git -C "$canonical_path" add README.md || return 1
	/usr/bin/git -C "$canonical_path" commit -q -m seed || return 1
	/usr/bin/git -C "$canonical_path" worktree add -q -b "$branch" "$linked_path" || return 1
	return 0
}

test_same_opencode_session_rolls_owner_pid() {
	local wt_path="${TEST_ROOT}/same-session"
	mkdir -p "$wt_path"
	export OPENCODE_SESSION_ID="ses_same_session"
	register_worktree "$wt_path" "feature/same-session" --owner-pid "$OWNER_PID" --session "$OPENCODE_SESSION_ID"

	local rc=0
	claim_worktree_ownership "$wt_path" "feature/same-session" --owner-pid "$CLAIM_PID" --session "$OPENCODE_SESSION_ID" || rc=1
	[[ "$(owner_info "$wt_path")" == "${CLAIM_PID}|${OPENCODE_SESSION_ID}|"* ]] || rc=1
	print_result "same trusted OpenCode session rolls owner PID" "$rc"
	return 0
}

test_parameterized_claim_preserves_metacharacters() {
	reset_registry
	local wt_path="${TEST_ROOT}/quote-'|worktree"
	local session_id="ses_quote_'|session"
	mkdir -p "$wt_path"
	export OPENCODE_SESSION_ID="$session_id"
	register_worktree "$wt_path" "feature/original" --owner-pid "$OWNER_PID" --session "$session_id"

	local rc=0
	claim_worktree_ownership "$wt_path" "feature/quote-'branch" --owner-pid "$CLAIM_PID" \
		--session "$session_id" --batch "batch-'value" --task "task-'value" || rc=1
	local registry_path=""
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	local stored_metadata=""
	stored_metadata=$(
		python3 - "$WORKTREE_REGISTRY_DB" "$registry_path" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute(
        """SELECT branch, owner_session, owner_batch, task_id
           FROM worktree_owners WHERE worktree_path = ?""",
        (sys.argv[2],),
    ).fetchone()
print("|".join(row) if row else "")
PY
	) || rc=1
	[[ "$stored_metadata" == "feature/quote-'branch|${session_id}|batch-'value|task-'value" ]] || rc=1
	print_result "parameterized claim preserves SQL metacharacters" "$rc"
	return 0
}

test_legacy_equivalent_registry_path_resolves() {
	reset_registry
	local real_path="${TEST_ROOT}/legacy-real-path"
	local legacy_path="${TEST_ROOT}/legacy-symlink-path"
	local resolved_path=""
	local rc=0
	mkdir -p "$real_path"
	ln -s "$real_path" "$legacy_path"
	_init_registry_db
	sqlite3 "$WORKTREE_REGISTRY_DB" "
		INSERT INTO worktree_owners (worktree_path, branch, owner_pid)
		VALUES ('$(_wt_sql_escape "$legacy_path")', 'feature/legacy-equivalent-path', ${OWNER_PID});
	"

	resolved_path=$(_wt_registry_lookup_path "$real_path") || rc=1
	[[ "$resolved_path" == "$legacy_path" ]] || rc=1
	print_result "legacy equivalent registry path resolves through batched normalization" "$rc"
	return 0
}

test_different_session_stays_blocked() {
	reset_registry
	local wt_path="${TEST_ROOT}/different-session"
	mkdir -p "$wt_path"
	register_worktree "$wt_path" "feature/different-session" --owner-pid "$OWNER_PID" --session "ses_original"
	export OPENCODE_SESSION_ID="ses_other"

	local rc=0
	if claim_worktree_ownership "$wt_path" "feature/different-session" --owner-pid "$CLAIM_PID" --session "$OPENCODE_SESSION_ID"; then
		rc=1
	fi
	[[ "$(owner_info "$wt_path")" == "${OWNER_PID}|ses_original|"* ]] || rc=1
	print_result "different live session remains blocked" "$rc"
	return 0
}

test_empty_session_cannot_roll_owner_pid() {
	reset_registry
	local wt_path="${TEST_ROOT}/empty-session"
	mkdir -p "$wt_path"
	unset OPENCODE_SESSION_ID
	register_worktree "$wt_path" "feature/empty-session" --owner-pid "$OWNER_PID" --session ""

	local rc=0
	if claim_worktree_ownership "$wt_path" "feature/empty-session" --owner-pid "$CLAIM_PID" --session ""; then
		rc=1
	fi
	[[ "$(owner_info "$wt_path")" == "${OWNER_PID}||"* ]] || rc=1
	print_result "empty session cannot bypass live owner" "$rc"
	return 0
}

test_untrusted_session_cannot_roll_owner_pid() {
	reset_registry
	local wt_path="${TEST_ROOT}/untrusted-session"
	mkdir -p "$wt_path"
	register_worktree "$wt_path" "feature/untrusted-session" --owner-pid "$OWNER_PID" --session "caller-supplied"
	unset OPENCODE_SESSION_ID

	local rc=0
	if claim_worktree_ownership "$wt_path" "feature/untrusted-session" --owner-pid "$CLAIM_PID" --session "caller-supplied"; then
		rc=1
	fi
	[[ "$(owner_info "$wt_path")" == "${OWNER_PID}|caller-supplied|"* ]] || rc=1
	print_result "untrusted session cannot bypass live owner" "$rc"
	return 0
}

test_canonical_paths_are_purged_without_signalling_live_owner() {
	reset_registry
	local canonical_path="${TEST_ROOT}/canonical"
	local linked_path="${TEST_ROOT}/linked"
	mkdir -p "$canonical_path"
	/usr/bin/git -C "$canonical_path" init -q -b develop
	/usr/bin/git -C "$canonical_path" config user.name Test
	/usr/bin/git -C "$canonical_path" config user.email test@example.invalid
	/usr/bin/git -C "$canonical_path" config commit.gpgsign false
	printf 'seed\n' >"${canonical_path}/README.md"
	/usr/bin/git -C "$canonical_path" add README.md
	/usr/bin/git -C "$canonical_path" commit -q -m seed
	/usr/bin/git -C "$canonical_path" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
	/usr/bin/git -C "$canonical_path" worktree add -q -b feature/linked "$linked_path"

	_init_registry_db
	sqlite3 "$WORKTREE_REGISTRY_DB" "
		INSERT OR REPLACE INTO worktree_owners
			(worktree_path, branch, owner_pid, owner_session)
		VALUES ('$canonical_path', 'develop', $OWNER_PID, 'ses_invalid_canonical');
	"

	local rc=0
	if claim_worktree_ownership "$canonical_path" develop --owner-pid "$CLAIM_PID" --session ses_claim; then
		rc=1
	fi
	local canonical_rows=""
	canonical_rows=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = '$canonical_path';")
	[[ "$canonical_rows" == "0" ]] || rc=1
	kill -0 "$OWNER_PID" >/dev/null 2>&1 || rc=1

	sqlite3 "$WORKTREE_REGISTRY_DB" "
		INSERT OR REPLACE INTO worktree_owners
			(worktree_path, branch, owner_pid, owner_session, owner_batch, task_id)
		VALUES ('$canonical_path', 'develop', $OWNER_PID, 'prior-worker', 'generation-7', '22438');
	"
	local canonical_owner="" expected_pid="" expected_session="" expected_batch=""
	local expected_task="" expected_created_at=""
	canonical_owner=$(owner_info "$canonical_path")
	IFS='|' read -r expected_pid expected_session expected_batch expected_task expected_created_at <<<"$canonical_owner"
	if transfer_worktree_ownership_if_expected "$canonical_path" develop \
		--owner-pid "$CLAIM_PID" --session continuation-worker --batch generation-8 --task 22438 \
		--expected-owner-pid "$expected_pid" --expected-session "$expected_session" \
		--expected-batch "$expected_batch" --expected-task "$expected_task" \
		--expected-created-at "$expected_created_at"; then
		rc=1
	fi
	canonical_rows=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = '$canonical_path';")
	[[ "$canonical_rows" == "0" ]] || rc=1
	kill -0 "$OWNER_PID" >/dev/null 2>&1 || rc=1

	export OPENCODE_SESSION_ID="ses_linked_owner"
	claim_worktree_ownership "$linked_path" feature/linked --owner-pid "$CLAIM_PID" --session "$OPENCODE_SESSION_ID" || rc=1
	[[ "$(owner_info "$linked_path")" == "${CLAIM_PID}|${OPENCODE_SESSION_ID}|"* ]] || rc=1
	print_result "canonical rows are purged without signalling live PIDs while linked ownership works" "$rc"
	return 0
}

test_expected_owner_transfer_is_atomic() {
	reset_registry
	local wt_path="${TEST_ROOT}/expected-transfer"
	mkdir -p "$wt_path"
	register_worktree "$wt_path" "feature/expected-transfer" --owner-pid "$OWNER_PID" \
		--session "prior-worker" --batch "generation-7" --task "22438"

	local current_owner="" expected_pid="" expected_session="" expected_batch=""
	local expected_task="" expected_created_at=""
	current_owner=$(owner_info "$wt_path")
	IFS='|' read -r expected_pid expected_session expected_batch expected_task expected_created_at <<<"$current_owner"

	local rc=0
	transfer_worktree_ownership_if_expected "$wt_path" "feature/expected-transfer" \
		--owner-pid "$CLAIM_PID" --session "continuation-worker" --batch "generation-8" --task "22438" \
		--expected-owner-pid "$expected_pid" --expected-session "$expected_session" \
		--expected-batch "$expected_batch" --expected-task "$expected_task" \
		--expected-created-at "$expected_created_at" || rc=1
	[[ "$(owner_info "$wt_path")" == "${CLAIM_PID}|continuation-worker|generation-8|22438|"* ]] || rc=1
	print_result "exact expected owner transfers atomically" "$rc"
	return 0
}

test_expected_owner_transfer_rejects_concurrent_mutation() {
	reset_registry
	local wt_path="${TEST_ROOT}/concurrent-transfer"
	mkdir -p "$wt_path"
	register_worktree "$wt_path" "feature/concurrent-transfer" --owner-pid "$OWNER_PID" \
		--session "prior-worker" --batch "generation-7" --task "22438"

	local captured_owner="" expected_pid="" expected_session="" expected_batch=""
	local expected_task="" expected_created_at=""
	captured_owner=$(owner_info "$wt_path")
	IFS='|' read -r expected_pid expected_session expected_batch expected_task expected_created_at <<<"$captured_owner"

	register_worktree "$wt_path" "feature/concurrent-transfer" --owner-pid "$CLAIM_PID" \
		--session "competing-worker" --batch "generation-8" --task "22438"
	local rc=0
	if transfer_worktree_ownership_if_expected "$wt_path" "feature/concurrent-transfer" \
		--owner-pid "$OWNER_PID" --session "late-worker" --batch "generation-9" --task "22438" \
		--expected-owner-pid "$expected_pid" --expected-session "$expected_session" \
		--expected-batch "$expected_batch" --expected-task "$expected_task" \
		--expected-created-at "$expected_created_at"; then
		rc=1
	fi
	[[ "$(owner_info "$wt_path")" == "${CLAIM_PID}|competing-worker|generation-8|22438|"* ]] || rc=1
	print_result "expected-owner transfer rejects concurrent registry mutation" "$rc"
	return 0
}

test_expected_owner_transfer_rejects_missing_option_value_cleanly() {
	reset_registry
	local wt_path="${TEST_ROOT}/missing-option-value"
	mkdir -p "$wt_path"

	local output="" status=0 rc=0
	output=$(transfer_worktree_ownership_if_expected "$wt_path" "feature/missing-option-value" \
		--task 2>&1) || status=$?
	if [[ "$status" -eq 0 || "$output" == *"shift count out of range"* ]]; then
		rc=1
	fi
	print_result "expected-owner transfer rejects a missing option value cleanly" "$rc"
	return 0
}

test_owner_contract_removal_is_atomic() {
	reset_registry
	local canonical_path="${TEST_ROOT}/atomic-remove-canonical"
	local linked_path="${TEST_ROOT}/atomic-remove-linked"
	local branch="feature/atomic-remove"
	create_linked_worktree_fixture "$canonical_path" "$linked_path" "$branch" || return 1
	register_worktree "$linked_path" "$branch" --owner-pid "$OWNER_PID" \
		--session "created-owner" --batch "" --task ""

	local captured_owner="" expected_pid="" expected_session="" expected_batch=""
	local expected_task="" expected_created_at=""
	captured_owner=$(owner_info "$linked_path")
	IFS='|' read -r expected_pid expected_session expected_batch expected_task expected_created_at <<<"$captured_owner"
	local rc=0
	remove_worktree_if_owner_contract "$linked_path" "$canonical_path" "$branch" \
		"$expected_pid" "$expected_session" "$expected_batch" "$expected_task" \
		"$expected_created_at" || rc=1
	[[ ! -e "$linked_path" ]] || rc=1
	if check_worktree_owner "$linked_path" >/dev/null 2>&1; then
		rc=1
	fi
	print_result "exact owner-contract removal retires worktree and registration atomically" "$rc"
	return 0
}

test_owner_contract_removal_rejects_concurrent_transfer() {
	reset_registry
	local canonical_path="${TEST_ROOT}/atomic-race-canonical"
	local linked_path="${TEST_ROOT}/atomic-race-linked"
	local branch="feature/atomic-race"
	create_linked_worktree_fixture "$canonical_path" "$linked_path" "$branch" || return 1
	register_worktree "$linked_path" "$branch" --owner-pid "$OWNER_PID" \
		--session "created-owner" --batch "" --task ""

	local captured_owner="" expected_pid="" expected_session="" expected_batch=""
	local expected_task="" expected_created_at=""
	captured_owner=$(owner_info "$linked_path")
	IFS='|' read -r expected_pid expected_session expected_batch expected_task expected_created_at <<<"$captured_owner"
	register_worktree "$linked_path" "$branch" --owner-pid "$CLAIM_PID" \
		--session "replacement-owner" --batch "replacement" --task ""
	local rc=0
	if remove_worktree_if_owner_contract "$linked_path" "$canonical_path" "$branch" \
		"$expected_pid" "$expected_session" "$expected_batch" "$expected_task" \
		"$expected_created_at"; then
		rc=1
	fi
	[[ -d "$linked_path" ]] || rc=1
	[[ "$(owner_info "$linked_path")" == "${CLAIM_PID}|replacement-owner|replacement||"* ]] || rc=1
	print_result "owner-contract removal preserves a concurrently transferred worktree" "$rc"
	return 0
}

main() {
	start_live_pids
	test_same_opencode_session_rolls_owner_pid
	test_parameterized_claim_preserves_metacharacters
	test_legacy_equivalent_registry_path_resolves
	test_different_session_stays_blocked
	test_empty_session_cannot_roll_owner_pid
	test_untrusted_session_cannot_roll_owner_pid
	test_canonical_paths_are_purged_without_signalling_live_owner
	test_expected_owner_transfer_is_atomic
	test_expected_owner_transfer_rejects_concurrent_mutation
	test_expected_owner_transfer_rejects_missing_option_value_cleanly
	test_owner_contract_removal_is_atomic
	test_owner_contract_removal_rejects_concurrent_transfer
	printf 'Results: %s/%s passed, %s failed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] && return 0
	return 1
}

main "$@"
