#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-hashnode.sh — Bounded Hashnode collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASHNODE_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_hashnode.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/hashnode-social-test.XXXXXX")
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
PASS=0
FAIL=0
ACCOUNT_ID="65b000000000000000000042"

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
	python3 - "$ROOT/sources/social/raw/hashnode" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_hashnode() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	local budget="$4"
	local page_size="$5"
	if python3 "$HASHNODE_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id "account_${ACCOUNT_ID}" \
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
	if run_hashnode "$fixture" "$connection_id" "$stream" 3 2 >/dev/null 2>&1; then
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

printf 'Hashnode social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_hashnode import PageRequest, STREAMS, page_checkpoint, page_request
from _knowledge_social_hashnode_contract import ApiResult
from _knowledge_social_hashnode_http import (
    GRAPHQL_URL,
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    _graphql_error_status,
    graphql_api,
)
from _knowledge_social_hashnode_identity import INSTANCE_ID, account_id, namespaced_id
from _knowledge_social_hashnode_routes import (
    ALLOWED_QUERIES,
    COMMENTS_QUERY,
    IDENTITY_QUERY,
    PUBLICATIONS_QUERY,
    _encode_route_state,
    page,
)

UID = "65b000000000000000000000042"
OTHER = "65b000000000000000000000043"
PUBLICATION = "65c000000000000000000042"
POST = "65d000000000000000000042"
COMMENT = "65e000000000000000000042"

assert set(STREAMS) == {
    "profile", "publications", "posts", "drafts", "comments", "reactions",
    "followers", "following",
}
assert all(spec.cost_units == 2 and spec.transport == "graphql" for spec in STREAMS.values())
assert len(ALLOWED_QUERIES) == 9
for query in ALLOWED_QUERIES:
    normalized = " ".join(query.split()).casefold()
    assert normalized.startswith("query aidevopshashnode")
    assert "mutation" not in normalized and "subscription" not in normalized


class Headers:
    def __init__(self, values=None):
        self.values = values or {}

    def get(self, key, default=None):
        return self.values.get(key, default)


class Response:
    status = 200

    def __init__(self, payload, headers=None):
        self.payload = json.dumps(payload).encode()
        self.headers = Headers(headers)

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
        assert "private-pat" not in request.full_url
        assert "private-pat" not in (request.data or b"").decode()
        self.requests.append(request)
        return self.responses.pop(0)


identity_payload = {"data": {"me": {
    "id": UID, "username": "selected", "name": "Selected", "bio": None,
    "tagline": None, "location": None, "dateJoined": "2024-01-01T00:00:00Z",
}}}
config = ProfileConfig("private-pat")
opener = Opener([Response(identity_payload)])
result = graphql_api(config, opener, IDENTITY_QUERY, {})
assert result.status == 200
assert opener.requests[0].method == "POST"
assert opener.requests[0].full_url == GRAPHQL_URL
assert opener.requests[0].get_header("Authorization") == "Bearer private-pat"

for unsafe in (
    "mutation Unsafe { publishPost(input: {}) { post { id } } }",
    IDENTITY_QUERY + " ",
):
    try:
        graphql_api(config, Opener([]), unsafe, {})
    except RuntimeError:
        pass
    else:
        raise AssertionError("unallowlisted Hashnode GraphQL document was accepted")

partial = {
    "data": {"me": {"id": UID}},
    "errors": [{"message": "redacted", "extensions": {"code": "FORBIDDEN"}}],
}
partial_result = graphql_api(config, Opener([Response(partial)]), IDENTITY_QUERY, {})
assert partial_result.status == 403 and partial_result.payload == {}
assert _graphql_error_status({"errors": [{"extensions": {"code": "NOT_FOUND"}}]}) == 404

try:
    graphql_api(
        config,
        Opener([Response({"data": {"me": identity_payload["data"]["me"]},
                          "access_token": "must-not-persist"})]),
        IDENTITY_QUERY,
        {},
    )
except RuntimeError:
    pass
else:
    raise AssertionError("credential-shaped Hashnode response was accepted")

request = PageRequest(
    "publications", account_id(UID), UID, "selected", INSTANCE_ID, 1, None, 2,
)


def publication_payload(author_id=UID, author_name="selected", end="pub-cursor-1", has_next=True):
    return {"data": {"me": {
        "id": UID,
        "username": "selected",
        "publications": {
            "edges": [{
                "cursor": end,
                "node": {
                    "id": PUBLICATION,
                    "title": "Owned publication",
                    "url": "https://selected.hashnode.dev",
                    "isTeam": False,
                    "followersCount": 3,
                    "about": {"text": "About"},
                    "author": {"id": author_id, "username": author_name, "name": "Selected"},
                },
            }],
            "pageInfo": {"endCursor": end, "hasNextPage": has_next},
        },
    }}}


first = page(lambda *_args: ApiResult(200, publication_payload()), request)
assert first["meta"]["complete"] is False
checkpoint, complete = page_checkpoint(first, CursorState(None, None, False), request)
assert not complete and checkpoint.next_cursor
resumed = page_request(
    "publications",
    {"id": account_id(UID), "provider_account_id": UID,
     "username": "selected", "instance_id": INSTANCE_ID},
    CursorState(checkpoint.next_cursor, None, False),
    2,
)
assert resumed.position == 2 and resumed.stop_at
try:
    page(lambda *_args: ApiResult(200, publication_payload()), resumed)
except RuntimeError:
    pass
else:
    raise AssertionError("Hashnode cursor loop was accepted")

try:
    page(
        lambda *_args: ApiResult(200, publication_payload(OTHER, "other", has_next=False)),
        request,
    )
except RuntimeError:
    pass
else:
    raise AssertionError("Hashnode publication ownership mismatch was accepted")

malformed = publication_payload(has_next=False)
malformed["data"]["me"]["publications"]["edges"][0]["node"].pop("title")
try:
    page(lambda *_args: ApiResult(200, malformed), request)
except RuntimeError:
    pass
else:
    raise AssertionError("malformed Hashnode publication was accepted")

comment_request = PageRequest(
    "comments", account_id(UID), UID, "selected", INSTANCE_ID, 1, None, 2,
)


def comments_payload(comment_end="comment-cursor-1", comments_next=True, posts_next=True):
    return {"data": {"user": {
        "id": UID,
        "username": "selected",
        "posts": {
            "edges": [{
                "cursor": "post-cursor-1",
                "node": {
                    "id": POST,
                    "title": "Bounded post",
                    "author": {"id": UID, "username": "selected"},
                    "publication": {
                        "id": PUBLICATION,
                        "title": "Owned publication",
                        "author": {"id": UID, "username": "selected"},
                    },
                    "comments": {
                        "edges": [{
                            "cursor": comment_end,
                            "node": {
                                "id": COMMENT,
                                "dateAdded": "2026-08-02T10:00:00Z",
                                "totalReactions": 1,
                                "content": {"text": "Useful response"},
                                "author": {"id": OTHER, "username": "reader", "name": "Reader"},
                            },
                        }],
                        "pageInfo": {"endCursor": comment_end, "hasNextPage": comments_next},
                    },
                },
            }],
            "pageInfo": {"endCursor": "post-cursor-1", "hasNextPage": posts_next},
        },
    }}}


comments_first = page(lambda *_args: ApiResult(200, comments_payload()), comment_request)
comments_checkpoint, comments_complete = page_checkpoint(
    comments_first, CursorState(None, None, False), comment_request
)
assert not comments_complete and comments_first["data"][0]["kind"] == "comment"
comments_resumed = page_request(
    "comments",
    {"id": account_id(UID), "provider_account_id": UID,
     "username": "selected", "instance_id": INSTANCE_ID},
    CursorState(comments_checkpoint.next_cursor, None, False),
    2,
)
comments_second = page(
    lambda *_args: ApiResult(200, comments_payload("comment-cursor-2", False, True)),
    comments_resumed,
)
assert comments_second["meta"]["complete"] is False
assert comments_second["meta"]["next_cursor"] == _encode_route_state({
    "outer_after": "post-cursor-1", "inner_after": None, "outer_id": None,
})

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_hashnode*.py"))
]
trees = [ast.parse(source) for source in sources]
request_calls = [
    node for tree in trees for node in ast.walk(tree)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
    and node.func.id == "Request"
]
assert len(request_calls) == 1
methods = {
    keyword.value.value for node in request_calls for keyword in node.keywords
    if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
}
assert methods == {"POST"}
assert COMMENTS_QUERY in ALLOWED_QUERIES and PUBLICATIONS_QUERY in ALLOWED_QUERIES
PY
assert_eq "identity, ownership, fixed-query, nested cursor, and mutation boundaries are guarded" \
	verified verified

python3 - "$TMP_DIR/complete.json" "$ACCOUNT_ID" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_hashnode_identity import INSTANCE_ID, account_id, namespaced_id

uid = sys.argv[2]
publication = "65c000000000000000000042"
post = "65d000000000000000000042"
author = {
    "provider_account_id": uid,
    "remote_id": namespaced_id("account", uid),
    "username": "selected",
    "name": "Selected",
    "tagline": None,
}
payload = {
    "identity": {"data": {
        "id": account_id(uid),
        "provider_account_id": uid,
        "username": "selected",
        "name": "Selected",
        "bio": "Account bio",
        "instance_id": INSTANCE_ID,
    }},
    "pages": [{
        "expect_request": {"position": 1, "stop_at": None, "limit": 2},
        "response": {
            "status": 200,
            "observed_at": "2026-08-02T10:00:00Z",
            "data": [{
                "kind": "post",
                "remote_id": namespaced_id("post", post),
                "post_id": post,
                "title": "Bounded Hashnode knowledge",
                "subtitle": None,
                "slug": "bounded-hashnode-knowledge",
                "url": "https://selected.hashnode.dev/bounded-hashnode-knowledge",
                "brief": "Bounded fixture",
                "markdown": "# Bounded Hashnode knowledge",
                "text": "Bounded Hashnode knowledge",
                "published_at": "2026-08-02T09:00:00Z",
                "updated_at": None,
                "reaction_count": 2,
                "response_count": 1,
                "reply_count": 0,
                "author": author,
                "publication": {
                    "remote_id": namespaced_id("publication", publication),
                    "publication_id": publication,
                    "title": "Owned publication",
                    "url": "https://selected.hashnode.dev",
                },
                "tags": [],
            }],
            "meta": {
                "stream": "posts",
                "instance_id": INSTANCE_ID,
                "transport": "graphql",
                "next_cursor": None,
                "complete": True,
                "snapshot": True,
            },
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
result=$(run_hashnode "$TMP_DIR/complete.json" conn_hashnode posts 3 2)
assert_eq "bounded Hashnode fixture completes" "$(json_field "$result" status)" complete
assert_eq "viewer verification plus one page consume three query units" \
	"$(json_field "$result" budget_units)" 3
assert_eq "Hashnode post text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1
assert_eq "completed Hashnode snapshot records its checkpoint" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_hashnode'")" \
	"done:1"
raw_complete=$(raw_count)
run_hashnode "$TMP_DIR/complete.json" conn_hashnode posts 3 2 >/dev/null
assert_eq "exact Hashnode replay keeps one normalized post" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='hashnode' AND object_type='post'")" 1
assert_eq "exact Hashnode replay reuses immutable raw evidence" "$(raw_count)" "$raw_complete"

python3 - "$TMP_DIR/mismatch.json" <<'PY'
import json
import sys

payload = {"identity": {"data": {
    "id": "wrong",
    "provider_account_id": "65b000000000000000000000043",
    "username": "other",
    "instance_id": "hashnode-gql-beta",
}}, "pages": []}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "selected-account identity mismatch is rejected" \
	"$TMP_DIR/mismatch.json" conn_mismatch posts
assert_eq "identity mismatch persists no raw evidence" "$(raw_count)" "$raw_before"

python3 - "$TMP_DIR/credential.json" "$ACCOUNT_ID" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_hashnode_identity import INSTANCE_ID, account_id

uid = sys.argv[2]
payload = {
    "identity": {"data": {
        "id": account_id(uid), "provider_account_id": uid,
        "username": "selected", "instance_id": INSTANCE_ID,
    }},
    "pages": [{
        "status": 200,
        "observed_at": "2026-08-02T10:01:00Z",
        "access_token": "must-not-persist",
        "data": [],
        "meta": {
            "stream": "posts", "instance_id": INSTANCE_ID,
            "transport": "graphql", "next_cursor": None,
            "complete": True, "snapshot": True,
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "credential-shaped Hashnode page is rejected" \
	"$TMP_DIR/credential.json" conn_credential posts
assert_eq "credential rejection persists no raw evidence" "$(raw_count)" "$raw_before"

python3 - "$TMP_DIR/paused.json" "$TMP_DIR/terminal.json" "$ACCOUNT_ID" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_hashnode_identity import INSTANCE_ID, account_id
from _knowledge_social_hashnode_routes import _encode_route_state

uid = sys.argv[3]
identity = {"data": {
    "id": account_id(uid), "provider_account_id": uid,
    "username": "selected", "instance_id": INSTANCE_ID,
}}
paused = {
    "identity": identity,
    "pages": [{
        "status": 200,
        "observed_at": "2026-08-02T10:02:00Z",
        "data": [],
        "meta": {
            "stream": "posts", "instance_id": INSTANCE_ID,
            "transport": "graphql",
            "next_cursor": _encode_route_state({"after": "post-cursor-next"}),
            "complete": False, "snapshot": True,
        },
    }],
}
terminal = {
    "identity": identity,
    "pages": [{
        "expect_request": {"position": 2},
        "response": {"status": 503, "observed_at": "2026-08-02T10:03:00Z"},
    }],
}
for path, payload in ((sys.argv[1], paused), (sys.argv[2], terminal)):
    with open(path, "w", encoding="utf-8") as target:
        json.dump(payload, target)
PY
paused_result=$(run_hashnode "$TMP_DIR/paused.json" conn_terminal posts 3 2)
assert_eq "bounded query budget checkpoints an incomplete page" \
	"$(json_field "$paused_result" status)" budget_exhausted
terminal_cursor_before=$(sql_value "SELECT cursor FROM sync_cursors WHERE connection_id='conn_terminal'")
terminal_raw_before=$(raw_count)
terminal_result=$(run_hashnode "$TMP_DIR/terminal.json" conn_terminal posts 3 2)
assert_eq "terminal Hashnode response is classified" \
	"$(json_field "$terminal_result" status)" failed
assert_eq "terminal response preserves the prior checkpoint" \
	"$(sql_value "SELECT cursor FROM sync_cursors WHERE connection_id='conn_terminal'")" \
	"$terminal_cursor_before"
assert_eq "terminal response appends diagnostics without replacing prior evidence" \
	"$(raw_count)" "$((terminal_raw_before + 1))"

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
from _knowledge_social_hashnode import STREAMS
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    release_run_lease,
)

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_hashnode_fence", "posts", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_hashnode_fence", "posts", "new_runner", "sync", 10),
    now_epoch=9001,
)
context = CollectionContext(
    root,
    "conn_hashnode_fence",
    {"id": "hnu_selected", "username": "selected"},
    "posts",
    "none",
    ConnectionConfig(("posts",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["posts"],
    old,
    "hashnode",
)
archive = {
    "provider": "hashnode",
    "connection_id": "conn_hashnode_fence",
    "remote_account_id": "hnu_selected",
    "exported_at": "2026-08-02T10:04:00Z",
    "enabled_streams": ["posts"],
    "policy": {"media_hydration": "none"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
page_data = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"posts"}',
    archive,
    PageCheckpoint(None, None),
    True,
    2,
)
os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "9001"
try:
    persist_page(context, page_data)
except SocialLeaseLostError:
    pass
else:
    raise SystemExit("stale Hashnode collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    cursor = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_hashnode_fence'"
    ).fetchone()[0]
assert cursor == 0
release_run_lease(root, new)
PY
assert_eq "stale Hashnode lease cannot commit evidence or a cursor" verified verified

assert_eq "unsupported Hashnode private categories remain explicit gaps" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_hashnode' AND status IN ('partial','unavailable') AND stream IN ('authored_comments_elsewhere','reaction_history','comment_replies','messages','notifications','account_export')")" 6

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
