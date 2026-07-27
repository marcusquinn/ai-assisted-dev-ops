#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-meta.sh — bounded Meta product collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
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
	local product="$1"
	python3 - "$ROOT/sources/social/raw/$product" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

expect_sync_failure() {
	local description="$1"
	local product="$2"
	local account_id="$3"
	local stream="$4"
	local fixture="$5"
	if "$HELPER" sync-meta --product "$product" --base "$BASE" \
		--alias personal:default --connection-id "conn_${product}_failure" \
		--account-id "$account_id" --stream "$stream" --profile fixture \
		--fixture "$fixture" >/dev/null 2>&1; then
		assert_eq "$description" accepted rejected
	else
		assert_eq "$description" rejected rejected
	fi
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Meta social collector tests\n'

help_output=$("$HELPER" help)
if [[ "$help_output" == *"sync-meta"* && "$help_output" == *"facebook|instagram|threads"* ]]; then
	assert_eq "Meta help exposes the product-scoped route" advertised advertised
else
	assert_eq "Meta help exposes the product-scoped route" missing advertised
fi

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_meta import (
    GRAPH_API_VERSION,
    PRODUCTS,
    THREADS_API_VERSION,
    MetaAdapterError,
    MetaProductModule,
    page_checkpoint,
    page_request,
)
from _knowledge_social_meta_contract import ApiResult, page_payload
from _knowledge_social_meta_provider import READ_EDGES, _http_exports

assert GRAPH_API_VERSION == "v25.0"
assert THREADS_API_VERSION == "v1.0"
assert set(PRODUCTS) == {"facebook", "instagram", "threads"}
assert PRODUCTS["facebook"].api_base == "https://graph.facebook.com/v25.0"
assert PRODUCTS["instagram"].api_base == "https://graph.facebook.com/v25.0"
assert PRODUCTS["threads"].api_base == "https://graph.threads.com/v1.0"
assert set(PRODUCTS["facebook"].streams) == {"posts"}
assert set(PRODUCTS["instagram"].streams) == {"media"}
assert set(PRODUCTS["threads"].streams) == {"posts", "replies", "mentions"}
assert READ_EDGES == {
    "facebook": frozenset({"posts"}),
    "instagram": frozenset({"media"}),
    "threads": frozenset({"threads", "replies", "mentions"}),
}
assert callable(_http_exports())

request = page_request(
    "facebook", "posts", {"id": "1001"}, CursorState(None, None, False), 1
)
payload = {
    "meta": {
        "product": "facebook",
        "stream": "posts",
        "next_cursor": "cursor-one",
        "complete": False,
    }
}
checkpoint, complete = page_checkpoint(
    "facebook", payload, CursorState(None, None, False), request
)
resumed = page_request(
    "facebook",
    "posts",
    {"id": "1001"},
    CursorState(checkpoint.next_cursor, None, complete),
    1,
)
assert resumed.after == "cursor-one" and complete is False
assert MetaProductModule("threads").PROVIDER == "threads"

result = ApiResult(
    200,
    {
        "data": [{"id": "1001_5001", "message": "safe", "unexpected": "drop"}],
        "paging": {
            "cursors": {"after": "cursor-two"},
            "next": "https://graph.facebook.com/v25.0/1001/posts?after=cursor-two",
        },
    },
)
safe_page = page_payload(result, PRODUCTS["facebook"], "posts", "1001", 1)
assert safe_page["data"] == [{"id": "1001_5001", "message": "safe"}]
assert safe_page["meta"]["next_cursor"] == "cursor-two"

threads_page = page_payload(
    ApiResult(
        200,
        {
            "data": [{"id": "7001", "text": "safe"}],
            "paging": {
                "cursors": {"after": "threads-cursor"},
                "next": "https://graph.threads.net/v1.0/me/threads?after=threads-cursor",
            },
        },
    ),
    PRODUCTS["threads"],
    "posts",
    "3001",
    1,
)
assert threads_page["meta"]["next_cursor"] == "threads-cursor"
try:
    page_request(
        "facebook", "posts", {"id": "1001_5001"}, CursorState(None, None, False), 1
    )
except MetaAdapterError:
    pass
else:
    raise AssertionError("composite content ID was accepted as an account identity")

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("*knowledge_social_meta*.py"))
]
assert sources
assert all("knowledge_social_operations" not in source for source in sources)
assert all("knowledge_social_browser" not in source for source in sources)
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
PY
assert_eq "product manifests, cursor isolation, field allowlists, and GET-only transport are guarded" \
	verified verified

cat >"$TMP_DIR/facebook-1.json" <<'JSON'
{
  "identity":{"data":{"id":"1001","product":"facebook","name":"Fixture Page"}},
  "pages":[{
    "expect_request":{"product":"facebook","stream":"posts","after":null,"limit":1},
    "response":{"status":200,"observed_at":"2026-07-27T10:00:00Z",
      "data":[{"id":"1001_5001","message":"bounded page post","created_time":"2026-07-01T10:00:00Z"}],
      "meta":{"product":"facebook","stream":"posts","next_cursor":"cursor-one","complete":false}}
  }]
}
JSON
first_result=$("$HELPER" sync-meta --product facebook --base "$BASE" \
	--alias personal:default --connection-id conn_facebook --account-id 1001 \
	--stream posts --profile fixture --budget 3 --page-size 1 \
	--fixture "$TMP_DIR/facebook-1.json")
assert_eq "one Facebook page pauses at the hard request budget" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "identity and one Graph page reserve three units" \
	"$(json_field "$first_result" budget_units)" 3
assert_eq "Facebook content is stored under its own provider identity" \
	"$(sql_value "SELECT provider || ':' || text_content FROM objects WHERE remote_id='1001_5001'")" \
	"facebook:bounded page post"
assert_eq "Facebook curated activity remains explicit unavailable evidence" \
	"$(sql_value "SELECT status FROM coverage_records WHERE provider='facebook' AND stream='curated_activity'")" \
	unavailable

cat >"$TMP_DIR/facebook-2.json" <<'JSON'
{
  "identity":{"data":{"id":"1001","product":"facebook","name":"Fixture Page"}},
  "pages":[{
    "expect_request":{"product":"facebook","stream":"posts","after":"cursor-one","limit":1},
    "response":{"status":200,"observed_at":"2026-07-27T10:01:00Z",
      "data":[{"id":"1001_5002","message":"resumed page post","created_time":"2026-07-02T10:00:00Z"}],
      "meta":{"product":"facebook","stream":"posts","next_cursor":null,"complete":true}}
  }]
}
JSON
second_result=$("$HELPER" sync-meta --product facebook --base "$BASE" \
	--alias personal:default --connection-id conn_facebook --account-id 1001 \
	--stream posts --profile fixture --page-size 1 \
	--fixture "$TMP_DIR/facebook-2.json")
assert_eq "Facebook resumes from its independent opaque cursor" \
	"$(json_field "$second_result" status)" complete
assert_eq "Facebook completion clears only its stream cursor" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_facebook' AND stream='posts'")" \
	"done:1"

facebook_batches=$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='facebook'")
python3 - "$TMP_DIR/facebook-1.json" "$TMP_DIR/facebook-2.json" \
	"$TMP_DIR/facebook-replay.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    first = json.load(source)
with open(sys.argv[2], encoding="utf-8") as source:
    second = json.load(source)
with open(sys.argv[3], "w", encoding="utf-8") as target:
    json.dump({"identity": first["identity"], "pages": first["pages"] + second["pages"]}, target)
PY
"$HELPER" sync-meta --product facebook --base "$BASE" \
	--alias personal:default --connection-id conn_facebook --account-id 1001 \
	--stream posts --profile fixture --budget 5 --page-size 1 \
	--fixture "$TMP_DIR/facebook-replay.json" >/dev/null
assert_eq "exact Facebook page replay is content-addressed and idempotent" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='facebook'")" \
	"$facebook_batches"

cat >"$TMP_DIR/instagram.json" <<'JSON'
{
  "identity":{"data":{"id":"2001","product":"instagram","username":"fixture_ig"}},
  "pages":[{
    "expect_request":{"product":"instagram","stream":"media","after":null},
    "response":{"status":200,"observed_at":"2026-07-27T10:02:00Z",
      "data":[{"id":"6001","caption":"professional media","media_type":"IMAGE","timestamp":"2026-07-03T10:00:00Z"}],
      "meta":{"product":"instagram","stream":"media","next_cursor":null,"complete":true}}
  }]
}
JSON
"$HELPER" sync-meta --product instagram --base "$BASE" \
	--alias personal:default --connection-id conn_instagram --account-id 2001 \
	--stream media --profile fixture --fixture "$TMP_DIR/instagram.json" >/dev/null
assert_eq "Instagram media uses a separate provider identity and checkpoint" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='instagram' AND object_type='media' AND remote_id='6001'")" 1
assert_eq "Instagram relationships remain explicit unavailable evidence" \
	"$(sql_value "SELECT status FROM coverage_records WHERE provider='instagram' AND stream='relationships'")" \
	unavailable

object_id=7001
for stream in posts replies mentions; do
	cat >"$TMP_DIR/threads-${stream}.json" <<JSON
{"identity":{"data":{"id":"3001","product":"threads","username":"fixture_threads"}},
 "pages":[{"expect_request":{"product":"threads","stream":"${stream}","after":null},
 "response":{"status":200,"observed_at":"2026-07-27T10:03:00Z",
 "data":[{"id":"${object_id}","text":"threads ${stream}","timestamp":"2026-07-04T10:00:00Z"}],
 "meta":{"product":"threads","stream":"${stream}","next_cursor":null,"complete":true}}}]}
JSON
	"$HELPER" sync-meta --product threads --base "$BASE" \
		--alias personal:default --connection-id conn_threads --account-id 3001 \
		--stream "$stream" --profile fixture \
		--fixture "$TMP_DIR/threads-${stream}.json" >/dev/null
	object_id=$((object_id + 1))
done
assert_eq "Threads posts, replies, and mentions own independent checkpoints" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_threads' AND backfill_complete=1")" 3
assert_eq "observed Threads mentions do not fabricate an authored activity" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='threads' AND activity_type='account_mentioned'")" 0
assert_eq "observed Threads mentions are not attributed to the selected account" \
	"$(sql_value "SELECT coalesce(account_remote_id,'none') || ':' || evidence_class FROM objects WHERE provider='threads' AND remote_id='7003'")" \
	"none:observed"
assert_eq "Threads relationship coverage remains explicit" \
	"$(sql_value "SELECT status FROM coverage_records WHERE provider='threads' AND stream='relationships'")" \
	unavailable

cursor_before=$(sql_value "SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_facebook' AND stream='posts'")
cat >"$TMP_DIR/facebook-rate.json" <<'JSON'
{"identity":{"data":{"id":"1001","product":"facebook"}},
 "pages":[{"status":429,"observed_at":"2026-07-27T10:04:00Z","retry_after":1785232800}]}
JSON
rate_result=$("$HELPER" sync-meta --product facebook --base "$BASE" \
	--alias personal:default --connection-id conn_facebook --account-id 1001 \
	--stream posts --profile fixture --fixture "$TMP_DIR/facebook-rate.json")
assert_eq "terminal Meta rate limits are sanitized" \
	"$(json_field "$rate_result" failure_class)" rate_limit
assert_eq "terminal Meta failures preserve the prior checkpoint" \
	"$(sql_value "SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_facebook' AND stream='posts'")" \
	"$cursor_before"

cat >"$TMP_DIR/facebook-credential.json" <<'JSON'
{"identity":{"data":{"id":"1001","product":"facebook"}},
 "pages":[{"status":200,"observed_at":"2026-07-27T10:05:00Z",
 "data":[{"id":"5999","access_token":"must-not-persist"}],
 "meta":{"product":"facebook","stream":"posts","next_cursor":null,"complete":true}}]}
JSON
raw_before_credential=$(raw_count facebook)
expect_sync_failure "credential-shaped Meta data is rejected" facebook 1001 posts \
	"$TMP_DIR/facebook-credential.json"
assert_eq "credential rejection creates no Facebook raw evidence" \
	"$(raw_count facebook)" "$raw_before_credential"

cat >"$TMP_DIR/facebook-wrong-account.json" <<'JSON'
{"identity":{"data":{"id":"1999","product":"facebook"}},"pages":[]}
JSON
raw_before_mismatch=$(raw_count facebook)
expect_sync_failure "Meta account rebinding fails before collection" facebook 1001 posts \
	"$TMP_DIR/facebook-wrong-account.json"
assert_eq "identity mismatch creates no Facebook raw evidence" \
	"$(raw_count facebook)" "$raw_before_mismatch"

python3 - "$ROOT" "$SCRIPT_DIR/../scripts" <<'PY'
import os
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from _knowledge_social_collect import (
    CollectionContext, ConnectionConfig, CursorState, PageCheckpoint, SuccessfulPage,
)
from _knowledge_social_collect_persist import persist_page
from _knowledge_social_lease import (
    RunLeaseRequest, SocialLeaseLostError, acquire_run_lease, release_run_lease,
)
from _knowledge_social_meta import PRODUCTS

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_meta_fence", "posts", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_meta_fence", "posts", "new_runner", "sync", 10),
    now_epoch=9001,
)
context = CollectionContext(
    root,
    "conn_meta_fence",
    {"id": "4001", "product": "facebook"},
    "posts",
    "none",
    ConnectionConfig(("posts",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    PRODUCTS["facebook"].streams["posts"],
    old,
    "facebook",
)
archive = {
    "provider": "facebook",
    "connection_id": "conn_meta_fence",
    "remote_account_id": "4001",
    "exported_at": "2026-07-27T10:06:00Z",
    "enabled_streams": ["posts"],
    "policy": {"media_hydration": "none"},
    "accounts": [], "objects": [], "activities": [], "media": [], "coverage": [],
}
page = SuccessfulPage(
    {
        "status": 200,
        "observed_at": archive["exported_at"],
        "data": [],
        "meta": {"product": "facebook", "stream": "posts"},
    },
    '{"product":"facebook","stream":"posts"}',
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
    raise SystemExit("stale Meta collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    cursor = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_meta_fence'"
    ).fetchone()[0]
assert cursor == 0
release_run_lease(root, new)
PY
assert_eq "stale Meta lease cannot commit evidence or a cursor" verified verified

mkdir -p "$TMP_DIR/fake-meta"
cat >"$TMP_DIR/fake-meta/sitecustomize.py" <<'PY'
import json
import os
from pathlib import Path
from urllib.parse import parse_qs, urlparse
import urllib.request


class Response:
    status = 200

    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, _limit):
        return self.payload


def fake_urlopen(request, timeout):
    parsed = urlparse(request.full_url)
    query = parse_qs(parsed.query)
    path = parsed.path
    is_page = path.endswith("/4001/posts")
    log_path = Path(os.environ["META_READ_LOG"])
    headers = {key.lower(): value for key, value in request.header_items()}
    row = {
        "kind": "page" if is_page else "identity",
        "host": parsed.hostname,
        "path": path,
        "method": request.get_method(),
        "fields": query.get("fields", [None])[0],
        "limit": query.get("limit", [None])[0],
        "bearer": headers.get("authorization", "").startswith("Bearer "),
        "selected_secret": "META_FIXTURE_FACEBOOK_ACCESS_TOKEN" in os.environ,
        "instagram_secret": "META_FIXTURE_INSTAGRAM_ACCESS_TOKEN" in os.environ,
        "threads_secret": "META_FIXTURE_THREADS_ACCESS_TOKEN" in os.environ,
        "unrelated_secret": "UNRELATED_PROVIDER_TOKEN" in os.environ,
        "timeout": timeout,
    }
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")
    if path.endswith("/4001"):
        calls = sum(
            json.loads(line)["kind"] == "identity"
            for line in log_path.read_text(encoding="utf-8").splitlines()
        )
        rebound = log_path.name == "meta-rebind.log" and calls > 1
        return Response({
            "id": "4999" if rebound else "4001",
            "name": "Guarded Page",
            "category": "Fixture",
        })
    if is_page:
        return Response({
            "data": [{
                "id": "4001_8001",
                "message": "guarded live Meta evidence",
                "created_time": "2026-07-27T10:07:00Z",
            }]
        })
    raise RuntimeError("unexpected endpoint")


urllib.request.urlopen = fake_urlopen
PY
: >"$TMP_DIR/meta-read.log"
chmod 0600 "$TMP_DIR/meta-read.log"
live_result=$(
	PYTHONPATH="$TMP_DIR/fake-meta" META_READ_LOG="$TMP_DIR/meta-read.log" \
		META_FIXTURE_FACEBOOK_ACCESS_TOKEN=fixture-token \
		META_FIXTURE_INSTAGRAM_ACCESS_TOKEN=other-product \
		META_FIXTURE_THREADS_ACCESS_TOKEN=other-product \
		UNRELATED_PROVIDER_TOKEN=unrelated \
		"$HELPER" sync-meta --product facebook --base "$BASE" \
		--alias personal:default --connection-id conn_meta_live --account-id 4001 \
		--stream posts --profile fixture --budget 3 --page-size 7
)
assert_eq "guarded live Meta boundary persists one Facebook page" \
	"$(json_field "$live_result" status)" complete
live_guard=$(
	python3 - "$TMP_DIR/meta-read.log" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
identities = [row for row in rows if row["kind"] == "identity"]
pages = [row for row in rows if row["kind"] == "page"]
safe = (
    len(identities) == 2
    and len(pages) == 1
    and pages[0]["limit"] == "7"
    and all(row["host"] == "graph.facebook.com" for row in rows)
    and all(row["method"] == "GET" and row["bearer"] for row in rows)
    and all(row["selected_secret"] for row in rows)
    and all(not row["instagram_secret"] for row in rows)
    and all(not row["threads_secret"] for row in rows)
    and all(not row["unrelated_secret"] for row in rows)
    and all(row["timeout"] == 60 for row in rows)
)
print("bounded-read-only" if safe else "unsafe")
PY
)
assert_eq "live Meta boundary revalidates identity and passes only selected credentials" \
	"$live_guard" bounded-read-only
assert_eq "guarded live Meta evidence reaches the provider-neutral corpus" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='facebook' AND remote_id='4001_8001'")" 1

: >"$TMP_DIR/meta-rebind.log"
chmod 0600 "$TMP_DIR/meta-rebind.log"
raw_before_rebind=$(raw_count facebook)
if PYTHONPATH="$TMP_DIR/fake-meta" META_READ_LOG="$TMP_DIR/meta-rebind.log" \
	META_FIXTURE_FACEBOOK_ACCESS_TOKEN=fixture-token \
	"$HELPER" sync-meta --product facebook --base "$BASE" \
	--alias personal:default --connection-id conn_meta_rebind --account-id 4001 \
	--stream posts --profile fixture --budget 3 --page-size 7 \
	>/dev/null 2>&1; then
	rebind_result=accepted
else
	rebind_result=rejected
fi
assert_eq "live Meta boundary rejects account rebinding before the stream read" \
	"$rebind_result" rejected
assert_eq "per-page Meta identity mismatch creates no raw evidence" \
	"$(raw_count facebook)" "$raw_before_rebind"

assert_eq "each Meta product persists a distinct account identity" \
	"$(sql_value "SELECT count(DISTINCT provider) FROM accounts WHERE provider IN ('facebook','instagram','threads')")" 3

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
