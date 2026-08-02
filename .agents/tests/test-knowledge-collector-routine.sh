#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-collector-routine.sh — Fake-clock freshness and health tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
SCHEDULER="${SCRIPTS_DIR}/knowledge_collector_schedule.py"
ROUTINE="${SCRIPTS_DIR}/knowledge-collector-routine.sh"
TMP_DIR=$(mktemp -d)
CONFIG="${TMP_DIR}/collectors.json"
STATE="${TMP_DIR}/health.json"
PASS=0
FAIL=0
mkdir -p "${TMP_DIR}/_knowledge"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

assert_eq() {
	local description="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL  %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
	fi
	return 0
}

cat >"$CONFIG" <<JSON
{"schema":"aidevops.knowledge-collector/v1","connections":[
 {"connection_id":"archive_one","connector_id":"folder","mode":"archive","working_directory":"$TMP_DIR","enabled":true},
 {"connection_id":"event_one","connector_id":"social","mode":"event","working_directory":"$TMP_DIR","enabled":true,"event_pending":true,"event_token":"event-1","minimum_interval_seconds":60},
 {"connection_id":"hybrid_one","connector_id":"social","mode":"hybrid","working_directory":"$TMP_DIR","enabled":true,"reconcile_seconds":300,"minimum_interval_seconds":60},
 {"connection_id":"poll_one","connector_id":"mailbox","mode":"poll","working_directory":"$TMP_DIR","projection_root":"$TMP_DIR/_knowledge","enabled":true,"freshness_seconds":120,"minimum_interval_seconds":60,"stale_seconds":240},
 {"connection_id":"watch_one","connector_id":"inbox-watch","mode":"watch","working_directory":"$TMP_DIR","projection_root":"$TMP_DIR/_knowledge","enabled":true,"freshness_seconds":60,"minimum_interval_seconds":60}
]}
JSON
chmod 0600 "$CONFIG"

printf 'Knowledge collector freshness routine tests\n'
plan=$("$ROUTINE" plan --config "$CONFIG" --state "$STATE" --now-epoch 1000)
plan_summary=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(",".join("{}:{}:{}".format(x["connection_id"], str(x["due"]).lower(), x["health"]) for x in d))' "$plan")
assert_eq "fake-clock plan distinguishes manual and due source modes" "$plan_summary" \
	"archive_one:false:manual,event_one:true:pending,hybrid_one:true:pending,poll_one:true:pending,watch_one:true:pending"
if [[ -e "${TMP_DIR}/.collector-health.lock" || -e "$STATE" ]]; then
	assert_eq "read-only planning creates no state or lock files" mutated unchanged
else
	assert_eq "read-only planning creates no state or lock files" unchanged unchanged
fi

python_summary=$(
	python3 - "$SCHEDULER" "$CONFIG" "$STATE" <<'PY'
import importlib.util
import dataclasses
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location("collector_schedule", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
connections = module.load_config(module.Path(sys.argv[2]))
state = module.load_state(module.Path(sys.argv[3]))
calls = []
projections = []
checkpoints = []

if module._receipt('{"counts":{"imported":3}}')["changed_count"] != 3:
    raise SystemExit("folder receipt was not normalized")
if module._receipt('{"resources":4}')["changed_count"] != 4:
    raise SystemExit("social receipt was not normalized")
try:
    module._receipt('{"status":"complete"}')
except module.CollectorScheduleError:
    pass
else:
    raise SystemExit("missing changed count did not fail closed")
for unsupported in ("dry-run", "planned", "unexpected"):
    try:
        module._receipt('{{"changed_count":1,"status":"{}"}}'.format(unsupported))
    except module.CollectorScheduleError:
        pass
    else:
        raise SystemExit(f"unsupported status failed open: {unsupported}")
try:
    module._receipt('{"changed_count":1,"status":"complete","commit_state":"planned"}')
except module.CollectorScheduleError:
    pass
else:
    raise SystemExit("planned commit state failed open")

def command_builder(connection):
    return [connection.connector_id]

def process_runner(connection, command):
    calls.append((connection.connection_id, tuple(command)))
    if connection.connection_id == "hybrid_one":
        return subprocess.CompletedProcess(command, 1, "", "synthetic private failure")
    changed = 2 if connection.connection_id in ("poll_one", "watch_one") else 0
    suffix = ',"rate_reset_at":1200,"coverage_status":"partial","pages":1' if connection.connection_id == "poll_one" else ""
    return subprocess.CompletedProcess(command, 0, f'collector log\n{{"changed_count":{changed}{suffix}}}', "")

def projection_runner(connection, timeout):
    projections.append((connection.connection_id, timeout, connection.projection_root))
    return "complete"

first = module.execute_due(
    connections, state, 1000, dry_run=False,
    command_builder=command_builder,
    process_runner=process_runner,
    projection_runner=projection_runner,
    checkpoint=lambda value: checkpoints.append(module.json.loads(module.json.dumps(value))),
)
second = module.execute_due(
    connections, state, 1010, dry_run=False,
    command_builder=command_builder,
    process_runner=process_runner,
    projection_runner=projection_runner,
)
if len(calls) != 4 or len(second) != 0:
    raise SystemExit(f"minimum interval or manual mode failed: {calls} {second}")
if projections != [("poll_one", 300, (module.Path(sys.argv[2]).parent / "_knowledge").resolve())]:
    raise SystemExit(f"projection was not changed-directory-coalesced: {projections}")
failed = state["connections"]["hybrid_one"]
if "synthetic" in str(state) or failed["consecutive_failures"] != 1:
    raise SystemExit("failure receipt leaked content or missed failure count")
module.execute_due(
    [connections[2]], state, 1060, dry_run=False,
    command_builder=command_builder, process_runner=process_runner,
)
module.execute_due(
    [connections[2]], state, 1120, dry_run=False,
    command_builder=command_builder, process_runner=process_runner,
)
if not failed["alert"] or module._health(connections[2], failed, 1120) != "terminal-failure":
    raise SystemExit("terminal failures did not cross the deduplicated alert threshold")
event = state["connections"]["event_one"]
poll = state["connections"]["poll_one"]
if event["event_token"] != "event-1" or module.due_at(connections[1], event, 1010) <= 1010:
    raise SystemExit("event token was not acknowledged exactly once")
if poll["rate_reset_at"] != 1200 or poll["coverage_status"] != "partial" or poll["pages"] != 1:
    raise SystemExit("content-free collector receipt fields were not retained")
if module._health(connections[3], poll, 1100) != "rate-reset" or module._health(connections[3], poll, 1300) != "partial":
    raise SystemExit("rate-reset and partial coverage health were not distinguished")
if not any(record["connections"].get("poll_one", {}).get("status") == "running" for record in checkpoints):
    raise SystemExit("running crash checkpoint was not persisted")
module.execute_due(
    [connections[2]], state, 1180, dry_run=False,
    command_builder=command_builder,
    process_runner=lambda connection, command: subprocess.CompletedProcess(command, 0, '{"changed_count":0}', ""),
)
if failed["alert"] or failed["consecutive_failures"] != 0:
    raise SystemExit("verified recovery did not clear terminal alert state")

launch_state = {"schema": module.SCHEMA, "connections": {}}
launch_calls = []
def launch_builder(connection):
    if connection.connection_id == "poll_one":
        raise OSError("synthetic launch failure")
    return [connection.connector_id]
def launch_runner(connection, command):
    launch_calls.append(connection.connection_id)
    return subprocess.CompletedProcess(command, 0, '{"changed_count":0}', "")
launch_results = module.execute_due(
    [connections[3], connections[4]], launch_state, 1000, dry_run=False,
    command_builder=launch_builder, process_runner=launch_runner,
)
if [result["status"] for result in launch_results] != ["failed", "complete"] or launch_calls != ["watch_one"]:
    raise SystemExit("launch failure aborted an independent due connection")

projection_state = {"schema": module.SCHEMA, "connections": {}}
projection_attempts = []
def changed_runner(connection, command):
    return subprocess.CompletedProcess(command, 0, '{"changed_count":1}', "")
def timeout_projection(connection, timeout):
    raise subprocess.TimeoutExpired([connection.connector_id], timeout)
module.execute_due(
    [connections[4]], projection_state, 1000, dry_run=False,
    command_builder=command_builder, process_runner=changed_runner,
    projection_runner=timeout_projection,
)
projection_record = projection_state["connections"]["watch_one"]
if projection_record["projection_status"] != "pending" or projection_record["status"] != "partial":
    raise SystemExit("projection timeout did not preserve durable pending debt")
dry_projection_state = module.json.loads(module.json.dumps(projection_state))
dry_projection_attempts = []
dry_projection_results = module.execute_due(
    [connections[4]], projection_state, 1060, dry_run=True,
    projection_runner=lambda connection, timeout: dry_projection_attempts.append(connection.connection_id) or "complete",
)
if dry_projection_attempts or dry_projection_results != [{"connection_id": "watch_one", "status": "planned"}]:
    raise SystemExit("dry-run executed pending projection debt or replaced its planned result")
if projection_state != dry_projection_state:
    raise SystemExit("dry-run mutated collector health state")
module.execute_due(
    [connections[4]], projection_state, 1060, dry_run=False,
    command_builder=command_builder,
    process_runner=lambda connection, command: subprocess.CompletedProcess(command, 0, '{"changed_count":0}', ""),
    projection_runner=lambda connection, timeout: projection_attempts.append(connection.connection_id) or "complete",
)
if projection_attempts != ["watch_one"] or projection_record["projection_status"] != "complete":
    raise SystemExit("pending projection debt was not retried after an empty collection")

partial_state = {"schema": module.SCHEMA, "connections": {}}
partial_projections = []
partial_results = module.execute_due(
    [connections[4]], partial_state, 1000, dry_run=False,
    command_builder=command_builder,
    process_runner=lambda connection, command: subprocess.CompletedProcess(
        command, 2, '{"counts":{"imported":2},"status":"partial"}', ""
    ),
    projection_runner=lambda connection, timeout: partial_projections.append(connection.connection_id) or "complete",
)
partial_record = partial_state["connections"]["watch_one"]
if partial_results[0]["changed_count"] != 2 or partial_projections != ["watch_one"] or partial_record["status"] != "partial":
    raise SystemExit("nonzero partial receipt discarded committed changes")
if "last_success" in partial_record:
    raise SystemExit("partial collection incorrectly advanced full freshness")

rate_state = {"schema": module.SCHEMA, "connections": {}}
rate_receipt = '{"resources":0,"status":"rate_limited","failure_class":"rate_limit","rate_reset_at":1785232800}'
module.execute_due(
    [connections[1]], rate_state, 1000, dry_run=False,
    command_builder=command_builder,
    process_runner=lambda connection, command: subprocess.CompletedProcess(command, 0, rate_receipt, ""),
)
rate_record = rate_state["connections"]["event_one"]
if rate_record["status"] != "pending" or rate_record["rate_reset_at"] != 1785232800:
    raise SystemExit("rate-limited provider receipt was not deferred to its reset")
if "last_success" in rate_record or "event_token" in rate_record or module.due_at(connections[1], rate_record, 1100) != 1785232800:
    raise SystemExit("rate-limited provider advanced success or acknowledged its event")
relative_receipt = module._receipt(
    '{"resources":0,"status":"rate_limited","failure_class":"rate_limit","retry_after":"30"}',
    1000,
)
if relative_receipt["rate_reset_at"] != 1030:
    raise SystemExit("relative provider retry boundary was not made absolute")
long_relative_receipt = module._receipt(
    '{"resources":0,"status":"rate_limited","failure_class":"rate_limit","retry_after":"172800"}',
    1000,
)
if long_relative_receipt["rate_reset_at"] != 173800:
    raise SystemExit("multi-day provider retry duration was mistaken for an epoch")
explicit_relative_receipt = module._receipt(
    '{"resources":0,"status":"rate_limited","failure_class":"rate_limit","retry_after_seconds":172800}',
    1000,
)
if explicit_relative_receipt["rate_reset_at"] != 173800:
    raise SystemExit("explicit provider retry duration was not made absolute")
absolute_receipt = module._receipt(
    '{"resources":0,"status":"rate_limited","failure_class":"rate_limit","retry_after":1785232800}',
    1000,
)
if absolute_receipt["rate_reset_at"] != 1785232800:
    raise SystemExit("absolute provider retry epoch was treated as a duration")

for connector_id, arguments, projection_root in (
    ("social", ["telegram", "--dry-run"], None),
    ("folder", ["source", "--dry-run"], str((module.Path(sys.argv[2]).parent / "_knowledge").resolve())),
):
    candidate = {
        "connection_id": f"unsafe_{connector_id}",
        "connector_id": connector_id,
        "mode": "poll",
        "working_directory": str(module.Path(sys.argv[2]).parent),
        "arguments": arguments,
        "enabled": True,
    }
    if projection_root is not None:
        candidate["projection_root"] = projection_root
    try:
        module._connection(candidate)
    except module.CollectorScheduleError:
        pass
    else:
        raise SystemExit(f"enabled {connector_id} dry-run arguments were accepted")

for failure_class in ("authorization", "unavailable", "provider"):
    terminal_state = {"schema": module.SCHEMA, "connections": {}}
    terminal_receipt = '{{"resources":0,"status":"failed","failure_class":"{}"}}'.format(failure_class)
    module.execute_due(
        [connections[1]], terminal_state, 1000, dry_run=False,
        command_builder=command_builder,
        process_runner=lambda connection, command, output=terminal_receipt: subprocess.CompletedProcess(command, 0, output, ""),
    )
    terminal_record = terminal_state["connections"]["event_one"]
    if terminal_record["status"] != "failed" or "last_success" in terminal_record or "event_token" in terminal_record:
        raise SystemExit(f"terminal provider failure became healthy: {failure_class}")

deferred_state = {"schema": module.SCHEMA, "connections": {}}
module.execute_due(
    [connections[3]], deferred_state, 1000, dry_run=False,
    command_builder=command_builder,
    process_runner=lambda connection, command: subprocess.CompletedProcess(
        command, 0, '{"changed_count":0,"collector_status":"deferred"}', ""
    ),
)
deferred_record = deferred_state["connections"]["poll_one"]
if deferred_record["status"] != "pending" or deferred_record.get("consecutive_failures", 0) != 0 or "last_success" in deferred_record:
    raise SystemExit("benign contention became success or failure")

marker = module.Path(sys.argv[3]).with_name("orphan-marker")
child = f"import pathlib,time; time.sleep(2); pathlib.Path({str(marker)!r}).write_text('orphan')"
parent = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(10)"
bounded = dataclasses.replace(connections[3], timeout_seconds=1)
try:
    module.run_process(bounded, [sys.executable, "-c", parent])
except subprocess.TimeoutExpired:
    pass
else:
    raise SystemExit("bounded collector did not time out")
time.sleep(2)
if marker.exists():
    raise SystemExit("collector timeout left a mutating descendant alive")

escaped_marker = module.Path(sys.argv[3]).with_name("escaped-orphan-marker")
escaped_grandchild = (
    "import pathlib,time; time.sleep(1); "
    f"pathlib.Path({str(escaped_marker)!r}).write_text('orphan')"
)
escaped_child = (
    "import os,signal,subprocess,sys,time\n"
    "os.setsid()\n"
    "def escape(signum, frame):\n"
    f"    subprocess.Popen([sys.executable,'-c',{escaped_grandchild!r}])\n"
    "signal.signal(signal.SIGTERM, escape)\n"
    "time.sleep(4)\n"
)
escaped_parent = (
    "import subprocess,sys,time; "
    f"subprocess.Popen([sys.executable,'-c',{escaped_child!r}]); time.sleep(10)"
)
started = time.monotonic()
try:
    module.run_process(bounded, [sys.executable, "-c", escaped_parent])
except subprocess.TimeoutExpired:
    pass
else:
    raise SystemExit("session-changing descendant test did not time out")
if time.monotonic() - started >= 4:
    raise SystemExit("escaped descendant held collector output pipes open")
time.sleep(4)
if escaped_marker.exists():
    raise SystemExit("collector timeout left a session-changing descendant alive")

interrupt_marker = module.Path(sys.argv[3]).with_name("interrupt-orphan-marker")
interrupter = (
    "import os,pathlib,signal,time; os.kill(os.getppid(),signal.SIGTERM); time.sleep(2); "
    f"pathlib.Path({str(interrupt_marker)!r}).write_text('orphan')"
)
interrupt_bounded = dataclasses.replace(connections[3], timeout_seconds=10)
try:
    module.run_process(interrupt_bounded, [sys.executable, "-c", interrupter])
except module.CollectorInterrupted:
    pass
else:
    raise SystemExit("external scheduler interrupt was not handled")
time.sleep(2)
if interrupt_marker.exists():
    raise SystemExit("scheduler interrupt left its collector running")

module.write_state(module.Path(sys.argv[3]), state)
reloaded = module.load_state(module.Path(sys.argv[3]))
if reloaded != state:
    raise SystemExit("atomic state did not replay exactly")
print("4:manual-skipped:min-interval:changed-only:content-free:atomic:event:rate-reset:checkpoint:alerts:receipts:launch:projection:process-group:partial:terminal:deferred")
PY
)
assert_eq "execution is bounded, changed-only, content-free, and replayable" "$python_summary" \
	"4:manual-skipped:min-interval:changed-only:content-free:atomic:event:rate-reset:checkpoint:alerts:receipts:launch:projection:process-group:partial:terminal:deferred"

inbox_receipt=$(AIDEVOPS_COLLECTOR_RECEIPT=1 "$SCRIPTS_DIR/inbox-watch-routine.sh" "$TMP_DIR")
inbox_changed=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1].splitlines()[-1])["changed_count"])' "$inbox_receipt")
assert_eq "inbox watch emits a mandatory zero-change receipt" "$inbox_changed" "0"

BUSY_HOME="${TMP_DIR}/busy-home"
mkdir -p "${BUSY_HOME}/.config/aidevops" "${BUSY_HOME}/.aidevops/.agent-workspace/locks/email-poll.lock"
printf '{"mailboxes":[]}\n' >"${BUSY_HOME}/.config/aidevops/mailboxes.json"
chmod 0600 "${BUSY_HOME}/.config/aidevops/mailboxes.json"
printf '%s\n' "$$" >"${BUSY_HOME}/.aidevops/.agent-workspace/locks/email-poll.lock/pid"
busy_receipt=$(HOME="$BUSY_HOME" AIDEVOPS_COLLECTOR_RECEIPT=1 "$SCRIPTS_DIR/email-poll-helper.sh" tick)
busy_status=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1].splitlines()[-1])["collector_status"])' "$busy_receipt")
assert_eq "mailbox lock contention emits deferred rather than failure" "$busy_status" "deferred"

if chmod 0644 "$CONFIG" && "$ROUTINE" plan --config "$CONFIG" --state "$STATE" >/dev/null 2>&1; then
	assert_eq "non-private config fails closed" accepted rejected
else
	assert_eq "non-private config fails closed" rejected rejected
fi
chmod 0600 "$CONFIG"

if AIDEVOPS_TEST_MODE='' "$ROUTINE" plan --config "$CONFIG" --state "$STATE" --now-epoch 2000 >/dev/null 2>&1; then
	assert_eq "clock override is unavailable outside tests" accepted rejected
else
	assert_eq "clock override is unavailable outside tests" rejected rejected
fi

if rg -n '\beval\b|shell=True|knowledge_social_operations|operation-run|\bsend\b|\bpublish\b|\btrade\b|\bwallet\b|\bpayment\b' "$SCHEDULER" "$ROUTINE" >/dev/null; then
	assert_eq "runner has no eval or outbound mutation reachability" reachable unreachable
else
	assert_eq "runner has no eval or outbound mutation reachability" unreachable unreachable
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
