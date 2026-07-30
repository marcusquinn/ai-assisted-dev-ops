#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-sync.sh — Fenced social routine regression tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
PASS=0
FAIL=0

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
		printf '  FAIL  %s (expected=%s actual=%s)\n' \
			"$description" "$expected" "$actual"
	fi
	return 0
}

json_field() {
	local payload="$1"
	local field="$2"
	python3 -c \
		'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' \
		"$payload" "$field"
	return 0
}

sql_value() {
	local query="$1"
	python3 - "$ROOT/index/social.db" "$query" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
print(connection.execute(sys.argv[2]).fetchone()[0])
connection.close()
PY
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Social sync routine tests\n'
assert_eq "current schema is active" "$(sql_value 'PRAGMA user_version')" "5"
assert_eq "lease and reconciliation tables are provisioned" \
	"$(sql_value "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('collector_lease_generations','collector_leases','reconciliation_items')")" \
	"3"

if AIDEVOPS_TEST_MODE='' AIDEVOPS_SOCIAL_NOW_EPOCH='' \
	"$HELPER" sync-due --base "$BASE" --now-epoch 1000 >/dev/null 2>&1; then
	assert_eq "explicit clock override is unavailable outside tests" accepted rejected
else
	assert_eq "explicit clock override is unavailable outside tests" rejected rejected
fi
if AIDEVOPS_TEST_MODE='' AIDEVOPS_SOCIAL_NOW_EPOCH=1000 \
	"$HELPER" sync-due --base "$BASE" >/dev/null 2>&1; then
	assert_eq "environment clock override is unavailable outside tests" accepted rejected
else
	assert_eq "environment clock override is unavailable outside tests" rejected rejected
fi

cat >"$TMP_DIR/initial.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "private-handle"}},
  "pages": [{
    "status": 200,
    "observed_at": "2026-07-25T06:00:00Z",
    "data": [{
      "id": "post101",
      "author_id": "acct42",
      "text": "lease fixture",
      "created_at": "2026-07-25T05:00:00Z"
    }],
    "meta": {}
  }]
}
JSON

export AIDEVOPS_SOCIAL_NOW_EPOCH=1000
sync_result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_sync --account-id acct42 --stream authored \
	--collector-id runner_one --fixture "$TMP_DIR/initial.json")
run_id_length=$(json_field "$sync_result" run_id |
	python3 -c 'import sys; print(len(sys.stdin.read().strip()))')
assert_eq "successful sync returns a durable run ID" "$run_id_length" "64"
assert_eq "successful receipt carries the collector fence" \
	"$(sql_value "SELECT status || ':' || run_kind || ':' || collector_id || ':' || fencing_token FROM sync_runs WHERE connection_id='conn_sync'")" \
	"complete:sync:runner_one:1"
assert_eq "completed invocation releases its live lease" \
	"$(sql_value "SELECT count(*) FROM collector_leases WHERE connection_id='conn_sync'")" \
	"0"

not_due=$("$HELPER" sync-due --base "$BASE" \
	--now-epoch 1000 --interval-seconds 60)
due=$("$HELPER" sync-due --base "$BASE" \
	--now-epoch 1060 --interval-seconds 60)
assert_eq "daily planner omits a stream before its deterministic boundary" \
	"$not_due" "[]"
due_summary=$(python3 -c \
	'import json,sys; d=json.loads(sys.argv[1]); print("{}:{}:{}:{}".format(len(d),d[0]["connection_id"],d[0]["stream"],d[0]["due_at"]))' \
	"$due")
assert_eq "daily planner emits one sorted opaque target at the boundary" \
	"$due_summary" "1:conn_sync:authored:1060"

cat >"$TMP_DIR/rate-limit.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42"}},
  "pages": [{
    "status": 429,
    "observed_at": "2026-07-25T06:05:00Z",
    "retry_after": 1100
  }]
}
JSON
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_sync --account-id acct42 --stream authored \
	--collector-id runner_one --fixture "$TMP_DIR/rate-limit.json" >/dev/null
assert_eq "rate reset suppresses retries before the provider boundary" \
	"$("$HELPER" sync-due --base "$BASE" --now-epoch 1099 --interval-seconds 86400)" \
	"[]"
rate_due=$("$HELPER" sync-due --base "$BASE" \
	--now-epoch 1100 --interval-seconds 86400)
assert_eq "rate reset schedules one bounded retry without waiting a full interval" \
	"$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("{}:{}".format(len(d),d[0]["due_at"]))' "$rate_due")" \
	"1:1100"

race_summary=$(
	python3 - "$ROOT" "$SCRIPT_DIR/../scripts" <<'PY'
import multiprocessing
import os
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseBusyError,
    SocialLeaseLostError,
    acquire_run_lease,
    assert_run_lease,
    fail_active_run,
    release_run_lease,
)
from _knowledge_social_x import CursorState, PageCheckpoint, STREAMS
from _knowledge_social_x_persist import SuccessfulPage, persist_page
from _knowledge_social_x_state import CollectionContext, ConnectionConfig

root = Path(sys.argv[1])


def contender(owner, barrier, queue):
    barrier.wait()
    try:
        lease = acquire_run_lease(
            root,
            RunLeaseRequest("conn_race", "authored", owner, "sync", 10),
            now_epoch=2000,
        )
        queue.put(("writer", owner, lease.fencing_token, lease.run_id))
    except SocialLeaseBusyError:
        queue.put(("busy", owner, 0, ""))


context = multiprocessing.get_context("fork")
barrier = context.Barrier(2)
queue = context.Queue()
workers = [
    context.Process(target=contender, args=(owner, barrier, queue))
    for owner in ("runner_a", "runner_b")
]
for worker in workers:
    worker.start()
for worker in workers:
    worker.join(10)
if any(worker.exitcode != 0 for worker in workers):
    raise SystemExit("collector contender failed")
results = [queue.get(timeout=2) for _ in workers]
if sorted(result[0] for result in results) != ["busy", "writer"]:
    raise SystemExit("competing collectors did not elect exactly one writer")

stale = acquire_run_lease(
    root,
    RunLeaseRequest("conn_stale", "authored", "runner_old", "sync", 10),
    now_epoch=3000,
)
fresh = acquire_run_lease(
    root,
    RunLeaseRequest("conn_stale", "authored", "runner_new", "sync", 10),
    now_epoch=3010,
)
database = sqlite3.connect(root / "index" / "social.db")
database.row_factory = sqlite3.Row
database.execute("BEGIN IMMEDIATE")
try:
    assert_run_lease(database, stale, now_epoch=3010)
except SocialLeaseLostError:
    database.rollback()
else:
    raise SystemExit("stale fencing token remained writable")
finally:
    database.close()
release_run_lease(root, fresh)

old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_sync", "authored", "runner_old", "sync", 10),
    now_epoch=4000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_sync", "authored", "runner_new", "sync", 10),
    now_epoch=4010,
)
database = sqlite3.connect(root / "index" / "social.db")
stored = database.execute(
    "SELECT cursor,watermark,backfill_complete FROM sync_cursors "
    "WHERE connection_id='conn_sync' AND stream='authored'"
).fetchone()
database.close()
collection = CollectionContext(
    root,
    "conn_sync",
    {"id": "acct42"},
    "authored",
    "none",
    ConnectionConfig(("authored",), {"media_hydration": "none"}),
    CursorState(stored[0], stored[1], bool(stored[2])),
    STREAMS["authored"],
    old,
    "xapi",
)
page = SuccessfulPage(
    {
        "status": 200,
        "observed_at": "2026-07-25T06:01:00Z",
        "data": [],
        "meta": {},
    },
    "/2/users/acct42/tweets?max_results=100",
    {
        "remote_account_id": "acct42",
        "enabled_streams": ["authored"],
        "policy": {"media_hydration": "none"},
        "accounts": [],
        "objects": [],
        "activities": [],
        "media": [],
        "exported_at": "2026-07-25T06:01:00Z",
    },
    PageCheckpoint(None, "post999"),
    True,
    1,
)
os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "4010"
try:
    persist_page(collection, page)
except SocialLeaseLostError:
    pass
else:
    raise SystemExit("stale page unexpectedly advanced a cursor")
database = sqlite3.connect(root / "index" / "social.db")
current = database.execute(
    "SELECT watermark FROM sync_cursors "
    "WHERE connection_id='conn_sync' AND stream='authored'"
).fetchone()[0]
database.close()
if current != "post101":
    raise SystemExit("stale page changed the durable cursor")
fail_active_run(root, new, "test_handoff", now_epoch=4010)
release_run_lease(root, new)

print("writer:1:stale-rejected:cursor-stable")
PY
)
assert_eq "two competing collectors yield exactly one writer" \
	"$race_summary" "writer:1:stale-rejected:cursor-stable"
assert_eq "stale takeover uses a strictly greater token" \
	"$(sql_value "SELECT last_token FROM collector_lease_generations WHERE connection_id='conn_stale'")" \
	"2"
assert_eq "takeover records an abandoned receipt for crash recovery" \
	"$(sql_value "SELECT status || ':' || failure_class FROM sync_runs WHERE connection_id='conn_stale' AND fencing_token=1")" \
	"abandoned:lease_expired"
assert_eq "stale collector cannot advance the committed watermark" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_sync' AND stream='authored'")" \
	"post101"

expiry_summary=$(
	python3 - "$ROOT" "$SCRIPT_DIR/../scripts" <<'PY'
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
import _knowledge_social_collect_persist as persistence
from _knowledge_social_collect import (
    CollectionContext,
    ConnectionConfig,
    CursorState,
    PageCheckpoint,
    SuccessfulPage,
    TerminalDecision,
)
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
)
from _knowledge_social_x import STREAMS

root = Path(sys.argv[1])


def durable_state():
    with sqlite3.connect(root / "index" / "social.db") as database:
        cursor = database.execute(
            "SELECT cursor,watermark,backfill_complete FROM sync_cursors "
            "WHERE connection_id='conn_sync' AND stream='authored'"
        ).fetchone()
        fetches = database.execute(
            "SELECT count(*) FROM fetch_batches "
            "WHERE connection_id='conn_sync' AND stream='authored'"
        ).fetchone()[0]
        coverage = database.execute(
            "SELECT status,unavailable_reason,batch_id FROM coverage_records "
            "WHERE provider='xapi' AND connection_id='conn_sync' "
            "AND stream='authored'"
        ).fetchone()
    return cursor, fetches, coverage


def collection_for(lease):
    cursor = durable_state()[0]
    return CollectionContext(
        root,
        "conn_sync",
        {"id": "acct42"},
        "authored",
        "none",
        ConnectionConfig(("authored",), {"media_hydration": "none"}),
        CursorState(cursor[0], cursor[1], bool(cursor[2])),
        STREAMS["authored"],
        lease=lease,
        provider="xapi",
    )


def reject_after_expiry(start, operation):
    lease = acquire_run_lease(
        root,
        RunLeaseRequest(
            "conn_sync", "authored", f"expiry_{start}", "sync", 2
        ),
        now_epoch=start,
    )
    clock_calls = 0

    def advancing_clock():
        nonlocal clock_calls
        clock_calls += 1
        return start + (1 if clock_calls == 1 else 2)

    original_clock = persistence.social_now
    persistence.social_now = advancing_clock
    try:
        try:
            operation(collection_for(lease))
        except SocialLeaseLostError:
            pass
        else:
            raise SystemExit("expired lease committed social persistence")
    finally:
        persistence.social_now = original_clock
    successor = acquire_run_lease(
        root,
        RunLeaseRequest(
            "conn_sync", "authored", f"successor_{start}", "sync", 10
        ),
        now_epoch=start + 2,
    )
    fail_active_run(root, successor, "test_cleanup", now_epoch=start + 2)
    release_run_lease(root, successor)


def persist_success(context):
    page = SuccessfulPage(
        {"status": 200, "observed_at": "2026-07-25T08:00:00Z", "data": []},
        "/2/users/acct42/tweets?max_results=100",
        {
            "remote_account_id": "acct42",
            "enabled_streams": ["authored"],
            "policy": {"media_hydration": "none"},
            "accounts": [],
            "objects": [],
            "activities": [],
            "media": [],
            "exported_at": "2026-07-25T08:00:00Z",
        },
        PageCheckpoint(None, "must_not_commit"),
        True,
        1,
    )
    persistence.persist_page(context, page)


def persist_terminal(context):
    persistence.record_terminal(
        context,
        {"status": 500, "observed_at": "2026-07-25T08:01:00Z"},
        "/2/users/acct42/tweets?max_results=100",
        TerminalDecision("failed", "failed", "provider"),
    )


def persist_stop(context):
    persistence.record_bounded_stop(context, "paused", "budget")


before = durable_state()
reject_after_expiry(6000, persist_success)
reject_after_expiry(7000, persist_terminal)
reject_after_expiry(8000, persist_stop)
if durable_state() != before:
    raise SystemExit("expired persistence changed durable social state")
print("page:terminal:stop:rolled-back")
PY
)
assert_eq "leases expiring during persistence roll back every durable path" \
	"$expiry_summary" "page:terminal:stop:rolled-back"

cat >"$TMP_DIR/missing.json" <<'JSON'
{
  "provider": "xapi",
  "observed_at": "2026-07-25T07:00:00Z",
  "complete": true,
  "objects": [],
  "activities": []
}
JSON
chmod 0644 "$TMP_DIR/missing.json"
if "$HELPER" reconcile --base "$BASE" --connection-id conn_sync \
	--stream authored --snapshot "$TMP_DIR/missing.json" \
	--collector-id runner_reconcile --now-epoch 5000 >/dev/null 2>&1; then
	assert_eq "group-readable reconciliation evidence fails closed" \
		"accepted" "rejected"
else
	assert_eq "group-readable reconciliation evidence fails closed" \
		"rejected" "rejected"
fi
chmod 0600 "$TMP_DIR/missing.json"
ln -s "$TMP_DIR/missing.json" "$TMP_DIR/linked.json"
if "$HELPER" reconcile --base "$BASE" --connection-id conn_sync \
	--stream authored --snapshot "$TMP_DIR/linked.json" \
	--collector-id runner_reconcile --now-epoch 5000 >/dev/null 2>&1; then
	assert_eq "symlinked reconciliation evidence fails closed" "accepted" "rejected"
else
	assert_eq "symlinked reconciliation evidence fails closed" "rejected" "rejected"
fi
missing_result=$("$HELPER" reconcile --base "$BASE" \
	--connection-id conn_sync --stream authored --snapshot "$TMP_DIR/missing.json" \
	--collector-id runner_reconcile --now-epoch 5000)
assert_eq "complete reconciliation marks absent object and activity evidence missing" \
	"$(json_field "$missing_result" missing)" "2"
assert_eq "missing evidence is retained rather than purged" \
	"$(sql_value "SELECT (SELECT count(*) FROM objects WHERE remote_id='post101') || ':' || (SELECT count(*) FROM reconciliation_items WHERE status='missing')")" \
	"1:2"
assert_eq "missing activity is excluded from active query provenance" \
	"$(sql_value "SELECT state FROM activities WHERE remote_id='acct42-authored-post101'")" \
	"missing"
assert_eq "reconciliation never advances the provider cursor" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_sync' AND stream='authored'")" \
	"post101"

cat >"$TMP_DIR/present.json" <<'JSON'
{
  "provider": "xapi",
  "observed_at": "2026-07-25T08:00:00Z",
  "complete": true,
  "objects": [{"object_type": "post", "remote_id": "post101"}],
  "activities": [{
    "activity_type": "authored",
    "remote_id": "acct42-authored-post101"
  }]
}
JSON
chmod 0600 "$TMP_DIR/present.json"
present_result=$("$HELPER" reconcile --base "$BASE" \
	--connection-id conn_sync --stream authored --snapshot "$TMP_DIR/present.json" \
	--collector-id runner_reconcile --now-epoch 6000)
assert_eq "reappearing evidence clears the missing state" \
	"$(json_field "$present_result" present):$(sql_value "SELECT count(*) FROM reconciliation_items WHERE status='present' AND first_missing_at IS NULL")" \
	"2:2"
assert_eq "reappearing activity restores active provenance" \
	"$(sql_value "SELECT state FROM activities WHERE remote_id='acct42-authored-post101'")" \
	"active"

receipts=$("$HELPER" receipts --base "$BASE" --connection-id conn_sync)
assert_eq "run receipts expose no private account handle" \
	"$([[ "$receipts" == *private-handle* ]] && printf present || printf absent)" \
	"absent"
assert_eq "weekly planner waits from the completed reconciliation receipt" \
	"$("$HELPER" reconcile-due --base "$BASE" --now-epoch 6059 --interval-seconds 60)" \
	"[]"
reconcile_due=$("$HELPER" reconcile-due --base "$BASE" \
	--now-epoch 6060 --interval-seconds 60)
reconcile_summary=$(python3 -c \
	'import json,sys; d=json.loads(sys.argv[1]); print("{}:{}:{}".format(len(d),d[0]["run_kind"],d[0]["due_at"]))' \
	"$reconcile_due")
assert_eq "weekly planner emits the stream at its deterministic boundary" \
	"$reconcile_summary" "1:reconcile:6060"

cat >"$TMP_DIR/stale.json" <<'JSON'
{
  "provider": "xapi",
  "observed_at": "2026-07-25T07:30:00Z",
  "complete": true,
  "objects": [],
  "activities": []
}
JSON
chmod 0600 "$TMP_DIR/stale.json"
if "$HELPER" reconcile --base "$BASE" --connection-id conn_sync \
	--stream authored --snapshot "$TMP_DIR/stale.json" \
	--collector-id runner_reconcile --now-epoch 7000 >/dev/null 2>&1; then
	assert_eq "older reconciliation evidence cannot roll state backward" \
		"accepted" "rejected"
else
	assert_eq "older reconciliation evidence cannot roll state backward" \
		"rejected" "rejected"
fi

cat >"$TMP_DIR/conflict.json" <<'JSON'
{
  "provider": "xapi",
  "observed_at": "2026-07-25T08:00:00Z",
  "complete": true,
  "objects": [],
  "activities": []
}
JSON
chmod 0600 "$TMP_DIR/conflict.json"
if "$HELPER" reconcile --base "$BASE" --connection-id conn_sync \
	--stream authored --snapshot "$TMP_DIR/conflict.json" \
	--collector-id runner_reconcile --now-epoch 7500 >/dev/null 2>&1; then
	assert_eq "same-time conflicting evidence fails closed" "accepted" "rejected"
else
	assert_eq "same-time conflicting evidence fails closed" "rejected" "rejected"
fi
if "$HELPER" reconcile --base "$BASE" --connection-id conn_sync \
	--stream mentions --snapshot "$TMP_DIR/present.json" \
	--collector-id runner_reconcile --now-epoch 7600 >/dev/null 2>&1; then
	assert_eq "reconciliation cannot widen into a disabled stream" \
		"accepted" "rejected"
else
	assert_eq "reconciliation cannot widen into a disabled stream" \
		"rejected" "rejected"
fi
replay_result=$("$HELPER" reconcile --base "$BASE" --connection-id conn_sync \
	--stream authored --snapshot "$TMP_DIR/present.json" \
	--collector-id runner_reconcile --now-epoch 8000)
assert_eq "exact reconciliation replay is idempotent" \
	"$(json_field "$replay_result" present):$(sql_value "SELECT count(*) FROM fetch_batches WHERE terminal_status='reconciliation'")" \
	"2:2"
assert_eq "rejected stale and conflicting evidence leaves active state unchanged" \
	"$(sql_value "SELECT state FROM activities WHERE remote_id='acct42-authored-post101'")" \
	"active"

MIGRATION_ROOT="${TMP_DIR}/migration"
mkdir -p "$MIGRATION_ROOT/index"
chmod 0700 "$MIGRATION_ROOT" "$MIGRATION_ROOT/index"
python3 - "$MIGRATION_ROOT" "$SCRIPT_DIR/../scripts" <<'PY'
import sqlite3
import sys
from pathlib import Path

root = Path(sys.argv[1])
path = root / "index" / "social.db"
database = sqlite3.connect(path)
database.execute(
    "CREATE TABLE schema_meta(version INTEGER PRIMARY KEY,applied_at TEXT NOT NULL)"
)
database.execute(
    "CREATE TABLE sync_runs(run_id TEXT PRIMARY KEY,connection_id TEXT NOT NULL,"
    "status TEXT NOT NULL,resource_count INTEGER NOT NULL DEFAULT 0,"
    "failure_class TEXT,retry_after TEXT,fencing_token TEXT,diagnostics TEXT)"
)
database.execute("INSERT INTO schema_meta VALUES(1,'2026-07-25T00:00:00Z')")
database.execute("PRAGMA user_version=1")
database.commit()
database.close()

sys.path.insert(0, sys.argv[2])
from knowledge_social_store import connect, migrate

database = connect(root)
migrate(database)
columns = {row[1] for row in database.execute("PRAGMA table_info(sync_runs)")}
if database.execute("PRAGMA user_version").fetchone()[0] != 5:
    raise SystemExit("v1 database did not migrate to the current schema")
required = {
    "stream",
    "run_kind",
    "collector_id",
    "started_at",
    "completed_at",
    "request_hash",
}
if not required <= columns:
    raise SystemExit("v1 receipt table did not gain Phase 5 columns")
database.close()
PY
migration_version=$(
	python3 - "$MIGRATION_ROOT/index/social.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
print(connection.execute("PRAGMA user_version").fetchone()[0])
connection.close()
PY
)
assert_eq "existing v1 stores migrate without replacement" "$migration_version" "5"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
