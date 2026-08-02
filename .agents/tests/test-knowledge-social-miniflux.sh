#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-miniflux.sh — Bounded Miniflux collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIFLUX_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_miniflux.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/miniflux-social-test.XXXXXX")
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
	python3 - "$ROOT/sources/social/raw/miniflux" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_miniflux() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	local budget="$4"
	local page_size="$5"
	if python3 "$MINIFLUX_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id user_7 \
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
	if run_miniflux "$fixture" "$connection_id" "$stream" 7 40 >/dev/null 2>&1; then
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

printf 'Miniflux social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_miniflux import PageRequest, STREAMS, page_checkpoint, page_request
from _knowledge_social_miniflux_contract import ApiResult, identity_value
from _knowledge_social_miniflux_http import HTTP_TIMEOUT_SECONDS, ProfileConfig, api
from _knowledge_social_miniflux_identity import account_id, installation_id, resource_id
from _knowledge_social_miniflux_routes import allowlisted_path, page

assert set(STREAMS) == {
    "entries", "read", "removed", "starred", "tags", "feeds", "categories", "opml",
}
for allowed in ("/v1/me", "/v1/entries", "/v1/feeds", "/v1/categories", "/v1/export"):
    assert allowlisted_path(allowed)
for rejected in ("/v1/entries/1", "/v1/import", "/v1/feeds/1/refresh", "/v1/api-keys"):
    assert not allowlisted_path(rejected)

instance = installation_id("https://reader.example.test/miniflux", "o" * 32)
identity = identity_value({"id": 7, "username": "reader"}, "7", instance)
assert identity["id"] == account_id(instance, 7)
assert resource_id(instance, "entry", 1) != resource_id(instance, "entry", 2)

request = PageRequest("entries", identity["id"], instance, "7", 0, None, 1)
entry = {
    "id": 9, "user_id": 7, "title": "Bounded feed item",
    "content": "Miniflux knowledge", "published_at": "2026-08-02T06:00:00Z",
    "created_at": "2026-08-02T06:00:01Z", "changed_at": "2026-08-02T06:00:02Z",
    "status": "read", "starred": True, "tags": ["research"],
}
payload = page(lambda _path, _params: ApiResult(200, {"total": 1, "entries": [entry]}), request)
assert payload["data"][0]["title"] == "Bounded feed item"
assert payload["meta"]["has_more"] is True
checkpoint, complete = page_checkpoint(payload, CursorState(None, None, False), request)
assert not complete and checkpoint.next_cursor is not None and checkpoint.watermark is not None
resumed = page_request("entries", identity, CursorState(checkpoint.next_cursor, checkpoint.watermark, False), 1)
assert resumed.after_entry_id == 9
incremental = page_request("entries", identity, CursorState(None, checkpoint.watermark, True), 1)
assert incremental.changed_after == int(checkpoint.watermark) - 1
try:
    page(
        lambda _path, _params: ApiResult(200, {"entries": [entry]}),
        PageRequest("entries", identity["id"], instance, "7", 9, None, 1),
    )
except RuntimeError:
    pass
else:
    raise AssertionError("non-advancing Miniflux entry page was accepted")

opml = page(
    lambda _path, _params: ApiResult(200, '<opml><body><outline text="Feed" xmlUrl="https://feed.example/rss"/></body></opml>'),
    PageRequest("opml", identity["id"], instance, "7", 0, None, 5),
)
assert len(opml["data"]) == 1 and opml["meta"]["snapshot"] is True


class Headers:
    def get(self, _key, default=None):
        return default


class Response:
    status = 200
    headers = Headers()

    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def read(self, size=-1):
        return self.payload[:size]


class Opener:
    def __init__(self, response):
        self.response = response
        self.request = None

    def open(self, request, timeout):
        assert timeout == HTTP_TIMEOUT_SECONDS and request.method == "GET"
        assert request.get_header("X-auth-token") == "private-token"
        assert "private-token" not in request.full_url
        self.request = request
        return self.response


config = ProfileConfig("https://reader.example.test/miniflux", "private-token", "o" * 32, instance)
opener = Opener(Response({"entries": []}))
api(config, opener, "/v1/entries", {"order": "id", "direction": "asc", "limit": "1", "after_entry_id": "0"})
assert opener.request.full_url.startswith("https://reader.example.test/miniflux/v1/entries?")
try:
    api(config, opener, "/v1/import", {})
except RuntimeError:
    pass
else:
    raise AssertionError("Miniflux mutation route was accepted")

sources = [path.read_text(encoding="utf-8") for path in sorted(scripts.glob("_knowledge_social_miniflux*.py"))]
trees = [ast.parse(source) for source in sources]
request_calls = [
    node for tree in trees for node in ast.walk(tree)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "Request"
]
assert request_calls
for node in request_calls:
    methods = [
        keyword.value.value for keyword in node.keywords
        if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
    ]
    assert methods == ["GET"]
PY
assert_eq "identity, routes, incremental overlap, OPML, and GET-only AST are guarded" \
	verified verified

python3 - "$TMP_DIR/complete.json" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_miniflux_identity import account_id, installation_id, resource_id

instance = installation_id("https://reader.example.test/miniflux", "o" * 32)
durable = account_id(instance, 7)
payload = {
    "identity": {"data": {
        "id": durable, "installation_id": instance, "user_id": "7", "username": "reader",
    }},
    "pages": [{
        "expect_request": {"after_entry_id": 0, "changed_after": None, "limit": 1},
        "response": {
            "status": 200, "observed_at": "2026-08-02T06:30:00Z",
            "data": [{
                "kind": "entry", "remote_id": resource_id(instance, "entry", 9),
                "entry_id": 9, "title": "Bounded feed item", "body": "Miniflux knowledge",
                "created_at": "2026-08-02T06:00:01Z", "changed_at": "2026-08-02T06:00:02Z",
                "status": "read", "starred": True, "tags": ["research"],
            }],
            "meta": {"stream": "entries", "has_more": False,
                     "next_after_entry_id": 9, "watermark": 1785650402, "snapshot": False},
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
result=$(run_miniflux "$TMP_DIR/complete.json" conn_miniflux entries 3 1)
assert_eq "bounded Miniflux fixture completes" "$(json_field "$result" status)" complete
assert_eq "identity plus page consumes three request units" \
	"$(json_field "$result" budget_units)" 3
assert_eq "Miniflux entry text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'knowledge'")" 1

python3 - "$TMP_DIR/mismatch.json" <<'PY'
import json
import sys

payload = {"identity": {"data": {
    "id": "wrong", "installation_id": "miniflux_wrong", "user_id": "8",
}}, "pages": []}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "selected-account identity mismatch is rejected" \
	"$TMP_DIR/mismatch.json" conn_mismatch entries
assert_eq "identity mismatch persists no raw evidence" "$(raw_count)" "$raw_before"

python3 - "$TMP_DIR/credential.json" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_miniflux_identity import account_id, installation_id

instance = installation_id("https://reader.example.test/miniflux", "o" * 32)
payload = {
    "identity": {"data": {"id": account_id(instance, 7),
                             "installation_id": instance, "user_id": "7"}},
    "pages": [{"status": 200, "observed_at": "2026-08-02T06:31:00Z",
               "api_token": "must-not-persist", "data": [],
               "meta": {"stream": "feeds", "has_more": False,
                        "next_after_entry_id": 0, "watermark": None, "snapshot": True}}],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "credential-shaped Miniflux page is rejected" \
	"$TMP_DIR/credential.json" conn_credential feeds
assert_eq "credential rejection persists no raw evidence" "$(raw_count)" "$raw_before"

assert_eq "operator-retention and archive gaps remain explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_miniflux' AND status='unavailable'")" 4

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
