#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-forem.sh — Multi-instance Forem collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOREM_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_forem.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
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
	python3 - "$ROOT/sources/social/raw/forem" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_forem() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	local budget="$4"
	local page_size="$5"
	if python3 "$FOREM_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id user_42 \
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
	if run_forem "$fixture" "$connection_id" "$stream" 11 100 \
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

status = int(sys.argv[3])
page = {"status": status, "observed_at": "2026-08-01T12:00:00Z"}
if status == 429:
    page["retry_after"] = 1785542400
payload = {
    "identity": {"data": {
        "provider_account_id": "42",
        "username": "selected-user",
        "instance_id": sys.argv[2],
    }},
    "pages": [page],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	local result=""
	result=$(run_forem "$fixture" "conn_terminal_${name}" followers 11 100)
	assert_eq "${status} Forem response is terminal" \
		"$(json_field "$result" failure_class)" "$expected_failure"
	assert_eq "${status} terminal response records explicit coverage" \
		"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_terminal_${name}' AND stream='followers'")" \
		"${expected_coverage}:${expected_failure}"
	assert_eq "${status} terminal response advances no checkpoint" \
		"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_terminal_${name}'")" 0
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Forem social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import os
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_forem import PageRequest, STREAMS, namespaced_id
from _knowledge_social_forem_contract import ApiResult
from _knowledge_social_forem_http import (
    ACCEPT_HEADER,
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    _canonical_base_url,
    _http_exports,
    api,
    installation_fingerprint,
)
from _knowledge_social_forem_provider import _dispatch, _profile
from _knowledge_social_forem_normalize import PageContext, normalize_page
from _knowledge_social_forem_routes import EXACT_READ_PATHS, allowlisted_path, page

assert set(STREAMS) == {
    "authored_articles", "reading_list", "followed_tags", "followers"
}
assert all(spec.pagination == "snapshot" for spec in STREAMS.values())
assert all(spec.cost_units == 2 for spec in STREAMS.values())
assert EXACT_READ_PATHS == {
    "/api/users/me", "/api/articles/me/all", "/api/readinglist",
    "/api/follows/tags", "/api/followers/users",
}
for rejected in (
    "/api/comments", "/api/reactions", "/api/follows", "/api/admin/users",
    "/notifications", "/messages", "/settings", "/api/articles/1/unpublish",
):
    assert not allowlisted_path(rejected)

base_a = _canonical_base_url("https://forem-a.example.invalid/community/")
base_b = _canonical_base_url("https://forem-b.example.invalid/community")
instance_a = installation_fingerprint(base_a, "a" * 32)
instance_b = installation_fingerprint(base_b, "b" * 32)
assert base_a == "https://forem-a.example.invalid/community"
assert instance_a != instance_b
assert namespaced_id(instance_a, "user", "42") != namespaced_id(
    instance_b, "user", "42"
)
for invalid in (
    "http://forem.example.invalid",
    "https://user@forem.example.invalid",
    "https://forem.example.invalid/%2e%2e/admin",
    "https://forem.example.invalid/api",
):
    try:
        _canonical_base_url(invalid)
    except RuntimeError as error:
        assert "example.invalid" not in str(error)
    else:
        raise AssertionError("unsafe Forem base URL was accepted")

os.environ["FOREM_SCOPE_BASE_URL"] = base_a
os.environ["FOREM_SCOPE_API_KEY"] = "private-api-key-value"
os.environ["FOREM_SCOPE_ORIGIN_KEY"] = "a" * 32
os.environ["FOREM_SCOPE_AUTH_MODE"] = "admin"
try:
    _profile("scope")
except RuntimeError:
    pass
else:
    raise AssertionError("non-user Forem authority was accepted")


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
        assert "private-api-key-value" not in request.full_url
        assert request.get_header("Api-key") == "private-api-key-value"
        assert request.get_header("Accept") == ACCEPT_HEADER
        self.requests.append(request)
        return Response(self.payloads.pop(0))


config = ProfileConfig(base_a, "private-api-key-value", "user_api_key", instance_a)
opener = Opener([{"id": 42, "username": "selected-user", "email": "private"}])
identity = api(config, opener, "/api/users/me", {})
assert identity.status == 200
assert callable(_http_exports().open)
try:
    api(config, opener, "/api/reactions", {})
except RuntimeError:
    pass
else:
    raise AssertionError("Forem mutation route was reachable")


def request_for(stream, position=1, limit=2):
    return PageRequest(
        stream,
        namespaced_id(instance_a, "user", "42"),
        "42",
        "selected-user",
        instance_a,
        position,
        None,
        limit,
    )


calls = []


def articles_api(path, params):
    calls.append((path, params))
    return ApiResult(200, [{
        "id": 100,
        "title": "Bounded article",
        "description": "Knowledge",
        "created_at": "2026-08-01T11:00:00Z",
        "user": {"user_id": 42},
        "url": "https://not-persisted.invalid/private",
    }])


articles = page(articles_api, request_for("authored_articles"), {})
assert articles["data"][0]["remote_id"] == namespaced_id(
    instance_a, "article", "100"
)
assert "url" not in articles["data"][0]
assert articles["meta"]["next_position"] is None
assert calls == [("/api/articles/me/all", {"page": "1", "per_page": "2"})]


def tags_api(path, params):
    assert path == "/api/follows/tags"
    assert params == {}
    return ApiResult(200, [{"id": 7, "name": "python", "points": 3.5}])


tags = page(tags_api, request_for("followed_tags"), {})
assert tags["data"][0]["kind"] == "tag"
assert tags["meta"]["snapshot"] is True

account_id = namespaced_id(instance_a, "user", "42")
follower_id = namespaced_id(instance_a, "user", "77")
follower_archive = normalize_page(
    {
        "status": 200,
        "observed_at": "2026-08-01T12:00:00Z",
        "data": [{"kind": "user", "remote_id": follower_id, "name": "Follower"}],
    },
    PageContext(
        "conn_followers",
        {
            "id": account_id,
            "provider_account_id": "42",
            "instance_id": instance_a,
            "username": "selected-user",
        },
        "followers",
        ("followers",),
        {},
    ),
)
follower_activity = follower_archive["activities"][0]
assert follower_activity["actor_remote_id"] == follower_id
assert follower_activity["object_remote_id"] == account_id

dispatch_opener = Opener([
    {"id": 42, "username": "selected-user", "email": "private@example.invalid"},
    [{
        "id": 100,
        "title": "Selected article",
        "user": {"user_id": 42},
        "canonical_url": "https://not-persisted.invalid/article",
    }],
])
dispatched = _dispatch(request_for("authored_articles").payload(), config, dispatch_opener)
assert len(dispatch_opener.requests) == 2
assert dispatched["data"][0]["title"] == "Selected article"
assert "private@example.invalid" not in json.dumps(dispatched)
assert "canonical_url" not in json.dumps(dispatched)

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_forem*.py"))
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
    for alias in (
        node.names if isinstance(node, ast.Import) else [ast.alias(node.module or "")]
    )
}
assert "requests" not in imports
assert all("_knowledge_social_outbound" not in source for source in sources)
assert all("/api/admin/" not in source for source in sources)
PY
assert_eq "exact routes, namespaces, API-key policy, identity recheck, and GET-only AST are guarded" \
	verified verified

cat >"$TMP_DIR/first.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected-user","display_name":"Private A","instance_id":"${INSTANCE_A}"}},
  "pages":[{
    "expect_request":{"position":1,"stop_at":null,"limit":1,"instance_id":"${INSTANCE_A}"},
    "response":{"status":200,"observed_at":"2026-08-01T12:01:00Z",
      "data":[{"kind":"article","remote_id":"frm_${INSTANCE_A}_article_100","article_id":"100","title":"Newest bounded article","description":"Forem fixture knowledge","created_at":"2026-08-01T11:00:00Z"}],
      "meta":{"stream":"authored_articles","instance_id":"${INSTANCE_A}","next_position":2,"newest_id":"frm_${INSTANCE_A}_article_100","complete":false,"snapshot":true}}
  }]
}
JSON
first_result=$(run_forem "$TMP_DIR/first.json" conn_a authored_articles 3 1)
assert_eq "one bounded Forem page pauses initial snapshot" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "identity plus one Forem page reserves three request units" \
	"$(json_field "$first_result" budget_units)" 3
assert_eq "partial Forem page commits evidence and cursor atomically" \
	"$(sql_value "SELECT count(*) || ':' || (SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_a' AND stream='authored_articles') FROM fetch_batches WHERE connection_id='conn_a'")" \
	"1:0"
assert_eq "authored Forem text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1
assert_eq "collector output omits private profile metadata" \
	"$([[ "$first_result" == *Private* || "$first_result" == *selected-user* ]] && printf present || printf absent)" absent

cat >"$TMP_DIR/resume.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected-user","instance_id":"${INSTANCE_A}"}},
  "pages":[{
    "expect_request":{"position":2,"stop_at":null,"instance_id":"${INSTANCE_A}"},
    "response":{"status":200,"observed_at":"2026-08-01T12:02:00Z",
      "data":[{"kind":"article","remote_id":"frm_${INSTANCE_A}_article_90","article_id":"90","title":"Older article"}],
      "meta":{"stream":"authored_articles","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"frm_${INSTANCE_A}_article_90","complete":true,"snapshot":true}}
  }]
}
JSON
second_result=$(run_forem "$TMP_DIR/resume.json" conn_a authored_articles 11 100)
assert_eq "Forem snapshot resumes from its independent page" \
	"$(json_field "$second_result" status)" complete
assert_eq "completed Forem snapshot clears the page cursor" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_a' AND stream='authored_articles'")" \
	"done:1"

cat >"$TMP_DIR/instance-b.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected-user","instance_id":"${INSTANCE_B}"}},
  "pages":[{"status":200,"observed_at":"2026-08-01T12:03:00Z",
    "data":[{"kind":"article","remote_id":"frm_${INSTANCE_B}_article_100","article_id":"100","title":"Same local ID, other Forem"}],
    "meta":{"stream":"authored_articles","instance_id":"${INSTANCE_B}","next_position":null,"newest_id":"frm_${INSTANCE_B}_article_100","complete":true,"snapshot":true}}]
}
JSON
run_forem "$TMP_DIR/instance-b.json" conn_b authored_articles 11 100 >/dev/null
assert_eq "two Forem installations cannot collide on account or article IDs" \
	"$(sql_value "SELECT (SELECT count(*) FROM accounts WHERE provider='forem') || ':' || (SELECT count(*) FROM objects WHERE provider='forem' AND object_type='article')")" \
	"2:3"

expect_sync_failure "cross-installation connection rebinding is rejected" \
	"$TMP_DIR/instance-b.json" conn_a authored_articles

cat >"$TMP_DIR/identity-mismatch.json" <<JSON
{"identity":{"data":{"provider_account_id":"43","username":"other-user","instance_id":"${INSTANCE_A}"}},"pages":[]}
JSON
identity_raw_before=$(raw_count)
expect_sync_failure "selected-account identity mismatch is rejected" \
	"$TMP_DIR/identity-mismatch.json" conn_identity authored_articles
assert_eq "identity mismatch creates no raw evidence" "$(raw_count)" "$identity_raw_before"

cat >"$TMP_DIR/credential.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected-user","instance_id":"${INSTANCE_A}"}},
  "pages":[{"status":200,"observed_at":"2026-08-01T12:04:00Z","api_key":"must-not-persist","data":[],
    "meta":{"stream":"reading_list","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":null,"complete":true,"snapshot":true}}]
}
JSON
credential_raw_before=$(raw_count)
expect_sync_failure "credential-shaped Forem pages are rejected" \
	"$TMP_DIR/credential.json" conn_credential reading_list
assert_eq "credential rejection creates no raw evidence" "$(raw_count)" "$credential_raw_before"

python3 - "$TMP_DIR/oversized.json" "$INSTANCE_A" <<'PY'
import json
import sys

instance = sys.argv[2]
data = [
    {
        "kind": "tag",
        "remote_id": f"frm_{instance}_tag_{1000 + offset}",
        "tag_id": str(1000 + offset),
        "name": f"tag-{offset}",
    }
    for offset in range(101)
]
payload = {
    "identity": {"data": {
        "provider_account_id": "42",
        "username": "selected-user",
        "instance_id": instance,
    }},
    "pages": [{
        "status": 200,
        "observed_at": "2026-08-01T12:04:30Z",
        "data": data,
        "meta": {
            "stream": "followed_tags",
            "instance_id": instance,
            "next_position": None,
            "newest_id": data[0]["remote_id"],
            "complete": True,
            "snapshot": True,
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
oversized_raw_before=$(raw_count)
expect_sync_failure "oversized Forem pages are rejected" \
	"$TMP_DIR/oversized.json" conn_oversized followed_tags
assert_eq "oversized rejection creates no raw evidence" \
	"$(raw_count)" "$oversized_raw_before"

run_terminal_fixture forbidden 403 authorization failed
run_terminal_fixture unavailable 404 unavailable unavailable
run_terminal_fixture rate 429 rate_limit paused
run_terminal_fixture provider 500 provider failed

cat >"$TMP_DIR/tags.json" <<JSON
{
  "identity":{"data":{"provider_account_id":"42","username":"selected-user","instance_id":"${INSTANCE_A}"}},
  "pages":[{"status":200,"observed_at":"2026-08-01T12:05:00Z",
    "data":[{"kind":"tag","remote_id":"frm_${INSTANCE_A}_tag_7","tag_id":"7","name":"python","points":3.5}],
    "meta":{"stream":"followed_tags","instance_id":"${INSTANCE_A}","next_position":null,"newest_id":"frm_${INSTANCE_A}_tag_7","complete":true,"snapshot":true}}]
}
JSON
run_forem "$TMP_DIR/tags.json" conn_tags followed_tags 11 100 >/dev/null
tag_batches=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_tags'")
tag_raw=$(raw_count)
run_forem "$TMP_DIR/tags.json" conn_tags followed_tags 11 100 >/dev/null
assert_eq "exact Forem snapshot replay is idempotent" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_tags'"):$(raw_count)" \
	"${tag_batches}:${tag_raw}"
assert_eq "unsupported account categories remain explicit gaps" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_tags' AND status='unavailable' AND stream IN ('authored_comments','reactions','following','organizations','notifications','messages','account_exports','deleted_or_purged_content','installation_retention')")" 9

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
from _knowledge_social_forem import STREAMS
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    release_run_lease,
)

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_forem_fence", "reading_list", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_forem_fence", "reading_list", "new_runner", "sync", 10),
    now_epoch=9001,
)
account_id = "frm_aaaaaaaaaaaaaaaaaaaaaaaa_user_42"
context = CollectionContext(
    root,
    "conn_forem_fence",
    {"id": account_id},
    "reading_list",
    "none",
    ConnectionConfig(("reading_list",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["reading_list"],
    old,
    "forem",
)
archive = {
    "provider": "forem",
    "connection_id": "conn_forem_fence",
    "remote_account_id": account_id,
    "exported_at": "2026-08-01T12:06:00Z",
    "enabled_streams": ["reading_list"],
    "policy": {"media_hydration": "none"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
successful = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"reading_list"}',
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
    raise SystemExit("stale Forem collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    count = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_forem_fence'"
    ).fetchone()[0]
assert count == 0
release_run_lease(root, new)
PY
assert_eq "stale Forem lease cannot commit evidence or a cursor" verified verified

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
