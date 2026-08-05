#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for Buzz Desktop OpenCode ACP compatibility reconciliation.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/../.." && pwd)"
HELPER="${REPO_ROOT}/.agents/scripts/buzz-desktop-helper.sh"
SETUP_FILE="${REPO_ROOT}/setup.sh"
CLI_FILE="${REPO_ROOT}/aidevops.sh"
TEST_ROOT=$(mktemp -d)
TEST_HOME="${TEST_ROOT}/home"
TEST_APP="${TEST_ROOT}/Buzz.app"
TEST_STORE="${TEST_HOME}/Library/Application Support/xyz.block.buzz.app/agents/managed-agents.json"
TEST_STATE_DIR="${TEST_HOME}/.aidevops/state"
TEST_STATE_FILE="${TEST_STATE_DIR}/buzz-opencode-acp-fix.json"
TEST_BACKUP_DIR="${TEST_HOME}/.aidevops/buzz-backups"
TEST_LOCK_DIR="${TEST_HOME}/.aidevops/locks/buzz-opencode-acp-fix.lock"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

pass() {
	local name="$1"
	printf '[PASS] %s\n' "$name"
	PASS_COUNT=$((PASS_COUNT + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf '[FAIL] %s — %s\n' "$name" "$detail"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

assert_eq() {
	local name="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected '${expected}', got '${actual}'"
	fi
	return 0
}

assert_contains() {
	local name="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == *"$expected"* ]]; then
		pass "$name"
	else
		fail "$name" "missing '${expected}' in '${actual}'"
	fi
	return 0
}

assert_file_exists() {
	local name="$1"
	local path="$2"
	if [[ -f "$path" && ! -L "$path" ]]; then
		pass "$name"
	else
		fail "$name" "expected regular file at ${path}"
	fi
	return 0
}

assert_file_absent() {
	local name="$1"
	local path="$2"
	if [[ ! -e "$path" && ! -L "$path" ]]; then
		pass "$name"
	else
		fail "$name" "unexpected path at ${path}"
	fi
	return 0
}

file_hash() {
	local path="$1"
	shasum -a 256 "$path" | cut -d ' ' -f 1
	return 0
}

write_store() {
	mkdir -p "${TEST_STORE%/*}"
	cat >"$TEST_STORE" <<'JSON'
[
  {
    "pubkey": "pub-empty-path",
    "name": "Empty path",
    "agent_command": "/opt/homebrew/bin/opencode",
    "agent_command_override": "/opt/homebrew/bin/opencode",
    "agent_args": [],
    "private_key_nsec": "fixture-secret-never-output",
    "unknown": {"preserve": true}
  },
  {
    "pubkey": "pub-missing-args",
    "name": "Missing args",
    "agent_command": "opencode",
    "agent_command_override": "opencode"
  },
  {
    "pubkey": "pub-custom",
    "name": "Custom args",
    "agent_command": "/usr/local/bin/opencode",
    "agent_command_override": "/usr/local/bin/opencode",
    "agent_args": ["acp", "--cwd", "/project"]
  },
  {
    "pubkey": "pub-other",
    "name": "Other harness",
    "agent_command": "/usr/local/bin/goose",
    "agent_args": []
  },
  {
    "pubkey": null,
    "name": "Built-in harness",
    "is_builtin": true,
    "agent_command": "builtin",
    "agent_args": [],
    "unknown": {"preserve": true}
  }
]
JSON
	chmod 600 "$TEST_STORE"
	return 0
}

reset_fixture() {
	rm -rf "$TEST_HOME" "$TEST_APP"
	mkdir -p "$TEST_HOME" "$TEST_APP"
	write_store
	return 0
}

run_helper() {
	HOME="$TEST_HOME" \
		AIDEVOPS_BUZZ_PLATFORM_OVERRIDE="${TEST_PLATFORM:-Darwin}" \
		AIDEVOPS_BUZZ_VERSION_OVERRIDE="${TEST_VERSION:-0.5.4}" \
		AIDEVOPS_BUZZ_RUNNING_OVERRIDE="${TEST_RUNNING:-false}" \
		AIDEVOPS_BUZZ_APP_PATH="$TEST_APP" \
		AIDEVOPS_BUZZ_STORE_PATH="$TEST_STORE" \
		AIDEVOPS_BUZZ_STATE_DIR="$TEST_STATE_DIR" \
		AIDEVOPS_BUZZ_STATE_FILE="$TEST_STATE_FILE" \
		AIDEVOPS_BUZZ_BACKUP_DIR="$TEST_BACKUP_DIR" \
		AIDEVOPS_BUZZ_LOCK_DIR="$TEST_LOCK_DIR" \
		bash "$HELPER" "$@"
	return $?
}

test_status_reports_eligible_records() {
	reset_fixture
	local output=""
	output=$(run_helper status)
	assert_contains "status identifies affected Buzz release" "$output" "Buzz Desktop 0.5.4"
	assert_contains "status counts empty-argument OpenCode records" "$output" "2 OpenCode record(s) need remediation"
	return 0
}

test_apply_is_bounded_and_private() {
	reset_fixture
	run_helper apply >/dev/null
	assert_eq "apply updates only eligible OpenCode records" \
		"$(jq '[.[] | select(.agent_args == ["acp"])] | length' "$TEST_STORE")" "2"
	assert_eq "apply preserves custom arguments" \
		"$(jq -c '.[] | select(.pubkey == "pub-custom") | .agent_args' "$TEST_STORE")" \
		'["acp","--cwd","/project"]'
	assert_eq "apply preserves unrelated harness arguments" \
		"$(jq -c '.[] | select(.pubkey == "pub-other") | .agent_args' "$TEST_STORE")" '[]'
	assert_eq "apply accepts and preserves unrelated null-pubkey records" \
		"$(jq -c '.[] | select(.name == "Built-in harness") | {pubkey,agent_args,unknown}' "$TEST_STORE")" \
		'{"pubkey":null,"agent_args":[],"unknown":{"preserve":true}}'
	assert_eq "apply preserves unknown fields" \
		"$(jq -r '.[] | select(.pubkey == "pub-empty-path") | .unknown.preserve' "$TEST_STORE")" "true"
	assert_file_exists "apply records private rollback state" "$TEST_STATE_FILE"
	assert_eq "rollback state uses private permissions" "$(_file_perms_for_test "$TEST_STATE_FILE")" "600"
	local backups=""
	backups=$(printf '%s\n' "$TEST_BACKUP_DIR"/managed-agents.*.json)
	assert_contains "apply creates a private backup" "$backups" "managed-agents."
	return 0
}

_file_perms_for_test() {
	local path="$1"
	if [[ "$(uname -s)" == "Darwin" ]]; then
		stat -f '%Lp' "$path"
	else
		stat -c '%a' "$path"
	fi
	return 0
}

test_reconcile_is_idempotent() {
	reset_fixture
	run_helper reconcile --quiet
	local before=""
	before=$(file_hash "$TEST_STORE")
	run_helper reconcile --quiet
	assert_eq "reconcile does not rewrite an applied store" "$(file_hash "$TEST_STORE")" "$before"
	return 0
}

test_reconcile_repairs_managed_drift() {
	reset_fixture
	run_helper apply --quiet
	local edited="${TEST_STORE}.edited"
	jq 'map(
		if .pubkey == "pub-empty-path" then .agent_args = []
		elif .pubkey == "pub-missing-args" then .agent_args = ["user-choice"]
		else .
		end
	)' "$TEST_STORE" >"$edited"
	chmod 600 "$edited"
	mv "$edited" "$TEST_STORE"

	run_helper reconcile --quiet
	assert_eq "reconcile repairs an aidevops-managed empty argument" \
		"$(jq -c '.[] | select(.pubkey == "pub-empty-path") | .agent_args' "$TEST_STORE")" '["acp"]'
	assert_eq "reconcile preserves a later user argument edit" \
		"$(jq -c '.[] | select(.pubkey == "pub-missing-args") | .agent_args' "$TEST_STORE")" \
		'["user-choice"]'
	return 0
}

test_reconcile_defers_managed_drift_while_running() {
	reset_fixture
	run_helper apply --quiet
	local edited="${TEST_STORE}.edited"
	jq 'map(if .pubkey == "pub-empty-path" then .agent_args = [] else . end)' \
		"$TEST_STORE" >"$edited"
	chmod 600 "$edited"
	mv "$edited" "$TEST_STORE"
	local before=""
	local rc=0
	before=$(file_hash "$TEST_STORE")
	TEST_RUNNING=true run_helper reconcile >/dev/null 2>&1 || rc=$?
	assert_eq "running Buzz defers managed drift reconciliation" "$rc" "2"
	assert_eq "deferred drift reconciliation leaves store unchanged" \
		"$(file_hash "$TEST_STORE")" "$before"
	return 0
}

test_rollback_restores_owned_fields() {
	reset_fixture
	run_helper apply --quiet
	run_helper rollback --quiet
	assert_eq "rollback restores originally empty arguments" \
		"$(jq -c '.[] | select(.pubkey == "pub-empty-path") | .agent_args' "$TEST_STORE")" '[]'
	assert_eq "rollback restores an originally absent argument field as empty" \
		"$(jq -c '.[] | select(.pubkey == "pub-missing-args") | .agent_args' "$TEST_STORE")" '[]'
	assert_eq "rollback leaves custom arguments unchanged" \
		"$(jq -c '.[] | select(.pubkey == "pub-custom") | .agent_args' "$TEST_STORE")" \
		'["acp","--cwd","/project"]'
	assert_file_absent "rollback removes active compatibility state" "$TEST_STATE_FILE"
	return 0
}

test_rollback_preserves_later_user_edit() {
	reset_fixture
	run_helper apply --quiet
	local edited="${TEST_STORE}.edited"
	jq 'map(if .pubkey == "pub-empty-path" then .agent_args = ["user-choice"] else . end)' \
		"$TEST_STORE" >"$edited"
	chmod 600 "$edited"
	mv "$edited" "$TEST_STORE"
	run_helper rollback --quiet
	assert_eq "rollback preserves a later user argument edit" \
		"$(jq -c '.[] | select(.pubkey == "pub-empty-path") | .agent_args' "$TEST_STORE")" \
		'["user-choice"]'
	return 0
}

test_running_app_refuses_mutation() {
	reset_fixture
	local before=""
	local rc=0
	before=$(file_hash "$TEST_STORE")
	TEST_RUNNING=true run_helper apply >/dev/null 2>&1 || rc=$?
	assert_eq "running Buzz returns deferred exit code" "$rc" "2"
	assert_eq "running Buzz leaves store unchanged" "$(file_hash "$TEST_STORE")" "$before"
	assert_file_absent "running Buzz does not create state" "$TEST_STATE_FILE"
	return 0
}

test_unknown_version_and_platform_are_noops() {
	reset_fixture
	local before=""
	before=$(file_hash "$TEST_STORE")
	TEST_VERSION=0.5.5 run_helper reconcile --quiet
	assert_eq "unknown future Buzz version is not guessed affected" "$(file_hash "$TEST_STORE")" "$before"
	TEST_PLATFORM=Linux run_helper reconcile --quiet
	assert_eq "non-macOS platform is unchanged" "$(file_hash "$TEST_STORE")" "$before"
	return 0
}

test_symlink_store_fails_closed() {
	reset_fixture
	local target="${TEST_STORE}.target"
	mv "$TEST_STORE" "$target"
	ln -s "$target" "$TEST_STORE"
	local rc=0
	run_helper apply >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		pass "symlinked Buzz store fails closed"
	else
		fail "symlinked Buzz store fails closed" "apply returned zero"
	fi
	assert_eq "symlink target remains unchanged" \
		"$(jq '[.[] | select((.agent_args // []) == ["acp"])] | length' "$target")" "0"
	return 0
}

test_malformed_record_fails_closed() {
	reset_fixture
	local malformed="${TEST_STORE}.malformed"
	jq 'map(if .pubkey == "pub-empty-path" then del(.pubkey) else . end)' \
		"$TEST_STORE" >"$malformed"
	chmod 600 "$malformed"
	mv "$malformed" "$TEST_STORE"
	local before=""
	local rc=0
	before=$(file_hash "$TEST_STORE")
	run_helper apply >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		pass "malformed Buzz records fail closed"
	else
		fail "malformed Buzz records fail closed" "apply returned zero"
	fi
	assert_eq "malformed Buzz store remains unchanged" "$(file_hash "$TEST_STORE")" "$before"
	assert_file_absent "malformed Buzz store creates no state" "$TEST_STATE_FILE"
	return 0
}

test_cli_and_setup_wiring() {
	if grep -Fq 'buzz) _dispatch_helper "buzz-desktop-helper.sh"' "$CLI_FILE"; then
		pass "aidevops CLI routes the Buzz helper"
	else
		fail "aidevops CLI routes the Buzz helper" "dispatch entry missing"
	fi
	local setup_calls=""
	setup_calls=$(grep -c 'reconcile_buzz_desktop_compatibility' "$SETUP_FILE" || true)
	if [[ "$setup_calls" -ge 2 ]]; then
		pass "interactive setup and non-interactive update reconcile Buzz"
	else
		fail "interactive setup and non-interactive update reconcile Buzz" "expected at least two setup call sites"
	fi
	if grep -Fq "\${INSTALL_DIR}/agents/scripts/buzz-desktop-helper.sh" "$SETUP_FILE"; then
		pass "setup invokes the deployed Buzz helper path"
	else
		fail "setup invokes the deployed Buzz helper path" "deployed helper path missing"
	fi
	return 0
}

main() {
	test_status_reports_eligible_records
	test_apply_is_bounded_and_private
	test_reconcile_is_idempotent
	test_reconcile_repairs_managed_drift
	test_reconcile_defers_managed_drift_while_running
	test_rollback_restores_owned_fields
	test_rollback_preserves_later_user_edit
	test_running_app_refuses_mutation
	test_unknown_version_and_platform_are_noops
	test_symlink_store_fails_closed
	test_malformed_record_fails_closed
	test_cli_and_setup_wiring
	printf '\nResults: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
	[[ "$FAIL_COUNT" -eq 0 ]]
	return $?
}

main "$@"
