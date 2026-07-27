#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-linkedin.sh — LinkedIn Member Snapshot collector tests

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
	python3 - "$ROOT/sources/social/raw/linkedin" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

expect_sync_failure() {
	local description="$1"
	local fixture="$2"
	local stream="$3"
	if "$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
		--connection-id conn_linkedin --account-id member42 \
		--stream "$stream" --profile fixture --fixture "$fixture" \
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
	local fixture="${TMP_DIR}/${name}.json"
	python3 - "$fixture" "$status" <<'PY'
import json
import sys

status = int(sys.argv[2])
page = {"status": status, "observed_at": "2026-07-27T10:10:00Z"}
if status == 429:
    page["retry_after"] = 1785232800
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump({"identity": {"data": {"id": "member42"}}, "pages": [page]}, target)
PY
	local result=""
	result=$("$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
		--connection-id conn_linkedin --account-id member42 \
		--stream authored_posts --profile fixture --fixture "$fixture")
	local expected_status="failed"
	[[ "$status" == "429" ]] && expected_status="rate_limited"
	assert_eq "LinkedIn ${status} response is terminal" \
		"$(json_field "$result" status)" "$expected_status"
	assert_eq "LinkedIn ${status} response is sanitized" \
		"$(json_field "$result" failure_class)" "$expected_failure"
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'LinkedIn social collector tests\n'

help_output=$("$HELPER" help)
if [[ "$help_output" == *"eligible EEA or Swiss"* && "$help_output" == *"sync-linkedin"* ]]; then
	assert_eq "LinkedIn help exposes the region-gated snapshot route" advertised advertised
else
	assert_eq "LinkedIn help exposes the region-gated snapshot route" missing advertised
fi

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import importlib.util
import json
import sys
from email.message import Message
from io import BytesIO
from pathlib import Path
from urllib.error import HTTPError

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))
from _knowledge_social_linkedin import API_VERSION, STREAMS
from _knowledge_social_linkedin_contract import ApiResult, snapshot_page
from _knowledge_social_linkedin_provider import (
    API_BASE, NO_DATA_MESSAGE, READ_ENDPOINTS, _api, _http_exports,
)

expected = {
    "authored_posts": "MEMBER_SHARE_INFO",
    "authored_articles": "ARTICLES",
    "comments": "ALL_COMMENTS",
    "reactions": "ALL_LIKES",
    "saved_items": "ACTOR_SAVE_ITEM",
    "messages": "INBOX",
    "following": "MEMBER_FOLLOWING",
    "connections": "CONNECTIONS",
    "company_follows": "COMPANY_FOLLOWS",
    "groups": "GROUPS",
}
assert {name: spec.snapshot_domain for name, spec in STREAMS.items()} == expected
assert API_VERSION == "202312"
assert API_BASE == "https://api.linkedin.com/rest"
assert READ_ENDPOINTS == {"memberAuthorizations", "memberSnapshotData"}
assert callable(_http_exports())

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("*knowledge_social_linkedin*.py"))
]
assert all("linkedin-automation" not in source for source in sources)
trees = [ast.parse(source) for source in sources]
imports = {
    alias.name
    for tree in trees
    for node in ast.walk(tree)
    if isinstance(node, (ast.Import, ast.ImportFrom))
    for alias in (
        node.names if isinstance(node, ast.Import) else [ast.alias(node.module or "")]
    )
}
assert all("linkedin_automation" not in name for name in imports)
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


def no_data_opener(request, timeout):
    assert request.get_method() == "GET"
    assert timeout == 60
    body = json.dumps({"message": NO_DATA_MESSAGE}).encode()
    raise HTTPError(request.full_url, 404, "Not Found", Message(), BytesIO(body))


result = _api(
    "test-token",
    no_data_opener,
    "memberSnapshotData",
    {"q": "criteria", "domain": "ARTICLES", "start": "1", "count": "10"},
)
assert result.no_data is True
page = snapshot_page(result, "ARTICLES", 1, 10)
assert page["status"] == 200 and page["meta"]["complete"] is True

successful = ApiResult(200, {
    "paging": {"start": 1, "count": 10, "links": [], "total": 1},
    "elements": [{"snapshotDomain": "ARTICLES", "snapshotData": [{"id": "one"}]}],
})
partial = snapshot_page(successful, "ARTICLES", 1, 10)
assert partial["meta"]["complete"] is False
assert partial["meta"]["next_start"] == 2


def unauthorized_no_data_opener(request, timeout):
    assert request.get_method() == "GET"
    assert timeout == 60
    body = json.dumps({"message": NO_DATA_MESSAGE}).encode()
    raise HTTPError(request.full_url, 401, "Unauthorized", Message(), BytesIO(body))


unauthorized = _api(
    "test-token",
    unauthorized_no_data_opener,
    "memberSnapshotData",
    {"q": "criteria", "domain": "ARTICLES", "start": "1", "count": "10"},
)
assert unauthorized.no_data is False
assert snapshot_page(unauthorized, "ARTICLES", 1, 10)["status"] == 401
PY
assert_eq "stream registry, GET-only transport, and status-bound no-data completion are guarded" \
	verified verified

cat >"$TMP_DIR/minimum-budget.json" <<'JSON'
{"identity":{"data":{"id":"member42"}},"pages":[]}
JSON
for budget in 1 2; do
	if "$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
		--connection-id "conn_budget_${budget}" --account-id member42 \
		--stream authored_posts --profile fixture \
		--fixture "$TMP_DIR/minimum-budget.json" --budget "$budget" \
		>/dev/null 2>&1; then
		assert_eq "LinkedIn budget ${budget} is rejected" accepted rejected
	else
		assert_eq "LinkedIn budget ${budget} is rejected" rejected rejected
	fi
done

cat >"$TMP_DIR/posts-1.json" <<'JSON'
{
  "identity":{"data":{"id":"member42"}},
  "pages":[{
    "expect_request":{"domain":"MEMBER_SHARE_INFO","start":0,"limit":1},
    "response":{"status":200,"observed_at":"2026-07-27T10:00:00Z",
      "data":[{"Post Link":"private-post-reference-1","ShareCommentary":"bounded knowledge"}],
      "meta":{"domain":"MEMBER_SHARE_INFO","next_start":1,"complete":false,"snapshot":true}}
  }]
}
JSON
first_result=$("$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
	--connection-id conn_linkedin --account-id member42 \
	--stream authored_posts --profile fixture --budget 3 --page-size 1 \
	--fixture "$TMP_DIR/posts-1.json")
assert_eq "one LinkedIn page pauses at the hard request budget" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "identity and one guarded page reserve three units" \
	"$(json_field "$first_result" budget_units)" 3
assert_eq "partial LinkedIn snapshot advances only its stream cursor" \
	"$(sql_value "SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_linkedin' AND stream='authored_posts'")" 0
assert_eq "snapshot records use content-addressed stable identities" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='linkedin' AND object_type='post' AND remote_id LIKE 'li_snapshot_%'")" 1
assert_eq "normalized rows retain provenance but not undocumented private fields" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='linkedin' AND provider_json LIKE '%linkedin_member_snapshot_api%' AND provider_json NOT LIKE '%bounded knowledge%'")" 1
assert_eq "LinkedIn consent and deletion obligations are durable coverage" \
	"$(sql_value "SELECT retention_limit || ':' || status FROM coverage_records WHERE connection_id='conn_linkedin' AND stream='authored_posts'")" \
	"member_consent_and_delete_on_request_or_linked_account_closure:paused"
assert_eq "newsletter subscriptions remain explicit unavailable evidence" \
	"$(sql_value "SELECT status FROM coverage_records WHERE connection_id='conn_linkedin' AND stream='newsletter_subscriptions'")" unavailable

cat >"$TMP_DIR/posts-2.json" <<'JSON'
{
  "identity":{"data":{"id":"member42"}},
  "pages":[{
    "expect_request":{"domain":"MEMBER_SHARE_INFO","start":1},
    "response":{"status":200,"observed_at":"2026-07-27T10:01:00Z",
      "data":[{"Post Link":"private-post-reference-2","ShareCommentary":"resumed evidence"}],
      "meta":{"domain":"MEMBER_SHARE_INFO","next_start":null,"complete":true,"snapshot":true}}
  }]
}
JSON
second_result=$("$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
	--connection-id conn_linkedin --account-id member42 \
	--stream authored_posts --profile fixture --page-size 1 \
	--fixture "$TMP_DIR/posts-2.json")
assert_eq "LinkedIn snapshot resumes from its independent page cursor" \
	"$(json_field "$second_result" status)" complete
assert_eq "snapshot exhaustion clears the cursor and marks backfill complete" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_linkedin' AND stream='authored_posts'")" \
	"done:1"

post_batches=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_linkedin' AND stream='authored_posts'")
python3 - "$TMP_DIR/posts-1.json" "$TMP_DIR/posts-2.json" \
	"$TMP_DIR/posts-replay.json" <<'PY'
import json
import sys

first = json.load(open(sys.argv[1], encoding="utf-8"))
second = json.load(open(sys.argv[2], encoding="utf-8"))
with open(sys.argv[3], "w", encoding="utf-8") as target:
    json.dump({"identity": first["identity"], "pages": first["pages"] + second["pages"]}, target)
PY
"$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
	--connection-id conn_linkedin --account-id member42 \
	--stream authored_posts --profile fixture --budget 5 --page-size 1 \
	--fixture "$TMP_DIR/posts-replay.json" >/dev/null
assert_eq "exact LinkedIn snapshot replay is content-addressed and idempotent" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_linkedin' AND stream='authored_posts'")" \
	"$post_batches"
assert_eq "snapshot replay preserves exactly two normalized post records" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='linkedin' AND object_type='post'")" 2

cat >"$TMP_DIR/posts-other-account.json" <<'JSON'
{
  "identity":{"data":{"id":"member43"}},
  "pages":[{"status":200,"observed_at":"2026-07-27T10:01:30Z",
    "data":[{"Post Link":"private-post-reference-1","ShareCommentary":"bounded knowledge"}],
    "meta":{"domain":"MEMBER_SHARE_INFO","next_start":null,"complete":true,"snapshot":true}}]
}
JSON
"$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
	--connection-id conn_linkedin_other --account-id member43 \
	--stream authored_posts --profile fixture \
	--fixture "$TMP_DIR/posts-other-account.json" >/dev/null
assert_eq "content-addressed LinkedIn records remain scoped to the verified account" \
	"$(sql_value "SELECT count(DISTINCT remote_id) || ':' || count(DISTINCT account_remote_id) FROM objects WHERE provider='linkedin' AND object_type='post'")" \
	"3:2"

cat >"$TMP_DIR/messages.json" <<'JSON'
{
  "identity":{"data":{"id":"member42"}},
  "pages":[{"status":200,"observed_at":"2026-07-27T10:02:00Z",
    "data":[{"Conversation ID":"conversation42","Content":"private message"}],
    "meta":{"domain":"INBOX","next_start":null,"complete":true,"snapshot":true}}]
}
JSON
"$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
	--connection-id conn_linkedin --account-id member42 \
	--stream messages --profile fixture --fixture "$TMP_DIR/messages.json" >/dev/null
assert_eq "message snapshots keep an independent complete checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_linkedin' AND stream IN ('authored_posts','messages') AND backfill_complete=1")" 2

cursor_before=$(sql_value "SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_linkedin' AND stream='authored_posts'")
run_terminal_fixture quota 429 rate_limit
run_terminal_fixture unauthorized 401 authorization
run_terminal_fixture forbidden 403 authorization
run_terminal_fixture missing 404 unavailable
run_terminal_fixture provider 500 provider
assert_eq "terminal LinkedIn failures preserve the prior checkpoint" \
	"$(sql_value "SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_linkedin' AND stream='authored_posts'")" \
	"$cursor_before"

batch_count=$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='linkedin'")
cat >"$TMP_DIR/malformed.json" <<'JSON'
{"identity":{"data":{"id":"member42"}},"pages":[{"status":200,"observed_at":"2026-07-27T10:03:00Z","data":{},"meta":{"domain":"ARTICLES","next_start":null,"complete":true,"snapshot":true}}]}
JSON
expect_sync_failure "malformed LinkedIn snapshots fail before persistence" \
	"$TMP_DIR/malformed.json" authored_articles
assert_eq "malformed LinkedIn data advances no batch" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='linkedin'")" "$batch_count"

cat >"$TMP_DIR/credential.json" <<'JSON'
{"identity":{"data":{"id":"member42"}},"pages":[{"status":200,"observed_at":"2026-07-27T10:04:00Z","data":[{"access_token":"must-not-persist"}],"meta":{"domain":"ARTICLES","next_start":null,"complete":true,"snapshot":true}}]}
JSON
expect_sync_failure "credential-shaped LinkedIn snapshots are rejected" \
	"$TMP_DIR/credential.json" authored_articles
assert_eq "credential rejection creates no raw evidence" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='linkedin'")" "$batch_count"

cat >"$TMP_DIR/wrong-account.json" <<'JSON'
{"identity":{"data":{"id":"other_member"}},"pages":[]}
JSON
raw_before_mismatch=$(raw_count)
expect_sync_failure "selected LinkedIn member mismatch fails before collection" \
	"$TMP_DIR/wrong-account.json" authored_articles
assert_eq "identity mismatch creates no LinkedIn raw evidence" \
	"$(raw_count)" "$raw_before_mismatch"

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
from _knowledge_social_linkedin import STREAMS

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_linkedin_fence", "connections", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_linkedin_fence", "connections", "new_runner", "sync", 10),
    now_epoch=9001,
)
context = CollectionContext(
    root,
    "conn_linkedin_fence",
    {"id": "member42"},
    "connections",
    "none",
    ConnectionConfig(("connections",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["connections"],
    old,
    "linkedin",
)
archive = {
    "provider": "linkedin",
    "connection_id": "conn_linkedin_fence",
    "remote_account_id": "member42",
    "exported_at": "2026-07-27T10:05:00Z",
    "enabled_streams": ["connections"],
    "policy": {"media_hydration": "none"},
    "accounts": [], "objects": [], "activities": [], "media": [], "coverage": [],
}
page = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"connections"}',
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
    raise SystemExit("stale LinkedIn collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    cursor = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_linkedin_fence'"
    ).fetchone()[0]
assert cursor == 0
release_run_lease(root, new)
PY
assert_eq "stale LinkedIn lease cannot commit evidence or a cursor" verified verified

mkdir -p "$TMP_DIR/fake-linkedin"
cat >"$TMP_DIR/fake-linkedin/sitecustomize.py" <<'PY'
import json
import os
from email.message import Message
from io import BytesIO
from pathlib import Path
from urllib.error import HTTPError
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
    endpoint = parsed.path.rsplit("/", 1)[-1]
    query = parse_qs(parsed.query)
    log_path = Path(os.environ["LINKEDIN_READ_LOG"])
    headers = {key.lower(): value for key, value in request.header_items()}
    row = {
        "endpoint": endpoint,
        "method": request.get_method(),
        "count": query.get("count", [None])[0],
        "start": query.get("start", [None])[0],
        "bearer": headers.get("authorization", "").startswith("Bearer "),
        "version": headers.get("linkedin-version"),
        "unrelated_secret": "UNRELATED_PROVIDER_TOKEN" in os.environ,
        "timeout": timeout,
    }
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")
    if endpoint == "memberAuthorizations":
        calls = sum(
            json.loads(line)["endpoint"] == endpoint
            for line in log_path.read_text(encoding="utf-8").splitlines()
        )
        rebound = log_path.name == "linkedin-rebind.log" and calls > 1
        member = "other_member" if rebound else "live_member42"
        return Response({"elements": [{
            "memberComplianceAuthorizationKey": {
                "developerApplication": "urn:li:developerApplication:fixture",
                "member": f"urn:li:person:{member}",
            },
            "memberComplianceScopes": ["DMA"],
        }]})
    if endpoint == "memberSnapshotData":
        domain = query["domain"][0]
        if query.get("start", ["0"])[0] != "0":
            body = json.dumps({"message": "No data found for this memberId"}).encode()
            raise HTTPError(
                request.full_url, 404, "Not Found", Message(), BytesIO(body)
            )
        return Response({
            "paging": {"start": 0, "count": int(query["count"][0]), "links": []},
            "elements": [{
                "snapshotDomain": domain,
                "snapshotData": [{"Synthetic Label": "guarded live evidence"}],
            }],
        })
    raise RuntimeError("unexpected endpoint")


urllib.request.urlopen = fake_urlopen
PY
: >"$TMP_DIR/linkedin-read.log"
chmod 0600 "$TMP_DIR/linkedin-read.log"
live_result=$(
	PYTHONPATH="$TMP_DIR/fake-linkedin" LINKEDIN_READ_LOG="$TMP_DIR/linkedin-read.log" \
		LINKEDIN_FIXTURE_ACCESS_TOKEN=fixture-token UNRELATED_PROVIDER_TOKEN=unrelated \
		"$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
		--connection-id conn_linkedin_live --account-id live_member42 \
		--stream authored_articles --profile fixture --budget 5 --page-size 7
)
assert_eq "guarded live LinkedIn boundary persists one snapshot page" \
	"$(json_field "$live_result" status)" complete
live_guard=$(
	python3 - "$TMP_DIR/linkedin-read.log" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
identities = [row for row in rows if row["endpoint"] == "memberAuthorizations"]
pages = [row for row in rows if row["endpoint"] == "memberSnapshotData"]
safe = (
    len(identities) == 3
    and len(pages) == 2
    and pages[0]["count"] == "7"
    and [row["start"] for row in pages] == ["0", "1"]
    and all(row["method"] == "GET" and row["bearer"] for row in rows)
    and all(row["version"] == "202312" for row in rows)
    and all(not row["unrelated_secret"] for row in rows)
)
print("bounded-read-only" if safe else "unsafe")
PY
)
assert_eq "live boundary revalidates identity and passes only selected credentials" \
	"$live_guard" bounded-read-only

: >"$TMP_DIR/linkedin-rebind.log"
chmod 0600 "$TMP_DIR/linkedin-rebind.log"
raw_before_rebind=$(raw_count)
if PYTHONPATH="$TMP_DIR/fake-linkedin" LINKEDIN_READ_LOG="$TMP_DIR/linkedin-rebind.log" \
	LINKEDIN_FIXTURE_ACCESS_TOKEN=fixture-token \
	"$HELPER" sync-linkedin --base "$BASE" --alias personal:default \
	--connection-id conn_linkedin_rebind --account-id live_member42 \
	--stream authored_articles --profile fixture --budget 3 --page-size 7 \
	>/dev/null 2>&1; then
	rebind_result=accepted
else
	rebind_result=rejected
fi
assert_eq "live boundary rejects LinkedIn account rebinding before snapshot read" \
	"$rebind_result" rejected
assert_eq "per-page LinkedIn identity mismatch creates no raw evidence" \
	"$(raw_count)" "$raw_before_rebind"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
