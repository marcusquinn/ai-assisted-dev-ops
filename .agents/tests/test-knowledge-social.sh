#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social.sh — Social archive/store regression tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
CORPUS_ROOT="${BASE}/_knowledge"
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

store_snapshot() {
	local root="$1"
	python3 - "$root" <<'PY'
import hashlib
import json
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
snapshot = {}
for path in sorted(root.rglob("*")):
    file_stat = path.lstat()
    record = {
        "mode": stat.S_IMODE(file_stat.st_mode),
        "mtime_ns": file_stat.st_mtime_ns,
        "size": file_stat.st_size,
    }
    if path.is_file():
        record["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    snapshot[path.relative_to(root).as_posix()] = record
print(json.dumps(snapshot, sort_keys=True, separators=(",", ":")))
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
mkdir -p "$CORPUS_ROOT"
chmod 0700 "$BASE" "$CORPUS_ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null
assert_eq "schema is versioned" "$(sql_value 'PRAGMA user_version')" "8"
assert_eq "all provider-neutral and local-operation tables exist" "$(sql_value "SELECT count(*) FROM sqlite_master WHERE name IN ('connections','accounts','objects','activities','media','fetch_batches','sync_cursors','sync_runs','tombstones','annotations','coverage_records','objects_fts','outbound_operations','outbound_approvals','outbound_attempts','outbound_reconciliations','notification_state')")" "17"

first_result=$("$HELPER" import-archive --base "$BASE" --alias personal:default --archive "$ARCHIVE")
first_hash=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["batch_id"])' "$first_result")
assert_eq "archive imports one canonical object" "$(sql_value 'SELECT count(*) FROM objects')" "1"
assert_eq "archive imports one activity" "$(sql_value 'SELECT count(*) FROM activities')" "1"
assert_eq "coverage records completeness" "$(sql_value "SELECT status || ':' || cursor_exhausted FROM coverage_records WHERE stream='authored'")" "complete:1"
assert_eq "FTS projection is searchable" "$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'searchable'")" "1"
assert_eq "raw evidence hash names immutable batch" "$(sql_value 'SELECT response_hash FROM fetch_batches')" "$first_hash"
assert_eq "raw batch has one corpus-scoped canonical source" "$(sql_value 'SELECT count(*) FROM evidence_sources WHERE evidence_id=(SELECT evidence_id FROM fetch_batches)')" "1"
assert_eq "normalized rows remain projections of canonical evidence" "$(sql_value 'SELECT count(*) FROM canonical_evidence_projections')" "2"

"$HELPER" import-archive --base "$BASE" --alias personal:default --archive "$ARCHIVE" >/dev/null
assert_eq "re-import is idempotent" "$(sql_value "SELECT (SELECT count(*) FROM fetch_batches) || ':' || (SELECT count(*) FROM objects) || ':' || (SELECT count(*) FROM activities)")" "1:1:1"

python3 - "$CORPUS_ROOT/index/social.db" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("DELETE FROM objects_fts")
connection.commit()
connection.close()
PY
"$HELPER" rebuild --base "$BASE" --alias personal:default >/dev/null
assert_eq "projection rebuilds from canonical rows" "$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'evidence'")" "1"
python3 - "$BASE/catalog.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("UPDATE corpus_grants SET status='inactive' WHERE capability='knowledge.write'")
connection.commit()
connection.close()
PY
coverage_snapshot_before=$(store_snapshot "$CORPUS_ROOT")
coverage_result=$("$HELPER" coverage --base "$BASE" --alias personal:default)
coverage_snapshot_after=$(store_snapshot "$CORPUS_ROOT")
assert_eq "coverage survives restart with only a read grant" "$(python3 -c 'import json,sys; data=json.loads(sys.argv[1]); print(data[0]["batch_id"] + ":" + data[0]["status"])' "$coverage_result")" "${first_hash}:complete"
assert_eq "read-only coverage leaves the store unchanged" "$coverage_snapshot_after" "$coverage_snapshot_before"
: >"$CORPUS_ROOT/index/social.db-wal"
chmod 0600 "$CORPUS_ROOT/index/social.db-wal"
if "$HELPER" coverage --base "$BASE" --alias personal:default >/dev/null 2>&1; then
	assert_eq "coverage rejects active or uncheckpointed journal state" "accepted" "rejected"
else
	assert_eq "coverage rejects active or uncheckpointed journal state" "rejected" "rejected"
fi
rm "$CORPUS_ROOT/index/social.db-wal"
python3 - "$BASE/catalog.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("UPDATE corpus_grants SET status='active' WHERE capability='knowledge.write'")
connection.commit()
connection.close()
PY
assert_eq "database is private" "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$CORPUS_ROOT/index/social.db")" "0o600"

corrected_archive="${TMP_DIR}/corrected.json"
python3 - "$ARCHIVE" "$corrected_archive" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
data["activities"][0]["actor_remote_id"] = "acct-corrected"
json.dump(data, open(sys.argv[2], "w", encoding="utf-8"))
PY
"$HELPER" import-archive --base "$BASE" --alias personal:default --archive "$corrected_archive" >/dev/null
assert_eq "re-import refreshes an activity actor" "$(sql_value "SELECT actor_remote_id FROM activities WHERE remote_id='activity-1'")" "acct-corrected"

unsafe_archive="${TMP_DIR}/unsafe.json"
python3 - "$ARCHIVE" "$unsafe_archive" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
data["connection_id"] = "../revealing-name"
json.dump(data, open(sys.argv[2], "w", encoding="utf-8"))
PY
if "$HELPER" import-archive --base "$BASE" --alias personal:default --archive "$unsafe_archive" >/dev/null 2>&1; then
	assert_eq "path traversal connection ID is rejected" "accepted" "rejected"
else
	assert_eq "path traversal connection ID is rejected" "rejected" "rejected"
fi

credential_keys=(accessToken clientSecret token secret sessionCookie bearerToken oauthToken setCookie privateKey secretAccessKey x-api-key)
accepted_credential_keys=""
for credential_key in "${credential_keys[@]}"; do
	credential_archive="${TMP_DIR}/credential-${credential_key}.json"
	python3 - "$ARCHIVE" "$credential_archive" "$credential_key" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
data["provider_json"] = {sys.argv[3]: "must-not-persist"}
json.dump(data, open(sys.argv[2], "w", encoding="utf-8"))
PY
	if "$HELPER" import-archive --base "$BASE" --alias personal:default --archive "$credential_archive" >/dev/null 2>&1; then
		accepted_credential_keys="${accepted_credential_keys}${credential_key},"
	fi
done
assert_eq "credential key variants are rejected before raw persistence" "$accepted_credential_keys" ""
assert_eq "rejected archives create no raw batches" "$(python3 -c 'from pathlib import Path; import sys; print(len(list(Path(sys.argv[1]).rglob("*.json.gz"))))' "$CORPUS_ROOT/sources/social/raw")" "2"

unsupported_archive="${TMP_DIR}/unsupported-schema.json"
python3 - "$ARCHIVE" "$unsupported_archive" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
data["objects"][0]["text"] = "must not persist under an unsupported schema"
json.dump(data, open(sys.argv[2], "w", encoding="utf-8"))
PY
python3 - "$CORPUS_ROOT/index/social.db" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA user_version=999")
connection.close()
PY
if "$HELPER" import-archive --base "$BASE" --alias personal:default --archive "$unsupported_archive" >/dev/null 2>&1; then
	assert_eq "unsupported schema rejects import before raw persistence" "accepted" "rejected"
else
	assert_eq "unsupported schema rejects import before raw persistence" "rejected" "rejected"
fi
assert_eq "unsupported schema creates no raw batch" "$(python3 -c 'from pathlib import Path; import sys; print(len(list(Path(sys.argv[1]).rglob("*.json.gz"))))' "$CORPUS_ROOT/sources/social/raw")" "2"
python3 - "$CORPUS_ROOT/index/social.db" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA user_version=8")
connection.close()
PY

AUTH_BASE="${TMP_DIR}/authorization"
AUTH_ROOT="${AUTH_BASE}/_knowledge"
AUTH_CATALOG="${AUTH_BASE}/catalog.db"
mkdir -p "$AUTH_ROOT"
chmod 0700 "$AUTH_BASE" "$AUTH_ROOT"
"$CORPUS_HELPER" provision --base "$AUTH_BASE" >/dev/null
if "$HELPER" coverage --base "$AUTH_BASE" --alias personal:default >/dev/null 2>&1; then
	assert_eq "coverage rejects an absent store" "accepted" "rejected"
else
	assert_eq "coverage rejects an absent store" "rejected" "rejected"
fi
assert_eq "coverage creates no database" "$([[ -e "$AUTH_ROOT/index" ]] && printf present || printf absent)" "absent"
python3 - "$AUTH_CATALOG" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("UPDATE corpus_grants SET status='inactive' WHERE capability='knowledge.write'")
connection.commit()
connection.close()
PY
if "$HELPER" provision --base "$AUTH_BASE" --alias personal:default >/dev/null 2>&1; then
	assert_eq "inactive write grant fails before store creation" "accepted" "rejected"
else
	assert_eq "inactive write grant fails before store creation" "rejected" "rejected"
fi
assert_eq "inactive grant creates no database" "$([[ -e "$AUTH_ROOT/index" ]] && printf present || printf absent)" "absent"

python3 - "$AUTH_CATALOG" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("DELETE FROM corpus_grants WHERE capability='knowledge.write'")
connection.commit()
connection.close()
PY
if "$HELPER" provision --base "$AUTH_BASE" --alias personal:default >/dev/null 2>&1; then
	assert_eq "missing write grant fails before store creation" "accepted" "rejected"
else
	assert_eq "missing write grant fails before store creation" "rejected" "rejected"
fi
assert_eq "missing grant creates no database" "$([[ -e "$AUTH_ROOT/index" ]] && printf present || printf absent)" "absent"

FORGED_ROOT="${TMP_DIR}/forged-root"
if "$HELPER" provision --base "$AUTH_BASE" --corpus-root "$FORGED_ROOT" >/dev/null 2>&1; then
	assert_eq "physical corpus root argument is rejected" "accepted" "rejected"
else
	assert_eq "physical corpus root argument is rejected" "rejected" "rejected"
fi
assert_eq "forged root creates no directory" "$([[ -e "$FORGED_ROOT" ]] && printf present || printf absent)" "absent"

OUTSIDE="${TMP_DIR}/outside"
mkdir -p "$OUTSIDE"
chmod 0700 "$OUTSIDE"
python3 - "$AUTH_CATALOG" "$OUTSIDE" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute(
    "INSERT INTO corpus_grants SELECT corpus_id,principal_id,role,'knowledge.write',scope,'active' "
    "FROM corpus_grants WHERE capability='knowledge.read'"
)
connection.execute("UPDATE corpora SET location_ref=?", (sys.argv[2],))
connection.commit()
connection.close()
PY
if "$HELPER" provision --base "$AUTH_BASE" --alias personal:default >/dev/null 2>&1; then
	assert_eq "out-of-base catalog root is rejected" "accepted" "rejected"
else
	assert_eq "out-of-base catalog root is rejected" "rejected" "rejected"
fi
assert_eq "out-of-base root creates no social store" "$([[ -e "$OUTSIDE/index" ]] && printf present || printf absent)" "absent"

ln -s "$OUTSIDE" "${AUTH_BASE}/linked-root"
python3 - "$AUTH_CATALOG" "${AUTH_BASE}/linked-root" <<'PY'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.execute("UPDATE corpora SET location_ref=?", (sys.argv[2],))
connection.commit()
connection.close()
PY
if "$HELPER" provision --base "$AUTH_BASE" --alias personal:default >/dev/null 2>&1; then
	assert_eq "symlinked catalog root is rejected" "accepted" "rejected"
else
	assert_eq "symlinked catalog root is rejected" "rejected" "rejected"
fi
assert_eq "symlinked root creates no social store" "$([[ -e "$OUTSIDE/index" ]] && printf present || printf absent)" "absent"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
