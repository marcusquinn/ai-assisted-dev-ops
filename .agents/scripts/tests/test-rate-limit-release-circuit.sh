#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t3570 / GH#23102: repeated transient rate-limit claim
# releases should trip a per-issue circuit breaker, post one consolidated audit
# comment, and suppress duplicate CLAIM_RELEASED comment storms while active.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
CALL_LOG="${TMP_HOME}/gh-calls.log"
COMMENTS_JSON="${TMP_HOME}/comments.json"
: >"$CALL_LOG"
printf '[]\n' >"$COMMENTS_JSON"

cleanup() {
	rm -rf "$TMP_HOME"
	return 0
}
trap cleanup EXIT

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message" >>"$CALL_LOG"
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message" >>"$CALL_LOG"
	return 0
}

clear_active_status_on_release() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name="$3"
	printf 'CLEAR issue=%s repo=%s runner=%s\n' "$issue_number" "$repo_slug" "$runner_name" >>"$CALL_LOG"
	return 0
}

append_comment_fixture() {
	local created_at="$1"
	local body="$2"
	local tmp="${COMMENTS_JSON}.tmp"
	jq --arg created_at "$created_at" --arg body "$body" \
		'. + [{created_at: $created_at, body: $body}]' \
		"$COMMENTS_JSON" >"$tmp"
	mv "$tmp" "$COMMENTS_JSON"
	return 0
}

reset_case() {
	: >"$CALL_LOG"
	printf '[]\n' >"$COMMENTS_JSON"
	unset AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_OVERRIDE 2>/dev/null || true
	export AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_THRESHOLD=3
	export AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_LOOKBACK_SECS=86400
	export AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_COOLDOWN_SECS=600
	return 0
}

gh() {
	local cmd="${1:-}"
	shift || true
	case "$cmd" in
	api)
		local path="${1:-}"
		shift || true
		local method="GET" body="" prev=""
		local arg
		for arg in "$@"; do
			if [[ "$prev" == "--method" ]]; then
				method="$arg"
			fi
			if [[ "$arg" == body=* ]]; then
				body="${arg#body=}"
			fi
			prev="$arg"
		done
		printf 'API method=%s path=%s body=%s\n' "$method" "$path" "$body" >>"$CALL_LOG"
		if [[ "$method" == "POST" ]]; then
			append_comment_fixture "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$body"
			printf '{}\n'
		else
			jq -c '.' "$COMMENTS_JSON"
		fi
		;;
	issue)
		local subcmd="${1:-}"
		shift || true
		if [[ "$subcmd" == "unlock" ]]; then
			local issue_number="${1:-}"
			shift || true
			local repo_slug="" prev=""
			local arg
			for arg in "$@"; do
				if [[ "$prev" == "--repo" ]]; then
					repo_slug="$arg"
				fi
				prev="$arg"
			done
			printf 'UNLOCK issue=%s repo=%s\n' "$issue_number" "$repo_slug" >>"$CALL_LOG"
		fi
		;;
	*) ;;
	esac
	return 0
}

# shellcheck source=../headless-runtime-failure.sh
source "${SCRIPT_DIR}/headless-runtime-failure.sh"

# This focused test exercises release-circuit behavior, not repository
# authority discovery. Keep the managed-repository precondition deterministic.
aidevops_can_manage_repo_issue_state() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]]
	return $?
}

export DISPATCH_REPO_SLUG="owner/repo"

iso_offset() {
	local seconds_delta="$1"
	local epoch
	epoch=$(($(date +%s) + seconds_delta))
	date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

epoch_offset() {
	local seconds_delta="$1"
	printf '%s\n' "$(($(date +%s) + seconds_delta))"
	return 0
}

test_threshold_posts_audit_and_release() {
	reset_case
	append_comment_fixture "$(iso_offset -120)" '<!-- ops:start -->
CLAIM_RELEASED reason=rate_limit_transient runner=test ts=x
<!-- ops:end -->'
	append_comment_fixture "$(iso_offset -60)" '<!-- ops:start -->
CLAIM_RELEASED reason=rate_limit_transient runner=test ts=x
<!-- ops:end -->'

	_release_dispatch_claim "issue-12345" "rate_limit_transient" "1" "0"

	if grep -q 'RATE_LIMIT_RELEASE_CIRCUIT active=true count=3' "$CALL_LOG" && \
		grep -q 'CLAIM_RELEASED reason=rate_limit_transient' "$CALL_LOG"; then
		printf 'PASS threshold crossing posts consolidated audit and current release\n'
		return 0
	fi
	printf 'FAIL threshold crossing missing audit or release\n'
	sed 's/^/  /' "$CALL_LOG"
	return 1
}

test_active_circuit_suppresses_duplicate_release() {
	reset_case
	local next_epoch
	next_epoch=$(epoch_offset 600)
	append_comment_fixture "$(iso_offset -30)" "<!-- ops:start -->
<!-- rate-limit-release-circuit-breaker issue=12345 count=3 next_epoch=${next_epoch} -->
RATE_LIMIT_RELEASE_CIRCUIT active=true count=3
<!-- ops:end -->"

	_release_dispatch_claim "issue-12345" "rate_limit_transient" "1" "0"

	if grep -q 'suppressing duplicate CLAIM_RELEASED' "$CALL_LOG" && \
		! grep -q 'CLAIM_RELEASED reason=rate_limit_transient' "$CALL_LOG" && \
		grep -q 'CLEAR issue=12345 repo=owner/repo' "$CALL_LOG" && \
		grep -q 'UNLOCK issue=12345 repo=owner/repo' "$CALL_LOG"; then
		printf 'PASS active circuit suppresses duplicate release while cleaning state\n'
		return 0
	fi
	printf 'FAIL active circuit did not suppress duplicate release cleanly\n'
	sed 's/^/  /' "$CALL_LOG"
	return 1
}

test_cooldown_expiry_allows_release() {
	reset_case
	local next_epoch
	next_epoch=$(epoch_offset -60)
	append_comment_fixture "$(iso_offset -900)" "<!-- rate-limit-release-circuit-breaker issue=12345 count=3 next_epoch=${next_epoch} -->"

	_release_dispatch_claim "issue-12345" "rate_limit_transient" "1" "0"

	if grep -q 'CLAIM_RELEASED reason=rate_limit_transient' "$CALL_LOG"; then
		printf 'PASS expired circuit allows release after cooldown\n'
		return 0
	fi
	printf 'FAIL expired circuit did not allow release\n'
	sed 's/^/  /' "$CALL_LOG"
	return 1
}

test_non_rate_limit_release_unchanged() {
	reset_case
	local next_epoch
	next_epoch=$(epoch_offset 600)
	append_comment_fixture "$(iso_offset -30)" "<!-- rate-limit-release-circuit-breaker issue=12345 count=3 next_epoch=${next_epoch} -->"

	_release_dispatch_claim "issue-12345" "worker_failed" "1" "0"

	if grep -q 'CLAIM_RELEASED reason=worker_failed' "$CALL_LOG" && \
		! grep -q 'suppressing duplicate CLAIM_RELEASED' "$CALL_LOG"; then
		printf 'PASS non-rate-limit release handling unchanged\n'
		return 0
	fi
	printf 'FAIL non-rate-limit release path changed unexpectedly\n'
	sed 's/^/  /' "$CALL_LOG"
	return 1
}

test_threshold_posts_audit_and_release
test_active_circuit_suppresses_duplicate_release
test_cooldown_expiry_allows_release
test_non_rate_limit_release_unchanged
