#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../worktree-archive-helper.sh"
TEST_DIR=""

teardown() {
	[[ -z "$TEST_DIR" || ! -d "$TEST_DIR" ]] || rm -rf "$TEST_DIR"
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	git init -q -b main "${TEST_DIR}/repo"
	git -C "${TEST_DIR}/repo" config user.email test@example.invalid
	git -C "${TEST_DIR}/repo" config user.name 'Aidevops Test'
	printf 'base\n' >"${TEST_DIR}/repo/file.txt"
	git -C "${TEST_DIR}/repo" add file.txt
	git -C "${TEST_DIR}/repo" commit -qm init
	git -C "${TEST_DIR}/repo" worktree add -qb feature/archive "${TEST_DIR}/worker"
	return 0
}

main() {
	local archive_dir=""
	local restored_path=""

	setup
	restored_path="${TEST_DIR}/restored"
	printf 'commit\n' >"${TEST_DIR}/worker/commit.txt"
	git -C "${TEST_DIR}/worker" add commit.txt
	git -C "${TEST_DIR}/worker" commit -qm feature
	printf 'staged\n' >"${TEST_DIR}/worker/file.txt"
	git -C "${TEST_DIR}/worker" add file.txt
	printf 'dirty\n' >>"${TEST_DIR}/worker/file.txt"
	printf 'untracked\n' >"${TEST_DIR}/worker/untracked.txt"
	archive_dir=$(AIDEVOPS_WORKTREE_ARCHIVE_ROOT="${TEST_DIR}/archives" "$HELPER" archive "${TEST_DIR}/worker" --repo example/repo --issue 42 --reason failed-worker --base-branch main)
	"$HELPER" verify "$archive_dir"
	AIDEVOPS_WORKTREE_ARCHIVE_ROOT="${TEST_DIR}/archives" "$HELPER" list --repo example/repo --issue 42 | grep -F '"issue": 42'
	"$HELPER" restore "$archive_dir" --target "$restored_path"
	[[ -f "${restored_path}/commit.txt" && -f "${restored_path}/untracked.txt" ]]
	grep -Fx 'dirty' "${restored_path}/file.txt"
	AIDEVOPS_WORKTREE_ARCHIVE_ROOT="${TEST_DIR}/archives" "$HELPER" prune --older-than 1d --max-total-size 1K --dry-run
	"$HELPER" archive "${TEST_DIR}/worker" --repo bad --issue 0 --reason bad --base-branch main && return 1
	printf 'PASS worktree archive helper\n'
	return 0
}

main "$@"
