#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-patreon.sh — bounded Patreon creator collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/../scripts"
COLLECTOR="${SCRIPTS}/knowledge_social_patreon.py"
CORPUS_HELPER="${SCRIPTS}/knowledge-corpus-helper.sh"
SOCIAL_HELPER="${SCRIPTS}/knowledge-social-helper.sh"
DOC="${SCRIPT_DIR}/../content/social-patreon.md"
MATRIX="${SCRIPT_DIR}/../aidevops/knowledge-plane/06-social-provider-capabilities.md"
OPERATIONS="${SCRIPT_DIR}/../aidevops/knowledge-plane/05-social-operations.md"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
ACCOUNT_ID="creator_123"
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

raw_text() {
	python3 - "$ROOT/sources/social/raw/patreon" <<'PY'
import gzip
import sys
from pathlib import Path
root = Path(sys.argv[1])
print("\n".join(gzip.open(path, "rt", encoding="utf-8").read() for path in root.rglob("*.json.gz")))
PY
	return 0
}

run_fixture() {
	local fixture="$1"
	local connection="$2"
	local stream="$3"
	shift 3
	if python3 "$COLLECTOR" --base "$BASE" --alias personal:default \
		--connection-id "$connection" --account-id "$ACCOUNT_ID" \
		--stream "$stream" --profile fixture --fixture "$fixture" "$@"; then
		return 0
	fi
	return 1
}

run_terminal_case() {
	local name="$1"
	local status="$2"
	local expected_failure="$3"
	local fixture="${TMP_DIR}/terminal-${name}.json"
	python3 - "$fixture" "$ACCOUNT_ID" "$status" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "provider_account_id": sys.argv[2], "role": "creator", "is_creator": True,
        "campaign_ids": ["101", "202"], "member_data_authorized": False,
    }},
    "pages": [{"status": int(sys.argv[3]), "observed_at": "2026-08-02T21:03:00Z"}],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	local result=""
	result=$(run_fixture "$fixture" "conn_terminal_${name}" posts)
	assert_eq "${status} response is terminal without checkpoint advancement" \
		"$(json_field "$result" failure_class):$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_terminal_${name}'")" \
		"${expected_failure}:0"
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Patreon social collector tests\n'

python3 - "$SCRIPTS" <<'PY'
import ast
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_patreon import PageRequest, STREAMS, page_checkpoint, page_request
from _knowledge_social_patreon_contract import benefit_records, membership_records
from _knowledge_social_patreon_provider import (
    ApiResult, Profile, PatreonReadProviderError, _dispatch,
)
from knowledge_social_patreon import _enforce_rate_budget

assert set(STREAMS) == {"account", "campaigns", "posts", "memberships", "benefits"}
profile = Profile(
    "fixture-token", ("101", "202"),
    frozenset({"identity", "campaigns", "campaigns.posts", "campaigns.members"}),
    b"p" * 32, "membership-services",
)
calls = []

def api(_profile, path, params):
    calls.append((path, params))
    if path == "/identity":
        return ApiResult(200, {"data": {
            "type": "user", "id": "creator_123", "attributes": {"is_creator": True},
        }})
    if path == "/campaigns":
        return ApiResult(200, {"data": [
            {"type": "campaign", "id": "101"},
            {"type": "campaign", "id": "202"},
        ], "meta": {"pagination": {"cursors": {"next": None}}}})
    if path == "/campaigns/101/posts":
        return ApiResult(200, {"data": [{
            "type": "post", "id": "post-1",
            "attributes": {"title": "Creator update", "content": "Bounded content", "is_public": False},
            "relationships": {"campaign": {"data": {"type": "campaign", "id": "101"}}},
        }], "meta": {"pagination": {"cursors": {"next": "cursor-a"}}}})
    raise AssertionError(path)

request = PageRequest("posts", "creator_123", ("101", "202"), "101", None, (), 100, True)
page = _dispatch(request.payload(), profile, api)
assert page["data"][0]["remote_id"] == "post_post-1"
assert page["meta"]["next_cursor"] == "cursor-a"
post_params = calls[-1][1]
assert "email" not in json.dumps(post_params).lower()
assert post_params["json-api-use-default-includes"] == "false"

def wrong_campaign_api(_profile, path, _params):
    if path == "/identity":
        return ApiResult(200, {"data": {
            "type": "user", "id": "creator_123", "attributes": {"is_creator": True},
        }})
    return ApiResult(200, {"data": [{"type": "campaign", "id": "999"}]})

try:
    _dispatch({"action": "identity", "account_id": "creator_123"}, profile, wrong_campaign_api)
except PatreonReadProviderError:
    pass
else:
    raise SystemExit("unowned Patreon campaign was accepted")

def paged_campaign_api(_profile, path, _params):
    if path == "/identity":
        return ApiResult(200, {"data": {
            "type": "user", "id": "creator_123", "attributes": {"is_creator": True},
        }})
    return ApiResult(200, {
        "data": [{"type": "campaign", "id": "101"}],
        "meta": {"pagination": {"cursors": {"next": "more-owned-campaigns"}}},
    })

try:
    _dispatch({"action": "identity", "account_id": "creator_123"}, profile, paged_campaign_api)
except PatreonReadProviderError as error:
    assert "bounded identity page" in str(error)
else:
    raise SystemExit("incomplete Patreon campaign ownership page was accepted")

malformed_benefits = {
    "data": {
        "type": "campaign", "id": "101", "attributes": {"name": "Campaign"},
        "relationships": {
            "benefits": {"data": [{"type": "benefit", "id": "b1"}]},
            "tiers": {"data": [{"type": "tier", "id": "t1"}]},
        },
    },
    "included": [
        {"type": "benefit", "id": "b1", "attributes": {"title": "Benefit"}},
        {"type": "tier", "id": "wrong-tier", "attributes": {"title": "Tier"}},
    ],
}
try:
    benefit_records(malformed_benefits, "101")
except Exception:
    pass
else:
    raise SystemExit("malformed Patreon includes were accepted")

member_payload = {
    "data": [{
        "type": "member", "id": "direct-member-id",
        "attributes": {"patron_status": "active_patron", "currently_entitled_amount_cents": 500},
        "relationships": {"currently_entitled_tiers": {"data": [{"type": "tier", "id": "t1"}]}},
    }],
    "included": [{"type": "tier", "id": "t1", "attributes": {"title": "Supporter"}}],
    "meta": {"pagination": {"cursors": {"next": None}}},
}
members, cursor = membership_records(b"p" * 32, member_payload, "101")
assert cursor is None and members[0]["remote_id"].startswith("member_")
assert "direct-member-id" not in json.dumps(members)
member_payload["data"][0]["attributes"]["full_name"] = "Must not persist"
try:
    membership_records(b"p" * 32, member_payload, "101")
except Exception:
    pass
else:
    raise SystemExit("unrequested Patreon member PII was accepted")

account = {
    "id": "creator_123", "provider_account_id": "creator_123",
    "campaign_ids": ["101", "202"], "member_data_authorized": False,
}
first = page_request("posts", account, CursorState(None, None, False), 100)
checkpoint, complete = page_checkpoint({
    "data": [],
    "meta": {"stream": "posts", "campaign_id": "101", "next_cursor": "loop-a", "next_campaign_id": None, "complete": False},
}, CursorState(None, None, False), first)
assert not complete and checkpoint.next_cursor
resumed = page_request("posts", account, CursorState(checkpoint.next_cursor, None, False), 100)
try:
    page_checkpoint({
        "data": [],
        "meta": {"stream": "posts", "campaign_id": "101", "next_cursor": "loop-a", "next_campaign_id": None, "complete": False},
    }, CursorState(checkpoint.next_cursor, None, False), resumed)
except Exception:
    pass
else:
    raise SystemExit("Patreon pagination cursor loop was accepted")

try:
    _enforce_rate_budget(["--budget", "100"])
except Exception:
    pass
else:
    raise SystemExit("Patreon invocation exceeded the documented token rate budget")

sources = [path.read_text(encoding="utf-8") for path in scripts.glob("*knowledge_social_patreon*.py")]
trees = [ast.parse(source) for source in sources]
request_calls = [
    node for tree in trees for node in ast.walk(tree)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "Request"
]
assert len(request_calls) == 1
methods = [
    keyword.value.value for keyword in request_calls[0].keywords
    if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
]
assert methods == ["GET"]
for forbidden in (
    'method="POST"', 'method="PUT"', 'method="PATCH"', 'method="DELETE"',
    "playwright", "selenium", "_knowledge_social_outbound", "/webhooks", "/lives",
):
    assert all(forbidden not in source for source in sources)
PY
assert_eq "identity, ownership, fields, includes, minimization, cursors, and GET-only AST are guarded" verified verified

helper_help=$("$SOCIAL_HELPER" help)
sync_help=$("$SOCIAL_HELPER" sync-patreon --help 2>&1)
if [[ "$helper_help" == *"sync-patreon"* && "$helper_help" == *"5-99"* &&
	"$sync_help" == *"bounded, read-only Patreon creator stream"* ]]; then
	assert_eq "helper advertises only the bounded Patreon creator route" guarded guarded
else
	assert_eq "helper advertises only the bounded Patreon creator route" missing guarded
fi

registry_resolution=$("$SOCIAL_HELPER" provider-resolve --provider patreon |
	python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["provider"] + ":" + ",".join(data["modes"]))')
assert_eq "registry exposes only Patreon live collection" "$registry_resolution" "patreon:live"

if rg -Fq '| Patreon |' "$MATRIX" &&
	rg -Fq 'Patron-owned memberships' "$DOC" &&
	rg -Fq 'PATREON_<PROFILE>_MEMBER_DATA_PURPOSE=membership-services' "$OPERATIONS"; then
	assert_eq "documentation preserves creator, patron, and member-purpose boundaries" documented documented
else
	assert_eq "documentation preserves creator, patron, and member-purpose boundaries" missing documented
fi

cat >"$TMP_DIR/campaign-first.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","role":"creator","is_creator":true,"campaign_ids":["101","202"],"member_data_authorized":false}},"pages":[{
  "expect_request":{"campaign_id":"101","cursor":null,"limit":100},
  "response":{"status":200,"observed_at":"2026-08-02T20:00:00Z","data":[
    {"kind":"campaign","remote_id":"campaign_101","campaign_id":"101","name":"First Campaign","summary":"Creator campaign knowledge"}],
  "meta":{"stream":"campaigns","campaign_id":"101","next_cursor":null,"next_campaign_id":"202","complete":false}}}]}
JSON
first=$(run_fixture "$TMP_DIR/campaign-first.json" conn_campaigns campaigns --budget 5)
assert_eq "one selected campaign page pauses with a durable campaign cursor" "$(json_field "$first" status)" budget_exhausted
assert_eq "first campaign evidence reaches corpus search" "$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'knowledge'")" 1

cat >"$TMP_DIR/campaign-resume.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","role":"creator","is_creator":true,"campaign_ids":["101","202"],"member_data_authorized":false}},"pages":[{
  "expect_request":{"campaign_id":"202","cursor":null},
  "response":{"status":200,"observed_at":"2026-08-02T20:01:00Z","data":[
    {"kind":"campaign","remote_id":"campaign_202","campaign_id":"202","name":"Second Campaign"}],
  "meta":{"stream":"campaigns","campaign_id":"202","next_cursor":null,"next_campaign_id":null,"complete":true}}}]}
JSON
second=$(run_fixture "$TMP_DIR/campaign-resume.json" conn_campaigns campaigns)
assert_eq "explicit campaign sequence resumes and completes" "$(json_field "$second" status)" complete
assert_eq "only selected creator campaigns persist" "$(sql_value "SELECT count(*) FROM objects WHERE provider='patreon' AND object_type='campaign'")" 2

cat >"$TMP_DIR/posts-first.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","role":"creator","is_creator":true,"campaign_ids":["101","202"],"member_data_authorized":false}},"pages":[{
  "expect_request":{"campaign_id":"101","cursor":null},
  "response":{"status":200,"observed_at":"2026-08-02T20:02:00Z","data":[
    {"kind":"post","remote_id":"post_1","campaign_id":"101","title":"Private update","content":"Fixture-proven Patreon post","is_public":false,"published_at":"2026-08-01T10:00:00Z"}],
  "meta":{"stream":"posts","campaign_id":"101","next_cursor":"cursor-a","next_campaign_id":null,"complete":false}}}]}
JSON
post_first=$(run_fixture "$TMP_DIR/posts-first.json" conn_posts posts --budget 5)
assert_eq "opaque post cursor pauses independently" "$(json_field "$post_first" status)" budget_exhausted

cat >"$TMP_DIR/posts-resume.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","role":"creator","is_creator":true,"campaign_ids":["101","202"],"member_data_authorized":false}},"pages":[{
  "expect_request":{"campaign_id":"101","cursor":"cursor-a"},
  "response":{"status":200,"observed_at":"2026-08-02T20:03:00Z","data":[],
  "meta":{"stream":"posts","campaign_id":"101","next_cursor":null,"next_campaign_id":"202","complete":false}}},{
  "expect_request":{"campaign_id":"202","cursor":null},
  "response":{"status":200,"observed_at":"2026-08-02T20:04:00Z","data":[],
  "meta":{"stream":"posts","campaign_id":"202","next_cursor":null,"next_campaign_id":null,"complete":true}}}]}
JSON
post_second=$(run_fixture "$TMP_DIR/posts-resume.json" conn_posts posts --budget 8)
assert_eq "post cursor and campaign fanout complete atomically" "$(json_field "$post_second" status)" complete
assert_eq "post text is searchable" "$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'Patreon'")" 1

cat >"$TMP_DIR/membership.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","role":"creator","is_creator":true,"campaign_ids":["101","202"],"member_data_authorized":true}},"pages":[{
  "response":{"status":200,"observed_at":"2026-08-02T20:05:00Z","data":[
    {"kind":"membership","remote_id":"member_0123456789abcdef0123456789abcdef","campaign_id":"101","currently_entitled_amount_cents":500,"patron_status":"active_patron","tier_ids":["tier_101_t1"]}],
  "meta":{"stream":"memberships","campaign_id":"101","next_cursor":null,"next_campaign_id":"202","complete":false}}}]}
JSON
membership=$(run_fixture "$TMP_DIR/membership.json" conn_members memberships --budget 5)
assert_eq "purpose-gated minimized membership snapshot persists" "$(json_field "$membership" status)" budget_exhausted
assert_eq "membership evidence is protected business data" \
	"$(sql_value "SELECT evidence_class FROM objects WHERE provider='patreon' AND object_type='membership'")" protected_business
persisted=$(raw_text)
if [[ "$persisted" == *"direct-member-id"* || "$persisted" == *"full_name"* || "$persisted" == *"email"* || "$persisted" == *"address"* ]]; then
	assert_eq "raw membership evidence excludes direct member PII" leaked excluded
else
	assert_eq "raw membership evidence excludes direct member PII" excluded excluded
fi

cat >"$TMP_DIR/mismatch.json" <<'JSON'
{"identity":{"data":{"provider_account_id":"other_creator","role":"creator","is_creator":true,"campaign_ids":["101"],"member_data_authorized":false}},"pages":[]}
JSON
if run_fixture "$TMP_DIR/mismatch.json" conn_mismatch campaigns >/dev/null 2>&1; then
	assert_eq "creator identity mismatch is rejected before persistence" accepted rejected
else
	assert_eq "creator identity mismatch is rejected before persistence" rejected rejected
fi
assert_eq "identity mismatch creates no connection" "$(sql_value "SELECT count(*) FROM connections WHERE connection_id='conn_mismatch'")" 0

cat >"$TMP_DIR/campaign-mismatch.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","role":"creator","is_creator":true,"campaign_ids":["101","202"],"member_data_authorized":false}},"pages":[{
  "status":200,"observed_at":"2026-08-02T20:06:00Z","data":[],
  "meta":{"stream":"posts","campaign_id":"202","next_cursor":null,"next_campaign_id":null,"complete":true}}]}
JSON
if run_fixture "$TMP_DIR/campaign-mismatch.json" conn_campaign_mismatch posts >/dev/null 2>&1; then
	assert_eq "page campaign mismatch is rejected before persistence" accepted rejected
else
	assert_eq "page campaign mismatch is rejected before persistence" rejected rejected
fi
assert_eq "campaign mismatch preserves empty prior state" "$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_campaign_mismatch'")" 0

cat >"$TMP_DIR/credential.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","role":"creator","is_creator":true,"campaign_ids":["101","202"],"member_data_authorized":false}},"pages":[{
  "status":200,"observed_at":"2026-08-02T20:07:00Z","data":[{"kind":"post","remote_id":"post_bad","client_secret":"must-not-persist"}],
  "meta":{"stream":"posts","campaign_id":"101","next_cursor":null,"next_campaign_id":null,"complete":true}}]}
JSON
if run_fixture "$TMP_DIR/credential.json" conn_credential posts >/dev/null 2>&1; then
	assert_eq "credential-shaped provider payload is rejected" accepted rejected
else
	assert_eq "credential-shaped provider payload is rejected" rejected rejected
fi
assert_eq "credential rejection preserves empty prior state" "$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_credential'")" 0

cat >"$TMP_DIR/cursor-loop.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","role":"creator","is_creator":true,"campaign_ids":["101","202"],"member_data_authorized":false}},"pages":[
  {"response":{"status":200,"observed_at":"2026-08-02T20:08:00Z","data":[{"kind":"post","remote_id":"loop_1","campaign_id":"101"}],"meta":{"stream":"posts","campaign_id":"101","next_cursor":"loop-a","next_campaign_id":null,"complete":false}}},
  {"expect_request":{"cursor":"loop-a"},"response":{"status":200,"observed_at":"2026-08-02T20:09:00Z","data":[{"kind":"post","remote_id":"loop_2","campaign_id":"101"}],"meta":{"stream":"posts","campaign_id":"101","next_cursor":"loop-b","next_campaign_id":null,"complete":false}}},
  {"expect_request":{"cursor":"loop-b"},"response":{"status":200,"observed_at":"2026-08-02T20:10:00Z","data":[{"kind":"post","remote_id":"loop_3","campaign_id":"101"}],"meta":{"stream":"posts","campaign_id":"101","next_cursor":"loop-a","next_campaign_id":null,"complete":false}}}
]}
JSON
if run_fixture "$TMP_DIR/cursor-loop.json" conn_loop posts --budget 11 >/dev/null 2>&1; then
	assert_eq "multi-page cursor loop is rejected" accepted rejected
else
	assert_eq "multi-page cursor loop is rejected" rejected rejected
fi
assert_eq "cursor loop preserves the last coherent page and checkpoint" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='patreon' AND remote_id IN ('loop_1','loop_2')")" 2
assert_eq "cursor loop never persists the looping page" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='patreon' AND remote_id='loop_3'")" 0

cat >"$TMP_DIR/rate.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","role":"creator","is_creator":true,"campaign_ids":["101","202"],"member_data_authorized":false}},"pages":[{"status":429,"observed_at":"2026-08-02T20:11:00Z","retry_after":60}]}
JSON
rate=$(run_fixture "$TMP_DIR/rate.json" conn_rate posts)
assert_eq "rate limit pauses without checkpoint advancement" "$(json_field "$rate" failure_class):$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_rate'")" rate_limit:0
run_terminal_case forbidden 403 authorization
run_terminal_case unavailable 404 unavailable
run_terminal_case provider 500 provider

python3 - "$ROOT" "$SCRIPTS" <<'PY'
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
from _knowledge_social_patreon import STREAMS

root = Path(sys.argv[1])
old = acquire_run_lease(
    root, RunLeaseRequest("conn_patreon_fence", "posts", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root, RunLeaseRequest("conn_patreon_fence", "posts", "new_runner", "sync", 10),
    now_epoch=9001,
)
context = CollectionContext(
    root, "conn_patreon_fence",
    {"id": "creator_123", "campaign_ids": ["101"], "member_data_authorized": False},
    "posts", "none", ConnectionConfig(("posts",), {"media_hydration": "none"}),
    CursorState(None, None, False), STREAMS["posts"], old, "patreon",
)
archive = {
    "provider": "patreon", "connection_id": "conn_patreon_fence",
    "remote_account_id": "creator_123", "exported_at": "2026-08-02T20:12:00Z",
    "enabled_streams": ["posts"], "policy": {"media_hydration": "none"},
    "accounts": [], "objects": [], "activities": [], "media": [], "coverage": [],
}
successful = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"posts"}', archive, PageCheckpoint(None, None), True, 3,
)
os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "9001"
try:
    persist_page(context, successful)
except SocialLeaseLostError:
    pass
else:
    raise SystemExit("stale Patreon collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    count = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_patreon_fence'"
    ).fetchone()[0]
assert count == 0
release_run_lease(root, new)
PY
assert_eq "stale Patreon lease cannot commit evidence or a cursor" verified verified

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
