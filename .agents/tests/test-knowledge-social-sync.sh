#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-sync.sh — Fenced routine and reconciliation tests

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
		printf '  FAIL  %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
	fi
	return 0
}

json_field() {
	local payload="$1"
	local field="$2"
	python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$payload" "$field"
	return 0
}

sql_value() {
	local query="$1"
	python3 - "$ROOT/index/social.db" "$query" <<'PY'
import sqlite3
import sys
database = sqlite3.connect(sys.argv[1])
print(database.execute(sys.argv[2]).fetchone()[0])
database.close()
PY
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

migration_result=$(
	python3 - "$SCRIPT_DIR/../scripts" "$TMP_DIR/migration-root" <<'PY'
import os
import sqlite3
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from knowledge_social_store import connect, migrate
root = Path(sys.argv[2])
(root / "index").mkdir(parents=True, mode=0o700)
os.chmod(root, 0o700)
database_path = root / "index" / "social.db"
database = sqlite3.connect(database_path)
database.execute("CREATE TABLE sync_cursors(connection_id TEXT NOT NULL,stream TEXT NOT NULL,cursor TEXT,watermark TEXT,last_success_at TEXT,backfill_complete INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(connection_id,stream))")
database.execute("CREATE TABLE sync_runs(run_id TEXT PRIMARY KEY,connection_id TEXT NOT NULL,status TEXT NOT NULL,resource_count INTEGER NOT NULL DEFAULT 0,failure_class TEXT,retry_after TEXT,fencing_token TEXT,diagnostics TEXT)")
database.execute("PRAGMA user_version=1")
database.commit()
database.close()
os.chmod(database_path, 0o600)
database = connect(root)
migrate(database)
version = database.execute("PRAGMA user_version").fetchone()[0]
cursor_columns = {row[1] for row in database.execute("PRAGMA table_info(sync_cursors)")}
run_columns = {row[1] for row in database.execute("PRAGMA table_info(sync_runs)")}
tables = {row[0] for row in database.execute("SELECT name FROM sqlite_master WHERE type='table'")}
database.close()
valid = version == 2 and "fencing_token" in cursor_columns and {"stream", "run_type", "started_at", "completed_at"} <= run_columns and {"collector_leases", "reconciliation_observations"} <= tables
print("migrated" if valid else "invalid")
PY
)
assert_eq "schema v1 upgrades atomically to fenced schema v2" "$migration_result" "migrated"

cat >"$TMP_DIR/seed.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42"}},
  "pages": [{
    "status": 200,
    "observed_at": "2026-07-25T10:00:00Z",
    "data": [{"id": "post101", "author_id": "acct42", "text": "fenced evidence", "created_at": "2026-07-25T09:00:00Z"}],
    "meta": {}
  }]
}
JSON

first=$(
	"$HELPER" acquire-lease --base "$BASE" --alias personal:default \
		--connection-id conn_shared --collector-id runner_one --lease-seconds 60 \
		--now 2099-01-01T00:00:00Z
)
token_one=$(json_field "$first" fencing_token)
assert_eq "first collector receives the first fencing generation" "$token_one" "1"

competing=$(
	"$HELPER" acquire-lease --base "$BASE" --alias personal:default \
		--connection-id conn_shared --collector-id runner_two --lease-seconds 60 \
		--now 2099-01-01T00:00:30Z
)
assert_eq "a competing live collector cannot acquire the connection" \
	"$(json_field "$competing" status)" "held"

second=$(
	"$HELPER" acquire-lease --base "$BASE" --alias personal:default \
		--connection-id conn_shared --collector-id runner_two --lease-seconds 300 \
		--now 2099-01-01T00:02:00Z
)
token_two=$(json_field "$second" fencing_token)
assert_eq "lease takeover increments the fencing generation" "$token_two" "2"

if "$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_shared --account-id acct42 --stream authored \
	--fencing-token "$token_one" --fixture "$TMP_DIR/seed.json" >/dev/null 2>&1; then
	assert_eq "a stale collector cannot commit provider content" accepted rejected
else
	assert_eq "a stale collector cannot commit provider content" rejected rejected
fi
assert_eq "stale fencing leaves the cursor absent" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_shared'")" "0"

fresh_result=$(
	"$HELPER" sync-x --base "$BASE" --alias personal:default \
		--connection-id conn_shared --account-id acct42 --stream authored \
		--fencing-token "$token_two" --fixture "$TMP_DIR/seed.json"
)
assert_eq "the current lease generation can complete collection" \
	"$(json_field "$fresh_result" status)" "complete"
assert_eq "cursor advancement records the accepted fencing generation" \
	"$(sql_value "SELECT fencing_token FROM sync_cursors WHERE connection_id='conn_shared'")" "$token_two"

stale_release=$(
	"$HELPER" release-lease --base "$BASE" --alias personal:default \
		--connection-id conn_shared --collector-id runner_one --fencing-token "$token_one"
)
assert_eq "an old generation cannot release the current lease" \
	"$(json_field "$stale_release" status)" "stale"
current_release=$(
	"$HELPER" release-lease --base "$BASE" --alias personal:default \
		--connection-id conn_shared --collector-id runner_two --fencing-token "$token_two"
)
assert_eq "the current owner can release its exact generation" \
	"$(json_field "$current_release" status)" "released"

executed=$(
	"$HELPER" sync-due --base "$BASE" --alias personal:default \
		--collector-id routine_runner --interval-seconds 86400 --execute \
		--fixture "$TMP_DIR/seed.json" --now 2099-01-01T00:03:00Z
)
assert_eq "sync-due executes the guarded provider route under its lease" \
	"$(json_field "$executed" completed)" "1"
assert_eq "successful routine collection persists a fenced run receipt" \
	"$(sql_value "SELECT count(*) FROM sync_runs WHERE run_type='sync' AND status='complete' AND fencing_token IS NOT NULL")" "1"

due=$(
	"$HELPER" sync-due --base "$BASE" --alias personal:default \
		--collector-id routine_runner --interval-seconds 86400 \
		--now 2099-01-02T00:04:00Z
)
assert_eq "sync-due deterministically identifies the configured stream" \
	"$(json_field "$due" scheduled)" "1"
assert_eq "a dry routine performs no provider request" \
	"$(json_field "$due" completed)" "0"

python3 - "$ROOT/index/social.db" <<'PY'
import sqlite3
import sys
import uuid
database = sqlite3.connect(sys.argv[1])
database.execute(
    "INSERT INTO sync_runs(run_id,connection_id,status,retry_after,stream,run_type,started_at,completed_at) VALUES(?,?,?,?,?,?,?,?)",
    (uuid.uuid4().hex, "conn_shared", "paused", "2099-01-03T00:00:00Z", "authored", "sync", "2099-01-02T00:00:00Z", "2099-01-02T00:00:00Z"),
)
database.commit()
database.close()
PY
rate_blocked=$(
	"$HELPER" sync-due --base "$BASE" --alias personal:default \
		--collector-id routine_runner --interval-seconds 86400 \
		--now 2099-01-02T12:00:00Z
)
assert_eq "provider reset time suppresses repeated routine retries" \
	"$(json_field "$rate_blocked" scheduled)" "0"

cat >"$TMP_DIR/snapshot.json" <<'JSON'
{
  "provider": "xapi",
  "observed_at": "2099-01-02T00:00:00Z",
  "object_type": "post",
  "remote_ids": [],
  "complete": true
}
JSON
if "$HELPER" reconcile --base "$BASE" --alias personal:default \
	--connection-id conn_shared --stream authored --collector-id routine_runner \
	--snapshot "$TMP_DIR/snapshot.json" --now 2099-01-02T00:00:00Z >/dev/null 2>&1; then
	assert_eq "reconciliation rejects a group-readable private snapshot" accepted rejected
else
	assert_eq "reconciliation rejects a group-readable private snapshot" rejected rejected
fi
chmod 0600 "$TMP_DIR/snapshot.json"
reconciled=$(
	"$HELPER" reconcile --base "$BASE" --alias personal:default \
		--connection-id conn_shared --stream authored --collector-id routine_runner \
		--snapshot "$TMP_DIR/snapshot.json" --now 2099-01-02T00:00:00Z
)
assert_eq "complete provider absence is recorded as missing" \
	"$(json_field "$reconciled" missing)" "1"
assert_eq "reconciliation is non-destructive" "$(sql_value 'SELECT count(*) FROM objects')" "1"
assert_eq "missing state remains auditable by stable provider identity" \
	"$(sql_value "SELECT state FROM reconciliation_observations WHERE remote_id='post101'")" "missing"
assert_eq "reconciliation produces a terminal run receipt" \
	"$(sql_value "SELECT status || ':' || run_type || ':' || resource_count FROM sync_runs WHERE run_type='reconcile'")" \
	"complete:reconcile:1"
assert_eq "complete reconciliation evidence is retained as an immutable raw batch" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE terminal_status='reconciliation'")" "1"

python3 - "$ROOT/index/social.db" <<'PY'
import sqlite3
import uuid
import sys
database = sqlite3.connect(sys.argv[1])
database.execute(
    "INSERT INTO sync_runs(run_id,connection_id,status,stream,run_type,started_at) VALUES(?,?,?,?,?,?)",
    (uuid.uuid4().hex, "conn_crash", "running", "authored", "sync", "2099-01-01T00:00:00Z"),
)
database.execute(
    "INSERT INTO collector_leases(connection_id,holder_id,fencing_token,lease_until,acquired_at,updated_at) VALUES(?,?,?,?,?,?)",
    ("conn_crash", "dead_runner", 4, "2099-01-01T00:01:00Z", "2099-01-01T00:00:00Z", "2099-01-01T00:00:00Z"),
)
database.commit()
database.close()
PY
recovered=$(
	"$HELPER" acquire-lease --base "$BASE" --alias personal:default \
		--connection-id conn_crash --collector-id recovery_runner --lease-seconds 60 \
		--now 2099-01-01T00:02:00Z
)
assert_eq "crash recovery advances beyond the abandoned generation" \
	"$(json_field "$recovered" fencing_token)" "5"
assert_eq "crash recovery closes the abandoned running receipt" \
	"$(sql_value "SELECT status || ':' || failure_class FROM sync_runs WHERE connection_id='conn_crash'")" \
	"failed:interrupted"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
