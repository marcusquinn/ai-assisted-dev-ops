#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-freshrss.sh — Bounded FreshRSS collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRESHRSS_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_freshrss.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/freshrss-social-test.XXXXXX")
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
	python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' \
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
	python3 - "$ROOT/sources/social/raw/freshrss" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_freshrss() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	local budget="$4"
	local page_size="$5"
	if python3 "$FRESHRSS_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id reader \
		--stream "$stream" --profile fixture --fixture "$fixture" \
		--budget "$budget" --page-size "$page_size"; then
		return 0
	fi
	return 1
}

expect_failure() {
	local description="$1"
	local fixture="$2"
	local connection_id="$3"
	local stream="$4"
	if run_freshrss "$fixture" "$connection_id" "$stream" 8 10 >/dev/null 2>&1; then
		assert_eq "$description" accepted rejected
	else
		assert_eq "$description" rejected rejected
	fi
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'FreshRSS social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_freshrss import PageRequest, STREAMS, page_checkpoint, page_request
from _knowledge_social_freshrss_contract import ApiResult, identity_value
from _knowledge_social_freshrss_http import (
    API_PREFIX,
    HTTP_TIMEOUT_SECONDS,
    LOGIN_PATH,
    ProfileConfig,
    api,
    login,
)
from _knowledge_social_freshrss_identity import account_id, installation_id, resource_id
from _knowledge_social_freshrss_routes import (
    ITEMS_PATH,
    OPML_PATH,
    STARRED_PATH,
    SUBSCRIPTIONS_PATH,
    TAGS_PATH,
    allowlisted_path,
    page,
)

assert set(STREAMS) == {
    "items", "unread", "starred", "subscriptions", "folders", "tags", "opml",
}
for allowed in (
    "/reader/api/0/user-info", SUBSCRIPTIONS_PATH, TAGS_PATH,
    ITEMS_PATH, STARRED_PATH, OPML_PATH,
):
    assert allowlisted_path(allowed)
for rejected in (
    "/reader/api/0/token",
    "/reader/api/0/subscription/edit",
    "/reader/api/0/edit-tag",
    "/reader/api/0/mark-all-as-read",
    "/api/fever.php",
):
    assert not allowlisted_path(rejected)

instance = installation_id("https://reader.example.test/freshrss", "o" * 32)
identity = identity_value(
    {"userId": "reader", "userName": "reader", "userProfileId": "reader"},
    "reader",
    instance,
)
assert identity["id"] == account_id(instance, "reader")
assert resource_id(instance, "entry", "tag:google.com,2005:reader/item/1") != resource_id(
    instance, "entry", "tag:google.com,2005:reader/item/2"
)

item = {
    "id": "tag:google.com,2005:reader/item/9",
    "crawlTimeMsec": "1785650402000",
    "timestampUsec": "1785650402000000",
    "published": 1785650402,
    "title": "Bounded feed item",
    "author": "Author",
    "canonical": [{"href": "https://site.example/article"}],
    "categories": ["user/-/label/research"],
    "origin": {
        "streamId": "feed/7",
        "title": "Example feed",
        "htmlUrl": "https://site.example/",
    },
    "summary": {"content": "FreshRSS knowledge"},
}
request = PageRequest("items", identity["id"], instance, "reader", None, None, 1)
observed_requests = []


def item_api(path, params):
    observed_requests.append((path, params))
    return ApiResult(
        200,
        {"id": "reading-list", "updated": 1785650402, "items": [item], "continuation": "c-1"},
    )


payload = page(item_api, request)
assert observed_requests == [(ITEMS_PATH, {"output": "json", "n": "1", "r": "o"})]
assert payload["data"][0]["title"] == "Bounded feed item"
checkpoint, complete = page_checkpoint(payload, CursorState(None, None, False), request)
assert not complete and checkpoint.next_cursor is not None
resumed = page_request(
    "items", identity, CursorState(checkpoint.next_cursor, checkpoint.watermark, False), 1
)
assert resumed.continuation == "c-1" and resumed.newer_than is None
incremental = page_request(
    "items", identity, CursorState(None, checkpoint.watermark, True), 1
)
assert incremental.newer_than == 1785650401

unread = page(
    lambda path, params: ApiResult(200, {"updated": 1785650402, "items": [item]}),
    PageRequest("unread", identity["id"], instance, "reader", None, None, 10),
)
assert unread["data"][0]["read"] is False
starred_item = dict(item, categories=["user/-/state/com.google/starred"])
starred = page(
    lambda path, params: ApiResult(200, {"updated": 1785650402, "items": [starred_item]}),
    PageRequest("starred", identity["id"], instance, "reader", None, None, 10),
)
assert starred["data"][0]["starred"] is True

subscriptions = page(
    lambda path, params: ApiResult(200, {"subscriptions": [{
        "id": "feed/7", "title": "Example", "url": "https://feed.example/rss",
        "htmlUrl": "https://site.example/",
        "categories": [{"id": "user/-/label/Research", "label": "Research"}],
    }]}),
    PageRequest("subscriptions", identity["id"], instance, "reader", None, None, 10),
)
assert subscriptions["data"][0]["folders"] == ["Research"]

tag_payload = {"tags": [
    {"id": "user/-/label/Research", "label": "Research", "type": "folder"},
    {"id": "user/-/label/Pinned", "label": "Pinned", "type": "tag", "unread_count": 0},
    {"id": "user/-/state/com.google/read"},
]}
folders = page(
    lambda path, params: ApiResult(200, tag_payload),
    PageRequest("folders", identity["id"], instance, "reader", None, None, 10),
)
tags = page(
    lambda path, params: ApiResult(200, tag_payload),
    PageRequest("tags", identity["id"], instance, "reader", None, None, 10),
)
assert [record["kind"] for record in folders["data"]] == ["folder"]
assert [record["kind"] for record in tags["data"]] == ["tag"]

opml = page(
    lambda path, params: ApiResult(
        200,
        '<opml xmlns:frss="https://freshrss.org/opml"><body><outline text="Research">'
        '<outline text="Feed" type="rss" xmlUrl="https://feed.example/rss" '
        'htmlUrl="https://site.example/" frss:CURLOPT_COOKIE="must-not-persist"/>'
        '</outline></body></opml>',
    ),
    PageRequest("opml", identity["id"], instance, "reader", None, None, 10),
)
assert opml["data"][0]["category"] == "Research"
assert "CURLOPT" not in json.dumps(opml)


class Headers:
    def get(self, _key, default=None):
        return default


class Response:
    status = 200
    headers = Headers()

    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def read(self, size=-1):
        return self.payload[:size]


class Opener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        assert timeout == HTTP_TIMEOUT_SECONDS
        self.requests.append(request)
        return self.responses.pop(0)


config = ProfileConfig(
    "https://reader.example.test/freshrss", "reader", "private-password", "o" * 32, instance
)
opener = Opener([
    Response(b"SID=reader/hash\nLSID=null\nAuth=reader/hash\n"),
    Response(b'{"subscriptions": []}'),
])
authorized = login(config, opener)
assert authorized.payload == "reader/hash"
api(config, opener, authorized.payload, SUBSCRIPTIONS_PATH, {"output": "json"})
assert opener.requests[0].method == "POST"
assert opener.requests[0].full_url.endswith(f"{API_PREFIX}{LOGIN_PATH}")
assert "private-password" not in opener.requests[0].full_url
assert opener.requests[1].method == "GET"
assert opener.requests[1].get_header("Authorization") == "GoogleLogin auth=reader/hash"

http_source = (scripts / "_knowledge_social_freshrss_http.py").read_text(encoding="utf-8")
tree = ast.parse(http_source)
methods = {}
for node in tree.body:
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in {"login", "api"}:
        methods[node.name] = [
            keyword.value.value
            for call in ast.walk(node)
            if isinstance(call, ast.Call)
            and isinstance(call.func, ast.Name)
            and call.func.id == "Request"
            for keyword in call.keywords
            if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
        ]
assert methods == {"login": ["POST"], "api": ["GET"]}
all_sources = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_freshrss*.py"))
)
assert "/reader/api/0/token" not in all_sources
assert "fever.php" not in all_sources
PY
assert_eq "identity, routes, pagination, snapshots, and POST/GET AST are guarded" \
	verified verified

python3 - "$TMP_DIR" <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_freshrss_identity import account_id, installation_id, resource_id

target = Path(sys.argv[1])
instance = installation_id("https://reader.example.test/freshrss", "o" * 32)
durable = account_id(instance, "reader")
identity = {
    "status": 200,
    "data": {
        "id": durable,
        "installation_id": instance,
        "user_id": "reader",
        "username": "reader",
    },
}


def record(native, title, body, *, read=False, starred=False):
    return {
        "kind": "entry",
        "remote_id": resource_id(instance, "entry", native),
        "native_id": native,
        "title": title,
        "body": body,
        "author": "Author",
        "url": f"https://site.example/{native}",
        "published_at": "2026-08-02T06:00:02Z",
        "created_at": "2026-08-02T06:00:02Z",
        "read": read,
        "starred": starred,
        "labels": ["research"],
    }


def response(stream, data, *, continuation=None, watermark=None, snapshot=False):
    return {
        "status": 200,
        "observed_at": "2026-08-02T06:30:00Z",
        "data": data,
        "meta": {
            "stream": stream,
            "has_more": continuation is not None,
            "next_continuation": continuation,
            "watermark": watermark,
            "snapshot": snapshot,
        },
    }


def write(name, pages, selected_identity=identity):
    (target / name).write_text(
        json.dumps({"identity": selected_identity, "pages": pages}), encoding="utf-8"
    )


write("items-first.json", [{
    "expect_request": {"continuation": None, "newer_than": None, "limit": 1},
    "response": response(
        "items", [record("entry-1", "First item", "FreshRSS first knowledge")],
        continuation="opaque-cursor", watermark=1785650402,
    ),
}])
write("items-second.json", [{
    "expect_request": {"continuation": "opaque-cursor", "newer_than": None, "limit": 1},
    "response": response(
        "items", [record("entry-2", "Second item", "FreshRSS resumed knowledge")],
        watermark=1785650403,
    ),
}])
write("items-replay.json", [{
    "expect_request": {"continuation": None, "newer_than": 1785650402, "limit": 1},
    "response": response(
        "items", [record("entry-2", "Second item", "FreshRSS resumed knowledge")],
        watermark=1785650403,
    ),
}])

snapshot_rows = {
    "subscriptions": [{
        "kind": "feed", "remote_id": resource_id(instance, "feed", "feed/7"),
        "native_id": "feed/7", "title": "Example feed",
        "url": "https://feed.example/rss", "html_url": "https://site.example/",
        "folders": ["Research"],
    }],
    "folders": [{
        "kind": "folder", "remote_id": resource_id(instance, "folder", "Research"),
        "native_id": "user/-/label/Research", "title": "Research", "unread_count": None,
    }],
    "tags": [{
        "kind": "tag", "remote_id": resource_id(instance, "tag", "Pinned"),
        "native_id": "user/-/label/Pinned", "title": "Pinned", "unread_count": 0,
    }],
    "opml": [{
        "kind": "feed", "remote_id": resource_id(instance, "opml_feed", "https://feed.example/rss"),
        "title": "Example feed", "url": "https://feed.example/rss",
        "html_url": "https://site.example/", "description": None,
        "feed_type": "rss", "category": "Research",
    }],
}
for stream, rows in snapshot_rows.items():
    write(
        f"{stream}.json",
        [{"response": response(stream, rows, snapshot=True)}],
    )

write("unread.json", [{
    "response": response(
        "unread", [record("entry-3", "Unread item", "Unread knowledge")],
        watermark=1785650404,
    ),
}])
write("starred.json", [{
    "response": response(
        "starred", [record("entry-4", "Starred item", "Starred knowledge", starred=True)],
        watermark=1785650405,
    ),
}])

write("credential.json", [{
    "response": {
        **response("subscriptions", [], snapshot=True),
        "api_password": "must-not-persist",
    },
}])
write("malformed.json", [{
    "response": {
        **response("items", [], continuation="stuck", watermark=1785650402),
        "meta": {
            "stream": "items", "has_more": True, "next_continuation": "",
            "watermark": 1785650402, "snapshot": False,
        },
    },
}])
write("terminal.json", [{
    "response": {"status": 500, "observed_at": "2026-08-02T06:30:00Z"},
}])
wrong = {
    "status": 200,
    "data": {
        "id": account_id(instance, "other"), "installation_id": instance,
        "user_id": "other", "username": "other",
    },
}
write("mismatch.json", [], wrong)
PY

result=$(run_freshrss "$TMP_DIR/items-first.json" conn_freshrss items 5 1)
assert_eq "bounded first page stops at its request budget" \
	"$(json_field "$result" status)" budget_exhausted
assert_eq "login, identity, and one data page consume five units" \
	"$(json_field "$result" budget_units)" 5

result=$(run_freshrss "$TMP_DIR/items-second.json" conn_freshrss items 5 1)
assert_eq "opaque continuation resumes to completion" \
	"$(json_field "$result" status)" complete
assert_eq "resumed FreshRSS text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'resumed'")" 1

objects_before=$(sql_value "SELECT count(*) FROM objects WHERE provider='freshrss'")
run_freshrss "$TMP_DIR/items-replay.json" conn_freshrss items 5 1 >/dev/null
assert_eq "incremental overlap replays idempotently" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='freshrss'")" "$objects_before"

for stream in subscriptions folders tags unread starred opml; do
	run_freshrss "$TMP_DIR/${stream}.json" conn_freshrss "$stream" 5 10 >/dev/null
done
assert_eq "all seven fixture-proven streams retain independent checkpoints" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_freshrss'")" 7

objects_before=$(sql_value "SELECT count(*) FROM objects WHERE provider='freshrss'")
run_freshrss "$TMP_DIR/subscriptions.json" conn_freshrss subscriptions 5 10 >/dev/null
assert_eq "subscription snapshot replay never duplicates or infers deletion" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='freshrss'")" "$objects_before"

raw_before=$(raw_count)
expect_failure "selected-account identity mismatch is rejected" \
	"$TMP_DIR/mismatch.json" conn_mismatch items
assert_eq "identity mismatch persists no raw evidence" "$(raw_count)" "$raw_before"

expect_failure "credential-shaped FreshRSS page is rejected" \
	"$TMP_DIR/credential.json" conn_credential subscriptions
assert_eq "credential rejection preserves prior evidence" "$(raw_count)" "$raw_before"

expect_failure "malformed continuation is rejected" \
	"$TMP_DIR/malformed.json" conn_malformed items
assert_eq "malformed page preserves its absent checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_malformed'")" 0

raw_before=$(raw_count)
result=$(run_freshrss "$TMP_DIR/terminal.json" conn_terminal items 5 10)
assert_eq "terminal provider failure is sanitized" "$(json_field "$result" status)" failed
assert_eq "terminal failure emits one sanitized raw boundary" \
	"$(raw_count)" "$((raw_before + 1))"
assert_eq "terminal failure preserves its absent checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_terminal'")" 0

assert_eq "retention, deletion, archive, and Fever POST gaps remain explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_freshrss' AND status='unavailable'")" 4

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
