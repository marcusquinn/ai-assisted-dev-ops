#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-hacker-news.sh — Public Hacker News collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HN_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_hacker_news.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/hacker-news-social-test.XXXXXX")
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
	python3 - "$ROOT/sources/social/raw/hacker-news" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_hn() {
	local fixture="$1"
	local connection_id="$2"
	local budget="$3"
	local page_size="$4"
	local selected_username="$5"
	if python3 "$HN_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id "$selected_username" \
		--stream submitted --profile public --fixture "$fixture" \
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
	local selected_username="$6"
	if run_hn "$fixture" "$connection_id" "$budget" "$page_size" \
		"$selected_username" >/dev/null 2>&1; then
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

printf 'Hacker News social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_hacker_news import (
    PageRequest, page_checkpoint, page_request, parse_page_request,
)
from _knowledge_social_hacker_news_contract import item_value, user_value
from _knowledge_social_hacker_news_http import (
    HTTP_TIMEOUT_SECONDS, allowlisted_route, api,
)
from _knowledge_social_hacker_news_identity import selector_id

assert selector_id("CaseUser") != selector_id("caseuser")
missing = user_value(None, "jl")
assert missing["availability"] == "missing" and missing["username"] == "jl"
try:
    user_value({"id": "caseuser", "submitted": []}, "CaseUser")
except RuntimeError:
    pass
else:
    raise AssertionError("case-changed Hacker News username was accepted")

account = {
    "id": selector_id("CaseUser"), "username": "CaseUser",
    "availability": "public", "submitted": [11, 12],
}
first = page_request("submitted", account, CursorState(None, None, False), 2)
assert first.item_id == 11 and parse_page_request(first.payload()) == first
payload = {
    "status": 200, "observed_at": "2026-08-02T10:00:00Z",
    "data": [{"item_id": 11, "state": "live", "type": "story",
              "by": "CaseUser", "time": 1785664800, "title": "First"}],
    "meta": {
        "stream": "submitted", "username": "CaseUser",
        "selector_id": selector_id("CaseUser"),
        "snapshot_sha256": first.snapshot_sha256, "position": 0,
        "total": 2, "item_id": 11, "item_state": "live",
        "response_bytes": 128,
    },
}
checkpoint, complete = page_checkpoint(payload, CursorState(None, None, False), first)
assert not complete and checkpoint.next_cursor
changed = dict(account, submitted=[99])
resumed = page_request(
    "submitted", changed, CursorState(checkpoint.next_cursor, checkpoint.watermark, False), 1,
)
assert resumed.item_id == 12 and resumed.items == (11, 12)

assert item_value(None, 20, "CaseUser")["state"] == "missing"
assert item_value({"id": 20, "deleted": True}, 20, "CaseUser")["state"] == "deleted"
assert item_value({"id": 20, "dead": True}, 20, "CaseUser")["state"] == "dead"
try:
    item_value({"id": 20, "type": "story", "by": "Other"}, 20, "CaseUser")
except RuntimeError:
    pass
else:
    raise AssertionError("item attributed to another username was accepted")


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
        self.requests.append(request)
        return self.responses.pop(0)


opener = Opener([
    Response({"id": "CaseUser", "submitted": [20]}),
    Response({"id": 20, "type": "story", "by": "CaseUser"}),
])
assert api(opener, "user", "CaseUser").status == 200
assert api(opener, "item", 20).status == 200
assert opener.requests[0].full_url == "https://hacker-news.firebaseio.com/v0/user/CaseUser.json"
assert opener.requests[1].full_url == "https://hacker-news.firebaseio.com/v0/item/20.json"
assert allowlisted_route("user") and allowlisted_route("item")
assert not allowlisted_route("maxitem")
try:
    api(opener, "updates", "CaseUser")
except RuntimeError:
    pass
else:
    raise AssertionError("non-user/item Hacker News route was accepted")

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_hacker_news*.py"))
]
trees = [ast.parse(source) for source in sources]
request_calls = [
    node for tree in trees for node in ast.walk(tree)
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Name)
    and node.func.id == "Request"
]
assert request_calls
for node in request_calls:
    methods = [
        keyword.value.value for keyword in node.keywords
        if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
    ]
    assert methods == ["GET"]
PY
assert_eq "case-sensitive selector, deterministic resume, schemas, budgets, and GET-only routes are guarded" \
	verified verified

python3 - "$TMP_DIR" "$SCRIPT_DIR/../scripts" <<'PY'
import json
import sys
from pathlib import Path

target = Path(sys.argv[1])
sys.path.insert(0, sys.argv[2])
from _knowledge_social_hacker_news import page_request
from _knowledge_social_hacker_news_identity import selector_id
from _knowledge_social_collect import CursorState

USERNAME = "CaseUser"
SELECTOR = selector_id(USERNAME)


def identity(items, availability="public", username=USERNAME, selector=SELECTOR):
    return {
        "status": 200,
        "observed_at": "2026-08-02T10:01:00Z",
        "data": {
            "id": selector,
            "username": username,
            "availability": availability,
            "submitted": items,
            "created": 1173923446,
            "karma": 42,
            "about": "Public profile",
            "response_bytes": 100,
        },
    }


def response(items, position, record, observed_at):
    account = {
        "id": SELECTOR, "username": USERNAME,
        "availability": "public", "submitted": items,
    }
    request = page_request("submitted", account, CursorState(None, None, False), len(items) or 1)
    request = type(request)(
        request.stream, request.username, request.selector_id,
        request.items, position, request.snapshot_sha256,
    )
    state = "empty" if record is None else record["state"]
    return {
        "status": 200,
        "observed_at": observed_at,
        "data": [] if record is None else [record],
        "meta": {
            "stream": "submitted", "username": USERNAME,
            "selector_id": SELECTOR,
            "snapshot_sha256": request.snapshot_sha256,
            "position": position, "total": len(items),
            "item_id": request.item_id, "item_state": state,
            "response_bytes": 200,
        },
    }


def write(name, identity_payload, pages):
    (target / name).write_text(
        json.dumps({"identity": identity_payload, "pages": pages}),
        encoding="utf-8",
    )


complete_items = [101, 102]
write("complete.json", identity(complete_items), [
    {
        "expect_request": {"position": 0, "items": complete_items},
        "response": response(complete_items, 0, {
            "item_id": 101, "state": "live", "type": "story", "by": USERNAME,
            "time": 1785664860, "title": "Bounded story",
            "text": "Hacker News fixture knowledge", "url": "https://example.invalid/story",
            "score": 5, "descendants": 1, "kids": [500], "parts": None,
            "parent": None, "poll": None,
        }, "2026-08-02T10:02:00Z"),
    },
    {
        "expect_request": {"position": 1, "items": complete_items},
        "response": response(complete_items, 1, {
            "item_id": 102, "state": "live", "type": "comment", "by": USERNAME,
            "time": 1785664920, "title": None, "text": "Second public comment",
            "url": None, "score": None, "descendants": None, "kids": None,
            "parts": None, "parent": 101, "poll": None,
        }, "2026-08-02T10:03:00Z"),
    },
])

resume_items = [201, 202]
write("resume-first.json", identity(resume_items), [{
    "expect_request": {"position": 0, "items": resume_items},
    "response": response(resume_items, 0, {
        "item_id": 201, "state": "live", "type": "story", "by": USERNAME,
        "time": 1785664980, "title": "Resume one", "text": None, "url": None,
        "score": 1, "descendants": 0, "kids": None, "parts": None,
        "parent": None, "poll": None,
    }, "2026-08-02T10:04:00Z"),
}])
write("resume-second.json", identity([999]), [{
    "expect_request": {"position": 1, "items": resume_items},
    "response": response(resume_items, 1, {
        "item_id": 202, "state": "live", "type": "comment", "by": USERNAME,
        "time": 1785665040, "title": None, "text": "Resumed item", "url": None,
        "score": None, "descendants": None, "kids": None, "parts": None,
        "parent": 201, "poll": None,
    }, "2026-08-02T10:05:00Z"),
}])

write("missing-user.json", identity([], "missing"), [{
    "expect_request": {"position": 0, "items": []},
    "response": response([], 0, None, "2026-08-02T10:06:00Z"),
}])

tombstone_items = [301, 302, 303]
write("tombstones.json", identity(tombstone_items), [
    {"response": response(tombstone_items, 0, {"item_id": 301, "state": "missing"}, "2026-08-02T10:07:00Z")},
    {"response": response(tombstone_items, 1, {"item_id": 302, "state": "deleted", "type": None, "by": None}, "2026-08-02T10:08:00Z")},
    {"response": response(tombstone_items, 2, {"item_id": 303, "state": "dead", "type": "story", "by": USERNAME}, "2026-08-02T10:09:00Z")},
])

write("case-mismatch.json", identity([], username="caseuser", selector=selector_id("caseuser")), [])

malformed_items = [350]
malformed = response(malformed_items, 0, {"item_id": 350, "state": "missing"}, "2026-08-02T10:10:00Z")
malformed["meta"]["snapshot_sha256"] = "0" * 64
write("malformed.json", identity(malformed_items), [{"response": malformed}])

terminal_items = [401, 402]
write("terminal-first.json", identity(terminal_items), [{
    "response": response(terminal_items, 0, {
        "item_id": 401, "state": "live", "type": "story", "by": USERNAME,
        "time": 1785665100, "title": "Before failure", "text": None, "url": None,
        "score": 1, "descendants": 0, "kids": None, "parts": None,
        "parent": None, "poll": None,
    }, "2026-08-02T10:11:00Z"),
}])
write("terminal-second.json", identity(terminal_items), [{
    "expect_request": {"position": 1, "items": terminal_items},
    "response": {"status": 500, "observed_at": "2026-08-02T10:12:00Z", "response_bytes": 10},
}])
write("identity-terminal.json", {
    "status": 500, "observed_at": "2026-08-02T10:13:00Z", "response_bytes": 10,
}, [])

credential_items = [501]
credential = response(credential_items, 0, {"item_id": 501, "state": "missing"}, "2026-08-02T10:14:00Z")
credential["access_token"] = "must-not-persist"
write("credential.json", identity(credential_items), [{"response": credential}])
PY

complete_result=$(run_hn "$TMP_DIR/complete.json" conn_hn_complete 5 2 CaseUser)
assert_eq "bounded Hacker News fixture completes" \
	"$(json_field "$complete_result" status)" complete
assert_eq "identity and two item reads reserve five request units" \
	"$(json_field "$complete_result" budget_units)" 5
assert_eq "public Hacker News text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'knowledge'")" 1
assert_eq "public-only unavailable categories remain explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_hn_complete' AND status='unavailable'")" 9
complete_raw=$(raw_count)
run_hn "$TMP_DIR/complete.json" conn_hn_complete 5 2 CaseUser >/dev/null
assert_eq "exact Hacker News snapshot replay is idempotent" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='hacker-news' AND remote_id IN ('hn_item_101','hn_item_102')")" 2
assert_eq "content-addressed replay does not duplicate raw blobs" "$(raw_count)" "$complete_raw"

resume_first=$(run_hn "$TMP_DIR/resume-first.json" conn_hn_resume 3 2 CaseUser)
assert_eq "request budget pauses a submitted-ID slice" \
	"$(json_field "$resume_first" status)" budget_exhausted
resume_second=$(run_hn "$TMP_DIR/resume-second.json" conn_hn_resume 3 1 CaseUser)
assert_eq "resume uses the durable content-addressed ID slice" \
	"$(json_field "$resume_second" status)" complete
assert_eq "resumed snapshot retains both public items" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='hacker-news' AND remote_id IN ('hn_item_201','hn_item_202')")" 2

missing_result=$(run_hn "$TMP_DIR/missing-user.json" conn_hn_missing_user 3 1 CaseUser)
assert_eq "missing public username completes without an identity claim" \
	"$(json_field "$missing_result" status)" complete
assert_eq "missing public username records explicit coverage" \
	"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_hn_missing_user' AND stream='public_selector'")" \
	"unavailable:public_username_not_found"

run_hn "$TMP_DIR/tombstones.json" conn_hn_tombstones 7 3 CaseUser >/dev/null
assert_eq "missing, deleted, and dead items remain unavailable rather than empty" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_hn_tombstones' AND stream LIKE 'submitted_item_%' AND status='unavailable'")" 3
assert_eq "tombstones do not create authored objects" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='hacker-news' AND remote_id IN ('hn_item_301','hn_item_302','hn_item_303')")" 0

raw_before=$(raw_count)
expect_failure "case-changed public username is rejected" \
	"$TMP_DIR/case-mismatch.json" conn_hn_case 3 1 CaseUser
expect_failure "malformed page provenance is rejected" \
	"$TMP_DIR/malformed.json" conn_hn_malformed 3 1 CaseUser
expect_failure "credential-shaped public payload is rejected" \
	"$TMP_DIR/credential.json" conn_hn_credential 3 1 CaseUser
assert_eq "rejected observations persist no raw evidence" "$(raw_count)" "$raw_before"

run_hn "$TMP_DIR/terminal-first.json" conn_hn_terminal 3 2 CaseUser >/dev/null
terminal_result=$(run_hn "$TMP_DIR/terminal-second.json" conn_hn_terminal 3 1 CaseUser)
assert_eq "terminal item failure is sanitized" \
	"$(json_field "$terminal_result" failure_class)" provider
assert_eq "terminal item failure preserves its prior checkpoint" \
	"$(sql_value "SELECT cursor IS NOT NULL FROM sync_cursors WHERE connection_id='conn_hn_terminal' AND stream='submitted'")" 1
assert_eq "terminal item failure records failed coverage" \
	"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_hn_terminal' AND stream='submitted'")" \
	"failed:provider"

identity_terminal=$(run_hn "$TMP_DIR/identity-terminal.json" conn_hn_identity_terminal 3 1 jl)
assert_eq "terminal public-selector read is sanitized" \
	"$(json_field "$identity_terminal" failure_class)" provider
assert_eq "terminal public-selector read records coverage without account identity" \
	"$(sql_value "SELECT status || ':' || unavailable_reason FROM coverage_records WHERE connection_id='conn_hn_identity_terminal' AND stream='submitted'")" \
	"failed:provider"

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
from _knowledge_social_hacker_news import STREAMS
from _knowledge_social_hacker_news_identity import selector_id
from _knowledge_social_lease import (
    RunLeaseRequest, SocialLeaseLostError, acquire_run_lease, release_run_lease,
)

root = Path(sys.argv[1])
old = acquire_run_lease(
    root, RunLeaseRequest("conn_hn_fence", "submitted", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root, RunLeaseRequest("conn_hn_fence", "submitted", "new_runner", "sync", 10),
    now_epoch=9001,
)
selected = selector_id("CaseUser")
context = CollectionContext(
    root, "conn_hn_fence", {"id": selected, "username": "CaseUser"},
    "submitted", "none", ConnectionConfig(("submitted",), {"media_hydration": "none"}),
    CursorState(None, None, False), STREAMS["submitted"], old, "hacker-news",
)
archive = {
    "provider": "hacker-news", "connection_id": "conn_hn_fence",
    "remote_account_id": selected, "exported_at": "2026-08-02T10:15:00Z",
    "enabled_streams": ["submitted"], "policy": {"media_hydration": "none"},
    "accounts": [], "objects": [], "activities": [], "media": [], "coverage": [],
}
successful = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"submitted"}', archive, PageCheckpoint(None, None), True, 2,
)
os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "9001"
try:
    persist_page(context, successful)
except SocialLeaseLostError:
    pass
else:
    raise SystemExit("stale Hacker News collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    count = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_hn_fence'"
    ).fetchone()[0]
assert count == 0
release_run_lease(root, new)
PY
assert_eq "stale Hacker News lease cannot commit evidence or a cursor" verified verified

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
