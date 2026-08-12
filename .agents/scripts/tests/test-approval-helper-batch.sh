#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
PARENT_DIR="${SCRIPT_DIR}/.."
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-approval-batch-XXXXXX") || exit 1
CALL_LOG="${TMPROOT}/calls.log"

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
				return 0
			}
			main "$@"
		' _ "$command" "$@" <<<"$confirmation"
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

printf 'PASS approval helper batches targets behind one APPROVE confirmation\n'
exit 0
