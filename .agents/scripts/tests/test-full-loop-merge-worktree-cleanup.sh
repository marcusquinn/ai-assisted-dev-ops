#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_ROOT=""
FIXTURE_GIT_BIN=""
GH_PR_HEAD_REF=""
GH_PR_HEAD_OID=""
GH_PR_HEAD_REPO=""
GH_RELEASE_STATUS="not-requested"
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '  %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		if [[ "$PWD" == "$TEST_ROOT" || "$PWD" == "$TEST_ROOT/"* ]]; then
			cd "$AGENTS_SCRIPTS_DIR" || return 1
		fi
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

resolve_fixture_git() {
	FIXTURE_GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-}"
	if [[ -z "$FIXTURE_GIT_BIN" ]]; then
		FIXTURE_GIT_BIN=$(command -p -v git 2>/dev/null || true)
	fi
	if [[ -z "$FIXTURE_GIT_BIN" || ! -x "$FIXTURE_GIT_BIN" ]]; then
		printf 'ERROR: real Git executable unavailable for disposable fixture\n' >&2
		return 1
	fi
	return 0
}

gh() {
	local command="${1:-}"
	local subcommand="${2:-}"
	local args="$*"
	if [[ "$command" == "pr" && "$subcommand" == "view" ]]; then
		if [[ "$args" == *"state,mergedAt,mergeCommit,headRefName,headRefOid,headRepository,isCrossRepository"* ]]; then
			jq -cn --arg head_ref "$GH_PR_HEAD_REF" --arg head_oid "$GH_PR_HEAD_OID" \
				--arg head_repo "$GH_PR_HEAD_REPO" \
				'{state:"MERGED",mergedAt:"2026-07-11T00:00:00Z",mergeCommit:{oid:"merge123"},
				  headRefName:$head_ref,headRefOid:$head_oid,headRepository:{nameWithOwner:$head_repo},isCrossRepository:false}'
			return 0
		fi
		if [[ "$args" == *"state,mergedAt,mergeCommit"* ]]; then
			printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","mergeCommit":{"oid":"merge123"}}'
			return 0
		fi
		if [[ "$args" == *"headRefName,headRefOid,headRepository,isCrossRepository"* ]]; then
			jq -cn --arg head_ref "$GH_PR_HEAD_REF" --arg head_oid "$GH_PR_HEAD_OID" \
				--arg head_repo "$GH_PR_HEAD_REPO" \
				'{headRefName:$head_ref,headRefOid:$head_oid,headRepository:{nameWithOwner:$head_repo},isCrossRepository:false}'
			return 0
		fi
		if [[ "$args" == *"body"* ]]; then
			printf '%s\n' "Resolves #42"
			return 0
		fi
	fi
	return 0
}

_full_loop_terminal_release_status() {
	local repo="$1"
	local pr_number="$2"
	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	case "$GH_RELEASE_STATUS" in
	published | superseded | not-requested) printf '%s\n' "$GH_RELEASE_STATUS" ;;
	*) return 1 ;;
	esac
	return 0
}

cmd_pre_merge_gate() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	[[ -n "$pr_number" && -n "$repo" ]] || return 1
	return 0
}

_merge_execute() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	local merge_method="${3:-}"
	local has_admin="${4:-}"
	local has_auto="${5:-}"
	[[ -n "$pr_number" && -n "$repo" && -n "$merge_method" && -n "$has_admin" && -n "$has_auto" ]] || return 1
	return 0
}

_retarget_stacked_children_interactive() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	[[ -n "$pr_number" && -n "$repo" ]] || return 1
	return 0
}

_merge_unlock_resources() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	[[ -n "$pr_number" && -n "$repo" ]] || return 1
	return 0
}

release_interactive_claim_on_merge() {
	local pr_number="${1:-}"
	local repo="${2:-}"
	local issue_number="${3:-}"
	[[ -n "$pr_number" && -n "$repo" && -n "$issue_number" ]] || return 1
	return 0
}

auto_file_next_phase() {
	local issue_number="${1:-}"
	local repo="${2:-}"
	[[ -n "$issue_number" && -n "$repo" ]] || return 1
	return 0
}

install_subject_stubs() {
	# full-loop-helper-merge.sh defines several of these symbols. Reinstall the
	# stubs after sourcing so cmd_merge exercises orchestration and cleanup only.
	cmd_pre_merge_gate() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		[[ -n "$pr_number" && -n "$repo" ]] || return 1
		return 0
	}

	_merge_execute() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		local merge_method="${3:-}"
		local has_admin="${4:-}"
		local has_auto="${5:-}"
		[[ -n "$pr_number" && -n "$repo" && -n "$merge_method" && -n "$has_admin" && -n "$has_auto" ]] || return 1
		return 0
	}

	_retarget_stacked_children_interactive() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		[[ -n "$pr_number" && -n "$repo" ]] || return 1
		return 0
	}

	_merge_unlock_resources() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		[[ -n "$pr_number" && -n "$repo" ]] || return 1
		return 0
	}

	release_interactive_claim_on_merge() {
		local pr_number="${1:-}"
		local repo="${2:-}"
		local issue_number="${3:-}"
		[[ -n "$pr_number" && -n "$repo" && -n "$issue_number" ]] || return 1
		return 0
	}

	auto_file_next_phase() {
		local issue_number="${1:-}"
		local repo="${2:-}"
		[[ -n "$issue_number" && -n "$repo" ]] || return 1
		return 0
	}

	load_state() {
		PR_NUMBER=123
		RELEASE_STATUS="not-requested"
		SAVED_PROMPT="merge-cleanup-regression"
		STARTED_AT="2026-08-02T00:00:00Z"
		return 0
	}

	_full_loop_terminal_release_status() {
		local repo="$1"
		local pr_number="$2"
		[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
		case "$GH_RELEASE_STATUS" in
		published | superseded | not-requested) printf '%s\n' "$GH_RELEASE_STATUS" ;;
		*) return 1 ;;
		esac
		return 0
	}

	_merge_capture_session_distill_provenance() { return 0; }
	_merge_reconcile_closing_issues() { return 0; }

	return 0
}

setup_subject() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		teardown || return 1
	fi
	TEST_ROOT=$(mktemp -d)
	trap teardown EXIT
	export HOME="${TEST_ROOT}/home"
	export AIDEVOPS_SKIP_AUTO_CLAIM=1
	export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="${TEST_ROOT}/cleanup-receipts"
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/release-receipts"
	export AIDEVOPS_FULL_LOOP_REPO="example/repo"
	unset AIDEVOPS_SESSION_ID OPENCODE_SESSION_ID CLAUDE_SESSION_ID
	STATE_DIR="${TEST_ROOT}/state"
	STATE_FILE="${STATE_DIR}/full-loop.state"
	mkdir -p "$HOME" "${TEST_ROOT}/bin"
	export AIDEVOPS_TEST_REAL_GIT="$FIXTURE_GIT_BIN"
	cat >"${TEST_ROOT}/bin/git" <<'GIT'
#!/usr/bin/env bash
exec "${AIDEVOPS_TEST_REAL_GIT:?}" "$@"
GIT
	chmod +x "${TEST_ROOT}/bin/git"
	cat >"${TEST_ROOT}/bin/trash" <<'TRASH'
#!/usr/bin/env bash
exit 1
TRASH
	chmod +x "${TEST_ROOT}/bin/trash"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	local canonical_repo="${TEST_ROOT}/repo"
	local origin_repo="${TEST_ROOT}/origin.git"
	local updater_repo="${TEST_ROOT}/updater"
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	mkdir -p "$canonical_repo" "${worktree_path%/*}"
	git -C "$canonical_repo" init -q -b main
	git -C "$canonical_repo" config user.email test@example.invalid
	git -C "$canonical_repo" config user.name 'Aidevops Test'
	printf 'base\n' >"${canonical_repo}/README.md"
	git -C "$canonical_repo" add README.md
	git -C "$canonical_repo" commit -q -m 'init'
	git clone -q --bare "$canonical_repo" "$origin_repo"
	git -C "$canonical_repo" remote add origin "$origin_repo"
	git -C "$canonical_repo" push -q -u origin main
	git -C "$canonical_repo" worktree add -q "$worktree_path" -b feature/full-loop-cleanup
	GH_PR_HEAD_REF="feature/full-loop-cleanup"
	GH_PR_HEAD_OID=$(git -C "$worktree_path" rev-parse HEAD)
	GH_PR_HEAD_REPO="example/repo"
	GH_RELEASE_STATUS="not-requested"
	git -C "$canonical_repo" checkout -q -b feature/active
	git clone -q "$origin_repo" "$updater_repo"
	git -C "$updater_repo" config user.email test@example.invalid
	git -C "$updater_repo" config user.name 'Aidevops Test'
	printf 'remote main advance\n' >>"${updater_repo}/README.md"
	git -C "$updater_repo" add README.md
	git -C "$updater_repo" commit -q -m 'advance main'
	git -C "$updater_repo" push -q origin main

	cd "$worktree_path"
	export SCRIPT_DIR="$AGENTS_SCRIPTS_DIR"
	# shellcheck source=../shared-constants.sh
	source "${AGENTS_SCRIPTS_DIR}/shared-constants.sh"
	# shellcheck source=../full-loop-helper-state.sh
	source "${AGENTS_SCRIPTS_DIR}/full-loop-helper-state.sh"
	# shellcheck source=../full-loop-helper-merge.sh
	source "${AGENTS_SCRIPTS_DIR}/full-loop-helper-merge.sh"
	install_subject_stubs
	return 0
}

configure_alias_repo_identity() {
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	local alias_branch="$1"
	git -C "$worktree_path" branch -m "$alias_branch"
	git -C "$worktree_path" remote add pr-head "https://github.com/${GH_PR_HEAD_REPO}.git"
	return 0
}

configure_managed_repo_identity() {
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	git -C "$worktree_path" remote add managed "https://github.com/${GH_PR_HEAD_REPO}.git"
	return 0
}

test_cmd_merge_defers_current_linked_worktree() {
	local canonical_repo="${TEST_ROOT}/repo"
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	local active_before=""
	active_before=$(git -C "$canonical_repo" rev-parse feature/active)
	local remote_main=""
	remote_main=$(git -C "${TEST_ROOT}/updater" rev-parse main)

	cmd_merge "123" "example/repo" --squash

	local rc=0
	local marker_path="${worktree_path}/.agents/.full-loop-cleanup-deferred"
	local marker_pid=""
	local receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	local receipt_worktree=""
	receipt_worktree=$(git -C "$worktree_path" rev-parse --show-toplevel)
	git -C "$canonical_repo" worktree list --porcelain | grep -q "$worktree_path" || rc=1
	[[ -d "$worktree_path" ]] || rc=1
	git -C "$canonical_repo" show-ref --verify --quiet refs/heads/feature/full-loop-cleanup || rc=1
	[[ -f "$marker_path" ]] || rc=1
	IFS= read -r marker_pid <"$marker_path" || rc=1
	[[ "$marker_pid" =~ ^[0-9]+$ ]] || rc=1
	kill -0 "$marker_pid" 2>/dev/null || rc=1
	[[ -f "$receipt_path" ]] || rc=1
	jq -e --arg worktree "$receipt_worktree" --arg branch "feature/full-loop-cleanup" \
		'.resource_cleanup_state == "CLEANUP_DEFERRED" and .executor_completion_state == "FINALIZATION_PENDING"
		 and .cleanup_lease.state == "pending" and .worktree == $worktree and .branch == $branch
		 and (.owner.pid | type == "number") and (.owner.process_identity | length > 0)' \
		"$receipt_path" >/dev/null || rc=1
	cmd_record_no_release "123" "example/repo" >/dev/null || rc=1
	cmd_complete >/dev/null || rc=1
	jq -e '
		.executor_completion_state == "COMPLETE"
		and .resource_cleanup_state == "CLEANUP_DEFERRED"
		and .release_status == "not-requested"
	' "$receipt_path" >/dev/null || rc=1
	cp "$receipt_path" "${TEST_ROOT}/completed-receipt.json"
	cmd_complete >/dev/null || rc=1
	cmp -s "$receipt_path" "${TEST_ROOT}/completed-receipt.json" || rc=1
	if [[ "$(git -C "$canonical_repo" branch --show-current)" != "feature/active" ]]; then
		rc=1
	fi
	if [[ "$(git -C "$canonical_repo" rev-parse feature/active)" != "$active_before" ]]; then
		rc=1
	fi
	# Cleanup is deferred before canonical refresh because the parent runtime may
	# still use this logical project directory.
	if [[ "$(git -C "$canonical_repo" rev-parse main)" == "$remote_main" ]]; then rc=1; fi
	print_result "merge then no-release completion finalizes deferred cleanup idempotently" "$rc"
	return 0
}

test_no_release_before_merge_receipt_converges() {
	setup_subject
	local receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	local rc=0
	cmd_record_no_release "123" "example/repo" >/dev/null || rc=1
	[[ ! -e "$receipt_path" ]] || rc=1
	cmd_merge "123" "example/repo" --squash >/dev/null || rc=1
	jq -e '
		.executor_completion_state == "FINALIZATION_PENDING"
		and .release_status == "pending"
	' "$receipt_path" >/dev/null || rc=1
	cmd_complete >/dev/null || rc=1
	jq -e '
		.executor_completion_state == "COMPLETE"
		and .release_status == "not-requested"
	' "$receipt_path" >/dev/null || rc=1
	print_result "no-release evidence recorded before merge receipt converges atomically" "$rc"
	return 0
}

test_cmd_merge_defers_exact_head_alias_worktree() {
	setup_subject
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	local alias_branch="bugfix/repair-pr-head"
	configure_alias_repo_identity "$alias_branch"
	local receipt_worktree=""
	receipt_worktree=$(git -C "$worktree_path" rev-parse --show-toplevel)

	local cleanup_plan=""
	cleanup_plan=$(_merge_fresh_worktree_cleanup_plan "123" "example/repo") || true
	local planned_worktree="" planned_branch="" canonical_dir="" delete_remote_branch=""
	IFS=$'\t' read -r planned_worktree planned_branch canonical_dir delete_remote_branch <<<"$cleanup_plan"
	cmd_merge "123" "example/repo" --squash

	local rc=0
	local receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	[[ "$planned_worktree" == "$receipt_worktree" ]] || rc=1
	[[ "$planned_branch" == "$alias_branch" ]] || rc=1
	[[ -n "$canonical_dir" ]] || rc=1
	[[ "$delete_remote_branch" == "0" ]] || rc=1
	[[ -f "$receipt_path" ]] || rc=1
	jq -e --arg worktree "$receipt_worktree" --arg branch "$alias_branch" '
		.resource_cleanup_state == "CLEANUP_DEFERRED"
		and .executor_completion_state == "FINALIZATION_PENDING"
		and .worktree == $worktree and .branch == $branch
	' "$receipt_path" >/dev/null || rc=1
	print_result "exact-head repair alias persists its actual local cleanup target" "$rc"
	return 0
}

test_cmd_adopt_merged_receipt_is_idempotent() {
	setup_subject
	configure_managed_repo_identity
	local receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	local receipt_worktree=""
	local rc=0
	receipt_worktree=$(git -C "$worktree_path" rev-parse --show-toplevel)

	cmd_adopt_merged_receipt "123" "example/repo" || rc=1
	[[ -f "$receipt_path" ]] || rc=1
	jq -e --arg worktree "$receipt_worktree" '
		.repository == "example/repo" and .pr_number == 123
		and .worktree == $worktree and .branch == "feature/full-loop-cleanup"
		and .executor_completion_state == "FINALIZATION_PENDING"
		and .resource_cleanup_state == "CLEANUP_DEFERRED"
		and .release_status == "not-requested"
		and .cleanup_lease.state == "pending"
		and (.owner.pid | type == "number") and (.owner.process_identity | length > 0)
	' "$receipt_path" >/dev/null || rc=1
	cp "$receipt_path" "${TEST_ROOT}/adopted-before.json"
	cmd_adopt_merged_receipt "123" "example/repo" || rc=1
	cmp -s "$receipt_path" "${TEST_ROOT}/adopted-before.json" || rc=1
	print_result "externally merged PR adoption is exact-head and idempotent" "$rc"
	return 0
}

test_cmd_adopt_merged_receipt_rejects_unsafe_evidence() {
	local rc=0
	local receipt_path=""

	setup_subject
	configure_managed_repo_identity
	receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	GH_RELEASE_STATUS="pending"
	if cmd_adopt_merged_receipt "123" "example/repo" >/dev/null 2>&1; then rc=1; fi
	[[ ! -e "$receipt_path" ]] || rc=1

	setup_subject
	configure_managed_repo_identity
	receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	GH_PR_HEAD_OID="0000000000000000000000000000000000000000"
	if cmd_adopt_merged_receipt "123" "example/repo" >/dev/null 2>&1; then rc=1; fi
	[[ ! -e "$receipt_path" ]] || rc=1

	setup_subject
	configure_managed_repo_identity
	receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	git branch -m "feature/different-branch"
	if cmd_adopt_merged_receipt "123" "example/repo" >/dev/null 2>&1; then rc=1; fi
	[[ ! -e "$receipt_path" ]] || rc=1

	setup_subject
	configure_managed_repo_identity
	receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	if cmd_adopt_merged_receipt "123" "wrong/repo" >/dev/null 2>&1; then rc=1; fi
	[[ ! -e "$receipt_path" ]] || rc=1

	setup_subject
	configure_managed_repo_identity
	receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	_resolve_worktree_owner_pid() {
		printf '%s\n' 99999999
		return 0
	}
	if cmd_adopt_merged_receipt "123" "example/repo" >/dev/null 2>&1; then rc=1; fi
	[[ ! -e "$receipt_path" ]] || rc=1
	unset -f _resolve_worktree_owner_pid

	print_result "merged-receipt adoption rejects nonterminal, head, branch, repository, and dead-owner evidence" "$rc"
	return 0
}

test_cmd_adopt_merged_receipt_rejects_receipt_conflicts() {
	local rc=0
	local receipt_path=""

	setup_subject
	configure_managed_repo_identity
	receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	cmd_adopt_merged_receipt "123" "example/repo" >/dev/null || rc=1
	jq '.owner.process_identity = "reused process generation"' "$receipt_path" >"${receipt_path}.tmp"
	mv "${receipt_path}.tmp" "$receipt_path"
	cp "$receipt_path" "${TEST_ROOT}/conflict-before.json"
	if cmd_adopt_merged_receipt "123" "example/repo" >/dev/null 2>&1; then rc=1; fi
	cmp -s "$receipt_path" "${TEST_ROOT}/conflict-before.json" || rc=1

	setup_subject
	configure_managed_repo_identity
	receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	cmd_adopt_merged_receipt "123" "example/repo" >/dev/null || rc=1
	full_loop_transition_cleanup_receipt "$receipt_path" "$_FULL_LOOP_CLEANUP_LEASED" "$$" || rc=1
	cp "$receipt_path" "${TEST_ROOT}/leased-before.json"
	if cmd_adopt_merged_receipt "123" "example/repo" >/dev/null 2>&1; then rc=1; fi
	cmp -s "$receipt_path" "${TEST_ROOT}/leased-before.json" || rc=1

	print_result "merged-receipt adoption preserves conflicting and leased receipts" "$rc"
	return 0
}

test_cleanup_plan_rejects_head_drift() {
	setup_subject
	GH_PR_HEAD_OID="0000000000000000000000000000000000000000"
	local cleanup_plan=""
	local rc=0
	if cleanup_plan=$(_merge_fresh_worktree_cleanup_plan "123" "example/repo"); then rc=1; fi
	[[ -z "$cleanup_plan" ]] || rc=1
	print_result "cleanup plan rejects PR head drift" "$rc"
	return 0
}

test_cleanup_plan_rejects_detached_checkout() {
	setup_subject
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	git -C "$worktree_path" checkout -q --detach
	local cleanup_plan=""
	local rc=0
	if cleanup_plan=$(_merge_fresh_worktree_cleanup_plan "123" "example/repo"); then rc=1; fi
	[[ -z "$cleanup_plan" ]] || rc=1
	print_result "cleanup plan rejects detached checkout" "$rc"
	return 0
}

test_cleanup_plan_rejects_canonical_checkout() {
	setup_subject
	local canonical_repo="${TEST_ROOT}/repo"
	cd "$canonical_repo"
	GH_PR_HEAD_REF="feature/active"
	GH_PR_HEAD_OID=$(git rev-parse HEAD)
	local cleanup_plan=""
	local rc=0
	if cleanup_plan=$(_merge_fresh_worktree_cleanup_plan "123" "example/repo"); then rc=1; fi
	[[ -z "$cleanup_plan" ]] || rc=1
	print_result "cleanup plan rejects canonical checkout" "$rc"
	return 0
}

test_cleanup_plan_rejects_unrelated_same_content_branch() {
	setup_subject
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	git -C "$worktree_path" branch -m "bugfix/unrelated-same-content"
	git -C "$worktree_path" remote add unrelated "https://github.com/other/repository.git"
	local cleanup_plan=""
	local rc=0
	if cleanup_plan=$(_merge_fresh_worktree_cleanup_plan "123" "example/repo"); then rc=1; fi
	[[ -z "$cleanup_plan" ]] || rc=1
	print_result "cleanup plan rejects unrelated same-content branch" "$rc"
	return 0
}

test_cleanup_plan_rejects_ambiguous_alias_repository() {
	setup_subject
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	configure_alias_repo_identity "bugfix/ambiguous-repository"
	git -C "$worktree_path" remote add other-head "https://github.com/other/repository.git"
	local cleanup_plan=""
	local rc=0
	if cleanup_plan=$(_merge_fresh_worktree_cleanup_plan "123" "example/repo"); then rc=1; fi
	[[ -z "$cleanup_plan" ]] || rc=1
	print_result "cleanup plan rejects ambiguous alias repository identity" "$rc"
	return 0
}

test_worktree_metadata_match_rejects_missing_record() {
	setup_subject
	local current_root=""
	local current_head=""
	local porcelain=""
	current_root=$(git rev-parse --show-toplevel)
	current_head=$(git rev-parse HEAD)
	porcelain=$(printf 'worktree %s\nHEAD %s\nbranch refs/heads/main\n' "${TEST_ROOT}/unrelated" "$current_head")
	local rc=0
	if _merge_worktree_record_matches "$porcelain" "$current_root" "feature/full-loop-cleanup" "$current_head"; then rc=1; fi
	print_result "cleanup plan rejects missing current-worktree metadata" "$rc"
	return 0
}

test_cmd_merge_persists_cleanup_without_canonical_path() {
	setup_subject
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	local receipt_path="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_repo-123.json"
	local receipt_worktree=""
	local output=""
	local rc=0
	receipt_worktree=$(git -C "$worktree_path" rev-parse --show-toplevel)

	_merge_current_canonical_dir_for_cleanup() {
		local current_root="$1"
		[[ -n "$current_root" ]] || return 1
		return 1
	}

	output=$(cmd_merge "123" "example/repo" --squash 2>&1) || rc=1
	[[ "$output" == *"CANONICAL_SYNC_PENDING=true reason=canonical_path_unavailable"* ]] || rc=1
	[[ "$output" == *"LIFECYCLE_STATE=CLEANUP_DEFERRED"* ]] || rc=1
	[[ -f "$receipt_path" ]] || rc=1
	jq -e --arg worktree "$receipt_worktree" '
		.repository == "example/repo" and .pr_number == 123
		and .worktree == $worktree and .branch == "feature/full-loop-cleanup"
		and .resource_cleanup_state == "CLEANUP_DEFERRED"
		and .executor_completion_state == "FINALIZATION_PENDING"
	' "$receipt_path" >/dev/null || rc=1
	print_result "canonical sync pending coexists with durable deferred cleanup" "$rc"
	return 0
}

test_cmd_merge_defers_cleanup_for_live_process_cwd() {
	setup_subject
	local canonical_repo="${TEST_ROOT}/repo"
	local worktree_path="${TEST_ROOT}/worktrees/repo-feature-full-loop-cleanup"
	local sleeper_pid=""
	(
		cd "$worktree_path" || exit 2
		sleep 30
	) &
	sleeper_pid=$!
	sleep 1

	cmd_merge "123" "example/repo" --squash

	local rc=0
	[[ -d "$worktree_path" ]] || rc=1
	git -C "$canonical_repo" worktree list --porcelain | grep -qF "$worktree_path" || rc=1
	kill "$sleeper_pid" 2>/dev/null || true
	wait "$sleeper_pid" 2>/dev/null || true
	print_result "cmd_merge defers cleanup while another process uses worktree cwd" "$rc"
	return 0
}

test_refresh_canonical_reports_pending_without_mutation() {
	local canonical_repo="${TEST_ROOT}/repo-default"
	local origin_repo="${TEST_ROOT}/origin-default.git"
	local updater_repo="${TEST_ROOT}/updater-default"
	mkdir -p "$canonical_repo"
	git -C "$canonical_repo" init -q -b main
	git -C "$canonical_repo" config user.email test@example.invalid
	git -C "$canonical_repo" config user.name 'Aidevops Test'
	printf 'base\n' >"${canonical_repo}/README.md"
	git -C "$canonical_repo" add README.md
	git -C "$canonical_repo" commit -q -m 'init'
	git clone -q --bare "$canonical_repo" "$origin_repo"
	git -C "$canonical_repo" remote add origin "$origin_repo"
	git -C "$canonical_repo" push -q -u origin main
	git clone -q "$origin_repo" "$updater_repo"
	git -C "$updater_repo" config user.email test@example.invalid
	git -C "$updater_repo" config user.name 'Aidevops Test'
	printf 'remote main advance\n' >>"${updater_repo}/README.md"
	git -C "$updater_repo" add README.md
	git -C "$updater_repo" commit -q -m 'advance main'
	git -C "$updater_repo" push -q origin main

	local output=""
	local refresh_rc=0
	output=$(_merge_refresh_canonical_for_cleanup "$canonical_repo" "main" 2>&1) || refresh_rc=$?

	local rc=0
	[[ "$refresh_rc" -ne 0 ]] || rc=1
	[[ "$output" == *"CANONICAL_SYNC_PENDING=true"* ]] || rc=1
	if [[ "$(git -C "$canonical_repo" branch --show-current)" != "main" ]]; then
		rc=1
	fi
	if [[ "$(git -C "$canonical_repo" rev-parse main)" == "$(git -C "$updater_repo" rev-parse main)" ]]; then
		rc=1
	fi
	print_result "canonical drift is explicit pending without unaudited mutation" "$rc"
	return 0
}

main() {
	resolve_fixture_git
	setup_subject
	test_refresh_canonical_reports_pending_without_mutation
	test_cmd_merge_defers_current_linked_worktree
	test_no_release_before_merge_receipt_converges
	test_cmd_merge_defers_cleanup_for_live_process_cwd
	test_cmd_merge_defers_exact_head_alias_worktree
	test_cmd_adopt_merged_receipt_is_idempotent
	test_cmd_adopt_merged_receipt_rejects_unsafe_evidence
	test_cmd_adopt_merged_receipt_rejects_receipt_conflicts
	test_cleanup_plan_rejects_head_drift
	test_cleanup_plan_rejects_detached_checkout
	test_cleanup_plan_rejects_canonical_checkout
	test_cleanup_plan_rejects_unrelated_same_content_branch
	test_cleanup_plan_rejects_ambiguous_alias_repository
	test_worktree_metadata_match_rejects_missing_record
	# This fixture replaces the canonical resolver, so keep it last.
	test_cmd_merge_persists_cleanup_without_canonical_path
	printf '\n%d/%d tests passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
