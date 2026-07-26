#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-reddit.sh — Guarded Reddit collector regression tests

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
	local connection_id="$3"
	local account_id="$4"
	local stream="$5"
	if "$HELPER" sync-reddit --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id "$account_id" \
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
    "identity": {"data": {"id": "reddit42", "username": "private-user"}},
    "pages": [{
        "status": int(sys.argv[2]),
        "observed_at": f"2026-07-26T08:{int(sys.argv[2]) % 60:02d}:00Z",
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	local result=""
	result=$("$HELPER" sync-reddit --base "$BASE" --alias personal:default \
		--connection-id conn_authored --account-id reddit42 \
		--stream authored_submissions --profile fixture --fixture "$fixture")
	assert_eq "${status} response is terminal" \
		"$(json_field "$result" status)" failed
	assert_eq "${status} response has a sanitized failure class" \
		"$(json_field "$result" failure_class)" "$expected_failure"
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Reddit social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from _knowledge_social_reddit import STREAMS
from _knowledge_social_reddit_read_routes import (
    LISTING_STREAMS,
    ProviderPageRequest,
    SNAPSHOT_STREAMS,
    _listing_generator,
    _snapshot_values,
)
from _knowledge_social_reddit_reader import _provider_failure

expected = {
    "authored_submissions", "authored_comments", "mentions", "comment_replies",
    "submission_replies", "inbox_messages", "sent_messages", "saved", "upvoted",
    "downvoted", "hidden", "subscribed_subreddits", "moderated_subreddits",
    "contributor_subreddits", "multireddits", "friends", "blocked", "trusted",
}
assert set(STREAMS) == expected
assert LISTING_STREAMS | SNAPSHOT_STREAMS == expected
sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(Path(sys.argv[1]).glob("_knowledge_social_reddit_read_*.py"))
]
banned = {
    "submit", "reply", "upvote", "downvote", "save", "hide", "unhide",
    "message", "subscribe", "unsubscribe", "friend", "unfriend", "block",
    "unblock", "delete", "edit", "distinguish",
}
calls = {
    node.func.attr
    for source in sources
    for node in ast.walk(ast.parse(source))
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
}
assert calls.isdisjoint(banned), sorted(calls & banned)


class RecordingNode:
    def __init__(self, path, calls):
        self.path = path
        self.calls = calls

    def __getattr__(self, name):
        return RecordingNode(f"{self.path}.{name}", self.calls)

    def __call__(self, **kwargs):
        self.calls.append((self.path, kwargs))
        return []


expected_listing_routes = {
    "authored_submissions": "selected.submissions.new",
    "authored_comments": "selected.comments.new",
    "mentions": "client.inbox.mentions",
    "comment_replies": "client.inbox.comment_replies",
    "submission_replies": "client.inbox.submission_replies",
    "inbox_messages": "client.inbox.messages",
    "sent_messages": "client.inbox.sent",
    "saved": "selected.saved",
    "upvoted": "selected.upvoted",
    "downvoted": "selected.downvoted",
    "hidden": "selected.hidden",
    "subscribed_subreddits": "client.user.subreddits",
    "moderated_subreddits": "client.user.moderator_subreddits",
    "contributor_subreddits": "client.user.contributor_subreddits",
}
expected_snapshot_routes = {
    "multireddits": "client.user.multireddits",
    "friends": "client.user.friends",
    "blocked": "client.user.blocked",
    "trusted": "client.user.trusted",
}
for stream, expected_route in expected_listing_routes.items():
    route_calls = []
    client = RecordingNode("client", route_calls)
    selected = RecordingNode("selected", route_calls)
    request = ProviderPageRequest(stream, "account", None, None, 7)
    assert list(_listing_generator(client, selected, request)) == []
    assert route_calls == [
        (expected_route, {"limit": 7, "params": {}, "request_limit": 7})
    ]
for stream, expected_route in expected_snapshot_routes.items():
    route_calls = []
    client = RecordingNode("client", route_calls)
    assert _snapshot_values(client, stream) == []
    assert route_calls == [(expected_route, {})]

missing = "PRAW is unavailable; install it outside the agent session"
assert str(_provider_failure(f"ERROR: {missing}")) == missing
assert str(_provider_failure("ERROR: private provider detail")) == (
    "Reddit read provider is unavailable"
)
PY
assert_eq "required streams and sanitized provider failures are guarded" \
	verified verified

cat >"$TMP_DIR/backfill-1.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "expect_request":{"after":null,"stop_at":null,"limit":1},
    "response":{
      "status":200,"observed_at":"2026-07-26T08:00:00Z",
      "data":[{
        "kind":"submission","fullname":"t3_new","title":"Newest knowledge",
        "selftext":"first bounded page","created_utc":1785052800,
        "author":{"remote_id":"reddit42","name":"private-user"},
        "subreddit":{"kind":"subreddit","fullname":"t5_dev","remote_id":"subreddit_dev","display_name":"devops","title":"DevOps"}
      }],
      "meta":{"next_after":"t3_cursor","newest_fullname":"t3_new","reached_watermark":false,"complete":false,"snapshot":false}
    }
  }]
}
JSON
first_result=$("$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 \
	--stream authored_submissions --profile fixture --budget 1 --page-size 1 \
	--fixture "$TMP_DIR/backfill-1.json")
assert_eq "one-page budget pauses initial Reddit backfill" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "partial Reddit page stores one request unit" \
	"$(json_field "$first_result" budget_units)" 1
assert_eq "partial Reddit page advances only its stream cursor" \
	"$(sql_value "SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored_submissions'")" 0
assert_eq "Reddit content is searchable through the shared FTS projection" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1
assert_eq "listing coverage records the provider retention boundary" \
	"$(sql_value "SELECT retention_limit || ':' || status FROM coverage_records WHERE connection_id='conn_authored' AND stream='authored_submissions'")" \
	"provider_listing_window:paused"
assert_eq "private Reddit handle is absent from collector output" \
	"$([[ "$first_result" == *private-user* ]] && printf present || printf absent)" absent

cat >"$TMP_DIR/backfill-2.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "expect_request":{"after":"t3_cursor","stop_at":null},
    "response":{
      "status":200,"observed_at":"2026-07-26T08:01:00Z",
      "data":[{
        "kind":"submission","fullname":"t3_old","title":"Older knowledge",
        "selftext":"resumed page","created_utc":1784966400,
        "author":{"remote_id":"reddit42","name":"private-user"},
        "subreddit":null
      }],
      "meta":{"next_after":null,"newest_fullname":"t3_old","reached_watermark":false,"complete":true,"snapshot":false}
    }
  }]
}
JSON
second_result=$("$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 \
	--stream authored_submissions --profile fixture \
	--fixture "$TMP_DIR/backfill-2.json")
assert_eq "Reddit backfill resumes from its stable fullname cursor" \
	"$(json_field "$second_result" status)" complete
assert_eq "backfill exhaustion preserves the first page watermark" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored_submissions'")" \
	"done:t3_new:1"
assert_eq "both immutable backfill pages remain durable" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_authored' AND stream='authored_submissions' AND terminal_status='success'")" 2

cat >"$TMP_DIR/incremental.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "expect_request":{"after":null,"stop_at":"t3_new"},
    "response":{
      "status":200,"observed_at":"2026-07-26T08:02:00Z",
      "data":[{
        "kind":"submission","fullname":"t3_latest","title":"Latest delta",
        "selftext":"incremental marker","created_utc":1785139200,
        "author":{"remote_id":"reddit42","name":"private-user"},
        "subreddit":null
      }],
      "meta":{"next_after":null,"newest_fullname":"t3_latest","reached_watermark":true,"complete":true,"snapshot":false}
    }
  }]
}
JSON
delta_result=$("$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 \
	--stream authored_submissions --profile fixture \
	--fixture "$TMP_DIR/incremental.json")
assert_eq "newest-first incremental scan stops at the prior watermark" \
	"$(json_field "$delta_result" status)" complete
assert_eq "incremental completion advances to the newest stable fullname" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored_submissions'")" \
	"t3_latest"

cat >"$TMP_DIR/comments-initial.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "status":200,"observed_at":"2026-07-26T08:03:00Z",
    "data":[{"kind":"comment","fullname":"t1_prior","body":"prior comment","created_utc":1785052800,"author":{"remote_id":"reddit42","name":"private-user"},"subreddit":null}],
    "meta":{"next_after":null,"newest_fullname":"t1_prior","reached_watermark":false,"complete":true,"snapshot":false}
  }]
}
JSON
"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 \
	--stream authored_comments --profile fixture \
	--fixture "$TMP_DIR/comments-initial.json" >/dev/null

cat >"$TMP_DIR/comments-partial.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "expect_request":{"after":null,"stop_at":"t1_prior"},
    "response":{
      "status":200,"observed_at":"2026-07-26T08:04:00Z",
      "data":[{"kind":"comment","fullname":"t1_current","body":"current comment","created_utc":1785139200,"author":{"remote_id":"reddit42","name":"private-user"},"subreddit":null}],
      "meta":{"next_after":"t1_resume","newest_fullname":"t1_current","reached_watermark":false,"complete":false,"snapshot":false}
    }
  }]
}
JSON
"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 \
	--stream authored_comments --profile fixture --budget 1 \
	--fixture "$TMP_DIR/comments-partial.json" >/dev/null

cat >"$TMP_DIR/comments-resume.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "expect_request":{"after":"t1_resume","stop_at":"t1_prior"},
    "response":{
      "status":200,"observed_at":"2026-07-26T08:05:00Z","data":[],
      "meta":{"next_after":null,"newest_fullname":null,"reached_watermark":true,"complete":true,"snapshot":false}
    }
  }]
}
JSON
"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 \
	--stream authored_comments --profile fixture \
	--fixture "$TMP_DIR/comments-resume.json" >/dev/null
assert_eq "interrupted incremental scans retain their original stop watermark" \
	"$(sql_value "SELECT watermark || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored_comments'")" \
	"t1_current:1"
assert_eq "each Reddit stream owns an independent checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_authored'")" 2

cat >"$TMP_DIR/saved-mixed.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "status":200,"observed_at":"2026-07-26T08:06:00Z",
    "data":[
      {"kind":"submission","fullname":"t3_saved","title":"Saved post","selftext":"mixed listing post","created_utc":1785139200,"author":{"remote_id":"usr_author","name":"other-user"},"subreddit":null},
      {"kind":"comment","fullname":"t1_saved","body":"mixed listing comment","created_utc":1785139201,"author":{"remote_id":"usr_author","name":"other-user"},"subreddit":null}
    ],
    "meta":{"next_after":null,"newest_fullname":"t3_saved","reached_watermark":false,"complete":true,"snapshot":false}
  }]
}
JSON
"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 --stream saved \
	--profile fixture --fixture "$TMP_DIR/saved-mixed.json" >/dev/null
assert_eq "mixed saved listings preserve post and comment object types" \
	"$(sql_value "SELECT group_concat(object_type,',') FROM (SELECT DISTINCT object_type FROM objects WHERE remote_id IN ('t3_saved','t1_saved') ORDER BY object_type)")" \
	"comment,post"
assert_eq "curation activity is attributed to the selected account" \
	"$(sql_value "SELECT count(*) FROM activities WHERE activity_type='saved' AND actor_remote_id='reddit42'")" 2

cat >"$TMP_DIR/subscriptions.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "expect_request":{"after":null,"stop_at":null},
    "response":{
      "status":200,"observed_at":"2026-07-26T08:07:00Z",
      "data":[{"kind":"subreddit","fullname":"t5_ops","remote_id":"subreddit_ops","display_name":"operations","title":"Operations"}],
      "meta":{"next_after":null,"newest_fullname":"t5_ops","reached_watermark":false,"complete":true,"snapshot":false}
    }
  }]
}
JSON
"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 \
	--stream subscribed_subreddits --profile fixture \
	--fixture "$TMP_DIR/subscriptions.json" >/dev/null
"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 \
	--stream subscribed_subreddits --profile fixture \
	--fixture "$TMP_DIR/subscriptions.json" >/dev/null
assert_eq "completed subscription snapshots rescan from the beginning" \
	"$(sql_value "SELECT backfill_complete || ':' || coalesce(cursor,'reset') FROM sync_cursors WHERE connection_id='conn_authored' AND stream='subscribed_subreddits'")" \
	"1:reset"
assert_eq "subscription membership preserves selected-account direction" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id FROM activities WHERE activity_type='subscribed_subreddits'")" \
	"reddit42:subreddit_ops"

cat >"$TMP_DIR/multireddits.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "status":200,"observed_at":"2026-07-26T08:08:00Z",
    "data":[{
      "kind":"multireddit","remote_id":"multi_fixture","display_name":"Research",
      "path":"/user/private-user/m/research","description_md":"knowledge feed",
      "visibility":"private","subreddits":[
        {"kind":"subreddit","fullname":"t5_research","remote_id":"subreddit_research","display_name":"research","title":"Research"}
      ]
    }],
    "meta":{"next_after":null,"newest_fullname":null,"reached_watermark":false,"complete":true,"snapshot":true}
  }]
}
JSON
before_replay_batches=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_authored' AND stream='multireddits'")
"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 --stream multireddits \
	--profile fixture --fixture "$TMP_DIR/multireddits.json" >/dev/null
after_first_snapshot=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_authored' AND stream='multireddits'")
"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 --stream multireddits \
	--profile fixture --fixture "$TMP_DIR/multireddits.json" >/dev/null
after_snapshot_replay=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_authored' AND stream='multireddits'")
assert_eq "multireddit snapshots create one immutable batch" \
	"$((after_first_snapshot - before_replay_batches))" 1
assert_eq "exact snapshot replay is content-addressed and idempotent" \
	"$after_snapshot_replay" "$after_first_snapshot"
assert_eq "custom-feed membership retains both stable identities" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id FROM activities WHERE activity_type='multireddit_membership'")" \
	"multi_fixture:subreddit_research"

cat >"$TMP_DIR/friends.json" <<'JSON'
{
  "identity":{"data":{"id":"reddit42","username":"private-user"}},
  "pages":[{
    "status":200,"observed_at":"2026-07-26T08:09:00Z",
    "data":[{"kind":"redditor","remote_id":"usr_friend","name":"friend-user","relationship_utc":1785139200}],
    "meta":{"next_after":null,"newest_fullname":null,"reached_watermark":false,"complete":true,"snapshot":true}
  }]
}
JSON
"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 --stream friends \
	--profile fixture --fixture "$TMP_DIR/friends.json" >/dev/null
assert_eq "friend relationships preserve selected-to-remote direction" \
	"$(sql_value "SELECT actor_remote_id || ':' || object_remote_id FROM activities WHERE activity_type='friends'")" \
	"reddit42:usr_friend"

cursor_before=$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored_submissions'")
cat >"$TMP_DIR/rate-limit.json" <<'JSON'
{"identity":{"data":{"id":"reddit42","username":"private-user"}},"pages":[{"status":429,"observed_at":"2026-07-26T08:10:00Z","retry_after":1785150000}]}
JSON
rate_result=$("$HELPER" sync-reddit --base "$BASE" --alias personal:default \
	--connection-id conn_authored --account-id reddit42 \
	--stream authored_submissions --profile fixture \
	--fixture "$TMP_DIR/rate-limit.json")
assert_eq "Reddit rate limits pause one invocation" \
	"$(json_field "$rate_result" status)" rate_limited
assert_eq "terminal Reddit response preserves the prior checkpoint" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_authored' AND stream='authored_submissions'")" \
	"$cursor_before"
assert_eq "rate receipt contains only sanitized stream diagnostics" \
	"$(sql_value "SELECT failure_class || ':' || retry_after || ':' || diagnostics FROM sync_runs WHERE connection_id='conn_authored' ORDER BY rowid DESC LIMIT 1")" \
	'rate_limit:1785150000:{"stream":"authored_submissions"}'

run_terminal_fixture unauthorized 401 authorization
run_terminal_fixture forbidden 403 authorization
run_terminal_fixture missing 404 unavailable
run_terminal_fixture provider 500 provider

batch_count=$(sql_value "SELECT count(*) FROM fetch_batches")
cat >"$TMP_DIR/malformed.json" <<'JSON'
{"identity":{"data":{"id":"reddit42"}},"pages":[{"status":200,"observed_at":"2026-07-26T08:11:00Z","data":{"kind":"comment"},"meta":{}}]}
JSON
expect_sync_failure "malformed Reddit pages fail before persistence" \
	"$TMP_DIR/malformed.json" conn_authored reddit42 authored_submissions
assert_eq "malformed Reddit page advances no batch" \
	"$(sql_value "SELECT count(*) FROM fetch_batches")" "$batch_count"

cat >"$TMP_DIR/credential.json" <<'JSON'
{"identity":{"data":{"id":"reddit42"}},"pages":[{"status":200,"observed_at":"2026-07-26T08:12:00Z","access_token":"must-not-persist","data":[],"meta":{"next_after":null,"newest_fullname":null,"reached_watermark":false,"complete":true,"snapshot":false}}]}
JSON
expect_sync_failure "credential-shaped Reddit pages are rejected" \
	"$TMP_DIR/credential.json" conn_authored reddit42 authored_submissions
assert_eq "credential rejection creates no raw evidence" \
	"$(sql_value "SELECT count(*) FROM fetch_batches")" "$batch_count"

cat >"$TMP_DIR/wrong-account.json" <<'JSON'
{"identity":{"data":{"id":"reddit_other","username":"other-user"}},"pages":[]}
JSON
raw_before_mismatch=$(raw_count)
expect_sync_failure "selected Reddit account mismatch fails before collection" \
	"$TMP_DIR/wrong-account.json" conn_authored reddit42 authored_submissions
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
from _knowledge_social_reddit import STREAMS

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_reddit_fence", "friends", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_reddit_fence", "friends", "new_runner", "sync", 10),
    now_epoch=9001,
)
context = CollectionContext(
    root,
    "conn_reddit_fence",
    {"id": "reddit42"},
    "friends",
    "none",
    ConnectionConfig(("friends",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["friends"],
    old,
    "reddit",
)
archive = {
    "provider": "reddit",
    "connection_id": "conn_reddit_fence",
    "remote_account_id": "reddit42",
    "exported_at": "2026-07-26T08:13:00Z",
    "enabled_streams": ["friends"],
    "policy": {"media_hydration": "none"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
page = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"friends"}',
    archive,
    PageCheckpoint(None, None),
    True,
    1,
)
os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "9001"
try:
    persist_page(context, page)
except SocialLeaseLostError:
    pass
else:
    raise SystemExit("stale Reddit collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    cursor = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_reddit_fence'"
    ).fetchone()[0]
assert cursor == 0
release_run_lease(root, new)
PY
assert_eq "stale Reddit lease cannot commit evidence or a cursor" verified verified

mkdir -p "$TMP_DIR/fake-praw"
cat >"$TMP_DIR/fake-praw/praw.py" <<'PY'
import json
import os
from pathlib import Path

__version__ = "fixture"


def log(record):
    path = Path(os.environ["REDDIT_READ_LOG"])
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


class Subreddit:
    def __init__(self):
        self.id = "fixturecommunity"
        self.display_name = "fixture-community"
        self.title = "Fixture Community"


class Submission:
    def __init__(self, identity):
        self.id = "fixturepost"
        self.author = identity
        self.subreddit = Subreddit()
        self.title = "guarded PRAW page"
        self.selftext = "read boundary marker"
        self.created_utc = 1785139200

    def __getattr__(self, name):
        log({"unexpected_dynamic_attribute": name})
        raise RuntimeError("dynamic fetch forbidden")


class Listing:
    def __init__(self, identity, kwargs):
        self.values = [Submission(identity)]
        self.params = dict(kwargs["params"])
        self.params["after"] = None

    def __iter__(self):
        return iter(self.values)


class NewListing:
    def __init__(self, identity):
        self.identity = identity

    def new(self, **kwargs):
        log({"listing_kwargs": kwargs})
        return Listing(self.identity, kwargs)


class Redditor:
    def __init__(self):
        self.id = "redditlive42"
        self.name = "private-live-user"
        self.submissions = NewListing(self)


class User:
    def __init__(self, identity):
        self.identity = identity

    def me(self):
        return self.identity


class Reddit:
    def __init__(self, **credentials):
        if "UNRELATED_PROVIDER_TOKEN" in os.environ:
            raise RuntimeError("unrelated secret reached the child")
        log({"credential_keys": sorted(credentials)})
        identity = Redditor()
        self.user = User(identity)
        self.inbox = object()
PY
: >"$TMP_DIR/reddit-read.log"
chmod 0600 "$TMP_DIR/reddit-read.log"
live_result=$(
	PYTHONPATH="$TMP_DIR/fake-praw" REDDIT_READ_LOG="$TMP_DIR/reddit-read.log" \
		REDDIT_FIXTURE_CLIENT_ID=client REDDIT_FIXTURE_CLIENT_SECRET=secret \
		REDDIT_FIXTURE_USERNAME=user REDDIT_FIXTURE_PASSWORD=password \
		REDDIT_FIXTURE_USER_AGENT=agent UNRELATED_PROVIDER_TOKEN=unrelated \
		"$HELPER" sync-reddit --base "$BASE" --alias personal:default \
		--connection-id conn_live --account-id redditlive42 \
		--stream authored_submissions --profile fixture --page-size 7
)
assert_eq "guarded live PRAW boundary persists one readable page" \
	"$(json_field "$live_result" status)" complete
live_guard=$(
	python3 - "$TMP_DIR/reddit-read.log" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
listings = [row["listing_kwargs"] for row in rows if "listing_kwargs" in row]
dynamic = [row for row in rows if "unexpected_dynamic_attribute" in row]
credential_rows = [row["credential_keys"] for row in rows if "credential_keys" in row]
expected_credentials = ["client_id", "client_secret", "password", "user_agent", "username"]
safe = (
    len(listings) == 1
    and listings[0] == {"limit": 7, "params": {}, "request_limit": 7}
    and not dynamic
    and credential_rows
    and all(row == expected_credentials for row in credential_rows)
)
print("bounded-read-only" if safe else "unsafe")
PY
)
assert_eq "live boundary passes explicit one-page limits and only selected credentials" \
	"$live_guard" bounded-read-only
assert_eq "live boundary never prints the private account handle" \
	"$([[ "$live_result" == *private-live-user* ]] && printf present || printf absent)" absent

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
