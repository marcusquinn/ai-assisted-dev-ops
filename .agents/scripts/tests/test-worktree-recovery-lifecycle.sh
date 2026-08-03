#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for exact, read-only worktree recovery cleanup plans.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
TEST_DIR=""
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

create_archived_fixture() {
	local repo_path="$1"
	local worktree_path="$2"
	local recovery_root="$3"
	local branch_name="$4"

	"$GIT_BIN" init -q -b main "$repo_path" || return 1
	"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || return 1
	"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || return 1
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || return 1
	printf 'base\n' >"${repo_path}/README.md" || return 1
	"$GIT_BIN" -C "$repo_path" add README.md || return 1
	"$GIT_BIN" -C "$repo_path" commit -q -m init || return 1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b "$branch_name" "$worktree_path" || return 1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$worktree_path" "test.sh" "recovery-plan" || return 1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$worktree_path" "$WORKTREE_RECOVERABLE_ARCHIVE_PATH" "test.sh" "recovery-plan" \
		"recovery_path=archive-first" "false" "false" || return 1
	printf '%s\n' "$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
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
		.schema == "aidevops.worktree-recovery-plan/v1" and .producer == "worktree-helper" and
		.read_only == true and .inventory_complete == true and .inventory_error == null and
		(.source_roots | length == 1) and .entry_count == 1 and
		.sized_entry_count == 1 and .unavailable_size_count == 0 and
		.candidate_count == 1 and .protected_count == 0 and .unknown_count == 0 and
		(.candidate_bytes > 0) and .candidate_bytes == .expected_allocated_bytes and
		(.plan_id | startswith("sha256:")) and
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
	print_result "git_state_detects_recovery_data" "$rc" \
		"Expected tracked, untracked, and ignored recovery data to veto candidates"
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

# shellcheck source=../audit-worktree-removal-helper.sh
source "${SCRIPTS_DIR}/audit-worktree-removal-helper.sh"
# shellcheck source=../worktree-recovery-lifecycle-helper.sh
source "${SCRIPTS_DIR}/worktree-recovery-lifecycle-helper.sh"
# shellcheck source=../worktree-helper-cmds.sh
source "${SCRIPTS_DIR}/worktree-helper-cmds.sh"

setup
printf '=== test-worktree-recovery-lifecycle.sh ===\n'
test_git_state_detects_recovery_data
test_exact_plan_writes_candidate_without_mutation
test_plan_output_refuses_unsafe_targets
test_classification_fails_closed
test_plan_records_malformed_bucket_unknown
test_size_drift_downgrades_only_entry
test_global_inventory_failure_is_explicit
printf '\nResults: %s run, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
