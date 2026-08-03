#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-linters-local-ratchet-timeout.sh — ratchet progress/timeout diagnostics.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
RATCHET_SCRIPT="${SCRIPT_DIR}/../linters-local-ratchet.sh"
RATCHET_SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [ "$passed" -eq 0 ]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [ -n "$message" ]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

source_ratchet_helpers() {
	SCRIPT_DIR="$RATCHET_SCRIPT_DIR"
	# shellcheck disable=SC1090  # test intentionally sources the helper under test
	source "$RATCHET_SCRIPT"
	return 0
}

slow_ratchet_counter() {
	sleep 3
	echo "1"
	return 0
}

fast_ratchet_counter() {
	echo "7"
	return 0
}

test_ratchet_counter_times_out_with_diagnostic() {
	source_ratchet_helpers
	local out ret=0
	RATCHET_STEP_TIMEOUT_SECONDS=1 out=$(_ratchet_count_with_progress "slow_test" "slow_ratchet_counter" "" 2>&1) || ret=$?

	if [ "$ret" -ne 0 ] && printf '%s' "$out" | grep -q 'slow_test timed out after 1s'; then
		print_result "ratchet timeout: counter failure includes pattern name and timeout" 0
	else
		print_result "ratchet timeout: counter failure includes pattern name and timeout" 1 \
			"expected timeout diagnostic, got exit=$ret output=[$out]"
	fi
	return 0
}

test_ratchet_counter_reports_progress_and_value() {
	source_ratchet_helpers
	local out ret=0
	RATCHET_STEP_TIMEOUT_SECONDS=5 out=$(_ratchet_count_with_progress "fast_test" "fast_ratchet_counter" "" 2>&1) || ret=$?

	if [ "$ret" -eq 0 ] && printf '%s' "$out" | grep -q 'Ratchets: counting fast_test' && printf '%s' "$out" | grep -q '7'; then
		print_result "ratchet progress: counter emits start diagnostic and preserves count" 0
	else
		print_result "ratchet progress: counter emits start diagnostic and preserves count" 1 \
			"expected progress diagnostic and count, got exit=$ret output=[$out]"
	fi
	return 0
}

test_missing_return_counter_scans_inventory_once() {
	source_ratchet_helpers
	local tmp_dir count
	tmp_dir=$(mktemp -d)
	printf 'one() {\n\tif true; then\n\t\treturn 0\n\tfi\n\treturn 1\n}\ntwo() {\n\t:\n}\n' >"${tmp_dir}/missing.sh"
	printf 'complete() {\n\treturn 0\n}\n' >"${tmp_dir}/complete.sh"
	count=$(_ratchet_count_missing_return "$tmp_dir")
	if [[ "$count" -eq 1 ]]; then
		print_result "ratchet missing-return counter cannot be masked by extra returns" 0
	else
		print_result "ratchet missing-return counter cannot be masked by extra returns" 1 "count=$count"
	fi
	rm -rf "$tmp_dir"
	return 0
}

write_clean_ratchet_fixture() {
	local target_dir="$1"
	mkdir -p "$target_dir"
	printf 'complete() {\n\treturn 0\n}\n' >"${target_dir}/fixture.sh"
	return 0
}

write_regressed_ratchet_fixture() {
	local pattern_name="$1"
	local target_dir="$2"
	mkdir -p "$target_dir"
	case "$pattern_name" in
	bare_positional_params)
		printf 'uses_arg() {\n\tprintf "%%s\\n" "%s%s"\n\treturn 0\n}\n' '$' '1' >"${target_dir}/fixture.sh"
		;;
	hardcoded_aidevops_path)
		# shellcheck disable=SC2088  # Fixture needs a literal tilde path.
		printf 'path=%s%s\n' '~/' '.aidevops' >"${target_dir}/fixture.sh"
		;;
	broad_catch_or_true)
		printf 'false %s%s\n' '||' ' true' >"${target_dir}/fixture.sh"
		;;
	silent_errors)
		printf 'false %s%s\n' '2>' '/dev/null' >"${target_dir}/fixture.sh"
		;;
	missing_return_files)
		printf 'complete() {\n\treturn 0\n}\nincomplete() {\n\t:\n}\n' >"${target_dir}/fixture.sh"
		;;
	esac
	return 0
}

ratchet_fixture_count() {
	local pattern_name="$1"
	local target_dir="$2"
	case "$pattern_name" in
	bare_positional_params) _ratchet_count_bare_positional "$target_dir" ;;
	hardcoded_aidevops_path) _ratchet_count_hardcoded_path "$target_dir" ;;
	broad_catch_or_true) _ratchet_count_broad_catch "$target_dir" ;;
	silent_errors) _ratchet_count_silent_errors "$target_dir" ;;
	missing_return_files) _ratchet_count_missing_return "$target_dir" ;;
	esac
	return $?
}

test_each_ratchet_blocks_regression_and_allows_improvement() {
	source_ratchet_helpers
	local tmp_dir pattern_name clean_count regressed_count regression_rc improvement_rc
	local patterns=(bare_positional_params hardcoded_aidevops_path broad_catch_or_true silent_errors missing_return_files)
	tmp_dir=$(mktemp -d)
	for pattern_name in "${patterns[@]}"; do
		write_clean_ratchet_fixture "${tmp_dir}/${pattern_name}/clean"
		write_regressed_ratchet_fixture "$pattern_name" "${tmp_dir}/${pattern_name}/regressed"
		clean_count=$(ratchet_fixture_count "$pattern_name" "${tmp_dir}/${pattern_name}/clean")
		regressed_count=$(ratchet_fixture_count "$pattern_name" "${tmp_dir}/${pattern_name}/regressed")
		regression_rc=0
		improvement_rc=0
		_ratchet_check_pattern "$pattern_name" "$regressed_count" "$clean_count" 0 true >/dev/null 2>&1 || regression_rc=$?
		_ratchet_check_pattern "$pattern_name" "$clean_count" "$regressed_count" 0 true >/dev/null 2>&1 || improvement_rc=$?
		if [[ "$clean_count" -eq 0 && "$regressed_count" -eq 1 && "$regression_rc" -eq 1 && "$improvement_rc" -eq 0 ]]; then
			print_result "ratchet delta: ${pattern_name} blocks +1 and permits -1" 0
		else
			print_result "ratchet delta: ${pattern_name} blocks +1 and permits -1" 1 \
				"clean=$clean_count regressed=$regressed_count regression_rc=$regression_rc improvement_rc=$improvement_rc"
		fi
	done
	rm -rf "$tmp_dir"
	return 0
}

test_snapshot_increase_detection_covers_all_counters() {
	source_ratchet_helpers
	local candidate=""
	local detected=0
	local candidates=("1 0 0 0 0" "0 1 0 0 0" "0 0 1 0 0" "0 0 0 1 0" "0 0 0 0 1")
	for candidate in "${candidates[@]}"; do
		_ratchet_counts_increased "$candidate" "0 0 0 0 0" && detected=$((detected + 1))
	done
	if [[ "$detected" -eq 5 ]] && ! _ratchet_counts_increased "0 1 2 3 4" "1 2 3 4 5"; then
		print_result "ratchet migration: every counter increase requires evidence" 0
	else
		print_result "ratchet migration: every counter increase requires evidence" 1 "detected=$detected"
	fi
	return 0
}

test_atomic_write_preserves_baseline_on_invalid_json() {
	source_ratchet_helpers
	local tmp_dir baseline_file before after ret=0
	tmp_dir=$(mktemp -d)
	baseline_file="${tmp_dir}/ratchets.json"
	printf '{"version":1}\n' >"$baseline_file"
	before=$(cksum <"$baseline_file")
	_ratchet_write_json_atomically "$baseline_file" '{invalid' >/dev/null 2>&1 || ret=$?
	after=$(cksum <"$baseline_file")
	if [[ "$ret" -ne 0 && "$before" == "$after" ]]; then
		print_result "ratchet migration: invalid JSON leaves baseline unchanged" 0
	else
		print_result "ratchet migration: invalid JSON leaves baseline unchanged" 1 "ret=$ret before=$before after=$after"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_snapshot_match_detects_idempotent_update() {
	source_ratchet_helpers
	local tmp_dir baseline_file migration rendered ret=0
	tmp_dir=$(mktemp -d)
	baseline_file="${tmp_dir}/ratchets.json"
	migration=$(_ratchet_build_migration_json "fixture migration" "previous-sha" "source-sha" 1 1 "0 1 2 3 4" "1 2 3 4 5")
	rendered=$(_ratchet_build_baseline_json "2026-08-03T00:00:00Z" "source-sha" "tree-sha" "base-sha" \
		"1 2 3 4 5" 1 1 "previous-sha" "2026-04-04T00:00:00Z" "0 1 2 3 4" "$migration")
	printf '%s\n' "$rendered" >"$baseline_file"
	_ratchet_snapshot_matches "$baseline_file" "tree-sha" "base-sha" "1 2 3 4 5" || ret=$?
	if [[ "$ret" -eq 0 ]]; then
		print_result "ratchet migration: identical snapshot is a no-op" 0
	else
		print_result "ratchet migration: identical snapshot is a no-op" 1 "ret=$ret"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_snapshot_increase_is_rejected_without_migration_evidence() {
	source_ratchet_helpers
	local tmp_dir repo_dir baseline_file rendered before after ret=0
	tmp_dir=$(mktemp -d)
	repo_dir="${tmp_dir}/repo"
	baseline_file="${repo_dir}/.agents/configs/ratchets.json"
	mkdir -p "${repo_dir}/.agents/scripts" "${repo_dir}/.agents/configs"
	printf 'safe() {\n\treturn 0\n}\nfalse %s%s\n' '||' ' true' >"${repo_dir}/.agents/scripts/fixture.sh"
	printf '' >"${repo_dir}/.gitignore"
	git -C "$repo_dir" init -q -b main
	git -C "$repo_dir" config user.email "test@example.invalid"
	git -C "$repo_dir" config user.name "Ratchet Test"
	git -C "$repo_dir" add .
	git -C "$repo_dir" commit -q -m "fixture" --no-verify
	rendered=$(_ratchet_build_baseline_json "2026-08-03T00:00:00Z" "source-sha" "tree-sha" "base-sha" \
		"0 0 0 0 0" 1 1 "previous-sha" "2026-04-04T00:00:00Z" "0 0 0 0 0" "null")
	printf '%s\n' "$rendered" >"$baseline_file"
	before=$(cksum <"$baseline_file")
	unset RATCHET_ALLOW_MIGRATION RATCHET_MIGRATION_REASON RATCHET_PREVIOUS_SOURCE_COMMIT
	_ratchet_write_baseline "$baseline_file" "$repo_dir" "0 0 1 0 0" >/dev/null 2>&1 || ret=$?
	after=$(cksum <"$baseline_file")
	if [[ "$ret" -ne 0 && "$before" == "$after" ]]; then
		print_result "ratchet migration: unexplained increase is rejected transactionally" 0
	else
		print_result "ratchet migration: unexplained increase is rejected transactionally" 1 "ret=$ret before=$before after=$after"
	fi
	rm -rf "$tmp_dir"
	return 0
}

main() {
	test_ratchet_counter_times_out_with_diagnostic
	test_ratchet_counter_reports_progress_and_value
	test_missing_return_counter_scans_inventory_once
	test_each_ratchet_blocks_regression_and_allows_improvement
	test_snapshot_increase_detection_covers_all_counters
	test_atomic_write_preserves_baseline_on_invalid_json
	test_snapshot_match_detects_idempotent_update
	test_snapshot_increase_is_rejected_without_migration_evidence

	echo ""
	if [ "$TESTS_FAILED" -eq 0 ]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		return 0
	fi

	printf '%b%d/%d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	return 1
}

main "$@"
