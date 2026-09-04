#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-registry-dead-owner.sh — GH#23024 regression guard.
#
# Verifies that a dead registry owner PID is quarantined before cleanup may
# unregister it, preventing a single stale PID probe from deleting active
# worktrees after an AI runtime crash/restart.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REGISTRY_LIB="${SCRIPT_DIR}/../shared-worktree-registry.sh"
CLEAN_LIB="${SCRIPT_DIR}/../worktree-clean-lib.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_ROOT=$(mktemp -d)
	export WORKTREE_REGISTRY_DIR="${TEST_ROOT}/registry"
	export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
	export WORKTREE_OWNER_DEAD_COOLDOWN_MINUTES=60
	# shellcheck source=../shared-worktree-registry.sh
	source "$REGISTRY_LIB"
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

make_worktree_dir() {
	local name="$1"
	local wt_path="${TEST_ROOT}/${name}"
	mkdir -p "$wt_path"
	printf '%s' "$wt_path"
	return 0
}

register_dead_owner_fixture() {
	local wt_path="$1"
	local branch="$2"
	_init_registry_db || return 1
	wt_path=$(_wt_registry_lookup_path "$wt_path")
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        INSERT INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_comm, owner_process_start)
        VALUES
            ('$(_wt_sql_escape "$wt_path")', '$(_wt_sql_escape "$branch")',
             999999, 'test-dead-owner', 'dead-process-generation');
    " || return 1
	return 0
}

live_other_pid() {
	local my_pid
	my_pid=$(_resolve_worktree_owner_pid "")
	if [[ "$$" != "$my_pid" ]] && kill -0 "$$" 2>/dev/null; then
		printf '%s' "$$"
		return 0
	fi
	if [[ -n "${PPID:-}" && "$PPID" != "$my_pid" ]] && kill -0 "$PPID" 2>/dev/null; then
		printf '%s' "$PPID"
		return 0
	fi
	printf '%s' "1"
	return 0
}

assert_owner_exists() {
	local wt_path="$1"
	local owner_info=""
	owner_info=$(check_worktree_owner "$wt_path" 2>/dev/null || true)
	[[ -n "$owner_info" ]] && return 0
	return 1
}

assert_owner_missing() {
	local wt_path="$1"
	local owner_info=""
	owner_info=$(check_worktree_owner "$wt_path" 2>/dev/null || true)
	[[ -z "$owner_info" ]] && return 0
	return 1
}

test_dead_owner_first_pass_quarantines() {
	local wt_path
	wt_path=$(make_worktree_dir "dead-owner-first")
	register_dead_owner_fixture "$wt_path" "feature/dead-owner-first"

	local rc=0
	if ! is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_exists "$wt_path" || rc=1
	[[ -n "$(worktree_owner_dead_seen_at "$wt_path")" ]] || rc=1
	print_result "dead owner first pass is quarantined" "$rc"
	return 0
}

test_dead_owner_within_cooldown_keeps_skip() {
	local wt_path
	wt_path=$(make_worktree_dir "dead-owner-cooldown")
	register_dead_owner_fixture "$wt_path" "feature/dead-owner-cooldown"
	is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1

	local rc=0
	if ! is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_exists "$wt_path" || rc=1
	print_result "dead owner within cooldown still blocks cleanup" "$rc"
	return 0
}

test_dead_owner_after_cooldown_unregisters() {
	local wt_path
	wt_path=$(make_worktree_dir "dead-owner-expired")
	register_dead_owner_fixture "$wt_path" "feature/dead-owner-expired"
	is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1
	local registry_path
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners
        SET owner_dead_seen_at = '2020-01-01T00:00:00Z'
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    "
	export WORKTREE_OWNER_DEAD_COOLDOWN_MINUTES=1

	local rc=0
	if is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_missing "$wt_path" || rc=1
	print_result "dead owner after cooldown unregisters" "$rc"
	return 0
}

test_owner_pid_override_rejects_sql_payload() {
	local wt_path
	wt_path=$(make_worktree_dir "owner-pid-sql-payload")
	register_worktree "$wt_path" "feature/owner-pid-sql-payload" --owner-pid "1); DROP TABLE worktree_owners; --"

	local owner_info=""
	owner_info=$(check_worktree_owner "$wt_path" 2>/dev/null || true)
	local owner_pid="${owner_info%%|*}"

	local table_exists=""
	table_exists=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'worktree_owners';" 2>/dev/null || true)

	local rc=0
	[[ "$table_exists" == "worktree_owners" ]] || rc=1
	[[ -n "$owner_info" ]] || rc=1
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || rc=1
	print_result "owner pid override rejects SQL payload" "$rc" "(owner_info='${owner_info}')"
	return 0
}

test_recycled_live_pid_with_same_command_unregisters() {
	local wt_path
	wt_path=$(make_worktree_dir "recycled-live-same-command")
	local owner_pid
	owner_pid=$(live_other_pid)
	register_worktree "$wt_path" "feature/recycled-live-same-command" --owner-pid "$owner_pid"
	local registry_path
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	local owner_comm=""
	owner_comm=$(_get_proc_comm "$owner_pid")
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners
        SET owner_comm = '$(_wt_sql_escape "$owner_comm")',
            owner_process_start = 'recycled-process-generation'
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    "

	local rc=0
	if is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_missing "$wt_path" || rc=1
	print_result "recycled live pid with same command unregisters" "$rc"
	return 0
}

test_matching_live_process_generation_still_blocks() {
	local wt_path
	wt_path=$(make_worktree_dir "matching-live-process-generation")
	local owner_pid
	owner_pid=$(live_other_pid)
	register_worktree "$wt_path" "feature/matching-live-process-generation" --owner-pid "$owner_pid"
	local registry_path
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	local registered_process_start=""
	registered_process_start=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT COALESCE(owner_process_start, '') FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    ")

	local rc=0
	[[ -n "$registered_process_start" ]] || rc=1
	if ! is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_exists "$wt_path" || rc=1
	print_result "matching live process generation still blocks" "$rc"
	return 0
}

test_reused_owner_delete_preserves_concurrent_replacement() {
	local wt_path
	wt_path=$(make_worktree_dir "reused-owner-delete-race")
	local owner_pid
	owner_pid=$(live_other_pid)
	register_worktree "$wt_path" "feature/reused-owner-delete-race" --owner-pid "$owner_pid"
	local registry_path=""
	local original_process_start=""
	local original_created_at=""
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	IFS='|' read -r original_process_start original_created_at <<<"$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
        SELECT COALESCE(owner_process_start, ''), COALESCE(created_at, '')
        FROM worktree_owners WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    ")"
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners SET owner_process_start = 'replacement-generation'
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    "

	local rc=0
	if _wt_unregister_owner_if_generation_matches "$registry_path" "$owner_pid" \
		"$original_process_start" "$original_created_at"; then
		rc=1
	fi
	local replacement_process_start=""
	replacement_process_start=$(sqlite3 "$WORKTREE_REGISTRY_DB" "
        SELECT COALESCE(owner_process_start, '') FROM worktree_owners
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    ")
	[[ "$replacement_process_start" == "replacement-generation" ]] || rc=1
	print_result "reused-owner deletion preserves concurrent replacement" "$rc"
	return 0
}

test_expired_legacy_dispatch_precreate_systemd_owner_unregisters() {
	local wt_path
	wt_path=$(make_worktree_dir "legacy-dispatch-precreate-systemd")
	local owner_pid
	owner_pid=$(live_other_pid)
	register_worktree "$wt_path" "feature/legacy-dispatch-precreate-systemd" \
		--owner-pid "$owner_pid" --session "dispatch-precreate-28807" --task "28807"
	local registry_path
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners
        SET created_at = '2020-01-01T00:00:00Z', owner_comm = 'systemd',
            owner_process_start = ''
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    "
	_get_proc_comm() {
		printf '%s' 'systemd'
		return 0
	}
	export WORKTREE_DISPATCH_PRECREATE_LEGACY_GRACE_MINUTES=15

	local rc=0
	if is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_missing "$wt_path" || rc=1
	print_result "expired legacy systemd precreate owner unregisters" "$rc"
	return 0
}

test_recent_legacy_dispatch_precreate_systemd_owner_blocks() {
	local wt_path
	wt_path=$(make_worktree_dir "recent-dispatch-precreate-systemd")
	local owner_pid
	owner_pid=$(live_other_pid)
	register_worktree "$wt_path" "feature/recent-dispatch-precreate-systemd" \
		--owner-pid "$owner_pid" --session "dispatch-precreate-28808" --task "28808"
	local registry_path
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners SET owner_comm = 'systemd', owner_process_start = ''
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    "
	_get_proc_comm() {
		printf '%s' 'systemd'
		return 0
	}
	export WORKTREE_DISPATCH_PRECREATE_LEGACY_GRACE_MINUTES=15

	local rc=0
	if ! is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_exists "$wt_path" || rc=1
	print_result "recent legacy systemd precreate owner keeps launch grace" "$rc"
	return 0
}

test_tokenized_systemd_owner_ignores_legacy_expiry() {
	local wt_path
	wt_path=$(make_worktree_dir "tokenized-dispatch-precreate-systemd")
	local owner_pid
	owner_pid=$(live_other_pid)
	register_worktree "$wt_path" "feature/tokenized-dispatch-precreate-systemd" \
		--owner-pid "$owner_pid" --session "dispatch-precreate-28810" --task "28810"
	local registry_path
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners
        SET created_at = '2020-01-01T00:00:00Z', owner_comm = 'systemd'
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    "
	_get_proc_comm() {
		printf '%s' 'systemd'
		return 0
	}

	local rc=0
	if ! is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_exists "$wt_path" || rc=1
	print_result "tokenized systemd owner ignores legacy expiry" "$rc"
	return 0
}

test_mismatched_legacy_dispatch_precreate_identity_blocks() {
	local wt_path
	wt_path=$(make_worktree_dir "mismatched-dispatch-precreate-systemd")
	local owner_pid
	owner_pid=$(live_other_pid)
	register_worktree "$wt_path" "feature/mismatched-dispatch-precreate-systemd" \
		--owner-pid "$owner_pid" --session "dispatch-precreate-99999" --task "28809"
	local registry_path
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners
        SET owner_comm = 'systemd', owner_process_start = ''
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    "
	_get_proc_comm() {
		printf '%s' 'systemd'
		return 0
	}
	export WORKTREE_DISPATCH_PRECREATE_LEGACY_GRACE_MINUTES=15

	local rc=0
	if ! is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_exists "$wt_path" || rc=1
	print_result "mismatched systemd precreate identity remains protected" "$rc"
	return 0
}

test_explicit_cleanup_lease_identity() {
	local wt_path
	wt_path=$(make_worktree_dir "explicit-cleanup-lease")
	local distinct_live_pid
	sleep 30 &
	distinct_live_pid=$!
	claim_worktree_ownership "$wt_path" "feature/explicit-cleanup-lease" \
		--owner-pid "$$" --session "cleanup:$$" --task "worktree-removal"

	local rc=0
	if is_worktree_owned_by_others_for_pid "$wt_path" "$$" >/dev/null 2>&1; then
		rc=1
	fi
	if ! is_worktree_owned_by_others_for_pid "$wt_path" "$distinct_live_pid" >/dev/null 2>&1; then
		rc=1
	fi
	if ! is_worktree_owned_by_others_for_pid "$wt_path" "invalid" >/dev/null 2>&1; then
		rc=1
	fi
	if ! worktree_has_exact_owner_contract "$wt_path" "$$" "cleanup:$$" \
		"worktree-removal"; then
		rc=1
	fi
	if worktree_has_exact_owner_contract "$wt_path" "$$" "cleanup-replaced" \
		"worktree-removal"; then
		rc=1
	fi
	if unregister_worktree_if_owner_contract "$wt_path" "$$" "cleanup-replaced" \
		"worktree-removal"; then
		rc=1
	fi
	if ! worktree_has_exact_owner_contract "$wt_path" "$$" "cleanup:$$" \
		"worktree-removal"; then
		rc=1
	fi
	if ! unregister_worktree_if_owner_contract "$wt_path" "$$" "cleanup:$$" \
		"worktree-removal"; then
		rc=1
	fi
	if check_worktree_owner "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	kill "$distinct_live_pid" 2>/dev/null || true
	wait "$distinct_live_pid" 2>/dev/null || true
	print_result "explicit cleanup lease distinguishes exact holder and other runtimes" "$rc"
	return 0
}

test_matching_pid_requires_matching_process_generation() {
	local wt_path
	wt_path=$(make_worktree_dir "matching-pid-recycled-generation")
	claim_worktree_ownership "$wt_path" "feature/matching-pid-recycled-generation" \
		--owner-pid "$$" --session "cleanup:$$" --task "worktree-removal"
	local registry_path=""
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners SET owner_process_start = 'recycled-process-generation'
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    "

	local rc=0
	if is_worktree_owned_by_others_for_pid "$wt_path" "$$" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_missing "$wt_path" || rc=1
	print_result "matching PID still requires matching process generation" "$rc"
	return 0
}

test_legacy_registry_schema_migrates_on_owner_check() {
	local wt_path
	wt_path=$(make_worktree_dir "legacy-schema-owner-check")
	local owner_pid
	owner_pid=$(live_other_pid)
	mkdir -p "$WORKTREE_REGISTRY_DIR"
	rm -f "$WORKTREE_REGISTRY_DB"
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        CREATE TABLE worktree_owners (
            worktree_path TEXT PRIMARY KEY,
            branch TEXT,
            owner_pid INTEGER,
            owner_session TEXT DEFAULT '',
            owner_batch TEXT DEFAULT '',
            task_id TEXT DEFAULT '',
            owner_dead_seen_at TEXT DEFAULT '',
            created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
        INSERT INTO worktree_owners (worktree_path, branch, owner_pid, created_at)
        VALUES ('$(_wt_sql_escape "$wt_path")', 'feature/legacy-schema-owner-check', ${owner_pid}, '2020-01-01T00:00:00Z');
    "
	local rc=0
	if is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	local has_owner_comm=""
	has_owner_comm=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT 1 FROM pragma_table_info('worktree_owners') WHERE name = 'owner_comm';" 2>/dev/null || true)
	local has_owner_process_start=""
	has_owner_process_start=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT 1 FROM pragma_table_info('worktree_owners') WHERE name = 'owner_process_start';" 2>/dev/null || true)
	[[ "$has_owner_comm" == "1" ]] || rc=1
	[[ "$has_owner_process_start" == "1" ]] || rc=1
	print_result "legacy registry schema migrates during owner check" "$rc"
	return 0
}

test_existing_owner_reconciliation_quarantines_then_unregisters() {
	local wt_path
	wt_path=$(make_worktree_dir "reconcile-existing-dead-owner")
	register_dead_owner_fixture "$wt_path" "feature/reconcile-existing-dead-owner"

	local rc=0
	_wt_registry_reconcile_existing_owners || rc=1
	assert_owner_exists "$wt_path" || rc=1
	[[ -n "$(worktree_owner_dead_seen_at "$wt_path")" ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1

	local registry_path=""
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	sqlite3 "$WORKTREE_REGISTRY_DB" "
        UPDATE worktree_owners
        SET owner_dead_seen_at = '2020-01-01T00:00:00Z'
        WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
    "
	export WORKTREE_OWNER_DEAD_COOLDOWN_MINUTES=1
	_wt_registry_reconcile_existing_owners || rc=1
	assert_owner_missing "$wt_path" || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "existing-owner reconciliation quarantines then unregisters without deleting directory" "$rc"
	return 0
}

test_existing_owner_reconciliation_preserves_live_generation() {
	local wt_path
	wt_path=$(make_worktree_dir "reconcile-existing-live-owner")
	local owner_pid
	owner_pid=$(live_other_pid)
	register_worktree "$wt_path" "feature/reconcile-existing-live-owner" --owner-pid "$owner_pid"

	local rc=0
	_wt_registry_reconcile_existing_owners || rc=1
	assert_owner_exists "$wt_path" || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "existing-owner reconciliation preserves live generation and directory" "$rc"
	return 0
}

test_inconclusive_dead_pid_probe_fails_closed() {
	local wt_path
	wt_path=$(make_worktree_dir "inconclusive-dead-pid-probe")
	register_dead_owner_fixture "$wt_path" "feature/inconclusive-dead-pid-probe"
	_wt_pid_is_definitely_absent() { return 1; }

	local rc=0
	if ! is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_exists "$wt_path" || rc=1
	[[ -z "$(worktree_owner_dead_seen_at "$wt_path")" ]] || rc=1
	print_result "inconclusive dead PID probe fails closed" "$rc"
	return 0
}

test_unavailable_process_generation_fails_closed() {
	local wt_path
	wt_path=$(make_worktree_dir "unavailable-process-generation")
	local owner_pid
	owner_pid=$(live_other_pid)
	register_worktree "$wt_path" "feature/unavailable-process-generation" --owner-pid "$owner_pid"
	_wt_process_start_token_for_pid() { return 1; }

	local rc=0
	if ! is_worktree_owned_by_others "$wt_path" >/dev/null 2>&1; then
		rc=1
	fi
	assert_owner_exists "$wt_path" || rc=1
	print_result "unavailable process generation fails closed" "$rc"
	return 0
}

test_should_skip_cleanup_branch_merged_within_grace() {
	local wt_path
	wt_path=$(make_worktree_dir "branch-merged-grace")
	local rc
	rc=$(
		set +e
		is_worktree_owned_by_others() { return 1; }
		check_worktree_owner() { printf '%s\n' ''; return 0; }
		worktree_is_in_grace_period() { return 0; }
		get_validated_grace_hours() { printf '%s\n' '4'; return 0; }
		worktree_has_changes() { return 1; }
		branch_has_zero_commits_ahead() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		log_worktree_removal_event() { return 0; }
		: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
		_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
		_WTAR_WH_CALLER="${_WTAR_WH_CALLER:-test}"
		export RED GREEN YELLOW BLUE BOLD NC _WTAR_SKIPPED _WTAR_WH_CALLER
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_LIB" >/dev/null 2>&1 || exit 9
		should_skip_cleanup "$wt_path" "feature/branch-merged-grace" "main" "" "false" >/dev/null 2>&1
		printf '%s' "$?"
	)
	if [[ "$rc" == "0" ]]; then
		print_result "branch-merged worktree within grace still skips" 0
	else
		print_result "branch-merged worktree within grace still skips" 1 "(rc=$rc)"
	fi
	return 0
}

main() {
	setup
	trap teardown EXIT
	printf 'Running worktree registry dead-owner tests\n'
	test_dead_owner_first_pass_quarantines
	test_dead_owner_within_cooldown_keeps_skip
	test_dead_owner_after_cooldown_unregisters
	test_owner_pid_override_rejects_sql_payload
	test_recycled_live_pid_with_same_command_unregisters
	test_matching_live_process_generation_still_blocks
	test_reused_owner_delete_preserves_concurrent_replacement
	test_expired_legacy_dispatch_precreate_systemd_owner_unregisters
	test_recent_legacy_dispatch_precreate_systemd_owner_blocks
	test_tokenized_systemd_owner_ignores_legacy_expiry
	test_mismatched_legacy_dispatch_precreate_identity_blocks
	test_explicit_cleanup_lease_identity
	test_matching_pid_requires_matching_process_generation
	test_legacy_registry_schema_migrates_on_owner_check
	test_existing_owner_reconciliation_quarantines_then_unregisters
	test_existing_owner_reconciliation_preserves_live_generation
	test_inconclusive_dead_pid_probe_fails_closed
	test_unavailable_process_generation_fails_closed
	test_should_skip_cleanup_branch_merged_within_grace
	printf 'Results: %s/%s passed, %s failed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] && return 0
	return 1
}

main "$@"
