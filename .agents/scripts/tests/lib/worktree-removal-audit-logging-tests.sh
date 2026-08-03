#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worktree Removal Audit Tests — Logging, Guard, and Git Lock Coverage
# =============================================================================
# Sourced by ../test-worktree-removal-audit.sh.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_WORKTREE_REMOVAL_AUDIT_LOGGING_TESTS_LOADED:-}" ]] && return 0
_WORKTREE_REMOVAL_AUDIT_LOGGING_TESTS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Test 1: log_worktree_removal_event writes one structured line
# =============================================================================
test_log_writes_one_line() {
	local log_file="${TEST_DIR}/t1-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	log_worktree_removal_event "$_WTAR_REMOVED" "test-caller.sh" "/tmp/test-wt" "manual" "trash"

	local rc=0
	assert_line_count "$log_file" 1 || rc=$?
	print_result "log_writes_one_line" "$rc" "Expected exactly 1 line in log"
	return 0
}

# =============================================================================
# Test 2: log line format matches [ISO8601] [caller] worktree-<type>: <path> — <reason>
# =============================================================================
test_log_format_correct() {
	local log_file="${TEST_DIR}/t2-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	log_worktree_removal_event "$_WTAR_SKIPPED" "worktree-helper.sh" "/some/path" "owned-skip" "skipped"

	local pattern='^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] \[worktree-helper\.sh\] worktree-skipped: /some/path — owned-skip — mode=skipped$'
	local rc=0
	assert_file_contains "$log_file" "$pattern" || rc=$?
	print_result "log_format_correct" "$rc" "Log line does not match expected format. Content: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 3: AIDEVOPS_CLEANUP_LOG env var is honoured (custom log path)
# =============================================================================
test_custom_log_path() {
	local custom_log="${TEST_DIR}/custom/subdir/audit.log"
	export AIDEVOPS_CLEANUP_LOG="$custom_log"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	log_worktree_removal_event "$_WTAR_REMOVED" "test.sh" "/wt/path" "age-eligible" "permanent"

	local rc=0
	if [[ -f "$custom_log" ]]; then
		assert_file_contains "$custom_log" "worktree-removed" || rc=$?
	else
		rc=1
		echo "  custom log file not created at $custom_log"
	fi
	print_result "custom_log_path_honoured" "$rc" "Custom AIDEVOPS_CLEANUP_LOG path not written"
	return 0
}

# =============================================================================
# Test 4: Multiple event types produce correct type strings in log
# =============================================================================
test_all_event_types() {
	local log_file="${TEST_DIR}/t4-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	log_worktree_removal_event "$_WTAR_REMOVED" "s.sh" "/p1" "manual" "trash"
	log_worktree_removal_event "$_WTAR_SKIPPED" "s.sh" "/p2" "grace-period" "skipped"
	log_worktree_removal_event "$_WTAR_FIXTURE_REMOVED" "s.sh" "/p3" "fixture" "fixture"

	local rc=0
	assert_line_count "$log_file" 3 || rc=1
	assert_file_contains "$log_file" "worktree-removed.*p1.*mode=trash" || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*p2.*grace-period.*mode=skipped" || rc=1
	assert_file_contains "$log_file" "worktree-fixture-removed.*p3.*fixture.*mode=fixture" || rc=1
	print_result "all_event_types_logged" "$rc" "Not all event types written correctly"
	return 0
}

# =============================================================================
# Test 5: should_skip_cleanup owned-skip path emits a worktree-skipped entry
# =============================================================================
test_should_skip_cleanup_owned_skip_logs() {
	local log_file="${TEST_DIR}/t5-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/fake-wt-$$"
	mkdir -p "$wt_path"

	# Run in a subshell to avoid polluting the outer env with stubs.
	(
		RED='' NC=''
		is_worktree_owned_by_others() { return 0; }
		check_worktree_owner() {
			echo "99999|session-stub"
			return 0
		}
		worktree_is_in_grace_period() { return 1; }
		get_validated_grace_hours() {
			echo "4"
			return 0
		}
		worktree_has_changes() { return 1; }
		branch_has_zero_commits_ahead() { return 1; }

		export AIDEVOPS_CLEANUP_LOG="$log_file"
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"

		# Define the should_skip_cleanup function body as it appears in worktree-helper.sh
		# after the t2976 changes — exercises the owned-skip audit log path.
		should_skip_cleanup() {
			local wt_path_sc="$1"
			local wt_branch_sc="$2"
			local default_br_sc="$3"
			local open_pr_list_sc="$4"
			local force_merged_flag_sc="$5"

			if is_worktree_owned_by_others "$wt_path_sc"; then
				local owner_info_sc
				owner_info_sc=$(check_worktree_owner "$wt_path_sc")
				local owner_pid_sc="${owner_info_sc%%|*}"
				echo "  ${wt_branch_sc} (owned by active session PID $owner_pid_sc - skipping)"
				echo "    $wt_path_sc"
				echo ""
				log_worktree_removal_event "$_WTAR_SKIPPED" "worktree-helper.sh" \
					"$wt_path_sc" "owned-skip" "skipped"
				return 0
			fi
			return 1
		}

		should_skip_cleanup "$wt_path" "feature/test" "main" "" "false"
	)

	local rc=0
	assert_file_contains "$log_file" "worktree-skipped.*owned-skip" || rc=$?
	print_result "should_skip_cleanup_owned_skip_logs" "$rc" \
		"Expected worktree-skipped/owned-skip entry. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 6: audit helper is idempotent — double-sourcing does not duplicate output
# =============================================================================
test_idempotent_sourcing() {
	local log_file="${TEST_DIR}/t6-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER" # second source — guard makes this a no-op

	log_worktree_removal_event "$_WTAR_REMOVED" "test.sh" "/wt" "manual" "trash"

	local rc=0
	assert_line_count "$log_file" 1 || rc=$?
	print_result "idempotent_sourcing" "$rc" "Double-sourcing produced unexpected output"
	return 0
}

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
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
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
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
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
