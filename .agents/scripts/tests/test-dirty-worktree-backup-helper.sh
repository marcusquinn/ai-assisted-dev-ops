#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../dirty-worktree-backup-helper.sh"

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$detail"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

setup_repo() {
	local repo_dir="$1"
	mkdir -p "$repo_dir"
	/usr/bin/git -C "$repo_dir" init -q -b main || return 1
	/usr/bin/git -C "$repo_dir" config user.email test@example.invalid || return 1
	/usr/bin/git -C "$repo_dir" config user.name Test || return 1
	/usr/bin/git -C "$repo_dir" config commit.gpgsign false || return 1
	printf 'base\n' >"$repo_dir/README.md"
	/usr/bin/git -C "$repo_dir" add README.md || return 1
	/usr/bin/git -C "$repo_dir" commit -q -m init || return 1
	return 0
}

test_round_trip_preserves_exact_state() {
	local repo_dir="${TEST_ROOT}/round-trip-repo"
	local backup_root="${TEST_ROOT}/round-trip-backups"
	local output=""
	local backup_dir=""
	local backup_id=""
	local rc=0

	setup_repo "$repo_dir" || return 1
	printf 'staged\n' >"$repo_dir/staged.txt"
	/usr/bin/git -C "$repo_dir" add staged.txt || return 1
	printf 'unstaged\n' >>"$repo_dir/README.md"
	mkdir -p "$repo_dir/todo/tasks"
	printf 'brief\n' >"$repo_dir/todo/tasks/t1-brief.md"
	ln -s ../../README.md "$repo_dir/todo/tasks/readme-link"

	output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" backup --repo "$repo_dir" --reason $'roundtrip\twith\nmetadata' \
		--task t1 --operation-id round-trip --machine 2>/dev/null) || return 1
	IFS='|' read -r backup_id backup_dir <<<"$output"
	[[ -n "$backup_id" && -d "$backup_dir" ]] || return 1
	[[ -s "$backup_dir/tracked.patch" ]] || rc=1
	[[ -f "$backup_dir/untracked/todo/tasks/t1-brief.md" ]] || rc=1
	[[ -L "$backup_dir/untracked/todo/tasks/readme-link" ]] || rc=1
	[[ -f "$backup_dir/manifest.tsv" ]] || rc=1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" verify --repo "$repo_dir" --backup "$backup_id" >/dev/null || rc=1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" matches --repo "$repo_dir" --backup "$backup_id" >/dev/null || rc=1
	local repeated_output=""
	repeated_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" backup --repo "$repo_dir" --operation-id round-trip --machine 2>/dev/null) || rc=1
	[[ "$repeated_output" == "$output" ]] || rc=1
	if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" verify --repo "$repo_dir" --backup ../escape >/dev/null 2>&1; then
		rc=1
	fi

	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" clean --repo "$repo_dir" --backup "$backup_id" \
		--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >/dev/null || rc=1
	[[ -z "$(/usr/bin/git -C "$repo_dir" status --porcelain=v1)" ]] || rc=1
	[[ ! -e "$repo_dir/todo/tasks/t1-brief.md" ]] || rc=1

	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" restore --repo "$repo_dir" --backup "$backup_id" \
		--confirm RESTORE_DIRTY_WORKTREE_BACKUP >/dev/null || rc=1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" matches --repo "$repo_dir" --backup "$backup_id" >/dev/null || rc=1
	[[ -L "$repo_dir/todo/tasks/readme-link" ]] || rc=1
	[[ "$(/usr/bin/git -C "$repo_dir" show :staged.txt)" == "staged" ]] || rc=1

	print_result "backup-clean-restore round trip preserves HEAD, index, tracked, untracked, and symlink state" "$rc" "backup_id=$backup_id"
	return 0
}

test_clean_refuses_changed_state() {
	local repo_dir="${TEST_ROOT}/changed-repo"
	local backup_root="${TEST_ROOT}/changed-backups"
	local output=""
	local backup_id=""
	local backup_dir=""
	local verification_output=""
	local limit_output=""
	local rc=0

	setup_repo "$repo_dir" || return 1
	printf 'first\n' >>"$repo_dir/README.md"
	output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" backup --repo "$repo_dir" --operation-id changed --machine 2>/dev/null) || return 1
	IFS='|' read -r backup_id backup_dir <<<"$output"
	printf 'second\n' >>"$repo_dir/README.md"
	if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" clean --repo "$repo_dir" --backup "$backup_id" \
		--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >/dev/null 2>&1; then
		rc=1
	fi
	grep -q '^second$' "$repo_dir/README.md" || rc=1
	[[ -d "$backup_dir" ]] || rc=1
	print_result "clean refuses state changed after preservation" "$rc"
	return 0
}

test_ignored_descendants_and_clean_rollback() {
	local repo_dir="${TEST_ROOT}/ignored-repo"
	local backup_root="${TEST_ROOT}/ignored-backups"
	local failure_hook="${TEST_ROOT}/fail-clean.sh"
	local output=""
	local backup_id=""
	local backup_dir=""
	local rc=0

	setup_repo "$repo_dir" || return 1
	mkdir -p "$repo_dir/local-state/runtime/nested"
	printf 'runtime/\n' >"$repo_dir/local-state/.gitignore"
	printf 'metadata\n' >"$repo_dir/local-state/metadata.txt"
	printf '\001ignored\000payload\377' >"$repo_dir/local-state/runtime/nested/payload.bin"
	chmod 640 "$repo_dir/local-state/runtime/nested/payload.bin"
	ln -s payload.bin "$repo_dir/local-state/runtime/nested/payload-link"
	printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$failure_hook"
	chmod +x "$failure_hook"

	output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" backup --repo "$repo_dir" --operation-id ignored --machine 2>/dev/null) || return 1
	IFS='|' read -r backup_id backup_dir <<<"$output"
	[[ -f "$backup_dir/untracked/local-state/runtime/nested/payload.bin" ]] || rc=1
	[[ -L "$backup_dir/untracked/local-state/runtime/nested/payload-link" ]] || rc=1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" verify --repo "$repo_dir" --backup "$backup_id" >/dev/null || rc=1
	chmod 600 "$backup_dir/untracked/local-state/runtime/nested/payload.bin"
	if verification_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" verify --repo "$repo_dir" --backup "$backup_id" 2>&1); then
		rc=1
	fi
	[[ "$verification_output" != *"payload.bin"* ]] || rc=1
	chmod 640 "$backup_dir/untracked/local-state/runtime/nested/payload.bin"
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" verify --repo "$repo_dir" --backup "$backup_id" >/dev/null || rc=1
	if limit_output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		AIDEVOPS_DIRTY_BACKUP_MAX_UNTRACKED_FILES=2 \
		bash "$HELPER" backup --repo "$repo_dir" --operation-id bounded --machine 2>&1); then
		rc=1
	fi
	[[ "$limit_output" != *"payload.bin"* ]] || rc=1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" matches --repo "$repo_dir" --backup "$backup_id" >/dev/null || rc=1

	if AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		AIDEVOPS_DIRTY_BACKUP_AFTER_REMOVE_HOOK="$failure_hook" \
		bash "$HELPER" clean --repo "$repo_dir" --backup "$backup_id" \
		--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >/dev/null 2>&1; then
		rc=1
	fi
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" matches --repo "$repo_dir" --backup "$backup_id" >/dev/null || rc=1
	[[ "$(awk -F '\t' '$1 == "clean_state" { print $2 }' "$backup_dir/manifest.tsv")" == "rolled_back" ]] || rc=1
	[[ "$(stat -f '%Lp' "$repo_dir/local-state/runtime/nested/payload.bin" 2>/dev/null ||
		stat -c '%a' "$repo_dir/local-state/runtime/nested/payload.bin")" == "640" ]] || rc=1

	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" clean --repo "$repo_dir" --backup "$backup_id" \
		--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >/dev/null || rc=1
	[[ -z "$(/usr/bin/git -C "$repo_dir" status --porcelain=v1)" ]] || rc=1
	[[ ! -e "$repo_dir/local-state/.gitignore" ]] || rc=1
	[[ ! -e "$repo_dir/local-state/runtime/nested/payload.bin" ]] || rc=1

	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" restore --repo "$repo_dir" --backup "$backup_id" \
		--confirm RESTORE_DIRTY_WORKTREE_BACKUP >/dev/null || rc=1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" matches --repo "$repo_dir" --backup "$backup_id" >/dev/null || rc=1
	[[ "$(/usr/bin/git -C "$repo_dir" check-ignore local-state/runtime/nested/payload.bin)" == "local-state/runtime/nested/payload.bin" ]] || rc=1
	[[ "$(readlink "$repo_dir/local-state/runtime/nested/payload-link")" == "payload.bin" ]] || rc=1

	print_result "ignored descendants are integrity-protected and failed clean rolls back before safe retry" "$rc" "backup_id=$backup_id"
	return 0
}

test_prune_requires_terminal_state() {
	local repo_dir="${TEST_ROOT}/prune-repo"
	local backup_root="${TEST_ROOT}/prune-backups"
	local output=""
	local backup_id=""
	local backup_dir=""
	local rc=0

	setup_repo "$repo_dir" || return 1
	printf 'open backup\n' >>"$repo_dir/README.md"
	output=$(AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" backup --repo "$repo_dir" --operation-id prune --machine 2>/dev/null) || return 1
	IFS='|' read -r backup_id backup_dir <<<"$output"
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" prune --force --retention-days 0 >/dev/null || rc=1
	[[ -d "$backup_dir" ]] || rc=1
	AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" bash "$HELPER" acknowledge \
		--backup "$backup_id" --confirm ACKNOWLEDGE_DIRTY_WORKTREE_BACKUP >/dev/null || rc=1
	AIDEVOPS_REAL_GIT_BIN=/usr/bin/git AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" \
		bash "$HELPER" prune --force --retention-days 0 >/dev/null || rc=1
	[[ ! -d "$backup_dir" ]] || rc=1
	print_result "prune retains open evidence and removes only acknowledged backups" "$rc"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dirty-backup-test.XXXXXX") || exit 1
	trap teardown EXIT

	test_round_trip_preserves_exact_state
	test_clean_refuses_changed_state
	test_ignored_descendants_and_clean_rollback
	test_prune_requires_terminal_state

	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
