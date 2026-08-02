#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-ghost.sh — Identity-bound Ghost Content API tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHOST_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_ghost.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
INSTANCE_A="aaaaaaaaaaaaaaaaaaaaaaaa"
SITE_ID="ghost_publication"
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
	python3 - "$ROOT/sources/social/raw/ghost" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_ghost() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	local budget="$4"
	local page_size="$5"
	if python3 "$GHOST_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id "$SITE_ID" \
		--stream "$stream" --profile fixture --fixture "$fixture" \
		--budget "$budget" --page-size "$page_size"; then
		return 0
	fi
	return 1
}

expect_sync_failure() {
	local description="$1"
	local fixture="$2"
	local connection_id="$3"
	local stream="$4"
	if run_ghost "$fixture" "$connection_id" "$stream" 11 100 \
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
	python3 - "$fixture" "$INSTANCE_A" "$SITE_ID" "$status" <<'PY'
import json
import sys

status = int(sys.argv[4])
page = {"status": status, "observed_at": "2026-08-02T12:00:00Z"}
if status == 429:
    page["retry_after"] = 1785690000
payload = {
    "identity": {"data": {
        "provider_account_id": sys.argv[3],
        "site_id": sys.argv[3],
        "instance_id": sys.argv[2],
        "version": "6.0",
    }},
    "pages": [page],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	local result=""
	result=$(run_ghost "$fixture" "conn_terminal_${name}" authors 11 100)
	assert_eq "${status} Ghost response is terminal" \
		"$(json_field "$result" failure_class)" "$expected_failure"
	assert_eq "${status} terminal response records explicit coverage" \
		"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_terminal_${name}' AND stream='authors'")" \
		"${expected_coverage}:${expected_failure}"
	assert_eq "${status} terminal response advances no checkpoint" \
		"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_terminal_${name}'")" 0
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Ghost social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import json
import os
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_ghost import PageRequest, STREAMS, namespaced_id
from _knowledge_social_ghost_contract import ApiResult, GhostReadProviderError
from _knowledge_social_ghost_http import (
    ACCEPT_VERSION,
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    _canonical_admin_url,
    _canonical_site_url,
    _http_exports,
    api,
    installation_fingerprint,
)
from _knowledge_social_ghost_provider import _dispatch, _profile
from _knowledge_social_ghost_routes import (
    EXACT_READ_PATHS,
    SITE_PATH,
    STREAM_PATHS,
    allowlisted_path,
    page,
)

instance = "a" * 24
site_id = "ghost_publication"
content_key = "a" * 26
admin_url = _canonical_admin_url("https://admin.example.invalid/publication/")
site_url = _canonical_site_url("https://www.example.invalid/")

assert set(STREAMS) == {"posts", "pages", "tags", "authors"}
assert all(spec.pagination == "snapshot" for spec in STREAMS.values())
assert all(spec.cost_units == 2 for spec in STREAMS.values())
assert ACCEPT_VERSION == "v6.0"
assert EXACT_READ_PATHS == {
    SITE_PATH,
    "/ghost/api/content/posts/",
    "/ghost/api/content/pages/",
    "/ghost/api/content/tags/",
    "/ghost/api/content/authors/",
}
for rejected in (
    "/ghost/api/admin/posts/",
    "/ghost/api/admin/members/",
    "/ghost/api/admin/newsletters/",
    "/ghost/api/admin/users/",
    "/ghost/api/admin/comments/",
    "/ghost/api/admin/db/",
    "/ghost/api/content/settings/",
):
    assert not allowlisted_path(rejected)

assert admin_url == "https://admin.example.invalid/publication"
assert site_url == "https://www.example.invalid"
assert installation_fingerprint(admin_url, "a" * 32) != installation_fingerprint(
    admin_url, "b" * 32
)
for invalid in (
    "http://admin.example.invalid",
    "https://user@admin.example.invalid",
    "https://admin.example.invalid/%2e%2e/ghost",
    "https://admin.example.invalid/ghost/api/admin",
):
    try:
        _canonical_admin_url(invalid)
    except RuntimeError as error:
        assert "admin.example.invalid" not in str(error)
    else:
        raise AssertionError("unsafe Ghost admin URL was accepted")

os.environ["GHOST_SCOPE_ADMIN_URL"] = admin_url
os.environ["GHOST_SCOPE_SITE_URL"] = site_url
os.environ["GHOST_SCOPE_SITE_ID"] = site_id
os.environ["GHOST_SCOPE_CONTENT_API_KEY"] = content_key
os.environ["GHOST_SCOPE_ORIGIN_KEY"] = "a" * 32
os.environ["GHOST_SCOPE_AUTH_MODE"] = "admin_api_key"
try:
    _profile("scope")
except RuntimeError:
    pass
else:
    raise AssertionError("Ghost Admin authority was accepted")

os.environ["GHOST_SCOPE_AUTH_MODE"] = "content_api_key"
os.environ["GHOST_SCOPE_CONTENT_API_KEY"] = "header.payload.signature"
try:
    _profile("scope")
except RuntimeError:
    pass
else:
    raise AssertionError("JWT-shaped Ghost credential was accepted")


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
    def __init__(self, payloads):
        self.payloads = list(payloads)
        self.requests = []

    def open(self, request, timeout):
        assert timeout == HTTP_TIMEOUT_SECONDS
        assert request.method == "GET"
        assert request.get_header("Accept-version") == ACCEPT_VERSION
        assert request.get_header("Authorization") is None
        self.requests.append(request)
        return Response(self.payloads.pop(0))


config = ProfileConfig(
    admin_url,
    site_url,
    site_id,
    content_key,
    "content_api_key",
    instance,
)
opener = Opener([
    {"site": {"title": "Publication", "url": site_url, "version": "6.0"}},
    {"posts": [], "meta": {"pagination": {
        "page": 1, "limit": 2, "pages": 1, "total": 0,
        "next": None, "prev": None,
    }}},
])
identity_result = api(config, opener, SITE_PATH, {})
assert identity_result.status == 200
assert "key=" not in opener.requests[0].full_url
content_result = api(
    config,
    opener,
    STREAM_PATHS["posts"],
    {"page": "1", "limit": "2", "formats": "html,plaintext"},
)
assert content_result.status == 200
query = parse_qs(urlsplit(opener.requests[1].full_url).query)
assert query["key"] == [content_key]
assert "Authorization" not in dict(opener.requests[1].header_items())
assert callable(_http_exports().open)
try:
    api(config, opener, "/ghost/api/admin/members/", {})
except RuntimeError:
    pass
else:
    raise AssertionError("Ghost private Admin route was reachable")

good_identity = Opener([
    {"site": {
        "title": "Public Knowledge",
        "description": "not persisted",
        "url": site_url,
        "version": "6.0",
    }}
])
identity = _dispatch(
    {"action": "identity", "account_id": site_id}, config, good_identity
)
encoded_identity = json.dumps(identity, sort_keys=True)
assert content_key not in encoded_identity
assert site_url not in encoded_identity
assert identity["data"]["provider_account_id"] == site_id

wrong_site = Opener([
    {"site": {
        "title": "Other Publication",
        "url": "https://other.example.invalid/",
        "version": "6.0",
    }}
])
try:
    _dispatch({"action": "identity", "account_id": site_id}, config, wrong_site)
except GhostReadProviderError:
    pass
else:
    raise AssertionError("cross-site Ghost identity was accepted")


def request_for(stream, position=1, limit=2):
    return PageRequest(
        stream,
        namespaced_id(instance, "site", site_id),
        site_id,
        site_id,
        instance,
        position,
        None,
        limit,
    )


post_calls = []


def posts_api(path, params):
    post_calls.append((path, params))
    return ApiResult(200, {
        "posts": [{
            "id": "post-1",
            "uuid": "post-uuid",
            "title": "Bounded Ghost knowledge",
            "slug": "bounded-ghost-knowledge",
            "html": "<p>Published text</p>",
            "plaintext": "Published text",
            "published_at": "2026-08-02T10:00:00Z",
            "url": "https://cross-site.example.invalid/not-persisted",
            "feature_image": "https://cross-site.example.invalid/image.jpg",
        }],
        "meta": {"pagination": {
            "page": 1, "limit": 2, "pages": 1, "total": 1,
            "next": None, "prev": None,
        }},
    })


posts = page(posts_api, request_for("posts"), {})
assert post_calls == [(STREAM_PATHS["posts"], {
    "page": "1", "limit": "2", "formats": "html,plaintext",
})]
assert posts["data"][0]["remote_id"] == namespaced_id(instance, "post", "post-1")
assert "url" not in posts["data"][0]
assert "feature_image" not in posts["data"][0]


def authors_api(_path, _params):
    return ApiResult(200, {
        "authors": [{
            "id": "author-1",
            "name": "Public Author",
            "slug": "public-author",
            "bio": "Published biography",
            "email": "omitted@example.invalid",
            "location": "omitted",
            "website": "https://omitted.example.invalid",
            "count": {"posts": 4},
        }],
        "meta": {"pagination": {
            "page": 1, "limit": 2, "pages": 1, "total": 1,
            "next": None, "prev": None,
        }},
    })


authors = page(authors_api, request_for("authors"), {})
assert set(authors["data"][0]) == {
    "kind", "remote_id", "resource_id", "name", "slug", "bio", "post_count"
}
assert authors["data"][0]["post_count"] == 4


def bad_pagination(_path, _params):
    return ApiResult(200, {
        "pages": [],
        "meta": {"pagination": {
            "page": 1, "limit": 2, "pages": 2, "total": 3,
            "next": 1, "prev": None,
        }},
    })


try:
    page(bad_pagination, request_for("pages"), {})
except GhostReadProviderError:
    pass
else:
    raise AssertionError("non-advancing Ghost pagination was accepted")


def private_tag(_path, _params):
    return ApiResult(200, {
        "tags": [{
            "id": "tag-1", "name": "Private", "slug": "hash-private",
            "visibility": "internal",
        }],
        "meta": {"pagination": {
            "page": 1, "limit": 2, "pages": 1, "total": 1,
            "next": None, "prev": None,
        }},
    })


try:
    page(private_tag, request_for("tags"), {})
except GhostReadProviderError:
    pass
else:
    raise AssertionError("internal Ghost tag was accepted")
PY
assert_eq "Ghost Content/Admin boundaries and transport contract" verified verified

cat >"$TMP_DIR/posts-first.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"${SITE_ID}","site_id":"${SITE_ID}","instance_id":"${INSTANCE_A}","version":"6.0","display_name":"Public Knowledge"}},
  "pages":[{
    "expect_request":{"position":1,"stop_at":null,"instance_id":"${INSTANCE_A}"},
    "response":{"status":200,"observed_at":"2026-08-02T12:01:00Z",
      "data":[{"kind":"post","remote_id":"gst_${INSTANCE_A}_post_post-1","resource_id":"post-1","title":"Bounded Ghost knowledge","slug":"bounded","plaintext":"Fixture text","published_at":"2026-08-02T10:00:00Z"}],
      "meta":{"stream":"posts","instance_id":"${INSTANCE_A}","next_position":2,"newest_id":"gst_${INSTANCE_A}_post_post-1","complete":false,"snapshot":true}}
  }]
}
JSON
first_result=$(run_ghost "$TMP_DIR/posts-first.json" conn_posts posts 3 1)
assert_eq "bounded Ghost run pauses after its request budget" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "first Ghost page persists a resumable cursor" \
	"$(sql_value "SELECT backfill_complete || ':' || (cursor IS NOT NULL) FROM sync_cursors WHERE connection_id='conn_posts' AND stream='posts'")" \
	"0:1"
assert_eq "published Ghost text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1

cat >"$TMP_DIR/posts-resume.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"${SITE_ID}","site_id":"${SITE_ID}","instance_id":"${INSTANCE_A}","version":"6.0","display_name":"Public Knowledge"}},
  "pages":[{
    "expect_request":{"position":2,"stop_at":null,"instance_id":"${INSTANCE_A}"},
    "response":{"status":200,"observed_at":"2026-08-02T12:02:00Z",
      "data":[{"kind":"post","remote_id":"gst_${INSTANCE_A}_post_post-2","resource_id":"post-2","title":"Older Ghost knowledge","slug":"older","plaintext":"Older fixture text","published_at":"2026-08-01T10:00:00Z"}],
      "meta":{"stream":"posts","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"gst_${INSTANCE_A}_post_post-2","complete":true,"snapshot":true}}
  }]
}
JSON
second_result=$(run_ghost "$TMP_DIR/posts-resume.json" conn_posts posts 11 1)
assert_eq "Ghost snapshot resumes from its independent page" \
	"$(json_field "$second_result" status)" complete
assert_eq "completed Ghost snapshot clears its page cursor" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_posts' AND stream='posts'")" \
	"done:1"
assert_eq "Ghost posts persist publication objects and activities" \
	"$(sql_value "SELECT (SELECT count(*) FROM objects WHERE provider='ghost' AND object_type='post') || ':' || (SELECT count(*) FROM activities WHERE provider='ghost' AND activity_type='published_post')")" \
	"2:2"

cat >"$TMP_DIR/identity-mismatch.json" <<JSON
{"identity":{"data":{"provider_account_id":"other_publication","site_id":"other_publication","instance_id":"${INSTANCE_A}","version":"6.0"}},"pages":[]}
JSON
identity_raw_before=$(raw_count)
expect_sync_failure "selected Ghost publication mismatch is rejected" \
	"$TMP_DIR/identity-mismatch.json" conn_identity posts
assert_eq "identity mismatch creates no raw evidence" \
	"$(raw_count)" "$identity_raw_before"

cat >"$TMP_DIR/credential.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"${SITE_ID}","site_id":"${SITE_ID}","instance_id":"${INSTANCE_A}","version":"6.0"}},
  "pages":[{"status":200,"observed_at":"2026-08-02T12:03:00Z","api_key":"redacted","data":[],
    "meta":{"stream":"authors","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":null,"complete":true,"snapshot":true}}]
}
JSON
credential_raw_before=$(raw_count)
expect_sync_failure "credential-shaped Ghost pages are rejected" \
	"$TMP_DIR/credential.json" conn_credential authors
assert_eq "credential rejection creates no raw evidence" \
	"$(raw_count)" "$credential_raw_before"

cat >"$TMP_DIR/malformed.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"${SITE_ID}","site_id":"${SITE_ID}","instance_id":"${INSTANCE_A}","version":"6.0"}},
  "pages":[{"status":200,"observed_at":"2026-08-02T12:04:00Z","data":[],
    "meta":{"stream":"pages","instance_id":"${INSTANCE_A}","next_position":1,"newest_id":null,"complete":false,"snapshot":true}}]
}
JSON
expect_sync_failure "non-advancing Ghost fixture cursor is rejected" \
	"$TMP_DIR/malformed.json" conn_malformed pages
assert_eq "malformed Ghost page advances no checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_malformed'")" 0

run_terminal_fixture forbidden 403 authorization failed
run_terminal_fixture rate 429 rate_limit paused
run_terminal_fixture provider 500 provider failed

cat >"$TMP_DIR/tags.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"${SITE_ID}","site_id":"${SITE_ID}","instance_id":"${INSTANCE_A}","version":"6.0","display_name":"Public Knowledge"}},
  "pages":[{"status":200,"observed_at":"2026-08-02T12:05:00Z",
    "data":[{"kind":"tag","remote_id":"gst_${INSTANCE_A}_tag_tag-1","resource_id":"tag-1","name":"Knowledge","slug":"knowledge","description":"Public taxonomy","post_count":2}],
    "meta":{"stream":"tags","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"gst_${INSTANCE_A}_tag_tag-1","complete":true,"snapshot":true}}]
}
JSON
run_ghost "$TMP_DIR/tags.json" conn_tags tags 11 100 >/dev/null
tag_batches=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_tags'")
tag_raw=$(raw_count)
run_ghost "$TMP_DIR/tags.json" conn_tags tags 11 100 >/dev/null
assert_eq "exact Ghost snapshot replay is idempotent" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_tags'"):$(raw_count)" \
	"${tag_batches}:${tag_raw}"
assert_eq "private Ghost categories remain explicit gaps" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_tags' AND status='unavailable' AND stream IN ('members','newsletters','comments','account_export','staff_and_owner_identity','drafts_and_unpublished','deleted_or_purged_content','provider_retention')")" 8

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
from _knowledge_social_ghost import STREAMS
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    release_run_lease,
)

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_ghost_fence", "tags", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_ghost_fence", "tags", "new_runner", "sync", 10),
    now_epoch=9001,
)
account_id = "gst_aaaaaaaaaaaaaaaaaaaaaaaa_site_ghost_publication"
context = CollectionContext(
    root,
    "conn_ghost_fence",
    {"id": account_id},
    "tags",
    "none",
    ConnectionConfig(("tags",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["tags"],
    old,
    "ghost",
)
archive = {
    "provider": "ghost",
    "connection_id": "conn_ghost_fence",
    "remote_account_id": account_id,
    "exported_at": "2026-08-02T12:06:00Z",
    "enabled_streams": ["tags"],
    "policy": {"media_hydration": "none"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
successful = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"tags"}',
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
    raise SystemExit("stale Ghost collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    count = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_ghost_fence'"
    ).fetchone()[0]
assert count == 0
release_run_lease(root, new)
PY
assert_eq "stale Ghost lease cannot commit evidence or a cursor" verified verified

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
