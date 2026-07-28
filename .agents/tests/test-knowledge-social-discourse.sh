#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-discourse.sh — Multi-instance Discourse collector tests

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
	python3 - "$ROOT/sources/social/raw/discourse" <<'PY'
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
	if "$HELPER" sync-discourse --base "$BASE" --alias personal:default \
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
	local expected_coverage="$4"
	local fixture="${TMP_DIR}/terminal-${name}.json"
	python3 - "$fixture" "$INSTANCE_A" "$status" <<'PY'
import json
import sys

instance = sys.argv[2]
status = int(sys.argv[3])
page = {
    "status": status,
    "observed_at": f"2026-07-28T09:{status % 60:02d}:00Z",
}
if status == 429:
    page["retry_after"] = 1785200000
payload = {
    "identity": {"data": {
        "provider_account_id": "42",
        "username": "selected_user",
        "instance_id": instance,
    }},
    "pages": [page],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	local result=""
	result=$("$HELPER" sync-discourse --base "$BASE" --alias personal:default \
		--connection-id "conn_terminal_${name}" --account-id user_42 \
		--stream private_messages --profile fixture --fixture "$fixture")
	assert_eq "${status} Discourse response is terminal" \
		"$(json_field "$result" failure_class)" "$expected_failure"
	assert_eq "${status} terminal response records explicit coverage" \
		"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_terminal_${name}' AND stream='private_messages'")" \
		"${expected_coverage}:${expected_failure}"
	assert_eq "${status} terminal response advances no checkpoint" \
		"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_terminal_${name}'")" 0
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Discourse social collector tests\n'

help_output=$("$HELPER" help)
if [[ "$help_output" == *"exact HTTPS installation"* &&
	"$help_output" == *"--page-size is 1-20"* ]]; then
	assert_eq "Discourse CLI advertises the executable safety contract" advertised advertised
else
	assert_eq "Discourse CLI advertises the executable safety contract" missing advertised
fi
matrix_output=$(<"$SCRIPT_DIR/../aidevops/knowledge-plane/06-social-provider-capabilities.md")
docs_output=$(<"$SCRIPT_DIR/../content/social-discourse.md")
if [[ "$matrix_output" == *'| Discourse | **Live** topics and posts'* &&
	"$docs_output" == *'DISCOURSE_<PROFILE>_ORIGIN_KEY'* ]]; then
	assert_eq "Live capability claim is backed by operator evidence" verified verified
else
	assert_eq "Live capability claim is backed by operator evidence" missing verified
fi

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import os
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_discourse import PageRequest, STREAMS, namespaced_id
from _knowledge_social_discourse_contract import ApiResult
from _knowledge_social_discourse_provider import (
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    _api,
    _canonical_base_url,
    _http_exports,
    _profile,
    installation_fingerprint,
)
from _knowledge_social_discourse_routes import (
    EXACT_READ_PATHS,
    allowlisted_path,
    page,
)

expected_streams = {
    "authored_topics", "authored_posts", "likes", "bookmarks",
    "notifications", "private_messages", "sent_messages", "reading_state",
    "groups", "category_preferences",
}
assert set(STREAMS) == expected_streams
assert EXACT_READ_PATHS == {
    "/session/current.json", "/user_actions.json", "/notifications.json",
    "/categories.json",
}
for rejected in (
    "/export_csv/latest_user_archive/42.json",
    "/admin/users/list/active.json",
    "/post_actions/42.json",
    "/topics.json",
):
    assert not allowlisted_path(rejected)

base_a = _canonical_base_url("https://community-a.example.invalid/forum/")
base_b = _canonical_base_url("https://community-b.example.invalid/forum")
origin_key_a = "a" * 32
origin_key_b = "b" * 32
instance_a = installation_fingerprint(base_a, origin_key_a)
instance_b = installation_fingerprint(base_b, origin_key_b)
assert base_a == "https://community-a.example.invalid/forum"
assert instance_a != instance_b
assert installation_fingerprint(base_a, origin_key_b) != instance_a
assert namespaced_id(instance_a, "user", "42") != namespaced_id(
    instance_b, "user", "42"
)
for invalid in (
    "http://community.example.invalid",
    "https://user@example.invalid",
    "https://community.example.invalid/%2e%2e/admin",
):
    try:
        _canonical_base_url(invalid)
    except RuntimeError as error:
        assert "example.invalid" not in str(error)
    else:
        raise AssertionError("unsafe Discourse base URL was accepted")

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
        assert "private-key-value" not in request.full_url
        self.requests.append(request)
        return Response(self.payload)


config = ProfileConfig(base_a, "private-key-value", "read", instance_a)
opener = Opener({"category_list": {"categories": []}})
result = _api(config, opener, "/categories.json", {})
assert result.status == 200
assert len(opener.requests) == 1
assert callable(_http_exports().open)
try:
    _api(config, opener, "/admin/users.json", {})
except RuntimeError:
    pass
else:
    raise AssertionError("non-allowlisted Discourse route was reachable")
try:
    _api(
        config,
        opener,
        "/notifications.json",
        {"username": "selected_user", "offset": "0", "limit": "20", "recent": "true"},
    )
except RuntimeError:
    pass
else:
    raise AssertionError("notification side-effect query was reachable")

os.environ["DISCOURSE_SCOPE_TEST_BASE_URL"] = base_a
os.environ["DISCOURSE_SCOPE_TEST_USER_API_KEY"] = "private-key-value"
os.environ["DISCOURSE_SCOPE_TEST_ORIGIN_KEY"] = origin_key_a
os.environ["DISCOURSE_SCOPE_TEST_USER_API_SCOPE"] = "write"
try:
    _profile("scope_test")
except RuntimeError:
    pass
else:
    raise AssertionError("Discourse write scope was accepted")

request = PageRequest(
    "authored_topics",
    namespaced_id(instance_a, "user", "42"),
    "42",
    "selected_user",
    instance_a,
    0,
    None,
    1,
)
seen = []

def action_api(path, params):
    seen.append((path, params))
    return ApiResult(
        200,
        {"user_actions": [{
            "action_type": 4, "topic_id": 100, "post_id": 101,
            "title": "Selected topic", "excerpt": "Bounded body",
            "created_at": "2026-07-28T09:00:00Z",
        }]},
    )

serialized = page(action_api, request, {})
assert serialized["data"][0]["remote_id"] == namespaced_id(instance_a, "topic", "100")
assert serialized["meta"]["next_position"] == 1
assert seen == [(
    "/user_actions.json",
    {"username": "selected_user", "filter": "4", "offset": "0", "limit": "1"},
)]

def request_for(stream, limit=2):
    return PageRequest(
        stream,
        namespaced_id(instance_a, "user", "42"),
        "42",
        "selected_user",
        instance_a,
        0,
        None,
        limit,
    )


def route_result(stream, payload, identity=None, limit=2):
    calls = []

    def api(path, params):
        calls.append((path, params))
        return ApiResult(200, payload)

    return page(api, request_for(stream, limit), identity or {}), calls


authored_post, _ = route_result(
    "authored_posts",
    {"user_actions": [{"action_type": 5, "topic_id": 7, "post_id": 8}]},
)
assert authored_post["data"][0]["kind"] == "post"

likes, _ = route_result(
    "likes",
    {"user_actions": [{"action_type": 1, "topic_id": 7, "post_id": 8}]},
)
assert likes["meta"]["snapshot"] is True

bookmarks, bookmark_calls = route_result(
    "bookmarks",
    {"user_bookmark_list": {"bookmarks": [{"id": 9, "post_id": 8}], "more_bookmarks_url": None}},
)
assert bookmarks["meta"]["snapshot"] is True
assert bookmark_calls[0][0] == "/u/selected_user/bookmarks.json"

notifications, notification_calls = route_result(
    "notifications",
    {
        "notifications": [{"id": 10, "notification_type": 1, "read": False}],
        "total_rows_notifications": 1,
        "load_more_notifications": "/notifications?offset=1",
    },
    limit=1,
)
assert notifications["meta"]["complete"] is True
assert notifications["meta"]["next_position"] is None
assert "recent" not in notification_calls[0][1]

empty_notifications, _ = route_result(
    "notifications",
    {
        "notifications": [],
        "total_rows_notifications": 0,
        "load_more_notifications": "/notifications?offset=0",
    },
    limit=1,
)
assert empty_notifications["meta"]["complete"] is True

message_payload = {
    "topic_list": {
        "topics": [{"id": 11, "archetype": "private_message", "title": "Subject"}],
        "per_page": 20,
        "more_topics_url": None,
    }
}
received, received_calls = route_result("private_messages", message_payload)
sent, sent_calls = route_result("sent_messages", message_payload)
assert received["meta"]["snapshot"] is True
assert sent["meta"]["snapshot"] is True
assert "/private-messages/" in received_calls[0][0]
assert "/private-messages-sent/" in sent_calls[0][0]

reading, _ = route_result(
    "reading_state",
    [{"topic_id": 12, "highest_post_number": 3, "last_read_post_number": 2}],
)
assert reading["data"][0]["kind"] == "topic_state"

identity = {
    "groups": [{"id": "13", "name": "Members", "has_messages": True, "owner": False}],
    "category_preferences": {"watched": ["14"]},
}
groups, group_calls = route_result("groups", {}, identity)
assert groups["data"][0]["kind"] == "group"
assert group_calls == []

categories, category_calls = route_result(
    "category_preferences",
    {"category_list": {"categories": [{"id": 14, "name": "Selected"}]}},
    identity,
)
assert categories["data"][0]["preference_levels"] == ["watched"]
assert category_calls[0][0] == "/categories.json"

def expect_route_rejection(stream, payload, identity=None, limit=20):
    try:
        route_result(stream, payload, identity, limit)
    except RuntimeError:
        return
    raise AssertionError(f"oversized or stalled {stream} route was accepted")


expect_route_rejection(
    "notifications",
    {"notifications": [], "total_rows_notifications": 1},
    limit=1,
)
expect_route_rejection(
    "private_messages",
    {"topic_list": {"topics": [{}] * 101, "per_page": 20}},
)
expect_route_rejection("reading_state", [{}] * 1001)
expect_route_rejection("groups", {}, {"groups": [{}] * 1001})
expect_route_rejection(
    "category_preferences",
    {"category_list": {"categories": [{}] * 1001}},
    {"category_preferences": {}},
)

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_discourse*.py"))
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
assert "pydiscourse" not in imports
assert all("_knowledge_social_outbound" not in source for source in sources)
PY
assert_eq "stdlib transport, exact routes, namespaces, scope, and GET-only AST are guarded" \
	verified verified

cat >"$TMP_DIR/minimum-budget.json" <<JSON
{"identity":{"data":{"provider_account_id":"42","username":"selected_user","instance_id":"${INSTANCE_A}"}},"pages":[]}
JSON
for budget in 1 2; do
	if "$HELPER" sync-discourse --base "$BASE" --alias personal:default \
		--connection-id "conn_budget_${budget}" --account-id user_42 \
		--stream authored_topics --profile fixture \
		--fixture "$TMP_DIR/minimum-budget.json" --budget "$budget" \
		>/dev/null 2>&1; then
		assert_eq "Discourse budget ${budget} is rejected" accepted rejected
	else
		assert_eq "Discourse budget ${budget} is rejected" rejected rejected
	fi
done
assert_eq "rejected budgets create no run receipts" \
	"$(sql_value "SELECT count(*) FROM sync_runs WHERE connection_id LIKE 'conn_budget_%'")" 0

cat >"$TMP_DIR/instance-a-first.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected_user","name":"Private A","instance_id":"${INSTANCE_A}"}},
  "pages":[{
    "expect_request":{"position":0,"stop_at":null,"limit":1,"instance_id":"${INSTANCE_A}","provider_account_id":"42"},
    "response":{"status":200,"observed_at":"2026-07-28T10:00:00Z",
      "data":[{"kind":"topic","remote_id":"dsc_${INSTANCE_A}_topic_100","topic_id":"100","post_id":"101","action_type":4,"title":"Newest bounded topic","excerpt":"Discourse fixture knowledge","created_at":"2026-07-28T09:00:00Z"}],
      "meta":{"stream":"authored_topics","instance_id":"${INSTANCE_A}","next_position":1,"newest_id":"dsc_${INSTANCE_A}_topic_100","reached_watermark":false,"complete":false,"snapshot":false}}
  }]
}
JSON
first_result=$("$HELPER" sync-discourse --base "$BASE" --alias personal:default \
	--connection-id conn_instance_a --account-id user_42 --stream authored_topics \
	--profile fixture --fixture "$TMP_DIR/instance-a-first.json" \
	--budget 3 --page-size 1)
assert_eq "one bounded Discourse page pauses the initial backfill" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "identity plus one page reserves three request units" \
	"$(json_field "$first_result" budget_units)" 3
assert_eq "partial page commits evidence and its cursor atomically" \
	"$(sql_value "SELECT (SELECT count(*) FROM fetch_batches WHERE connection_id='conn_instance_a') || ':' || (SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_instance_a' AND stream='authored_topics')")" \
	"1:0"
assert_eq "authored Discourse text reaches the FTS projection" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1
assert_eq "collector output omits private identity metadata" \
	"$([[ "$first_result" == *Private* || "$first_result" == *selected_user* ]] && printf present || printf absent)" absent

cat >"$TMP_DIR/instance-a-resume.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected_user","instance_id":"${INSTANCE_A}"}},
  "pages":[{
    "expect_request":{"position":1,"stop_at":null,"instance_id":"${INSTANCE_A}"},
    "response":{"status":200,"observed_at":"2026-07-28T10:01:00Z",
      "data":[{"kind":"topic","remote_id":"dsc_${INSTANCE_A}_topic_90","topic_id":"90","post_id":"91","action_type":4,"title":"Older topic","excerpt":"Resumed page","created_at":"2026-07-27T09:00:00Z"}],
      "meta":{"stream":"authored_topics","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"dsc_${INSTANCE_A}_topic_90","reached_watermark":false,"complete":true,"snapshot":false}}
  }]
}
JSON
second_result=$("$HELPER" sync-discourse --base "$BASE" --alias personal:default \
	--connection-id conn_instance_a --account-id user_42 --stream authored_topics \
	--profile fixture --fixture "$TMP_DIR/instance-a-resume.json")
assert_eq "Discourse backfill resumes from its independent position" \
	"$(json_field "$second_result" status)" complete
assert_eq "completed backfill preserves the first-page watermark" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_instance_a' AND stream='authored_topics'")" \
	"done:dsc_${INSTANCE_A}_topic_100:1"

cat >"$TMP_DIR/instance-a-delta.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected_user","instance_id":"${INSTANCE_A}"}},
  "pages":[{
    "expect_request":{"position":0,"stop_at":"dsc_${INSTANCE_A}_topic_100","instance_id":"${INSTANCE_A}"},
    "response":{"status":200,"observed_at":"2026-07-28T10:01:30Z",
      "data":[{"kind":"topic","remote_id":"dsc_${INSTANCE_A}_topic_110","topic_id":"110","post_id":"111","action_type":4,"title":"Incremental topic","created_at":"2026-07-28T10:01:00Z"}],
      "meta":{"stream":"authored_topics","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"dsc_${INSTANCE_A}_topic_110","reached_watermark":true,"complete":true,"snapshot":false}}
  }]
}
JSON
"$HELPER" sync-discourse --base "$BASE" --alias personal:default \
	--connection-id conn_instance_a --account-id user_42 --stream authored_topics \
	--profile fixture --fixture "$TMP_DIR/instance-a-delta.json" >/dev/null
assert_eq "authored-content delta advances its stable watermark" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_instance_a' AND stream='authored_topics'")" \
	"dsc_${INSTANCE_A}_topic_110"

cat >"$TMP_DIR/instance-b.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected_user","instance_id":"${INSTANCE_B}"}},
  "pages":[{"status":200,"observed_at":"2026-07-28T10:02:00Z",
    "data":[{"kind":"topic","remote_id":"dsc_${INSTANCE_B}_topic_100","topic_id":"100","post_id":"101","action_type":4,"title":"Same local ID, other installation","created_at":"2026-07-28T08:00:00Z"}],
    "meta":{"stream":"authored_topics","instance_id":"${INSTANCE_B}","next_position":null,"newest_id":"dsc_${INSTANCE_B}_topic_100","reached_watermark":false,"complete":true,"snapshot":false}}]
}
JSON
"$HELPER" sync-discourse --base "$BASE" --alias personal:default \
	--connection-id conn_instance_b --account-id user_42 --stream authored_topics \
	--profile fixture --fixture "$TMP_DIR/instance-b.json" >/dev/null
assert_eq "two installations cannot collide on account or topic IDs" \
	"$(sql_value "SELECT (SELECT count(*) FROM accounts WHERE provider='discourse') || ':' || (SELECT count(*) FROM objects WHERE provider='discourse' AND object_type='topic')")" \
	"2:4"
assert_eq "installation checkpoints retain distinct stable origins" \
	"$(sql_value "SELECT count(DISTINCT watermark) FROM sync_cursors WHERE connection_id IN ('conn_instance_a','conn_instance_b') AND stream='authored_topics'")" 2

batches_before_rebind=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_instance_a'")
expect_sync_failure "cross-installation connection rebinding is rejected" \
	"$TMP_DIR/instance-b.json" conn_instance_a user_42 authored_topics
assert_eq "rebind rejection preserves prior evidence and checkpoints" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_instance_a'")" \
	"$batches_before_rebind"

cat >"$TMP_DIR/identity-mismatch.json" <<JSON
{"identity":{"data":{"provider_account_id":"43","username":"other_user","instance_id":"${INSTANCE_A}"}},"pages":[]}
JSON
identity_raw_before=$(raw_count)
expect_sync_failure "selected-account identity mismatch is rejected" \
	"$TMP_DIR/identity-mismatch.json" conn_identity_mismatch user_42 authored_topics
assert_eq "identity mismatch creates no raw evidence" "$(raw_count)" "$identity_raw_before"

cat >"$TMP_DIR/credential.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected_user","instance_id":"${INSTANCE_A}"}},
  "pages":[{"status":200,"observed_at":"2026-07-28T10:03:00Z","api_key":"must-not-persist","data":[],
    "meta":{"stream":"authored_topics","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":null,"reached_watermark":false,"complete":true,"snapshot":false}}]
}
JSON
credential_raw_before=$(raw_count)
expect_sync_failure "credential-shaped Discourse pages are rejected" \
	"$TMP_DIR/credential.json" conn_credential user_42 authored_topics
assert_eq "credential rejection creates no raw evidence" \
	"$(raw_count)" "$credential_raw_before"

cat >"$TMP_DIR/malformed.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected_user","instance_id":"${INSTANCE_A}"}},
  "pages":[{"status":200,"observed_at":"2026-07-28T10:04:00Z","data":{"kind":"topic"},
    "meta":{"stream":"authored_topics","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":null,"reached_watermark":false,"complete":true,"snapshot":false}}]
}
JSON
expect_sync_failure "malformed Discourse page roots are rejected" \
	"$TMP_DIR/malformed.json" conn_malformed user_42 authored_topics

python3 - "$TMP_DIR/oversized.json" "$INSTANCE_A" <<'PY'
import json
import sys

instance = sys.argv[2]
data = [
    {
        "kind": "topic",
        "remote_id": f"dsc_{instance}_topic_{200 + offset}",
        "topic_id": str(200 + offset),
        "action_type": 4,
    }
    for offset in range(21)
]
payload = {
    "identity": {"data": {
        "provider_account_id": "42",
        "username": "selected_user",
        "instance_id": instance,
    }},
    "pages": [{
        "status": 200,
        "observed_at": "2026-07-28T10:04:30Z",
        "data": data,
        "meta": {
            "stream": "authored_topics",
            "instance_id": instance,
            "next_position": None,
            "newest_id": data[0]["remote_id"],
            "reached_watermark": False,
            "complete": True,
            "snapshot": False,
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
oversized_raw_before=$(raw_count)
expect_sync_failure "oversized Discourse pages are rejected before persistence" \
	"$TMP_DIR/oversized.json" conn_oversized user_42 authored_topics
assert_eq "oversized page rejection creates no raw evidence" \
	"$(raw_count)" "$oversized_raw_before"

run_terminal_fixture forbidden 403 authorization failed
run_terminal_fixture unavailable 404 unavailable unavailable
run_terminal_fixture rate 429 rate_limit paused
run_terminal_fixture provider 500 provider failed

cat >"$TMP_DIR/messages.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected_user","instance_id":"${INSTANCE_A}"}},
  "pages":[{"status":200,"observed_at":"2026-07-28T10:05:00Z",
    "data":[{"kind":"private_message_topic","remote_id":"dsc_${INSTANCE_A}_message_500","topic_id":"500","title":"Private scope-gated subject","created_at":"2026-07-28T08:00:00Z","last_posted_at":"2026-07-28T09:00:00Z","posts_count":2,"unread_posts":1}],
    "meta":{"stream":"private_messages","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"dsc_${INSTANCE_A}_message_500","reached_watermark":false,"complete":true,"snapshot":true}}]
}
JSON
"$HELPER" sync-discourse --base "$BASE" --alias personal:default \
	--connection-id conn_messages --account-id user_42 --stream private_messages \
	--profile fixture --fixture "$TMP_DIR/messages.json" >/dev/null
assert_eq "authorized messages persist topic metadata without bodies" \
	"$(sql_value "SELECT object_type || ':' || json_extract(provider_json,'$.record.posts_count') FROM objects WHERE remote_id='dsc_${INSTANCE_A}_message_500'")" \
	"private_message_topic:2"
assert_eq "private-message body limits remain explicit partial coverage" \
	"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_messages' AND stream='private_messages'")" \
	"partial:private_message_topic_metadata_only"
assert_eq "unsupported plugin, archive, search, body, and history routes remain gaps" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_messages' AND status='unavailable' AND stream IN ('account_archive','followers','following','watched_topics','tracked_topics','private_message_bodies','complete_reading_history')")" 7

cat >"$TMP_DIR/messages-update.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected_user","instance_id":"${INSTANCE_A}"}},
  "pages":[{
    "expect_request":{"position":0,"stop_at":null},
    "response":{"status":200,"observed_at":"2026-07-28T10:05:30Z",
      "data":[{"kind":"private_message_topic","remote_id":"dsc_${INSTANCE_A}_message_500","topic_id":"500","title":"Private scope-gated subject","created_at":"2026-07-28T08:00:00Z","last_posted_at":"2026-07-28T10:05:00Z","posts_count":3,"unread_posts":2}],
      "meta":{"stream":"private_messages","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"dsc_${INSTANCE_A}_message_500","reached_watermark":false,"complete":true,"snapshot":true}}
  }]
}
JSON
"$HELPER" sync-discourse --base "$BASE" --alias personal:default \
	--connection-id conn_messages --account-id user_42 --stream private_messages \
	--profile fixture --fixture "$TMP_DIR/messages-update.json" >/dev/null
assert_eq "mutable message-topic metadata is refreshed by a full snapshot" \
	"$(sql_value "SELECT json_extract(provider_json,'$.record.posts_count') || ':' || json_extract(provider_json,'$.record.unread_posts') FROM objects WHERE remote_id='dsc_${INSTANCE_A}_message_500'")" \
	"3:2"
assert_eq "message snapshots never persist a stable-ID watermark" \
	"$(sql_value "SELECT coalesce(watermark,'none') FROM sync_cursors WHERE connection_id='conn_messages' AND stream='private_messages'")" none

cat >"$TMP_DIR/groups.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected_user","instance_id":"${INSTANCE_A}"}},
  "pages":[{"status":200,"observed_at":"2026-07-28T10:06:00Z",
    "data":[{"kind":"group","remote_id":"dsc_${INSTANCE_A}_group_7","group_id":"7","name":"Fixture group","has_messages":true,"owner":false}],
    "meta":{"stream":"groups","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"dsc_${INSTANCE_A}_group_7","reached_watermark":false,"complete":true,"snapshot":true}}]
}
JSON
"$HELPER" sync-discourse --base "$BASE" --alias personal:default \
	--connection-id conn_groups --account-id user_42 --stream groups \
	--profile fixture --fixture "$TMP_DIR/groups.json" >/dev/null
group_batches=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_groups'")
group_raw=$(raw_count)
"$HELPER" sync-discourse --base "$BASE" --alias personal:default \
	--connection-id conn_groups --account-id user_42 --stream groups \
	--profile fixture --fixture "$TMP_DIR/groups.json" >/dev/null
assert_eq "exact snapshot replay is content-addressed and idempotent" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_groups'"):$(raw_count)" \
	"${group_batches}:${group_raw}"
assert_eq "group replay leaves one stable membership" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='discourse' AND activity_type='group_membership' AND object_remote_id='dsc_${INSTANCE_A}_group_7'")" 1

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
from _knowledge_social_discourse import STREAMS
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    release_run_lease,
)

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_discourse_fence", "groups", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_discourse_fence", "groups", "new_runner", "sync", 10),
    now_epoch=9001,
)
account_id = "dsc_aaaaaaaaaaaaaaaaaaaaaaaa_user_42"
context = CollectionContext(
    root,
    "conn_discourse_fence",
    {"id": account_id},
    "groups",
    "none",
    ConnectionConfig(("groups",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["groups"],
    old,
    "discourse",
)
archive = {
    "provider": "discourse",
    "connection_id": "conn_discourse_fence",
    "remote_account_id": account_id,
    "exported_at": "2026-07-28T10:07:00Z",
    "enabled_streams": ["groups"],
    "policy": {"media_hydration": "none"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
page = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"groups"}',
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
    raise SystemExit("stale Discourse collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    cursor = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_discourse_fence'"
    ).fetchone()[0]
assert cursor == 0
release_run_lease(root, new)
PY
assert_eq "stale Discourse lease cannot commit evidence or a cursor" verified verified

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
