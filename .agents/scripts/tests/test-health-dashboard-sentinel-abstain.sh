#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#24072: if the health issue resolver emits the
# query-failed sentinel, the orchestrator must abstain for this pulse without
# clearing the cached issue number or calling downstream issue update helpers.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TMP=$(mktemp -d -t health-sentinel.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export HOME="${TMP}/home"
export LOGFILE="${TMP}/stats.log"
mkdir -p "${HOME}/.aidevops/logs"
: >"$LOGFILE"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# shellcheck source=../portable-stat.sh
source "${SCRIPTS_DIR}/portable-stat.sh"
# shellcheck source=../stats-health-dashboard.sh
source "${SCRIPTS_DIR}/stats-health-dashboard.sh"

CALLS_FILE="${TMP}/calls.log"
: >"$CALLS_FILE"

record_call() {
	local name="$1"
	printf '%s\n' "$name" >>"$CALLS_FILE"
	return 0
}

# shellcheck disable=SC2317
_resolve_current_gh_login_or_fallback() {
	printf '%s' "alice"
	return 0
}

# shellcheck disable=SC2317
_get_runner_role() {
	local runner_user="$1"
	local repo_slug="$2"
	[[ -n "$runner_user" && -n "$repo_slug" ]] || return 1
	printf '%s' "supervisor"
	return 0
}

# shellcheck disable=SC2317
_dashboard_identity_aliases() {
	local runner_user="$1"
	printf '%s\n' "$runner_user"
	return 0
}

# shellcheck disable=SC2317
_resolve_runner_role_config() {
	local runner_user="$1"
	local runner_role="$2"
	[[ -n "$runner_user" && -n "$runner_role" ]] || return 1
	printf '%s' "[Supervisor:alice]|supervisor|0E8A16|Supervisor runner|Supervisor"
	return 0
}

# shellcheck disable=SC2317
_sanitize_runner_identity_for_cache() {
	local runner_user="$1"
	printf '%s' "$runner_user"
	return 0
}

# shellcheck disable=SC2317
_check_health_issue_activity_guard() {
	return 0
}

# shellcheck disable=SC2317
_resolve_health_issue_number() {
	record_call "resolve"
	printf '%s' "$_HEALTH_QUERY_FAILED_SENTINEL"
	return 0
}

# shellcheck disable=SC2317
_periodic_health_issue_dedup() {
	record_call "dedup"
	return 0
}

# shellcheck disable=SC2317
_ensure_health_issue_pinned() {
	record_call "pin"
	return 0
}

# shellcheck disable=SC2317
_assemble_health_issue_body() {
	record_call "assemble"
	printf '%s' "body"
	return 0
}

# shellcheck disable=SC2317
_update_health_issue_title() {
	record_call "title"
	return 0
}

# shellcheck disable=SC2317
privacy_redact_public_text_from_inventory() {
	local body="$1"
	record_call "sanitize"
	printf '%s' "${body//\/Users\/example\/Git\/private-project/[local-path]}"
	return 0
}

# shellcheck disable=SC2317
gh_issue_edit_safe() {
	local health_issue_number="$1"
	shift
	record_call "edit:${health_issue_number}:$*"
	return 0
}

# shellcheck disable=SC2317
_gh_with_timeout() {
	local mode="$1"
	shift
	"$@"
	return $?
}

cache_file="${HOME}/.aidevops/logs/health-issue-alice-owner-repo"
printf '%s\n' "42" >"$cache_file"

_update_health_issue_for_repo "owner/repo" "${TMP}/repo" "" "" ""

cache_value=$(<"$cache_file")
if [[ "$cache_value" == "42" ]]; then
	pass "preserves cached issue number when resolver emits sentinel"
else
	fail "preserves cached issue number when resolver emits sentinel" "cache contains '${cache_value}'"
fi

if [[ "$(<"$CALLS_FILE")" == "resolve" ]]; then
	pass "abstains immediately after resolver sentinel"
else
	fail "abstains immediately after resolver sentinel" "expected only 'resolve', but got: $(tr '\n' ' ' <"$CALLS_FILE")"
fi

: >"$CALLS_FILE"
_update_health_issue_body_or_fail "42" "owner/repo" "Local source: /Users/example/Git/private-project"
calls=$(<"$CALLS_FILE")
if [[ "$calls" == *"sanitize"* && "$calls" == *"--body Local source: [local-path]"* && "$calls" != *"private-project"* ]]; then
	pass "sanitizes dashboard body before public issue edit"
else
	fail "sanitizes dashboard body before public issue edit" "calls=${calls}"
fi

if ((TESTS_FAILED > 0)); then
	printf '\n  %s%d failed%s of %d tests\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_NC" "$TESTS_RUN"
	exit 1
fi

printf '\n  %sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
exit 0
