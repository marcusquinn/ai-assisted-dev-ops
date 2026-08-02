#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-stack-exchange.sh — Bounded Stack Exchange collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_stack_exchange.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/stack-exchange-social-test.XXXXXX")
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
	python3 - "$ROOT/sources/social/raw/stack-exchange" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_stack() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	local budget="$4"
	local page_size="$5"
	if python3 "$STACK_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id account_500 \
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
	if run_stack "$fixture" "$connection_id" "$stream" 7 40 >/dev/null 2>&1; then
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

printf 'Stack Exchange social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import os
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_stack_exchange import PageRequest, STREAMS, page_checkpoint, page_request
from _knowledge_social_stack_exchange_contract import ApiResult, identity_value, wrapper
from _knowledge_social_stack_exchange_http import HTTP_TIMEOUT_SECONDS, ProfileConfig, api
from _knowledge_social_stack_exchange_identity import (
    account_id, associated_account_id, namespaced_id,
)
import _knowledge_social_stack_exchange_provider as provider
from _knowledge_social_stack_exchange_provider import _profile
from _knowledge_social_stack_exchange_routes import allowlisted_path, page

assert set(STREAMS) == {
    "posts", "questions", "answers", "comments", "favorites", "inbox",
    "notifications", "associated_accounts",
}
assert all(spec.cost_units == 2 and spec.pagination == "snapshot" for spec in STREAMS.values())
for allowed in ("/me", "/me/posts", "/me/favorites", "/me/associated"):
    assert allowlisted_path(allowed)
for rejected in (
    "/questions/add", "/questions/1/favorite", "/answers/1/upvote",
    "/access-tokens/token/invalidate", "/apps/token/de-authenticate",
):
    assert not allowlisted_path(rejected)

identity = identity_value({
    "items": [{"account_id": 500, "user_id": 42, "display_name": "selected"}],
    "has_more": False, "quota_remaining": 9999,
}, "500", "stackoverflow")
assert identity["id"] == account_id(500, "stackoverflow", 42)
assert namespaced_id("stackoverflow", "post", 1) != namespaced_id("superuser", "post", 1)
assert associated_account_id(500, "https://stackoverflow.com", 42) != associated_account_id(
    500, "https://superuser.com", 42
)
try:
    identity_value({
        "items": [{"account_id": 501, "user_id": 42}],
        "has_more": False, "quota_remaining": 9999,
    }, "500", "stackoverflow")
except RuntimeError:
    pass
else:
    raise AssertionError("mismatched Stack Exchange network identity was accepted")

assert wrapper({"items": [], "has_more": True, "backoff": 5, "quota_remaining": 9}, limit=100)[2] == 5

os.environ.update({
    "STACK_EXCHANGE_SCOPE_ACCESS_TOKEN": "private-token",
    "STACK_EXCHANGE_SCOPE_SITE": "stackoverflow",
    "STACK_EXCHANGE_SCOPE_SCOPES": "write_access",
})
try:
    _profile("scope")
except RuntimeError:
    pass
else:
    raise AssertionError("write-authorized Stack Exchange profile was accepted")


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
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        assert timeout == HTTP_TIMEOUT_SECONDS
        assert request.method == "GET"
        assert "private-token" not in request.full_url
        self.requests.append(request)
        return self.responses.pop(0)


config = ProfileConfig("private-token", "stackoverflow", frozenset())
original_api = provider.api
provider.api = lambda *_args: ApiResult(200, {
    "items": [{"account_id": 500, "user_id": 42}], "has_more": False,
    "backoff": 5, "quota_remaining": 9999,
})
assert provider._identity(config, None, "500")["status"] == 429
provider.api = original_api
opener = Opener([Response({"items": [], "has_more": False, "quota_remaining": 9999})])
api(config, opener, "/me/posts", {"site": "stackoverflow", "page": "1", "pagesize": "2", "filter": "withbody"})
assert opener.requests[0].full_url.startswith("https://api.stackexchange.com/2.3/me/posts?")
try:
    api(config, opener, "/questions/add", {})
except RuntimeError:
    pass
else:
    raise AssertionError("Stack Exchange write route was accepted")

request = PageRequest(
    "posts", identity["id"], "500", "42", "stackoverflow", 1, 2,
)
post = {
    "post_id": 7, "post_type": "question", "title": "Bounded question",
    "body_markdown": "Stack Exchange knowledge", "creation_date": 1785630000,
    "score": -1,
}
payload = page(
    lambda _path, _params: ApiResult(200, {
        "items": [post], "has_more": True, "quota_remaining": 9998,
    }),
    request,
)
assert payload["data"][0]["score"] == -1
checkpoint, complete = page_checkpoint(payload, CursorState(None, None, False), request)
assert not complete and checkpoint.next_cursor is not None
resumed = page_request("posts", identity, CursorState(checkpoint.next_cursor, None, False), 2)
assert resumed.page == 2

backoff = page(
    lambda _path, _params: ApiResult(200, {
        "items": [], "has_more": True, "backoff": 5, "quota_remaining": 9997,
    }),
    request,
)
assert isinstance(backoff, ApiResult) and backoff.status == 429 and backoff.retry_after is not None

sources = [path.read_text(encoding="utf-8") for path in sorted(scripts.glob("_knowledge_social_stack_exchange*.py"))]
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
assert_eq "identity, routes, paging, backoff, scopes, and GET-only AST are guarded" \
	verified verified

python3 - "$TMP_DIR/complete.json" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_stack_exchange_identity import account_id, namespaced_id

durable = account_id("500", "stackoverflow", "42")
payload = {
    "identity": {"data": {
        "id": durable, "network_account_id": "500", "site_user_id": "42",
        "api_site_parameter": "stackoverflow", "display_name": "selected",
    }},
    "pages": [{
        "expect_request": {"page": 1, "limit": 1},
        "response": {
            "status": 200, "observed_at": "2026-08-02T06:15:00Z",
            "data": [{
                "kind": "question", "remote_id": namespaced_id("stackoverflow", "question", 7),
                "title": "Bounded question", "body": "Stack Exchange knowledge",
                "created_at": 1785630000,
            }],
            "meta": {"stream": "posts", "api_site_parameter": "stackoverflow",
                     "has_more": False, "quota_remaining": 9998, "snapshot": True},
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
result=$(run_stack "$TMP_DIR/complete.json" conn_stack posts 3 1)
assert_eq "bounded Stack Exchange fixture completes" "$(json_field "$result" status)" complete
assert_eq "identity plus page consumes three request units" \
	"$(json_field "$result" budget_units)" 3
assert_eq "authored Stack Exchange text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'knowledge'")" 1

python3 - "$TMP_DIR/mismatch.json" <<'PY'
import json
import sys

payload = {"identity": {"data": {
    "id": "wrong", "network_account_id": "501", "site_user_id": "42",
    "api_site_parameter": "stackoverflow",
}}, "pages": []}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "selected-network identity mismatch is rejected" \
	"$TMP_DIR/mismatch.json" conn_mismatch posts
assert_eq "identity mismatch persists no raw evidence" "$(raw_count)" "$raw_before"

python3 - "$TMP_DIR/credential.json" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_stack_exchange_identity import account_id

payload = {
    "identity": {"data": {"id": account_id("500", "stackoverflow", "42"),
                            "network_account_id": "500", "site_user_id": "42",
                            "api_site_parameter": "stackoverflow"}},
    "pages": [{"status": 200, "observed_at": "2026-08-02T06:16:00Z",
               "access_token": "must-not-persist", "data": [],
               "meta": {"stream": "favorites", "api_site_parameter": "stackoverflow",
                        "has_more": False, "quota_remaining": 9997, "snapshot": True}}],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "credential-shaped Stack Exchange page is rejected" \
	"$TMP_DIR/credential.json" conn_credential favorites
assert_eq "credential rejection persists no raw evidence" "$(raw_count)" "$raw_before"

assert_eq "unavailable history categories remain explicit gaps" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_stack' AND status='unavailable'")" 7

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
