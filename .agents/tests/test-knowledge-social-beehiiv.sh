#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-beehiiv.sh — Publication-scoped beehiiv collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEEHIIV_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_beehiiv.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/beehiiv-test.XXXXXX")
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
PUBLICATION_ID="pub_fixture_publication"
OTHER_PUBLICATION_ID="pub_other_publication"
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

raw_count() {
	local connection_id="${1:-}"
	python3 - "$ROOT/sources/social/raw/beehiiv" "$connection_id" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
connection = sys.argv[2]
if connection:
    root = root / connection
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_fixture() {
	local fixture="$1"
	local connection_id="$2"
	shift 2
	python3 "$BEEHIIV_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id "$PUBLICATION_ID" \
		--stream posts --profile fixture --fixture "$fixture" \
		--budget 5 --page-size 1 "$@" || return 1
	return 0
}

run_live_profile() {
	local profile="$1"
	local connection_id="$2"
	python3 "$BEEHIIV_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id "$PUBLICATION_ID" \
		--stream posts --profile "$profile" --budget 3 --page-size 1 || return 1
	return 0
}

expect_failure() {
	local description="$1"
	local fixture="$2"
	local connection_id="$3"
	if run_fixture "$fixture" "$connection_id" >/dev/null 2>&1; then
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

printf 'beehiiv social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import os
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_beehiiv import (
    PageRequest,
    STREAMS,
    page_checkpoint,
    page_request,
)
from _knowledge_social_beehiiv_http import (
    HTTP_TIMEOUT_SECONDS,
    ApiResult,
    ProfileConfig,
    _RejectRedirect,
    allowlisted_path,
    api,
    target_url,
)
from _knowledge_social_beehiiv_provider import _identity, _posts, _profile
from _knowledge_social_collect import CursorState
from knowledge_social_beehiiv import _policy

publication_id = "pub_fixture_publication"
other_publication_id = "pub_other_publication"
assert set(STREAMS) == {"posts"}
assert _policy().max_budget == 59
assert allowlisted_path("/publications")
assert allowlisted_path(f"/publications/{publication_id}/posts")
assert not allowlisted_path(f"/publications/{publication_id}/subscriptions")
assert not allowlisted_path(f"/publications/{publication_id}/segments")
assert not allowlisted_path(f"/publications/{publication_id}/posts/post_one")
assert _RejectRedirect().redirect_request() is None

url = target_url(
    f"/publications/{publication_id}/posts",
    {
        "expand": "free_web_content",
        "limit": "1",
        "page": "1",
        "status": "confirmed",
        "order_by": "created",
        "direction": "asc",
    },
)
assert url.startswith("https://api.beehiiv.com/v2/publications/")
assert "free_web_content" in url and "access" not in url
for invalid_path in (
    f"/publications/{publication_id}/subscriptions",
    f"/publications/{publication_id}/segments",
    f"/publications/{publication_id}/posts/post_one",
):
    try:
        target_url(invalid_path, {})
    except RuntimeError:
        pass
    else:
        raise AssertionError(f"beehiiv route was reachable: {invalid_path}")

account = {
    "id": publication_id,
    "name": "Fixture Publication",
    "organization_name": "Fixture Organization",
    "created": 1700000000,
    "referral_program_enabled": False,
    "scope_verified": True,
}
first = PageRequest("posts", publication_id, 1, 1)
first_payload = {
    "status": 200,
    "observed_at": "2026-08-02T10:00:00Z",
    "data": [],
    "meta": {
        "stream": "posts",
        "publication_id": publication_id,
        "page": 1,
        "total_pages": 2,
        "total_results": 2,
    },
}
checkpoint, complete = page_checkpoint(first_payload, CursorState(None, None, False), first)
assert not complete and checkpoint.next_cursor
resumed = page_request("posts", account, CursorState(checkpoint.next_cursor, None, False), 1)
assert resumed.page == 2
try:
    page_checkpoint(
        {
            **first_payload,
            "meta": {**first_payload["meta"], "publication_id": other_publication_id},
        },
        CursorState(None, None, False),
        first,
    )
except RuntimeError:
    pass
else:
    raise AssertionError("cross-publication beehiiv page advanced a checkpoint")

profile_prefix = "BEEHIIV_OWNERSHIP_FIXTURE"
profile_values = {
    "ACCESS_TOKEN": "fixture-token",
    "PUBLICATION_ID": publication_id,
    "PUBLICATION_NAME": "Fixture Publication",
    "ORGANIZATION_NAME": "Fixture Organization",
}
for suffix, value in profile_values.items():
    os.environ[f"{profile_prefix}_{suffix}"] = value
try:
    _profile("ownership_fixture")
except RuntimeError:
    pass
else:
    raise AssertionError("beehiiv profile without ownership attestation was accepted")
os.environ[f"{profile_prefix}_CREATOR_OWNED_PUBLICATION_ID"] = other_publication_id
try:
    _profile("ownership_fixture")
except RuntimeError:
    pass
else:
    raise AssertionError("beehiiv mismatched ownership attestation was accepted")
os.environ[f"{profile_prefix}_CREATOR_OWNED_PUBLICATION_ID"] = publication_id
assert _profile("ownership_fixture").creator_owned_publication_id == publication_id
for suffix in (*profile_values, "CREATOR_OWNED_PUBLICATION_ID"):
    os.environ.pop(f"{profile_prefix}_{suffix}")


class Headers:
    def __init__(self, values=None):
        self.values = values or {}

    def get(self, key, default=None):
        return self.values.get(key, default)


class Response:
    def __init__(self, payload, status=200, headers=None):
        self.payload = payload
        self.status = status
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
        assert timeout == HTTP_TIMEOUT_SECONDS and request.method == "GET"
        assert "fixture-token" not in request.full_url
        self.requests.append(request)
        return self.responses.pop(0)


config = ProfileConfig(
    "fixture-token",
    publication_id,
    "Fixture Publication",
    "Fixture Organization",
    publication_id,
)
publication = {
    "id": publication_id,
    "name": "Fixture Publication",
    "organization_name": "Fixture Organization",
    "created": 1700000000,
    "referral_program_enabled": False,
}
identity_body = json.dumps(
    {
        "data": [publication],
        "limit": 2,
        "page": 1,
        "total_results": 1,
        "total_pages": 1,
    }
).encode()
identity = _identity(config, Opener([Response(identity_body)]), publication_id)
assert identity["data"]["id"] == publication_id
assert identity["data"]["scope_verified"] is True
assert identity["data"]["ownership_attested"] is True

unowned_config = ProfileConfig(
    "fixture-token",
    publication_id,
    "Fixture Publication",
    "Fixture Organization",
    other_publication_id,
)
try:
    _identity(unowned_config, Opener([]), publication_id)
except RuntimeError:
    pass
else:
    raise AssertionError("beehiiv unowned publication configuration was accepted")

wide_scope = json.dumps(
    {
        "data": [publication, {**publication, "id": other_publication_id}],
        "limit": 2,
        "page": 1,
        "total_results": 2,
        "total_pages": 1,
    }
).encode()
try:
    _identity(config, Opener([Response(wide_scope)]), publication_id)
except RuntimeError:
    pass
else:
    raise AssertionError("workspace-wide beehiiv credential passed publication scoping")

raw_post = {
    "id": "post_fixture_one",
    "title": "Bounded beehiiv knowledge",
    "subtitle": "Fixture subtitle",
    "authors": ["Fixture Author"],
    "created": 1700000000,
    "status": "confirmed",
    "publish_date": 1700000100,
    "displayed_date": 1700000100,
    "subject_line": "Fixture subject",
    "preview_text": "Fixture preview",
    "slug": "fixture-post",
    "web_url": "https://example.invalid/p/fixture-post",
    "audience": "free",
    "platform": "web",
    "content_tags": ["knowledge"],
    "hidden_from_feed": False,
    "enforce_gated_content": False,
    "content": {"free": {"web": "<p>Fixture body</p>"}},
}
post_page = _posts(
    lambda path, params: ApiResult(
        200,
        {
            "data": [raw_post],
            "limit": 1,
            "page": 1,
            "total_results": 1,
            "total_pages": 1,
        },
    ),
    first,
)
assert post_page["data"][0]["remote_id"] == "post_fixture_one"
assert post_page["data"][0]["free_web_content"] == "<p>Fixture body</p>"
assert "stats" not in post_page["data"][0]

for contradiction in (
    {"limit": 2},
    {"total_pages": 2},
    {"data": []},
):
    payload = {
        "data": [raw_post],
        "limit": 1,
        "page": 1,
        "total_results": 1,
        "total_pages": 1,
        **contradiction,
    }
    try:
        _posts(lambda path, params, value=payload: ApiResult(200, value), first)
    except RuntimeError:
        pass
    else:
        raise AssertionError("contradictory beehiiv pagination metadata was accepted")

scheduled = {**raw_post, "id": "post_future", "publish_date": 4102444800}
scheduled_page = _posts(
    lambda path, params: ApiResult(
        200,
        {
            "data": [scheduled],
            "limit": 1,
            "page": 1,
            "total_results": 1,
            "total_pages": 1,
        },
    ),
    first,
)
assert scheduled_page["data"] == []

opener = Opener([Response(identity_body)])
assert api(config, opener, "/publications", {"limit": "2", "page": "1"}).status == 200
rate = Opener([Response(b"", status=429, headers={"RateLimit-Reset": "2000000000"})])
limited = api(config, rate, "/publications", {"limit": "2", "page": "1"})
assert limited.status == 429 and limited.retry_after == 2000000000

provider_sources = [
    (scripts / "_knowledge_social_beehiiv_http.py").read_text(encoding="utf-8"),
    (scripts / "_knowledge_social_beehiiv_provider.py").read_text(encoding="utf-8"),
]
assert all("/subscriptions" not in source and "/segments" not in source for source in provider_sources)
trees = [ast.parse(source) for source in provider_sources]
calls = [
    node
    for tree in trees
    for node in ast.walk(tree)
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Name)
    and node.func.id == "Request"
]
assert calls
for node in calls:
    methods = [
        keyword.value.value
        for keyword in node.keywords
        if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
    ]
    assert methods == ["GET"]
PY
assert_eq "identity, scope, pagination, quota, redirects, and GET routes are guarded" verified verified

help_output=$("$SOCIAL_HELPER" help 2>&1)
if [[ "$help_output" == *"sync-beehiiv"* && "$help_output" == *"PUBLICATION_ID"* ]]; then
	assert_eq "provider-neutral helper exposes the bounded beehiiv route" exposed exposed
else
	assert_eq "provider-neutral helper exposes the bounded beehiiv route" missing exposed
fi

if BEEHIIV_PREFLIGHT_MISSING_PUBLICATION_ID="$PUBLICATION_ID" \
	run_live_profile preflight_missing conn_preflight_missing >/dev/null 2>&1; then
	assert_eq "missing ownership fails before the live reader" accepted rejected
else
	assert_eq "missing ownership fails before the live reader" rejected rejected
fi
if BEEHIIV_PREFLIGHT_MISMATCH_PUBLICATION_ID="$PUBLICATION_ID" \
	BEEHIIV_PREFLIGHT_MISMATCH_CREATOR_OWNED_PUBLICATION_ID="$OTHER_PUBLICATION_ID" \
	run_live_profile preflight_mismatch conn_preflight_mismatch >/dev/null 2>&1; then
	assert_eq "mismatched ownership fails before the live reader" accepted rejected
else
	assert_eq "mismatched ownership fails before the live reader" rejected rejected
fi
assert_eq "ownership preflight leaves durable run state untouched" \
	"$(sql_value "SELECT (SELECT count(*) FROM collector_lease_generations WHERE connection_id LIKE 'conn_preflight_%') + (SELECT count(*) FROM collector_leases WHERE connection_id LIKE 'conn_preflight_%') + (SELECT count(*) FROM sync_runs WHERE connection_id LIKE 'conn_preflight_%')")" 0
assert_eq "ownership preflight writes no raw evidence" "$(raw_count)" 0

python3 - "$TMP_DIR" "$PUBLICATION_ID" <<'PY'
import json
import sys
from pathlib import Path

target = Path(sys.argv[1])
publication_id = sys.argv[2]
identity = {
    "data": {
        "id": publication_id,
        "name": "Fixture Publication",
        "organization_name": "Fixture Organization",
        "created": 1700000000,
        "referral_program_enabled": False,
        "scope_verified": True,
        "ownership_attested": True,
    }
}


def record(post_id, title, body, published):
    return {
        "kind": "post",
        "remote_id": post_id,
        "title": title,
        "subtitle": "Fixture subtitle",
        "authors": ["Fixture Author"],
        "created_at": published,
        "status": "confirmed",
        "publish_date": published,
        "displayed_date": published,
        "subject_line": "Fixture subject",
        "preview_text": "Fixture preview",
        "slug": post_id,
        "web_url": f"https://example.invalid/p/{post_id}",
        "audience": "free",
        "platform": "web",
        "content_tags": ["knowledge"],
        "meta_default_description": None,
        "meta_default_title": None,
        "hidden_from_feed": False,
        "enforce_gated_content": False,
        "free_web_content": body,
    }


def page(number, total, item, observed):
    return {
        "expect_request": {"page": number, "limit": 1},
        "response": {
            "status": 200,
            "observed_at": observed,
            "data": [item],
            "meta": {
                "stream": "posts",
                "publication_id": publication_id,
                "page": number,
                "total_pages": total,
                "total_results": total,
            },
        },
    }


complete = {
    "identity": identity,
    "pages": [
        page(
            1,
            2,
            record(
                "post_fixture_one",
                "Bounded beehiiv knowledge",
                "<p>First fixture body</p>",
                "2026-08-02T09:00:00Z",
            ),
            "2026-08-02T10:00:00Z",
        ),
        page(
            2,
            2,
            record(
                "post_fixture_two",
                "Second publication post",
                "<p>Second fixture body</p>",
                "2026-08-02T09:30:00Z",
            ),
            "2026-08-02T10:01:00Z",
        ),
    ],
}
(target / "complete.json").write_text(json.dumps(complete), encoding="utf-8")

mismatch = {
    "identity": {
        "data": {
            **identity["data"],
            "id": "pub_other_publication",
        }
    },
    "pages": [],
}
(target / "mismatch.json").write_text(json.dumps(mismatch), encoding="utf-8")

unowned = {
    "identity": {
        "data": {
            **identity["data"],
            "ownership_attested": False,
        }
    },
    "pages": [],
}
(target / "unowned.json").write_text(json.dumps(unowned), encoding="utf-8")

cross = {
    "identity": identity,
    "pages": [
        {
            **complete["pages"][0],
            "response": {
                **complete["pages"][0]["response"],
                "meta": {
                    **complete["pages"][0]["response"]["meta"],
                    "publication_id": "pub_other_publication",
                },
            },
        }
    ],
}
(target / "cross.json").write_text(json.dumps(cross), encoding="utf-8")

credential = {
    "identity": identity,
    "pages": [
        {
            **complete["pages"][0],
            "response": {
                **complete["pages"][0]["response"],
                "access_token": "fixture-must-not-persist",
            },
        }
    ],
}
(target / "credential.json").write_text(json.dumps(credential), encoding="utf-8")

malformed = {
    "identity": identity,
    "pages": [
        {
            **complete["pages"][0],
            "response": {
                **complete["pages"][0]["response"],
                "meta": {
                    key: value
                    for key, value in complete["pages"][0]["response"]["meta"].items()
                    if key != "total_results"
                },
            },
        }
    ],
}
(target / "malformed.json").write_text(json.dumps(malformed), encoding="utf-8")

contradictory = {
    "identity": identity,
    "pages": [
        {
            **complete["pages"][0],
            "response": {
                **complete["pages"][0]["response"],
                "meta": {
                    **complete["pages"][0]["response"]["meta"],
                    "total_results": 1,
                },
            },
        }
    ],
}
(target / "contradictory.json").write_text(
    json.dumps(contradictory), encoding="utf-8"
)

terminal = {
    "identity": {"status": 403, "observed_at": "2026-08-02T10:02:00Z"},
    "pages": [],
}
(target / "terminal.json").write_text(json.dumps(terminal), encoding="utf-8")
PY

if run_fixture "$TMP_DIR/complete.json" conn_budget_equals --budget=60 >/dev/null 2>&1; then
	assert_eq "equals-form budget above the provider fuse is rejected" accepted rejected
else
	assert_eq "equals-form budget above the provider fuse is rejected" rejected rejected
fi
if run_fixture "$TMP_DIR/complete.json" conn_budget_duplicate --budget 60 >/dev/null 2>&1; then
	assert_eq "duplicate budget cannot bypass the provider fuse" accepted rejected
else
	assert_eq "duplicate budget cannot bypass the provider fuse" rejected rejected
fi

result=$(run_fixture "$TMP_DIR/complete.json" conn_beehiiv)
assert_eq "bounded two-page beehiiv fixture completes" "$(json_field "$result" status)" complete
assert_eq "identity plus two pages consumes five requests" "$(json_field "$result" budget_units)" 5
assert_eq "publication identity persists before post projections" \
	"$(sql_value "SELECT remote_id || ':' || display_name FROM accounts WHERE provider='beehiiv'")" \
	"${PUBLICATION_ID}:Fixture Publication"
assert_eq "confirmed free post content reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1
assert_eq "subscriber, segment, export, stats, premium, and deletion gaps stay explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_beehiiv' AND status='unavailable'")" 8
assert_eq "successful page exhaustion advances only the selected stream" \
	"$(sql_value "SELECT coalesce(cursor, 'none') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_beehiiv' AND stream='posts'")" \
	"none:1"

batch_count=$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_beehiiv'")
raw_before=$(raw_count conn_beehiiv)
object_count=$(sql_value "SELECT count(*) FROM objects WHERE provider='beehiiv'")
run_fixture "$TMP_DIR/complete.json" conn_beehiiv >/dev/null
assert_eq "exact beehiiv replay is content-addressed" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_beehiiv'"):$(raw_count conn_beehiiv):$(sql_value "SELECT count(*) FROM objects WHERE provider='beehiiv'")" \
	"${batch_count}:${raw_before}:${object_count}"

raw_all_before=$(raw_count)
expect_failure "wrong publication identity is rejected before persistence" \
	"$TMP_DIR/mismatch.json" conn_mismatch
assert_eq "identity mismatch writes no raw evidence" "$(raw_count)" "$raw_all_before"

expect_failure "missing creator-ownership attestation is rejected before persistence" \
	"$TMP_DIR/unowned.json" conn_unowned
assert_eq "ownership rejection advances no checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_unowned'")" 0
assert_eq "ownership rejection writes no raw evidence" "$(raw_count)" "$raw_all_before"

expect_failure "cross-publication page provenance is rejected" \
	"$TMP_DIR/cross.json" conn_cross
assert_eq "cross-publication rejection writes no raw evidence" "$(raw_count)" "$raw_all_before"

expect_failure "credential-shaped beehiiv payload is rejected" \
	"$TMP_DIR/credential.json" conn_credential
assert_eq "credential rejection writes no raw evidence" "$(raw_count)" "$raw_all_before"

cursor_before=$(sql_value "SELECT coalesce(cursor, 'none') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_beehiiv' AND stream='posts'")
expect_failure "malformed beehiiv page fails closed" \
	"$TMP_DIR/malformed.json" conn_beehiiv
assert_eq "malformed page preserves the prior checkpoint" \
	"$(sql_value "SELECT coalesce(cursor, 'none') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_beehiiv' AND stream='posts'")" \
	"$cursor_before"
assert_eq "malformed page writes no new raw evidence" "$(raw_count conn_beehiiv)" "$raw_before"

expect_failure "contradictory beehiiv pagination fails closed" \
	"$TMP_DIR/contradictory.json" conn_beehiiv
assert_eq "contradictory pagination preserves the prior checkpoint" \
	"$(sql_value "SELECT coalesce(cursor, 'none') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_beehiiv' AND stream='posts'")" \
	"$cursor_before"
assert_eq "contradictory pagination writes no new raw evidence" \
	"$(raw_count conn_beehiiv)" "$raw_before"

terminal=$(run_fixture "$TMP_DIR/terminal.json" conn_plan_gate)
assert_eq "plan or authorization gate is terminal" \
	"$(json_field "$terminal" status):$(json_field "$terminal" failure_class)" \
	"failed:authorization"
assert_eq "terminal authorization response advances no checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_plan_gate'")" 0

python3 - "$ROOT" "$SCRIPT_DIR/../scripts" <<'PY'
import os
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from _knowledge_social_beehiiv import STREAMS
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

root = Path(sys.argv[1])
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_beehiiv_fence", "posts", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_beehiiv_fence", "posts", "new_runner", "sync", 10),
    now_epoch=9001,
)
publication_id = "pub_fixture_publication"
context = CollectionContext(
    root,
    "conn_beehiiv_fence",
    {"id": publication_id},
    "posts",
    "none",
    ConnectionConfig(("posts",), {"media_hydration": "none"}),
    CursorState(None, None, False),
    STREAMS["posts"],
    old,
    "beehiiv",
)
archive = {
    "provider": "beehiiv",
    "connection_id": "conn_beehiiv_fence",
    "remote_account_id": publication_id,
    "exported_at": "2026-08-02T10:03:00Z",
    "enabled_streams": ["posts"],
    "policy": {"media_hydration": "none"},
    "accounts": [],
    "objects": [],
    "activities": [],
    "media": [],
    "coverage": [],
}
successful = SuccessfulPage(
    {"status": 200, "observed_at": archive["exported_at"], "data": [], "meta": {}},
    '{"stream":"posts"}',
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
    raise SystemExit("stale beehiiv collector advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    cursor_count = database.execute(
        "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_beehiiv_fence'"
    ).fetchone()[0]
    batch_count = database.execute(
        "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_beehiiv_fence'"
    ).fetchone()[0]
assert cursor_count == 0 and batch_count == 0
release_run_lease(root, new)
PY
assert_eq "stale beehiiv lease cannot commit evidence or a cursor" verified verified

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
