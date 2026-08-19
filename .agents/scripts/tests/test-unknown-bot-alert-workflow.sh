#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/unknown-bot-alert.yml"
KNOWN_BOTS_FILE="$REPO_ROOT/.agents/configs/known-bots.txt"

pass_count=0
fail_count=0

print_result() {
	local name="$1"
	local status="$2"
	local detail="${3:-}"
	if [[ "$status" -eq 0 ]]; then
		printf 'ok - %s\n' "$name"
		pass_count=$((pass_count + 1))
		return 0
	fi
	printf 'not ok - %s' "$name"
	if [[ -n "$detail" ]]; then
		printf ' (%s)' "$detail"
	fi
	printf '\n'
	fail_count=$((fail_count + 1))
	return 1
}

assert_contains() {
	local name="$1"
	local needle="$2"
	if grep -Fq -- "$needle" "$WORKFLOW_FILE"; then
		print_result "$name" 0
		return 0
	fi
	print_result "$name" 1 "missing: $needle"
	return 1
}

assert_not_contains() {
	local name="$1"
	local needle="$2"
	if grep -Fq -- "$needle" "$WORKFLOW_FILE"; then
		print_result "$name" 1 "unexpected: $needle"
		return 1
	fi
	print_result "$name" 0
	return 0
}

test_comment_body_is_data_not_shell_source() {
	assert_contains "comment body is passed via environment" "COMMENT_BODY: \${{ github.event.comment.body }}"
	assert_contains "body length uses printf on env var" "BODY_LEN=\$(printf '%s' \"\$COMMENT_BODY\" | wc -c | tr -d ' ')"
	assert_not_contains "workflow does not inline raw comment body into run script" "echo -n \"\${{ github.event.comment.body }}\""
	return 0
}

test_missing_unknown_bot_label_does_not_break_workflow() {
	assert_contains "dedup search does not require unknown-bot label" "--search \"unknown bot: \$BOT_LOGIN in:title\""
	assert_not_contains "dedup no longer filters by missing unknown-bot label" '--label "unknown-bot"'
	assert_contains "issue creation builds optional labels" 'label_args=()'
	assert_contains "issue creation sends body through body-file" "--body-file \"\$body_file\""
	return 0
}

test_generated_guidance_targets_current_docs() {
	assert_contains "workflow points at current rule document" "reference/gh-command-discipline.md rule #8c"
	assert_contains "workflow points at known bots config" ".agents/configs/known-bots.txt"
	assert_not_contains "workflow does not tell workers to edit placeholder build prompt" "EDIT: .agents/prompts/build.txt"
	assert_not_contains "workflow does not cite obsolete build token rules" "build.txt rules #8a-#8d"
	return 0
}

test_coderabbit_bot_is_known() {
	if grep -Fxq 'coderabbitai[bot]' "$KNOWN_BOTS_FILE"; then
		print_result "coderabbit bot is in known bots config" 0
	else
		print_result "coderabbit bot is in known bots config" 1 "missing from $KNOWN_BOTS_FILE"
		return 1
	fi

	assert_contains "coderabbit bot is in workflow fallback" '"coderabbitai[bot]"'
	return 0
}

test_sonarqubecloud_bot_is_known() {
	if grep -Fxq 'sonarqubecloud[bot]' "$KNOWN_BOTS_FILE"; then
		print_result "sonarqubecloud bot is in known bots config" 0
	else
		print_result "sonarqubecloud bot is in known bots config" 1 "missing from $KNOWN_BOTS_FILE"
		return 1
	fi

	assert_contains "sonarqubecloud bot is in workflow fallback" '"sonarqubecloud[bot]"'
	return 0
}

test_codacy_production_bot_is_known() {
	if grep -Fxq 'codacy-production[bot]' "$KNOWN_BOTS_FILE"; then
		print_result "codacy-production bot is in known bots config" 0
	else
		print_result "codacy-production bot is in known bots config" 1 "missing from $KNOWN_BOTS_FILE"
		return 1
	fi

	assert_contains "codacy-production bot is in workflow fallback" '"codacy-production[bot]"'
	return 0
}

main() {
	if [[ ! -f "$WORKFLOW_FILE" ]]; then
		print_result "workflow exists" 1 "$WORKFLOW_FILE"
		return 1
	fi

	test_comment_body_is_data_not_shell_source
	test_missing_unknown_bot_label_does_not_break_workflow
	test_generated_guidance_targets_current_docs
	test_coderabbit_bot_is_known
	test_sonarqubecloud_bot_is_known
	test_codacy_production_bot_is_known

	printf '\nPassed: %d, Failed: %d\n' "$pass_count" "$fail_count"
	if [[ "$fail_count" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
