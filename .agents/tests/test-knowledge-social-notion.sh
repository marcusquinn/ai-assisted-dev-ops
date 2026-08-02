#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-notion.sh — Bounded Notion Sites collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTION_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_notion.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/notion-social-test.XXXXXX")
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
WORKSPACE_ID="11111111-1111-4111-8111-111111111111"
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
	python3 - "$ROOT/sources/social/raw/notion-sites" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

raw_contains() {
	local needle="$1"
	python3 - "$ROOT/sources/social/raw/notion-sites" "$needle" <<'PY'
import gzip
import sys
from pathlib import Path

root = Path(sys.argv[1])
needle = sys.argv[2]
matches = 0
if root.exists():
    for path in root.rglob("*.json.gz"):
        with gzip.open(path, "rt", encoding="utf-8") as source:
            matches += needle in source.read()
print(matches)
PY
	return 0
}

run_notion() {
	local fixture="$1"
	local connection_id="$2"
	local budget="$3"
	local page_size="$4"
	local workspace_id="${5:-$WORKSPACE_ID}"
	if python3 "$NOTION_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id "$workspace_id" \
		--stream site_tree --profile fixture --fixture "$fixture" \
		--budget "$budget" --page-size "$page_size"; then
		return 0
	fi
	return 1
}

expect_failure() {
	local description="$1"
	local fixture="$2"
	local connection_id="$3"
	local budget="$4"
	local page_size="$5"
	if run_notion "$fixture" "$connection_id" "$budget" "$page_size" \
		>/dev/null 2>&1; then
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

printf 'Notion Sites social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import os
import sys
import uuid
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_notion import (
    API_VERSION,
    STREAMS,
    Limits,
    PageRequest,
    Task,
    TraversalState,
    _encode_state,
    page_checkpoint,
    page_request,
    parse_page_request,
    task_value,
)
from _knowledge_social_notion_contract import (
    ApiResult,
    NotionReadProviderError,
    file_descriptors,
    plain_text,
)
from _knowledge_social_notion_http import (
    API_ORIGIN,
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    _RejectRedirect,
    identity_api,
    task_api,
)
from _knowledge_social_notion_identity import NotionAdapterError, notion_id
from _knowledge_social_notion_provider import (
    _handle_result,
    _page,
    _profile_matches,
)

WORKSPACE = "11111111-1111-4111-8111-111111111111"
BOT = "22222222-2222-4222-8222-222222222222"
ROOT = "33333333-3333-4333-8333-333333333333"
BLOCK = "44444444-4444-4444-8444-444444444444"
EMBED = "55555555-5555-4555-8555-555555555555"
FILE = "66666666-6666-4666-8666-666666666666"
DATABASE = "77777777-7777-4777-8777-777777777777"
SOURCE = "88888888-8888-4888-8888-888888888888"
ROW = "99999999-9999-4999-8999-999999999999"
COMMENT = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
DISCUSSION = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
CREATOR = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
LIMITS = Limits(3, 20, 50, 1024 * 1024)
ACCOUNT = {
    "id": WORKSPACE,
    "workspace_id": WORKSPACE,
    "root_page_ids": [ROOT],
    "include_comments": False,
    "limits": LIMITS.payload(),
}


def expect_error(callback, message):
    try:
        callback()
    except (NotionAdapterError, NotionReadProviderError):
        return
    raise AssertionError(message)


def response(request, data=None, discoveries=None, *, cursor=None,
             page_count=0, block_count=0, response_bytes=100,
             request_status="complete", limit_reason=None):
    return {
        "status": 200,
        "observed_at": "2026-08-02T12:00:00Z",
        "data": data or [],
        "meta": {
            "block_count": block_count,
            "discoveries": [item.payload() for item in (discoveries or [])],
            "limit_reason": limit_reason,
            "next_cursor": cursor,
            "page_count": page_count,
            "request_sha256": request.digest(),
            "request_status": request_status,
            "response_bytes": response_bytes,
            "task": request.task.payload(),
        },
    }


def state_for(request):
    task = request.task
    traversal = TraversalState((task,), frozenset({task.key()}), 0, 0, 0)
    return CursorState(_encode_state(traversal, request.binding), None, False)


assert set(STREAMS) == {"site_tree"}
assert STREAMS["site_tree"].cost_units == 2
assert notion_id(ROOT.replace("-", ""), "root") == ROOT
expect_error(lambda: notion_id("https://example.invalid/notion-page", "root"),
             "public Notion Site URL was accepted as a root")

initial = page_request("site_tree", ACCOUNT, CursorState(None, None, False), 100)
assert initial.task == Task("page", ROOT, 0)
assert parse_page_request(initial.payload()) == initial

first_payload = response(
    initial,
    [{"kind": "page", "id": ROOT, "parent": {"type": "workspace"},
      "text": "Root"}],
    [Task("blocks", ROOT, 0)],
    page_count=1,
)
checkpoint, complete = page_checkpoint(
    first_payload, CursorState(None, None, False), initial
)
assert not complete and checkpoint.next_cursor
resumed_state = CursorState(checkpoint.next_cursor, checkpoint.watermark, False)
resumed = page_request("site_tree", ACCOUNT, resumed_state, 100)
assert resumed.task == Task("blocks", ROOT, 0)

changed_root = dict(ACCOUNT, root_page_ids=[BLOCK])
expect_error(
    lambda: page_request("site_tree", changed_root, resumed_state, 100),
    "durable cursor resumed under a different root policy",
)
changed_limits = dict(ACCOUNT, limits=Limits(2, 20, 50, 1024 * 1024).payload())
expect_error(
    lambda: page_request("site_tree", changed_limits, resumed_state, 100),
    "durable cursor resumed under different traversal limits",
)

escaped = response(
    resumed,
    [],
    [Task("page", BLOCK, 1, parent_kind="page_id", parent_id=BLOCK)],
)
expect_error(
    lambda: page_checkpoint(escaped, resumed_state, resumed),
    "discovery escaped the requested parent",
)

understated_depth = response(
    resumed,
    [],
    [Task("blocks", BLOCK, 0, parent_kind="page_id", parent_id=ROOT)],
)
expect_error(
    lambda: page_checkpoint(understated_depth, resumed_state, resumed),
    "descendant discovery understated its traversal depth",
)

same_cursor_request = PageRequest(
    resumed.workspace_id,
    resumed.root_page_ids,
    resumed.limits,
    resumed.include_comments,
    resumed.binding,
    Task("blocks", ROOT, 0, "opaque-A"),
    resumed.page_size,
)
same_cursor_payload = response(same_cursor_request, cursor="opaque-A")
same_cursor_state = state_for(same_cursor_request)
expect_error(
    lambda: page_checkpoint(
        same_cursor_payload,
        same_cursor_state,
        same_cursor_request,
    ),
    "non-advancing Notion cursor was accepted",
)

data_source_request = PageRequest(
    initial.workspace_id,
    initial.root_page_ids,
    initial.limits,
    initial.include_comments,
    initial.binding,
    Task(
        "data_source", SOURCE, 1,
        parent_kind="database_id", parent_id=DATABASE,
        database_id=DATABASE,
    ),
    100,
)
wrong_parent = response(
    data_source_request,
    [],
    [Task(
        "blocks", ROW, 2,
        parent_kind="data_source_id", parent_id=BLOCK,
        database_id=DATABASE,
    )],
)
data_source_state = state_for(data_source_request)
expect_error(
    lambda: page_checkpoint(
        wrong_parent,
        data_source_state,
        data_source_request,
    ),
    "data-source row discovery escaped its exact data source",
)

bad_data_source_task = Task(
    "data_source", SOURCE, 1,
    parent_kind="page_id", parent_id=DATABASE, database_id=DATABASE,
)
expect_error(
    lambda: task_value(bad_data_source_task.payload(), LIMITS),
    "data-source task without an exact database parent was accepted",
)

for key, count in (("page_count", 21), ("block_count", 51), ("response_bytes", 1024 * 1024 + 1)):
    kwargs = {key: count}
    bounded = response(initial, **kwargs)
    expect_error(
        lambda bounded=bounded: page_checkpoint(
            bounded, CursorState(None, None, False), initial
        ),
        f"{key} budget overrun was accepted",
    )

depth_limited = response(initial, limit_reason="depth")
expect_error(
    lambda: page_checkpoint(depth_limited, CursorState(None, None, False), initial),
    "provider depth exhaustion advanced a checkpoint",
)

small_limits = Limits(1, 1, 1, 65536)
small_account = dict(ACCOUNT, limits=small_limits.payload())
small_request = page_request("site_tree", small_account, CursorState(None, None, False), 100)
queue_request = PageRequest(
    small_request.workspace_id,
    small_request.root_page_ids,
    small_request.limits,
    small_request.include_comments,
    small_request.binding,
    Task("blocks", ROOT, 0),
    small_request.page_size,
)
queue_state = state_for(queue_request)
many = []
for index in range(1, 106):
    child_id = str(uuid.UUID(int=index))
    many.append(Task("blocks", child_id, 1, parent_kind="page_id", parent_id=ROOT))
queue_payload = response(queue_request, discoveries=many)
expect_error(
    lambda: page_checkpoint(
        queue_payload, queue_state, queue_request
    ),
    "durable queue safety limit was accepted",
)

config = ProfileConfig(
    "fixture-access-value", WORKSPACE, (ROOT,), False,
    LIMITS.max_depth, LIMITS.max_pages, LIMITS.max_blocks, LIMITS.max_bytes,
)
_profile_matches(initial, config)
expect_error(
    lambda: _profile_matches(
        initial,
        ProfileConfig(
            "fixture-access-value", WORKSPACE, (BLOCK,), False,
            LIMITS.max_depth, LIMITS.max_pages, LIMITS.max_blocks, LIMITS.max_bytes,
        ),
    ),
    "secret profile root mismatch was accepted",
)

root_raw = {
    "object": "page",
    "id": ROOT,
    "parent": {"type": "workspace", "workspace": True},
    "created_time": "2026-08-02T11:00:00Z",
    "last_edited_time": "2026-08-02T11:01:00Z",
    "public_url": "https://example.invalid/public-root",
    "properties": {
        "title": {"type": "title", "title": [{"plain_text": "Authorized root"}]},
    },
    "cover": {
        "type": "file",
        "file": {
            "url": "https://example.invalid/signed-cover",
            "expiry_time": "2026-08-02T12:00:00Z",
        },
    },
}
root_result = _handle_result(ApiResult(200, root_raw, 120), initial)
encoded_root = json.dumps(root_result, sort_keys=True)
assert "Authorized root" in encoded_root
assert "signed-cover" not in encoded_root and "public-root" not in encoded_root
assert root_result["data"][0]["files"][0]["kind"] == "notion_hosted"
assert [item["kind"] for item in root_result["meta"]["discoveries"]] == ["blocks"]

block_request = PageRequest(
    initial.workspace_id, initial.root_page_ids, initial.limits,
    initial.include_comments, initial.binding, Task("blocks", ROOT, 0), 100,
)
blocks_raw = {
    "object": "list",
    "results": [
        {
            "object": "block", "id": BLOCK,
            "parent": {"type": "page_id", "page_id": ROOT},
            "type": "paragraph", "has_children": True,
            "paragraph": {"rich_text": [{"plain_text": "Nested knowledge"}]},
        },
        {
            "object": "block", "id": EMBED,
            "parent": {"type": "page_id", "page_id": ROOT},
            "type": "embed", "has_children": False,
            "embed": {"url": "https://example.invalid/embed-target"},
        },
        {
            "object": "block", "id": FILE,
            "parent": {"type": "page_id", "page_id": ROOT},
            "type": "file", "has_children": False,
            "file": {
                "type": "external",
                "external": {"url": "https://example.invalid/file-target"},
            },
        },
    ],
    "has_more": False,
    "next_cursor": None,
}
blocks_result = _handle_result(ApiResult(200, blocks_raw, 240), block_request)
encoded_blocks = json.dumps(blocks_result, sort_keys=True)
assert "Nested knowledge" in encoded_blocks
assert "embed-target" not in encoded_blocks and "file-target" not in encoded_blocks
assert blocks_result["data"][1]["external_target_not_fetched"] is True
assert blocks_result["data"][2]["files"][0]["kind"] == "external"
assert [item["resource_id"] for item in blocks_result["meta"]["discoveries"]] == [BLOCK]

database_request = PageRequest(
    initial.workspace_id, initial.root_page_ids, initial.limits,
    initial.include_comments, initial.binding,
    Task("database", DATABASE, 1, parent_kind="page_id", parent_id=ROOT), 100,
)
database_raw = {
    "object": "database", "id": DATABASE,
    "parent": {"type": "page_id", "page_id": ROOT},
    "title": [{"plain_text": "Structured notes"}],
    "data_sources": [{"id": SOURCE, "name": "Primary"}],
}
database_result = _handle_result(ApiResult(200, database_raw, 100), database_request)
assert database_result["data"][0]["kind"] == "database"
assert database_result["meta"]["discoveries"][0]["resource_id"] == SOURCE

row_request = data_source_request
row_raw = {
    "object": "list",
    "results": [{
        "object": "page", "id": ROW,
        "parent": {
            "type": "data_source_id", "data_source_id": SOURCE,
            "database_id": DATABASE,
        },
        "properties": {
            "title": {"type": "title", "title": [{"plain_text": "Structured row"}]},
        },
        "public_url": None,
    }],
    "has_more": True,
    "next_cursor": "opaque-row-cursor",
}
row_result = _handle_result(ApiResult(200, row_raw, 100), row_request)
assert row_result["data"][0]["text"] == "Structured row"
assert row_result["meta"]["next_cursor"] == "opaque-row-cursor"
assert row_result["meta"]["discoveries"][0]["parent_id"] == SOURCE

comment_request = PageRequest(
    initial.workspace_id, initial.root_page_ids, initial.limits,
    True, initial.binding, Task("comments", ROOT, 0), 100,
)
comment_raw = {
    "object": "list",
    "results": [{
        "object": "comment", "id": COMMENT,
        "parent": {"type": "page_id", "page_id": ROOT},
        "discussion_id": DISCUSSION,
        "created_by": {"object": "user", "id": CREATOR},
        "created_time": "2026-08-02T11:02:00Z",
        "rich_text": [{"plain_text": "Open comment"}],
        "attachments": [{
            "type": "external",
            "external": {"url": "https://example.invalid/comment-file"},
        }],
    }],
    "has_more": False,
    "next_cursor": None,
}
comment_result = _handle_result(ApiResult(200, comment_raw, 100), comment_request)
encoded_comment = json.dumps(comment_result, sort_keys=True)
assert "Open comment" in encoded_comment and "comment-file" not in encoded_comment
assert comment_result["data"][0]["kind"] == "comment"

assert plain_text({"rich_text": [{"plain_text": "Safe text"}]}) == "Safe text"
expect_error(
    lambda: plain_text({"rich_text": [{"plain_text": "access_token=must-not-persist"}]}),
    "credential-shaped rich text was accepted",
)
files = file_descriptors({
    "type": "external",
    "external": {"url": "https://example.invalid/file"},
})
assert files == [{"disposition": "external_target_not_fetched", "kind": "external"}]


class Headers:
    def get(self, _key, default=None):
        return default


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
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        assert timeout == HTTP_TIMEOUT_SECONDS
        self.requests.append(request)
        return self.responses.pop(0)


route_tasks = [
    Task("page", ROOT, 0),
    Task("blocks", ROOT, 0, "opaque-A"),
    Task("database", DATABASE, 1, parent_kind="page_id", parent_id=ROOT),
    Task("comments", ROOT, 0, "opaque-B"),
    Task(
        "data_source", SOURCE, 1, "opaque-C",
        parent_kind="database_id", parent_id=DATABASE, database_id=DATABASE,
    ),
]
route_opener = Opener([Response({}) for _ in range(len(route_tasks) + 1)])
assert identity_api(config, route_opener).status == 200
for task in route_tasks:
    request = PageRequest(
        WORKSPACE, (ROOT,), LIMITS, False, initial.binding, task, 17
    )
    assert task_api(config, route_opener, request).status == 200

methods = [request.method for request in route_opener.requests]
assert methods == ["GET", "GET", "GET", "GET", "GET", "POST"]
assert route_opener.requests[0].full_url == f"{API_ORIGIN}/v1/users/me"
assert route_opener.requests[1].full_url == f"{API_ORIGIN}/v1/pages/{ROOT}"
assert route_opener.requests[3].full_url == f"{API_ORIGIN}/v1/databases/{DATABASE}"
assert urlsplit(route_opener.requests[4].full_url).path == "/v1/comments"
assert parse_qs(urlsplit(route_opener.requests[4].full_url).query) == {
    "block_id": [ROOT], "page_size": ["17"], "start_cursor": ["opaque-B"],
}
assert route_opener.requests[5].full_url == f"{API_ORIGIN}/v1/data_sources/{SOURCE}/query"
assert json.loads(route_opener.requests[5].data) == {
    "page_size": 17, "start_cursor": "opaque-C",
}
assert all(request.full_url.startswith(f"{API_ORIGIN}/v1/") for request in route_opener.requests)
assert _RejectRedirect().redirect_request(None) is None

identity_raw = {
    "object": "user", "type": "bot", "id": BOT,
    "bot": {
        "workspace_id": WORKSPACE, "workspace_name": "Fixture workspace",
        "owner": {"type": "workspace", "workspace": True},
    },
}
live_opener = Opener([Response(identity_raw), Response(root_raw)])
live_result = _page(live_opener, config, initial)
assert live_result["status"] == 200
assert [request.method for request in live_opener.requests] == ["GET", "GET"]
assert live_opener.requests[0].full_url.endswith("/v1/users/me")
assert live_opener.requests[1].full_url.endswith(f"/v1/pages/{ROOT}")

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_notion*.py"))
]
trees = [ast.parse(source) for source in sources]
verbs = {
    node.value
    for tree in trees
    for node in ast.walk(tree)
    if isinstance(node, ast.Constant)
    and isinstance(node.value, str)
    and node.value in {"GET", "POST", "PUT", "PATCH", "DELETE"}
}
assert verbs == {"GET", "POST"}
assert all("/v1/search" not in source for source in sources)
assert all("urlopen(" not in source and "requests." not in source for source in sources)
PY
assert_eq "workspace/root bindings, provider projections, budgets, redirects, and exact routes are guarded" \
	verified verified

python3 - "$TMP_DIR" "$SCRIPT_DIR/../scripts" <<'PY'
import json
import sys
from pathlib import Path

target = Path(sys.argv[1])
sys.path.insert(0, sys.argv[2])

from _knowledge_social_collect import CursorState
from _knowledge_social_notion import Limits, Task, page_checkpoint, page_request

WORKSPACE = "11111111-1111-4111-8111-111111111111"
BOT = "22222222-2222-4222-8222-222222222222"
ROOT = "33333333-3333-4333-8333-333333333333"
BLOCK = "44444444-4444-4444-8444-444444444444"
DATABASE = "77777777-7777-4777-8777-777777777777"
SOURCE = "88888888-8888-4888-8888-888888888888"
ROW_ONE = "99999999-9999-4999-8999-999999999991"
ROW_TWO = "99999999-9999-4999-8999-999999999992"
COMMENT = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
DISCUSSION = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
CREATOR = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
LIMITS = Limits(4, 20, 50, 1024 * 1024)


def account(comments=False, workspace=WORKSPACE, roots=(ROOT,)):
    return {
        "bot_id": BOT,
        "id": workspace,
        "include_comments": comments,
        "limits": LIMITS.payload(),
        "owner_type": "workspace",
        "root_page_ids": list(roots),
        "workspace_id": workspace,
        "workspace_name": "Fixture workspace",
    }


def identity(comments=False, workspace=WORKSPACE, roots=(ROOT,)):
    data = account(comments, workspace, roots)
    data["api_version"] = "2026-03-11"
    data["response_bytes"] = 80
    return {
        "status": 200,
        "observed_at": "2026-08-02T12:10:00Z",
        "data": data,
    }


def success(request, data=None, discoveries=None, *, cursor=None,
            page_count=0, block_count=0, response_bytes=100,
            request_status="complete", limit_reason=None, observed_at="2026-08-02T12:11:00Z"):
    return {
        "status": 200,
        "observed_at": observed_at,
        "data": data or [],
        "meta": {
            "block_count": block_count,
            "discoveries": [item.payload() for item in (discoveries or [])],
            "limit_reason": limit_reason,
            "next_cursor": cursor,
            "page_count": page_count,
            "request_sha256": request.digest(),
            "request_status": request_status,
            "response_bytes": response_bytes,
            "task": request.task.payload(),
        },
    }


def entry(request, response):
    return {"expect_request": {"task": request.task.payload()}, "response": response}


def advance(state, request, payload):
    checkpoint, complete = page_checkpoint(payload, state, request)
    return CursorState(checkpoint.next_cursor, checkpoint.watermark, complete)


def write(name, identity_payload, pages):
    (target / name).write_text(
        json.dumps({"identity": identity_payload, "pages": pages}),
        encoding="utf-8",
    )


def page_record(page_id, text, parent=None):
    return {
        "created_at": "2026-08-02T12:00:00Z",
        "files": [],
        "id": page_id,
        "in_trash": False,
        "kind": "page",
        "last_edited_at": "2026-08-02T12:01:00Z",
        "parent": parent or {"type": "workspace"},
        "published": True,
        "text": text,
    }


initial_state = CursorState(None, None, False)

# Minimal complete page + child-block traversal, including URL-free file metadata.
complete_account = account()
complete_request = page_request("site_tree", complete_account, initial_state, 100)
complete_page = success(
    complete_request,
    [{
        **page_record(ROOT, "Notion fixture knowledge"),
        "files": [{
            "disposition": "metadata_only_not_fetched",
            "expiry_time": "2026-08-02T13:00:00Z",
            "kind": "notion_hosted",
        }],
    }],
    [Task("blocks", ROOT, 0)],
    page_count=1,
)
complete_state = advance(initial_state, complete_request, complete_page)
complete_blocks_request = page_request("site_tree", complete_account, complete_state, 100)
complete_blocks = success(
    complete_blocks_request,
    [{
        "block_type": "paragraph",
        "created_at": "2026-08-02T12:00:00Z",
        "external_target_not_fetched": False,
        "files": [],
        "id": BLOCK,
        "in_trash": False,
        "kind": "block",
        "last_edited_at": "2026-08-02T12:01:00Z",
        "parent": {"type": "page_id", "page_id": ROOT},
        "text": "Nested fixture paragraph",
    }],
    block_count=1,
)
write(
    "complete.json",
    identity(),
    [entry(complete_request, complete_page), entry(complete_blocks_request, complete_blocks)],
)

# Two-invocation budget resume uses the durable queue head.
write("resume-first.json", identity(), [entry(complete_request, complete_page)])
write("resume-second.json", identity(), [entry(complete_blocks_request, complete_blocks)])

# Child database, opaque data-source cursor, and row block traversal.
structured_account = account()
structured_state = initial_state
structured_pages = []
request = page_request("site_tree", structured_account, structured_state, 100)
payload = success(
    request,
    [page_record(ROOT, "Structured root")],
    [Task("blocks", ROOT, 0)],
    page_count=1,
)
structured_pages.append(entry(request, payload))
structured_state = advance(structured_state, request, payload)

request = page_request("site_tree", structured_account, structured_state, 100)
payload = success(
    request,
    [{
        "block_type": "child_database", "files": [], "id": DATABASE,
        "in_trash": False, "kind": "block",
        "parent": {"type": "page_id", "page_id": ROOT},
        "text": "Fixture database",
    }],
    [Task("database", DATABASE, 1, parent_kind="page_id", parent_id=ROOT)],
    block_count=1,
)
structured_pages.append(entry(request, payload))
structured_state = advance(structured_state, request, payload)

request = page_request("site_tree", structured_account, structured_state, 100)
payload = success(
    request,
    [{
        "files": [], "id": DATABASE, "kind": "database",
        "parent": {"type": "page_id", "page_id": ROOT},
        "text": "Structured notes",
    }],
    [Task(
        "data_source", SOURCE, 1,
        parent_kind="database_id", parent_id=DATABASE, database_id=DATABASE,
    )],
)
structured_pages.append(entry(request, payload))
structured_state = advance(structured_state, request, payload)

request = page_request("site_tree", structured_account, structured_state, 100)
payload = success(
    request,
    [page_record(
        ROW_ONE,
        "Structured Notion row one",
        {"type": "data_source_id", "data_source_id": SOURCE, "database_id": DATABASE},
    )],
    [Task(
        "blocks", ROW_ONE, 2,
        parent_kind="data_source_id", parent_id=SOURCE, database_id=DATABASE,
    )],
    cursor="opaque-row-page",
    page_count=1,
)
structured_pages.append(entry(request, payload))
structured_state = advance(structured_state, request, payload)

request = page_request("site_tree", structured_account, structured_state, 100)
assert request.task.cursor == "opaque-row-page"
payload = success(
    request,
    [page_record(
        ROW_TWO,
        "Structured Notion row two",
        {"type": "data_source_id", "data_source_id": SOURCE, "database_id": DATABASE},
    )],
    [Task(
        "blocks", ROW_TWO, 2,
        parent_kind="data_source_id", parent_id=SOURCE, database_id=DATABASE,
    )],
    page_count=1,
)
structured_pages.append(entry(request, payload))
structured_state = advance(structured_state, request, payload)

for row_id in (ROW_ONE, ROW_TWO):
    request = page_request("site_tree", structured_account, structured_state, 100)
    assert request.task.resource_id == row_id
    payload = success(request)
    structured_pages.append(entry(request, payload))
    structured_state = advance(structured_state, request, payload)
assert structured_state.backfill_complete
write("structured.json", identity(), structured_pages)

# Comments are capability-gated and independently paginated in the queue.
comment_account = account(comments=True)
comment_state = initial_state
comment_pages = []
request = page_request("site_tree", comment_account, comment_state, 100)
payload = success(
    request,
    [page_record(ROOT, "Commented root")],
    [Task("blocks", ROOT, 0), Task("comments", ROOT, 0)],
    page_count=1,
)
comment_pages.append(entry(request, payload))
comment_state = advance(comment_state, request, payload)
request = page_request("site_tree", comment_account, comment_state, 100)
payload = success(request)
comment_pages.append(entry(request, payload))
comment_state = advance(comment_state, request, payload)
request = page_request("site_tree", comment_account, comment_state, 100)
payload = success(
    request,
    [{
        "created_at": "2026-08-02T12:20:00Z",
        "created_by": CREATOR,
        "discussion_id": DISCUSSION,
        "files": [],
        "id": COMMENT,
        "kind": "comment",
        "parent": {"type": "page_id", "page_id": ROOT},
        "text": "Open fixture comment",
    }],
)
comment_pages.append(entry(request, payload))
comment_state = advance(comment_state, request, payload)
assert comment_state.backfill_complete
write("comments.json", identity(comments=True), comment_pages)

# Validation and terminal fixtures must preserve the previous durable boundary.
bad_sha = dict(complete_page)
bad_sha["meta"] = dict(complete_page["meta"], request_sha256="0" * 64)
write("malformed.json", identity(), [entry(complete_request, bad_sha)])

escape = success(
    complete_request,
    [],
    [Task("page", BLOCK, 1, parent_kind="page_id", parent_id=ROOT)],
)
write("root-escape.json", identity(), [entry(complete_request, escape)])

credential = dict(complete_page, access_token="must-not-persist")
write("credential.json", identity(), [entry(complete_request, credential)])

limited = success(complete_request, limit_reason="blocks")
write("limit.json", identity(), [entry(complete_request, limited)])

write(
    "identity-mismatch.json",
    identity(workspace=BLOCK),
    [],
)

write("terminal-first.json", identity(), [entry(complete_request, complete_page)])
write(
    "terminal-second.json",
    identity(),
    [{
        "expect_request": {"task": complete_blocks_request.task.payload()},
        "response": {
            "status": 500,
            "observed_at": "2026-08-02T12:30:00Z",
            "response_bytes": 10,
        },
    }],
)

write(
    "identity-terminal.json",
    {
        "status": 429,
        "observed_at": "2026-08-02T12:31:00Z",
        "response_bytes": 0,
        "retry_after": 1785675000,
    },
    [],
)
PY

complete_result=$(run_notion "$TMP_DIR/complete.json" conn_notion_complete 5 100)
assert_eq "bounded Notion root tree completes" \
	"$(json_field "$complete_result" status)" complete
assert_eq "identity and two root-tree reads consume five request units" \
	"$(json_field "$complete_result" budget_units)" 5
assert_eq "authorized Notion text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'knowledge'")" 1
assert_eq "fixed API/export gaps remain explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_notion_complete' AND status='unavailable'")" 6
assert_eq "signed file targets never reach raw evidence" \
	"$(raw_contains 'signed-cover')" 0
complete_raw=$(raw_count)
run_notion "$TMP_DIR/complete.json" conn_notion_complete 5 100 >/dev/null
assert_eq "exact Notion replay is idempotent" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='notion-sites' AND remote_id IN ('notion_page_33333333333343338333333333333333','notion_block_44444444444444448444444444444444')")" 2
assert_eq "content-addressed replay does not duplicate Notion raw blobs" \
	"$(raw_count)" "$complete_raw"

resume_first=$(run_notion "$TMP_DIR/resume-first.json" conn_notion_resume 3 100)
assert_eq "request budget pauses at a durable queue head" \
	"$(json_field "$resume_first" status)" budget_exhausted
resume_second=$(run_notion "$TMP_DIR/resume-second.json" conn_notion_resume 3 100)
assert_eq "second invocation resumes the exact child-block task" \
	"$(json_field "$resume_second" status)" complete

structured_result=$(run_notion "$TMP_DIR/structured.json" conn_notion_structured 15 100)
assert_eq "database and opaque data-source pagination complete" \
	"$(json_field "$structured_result" status)" complete
assert_eq "both data-source rows become authorized page evidence" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='notion-sites' AND object_type='page' AND remote_id IN ('notion_page_33333333333343338333333333333333','notion_page_99999999999949998999999999999991','notion_page_99999999999949998999999999999992')")" 3
assert_eq "structured Notion row text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'Structured AND row'")" 2

comments_result=$(run_notion "$TMP_DIR/comments.json" conn_notion_comments 7 100)
assert_eq "capability-gated unresolved comments complete" \
	"$(json_field "$comments_result" status)" complete
assert_eq "unresolved comment becomes neutral object evidence" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='notion-sites' AND object_type='comment' AND remote_id='notion_comment_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa'")" 1

raw_before=$(raw_count)
expect_failure "wrong workspace identity is rejected" \
	"$TMP_DIR/identity-mismatch.json" conn_notion_identity_mismatch 3 100
expect_failure "root-escape discovery is rejected" \
	"$TMP_DIR/root-escape.json" conn_notion_escape 3 100
expect_failure "malformed request provenance is rejected" \
	"$TMP_DIR/malformed.json" conn_notion_malformed 3 100
expect_failure "credential-shaped page evidence is rejected" \
	"$TMP_DIR/credential.json" conn_notion_credential 3 100
expect_failure "provider traversal-limit response cannot advance" \
	"$TMP_DIR/limit.json" conn_notion_limit 3 100
assert_eq "all rejected Notion observations persist no raw evidence" \
	"$(raw_count)" "$raw_before"

run_notion "$TMP_DIR/terminal-first.json" conn_notion_terminal 3 100 >/dev/null
terminal_cursor_before=$(sql_value "SELECT cursor FROM sync_cursors WHERE connection_id='conn_notion_terminal' AND stream='site_tree'")
terminal_result=$(run_notion "$TMP_DIR/terminal-second.json" conn_notion_terminal 3 100)
assert_eq "terminal Notion task failure is sanitized" \
	"$(json_field "$terminal_result" failure_class)" provider
assert_eq "terminal Notion task failure preserves its prior checkpoint" \
	"$(sql_value "SELECT cursor FROM sync_cursors WHERE connection_id='conn_notion_terminal' AND stream='site_tree'")" \
	"$terminal_cursor_before"
assert_eq "terminal Notion task records failed stream coverage" \
	"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_notion_terminal' AND stream='site_tree'")" \
	"failed:provider"

identity_terminal=$(run_notion "$TMP_DIR/identity-terminal.json" conn_notion_identity_terminal 3 100)
assert_eq "terminal Notion identity response is sanitized" \
	"$(json_field "$identity_terminal" failure_class)" rate_limit
assert_eq "identity retry boundary remains observable" \
	"$(json_field "$identity_terminal" status)" rate_limited

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
from _knowledge_social_notion import STREAMS

root = Path(sys.argv[1])
workspace = "11111111-1111-4111-8111-111111111111"
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_notion_fence", "site_tree", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_notion_fence", "site_tree", "new_runner", "sync", 10),
    now_epoch=9001,
)
context = CollectionContext(
    root,
    "conn_notion_fence",
    {"id": workspace, "workspace_id": workspace},
    "site_tree",
    "none",
    ConnectionConfig(("site_tree",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["site_tree"],
    old,
    "notion-sites",
)
archive = {
    "provider": "notion-sites",
    "connection_id": "conn_notion_fence",
    "remote_account_id": workspace,
    "exported_at": "2026-08-02T12:40:00Z",
    "enabled_streams": ["site_tree"],
    "policy": {"media_hydration": "none"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
successful = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"site_tree"}',
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
    raise SystemExit("stale Notion collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    count = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_notion_fence'"
    ).fetchone()[0]
assert count == 0
release_run_lease(root, new)
PY
assert_eq "stale Notion lease cannot commit evidence or a cursor" verified verified

assert_eq "provider documentation classifies every route as Live, Export, Gate, or No" \
	"$(
		python3 - "$SCRIPT_DIR/../content/social-notion-sites.md" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = ("**Live", "**Export", "**Gate", "**No")
print("classified" if all(item in text for item in required) else "missing")
PY
	)" classified

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
