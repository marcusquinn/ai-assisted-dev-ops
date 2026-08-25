#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../deployment-copy-helper.sh"
PYTHON_HELPER="${SCRIPT_DIR}/../deployment-copy-helper.py"
TEST_TMP_ROOT="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
REAL_GIT="${AIDEVOPS_REAL_GIT_BIN:-/usr/bin/git}"
TEST_ROOT=""
REPO=""
WORKTREE=""
SOURCE=""
DESTINATION=""
ALLOW_FILE=""
STATE_ROOT=""
EXPECTED_SHA=""

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

run_helper() {
	AIDEVOPS_DEPLOYMENT_COPY_STATE_DIR="$STATE_ROOT" \
		AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" \
		"$HELPER" "$@"
	return $?
}

write_allow_file() {
	local allowed_path="$1"
	printf '%s\n' "$allowed_path" >"$ALLOW_FILE"
	chmod 600 "$ALLOW_FILE"
	return 0
}

json_value() {
	local payload="$1"
	local expression="$2"
	python3 -c 'import json,sys; print(eval(sys.argv[2], {}, {"data": json.loads(sys.argv[1])}))' \
		"$payload" "$expression"
	return $?
}

assert_file_contains() {
	local file_path="$1"
	local expected="$2"
	[[ -f "$file_path" ]] || fail "missing file: $file_path"
	[[ "$(<"$file_path")" == "$expected" ]] || fail "unexpected content in $file_path"
	return 0
}

setup_fixture() {
	mkdir -p "$TEST_TMP_ROOT"
	TEST_ROOT=$(mktemp -d "$TEST_TMP_ROOT/deployment-copy.XXXXXX")
	trap cleanup EXIT
	REPO="$TEST_ROOT/source repo"
	WORKTREE="$TEST_ROOT/source worktree"
	SOURCE="$WORKTREE/source tree"
	DESTINATION="$TEST_ROOT/runtime target"
	ALLOW_FILE="$TEST_ROOT/allowed-targets.txt"
	STATE_ROOT="$TEST_ROOT/private state"
	mkdir -p "$REPO" "$STATE_ROOT"
	chmod 700 "$STATE_ROOT"
	"$REAL_GIT" -C "$REPO" init -b main >/dev/null
	"$REAL_GIT" -C "$REPO" config user.email test@example.invalid
	"$REAL_GIT" -C "$REPO" config user.name 'Deployment Copy Test'
	mkdir -p "$REPO/source tree/nested"
	printf 'new payload\n' >"$REPO/source tree/hello.txt"
	printf '#!/bin/sh\nprintf test\n' >"$REPO/source tree/nested/run.sh"
	chmod 755 "$REPO/source tree/nested/run.sh"
	"$REAL_GIT" -C "$REPO" add .
	"$REAL_GIT" -C "$REPO" commit -m fixture >/dev/null
	"$REAL_GIT" -C "$REPO" worktree add -b feature/deploy "$WORKTREE" >/dev/null
	EXPECTED_SHA=$("$REAL_GIT" -C "$WORKTREE" rev-parse HEAD)
	mkdir -p "$DESTINATION"
	printf 'old payload\n' >"$DESTINATION/old.txt"
	write_allow_file "$DESTINATION"
	return 0
}

test_dry_run_and_deploy() {
	local dry_json=""
	local deploy_json=""
	dry_json=$(run_helper deploy --source "$SOURCE" --destination "$DESTINATION" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --dry-run --machine)
	[[ "$(json_value "$dry_json" 'data["status"]')" == "planned" ]] || fail "dry-run status"
	[[ "$(json_value "$dry_json" '"hello.txt" in data["plan"]["add"]')" == "True" ]] || fail "dry-run add set"
	[[ "$(json_value "$dry_json" '"old.txt" in data["plan"]["delete"]')" == "True" ]] || fail "dry-run delete set"
	assert_file_contains "$DESTINATION/old.txt" "old payload"
	deploy_json=$(run_helper deploy --source "$SOURCE" --destination "$DESTINATION" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine)
	[[ "$(json_value "$deploy_json" 'data["status"]')" == "success" ]] || fail "deploy status"
	[[ "$deploy_json" != *"$TEST_ROOT"* ]] || fail "machine output exposed an absolute private path"
	[[ ! -e "$DESTINATION/old.txt" ]] || fail "destination-only file survived deployment"
	assert_file_contains "$DESTINATION/hello.txt" "new payload"
	DEPLOY_OPERATION_ID=$(json_value "$deploy_json" 'data["operation_id"]')
	pass "dry-run plans exact changes and deployment converges without path disclosure"
	return 0
}

test_post_activation_failure_recovery() {
	AIDEVOPS_DEPLOYMENT_COPY_STATE_DIR="$STATE_ROOT" \
		AIDEVOPS_REAL_GIT_BIN="$REAL_GIT" \
		python3 - "$PYTHON_HELPER" "$SOURCE" "$DESTINATION" "$EXPECTED_SHA" "$ALLOW_FILE" <<'PY'
import argparse
import importlib.util
from pathlib import Path
import re
import sys

spec = importlib.util.spec_from_file_location("deployment_copy_helper", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit("helper module could not be loaded")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
destination = Path(sys.argv[3]).resolve()
real_scan_tree = helper.scan_tree
destination_scans = 0


def failing_scan_tree(root, *args, **kwargs):
    global destination_scans
    if Path(root).resolve() == destination:
        destination_scans += 1
        if destination_scans == 3:
            raise helper.DeploymentError("injected post-activation verification failure")
    return real_scan_tree(root, *args, **kwargs)


helper.scan_tree = failing_scan_tree
arguments = argparse.Namespace(
    allow_file=sys.argv[5],
    destination=sys.argv[3],
    dry_run=False,
    expected_sha=sys.argv[4],
    machine=True,
    reviewed_tree_sha256=None,
    source=sys.argv[2],
)
try:
    helper.deploy(arguments)
except helper.DeploymentError as error:
    if not error.operation_id or not re.fullmatch(
        r"op-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}", error.operation_id
    ):
        raise SystemExit("failed deployment did not report a safe operation ID")
else:
    raise SystemExit("injected post-activation failure unexpectedly succeeded")
PY
	assert_file_contains "$DESTINATION/old.txt" "old payload"
	[[ ! -e "$DESTINATION/hello.txt" ]] || fail "failed activation remained live"
	pass "post-activation failure restores the previous tree and reports an operation ID"
	return 0
}

test_rollback() {
	local recover_json=""
	local rollback_json=""
	local rollback_path="$TEST_ROOT/.runtime target.aidevops-rollback-${DEPLOY_OPERATION_ID}"
	ln -s "$DESTINATION/hello.txt" "$rollback_path/unsafe-link"
	if run_helper rollback --operation-id "$DEPLOY_OPERATION_ID" \
		--confirm ROLLBACK_DEPLOYMENT_COPY --allow-file "$ALLOW_FILE" --machine >/dev/null 2>&1; then
		fail "unsafe rollback tree was activated"
	fi
	assert_file_contains "$DESTINATION/hello.txt" "new payload"
	rm "$rollback_path/unsafe-link"
	rollback_json=$(run_helper rollback --operation-id "$DEPLOY_OPERATION_ID" \
		--confirm ROLLBACK_DEPLOYMENT_COPY --allow-file "$ALLOW_FILE" --machine)
	[[ "$(json_value "$rollback_json" 'data["status"]')" == "rolled_back" ]] || fail "rollback status"
	assert_file_contains "$DESTINATION/old.txt" "old payload"
	[[ ! -e "$DESTINATION/hello.txt" ]] || fail "deployed tree survived rollback"
	recover_json=$(run_helper recover --operation-id "$DEPLOY_OPERATION_ID" \
		--confirm RECOVER_DEPLOYMENT_COPY --allow-file "$ALLOW_FILE" --machine)
	[[ "$(json_value "$recover_json" 'data["status"]')" == "recovered_previous" ]] || fail "recovery did not recognize restored previous tree"
	pass "rollback restores the exact previous destination"
	return 0
}

test_source_provenance() {
	local error_json=""
	if error_json=$(run_helper deploy --source "$SOURCE" --destination "$DESTINATION" \
		--expected-sha "0000000000000000000000000000000000000000" \
		--allow-file "$ALLOW_FILE" --machine); then
		fail "source SHA mismatch was accepted"
	fi
	[[ "$(json_value "$error_json" 'data["status"]')" == "blocked" ]] || fail "machine refusal status"
	[[ "$error_json" != *"$TEST_ROOT"* ]] || fail "machine refusal exposed an absolute private path"
	if run_helper deploy --source "$REPO/source tree" --destination "$DESTINATION" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine >/dev/null 2>&1; then
		fail "canonical source checkout was accepted"
	fi
	assert_file_contains "$DESTINATION/old.txt" "old payload"
	pass "source must be the expected commit in a linked worktree"
	return 0
}

test_reviewed_generated_tree() {
	local manifest_json=""
	local reviewed_digest=""
	printf 'reviewed generated payload\n' >"$SOURCE/hello.txt"
	if run_helper deploy --source "$SOURCE" --destination "$DESTINATION" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine >/dev/null 2>&1; then
		fail "dirty source was accepted without reviewed digest"
	fi
	manifest_json=$(run_helper manifest --source "$SOURCE" --expected-sha "$EXPECTED_SHA" --machine)
	reviewed_digest=$(json_value "$manifest_json" 'data["tree_sha256"]')
	run_helper deploy --source "$SOURCE" --destination "$DESTINATION" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" \
		--reviewed-tree-sha256 "$reviewed_digest" --machine >/dev/null
	assert_file_contains "$DESTINATION/hello.txt" "reviewed generated payload"
	printf 'changed after review\n' >"$SOURCE/hello.txt"
	if run_helper deploy --source "$SOURCE" --destination "$DESTINATION" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" \
		--reviewed-tree-sha256 "$reviewed_digest" --machine >/dev/null 2>&1; then
		fail "post-review source change was accepted"
	fi
	printf 'new payload\n' >"$SOURCE/hello.txt"
	pass "generated trees require and retain an exact reviewed digest"
	return 0
}

test_unsafe_paths_and_types() {
	local bare_destination="$TEST_ROOT/bare target"
	local destination_link="$TEST_ROOT/destination link"
	local git_destination="$WORKTREE/runtime target"
	ln -s "$DESTINATION" "$destination_link"
	write_allow_file "$destination_link"
	if run_helper deploy --source "$SOURCE" --destination "$destination_link" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine >/dev/null 2>&1; then
		fail "symlinked destination was accepted"
	fi
	write_allow_file "$git_destination"
	if run_helper deploy --source "$SOURCE" --destination "$git_destination" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine >/dev/null 2>&1; then
		fail "Git worktree destination was accepted"
	fi
	"$REAL_GIT" init --bare "$bare_destination" >/dev/null
	write_allow_file "$bare_destination"
	if run_helper deploy --source "$SOURCE" --destination "$bare_destination" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine >/dev/null 2>&1; then
		fail "bare Git repository destination was accepted"
	fi
	write_allow_file "$DESTINATION"
	mkdir "$SOURCE/.git"
	printf 'metadata\n' >"$SOURCE/.git/config"
	if run_helper manifest --source "$SOURCE" --expected-sha "$EXPECTED_SHA" --machine >/dev/null 2>&1; then
		fail "nested Git metadata was accepted"
	fi
	rm -rf "$SOURCE/.git"
	ln -s "$SOURCE/hello.txt" "$SOURCE/link.txt"
	if run_helper manifest --source "$SOURCE" --expected-sha "$EXPECTED_SHA" --machine >/dev/null 2>&1; then
		fail "symlinked source entry was accepted"
	fi
	rm "$SOURCE/link.txt"
	mkfifo "$SOURCE/pipe"
	if run_helper manifest --source "$SOURCE" --expected-sha "$EXPECTED_SHA" --machine >/dev/null 2>&1; then
		fail "special source entry was accepted"
	fi
	rm "$SOURCE/pipe"
	chmod 4755 "$SOURCE/nested/run.sh"
	if run_helper manifest --source "$SOURCE" --expected-sha "$EXPECTED_SHA" --machine >/dev/null 2>&1; then
		fail "special permission bits were accepted"
	fi
	chmod 755 "$SOURCE/nested/run.sh"
	pass "Git-owned, symlinked, special-file, and special-mode paths fail closed"
	return 0
}

test_live_and_stale_locks() {
	local lock_dir=""
	local before=""
	lock_dir="$TEST_ROOT/.runtime target.aidevops-lock"
	mkdir -p "$lock_dir"
	printf '{"pid":%s,"token":"fixture"}\n' "$$" >"$lock_dir/owner.json"
	chmod 600 "$lock_dir/owner.json"
	before=$(<"$DESTINATION/hello.txt")
	if run_helper deploy --source "$SOURCE" --destination "$DESTINATION" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine >/dev/null 2>&1; then
		fail "live destination lock was ignored"
	fi
	[[ "$(<"$DESTINATION/hello.txt")" == "$before" ]] || fail "live-lock refusal mutated destination"
	printf '{"pid":99999999,"token":"stale"}\n' >"$lock_dir/owner.json"
	run_helper deploy --source "$SOURCE" --destination "$DESTINATION" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine >/dev/null
	assert_file_contains "$DESTINATION/hello.txt" "new payload"
	pass "live locks block and dead-owner locks are reclaimed"
	return 0
}

test_interrupted_staging_recovery() {
	local interrupted_destination="$TEST_ROOT/interrupted target"
	local interrupted_id="op-20260825T000000Z-abcdef123456"
	local interrupted_stage="$TEST_ROOT/.interrupted target.aidevops-stage-${interrupted_id}-fixture"
	local interrupted_rollback="$TEST_ROOT/.interrupted target.aidevops-rollback-${interrupted_id}"
	local interrupted_displaced="$TEST_ROOT/.interrupted target.aidevops-displaced-${interrupted_id}"
	local receipt="$STATE_ROOT/operations/${interrupted_id}.json"
	mkdir -p "$interrupted_stage"
	printf 'partial\n' >"$interrupted_stage/partial.txt"
	write_allow_file "$interrupted_destination"
	python3 -c 'import json,sys; json.dump({"schema":"aidevops.deployment-copy/v1","operation_id":sys.argv[1],"source_repo":sys.argv[2],"destination":sys.argv[3],"rollback_path":sys.argv[4],"displaced_path":sys.argv[5],"stage_path":sys.argv[6],"previous_present":False,"previous_tree_sha256":None,"tree_sha256":"0"*64,"status":"staging"}, open(sys.argv[7],"w"))' \
		"$interrupted_id" "$WORKTREE" "$interrupted_destination" \
		"$interrupted_rollback" "$interrupted_displaced" "$interrupted_stage" "$receipt"
	chmod 600 "$receipt"
	run_helper recover --operation-id "$interrupted_id" --confirm RECOVER_DEPLOYMENT_COPY \
		--allow-file "$ALLOW_FILE" --machine >/dev/null
	[[ ! -e "$interrupted_stage" && ! -e "$interrupted_destination" ]] || fail "interrupted stage was not safely aborted"
	pass "interrupted pre-activation staging recovers without destination mutation"
	return 0
}

test_receipt_path_binding() {
	local protected_tree="$TEST_ROOT/protected tree"
	local protected_destination="$TEST_ROOT/protected target"
	local protected_id="op-20260825T000001Z-abcdef123456"
	local receipt="$STATE_ROOT/operations/${protected_id}.json"
	mkdir -p "$protected_tree"
	printf 'retain\n' >"$protected_tree/retain.txt"
	write_allow_file "$protected_destination"
	python3 -c 'import json,sys; destination=sys.argv[3]; name=destination.rsplit("/",1)[-1]; parent=destination.rsplit("/",1)[0]; json.dump({"schema":"aidevops.deployment-copy/v1","operation_id":sys.argv[1],"source_repo":sys.argv[2],"destination":destination,"rollback_path":parent+"/."+name+".aidevops-rollback-"+sys.argv[1],"displaced_path":parent+"/."+name+".aidevops-displaced-"+sys.argv[1],"stage_path":sys.argv[4],"previous_present":False,"previous_tree_sha256":None,"tree_sha256":"0"*64,"status":"staging"}, open(sys.argv[5],"w"))' \
		"$protected_id" "$WORKTREE" "$protected_destination" "$protected_tree" "$receipt"
	chmod 600 "$receipt"
	if run_helper recover --operation-id "$protected_id" --confirm RECOVER_DEPLOYMENT_COPY \
		--allow-file "$ALLOW_FILE" --machine >/dev/null 2>&1; then
		fail "receipt redirected recovery outside its operation path"
	fi
	assert_file_contains "$protected_tree/retain.txt" "retain"
	pass "receipt paths cannot redirect recovery mutations"
	return 0
}

test_first_deployment_rollback() {
	local first_destination="$TEST_ROOT/first target"
	local deploy_json=""
	local rollback_json=""
	local operation_id=""
	write_allow_file "$first_destination"
	deploy_json=$(run_helper deploy --source "$SOURCE" --destination "$first_destination" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine)
	operation_id=$(json_value "$deploy_json" 'data["operation_id"]')
	rollback_json=$(run_helper rollback --operation-id "$operation_id" \
		--confirm ROLLBACK_DEPLOYMENT_COPY --allow-file "$ALLOW_FILE" --machine)
	[[ "$(json_value "$rollback_json" 'data["status"]')" == "rolled_back" ]] || fail "first-deployment rollback status"
	[[ ! -e "$first_destination" ]] || fail "first-deployment rollback did not restore an absent target"
	pass "rollback restores an originally absent destination"
	return 0
}

test_empty_destination() {
	local empty_destination="$TEST_ROOT/empty target"
	local deploy_json=""
	local operation_id=""
	mkdir "$empty_destination"
	write_allow_file "$empty_destination"
	deploy_json=$(run_helper deploy --source "$SOURCE" --destination "$empty_destination" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine)
	operation_id=$(json_value "$deploy_json" 'data["operation_id"]')
	assert_file_contains "$empty_destination/hello.txt" "new payload"
	run_helper rollback --operation-id "$operation_id" --confirm ROLLBACK_DEPLOYMENT_COPY \
		--allow-file "$ALLOW_FILE" --machine >/dev/null
	[[ -d "$empty_destination" && ! -e "$empty_destination/hello.txt" ]] || fail "empty destination was not restored"
	pass "an authorized empty destination can deploy and roll back"
	return 0
}

test_rollback_without_source_worktree() {
	local detached_destination="$TEST_ROOT/detached target"
	local deploy_json=""
	local operation_id=""
	mkdir "$detached_destination"
	printf 'previous\n' >"$detached_destination/previous.txt"
	write_allow_file "$detached_destination"
	deploy_json=$(run_helper deploy --source "$SOURCE" --destination "$detached_destination" \
		--expected-sha "$EXPECTED_SHA" --allow-file "$ALLOW_FILE" --machine)
	operation_id=$(json_value "$deploy_json" 'data["operation_id"]')
	"$REAL_GIT" -C "$REPO" worktree remove --force "$WORKTREE"
	run_helper rollback --operation-id "$operation_id" --confirm ROLLBACK_DEPLOYMENT_COPY \
		--allow-file "$ALLOW_FILE" --machine >/dev/null
	assert_file_contains "$detached_destination/previous.txt" "previous"
	pass "rollback remains available after the source worktree is removed"
	return 0
}

main() {
	[[ -x "$REAL_GIT" ]] || fail "native git is unavailable"
	setup_fixture
	test_post_activation_failure_recovery
	test_dry_run_and_deploy
	test_rollback
	test_source_provenance
	test_reviewed_generated_tree
	test_unsafe_paths_and_types
	test_live_and_stale_locks
	test_interrupted_staging_recovery
	test_receipt_path_binding
	test_first_deployment_rollback
	test_empty_destination
	test_rollback_without_source_worktree
	/bin/bash -n "$HELPER"
	/bin/bash -n "$0"
	pass "Bash 3.2 parser accepts helper and test harness"
	printf 'PASS: deployment-copy helper tests\n'
	return 0
}

DEPLOY_OPERATION_ID=""
main "$@"
