#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-mastodon.sh — Bounded Mastodon collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTODON_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_mastodon.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
INSTANCE_A="aaaaaaaaaaaaaaaaaaaaaaaa"
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
	python3 - "$ROOT/sources/social/raw/mastodon" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_mastodon() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	local budget="$4"
	local page_size="$5"
	if python3 "$MASTODON_SCRIPT" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id account_42 \
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
	if run_mastodon "$fixture" "$connection_id" "$stream" 11 40 >/dev/null 2>&1; then
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

printf 'Mastodon social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import os
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_mastodon import PageRequest, STREAMS, namespaced_id
from _knowledge_social_mastodon_contract import ApiResult
from _knowledge_social_mastodon_http import (
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    _canonical_base_url,
    api,
    installation_fingerprint,
)
from _knowledge_social_mastodon_provider import _profile
from _knowledge_social_mastodon_routes import (
    EXACT_READ_PATHS,
    allowlisted_path,
    page,
    page_limit_for_path,
)

assert set(STREAMS) == {
    "authored_statuses", "favourites", "bookmarks", "notifications",
    "followers", "following", "followed_tags", "lists",
}
assert all(spec.pagination == "snapshot" and spec.cost_units == 2 for spec in STREAMS.values())
assert "/api/v1/accounts/verify_credentials" in EXACT_READ_PATHS
assert allowlisted_path("/api/v1/accounts/42/statuses")
assert allowlisted_path("/api/v1/accounts/42/followers")
assert page_limit_for_path("/api/v1/accounts/42/statuses") == 40
assert page_limit_for_path("/api/v1/notifications") == 80
assert page_limit_for_path("/api/v1/followed_tags") == 100
for rejected in (
    "/api/v1/statuses/1/favourite", "/api/v1/accounts/update_credentials",
    "/api/v1/notifications/clear", "/api/v1/lists/1/accounts/add",
    "/api/v1/admin/accounts",
):
    assert not allowlisted_path(rejected)

base = _canonical_base_url("https://mastodon.example.invalid/")
instance = installation_fingerprint(base, "a" * 32)
assert instance == installation_fingerprint("https://mastodon.example.invalid", "a" * 32)
assert namespaced_id(instance, "status", "opaque-A") != namespaced_id(
    instance, "status", "opaque-B"
)
for invalid in (
    "http://mastodon.example.invalid", "https://user@mastodon.example.invalid",
    "https://mastodon.example.invalid/subpath", "https://mastodon.example.invalid/?query=1",
):
    try:
        _canonical_base_url(invalid)
    except RuntimeError as error:
        assert "example.invalid" not in str(error)
    else:
        raise AssertionError("unsafe Mastodon origin was accepted")

os.environ.update({
    "MASTODON_SCOPE_BASE_URL": base,
    "MASTODON_SCOPE_ACCESS_TOKEN": "private-token",
    "MASTODON_SCOPE_ORIGIN_KEY": "a" * 32,
    "MASTODON_SCOPE_AUTH_MODE": "user_token",
    "MASTODON_SCOPE_SCOPES": "read:accounts write:statuses",
})
try:
    _profile("scope")
except RuntimeError:
    pass
else:
    raise AssertionError("write-authorized Mastodon profile was accepted")


class Headers:
    def __init__(self, link=None):
        self.link = link

    def get(self, key, default=None):
        return self.link if key == "Link" else default


class Response:
    status = 200

    def __init__(self, payload, link=None):
        self.payload = json.dumps(payload).encode()
        self.headers = Headers(link)

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
        assert "private-token" not in request.full_url
        self.requests.append(request)
        return self.responses.pop(0)


scopes = frozenset({"read:accounts", "read:statuses"})
config = ProfileConfig(base, "private-token", "user_token", instance, scopes)
next_url = "https://mastodon.example.invalid/api/v1/accounts/42/statuses?limit=2&max_id=opaque%2Fcursor"
opener = Opener([Response([], f'<{next_url}>; rel="next"')])
result = api(config, opener, "/api/v1/accounts/42/statuses", {"limit": "2"})
assert result.next_url == next_url
assert opener.requests[0].full_url.endswith("/api/v1/accounts/42/statuses?limit=2")
try:
    api(config, opener, "https://other.invalid/api/v1/accounts/42/statuses?limit=2", {})
except RuntimeError:
    pass
else:
    raise AssertionError("cross-origin Mastodon next link was accepted")
try:
    api(
        config,
        Opener([]),
        "https://mastodon.example.invalid/api/v1/accounts/42/statuses?limit=41",
        {},
    )
except RuntimeError:
    pass
else:
    raise AssertionError("oversized Mastodon next-link page was accepted")

request = PageRequest(
    "authored_statuses", namespaced_id(instance, "account", "42"), "42",
    "selected", instance, 1, None, 2,
)
calls = []


def status_api(target, params):
    calls.append((target, params))
    return ApiResult(200, [{
        "id": "status/opaque", "created_at": "2026-08-02T00:00:00Z",
        "content": "<p>Bounded status</p>", "account": {
            "id": "42", "username": "selected", "acct": "selected",
        },
    }], next_url)


payload = page(status_api, request, {})
assert payload["meta"]["next_url"] == next_url
assert payload["data"][0]["author_remote_id"] == request.account_id
assert calls == [("/api/v1/accounts/42/statuses", {"limit": "2"})]

large_request = PageRequest(
    "authored_statuses", namespaced_id(instance, "account", "42"), "42",
    "selected", instance, 1, None, 100,
)
calls.clear()
page(status_api, large_request, {})
assert calls == [("/api/v1/accounts/42/statuses", {"limit": "40"})]

cross_stream_request = PageRequest(
    "authored_statuses", namespaced_id(instance, "account", "42"), "42",
    "selected", instance, 2,
    "https://mastodon.example.invalid/api/v1/favourites?limit=40", 40,
)
try:
    page(status_api, cross_stream_request, {})
except RuntimeError:
    pass
else:
    raise AssertionError("cross-stream Mastodon next link was accepted")

sources = [path.read_text(encoding="utf-8") for path in sorted(scripts.glob("_knowledge_social_mastodon*.py"))]
trees = [ast.parse(source) for source in sources]
request_calls = [
    node for tree in trees for node in ast.walk(tree)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "Request"
]
assert request_calls
for node in request_calls:
    methods = [
        keyword.value.value for keyword in node.keywords
        if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
    ]
    assert methods == ["GET"]
assert all("_knowledge_social_outbound" not in source for source in sources)
PY
assert_eq "exact origins, opaque Link pagination, scopes, routes, and GET-only AST are guarded" \
	verified verified

python3 - "$TMP_DIR/first.json" "$INSTANCE_A" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_mastodon_identity import namespaced_id

instance = sys.argv[2]
next_url = "https://mastodon.example.invalid/api/v1/accounts/42/statuses?limit=1&max_id=opaque%2Fnext"
payload = {
    "identity": {"data": {
        "provider_account_id": "42", "username": "selected", "acct": "selected",
        "display_name": "Private profile", "uri": "https://mastodon.example.invalid/users/selected",
        "instance_id": instance,
    }},
    "pages": [{
        "expect_request": {"position": 1, "stop_at": None, "limit": 1},
        "response": {
            "status": 200, "observed_at": "2026-08-02T00:01:00Z",
            "data": [{
                "kind": "status", "remote_id": namespaced_id(instance, "status", "100"),
                "status_id": "100", "author_remote_id": namespaced_id(instance, "account", "42"),
                "content": "<p>Bounded Mastodon knowledge</p>",
                "created_at": "2026-08-02T00:00:00Z",
            }],
            "meta": {"stream": "authored_statuses", "instance_id": instance,
                     "next_url": next_url, "complete": False, "snapshot": True},
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
first_result=$(run_mastodon "$TMP_DIR/first.json" conn_mastodon authored_statuses 3 1)
assert_eq "one bounded Mastodon page pauses at its opaque Link" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "identity plus page consumes three request units" \
	"$(json_field "$first_result" budget_units)" 3
assert_eq "partial page commits evidence and cursor atomically" \
	"$(sql_value "SELECT count(*) || ':' || (SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_mastodon') FROM fetch_batches WHERE connection_id='conn_mastodon'")" \
	"1:0"
assert_eq "authored Mastodon text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1

python3 - "$TMP_DIR/resume.json" "$INSTANCE_A" <<'PY'
import json
import sys

instance = sys.argv[2]
next_url = "https://mastodon.example.invalid/api/v1/accounts/42/statuses?limit=1&max_id=opaque%2Fnext"
payload = {
    "identity": {"data": {"provider_account_id": "42", "username": "selected",
                            "acct": "selected", "instance_id": instance}},
    "pages": [{
        "expect_request": {"position": 2, "stop_at": next_url},
        "response": {"status": 200, "observed_at": "2026-08-02T00:02:00Z", "data": [],
                     "meta": {"stream": "authored_statuses", "instance_id": instance,
                              "next_url": None, "complete": True, "snapshot": True}},
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
second_result=$(run_mastodon "$TMP_DIR/resume.json" conn_mastodon authored_statuses 11 40)
assert_eq "Mastodon resumes the exact opaque Link" \
	"$(json_field "$second_result" status)" complete
assert_eq "completed Mastodon snapshot clears its cursor" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_mastodon'")" \
	"done:1"

cat >"$TMP_DIR/mismatch.json" <<JSON
{"identity":{"data":{"provider_account_id":"43","username":"other","acct":"other","instance_id":"${INSTANCE_A}"}},"pages":[]}
JSON
raw_before=$(raw_count)
expect_failure "selected-account identity mismatch is rejected" \
	"$TMP_DIR/mismatch.json" conn_mismatch authored_statuses
assert_eq "identity mismatch persists no raw evidence" "$(raw_count)" "$raw_before"

cat >"$TMP_DIR/credential.json" <<JSON
{"identity":{"data":{"provider_account_id":"42","username":"selected","acct":"selected","instance_id":"${INSTANCE_A}"}},
 "pages":[{"status":200,"observed_at":"2026-08-02T00:03:00Z","access_token":"must-not-persist","data":[],
 "meta":{"stream":"bookmarks","instance_id":"${INSTANCE_A}","next_url":null,"complete":true,"snapshot":true}}]}
JSON
raw_before=$(raw_count)
expect_failure "credential-shaped Mastodon page is rejected" \
	"$TMP_DIR/credential.json" conn_credential bookmarks
assert_eq "credential rejection persists no raw evidence" "$(raw_count)" "$raw_before"

cat >"$TMP_DIR/rate.json" <<JSON
{"identity":{"data":{"provider_account_id":"42","username":"selected","acct":"selected","instance_id":"${INSTANCE_A}"}},
 "pages":[{"status":429,"observed_at":"2026-08-02T00:04:00Z","retry_after":1785629400}]}
JSON
rate_result=$(run_mastodon "$TMP_DIR/rate.json" conn_rate notifications 11 40)
assert_eq "rate limit becomes an explicit paused result" \
	"$(json_field "$rate_result" failure_class):$(json_field "$rate_result" status)" \
	"rate_limit:rate_limited"
assert_eq "terminal response advances no checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_rate'")" 0

assert_eq "unsupported private and historical categories remain explicit gaps" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_mastodon' AND status='unavailable' AND stream IN ('conversations','list_members','account_exports','federated_history','moderation_history','deleted_or_purged_content','instance_retention')")" 7

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
