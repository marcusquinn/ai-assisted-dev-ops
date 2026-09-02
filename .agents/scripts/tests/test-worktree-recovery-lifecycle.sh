#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for exact worktree recovery planning and explicit apply.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
TEST_DIR=""
TEST_LEGACY_RECOVERY_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		[[ -z "$detail" ]] || printf '  %s\n' "$detail"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	[[ -z "$TEST_DIR" || ! -d "$TEST_DIR" ]] || rm -rf "$TEST_DIR"
	return 0
}

create_unarchived_fixture() {
	local repo_path="$1"
	local worktree_path="$2"
	local branch_name="$3"

	"$GIT_BIN" init -q -b main "$repo_path" || return 1
	"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || return 1
	"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || return 1
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || return 1
	printf 'base\n' >"${repo_path}/README.md" || return 1
	"$GIT_BIN" -C "$repo_path" add README.md || return 1
	"$GIT_BIN" -C "$repo_path" commit -q -m init || return 1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b "$branch_name" "$worktree_path" || return 1
	return 0
}

create_archived_fixture() {
	local repo_path="$1"
	local worktree_path="$2"
	local recovery_root="$3"
	local branch_name="$4"

	create_unarchived_fixture "$repo_path" "$worktree_path" "$branch_name" || return 1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$worktree_path" "test.sh" "recovery-plan" || return 1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$worktree_path" "$WORKTREE_RECOVERABLE_ARCHIVE_PATH" "test.sh" "recovery-plan" \
		"recovery_path=archive-first" "false" "false" || return 1
	printf '%s\n' "$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	return 0
}

create_candidate_plan_fixture() {
	local home_path="$1"
	local repo_path="$2"
	local worktree_path="$3"
	local recovery_root="$4"
	local branch_name="$5"
	local plan_path="$6"
	local archive_path=""

	mkdir -p "$home_path" "$recovery_root" || return 1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"$branch_name") || return 1
	install_clear_evidence_stubs
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery plan --output "$plan_path" >/dev/null || return 1
	printf '%s\n' "$archive_path"
	return 0
}

resign_test_plan() {
	local plan_path="$1"
	local plan_material=""
	local plan_digest=""
	local candidate_count=""
	local candidate_bytes=""
	local confirmation=""
	local temp_path="${plan_path}.resign.$$"

	plan_material=$(_worktree_recovery_apply_plan_material "$plan_path") || return 1
	plan_digest=$(_worktree_recovery_plan_sha256_text "$plan_material") || return 1
	candidate_count=$(jq -r '.candidate_count' "$plan_path") || return 1
	candidate_bytes=$(jq -r '.candidate_bytes' "$plan_path") || return 1
	confirmation=$(_worktree_recovery_plan_confirmation_token \
		"sha256:$plan_digest" "$candidate_count" "$candidate_bytes") || return 1
	jq -c --arg plan_id "sha256:$plan_digest" --arg confirmation "$confirmation" \
		'.plan_id = $plan_id | .confirmation_token = $confirmation' \
		"$plan_path" >"$temp_path" || return 1
	mv "$temp_path" "$plan_path" || return 1
	return 0
}

write_test_producer_lock() {
	local recovery_root="$1"
	local owner_pid="$2"
	local owner_lstart="$3"
	local lock_path="${recovery_root}/${_WT_RECOVERY_PRODUCER_LOCK_NAME}"

	mkdir "$lock_path" || return 1
	printf '%s\n' "$owner_pid" >"$lock_path/pid" || return 1
	printf '%s\n' "$owner_lstart" >"$lock_path/lstart" || return 1
	printf '%s\n' "fixture-lock-token" >"$lock_path/token" || return 1
	printf '%s\n' "complete" >"$lock_path/initialized" || return 1
	return 0
}

remove_test_producer_lock() {
	local recovery_root="$1"
	local lock_path="${recovery_root}/${_WT_RECOVERY_PRODUCER_LOCK_NAME}"

	rm -f "$lock_path/pid" "$lock_path/lstart" "$lock_path/token" "$lock_path/initialized" || return 1
	rmdir "$lock_path" || return 1
	return 0
}

archive_tree_digest() {
	local bucket_path="$1"
	local parent_path="${bucket_path%/*}"
	local base_name="${bucket_path##*/}"
	local digest=""

	if command -v shasum >/dev/null 2>&1; then
		digest=$(tar -cf - -C "$parent_path" "$base_name" | shasum -a 256) || return 1
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(tar -cf - -C "$parent_path" "$base_name" | sha256sum) || return 1
	else
		return 1
	fi
	digest="${digest%%[[:space:]]*}"
	printf '%s\n' "$digest"
	return 0
}

install_external_evidence_stub() {
	_worktree_recovery_plan_external_evidence_json() {
		jq -cn '{commit:"merged",open_pr:"clear",task:"closed",issue_number:"29388",repo:"example/repo"}'
		return 0
	}
	return 0
}

install_clear_evidence_stubs() {
	_worktree_recovery_plan_git_state() {
		printf 'clear\n'
		return 0
	}
	_worktree_recovery_plan_worktree_reference_state() {
		printf 'clear\n'
		return 0
	}
	_worktree_recovery_plan_registry_state() {
		printf 'clear\n'
		return 0
	}
	_worktree_recovery_plan_claim_state() {
		printf 'clear\n'
		return 0
	}
	_worktree_recovery_plan_process_state() {
		printf 'clear\n'
		return 0
	}
	install_external_evidence_stub
	return 0
}

test_exact_plan_writes_candidate_without_mutation() {
	local home_path="${TEST_DIR}/candidate-home"
	local repo_path="${TEST_DIR}/candidate-repo"
	local worktree_path="${TEST_DIR}/candidate-worktree"
	local recovery_root="${home_path}/recovery"
	local output_path="${TEST_DIR}/candidate-plan.json"
	local second_output_path="${TEST_DIR}/candidate-plan-second.json"
	local archive_path="" marker_path="" marker_digest_before="" marker_digest_after=""
	local bucket_path="" tree_digest_before="" tree_digest_after=""
	local rc=0

	mkdir -p "$home_path" "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"bugfix/gh29388-recovery-plan") || rc=1
	"$GIT_BIN" -C "$archive_path" remote add origin \
		"https://github.com/example/repo.git" || rc=1
	marker_path="${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}"
	bucket_path="${archive_path%/*}"
	marker_digest_before=$(_worktree_recovery_plan_sha256_file "$marker_path") || rc=1
	tree_digest_before=$(archive_tree_digest "$bucket_path") || rc=1
	install_external_evidence_stub
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery plan --output "$output_path" >/dev/null || rc=1
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery plan --output "$second_output_path" >/dev/null || rc=1
	marker_digest_after=$(_worktree_recovery_plan_sha256_file "$marker_path") || rc=1
	tree_digest_after=$(archive_tree_digest "$bucket_path") || rc=1
	[[ "$marker_digest_before" == "$marker_digest_after" ]] || rc=1
	[[ "$tree_digest_before" == "$tree_digest_after" ]] || rc=1
	[[ ! -e "$worktree_path" && -d "$archive_path" ]] || rc=1
	jq -e --arg archive "$archive_path" '
		.schema == "aidevops.worktree-recovery-plan/v2" and .producer == "worktree-helper" and
		.read_only == true and .inventory_complete == true and .inventory_error == null and
		(.source_roots | length == 1) and .entry_count == 1 and
		.sized_entry_count == 1 and .unavailable_size_count == 0 and
		.candidate_count == 1 and .protected_count == 0 and .unknown_count == 0 and
		(.candidate_bytes > 0) and .candidate_bytes == .expected_allocated_bytes and
		(.plan_id | startswith("sha256:")) and
		(.confirmation_token | startswith("apply-sha256:")) and
		(.entries | length == 1) and .entries[0].archive_path == $archive and
		.entries[0].disposition == "candidate" and
		.entries[0].expected_allocated_bytes > 0 and
		(.entries[0].identity.identity_digest | startswith("sha256:")) and
		(.entries[0].identity.index_digest | startswith("sha256:"))
	' "$output_path" >/dev/null || rc=1
	[[ "$(jq -cS '.entries' "$output_path")" == "$(jq -cS '.entries' "$second_output_path")" ]] || rc=1
	[[ "$(jq -r '.plan_id' "$output_path")" == "$(jq -r '.plan_id' "$second_output_path")" ]] || rc=1
	print_result "exact_plan_writes_candidate_without_mutation" "$rc" \
		"Expected one identity-bound candidate and unchanged recovery evidence"
	return 0
}

test_git_state_detects_recovery_data() {
	local home_path="${TEST_DIR}/dirty-home"
	local repo_path="${TEST_DIR}/dirty-repo"
	local worktree_path="${TEST_DIR}/dirty-worktree"
	local recovery_root="${home_path}/recovery"
	local archive_path="" identity="" state=""
	local rc=0

	mkdir -p "$home_path" "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"bugfix/gh29388-dirty-plan") || rc=1
	identity=$(_worktree_recovery_plan_identity_json "${archive_path%/*}") || rc=1
	printf 'changed\n' >"${archive_path}/README.md" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	"$GIT_BIN" -C "$archive_path" checkout -q -- README.md || rc=1
	printf 'untracked\n' >"${archive_path}/unique.bin" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	rm -f "${archive_path}/unique.bin"
	printf '*.cache\n' >>"${repo_path}/.git/info/exclude" || rc=1
	printf 'ignored\n' >"${archive_path}/unique.cache" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	rm -f "${archive_path}/unique.cache"
	printf 'node_modules/\nprivate-artifact/\n' >>"${repo_path}/.git/info/exclude" || rc=1
	mkdir -p "${archive_path}/node_modules/package" || rc=1
	printf 'regenerable\n' >"${archive_path}/node_modules/package/cache.bin" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || rc=1
	mkdir -p "${archive_path}/private-artifact" || rc=1
	printf 'preserve\n' >"${archive_path}/private-artifact/user.bin" || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	print_result "git_state_detects_recovery_data" "$rc" \
		"Expected tracked, untracked, and user ignored data to veto candidates while recognised caches remain clear"
	return 0
}

test_cache_policy_recognises_python_and_root_codegraph_only() {
	local archive_path="${TEST_DIR}/cache-status-archive"
	local status_path="${TEST_DIR}/cache-status.bin"
	local symlink_target="${TEST_DIR}/cache-status-symlink-target"
	local policy_status=0
	local rc=0

	"$GIT_BIN" init -q -b main "$archive_path" || rc=1
	mkdir -p "${archive_path}/backend/__pycache__" \
		"${archive_path}/backend/.pytest_cache" "${archive_path}/.codegraph" \
		"${archive_path}/nested/.codegraph" "$symlink_target" || rc=1
	printf '!! backend/__pycache__/module.pyc\0!! backend/.pytest_cache/state\0!! .codegraph/codegraph.db\0' \
		>"$status_path" || rc=1
	policy_status=0
	_worktree_recovery_status_has_user_data "$status_path" "$archive_path" || policy_status=$?
	[[ "$policy_status" -eq 1 ]] || rc=1
	policy_status=0
	_worktree_recovery_cache_policy "status" "$status_path" "$archive_path" \
		"${TEST_DIR}/missing-git" || policy_status=$?
	[[ "$policy_status" -eq 2 ]] || rc=1
	printf '!! nested/.codegraph/codegraph.db\0' >"$status_path" || rc=1
	policy_status=0
	_worktree_recovery_status_has_user_data "$status_path" "$archive_path" || policy_status=$?
	[[ "$policy_status" -eq 0 ]] || rc=1
	rm -rf "${archive_path}/.codegraph" || rc=1
	ln -s "$symlink_target" "${archive_path}/.codegraph" || rc=1
	printf '!! .codegraph/codegraph.db\0' >"$status_path" || rc=1
	policy_status=0
	_worktree_recovery_status_has_user_data "$status_path" "$archive_path" || policy_status=$?
	[[ "$policy_status" -eq 0 ]] || rc=1
	printf '!! logs/diagnostic.log\0' >"$status_path" || rc=1
	policy_status=0
	_worktree_recovery_status_has_user_data "$status_path" "$archive_path" || policy_status=$?
	[[ "$policy_status" -eq 0 ]] || rc=1
	print_result "cache_policy_recognises_python_and_root_codegraph_only" "$rc" \
		"Expected Python and root CodeGraph caches to be regenerable while nested CodeGraph, symlinks, and logs remain protected"
	return 0
}

test_git_state_protects_tracked_regenerable_cache_roots() {
	local cache_path="" repo_path="" identity="" state=""
	local rc=0

	for cache_path in ".codegraph" "backend/__pycache__" "backend/.pytest_cache"; do
		repo_path="${TEST_DIR}/tracked-status-${cache_path//\//-}"
		"$GIT_BIN" init -q -b main "$repo_path" || rc=1
		"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || rc=1
		"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || rc=1
		"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || rc=1
		printf '%s/\n' "$cache_path" >>"${repo_path}/.git/info/exclude" || rc=1
		mkdir -p "${repo_path}/${cache_path}" || rc=1
		printf 'tracked configuration\n' >"${repo_path}/${cache_path}/config.json" || rc=1
		"$GIT_BIN" -C "$repo_path" add -f "${cache_path}/config.json" || rc=1
		"$GIT_BIN" -C "$repo_path" commit -q -m init || rc=1
		printf 'generated cache\n' >"${repo_path}/${cache_path}/generated.bin" || rc=1
		identity=$(jq -cn --arg archive_path "$repo_path" '{archive_path:$archive_path}') || rc=1
		state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
		[[ "$state" == "dirty" ]] || rc=1
	done
	print_result "git_state_protects_tracked_regenerable_cache_roots" "$rc" \
		"Expected tracked content to keep every newly recognised cache identity protected"
	return 0
}

test_archive_prunes_only_regenerable_ignored_caches() {
	local repo_path="${TEST_DIR}/cache-policy-repo"
	local worktree_path="${TEST_DIR}/cache-policy-worktree"
	local recovery_root="${TEST_DIR}/cache-policy-recovery"
	local archive_path="" identity="" state=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	create_unarchived_fixture "$repo_path" "$worktree_path" \
		"bugfix/gh30931-cache-policy" || rc=1
	printf 'node_modules/\n__pycache__/\n.pytest_cache/\n/.codegraph/\nnested/.codegraph/\nprivate-artifact/\n' \
		>>"${repo_path}/.git/info/exclude" || rc=1
	mkdir -p "${worktree_path}/node_modules/package" \
		"${worktree_path}/backend/__pycache__" "${worktree_path}/backend/.pytest_cache" \
		"${worktree_path}/.codegraph" "${worktree_path}/nested/.codegraph" \
		"${worktree_path}/private-artifact" || rc=1
	python3 - "${worktree_path}/node_modules/package/large-cache.bin" <<'PY' || rc=1
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"x" * 2 * 1024 * 1024)
PY
	printf 'bytecode\n' >"${worktree_path}/backend/__pycache__/module.pyc" || rc=1
	printf 'pytest\n' >"${worktree_path}/backend/.pytest_cache/state" || rc=1
	printf 'graph\n' >"${worktree_path}/.codegraph/codegraph.db" || rc=1
	printf 'nested graph\n' >"${worktree_path}/nested/.codegraph/codegraph.db" || rc=1
	printf 'user-evidence\n' >"${worktree_path}/private-artifact/user.bin" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$worktree_path" "test.sh" "cache-policy" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	[[ ! -e "${archive_path}/node_modules" ]] || rc=1
	[[ ! -e "${archive_path}/backend/__pycache__" ]] || rc=1
	[[ ! -e "${archive_path}/backend/.pytest_cache" ]] || rc=1
	[[ ! -e "${archive_path}/.codegraph" ]] || rc=1
	[[ -f "${archive_path}/nested/.codegraph/codegraph.db" ]] || rc=1
	[[ -f "${archive_path}/private-artifact/user.bin" ]] || rc=1
	identity=$(_worktree_recovery_plan_identity_json "${archive_path%/*}") || rc=1
	state=$(_worktree_recovery_plan_git_state "$identity") || rc=1
	[[ "$state" == "dirty" ]] || rc=1
	print_result "archive_prunes_only_regenerable_ignored_caches" "$rc" \
		"Expected large dependency caches to be omitted while ignored user evidence remains protected"
	return 0
}

test_archive_pruning_preserves_tracked_codegraph_root() {
	local source_path="${TEST_DIR}/tracked-codegraph-source"
	local archive_path="${TEST_DIR}/tracked-codegraph-archive"
	local rc=0

	"$GIT_BIN" init -q -b main "$source_path" || rc=1
	"$GIT_BIN" -C "$source_path" config user.email test@example.invalid || rc=1
	"$GIT_BIN" -C "$source_path" config user.name 'Aidevops Test' || rc=1
	"$GIT_BIN" -C "$source_path" config commit.gpgsign false || rc=1
	printf '/.codegraph/\n' >>"${source_path}/.git/info/exclude" || rc=1
	mkdir -p "${source_path}/.codegraph" || rc=1
	printf 'tracked configuration\n' >"${source_path}/.codegraph/config.json" || rc=1
	"$GIT_BIN" -C "$source_path" add -f .codegraph/config.json || rc=1
	"$GIT_BIN" -C "$source_path" commit -q -m init || rc=1
	printf 'generated graph\n' >"${source_path}/.codegraph/codegraph.db" || rc=1
	cp -R "$source_path" "$archive_path" || rc=1
	_worktree_prune_regenerable_archive_caches \
		"$source_path" "$archive_path" "$GIT_BIN" || rc=1
	[[ -f "${archive_path}/.codegraph/config.json" &&
		-f "${archive_path}/.codegraph/codegraph.db" ]] || rc=1
	print_result "archive_pruning_preserves_tracked_codegraph_root" "$rc" \
		"Expected any tracked file to veto pruning the repository-root CodeGraph cache"
	return 0
}

test_claim_state_uses_archive_repository() {
	local home_path="${TEST_DIR}/claim-home"
	local repo_path="${TEST_DIR}/claim-repo"
	local worktree_path="${TEST_DIR}/claim-worktree"
	local unrelated_repo="${TEST_DIR}/claim-unrelated-repo"
	local recovery_root="${home_path}/recovery"
	local claim_dir="${home_path}/.aidevops/.agent-workspace/interactive-claims"
	local archive_path="" identity="" unavailable_identity="" state=""
	local rc=0

	mkdir -p "$home_path" "$recovery_root" "$claim_dir" || rc=1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"bugfix/gh30902-archive-claim") || rc=1
	"$GIT_BIN" -C "$archive_path" remote add origin \
		"https://github.com/archive/repo.git" || rc=1
	identity=$(_worktree_recovery_plan_identity_json "${archive_path%/*}") || rc=1
	"$GIT_BIN" init -q -b main "$unrelated_repo" || rc=1
	"$GIT_BIN" -C "$unrelated_repo" remote add origin \
		"https://github.com/unrelated/repo.git" || rc=1
	jq -n '{issue:30902,slug:"unrelated/repo",pid:1,
		hostname:"aidevops-remote-fixture.invalid"}' \
		>"${claim_dir}/unrelated-repo-30902.json" || rc=1
	state=$(
		cd "$unrelated_repo" || exit 1
		export HOME="$home_path"
		_worktree_recovery_plan_claim_state "$identity"
	) || rc=1
	[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_CLEAR" ]] || rc=1
	jq -n '{issue:30902,slug:"archive/repo",pid:1,
		hostname:"aidevops-remote-fixture.invalid"}' \
		>"${claim_dir}/archive-repo-30902.json" || rc=1
	state=$(
		cd "$unrelated_repo" || exit 1
		export HOME="$home_path"
		_worktree_recovery_plan_claim_state "$identity"
	) || rc=1
	[[ "$state" == "$WORKTREE_RECOVERY_PLAN_STATE_ACTIVE" ]] || rc=1
	unavailable_identity=$(printf '%s\n' "$identity" | jq -c \
		--arg archive "${TEST_DIR}/missing-archive" '.archive_path = $archive') || rc=1
	state=$(_worktree_recovery_plan_claim_state "$unavailable_identity") || rc=1
	[[ "$state" == "$WORKTREE_RECOVERY_UNAVAILABLE" ]] || rc=1
	print_result "claim_state_uses_archive_repository" "$rc" \
		"Expected archive-bound claims, no unrelated CWD fallback, and unavailable invalid identity"
	return 0
}

test_plan_output_refuses_unsafe_targets() {
	local existing_path="${TEST_DIR}/existing-plan.json"
	local symlink_path="${TEST_DIR}/symlink-plan.json"
	local target_path="${TEST_DIR}/symlink-target.json"
	local home_path="${TEST_DIR}/unsafe-home"
	local recovery_root="${home_path}/recovery"
	local unwritable_dir="${TEST_DIR}/unwritable"
	local unwritable_path="${unwritable_dir}/plan.json"
	local rc=0

	mkdir -p "$recovery_root" "$unwritable_dir" || rc=1
	printf '{}\n' >"$existing_path" || rc=1
	printf '{}\n' >"$target_path" || rc=1
	ln -s "$target_path" "$symlink_path" || rc=1
	if worktree_recovery_plan_write "$existing_path" >/dev/null 2>&1; then rc=1; fi
	if worktree_recovery_plan_write "$symlink_path" >/dev/null 2>&1; then rc=1; fi
	if worktree_recovery_plan_write "relative-plan.json" >/dev/null 2>&1; then rc=1; fi
	chmod 500 "$unwritable_dir" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_plan_write "$unwritable_path" >/dev/null 2>&1; then rc=1; fi
	chmod 700 "$unwritable_dir" || rc=1
	[[ "$(<"$existing_path")" == '{}' && -L "$symlink_path" ]] || rc=1
	[[ ! -e "$unwritable_path" && ! -L "$unwritable_path" ]] || rc=1
	print_result "plan_output_refuses_unsafe_targets" "$rc" \
		"Expected existing, symlinked, and relative outputs to fail without mutation"
	return 0
}

test_classification_fails_closed() {
	local identity='{"source_removal_outcome":"removed","branch":"refs/heads/bugfix/gh29388-plan"}'
	local clear_external='{"commit":"merged","open_pr":"clear","task":"closed"}'
	local evidence="" result=""
	local protected_case=""
	local rc=0

	evidence=$(jq -cn --argjson external "$clear_external" \
		'{git:"dirty",worktree:"clear",registry:"clear",claim:"clear",process:"clear",external:$external}') || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "protected" ]] || rc=1
	evidence=$(jq -cn --argjson external "$clear_external" \
		'{git:"clear",worktree:"clear",registry:"clear",claim:"unavailable",process:"clear",external:$external}') || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "unknown" ]] || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" false) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.reasons[0]')" == "identity-or-size-changed" ]] || rc=1
	for protected_case in worktree registry claim process; do
		evidence=$(jq -cn --arg field "$protected_case" --argjson external "$clear_external" \
			'{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",external:$external} | .[$field]="active"') || rc=1
		result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
		[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "protected" ]] || rc=1
	done
	for clear_external in \
		'{"commit":"unproven","open_pr":"clear","task":"closed"}' \
		'{"commit":"merged","open_pr":"active","task":"closed"}' \
		'{"commit":"merged","open_pr":"clear","task":"open"}'; do
		evidence=$(jq -cn --argjson external "$clear_external" \
			'{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",external:$external}') || rc=1
		result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
		[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "protected" ]] || rc=1
	done
	clear_external='{"commit":"unavailable","open_pr":"unavailable","task":"unavailable"}'
	evidence=$(jq -cn --argjson external "$clear_external" \
		'{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",external:$external}') || rc=1
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "unknown" ]] || rc=1
	identity='{"source_removal_outcome":"removed","branch":"detached"}'
	result=$(_worktree_recovery_plan_classification_json "$identity" "$evidence" true) || rc=1
	[[ "$(printf '%s\n' "$result" | jq -r '.disposition')" == "protected" ]] || rc=1
	print_result "classification_fails_closed" "$rc" \
		"Expected dirty evidence to protect and unavailable or changed evidence to remain unknown"
	return 0
}

test_plan_records_malformed_bucket_unknown() {
	local home_path="${TEST_DIR}/malformed-home"
	local recovery_root="${home_path}/recovery"
	local malformed_bucket="${recovery_root}/aidevops-worktree-cleanup-malformed"
	local output_path="${TEST_DIR}/malformed-plan.json"
	local rc=0

	mkdir -p "${malformed_bucket}/${_WT_RECOVERY_DIR_NAME}" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT_V2" > \
		"${malformed_bucket}/${_WT_RECOVERY_DIR_NAME}/format" || rc=1
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_plan_write "$output_path" >/dev/null || rc=1
	jq -e '.candidate_count == 0 and .unknown_count == 1 and
		.entries[0].reasons == ["archive-unrecognised-or-incomplete"]' \
		"$output_path" >/dev/null || rc=1
	print_result "plan_records_malformed_bucket_unknown" "$rc" \
		"Expected malformed archives to remain visible but never become candidates"
	return 0
}

test_size_drift_downgrades_only_entry() {
	local home_path="${TEST_DIR}/drift-home"
	local repo_path="${TEST_DIR}/drift-repo"
	local worktree_path="${TEST_DIR}/drift-worktree"
	local recovery_root="${home_path}/recovery"
	local archive_path="" bucket_path="" measured="" expected_bytes="" entry=""
	local rc=0

	mkdir -p "$home_path" "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"bugfix/gh29388-drift-plan") || rc=1
	bucket_path="${archive_path%/*}"
	measured=$(_worktree_recovery_measure_path "$bucket_path") || rc=1
	IFS='|' read -r expected_bytes _ _ <<<"$measured"
	entry=$(
		install_clear_evidence_stubs
		_worktree_recovery_measure_path() {
			local ignored_path="$1"
			: "$ignored_path"
			printf '%s|exact|' "$((expected_bytes + 1024))"
			return 0
		}
		_worktree_recovery_plan_attributed_entry_json "current" "$bucket_path" "$expected_bytes"
	) || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.disposition')" == "unknown" ]] || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.reasons[0]')" == "identity-or-size-changed" ]] || rc=1
	print_result "size_drift_downgrades_only_entry" "$rc" \
		"Expected a late byte change to downgrade the affected entry"
	return 0
}

test_attributed_remeasurement_uses_explicit_budget() {
	local bucket_path="${TEST_DIR}/remeasure-budget-bucket"
	local du_script="${TEST_DIR}/remeasure-budget-du.sh"
	local reasons_path="${TEST_DIR}/remeasure-budget-reasons"
	local entry="" timed_out="" counts=""
	local rc=0

	mkdir -p "$bucket_path" || rc=1
	cat >"$du_script" <<'SH'
#!/usr/bin/env bash
sleep 0.3
printf '1\t%s\n' "$2"
SH
	chmod 700 "$du_script" || rc=1
	entry=$(
		_worktree_recovery_plan_identity_json() {
			jq -cn --arg bucket "$bucket_path" \
				'{bucket_path:$bucket,archive_path:($bucket + "/archive"),
				source_removal_outcome:"removed",branch:"refs/heads/bugfix/gh31009"}'
			return $?
		}
		_worktree_recovery_plan_evidence_json() {
			jq -cn '{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",
				external:{commit:"merged",open_pr:"clear",task:"closed"}}'
			return $?
		}
		AIDEVOPS_WORKTREE_RECOVERY_DU_COMMAND="$du_script" \
			AIDEVOPS_WORKTREE_RECOVERY_SIZE_TIMEOUT_TENTHS=2 \
			_worktree_recovery_plan_attributed_entry_json "current" "$bucket_path" 1024 10
	) || rc=1
	[[ "$(printf '%s\n' "$entry" | jq -r '.disposition')" == "candidate" ]] || rc=1
	timed_out=$(
		_worktree_recovery_plan_identity_json() {
			jq -cn --arg bucket "$bucket_path" \
				'{bucket_path:$bucket,archive_path:($bucket + "/archive"),
				source_removal_outcome:"removed",branch:"refs/heads/bugfix/gh31009"}'
			return $?
		}
		_worktree_recovery_plan_evidence_json() {
			jq -cn '{git:"clear",worktree:"clear",registry:"clear",claim:"clear",process:"clear",
				external:{commit:"merged",open_pr:"clear",task:"closed"}}'
			return $?
		}
		AIDEVOPS_WORKTREE_RECOVERY_DU_COMMAND="$du_script" \
			AIDEVOPS_WORKTREE_RECOVERY_SIZE_TIMEOUT_TENTHS=2 \
			_worktree_recovery_plan_attributed_entry_json "current" "$bucket_path" 1024
	) || rc=1
	[[ "$(printf '%s\n' "$timed_out" | jq -r '.reasons[0]')" == "sizing-timeout" ]] || rc=1
	: >"$reasons_path" || rc=1
	_worktree_recovery_maintenance_record_reason "$reasons_path" \
		"$WORKTREE_RECOVERY_PLAN_DISPOSITION_UNKNOWN" "sizing-timeout" || rc=1
	counts=$(_worktree_recovery_maintenance_reason_counts_json "$reasons_path") || rc=1
	printf '%s\n' "$counts" | jq -e \
		'.sizing_timeout == 1 and .sizing_unavailable == 0 and .classification_unavailable == 0' \
		>/dev/null || rc=1
	print_result "attributed_remeasurement_uses_explicit_budget" "$rc" \
		"Expected a slow exact remeasurement to use its supplied budget and distinguish timeout from overall deadline exhaustion"
	return 0
}

test_global_inventory_failure_is_explicit() {
	local plan=""
	local rc=0

	plan=$(
		worktree_recovery_inventory() {
			return 1
		}
		worktree_recovery_plan_json "Linux"
	) || rc=1
	printf '%s\n' "$plan" | jq -e '
		.inventory_complete == false and
		.inventory_error == "classification-unavailable" and
		.candidate_count == 0 and .entry_count == 0
	' >/dev/null || rc=1
	print_result "global_inventory_failure_is_explicit" "$rc" \
		"Expected a failed global scan to produce no candidates and an explicit error"
	return 0
}

test_entry_sizing_failure_is_localized() {
	local plan=""
	local rc=0

	plan=$(
		worktree_recovery_lifecycle_json() {
			printf '%s\n' '{"error":null,"sizing_error":"sizing-timeout","buckets":[
			{"role":"current","state":"attributed","path":"/recovery/exact","bytes":1024,"sizing_confidence":"exact"},
			{"role":"current","state":"attributed","path":"/recovery/slow","bytes":null,"sizing_confidence":"unavailable"}]}'
			return 0
		}
		_worktree_recovery_plan_attributed_entry_json() {
			local role="$1"
			local bucket_path="$2"
			local ignored_bytes="$3"
			local bytes=1024
			: "$ignored_bytes"
			if [[ "$bucket_path" == "/recovery/slow" ]]; then
				_worktree_recovery_plan_unknown_entry_json \
					"$role" "$bucket_path" null "sizing-unavailable"
				return $?
			fi
			jq -cn --arg role "$role" --arg path "$bucket_path" --argjson bytes "$bytes" \
				'{role:$role,path:$path,archive_path:($path + "/archive"),expected_allocated_bytes:$bytes,
				identity:{identity_digest:"sha256:fixture"},evidence:{},disposition:"candidate",
				reasons:["all-required-evidence-clear"]}'
			return $?
		}
		worktree_recovery_plan_json "Linux"
	) || rc=1
	printf '%s\n' "$plan" | jq -e '
		.inventory_complete == true and .inventory_error == null and
		.classification_complete == true and .classified_entry_count == 2 and
		.candidate_count == 1 and .unknown_count == 1 and
		([.entries[] | select(.path == "/recovery/slow")][0].reasons == ["sizing-unavailable"])
	' >/dev/null || rc=1
	print_result "entry_sizing_failure_is_localized" "$rc" \
		"Expected one slow size probe to remain unknown without blocking an exact peer candidate"
	return 0
}

test_manual_plan_classification_is_bounded_and_resumable() {
	local first_output="${TEST_DIR}/bounded-plan-first.json"
	local second_output="${TEST_DIR}/bounded-plan-second.json"
	local rc=0

	(
		worktree_recovery_lifecycle_json() {
			printf '%s\n' '{"error":null,"sizing_error":null,"buckets":[
			{"role":"current","state":"unknown","path":"/recovery/bucket-0","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/bucket-1","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/bucket-2","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/bucket-3","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/bucket-4","bytes":null,"sizing_confidence":"unavailable"}]}'
			return 0
		}
		cmd_recovery plan --max-classify 2 --offset 0 --output "$first_output" >/dev/null || return 1
		cmd_recovery plan --output "$second_output" --offset 2 --max-classify 2 >/dev/null || return 1
	) || rc=1
	jq -e '
		.classification_complete == false and .classified_entry_count == 2 and
		.deferred_entry_count == 3 and .classification_offset == 0 and
		.next_classification_offset == 2 and
		([.entries[] | select(.reasons == ["classification-deferred"]) | .path] ==
		 ["/recovery/bucket-2","/recovery/bucket-3","/recovery/bucket-4"])
	' "$first_output" >/dev/null || rc=1
	jq -e '
		.classification_complete == false and .classified_entry_count == 2 and
		.deferred_entry_count == 3 and .classification_offset == 2 and
		.next_classification_offset == 4 and
		([.entries[] | select(.reasons == ["classification-deferred"]) | .path] ==
		 ["/recovery/bucket-0","/recovery/bucket-1","/recovery/bucket-4"])
	' "$second_output" >/dev/null || rc=1
	[[ "$(jq -r '.plan_id' "$first_output")" != "$(jq -r '.plan_id' "$second_output")" ]] || rc=1
	print_result "manual_plan_classification_is_bounded_and_resumable" "$rc" \
		"Expected bounded plan windows to expose a deterministic continuation offset"
	return 0
}

test_manual_plan_deadline_emits_continuation() {
	local output_path="${TEST_DIR}/deadline-plan.json"
	local clock_path="${TEST_DIR}/deadline-clock"
	local rc=0

	printf '0\n' >"$clock_path" || rc=1
	(
		worktree_recovery_lifecycle_json() {
			printf '%s\n' '{"error":null,"sizing_error":null,"buckets":[
			{"role":"current","state":"unknown","path":"/recovery/deadline-0","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/deadline-1","bytes":null,"sizing_confidence":"unavailable"},
			{"role":"current","state":"unknown","path":"/recovery/deadline-2","bytes":null,"sizing_confidence":"unavailable"}]}'
			return 0
		}
		date() {
			local call_count=0
			if [[ "${1:-}" == "+%s" ]]; then
				IFS= read -r call_count <"$clock_path" || return 1
				call_count=$((call_count + 1))
				printf '%s\n' "$call_count" >"$clock_path" || return 1
				if [[ "$call_count" -le 2 ]]; then printf '100\n'; else printf '102\n'; fi
				return 0
			fi
			command date "$@"
			return $?
		}
		cmd_recovery plan --output "$output_path" --max-classify 3 \
			--deadline-seconds 1 >/dev/null || return 1
	) || rc=1
	jq -e '
		.classification_complete == false and .classified_entry_count == 1 and
		.deferred_entry_count == 2 and .classification_deadline_seconds == 1 and
		.classification_deadline_exhausted == true and .next_classification_offset == 1 and
		([.entries[] | select(.reasons == ["classification-deadline-exhausted"]) | .path] ==
		 ["/recovery/deadline-1","/recovery/deadline-2"])
	' "$output_path" >/dev/null || rc=1
	print_result "manual_plan_deadline_emits_continuation" "$rc" \
		"Expected deadline exhaustion to stop new classification and preserve a continuation offset"
	return 0
}

test_apply_removes_only_candidates_and_replays_receipt() {
	local home_path="${TEST_DIR}/apply-home"
	local repo_path="${TEST_DIR}/apply-repo"
	local worktree_path="${TEST_DIR}/apply-worktree"
	local recovery_root="${home_path}/recovery"
	local malformed_bucket="${recovery_root}/aidevops-worktree-cleanup-unknown"
	local plan_path="${TEST_DIR}/apply-plan.json"
	local receipt_path="${TEST_DIR}/apply-receipt.json"
	local archive_path=""
	local bucket_path=""
	local confirmation=""
	local rc=0

	mkdir -p "$recovery_root" "${malformed_bucket}/${_WT_RECOVERY_DIR_NAME}" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT_V2" > \
		"${malformed_bucket}/${_WT_RECOVERY_DIR_NAME}/format" || rc=1
	archive_path=$(create_archived_fixture "$repo_path" "$worktree_path" "$recovery_root" \
		"bugfix/gh29389-apply-success") || rc=1
	bucket_path="${archive_path%/*}"
	install_clear_evidence_stubs
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery plan --output "$plan_path" >/dev/null || rc=1
	confirmation=$(jq -r '.confirmation_token' "$plan_path") || rc=1
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery apply --plan "$plan_path" --receipt "$receipt_path" \
		--confirm "$confirmation" >/dev/null || rc=1
	[[ ! -e "$bucket_path" && -d "$malformed_bucket" && -f "$receipt_path" ]] || rc=1
	jq -e '
		.schema == "aidevops.worktree-recovery-apply-receipt/v1" and
		.complete == true and .candidate_count == 1 and
		.expected_allocated_bytes == .observed_allocated_bytes and
		(.entries | length == 1) and .entries[0].outcome == "removed"
	' "$receipt_path" >/dev/null || rc=1
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery apply --receipt "$receipt_path" --confirm "$confirmation" \
		--plan "$plan_path" >/dev/null || rc=1
	[[ ! -e "$bucket_path" && -d "$malformed_bucket" ]] || rc=1
	print_result "apply_removes_only_candidates_and_replays_receipt" "$rc" \
		"Expected exact candidate deletion, unknown preservation, an auditable receipt, and safe replay"
	return 0
}

test_apply_rejects_unsafe_manifest_and_cli_inputs() {
	local home_path="${TEST_DIR}/reject-home"
	local repo_path="${TEST_DIR}/reject-repo"
	local worktree_path="${TEST_DIR}/reject-worktree"
	local recovery_root="${home_path}/recovery"
	local plan_path="${TEST_DIR}/reject-plan.json"
	local duplicate_plan="${TEST_DIR}/duplicate-plan.json"
	local outside_plan="${TEST_DIR}/outside-plan.json"
	local unsupported_plan="${TEST_DIR}/unsupported-plan.json"
	local symlink_plan="${TEST_DIR}/reject-symlink-plan.json"
	local mismatched_receipt="${TEST_DIR}/mismatched-receipt.json"
	local receipt_path="${TEST_DIR}/rejected-receipt.json"
	local candidate_plan=""
	local candidate_receipt=""
	local outside_root="${TEST_DIR}/outside-root"
	local archive_path=""
	local bucket_path=""
	local confirmation=""
	local rc=0

	archive_path=$(create_candidate_plan_fixture "$home_path" "$repo_path" "$worktree_path" \
		"$recovery_root" "bugfix/gh29389-reject-inputs" "$plan_path") || rc=1
	bucket_path="${archive_path%/*}"
	confirmation=$(jq -r '.confirmation_token' "$plan_path") || rc=1
	install_clear_evidence_stubs
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery apply --plan "$plan_path" --receipt "$receipt_path" \
		--confirm "apply-sha256:$(printf '0%.0s' {1..64})" >/dev/null 2>&1; then rc=1; fi
	if cmd_recovery apply --plan "$plan_path" --plan "$plan_path" \
		--receipt "$receipt_path" --confirm "$confirmation" >/dev/null 2>&1; then rc=1; fi
	if cmd_recovery apply --plan "$plan_path" --receipt "$receipt_path" \
		--unknown value --confirm "$confirmation" >/dev/null 2>&1; then rc=1; fi
	if cmd_recovery apply --plan "$plan_path" --receipt "$receipt_path" >/dev/null 2>&1; then rc=1; fi
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_apply "relative-plan.json" "$receipt_path" "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_apply "$plan_path" "relative-receipt.json" "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	candidate_receipt="${archive_path}/unsafe-receipt.json"
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_apply "$plan_path" "$candidate_receipt" "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	candidate_plan="${archive_path}/unsafe-plan.json"
	jq -c '.' "$plan_path" >"$candidate_plan" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_apply "$candidate_plan" "$receipt_path" "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	ln -s "$plan_path" "$symlink_plan" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_apply "$symlink_plan" "$receipt_path" "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	printf '{}\n' >"$mismatched_receipt" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_apply "$plan_path" "$mismatched_receipt" "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	jq -c '.schema = "aidevops.worktree-recovery-plan/unsupported"' \
		"$plan_path" >"$unsupported_plan" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_apply "$unsupported_plan" "$receipt_path" "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	jq -c '
		.entries += [.entries[0]] |
		.entry_count += 1 | .sized_entry_count += 1 |
		.expected_allocated_bytes += .entries[0].expected_allocated_bytes |
		.candidate_count += 1 | .candidate_bytes += .entries[0].expected_allocated_bytes
	' "$plan_path" >"$duplicate_plan" || rc=1
	resign_test_plan "$duplicate_plan" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_apply "$duplicate_plan" "$receipt_path" \
		"$(jq -r '.confirmation_token' "$duplicate_plan")" >/dev/null 2>&1; then rc=1; fi
	mkdir -p "$outside_root" || rc=1
	jq -c --arg path "${outside_root}/forged-bucket" \
		--arg archive "${outside_root}/forged-bucket/archive" \
		'.entries[0].path = $path | .entries[0].archive_path = $archive' \
		"$plan_path" >"$outside_plan" || rc=1
	resign_test_plan "$outside_plan" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		worktree_recovery_apply "$outside_plan" "$receipt_path" \
		"$(jq -r '.confirmation_token' "$outside_plan")" >/dev/null 2>&1; then rc=1; fi
	[[ -d "$bucket_path" && ! -e "$receipt_path" && ! -L "$receipt_path" &&
		! -e "$candidate_receipt" ]] || rc=1
	print_result "apply_rejects_unsafe_manifest_and_cli_inputs" "$rc" \
		"Expected malformed consent, parser input, receipts, schemas, duplicates, and roots to fail closed"
	return 0
}

test_apply_preflight_drift_stages_nothing() {
	local home_path="${TEST_DIR}/preflight-home"
	local recovery_root="${home_path}/recovery"
	local plan_path="${TEST_DIR}/preflight-plan.json"
	local receipt_path="${TEST_DIR}/preflight-receipt.json"
	local archive_a="" archive_b="" bucket_a="" bucket_b="" confirmation=""
	local staged_count=0
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_a=$(create_archived_fixture "${TEST_DIR}/preflight-repo-a" \
		"${TEST_DIR}/preflight-worktree-a" "$recovery_root" \
		"bugfix/gh29389-preflight-a") || rc=1
	archive_b=$(create_archived_fixture "${TEST_DIR}/preflight-repo-b" \
		"${TEST_DIR}/preflight-worktree-b" "$recovery_root" \
		"bugfix/gh29389-preflight-b") || rc=1
	bucket_a="${archive_a%/*}"
	bucket_b="${archive_b%/*}"
	install_clear_evidence_stubs
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery plan --output "$plan_path" >/dev/null || rc=1
	confirmation=$(jq -r '.confirmation_token' "$plan_path") || rc=1
	printf 'late drift\n' >"${archive_b}/late-drift.bin" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery apply --plan "$plan_path" --receipt "$receipt_path" \
		--confirm "$confirmation" >/dev/null 2>&1; then rc=1; fi
	[[ -d "$bucket_a" && -d "$bucket_b" && -f "$receipt_path" ]] || rc=1
	jq -e '
		.schema == "aidevops.worktree-recovery-apply-reservation/v1" and .complete == false
	' "$receipt_path" >/dev/null || rc=1
	for staged_path in "$recovery_root"/.retention-trash/apply-*/candidate-*; do
		[[ -e "$staged_path" || -L "$staged_path" ]] || continue
		staged_count=$((staged_count + 1))
	done
	[[ "$staged_count" -eq 0 ]] || rc=1
	print_result "apply_preflight_drift_stages_nothing" "$rc" \
		"Expected one late candidate drift to leave the complete batch at original paths"
	return 0
}

test_apply_resumes_move_and_delete_crash_windows() {
	local move_home="${TEST_DIR}/move-home"
	local move_root="${move_home}/recovery"
	local move_plan="${TEST_DIR}/move-plan.json"
	local move_receipt="${TEST_DIR}/move-receipt.json"
	local delete_home="${TEST_DIR}/delete-home"
	local delete_root="${delete_home}/recovery"
	local delete_plan="${TEST_DIR}/delete-plan.json"
	local delete_receipt="${TEST_DIR}/delete-receipt.json"
	local archive_path="" bucket_path="" confirmation="" journal_path="" staged_path=""
	local candidate_journal=""
	local rc=0

	archive_path=$(create_candidate_plan_fixture "$move_home" "${TEST_DIR}/move-repo" \
		"${TEST_DIR}/move-worktree" "$move_root" "bugfix/gh29389-move-interrupt" \
		"$move_plan") || rc=1
	bucket_path="${archive_path%/*}"
	confirmation=$(jq -r '.confirmation_token' "$move_plan") || rc=1
	install_clear_evidence_stubs
	if AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_MOVE=1 HOME="$move_home" \
		AIDEVOPS_WORKTREE_TRASH_ROOT="$move_root" cmd_recovery apply \
		--plan "$move_plan" --receipt "$move_receipt" --confirm "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	for candidate_journal in "$move_root"/.retention-trash/apply-*/journal.json; do
		[[ -f "$candidate_journal" ]] || continue
		journal_path="$candidate_journal"
	done
	[[ -n "$journal_path" && ! -e "$bucket_path" && -f "$move_receipt" ]] || rc=1
	jq -e '.schema == "aidevops.worktree-recovery-apply-reservation/v1" and .complete == false' \
		"$move_receipt" >/dev/null || rc=1
	staged_path=$(jq -r '.entries[0].staged_path' "$journal_path") || rc=1
	[[ "$(jq -r '.entries[0].state' "$journal_path")" == "planned" && -d "$staged_path" ]] || rc=1
	HOME="$move_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$move_root" cmd_recovery apply \
		--plan "$move_plan" --receipt "$move_receipt" --confirm "$confirmation" \
		>/dev/null || rc=1
	[[ -f "$move_receipt" && ! -e "$staged_path" ]] || rc=1

	archive_path=$(create_candidate_plan_fixture "$delete_home" "${TEST_DIR}/delete-repo" \
		"${TEST_DIR}/delete-worktree" "$delete_root" "bugfix/gh29389-delete-interrupt" \
		"$delete_plan") || rc=1
	bucket_path="${archive_path%/*}"
	confirmation=$(jq -r '.confirmation_token' "$delete_plan") || rc=1
	install_clear_evidence_stubs
	if AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_DELETE=1 HOME="$delete_home" \
		AIDEVOPS_WORKTREE_TRASH_ROOT="$delete_root" cmd_recovery apply \
		--plan "$delete_plan" --receipt "$delete_receipt" --confirm "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	journal_path=""
	for candidate_journal in "$delete_root"/.retention-trash/apply-*/journal.json; do
		[[ -f "$candidate_journal" ]] || continue
		journal_path="$candidate_journal"
	done
	[[ -n "$journal_path" && ! -e "$bucket_path" && -f "$delete_receipt" ]] || rc=1
	jq -e '.schema == "aidevops.worktree-recovery-apply-reservation/v1" and .complete == false' \
		"$delete_receipt" >/dev/null || rc=1
	staged_path=$(jq -r '.entries[0].staged_path' "$journal_path") || rc=1
	[[ "$(jq -r '.entries[0].state' "$journal_path")" == "staged" && ! -e "$staged_path" ]] || rc=1
	HOME="$delete_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$delete_root" cmd_recovery apply \
		--plan "$delete_plan" --receipt "$delete_receipt" --confirm "$confirmation" \
		>/dev/null || rc=1
	[[ -f "$delete_receipt" ]] || rc=1
	print_result "apply_resumes_move_and_delete_crash_windows" "$rc" \
		"Expected retries to reconcile exact journal state after rename or delete interruption"
	return 0
}

test_apply_resumes_transaction_initialization_crashes() {
	local dir_home="${TEST_DIR}/transaction-dir-home"
	local dir_root="${dir_home}/recovery"
	local dir_plan="${TEST_DIR}/transaction-dir-plan.json"
	local dir_receipt="${TEST_DIR}/transaction-dir-receipt.json"
	local next_home="${TEST_DIR}/journal-next-home"
	local next_root="${next_home}/recovery"
	local next_plan="${TEST_DIR}/journal-next-plan.json"
	local next_receipt="${TEST_DIR}/journal-next-receipt.json"
	local archive_path="" bucket_path="" confirmation="" next_path=""
	local rc=0

	archive_path=$(create_candidate_plan_fixture "$dir_home" "${TEST_DIR}/transaction-dir-repo" \
		"${TEST_DIR}/transaction-dir-worktree" "$dir_root" \
		"bugfix/gh29389-transaction-dir-interrupt" "$dir_plan") || rc=1
	bucket_path="${archive_path%/*}"
	confirmation=$(jq -r '.confirmation_token' "$dir_plan") || rc=1
	if AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_TRANSACTION_DIR=1 HOME="$dir_home" \
		AIDEVOPS_WORKTREE_TRASH_ROOT="$dir_root" cmd_recovery apply --plan "$dir_plan" \
		--receipt "$dir_receipt" --confirm "$confirmation" >/dev/null 2>&1; then rc=1; fi
	[[ -d "$bucket_path" && -f "$dir_receipt" ]] || rc=1
	HOME="$dir_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$dir_root" cmd_recovery apply \
		--plan "$dir_plan" --receipt "$dir_receipt" --confirm "$confirmation" >/dev/null || rc=1
	[[ ! -e "$bucket_path" ]] || rc=1

	archive_path=$(create_candidate_plan_fixture "$next_home" "${TEST_DIR}/journal-next-repo" \
		"${TEST_DIR}/journal-next-worktree" "$next_root" \
		"bugfix/gh29389-journal-next-interrupt" "$next_plan") || rc=1
	bucket_path="${archive_path%/*}"
	confirmation=$(jq -r '.confirmation_token' "$next_plan") || rc=1
	if AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_JOURNAL_NEXT=1 HOME="$next_home" \
		AIDEVOPS_WORKTREE_TRASH_ROOT="$next_root" cmd_recovery apply --plan "$next_plan" \
		--receipt "$next_receipt" --confirm "$confirmation" >/dev/null 2>&1; then rc=1; fi
	for next_path in "$next_root"/.retention-trash/apply-*/.journal.json.next; do
		[[ -f "$next_path" && -d "$bucket_path" ]] || rc=1
	done
	HOME="$next_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$next_root" cmd_recovery apply \
		--plan "$next_plan" --receipt "$next_receipt" --confirm "$confirmation" >/dev/null || rc=1
	[[ ! -e "$bucket_path" ]] || rc=1
	print_result "apply_resumes_transaction_initialization_crashes" "$rc" \
		"Expected empty transaction directories and journal-next files to resume safely"
	return 0
}

test_receipt_reservation_blocks_conflicting_plan() {
	local home_path="${TEST_DIR}/reservation-home"
	local recovery_root="${home_path}/recovery"
	local first_plan="${TEST_DIR}/reservation-first-plan.json"
	local second_plan="${TEST_DIR}/reservation-second-plan.json"
	local receipt_path="${TEST_DIR}/reservation-receipt.json"
	local first_archive="" first_bucket="" first_confirmation=""
	local second_archive="" second_bucket="" second_confirmation=""
	local rc=0

	first_archive=$(create_candidate_plan_fixture "$home_path" "${TEST_DIR}/reservation-first-repo" \
		"${TEST_DIR}/reservation-first-worktree" "$recovery_root" \
		"bugfix/gh29389-reservation-first" "$first_plan") || rc=1
	first_bucket="${first_archive%/*}"
	first_confirmation=$(jq -r '.confirmation_token' "$first_plan") || rc=1
	if AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_RECEIPT_RESERVATION=1 HOME="$home_path" \
		AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" cmd_recovery apply --plan "$first_plan" \
		--receipt "$receipt_path" --confirm "$first_confirmation" >/dev/null 2>&1; then rc=1; fi
	second_archive=$(create_candidate_plan_fixture "$home_path" "${TEST_DIR}/reservation-second-repo" \
		"${TEST_DIR}/reservation-second-worktree" "$recovery_root" \
		"bugfix/gh29389-reservation-second" "$second_plan") || rc=1
	second_bucket="${second_archive%/*}"
	second_confirmation=$(jq -r '.confirmation_token' "$second_plan") || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" cmd_recovery apply \
		--plan "$second_plan" --receipt "$receipt_path" --confirm "$second_confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	[[ -d "$first_bucket" && -d "$second_bucket" ]] || rc=1
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" cmd_recovery apply \
		--plan "$first_plan" --receipt "$receipt_path" --confirm "$first_confirmation" >/dev/null || rc=1
	[[ ! -e "$first_bucket" && -d "$second_bucket" ]] || rc=1
	jq -e --arg plan_id "$(jq -r '.plan_id' "$first_plan")" \
		'.schema == "aidevops.worktree-recovery-apply-receipt/v1" and
		.complete == true and .plan_id == $plan_id' "$receipt_path" >/dev/null || rc=1
	print_result "receipt_reservation_blocks_conflicting_plan" "$rc" \
		"Expected one plan-bound reservation to block conflicting deletion and permit exact retry"
	return 0
}

test_receipt_publication_owns_only_reserved_temp() {
	local kind="" home_path="" recovery_root="" plan_path="" receipt_path=""
	local archive_path="" bucket_path="" confirmation="" sidecar_path=""
	local collision_home="${TEST_DIR}/completion-collision-home"
	local collision_root="${collision_home}/recovery"
	local collision_plan="${TEST_DIR}/completion-collision-plan.json"
	local collision_receipt="${TEST_DIR}/completion-collision-receipt.json"
	local completion_path=""
	local rc=0

	printf 'symlink sentinel\n' >"${TEST_DIR}/sidecar-symlink-target" || rc=1
	for kind in regular directory symlink; do
		home_path="${TEST_DIR}/sidecar-${kind}-home"
		recovery_root="${home_path}/recovery"
		plan_path="${TEST_DIR}/sidecar-${kind}-plan.json"
		receipt_path="${TEST_DIR}/sidecar-${kind}-receipt.json"
		sidecar_path="${receipt_path%/*}/.${receipt_path##*/}.next"
		archive_path=$(create_candidate_plan_fixture "$home_path" \
			"${TEST_DIR}/sidecar-${kind}-repo" "${TEST_DIR}/sidecar-${kind}-worktree" \
			"$recovery_root" "bugfix/gh29389-sidecar-${kind}" "$plan_path") || rc=1
		bucket_path="${archive_path%/*}"
		confirmation=$(jq -r '.confirmation_token' "$plan_path") || rc=1
		case "$kind" in
		regular) printf 'regular sentinel\n' >"$sidecar_path" || rc=1 ;;
		directory) mkdir "$sidecar_path" || rc=1 ;;
		symlink) ln -s "${TEST_DIR}/sidecar-symlink-target" "$sidecar_path" || rc=1 ;;
		esac
		HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" cmd_recovery apply \
			--plan "$plan_path" --receipt "$receipt_path" --confirm "$confirmation" >/dev/null || rc=1
		[[ ! -e "$bucket_path" && -f "$receipt_path" ]] || rc=1
		case "$kind" in
		regular) [[ "$(<"$sidecar_path")" == "regular sentinel" ]] || rc=1 ;;
		directory) [[ -d "$sidecar_path" && ! -L "$sidecar_path" ]] || rc=1 ;;
		symlink) [[ -L "$sidecar_path" && "$(<"${TEST_DIR}/sidecar-symlink-target")" == "symlink sentinel" ]] || rc=1 ;;
		esac
	done

	archive_path=$(create_candidate_plan_fixture "$collision_home" \
		"${TEST_DIR}/completion-collision-repo" "${TEST_DIR}/completion-collision-worktree" \
		"$collision_root" "bugfix/gh29389-completion-collision" "$collision_plan") || rc=1
	bucket_path="${archive_path%/*}"
	confirmation=$(jq -r '.confirmation_token' "$collision_plan") || rc=1
	if AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_RECEIPT_RESERVATION=1 \
		HOME="$collision_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$collision_root" cmd_recovery apply \
		--plan "$collision_plan" --receipt "$collision_receipt" --confirm "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	completion_path=$(jq -r '.completion_path' "$collision_receipt") || rc=1
	rm -f "$completion_path" || rc=1
	mkdir "$completion_path" || rc=1
	if HOME="$collision_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$collision_root" cmd_recovery apply \
		--plan "$collision_plan" --receipt "$collision_receipt" --confirm "$confirmation" \
		>/dev/null 2>&1; then rc=1; fi
	[[ -d "$bucket_path" && -d "$completion_path" ]] || rc=1
	print_result "receipt_publication_owns_only_reserved_temp" "$rc" \
		"Expected adjacent sentinels preserved and reserved-temp replacement detected before deletion"
	return 0
}

test_shared_producer_lock_fails_closed_and_reclaims_stale() {
	local home_path="${TEST_DIR}/lock-home"
	local recovery_root="${home_path}/recovery"
	local plan_path="${TEST_DIR}/lock-plan.json"
	local receipt_path="${TEST_DIR}/lock-receipt.json"
	local archive_path="" bucket_path="" confirmation="" live_lstart=""
	local source_repo="${TEST_DIR}/lock-source-repo"
	local source_worktree="${TEST_DIR}/lock-source-worktree"
	local lock_path="${recovery_root}/${_WT_RECOVERY_PRODUCER_LOCK_NAME}"
	local rc=0

	archive_path=$(create_candidate_plan_fixture "$home_path" "${TEST_DIR}/lock-repo" \
		"${TEST_DIR}/lock-worktree" "$recovery_root" "bugfix/gh29389-lock-apply" \
		"$plan_path") || rc=1
	bucket_path="${archive_path%/*}"
	confirmation=$(jq -r '.confirmation_token' "$plan_path") || rc=1
	create_unarchived_fixture "$source_repo" "$source_worktree" \
		"bugfix/gh29389-lock-archive" || rc=1
	live_lstart=$(_worktree_recovery_process_lstart "$$") || rc=1
	write_test_producer_lock "$recovery_root" "$$" "$live_lstart" || rc=1
	install_clear_evidence_stubs
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery apply --plan "$plan_path" --receipt "$receipt_path" \
		--confirm "$confirmation" >/dev/null 2>&1; then rc=1; fi
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$source_worktree" "test.sh" "shared-lock" >/dev/null 2>&1; then rc=1; fi
	[[ -d "$bucket_path" && -d "$source_worktree" && ! -e "$receipt_path" ]] || rc=1
	remove_test_producer_lock "$recovery_root" || rc=1
	mkdir "$lock_path" || rc=1
	if HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" \
		cmd_recovery apply --plan "$plan_path" --receipt "$receipt_path" \
		--confirm "$confirmation" >/dev/null 2>&1; then rc=1; fi
	rmdir "$lock_path" || rc=1
	write_test_producer_lock "$recovery_root" "999999999" "stale-process-generation" || rc=1
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" cmd_recovery apply \
		--plan "$plan_path" --receipt "$receipt_path" --confirm "$confirmation" \
		>/dev/null || rc=1
	[[ ! -e "$bucket_path" && -f "$receipt_path" && ! -e "$lock_path" ]] || rc=1
	print_result "shared_producer_lock_fails_closed_and_reclaims_stale" "$rc" \
		"Expected live/malformed locks to block both producers and a proven stale lock to be reclaimed"
	return 0
}

test_apply_handles_attributable_legacy_root_transaction() {
	local home_path="${TEST_DIR}/legacy-home"
	local current_root="${home_path}/current-recovery"
	local legacy_root="${home_path}/.Trash"
	local plan_path="${TEST_DIR}/legacy-plan.json"
	local receipt_path="${TEST_DIR}/legacy-receipt.json"
	local archive_path="" bucket_path="" confirmation=""
	local rc=0

	mkdir -p "$current_root" "$legacy_root" || rc=1
	archive_path=$(create_archived_fixture "${TEST_DIR}/legacy-repo" \
		"${TEST_DIR}/legacy-worktree" "$legacy_root" \
		"bugfix/gh29389-legacy-transaction") || rc=1
	bucket_path="${archive_path%/*}"
	TEST_LEGACY_RECOVERY_ROOT="$legacy_root"
	_worktree_legacy_recovery_root() {
		local ignored_platform="${1:-}"
		: "$ignored_platform"
		printf '%s\n' "$TEST_LEGACY_RECOVERY_ROOT"
		return 0
	}
	install_clear_evidence_stubs
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$current_root" \
		cmd_recovery plan --output "$plan_path" >/dev/null || rc=1
	confirmation=$(jq -r '.confirmation_token' "$plan_path") || rc=1
	HOME="$home_path" AIDEVOPS_WORKTREE_TRASH_ROOT="$current_root" cmd_recovery apply \
		--plan "$plan_path" --receipt "$receipt_path" --confirm "$confirmation" \
		>/dev/null || rc=1
	[[ ! -e "$bucket_path" && -f "$receipt_path" &&
		! -d "$legacy_root/.retention-trash" && ! -d "$current_root/.retention-trash" ]] || rc=1
	print_result "apply_handles_attributable_legacy_root_transaction" "$rc" \
		"Expected one locked journal to stage and clean an exact candidate in an attributable legacy root"
	return 0
}

test_automatic_maintenance_is_bounded_and_policy_bound() {
	local home_path="${TEST_DIR}/automatic-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_a="" archive_b="" archive_protected=""
	local bucket_a="" bucket_b="" protected_bucket=""
	local output="" receipt_path="" removed_count=0
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_a=$(create_archived_fixture "${TEST_DIR}/automatic-repo-a" \
		"${TEST_DIR}/automatic-worktree-a" "$recovery_root" \
		"bugfix/gh29832-automatic-a") || rc=1
	archive_b=$(create_archived_fixture "${TEST_DIR}/automatic-repo-b" \
		"${TEST_DIR}/automatic-worktree-b" "$recovery_root" \
		"bugfix/gh29832-automatic-b") || rc=1
	archive_protected=$(create_archived_fixture "${TEST_DIR}/automatic-repo-protected" \
		"${TEST_DIR}/automatic-worktree-protected" "$recovery_root" \
		"bugfix/gh29832-automatic-protected") || rc=1
	bucket_a="${archive_a%/*}"
	bucket_b="${archive_b%/*}"
	protected_bucket="${archive_protected%/*}"
	printf 'pending\n' >"${protected_bucket}/${_WT_RECOVERY_DIR_NAME}/source-removal-outcome" || rc=1
	install_clear_evidence_stubs
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_CANDIDATES=1 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "removed" ]] || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.removed')" == "1" ]] || rc=1
	printf '%s\n' "$output" | jq -e '
		.diagnostics.inventory_count == 3 and .diagnostics.scanned_count == 3 and
		.diagnostics.coverage_complete == true and .diagnostics.coverage_percent == 100 and
		.diagnostics.reason_counts.protected_evidence == 1 and
		.diagnostics.reason_counts.protected_limit == 1 and
		.diagnostics.classification_reason_counts.source_removal_not_complete == 1 and
		.diagnostics.classification_reason_counts.selection_limit == 1
	' >/dev/null || rc=1
	[[ -d "$protected_bucket" ]] || rc=1
	[[ -d "$bucket_a" ]] && removed_count=$((removed_count + 0)) || removed_count=$((removed_count + 1))
	[[ -d "$bucket_b" ]] && removed_count=$((removed_count + 0)) || removed_count=$((removed_count + 1))
	[[ "$removed_count" -eq 1 ]] || rc=1
	receipt_path=$(printf '%s\n' "$output" | jq -r '.receipt') || rc=1
	jq -e --arg policy_id "$WORKTREE_RECOVERY_AUTOMATION_POLICY_ID" '
		.complete == true and .candidate_count == 1 and
		(.confirmation | startswith("automatic-sha256:")) and
		.automatic_policy.policy_id == $policy_id and
		.entries[0].maintenance.selected_reason == "pressure"
	' "$receipt_path" >/dev/null || rc=1
	print_result "automatic_maintenance_is_bounded_and_policy_bound" "$rc" \
		"Expected pressure cleanup to remove one exact candidate and preserve protected evidence"
	return 0
}

test_automatic_maintenance_checks_capacity_before_aggregate_size() {
	local home_path="${TEST_DIR}/automatic-capacity-first-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" bucket_path="" output="" receipt_path=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "${TEST_DIR}/automatic-capacity-first-repo" \
		"${TEST_DIR}/automatic-capacity-first-worktree" "$recovery_root" \
		"bugfix/gh30443-capacity-first") || rc=1
	bucket_path="${archive_path%/*}"
	install_clear_evidence_stubs
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=1
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
			return 0
		}
		_worktree_recovery_maintenance_measure_store() {
			return 1
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS=3650 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "removed" ]] || rc=1
	receipt_path=$(printf '%s\n' "$output" | jq -r '.receipt') || rc=1
	jq -e '
		.automatic_policy.pressure_active == true and
		.automatic_policy.pressure_reason == "filesystem-free-kb-soft-limit" and
		.automatic_policy.store_bytes == null and
		.entries[0].maintenance.selected_reason == "pressure"
	' "$receipt_path" >/dev/null || rc=1
	[[ ! -e "$bucket_path" ]] || rc=1
	print_result "automatic_maintenance_checks_capacity_before_aggregate_size" "$rc" \
		"Expected known low capacity to bypass aggregate sizing and retain exact candidate checks"
	return 0
}

test_automatic_maintenance_enters_pressure_when_aggregate_size_times_out() {
	local home_path="${TEST_DIR}/automatic-age-fallback-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" bucket_path="" output="" receipt_path=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "${TEST_DIR}/automatic-age-fallback-repo" \
		"${TEST_DIR}/automatic-age-fallback-worktree" "$recovery_root" \
		"bugfix/gh30443-age-fallback") || rc=1
	bucket_path="${archive_path%/*}"
	install_clear_evidence_stubs
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=90000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=90
			return 0
		}
		_worktree_recovery_maintenance_measure_store() {
			local ignored_root="$1"
			local aggregate_timeout="$2"
			: "$ignored_root"
			[[ "$aggregate_timeout" == "73" ]] || return 1
			printf 'null|unavailable|sizing-timeout'
			return 0
		}
		_worktree_recovery_maintenance_age_seconds() {
			local ignored_entry="$1"
			: "$ignored_entry"
			printf '0\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_AGGREGATE_SIZE_TIMEOUT_TENTHS=73 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS=7 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "removed" ]] || rc=1
	receipt_path=$(printf '%s\n' "$output" | jq -r '.receipt') || rc=1
	jq -e '
		.automatic_policy.pressure_active == true and
		.automatic_policy.pressure_reason == "aggregate-size-unavailable" and
		.automatic_policy.store_bytes == null and
		.entries[0].maintenance.selected_reason == "pressure"
	' "$receipt_path" >/dev/null || rc=1
	[[ ! -e "$bucket_path" ]] || rc=1
	print_result "automatic_maintenance_enters_pressure_when_aggregate_size_times_out" "$rc" \
		"Expected aggregate sizing uncertainty to trigger bounded pressure cleanup"
	return 0
}

test_automatic_maintenance_deadline_advances_cursor() {
	local home_path="${TEST_DIR}/automatic-deadline-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local bucket_path="" output=""
	local started_epoch=0 elapsed_seconds=0
	local index=0 remaining_buckets=0
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	while [[ "$index" -lt 300 ]]; do
		printf -v bucket_path '%s/aidevops-worktree-cleanup-%03d' "$recovery_root" "$index"
		mkdir "$bucket_path" || rc=1
		index=$((index + 1))
	done
	started_epoch=$(date +%s) || rc=1
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=1
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
			return 0
		}
		_worktree_recovery_inventory_bucket_state() {
			local ignored_bucket="$1"
			local ignored_root="$2"
			local deadline_epoch="$3"
			: "$ignored_bucket" "$ignored_root"
			_worktree_recovery_run_before_epoch "$deadline_epoch" sleep 5
			return $?
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_DEADLINE_SECONDS=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run
	) || rc=1
	elapsed_seconds=$(($(date +%s) - started_epoch)) || rc=1
	for bucket_path in "$recovery_root"/aidevops-worktree-cleanup-*; do
		[[ -d "$bucket_path" ]] && remaining_buckets=$((remaining_buckets + 1))
	done
	printf '%s\n' "$output" | jq -e '
		.outcome == "no-candidates" and .policy.pressure_active == true and
		.diagnostics.inventory_count == 300 and .diagnostics.scanned_count == 1 and
		.diagnostics.cursor_before == 0 and .diagnostics.cursor_after == 1 and
		.diagnostics.deadline_seconds == 1 and .diagnostics.deadline_exhausted == true and
		.diagnostics.reason_counts.unknown_archive == 1
	' >/dev/null || rc=1
	[[ "$elapsed_seconds" -le 6 && "$remaining_buckets" -eq 300 ]] || rc=1
	print_result "automatic_maintenance_deadline_advances_cursor" "$rc" \
		"Expected 300 delayed validations to stop within the deadline, advance one cursor entry, and preserve every bucket"
	return 0
}

test_automatic_maintenance_bounds_classification_subprocesses() {
	local home_path="${TEST_DIR}/automatic-classification-timeout-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local bucket_path="${recovery_root}/aidevops-worktree-cleanup-timeout"
	local output=""
	local started_epoch=0
	local elapsed_seconds=0
	local rc=0

	mkdir -p "$bucket_path" || rc=1
	started_epoch=$(date +%s) || rc=1
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=1
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
			return 0
		}
		_worktree_recovery_maintenance_inventory_file() {
			local output_path="$1"
			local ignored_platform="$2"
			: "$ignored_platform"
			printf '%s\n' "$bucket_path" >"$output_path"
			return $?
		}
		_worktree_recovery_inventory_bucket_state() {
			local ignored_bucket="$1"
			local ignored_root="$2"
			local ignored_deadline="$3"
			: "$ignored_bucket" "$ignored_root" "$ignored_deadline"
			printf 'attributed\n'
			return 0
		}
		_worktree_recovery_measure_path() {
			local ignored_path="$1"
			local ignored_timeout="$2"
			: "$ignored_path" "$ignored_timeout"
			printf '1024|exact|\n'
			return 0
		}
		_worktree_recovery_plan_attributed_entry_json() {
			local ignored_role="$1"
			local ignored_path="$2"
			local ignored_bytes="$3"
			: "$ignored_role" "$ignored_path" "$ignored_bytes"
			sleep 5
			return 1
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_DEADLINE_SECONDS=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run
	) || rc=1
	elapsed_seconds=$(($(date +%s) - started_epoch)) || rc=1
	printf '%s\n' "$output" | jq -e '
		.outcome == "no-candidates" and .policy.pressure_active == true and
		.diagnostics.inventory_count == 1 and .diagnostics.scanned_count == 1 and
		.diagnostics.cursor_before == 0 and .diagnostics.cursor_after == 0 and
		.diagnostics.deadline_exhausted == true and
		.diagnostics.reason_counts.unknown_classification == 1
	' >/dev/null || rc=1
	[[ "$elapsed_seconds" -le 6 && -d "$bucket_path" ]] || rc=1
	print_result "automatic_maintenance_bounds_classification_subprocesses" "$rc" \
		"Expected classification and descendants to stop at the aggregate deadline without deleting the bucket"
	return 0
}

test_automatic_maintenance_preserves_bucket_when_exact_size_is_unavailable() {
	local home_path="${TEST_DIR}/automatic-bucket-timeout-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" bucket_path="" output=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "${TEST_DIR}/automatic-bucket-timeout-repo" \
		"${TEST_DIR}/automatic-bucket-timeout-worktree" "$recovery_root" \
		"bugfix/gh30443-bucket-timeout") || rc=1
	bucket_path="${archive_path%/*}"
	install_clear_evidence_stubs
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		aidevops_disk_capacity_snapshot() {
			local ignored_path="$1"
			: "$ignored_path"
			AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=90000
			AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=90
			return 0
		}
		_worktree_recovery_maintenance_measure_store() {
			local ignored_root="$1"
			local ignored_timeout="$2"
			: "$ignored_root" "$ignored_timeout"
			printf '1024|exact|'
			return 0
		}
		_worktree_recovery_measure_path() {
			local ignored_path="$1"
			: "$ignored_path"
			printf 'null|unavailable|sizing-timeout'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=10 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS=1 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "no-candidates" ]] || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.policy.unknown_count')" == "1" ]] || rc=1
	printf '%s\n' "$output" | jq -e '
		.diagnostics.inventory_count == 1 and .diagnostics.scanned_count == 1 and
		.diagnostics.cursor_before == 0 and .diagnostics.cursor_after == 0 and
		.diagnostics.coverage_complete == true and
		.diagnostics.reason_counts.unknown_sizing == 1 and
		.diagnostics.classification_reason_counts.sizing_unavailable == 1
	' >/dev/null || rc=1
	[[ -d "$bucket_path" ]] || rc=1
	print_result "automatic_maintenance_preserves_bucket_when_exact_size_is_unavailable" "$rc" \
		"Expected per-bucket sizing uncertainty to remain non-destructive"
	return 0
}

run_zero_candidate_cycle_fixture() {
	local home_path="$1"
	local recovery_root="$2"
	local state_dir="$3"

	uname() {
		printf 'Linux\n'
		return 0
	}
	aidevops_disk_capacity_snapshot() {
		local ignored_path="$1"
		: "$ignored_path"
		AIDEVOPS_DISK_CAPACITY_TOTAL_KB=100000
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=1
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
		return 0
	}
	_worktree_recovery_maintenance_inventory_file() {
		local output_path="$1"
		local ignored_platform="$2"
		: "$ignored_platform"
		printf '%s/unknown-a\n%s/protected\n%s/unknown-b\n' \
			"$recovery_root" "$recovery_root" "$recovery_root" >"$output_path"
		return $?
	}
	_worktree_recovery_inventory_bucket_state() {
		local bucket_path="$1"
		local ignored_root="$2"
		local ignored_deadline="$3"
		: "$ignored_root" "$ignored_deadline"
		case "$bucket_path" in
		*/protected) printf 'attributed\n' ;;
		*) printf 'unknown\n' ;;
		esac
		return 0
	}
	_worktree_recovery_measure_path() {
		local ignored_path="$1"
		: "$ignored_path"
		printf '1024|exact|\n'
		return 0
	}
	_worktree_recovery_plan_attributed_entry_json() {
		local ignored_role="$1"
		local ignored_path="$2"
		local ignored_bytes="$3"
		: "$ignored_role" "$ignored_path" "$ignored_bytes"
		jq -cn --arg disposition "$WORKTREE_RECOVERY_PLAN_DISPOSITION_PROTECTED" \
			'{disposition:$disposition,reasons:["source-removal-not-complete"]}'
		return $?
	}
	HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
		AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN=2 \
		AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=10 \
		AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
		worktree_recovery_maintenance_run
	return $?
}

test_automatic_maintenance_escalates_completed_zero_candidate_cycle() {
	local home_path="${TEST_DIR}/automatic-cycle-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local first_output="" second_output=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	first_output=$(run_zero_candidate_cycle_fixture "$home_path" "$recovery_root" "$state_dir") || rc=1
	second_output=$(run_zero_candidate_cycle_fixture "$home_path" "$recovery_root" "$state_dir") || rc=1
	printf '%s\n' "$first_output" | jq -e '
		.outcome == "no-candidates" and .policy.pressure_active == true and
		.policy.store_bytes == null and .diagnostics.scanned_count == 2 and
		.diagnostics.cursor_before == 0 and .diagnostics.cursor_after == 2 and
		.diagnostics.classification_reason_counts.unknown_archive == 1 and
		.diagnostics.classification_reason_counts.source_removal_not_complete == 1 and
		.diagnostics.zero_candidate_cycle.scanned_count == 2 and
		.diagnostics.zero_candidate_cycle.completed_this_run == false and
		.escalation.required == false
	' >/dev/null || rc=1
	printf '%s\n' "$second_output" | jq -e '
		.outcome == "no-candidates" and .diagnostics.scanned_count == 1 and
		.diagnostics.cursor_before == 2 and .diagnostics.cursor_after == 0 and
		.diagnostics.classification_reason_counts.unknown_archive == 1 and
		.diagnostics.zero_candidate_cycle.scanned_count == 3 and
		.diagnostics.zero_candidate_cycle.completed_this_run == true and
		.diagnostics.zero_candidate_cycle.reason_counts.unknown_archive == 2 and
		.diagnostics.zero_candidate_cycle.reason_counts.source_removal_not_complete == 1 and
		.escalation.required == true and .escalation.authority == "read-only" and
		.escalation.command == ["worktree-helper.sh","recovery","plan","--output","<absolute-new-path>"]
	' >/dev/null || rc=1
	[[ ! -e "$state_dir/pending" ]] || rc=1
	print_result "automatic_maintenance_escalates_completed_zero_candidate_cycle" "$rc" \
		"Expected bounded rotation to preserve mixed reasons and request a read-only manual plan"
	return 0
}

test_automatic_maintenance_rejects_symlink_cycle_state() {
	local home_path="${TEST_DIR}/automatic-cycle-symlink-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local cycle_target="${home_path}/cycle-target"
	local rc=0

	mkdir -p "$recovery_root" "$state_dir" || rc=1
	printf 'preserve\n' >"$cycle_target" || rc=1
	ln -s "$cycle_target" "${state_dir}/zero-candidate-cycle.json" || rc=1
	if (
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run >/dev/null 2>&1
	); then rc=1; fi
	[[ "$(<"$cycle_target")" == "preserve" && -L "${state_dir}/zero-candidate-cycle.json" ]] || rc=1
	print_result "automatic_maintenance_rejects_symlink_cycle_state" "$rc" \
		"Expected completed-cycle diagnostics to fail closed without following a state symlink"
	return 0
}

test_automatic_maintenance_resumes_interrupted_apply() {
	local home_path="${TEST_DIR}/automatic-resume-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local archive_path="" bucket_path="" output=""
	local rc=0

	mkdir -p "$recovery_root" || rc=1
	archive_path=$(create_archived_fixture "${TEST_DIR}/automatic-resume-repo" \
		"${TEST_DIR}/automatic-resume-worktree" "$recovery_root" \
		"bugfix/gh29832-automatic-resume") || rc=1
	bucket_path="${archive_path%/*}"
	install_clear_evidence_stubs
	if (
		uname() {
			printf 'Linux\n'
			return 0
		}
		AIDEVOPS_WORKTREE_RECOVERY_TEST_INTERRUPT_AFTER_MOVE=1 \
			HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run >/dev/null 2>&1
	); then rc=1; fi
	[[ -d "$state_dir/pending" && ! -e "$bucket_path" ]] || rc=1
	output=$(
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES=1 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run
	) || rc=1
	[[ "$(printf '%s\n' "$output" | jq -r '.outcome')" == "resumed-and-removed" ]] || rc=1
	[[ ! -e "$bucket_path" && ! -d "$state_dir/pending" ]] || rc=1
	print_result "automatic_maintenance_resumes_interrupted_apply" "$rc" \
		"Expected the exact pending plan and journal to resume after interruption"
	return 0
}

test_automatic_maintenance_rejects_symlink_cursor() {
	local home_path="${TEST_DIR}/automatic-cursor-home"
	local recovery_root="${home_path}/.aidevops/recovery/worktrees"
	local state_dir="${home_path}/maintenance-state"
	local cursor_target="${home_path}/cursor-target"
	local rc=0

	mkdir -p "$recovery_root" "$state_dir" || rc=1
	printf 'preserve\n' >"$cursor_target" || rc=1
	ln -s "$cursor_target" "${state_dir}/cursor" || rc=1
	if (
		uname() {
			printf 'Linux\n'
			return 0
		}
		HOME="$home_path" AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_STATE_DIR="$state_dir" \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB=0 \
			AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT=0 \
			worktree_recovery_maintenance_run >/dev/null 2>&1
	); then rc=1; fi
	[[ "$(<"$cursor_target")" == "preserve" && -L "${state_dir}/cursor" ]] || rc=1
	print_result "automatic_maintenance_rejects_symlink_cursor" "$rc" \
		"Expected maintenance to fail closed without following a cursor symlink"
	return 0
}

test_large_plan_avoids_json_argv_limits() {
	local output_path="${TEST_DIR}/large-plan.json"
	local second_output_path="${TEST_DIR}/large-plan-second.json"
	local padding=""
	local detail=""
	local output_size=0
	local apply_entries=""
	local apply_metadata=""
	local expected_journal=""
	local journal_path="${TEST_DIR}/large-apply-journal.json"
	local rc=0

	padding=$(printf '%060000d' 0) || rc=1
	worktree_recovery_lifecycle_json() {
		printf '%s\n' '{"error":"synthetic-incomplete","buckets":['
		printf '%s\n' \
			'{"role":"current","state":"unknown","path":"/recovery/bucket-1","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"current","state":"unknown","path":"/recovery/bucket-2","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"current","state":"unknown","path":"/recovery/bucket-3","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"legacy","state":"unknown","path":"/recovery/bucket-4","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"legacy","state":"unknown","path":"/recovery/bucket-5","bytes":null,"sizing_confidence":"unavailable"},' \
			'{"role":"legacy","state":"unknown","path":"/recovery/bucket-6","bytes":null,"sizing_confidence":"unavailable"}'
		printf '%s\n' ']}'
		return 0
	}
	_worktree_recovery_plan_unknown_entry_json() {
		local role="$1"
		local bucket_path="$2"
		local ignored_bytes="$3"
		local reason="$4"
		: "$ignored_bytes"
		jq -cn --arg role "$role" --arg path "$bucket_path" --arg reason "$reason" \
			--arg padding "$padding" \
			'{role:$role,path:$path,archive_path:$path,expected_allocated_bytes:null,
			disposition:"unknown",reasons:[$reason],evidence:{padding:$padding}}'
		return $?
	}
	cmd_recovery plan --output "$output_path" >/dev/null || {
		detail="first oversized plan write failed"
		rc=1
	}
	cmd_recovery plan --output "$second_output_path" >/dev/null || {
		detail="second oversized plan write failed"
		rc=1
	}
	if [[ -f "$output_path" ]]; then
		output_size=$(wc -c <"$output_path") || rc=1
	fi
	if [[ "$output_size" -le 300000 ]]; then
		detail="oversized plan was only ${output_size} bytes"
		rc=1
	fi
	jq -e '.entry_count == 6 and .candidate_count == 0 and .unknown_count == 6' \
		"$output_path" >/dev/null || {
		detail="oversized plan counts were invalid"
		rc=1
	}
	if [[ "$(jq -r '.plan_id' "$output_path")" != "$(jq -r '.plan_id' "$second_output_path")" ]]; then
		detail="oversized plan digest was not deterministic"
		rc=1
	fi
	apply_entries=$(jq -c '[.entries | to_entries[] | {
		index:.key,role:.value.role,original_path:.value.path,
		staged_path:("/recovery/.trash/transaction/" + (.key | tostring)),
		archive_name:("bucket-" + (.key | tostring)),
		expected_allocated_bytes:.value.expected_allocated_bytes,
		identity:.value.identity,evidence:.value.evidence,reasons:.value.reasons,
		maintenance:null,state:"planned"}]' "$output_path") || rc=1
	apply_metadata=$(jq -c '{plan_id,plan_digest:(.plan_id | sub("^sha256:"; "")),
		confirmation:.confirmation_token,automatic_policy:null}' "$output_path") || rc=1
	expected_journal=$(_worktree_recovery_apply_expected_journal \
		"large-transaction" "$apply_metadata" "$apply_entries" "2026-08-10T00:00:00Z") || rc=1
	printf '%s\n' "$expected_journal" >"$journal_path" || rc=1
	_worktree_recovery_apply_validate_existing_journal \
		"$journal_path" "$expected_journal" || {
		detail="oversized apply journal validation failed"
		rc=1
	}
	print_result "large_plan_avoids_json_argv_limits" "$rc" \
		"${detail:-Expected a deterministic oversized plan without jq argv transport}"
	return 0
}

# shellcheck source=../audit-worktree-removal-helper.sh
source "${SCRIPTS_DIR}/audit-worktree-removal-helper.sh"
# shellcheck source=../worktree-recovery-lifecycle-helper.sh
source "${SCRIPTS_DIR}/worktree-recovery-lifecycle-helper.sh"
# shellcheck source=../worktree-recovery-maintenance-helper.sh
source "${SCRIPTS_DIR}/worktree-recovery-maintenance-helper.sh"
# shellcheck source=../worktree-helper-cmds.sh
source "${SCRIPTS_DIR}/worktree-helper-cmds.sh"

setup
printf '=== test-worktree-recovery-lifecycle.sh ===\n'
test_git_state_detects_recovery_data
test_cache_policy_recognises_python_and_root_codegraph_only
test_git_state_protects_tracked_regenerable_cache_roots
test_archive_prunes_only_regenerable_ignored_caches
test_archive_pruning_preserves_tracked_codegraph_root
test_claim_state_uses_archive_repository
test_exact_plan_writes_candidate_without_mutation
test_plan_output_refuses_unsafe_targets
test_classification_fails_closed
test_plan_records_malformed_bucket_unknown
test_size_drift_downgrades_only_entry
test_attributed_remeasurement_uses_explicit_budget
test_global_inventory_failure_is_explicit
test_entry_sizing_failure_is_localized
test_manual_plan_classification_is_bounded_and_resumable
test_manual_plan_deadline_emits_continuation
test_apply_removes_only_candidates_and_replays_receipt
test_apply_rejects_unsafe_manifest_and_cli_inputs
test_apply_preflight_drift_stages_nothing
test_apply_resumes_move_and_delete_crash_windows
test_apply_resumes_transaction_initialization_crashes
test_receipt_reservation_blocks_conflicting_plan
test_receipt_publication_owns_only_reserved_temp
test_shared_producer_lock_fails_closed_and_reclaims_stale
test_apply_handles_attributable_legacy_root_transaction
test_automatic_maintenance_is_bounded_and_policy_bound
test_automatic_maintenance_checks_capacity_before_aggregate_size
test_automatic_maintenance_enters_pressure_when_aggregate_size_times_out
test_automatic_maintenance_deadline_advances_cursor
test_automatic_maintenance_bounds_classification_subprocesses
test_automatic_maintenance_preserves_bucket_when_exact_size_is_unavailable
test_automatic_maintenance_escalates_completed_zero_candidate_cycle
test_automatic_maintenance_resumes_interrupted_apply
test_automatic_maintenance_rejects_symlink_cursor
test_automatic_maintenance_rejects_symlink_cycle_state
test_large_plan_avoids_json_argv_limits
printf '\nResults: %s run, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
