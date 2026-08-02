#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-youtube.sh — Guarded YouTube OAuth collector tests

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

with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute(sys.argv[2]).fetchone()[0])
PY
	return 0
}

raw_count() {
	python3 - "$ROOT/sources/social/raw" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

expect_sync_failure() {
	local description="$1"
	local fixture="$2"
	local stream="$3"
	if "$HELPER" sync-youtube --base "$BASE" --alias personal:default \
		--connection-id conn_youtube --account-id channel42 \
		--stream "$stream" --profile fixture --fixture "$fixture" \
		>/dev/null 2>&1; then
		assert_eq "$description" accepted rejected
	else
		assert_eq "$description" rejected rejected
	fi
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
    "identity": {"data": {
        "id": "channel42", "uploads_playlist_id": "uploads42",
        "title": "Private channel", "handle": "@private",
    }},
    "pages": [{
        "status": int(sys.argv[2]),
        "observed_at": f"2026-07-26T10:{int(sys.argv[2]) % 60:02d}:00Z",
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	local result=""
	result=$("$HELPER" sync-youtube --base "$BASE" --alias personal:default \
		--connection-id conn_youtube --account-id channel42 \
		--stream authored_videos --profile fixture --fixture "$fixture")
	assert_eq "${status} response is terminal" \
		"$(json_field "$result" status)" failed
	assert_eq "${status} response has a sanitized failure class" \
		"$(json_field "$result" failure_class)" "$expected_failure"
	return 0
}

run_identity_terminal_fixture() {
	local name="$1"
	local status="$2"
	local expected_output="$3"
	local expected_failure="$4"
	local expected_receipt="$5"
	local fixture="${TMP_DIR}/identity-${name}.json"
	local connection_id="conn_identity_${name}"
	python3 - "$fixture" "$status" <<'PY'
import json
import sys

status = int(sys.argv[2])
identity = {
    "status": status,
    "observed_at": f"2026-07-26T09:{status % 60:02d}:00Z",
}
if status == 429:
    identity["retry_after"] = 1785150000
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump({"identity": identity, "pages": []}, target)
PY
	local result=""
	result=$("$HELPER" sync-youtube --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id channel42 \
		--stream authored_videos --profile fixture --fixture "$fixture" \
		--budget 3)
	assert_eq "initial ${name} identity response is terminal" \
		"$(json_field "$result" status)" "$expected_output"
	assert_eq "initial ${name} identity response has a sanitized failure class" \
		"$(json_field "$result" failure_class)" "$expected_failure"
	if [[ "$status" == "429" ]]; then
		local retry_shape=""
		retry_shape=$(python3 -c 'import json,sys; value=json.loads(sys.argv[1])["retry_after"]; print(f"{type(value).__name__}:{value}")' "$result")
		assert_eq "initial quota identity response preserves its absolute retry epoch type" \
			"$retry_shape" "int:1785150000"
	fi
	assert_eq "initial ${name} identity response finishes its run receipt" \
		"$(sql_value "SELECT status || ':' || failure_class || ':' || coalesce(retry_after,'none') FROM sync_runs WHERE connection_id='${connection_id}'")" \
		"$expected_receipt"
	assert_eq "initial ${name} identity response binds no unverified evidence" \
		"$(sql_value "SELECT (SELECT count(*) FROM connections WHERE connection_id='${connection_id}') || ':' || (SELECT count(*) FROM fetch_batches WHERE connection_id='${connection_id}')")" \
		"0:0"
	return 0
}

expect_budget_rejection() {
	local budget="$1"
	if "$HELPER" sync-youtube --base "$BASE" --alias personal:default \
		--connection-id "conn_budget_${budget}" --account-id channel42 \
		--stream authored_videos --profile fixture \
		--fixture "$TMP_DIR/minimum-budget.json" --budget "$budget" \
		>/dev/null 2>&1; then
		assert_eq "YouTube budget ${budget} is rejected before collection" accepted rejected
	else
		assert_eq "YouTube budget ${budget} is rejected before collection" rejected rejected
	fi
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'YouTube social collector tests\n'

help_output=$("$HELPER" help)
if [[ "$help_output" == *"--budget is a hard 3-1000 unit limit"* ]]; then
	assert_eq "YouTube help advertises the executable budget range" advertised advertised
else
	assert_eq "YouTube help advertises the executable budget range" missing advertised
fi

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import importlib.util
import json
import sys
from email.message import Message
from io import BytesIO
from pathlib import Path
from urllib.error import HTTPError

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))
from _knowledge_social_youtube import STREAMS
from _knowledge_social_youtube_provider import API_BASE, _api, _http_exports
from _knowledge_social_youtube_routes import READ_ENDPOINTS, ROUTES

expected = {
    "authored_videos", "channel_activity", "owned_playlists",
    "subscriptions", "comments", "liked_videos",
}
assert set(STREAMS) == expected == set(ROUTES)
assert READ_ENDPOINTS == {
    "activities", "channels", "comments", "commentThreads",
    "playlistItems", "playlists", "subscriptions", "videos",
}
assert API_BASE == "https://www.googleapis.com/youtube/v3"
assert callable(_http_exports())
assert importlib.util.find_spec("googleapiclient") is None


def error_result(reason):
    body = json.dumps({"error": {"errors": [{"reason": reason}]}}).encode()
    headers = Message()
    headers["Retry-After"] = "60"

    def opener(request, timeout):
        assert timeout == 60
        raise HTTPError(request.full_url, 403, "Forbidden", headers, BytesIO(body))

    return _api("test-token", opener, "channels", {"part": "id", "mine": "true"})


for quota_reason in (
    "quotaExceeded",
    "dailyLimitExceeded",
    "rateLimitExceeded",
    "userRateLimitExceeded",
):
    quota_result = error_result(quota_reason)
    assert quota_result.status == 429
    assert quota_result.payload == {}
    assert quota_result.retry_after is not None
assert error_result("insufficientPermissions").status == 403

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_youtube*.py"))
]
calls = [
    node
    for source in sources
    for node in ast.walk(ast.parse(source))
    if isinstance(node, ast.Call)
]
request_calls = [
    node for node in calls
    if isinstance(node.func, ast.Name) and node.func.id == "Request"
]
assert request_calls
for node in request_calls:
    methods = [
        keyword.value.value
        for keyword in node.keywords
        if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
    ]
    assert methods == ["GET"]
PY
assert_eq "stream registry, stdlib transport, and GET-only endpoints are guarded" \
	verified verified

cat >"$TMP_DIR/minimum-budget.json" <<'JSON'
{"identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},"pages":[]}
JSON
expect_budget_rejection 1
expect_budget_rejection 2
assert_eq "rejected YouTube budgets create no run receipt" \
	"$(sql_value "SELECT count(*) FROM sync_runs WHERE connection_id IN ('conn_budget_1','conn_budget_2')")" 0

cat >"$TMP_DIR/videos-1.json" <<'JSON'
{
  "identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42","title":"Private channel","handle":"@private"}},
  "pages":[{
    "expect_request":{"cursor":null,"stop_at":null,"limit":1},
    "response":{"status":200,"observed_at":"2026-07-26T10:00:00Z",
      "data":[{"kind":"video","remote_id":"video_new","playlist_item_id":"upload_item_new","title":"Newest knowledge","description":"bounded YouTube page","published_at":"2026-07-26T09:00:00Z","channel_id":"channel42","channel_title":"Private channel","position":0,"privacy_status":"public"}],
      "meta":{"next_cursor":{"page_token":"nextVideos"},"newest_id":"video_new","reached_watermark":false,"complete":false,"snapshot":false}}
  }]
}
JSON
first_result=$("$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 \
	--stream authored_videos --profile fixture --budget 3 --page-size 1 \
	--fixture "$TMP_DIR/videos-1.json")
assert_eq "one-page quota pauses initial YouTube backfill" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "identity and one guarded page reserve three quota units" \
	"$(json_field "$first_result" budget_units)" 3
assert_eq "partial video page advances only its stream cursor" \
	"$(sql_value "SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_youtube' AND stream='authored_videos'")" 0
assert_eq "YouTube video text reaches the shared FTS projection" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1
assert_eq "API coverage records the 30-day refresh/delete boundary" \
	"$(sql_value "SELECT retention_limit || ':' || status FROM coverage_records WHERE connection_id='conn_youtube' AND stream='authored_videos'")" \
	"youtube_api_data_refresh_or_delete_within_30_days:paused"
assert_eq "unsupported account categories are durable gap evidence" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_youtube' AND stream IN ('watch_history','watch_later','saved_playlists','authored_comments_elsewhere') AND status='unavailable'")" 4
assert_eq "private channel metadata is absent from collector output" \
	"$([[ "$first_result" == *Private* || "$first_result" == *@private* ]] && printf present || printf absent)" absent

cat >"$TMP_DIR/videos-2.json" <<'JSON'
{
  "identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},
  "pages":[{
    "expect_request":{"cursor":{"page_token":"nextVideos"},"stop_at":null},
    "response":{"status":200,"observed_at":"2026-07-26T10:01:00Z",
      "data":[{"kind":"video","remote_id":"video_old","playlist_item_id":"upload_item_old","title":"Older knowledge","description":"resumed page","published_at":"2026-07-25T09:00:00Z","channel_id":"channel42","position":1}],
      "meta":{"next_cursor":null,"newest_id":"video_old","reached_watermark":false,"complete":true,"snapshot":false}}
  }]
}
JSON
second_result=$("$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 \
	--stream authored_videos --profile fixture --fixture "$TMP_DIR/videos-2.json")
assert_eq "YouTube backfill resumes from its opaque page cursor" \
	"$(json_field "$second_result" status)" complete
assert_eq "backfill exhaustion preserves the first-page watermark" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_youtube' AND stream='authored_videos'")" \
	"done:video_new:1"

cat >"$TMP_DIR/videos-delta.json" <<'JSON'
{
  "identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},
  "pages":[{
    "expect_request":{"cursor":null,"stop_at":"video_new"},
    "response":{"status":200,"observed_at":"2026-07-26T10:02:00Z",
      "data":[{"kind":"video","remote_id":"video_latest","playlist_item_id":"upload_item_latest","title":"Latest delta","published_at":"2026-07-26T10:00:00Z","channel_id":"channel42","position":0}],
      "meta":{"next_cursor":null,"newest_id":"video_latest","reached_watermark":true,"complete":true,"snapshot":false}}
  }]
}
JSON
"$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 \
	--stream authored_videos --profile fixture \
	--fixture "$TMP_DIR/videos-delta.json" >/dev/null
assert_eq "incremental completion advances the stable video watermark" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_youtube' AND stream='authored_videos'")" \
	video_latest

cat >"$TMP_DIR/subscriptions.json" <<'JSON'
{
  "identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},
  "pages":[{"status":200,"observed_at":"2026-07-26T10:03:00Z",
    "data":[{"kind":"subscription","remote_id":"subscription42","subscriber_channel_id":"channel42","subscribed_channel_id":"target_channel","title":"Target channel","published_at":"2026-07-20T10:00:00Z"}],
    "meta":{"next_cursor":null,"newest_id":"subscription42","reached_watermark":false,"complete":true,"snapshot":true}}]
}
JSON
"$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 --stream subscriptions \
	--profile fixture --fixture "$TMP_DIR/subscriptions.json" >/dev/null
assert_eq "subscription direction is selected channel to subscribed channel" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id FROM activities WHERE provider='youtube' AND activity_type='subscription'")" \
	"channel42:target_channel"

cat >"$TMP_DIR/playlist.json" <<'JSON'
{
  "identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},
  "pages":[{"status":200,"observed_at":"2026-07-26T10:04:00Z",
    "data":[{"kind":"playlist","remote_id":"playlist42","title":"Owned research","description":"playlist knowledge","published_at":"2026-07-01T10:00:00Z","channel_id":"channel42","item_count":1,"privacy_status":"private"}],
    "meta":{"next_cursor":{"phase":"items","playlist_id":"playlist42","item_token":null,"playlists_token":null},"newest_id":null,"reached_watermark":false,"complete":false,"snapshot":true}}]
}
JSON
"$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 --stream owned_playlists \
	--profile fixture --budget 3 --fixture "$TMP_DIR/playlist.json" >/dev/null
cat >"$TMP_DIR/playlist-items.json" <<'JSON'
{
  "identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},
  "pages":[{
    "expect_request":{"cursor":{"phase":"items","playlist_id":"playlist42","item_token":null,"playlists_token":null}},
    "response":{"status":200,"observed_at":"2026-07-26T10:05:00Z",
      "data":[{"kind":"playlist_item","remote_id":"membership42","playlist_id":"playlist42","video_id":"playlist_video","title":"Member video","published_at":"2026-07-02T10:00:00Z","position":0,"privacy_status":"public"}],
      "meta":{"next_cursor":null,"newest_id":null,"reached_watermark":false,"complete":true,"snapshot":true}}
  }]
}
JSON
"$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 --stream owned_playlists \
	--profile fixture --fixture "$TMP_DIR/playlist-items.json" >/dev/null
assert_eq "owned playlist membership retains playlist-to-video direction" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id FROM activities WHERE provider='youtube' AND activity_type='playlist_membership'")" \
	"playlist42:playlist_video"
assert_eq "saved third-party playlists remain explicit partial coverage" \
	"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_youtube' AND stream='owned_playlists'")" \
	"partial:saved_third_party_playlists_are_not_listable"

playlist_batches=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_youtube' AND stream='owned_playlists'")
python3 - "$TMP_DIR/playlist.json" "$TMP_DIR/playlist-items.json" \
	"$TMP_DIR/playlist-replay.json" <<'PY'
import json
import sys

first = json.load(open(sys.argv[1], encoding="utf-8"))
second = json.load(open(sys.argv[2], encoding="utf-8"))
with open(sys.argv[3], "w", encoding="utf-8") as target:
    json.dump({"identity": first["identity"], "pages": first["pages"] + second["pages"]}, target)
PY
"$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 --stream owned_playlists \
	--profile fixture --budget 5 --fixture "$TMP_DIR/playlist-replay.json" >/dev/null
assert_eq "exact compound snapshot replay is content-addressed and idempotent" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_youtube' AND stream='owned_playlists'")" \
	"$playlist_batches"

cat >"$TMP_DIR/comments-thread.json" <<'JSON'
{
  "identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},
  "pages":[{"status":200,"observed_at":"2026-07-26T10:06:00Z",
    "data":[
      {"kind":"comment","remote_id":"comment_top","parent_id":null,"video_id":"video_new","channel_id":"channel42","author_channel_id":"author42","author_display_name":"Commenter","text":"Top-level knowledge","published_at":"2026-07-25T10:00:00Z"},
      {"kind":"comment","remote_id":"comment_unknown","parent_id":null,"video_id":"video_new","channel_id":"channel42","text":"Unknown author knowledge","published_at":"2026-07-25T10:30:00Z"}
    ],
    "meta":{"next_cursor":{"phase":"replies","parent_id":"comment_top","reply_token":null,"threads_token":null},"newest_id":"comment_top","reached_watermark":false,"complete":false,"snapshot":false}}]
}
JSON
"$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 --stream comments \
	--profile fixture --budget 3 --fixture "$TMP_DIR/comments-thread.json" >/dev/null
cat >"$TMP_DIR/comments-replies.json" <<'JSON'
{
  "identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},
  "pages":[{
    "expect_request":{"cursor":{"phase":"replies","parent_id":"comment_top","reply_token":null,"threads_token":null}},
    "response":{"status":200,"observed_at":"2026-07-26T10:07:00Z",
      "data":[{"kind":"comment","remote_id":"comment_reply","parent_id":"comment_top","video_id":"video_new","channel_id":"channel42","author_channel_id":"channel42","author_display_name":"Owner","text":"Visible reply","published_at":"2026-07-25T11:00:00Z"}],
      "meta":{"next_cursor":null,"newest_id":null,"reached_watermark":false,"complete":true,"snapshot":false}}
  }]
}
JSON
"$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 --stream comments \
	--profile fixture --fixture "$TMP_DIR/comments-replies.json" >/dev/null
assert_eq "comment threads and complete replies use independent compound checkpoints" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='youtube' AND object_type='comment' AND remote_id IN ('comment_top','comment_reply')")" 2
assert_eq "comment evidence distinguishes owner, third-party, and unknown authors" \
	"$(sql_value "SELECT group_concat(remote_id || ':' || evidence_class, ',') FROM (SELECT remote_id, evidence_class FROM objects WHERE provider='youtube' AND object_type='comment' AND remote_id IN ('comment_reply','comment_top','comment_unknown') ORDER BY remote_id)")" \
	"comment_reply:authored,comment_top:observed,comment_unknown:observed"
assert_eq "channel-related comments remain explicit partial coverage" \
	"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_youtube' AND stream='comments'")" \
	"partial:channel_related_visible_comments_only"

cursor_before=$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_youtube' AND stream='authored_videos'")
cat >"$TMP_DIR/rate-limit.json" <<'JSON'
{"identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},"pages":[{"status":429,"observed_at":"2026-07-26T10:08:00Z","retry_after":1785150000}]}
JSON
rate_result=$("$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube --account-id channel42 --stream authored_videos \
	--profile fixture --fixture "$TMP_DIR/rate-limit.json")
assert_eq "YouTube rate limits pause one invocation" \
	"$(json_field "$rate_result" status)" rate_limited
assert_eq "terminal response preserves the prior YouTube checkpoint" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_youtube' AND stream='authored_videos'")" \
	"$cursor_before"
assert_eq "rate receipt contains only sanitized stream diagnostics" \
	"$(sql_value "SELECT failure_class || ':' || retry_after || ':' || diagnostics FROM sync_runs WHERE connection_id='conn_youtube' ORDER BY rowid DESC LIMIT 1")" \
	'rate_limit:1785150000:{"stream":"authored_videos"}'

run_terminal_fixture unauthorized 401 authorization
run_terminal_fixture forbidden 403 authorization
run_terminal_fixture missing 404 unavailable
run_terminal_fixture provider 500 provider
run_identity_terminal_fixture unauthorized 401 failed authorization \
	"failed:authorization:none"
run_identity_terminal_fixture quota 429 rate_limited rate_limit \
	"paused:rate_limit:1785150000"

batch_count=$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='youtube'")
cat >"$TMP_DIR/malformed.json" <<'JSON'
{"identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},"pages":[{"status":200,"observed_at":"2026-07-26T10:09:00Z","data":{},"meta":{}}]}
JSON
expect_sync_failure "malformed YouTube pages fail before persistence" \
	"$TMP_DIR/malformed.json" authored_videos
assert_eq "malformed YouTube page advances no batch" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='youtube'")" "$batch_count"

cat >"$TMP_DIR/credential.json" <<'JSON'
{"identity":{"data":{"id":"channel42","uploads_playlist_id":"uploads42"}},"pages":[{"status":200,"observed_at":"2026-07-26T10:10:00Z","access_token":"must-not-persist","data":[],"meta":{"next_cursor":null,"newest_id":null,"reached_watermark":false,"complete":true,"snapshot":false}}]}
JSON
expect_sync_failure "credential-shaped YouTube pages are rejected" \
	"$TMP_DIR/credential.json" authored_videos
assert_eq "credential rejection creates no raw evidence" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='youtube'")" "$batch_count"

cat >"$TMP_DIR/wrong-account.json" <<'JSON'
{"identity":{"data":{"id":"other_channel","uploads_playlist_id":"other_uploads"}},"pages":[]}
JSON
raw_before_mismatch=$(raw_count)
expect_sync_failure "selected YouTube account mismatch fails before collection" \
	"$TMP_DIR/wrong-account.json" authored_videos
assert_eq "identity mismatch creates no raw evidence" \
	"$(raw_count)" "$raw_before_mismatch"

python3 - "$ROOT" "$SCRIPT_DIR/../scripts" <<'PY'
import os
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from _knowledge_social_collect import (
    CollectionContext,
    ConnectionConfig,
    CursorState,
    PageCheckpoint,
    SuccessfulPage,
)
from _knowledge_social_collect_persist import persist_page
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    release_run_lease,
)
from _knowledge_social_youtube import STREAMS

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_youtube_fence", "liked_videos", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_youtube_fence", "liked_videos", "new_runner", "sync", 10),
    now_epoch=9001,
)
context = CollectionContext(
    root,
    "conn_youtube_fence",
    {"id": "channel42", "uploads_playlist_id": "uploads42"},
    "liked_videos",
    "none",
    ConnectionConfig(("liked_videos",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["liked_videos"],
    old,
    "youtube",
)
archive = {
    "provider": "youtube",
    "connection_id": "conn_youtube_fence",
    "remote_account_id": "channel42",
    "exported_at": "2026-07-26T10:10:30Z",
    "enabled_streams": ["liked_videos"],
    "policy": {"media_hydration": "none"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
page = SuccessfulPage(
    {
        "status": 200,
        "observed_at": archive["exported_at"],
        "data": [],
        "meta": {},
    },
    '{"stream":"liked_videos"}',
    archive,
    PageCheckpoint(None, None),
    True,
    2,
)
os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "9001"
try:
    persist_page(context, page)
except SocialLeaseLostError:
    pass
else:
    raise SystemExit("stale YouTube collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    cursor = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_youtube_fence'"
    ).fetchone()[0]
assert cursor == 0
release_run_lease(root, new)
PY
assert_eq "stale YouTube lease cannot commit evidence or a cursor" verified verified

mkdir -p "$TMP_DIR/fake-youtube"
cat >"$TMP_DIR/fake-youtube/sitecustomize.py" <<'PY'
import json
import os
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import urllib.request


class Response:
    status = 200

    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, _limit):
        return self.payload


def fake_urlopen(request, timeout):
    parsed = urlparse(request.full_url)
    endpoint = parsed.path.rsplit("/", 1)[-1]
    query = parse_qs(parsed.query)
    log_path = Path(os.environ["YOUTUBE_READ_LOG"])
    row = {
        "endpoint": endpoint,
        "method": request.get_method(),
        "maxResults": query.get("maxResults", [None])[0],
        "bearer": request.get_header("Authorization", "").startswith("Bearer "),
        "unrelated_secret": "UNRELATED_PROVIDER_TOKEN" in os.environ,
        "timeout": timeout,
    }
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")
    if endpoint == "channels":
        channel_calls = sum(
            json.loads(line)["endpoint"] == "channels"
            for line in log_path.read_text(encoding="utf-8").splitlines()
        )
        rebound = log_path.name == "youtube-rebind.log" and channel_calls > 1
        channel_id = "other_channel" if rebound else "live_channel42"
        uploads_id = "other_uploads" if rebound else "live_uploads42"
        return Response({"items": [{
            "id": channel_id,
            "snippet": {"title": "Private live channel", "customUrl": "@private-live"},
            "contentDetails": {"relatedPlaylists": {"uploads": uploads_id}},
        }]})
    if endpoint == "playlistItems":
        return Response({"items": [{
            "id": "live_upload_item",
            "snippet": {
                "title": "Guarded live page", "description": "read boundary marker",
                "publishedAt": "2026-07-26T10:11:00Z", "channelId": "live_channel42",
                "channelTitle": "Private live channel", "position": 0,
                "resourceId": {"videoId": "live_video42"},
            },
            "contentDetails": {"videoId": None},
            "status": {"privacyStatus": "public"},
        }]})
    raise RuntimeError("unexpected endpoint")


urllib.request.urlopen = fake_urlopen
PY
: >"$TMP_DIR/youtube-read.log"
chmod 0600 "$TMP_DIR/youtube-read.log"
live_result=$(
	PYTHONPATH="$TMP_DIR/fake-youtube" YOUTUBE_READ_LOG="$TMP_DIR/youtube-read.log" \
		YOUTUBE_FIXTURE_ACCESS_TOKEN=fixture-token UNRELATED_PROVIDER_TOKEN=unrelated \
		"$HELPER" sync-youtube --base "$BASE" --alias personal:default \
		--connection-id conn_youtube_live --account-id live_channel42 \
		--stream authored_videos --profile fixture --budget 3 --page-size 7
)
assert_eq "guarded live OAuth boundary persists one readable page" \
	"$(json_field "$live_result" status)" complete
assert_eq "uploaded videos fall back to the snippet resource ID when details are null" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='youtube' AND object_type='video' AND remote_id='live_video42'")" 1
live_guard=$(
	python3 - "$TMP_DIR/youtube-read.log" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
channels = [row for row in rows if row["endpoint"] == "channels"]
pages = [row for row in rows if row["endpoint"] == "playlistItems"]
safe = (
    len(channels) == 2
    and len(pages) == 1
    and pages[0]["maxResults"] == "7"
    and all(row["method"] == "GET" and row["bearer"] for row in rows)
    and all(not row["unrelated_secret"] for row in rows)
)
print("bounded-read-only" if safe else "unsafe")
PY
)
assert_eq "live boundary revalidates identity and passes only selected credentials" \
	"$live_guard" bounded-read-only
assert_eq "live boundary never prints private channel metadata" \
	"$([[ "$live_result" == *Private* || "$live_result" == *@private-live* ]] && printf present || printf absent)" absent

: >"$TMP_DIR/youtube-rebind.log"
chmod 0600 "$TMP_DIR/youtube-rebind.log"
raw_before_rebind=$(raw_count)
if PYTHONPATH="$TMP_DIR/fake-youtube" YOUTUBE_READ_LOG="$TMP_DIR/youtube-rebind.log" \
	YOUTUBE_FIXTURE_ACCESS_TOKEN=fixture-token \
	"$HELPER" sync-youtube --base "$BASE" --alias personal:default \
	--connection-id conn_youtube_rebind --account-id live_channel42 \
	--stream authored_videos --profile fixture --budget 3 --page-size 7 \
	>/dev/null 2>&1; then
	rebind_result=accepted
else
	rebind_result=rejected
fi
assert_eq "live boundary rejects account rebinding before a page read" \
	"$rebind_result" rejected
assert_eq "per-page identity mismatch creates no raw evidence" \
	"$(raw_count)" "$raw_before_rebind"
assert_eq "per-page identity mismatch advances no cursor" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_youtube_rebind'")" 0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
