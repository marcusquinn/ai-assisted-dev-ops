#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#27902: commit-and-pr must replace temporary WIP
# history with one conventional final commit before validation and publication.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message"
	return 0
}

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message" >&2
	return 0
}

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message" >&2
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPT_DIR}/full-loop-helper-commit.sh"

GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
git() {
	"$GIT_BIN" "$@"
	return $?
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

make_repo() {
	local repo_dir="$1"
	mkdir -p "$repo_dir"
	(
		cd "$repo_dir" || exit 1
		git init -q
		git config user.name 'Test User'
		git config user.email 'test@example.invalid'
		git config commit.gpgsign false
		printf 'base\n' >tracked.txt
		git add tracked.txt
		git commit -qm 'chore: initial fixture'
		git branch -M develop
		git remote add origin .
		git update-ref refs/remotes/origin/develop HEAD
		git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
		git switch -qc feature/test
	) || return 1
	return 0
}

commit_change() {
	local repo_dir="$1"
	local content="$2"
	local subject="$3"
	(
		cd "$repo_dir" || exit 1
		printf '%s\n' "$content" >>tracked.txt
		git add tracked.txt
		git commit -qm "$subject"
	) || return 1
	return 0
}

test_single_wip_is_finalized() {
	local repo_dir="${TEST_ROOT}/single-wip"
	make_repo "$repo_dir" || return 1
	commit_change "$repo_dir" 'single' 'wip: preserve single change' || return 1
	local original_head=""
	original_head=$(git -C "$repo_dir" rev-parse HEAD)
	(
		cd "$repo_dir" || exit 1
		_finalize_wip_history 'fix: finalize single change'
	) >/dev/null 2>&1
	local rc=$?
	local subject="" count="" final_head="" content=""
	subject=$(git -C "$repo_dir" log -1 --format=%s)
	count=$(git -C "$repo_dir" rev-list --count origin/develop..HEAD)
	final_head=$(git -C "$repo_dir" rev-parse HEAD)
	content=$(git -C "$repo_dir" show HEAD:tracked.txt)
	if [[ "$rc" -eq 0 && "$subject" == 'fix: finalize single change' && "$count" == '1' &&
		"$final_head" != "$original_head" && "$content" == $'base\nsingle' ]]; then
		print_result 'single WIP becomes one final commit' 0
	else
		print_result 'single WIP becomes one final commit' 1 "rc=${rc}, subject=${subject}, count=${count}"
	fi
	return 0
}

test_buried_wip_squashes_branch_range() {
	local repo_dir="${TEST_ROOT}/buried-wip"
	make_repo "$repo_dir" || return 1
	commit_change "$repo_dir" 'first' 'fix: first logical change' || return 1
	commit_change "$repo_dir" 'checkpoint' 'wip: preserve checkpoint' || return 1
	commit_change "$repo_dir" 'last' 'test: add coverage' || return 1
	(
		cd "$repo_dir" || exit 1
		_finalize_wip_history 'fix: publish complete branch'
	) >/dev/null 2>&1
	local rc=$?
	local subjects="" count="" content=""
	subjects=$(git -C "$repo_dir" log --format=%s origin/develop..HEAD)
	count=$(git -C "$repo_dir" rev-list --count origin/develop..HEAD)
	content=$(git -C "$repo_dir" show HEAD:tracked.txt)
	if [[ "$rc" -eq 0 && "$subjects" == 'fix: publish complete branch' && "$count" == '1' &&
		"$content" == $'base\nfirst\ncheckpoint\nlast' ]]; then
		print_result 'buried WIP squashes the complete branch range' 0
	else
		print_result 'buried WIP squashes the complete branch range' 1 "rc=${rc}, subjects=${subjects}, count=${count}"
	fi
	return 0
}

test_no_wip_preserves_history() {
	local repo_dir="${TEST_ROOT}/no-wip"
	make_repo "$repo_dir" || return 1
	commit_change "$repo_dir" 'first' 'fix: first change' || return 1
	commit_change "$repo_dir" 'second' 'test: second change' || return 1
	local original_head=""
	original_head=$(git -C "$repo_dir" rev-parse HEAD)
	(
		cd "$repo_dir" || exit 1
		_finalize_wip_history 'fix: unused replacement subject'
	) >/dev/null 2>&1
	local rc=$?
	local final_head="" count=""
	final_head=$(git -C "$repo_dir" rev-parse HEAD)
	count=$(git -C "$repo_dir" rev-list --count origin/develop..HEAD)
	if [[ "$rc" -eq 0 && "$final_head" == "$original_head" && "$count" == '2' ]]; then
		print_result 'branch without WIP preserves commit history' 0
	else
		print_result 'branch without WIP preserves commit history' 1 "rc=${rc}, count=${count}"
	fi
	return 0
}

test_non_wip_base_drift_reaches_normal_rebase() {
	local repo_dir="${TEST_ROOT}/non-wip-base-drift"
	make_repo "$repo_dir" || return 1
	commit_change "$repo_dir" 'feature' 'fix: preserve feature change' || return 1
	local original_head=""
	original_head=$(git -C "$repo_dir" rev-parse HEAD)

	(
		cd "$repo_dir" || exit 1
		git switch -q --detach origin/develop
		printf 'upstream\n' >upstream.txt
		git add upstream.txt
		git commit -qm 'fix: concurrent upstream change'
		git branch -f develop HEAD
		git switch -q --detach "$original_head"
		_finalize_wip_history 'fix: preserve feature change' &&
			_rebase_for_push 'feature/test' 0
	) >/dev/null 2>&1
	local rc=$?
	local count="" subject="" status="" content=""
	count=$(git -C "$repo_dir" rev-list --count origin/develop..HEAD)
	subject=$(git -C "$repo_dir" log -1 --format=%s)
	status=$(git -C "$repo_dir" status --porcelain)
	content=$(git -C "$repo_dir" show HEAD:tracked.txt)
	if [[ "$rc" -eq 0 && "$count" == '1' && "$subject" == 'fix: preserve feature change' &&
		-z "$status" && "$content" == $'base\nfeature' ]] &&
		git -C "$repo_dir" merge-base --is-ancestor origin/develop HEAD &&
		git -C "$repo_dir" show HEAD:upstream.txt >/dev/null 2>&1; then
		print_result 'non-WIP base drift reaches normal rebase without upstream reversions' 0
	else
		print_result 'non-WIP base drift reaches normal rebase without upstream reversions' 1 \
			"rc=${rc}, count=${count}, subject=${subject}, status=${status}"
	fi
	return 0
}

test_commit_hook_failure_restores_tip() {
	local repo_dir="${TEST_ROOT}/hook-failure"
	make_repo "$repo_dir" || return 1
	commit_change "$repo_dir" 'checkpoint' 'wip: preserve before failing hook' || return 1
	local original_head=""
	original_head=$(git -C "$repo_dir" rev-parse HEAD)
	printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"${repo_dir}/.git/hooks/commit-msg"
	chmod +x "${repo_dir}/.git/hooks/commit-msg"
	(
		cd "$repo_dir" || exit 1
		_finalize_wip_history 'fix: hook should reject this'
	) >/dev/null 2>&1
	local rc=$?
	local final_head="" status=""
	final_head=$(git -C "$repo_dir" rev-parse HEAD)
	status=$(git -C "$repo_dir" status --porcelain)
	if [[ "$rc" -ne 0 && "$final_head" == "$original_head" && -z "$status" ]]; then
		print_result 'commit-hook failure restores original WIP tip' 0
	else
		print_result 'commit-hook failure restores original WIP tip' 1 "rc=${rc}, status=${status}"
	fi
	return 0
}

test_wip_final_message_is_rejected() {
	local repo_dir="${TEST_ROOT}/wip-message"
	make_repo "$repo_dir" || return 1
	commit_change "$repo_dir" 'checkpoint' 'wip: preserve checkpoint' || return 1
	local original_head=""
	original_head=$(git -C "$repo_dir" rev-parse HEAD)
	(
		cd "$repo_dir" || exit 1
		_finalize_wip_history 'wip: still temporary'
	) >/dev/null 2>&1
	local rc=$?
	local final_head=""
	final_head=$(git -C "$repo_dir" rev-parse HEAD)
	if [[ "$rc" -ne 0 && "$final_head" == "$original_head" ]]; then
		print_result 'WIP final message is rejected without rewriting history' 0
	else
		print_result 'WIP final message is rejected without rewriting history' 1 "rc=${rc}"
	fi
	return 0
}

test_base_drift_fails_closed_without_reverting_upstream() {
	local repo_dir="${TEST_ROOT}/base-drift"
	make_repo "$repo_dir" || return 1
	commit_change "$repo_dir" 'checkpoint' 'wip: preserve checkpoint' || return 1
	local original_head=""
	original_head=$(git -C "$repo_dir" rev-parse HEAD)

	(
		cd "$repo_dir" || exit 1
		git switch -q --detach origin/develop
		printf 'upstream\n' >upstream.txt
		git add upstream.txt
		git commit -qm 'fix: concurrent upstream change'
		git branch -f develop HEAD
		git switch -q --detach "$original_head"
		_finalize_wip_history 'fix: preserve concurrent upstream change'
	) >/dev/null 2>&1
	local rc=$?
	local final_head=""
	final_head=$(git -C "$repo_dir" rev-parse HEAD)
	if [[ "$rc" -ne 0 && "$final_head" == "$original_head" ]] &&
		git -C "$repo_dir" show origin/develop:upstream.txt >/dev/null 2>&1; then
		print_result 'concurrent base drift aborts without staging upstream reversions' 0
	else
		print_result 'concurrent base drift aborts without staging upstream reversions' 1 \
			"rc=${rc}, final_head=${final_head}, original_head=${original_head}"
	fi
	return 0
}

test_orchestrator_finalizes_before_validation() {
	local orchestrator="${SCRIPT_DIR}/full-loop-helper.sh"
	local stage_line="" finalize_line="" validators_line=""
	# Literal caller variable names are the integration contract under test.
	# shellcheck disable=SC2016
	stage_line=$(grep -n '_stage_and_commit "\$commit_message"' "$orchestrator" | cut -d: -f1)
	# shellcheck disable=SC2016
	finalize_line=$(grep -n '_finalize_wip_history "\$commit_message"' "$orchestrator" | cut -d: -f1)
	# shellcheck disable=SC2016
	validators_line=$(grep -n '_run_project_validators "\$skip_hooks"' "$orchestrator" | cut -d: -f1)
	if [[ "$stage_line" =~ ^[0-9]+$ && "$finalize_line" =~ ^[0-9]+$ && "$validators_line" =~ ^[0-9]+$ &&
		"$stage_line" -lt "$finalize_line" && "$finalize_line" -lt "$validators_line" ]]; then
		print_result 'commit-and-pr finalizes WIP before project validation' 0
	else
		print_result 'commit-and-pr finalizes WIP before project validation' 1 \
			"stage=${stage_line}, finalize=${finalize_line}, validators=${validators_line}"
	fi
	return 0
}

test_single_wip_is_finalized
test_buried_wip_squashes_branch_range
test_no_wip_preserves_history
test_non_wip_base_drift_reaches_normal_rebase
test_commit_hook_failure_restores_tip
test_wip_final_message_is_rejected
test_base_drift_fails_closed_without_reverting_upstream
test_orchestrator_finalizes_before_validation

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_RUN" -ne 8 ]]; then
	printf '%sFAIL%s expected 8 tests to execute\n' "$TEST_RED" "$TEST_RESET"
	exit 1
fi
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
