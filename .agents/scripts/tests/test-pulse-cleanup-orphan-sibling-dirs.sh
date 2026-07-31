#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
if [[ -d "$ROOT_DIR/.agents/scripts" ]]; then
	AGENTS_SCRIPTS_DIR="$ROOT_DIR/.agents/scripts"
else
	AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

# Keep temporary fixture repositories on native Git; canonical mutation-guard
# behavior is covered by its dedicated tests.
git() {
	"$GIT_BIN" "$@"
	return $?
}

TEST_ROOT=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CI_REPAIR_REPO_HASH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CI_REPAIR_HEAD_PREFIX="bbbbbbbbbbbb"
CI_REPAIR_FINGERPRINT_PREFIX="cccccccccccc"
CI_REPAIR_VALID_NAME="aidevops-${CI_REPAIR_REPO_HASH}-ci-repair-pr28995-${CI_REPAIR_HEAD_PREFIX}-${CI_REPAIR_FINGERPRINT_PREFIX}-a1"
CI_REPAIR_OPEN_NAME="aidevops-${CI_REPAIR_REPO_HASH}-ci-repair-pr28996-${CI_REPAIR_HEAD_PREFIX}-${CI_REPAIR_FINGERPRINT_PREFIX}-a1"
CI_REPAIR_BAD_HASH_NAME="aidevops-${CI_REPAIR_REPO_HASH%?}-ci-repair-pr28995-${CI_REPAIR_HEAD_PREFIX}-${CI_REPAIR_FINGERPRINT_PREFIX}-a1"
CI_REPAIR_BAD_PR_NAME="aidevops-${CI_REPAIR_REPO_HASH}-ci-repair-pr0-${CI_REPAIR_HEAD_PREFIX}-${CI_REPAIR_FINGERPRINT_PREFIX}-a1"
CI_REPAIR_BAD_ATTEMPT_NAME="aidevops-${CI_REPAIR_REPO_HASH}-ci-repair-pr28995-${CI_REPAIR_HEAD_PREFIX}-${CI_REPAIR_FINGERPRINT_PREFIX}-a0"

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '  %s\n' "$message"
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

setup_fixture() {
	TEST_ROOT=$(mktemp -d)
	trap teardown EXIT
	export HOME="$TEST_ROOT/home"
	export LOGFILE="$TEST_ROOT/cleanup.log"
	export AIDEVOPS_ORPHAN_TRASH_ROOT="$TEST_ROOT/trash"
	export ORPHAN_WORKTREE_GRACE_SECS=0
	mkdir -p "$HOME/.config/aidevops" "$TEST_ROOT/Git" "$TEST_ROOT/Git/_worktrees" "$AIDEVOPS_ORPHAN_TRASH_ROOT"

	local repo="$TEST_ROOT/Git/aidevops"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name 'Aidevops Test'
	printf 'base\n' >"$repo/README.md"
	git -C "$repo" add README.md
	git -C "$repo" commit -q -m 'init'

	cat >"$HOME/.config/aidevops/repos.json" <<JSON
{"worktree_base_dir":"$TEST_ROOT/Git/_worktrees","initialized_repos":[{"path":"$repo","slug":"example/aidevops","local_only":false}]}
JSON

	# Registered valid worktree: matches worker naming but must be preserved.
	git -C "$repo" worktree add -q "$TEST_ROOT/Git/aidevops-feature-auto-registered" -b feature/auto-registered

	# Broken unregistered gitfile worktree-like directory: screenshot outlier class.
	mkdir -p "$TEST_ROOT/Git/aidevops-feature-auto-20260416-154130-gh19261"
	printf 'gitdir: %s\n' "$TEST_ROOT/missing/gitdir" >"$TEST_ROOT/Git/aidevops-feature-auto-20260416-154130-gh19261/.git"

	# Non-git worker-looking leftover directory: screenshot outlier class.
	mkdir -p "$TEST_ROOT/Git/aidevops-feature-auto-20260505-gh22927-dispatch-recovery"
	printf 'leftover\n' >"$TEST_ROOT/Git/aidevops-feature-auto-20260505-gh22927-dispatch-recovery/NOTE.txt"

	# General feature branch and legacy dot-separated worker names are outliers too.
	mkdir -p "$TEST_ROOT/Git/aidevops-feature-t2147-contributor-insight-pipeline"
	printf 'gitdir: %s\n' "$TEST_ROOT/missing/feature-t2147" >"$TEST_ROOT/Git/aidevops-feature-t2147-contributor-insight-pipeline/.git"
	mkdir -p "$TEST_ROOT/Git/aidevops.bugfix-skill-tag-rename"
	printf 'legacy\n' >"$TEST_ROOT/Git/aidevops.bugfix-skill-tag-rename/NOTE.txt"
	mkdir -p "$TEST_ROOT/Git/_worktrees/aidevops-feature-central-leftover"
	printf 'central leftover\n' >"$TEST_ROOT/Git/_worktrees/aidevops-feature-central-leftover/NOTE.txt"
	mkdir -p "$TEST_ROOT/Git/_worktrees/aidevops.bugfix-central-leftover"
	printf 'central legacy\n' >"$TEST_ROOT/Git/_worktrees/aidevops.bugfix-central-leftover/NOTE.txt"

	# Exact current ci-repair grammar is eligible; near-matches are preserved.
	mkdir -p "$TEST_ROOT/Git/_worktrees/$CI_REPAIR_VALID_NAME"
	printf 'ci repair leftover\n' >"$TEST_ROOT/Git/_worktrees/$CI_REPAIR_VALID_NAME/NOTE.txt"
	mkdir -p "$TEST_ROOT/Git/_worktrees/$CI_REPAIR_OPEN_NAME"
	printf 'open ci repair\n' >"$TEST_ROOT/Git/_worktrees/$CI_REPAIR_OPEN_NAME/NOTE.txt"
	mkdir -p "$TEST_ROOT/Git/_worktrees/$CI_REPAIR_BAD_HASH_NAME"
	mkdir -p "$TEST_ROOT/Git/_worktrees/$CI_REPAIR_BAD_PR_NAME"
	mkdir -p "$TEST_ROOT/Git/_worktrees/$CI_REPAIR_BAD_ATTEMPT_NAME"

	# Standalone repo: must not be trashed automatically.
	mkdir -p "$TEST_ROOT/Git/aidevops-cloudron-app"
	git -C "$TEST_ROOT/Git/aidevops-cloudron-app" init -q

	# Clean generated release clone under the worktree base: recoverable cruft.
	mkdir -p "$TEST_ROOT/Git/_worktrees/aidevops-release-clone-3.31.57"
	git -C "$TEST_ROOT/Git/_worktrees/aidevops-release-clone-3.31.57" init -q -b main
	git -C "$TEST_ROOT/Git/_worktrees/aidevops-release-clone-3.31.57" config user.email test@example.invalid
	git -C "$TEST_ROOT/Git/_worktrees/aidevops-release-clone-3.31.57" config user.name 'Aidevops Test'
	printf 'release\n' >"$TEST_ROOT/Git/_worktrees/aidevops-release-clone-3.31.57/README.md"
	git -C "$TEST_ROOT/Git/_worktrees/aidevops-release-clone-3.31.57" add README.md
	git -C "$TEST_ROOT/Git/_worktrees/aidevops-release-clone-3.31.57" commit -q -m 'release clone'

	return 0
}

load_subject() {
	# shellcheck source=../shared-constants.sh
	source "$AGENTS_SCRIPTS_DIR/shared-constants.sh"
	# shellcheck source=../pulse-cleanup.sh
	source "$AGENTS_SCRIPTS_DIR/pulse-cleanup.sh"
	gh() {
		if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
			case "${3:-}" in
			28995)
				printf 'CLOSED\n'
				return 0
				;;
			28996)
				printf 'OPEN\n'
				return 0
				;;
			esac
		fi
		return 1
	}
	return 0
}

test_ci_repair_sibling_name_validation() {
	local rc=0
	_pc_orphan_sibling_name_allowed "aidevops" "$CI_REPAIR_VALID_NAME" || rc=1
	_pc_orphan_sibling_name_allowed "aidevops" "$CI_REPAIR_OPEN_NAME" || rc=1
	_pc_orphan_sibling_pr_state_allowed "example/aidevops" "aidevops" "$CI_REPAIR_VALID_NAME" || rc=1
	if _pc_orphan_sibling_pr_state_allowed "example/aidevops" "aidevops" "$CI_REPAIR_OPEN_NAME"; then
		rc=1
	fi
	if _pc_orphan_sibling_name_allowed "aidevops" "$CI_REPAIR_BAD_HASH_NAME"; then
		rc=1
	fi
	if _pc_orphan_sibling_name_allowed "aidevops" "$CI_REPAIR_BAD_PR_NAME"; then
		rc=1
	fi
	if _pc_orphan_sibling_name_allowed "aidevops" "$CI_REPAIR_BAD_ATTEMPT_NAME"; then
		rc=1
	fi
	print_result "ci-repair sibling allowlist accepts only producer-compatible names" "$rc"
	return 0
}

test_orphan_sibling_dirs_move_to_trash_only() {
	local repo_json="$HOME/.config/aidevops/repos.json"
	local moved_count
	moved_count=$(_pc_cleanup_orphan_sibling_dirs "$repo_json" "$(date +%s)")

	if [[ "$moved_count" -ne 8 ]]; then
		print_result "orphan sibling cleanup moves eligible sibling and centralized outliers" 1 "expected 8 moved, got $moved_count"
		return 0
	fi

	if [[ -d "$TEST_ROOT/Git/aidevops-feature-auto-registered" ]]; then
		print_result "registered worktree is preserved" 0
	else
		print_result "registered worktree is preserved" 1 "registered worktree was removed"
	fi

	if [[ -d "$TEST_ROOT/Git/aidevops-cloudron-app/.git" ]]; then
		print_result "standalone git repo is preserved" 0
	else
		print_result "standalone git repo is preserved" 1 "standalone repo was removed"
	fi

	local trashed_count
	trashed_count=0
	local trash_bucket trashed_dir
	for trash_bucket in "$AIDEVOPS_ORPHAN_TRASH_ROOT"/*; do
		[[ -d "$trash_bucket" ]] || continue
		for trashed_dir in "$trash_bucket"/*; do
			[[ -d "$trashed_dir" ]] || continue
			trashed_count=$((trashed_count + 1))
		done
	done
	if [[ "$trashed_count" -eq 8 ]]; then
		print_result "eligible outliers are recoverable in trash bucket" 0
	else
		print_result "eligible outliers are recoverable in trash bucket" 1 "expected 8 trashed dirs, got $trashed_count"
	fi

	local malformed_preserved=0
	if [[ -d "$TEST_ROOT/Git/_worktrees/$CI_REPAIR_BAD_HASH_NAME" &&
		-d "$TEST_ROOT/Git/_worktrees/$CI_REPAIR_BAD_PR_NAME" &&
		-d "$TEST_ROOT/Git/_worktrees/$CI_REPAIR_BAD_ATTEMPT_NAME" ]]; then
		malformed_preserved=1
	fi
	if [[ "$malformed_preserved" -eq 1 ]]; then
		print_result "malformed ci-repair sibling names are preserved" 0
	else
		print_result "malformed ci-repair sibling names are preserved" 1
	fi
	if [[ -d "$TEST_ROOT/Git/_worktrees/$CI_REPAIR_OPEN_NAME" ]]; then
		print_result "open ci-repair sibling is preserved" 0
	else
		print_result "open ci-repair sibling is preserved" 1
	fi
	return 0
}

test_standalone_clean_check_requires_successful_status() {
	local candidate_path="$TEST_ROOT/Git/_worktrees/aidevops-release-clone-status-fails"
	mkdir -p "$candidate_path/.git"

	local fake_bin="$TEST_ROOT/fake-bin"
	mkdir -p "$fake_bin"
	cat >"$fake_bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-C" ]]; then
	shift 2
fi
case "${1:-} ${2:-}" in
"branch --show-current")
	printf 'main\n'
	exit 0
	;;
"status --porcelain")
	exit 128
	;;
*)
	exit 1
	;;
esac
SH
	chmod +x "$fake_bin/git"

	local old_path="$PATH"
	PATH="$fake_bin:$PATH"
	local reason=""
	set +e
	reason=$(_pc_classify_orphan_sibling_dir "$TEST_ROOT/Git/aidevops" "$candidate_path" "$(date +%s)")
	local rc=$?
	set -e
	PATH="$old_path"

	if [[ "$rc" -eq 1 && -z "$reason" ]]; then
		print_result "standalone clean check requires successful git status" 0
	else
		print_result "standalone clean check requires successful git status" 1 "expected preserve on failed status, got rc=$rc reason=$reason"
	fi
	return 0
}

main() {
	if ! command -v jq >/dev/null 2>&1; then
		printf 'SKIP jq unavailable\n'
		return 0
	fi
	setup_fixture
	load_subject
	test_ci_repair_sibling_name_validation
	test_orphan_sibling_dirs_move_to_trash_only
	test_standalone_clean_check_requires_successful_status
	printf '\n%d/%d tests passed\n' "$TESTS_PASSED" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
