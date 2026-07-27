#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Release-only mode, baseline seeding, and CLI registration coverage.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/upstream-watch-helper.sh"

PASS=0
FAIL=0

check_equal() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		PASS=$((PASS + 1))
		printf 'PASS: %s\n' "$name"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
	fi
	return 0
}

log_line_count() {
	local log_file="$1"
	wc -l <"$log_file" | tr -d '[:space:]'
	return 0
}

TMP="$(mktemp -d -t upstream-watch-mode.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export SCRIPT_DIR="$SCRIPTS_DIR"
export RED="" YELLOW="" BLUE="" GREEN="" CYAN="" NC=""

RELEASE_PROBE_LOG="${TMP}/release-probes.log"
COMMIT_PROBE_LOG="${TMP}/commit-probes.log"
QUEUE_LOG="${TMP}/queue.log"
OUTPUT_LOG="${TMP}/output.log"

_log_warn() {
	return 0
}

_queue_upstream_update_issue() {
	local slug="$1"
	local kind="$2"
	local old_value="$3"
	local new_value="$4"
	local entry_json="$5"
	local compact_entry
	compact_entry=$(printf '%s' "$entry_json" | jq -c '.')
	printf '%s|%s|%s|%s|%s\n' "$slug" "$kind" "$old_value" "$new_value" "$compact_entry" >>"$QUEUE_LOG"
	return 0
}

# shellcheck source=../upstream-watch-helper-check.sh
source "${SCRIPTS_DIR}/upstream-watch-helper-check.sh"

_probe_github_release() {
	printf 'release\n' >>"$RELEASE_PROBE_LOG"
	printf '%s' "${TEST_RELEASE_JSON:-}"
	return "${TEST_RELEASE_RC:-0}"
}

_probe_github_commit() {
	printf 'commit\n' >>"$COMMIT_PROBE_LOG"
	printf '%s' "${TEST_COMMIT_JSON:-}"
	return "${TEST_COMMIT_RC:-0}"
}

_show_release_diff() {
	return 0
}

_show_commit_diff() {
	return 0
}

reset_case() {
	: >"$RELEASE_PROBE_LOG"
	: >"$COMMIT_PROBE_LOG"
	: >"$QUEUE_LOG"
	: >"$OUTPUT_LOG"
	_check_updates_found=0
	_check_had_probe_failure=false
	TEST_RELEASE_RC=0
	TEST_COMMIT_RC=0
	TEST_RELEASE_JSON='{"tag_name":"v1","name":"v1","published_at":"2026-07-27T00:00:00Z"}'
	TEST_COMMIT_JSON='{"sha":"new0000abcdef","commit":{"committer":{"date":"2026-07-27T00:00:00Z"}}}'
	return 0
}

# Default entries retain release-and-commit monitoring.
reset_case
default_config='{"repos":[{"slug":"owner/default","relevance":"fixture"}]}'
_check_state='{"last_check":"","repos":{"owner/default":{"last_release_seen":"v1","last_commit_seen":"old0000","last_checked":"","updates_pending":0}},"non_github":{}}'
_check_single_github_repo "owner/default" "$default_config" "2026-07-28T00:00:00Z" false >"$OUTPUT_LOG"
check_equal "default mode probes commits" "1" "$(log_line_count "$COMMIT_PROBE_LOG")"
check_equal "default mode marks commit update pending" "1" "$(printf '%s' "$_check_state" | jq -r '.repos["owner/default"].updates_pending')"
check_equal "default mode queues commit review" "commit" "$(cut -d '|' -f 2 "$QUEUE_LOG")"

# Release-only entries ignore commit-only movement and avoid the commit API.
reset_case
release_config='{"repos":[{"slug":"owner/releases","watch_mode":"releases","relevance":"fixture"}]}'
_check_state='{"last_check":"","repos":{"owner/releases":{"last_release_seen":"v1","last_commit_seen":"old0000","last_checked":"","updates_pending":0}},"non_github":{}}'
_check_single_github_repo "owner/releases" "$release_config" "2026-07-28T00:00:00Z" true >"$OUTPUT_LOG"
check_equal "release-only mode skips commit probe" "0" "$(log_line_count "$COMMIT_PROBE_LOG")"
check_equal "release-only mode ignores commit-only movement" "0" "$(printf '%s' "$_check_state" | jq -r '.repos["owner/releases"].updates_pending')"
check_equal "release-only mode preserves commit state" "old0000" "$(printf '%s' "$_check_state" | jq -r '.repos["owner/releases"].last_commit_seen')"
check_equal "release-only mode queues nothing without a release" "0" "$(log_line_count "$QUEUE_LOG")"

# A release change still creates review work without a commit probe.
reset_case
TEST_RELEASE_JSON='{"tag_name":"v2","name":"v2","published_at":"2026-07-28T00:00:00Z"}'
_check_state='{"last_check":"","repos":{"owner/releases":{"last_release_seen":"v1","last_commit_seen":"old0000","last_checked":"","updates_pending":0}},"non_github":{}}'
_check_single_github_repo "owner/releases" "$release_config" "2026-07-28T00:00:00Z" true >"$OUTPUT_LOG"
check_equal "release-only mode detects a release" "1" "$(printf '%s' "$_check_state" | jq -r '.repos["owner/releases"].updates_pending')"
check_equal "release-only mode queues release review" "release" "$(cut -d '|' -f 2 "$QUEUE_LOG")"
check_equal "release detection still skips commit probe" "0" "$(log_line_count "$COMMIT_PROBE_LOG")"

# A committed baseline prevents an alert when runtime state is absent.
reset_case
baseline_config='{"repos":[{"slug":"owner/baseline","watch_mode":"releases","baseline_release":"v1","baseline_commit":"a7509a7fa6c467e"}]}'
_check_state='{"last_check":"","repos":{},"non_github":{}}'
_check_single_github_repo "owner/baseline" "$baseline_config" "2026-07-28T00:00:00Z" false >"$OUTPUT_LOG"
check_equal "baseline seeds reviewed release" "v1" "$(printf '%s' "$_check_state" | jq -r '.repos["owner/baseline"].last_release_seen')"
check_equal "baseline stores compact provenance commit" "a7509a7" "$(printf '%s' "$_check_state" | jq -r '.repos["owner/baseline"].last_commit_seen')"
check_equal "baseline avoids historical alert" "0" "$(log_line_count "$QUEUE_LOG")"

# Invalid committed modes fail the overall check without probing upstream.
reset_case
invalid_config='{"repos":[{"slug":"owner/invalid","watch_mode":"everything"}]}'
_check_state='{"last_check":"","repos":{},"non_github":{}}'
_check_single_github_repo "owner/invalid" "$invalid_config" "2026-07-28T00:00:00Z" false >"$OUTPUT_LOG" 2>&1
check_equal "invalid mode marks probe failure" "true" "$_check_had_probe_failure"
check_equal "invalid mode avoids release probe" "0" "$(log_line_count "$RELEASE_PROBE_LOG")"
check_equal "invalid mode avoids commit probe" "0" "$(log_line_count "$COMMIT_PROBE_LOG")"

# Source the public helper and isolate add behaviour from network/filesystem state.
# shellcheck source=../upstream-watch-helper.sh
source "$HELPER"

WRITTEN_CONFIG=""
WRITTEN_STATE=""

_check_prerequisites() {
	return 0
}

_read_config() {
	printf '%s' '{"repos":[],"non_github_upstreams":[]}'
	return 0
}

_write_config() {
	local config_json="$1"
	WRITTEN_CONFIG="$config_json"
	return 0
}

_read_state() {
	printf '%s' '{"last_check":"","repos":{},"non_github":{}}'
	return 0
}

_write_state() {
	local state_json="$1"
	WRITTEN_STATE="$state_json"
	return 0
}

_now_iso() {
	printf '%s' '2026-07-28T00:00:00Z'
	return 0
}

_log_info() {
	return 0
}

gh() {
	local command="$1"
	local endpoint="$2"
	if [[ "$command" != "api" ]]; then
		return 1
	fi
	if [[ "$endpoint" == */releases/latest ]]; then
		printf '%s\n' '{"tag_name":"v9","published_at":"2026-07-28T00:00:00Z","name":"v9"}'
	elif [[ "$endpoint" == *'/commits?per_page=1' ]]; then
		printf '%s\n' 'abcdef0123456789'
	elif [[ "$endpoint" == repos/* ]]; then
		printf '%s\n' '{"description":"Fixture repository","stargazers_count":1,"pushed_at":"2026-07-28T00:00:00Z","default_branch":"main"}'
	else
		return 1
	fi
	return 0
}

cmd_add owner/cli fixture releases >"${TMP}/cli.out" 2>&1
check_equal "add stores release-only mode" "releases" "$(printf '%s' "$WRITTEN_CONFIG" | jq -r '.repos[] | select(.slug == "owner/cli") | .watch_mode')"
check_equal "add stores release baseline" "v9" "$(printf '%s' "$WRITTEN_CONFIG" | jq -r '.repos[] | select(.slug == "owner/cli") | .baseline_release')"
check_equal "add stores commit baseline" "abcdef0123456789" "$(printf '%s' "$WRITTEN_CONFIG" | jq -r '.repos[] | select(.slug == "owner/cli") | .baseline_commit')"
check_equal "add seeds runtime release state" "v9" "$(printf '%s' "$WRITTEN_STATE" | jq -r '.repos["owner/cli"].last_release_seen')"

if cmd_add owner/bad "" everything >"${TMP}/invalid.out" 2>&1; then
	invalid_rc="0"
else
	invalid_rc="$?"
fi
check_equal "add rejects invalid watch mode" "1" "$invalid_rc"

WRITTEN_CONFIG=""
WRITTEN_STATE=""
main add owner/parser --mode releases --relevance "parser fixture" >"${TMP}/parser.out" 2>&1
check_equal "CLI parser forwards slug" "owner/parser" "$(printf '%s' "$WRITTEN_CONFIG" | jq -r '.repos[0].slug')"
check_equal "CLI parser forwards relevance" "parser fixture" "$(printf '%s' "$WRITTEN_CONFIG" | jq -r '.repos[0].relevance')"
check_equal "CLI parser forwards explicit mode" "releases" "$(printf '%s' "$WRITTEN_CONFIG" | jq -r '.repos[0].watch_mode')"

WRITTEN_CONFIG=""
WRITTEN_STATE=""
main add owner/shortcut --releases-only >"${TMP}/shortcut.out" 2>&1
check_equal "CLI releases-only shortcut is supported" "releases" "$(printf '%s' "$WRITTEN_CONFIG" | jq -r '.repos[0].watch_mode')"

if [[ "$FAIL" -gt 0 ]]; then
	printf '%s test(s) failed, %s passed\n' "$FAIL" "$PASS" >&2
	exit 1
fi

printf '%s test(s) passed\n' "$PASS"
