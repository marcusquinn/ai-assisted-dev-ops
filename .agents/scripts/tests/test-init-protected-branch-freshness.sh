#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
INSTALL_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENTS_DIR="${INSTALL_DIR}/.agents"
CONFIG_DIR="${HOME}/.config/aidevops"
REPOS_FILE="${CONFIG_DIR}/repos.json"

print_info() {
	printf 'INFO %s\n' "$*"
	return 0
}
print_success() {
	printf 'SUCCESS %s\n' "$*"
	return 0
}
print_warning() {
	printf 'WARNING %s\n' "$*"
	return 0
}
print_error() {
	printf 'ERROR %s\n' "$*"
	return 0
}

# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
source "${INSTALL_DIR}/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh"

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

assert_equal() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

commit_file() {
	local repo="$1"
	local content="$2"
	printf '%s\n' "$content" >"${repo}/state.txt"
	git -C "$repo" add state.txt
	git -C "$repo" commit -q -m "test: ${content}"
	return 0
}

run_freshness_checks() {
	local remote="$1"
	local seed="$2"
	local victim="$3"
	local fresh="$4"
	commit_file "$seed" "remote-ahead"
	git -C "$seed" push -q
	local remote_tip=""
	remote_tip=$(git -C "$seed" rev-parse HEAD)

	local stale_status=0 stale_output=""
	stale_output=$(cd "$victim" && AIDEVOPS_PROTECTED_BRANCH_CHOICE=2 check_protected_branch chore aidevops-init) || stale_status=$?
	assert_equal "1" "$stale_status" "direct protected-branch init rejects a behind branch"
	assert_equal "true" "$([[ "$stale_output" == *"Cannot initialize directly on stale main"* ]] && printf true || printf false)" "stale rejection explains the upstream mismatch"
	assert_equal "1" "$(git -C "$victim" rev-list --count HEAD..origin/main)" "preflight fetch refreshes the remote-tracking ref"

	commit_file "$victim" "local-divergence"
	local diverged_status=0 diverged_output=""
	diverged_output=$(cd "$victim" && AIDEVOPS_PROTECTED_BRANCH_CHOICE=2 check_protected_branch chore aidevops-init) || diverged_status=$?
	assert_equal "1" "$diverged_status" "direct protected-branch init rejects a diverged branch"
	assert_equal "true" "$([[ "$diverged_output" == *"diverged"* ]] && printf true || printf false)" "diverged rejection reports both local and remote history"

	git clone -q "$remote" "$fresh"
	local fresh_status=0
	(cd "$fresh" && AIDEVOPS_PROTECTED_BRANCH_CHOICE=2 check_protected_branch chore aidevops-init >/dev/null) || fresh_status=$?
	assert_equal "0" "$fresh_status" "direct protected-branch init remains available when synchronized"

	local helper_agents="${TEST_ROOT}/helper-agents"
	local helper_worktree="${TEST_ROOT}/centralized/helper-worktree"
	mkdir -p "${helper_agents}/scripts" "$(dirname "$helper_worktree")"
	cat >"${helper_agents}/scripts/worktree-helper.sh" <<'HELPEREOF'
#!/usr/bin/env bash
set -euo pipefail
branch_name="$2"
base_ref="HEAD"
[[ "${3:-}" != "--base" ]] || base_ref="$4"
git worktree add -b "$branch_name" "$HELPER_WORKTREE_PATH" "$base_ref"
HELPEREOF
	local helper_status=0
	(cd "$victim" && AGENTS_DIR="$helper_agents" HELPER_WORKTREE_PATH="$helper_worktree" AIDEVOPS_PROTECTED_BRANCH_CHOICE=1 check_protected_branch chore helper-init >/dev/null) || helper_status=$?
	assert_equal "0" "$helper_status" "helper-created worktree resolves its configured centralized path"
	assert_equal "$remote_tip" "$(git -C "$helper_worktree" rev-parse HEAD)" "helper-created worktree starts at the refreshed remote tip"

	local fallback_agents="${TEST_ROOT}/no-helper"
	mkdir -p "$fallback_agents"
	local worktree_status=0
	(cd "$victim" && AGENTS_DIR="$fallback_agents" AIDEVOPS_PROTECTED_BRANCH_CHOICE=1 check_protected_branch chore fallback-init >/dev/null) || worktree_status=$?
	assert_equal "0" "$worktree_status" "stale protected branch can select the safe worktree path"
	assert_equal "$remote_tip" "$(git -C "${TEST_ROOT}/victim-chore-fallback-init" rev-parse HEAD)" "fallback worktree starts at the refreshed remote tip"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap 'rm -rf "$TEST_ROOT"' EXIT
	local remote="${TEST_ROOT}/remote.git" seed="${TEST_ROOT}/seed"
	local victim="${TEST_ROOT}/victim" fresh="${TEST_ROOT}/fresh"
	git init -q --bare "$remote"
	git init -q -b main "$seed"
	git -C "$seed" config user.name "Test User"
	git -C "$seed" config user.email "test@example.invalid"
	commit_file "$seed" "base"
	git -C "$seed" remote add origin "$remote"
	git -C "$seed" push -q -u origin main
	git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
	git clone -q "$remote" "$victim"
	git -C "$victim" config user.name "Test User"
	git -C "$victim" config user.email "test@example.invalid"
	run_freshness_checks "$remote" "$seed" "$victim" "$fresh"

	printf '\n%d tests run, %d failures\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
