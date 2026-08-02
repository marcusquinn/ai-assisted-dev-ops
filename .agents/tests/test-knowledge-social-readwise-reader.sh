#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-readwise-reader.sh — Bounded Reader collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_readwise_reader.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/readwise-reader-test.XXXXXX")
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

with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute(sys.argv[2]).fetchone()[0])
PY
	return 0
}

raw_count() {
	python3 - "$ROOT/sources/social/raw/readwise-reader" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_reader() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	if python3 "$READER_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id personal_reader \
		--stream "$stream" --profile fixture --fixture "$fixture" \
		--budget 3 --page-size 1; then
		return 0
	fi
	return 1
}

expect_failure() {
	local description="$1"
	local fixture="$2"
	local connection_id="$3"
	if run_reader "$fixture" "$connection_id" documents >/dev/null 2>&1; then
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

printf 'Readwise Reader social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_readwise_reader import PageRequest, STREAMS, page_checkpoint, page_request
from _knowledge_social_readwise_reader_contract import ApiResult, identity_value
from _knowledge_social_readwise_reader_http import HTTP_TIMEOUT_SECONDS, ProfileConfig, api
from _knowledge_social_readwise_reader_identity import account_id, token_binding, verify_token_binding
from _knowledge_social_readwise_reader_routes import allowlisted_path, page
from knowledge_social_readwise_reader import _enforce_rate_budget

assert set(STREAMS) == {"documents", "tags", "notes", "state", "progress", "locations", "html"}
assert all(allowlisted_path(path) for path in ("/api/v2/auth/", "/api/v3/list/", "/api/v3/tags/"))
assert not allowlisted_path("/api/v3/save/") and not allowlisted_path("/api/v3/update/id/")

key = "k" * 32
binding = token_binding("selected-token", "personal_reader", key)
verify_token_binding("selected-token", "personal_reader", key, binding)
try:
    verify_token_binding("wrong-valid-token", "personal_reader", key, binding)
except RuntimeError:
    pass
else:
    raise AssertionError("wrong valid Reader token passed deployment binding")
identity = identity_value("personal_reader", key)
assert identity["id"] == account_id("personal_reader", key)

request = PageRequest("documents", identity["id"], "personal_reader", None, None, 1)
item = {
    "id": "doc-1", "title": "Bounded Reader item", "summary": "Reader knowledge",
    "created_at": "2026-08-02T07:00:00+00:00", "updated_at": "2026-08-02T07:01:00+00:00",
    "location": "later", "reading_progress": 0.5, "tags": {"research": "Research"},
}
payload = page(lambda _path, _params: ApiResult(200, {"results": [item], "nextPageCursor": "opaque-A"}), request)
checkpoint, complete = page_checkpoint(payload, CursorState(None, None, False), request)
assert not complete and checkpoint.next_cursor and checkpoint.watermark
resumed = page_request("documents", identity, CursorState(checkpoint.next_cursor, checkpoint.watermark, False), 1)
assert resumed.page_cursor == "opaque-A"
incremental = page_request("documents", identity, CursorState(None, checkpoint.watermark, True), 1)
assert incremental.updated_after < checkpoint.watermark

try:
    _enforce_rate_budget(["--budget", "20"])
except RuntimeError:
    pass
else:
    raise AssertionError("Reader request budget exceeded documented rate limit")


class Headers:
    def get(self, _key, default=None):
        return default


class Response:
    headers = Headers()

    def __init__(self, status, payload=b""):
        self.status = status
        self.payload = payload

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
        assert "selected-token" not in request.full_url
        self.request = request
        return self.response


config = ProfileConfig("selected-token", "personal_reader", key, binding)
opener = Opener(Response(204))
assert api(config, opener, "/api/v2/auth/", {}).status == 204
try:
    api(config, opener, "/api/v3/save/", {})
except RuntimeError:
    pass
else:
    raise AssertionError("Reader mutation route was accepted")

sources = [path.read_text(encoding="utf-8") for path in sorted(scripts.glob("_knowledge_social_readwise_reader*.py"))]
trees = [ast.parse(source) for source in sources]
calls = [node for tree in trees for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "Request"]
assert calls
for node in calls:
    methods = [keyword.value.value for keyword in node.keywords if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)]
    assert methods == ["GET"]
PY
assert_eq "token binding, cursor overlap, rate budget, routes, and GET-only AST are guarded" verified verified

python3 - "$TMP_DIR/complete.json" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {"id": "rwr_fixture_account", "binding_account_id": "personal_reader"}},
    "pages": [{
        "expect_request": {"page_cursor": None, "updated_after": None, "limit": 1},
        "response": {
            "status": 200, "observed_at": "2026-08-02T07:10:00Z",
            "data": [{"kind": "document", "remote_id": "rwr_document_fixture",
                      "title": "Bounded Reader item", "body": "Reader knowledge",
                      "created_at": "2026-08-02T07:00:00Z", "updated_at": "2026-08-02T07:01:00Z"}],
            "meta": {"stream": "documents", "next_page_cursor": None,
                     "watermark": "2026-08-02T07:01:00Z"},
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
result=$(run_reader "$TMP_DIR/complete.json" conn_reader documents)
assert_eq "bounded Reader fixture completes" "$(json_field "$result" status)" complete
assert_eq "identity plus page consumes three requests" "$(json_field "$result" budget_units)" 3
assert_eq "Reader document text reaches FTS" "$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'knowledge'")" 1

python3 - "$TMP_DIR/mismatch.json" <<'PY'
import json
import sys

payload = {"identity": {"data": {"id": "rwr_other", "binding_account_id": "other_reader"}}, "pages": []}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "wrong account binding is rejected" "$TMP_DIR/mismatch.json" conn_mismatch
assert_eq "binding mismatch persists no raw evidence" "$(raw_count)" "$raw_before"

python3 - "$TMP_DIR/credential.json" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {"id": "rwr_fixture_account", "binding_account_id": "personal_reader"}},
    "pages": [{"status": 200, "observed_at": "2026-08-02T07:11:00Z",
               "access_token": "must-not-persist", "data": [],
               "meta": {"stream": "documents", "next_page_cursor": None,
                        "watermark": "2026-08-02T07:01:00Z"}}],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "credential-shaped Reader page is rejected" "$TMP_DIR/credential.json" conn_credential
assert_eq "credential rejection persists no raw evidence" "$(raw_count)" "$raw_before"
assert_eq "identity, deletion, export, and retention gaps remain explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_reader' AND status='unavailable'")" 4

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
