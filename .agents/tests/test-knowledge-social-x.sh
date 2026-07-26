#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-x.sh — Guarded X adapter regression tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
XURL_HELPER="${SCRIPT_DIR}/../scripts/xurl-helper.sh"
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
connection = sqlite3.connect(sys.argv[1])
print(connection.execute(sys.argv[2]).fetchone()[0])
connection.close()
PY
	return 0
}

raw_count() {
	python3 - "$ROOT/sources/social/raw" <<'PY'
import sys
from pathlib import Path
print(len(list(Path(sys.argv[1]).rglob("*.json.gz"))))
PY
	return 0
}

run_terminal_fixture() {
	local name="$1"
	local status="$2"
	local expected_failure="$3"
	local fixture="${TMP_DIR}/${name}.json"
	python3 - "$fixture" "$status" <<'PY'
import json
import sys
payload = {
    "identity": {"data": {"id": "acct42", "username": "fixture-handle"}},
    "pages": [{
        "status": int(sys.argv[2]),
        "observed_at": f"2026-07-25T05:{int(sys.argv[2]) % 60:02d}:00Z",
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	local result=""
	result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
		--connection-id conn_authored --account-id acct42 --stream authored \
		--fixture "$fixture")
	assert_eq "${status} response is terminal" "$(json_field "$result" status)" "failed"
	assert_eq "${status} response has a sanitized failure class" \
		"$(json_field "$result" failure_class)" "$expected_failure"
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])
from _knowledge_social_x import CursorState, STREAMS, stream_endpoint

expected = {
    "authored", "mentions", "likes", "bookmarks", "followers", "following",
    "owned_lists", "followed_lists", "list_memberships",
}
assert set(STREAMS) == expected
routes = {
    "owned_lists": "/2/users/acct42/owned_lists?",
    "followed_lists": "/2/users/acct42/followed_lists?",
    "list_memberships": "/2/users/acct42/list_memberships?",
}
for stream, route in routes.items():
    endpoint = stream_endpoint(stream, "acct42", CursorState(None, None, True))
    assert route in endpoint
    assert "max_results=100" in endpoint
    assert "list.fields=" in endpoint
    assert "pagination_token=" not in endpoint
    assert not any(flag in endpoint for flag in ("-X", "--request", "-d", "--data"))
    assert STREAMS[stream].refresh_after_complete
PY
assert_eq "X stream allowlist exposes only the three official List snapshots" \
	verified verified

cat >"$TMP_DIR/page-1.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "fixture-handle", "name": "Fixture Account"}},
  "pages": [{
    "expect_endpoint_contains": ["/2/users/acct42/tweets?", "max_results=100"],
    "response": {
      "status": 200,
      "observed_at": "2026-07-25T05:00:00Z",
      "data": [{"id": "102", "author_id": "acct42", "text": "second", "created_at": "2026-07-24T02:00:00Z"}],
      "meta": {"next_token": "cursor-two"}
    }
  }]
}
JSON

first_result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--budget 1 --media-policy none --fixture "$TMP_DIR/page-1.json")
assert_eq "request-unit budget stops a backfill without retrying" \
	"$(json_field "$first_result" status)" "budget_exhausted"
assert_eq "one successful request consumes one budget unit" \
	"$(json_field "$first_result" budget_units)" "1"
assert_eq "first page advances only its stream cursor" \
	"$(sql_value "SELECT cursor || ':' || backfill_complete FROM sync_cursors WHERE stream='authored'")" "cursor-two:0"
assert_eq "none media policy persists no media metadata" "$(sql_value 'SELECT count(*) FROM media')" "0"
assert_eq "API objects update the local FTS projection" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'second'")" "1"
assert_eq "partial coverage is recorded with the durable page" \
	"$(sql_value "SELECT status || ':' || cursor_exhausted FROM coverage_records WHERE stream='authored'")" "paused:0"
assert_eq "private account identity is absent from command output" \
	"$([[ "$first_result" == *fixture-handle* ]] && printf present || printf absent)" "absent"

cat >"$TMP_DIR/page-2.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "fixture-handle"}},
  "pages": [{
    "expect_endpoint_contains": ["pagination_token=cursor-two"],
    "response": {
      "status": 200,
      "observed_at": "2026-07-25T05:01:00Z",
      "data": [{"id": "101", "author_id": "acct42", "text": "first", "created_at": "2026-07-24T01:00:00Z"}],
      "meta": {}
    }
  }]
}
JSON

second_result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--budget 2 --fixture "$TMP_DIR/page-2.json")
assert_eq "resumed pagination reaches exhaustion" "$(json_field "$second_result" status)" "complete"
assert_eq "cursor and content commit atomically at exhaustion" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE stream='authored'")" "done:102:1"
assert_eq "pagination stores both immutable API pages" \
	"$(sql_value "SELECT (SELECT count(*) FROM objects) || ':' || (SELECT count(*) FROM fetch_batches WHERE stream='authored')")" "2:2"
assert_eq "complete coverage preserves the full backfill time range" \
	"$(sql_value "SELECT earliest_at || ':' || latest_at || ':' || status FROM coverage_records WHERE stream='authored'")" \
	"2026-07-24T01:00:00Z:2026-07-24T02:00:00Z:complete"

cat >"$TMP_DIR/delta.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "fixture-handle"}},
  "pages": [{
    "expect_endpoint_contains": ["since_id=102"],
    "response": {
      "status": 200,
      "observed_at": "2026-07-25T05:02:00Z",
      "data": [{"id": "103", "author_id": "acct42", "text": "delta", "created_at": "2026-07-25T04:00:00Z"}],
      "meta": {}
    }
  }]
}
JSON

delta_result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/delta.json")
assert_eq "delta collection uses the committed watermark" "$(json_field "$delta_result" status)" "complete"
assert_eq "delta collection advances the watermark" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE stream='authored'")" "103"

cat >"$TMP_DIR/mentions.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "fixture-handle"}},
  "pages": [{
    "status": 200,
    "observed_at": "2026-07-25T05:03:00Z",
    "data": [{"id": "201", "author_id": "other77", "text": "mention", "created_at": "2026-07-25T05:03:00Z", "attachments": {"media_keys": ["media201"]}}],
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
assert_eq "enabled streams are merged instead of overwritten" \
	"$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1])))' "$(sql_value "SELECT enabled_streams FROM connections WHERE connection_id='conn_authored'")")" \
	"authored,mentions"
assert_eq "mention provenance records the content author as actor" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id FROM activities WHERE activity_type='mentions'")" "other77:201"
assert_eq "metadata policy links media to its post without a binary blob" \
	"$(sql_value "SELECT hydration_state || ':' || coalesce(blob_ref,'none') || ':' || object_remote_id FROM media WHERE remote_id='media201'")" \
	"metadata_only:none:201"

cat >"$TMP_DIR/empty-authored.json" <<'JSON'
{"identity":{"data":{"id":"acct42"}},"pages":[{"status":200,"observed_at":"2026-07-25T05:04:00Z","data":[],"meta":{}}]}
JSON
cat >"$TMP_DIR/empty-mentions.json" <<'JSON'
{"identity":{"data":{"id":"acct42"}},"pages":[{"status":200,"observed_at":"2026-07-25T05:04:00Z","data":[],"meta":{}}]}
JSON
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_empty --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/empty-authored.json" >/dev/null
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_empty --account-id acct42 --stream mentions \
	--fixture "$TMP_DIR/empty-mentions.json" >/dev/null
assert_eq "identical provider responses remain distinct per request stream" \
	"$(sql_value "SELECT count(*) || ':' || count(DISTINCT response_hash) FROM fetch_batches WHERE connection_id='conn_empty'")" "2:2"

cat >"$TMP_DIR/followers.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42"}},
  "pages": [{
    "status": 200,
    "observed_at": "2026-07-25T05:05:00Z",
    "data": [{"id": "follower77", "username": "follower"}],
    "meta": {}
  }]
}
JSON
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_relationship --account-id acct42 --stream followers \
	--fixture "$TMP_DIR/followers.json" >/dev/null
assert_eq "follower activity preserves relationship direction and account scope" \
	"$(sql_value "SELECT remote_id || ':' || actor_remote_id || ':' || object_remote_id FROM activities WHERE activity_type='followers'")" \
	"acct42-followers-follower77:follower77:acct42"

cat >"$TMP_DIR/no-delta.json" <<'JSON'
{"identity":{"data":{"id":"acct42"}},"pages":[]}
JSON
before_relationship_batches=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_relationship'")
unsupported_result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_relationship --account-id acct42 --stream followers \
	--fixture "$TMP_DIR/no-delta.json")
assert_eq "streams without an official delta parameter report the gap" \
	"$(json_field "$unsupported_result" status)" "delta_unavailable"
assert_eq "unsupported delta performs no provider page request" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_relationship'")" "$before_relationship_batches"
assert_eq "unsupported delta is recorded against its stream" \
	"$(sql_value "SELECT failure_class || ':' || diagnostics FROM sync_runs WHERE connection_id='conn_relationship' ORDER BY rowid DESC LIMIT 1")" \
	'delta_not_supported:{"stream":"followers"}'

cat >"$TMP_DIR/following.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42"}},
  "pages": [{"status":200,"observed_at":"2026-07-25T05:06:00Z","data":[{"id":"target88","username":"target"}],"meta":{}}]
}
JSON
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_relationship --account-id acct42 --stream following \
	--fixture "$TMP_DIR/following.json" >/dev/null
assert_eq "following activity preserves relationship direction" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id FROM activities WHERE activity_type='following'")" "acct42:target88"

cat >"$TMP_DIR/owned-lists-1.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42"}},
  "pages": [{
    "expect_endpoint_contains": ["/2/users/acct42/owned_lists?", "max_results=100", "list.fields="],
    "response": {
      "status": 200,
      "observed_at": "2026-07-25T05:07:00Z",
      "data": [{
        "id": "9002", "name": "Research", "description": "Private sources",
        "created_at": "2026-07-20T10:00:00Z", "owner_id": "acct42",
        "private": true, "follower_count": 4, "member_count": 12,
        "unexpected_field": "discarded"
      }],
      "meta": {"next_token": "owned-cursor"}
    }
  }]
}
JSON
owned_first=$(
	"$HELPER" sync-x --base "$BASE" --alias personal:default \
		--connection-id conn_lists --account-id acct42 --stream owned_lists \
		--budget 1 --fixture "$TMP_DIR/owned-lists-1.json"
)
assert_eq "owned Lists stop at the request budget with a resumable cursor" \
	"$(json_field "$owned_first" status):$(sql_value "SELECT cursor || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_lists' AND stream='owned_lists'")" \
	"budget_exhausted:owned-cursor:0"
assert_eq "X Lists normalize only allowlisted fields into a custom feed" \
	"$(sql_value "SELECT object_type || ':' || provider_json FROM objects WHERE provider='xapi' AND remote_id='9002'")" \
	'custom_feed:{"follower_count":4,"member_count":12,"owner_id":"acct42","private":true}'
assert_eq "owned List relationships preserve account-to-list direction" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id || ':' || coalesce(occurred_at,'observed') FROM activities WHERE activity_type='owned_lists' AND remote_id='acct42-owned_lists-9002'")" \
	"acct42:9002:observed"

cat >"$TMP_DIR/owned-lists-2.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42"}},
  "pages": [{
    "expect_endpoint_contains": ["pagination_token=owned-cursor"],
    "response": {
      "status": 200,
      "observed_at": "2026-07-25T05:08:00Z",
      "data": [{
        "id": "9001", "name": "Operations", "owner_id": "acct42",
        "private": false, "follower_count": 2, "member_count": 8
      }],
      "meta": {}
    }
  }]
}
JSON
owned_second=$(
	"$HELPER" sync-x --base "$BASE" --alias personal:default \
		--connection-id conn_lists --account-id acct42 --stream owned_lists \
		--fixture "$TMP_DIR/owned-lists-2.json"
)
assert_eq "owned List pagination resumes and preserves its first watermark" \
	"$(json_field "$owned_second" status):$(sql_value "SELECT coalesce(cursor,'done') || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_lists' AND stream='owned_lists'")" \
	"complete:done:9002:1"
assert_eq "both owned Lists are searchable provider-neutral custom feeds" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='xapi' AND object_type='custom_feed' AND remote_id IN ('9001','9002')")" "2"

cat >"$TMP_DIR/owned-lists-snapshot.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42"}},
  "pages": [{
    "expect_endpoint_contains": ["/2/users/acct42/owned_lists?"],
    "response": {
      "status": 200,
      "observed_at": "2026-07-25T05:09:00Z",
      "data": [{
        "id": "9002", "name": "Research", "description": "Private sources",
        "created_at": "2026-07-20T10:00:00Z", "owner_id": "acct42",
        "private": true, "follower_count": 4, "member_count": 12
      }],
      "meta": {}
    }
  }]
}
JSON
owned_batches_before=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_lists' AND stream='owned_lists'")
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_lists --account-id acct42 --stream owned_lists \
	--fixture "$TMP_DIR/owned-lists-snapshot.json" >/dev/null
owned_batches_once=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_lists' AND stream='owned_lists'")
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_lists --account-id acct42 --stream owned_lists \
	--fixture "$TMP_DIR/owned-lists-snapshot.json" >/dev/null
owned_batches_replayed=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_lists' AND stream='owned_lists'")
assert_eq "completed List snapshots rescan from the beginning" \
	"$((owned_batches_once - owned_batches_before)):$(sql_value "SELECT backfill_complete || ':' || coalesce(cursor,'reset') FROM sync_cursors WHERE connection_id='conn_lists' AND stream='owned_lists'")" \
	"1:1:reset"
assert_eq "exact List snapshot replay is content-addressed and idempotent" \
	"$owned_batches_replayed" "$owned_batches_once"

cat >"$TMP_DIR/followed-lists.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42"}},
  "pages": [{
    "expect_endpoint_contains": ["/2/users/acct42/followed_lists?"],
    "response": {
      "status": 200, "observed_at": "2026-07-25T05:10:00Z",
      "data": [{"id": "9100", "name": "Followed feed", "owner_id": "owner77", "private": false}],
      "meta": {}
    }
  }]
}
JSON
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_lists --account-id acct42 --stream followed_lists \
	--fixture "$TMP_DIR/followed-lists.json" >/dev/null
assert_eq "followed List relationships preserve selected-account direction" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id FROM activities WHERE activity_type='followed_lists'")" \
	"acct42:9100"

cat >"$TMP_DIR/list-memberships.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42"}},
  "pages": [{
    "expect_endpoint_contains": ["/2/users/acct42/list_memberships?"],
    "response": {
      "status": 200, "observed_at": "2026-07-25T05:11:00Z",
      "data": [{"id": "9200", "name": "Member feed", "owner_id": "owner88", "private": true}],
      "meta": {}
    }
  }]
}
JSON
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_lists --account-id acct42 --stream list_memberships \
	--fixture "$TMP_DIR/list-memberships.json" >/dev/null
assert_eq "List membership direction is stable from list to selected account" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id FROM activities WHERE activity_type='list_memberships'")" \
	"9200:acct42"
assert_eq "each X List category owns an independent checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_lists'")" "3"

list_batches_before=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_lists'")
cat >"$TMP_DIR/malformed-list.json" <<'JSON'
{"identity":{"data":{"id":"acct42"}},"pages":[{"status":200,"observed_at":"2026-07-25T05:12:00Z","data":[{"id":"9300","name":42}],"meta":{}}]}
JSON
if "$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_lists --account-id acct42 --stream owned_lists \
	--fixture "$TMP_DIR/malformed-list.json" >/dev/null 2>&1; then
	assert_eq "malformed X Lists fail before persistence" accepted rejected
else
	assert_eq "malformed X Lists fail before persistence" rejected rejected
fi
assert_eq "malformed X Lists leave prior evidence and checkpoints safe" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_lists'"):$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_lists' AND stream='owned_lists'")" \
	"${list_batches_before}:9002"

cursor_before=$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored'")
cat >"$TMP_DIR/rate-limit.json" <<'JSON'
{
  "identity": {"data": {"id": "acct42", "username": "fixture-handle"}},
  "pages": [{"status": 429, "observed_at": "2026-07-25T05:07:00Z", "retry_after": 1784959200}]
}
JSON
rate_result=$("$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/rate-limit.json")
assert_eq "429 is terminal for this invocation" "$(json_field "$rate_result" status)" "rate_limited"
assert_eq "terminal rate limit preserves the checkpoint" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored'")" "$cursor_before"
assert_eq "rate reset is recorded once with stream-only diagnostics" \
	"$(sql_value "SELECT failure_class || ':' || retry_after || ':' || diagnostics FROM sync_runs WHERE connection_id='conn_authored' ORDER BY rowid DESC LIMIT 1")" \
	'rate_limit:1784959200:{"stream":"authored"}'
assert_eq "terminal response is immutable evidence without erasing completion" \
	"$(sql_value "SELECT status || ':' || cursor_exhausted FROM coverage_records WHERE connection_id='conn_authored' AND stream='authored'")" "paused:1"

run_terminal_fixture unauthorized 401 authorization
run_terminal_fixture forbidden 403 authorization
run_terminal_fixture missing 404 unavailable
run_terminal_fixture provider 500 provider
assert_eq "terminal failures never advance the cursor" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored'")" "$cursor_before"

cat >"$TMP_DIR/first-terminal.json" <<'JSON'
{"identity":{"data":{"id":"acct42"}},"pages":[{"status":500,"observed_at":"2026-07-25T05:09:00Z"}]}
JSON
"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_first_terminal --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/first-terminal.json" >/dev/null
assert_eq "first terminal response binds the verified account" \
	"$(sql_value "SELECT remote_account_id FROM connections WHERE connection_id='conn_first_terminal'")" "acct42"
terminal_batch_count=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_first_terminal'")
cat >"$TMP_DIR/terminal-rebind.json" <<'JSON'
{"identity":{"data":{"id":"other99"}},"pages":[]}
JSON
if "$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_first_terminal --account-id other99 --stream authored \
	--fixture "$TMP_DIR/terminal-rebind.json" >/dev/null 2>&1; then
	assert_eq "terminal-bound connection cannot be rebound" "accepted" "rejected"
else
	assert_eq "terminal-bound connection cannot be rebound" "rejected" "rejected"
fi
assert_eq "terminal rebind rejection stores no additional raw evidence" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_first_terminal'")" "$terminal_batch_count"

batch_count=$(sql_value 'SELECT count(*) FROM fetch_batches')
cat >"$TMP_DIR/malformed.json" <<'JSON'
{"identity":{"data":{"id":"acct42"}},"pages":[{"status":200,"data":{"id":"not-an-array"},"meta":{}}]}
JSON
if "$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/malformed.json" >/dev/null 2>&1; then
	assert_eq "malformed page is rejected before persistence" "accepted" "rejected"
else
	assert_eq "malformed page is rejected before persistence" "rejected" "rejected"
fi
assert_eq "malformed page advances no batch or checkpoint" \
	"$(sql_value 'SELECT count(*) FROM fetch_batches'):$([[ "$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored'")" == "$cursor_before" ]] && printf stable || printf changed)" \
	"${batch_count}:stable"

cat >"$TMP_DIR/identity-credential.json" <<'JSON'
{"identity":{"data":{"id":"acct42","access_token":"must-not-persist"}},"pages":[]}
JSON
if "$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/identity-credential.json" >/dev/null 2>&1; then
	assert_eq "credential-shaped identity data is rejected" "accepted" "rejected"
else
	assert_eq "credential-shaped identity data is rejected" "rejected" "rejected"
fi
assert_eq "rejected identity creates no raw evidence" "$(sql_value 'SELECT count(*) FROM fetch_batches')" "$batch_count"

cat >"$TMP_DIR/page-credential.json" <<'JSON'
{"identity":{"data":{"id":"acct42"}},"pages":[{"status":200,"authorization":"must-not-persist","data":[],"meta":{}}]}
JSON
if "$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/page-credential.json" >/dev/null 2>&1; then
	assert_eq "credential-shaped page data is rejected" "accepted" "rejected"
else
	assert_eq "credential-shaped page data is rejected" "rejected" "rejected"
fi
assert_eq "rejected page creates no raw evidence" "$(sql_value 'SELECT count(*) FROM fetch_batches')" "$batch_count"

cat >"$TMP_DIR/wrong-account.json" <<'JSON'
{"identity":{"data":{"id":"other99"}},"pages":[]}
JSON
if "$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id acct42 --stream authored \
	--fixture "$TMP_DIR/wrong-account.json" >/dev/null 2>&1; then
	assert_eq "selected account mismatch is rejected before collection" "accepted" "rejected"
else
	assert_eq "selected account mismatch is rejected before collection" "rejected" "rejected"
fi

cat >"$TMP_DIR/rebind-account.json" <<'JSON'
{"identity":{"data":{"id":"other99"}},"pages":[]}
JSON
if "$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id other99 --stream authored \
	--fixture "$TMP_DIR/rebind-account.json" >/dev/null 2>&1; then
	assert_eq "existing connection cannot be rebound to another verified account" "accepted" "rejected"
else
	assert_eq "existing connection cannot be rebound to another verified account" "rejected" "rejected"
fi
assert_eq "account rejection leaves connection and raw evidence unchanged" \
	"$(sql_value "SELECT remote_account_id FROM connections WHERE connection_id='conn_authored'"):$(sql_value 'SELECT count(*) FROM fetch_batches')" \
	"acct42:${batch_count}"

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/xurl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${XURL_LOG:?}"
case "$*" in
*" whoami" | whoami)
	printf '%s\n' '{"data":{"id":"acct42","username":"fixture-handle"}}'
	;;
*"/2/users/acct42/tweets?"*)
	printf '%s\n' '{"status":200,"observed_at":"2026-07-25T05:08:00Z","data":[{"id":"301","author_id":"acct42","text":"guarded path","created_at":"2026-07-25T05:08:00Z"}],"meta":{}}'
	;;
*"/2/users/acct42/owned_lists?"*)
	printf '%s\n' '{"status":200,"observed_at":"2026-07-25T05:13:00Z","data":[{"id":"9401","name":"Owned fixture","owner_id":"acct42"}],"meta":{}}'
	;;
*"/2/users/acct42/followed_lists?"*)
	printf '%s\n' '{"status":200,"observed_at":"2026-07-25T05:14:00Z","data":[{"id":"9402","name":"Followed fixture","owner_id":"owner77"}],"meta":{}}'
	;;
*"/2/users/acct42/list_memberships?"*)
	printf '%s\n' '{"status":200,"observed_at":"2026-07-25T05:15:00Z","data":[{"id":"9403","name":"Membership fixture","owner_id":"owner88"}],"meta":{}}'
	;;
*)
	exit 7
	;;
esac
SH
chmod 0700 "$TMP_DIR/bin/xurl"
if XURL_LOG="$TMP_DIR/xurl.log" PATH="$TMP_DIR/bin:$PATH" \
	"$XURL_HELPER" run -- /2/lists -d '{}' >/dev/null 2>&1; then
	assert_eq "raw xurl request bodies cannot bypass write confirmation" accepted rejected
else
	assert_eq "raw xurl request bodies cannot bypass write confirmation" rejected rejected
fi
XURL_LOG="$TMP_DIR/xurl.log" PATH="$TMP_DIR/bin:$PATH" \
	"$HELPER" sync-x --base "$BASE" --alias personal:default \
	--connection-id conn_guarded --account-id acct42 --stream authored \
	--app fixture-app --username @fixture >/dev/null
for list_stream in owned_lists followed_lists list_memberships; do
	XURL_LOG="$TMP_DIR/xurl.log" PATH="$TMP_DIR/bin:$PATH" \
		"$HELPER" sync-x --base "$BASE" --alias personal:default \
		--connection-id conn_guarded_lists --account-id acct42 \
		--stream "$list_stream" --app fixture-app --username @fixture >/dev/null
done
guard_result=$(
	python3 - "$TMP_DIR/xurl.log" <<'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
writes = {
    "post", "reply", "quote", "delete", "like", "follow", "dm", "media",
    "--confirm-write", "-X", "--request", "-d", "--data", "-F", "--file",
}
routes = [
    "/2/users/acct42/tweets?",
    "/2/users/acct42/owned_lists?",
    "/2/users/acct42/followed_lists?",
    "/2/users/acct42/list_memberships?",
]
identities = [line for line in lines if line.endswith(" whoami")]
reads = [line for line in lines if not line.endswith(" whoami")]
safe = (
    len(lines) == 8
    and len(identities) == 4
    and len(reads) == 4
    and all(route in line for route, line in zip(routes, reads, strict=True))
    and not any(word in line.split() for word in writes for line in lines)
)
print("read-only" if safe else "unsafe")
PY
)
assert_eq "live adapter route reaches only guarded whoami and raw-read commands" "$guard_result" "read-only"
assert_eq "guarded route persists searchable provider content" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'guarded'")" "1"
assert_eq "guarded live List routes persist only the three allowlisted feeds" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='xapi' AND object_type='custom_feed' AND remote_id IN ('9401','9402','9403')")" "3"

assert_eq "all immutable raw paths remain opaque" \
	"$(
		python3 - "$ROOT/sources/social/raw" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
bad = [path for path in root.rglob("*.json.gz") if "fixture-handle" in path.as_posix()]
print("opaque" if not bad else "revealing")
PY
	)" "opaque"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
