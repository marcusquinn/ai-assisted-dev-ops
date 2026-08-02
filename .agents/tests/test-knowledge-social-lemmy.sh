#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-lemmy.sh — Version-gated Lemmy collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEMMY_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_lemmy.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/lemmy-social-test.XXXXXX")
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
INSTANCE_V4="aaaaaaaaaaaaaaaaaaaaaaaa"
INSTANCE_V3="bbbbbbbbbbbbbbbbbbbbbbbb"
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
	python3 - "$ROOT/sources/social/raw/lemmy" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_lemmy() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	local budget="$4"
	local page_size="$5"
	if python3 "$LEMMY_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id person_42 \
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
	if run_lemmy "$fixture" "$connection_id" "$stream" 5 1 >/dev/null 2>&1; then
		assert_eq "$description" accepted rejected
	else
		assert_eq "$description" rejected rejected
	fi
	return 0
}

make_empty_fixture() {
	local path="$1"
	local installation="$2"
	local family="$3"
	local version="$4"
	local stream="$5"
	python3 - "$path" "$installation" "$family" "$version" "$stream" <<'PY'
import json
import sys

path, installation, family, version, stream = sys.argv[1:]
payload = {
    "identity": {"data": {
        "provider_account_id": "42",
        "username": "selected",
        "display_name": "Selected Lemmy user",
        "ap_id": "https://lemmy.example.invalid/u/selected",
        "instance_id": installation,
        "api_family": family,
        "exact_version": version,
    }},
    "pages": [{
        "expect_request": {
            "stream": stream,
            "api_family": family,
            "exact_version": version,
            "position": 1,
            "page_cursor": None,
        },
        "response": {
            "status": 200,
            "observed_at": "2026-08-02T08:00:00Z",
            "data": [],
            "meta": {
                "stream": stream,
                "instance_id": installation,
                "api_family": family,
                "exact_version": version,
                "next": None,
                "complete": True,
                "watermark": None,
                "snapshot": True,
            },
        },
    }],
}
with open(path, "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Lemmy social collector tests\n'

help_output=$("$SOCIAL_HELPER" help)
if [[ "$help_output" == *"sync-lemmy discovers the exact server version"* &&
	"$help_output" == *"--page-size is 1-50"* ]]; then
	assert_eq "Lemmy CLI advertises its version and page safety contract" advertised advertised
else
	assert_eq "Lemmy CLI advertises its version and page safety contract" missing advertised
fi
matrix_output=$(<"$SCRIPT_DIR/../aidevops/knowledge-plane/06-social-provider-capabilities.md")
docs_output=$(<"$SCRIPT_DIR/../content/social-lemmy.md")
if [[ "$matrix_output" == *'| Lemmy | **Live/Partial** versioned posts and comments'* &&
	"$docs_output" == *'LEMMY_<PROFILE>_AUTH_MODE=user_token'* &&
	"$docs_output" == *'GET /api/v4/person/content?type_=posts'* ]]; then
	assert_eq "Live Lemmy claim is backed by operator and route evidence" verified verified
else
	assert_eq "Live Lemmy claim is backed by operator and route evidence" missing verified
fi

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import os
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_lemmy import (
    MAX_PAGE_ITEMS,
    STREAMS,
    V3_CURSOR_PREFIX,
    V3_STREAMS,
    V4_CURSOR_PREFIX,
    V4_STREAMS,
    PageRequest,
    page_checkpoint,
    page_request,
)
from _knowledge_social_lemmy_contract import ApiResult, identity_value
from _knowledge_social_lemmy_http import (
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    _RejectRedirect,
    _canonical_base_url,
    api,
    installation_fingerprint,
)
from _knowledge_social_lemmy_identity import api_family, namespaced_id
from _knowledge_social_lemmy_provider import _dispatch, _profile
from _knowledge_social_lemmy_reader import GuardedLemmy, verified_identity
from _knowledge_social_lemmy_v3 import page as page_v3
from _knowledge_social_lemmy_v3 import route as route_v3
from _knowledge_social_lemmy_v4 import page as page_v4
from _knowledge_social_lemmy_v4 import route as route_v4

expected = {
    "authored_posts", "authored_comments", "saved_posts", "saved_comments",
    "liked_posts", "liked_comments", "notifications", "replies", "mentions",
    "subscriptions", "multicommunities",
}
assert set(STREAMS) == expected
assert V4_STREAMS == expected - {"replies", "mentions"}
assert V3_STREAMS == expected - {"notifications", "multicommunities"}
snapshot_streams = {
    "saved_posts", "saved_comments", "liked_posts", "liked_comments",
    "subscriptions", "multicommunities",
}
assert all(not STREAMS[stream].incremental for stream in snapshot_streams)
assert all(
    STREAMS[stream].incremental for stream in expected - snapshot_streams
)
assert MAX_PAGE_ITEMS == 50

v4_site = {
    "version": "1.0.0-beta.1",
    "my_user": {"local_user_view": {"person": {
        "id": 42,
        "name": "selected",
        "display_name": "Selected",
        "ap_id": "https://lemmy.example.invalid/u/selected",
        "local": True,
    }}},
}
v3_site = {
    "version": "0.19.20",
    "my_user": {"local_user_view": {"person": {
        "id": 42,
        "name": "selected",
        "display_name": "Selected",
        "actor_id": "https://lemmy.example.invalid/u/selected",
        "local": True,
    }}},
}
v4_identity = identity_value(v4_site, "42", "a" * 24)
v3_identity = identity_value(v3_site, "42", "b" * 24)
assert v4_identity["api_family"] == "v4" and v3_identity["api_family"] == "v3"
assert v4_identity["ap_id"] == v3_identity["ap_id"]
v4_account = verified_identity({"data": v4_identity}, "person_42")
v3_account = verified_identity({"data": v3_identity}, "person_42")
assert v4_account["id"] != v3_account["id"]
assert namespaced_id("a" * 24, "post", 7) != namespaced_id("b" * 24, "post", 7)

for rejected_version in ("", "0.18.5", "2.0.0", "main", "1"):
    try:
        api_family(rejected_version)
    except RuntimeError:
        pass
    else:
        raise AssertionError("unsupported Lemmy version was accepted")

v4_request = page_request(
    "authored_posts", v4_account, CursorState(None, None, False), 2
)
v4_path, v4_params = route_v4(v4_request)
assert v4_path == "/api/v4/person/content"
assert v4_params == {"person_id": "42", "type_": "posts", "limit": "2"}
v4_payload = {
    "status": 200,
    "observed_at": "2026-08-02T08:01:00Z",
    "data": [],
    "meta": {
        "stream": "authored_posts",
        "instance_id": "a" * 24,
        "api_family": "v4",
        "exact_version": "1.0.0-beta.1",
        "next": "opaque+/cursor==",
        "complete": False,
        "watermark": "2026-08-02T08:00:00Z",
        "snapshot": True,
    },
}
v4_checkpoint, v4_complete = page_checkpoint(
    v4_payload, CursorState(None, None, False), v4_request
)
assert not v4_complete and v4_checkpoint.next_cursor.startswith(V4_CURSOR_PREFIX)
v4_resumed = page_request(
    "authored_posts",
    v4_account,
    CursorState(v4_checkpoint.next_cursor, v4_checkpoint.watermark, False),
    2,
)
assert v4_resumed.position == 2 and v4_resumed.page_cursor == "opaque+/cursor=="

v3_request = page_request(
    "saved_posts", v3_account, CursorState(None, None, False), 2
)
v3_payload = {
    "status": 200,
    "observed_at": "2026-08-02T08:02:00Z",
    "data": [],
    "meta": {
        "stream": "saved_posts",
        "instance_id": "b" * 24,
        "api_family": "v3",
        "exact_version": "0.19.20",
        "next": 2,
        "complete": False,
        "watermark": "2026-08-02T08:00:00Z",
        "snapshot": True,
    },
}
v3_checkpoint, v3_complete = page_checkpoint(
    v3_payload, CursorState(None, None, False), v3_request
)
assert not v3_complete and v3_checkpoint.next_cursor.startswith(V3_CURSOR_PREFIX)
v3_resumed = page_request(
    "saved_posts",
    v3_account,
    CursorState(v3_checkpoint.next_cursor, v3_checkpoint.watermark, False),
    2,
)
v3_path, v3_params, v3_envelope = route_v3(v3_resumed)
assert v3_path == "/api/v3/post/list" and v3_envelope == "posts"
assert v3_params["page"] == "2" and "page_cursor" not in v3_params

for wrong_route, request in ((route_v3, v4_request), (route_v4, v3_request)):
    try:
        wrong_route(request)
    except RuntimeError:
        pass
    else:
        raise AssertionError("Lemmy API-family route crossover was accepted")
for account, stream, cursor in (
    (v3_account, "saved_posts", v4_checkpoint.next_cursor),
    (v4_account, "authored_posts", v3_checkpoint.next_cursor),
):
    try:
        page_request(stream, account, CursorState(cursor, None, False), 2)
    except RuntimeError:
        pass
    else:
        raise AssertionError("Lemmy API-family cursor crossover was accepted")

post_ap_id = "https://lemmy.example.invalid/post/7"
post_view = {
    "type_": "post",
    "post": {
        "id": 7,
        "name": "Bounded Lemmy post",
        "body": "Lemmy knowledge",
        "published_at": "2026-08-02T08:00:00Z",
        "ap_id": post_ap_id,
        "deleted": False,
        "removed": False,
    },
    "creator": {
        "id": 42,
        "ap_id": "https://lemmy.example.invalid/u/selected",
    },
    "community": {
        "id": 9,
        "ap_id": "https://lemmy.example.invalid/c/research",
    },
}
serialized = page_v4(
    lambda _path, _params: ApiResult(
        200, {"items": [post_view], "next_page": None}
    ),
    PageRequest(
        "authored_posts",
        v4_account["id"],
        "42",
        "selected",
        v4_account["ap_id"],
        "a" * 24,
        "v4",
        "1.0.0-beta.1",
        1,
        None,
        None,
        None,
        1,
    ),
    v4_account,
)
assert serialized["data"][0]["remote_id"] == namespaced_id("a" * 24, "post", 7)
assert serialized["data"][0]["ap_id"] == post_ap_id
assert serialized["data"][0]["author_ap_id"] == v4_account["ap_id"]
empty_advancing = page_v4(
    lambda _path, _params: ApiResult(
        200, {"items": [], "next_page": "empty-page-next"}
    ),
    v4_request,
    v4_account,
)
assert not empty_advancing["meta"]["complete"]
assert empty_advancing["meta"]["next"] == "empty-page-next"
stuck_request = PageRequest(
    "authored_posts",
    v4_account["id"],
    "42",
    "selected",
    v4_account["ap_id"],
    "a" * 24,
    "v4",
    "1.0.0-beta.1",
    2,
    "stuck-cursor",
    None,
    None,
    1,
)
try:
    page_v4(
        lambda _path, _params: ApiResult(
            200, {"items": [post_view], "next_page": "stuck-cursor"}
        ),
        stuck_request,
        v4_account,
    )
except RuntimeError:
    pass
else:
    raise AssertionError("non-advancing Lemmy v4 cursor was accepted")

private_body = "must-remain-outside-normalized-evidence"
notification_view = {
    "notification": {
        "id": 11,
        "recipient_id": 42,
        "creator_id": 7,
        "private_message_id": 55,
        "kind": "private_message",
        "published_at": "2026-08-02T08:00:00Z",
        "read": False,
    },
    "data": {
        "type_": "private_message",
        "private_message": {"id": 55, "content": private_body},
        "creator": {
            "id": 7,
            "ap_id": "https://remote.example.invalid/u/sender",
        },
        "recipient": {
            "id": 42,
            "ap_id": "https://lemmy.example.invalid/u/selected",
        },
    },
}
notification_page = page_v4(
    lambda _path, _params: ApiResult(
        200, {"items": [notification_view], "next_page": None}
    ),
    PageRequest(
        "notifications",
        v4_account["id"],
        "42",
        "selected",
        v4_account["ap_id"],
        "a" * 24,
        "v4",
        "1.0.0-beta.1",
        1,
        None,
        None,
        None,
        1,
    ),
    v4_account,
)
notification = notification_page["data"][0]
assert notification["actor_ap_id"] == "https://remote.example.invalid/u/sender"
assert private_body not in json.dumps(notification, sort_keys=True)


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
    def __init__(self, payloads):
        self.payloads = list(payloads)
        self.requests = []

    def open(self, request, timeout):
        assert timeout == HTTP_TIMEOUT_SECONDS and request.method == "GET"
        assert request.get_header("Authorization") == "Bearer private-token"
        assert "private-token" not in request.full_url
        self.requests.append(request)
        return Response(self.payloads.pop(0))


base = _canonical_base_url("https://lemmy.example.invalid/")
instance = installation_fingerprint(base, "o" * 32)
config = ProfileConfig(base, "private-token", "user_token", instance)
stream_contracts = json.loads(
    (
        scripts.parent
        / "tests"
        / "fixtures"
        / "knowledge-social-lemmy"
        / "stream-contracts.json"
    ).read_text(encoding="utf-8")
)
for family, supported in (("v4", V4_STREAMS), ("v3", V3_STREAMS)):
    contract = stream_contracts[family]
    assert set(contract["streams"]) == supported
    account = verified_identity(
        {"data": identity_value(contract["identity"], "42", instance)}, "42"
    )
    for stream, case in contract["streams"].items():
        source = contract["records"][case["record"]]
        response = (
            {"items": [source], "next_page": None}
            if family == "v4"
            else {case["envelope"]: [source]}
        )
        fixture_opener = Opener([contract["identity"], response])
        fixture_request = page_request(
            stream, account, CursorState(None, None, False), 1
        )
        fixture_result = _dispatch(
            fixture_request.payload(), config, fixture_opener
        )
        assert fixture_result["status"] == 200
        assert [item["kind"] for item in fixture_result["data"]] == [case["kind"]]
        identity_url, page_url = [
            urlsplit(item.full_url) for item in fixture_opener.requests
        ]
        assert identity_url.path == "/api/v3/site" and not identity_url.query
        assert page_url.path == case["path"]
        assert parse_qs(page_url.query) == {
            key: [value] for key, value in case["params"].items()
        }
dispatch_account = verified_identity(
    {"data": identity_value(v4_site, "42", instance)}, "42"
)
dispatch_request = page_request(
    "subscriptions", dispatch_account, CursorState(None, None, False), 1
)
opener = Opener([v4_site, {"items": [], "next_page": None}])
dispatch_result = _dispatch(dispatch_request.payload(), config, opener)
assert dispatch_result["status"] == 200
assert [urlsplit(item.full_url).path for item in opener.requests] == [
    "/api/v3/site", "/api/v4/community/list",
]

mismatch_site = json.loads(json.dumps(v4_site))
mismatch_site["my_user"]["local_user_view"]["person"]["id"] = 43
mismatch = Opener([mismatch_site, {"items": [], "next_page": None}])
try:
    _dispatch(dispatch_request.payload(), config, mismatch)
except RuntimeError:
    pass
else:
    raise AssertionError("Lemmy page ran without authenticated identity rebinding")
assert len(mismatch.requests) == 1

try:
    api(config, Opener([]), "/api/v4/post", {})
except RuntimeError:
    pass
else:
    raise AssertionError("Lemmy mutation route was accepted")
assert _RejectRedirect().redirect_request() is None

os.environ.update({
    "LEMMY_FIXTURE_BASE_URL": base,
    "LEMMY_FIXTURE_ACCESS_TOKEN": "private-token",
    "LEMMY_FIXTURE_ORIGIN_KEY": "o" * 32,
    "LEMMY_FIXTURE_AUTH_MODE": "user_token",
    "UNRELATED_PROVIDER_TOKEN": "must-not-cross-boundary",
})
reader = GuardedLemmy(scripts / "_knowledge_social_lemmy_provider.py", "fixture")
environment = reader._environment()
assert set(key for key in environment if key.startswith("LEMMY_")) == {
    "LEMMY_FIXTURE_BASE_URL",
    "LEMMY_FIXTURE_ACCESS_TOKEN",
    "LEMMY_FIXTURE_ORIGIN_KEY",
    "LEMMY_FIXTURE_AUTH_MODE",
}
assert "UNRELATED_PROVIDER_TOKEN" not in environment
os.environ["LEMMY_SCOPE_BASE_URL"] = base
os.environ["LEMMY_SCOPE_ACCESS_TOKEN"] = "private-token"
os.environ["LEMMY_SCOPE_ORIGIN_KEY"] = "o" * 32
os.environ["LEMMY_SCOPE_AUTH_MODE"] = "service_token"
try:
    _profile("scope")
except RuntimeError:
    pass
else:
    raise AssertionError("non-user Lemmy token was accepted")


def overlap_post(family, timestamp, post_id):
    person_key = "ap_id" if family == "v4" else "actor_id"
    published_key = "published_at" if family == "v4" else "published"
    view = {
        "post": {
            "id": post_id,
            "name": f"Overlap post {post_id}",
            published_key: timestamp,
            "ap_id": f"https://lemmy.example.invalid/post/{post_id}",
        },
        "creator": {
            "id": 42,
            person_key: "https://lemmy.example.invalid/u/selected",
        },
        "community": {
            "id": 9,
            person_key: "https://lemmy.example.invalid/c/research",
        },
    }
    if family == "v4":
        view["type_"] = "post"
    return view


def collect_overlap_pages(family, account, initial_state, pages):
    state = initial_state
    requests = []
    for page_index, (timestamps, next_page) in enumerate(pages, start=1):
        request = page_request("authored_posts", account, state, 2)
        items = [
            overlap_post(family, timestamp, page_index * 10 + item_index)
            for item_index, timestamp in enumerate(timestamps, start=1)
        ]
        raw = (
            {"items": items, "next_page": next_page}
            if family == "v4"
            else {"posts": items}
        )
        page_fn = page_v4 if family == "v4" else page_v3
        payload = page_fn(
            lambda _path, _params, response=raw: ApiResult(200, response),
            request,
            account,
        )
        checkpoint, complete = page_checkpoint(payload, state, request)
        requests.append(request)
        state = CursorState(checkpoint.next_cursor, checkpoint.watermark, complete)
        if complete:
            break
    return requests, state


initial_pages = [
    (["2026-08-02T09:00:00Z", "2026-08-02T08:59:00Z"], "v4-page-2"),
    (["2026-08-02T08:58:00Z", "2026-08-02T08:57:00Z"], "v4-page-3"),
    (["2026-08-02T08:56:00Z"], None),
]
incremental_pages = [
    (["2026-08-02T09:00:00Z", "2026-08-02T08:30:00Z"], "v4-page-2"),
    (["2026-08-02T08:20:00Z", "2026-08-02T08:10:00Z"], "v4-page-3"),
    (["2026-08-02T07:59:58Z", "2026-08-02T07:59:57Z"], "v4-page-4"),
]
overlap_cutoff = "2026-08-02T08:00:00Z"
for family, account in (("v4", v4_account), ("v3", v3_account)):
    initial_requests, initial_state = collect_overlap_pages(
        family, account, CursorState(None, None, False), initial_pages
    )
    assert len(initial_requests) == 3 and initial_state.backfill_complete
    assert all(request.overlap_cutoff is None for request in initial_requests)
    assert initial_requests[1].watermark == "2026-08-02T09:00:00Z"

    incremental_requests, incremental_state = collect_overlap_pages(
        family,
        account,
        CursorState(None, overlap_cutoff, True),
        incremental_pages,
    )
    assert len(incremental_requests) == 3 and incremental_state.backfill_complete
    assert all(
        request.overlap_cutoff == overlap_cutoff
        for request in incremental_requests
    )
    assert incremental_requests[1].watermark == "2026-08-02T09:00:00Z"

    snapshot_request = page_request(
        "saved_posts", account, CursorState(None, overlap_cutoff, True), 1
    )
    assert snapshot_request.overlap_cutoff is None
    snapshot_source = overlap_post(
        family, "2020-01-01T00:00:00Z", 99
    )
    snapshot_raw = (
        {"items": [snapshot_source], "next_page": "saved-page-2"}
        if family == "v4"
        else {"posts": [snapshot_source]}
    )
    page_fn = page_v4 if family == "v4" else page_v3
    snapshot_page = page_fn(
        lambda _path, _params: ApiResult(200, snapshot_raw),
        snapshot_request,
        account,
    )
    assert not snapshot_page["meta"]["complete"]
    assert snapshot_page["meta"]["watermark"] == overlap_cutoff

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_lemmy*.py"))
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
assert all("_knowledge_social_outbound" not in source for source in sources)
PY
assert_eq "version discovery, isolated routes/cursors, identity rebinding, IDs, and GET-only transport are guarded" \
	verified verified
assert_eq "non-empty upstream fixtures exercise every v3/v4 stream through the provider dispatcher" \
	verified verified
assert_eq "initial v3/v4 backfills paginate to provider exhaustion" verified verified
assert_eq "incremental v3/v4 overlap uses the frozen pre-run watermark" verified verified
assert_eq "mutable saved and liked state rescans to provider exhaustion" verified verified

v4_streams=(
	authored_posts authored_comments saved_posts saved_comments liked_posts
	liked_comments notifications subscriptions multicommunities
)
for stream in "${v4_streams[@]}"; do
	fixture="${TMP_DIR}/v4-${stream}.json"
	make_empty_fixture "$fixture" "$INSTANCE_V4" v4 1.0.0-beta.1 "$stream"
	result=$(run_lemmy "$fixture" conn_v4 "$stream" 3 1)
	[[ "$(json_field "$result" status)" == complete ]]
done
assert_eq "every fixture-proven v4 stream owns an independent checkpoint" \
	"$(sql_value "SELECT group_concat(stream, ',') FROM (SELECT stream FROM sync_cursors WHERE connection_id='conn_v4' ORDER BY stream)")" \
	"authored_comments,authored_posts,liked_comments,liked_posts,multicommunities,notifications,saved_comments,saved_posts,subscriptions"

v3_streams=(
	authored_posts authored_comments saved_posts saved_comments liked_posts
	liked_comments replies mentions subscriptions
)
for stream in "${v3_streams[@]}"; do
	fixture="${TMP_DIR}/v3-${stream}.json"
	make_empty_fixture "$fixture" "$INSTANCE_V3" v3 0.19.20 "$stream"
	result=$(run_lemmy "$fixture" conn_v3 "$stream" 3 1)
	[[ "$(json_field "$result" status)" == complete ]]
done
assert_eq "every fixture-proven v3 stream owns an independent checkpoint" \
	"$(sql_value "SELECT group_concat(stream, ',') FROM (SELECT stream FROM sync_cursors WHERE connection_id='conn_v3' ORDER BY stream)")" \
	"authored_comments,authored_posts,liked_comments,liked_posts,mentions,replies,saved_comments,saved_posts,subscriptions"

assert_eq "federation, retention, export, private-message, vote, deletion, and version gaps remain explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_v4' AND status='unavailable' AND stream IN ('federated_history','operator_retention','settings_export_completeness','private_message_bodies','complete_vote_history','deleted_or_purged_content','v3_split_inbox')")" 7

python3 - "$TMP_DIR/v4-first.json" "$INSTANCE_V4" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_lemmy_identity import namespaced_id

path, installation = sys.argv[1:]
payload = {
    "identity": {"data": {
        "provider_account_id": "42", "username": "selected",
        "display_name": "Selected", "ap_id": "https://lemmy.example.invalid/u/selected",
        "instance_id": installation, "api_family": "v4",
        "exact_version": "1.0.0-beta.1",
    }},
    "pages": [{
        "expect_request": {"position": 1, "page_cursor": None, "watermark": None},
        "response": {
            "status": 200, "observed_at": "2026-08-02T08:10:00Z",
            "data": [{
                "kind": "post", "remote_id": namespaced_id(installation, "post", 7),
                "provider_id": "7", "author_remote_id": namespaced_id(installation, "person", 42),
                "community_remote_id": namespaced_id(installation, "community", 9),
                "title": "Bounded Lemmy fixture", "content": "Lemmy knowledge",
                "created_at": "2026-08-02T08:00:00Z",
                "ap_id": "https://lemmy.example.invalid/post/7",
            }],
            "meta": {
                "stream": "authored_posts", "instance_id": installation,
                "api_family": "v4", "exact_version": "1.0.0-beta.1",
                "next": "opaque-v4-next", "complete": False,
                "watermark": "2026-08-02T08:00:00Z", "snapshot": True,
            },
        },
    }],
}
with open(path, "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
first_result=$(run_lemmy "$TMP_DIR/v4-first.json" conn_v4_cursor authored_posts 3 1)
assert_eq "one bounded v4 page pauses on its opaque cursor" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "v4 numeric IDs are installation-qualified while ActivityPub IDs remain evidence" \
	"$(sql_value "SELECT (SELECT count(*) FROM objects WHERE provider='lemmy' AND remote_id LIKE 'lmy_${INSTANCE_V4}_post_%') || ':' || json_extract(provider_json, '$.record.ap_id') FROM objects WHERE provider='lemmy' AND remote_id LIKE 'lmy_${INSTANCE_V4}_post_%'")" \
	"1:https://lemmy.example.invalid/post/7"
checkpoint_before=$(sql_value "SELECT cursor || '|' || watermark || '|' || (SELECT count(*) FROM fetch_batches WHERE connection_id='conn_v4_cursor') FROM sync_cursors WHERE connection_id='conn_v4_cursor' AND stream='authored_posts'")
raw_before=$(raw_count)

python3 - "$TMP_DIR/credential.json" "$INSTANCE_V4" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "provider_account_id": "42", "username": "selected",
        "ap_id": "https://lemmy.example.invalid/u/selected",
        "instance_id": sys.argv[2], "api_family": "v4", "exact_version": "1.0.0-beta.1",
    }},
    "pages": [{
        "status": 200, "observed_at": "2026-08-02T08:11:00Z",
        "access_token": "must-not-persist", "data": [],
        "meta": {
            "stream": "authored_posts", "instance_id": sys.argv[2],
            "api_family": "v4", "exact_version": "1.0.0-beta.1",
            "next": None, "complete": True, "watermark": None, "snapshot": True,
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
expect_failure "credential-shaped Lemmy page is rejected" \
	"$TMP_DIR/credential.json" conn_v4_cursor authored_posts
assert_eq "credential rejection preserves raw evidence and the prior checkpoint" \
	"$(raw_count):$(sql_value "SELECT cursor || '|' || watermark || '|' || (SELECT count(*) FROM fetch_batches WHERE connection_id='conn_v4_cursor') FROM sync_cursors WHERE connection_id='conn_v4_cursor' AND stream='authored_posts'")" \
	"${raw_before}:${checkpoint_before}"

python3 - "$TMP_DIR/malformed.json" "$INSTANCE_V4" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "provider_account_id": "42", "username": "selected",
        "ap_id": "https://lemmy.example.invalid/u/selected",
        "instance_id": sys.argv[2], "api_family": "v4", "exact_version": "1.0.0-beta.1",
    }},
    "pages": [{
        "status": 200, "observed_at": "2026-08-02T08:12:00Z", "data": {},
        "meta": {
            "stream": "authored_posts", "instance_id": sys.argv[2],
            "api_family": "v4", "exact_version": "1.0.0-beta.1",
            "next": None, "complete": True,
            "watermark": "2026-08-02T08:00:00Z", "snapshot": True,
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
expect_failure "malformed Lemmy page is rejected" \
	"$TMP_DIR/malformed.json" conn_v4_cursor authored_posts
assert_eq "malformed page preserves the prior checkpoint" \
	"$(sql_value "SELECT cursor || '|' || watermark || '|' || (SELECT count(*) FROM fetch_batches WHERE connection_id='conn_v4_cursor') FROM sync_cursors WHERE connection_id='conn_v4_cursor' AND stream='authored_posts'")" \
	"$checkpoint_before"

python3 - "$TMP_DIR/version-drift.json" "$INSTANCE_V4" <<'PY'
import json
import sys

payload = {"identity": {"data": {
    "provider_account_id": "42", "username": "selected",
    "ap_id": "https://lemmy.example.invalid/u/selected",
    "instance_id": sys.argv[2], "api_family": "v4", "exact_version": "1.0.0-beta.2",
}}, "pages": []}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
expect_failure "exact Lemmy version drift is rejected" \
	"$TMP_DIR/version-drift.json" conn_v4_cursor authored_posts
assert_eq "version drift preserves the prior checkpoint" \
	"$(sql_value "SELECT cursor || '|' || watermark || '|' || (SELECT count(*) FROM fetch_batches WHERE connection_id='conn_v4_cursor') FROM sync_cursors WHERE connection_id='conn_v4_cursor' AND stream='authored_posts'")" \
	"$checkpoint_before"

python3 - "$TMP_DIR/account-rebind.json" "$INSTANCE_V4" <<'PY'
import json
import sys

payload = {"identity": {"data": {
    "provider_account_id": "43", "username": "other",
    "ap_id": "https://lemmy.example.invalid/u/other",
    "instance_id": sys.argv[2], "api_family": "v4", "exact_version": "1.0.0-beta.1",
}}, "pages": []}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
expect_failure "Lemmy account rebinding stops before persistence" \
	"$TMP_DIR/account-rebind.json" conn_v4_cursor authored_posts

python3 - "$TMP_DIR/instance-rebind.json" <<'PY'
import json
import sys

payload = {"identity": {"data": {
    "provider_account_id": "42", "username": "selected",
    "ap_id": "https://other.example.invalid/u/selected",
    "instance_id": "cccccccccccccccccccccccc",
    "api_family": "v4", "exact_version": "1.0.0-beta.1",
}}, "pages": []}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
expect_failure "Lemmy instance rebinding stops before persistence" \
	"$TMP_DIR/instance-rebind.json" conn_v4_cursor authored_posts
assert_eq "identity rebinding preserves raw evidence and checkpoint" \
	"$(raw_count):$(sql_value "SELECT cursor || '|' || watermark || '|' || (SELECT count(*) FROM fetch_batches WHERE connection_id='conn_v4_cursor') FROM sync_cursors WHERE connection_id='conn_v4_cursor' AND stream='authored_posts'")" \
	"${raw_before}:${checkpoint_before}"

python3 - "$TMP_DIR/rate.json" "$INSTANCE_V4" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "provider_account_id": "42", "username": "selected",
        "ap_id": "https://lemmy.example.invalid/u/selected",
        "instance_id": sys.argv[2], "api_family": "v4", "exact_version": "1.0.0-beta.1",
    }},
    "pages": [{"status": 429, "observed_at": "2026-08-02T08:13:00Z", "retry_after": 1785659000}],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
rate_result=$(run_lemmy "$TMP_DIR/rate.json" conn_v4_cursor authored_posts 5 1)
assert_eq "terminal Lemmy rate limit is sanitized" \
	"$(json_field "$rate_result" status):$(json_field "$rate_result" failure_class)" \
	"rate_limited:rate_limit"
assert_eq "terminal error preserves the prior checkpoint" \
	"$(sql_value "SELECT cursor || '|' || watermark FROM sync_cursors WHERE connection_id='conn_v4_cursor' AND stream='authored_posts'")" \
	"${checkpoint_before%|*}"

python3 - "$TMP_DIR/v4-resume.json" "$INSTANCE_V4" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "provider_account_id": "42", "username": "selected",
        "ap_id": "https://lemmy.example.invalid/u/selected",
        "instance_id": sys.argv[2], "api_family": "v4", "exact_version": "1.0.0-beta.1",
    }},
    "pages": [{
        "expect_request": {
            "position": 2, "page_cursor": "opaque-v4-next",
            "watermark": "2026-08-02T08:00:00Z",
        },
        "response": {
            "status": 200, "observed_at": "2026-08-02T08:14:00Z", "data": [],
            "meta": {
                "stream": "authored_posts", "instance_id": sys.argv[2],
                "api_family": "v4", "exact_version": "1.0.0-beta.1",
                "next": None, "complete": True,
                "watermark": "2026-08-02T08:00:00Z", "snapshot": True,
            },
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
resume_result=$(run_lemmy "$TMP_DIR/v4-resume.json" conn_v4_cursor authored_posts 3 1)
assert_eq "v4 fixture resumes the exact opaque cursor" \
	"$(json_field "$resume_result" status):$(sql_value "SELECT coalesce(cursor, 'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_v4_cursor' AND stream='authored_posts'")" \
	"complete:done:1"

python3 - "$TMP_DIR/v4-replay.json" "$INSTANCE_V4" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "provider_account_id": "42", "username": "selected",
        "ap_id": "https://lemmy.example.invalid/u/selected",
        "instance_id": sys.argv[2], "api_family": "v4", "exact_version": "1.0.0-beta.1",
    }},
    "pages": [{
        "expect_request": {
            "position": 1, "page_cursor": None,
            "watermark": "2026-08-02T08:00:00Z",
        },
        "response": {
            "status": 200, "observed_at": "2026-08-02T08:15:00Z", "data": [],
            "meta": {
                "stream": "authored_posts", "instance_id": sys.argv[2],
                "api_family": "v4", "exact_version": "1.0.0-beta.1",
                "next": None, "complete": True,
                "watermark": "2026-08-02T08:00:00Z", "snapshot": True,
            },
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
run_lemmy "$TMP_DIR/v4-replay.json" conn_v4_cursor authored_posts 3 1 >/dev/null
replay_before="$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_v4_cursor'"):$(raw_count)"
run_lemmy "$TMP_DIR/v4-replay.json" conn_v4_cursor authored_posts 3 1 >/dev/null
assert_eq "exact completed-page replay is deterministic and idempotent" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_v4_cursor'"):$(raw_count)" \
	"$replay_before"

python3 - "$TMP_DIR/v3-first.json" "$INSTANCE_V3" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_lemmy_identity import namespaced_id

installation = sys.argv[2]
payload = {
    "identity": {"data": {
        "provider_account_id": "42", "username": "selected",
        "ap_id": "https://lemmy.example.invalid/u/selected",
        "instance_id": installation, "api_family": "v3", "exact_version": "0.19.20",
    }},
    "pages": [{
        "expect_request": {"position": 1, "page_cursor": None},
        "response": {
            "status": 200, "observed_at": "2026-08-02T08:20:00Z",
            "data": [{
                "kind": "post", "remote_id": namespaced_id(installation, "post", 8),
                "provider_id": "8", "author_remote_id": namespaced_id(installation, "person", 7),
                "community_remote_id": namespaced_id(installation, "community", 9),
                "title": "Saved v3 post", "created_at": "2026-08-02T08:00:00Z",
                "ap_id": "https://lemmy.example.invalid/post/8",
            }],
            "meta": {
                "stream": "saved_posts", "instance_id": installation,
                "api_family": "v3", "exact_version": "0.19.20",
                "next": 2, "complete": False,
                "watermark": "2026-08-02T08:00:00Z", "snapshot": True,
            },
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
v3_first=$(run_lemmy "$TMP_DIR/v3-first.json" conn_v3_cursor saved_posts 3 1)
assert_eq "v3 fixture pauses on an isolated numeric-page cursor" \
	"$(json_field "$v3_first" status):$(sql_value "SELECT substr(cursor, 1, 17) FROM sync_cursors WHERE connection_id='conn_v3_cursor'")" \
	"budget_exhausted:lemmy-v3-page-v1:"

python3 - "$TMP_DIR/v3-resume.json" "$INSTANCE_V3" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "provider_account_id": "42", "username": "selected",
        "ap_id": "https://lemmy.example.invalid/u/selected",
        "instance_id": sys.argv[2], "api_family": "v3", "exact_version": "0.19.20",
    }},
    "pages": [{
        "expect_request": {"position": 2, "page_cursor": "2"},
        "response": {
            "status": 200, "observed_at": "2026-08-02T08:21:00Z", "data": [],
            "meta": {
                "stream": "saved_posts", "instance_id": sys.argv[2],
                "api_family": "v3", "exact_version": "0.19.20",
                "next": None, "complete": True,
                "watermark": "2026-08-02T08:00:00Z", "snapshot": True,
            },
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
v3_resume=$(run_lemmy "$TMP_DIR/v3-resume.json" conn_v3_cursor saved_posts 3 1)
assert_eq "v3 fixture resumes numeric page two without a v4 token" \
	"$(json_field "$v3_resume" status):$(sql_value "SELECT coalesce(cursor, 'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_v3_cursor'")" \
	"complete:done:1"

python3 - "$ROOT" "$SCRIPT_DIR/../scripts" "$INSTANCE_V4" <<'PY'
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
from _knowledge_social_lemmy import STREAMS
from _knowledge_social_lemmy_identity import namespaced_id

root = Path(sys.argv[1])
installation = sys.argv[3]
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_lemmy_fence", "subscriptions", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_lemmy_fence", "subscriptions", "new_runner", "sync", 10),
    now_epoch=9001,
)
account_id = namespaced_id(installation, "person", 42)
context = CollectionContext(
    root,
    "conn_lemmy_fence",
    {"id": account_id},
    "subscriptions",
    "none",
    ConnectionConfig(("subscriptions",), {"lemmy_api_family": "v4"}),
    CursorState(None, None, False),
    STREAMS["subscriptions"],
    old,
    "lemmy",
)
archive = {
    "provider": "lemmy",
    "connection_id": "conn_lemmy_fence",
    "remote_account_id": account_id,
    "exported_at": "2026-08-02T08:30:00Z",
    "enabled_streams": ["subscriptions"],
    "policy": {"lemmy_api_family": "v4"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
page = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"subscriptions"}',
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
    raise SystemExit("stale Lemmy collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    count = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_lemmy_fence'"
    ).fetchone()[0]
assert count == 0
release_run_lease(root, new)
PY
assert_eq "stale Lemmy lease cannot commit evidence or a cursor" verified verified

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
