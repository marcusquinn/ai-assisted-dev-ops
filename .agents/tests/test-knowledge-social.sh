#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social.sh — Social archive/store regression tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
TMP_DIR=$(mktemp -d)
CORPUS_ROOT="${TMP_DIR}/corpus"
ARCHIVE="${TMP_DIR}/archive.json"
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

sql_value() {
	local query="$1"
	python3 - "$CORPUS_ROOT/index/social.db" "$query" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
print(connection.execute(sys.argv[2]).fetchone()[0])
connection.close()
PY
	return 0
}

cat >"$ARCHIVE" <<'JSON'
{
  "provider": "xapi",
  "connection_id": "conn_0123456789abcdef",
  "remote_account_id": "acct-42",
  "exported_at": "2026-07-25T00:00:00Z",
  "enabled_streams": ["authored"],
  "policy": {"media_hydration": false},
  "accounts": [{"remote_id": "acct-42", "handle": "mutable", "display_name": "Example", "observed_at": "2026-07-25T00:00:00Z"}],
  "objects": [{"object_type": "post", "remote_id": "post-1", "account_remote_id": "acct-42", "text": "provider neutral searchable evidence", "created_at": "2024-01-02T00:00:00Z", "observed_at": "2026-07-25T00:00:00Z", "evidence_class": "authored"}],
  "activities": [{"activity_type": "authored", "remote_id": "activity-1", "actor_remote_id": "acct-42", "object_remote_id": "post-1", "occurred_at": "2024-01-02T00:00:00Z", "observed_at": "2026-07-25T00:00:00Z", "state": "active"}],
  "media": [],
  "coverage": [{"stream": "authored", "earliest_at": "2024-01-02T00:00:00Z", "latest_at": "2024-01-02T00:00:00Z", "cursor_exhausted": true, "status": "complete", "observed_at": "2026-07-25T00:00:00Z"}]
}
JSON

printf 'Social corpus tests\n'
"$HELPER" provision --corpus-root "$CORPUS_ROOT" >/dev/null
assert_eq "schema is versioned" "$(sql_value 'PRAGMA user_version')" "1"
assert_eq "all provider-neutral tables exist" "$(sql_value "SELECT count(*) FROM sqlite_master WHERE name IN ('connections','accounts','objects','activities','media','fetch_batches','sync_cursors','sync_runs','tombstones','annotations','coverage_records','objects_fts')")" "12"

first_result=$("$HELPER" import-archive --corpus-root "$CORPUS_ROOT" --archive "$ARCHIVE")
first_hash=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["batch_id"])' "$first_result")
assert_eq "archive imports one canonical object" "$(sql_value 'SELECT count(*) FROM objects')" "1"
assert_eq "archive imports one activity" "$(sql_value 'SELECT count(*) FROM activities')" "1"
assert_eq "coverage records completeness" "$(sql_value "SELECT status || ':' || cursor_exhausted FROM coverage_records WHERE stream='authored'")" "complete:1"
assert_eq "FTS projection is searchable" "$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'searchable'")" "1"
assert_eq "raw evidence hash names immutable batch" "$(sql_value 'SELECT response_hash FROM fetch_batches')" "$first_hash"

"$HELPER" import-archive --corpus-root "$CORPUS_ROOT" --archive "$ARCHIVE" >/dev/null
assert_eq "re-import is idempotent" "$(sql_value "SELECT (SELECT count(*) FROM fetch_batches) || ':' || (SELECT count(*) FROM objects) || ':' || (SELECT count(*) FROM activities)")" "1:1:1"

python3 - "$CORPUS_ROOT/index/social.db" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("DELETE FROM objects_fts")
connection.commit()
connection.close()
PY
"$HELPER" rebuild --corpus-root "$CORPUS_ROOT" >/dev/null
assert_eq "projection rebuilds from canonical rows" "$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'evidence'")" "1"
assert_eq "coverage survives restart and rebuild" "$("$HELPER" coverage --corpus-root "$CORPUS_ROOT" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data[0]["batch_id"] + ":" + data[0]["status"])')" "${first_hash}:complete"
assert_eq "database is private" "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$CORPUS_ROOT/index/social.db")" "0o600"

unsafe_archive="${TMP_DIR}/unsafe.json"
python3 - "$ARCHIVE" "$unsafe_archive" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
data["connection_id"] = "../revealing-name"
json.dump(data, open(sys.argv[2], "w", encoding="utf-8"))
PY
if "$HELPER" import-archive --corpus-root "$CORPUS_ROOT" --archive "$unsafe_archive" >/dev/null 2>&1; then
	assert_eq "path traversal connection ID is rejected" "accepted" "rejected"
else
	assert_eq "path traversal connection ID is rejected" "rejected" "rejected"
fi

credential_archive="${TMP_DIR}/credential.json"
python3 - "$ARCHIVE" "$credential_archive" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
data["provider_json"] = {"access_token": "must-not-persist"}
json.dump(data, open(sys.argv[2], "w", encoding="utf-8"))
PY
if "$HELPER" import-archive --corpus-root "$CORPUS_ROOT" --archive "$credential_archive" >/dev/null 2>&1; then
	assert_eq "credential material is rejected before raw persistence" "accepted" "rejected"
else
	assert_eq "credential material is rejected before raw persistence" "rejected" "rejected"
fi
assert_eq "rejected archives create no raw batches" "$(python3 -c 'from pathlib import Path; import sys; print(len(list(Path(sys.argv[1]).rglob("*.json.gz"))))' "$CORPUS_ROOT/sources/social/raw")" "1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
