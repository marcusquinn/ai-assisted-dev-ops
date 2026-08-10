#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-removal-audit-lib.sh — Regression tests for t2976: canonical audit
# logging at every worktree-removal event.
#
# Tests cover:
#   1. log_worktree_removal_event writes exactly one structured line per call
#   2. Log format: [ISO8601] [caller] worktree-{removed|skipped}: <path> — <reason> — mode=<mode>
#   3. Custom AIDEVOPS_CLEANUP_LOG env var is honoured
#   4. All three event types produce correct type strings in the log
#   5. should_skip_cleanup emits worktree-skipped when ownership blocks removal
#   6. Double-sourcing the audit helper is idempotent
#   7. Optional guard context is appended when supplied
#
# All tests run in isolated temp directories; no real ~/.aidevops state is
# written. Tests do not require git or gh — they exercise the logging functions
# directly via sourcing with stub dependencies.
#
# Scope note (t2976): The issue spec listed two additional EDIT targets —
#   cleanup_worktrees.sh and orphan-defaultbranch-guard.sh — but neither file
#   exists in this repository. All instrumented callers that DO exist are covered:
#   worktree-helper.sh, pulse-cleanup.sh, and skill-update-core-lib.sh
#   (sourced via skill-update-helper.sh). No test coverage is omitted for live code.
#
# Usage:
#   Source from test-worktree-removal-audit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_HELPER="${SCRIPT_DIR}/../audit-worktree-removal-helper.sh"
COMMANDS_HELPER="${SCRIPT_DIR}/../worktree-helper-cmds.sh"
CLEAN_HELPER="${SCRIPT_DIR}/../worktree-clean-lib.sh"
REGISTRY_HELPER="${SCRIPT_DIR}/../shared-worktree-registry.sh"
SKILL_PR_HELPER="${SCRIPT_DIR}/../skill-update-pr-lib.sh"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

# =============================================================================
# Test framework
# =============================================================================

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	export AIDEVOPS_WORKTREE_TRASH_ROOT="${TEST_DIR}/recovery"
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

assert_file_contains() {
	local file="$1"
	local pattern="$2"
	grep -qE "$pattern" "$file" 2>/dev/null
	return $?
}

assert_line_count() {
	local file="$1"
	local expected="$2"
	local actual
	actual=$(wc -l <"$file" 2>/dev/null | tr -d ' ')
	if [[ "$actual" -eq "$expected" ]]; then
		return 0
	fi
	echo "  expected $expected lines, got $actual"
	return 1
}

create_git_worktree_fixture() {
	local repo_path="$1"
	local wt_path="$2"
	local branch_name="$3"

	"$GIT_BIN" init -q -b main "$repo_path" || return 1
	"$GIT_BIN" -C "$repo_path" config user.email test@example.invalid || return 1
	"$GIT_BIN" -C "$repo_path" config user.name 'Aidevops Test' || return 1
	"$GIT_BIN" -C "$repo_path" config commit.gpgsign false || return 1
	printf 'base\n' >"${repo_path}/README.md" || return 1
	"$GIT_BIN" -C "$repo_path" add README.md || return 1
	"$GIT_BIN" -C "$repo_path" commit -q -m init || return 1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b "$branch_name" "$wt_path" main || return 1
	return 0
}

# Removal cases exercise their native Git/archive invariants. Give them a
# deterministic complete snapshot so unrelated host processes cannot turn the
# fixture into a degraded-visibility cleanup path.
with_complete_cwd_snapshot() (
	capture_worktree_process_cwds() { printf '/\n'; return 0; }
	"$@"
)

# shellcheck source=./test-worktree-removal-audit-events.sh
# shellcheck disable=SC1091  # test module resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-worktree-removal-audit-events.sh"

# =============================================================================
# Test 7: shared guard refuses current working directory removals
# =============================================================================
test_guard_refuses_current_cwd() {
	local log_file="${TEST_DIR}/t7-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/current-wt"
	mkdir -p "$wt_path"

	local rc=0
	(
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		cd "$wt_path" || exit 2
		if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
			exit 1
		fi
	) || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		assert_file_contains "$log_file" "worktree-skipped.*current-worktree.*mode=skipped" || rc=$?
	fi
	print_result "guard_refuses_current_cwd" "$rc" \
		"Expected current-worktree skip. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 8: shared guard refuses another live process with cwd in worktree
# =============================================================================
test_guard_refuses_other_process_cwd() {
	local log_file="${TEST_DIR}/t8-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/active-process-wt"
	mkdir -p "$wt_path"

	local sleeper_pid=""
	(
		cd "$wt_path" || exit 2
		sleep 30
	) &
	sleeper_pid=$!

	local rc=0
	local attempts=0
	while [[ "$attempts" -lt 20 ]]; do
		(
			unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
			# shellcheck source=../audit-worktree-removal-helper.sh
			source "$AUDIT_HELPER"
			if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
				exit 1
			fi
		) && break
		rc=$?
		attempts=$((attempts + 1))
		sleep 0.1
	done

	kill "$sleeper_pid" 2>/dev/null || true
	wait "$sleeper_pid" 2>/dev/null || true

	if [[ "$rc" -eq 0 ]]; then
		assert_file_contains "$log_file" "worktree-skipped.*active-cwd.*mode=skipped" || rc=$?
	fi
	print_result "guard_refuses_other_process_cwd" "$rc" \
		"Expected active-cwd skip. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 9: permanent helper removes only after guard passes and logs mode
# =============================================================================
test_permanent_helper_removes_and_logs() {
	local log_file="${TEST_DIR}/t9-cleanup.log"
	local repo_path="${TEST_DIR}/old-repo"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/old-wt"
	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/old" || return 1

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local rc=0
	(
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		with_complete_cwd_snapshot remove_worktree_path_permanently \
			"$wt_path" "test.sh" "age-eligible"
	) || rc=$?
	[[ ! -e "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-removed.*age-eligible.*mode=permanent" || rc=1
	print_result "permanent_helper_removes_and_logs" "$rc" \
		"Expected permanent removal audit. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# An inaccessible candidate must not be inferred to be a non-Git directory.
# =============================================================================
test_guard_fails_closed_on_inaccessible_candidate() {
	local log_file="${TEST_DIR}/inaccessible-cleanup.log"
	local repo_path="${TEST_DIR}/inaccessible-repo"
	local wt_path="${TEST_DIR}/inaccessible-worktree"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/inaccessible" || rc=1
	chmod 000 "$wt_path" || rc=1
	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		worktree_removal_guard "$wt_path" "test.sh" "manual" ""
	); then
		rc=1
	fi
	chmod 700 "$wt_path" || rc=1
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-metadata-unreadable.*mode=skipped" || rc=1
	print_result "guard_fails_closed_on_inaccessible_candidate" "$rc" \
		"Expected inaccessible candidate to remain and report unreadable metadata"
	return 0
}

# =============================================================================
# NUL-delimited porcelain parsing preserves unusual paths and exact block
# ownership: a lock in the adjacent block must not taint an unlocked candidate.
# =============================================================================
test_git_lock_parser_handles_unusual_paths_and_adjacent_blocks() {
	local repo_path="${TEST_DIR}/parser-repo"
	local wt_path="${TEST_DIR}/parser-worktree"$'\n'"with-newline"
	local adjacent_path="${TEST_DIR}/parser-adjacent"
	local wt_path_real=""
	local git_state=""
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/parser" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree add -q -b "feature/parser-adjacent" "$adjacent_path" main || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "adjacent-preservation" "$adjacent_path" || rc=1
	wt_path_real=$(cd "$wt_path" && pwd -P) || rc=1
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") || rc=1
	[[ "$git_state" == "$_WT_GIT_STATE_CLEAR" ]] || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "candidate-preservation" "$wt_path" || rc=1
	git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path_real") || rc=1
	[[ "$git_state" == "$_WT_GIT_STATE_LOCKED" ]] || rc=1
	print_result "git_lock_parser_handles_unusual_paths_and_adjacent_blocks" "$rc" \
		"Expected exact NUL-safe lock ownership for unusual worktree paths"
	return 0
}

# =============================================================================
# A status-zero list is not authoritative unless every block is structurally
# complete. Missing, duplicate, contradictory, or nested fields fail closed.
# =============================================================================
test_git_lock_parser_rejects_malformed_blocks() {
	local wt_path="${TEST_DIR}/malformed-parser-worktree"
	local other_path="${TEST_DIR}/malformed-parser-other"
	local valid_head="0123456789abcdef0123456789abcdef01234567"
	local other_head="89abcdef0123456789abcdef0123456789abcdef"
	local malformed_mode=""
	local git_state=""
	local rc=0
	mkdir -p "$wt_path"

	git() {
		local all_args="$*"
		case "$all_args" in
		*"rev-parse --show-toplevel"*) printf '%s\n' "$wt_path" ;;
		*"worktree list --porcelain -z"*)
			case "$malformed_mode" in
			unterminated) printf 'worktree %s\0HEAD %s\0branch refs/heads/test\0' "$wt_path" "$valid_head" ;;
			duplicate-start) printf 'worktree %s\0HEAD %s\0worktree %s\0HEAD %s\0branch refs/heads/other\0\0' "$wt_path" "$valid_head" "$other_path" "$other_head" ;;
			missing-head) printf 'worktree %s\0branch refs/heads/test\0\0' "$wt_path" ;;
			missing-identity) printf 'worktree %s\0HEAD %s\0\0' "$wt_path" "$valid_head" ;;
			contradictory) printf 'worktree %s\0HEAD %s\0branch refs/heads/test\0detached\0\0' "$wt_path" "$valid_head" ;;
			duplicate-head) printf 'worktree %s\0HEAD %s\0HEAD %s\0branch refs/heads/test\0\0' "$wt_path" "$valid_head" "$other_head" ;;
			empty-head) printf 'worktree %s\0HEAD \0branch refs/heads/test\0\0' "$wt_path" ;;
			empty-branch) printf 'worktree %s\0HEAD %s\0branch \0\0' "$wt_path" "$valid_head" ;;
			whitespace-head) printf 'worktree %s\0HEAD \t\0branch refs/heads/test\0\0' "$wt_path" ;;
			invalid-head) printf 'worktree %s\0HEAD deadbeef\0branch refs/heads/test\0\0' "$wt_path" ;;
			whitespace-branch) printf 'worktree %s\0HEAD %s\0branch \t\0\0' "$wt_path" "$valid_head" ;;
			invalid-branch) printf 'worktree %s\0HEAD %s\0branch refs/heads/bad..name\0\0' "$wt_path" "$valid_head" ;;
			invalid-namespace) printf 'worktree %s\0HEAD %s\0branch refs/tags/test\0\0' "$wt_path" "$valid_head" ;;
			esac
			;;
		*) return 1 ;;
		esac
		return 0
	}
	for malformed_mode in unterminated duplicate-start missing-head missing-identity contradictory duplicate-head \
		empty-head empty-branch whitespace-head invalid-head whitespace-branch invalid-branch invalid-namespace; do
		git_state=$(_worktree_git_lock_state "$wt_path" "$wt_path") || rc=1
		[[ "$git_state" == "$_WT_GIT_STATE_UNREADABLE" ]] || rc=1
	done
	unset -f git
	print_result "git_lock_parser_rejects_malformed_blocks" "$rc" \
		"Expected malformed structure, object IDs, and branch refs to remain unreadable"
	return 0
}

# =============================================================================
# Missing paths are normalized through their physical parent so aliases such as
# macOS /var and /private/var compare to the same Git metadata path.
# =============================================================================
test_missing_worktree_physical_parent_alias() {
	local physical_parent="${TEST_DIR}/physical-parent"
	local alias_parent="${TEST_DIR}/alias-parent"
	local expected_parent=""
	local resolved_path=""
	local rc=0
	mkdir -p "$physical_parent"
	ln -s "$physical_parent" "$alias_parent" || rc=1
	expected_parent=$(cd "$physical_parent" && pwd -P) || rc=1
	resolved_path=$(_worktree_physical_path "${alias_parent}/missing-worktree") || rc=1
	[[ "$resolved_path" == "${expected_parent}/missing-worktree" ]] || rc=1
	print_result "missing_worktree_physical_parent_alias" "$rc" \
		"Expected a missing aliased path to resolve through its physical parent"
	return 0
}

# =============================================================================
# Git remains the final permanent-removal authority. A foreign lock acquired
# after the initial guard but before `git worktree remove` must preserve the
# physical path and metadata.
# =============================================================================
test_permanent_helper_preserves_lock_acquired_after_guard() {
	local log_file="${TEST_DIR}/race-cleanup.log"
	local repo_path="${TEST_DIR}/race-repo"
	local wt_path="${TEST_DIR}/race-worktree"
	local wrapper_path="${TEST_DIR}/race-git"
	local marker_path="${TEST_DIR}/race-lock-injected"
	local metadata=""
	local wt_root=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/race" || rc=1
	cat >"$wrapper_path" <<'RACE_GIT'
#!/usr/bin/env bash
if [[ "$*" == *"worktree remove"* && ! -e "${RACE_MARKER:?}" ]]; then
	: >"$RACE_MARKER"
	"${REAL_GIT:?}" -C "${RACE_REPO:?}" worktree lock --reason "foreign-race-lock" "${RACE_WORKTREE:?}" || exit 1
fi
exec "${REAL_GIT:?}" "$@"
RACE_GIT
	chmod +x "$wrapper_path" || rc=1
	if (
		export AIDEVOPS_REAL_GIT_BIN="$wrapper_path"
		export REAL_GIT="$GIT_BIN"
		export RACE_MARKER="$marker_path"
		export RACE_REPO="$repo_path"
		export RACE_WORKTREE="$wt_path"
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		with_complete_cwd_snapshot remove_worktree_path_permanently \
			"$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" && -e "$marker_path" ]] || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	printf '%s\n' "$metadata" | grep -Eq '^locked([[:space:]]|$)' || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-worktree-locked.*mode=skipped" || rc=1
	print_result "permanent_helper_preserves_lock_acquired_after_guard" "$rc" \
		"Expected a lock acquired after guard evaluation to block final deletion"
	return 0
}

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
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" with_complete_cwd_snapshot remove_archived_worktree_path \
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
		with_complete_cwd_snapshot remove_archived_worktree_path "$wt_path" "$archive_path" "test.sh" \
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
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" with_complete_cwd_snapshot remove_archived_worktree_path \
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
	AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" with_complete_cwd_snapshot remove_archived_worktree_path \
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
		with_complete_cwd_snapshot remove_archived_worktree_path "$wt_path" "$archive_path" "test.sh" \
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

# =============================================================================
# Manual cleanup archives first, removes through native Git, and verifies exact
# metadata absence before ownership is unregistered.
# =============================================================================
test_manual_cleanup_archives_removes_and_prunes() {
	local log_file="${TEST_DIR}/manual-archive-cleanup.log"
	local repo_path="${TEST_DIR}/manual-archive-repo"
	local wt_path="${TEST_DIR}/manual-archive-worktree"
	local trash_destination="${TEST_DIR}/manual-archive-trash"
	local unregister_log="${TEST_DIR}/manual-archive-unregister.log"
	local cleanup_receipt_dir="${TEST_DIR}/manual-cleanup-receipts"
	local cleanup_receipt="${TEST_DIR}/manual-cleanup-receipts/example_repo-321.json"
	local wt_root=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/manual-archive" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
		unset _FULL_LOOP_CLEANUP_RECEIPT_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		SCRIPT_NAME="worktree-helper.sh"
		_WTAR_WH_CALLER="worktree-helper.sh"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		export AIDEVOPS_REAL_GIT_BIN="$GIT_BIN"
		export AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_destination"
		export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_receipt_dir"
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		full_loop_write_cleanup_deferred example/repo 321 "$wt_path" feature/manual-archive \
			"$$" manual-cleanup-test not-requested >/dev/null
		get_repo_root() {
			printf '%s\n' "$repo_path"
			return 0
		}
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		is_registered_canonical() { return 1; }
		unregister_worktree() {
			local removed_path="$1"
			printf '%s\n' "$removed_path" >>"$unregister_log"
			return 0
		}
		localdev_auto_branch_rm() { return 0; }
		preview_proxy_auto_free() { return 0; }
		_remove_cleanup_and_execute "$wt_path"
	); then
		rc=1
	fi
	[[ ! -e "$wt_path" && -d "$trash_destination" ]] || rc=1
	compgen -G "${trash_destination}/aidevops-worktree-cleanup-*/manual-archive-worktree" >/dev/null || rc=1
	if "$GIT_BIN" -C "$repo_path" worktree list --porcelain | grep -Fqx "worktree $wt_root"; then
		rc=1
	fi
	grep -Fxq "$wt_path" "$unregister_log" 2>/dev/null || rc=1
	assert_file_contains "$log_file" "worktree-removed.*manual.*mode=trash" || rc=1
	jq -e '.repository == "example/repo" and .pr_number == 321
		and .resource_cleanup_state == "CLEANED" and .cleanup_lease.state == "released"' \
		"$cleanup_receipt" >/dev/null || rc=1
	print_result "manual_cleanup_archives_removes_and_prunes" "$rc" \
		"Expected archive-first manual cleanup to verify metadata, unregister, and transition its exact receipt"
	return 0
}

# =============================================================================
# Manual targeted cleanup may recover from degraded process-CWD visibility only
# with exact-head merged-PR proof, no open PR, clean state, and an owned lease.
# =============================================================================
test_manual_cleanup_recovers_degraded_visibility_exact_head() {
	local log_file="${TEST_DIR}/manual-degraded-cleanup.log" repo_path="${TEST_DIR}/manual-degraded-repo"
	local wt_path="${TEST_DIR}/manual-degraded-worktree" trash_destination="${TEST_DIR}/manual-degraded-trash"
	local unregister_log="${TEST_DIR}/manual-degraded-unregister.log" branch_name="feature/manual-degraded"
	local head_sha="" metadata="" rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	head_sha=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	if ! (
		cd "$repo_path" || exit 1
		unset _WORKTREE_CMDS_LIB_LOADED _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		SCRIPT_NAME="worktree-helper.sh"
		_WTAR_WH_CALLER="worktree-helper.sh"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		export AIDEVOPS_REAL_GIT_BIN="$GIT_BIN"
		export AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_destination"
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		get_repo_root() {
			printf '%s\n' "$repo_path"
			return 0
		}
		worktree_removal_guard() {
			local candidate="$1"
			local caller="$2"
			local reason="$3"
			WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
			: "$candidate" "$caller" "$reason"
			return 2
		}
		worktree_has_changes() {
			local candidate="$1"
			[[ -n "$("$GIT_BIN" -C "$candidate" status --porcelain 2>/dev/null)" ]]
			return $?
		}
		is_registered_canonical() { return 1; }
		is_worktree_owned_by_others() { return 1; }
		is_worktree_owned_by_others_for_pid() { return 1; }
		worktree_has_exact_owner_contract() { return 0; }
		_branch_has_active_interactive_claim() { return 1; }
		_remove_repo_slug_for_worktree() {
			local candidate="$1"
			: "$candidate"
			printf '%s\n' "example/repository"
			return 0
		}
		gh_pr_list() {
			local all_args="$*"
			case "$all_args" in
			*"--state merged"*)
				printf '[{"number":42,"state":"MERGED","mergedAt":"2026-08-01T00:00:00Z","headRefName":"%s","headRefOid":"%s"}]\n' \
					"$branch_name" "$head_sha"
				;;
			*"--state open"*) printf '%s\n' '[]' ;;
			*) return 1 ;;
			esac
			return 0
		}
		_clean_acquire_removal_lease() {
			local candidate="$1"
			local branch="$2"
			: "$candidate" "$branch"
			return 0
		}
		unregister_worktree_if_owner_pid() { return 0; }
		unregister_worktree_if_owner_contract() {
			local candidate="$1"
			unregister_worktree "$candidate"
			return 0
		}
		unregister_worktree() {
			local removed_path="$1"
			printf '%s\n' "$removed_path" >>"$unregister_log"
			return 0
		}
		localdev_auto_branch_rm() { return 0; }
		preview_proxy_auto_free() { return 0; }
		_remove_resolve_path() {
			local target="$1"
			printf '%s\n' "$target"
			return 0
		}
		cmd_remove "$wt_path"
	); then
		rc=1
	fi
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	[[ ! -e "$wt_path" && -d "$trash_destination" ]] || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "branch refs/heads/${branch_name}" && rc=1
	"$GIT_BIN" -C "$repo_path" show-ref --verify --quiet "refs/heads/${branch_name}" || rc=1
	grep -Fxq "$wt_path" "$unregister_log" 2>/dev/null || rc=1
	assert_file_contains "$log_file" "worktree-removed.*manual.*mode=recoverable-trash.*merged_pr=42.*branch_preserved=true" || rc=1
	print_result "manual_cleanup_recovers_degraded_visibility_exact_head" "$rc" \
		"Expected candidate-local archive-first removal with exact merged proof and branch preservation"
	return 0
}

# =============================================================================
# A degraded cleanup lease is owned by the leaf executor PID, not the stable
# runtime PID used by generic interactive ownership checks. Rechecks after lease
# acquisition require the complete PID/session/task contract and fail closed if
# that evidence is replaced, deleted, or unavailable.
# =============================================================================
test_manual_degraded_recheck_requires_live_exact_lease() {
	local repo_path="${TEST_DIR}/manual-degraded-lease-repo"
	local wt_path="${TEST_DIR}/manual-degraded-lease-worktree"
	local registry_dir="${TEST_DIR}/manual-degraded-lease-registry"
	local branch_name="feature/manual-degraded-lease"
	local head_sha=""
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	head_sha=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED _WORKTREE_CLEAN_LIB_LOADED \
			_SHARED_WORKTREE_REGISTRY_LOADED 2>/dev/null || true
		export WORKTREE_REGISTRY_DIR="$registry_dir"
		export WORKTREE_REGISTRY_DB="${registry_dir}/worktree-registry.db"
		# shellcheck source=../shared-worktree-registry.sh
		source "$REGISTRY_HELPER"
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		sleep 30 &
		local runtime_pid=$!
		trap 'kill "$runtime_pid" 2>/dev/null || true' EXIT
		export OPENCODE_PID="$runtime_pid"
		worktree_has_changes() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		_remove_repo_slug_for_worktree() {
			local candidate="$1"
			: "$candidate"
			printf '%s\n' "example/repository"
			return 0
		}
		gh_pr_list() {
			local all_args="$*"
			case "$all_args" in
			*"--state merged"*)
				printf '[{"number":42,"state":"MERGED","mergedAt":"2026-08-01T00:00:00Z","headRefName":"%s","headRefOid":"%s"}]\n' \
					"$branch_name" "$head_sha"
				;;
			*"--state open"*) printf '%s\n' '[]' ;;
			*) return 1 ;;
			esac
			return 0
		}
		export WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		_clean_acquire_removal_lease "$wt_path" "$branch_name" || exit 1
		is_worktree_owned_by_others "$wt_path" || exit 1
		if is_worktree_owned_by_others_for_pid "$wt_path" "$$"; then
			exit 1
		fi
		_remove_degraded_fallback_allowed "$wt_path" "$$" || exit 1

		local registry_path=""
		registry_path=$(_wt_registry_lookup_path "$wt_path") || exit 1
		sqlite3 "$WORKTREE_REGISTRY_DB" "
			UPDATE worktree_owners
			SET owner_session = 'cleanup-replaced'
			WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
		" || exit 1
		if _remove_degraded_fallback_allowed "$wt_path" "$$"; then
			exit 1
		fi

		sqlite3 "$WORKTREE_REGISTRY_DB" "
			DELETE FROM worktree_owners
			WHERE worktree_path = '$(_wt_sql_escape "$registry_path")';
		" || exit 1
		if _remove_degraded_fallback_allowed "$wt_path" "$$"; then
			exit 1
		fi

		WORKTREE_REGISTRY_DB="${registry_dir}/missing.db"
		if _remove_degraded_fallback_allowed "$wt_path" "$$"; then
			exit 1
		fi
		exit 0
	); then
		rc=1
	fi
	print_result "manual_degraded_recheck_requires_live_exact_lease" "$rc" \
		"Expected post-lease checks to accept only the live exact PID/session/task contract"
	return 0
}

test_manual_degraded_recovery_rejects_unsafe_candidates() {
	local repo_path="${TEST_DIR}/manual-degraded-refusal-repo"
	local wt_path="${TEST_DIR}/manual-degraded-refusal-worktree"
	local branch_name="feature/manual-degraded-refusal"
	local head_sha=""
	local proof_mode="head-mismatch"
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "$branch_name" || rc=1
	head_sha=$("$GIT_BIN" -C "$wt_path" rev-parse --verify HEAD) || rc=1
	if ! (
		unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${COMMANDS_HELPER%/*}"
		RED="" NC=""
		# shellcheck source=../worktree-helper-cmds.sh
		source "$COMMANDS_HELPER"
		worktree_has_changes() { return 1; }
		is_worktree_owned_by_others() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		_remove_repo_slug_for_worktree() {
			local candidate="$1"
			: "$candidate"
			printf '%s\n' "example/repository"
			return 0
		}
		gh_pr_list() {
			local all_args="$*"
			local proof_head="$head_sha"
			[[ "$proof_mode" != "head-mismatch" ]] || proof_head="0000000000000000000000000000000000000000"
			case "$all_args" in
			*"--state merged"*)
				printf '[{"number":42,"state":"MERGED","mergedAt":"2026-08-01T00:00:00Z","headRefName":"%s","headRefOid":"%s"}]\n' \
					"$branch_name" "$proof_head"
				;;
			*"--state open"*)
				if [[ "$proof_mode" == "open-pr" ]]; then
					printf '[{"number":43,"headRefName":"%s","headRefOid":"%s"}]\n' "$branch_name" "$head_sha"
				else
					printf '%s\n' '[]'
				fi
				;;
			*) return 1 ;;
			esac
			return 0
		}
		WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		proof_mode="open-pr"
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		printf 'dirty\n' >"${wt_path}/untracked.txt"
		worktree_has_changes() {
			local candidate="$1"
			[[ -n "$("$GIT_BIN" -C "$candidate" status --porcelain 2>/dev/null)" ]]
			return $?
		}
		proof_mode="valid"
		if _remove_degraded_fallback_allowed "$wt_path"; then
			exit 1
		fi
		exit 0
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	print_result "manual_degraded_recovery_rejects_unsafe_candidates" "$rc" \
		"Expected head mismatch, open PR, and dirty state to fail closed"
	return 0
}

# =============================================================================
# A recoverable caller cannot rely on stale guard evidence. If a foreign lock
# exists when archive preparation starts, source removal must not start.
# =============================================================================
test_recoverable_cleanup_preserves_lock_acquired_after_guard() {
	local log_file="${TEST_DIR}/recoverable-race-cleanup.log"
	local repo_path="${TEST_DIR}/recoverable-race-repo"
	local wt_path="${TEST_DIR}/recoverable-race-worktree"
	local wt_root=""
	local metadata=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/recoverable-race" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "foreign-race-lock" "$wt_path" || rc=1
	if (
		unset _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${CLEAN_HELPER%/*}"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		_WTAR_WH_CALLER="test.sh"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		worktree_removal_guard() {
			WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
			return 2
		}
		worktree_has_changes() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		_clean_has_exact_removal_lease() { return 0; }
		_clean_remove_classified_worktree "$wt_path" "feature/recoverable-race" \
			"false" "false" "test=context" "$repo_path" \
			"$_WT_CLEAN_MODE_RECOVERABLE" "true"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	printf '%s\n' "$metadata" | grep -Eq '^locked([[:space:]]|$)' || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-worktree-locked.*mode=skipped" || rc=1
	print_result "recoverable_cleanup_preserves_lock_acquired_after_guard" "$rc" \
		"Expected archive preparation to preserve a lock after a stale guard"
	return 0
}

# =============================================================================
# Recoverable cleanup must retain both source and completed archive if its exact
# lease disappears while the archive copy is in progress.
# =============================================================================
test_recoverable_cleanup_preserves_lease_loss_after_archive() {
	local log_file="${TEST_DIR}/recoverable-lease-race-cleanup.log"
	local repo_path="${TEST_DIR}/recoverable-lease-race-repo"
	local wt_path="${TEST_DIR}/recoverable-lease-race-worktree"
	local trash_root="${TEST_DIR}/recoverable-lease-race-trash"
	local metadata=""
	local wt_root=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/recoverable-lease-race" || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	if (
		unset _WORKTREE_CLEAN_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${CLEAN_HELPER%/*}"
		RED="" GREEN="" YELLOW="" BLUE="" NC=""
		_WTAR_WH_CALLER="test.sh"
		export AIDEVOPS_WORKTREE_TRASH_ROOT="$trash_root"
		# shellcheck source=../worktree-clean-lib.sh
		source "$CLEAN_HELPER"
		worktree_removal_guard() {
			WORKTREE_REMOVAL_GUARD_REASON="cwd-visibility-degraded"
			return 2
		}
		worktree_has_changes() { return 1; }
		_branch_has_active_interactive_claim() { return 1; }
		local lease_checks=0
		_clean_has_exact_removal_lease() {
			lease_checks=$((lease_checks + 1))
			[[ "$lease_checks" -eq 1 ]]
			return $?
		}
		_clean_remove_classified_worktree "$wt_path" "feature/recoverable-lease-race" \
			"false" "false" "test=context" "$repo_path" \
			"$_WT_CLEAN_MODE_RECOVERABLE" "true"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	compgen -G "${trash_root}/aidevops-worktree-cleanup-*/recoverable-lease-race-worktree" >/dev/null || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*cleanup-lease-changed-after-archive.*mode=skipped" || rc=1
	print_result "recoverable_cleanup_preserves_lease_loss_after_archive" "$rc" \
		"Expected source, metadata, and archive retention after cleanup lease replacement"
	return 0
}

# =============================================================================
# Skill-update cleanup must not delete the branch or unregister ownership when
# the guarded permanent-removal primitive refuses the worktree.
# =============================================================================
test_skill_cleanup_has_no_removal_failure_fallback() {
	local wt_path="${TEST_DIR}/skill-fallback-worktree"
	local side_effect_log="${TEST_DIR}/skill-fallback-effects.log"
	local rc=0
	mkdir -p "$wt_path"

	if ! (
		unset _SKILL_UPDATE_PR_LIB_LOADED 2>/dev/null || true
		SCRIPT_DIR="${SKILL_PR_HELPER%/*}"
		_WTAR_SU_CALLER="skill-update-helper.sh"
		# shellcheck source=../skill-update-pr-lib.sh
		source "$SKILL_PR_HELPER"
		get_default_branch() {
			printf '%s\n' "main"
			return 0
		}
		git() {
			local all_args="$*"
			case "$all_args" in
			*"rev-list --count main..HEAD"*) printf '%s\n' "0" ;;
			*"worktree remove"* | *"branch -D"*) printf '%s\n' "$all_args" >>"$side_effect_log" ;;
			*) "$GIT_BIN" "$@" || return $? ;;
			esac
			return 0
		}
		is_worktree_owned_by_others() { return 1; }
		worktree_removal_guard() { return 0; }
		remove_worktree_path_permanently() { return 1; }
		log_info() { return 0; }
		log_warning() { return 0; }
		unregister_worktree() {
			printf '%s\n' "unregister:$1" >>"$side_effect_log"
			return 0
		}
		_cleanup_worktree "$wt_path" "feature/skill-fallback"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	[[ ! -s "$side_effect_log" ]] || rc=1
	print_result "skill_cleanup_has_no_removal_failure_fallback" "$rc" \
		"Expected failed guarded removal to preserve the path, branch, and registry"
	return 0
}

# =============================================================================
# Shared removal guard treats Git worktree locks as a non-overridable safety
# boundary. Direct permanent deletion must not bypass the lock.
# =============================================================================
test_permanent_helper_preserves_git_locked_worktree() {
	local log_file="${TEST_DIR}/locked-cleanup.log"
	local repo_path="${TEST_DIR}/locked-repo"
	local wt_path="${TEST_DIR}/locked-worktree"
	local wt_root=""
	local metadata=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/locked" || rc=1
	"$GIT_BIN" -C "$repo_path" worktree lock --reason "observation-provenance" "$wt_path" || rc=1
	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	wt_root=$("$GIT_BIN" -C "$wt_path" rev-parse --show-toplevel 2>/dev/null) || rc=1
	metadata=$("$GIT_BIN" -C "$repo_path" worktree list --porcelain 2>/dev/null) || rc=1
	printf '%s\n' "$metadata" | grep -Fqx "worktree $wt_root" || rc=1
	printf '%s\n' "$metadata" | grep -Eq '^locked([[:space:]]|$)' || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-worktree-locked.*mode=skipped" || rc=1
	print_result "permanent_helper_preserves_git_locked_worktree" "$rc" \
		"Expected locked worktree path and metadata to remain. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Git metadata failures are not evidence that a worktree is unlocked.
# =============================================================================
test_permanent_helper_fails_closed_on_unreadable_git_metadata() {
	local log_file="${TEST_DIR}/unreadable-cleanup.log"
	local wt_path="${TEST_DIR}/unreadable-worktree"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"
	printf 'gitdir: unavailable\n' >"${wt_path}/.git"

	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		git() {
			return 1
		}
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-metadata-unreadable.*mode=skipped" || rc=1
	print_result "permanent_helper_fails_closed_on_unreadable_git_metadata" "$rc" \
		"Expected unreadable Git metadata to block permanent removal. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# A successful metadata query that omits the exact candidate is ambiguous and
# must not be treated as proof that the candidate is unlocked.
# =============================================================================
test_permanent_helper_fails_closed_on_ambiguous_git_metadata() {
	local log_file="${TEST_DIR}/ambiguous-cleanup.log"
	local wt_path="${TEST_DIR}/ambiguous-worktree"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"
	printf 'gitdir: ambiguous\n' >"${wt_path}/.git"

	if (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		git() {
			local all_args="$*"
			case "$all_args" in
			*"rev-parse --show-toplevel"*) printf '%s\n' "$wt_path" ;;
			*"worktree list --porcelain -z"*)
				printf 'worktree %s\0HEAD 0123456789abcdef0123456789abcdef01234567\0detached\0\0' \
					"${TEST_DIR}/different-worktree"
				;;
			*) return 1 ;;
			esac
			return 0
		}
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*git-metadata-unreadable.*mode=skipped" || rc=1
	print_result "permanent_helper_fails_closed_on_ambiguous_git_metadata" "$rc" \
		"Expected ambiguous Git metadata to block permanent removal. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Verified unlocked worktrees remain eligible for the caller's existing policy.
# =============================================================================
test_guard_allows_verified_unlocked_worktree() {
	local repo_path="${TEST_DIR}/unlocked-repo"
	local wt_path="${TEST_DIR}/unlocked-worktree"
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/unlocked" || rc=1
	if ! (
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		worktree_removal_guard "$wt_path" "test.sh" "manual" ""
	); then
		rc=1
	fi
	[[ -d "$wt_path" ]] || rc=1
	print_result "guard_allows_verified_unlocked_worktree" "$rc" \
		"Expected verified unlocked worktree to pass the shared guard"
	return 0
}

# =============================================================================
# Test 10: optional guard context includes predicates needed for safe cleanup audit
# =============================================================================
test_optional_guard_context_logged() {
	local log_file="${TEST_DIR}/t10-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local context="branch=feature/gh23074 issue=23074 owner_guard=clear process_guard=clear recent_session_guard=clear commits=1 pr_state=none recovery_path=none"
	log_worktree_removal_event "$_WTAR_SKIPPED" "pulse-cleanup.sh" "/wt/context" "local-commits-no-pr" "skipped" "$context"
	local branch_merged_context="target_branch=main merge_proof=merge-base-is-ancestor merge_proof_result=ancestor branch=feature/gh23076 owner_guard=clear protected_status=clear"
	log_worktree_removal_event "$_WTAR_REMOVED" "worktree-helper.sh" "/wt/merged" "branch-merged" "permanent" "$branch_merged_context"

	local rc=0
	assert_file_contains "$log_file" "worktree-skipped.*local-commits-no-pr.*mode=skipped.*branch=feature/gh23074.*owner_guard=clear.*process_guard=clear.*recent_session_guard=clear.*commits=1.*pr_state=none.*recovery_path=none" || rc=1
	assert_file_contains "$log_file" "worktree-removed.*branch-merged.*mode=permanent.*target_branch=main.*merge_proof=merge-base-is-ancestor.*merge_proof_result=ancestor.*protected_status=clear" || rc=1
	print_result "optional_guard_context_logged" "$rc" \
		"Expected guard context audit. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 11: process-cwd helper refuses empty paths before glob-like matching
# =============================================================================
test_process_cwd_guard_refuses_empty_paths() {
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local rc=0
	if _worktree_has_process_cwd "" "/tmp/example"; then
		rc=1
	fi
	if _worktree_has_process_cwd "/tmp/example" ""; then
		rc=1
	fi
	print_result "process_cwd_guard_refuses_empty_paths" "$rc" \
		"Expected empty path inputs to return non-match"
	return 0
}

# =============================================================================
# Test 12: snapshot collection failures block removal, while an explicitly
# supplied empty successful snapshot avoids a second platform scan.
# =============================================================================
test_process_cwd_snapshot_failure_is_fail_closed() {
	local log_file="${TEST_DIR}/t12-cleanup.log"
	local wt_path="${TEST_DIR}/snapshot-failure-wt"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	capture_worktree_process_cwds() { return 1; }
	if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
		rc=1
	fi
	assert_file_contains "$log_file" "worktree-skipped.*cwd-visibility-unusable" || rc=1
	if ! worktree_removal_guard "$wt_path" "test.sh" "manual" ""; then
		rc=1
	fi
	print_result "process_cwd_snapshot_failure_is_fail_closed" "$rc" \
		"Expected collection failure to block and explicit empty snapshot to pass"
	return 0
}

# =============================================================================
# Test 13: each platform backend fails closed when it cannot publish any cwd
# target instead of treating an empty snapshot as authoritative.
# =============================================================================
test_snapshot_backend_requires_visible_target() {
	local rc=0
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	if [[ -d /proc ]]; then
		if (
			readlink() { return 1; }
			capture_worktree_process_cwds >/dev/null
		); then
			rc=1
		fi
	else
		if (
			lsof() { return 0; }
			capture_worktree_process_cwds >/dev/null
		); then
			rc=1
		fi
	fi
	print_result "snapshot_backend_requires_visible_target" "$rc" \
		"Expected an empty process-cwd backend result to fail closed"
	return 0
}

# =============================================================================
# The macOS lsof backend distinguishes complete output, partial/permission-
# limited output, and empty unusable output. Absence-only output never proves a
# candidate inactive.
# =============================================================================
test_lsof_snapshot_visibility_states() {
	local output=""
	local capture_status=0
	local rc=0

	if output=$(
		lsof() { return 0; }
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq 1 && -z "$output" ]] || rc=1

	if output=$(
		lsof() {
			printf 'p123\nn/visible-lsof-cwd\n'
			return 1
		}
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-lsof-cwd" ]] || rc=1

	if output=$(
		lsof() {
			printf 'p123\nn/complete-lsof-cwd\n'
			return 0
		}
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq 0 && "$output" == "/complete-lsof-cwd" ]] || rc=1
	print_result "lsof_snapshot_visibility_states" "$rc" \
		"Expected empty lsof to be unusable and partial lsof output to be degraded"
	return 0
}

# =============================================================================
# Test 14: a partially visible /proc snapshot preserves readable evidence and
# reports degraded visibility instead of aliasing it to a total failure.
# =============================================================================
test_proc_snapshot_preserves_degraded_visibility() {
	local proc_root="${TEST_DIR}/fake-proc"
	local output=""
	local capture_status=0
	local rc=0
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /hidden-cwd "${proc_root}/2/cwd"

	if output=$(
		readlink() {
			local link_path="$1"
			if [[ "$link_path" == */1/cwd ]]; then
				printf '/visible-cwd\n'
				return 0
			fi
			return 1
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_preserves_degraded_visibility" "$rc" \
		"Expected unreadable unknown ownership to preserve visible cwd evidence with degraded status"
	return 0
}

# =============================================================================
# Linux /proc entries that are unreadable but provably foreign do not invalidate
# otherwise usable evidence.
# =============================================================================
test_proc_snapshot_skips_foreign_uid_unreadable_entry() {
	local proc_root="${TEST_DIR}/fake-proc-foreign"
	local current_uid=""
	local foreign_uid=""
	local output=""
	local rc=0
	current_uid=$(id -u)
	foreign_uid=$((current_uid + 1))
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /foreign-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$foreign_uid" "$foreign_uid" "$foreign_uid" "$foreign_uid" >"${proc_root}/2/status"

	output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_skips_foreign_uid_unreadable_entry" "$rc" \
		"Expected foreign unreadable cwd to be skipped without hiding visible evidence"
	return 0
}

# =============================================================================
# Same-UID unreadability is explicitly degraded while preserving readable cwd
# evidence for candidate-specific positive matching.
# =============================================================================
test_proc_snapshot_marks_same_uid_unreadable_entry_degraded() {
	local proc_root="${TEST_DIR}/fake-proc-same-uid"
	local current_uid=""
	local output=""
	local capture_status=0
	local rc=0
	current_uid=$(id -u)
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /same-user-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$current_uid" "$current_uid" "$current_uid" "$current_uid" >"${proc_root}/2/status"

	if output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_marks_same_uid_unreadable_entry_degraded" "$rc" \
		"Expected simulated same-UID EACCES to return degraded status with visible evidence intact"
	return 0
}

# =============================================================================
# Degraded visibility is candidate-specific: unrelated readable CWDs require a
# recoverable path, while any readable target inside the candidate hard-blocks.
# =============================================================================
test_degraded_visibility_preserves_positive_candidate_match() {
	local log_file="${TEST_DIR}/degraded-candidate-cleanup.log"
	local wt_path="${TEST_DIR}/degraded-candidate"
	local guard_status=0
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	if worktree_removal_guard "$wt_path" "test.sh" "manual" "/unrelated-readable-cwd" \
		"$_WT_CWD_VISIBILITY_DEGRADED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	[[ "$guard_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "$_WT_CWD_REASON_DEGRADED" ]] || rc=1

	if worktree_removal_guard "$wt_path" "test.sh" "manual" "$wt_path/active-shell" \
		"$_WT_CWD_VISIBILITY_DEGRADED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	[[ "$guard_status" -eq 1 ]] || rc=1
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "active-cwd" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*cwd-visibility-degraded.*mode=recoverable-required" || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*active-cwd.*mode=skipped" || rc=1
	print_result "degraded_visibility_preserves_positive_candidate_match" "$rc" \
		"Expected unrelated denial to be recoverable-only and readable candidate CWD to hard-block"
	return 0
}

# =============================================================================
# Foreign skips alone are not usable evidence: an empty snapshot still blocks
# destructive cleanup.
# =============================================================================
test_proc_snapshot_requires_usable_evidence_after_foreign_skips() {
	local proc_root="${TEST_DIR}/fake-proc-foreign-only"
	local current_uid=""
	local foreign_uid=""
	local rc=0
	current_uid=$(id -u)
	foreign_uid=$((current_uid + 1))
	mkdir -p "${proc_root}/1"
	ln -s /foreign-cwd "${proc_root}/1/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$foreign_uid" "$foreign_uid" "$foreign_uid" "$foreign_uid" >"${proc_root}/1/status"

	if (
		readlink() { return 1; }
		_capture_worktree_proc_cwds "$proc_root" >/dev/null
	); then
		rc=1
	fi
	print_result "proc_snapshot_requires_usable_evidence_after_foreign_skips" "$rc" \
		"Expected zero captured cwd targets to remain fail-closed"
	return 0
}

# =============================================================================
# A process that vanishes during readlink is ignored when other usable evidence
# remains in the snapshot.
# =============================================================================
test_proc_snapshot_ignores_vanished_entry() {
	local proc_root="${TEST_DIR}/fake-proc-vanished"
	local output=""
	local rc=0
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /vanished-cwd "${proc_root}/2/cwd"

	output=$(
		readlink() {
			local link_path="$1"
			if [[ "$link_path" == */1/cwd ]]; then
				printf '/visible-cwd\n'
				return 0
			fi
			rm -f "$link_path"
			return 1
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_ignores_vanished_entry" "$rc" \
		"Expected a vanished process to be ignored without losing visible evidence"
	return 0
}

# =============================================================================
# Guard refusals expose a machine-readable reason without changing the
# exactly-once audit contract.
# =============================================================================
test_guard_reason_is_machine_readable() {
	local log_file="${TEST_DIR}/t15-cleanup.log"
	local wt_path="${TEST_DIR}/reason-wt"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	if worktree_removal_guard "$wt_path" "test.sh" "manual" "$wt_path"; then
		rc=1
	fi
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "active-cwd" ]] || rc=1
	assert_line_count "$log_file" 1 || rc=1
	print_result "guard_reason_is_machine_readable" "$rc" \
		"Expected active-cwd reason and exactly one audit row"
	return 0
}

# =============================================================================
# Test 16: manual removal renders safe actionable diagnostics for each shared
# guard reason. The guard remains the sole audit writer.
# =============================================================================
test_manual_guard_refusal_diagnostics() {
	local output_file="${TEST_DIR}/t16-output.log"
	local log_file="${TEST_DIR}/t16-cleanup.log"
	local rc=0
	local reason=""
	local guard_reason_to_test=""
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
	RED=""
	NC=""
	# shellcheck source=../worktree-helper-cmds.sh
	source "$COMMANDS_HELPER"
	worktree_removal_guard() {
		local path_to_remove="$1"
		local caller="$2"
		local removal_mode="$3"
		WORKTREE_REMOVAL_GUARD_REASON="$guard_reason_to_test"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$path_to_remove" \
			"$guard_reason_to_test" "skipped"
		: "$removal_mode"
		return 1
	}
	for reason in active-cwd current-worktree canonical-skip git-worktree-locked git-metadata-unreadable; do
		guard_reason_to_test="$reason"
		if _remove_validate_path "/safe/example-worktree" 2>>"$output_file"; then
			rc=1
		fi
	done
	assert_file_contains "$output_file" "Reason: active-cwd.*live process" || rc=1
	assert_file_contains "$output_file" "Reason: current-worktree.*inside the target" || rc=1
	assert_file_contains "$output_file" "Reason: canonical-skip.*canonical checkout" || rc=1
	assert_file_contains "$output_file" "Reason: git-worktree-locked.*explicitly locked" || rc=1
	assert_file_contains "$output_file" "Reason: git-metadata-unreadable.*could not prove" || rc=1
	assert_file_contains "$output_file" "cannot bypass this protection" || rc=1
	assert_line_count "$log_file" 5 || rc=1
	print_result "manual_guard_refusal_diagnostics" "$rc" \
		"Expected safe diagnostics and exactly one audit row per refusal"
	return 0
}

# =============================================================================
# Archive publication uses the same exclusive producer lock as recovery apply.
# =============================================================================
test_recoverable_archive_honours_shared_producer_lock() {
	local repo_path="${TEST_DIR}/producer-lock-repo"
	local wt_path="${TEST_DIR}/producer-lock-worktree"
	local recovery_root="${TEST_DIR}/producer-lock-recovery"
	local lock_path="${recovery_root}/${_WT_RECOVERY_PRODUCER_LOCK_NAME}"
	local process_lstart=""
	local archive_path=""
	local rc=0

	create_git_worktree_fixture "$repo_path" "$wt_path" "feature/producer-lock" || rc=1
	mkdir -p "$recovery_root" "$lock_path" || rc=1
	process_lstart=$(_worktree_recovery_process_lstart "$$") || rc=1
	printf '%s\n' "$$" >"$lock_path/pid" || rc=1
	printf '%s\n' "$process_lstart" >"$lock_path/lstart" || rc=1
	printf '%s\n' "archive-lock-fixture" >"$lock_path/token" || rc=1
	printf '%s\n' "complete" >"$lock_path/initialized" || rc=1
	if AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$wt_path" "test.sh" "producer-lock"; then
		rc=1
	fi
	[[ -d "$wt_path" && -d "$lock_path" ]] || rc=1
	if compgen -G "${recovery_root}/aidevops-worktree-cleanup-*" >/dev/null; then rc=1; fi
	rm -f "$lock_path/pid" "$lock_path/lstart" "$lock_path/token" "$lock_path/initialized" || rc=1
	rmdir "$lock_path" || rc=1
	AIDEVOPS_WORKTREE_TRASH_ROOT="$recovery_root" AIDEVOPS_REAL_GIT_BIN="$GIT_BIN" \
		archive_worktree_path_recoverably "$wt_path" "test.sh" "producer-lock" || rc=1
	archive_path="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"
	[[ -d "$archive_path" &&
		-f "${archive_path%/*}/${_WT_RECOVERY_DIR_NAME}/${_WT_RECOVERY_COMPLETE_MARKER}" &&
		! -e "$lock_path" ]] || rc=1
	print_result "recoverable_archive_honours_shared_producer_lock" "$rc" \
		"Expected a live apply-compatible lock to block archive publication through its completion marker"
	return 0
}

# =============================================================================
# Main
# =============================================================================

setup

echo "=== test-worktree-removal-audit.sh ==="

test_log_writes_one_line
test_log_format_correct
test_custom_log_path
test_all_event_types
test_should_skip_cleanup_owned_skip_logs
test_idempotent_sourcing
test_guard_refuses_current_cwd
test_guard_refuses_other_process_cwd
test_permanent_helper_removes_and_logs
test_guard_fails_closed_on_inaccessible_candidate
test_git_lock_parser_handles_unusual_paths_and_adjacent_blocks
test_git_lock_parser_rejects_malformed_blocks
test_missing_worktree_physical_parent_alias
test_permanent_helper_preserves_lock_acquired_after_guard
test_recovery_store_selects_platform_semantics
test_recovery_inventory_reports_legacy_buckets_fail_closed
test_recoverable_archive_then_native_remove
test_recoverable_archive_preserves_late_lock
test_recovery_archive_preserves_index_and_dirty_files
test_recovery_archive_preserves_detached_head_identity
test_recoverable_archive_refuses_replacement_worktree
test_recoverable_archive_refuses_late_unarchived_write_without_force
test_removal_helpers_refuse_direct_symlink_alias
test_manual_cleanup_archives_removes_and_prunes
test_manual_cleanup_recovers_degraded_visibility_exact_head
test_manual_degraded_recheck_requires_live_exact_lease
test_manual_degraded_recovery_rejects_unsafe_candidates
test_recoverable_cleanup_preserves_lock_acquired_after_guard
test_recoverable_cleanup_preserves_lease_loss_after_archive
test_skill_cleanup_has_no_removal_failure_fallback
test_permanent_helper_preserves_git_locked_worktree
test_permanent_helper_fails_closed_on_unreadable_git_metadata
test_permanent_helper_fails_closed_on_ambiguous_git_metadata
test_guard_allows_verified_unlocked_worktree
test_optional_guard_context_logged
test_process_cwd_guard_refuses_empty_paths
test_process_cwd_snapshot_failure_is_fail_closed
test_snapshot_backend_requires_visible_target
test_lsof_snapshot_visibility_states
test_proc_snapshot_preserves_degraded_visibility
test_proc_snapshot_skips_foreign_uid_unreadable_entry
test_proc_snapshot_marks_same_uid_unreadable_entry_degraded
test_degraded_visibility_preserves_positive_candidate_match
test_proc_snapshot_requires_usable_evidence_after_foreign_skips
test_proc_snapshot_ignores_vanished_entry
test_guard_reason_is_machine_readable
test_manual_guard_refusal_diagnostics
test_recoverable_archive_honours_shared_producer_lock

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed."

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
