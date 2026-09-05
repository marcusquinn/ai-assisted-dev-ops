#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../pre-edit-check.sh"
GIT_BIN="$(command -p -v git)"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
TEST_REGISTRY_DIR=""
TEST_REGISTRY_DB=""
TEST_WORKTREE_BASE=""
COLLISION_TASK=""
COLLISION_ORIGINAL_BRANCH=""
COLLISION_ORIGINAL_SHA=""
COLLISION_ADVANCED_SHA=""
COLLISION_TARGET_TREE=""
COLLISION_FRESH_PATH=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_repo() {
	TEST_ROOT=$(mktemp -d)
	TEST_WORKTREE_BASE="$(dirname "$TEST_ROOT")/$(basename "$TEST_ROOT")-worktrees"
	TEST_REGISTRY_DIR="${TEST_ROOT}/.registry"
	TEST_REGISTRY_DB="${TEST_REGISTRY_DIR}/worktree-registry.db"
	"$GIT_BIN" -C "$TEST_ROOT" init -b main >/dev/null 2>&1 || {
		"$GIT_BIN" -C "$TEST_ROOT" init >/dev/null 2>&1
		"$GIT_BIN" -C "$TEST_ROOT" checkout -b main >/dev/null 2>&1
	}
	"$GIT_BIN" -C "$TEST_ROOT" config user.name "Aidevops Test"
	"$GIT_BIN" -C "$TEST_ROOT" config user.email "test@example.com"
	"$GIT_BIN" -C "$TEST_ROOT" config core.hooksPath /dev/null
	"$GIT_BIN" -C "$TEST_ROOT" config commit.gpgsign false
	printf 'test\n' >"${TEST_ROOT}/README.md"
	"$GIT_BIN" -C "$TEST_ROOT" add README.md
	"$GIT_BIN" -C "$TEST_ROOT" commit -m "test: seed repo" >/dev/null 2>&1
	return 0
}

teardown_test_repo() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	if [[ -n "$TEST_WORKTREE_BASE" && -d "$TEST_WORKTREE_BASE" ]]; then
		rm -rf "$TEST_WORKTREE_BASE"
	fi
	return 0
}

run_helper() {
	local target_dir="$1"
	shift
	(
		cd "$target_dir" || exit 1
		AIDEVOPS_WORKTREE_BASE_DIR="$TEST_WORKTREE_BASE" \
			WORKTREE_REGISTRY_DIR="$TEST_REGISTRY_DIR" \
			WORKTREE_REGISTRY_DB="$TEST_REGISTRY_DB" \
			"$HELPER" "$@"
	)
	return $?
}

ensure_registry_schema() {
	mkdir -p "$TEST_REGISTRY_DIR"
	sqlite3 "$TEST_REGISTRY_DB" "
        CREATE TABLE IF NOT EXISTS worktree_owners (
            worktree_path TEXT PRIMARY KEY,
            branch        TEXT,
            owner_pid     INTEGER,
            owner_session TEXT DEFAULT '',
            owner_batch   TEXT DEFAULT '',
            task_id       TEXT DEFAULT '',
            created_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
    " >/dev/null 2>&1
	return 0
}

test_blocks_headless_edits_on_main_with_worktree_guidance() {
	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"canonical checkouts are read-only session mirrors"* ]] && [[ "$output" == *"CANONICAL_WORKTREE=true"* ]] && [[ "$output" == *"ACTION_REQUIRED=create_or_use_linked_worktree"* ]]; then
		print_result "blocks headless edits on main with worktree guidance" 0
		return 0
	fi

	print_result "blocks headless edits on main with worktree guidance" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_allows_linked_worktree_edits() {
	local worktree_path="${TEST_ROOT}/linked-worktree"
	"$GIT_BIN" -C "$TEST_ROOT" worktree add "$worktree_path" -b bugfix/test-linked-worktree >/dev/null 2>&1

	local output=""
	local exit_code=0
	output=$(run_helper "$worktree_path" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 0 ]] && [[ "$output" == *"OK"* ]] && [[ "$output" == *"In linked worktree on ref: "* ]]; then
		print_result "allows edits from linked worktree paths" 0
		return 0
	fi

	print_result "allows edits from linked worktree paths" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_namespaced_task_assignee_lookup() {
	local task_id="to01j2abc3def4gh5jkm6npq7rst-42.3"
	printf '%s\n' "- [ ] ${task_id} Namespaced assignee fixture assignee:other@example" >"${TEST_ROOT}/TODO.md"
	"$GIT_BIN" -C "$TEST_ROOT" add TODO.md
	"$GIT_BIN" -C "$TEST_ROOT" commit -m "test: add namespaced assignee fixture" >/dev/null 2>&1
	local worktree_path="${TEST_ROOT}/namespaced-assignee-worktree"
	"$GIT_BIN" -C "$TEST_ROOT" worktree add "$worktree_path" -b "feature/${task_id}-migration" >/dev/null 2>&1

	local output=""
	local exit_code=0
	output=$(AIDEVOPS_IDENTITY="me@example" run_helper "$worktree_path" 2>&1) || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] && [[ "$output" == *"Task ${task_id} is claimed by assignee:other@example"* ]]; then
		print_result "preserves namespaced task ID in assignee lookup" 0
		return 0
	fi

	print_result "preserves namespaced task ID in assignee lookup" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_malformed_task_assignee_fails_closed() {
	printf '%s\n' "- [ ] t7 Prefix task assignee:other@example" >>"${TEST_ROOT}/TODO.md"
	"$GIT_BIN" -C "$TEST_ROOT" add TODO.md
	"$GIT_BIN" -C "$TEST_ROOT" commit -m "test: add malformed-prefix fixture" >/dev/null 2>&1
	local worktree_path="${TEST_ROOT}/malformed-assignee-worktree"
	"$GIT_BIN" -C "$TEST_ROOT" worktree add "$worktree_path" -b "feature/t7.0-malformed" >/dev/null 2>&1

	local output=""
	local exit_code=0
	output=$(AIDEVOPS_IDENTITY="me@example" run_helper "$worktree_path" 2>&1) || exit_code=$?
	if [[ "$exit_code" -eq 0 ]] && [[ "$output" != *"Task t7 is claimed"* ]]; then
		print_result "malformed task-like branch does not match valid prefix assignee" 0
		return 0
	fi

	print_result "malformed task-like branch does not match valid prefix assignee" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_worker_env_does_not_bypass_canonical_guard() {
	local output=""
	local exit_code=0
	output=$(WORKER_WORKTREE_PATH="$TEST_ROOT" WORKER_WORKTREE_BRANCH="forged/worker" \
		FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"CANONICAL_WORKTREE=true"* ]] && [[ "$output" == *"ACTION_REQUIRED=create_or_use_linked_worktree"* ]]; then
		print_result "worker environment cannot bypass canonical worktree guard" 0
		return 0
	fi

	print_result "worker environment cannot bypass canonical worktree guard" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_warns_when_canonical_repo_is_off_main() {
	"$GIT_BIN" -C "$TEST_ROOT" switch -c develop >/dev/null 2>&1
	"$GIT_BIN" -C "$TEST_ROOT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop

	local output=""
	local exit_code=0
	output=$(run_helper "$TEST_ROOT" 2>&1) || exit_code=$?
	local canonical_rows=0
	if [[ -f "$TEST_REGISTRY_DB" ]]; then
		canonical_rows=$(sqlite3 "$TEST_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = '$TEST_ROOT';")
	fi

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"CANONICAL_WORKTREE=true"* ]] && [[ "$output" == *"ACTION_REQUIRED=create_or_use_linked_worktree"* ]] && [[ "$canonical_rows" -eq 0 ]]; then
		print_result "blocks canonical origin-default develop before ownership claim" 0
		return 0
	fi

	print_result "blocks canonical origin-default develop before ownership claim" 1 "exit=${exit_code} rows=${canonical_rows} output=${output}"
	return 0
}

test_blocks_when_linked_worktree_owned_by_another_live_process() {
	local worktree_path="${TEST_ROOT}/owned-worktree"
	"$GIT_BIN" -C "$TEST_ROOT" worktree add "$worktree_path" -b bugfix/owned-worktree >/dev/null 2>&1

	ensure_registry_schema
	sqlite3 "$TEST_REGISTRY_DB" "
        INSERT OR REPLACE INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_session)
        VALUES
            ('$worktree_path',
             'bugfix/owned-worktree',
             $$,
             'other-session');
    " >/dev/null 2>&1

	local output=""
	local exit_code=0
	local claim_pid=""
	sleep 30 >/dev/null 2>&1 &
	claim_pid=$!
	output=$(PRE_EDIT_OWNER_PID="$claim_pid" run_helper "$worktree_path" 2>&1) || exit_code=$?
	kill "$claim_pid" >/dev/null 2>&1 || true
	wait "$claim_pid" 2>/dev/null || true

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"WORKTREE_OWNERSHIP_CONFLICT=true"* ]] && [[ "$output" == *"WORKTREE_OWNER_PID=$$"* ]] && [[ "$output" == *"ACTION_REQUIRED=create_worktree"* ]]; then
		print_result "blocks linked worktree edits when owned by another live process" 0
		return 0
	fi

	print_result "blocks linked worktree edits when owned by another live process" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_allows_headless_child_of_exact_wrapper_owner() {
	local worktree_path="${TEST_ROOT}/wrapper-owned-worktree"
	"$GIT_BIN" -C "$TEST_ROOT" worktree add "$worktree_path" -b bugfix/wrapper-owned-worktree >/dev/null 2>&1

	ensure_registry_schema
	sqlite3 "$TEST_REGISTRY_DB" "
        INSERT OR REPLACE INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_session, task_id)
        VALUES
            ('$worktree_path', 'bugfix/wrapper-owned-worktree', $$, 'issue-28426', '28426');
    " >/dev/null 2>&1

	local output=""
	local exit_code=0
	output=$(AIDEVOPS_SESSION_ORIGIN=worker AIDEVOPS_HEADLESS=true \
		AIDEVOPS_WORKTREE_OWNER_PID="$$" \
		AIDEVOPS_WORKTREE_OWNER_SESSION="issue-28426" \
		AIDEVOPS_WORKTREE_OWNER_TASK="28426" \
		AIDEVOPS_WORKTREE_OWNER_PATH="$worktree_path" \
		PRE_EDIT_OWNER_PID="$BASHPID" run_helper "$worktree_path" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 0 && "$output" == *"OK"* && "$output" != *"WORKTREE_OWNERSHIP_CONFLICT=true"* ]]; then
		print_result "allows headless child of exact live wrapper owner" 0
		return 0
	fi

	print_result "allows headless child of exact live wrapper owner" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_headless_wrapper_owner_proof_fails_closed() {
	local worktree_path="${TEST_ROOT}/wrapper-proof-mismatch-worktree"
	"$GIT_BIN" -C "$TEST_ROOT" worktree add "$worktree_path" -b bugfix/wrapper-proof-mismatch >/dev/null 2>&1

	ensure_registry_schema
	sqlite3 "$TEST_REGISTRY_DB" "
        INSERT OR REPLACE INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_session, task_id)
        VALUES
            ('$worktree_path', 'bugfix/wrapper-proof-mismatch', $$, 'issue-28426', '28426');
    " >/dev/null 2>&1

	local proof_case=""
	local proof_pid=""
	local proof_session=""
	local proof_task=""
	local proof_path=""
	local output=""
	local exit_code=0
	for proof_case in missing mismatched-session mismatched-task mismatched-path non-ancestor-pid; do
		proof_pid="$$"
		proof_session="issue-28426"
		proof_task="28426"
		proof_path="$worktree_path"
		case "$proof_case" in
		missing) proof_pid="" ;;
		mismatched-session) proof_session="issue-99999" ;;
		mismatched-task) proof_task="99999" ;;
		mismatched-path) proof_path="$TEST_ROOT" ;;
		non-ancestor-pid) proof_pid="1" ;;
		esac

		output=""
		exit_code=0
		output=$(AIDEVOPS_SESSION_ORIGIN=worker AIDEVOPS_HEADLESS=true \
			AIDEVOPS_WORKTREE_OWNER_PID="$proof_pid" \
			AIDEVOPS_WORKTREE_OWNER_SESSION="$proof_session" \
			AIDEVOPS_WORKTREE_OWNER_TASK="$proof_task" \
			AIDEVOPS_WORKTREE_OWNER_PATH="$proof_path" \
			PRE_EDIT_OWNER_PID="$BASHPID" run_helper "$worktree_path" 2>&1) || exit_code=$?
		if [[ "$exit_code" -eq 2 && "$output" == *"WORKTREE_OWNERSHIP_CONFLICT=true"* ]]; then
			print_result "headless wrapper proof fails closed: ${proof_case}" 0
		else
			print_result "headless wrapper proof fails closed: ${proof_case}" 1 "exit=${exit_code} output=${output}"
		fi
	done
	return 0
}

test_rejects_forged_proof_for_unrelated_live_owner() {
	local worktree_path="${TEST_ROOT}/unrelated-live-owner-worktree"
	"$GIT_BIN" -C "$TEST_ROOT" worktree add "$worktree_path" -b bugfix/unrelated-live-owner >/dev/null 2>&1

	local unrelated_pid=""
	sleep 30 >/dev/null 2>&1 &
	unrelated_pid=$!
	ensure_registry_schema
	sqlite3 "$TEST_REGISTRY_DB" "
        INSERT OR REPLACE INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_session, task_id)
        VALUES
            ('$worktree_path', 'bugfix/unrelated-live-owner', $unrelated_pid, 'issue-28426', '28426');
    " >/dev/null 2>&1

	local output=""
	local exit_code=0
	output=$(AIDEVOPS_SESSION_ORIGIN=worker AIDEVOPS_HEADLESS=true \
		AIDEVOPS_WORKTREE_OWNER_PID="$unrelated_pid" \
		AIDEVOPS_WORKTREE_OWNER_SESSION="issue-28426" \
		AIDEVOPS_WORKTREE_OWNER_TASK="28426" \
		AIDEVOPS_WORKTREE_OWNER_PATH="$worktree_path" \
		PRE_EDIT_OWNER_PID="$BASHPID" run_helper "$worktree_path" 2>&1) || exit_code=$?
	kill "$unrelated_pid" >/dev/null 2>&1 || true
	wait "$unrelated_pid" 2>/dev/null || true

	if [[ "$exit_code" -eq 2 && "$output" == *"WORKTREE_OWNERSHIP_CONFLICT=true"* ]]; then
		print_result "rejects copied proof for unrelated live owner process" 0
		return 0
	fi

	print_result "rejects copied proof for unrelated live owner process" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_allows_same_opencode_session_pid_rollover() {
	local worktree_path="${TEST_ROOT}/same-session-worktree"
	"$GIT_BIN" -C "$TEST_ROOT" worktree add "$worktree_path" -b bugfix/same-session-worktree >/dev/null 2>&1

	ensure_registry_schema
	local original_pid=""
	local rollover_pid=""
	sleep 30 >/dev/null 2>&1 &
	original_pid=$!
	sleep 30 >/dev/null 2>&1 &
	rollover_pid=$!
	OPENCODE_PID="" OPENCODE_SESSION_ID="ses_pre_edit_rollover" PRE_EDIT_OWNER_PID="$original_pid" run_helper "$worktree_path" >/dev/null 2>&1

	local output=""
	local exit_code=0
	output=$(OPENCODE_PID="" OPENCODE_SESSION_ID="ses_pre_edit_rollover" PRE_EDIT_OWNER_PID="$rollover_pid" run_helper "$worktree_path" 2>&1) || exit_code=$?
	kill "$original_pid" "$rollover_pid" >/dev/null 2>&1 || true
	wait "$original_pid" "$rollover_pid" 2>/dev/null || true

	local stored_owner=""
	stored_owner=$(sqlite3 -separator '|' "$TEST_REGISTRY_DB" "
		SELECT owner_pid, owner_session FROM worktree_owners
		WHERE branch = 'bugfix/same-session-worktree';
	" 2>/dev/null || true)
	if [[ "$exit_code" -eq 0 ]] && [[ "$output" != *"WORKTREE_OWNERSHIP_CONFLICT=true"* ]] && [[ "$stored_owner" == "${rollover_pid}|ses_pre_edit_rollover" ]]; then
		print_result "allows same OpenCode session after owner PID rollover" 0
		return 0
	fi

	print_result "allows same OpenCode session after owner PID rollover" 1 "exit=${exit_code} owner=${stored_owner} output=${output}"
	return 0
}

test_headless_planning_path_requires_worktree() {
	# Ensure repo is on main for this test
	"$GIT_BIN" -C "$TEST_ROOT" switch main >/dev/null 2>&1 || true

	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --file "README.md" 2>&1) || exit_code=$?

	if [[ "$output" == *"LOOP_DECISION=worktree_created"* && "$output" != *"WORKTREE_PATH=${TEST_WORKTREE_BASE}/"* ]]; then
		print_result "headless planning worktree stays inside fixture base" 1 "$output"
		return 0
	fi
	if [[ "$exit_code" -ne 0 || "$output" == *"LOOP_DECISION=worktree"* || "$output" == *"LOOP_DECISION=worktree_created"* ]]; then
		print_result "headless planning path requires a linked worktree" 0
		return 0
	fi

	print_result "headless planning path requires a linked worktree" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_interactive_allowlisted_path_still_requires_worktree() {
	"$GIT_BIN" -C "$TEST_ROOT" switch main >/dev/null 2>&1 || true
	local output=""
	local exit_code=0
	output=$(run_helper "$TEST_ROOT" --file "README.md" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"ACTION_REQUIRED=create_or_use_linked_worktree"* ]]; then
		print_result "interactive allowlisted path still requires a linked worktree" 0
		return 0
	fi

	print_result "interactive allowlisted path still requires a linked worktree" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_path_traversal_blocked_on_main() {
	# Ensure repo is on main for this test
	"$GIT_BIN" -C "$TEST_ROOT" switch main >/dev/null 2>&1 || true

	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --file "todo/../secret.py" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"LOOP_DECISION=worktree"* ]]; then
		print_result "path traversal (todo/../secret.py) blocked on main" 0
		return 0
	fi

	print_result "path traversal (todo/../secret.py) blocked on main" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_absolute_path_outside_repo_blocked_on_main() {
	# Ensure repo is on main for this test
	"$GIT_BIN" -C "$TEST_ROOT" switch main >/dev/null 2>&1 || true

	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --file "/etc/passwd" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"LOOP_DECISION=worktree"* ]]; then
		print_result "absolute path outside repo (/etc/passwd) blocked on main" 0
		return 0
	fi

	print_result "absolute path outside repo (/etc/passwd) blocked on main" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_todo_subdir_path_requires_worktree() {
	# Ensure repo is on main for this test
	"$GIT_BIN" -C "$TEST_ROOT" switch main >/dev/null 2>&1 || true
	mkdir -p "${TEST_ROOT}/todo"

	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --file "todo/tasks/t001-brief.md" 2>&1) || exit_code=$?

	if [[ "$exit_code" -ne 0 || "$output" == *"LOOP_DECISION=worktree"* || "$output" == *"LOOP_DECISION=worktree_created"* ]]; then
		print_result "todo/ subdir path requires a linked worktree" 0
		return 0
	fi

	print_result "todo/ subdir path requires a linked worktree" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_auto_creates_git_path_worktree_from_ansi_helper_output() {
	local repo_parent="${TEST_ROOT}/ansi-case/Git"
	local repo_path="${repo_parent}/aidevops"
	mkdir -p "$repo_path"
	"$GIT_BIN" -C "$repo_path" init -b main >/dev/null 2>&1 || {
		"$GIT_BIN" -C "$repo_path" init >/dev/null 2>&1
		"$GIT_BIN" -C "$repo_path" checkout -b main >/dev/null 2>&1
	}
	"$GIT_BIN" -C "$repo_path" config user.name "Aidevops Test"
	"$GIT_BIN" -C "$repo_path" config user.email "test@example.com"
	"$GIT_BIN" -C "$repo_path" config core.hooksPath /dev/null
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false
	printf 'test\n' >"${repo_path}/README.md"
	"$GIT_BIN" -C "$repo_path" add README.md
	"$GIT_BIN" -C "$repo_path" commit -m "test: seed ansi repo" >/dev/null 2>&1

	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$repo_path" --loop-mode --task "https://github.com/marcusquinn/aidevops/issues/22136" 2>&1) || exit_code=$?

	local worktree_path=""
	worktree_path=$(printf '%s\n' "$output" | awk -F= '/^WORKTREE_PATH=/{print $2; exit}')
	if [[ "$exit_code" -eq 0 ]] && [[ "$output" == *"LOOP_DECISION=worktree_created"* ]] && [[ -n "$worktree_path" ]] && [[ -d "$worktree_path" ]]; then
		print_result "auto-creates /Git worktree despite ANSI helper output" 0
		return 0
	fi

	print_result "auto-creates /Git worktree despite ANSI helper output" 1 "exit=${exit_code} path=${worktree_path} output=${output}"
	return 0
}

setup_task_branch_collision_fixture() {
	local remote_path="${TEST_ROOT}/fixture-remote.git"
	"$GIT_BIN" init -q --bare "$remote_path"
	"$GIT_BIN" -C "$TEST_ROOT" remote add origin "$remote_path"
	"$GIT_BIN" -C "$TEST_ROOT" push -q -u origin main
	"$GIT_BIN" -C "$TEST_ROOT" remote set-head origin main

	COLLISION_TASK="Implement issue #28956 stale collision"
	local output=""
	local exit_code=0
	output=$(OPENCODE_SESSION_ID=collision-session AIDEVOPS_WORKTREE_BASE_DIR="$TEST_WORKTREE_BASE" \
		FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --task "$COLLISION_TASK" 2>&1) || exit_code=$?
	local original_path=""
	COLLISION_ORIGINAL_BRANCH=$(printf '%s\n' "$output" | awk -F= '/^WORKTREE_BRANCH=/{print $2; exit}')
	original_path=$(printf '%s\n' "$output" | awk -F= '/^WORKTREE_PATH=/{print substr($0, index($0, "=") + 1); exit}')
	COLLISION_ORIGINAL_SHA=$("$GIT_BIN" -C "$original_path" rev-parse HEAD 2>/dev/null || true)
	if [[ "$exit_code" -ne 0 || "$output" != *"WORKTREE_PROVENANCE=fresh"* || -z "$COLLISION_ORIGINAL_SHA" ]]; then
		print_result "creates first task worktree with fresh provenance" 1 "exit=${exit_code} output=${output}"
		return 1
	fi
	print_result "creates first task worktree with fresh provenance" 0

	"$GIT_BIN" -C "$TEST_ROOT" worktree remove --force "$original_path"
	ensure_registry_schema
	sqlite3 "$TEST_REGISTRY_DB" "DELETE FROM worktree_owners WHERE worktree_path = '$original_path';"
	COLLISION_TARGET_TREE=$("$GIT_BIN" -C "$TEST_ROOT" rev-parse "${COLLISION_ORIGINAL_SHA}^{tree}")
	COLLISION_ADVANCED_SHA=$(printf 'remote advance\n' | "$GIT_BIN" -C "$TEST_ROOT" commit-tree \
		"$COLLISION_TARGET_TREE" -p "$COLLISION_ORIGINAL_SHA")
	"$GIT_BIN" -C "$TEST_ROOT" push -q origin "${COLLISION_ADVANCED_SHA}:refs/heads/main"
	return 0
}

test_stale_task_branch_is_replaced_and_owned_continuation_resumes() {
	local output=""
	local exit_code=0
	output=$(OPENCODE_SESSION_ID=collision-session AIDEVOPS_WORKTREE_BASE_DIR="$TEST_WORKTREE_BASE" \
		FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --task "$COLLISION_TASK" 2>&1) || exit_code=$?
	local fresh_branch=""
	fresh_branch=$(printf '%s\n' "$output" | awk -F= '/^WORKTREE_BRANCH=/{print $2; exit}')
	COLLISION_FRESH_PATH=$(printf '%s\n' "$output" | awk -F= '/^WORKTREE_PATH=/{print substr($0, index($0, "=") + 1); exit}')
	local fresh_sha=""
	fresh_sha=$("$GIT_BIN" -C "$COLLISION_FRESH_PATH" rev-parse HEAD 2>/dev/null || true)
	local preserved_sha=""
	preserved_sha=$("$GIT_BIN" -C "$TEST_ROOT" rev-parse "refs/heads/${COLLISION_ORIGINAL_BRANCH}" 2>/dev/null || true)
	if [[ "$exit_code" -eq 0 && "$fresh_branch" == "${COLLISION_ORIGINAL_BRANCH}-fresh" &&
		"$fresh_sha" == "$COLLISION_ADVANCED_SHA" && "$preserved_sha" == "$COLLISION_ORIGINAL_SHA" &&
		"$output" == *"WORKTREE_PROVENANCE=fresh_collision"* ]]; then
		print_result "stale inactive task branch creates one fresh collision branch" 0
	else
		print_result "stale inactive task branch creates one fresh collision branch" 1 \
			"exit=${exit_code} original=${preserved_sha} fresh=${fresh_sha} target=${COLLISION_ADVANCED_SHA} output=${output}"
	fi

	output=""
	exit_code=0
	output=$(OPENCODE_SESSION_ID=foreign-session AIDEVOPS_WORKTREE_BASE_DIR="$TEST_WORKTREE_BASE" \
		FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --task "$COLLISION_TASK" 2>&1) || exit_code=$?
	local branch_key_count=0
	branch_key_count=$(printf '%s\n' "$output" | grep -c '^WORKTREE_BRANCH=' || true)
	if [[ "$exit_code" -eq 2 && "$branch_key_count" -eq 1 &&
		"$output" == *"WORKTREE_COLLISION=active_ownership_unverified"* ]]; then
		print_result "foreign session cannot reuse an active task worktree" 0
	else
		print_result "foreign session cannot reuse an active task worktree" 1 "exit=${exit_code} output=${output}"
	fi

	output=""
	exit_code=0
	output=$(OPENCODE_SESSION_ID=collision-session AIDEVOPS_WORKTREE_BASE_DIR="$TEST_WORKTREE_BASE" \
		FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --task "$COLLISION_TASK" 2>&1) || exit_code=$?
	local repeated_path=""
	repeated_path=$(printf '%s\n' "$output" | awk -F= '/^WORKTREE_PATH=/{print substr($0, index($0, "=") + 1); exit}')
	local fresh_root=""
	local repeated_root=""
	fresh_root=$("$GIT_BIN" -C "$COLLISION_FRESH_PATH" rev-parse --show-toplevel 2>/dev/null || true)
	repeated_root=$("$GIT_BIN" -C "$repeated_path" rev-parse --show-toplevel 2>/dev/null || true)
	if [[ "$exit_code" -eq 0 && "$repeated_root" == "$fresh_root" &&
		"$output" == *"WORKTREE_PROVENANCE=continuation_active"* ]]; then
		print_result "repeated task resumes its correctly owned active worktree" 0
	else
		print_result "repeated task resumes its correctly owned active worktree" 1 "exit=${exit_code} output=${output}"
	fi
	return 0
}

test_unique_task_branch_fails_closed() {
	local unique_task="Issue #29999 unique collision"
	local unique_branch="bugfix/gh29999-issue-29999-unique-collision"
	local unique_sha=""
	unique_sha=$(printf 'unique task commit\n' | "$GIT_BIN" -C "$TEST_ROOT" commit-tree \
		"$COLLISION_TARGET_TREE" -p "$COLLISION_ADVANCED_SHA")
	"$GIT_BIN" -C "$TEST_ROOT" branch "$unique_branch" "$unique_sha"
	local output=""
	local exit_code=0
	output=$(OPENCODE_SESSION_ID=collision-session AIDEVOPS_WORKTREE_BASE_DIR="$TEST_WORKTREE_BASE" \
		FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --task "$unique_task" 2>&1) || exit_code=$?
	local unique_after=""
	unique_after=$("$GIT_BIN" -C "$TEST_ROOT" rev-parse "refs/heads/${unique_branch}")
	if [[ "$exit_code" -eq 2 && "$unique_after" == "$unique_sha" &&
		"$output" == *"WORKTREE_COLLISION=unique_commits"* &&
		"$output" == *"ACTION_REQUIRED=inspect_existing_task_branch"* ]]; then
		print_result "inactive task branch with unique commits fails closed unchanged" 0
	else
		print_result "inactive task branch with unique commits fails closed unchanged" 1 "exit=${exit_code} output=${output}"
	fi
	return 0
}

test_task_branch_remote_refresh_failure_fails_closed() {
	local origin_url=""
	origin_url=$("$GIT_BIN" -C "$TEST_ROOT" remote get-url origin)
	"$GIT_BIN" -C "$TEST_ROOT" remote set-url origin "${TEST_ROOT}/missing-remote.git"
	local output=""
	local exit_code=0
	output=$(OPENCODE_SESSION_ID=collision-session AIDEVOPS_WORKTREE_BASE_DIR="$TEST_WORKTREE_BASE" \
		FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --task "Issue #30000 refresh failure" 2>&1) || exit_code=$?
	"$GIT_BIN" -C "$TEST_ROOT" remote set-url origin "$origin_url"
	local refresh_branch_created=0
	if "$GIT_BIN" -C "$TEST_ROOT" show-ref --verify --quiet refs/heads/bugfix/gh30000-issue-30000-refresh-failure; then
		refresh_branch_created=1
	fi
	if [[ "$exit_code" -eq 2 && "$output" == *"WORKTREE_COLLISION=target_refresh_failed"* &&
		"$output" == *"ACTION_REQUIRED=refresh_target"* &&
		"$output" == *"NEXT_STEP: Restore remote access, refresh the target branch"* &&
		"$refresh_branch_created" -eq 0 ]]; then
		print_result "remote refresh failure does not create a task branch" 0
	else
		print_result "remote refresh failure does not create a task branch" 1 "exit=${exit_code} output=${output}"
	fi
	return 0
}

main() {
	trap teardown_test_repo EXIT
	setup_test_repo

	test_blocks_headless_edits_on_main_with_worktree_guidance
	test_allows_linked_worktree_edits
	test_namespaced_task_assignee_lookup
	test_malformed_task_assignee_fails_closed
	test_worker_env_does_not_bypass_canonical_guard
	test_warns_when_canonical_repo_is_off_main
	test_blocks_when_linked_worktree_owned_by_another_live_process
	test_allows_headless_child_of_exact_wrapper_owner
	test_headless_wrapper_owner_proof_fails_closed
	test_rejects_forged_proof_for_unrelated_live_owner
	test_allows_same_opencode_session_pid_rollover
	test_headless_planning_path_requires_worktree
	test_interactive_allowlisted_path_still_requires_worktree
	test_path_traversal_blocked_on_main
	test_absolute_path_outside_repo_blocked_on_main
	test_todo_subdir_path_requires_worktree
	test_auto_creates_git_path_worktree_from_ansi_helper_output
	setup_task_branch_collision_fixture
	test_stale_task_branch_is_replaced_and_owned_continuation_resumes
	test_unique_task_branch_fails_closed
	test_task_branch_remote_refresh_failure_fails_closed

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
