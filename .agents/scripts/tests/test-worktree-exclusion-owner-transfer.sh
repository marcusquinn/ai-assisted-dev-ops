#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for t18098 worktree exclusion ownership transfer.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
AGENT_SCRIPTS_DIR="${TEST_SCRIPT_DIR}/.."
ORIGINAL_PATH="$PATH"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

# shellcheck source=../shared-constants.sh
source "${AGENT_SCRIPTS_DIR}/shared-constants.sh"
SCRIPT_DIR="$AGENT_SCRIPTS_DIR"
# shellcheck source=../worktree-exclusions-helper.sh
source "${AGENT_SCRIPTS_DIR}/worktree-exclusions-helper.sh"
# shellcheck source=../worktree-helper-add.sh
source "${AGENT_SCRIPTS_DIR}/worktree-helper-add.sh"
# shellcheck source=../headless-runtime-worker.sh
source "${AGENT_SCRIPTS_DIR}/headless-runtime-worker.sh"
# shellcheck source=../headless-runtime-failure.sh
source "${AGENT_SCRIPTS_DIR}/headless-runtime-failure.sh"

print_result() {
	local test_name="$1"
	local result="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s: %s\n' "$test_name" "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/home/.aidevops/agents/scripts"
	cat >"${TEST_ROOT}/bin/tmutil" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "isexcluded" ]]; then
	printf '[Excluded] test\n'
fi
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/tmutil"
	export HOME="${TEST_ROOT}/home"
	export PATH="${TEST_ROOT}/bin:${ORIGINAL_PATH}"
	set_platform "Darwin"
	return 0
}

set_platform() {
	local platform="$1"
	cat >"${TEST_ROOT}/bin/uname" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '${platform}'
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/uname"
	return 0
}

teardown_test_env() {
	export PATH="$ORIGINAL_PATH"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

fixture_git() {
	if /usr/bin/git "$@"; then
		return 0
	fi
	return 1
}

create_fixture() {
	local fixture_name="$1"
	FIXTURE_ROOT="${TEST_ROOT}/${fixture_name}"
	FIXTURE_ORIGIN="${FIXTURE_ROOT}/origin.git"
	FIXTURE_REPO="${FIXTURE_ROOT}/repo"
	FIXTURE_WORKTREE="${FIXTURE_ROOT}/worktree"
	mkdir -p "$FIXTURE_ROOT"
	fixture_git init --bare -q --initial-branch=main "$FIXTURE_ORIGIN"
	local empty_tree=""
	local seed_commit=""
	empty_tree=$(fixture_git --git-dir="$FIXTURE_ORIGIN" mktree </dev/null)
	seed_commit=$(printf 'test: seed\n' | fixture_git --git-dir="$FIXTURE_ORIGIN" \
		-c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" commit-tree "$empty_tree")
	fixture_git --git-dir="$FIXTURE_ORIGIN" update-ref refs/heads/main "$seed_commit"
	fixture_git clone -q "$FIXTURE_ORIGIN" "$FIXTURE_REPO"
	fixture_git -C "$FIXTURE_REPO" worktree add -q -b "feature/${fixture_name}" "$FIXTURE_WORKTREE" origin/main
	return 0
}

fixture_exclude_file() {
	local worktree_path="$1"
	git -C "$worktree_path" rev-parse --git-path info/exclude
	return 0
}

test_fresh_and_reused_worktree_stay_clean() {
	create_fixture "fresh"
	cmd_apply "$FIXTURE_WORKTREE"
	cmd_apply "$FIXTURE_WORKTREE"
	local status_output=""
	local exclude_file=""
	local marker_count="0"
	status_output=$(git -C "$FIXTURE_WORKTREE" status --porcelain)
	exclude_file=$(fixture_exclude_file "$FIXTURE_WORKTREE")
	marker_count=$(grep -Fxc '/.metadata_never_index' "$exclude_file" || true)
	if [[ -f "${FIXTURE_WORKTREE}/.metadata_never_index" && -z "$status_output" && "$marker_count" -eq 1 ]] &&
		git -C "$FIXTURE_WORKTREE" check-ignore -q --no-index .metadata_never_index; then
		print_result "fresh and reused macOS worktrees keep one ignored marker" 0
		return 0
	fi
	print_result "fresh and reused macOS worktrees keep one ignored marker" 1 \
		"status=${status_output:-<clean>} marker_count=${marker_count}"
	return 0
}

test_marker_collisions_remain_task_state() {
	local collision_kind=""
	local result=0
	local status_output=""
	local exclude_file=""
	for collision_kind in non-empty directory symlink; do
		create_fixture "collision-${collision_kind}"
		case "$collision_kind" in
			non-empty)
				printf 'task data\n' >"${FIXTURE_WORKTREE}/.metadata_never_index"
				;;
			directory)
				mkdir "${FIXTURE_WORKTREE}/.metadata_never_index"
				printf 'task data\n' >"${FIXTURE_WORKTREE}/.metadata_never_index/task.txt"
				;;
			symlink)
				printf 'task data\n' >"${FIXTURE_ROOT}/symlink-target"
				ln -s "${FIXTURE_ROOT}/symlink-target" "${FIXTURE_WORKTREE}/.metadata_never_index"
				;;
		esac
		cmd_apply "$FIXTURE_WORKTREE"
		status_output=$(git -C "$FIXTURE_WORKTREE" status --porcelain)
		exclude_file=$(fixture_exclude_file "$FIXTURE_WORKTREE")
		if [[ -z "$status_output" ]] ||
			grep -Fqx '/.metadata_never_index' "$exclude_file" 2>/dev/null ||
			git -C "$FIXTURE_WORKTREE" check-ignore -q --no-index .metadata_never_index 2>/dev/null ||
			_hrw_worktree_clean_for_owner_reclaim "$FIXTURE_WORKTREE"; then
			result=1
		fi
	done
	print_result "Spotlight marker collisions remain visible task state" "$result" \
		"last_kind=${collision_kind} status=${status_output:-<clean>}"
	return 0
}

test_source_helper_wins_over_stale_deployment() {
	create_fixture "source-helper"
	cat >"${HOME}/.aidevops/agents/scripts/worktree-exclusions-helper.sh" <<'EOF'
#!/usr/bin/env bash
touch "${2}/.stale-helper-used"
exit 0
EOF
	chmod +x "${HOME}/.aidevops/agents/scripts/worktree-exclusions-helper.sh"
	_apply_worktree_exclusions "$FIXTURE_WORKTREE"
	local status_output=""
	status_output=$(git -C "$FIXTURE_WORKTREE" status --porcelain)
	if [[ -f "${FIXTURE_WORKTREE}/.metadata_never_index" && ! -e "${FIXTURE_WORKTREE}/.stale-helper-used" && -z "$status_output" ]]; then
		print_result "source worktree helper does not call a stale deployed exclusion helper" 0
		return 0
	fi
	print_result "source worktree helper does not call a stale deployed exclusion helper" 1 \
		"status=${status_output:-<clean>}"
	return 0
}

test_legacy_marker_allows_safe_owner_transfer() {
	create_fixture "legacy-transfer"
	touch "${FIXTURE_WORKTREE}/.metadata_never_index"
	export WORKER_ISSUE_NUMBER="27164"
	local claim_calls=0
	local unregister_calls=0
	local transfer_calls=0
	claim_worktree_ownership() {
		local claim_path="$1"
		local claim_branch="$2"
		shift 2
		claim_calls=$((claim_calls + 1))
		[[ -n "$claim_path" && -n "$claim_branch" ]] || return 1
		if [[ "$claim_calls" -gt 1 ]]; then
			return 0
		fi
		return 1
	}
	check_worktree_owner_snapshot() {
		local check_path="$1"
		[[ -n "$check_path" ]] || return 1
		printf '%s|dispatch-precreate-27164||27164|2099-01-01T00:00:00Z|process-start-1\n' "$$"
		return 0
	}
	unregister_worktree() {
		local unregister_path="$1"
		[[ -n "$unregister_path" ]] || return 1
		unregister_calls=$((unregister_calls + 1))
		return 0
	}
	transfer_worktree_ownership_if_expected() {
		local transfer_path="$1"
		local transfer_branch="$2"
		[[ -n "$transfer_path" && -n "$transfer_branch" ]] || return 1
		transfer_calls=$((transfer_calls + 1))
		return 0
	}

	local result=0
	_hrw_claim_worker_worktree "issue-27164" "$FIXTURE_WORKTREE" >/dev/null || result=1
	local status_output=""
	status_output=$(git -C "$FIXTURE_WORKTREE" status --porcelain)
	if [[ "$claim_calls" -ne 2 || "$transfer_calls" -ne 1 || "$unregister_calls" -ne 0 || -n "$status_output" ]]; then
		result=1
	fi
	unset -f claim_worktree_ownership check_worktree_owner_snapshot unregister_worktree \
		transfer_worktree_ownership_if_expected
	unset WORKER_ISSUE_NUMBER
	print_result "legacy marker is healed before dispatch ownership transfer" "$result" \
		"claims=${claim_calls} transfers=${transfer_calls} unregisters=${unregister_calls} status=${status_output:-<clean>}"
	return 0
}

test_genuine_changes_still_block_transfer() {
	create_fixture "genuine-change"
	touch "${FIXTURE_WORKTREE}/.metadata_never_index"
	printf 'task work\n' >"${FIXTURE_WORKTREE}/task.txt"
	local result=1
	if ! _hrw_worktree_clean_for_owner_reclaim "$FIXTURE_WORKTREE"; then
		result=0
	fi
	local status_output=""
	status_output=$(git -C "$FIXTURE_WORKTREE" status --porcelain)
	if [[ "$status_output" != "?? task.txt" ]] ||
		! git -C "$FIXTURE_WORKTREE" check-ignore -q --no-index .metadata_never_index; then
		result=1
	fi
	print_result "genuine task state blocks takeover while infrastructure marker is healed" "$result" \
		"status=${status_output:-<clean>}"
	return 0
}

test_abnormal_exit_does_not_recover_marker() {
	create_fixture "abnormal-exit"
	touch "${FIXTURE_WORKTREE}/.metadata_never_index"
	local output_class=""
	output_class=$(_worker_produced_output "issue-27164" "$FIXTURE_WORKTREE")
	local before_head=""
	before_head=$(git -C "$FIXTURE_WORKTREE" rev-parse HEAD)
	local recovery_calls=0
	_attempt_orphan_recovery_pr() {
		recovery_calls=$((recovery_calls + 1))
		return 0
	}
	_WORKER_WORKTREE_PATH="$FIXTURE_WORKTREE"
	WORKER_NO_EXIT_PUSH=0
	WORKER_NO_ARCHIVE_DIRTY_PATCH=1
	_push_wip_commits_on_exit
	if [[ "${_WORKER_DIRTY_WORK_PRESERVED:-0}" == "1" ]]; then
		_recover_dirty_worker_pr "issue-27164" || true
	fi
	local after_head=""
	after_head=$(git -C "$FIXTURE_WORKTREE" rev-parse HEAD)
	local result=0
	if [[ "$output_class" != "noop" || "$before_head" != "$after_head" || "$recovery_calls" -ne 0 ]]; then
		result=1
	fi
	unset -f _attempt_orphan_recovery_pr
	unset _WORKER_WORKTREE_PATH WORKER_NO_EXIT_PUSH WORKER_NO_ARCHIVE_DIRTY_PATCH
	print_result "abnormal exit cannot commit or recover an infrastructure-only marker" "$result" \
		"class=${output_class} recovery_calls=${recovery_calls}"
	return 0
}

test_non_macos_remains_strict_noop() {
	set_platform "Linux"
	create_fixture "linux-noop"
	cmd_apply "$FIXTURE_WORKTREE"
	local result=0
	local marker_created=0
	local reclaim_status=0
	local exclude_file=""
	if [[ -e "${FIXTURE_WORKTREE}/.metadata_never_index" ]]; then
		marker_created=1
		result=1
	fi
	# The developer checkout may already carry the local macOS exclusion. Remove
	# it from this isolated clone so Linux strictness is tested independently.
	exclude_file=$(fixture_exclude_file "$FIXTURE_WORKTREE")
	grep -Fvx '/.metadata_never_index' "$exclude_file" >"${exclude_file}.test" || true
	mv "${exclude_file}.test" "$exclude_file"
	touch "${FIXTURE_WORKTREE}/.metadata_never_index"
	if _hrw_worktree_clean_for_owner_reclaim "$FIXTURE_WORKTREE"; then
		reclaim_status=1
		result=1
	fi
	local status_output=""
	status_output=$(git -C "$FIXTURE_WORKTREE" status --porcelain)
	print_result "non-macOS exclusion remains a no-op and marker state stays strict" "$result" \
		"marker_created=${marker_created} reclaim_allowed=${reclaim_status} status=${status_output:-<clean>} platform=$(uname -s)"
	set_platform "Darwin"
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_fresh_and_reused_worktree_stay_clean
	test_marker_collisions_remain_task_state
	test_source_helper_wins_over_stale_deployment
	test_legacy_marker_allows_safe_owner_transfer
	test_genuine_changes_still_block_transfer
	test_abnormal_exit_does_not_recover_marker
	test_non_macos_remains_strict_noop

	printf '\nTests: %s, Failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
