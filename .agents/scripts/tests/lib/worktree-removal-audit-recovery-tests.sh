#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worktree Removal Audit Tests — Recoverable Archive Coverage
# =============================================================================
# Sourced by ../test-worktree-removal-audit.sh.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_WORKTREE_REMOVAL_AUDIT_RECOVERY_TESTS_LOADED:-}" ]] && return 0
_WORKTREE_REMOVAL_AUDIT_RECOVERY_TESTS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Recoverable cleanup creates a complete archive while the registered source is
# still intact, then lets native Git remove the source and exact metadata.
# =============================================================================
test_recovery_store_selects_platform_semantics() {
	local fixture_home="${TEST_DIR}/platform-home"
	local override_root="${TEST_DIR}/operator-archive-root"
	local actual=""
	local rc=0

	mkdir -p "$fixture_home" || rc=1
	actual=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" _worktree_recovery_store_root "Linux") || rc=1
	[[ "$actual" == "$fixture_home/.aidevops/recovery/worktrees" ]] || rc=1
	actual=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" _worktree_recovery_store_root "Darwin") || rc=1
	[[ "$actual" == "$fixture_home/.Trash" ]] || rc=1
	actual=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$override_root" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" _worktree_recovery_store_root "Linux") || rc=1
	[[ "$actual" == "$override_root" ]] || rc=1
	print_result "recovery_store_selects_platform_semantics" "$rc" \
		"Expected Linux recovery ownership, macOS Trash, and explicit override precedence"
	return 0
}

test_recovery_inventory_reports_legacy_buckets_fail_closed() {
	local fixture_home="${TEST_DIR}/inventory-home"
	local current_root="${fixture_home}/.aidevops/recovery/worktrees"
	local override_link="${fixture_home}/operator-recovery"
	local legacy_alias="${fixture_home}/legacy-recovery-alias"
	local legacy_root="${fixture_home}/.Trash"
	local spoofed_bucket="${current_root}/aidevops-worktree-cleanup-spoofed"
	local unknown_bucket="${legacy_root}/aidevops-worktree-cleanup-interrupted"
	local current_repo="${TEST_DIR}/current-inventory-repo"
	local current_worktree="${TEST_DIR}/current-inventory-worktree"
	local current_archive=""
	local current_bucket=""
	local interrupted_repo="${TEST_DIR}/interrupted-inventory-repo"
	local interrupted_worktree="${TEST_DIR}/interrupted-inventory-worktree"
	local interrupted_archive=""
	local interrupted_bucket=""
	local compat_repo="${TEST_DIR}/compat-v1-inventory-repo"
	local compat_worktree="${TEST_DIR}/compat-v1-inventory-worktree"
	local compat_archive=""
	local compat_bucket=""
	local legacy_repo="${TEST_DIR}/legacy-v1-inventory-repo"
	local legacy_worktree="${TEST_DIR}/legacy-v1-inventory-worktree"
	local legacy_archive=""
	local legacy_bucket=""
	local recovery_dir=""
	local output=""
	local alias_output=""
	local rc=0

	mkdir -p "$spoofed_bucket/${_WT_RECOVERY_DIR_NAME}" \
		"$unknown_bucket/${_WT_RECOVERY_DIR_NAME}" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT" >"$spoofed_bucket/${_WT_RECOVERY_DIR_NAME}/format" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT" > \
		"$spoofed_bucket/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT" > \
		"$unknown_bucket/${_WT_RECOVERY_DIR_NAME}/format" || rc=1
	spoofed_bucket=$(cd "$spoofed_bucket" 2>/dev/null && pwd -P) || rc=1
	unknown_bucket=$(cd "$unknown_bucket" 2>/dev/null && pwd -P) || rc=1
	ln -s "$current_root" "$override_link" || rc=1
	ln -s "$legacy_root" "$legacy_alias" || rc=1
	create_git_worktree_fixture "$current_repo" "$current_worktree" "feature/current-inventory" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$current_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$current_worktree" "test.sh" "current-inventory" || rc=1
	current_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	current_bucket="${current_archive%/*}"
	create_git_worktree_fixture "$interrupted_repo" "$interrupted_worktree" \
		"feature/interrupted-inventory" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$legacy_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$interrupted_worktree" "test.sh" \
		"interrupted-inventory" || rc=1
	interrupted_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	interrupted_bucket="${interrupted_archive%/*}"
	rm -f "$interrupted_bucket/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}" || rc=1
	create_git_worktree_fixture "$compat_repo" "$compat_worktree" "feature/compat-v1-inventory" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$legacy_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$compat_worktree" "test.sh" "compat-v1-inventory" || rc=1
	compat_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	compat_bucket="${compat_archive%/*}"
	recovery_dir="$compat_bucket/${_WT_RECOVERY_DIR_NAME}"
	printf '%s\n' "$_WT_RECOVERY_FORMAT_V1" >"$recovery_dir/format" || rc=1
	printf '%s\n' "$_WT_RECOVERY_FORMAT_V1" >"$recovery_dir/${_WT_RECOVERY_COMPLETE_MARKER}" || rc=1
	rm -f "$recovery_dir/created-at" "$recovery_dir/producer" \
		"$recovery_dir/producer-context" "$recovery_dir/session-id" \
		"$recovery_dir/archive-outcome" "$recovery_dir/source-removal-outcome" || rc=1
	create_git_worktree_fixture "$legacy_repo" "$legacy_worktree" "feature/legacy-inventory" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$legacy_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$legacy_worktree" "test.sh" "legacy-inventory" || rc=1
	legacy_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	legacy_bucket="${legacy_archive%/*}"
	recovery_dir="$legacy_bucket/${_WT_RECOVERY_DIR_NAME}"
	printf '%s\n' "$_WT_RECOVERY_FORMAT_V1" >"$recovery_dir/format" || rc=1
	rm -f "$recovery_dir/${_WT_RECOVERY_COMPLETE_MARKER}" \
		"$recovery_dir/storage-owner" "$recovery_dir/storage-class" \
		"$recovery_dir/storage-policy" "$recovery_dir/storage-root" \
		"$recovery_dir/created-at" "$recovery_dir/producer" \
		"$recovery_dir/producer-context" "$recovery_dir/session-id" \
		"$recovery_dir/archive-outcome" "$recovery_dir/source-removal-outcome" || rc=1
	output=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$override_link" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" worktree_recovery_inventory "Linux") || rc=1
	printf '%s\n' "$output" | grep -Fq $'store\tcurrent\tjoint\trecovery\tmanual-review\tpresent\t' || rc=1
	printf '%s\n' "$output" | grep -Fq $'store\tlegacy\tjoint\trecovery\tmanual-review\tpresent\t' || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tcurrent\tframework\tattributed\t'"$current_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tcurrent\tframework\tunknown\t'"$spoofed_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tlegacy\tframework\tunknown\t'"$unknown_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tlegacy\tframework\tunknown\t'"$interrupted_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tlegacy\tframework\tattributed\t'"$compat_bucket" || rc=1
	printf '%s\n' "$output" | grep -Fq $'bucket\tlegacy\tframework\tattributed-legacy\t'"$legacy_bucket" || rc=1
	alias_output=$(HOME="$fixture_home" AIDEVOPS_WORKTREE_TRASH_ROOT="$legacy_alias" \
		AIDEVOPS_ORPHAN_TRASH_ROOT="" worktree_recovery_inventory "Linux") || rc=1
	[[ "$(printf '%s\n' "$alias_output" | grep -c '^store')" -eq 1 ]] || rc=1
	print_result "recovery_inventory_reports_legacy_buckets_fail_closed" "$rc" \
		"Expected attributed current and unknown legacy buckets to remain visible and protected"
	return 0
}

test_recoverable_archive_then_native_remove() {
	local repo_path="${TEST_DIR}/archive-repo"
	local wt_path="${TEST_DIR}/archive-worktree"
	local trash_root="${TEST_DIR}/archive-trash"
	local archive_path=""
	local wt_root=""
	local metadata=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	AIDEVOPS_SESSION_ID="ses_test_recovery" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "archive-test" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	[[ -d "$wt_path" && -d "$archive_path" && -e "$archive_path/.git" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/format")" == "$_WT_RECOVERY_FORMAT_V2" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/storage-owner")" == "framework" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/storage-class")" == "recovery" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/storage-policy")" == "manual-review" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/producer")" == "test.sh" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/producer-context")" == "archive-test" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/session-id")" == "ses_test_recovery" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/archive-outcome")" == "complete" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/source-removal-outcome")" == "pending" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}")" == "$_WT_RECOVERY_FORMAT" ]] || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$wt_path" "$archive_path" "test.sh" "recoverable-test" \
		"recovery_path=archive-first" "false" "false" || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" prune_missing_worktree_metadata "$repo_path" "$wt_path" || rc=1
	if "$GIT_BIN" -C "$repo_path" worktree list --porcelain | grep -Fqx "worktree $wt_root"; then
		rc=1
	fi
	[[ ! -e "$wt_path" && -d "$archive_path" && -e "$archive_path/.git" ]] || rc=1
	[[ "$(<"${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/source-removal-outcome")" == "removed" ]] || rc=1
	print_result "recoverable_archive_then_native_remove" "$rc" \
		"Expected archive retention after native source and metadata removal"
	return 0
}

# =============================================================================
# A foreign lock acquired after archive completion but before native Git removal
# must preserve the registered source while the completed archive also remains.
# =============================================================================
test_recoverable_archive_preserves_late_lock() {
	local repo_path="${TEST_DIR}/archive-race-repo"
	local wt_path="${TEST_DIR}/archive-race-worktree"
	local trash_root="${TEST_DIR}/archive-race-trash"
	local wrapper_path="${TEST_DIR}/archive-race-git"
	local marker_path="${TEST_DIR}/archive-race-lock-injected"
	local archive_path=""
	local metadata=""
	local wt_root=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-race" || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "archive-race" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	cat >"$wrapper_path" <<'RACE_GIT'
#!/usr/bin/env bash
if [[ "$*" == *"worktree remove"* && ! -e "${RACE_MARKER:?}" ]]; then
	: >"$RACE_MARKER"
	"${REAL_GIT:?}" -C "${RACE_REPO:?}" worktree lock \
		--reason "foreign-after-archive" "${RACE_WORKTREE:?}" || exit 1
fi
exec "${REAL_GIT:?}" "$@"
RACE_GIT
	chmod +x "$wrapper_path" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	if REAL_GIT="$GIT_BIN" RACE_MARKER="$marker_path" RACE_REPO="$repo_path" \
		RACE_WORKTREE="$wt_path" AIDEVOPS_REAL_GIT_BIN="$wrapper_path" \
		remove_archived_worktree_path "$wt_path" "$archive_path" "test.sh" \
		"recoverable-test" "recovery_path=archive-first" "false" "false"; then
		rc=1
	fi
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	[[ -d "$wt_path" && -d "$archive_path" && -e "$archive_path/.git" && -e "$marker_path" ]] || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	printf '%s\n' "$metadata" | grep -Fxq "locked foreign-after-archive" || rc=1
	print_result "recoverable_archive_preserves_late_lock" "$rc" \
		"Expected a late lock to preserve source, metadata, and completed archive"
	return 0
}

# =============================================================================
# Forced recovery keeps a usable detached admin snapshot with the exact staged,
# unstaged, and untracked state that existed before native source removal.
# =============================================================================
test_recovery_archive_preserves_index_and_dirty_files() {
	local repo_path="${TEST_DIR}/archive-dirty-repo"
	local wt_path="${TEST_DIR}/archive-dirty-worktree"
	local trash_root="${TEST_DIR}/archive-dirty-trash"
	local archive_path=""
	local recovery_dir=""
	local expected_status=""
	local actual_status=""
	local expected_head=""
	local actual_head=""
	local recorded_branch=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-dirty" || rc=1
	printf 'staged state\n' >>"$wt_path/README.md" || rc=1
	"$GIT_BIN" -C "$wt_path" add README.md || rc=1
	printf 'unstaged state\n' >>"$wt_path/README.md" || rc=1
	printf 'untracked state\n' >"$wt_path/untracked.txt" || rc=1
	expected_status=$("$GIT_BIN" -C "$wt_path" status --porcelain=v1 --untracked-files=all) || rc=1
	expected_head=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "dirty-archive" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	recovery_dir=$(_worktree_recovery_dir_for_archive "$archive_path") || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$wt_path" "$archive_path" "test.sh" "dirty-archive" \
		"recovery_path=archive-first" "false" "true" || rc=1
	actual_status=$("$GIT_BIN" -C "$archive_path" status --porcelain=v1 --untracked-files=all) || rc=1
	actual_head=$("$GIT_BIN" -C "$archive_path" rev-parse --verify HEAD) || rc=1
	IFS= read -r recorded_branch <"${recovery_dir}/branch" || rc=1
	[[ ! -e "$wt_path" && "$actual_status" == "$expected_status" ]] || rc=1
	[[ "$actual_head" == "$expected_head" ]] || rc=1
	[[ "$recorded_branch" == "refs/heads/feature/archive-dirty" ]] || rc=1
	if "$GIT_BIN" -C "$archive_path" symbolic-ref -q HEAD >/dev/null 2>&1; then
		rc=1
	fi
	print_result "recovery_archive_preserves_index_and_dirty_files" "$rc" \
		"Expected a usable detached archive with exact index and file state"
	return 0
}

test_recovery_archive_preserves_detached_head_identity() {
	local repo_path="${TEST_DIR}/archive-detached-repo"
	local wt_path="${TEST_DIR}/archive-detached-worktree"
	local trash_root="${TEST_DIR}/archive-detached-trash"
	local archive_path=""
	local recovery_dir=""
	local expected_head=""
	local actual_head=""
	local recorded_branch=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-detached" || rc=1
	"$GIT_BIN" -C "$wt_path" checkout -q --detach || rc=1
	expected_head=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "detached-archive" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	recovery_dir=$(_worktree_recovery_dir_for_archive "$archive_path") || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$wt_path" "$archive_path" "test.sh" "detached-archive" \
		"recovery_path=archive-first" "false" "false" || rc=1
	actual_head=$("$GIT_BIN" -C "$archive_path" rev-parse --verify HEAD) || rc=1
	IFS= read -r recorded_branch <"${recovery_dir}/branch" || rc=1
	[[ "$actual_head" == "$expected_head" && "$recorded_branch" == "detached" ]] || rc=1
	if "$GIT_BIN" -C "$archive_path" symbolic-ref -q HEAD >/dev/null 2>&1; then
		rc=1
	fi
	print_result "recovery_archive_preserves_detached_head_identity" "$rc" \
		"Expected detached identity and HEAD to survive native removal"
	return 0
}

# =============================================================================
# The archive and final removal must refer to the same source/admin identity.
# Replacing the registered worktree at the same pathname must fail closed.
# =============================================================================
test_recoverable_archive_refuses_replacement_worktree() {
	local log_file="${TEST_DIR}/archive-replacement.log"
	local repo_path="${TEST_DIR}/archive-replacement-repo"
	local wt_path="${TEST_DIR}/archive-replacement-worktree"
	local trash_root="${TEST_DIR}/archive-replacement-trash"
	local archive_path=""
	local metadata=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-original" || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "replacement-test" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	"$GIT_BIN" -C "$repo_path" worktree remove "$wt_path" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b "feature/archive-replacement" "$wt_path" main || rc=1
	if AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" remove_archived_worktree_path \
		"$wt_path" "$archive_path" "test.sh" "replacement-test" \
		"recovery_path=archive-first" "false" "false"; then
		rc=1
	fi
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	[[ -d "$wt_path" && -d "$archive_path" ]] || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "branch refs/heads/feature/archive-replacement" || rc=1
	assert_file_contains "$log_file" "git-worktree-identity-changed.*mode=skipped" || rc=1
	print_result "recoverable_archive_refuses_replacement_worktree" "$rc" \
		"Expected replacement identity to preserve both replacement and archive"
	return 0
}

test_recoverable_archive_refuses_late_unarchived_write_without_force() {
	local log_file="${TEST_DIR}/archive-late-write.log"
	local repo_path="${TEST_DIR}/archive-late-write-repo"
	local wt_path="${TEST_DIR}/archive-late-write-worktree"
	local trash_root="${TEST_DIR}/archive-late-write-trash"
	local wrapper_path="${TEST_DIR}/archive-late-write-git"
	local marker_path="${TEST_DIR}/archive-late-write-injected"
	local archive_path=""
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/archive-late-write" || rc=1
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" archive_worktree_path_recoverably \
		"$wt_path" "test.sh" "late-write-test" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	cat >"$wrapper_path" <<'LATE_WRITE_GIT'
#!/usr/bin/env bash
if [[ "$*" == *"worktree remove"* && ! -e "${LATE_WRITE_MARKER:?}" ]]; then
	printf 'late state\n' >"${LATE_WRITE_WORKTREE:?}/late-write.txt" || exit 1
	: >"$LATE_WRITE_MARKER"
fi
exec "${REAL_GIT:?}" "$@"
LATE_WRITE_GIT
	chmod +x "$wrapper_path" || rc=1
	if REAL_GIT="$GIT_BIN" LATE_WRITE_MARKER="$marker_path" \
		LATE_WRITE_WORKTREE="$wt_path" AIDEVOPS_REAL_GIT_BIN="$wrapper_path" \
		remove_archived_worktree_path "$wt_path" "$archive_path" "test.sh" \
		"late-write-test" "recovery_path=archive-first" "false" "false"; then
		rc=1
	fi
	[[ -f "$wt_path/late-write.txt" && ! -e "$archive_path/late-write.txt" ]] || rc=1
	assert_file_contains "$log_file" "git-worktree-remove-failed.*mode=skipped" || rc=1
	print_result "recoverable_archive_refuses_late_unarchived_write_without_force" "$rc" \
		"Expected an unforced native removal to preserve a late write"
	return 0
}

test_removal_helpers_refuse_direct_symlink_alias() {
	local log_file="${TEST_DIR}/symlink-alias.log"
	local repo_path="${TEST_DIR}/symlink-alias-repo"
	local wt_path="${TEST_DIR}/symlink-alias-worktree"
	local alias_path="${TEST_DIR}/symlink-alias"
	local trash_root="${TEST_DIR}/symlink-alias-trash"
	local rc=0
	local AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/symlink-alias" || rc=1
	ln -s "$wt_path" "$alias_path" || rc=1
	if remove_worktree_path_permanently "$alias_path" "test.sh" "alias-test"; then
		rc=1
	fi
	if archive_worktree_path_recoverably "$alias_path" "test.sh" "alias-test"; then
		rc=1
	fi
	[[ -L "$alias_path" && -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "git-worktree-identity-changed.*mode=skipped" || rc=1
	print_result "removal_helpers_refuse_direct_symlink_alias" "$rc" \
		"Expected direct symlink aliases to fail before source removal"
	return 0
}
