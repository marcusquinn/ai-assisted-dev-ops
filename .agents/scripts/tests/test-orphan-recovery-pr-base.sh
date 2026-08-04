#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-orphan-recovery-pr-base.sh — GH#24795/GH#24798 regression guard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SHARED_CLAIM_SCRIPT="${SCRIPT_DIR}/../shared-claim-lifecycle.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export TEST_ROOT
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/calls" "${TEST_ROOT}/home/.config/aidevops"
	export HOME="${TEST_ROOT}/home"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	cat >"${HOME}/.config/aidevops/repos.json" <<'JSON'
{
  "initialized_repos": [
    {"slug": "owner/repo", "pr_base_branch": "develop", "default_branch": "main"},
    {"slug": "exampleorg/examplerepo", "pr_base_branch": "develop", "default_branch": "main"}
  ]
}
JSON
	create_gh_stub
	# shellcheck source=/dev/null
	source "$SHARED_CLAIM_SCRIPT"
	install_test_overrides
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

create_gh_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
	printf 'main\n'
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
	printf '%s\n' "$*" >"${TEST_ROOT}/calls/pr-create.argv"
	exit 0
fi

printf 'unsupported gh invocation in orphan-recovery stub: %s\n' "$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

install_test_overrides() {
	gh_issue_view() {
		local issue_number="$1"
		shift || true
		[[ -n "$issue_number" ]] || return 1
		printf 'OPEN\n'
		return 0
	}

	_pr_exists_for_branch_or_issue() {
		local branch_name="$1"
		local issue_number="$2"
		local repo_slug="$3"
		[[ -n "$branch_name" && -n "$issue_number" && -n "$repo_slug" ]] || return 1
		printf 'absent'
		return 0
	}

	# _attempt_orphan_recovery_pr consumes the richer handoff-state provider
	# directly. Keep this base-selection test independent of live PR discovery.
	_pr_handoff_state_for_branch_or_issue() {
		local branch_name="$1"
		local issue_number="$2"
		local repo_slug="$3"
		[[ -n "$branch_name" && -n "$issue_number" && -n "$repo_slug" ]] || return 1
		printf 'absent|'
		return 0
	}

	_ensure_orphan_recovery_branch_remote() {
		local work_dir="$1"
		local branch_name="$2"
		local issue_number="$3"
		local repo_slug="$4"
		[[ -n "$work_dir" && -n "$branch_name" && -n "$issue_number" && -n "$repo_slug" ]] || return 1
		printf 'remote'
		return 0
	}

	return 0
}

test_orphan_recovery_uses_configured_pr_base() {
	if ! _attempt_orphan_recovery_pr "issue-24798" "$TEST_ROOT" "feature/auto-gh24798" "owner/repo"; then
		print_result "orphan recovery creates PR against configured base" 1 "_attempt_orphan_recovery_pr failed"
		return 0
	fi

	local argv=""
	argv=$(<"${TEST_ROOT}/calls/pr-create.argv")
	if [[ "$argv" == *'--head feature/auto-gh24798 --base develop'* ]] && [[ "$argv" != *'--base main'* ]]; then
		print_result "orphan recovery creates PR against configured base" 0
		return 0
	fi

	print_result "orphan recovery creates PR against configured base" 1 "argv=${argv}"
	return 0
}

test_dirty_recovery_creates_draft_checkpoint() {
	rm -f "${TEST_ROOT}/calls/pr-create.argv"
	if ! _attempt_orphan_recovery_pr "issue-27138" "$TEST_ROOT" "feature/auto-gh27138" "owner/repo" "draft"; then
		print_result "dirty recovery creates draft checkpoint PR" 1 "_attempt_orphan_recovery_pr failed"
		return 0
	fi

	local argv=""
	argv=$(<"${TEST_ROOT}/calls/pr-create.argv")
	if [[ "$argv" == *"--draft"* && "$argv" == *"checkpoint: recover dirty worker worktree for #27138"* ]]; then
		print_result "dirty recovery creates draft checkpoint PR" 0
		return 0
	fi
	print_result "dirty recovery creates draft checkpoint PR" 1 "argv=${argv}"
	return 0
}

test_configured_pr_base_overrides_default_branch() {
	local resolved=""
	resolved=$(_resolve_orphan_recovery_base_branch "exampleorg/examplerepo" "$TEST_ROOT")
	if [[ "$resolved" == "develop" ]]; then
		print_result "configured-base repo uses configured PR base over default branch" 0
		return 0
	fi

	print_result "configured-base repo uses configured PR base over default branch" 1 "resolved=${resolved}"
	return 0
}

test_explicit_dispatch_pr_base_overrides_repo_config() {
	local resolved=""
	WORKER_PR_BASE_BRANCH="release/2026"
	resolved=$(_resolve_orphan_recovery_base_branch "owner/repo" "$TEST_ROOT")
	unset WORKER_PR_BASE_BRANCH

	if [[ "$resolved" == "release/2026" ]]; then
		print_result "explicit dispatch PR base overrides repo configuration" 0
		return 0
	fi

	print_result "explicit dispatch PR base overrides repo configuration" 1 "resolved=${resolved}"
	return 0
}

test_unconfigured_repo_falls_back_to_github_default_branch() {
	local resolved=""
	resolved=$(_resolve_orphan_recovery_base_branch "owner/unconfigured" "$TEST_ROOT")
	if [[ "$resolved" == "main" ]]; then
		print_result "unconfigured repo falls back to GitHub default branch" 0
		return 0
	fi

	print_result "unconfigured repo falls back to GitHub default branch" 1 "resolved=${resolved}"
	return 0
}

main() {
	setup_test_env
	test_orphan_recovery_uses_configured_pr_base
	test_dirty_recovery_creates_draft_checkpoint
	test_configured_pr_base_overrides_default_branch
	test_explicit_dispatch_pr_base_overrides_repo_config
	test_unconfigured_repo_falls_back_to_github_default_branch
	teardown_test_env

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
