#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-status-default.sh — GH#20714/t2789 regression guard.
#
# Verifies pending creation withholds positive dispatch labels and canonical
# creation retains the historical status:available default.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""
STUB_DIR=""
CREATE_ARGS_FILE=""

pass() {
	local name="$1"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

assert_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "needle='${needle}' not found in '${haystack}'"
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "needle='${needle}' unexpectedly found in '${haystack}'"
	fi
	return 0
}

_teardown() {
	[[ -n "$STUB_DIR" ]] && rm -rf "$STUB_DIR"
	return 0
}

_setup() {
	STUB_DIR=$(mktemp -d)
	trap '_teardown' EXIT
	mkdir -p "${STUB_DIR}/repo" "${STUB_DIR}/home/.aidevops/logs"
	export HOME="${STUB_DIR}/home"
	CREATE_ARGS_FILE="${STUB_DIR}/create-args.txt"

	# shellcheck disable=SC1090
	if ! source "$CLAIM_SCRIPT" >/dev/null 2>&1; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
		exit 1
	fi

	_try_issue_sync_delegation() {
		return 1
	}

	_check_duplicate_issue() {
		return 1
	}

	_extract_github_slug() {
		printf '%s\n' 'owner/repo'
		return 0
	}

	_compose_issue_body() {
		local title="$1"
		local description="$2"
		printf '## %s\n\n%s\n' "$title" "$description"
		return 0
	}

	gh_create_issue() {
		local args="$*"
		printf '%s\n' "$args" >"$CREATE_ARGS_FILE"
		printf '%s\n' 'https://github.com/owner/repo/issues/12345'
		return 0
	}

	_verify_publication_pending_label() {
		return 0
	}

	_auto_assign_issue() {
		return 0
	}

	_interactive_session_auto_claim_new_task() {
		return 0
	}

	_lock_maintainer_issue_at_creation() {
		return 0
	}

	_link_parent_issue_post_create() {
		return 0
	}

	_ensure_todo_entry_written() {
		return 0
	}

	log_warn() {
		return 0
	}

	return 0
}

run_create() {
	local labels="$1"
	local state="${2:-pending}"
	TASK_PUBLICATION_STATE="$state"
	: >"$CREATE_ARGS_FILE"
	create_github_issue "t2789: test default status label" "body" "$labels" "${STUB_DIR}/repo" >/dev/null
	local create_args=""
	create_args=$(<"$CREATE_ARGS_FILE")
	printf '%s\n' "$create_args"
	return 0
}

_setup

args_default=$(run_create 'auto-dispatch,tier:standard,bug')
assert_contains "pending_blocker_added" "$args_default" '--label tier:standard,bug,publication:pending'
assert_not_contains "pending_auto_dispatch_withheld" "$args_default" 'auto-dispatch'
assert_not_contains "pending_status_available_withheld" "$args_default" 'status:available'

args_empty=$(run_create '')
assert_contains "empty_labels_pending_blocker_added" "$args_empty" '--label publication:pending'

args_explicit=$(run_create 'auto-dispatch,status:blocked,tier:standard')
assert_contains "explicit_blocked_status_preserved" "$args_explicit" '--label status:blocked,tier:standard,publication:pending'
assert_not_contains "explicit_status_no_default" "$args_explicit" 'status:available'

args_canonical=$(run_create 'auto-dispatch,tier:standard,bug' canonical)
assert_contains "canonical_status_available_added" "$args_canonical" '--label auto-dispatch,tier:standard,bug,status:available'
assert_not_contains "canonical_has_no_pending_blocker" "$args_canonical" 'publication:pending'

if [[ $FAIL -eq 0 ]]; then
	printf '%sAll claim-task-id status default tests passed%s (%d assertions)\n' "$GREEN" "$NC" "$PASS"
	exit 0
fi

printf '%sClaim-task-id status default tests failed%s (%d failures):%b\n' "$RED" "$NC" "$FAIL" "$ERRORS"
exit 1
