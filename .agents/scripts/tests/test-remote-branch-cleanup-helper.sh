#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/remote-branch-cleanup-helper.sh"
GIT_SHIM="${SCRIPTS_DIR}/git"
TEST_ROOT="${PWD}/.agents/tmp/test-remote-branch-cleanup.$$"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

assert_contains() {
	local haystack="$1"
	local needle="$2"
	local message="$3"
	case "$haystack" in
	*"$needle"*) pass "$message" ;;
	*) fail "$message (missing: $needle)" ;;
	esac
	return 0
}

assert_ref_exists() {
	local repo="$1"
	local branch="$2"
	local message="$3"
	git -C "$repo" ls-remote --exit-code origin "refs/heads/${branch}" >/dev/null 2>&1 || fail "$message"
	pass "$message"
	return 0
}

assert_ref_missing() {
	local repo="$1"
	local branch="$2"
	local message="$3"
	if git -C "$repo" ls-remote --exit-code origin "refs/heads/${branch}" >/dev/null 2>&1; then
		fail "$message"
	fi
	pass "$message"
	return 0
}

cleanup() {
	git -C "$TEST_ROOT/repo" worktree remove --force "$TEST_ROOT/active-wt" >/dev/null 2>&1 || true
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

make_commit() {
	local repo="$1"
	local file="$2"
	local content="$3"
	printf '%s\n' "$content" >"${repo}/${file}"
	git -C "$repo" add "$file"
	git -C "$repo" -c commit.gpgsign=false commit -qm "add ${file}"
	return 0
}

make_branch() {
	local repo="$1"
	local branch="$2"
	local file="$3"
	local content="$4"
	git -C "$repo" checkout -q main
	git -C "$repo" checkout -qb "$branch"
	make_commit "$repo" "$file" "$content"
	git -C "$repo" push -q origin "$branch"
	return 0
}

merge_branch_to_main() {
	local repo="$1"
	local branch="$2"
	git -C "$repo" checkout -q main
	git -C "$repo" -c commit.gpgsign=false merge -q --no-ff "$branch" -m "merge ${branch}"
	git -C "$repo" push -q origin main
	return 0
}

advance_origin_main() {
	local origin_repo="$1"
	local update_repo="$2"
	local update_name="${update_repo##*/}"
	git clone -q "$origin_repo" "$update_repo"
	git -C "$update_repo" config user.email test@example.invalid
	git -C "$update_repo" config user.name "Remote Branch Cleanup Test"
	make_commit "$update_repo" "${update_name}.txt" "$update_name"
	git -C "$update_repo" push -q origin main
	return 0
}

install_gh_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${AIDEVOPS_GH_ROUTE_DECISION:-}" "$*" >>"${REMOTE_BRANCH_CLEANUP_GH_CALL_LOG:-/dev/null}"
[[ "${1:-}" == "api" ]] || exit 1
endpoint="${2:-}"
case "$endpoint" in
*"pulls?state=open&per_page=100&page=1"*)
	if [[ "${REMOTE_BRANCH_CLEANUP_STUB_FULL_PAGE:-0}" == "1" ]]; then
		jq -cn '[range(0; 100) | {head: {ref: ("open-pr-" + (. | tostring))}, merged_at: null}]'
	else
		printf '%s\n' '[{"head":{"ref":"open-pr"},"merged_at":null}]'
	fi
	;;
*"pulls?state=open&per_page=100&page=2"*)
	printf '%s\n' '[{"head":{"ref":"open-pr"},"merged_at":null}]'
	;;
*"pulls?state=closed&per_page=100&page=1"*) printf '%s\n' '[]' ;;
*) exit 1 ;;
esac
exit 0
STUB
	chmod +x "${bin_dir}/gh"
	return 0
}

install_readback_failure_git_stub() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/git" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$*" == *"ls-remote --exit-code --heads origin refs/heads/merged-readback"* ]]; then
	exit 1
fi
exec "${GIT_SHIM}" "\$@"
STUB
	chmod +x "${bin_dir}/git"
	return 0
}

setup_repo() {
	mkdir -p "$TEST_ROOT"
	git init -q --bare "$TEST_ROOT/origin.git"
	git clone -q "$TEST_ROOT/origin.git" "$TEST_ROOT/repo"
	git -C "$TEST_ROOT/repo" config user.email test@example.invalid
	git -C "$TEST_ROOT/repo" config user.name "Remote Branch Cleanup Test"
	make_commit "$TEST_ROOT/repo" base.txt base
	git -C "$TEST_ROOT/repo" branch -M main
	git -C "$TEST_ROOT/repo" push -q -u origin main
	git -C "$TEST_ROOT/origin.git" symbolic-ref HEAD refs/heads/main

	make_branch "$TEST_ROOT/repo" merged-safe merged.txt merged
	merge_branch_to_main "$TEST_ROOT/repo" merged-safe

	make_branch "$TEST_ROOT/repo" unmerged unmerged.txt unmerged

	make_branch "$TEST_ROOT/repo" open-pr open.txt open
	merge_branch_to_main "$TEST_ROOT/repo" open-pr

	make_branch "$TEST_ROOT/repo" active-worktree active.txt active
	merge_branch_to_main "$TEST_ROOT/repo" active-worktree
	git -C "$TEST_ROOT/repo" worktree add -q "$TEST_ROOT/active-wt" active-worktree

	git -C "$TEST_ROOT/repo" fetch -q origin
	return 0
}

run_dry_run_assertions() {
	local repo="$1"
	local output gh_calls
	local gh_bin="$TEST_ROOT/bin"
	local gh_call_log="$TEST_ROOT/gh-calls.log"
	install_gh_stub "$gh_bin"
	: >"$gh_call_log"
	output=$(REMOTE_BRANCH_CLEANUP_GH_CALL_LOG="$gh_call_log" \
		REMOTE_BRANCH_CLEANUP_STUB_FULL_PAGE=1 \
		PATH="$gh_bin:$PATH" bash "$HELPER" --repo "$repo" --skip-fetch)
	gh_calls=$(<"$gh_call_log")

	assert_contains "$output" "would-del  merged-safe" "merged branch is a deletion candidate"
	assert_contains "$output" "review     unmerged" "unmerged branch is manual-review only"
	assert_contains "$output" "skip       open-pr" "open PR branch is skipped"
	assert_contains "$output" "open PR exists" "open PR skip reason is shown"
	assert_contains "$output" "skip       active-worktree" "active worktree branch is skipped"
	assert_contains "$output" "protected/default branch" "default branch is protected"
	assert_contains "$output" "Dry-run only" "default mode is dry-run"
	assert_contains "$gh_calls" "remote-branch-cleanup-pr-branches-rest|api repos/" "PR branch evidence uses attributed REST reads"
	assert_contains "$gh_calls" "pulls?state=open&per_page=100&page=1" "open PR branches use the first bounded REST page"
	assert_contains "$gh_calls" "pulls?state=open&per_page=100&page=2" "a full first page reads the second bounded REST page"
	if [[ "$gh_calls" == *"page=3"* || "$gh_calls" == *"--paginate"* ]]; then
		fail "remote branch cleanup must not exceed its two-page REST bound"
	fi
	pass "remote branch cleanup caps REST history reads at two pages"
	if [[ "$gh_calls" == *"pr list"* ]]; then
		fail "remote branch cleanup must not use native gh pr list"
	fi
	pass "remote branch cleanup avoids native gh pr list"
	return 0
}

run_apply_assertions() {
	local repo="$1"
	local gh_bin="$TEST_ROOT/bin"
	local repos_file="$TEST_ROOT/repos.json"
	local worktree_base="$TEST_ROOT/worktrees"
	local direct_output=""
	local direct_rc=0
	printf '{"initialized_repos":[{"path":"%s"}]}\n' "$repo" >"$repos_file"
	if direct_output=$(cd "$repo" && AIDEVOPS_REPOS_FILE="$repos_file" PATH="$SCRIPTS_DIR:$PATH" git push origin --delete merged-safe 2>&1); then
		fail "direct canonical git push must remain blocked"
	else
		direct_rc=$?
	fi
	[[ "$direct_rc" -eq 42 ]] || fail "direct canonical git push returns guard exit 42 (rc=$direct_rc)"
	assert_contains "$direct_output" "BLOCKED by canonical Git guard" "direct canonical git push remains blocked"
	assert_ref_exists "$repo" merged-safe "blocked direct push preserves merged branch"

	AIDEVOPS_REPOS_FILE="$repos_file" \
		AIDEVOPS_WORKTREE_BASE_DIR="$worktree_base" \
		PATH="$SCRIPTS_DIR:$gh_bin:$PATH" \
		bash "$HELPER" --repo "$repo" --skip-fetch --apply >/dev/null

	assert_ref_missing "$repo" merged-safe "apply deletes merged safe branch"
	assert_ref_exists "$repo" unmerged "apply preserves unmerged branch"
	assert_ref_exists "$repo" open-pr "apply preserves open PR branch"
	assert_ref_exists "$repo" active-worktree "apply preserves active worktree branch"
	assert_ref_exists "$repo" main "apply preserves default branch"
	if git -C "$repo" worktree list --porcelain | grep -F "$worktree_base" >/dev/null 2>&1; then
		fail "apply must remove its isolated deletion transport"
	fi
	pass "apply removes its isolated deletion transport"
	return 0
}

run_readback_failure_assertions() {
	local repo="$1"
	local gh_bin="$TEST_ROOT/bin"
	local git_bin="$TEST_ROOT/readback-bin"
	local repos_file="$TEST_ROOT/repos.json"
	local worktree_base="$TEST_ROOT/worktrees"
	local output=""
	local rc=0

	make_branch "$repo" merged-readback merged-readback.txt merged-readback
	merge_branch_to_main "$repo" merged-readback
	git -C "$repo" fetch -q origin
	install_readback_failure_git_stub "$git_bin"
	if output=$(AIDEVOPS_REPOS_FILE="$repos_file" \
		AIDEVOPS_WORKTREE_BASE_DIR="$worktree_base" \
		PATH="$git_bin:$gh_bin:$PATH" \
		bash "$HELPER" --repo "$repo" --skip-fetch --apply 2>&1); then
		fail "apply must fail when remote absence read-back is indeterminate"
	else
		rc=$?
	fi
	[[ "$rc" -eq 1 ]] || fail "indeterminate read-back returns terminal failure (rc=$rc)"
	assert_contains "$output" "remote absence verification failed" "apply reports indeterminate remote read-back"
	assert_ref_missing "$repo" merged-readback "fixture confirms deletion occurred before read-back failure"
	return 0
}

run_sync_assertions() {
	local origin_repo="$TEST_ROOT/sync-origin.git"
	local repo="$TEST_ROOT/sync-repo"
	local output ahead_count
	git init -q --bare "$origin_repo"
	git clone -q "$origin_repo" "$repo"
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name "Remote Branch Cleanup Test"
	make_commit "$repo" base.txt base
	git -C "$repo" branch -M main
	git -C "$repo" push -q -u origin main
	git -C "$origin_repo" symbolic-ref HEAD refs/heads/main

	advance_origin_main "$origin_repo" "$TEST_ROOT/sync-updater"
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo")
	assert_contains "$output" "would-ff" "dry-run reports pending default-branch fast-forward"
	assert_contains "$output" "behind origin/main; dry-run only" "dry-run explains sync is not applied"
	ahead_count=$(git -C "$repo" rev-list --count HEAD..origin/main)
	[[ "$ahead_count" == "1" ]] || fail "dry-run must not fast-forward local main"
	pass "dry-run leaves local main behind origin/main"

	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "fast-fwd" "apply fast-forwards clean default branch"
	ahead_count=$(git -C "$repo" rev-list --count HEAD..origin/main)
	[[ "$ahead_count" == "0" ]] || fail "apply should fast-forward local main"
	pass "apply reconciles local main with origin/main"

	git -C "$repo" checkout -qb feature-work
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "not default branch (main)" "non-default branch sync is skipped"

	git -C "$repo" checkout -q main
	advance_origin_main "$origin_repo" "$TEST_ROOT/sync-updater-dirty"
	printf '%s\n' dirty >>"${repo}/base.txt"
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "worktree or index is dirty" "dirty default branch sync is skipped"
	git -C "$repo" reset --hard -q HEAD
	git -C "$repo" merge --ff-only -q origin/main

	make_commit "$repo" local-ahead.txt local-ahead
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "local branch is ahead of origin/main" "ahead default branch sync is skipped"

	advance_origin_main "$origin_repo" "$TEST_ROOT/sync-updater-diverged"
	output=$(AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH=1 bash "$HELPER" --repo "$repo" --apply)
	assert_contains "$output" "local branch has diverged from origin/main" "diverged default branch sync is skipped"
	return 0
}

main() {
	setup_repo
	run_dry_run_assertions "$TEST_ROOT/repo"
	run_apply_assertions "$TEST_ROOT/repo"
	run_readback_failure_assertions "$TEST_ROOT/repo"
	run_sync_assertions
	return 0
}

main "$@"
