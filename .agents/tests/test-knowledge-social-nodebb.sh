#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-nodebb.sh — Multi-instance NodeBB collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
INSTANCE_A="aaaaaaaaaaaaaaaaaaaaaaaa"
INSTANCE_B="bbbbbbbbbbbbbbbbbbbbbbbb"
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
	python3 - "$ROOT/sources/social/raw/nodebb" <<'PY'
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
	local stream="$4"
	if "$HELPER" sync-nodebb --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id user_42 \
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
	local expected_coverage="$4"
	local fixture="${TMP_DIR}/terminal-${name}.json"
	python3 - "$fixture" "$INSTANCE_A" "$status" <<'PY'
import json
import sys

status = int(sys.argv[3])
page = {"status": status, "observed_at": "2026-07-28T12:00:00Z"}
if status == 429:
    page["retry_after"] = 1785200000
payload = {
    "identity": {"data": {
        "provider_account_id": "42",
        "userslug": "selected-user",
        "instance_id": sys.argv[2],
    }},
    "pages": [page],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	local result=""
	result=$("$HELPER" sync-nodebb --base "$BASE" --alias personal:default \
		--connection-id "conn_terminal_${name}" --account-id user_42 \
		--stream notifications --profile fixture --fixture "$fixture")
	assert_eq "${status} NodeBB response is terminal" \
		"$(json_field "$result" failure_class)" "$expected_failure"
	assert_eq "${status} terminal response records explicit coverage" \
		"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_terminal_${name}' AND stream='notifications'")" \
		"${expected_coverage}:${expected_failure}"
	assert_eq "${status} terminal response advances no checkpoint" \
		"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_terminal_${name}'")" 0
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'NodeBB social collector tests\n'

help_output=$("$HELPER" help)
if [[ "$help_output" == *"dedicated user bearer token"* &&
	"$help_output" == *"--page-size is 1-50"* ]]; then
	assert_eq "NodeBB CLI advertises the executable safety contract" advertised advertised
else
	assert_eq "NodeBB CLI advertises the executable safety contract" missing advertised
fi
matrix_output=$(<"$SCRIPT_DIR/../aidevops/knowledge-plane/06-social-provider-capabilities.md")
docs_output=$(<"$SCRIPT_DIR/../content/social-nodebb.md")
if [[ "$matrix_output" == *'| NodeBB | **Live** topics and posts'* &&
	"$docs_output" == *'NODEBB_<PROFILE>_TOKEN_TYPE=user'* ]]; then
	assert_eq "Live NodeBB claim is backed by operator evidence" verified verified
else
	assert_eq "Live NodeBB claim is backed by operator evidence" missing verified
fi

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import os
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_nodebb import PageRequest, STREAMS, namespaced_id
from _knowledge_social_nodebb_contract import ApiResult
from _knowledge_social_nodebb_http import (
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    _canonical_base_url,
    _http_exports,
    api,
    installation_fingerprint,
)
from _knowledge_social_nodebb_provider import _profile
from _knowledge_social_nodebb_routes import EXACT_READ_PATHS, allowlisted_path, page

expected_streams = {
    "capabilities", "authored_topics", "authored_posts", "upvoted",
    "downvoted", "bookmarks", "watched_topics", "category_state",
    "following", "followers", "groups", "notifications", "chat_rooms",
}
assert set(STREAMS) == expected_streams
assert STREAMS["capabilities"].cost_units == 3
assert all(
    spec.cost_units == 2
    for name, spec in STREAMS.items()
    if name != "capabilities"
)
assert EXACT_READ_PATHS == {
    "/api/self", "/api/config", "/api/v3/ping", "/api/notifications",
    "/api/v3/chats",
}
for rejected in (
    "/api/v3/topics", "/api/v3/users/42/exports/posts",
    "/api/v3/plugins/example", "/api/admin/extend/plugins", "/api/v1/users",
):
    assert not allowlisted_path(rejected)

base_a = _canonical_base_url("https://forum-a.example.invalid/community/")
base_b = _canonical_base_url("https://forum-b.example.invalid/community")
instance_a = installation_fingerprint(base_a, "a" * 32)
instance_b = installation_fingerprint(base_b, "b" * 32)
assert base_a == "https://forum-a.example.invalid/community"
assert instance_a != instance_b
assert namespaced_id(instance_a, "user", "42") != namespaced_id(
    instance_b, "user", "42"
)
for invalid in (
    "http://forum.example.invalid",
    "https://user@forum.example.invalid",
    "https://forum.example.invalid/%2e%2e/admin",
):
    try:
        _canonical_base_url(invalid)
    except RuntimeError as error:
        assert "example.invalid" not in str(error)
    else:
        raise AssertionError("unsafe NodeBB base URL was accepted")

os.environ["NODEBB_SCOPE_BASE_URL"] = base_a
os.environ["NODEBB_SCOPE_BEARER_TOKEN"] = "private-token-value"
os.environ["NODEBB_SCOPE_ORIGIN_KEY"] = "a" * 32
os.environ["NODEBB_SCOPE_TOKEN_TYPE"] = "master"
try:
    _profile("scope")
except RuntimeError:
    pass
else:
    raise AssertionError("NodeBB master token was accepted")


class Response:
    status = 200

    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def read(self, size=-1):
        return self.payload[:size]


class Opener:
    def __init__(self, payload):
        self.payload = payload
        self.requests = []

    def open(self, request, timeout):
        assert timeout == HTTP_TIMEOUT_SECONDS
        assert request.method == "GET"
        assert "private-token-value" not in request.full_url
        self.requests.append(request)
        return Response(self.payload)


config = ProfileConfig(base_a, "private-token-value", "user", instance_a)
opener = Opener({"uid": 42, "userslug": "selected-user"})
assert api(config, opener, "/api/self", {}).status == 200
assert callable(_http_exports().open)
try:
    api(config, opener, "/api/v3/topics", {})
except RuntimeError:
    pass
else:
    raise AssertionError("NodeBB mutation route was reachable")


def request_for(stream, position=1, limit=2):
    return PageRequest(
        stream,
        namespaced_id(instance_a, "user", "42"),
        "42",
        "selected-user",
        instance_a,
        position,
        None,
        limit,
    )


calls = []


def topics_api(path, params):
    calls.append((path, params))
    return ApiResult(200, {
        "topics": [{"tid": 100, "title": "Bounded topic"}],
        "pagination": {"next": {"active": True, "page": 2}},
    })


topics = page(topics_api, request_for("authored_topics"), {})
assert topics["data"][0]["remote_id"] == namespaced_id(instance_a, "topic", "100")
assert topics["meta"]["next_position"] == 2
assert calls == [("/api/user/selected-user/topics", {"page": "1"})]


def capability_api(path, params):
    assert params == {}
    if path == "/api/v3/ping":
        return ApiResult(200, {"status": {"code": "ok"}, "response": {"pong": True}})
    assert path == "/api/config"
    return ApiResult(200, {"loggedIn": True, "uid": 42, "disableChat": False})


capabilities = page(capability_api, request_for("capabilities", 0), {})
assert capabilities["data"][0]["v3_ping"] is True
assert capabilities["meta"]["snapshot"] is True


def chat_api(path, params):
    assert path == "/api/v3/chats"
    assert params == {"start": "0", "perPage": "2"}
    return ApiResult(200, {"response": {
        "rooms": [{"roomId": 7, "roomName": "Private room"}],
        "nextStart": 2,
    }})


chats = page(chat_api, request_for("chat_rooms", 0), {})
assert chats["data"][0]["kind"] == "chat_room"
assert chats["meta"]["next_position"] == 2

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_nodebb*.py"))
]
trees = [ast.parse(source) for source in sources]
request_calls = [
    node
    for tree in trees
    for node in ast.walk(tree)
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Name)
    and node.func.id == "Request"
]
assert request_calls
for node in request_calls:
    methods = [
        keyword.value.value
        for keyword in node.keywords
        if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
    ]
    assert methods == ["GET"]
imports = {
    alias.name.split(".")[0]
    for tree in trees
    for node in ast.walk(tree)
    if isinstance(node, (ast.Import, ast.ImportFrom))
    for alias in (node.names if isinstance(node, ast.Import) else [ast.alias(node.module or "")])
}
assert "requests" not in imports
assert all("_knowledge_social_outbound" not in source for source in sources)
assert all("/api/v3/plugins" not in source for source in sources)
PY
assert_eq "exact routes, namespaces, user-token policy, and GET-only AST are guarded" \
	verified verified

cat >"$TMP_DIR/first.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","userslug":"selected-user","display_name":"Private A","instance_id":"${INSTANCE_A}"}},
  "pages":[{
    "expect_request":{"position":1,"stop_at":null,"limit":1,"instance_id":"${INSTANCE_A}"},
    "response":{"status":200,"observed_at":"2026-07-28T12:01:00Z",
      "data":[{"kind":"topic","remote_id":"nbb_${INSTANCE_A}_topic_100","topic_id":"100","title":"Newest bounded topic","excerpt":"NodeBB fixture knowledge","created_at":"2026-07-28T11:00:00Z"}],
      "meta":{"stream":"authored_topics","instance_id":"${INSTANCE_A}","next_position":2,"newest_id":"nbb_${INSTANCE_A}_topic_100","reached_watermark":false,"complete":false,"snapshot":false}}
  }]
}
JSON
first_result=$("$HELPER" sync-nodebb --base "$BASE" --alias personal:default \
	--connection-id conn_a --account-id user_42 --stream authored_topics \
	--profile fixture --fixture "$TMP_DIR/first.json" --budget 3 --page-size 1)
assert_eq "one bounded NodeBB page pauses initial backfill" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "identity plus one NodeBB page reserves three request units" \
	"$(json_field "$first_result" budget_units)" 3
assert_eq "partial page commits evidence and cursor atomically" \
	"$(sql_value "SELECT count(*) || ':' || (SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_a' AND stream='authored_topics') FROM fetch_batches WHERE connection_id='conn_a'")" \
	"1:0"
assert_eq "authored NodeBB text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1
assert_eq "collector output omits private profile metadata" \
	"$([[ "$first_result" == *Private* || "$first_result" == *selected-user* ]] && printf present || printf absent)" absent

cat >"$TMP_DIR/resume.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","userslug":"selected-user","instance_id":"${INSTANCE_A}"}},
  "pages":[{
    "expect_request":{"position":2,"stop_at":null,"instance_id":"${INSTANCE_A}"},
    "response":{"status":200,"observed_at":"2026-07-28T12:02:00Z",
      "data":[{"kind":"topic","remote_id":"nbb_${INSTANCE_A}_topic_90","topic_id":"90","title":"Older topic"}],
      "meta":{"stream":"authored_topics","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"nbb_${INSTANCE_A}_topic_90","reached_watermark":false,"complete":true,"snapshot":false}}
  }]
}
JSON
second_result=$("$HELPER" sync-nodebb --base "$BASE" --alias personal:default \
	--connection-id conn_a --account-id user_42 --stream authored_topics \
	--profile fixture --fixture "$TMP_DIR/resume.json")
assert_eq "NodeBB backfill resumes from independent page" \
	"$(json_field "$second_result" status)" complete
assert_eq "completed backfill preserves first-page watermark" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_a' AND stream='authored_topics'")" \
	"done:nbb_${INSTANCE_A}_topic_100:1"

cat >"$TMP_DIR/instance-b.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","userslug":"selected-user","instance_id":"${INSTANCE_B}"}},
  "pages":[{"status":200,"observed_at":"2026-07-28T12:03:00Z",
    "data":[{"kind":"topic","remote_id":"nbb_${INSTANCE_B}_topic_100","topic_id":"100","title":"Same local ID, other forum"}],
    "meta":{"stream":"authored_topics","instance_id":"${INSTANCE_B}","next_position":null,"newest_id":"nbb_${INSTANCE_B}_topic_100","reached_watermark":false,"complete":true,"snapshot":false}}]
}
JSON
"$HELPER" sync-nodebb --base "$BASE" --alias personal:default \
	--connection-id conn_b --account-id user_42 --stream authored_topics \
	--profile fixture --fixture "$TMP_DIR/instance-b.json" >/dev/null
assert_eq "two NodeBB installations cannot collide on account or topic IDs" \
	"$(sql_value "SELECT (SELECT count(*) FROM accounts WHERE provider='nodebb') || ':' || (SELECT count(*) FROM objects WHERE provider='nodebb' AND object_type='topic')")" \
	"2:3"

expect_sync_failure "cross-installation connection rebinding is rejected" \
	"$TMP_DIR/instance-b.json" conn_a authored_topics

cat >"$TMP_DIR/identity-mismatch.json" <<JSON
{"identity":{"data":{"provider_account_id":"43","userslug":"other-user","instance_id":"${INSTANCE_A}"}},"pages":[]}
JSON
identity_raw_before=$(raw_count)
expect_sync_failure "selected-account identity mismatch is rejected" \
	"$TMP_DIR/identity-mismatch.json" conn_identity authored_topics
assert_eq "identity mismatch creates no raw evidence" "$(raw_count)" "$identity_raw_before"

cat >"$TMP_DIR/credential.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","userslug":"selected-user","instance_id":"${INSTANCE_A}"}},
  "pages":[{"status":200,"observed_at":"2026-07-28T12:04:00Z","bearer_token":"must-not-persist","data":[],
    "meta":{"stream":"notifications","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":null,"reached_watermark":false,"complete":true,"snapshot":true}}]
}
JSON
credential_raw_before=$(raw_count)
expect_sync_failure "credential-shaped NodeBB pages are rejected" \
	"$TMP_DIR/credential.json" conn_credential notifications
assert_eq "credential rejection creates no raw evidence" "$(raw_count)" "$credential_raw_before"

cat >"$TMP_DIR/malformed.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","userslug":"selected-user","instance_id":"${INSTANCE_A}"}},
  "pages":[{"status":200,"observed_at":"2026-07-28T12:04:30Z","data":{"kind":"post"},
    "meta":{"stream":"bookmarks","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":null,"reached_watermark":false,"complete":true,"snapshot":true}}]
}
JSON
expect_sync_failure "malformed NodeBB page roots are rejected" \
	"$TMP_DIR/malformed.json" conn_malformed bookmarks

python3 - "$TMP_DIR/oversized.json" "$INSTANCE_A" <<'PY'
import json
import sys

instance = sys.argv[2]
data = [
    {
        "kind": "post",
        "remote_id": f"nbb_{instance}_post_{1000 + offset}",
        "post_id": str(1000 + offset),
    }
    for offset in range(101)
]
payload = {
    "identity": {"data": {
        "provider_account_id": "42",
        "userslug": "selected-user",
        "instance_id": instance,
    }},
    "pages": [{
        "status": 200,
        "observed_at": "2026-07-28T12:04:45Z",
        "data": data,
        "meta": {
            "stream": "bookmarks",
            "instance_id": instance,
            "next_position": None,
            "newest_id": data[0]["remote_id"],
            "reached_watermark": False,
            "complete": True,
            "snapshot": True,
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
oversized_raw_before=$(raw_count)
if "$HELPER" sync-nodebb --base "$BASE" --alias personal:default \
	--connection-id conn_oversized --account-id user_42 --stream bookmarks \
	--profile fixture --fixture "$TMP_DIR/oversized.json" --page-size 50 \
	>/dev/null 2>&1; then
	assert_eq "oversized NodeBB pages are rejected" accepted rejected
else
	assert_eq "oversized NodeBB pages are rejected" rejected rejected
fi
assert_eq "oversized rejection creates no raw evidence" \
	"$(raw_count)" "$oversized_raw_before"

run_terminal_fixture forbidden 403 authorization failed
run_terminal_fixture unavailable 404 unavailable unavailable
run_terminal_fixture rate 429 rate_limit paused
run_terminal_fixture provider 500 provider failed

cat >"$TMP_DIR/chats.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","userslug":"selected-user","instance_id":"${INSTANCE_A}"}},
  "pages":[{"status":200,"observed_at":"2026-07-28T12:05:00Z",
    "data":[{"kind":"chat_room","remote_id":"nbb_${INSTANCE_A}_chat_7","room_id":"7","name":"Private room","unread":true}],
    "meta":{"stream":"chat_rooms","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"nbb_${INSTANCE_A}_chat_7","reached_watermark":false,"complete":true,"snapshot":true}}]
}
JSON
"$HELPER" sync-nodebb --base "$BASE" --alias personal:default \
	--connection-id conn_chats --account-id user_42 --stream chat_rooms \
	--profile fixture --fixture "$TMP_DIR/chats.json" >/dev/null
chat_batches=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_chats'")
chat_raw=$(raw_count)
"$HELPER" sync-nodebb --base "$BASE" --alias personal:default \
	--connection-id conn_chats --account-id user_42 --stream chat_rooms \
	--profile fixture --fixture "$TMP_DIR/chats.json" >/dev/null
assert_eq "exact NodeBB snapshot replay is idempotent" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_chats'"):$(raw_count)" \
	"${chat_batches}:${chat_raw}"
assert_eq "chat room metadata remains explicit partial coverage" \
	"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_chats' AND stream='chat_rooms'")" \
	"partial:room_metadata_without_message_bodies"
assert_eq "admin, plugin, export, body, history, and retention gaps remain explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_chats' AND status='unavailable' AND stream IN ('exact_nodebb_version','plugin_inventory','plugin_lists','chat_message_bodies','account_exports','complete_vote_history','deleted_or_purged_content','installation_retention')")" 8

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
from _knowledge_social_nodebb import STREAMS

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_nodebb_fence", "groups", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_nodebb_fence", "groups", "new_runner", "sync", 10),
    now_epoch=9001,
)
account_id = "nbb_aaaaaaaaaaaaaaaaaaaaaaaa_user_42"
context = CollectionContext(
    root,
    "conn_nodebb_fence",
    {"id": account_id},
    "groups",
    "none",
    ConnectionConfig(("groups",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["groups"],
    old,
    "nodebb",
)
archive = {
    "provider": "nodebb",
    "connection_id": "conn_nodebb_fence",
    "remote_account_id": account_id,
    "exported_at": "2026-07-28T12:06:00Z",
    "enabled_streams": ["groups"],
    "policy": {"media_hydration": "none"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
successful = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"groups"}',
    archive,
    PageCheckpoint(None, None),
    True,
    2,
)
os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "9001"
try:
    persist_page(context, successful)
except SocialLeaseLostError:
    pass
else:
    raise SystemExit("stale NodeBB collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    count = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_nodebb_fence'"
    ).fetchone()[0]
assert count == 0
release_run_lease(root, new)
PY
assert_eq "stale NodeBB lease cannot commit evidence or a cursor" verified verified

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
