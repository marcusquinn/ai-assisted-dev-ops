#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
PARENT_DIR="${SCRIPT_DIR}/.."
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-approval-batch-XXXXXX") || exit 1
CALL_LOG="${TMPROOT}/calls.log"
PROBE_LOG="${TMPROOT}/probes.log"
FAIL_TARGET=""
BATCH_FAILURE_CLASS="isolated-target"

cleanup() {
	local tmp_root="$TMPROOT"
	rm -rf "$tmp_root"
	return 0
}
trap cleanup EXIT

run_batch() {
	local confirmation="$1"
	local command="${2:-issue}"
	shift
	shift
	APPROVAL_HELPER_UNDER_TEST="${PARENT_DIR}/approval-helper.sh" \
		CALL_LOG="$CALL_LOG" \
		PROBE_LOG="$PROBE_LOG" \
		FAIL_TARGET="$FAIL_TARGET" \
		BATCH_FAILURE_CLASS="$BATCH_FAILURE_CLASS" \
		bash -c '
			set -uo pipefail
			# shellcheck disable=SC1090
			source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
			_require_interactive_root() { return 0; }
			_approval_private_key_path() { printf "/test/key"; return 0; }
			_require_approval_key() { return 0; }
			_require_gh_auth() { return 0; }
			_resolve_slug_or_fail() { local candidate="${1:-owner/repo}"; printf "%s" "$candidate"; return 0; }
			_validate_approval_target_kind() { return 0; }
			_fetch_target_title() { local target_type="$1"; local target_number="$2"; printf "Title %s" "$target_number"; [[ -n "$target_type" ]]; return 0; }
			_approve_target_after_confirmation() {
				local target_type="$1"
				local target_number="$2"
				local slug="$3"
				local actual_key="$4"
				printf "%s %s %s %s\n" "$target_type" "$target_number" "$slug" "$actual_key" >>"$CALL_LOG"
				if [[ -n "$FAIL_TARGET" && "$target_number" == "$FAIL_TARGET" ]]; then
					return 1
				fi
				return 0
			}
			_approval_classify_batch_failure() {
				printf "%s\n" "$BATCH_FAILURE_CLASS" >>"$PROBE_LOG"
				printf "%s" "$BATCH_FAILURE_CLASS"
				return 0
			}
			main "$@"
		' _ "$command" "$@" <<<"$confirmation"
	return $?
}

run_classifier() {
	local response="$1"
	local api_rc="$2"
	APPROVAL_HELPER_UNDER_TEST="${PARENT_DIR}/approval-helper.sh" \
		CLASSIFIER_RESPONSE="$response" \
		CLASSIFIER_RC="$api_rc" \
		bash -c '
			set -uo pipefail
			# shellcheck disable=SC1090
			source "$APPROVAL_HELPER_UNDER_TEST" >/dev/null 2>&1
			_gh_secondary_cooldown_preflight() { return 0; }
			_gh_secondary_cooldown_active() { return 1; }
			gh() {
				printf "%s" "$CLASSIFIER_RESPONSE"
				return "$CLASSIFIER_RC"
			}
			_approval_classify_batch_failure
		' 2>/dev/null
	return $?
}

: >"$CALL_LOG"
output=$(run_batch APPROVE issue 101 102 103 owner/repo 2>&1)
rc=$?
[[ "$rc" -eq 0 ]] || {
	printf 'FAIL batch approval returned %s\n%s\n' "$rc" "$output" >&2
	exit 1
}
[[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" == "3" ]] || {
	printf 'FAIL expected three approval calls\n' >&2
	exit 1
}
[[ "$output" == *"Type APPROVE once to confirm all 3 target(s):"* ]] || {
	printf 'FAIL missing one-confirmation batch prompt\n' >&2
	exit 1
}
[[ "$output" == *"issue #101: Title 101"* && "$output" == *"issue #103: Title 103"* ]] || {
	printf 'FAIL batch prompt did not enumerate targets\n' >&2
	exit 1
}

: >"$CALL_LOG"
output=$(run_batch APPROVE batch issue:111 pr:222 issue:333 owner/repo 2>&1)
rc=$?
[[ "$rc" -eq 0 ]] || {
	printf 'FAIL mixed batch approval returned %s\n%s\n' "$rc" "$output" >&2
	exit 1
}
[[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" == "3" ]] || {
	printf 'FAIL expected three mixed approval calls\n' >&2
	exit 1
}
[[ "$output" == *"issue #111: Title 111"* && "$output" == *"pr #222: Title 222"* ]] || {
	printf 'FAIL mixed batch prompt did not enumerate kinds\n' >&2
	exit 1
}

: >"$CALL_LOG"
if run_batch NO issue 201 202 owner/repo >/dev/null 2>&1; then
	printf 'FAIL rejected confirmation returned success\n' >&2
	exit 1
fi
[[ ! -s "$CALL_LOG" ]] || {
	printf 'FAIL rejected confirmation approved targets\n' >&2
	exit 1
}

: >"$CALL_LOG"
if run_batch APPROVE issue 301 301 owner/repo >/dev/null 2>&1; then
	printf 'FAIL duplicate batch target returned success\n' >&2
	exit 1
fi
[[ ! -s "$CALL_LOG" ]] || {
	printf 'FAIL duplicate batch target approved targets\n' >&2
	exit 1
}

: >"$CALL_LOG"
: >"$PROBE_LOG"
FAIL_TARGET="402"
BATCH_FAILURE_CLASS="isolated-target"
if output=$(run_batch APPROVE issue 401 402 403 owner/repo 2>&1); then
	printf 'FAIL isolated target failure returned success\n' >&2
	exit 1
fi
[[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" == "3" ]] || {
	printf 'FAIL isolated failure did not continue through later targets\n' >&2
	exit 1
}
[[ "$(wc -l <"$PROBE_LOG" | tr -d ' ')" == "1" ]] || {
	printf 'FAIL isolated failure did not classify exactly once\n' >&2
	exit 1
}
[[ "$output" == *"1 of 3 approval(s) failed; successful targets remain signed"* ]] || {
	printf 'FAIL isolated failure summary changed unexpectedly\n' >&2
	exit 1
}

: >"$CALL_LOG"
: >"$PROBE_LOG"
FAIL_TARGET="502"
BATCH_FAILURE_CLASS="systemic-transport"
if output=$(run_batch APPROVE issue 501 502 503 504 owner/repo 2>&1); then
	printf 'FAIL systemic transport failure returned success\n' >&2
	exit 1
fi
[[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" == "2" ]] || {
	printf 'FAIL systemic transport failure touched an unattempted target\n' >&2
	exit 1
}
[[ "$(wc -l <"$PROBE_LOG" | tr -d ' ')" == "1" ]] || {
	printf 'FAIL systemic failure did not classify exactly once\n' >&2
	exit 1
}
[[ "$output" == *"1 succeeded and remain signed, 1 failed, 2 unattempted"* ]] || {
	printf 'FAIL systemic failure summary omitted outcome counts\n' >&2
	exit 1
}
[[ "$output" == *"aidevops approve verify"* && "$output" == *"aidevops approve reconcile"* ]] || {
	printf 'FAIL systemic failure summary omitted recovery guidance\n' >&2
	exit 1
}

: >"$CALL_LOG"
: >"$PROBE_LOG"
FAIL_TARGET="601"
BATCH_FAILURE_CLASS="shared-rate-limit"
if run_batch APPROVE issue 601 602 603 owner/repo >/dev/null 2>&1; then
	printf 'FAIL shared rate-limit failure returned success\n' >&2
	exit 1
fi
[[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" == "1" ]] || {
	printf 'FAIL shared rate limit did not stop before untouched targets\n' >&2
	exit 1
}

FAIL_TARGET=""
BATCH_FAILURE_CLASS="isolated-target"

classifier_output=$(run_classifier $'HTTP/2 200\r\n\r\n{}' 0)
[[ "$classifier_output" == "isolated-target" ]] || {
	printf 'FAIL authenticated probe did not classify isolated target failure\n' >&2
	exit 1
}
classifier_output=$(run_classifier $'HTTP/2 503\r\n\r\n{"message":"service unavailable"}' 1)
[[ "$classifier_output" == "systemic-transport" ]] || {
	printf 'FAIL HTTP 503 probe did not classify systemic transport failure\n' >&2
	exit 1
}
classifier_output=$(run_classifier $'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: 123\r\nx-ratelimit-resource: core\r\n\r\n{}' 1)
[[ "$classifier_output" == "shared-rate-limit" ]] || {
	printf 'FAIL exhausted core limit did not classify shared rate-limit failure\n' >&2
	exit 1
}
classifier_output=$(run_classifier "" 1)
[[ "$classifier_output" == "systemic-transport" ]] || {
	printf 'FAIL failed independent probe did not classify systemic transport failure\n' >&2
	exit 1
}

printf 'PASS approval helper batches targets behind one APPROVE confirmation\n'
exit 0
