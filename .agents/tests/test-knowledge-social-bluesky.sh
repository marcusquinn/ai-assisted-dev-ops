#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-bluesky.sh — Bluesky authority and no-write tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/../scripts"
FIXTURE="${SCRIPT_DIR}/fixtures/knowledge-social-bluesky/profile.json"
CORPUS_HELPER="${SCRIPTS}/knowledge-corpus-helper.sh"
SOCIAL_HELPER="${SCRIPTS}/knowledge-social-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
ACCOUNT_DID="did:plc:fixtureaccountaaaaaaaa"

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
		printf '  PASS  %s\n' "$description"
	else
		printf '  FAIL  %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
		return 1
	fi
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

printf 'Bluesky social collector tests\n'

python3 - "$SCRIPTS" <<'PY'
import ast
import os
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_bluesky import (
    STREAMS,
    BlueskyAdapterError,
    PageRequest,
    page_checkpoint,
    page_request,
    parse_page_request,
)
from _knowledge_social_bluesky_http import (
    Profile,
    profile_from_environment,
    service_id,
    service_url,
)
from _knowledge_social_bluesky_identity import pds_endpoint
from _knowledge_social_bluesky_routes import items_from, page, params_for
from _knowledge_social_collect import CursorState

expected = {
    "profile", "posts", "reposts", "likes", "follows", "blocks",
    "lists", "list_items", "feed_generators", "starter_packs",
    "labeler_services", "repo_status", "blobs", "author_feed",
    "notifications", "preferences", "bookmarks", "mutes", "appview_lists",
    "appview_starter_packs", "labels", "chat_conversations", "chat_log",
    "repository_export",
}
assert set(STREAMS) == expected
assert STREAMS["posts"].collection == "app.bsky.feed.post"
assert STREAMS["notifications"].authority == "appview"
assert STREAMS["chat_log"].authority == "chat"
assert STREAMS["repository_export"].coverage_status == "unavailable"
assert all(spec.cost_units == 4 for spec in STREAMS.values())

request = PageRequest(
    "posts", "did:plc:fixtureaccountaaaaaaaa", "fixture.example.invalid",
    "a" * 24, "pds", "com.atproto.repo.listRecords",
    "app.bsky.feed.post", None, 50,
)
assert parse_page_request(request.payload()) == request
for endpoint in (
    "com.atproto.repo.createRecord", "com.atproto.repo.putRecord",
    "com.atproto.repo.deleteRecord", "com.atproto.repo.applyWrites",
    "app.bsky.graph.muteActor", "app.bsky.notification.updateSeen",
    "chat.bsky.convo.sendMessage", "chat.bsky.convo.deleteMessageForSelf",
):
    assert endpoint not in {spec.endpoint for spec in STREAMS.values()}

provider = ast.parse((scripts / "_knowledge_social_bluesky_http.py").read_text())
methods = {
    node.value.value
    for node in ast.walk(provider)
    if isinstance(node, ast.keyword)
    and node.arg == "method"
    and isinstance(node.value, ast.Constant)
}
assert methods == {"GET"}

try:
    altered = request.payload()
    altered["endpoint"] = "com.atproto.repo.applyWrites"
    parse_page_request(altered)
except BlueskyAdapterError:
    pass
else:
    raise AssertionError("write-capable XRPC route was accepted")

account = {
    "id": request.account_id,
    "handle": request.handle,
    "pds_id": "a" * 24,
    "appview_id": "b" * 24,
    "chat_id": "c" * 24,
}
checkpoint, complete = page_checkpoint(
    {
        "meta": {
            "stream": "posts", "did": request.account_id,
            "service_id": "a" * 24, "next_cursor": "opaque-page-2",
            "complete": False, "watermark": "bafyfixturewatermark",
        }
    },
    CursorState(None, None, False),
    request,
)
assert complete is False
resumed = page_request(
    "posts", account, CursorState(checkpoint.next_cursor, checkpoint.watermark, False), 50
)
assert resumed.cursor == "opaque-page-2"
migrated = dict(account, pds_id="e" * 24)
assert page_request(
    "posts", migrated, CursorState(checkpoint.next_cursor, checkpoint.watermark, False), 50
).cursor is None
try:
    rebound = dict(account, id="did:plc:anotherfixtureaccount")
    page_request(
        "posts", rebound, CursorState(checkpoint.next_cursor, checkpoint.watermark, False), 50
    )
except BlueskyAdapterError:
    pass
else:
    raise AssertionError("DID-rebound cursor was accepted")

profile = Profile(
    "x", request.handle, "https://pds.example.invalid",
    "https://appview.example.invalid", None, False, "oauth",
)
chat_request = PageRequest(
    "chat_log", request.account_id, request.handle, service_id(None),
    "chat", "chat.bsky.convo.getLog", None, None, 50,
)
assert page(profile, chat_request)["status"] == 403
assert params_for(chat_request) == {}
assert params_for(request) == {
    "repo": request.account_id,
    "collection": "app.bsky.feed.post",
    "limit": "50",
}
try:
    items_from({"records": ["malformed"]}, request)
except BlueskyAdapterError:
    pass
else:
    raise AssertionError("malformed repository records were accepted")
for unsafe in (
    "http://pds.example.invalid", "https://user@pds.example.invalid",
    "https://pds.example.invalid/path", "https://pds.example.invalid?query=1",
):
    try:
        service_url(unsafe)
    except BlueskyAdapterError:
        pass
    else:
        raise AssertionError("unsafe service URL was accepted")

document = {
    "id": request.account_id,
    "service": [{
        "id": "#atproto_pds",
        "type": "AtprotoPersonalDataServer",
        "serviceEndpoint": "https://pds.example.invalid",
    }],
}
assert pds_endpoint(document, request.account_id) == "https://pds.example.invalid"
try:
    pds_endpoint(document, "did:plc:anotherfixtureaccount")
except BlueskyAdapterError:
    pass
else:
    raise AssertionError("mismatched DID document was accepted")

os.environ.update({
    "BLUESKY_TEST_ACCESS_TOKEN": "x",
    "BLUESKY_TEST_HANDLE": request.handle,
    "BLUESKY_TEST_PDS_URL": "https://pds.example.invalid",
    "BLUESKY_TEST_APPVIEW_SERVICE": "did:web:appview.example.invalid#bsky_appview",
    "BLUESKY_TEST_AUTH_MODE": "oauth",
})
try:
    profile_from_environment("test")
except BlueskyAdapterError as error:
    assert "DPoP" in str(error)
else:
    raise AssertionError("bearer-only OAuth profile was accepted")
PY
assert_eq "routes, migration, cursors, and private gates are bounded" verified verified

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

result=$(python3 "$SCRIPTS/knowledge_social_bluesky.py" \
	--base "$BASE" --alias personal:default \
	--connection-id conn_bluesky_fixture --account-id "$ACCOUNT_DID" \
	--stream profile --profile fixture --fixture "$FIXTURE")
assert_eq "fixture collection completes" \
	"$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$result")" complete
assert_eq "reported budget includes all identity requests" \
	"$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["budget_units"])' "$result")" 7
assert_eq "stable DID is canonical account identity" \
	"$(sql_value "SELECT remote_id FROM accounts WHERE provider='bluesky'")" "$ACCOUNT_DID"
assert_eq "repository profile evidence persists once" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='bluesky' AND object_type='profile'")" 1
assert_eq "service authority is retained" \
	"$(sql_value "SELECT json_extract(provider_json, '$.authority') FROM objects WHERE provider='bluesky'")" pds
assert_eq "binary export remains explicit unavailable coverage" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_bluesky_fixture' AND stream='repository_car_export' AND status='unavailable'")" 1

python3 - "$SCRIPTS" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from _knowledge_social_bluesky import PageRequest
from _knowledge_social_bluesky_normalize import PageContext, normalize_page

did = "did:plc:fixtureaccountaaaaaaaa"
account = {
    "id": did,
    "handle": "fixture.example.invalid",
    "pds_id": "a" * 24,
    "appview_id": "b" * 24,
    "chat_id": "c" * 24,
}
payload = {
    "observed_at": "2026-07-31T12:00:00Z",
    "data": [{
        "uri": f"at://{did}/app.bsky.feed.post/deleted",
        "cid": "bafyfixturedeleted",
        "deleted": True,
        "value": {"text": "Synthetic tombstone"},
    }],
}
archive = normalize_page(payload, PageContext("conn", account, "posts", ("posts",), {}))
assert archive["activities"][0]["state"] == "deleted"
assert archive["objects"][0]["provider_json"]["tombstone"] is True
assert archive["objects"][0]["provider_json"]["at_uri"].startswith("at://")
assert archive["objects"][0]["provider_json"]["cid"] == "bafyfixturedeleted"
blob_archive = normalize_page(
    {"observed_at": payload["observed_at"], "data": [{"cid": "bafyfixtureblob"}]},
    PageContext("conn", account, "blobs", ("blobs",), {}),
)
assert blob_archive["media"][0] == {
    "remote_id": "bafyfixtureblob",
    "object_remote_id": "bafyfixtureblob",
    "content_sha256": None,
    "mime_type": None,
    "byte_size": None,
    "blob_ref": "bafyfixtureblob",
    "hydration_state": "metadata_only",
}

like_uri = f"at://{did}/app.bsky.feed.like/action"
target_uri = "at://did:plc:targetfixtureaccount/app.bsky.feed.post/post"
like_archive = normalize_page(
    {
        "observed_at": payload["observed_at"],
        "data": [{
            "uri": like_uri,
            "cid": "bafyfixturelike",
            "value": {"subject": {"uri": target_uri, "cid": "bafyfixturepost"}},
        }],
    },
    PageContext("conn", account, "likes", ("likes",), {}),
)
assert like_archive["objects"] == []
assert like_archive["activities"][0]["remote_id"] == like_uri
assert like_archive["activities"][0]["object_remote_id"] == target_uri

preference_type = "app.bsky.actor.defs#labelersPref"
preference_a = {"$type": preference_type, "labelerDid": "did:plc:labelerfixturea"}
preference_b = {"$type": preference_type, "labelerDid": "did:plc:labelerfixtureb"}
preference_archive = normalize_page(
    {"observed_at": payload["observed_at"], "data": [preference_a, preference_b]},
    PageContext("conn", account, "preferences", ("preferences",), {}),
)
preference_ids = [row["remote_id"] for row in preference_archive["objects"]]
assert len(set(preference_ids)) == 2
preference_a["visibility"] = "hide"
updated_preference = normalize_page(
    {"observed_at": payload["observed_at"], "data": [preference_a]},
    PageContext("conn", account, "preferences", ("preferences",), {}),
)
assert updated_preference["objects"][0]["remote_id"] == preference_ids[0]

bookmark = {
    "subject": {"uri": target_uri, "cid": "bafyfixturepost"},
    "createdAt": payload["observed_at"],
    "item": {
        "uri": target_uri,
        "likeCount": 1,
        "record": {"text": "Bookmarked fixture post"},
    },
}
bookmark_archive = normalize_page(
    {"observed_at": payload["observed_at"], "data": [bookmark]},
    PageContext("conn", account, "bookmarks", ("bookmarks",), {}),
)
bookmark["item"]["likeCount"] = 2
updated_bookmark = normalize_page(
    {"observed_at": payload["observed_at"], "data": [bookmark]},
    PageContext("conn", account, "bookmarks", ("bookmarks",), {}),
)
assert bookmark_archive["objects"][0]["remote_id"] == target_uri
assert updated_bookmark["objects"][0]["remote_id"] == target_uri
assert bookmark_archive["objects"][0]["text"] == "Bookmarked fixture post"

chat_items = [
    {
        "$type": "chat.bsky.convo.defs#logCreateMessage",
        "rev": "chat-rev-1",
        "convoId": "convo-fixture",
        "message": {
            "id": "message-1", "rev": "message-rev-1",
            "text": "First fixture message",
            "sender": {"did": "did:plc:senderfixtureaccount"},
            "sentAt": "2026-07-31T11:00:00Z",
        },
    },
    {
        "$type": "chat.bsky.convo.defs#logDeleteMessage",
        "rev": "chat-rev-2",
        "convoId": "convo-fixture",
        "message": {
            "id": "message-1", "rev": "message-rev-2",
            "sender": {"did": "did:plc:senderfixtureaccount"},
            "sentAt": "2026-07-31T11:01:00Z",
        },
    },
]
chat_archive = normalize_page(
    {"observed_at": payload["observed_at"], "data": chat_items},
    PageContext("conn", account, "chat_log", ("chat_log",), {}),
)
assert [row["remote_id"] for row in chat_archive["objects"]] == [
    "chat-rev-1", "chat-rev-2"
]
assert chat_archive["objects"][0]["text"] == "First fixture message"
assert chat_archive["activities"][0]["actor_remote_id"] == "did:plc:senderfixtureaccount"
assert chat_archive["activities"][1]["state"] == "deleted"
PY
assert_eq "normalization identities and sparse relationships converge" verified verified

if rg -n --glob '*bluesky*' 'method="(POST|PUT|PATCH|DELETE)"' \
	"$SCRIPTS" "$SCRIPT_DIR/fixtures/knowledge-social-bluesky" >/dev/null; then
	assert_eq "credentials and provider writes remain unreachable" exposed isolated
else
	assert_eq "credentials and provider writes remain unreachable" isolated isolated
fi

printf 'Bluesky social collector tests passed\n'
