#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for GH#29719: update help must be observational.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
AIDEVOPS_SH="$REPO_ROOT/aidevops.sh"
TEST_ROOT="$(mktemp -d)"
SENTINEL_LOG="$TEST_ROOT/sentinel.log"
PASS_COUNT=0
FAIL_COUNT=0
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS_COUNT=$((PASS_COUNT + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf 'FAIL %s: %s\n' "$name" "$detail" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

create_blocking_stub() {
	local command_name="$1"
	local stub_path="$TEST_ROOT/bin/$command_name"
	cat >"$stub_path" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >>"$SENTINEL_LOG"
exit 97
STUB
	chmod +x "$stub_path"
	return 0
}

extract_function() {
	local function_name="$1"
	local output_file="$2"
	awk -v function_name="$function_name" '
		$0 ~ "^" function_name "\\(\\)[[:space:]]*\\{" { capturing = 1 }
		capturing {
			print
			line = $0
			open_count = gsub(/\{/, "", line)
			line = $0
			close_count = gsub(/\}/, "", line)
			depth += open_count - close_count
			if (depth == 0) exit
		}
	' "$AIDEVOPS_SH" >"$output_file"
	[[ -s "$output_file" ]]
	return 0
}

run_help() {
	local command_name="$1"
	local help_flag="$2"
	local output=""
	local rc=0
	rm -f "$SENTINEL_LOG"
	output=$(HOME="$TEST_ROOT/home" \
		PATH="$TEST_ROOT/bin:$PATH" \
		SENTINEL_LOG="$SENTINEL_LOG" \
		bash "$AIDEVOPS_SH" "$command_name" --compact "$help_flag" 2>&1) || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		fail "$command_name $help_flag exits successfully" "exit=$rc output=$output"
	elif [[ "$output" != *"Usage: aidevops update [OPTIONS]"* ]] ||
		[[ "$output" != *"--skip-project-sync"* ]] ||
		[[ "$output" != *"--compact"* ]] ||
		[[ "$output" != *"--verbose"* ]]; then
		fail "$command_name $help_flag prints update usage" "$output"
	elif [[ -e "$SENTINEL_LOG" ]]; then
		fail "$command_name $help_flag bypasses every mutation-capable dependency" "$(tr '\n' ' ' <"$SENTINEL_LOG")"
	else
		pass "$command_name $help_flag is side-effect-free"
	fi
	return 0
}

UPDATE_CALLS=0
UPDATE_ARGS=""
UNREGISTERED_CALLS=0
_main_check_unregistered() {
	UNREGISTERED_CALLS=$((UNREGISTERED_CALLS + 1))
	return 0
}

cmd_update() {
	UPDATE_CALLS=$((UPDATE_CALLS + 1))
	UPDATE_ARGS="$*"
	return 0
}

test_normal_dispatch() {
	local command_name="$1"
	UPDATE_CALLS=0
	UPDATE_ARGS=""
	UNREGISTERED_CALLS=0
	main "$command_name" --compact
	if [[ "$UPDATE_CALLS" -eq 1 && "$UPDATE_ARGS" == "--compact" && "$UNREGISTERED_CALLS" -eq 1 ]]; then
		pass "$command_name without help preserves update dispatch"
	else
		fail "$command_name without help preserves update dispatch" \
			"update_calls=$UPDATE_CALLS update_args=$UPDATE_ARGS unregistered_calls=$UNREGISTERED_CALLS"
	fi
	return 0
}

main() {
	mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home"
	local command_name
	for command_name in git jq curl brew npm bun pip python python3; do
		create_blocking_stub "$command_name"
	done

	run_help update --help
	run_help upgrade --help
	run_help u -h
	run_help update help
	extract_function main "$TEST_ROOT/main.sh"
	# shellcheck source=/dev/null
	source "$TEST_ROOT/main.sh"
	test_normal_dispatch update
	test_normal_dispatch upgrade
	test_normal_dispatch u

	printf '\nRan %d tests, %d failed.\n' "$((PASS_COUNT + FAIL_COUNT))" "$FAIL_COUNT"
	[[ "$FAIL_COUNT" -eq 0 ]] || return 1
	return 0
}

main "$@"
