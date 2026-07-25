#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-x.sh — Guarded X adapter regression tests

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

cat >"$TMP_DIR/page-1.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "private-handle", "name": "Private Account"}},
  "pages": [{
    "status": 200,
    "observed_at": "2026-07-25T05:00:00Z",
    "data": [{"id": "102", "author_id": "acct42", "text": "second", "created_at": "2026-07-24T02:00:00Z"}],
    "includes": {"media": [{"media_key": "media102", "type": "photo", "url": "https://example.invalid/private.jpg"}]},
    "meta": {"next_token": "cursor-two"}
  }]
}
JSON

first_result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--budget 1 --media-policy none --fixture "$TMP_DIR/page-1.json")
assert_eq "page budget stops a backfill without retrying" \
	"$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$first_result")" "budget_exhausted"
assert_eq "first page advances only its stream cursor" \
	"$(sql_value "SELECT cursor || ':' || backfill_complete FROM sync_cursors WHERE stream='authored'")" "cursor-two:0"
assert_eq "none media policy persists no media metadata" "$(sql_value 'SELECT count(*) FROM media')" "0"

cat >"$TMP_DIR/page-2.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "private-handle"}},
  "pages": [{
    "status": 200,
    "observed_at": "2026-07-25T05:01:00Z",
    "data": [{"id": "101", "author_id": "acct42", "text": "first", "created_at": "2026-07-24T01:00:00Z"}],
    "meta": {}
  }]
}
JSON

second_result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--budget 2 --fixture "$TMP_DIR/page-2.json")
assert_eq "resumed pagination reaches exhaustion" \
	"$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$second_result")" "complete"
assert_eq "cursor and content commit atomically at exhaustion" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE stream='authored'")" "done:102:1"
assert_eq "pagination stores both immutable API pages" \
	"$(sql_value "SELECT (SELECT count(*) FROM objects) || ':' || (SELECT count(*) FROM fetch_batches WHERE stream='authored')")" "2:2"

cat >"$TMP_DIR/mentions.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "private-handle"}},
  "pages": [{
    "status": 200,
    "observed_at": "2026-07-25T05:02:00Z",
    "data": [{"id": "201", "author_id": "other77", "text": "mention", "created_at": "2026-07-25T05:02:00Z"}],
    "includes": {"media": [{"media_key": "media201", "type": "photo"}]},
    "meta": {}
  }]
}
JSON
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream mentions \
	--media-policy metadata --fixture "$TMP_DIR/mentions.json" >/dev/null
assert_eq "each stream owns an independent cursor" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_authored'")" "2"
assert_eq "metadata policy records no media binary reference" \
	"$(sql_value "SELECT hydration_state || ':' || coalesce(blob_ref,'none') FROM media WHERE remote_id='media201'")" "metadata_only:none"

cursor_before=$(sql_value "SELECT watermark FROM sync_cursors WHERE stream='authored'")
cat >"$TMP_DIR/rate-limit.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "private-handle"}},
  "pages": [{"status": 429, "retry_after": "2026-07-25T06:00:00Z"}]
}
JSON
rate_result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/rate-limit.json")
assert_eq "429 is terminal for this invocation" \
	"$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$rate_result")" "rate_limited"
assert_eq "terminal rate limit preserves the checkpoint" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE stream='authored'")" "$cursor_before"
assert_eq "rate reset is recorded once without raw diagnostics" \
	"$(sql_value "SELECT failure_class || ':' || retry_after || ':' || diagnostics FROM sync_runs ORDER BY rowid DESC LIMIT 1")" \
	"rate_limit:2026-07-25T06:00:00Z:sanitized"

cat >"$TMP_DIR/wrong-account.json" <<'JSON'
{"identity": {"data": {"id": "other99"}}, "pages": []}
JSON
batch_count=$(sql_value 'SELECT count(*) FROM fetch_batches')
if "$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/wrong-account.json" >/dev/null 2>&1; then
	assert_eq "account mismatch is rejected before collection" "accepted" "rejected"
else
	assert_eq "account mismatch is rejected before collection" "rejected" "rejected"
fi
assert_eq "account mismatch persists no raw page" "$(sql_value 'SELECT count(*) FROM fetch_batches')" "$batch_count"

assert_eq "adapter source reaches only guarded read commands" \
	"$(
		python3 - "$SCRIPT_DIR/../scripts/knowledge_social_x.py" <<'PY'
import ast
import sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
commands = []
for node in tree.body:
    if isinstance(node, ast.ClassDef) and node.name == "GuardedXurl":
        for method in node.body:
            if isinstance(method, ast.FunctionDef) and method.name in {"identity", "page"}:
                for child in ast.walk(method):
                    if isinstance(child, ast.Constant) and child.value in {"post", "reply", "like", "follow", "dm", "media"}:
                        commands.append(child.value)
print(",".join(sorted(set(commands))))
PY
	)" ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
