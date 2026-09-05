#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT_BASE="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEST_ROOT_BASE"
TEST_ROOT=$(mktemp -d "${TEST_ROOT_BASE}/pulse-campaign-shadow-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
export LOGFILE="${TEST_ROOT}/pulse.log"
export REPOS_JSON="${TEST_ROOT}/repos.json"
mkdir -p "$HOME" "$AIDEVOPS_TEMP_DIR"
printf '{"initialized_repos":[]}\n' >"$REPOS_JSON"

# shellcheck source=../pulse-campaign-shadow.sh
source "${SOURCE_DIR}/pulse-campaign-shadow.sh"

FETCH_LOG="${TEST_ROOT}/fetch.log"
CAPTURE_RAW="${TEST_ROOT}/captured-raw.json"
CAPTURE_READY="${TEST_ROOT}/captured-ready.json"
CAPTURE_SUCCEEDED="${TEST_ROOT}/captured-succeeded.txt"
LEGACY_JSON='[{"number":2,"createdAt":"2026-01-02T00:00:00Z"},{"number":1,"createdAt":"2026-01-01T00:00:00Z"}]'
FILTERED_JSON='[{"number":1,"createdAt":"2026-01-01T00:00:00Z"}]'

list_dispatchable_issue_candidates_json() {
	local repo_slug="$1"
	local source_limit="$2"
	local raw_snapshot_file="${3:-}"
	local snapshot_status_file="${4:-}"
	local dependency_normalization_mode="${5:-normalize}"
	local completeness_file="${6:-}"
	printf '%s|%s|%s\n' "$repo_slug" "$source_limit" "$dependency_normalization_mode" >>"$FETCH_LOG"
	if [[ -n "$raw_snapshot_file" ]]; then
		printf '%s\n' "$LEGACY_JSON" >"$raw_snapshot_file"
	fi
	if [[ -n "$snapshot_status_file" ]]; then
		printf '1\n' >"$snapshot_status_file"
	fi
	[[ -z "$completeness_file" ]] || printf '1\n' >"$completeness_file"
	printf '%s\n' "$LEGACY_JSON"
	return 0
}

_dispatch_filter_repo_pr_backlog_candidates() {
	local repo_slug="$1"
	local candidates_json="$2"
	: "$repo_slug" "$candidates_json"
	printf '%s\n' "$FILTERED_JSON"
	return 0
}

_pulse_campaign_run_coordinator() {
	local timeout_seconds="$1"
	shift
	: "$timeout_seconds"
	local previous=""
	local argument=""
	for argument in "$@"; do
		if [[ "$previous" == "--issues-file" ]]; then
			cp "$argument" "$CAPTURE_RAW"
		elif [[ "$previous" == "--ready-file" ]]; then
			cp "$argument" "$CAPTURE_READY"
		elif [[ "$previous" == "--source-succeeded" ]]; then
			printf '%s\n' "$argument" >"$CAPTURE_SUCCEEDED"
		fi
		previous="$argument"
	done
	printf '{"repository":{"slug":"example/repository"},"generation":1,"frontier":[{"issueNumber":1}],"lanes":[],"source":{"complete":true}}\n'
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
		return 1
	fi
	return 0
}

export AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED=0
disabled_output=$(pulse_campaign_shadow_candidates_json "example/repository" "$TEST_ROOT" 100 "skip" "$TEST_ROOT/complete")
assert_equal "1" "$(<"$TEST_ROOT/complete")" "disabled shadow preserves source completeness"
assert_equal "$FILTERED_JSON" "$disabled_output" "disabled shadow preserves legacy output"
assert_equal "1" "$(wc -l <"$FETCH_LOG" | tr -d ' ')" "disabled shadow performs one issue fetch"
assert_equal "example/repository|100|skip" "$(<"$FETCH_LOG")" "disabled shadow forwards normalization mode"
if [[ -e "$CAPTURE_RAW" || -e "$CAPTURE_READY" || -e "$CAPTURE_SUCCEEDED" ]]; then
	printf 'FAIL: disabled shadow invoked the campaign planner\n' >&2
	exit 1
fi

: >"$FETCH_LOG"
export AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED=1
enabled_output=$(pulse_campaign_shadow_candidates_json "example/repository" "$TEST_ROOT" 100 normalize "$TEST_ROOT/complete")
assert_equal "1" "$(<"$TEST_ROOT/complete")" "enabled shadow preserves source completeness"
assert_equal "$FILTERED_JSON" "$enabled_output" "enabled shadow preserves legacy output"
assert_equal "1" "$(wc -l <"$FETCH_LOG" | tr -d ' ')" "enabled shadow reuses one issue fetch"
assert_equal "example/repository|100|normalize" "$(<"$FETCH_LOG")" "enabled shadow defaults normalization mode"
assert_equal "$LEGACY_JSON" "$(<"$CAPTURE_RAW")" "planner receives the exact raw snapshot"
assert_equal "$FILTERED_JSON" "$(<"$CAPTURE_READY")" "planner receives the exact filtered-ready set"
assert_equal "1" "$(<"$CAPTURE_SUCCEEDED")" "planner receives successful snapshot provenance"

_pulse_campaign_run_coordinator() {
	local timeout_seconds="$1"
	shift
	: "$timeout_seconds" "$*"
	return 124
}

: >"$FETCH_LOG"
failed_output=$(pulse_campaign_shadow_candidates_json "example/repository" "$TEST_ROOT" 100)
assert_equal "$FILTERED_JSON" "$failed_output" "planner timeout falls back to legacy output"
assert_equal "1" "$(wc -l <"$FETCH_LOG" | tr -d ' ')" "planner failure does not repeat the issue fetch"

# Exercise real discovery/filtering rather than treating a successful wrapper
# exit as proof that an empty result is authoritative.
SCRIPT_DIR="$SOURCE_DIR"
# shellcheck source=../pulse-repo-meta.sh
source "${SOURCE_DIR}/pulse-repo-meta.sh"
SNAPSHOT_MODE=empty
gh_issue_list() {
	case "$SNAPSHOT_MODE" in
	failed) return 1 ;;
	malformed) printf 'null\n' ;;
	truncated) printf '%s\n' '[{"number":1,"labels":[],"assignees":[]}]' ;;
	*) printf '[]\n' ;;
	esac
	return 0
}
_dispatch_filter_repo_pr_backlog_candidates() {
	local repo_slug="$1" candidates_json="$2"
	: "$repo_slug"
	[[ "$SNAPSHOT_MODE" != filter_failed ]] || return 1
	printf '%s\n' "$candidates_json"
	return 0
}
for shadow_enabled in 0 1; do
	AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED="$shadow_enabled"
	for SNAPSHOT_MODE in empty failed malformed truncated filter_failed; do
		filter_status=0
		pulse_campaign_shadow_candidates_json "example/repository" "$TEST_ROOT" 1 skip "$TEST_ROOT/complete" >/dev/null || filter_status=$?
		expected_complete=0
		[[ "$SNAPSHOT_MODE" != empty ]] || expected_complete=1
		assert_equal "$expected_complete" "$(<"$TEST_ROOT/complete")" "real ${SNAPSHOT_MODE} discovery, shadow=${shadow_enabled}"
		if [[ "$SNAPSHOT_MODE" == filter_failed ]]; then
			assert_equal "1" "$filter_status" "failed downstream filter propagates failure"
		fi
	done
done

# Carry the completeness evidence onto the actual ranked candidate snapshot.
# shellcheck source=../pulse-dispatch-engine.sh
source "${SOURCE_DIR}/pulse-dispatch-engine.sh"
check_repo_pulse_schedule() { return 0; }
check_repo_pulse_interval() { return 0; }
update_repo_pulse_timestamp() { return 0; }
gh_issue_list() {
	local repo_slug=""
	while [[ $# -gt 0 ]]; do
		case "$1" in --repo) repo_slug="$2"; shift 2 ;; *) shift ;; esac
	done
	if [[ "$repo_slug" == o/product ]]; then
		[[ "$SNAPSHOT_MODE" != failed ]] || return 1
		printf '[]\n'
	else
		printf '%s\n' '[{"number":1,"title":"work","labels":[],"assignees":[]}]'
	fi
	return 0
}
_dispatch_filter_repo_pr_backlog_candidates() {
	local repo_slug="$1" candidates_json="$2"
	if [[ "$repo_slug" == o/product && "$SNAPSHOT_MODE" == filter_failed ]]; then
		return 1
	fi
	printf '%s\n' "$candidates_json"
	return 0
}
jq -nc --arg path "$TEST_ROOT" '{initialized_repos:[
	{slug:"o/product",path:$path,pulse:true,priority:"product"},
	{slug:"o/tooling",path:$path,pulse:true,priority:"tooling"}]}' >"$REPOS_JSON"
AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED=0
for SNAPSHOT_MODE in empty failed filter_failed; do
	ranked=$(build_ranked_dispatch_candidates_json 100 skip)
	expected_complete=true
	[[ "$SNAPSHOT_MODE" == empty ]] || expected_complete=false
	assert_equal "1" "$(jq length <<<"$ranked")" "ranking retains tooling candidate on ${SNAPSHOT_MODE} product read"
	assert_equal "$expected_complete" "$(jq -r '.[0].product_discovery_complete' <<<"$ranked")" "ranked snapshot retains ${SNAPSHOT_MODE} product evidence"
done

# A failed wrapper cannot resurrect stale successful side-channel evidence.
pulse_campaign_shadow_candidates_json() {
	local repo_slug="$1" repo_path="$2" limit="$3" mode="$4" completeness_file="$5"
	: "$repo_path" "$limit" "$mode"
	printf '1\n' >"$completeness_file"
	[[ "$repo_slug" != o/product ]] || return 1
	printf '%s\n' '[{"number":1,"labels":[],"assignees":[]}]'
	return 0
}
ranked=$(build_ranked_dispatch_candidates_json 100 skip)
assert_equal "false" "$(jq -r '.[0].product_discovery_complete' <<<"$ranked")" "wrapper failure invalidates earlier successful completeness marker"

printf 'PASS: pulse campaign shadow compatibility\n'
