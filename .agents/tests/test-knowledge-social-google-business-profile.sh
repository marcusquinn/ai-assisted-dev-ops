#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-google-business-profile.sh — guarded GBP collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/../scripts"
COLLECTOR="${SCRIPTS}/knowledge_social_google_business_profile.py"
CORPUS_HELPER="${SCRIPTS}/knowledge-corpus-helper.sh"
SOCIAL_HELPER="${SCRIPTS}/knowledge-social-helper.sh"
FIXTURES="${SCRIPT_DIR}/fixtures/knowledge-social-google-business-profile"
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

run_collector() {
	local fixture="$1"
	shift
	python3 "$COLLECTOR" --base "$BASE" --alias personal:default \
		--connection-id conn_gbp --account-id location42 --stream reviews \
		--profile fixture --fixture "$fixture" "$@"
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Google Business Profile social collector tests\n'

first=$(run_collector "$FIXTURES/reviews-page-1.json" --budget 3 --page-size 1)
assert_eq "bounded first page pauses at the logical budget" \
	"$(json_field "$first" status)" budget_exhausted
assert_eq "review cursor remains independently resumable" \
	"$(sql_value "SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_gbp' AND stream='reviews'")" 0
assert_eq "protected review text reaches the private FTS projection" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'protected'")" 1
assert_eq "protected marker survives normalization" \
	"$(sql_value "SELECT json_extract(provider_json, '$.protected_customer_content') FROM objects WHERE remote_id='review-new'")" 1

second=$(run_collector "$FIXTURES/reviews-page-2.json")
assert_eq "review pagination resumes from the opaque provider token" \
	"$(json_field "$second" status)" complete
assert_eq "owner replies retain authored evidence semantics" \
	"$(sql_value "SELECT evidence_class FROM objects WHERE remote_id='review-new-owner-reply'")" authored
assert_eq "completed review stream commits no residual cursor" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_gbp' AND stream='reviews'")" done:1
assert_eq "unsupported Q&A is explicit durable coverage" \
	"$(sql_value "SELECT status FROM coverage_records WHERE connection_id='conn_gbp' AND stream='questions_answers'")" unavailable
assert_eq "messages remain an explicit unavailable category" \
	"$(sql_value "SELECT status FROM coverage_records WHERE connection_id='conn_gbp' AND stream='messages'")" unavailable

python3 - "$SCRIPTS" <<'PY'
import ast
import importlib.util
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))
import _knowledge_social_google_business_profile as gbp
import _knowledge_social_google_business_profile_provider as provider
from _knowledge_social_google_business_profile_records import serialize_records
from _knowledge_social_google_business_profile_routes import build_route
from _knowledge_social_google_business_profile_transport import ApiResult

expected = {
    "location_profile", "attributes", "media", "local_posts", "reviews",
    "verification_state", "performance", "search_keywords",
}
assert set(gbp.STREAMS) == expected == set(provider.READ_STREAMS)
assert importlib.util.find_spec("googleapiclient") is None
assert build_route("attributes", "account42", "location42", "ignored", 10).params is None
reviews_route = build_route("reviews", "account42", "location42", "next-page", 10)
assert reviews_route.params == {"pageSize": 10, "pageToken": "next-page"}

identity = provider.Identity("subject42", "account42", "organization42", "location42")
responses = {
    "location_profile": {"name": "locations/location42", "title": "Synthetic", "profile": {"description": "Profile evidence"}, "serviceItems": [{"structuredServiceItem": {}}]},
    "attributes": {"attributes": [{"attributeId": "wheelchair_accessible", "values": [True]}]},
    "media": {"mediaItems": [{"name": "media-one", "mediaFormat": "PHOTO"}]},
    "local_posts": {"localPosts": [{"name": "post-one", "summary": "Update"}]},
    "reviews": {"reviews": [{"reviewId": "review-one", "comment": "Feedback", "reviewReply": {"comment": "Reply"}}]},
    "verification_state": {"hasVoiceOfMerchant": True},
    "performance": {"multiDailyMetricTimeSeries": [{"dailyMetric": "CALL_CLICKS", "timeSeries": {"datedValues": []}}]},
    "search_keywords": {"searchKeywordsCounts": [{"searchKeyword": "synthetic query", "insightsValue": {"value": "2"}}]},
}
for stream, payload in responses.items():
    records = serialize_records(stream, payload, identity.location_id)
    assert records, stream
assert len(serialize_records("reviews", responses["reviews"], identity.location_id)) == 2
performance_id = serialize_records(
    "performance", responses["performance"], identity.location_id
)[0]["remote_id"]
responses["performance"]["multiDailyMetricTimeSeries"][0]["timeSeries"] = {
    "datedValues": [{"date": {"year": 2026, "month": 7, "day": 30}, "value": "9"}]
}
assert serialize_records(
    "performance", responses["performance"], identity.location_id
)[0]["remote_id"] == performance_id
keyword_id = serialize_records(
    "search_keywords", responses["search_keywords"], identity.location_id
)[0]["remote_id"]
responses["search_keywords"]["searchKeywordsCounts"][0]["insightsValue"] = {
    "value": "99"
}
assert serialize_records(
    "search_keywords", responses["search_keywords"], identity.location_id
)[0]["remote_id"] == keyword_id

page_request = {
    "stream": "reviews", "location_id": "location42",
    "business_account_id": "account42", "organization_id": "organization42",
    "cursor": None, "stop_at": None, "limit": 10,
}
state = {"route_seen": False, "userinfo_calls": 0}

def fake_api(base, path, params):
    del base, params
    if path == "/userinfo":
        state["userinfo_calls"] += 1
        if state["route_seen"] and state.get("drift"):
            return ApiResult(403, {})
        return ApiResult(200, {"sub": "subject42"})
    if path == "/accounts/account42":
        return ApiResult(200, {"name": "accounts/account42"})
    if path == "/accounts/organization42":
        return ApiResult(200, {"name": "accounts/organization42"})
    if path == "/locations/location42":
        return ApiResult(200, {"name": "locations/location42", "title": "Synthetic"})
    if path.endswith("/reviews"):
        state["route_seen"] = True
        return ApiResult(200, {"reviews": []})
    raise AssertionError(path)

guarded = provider._guarded_page(fake_api, page_request, identity)
assert guarded["status"] == 200
assert state == {"route_seen": True, "userinfo_calls": 2}
state = {"route_seen": False, "userinfo_calls": 0, "drift": True}
guarded = provider._guarded_page(fake_api, page_request, identity)
assert guarded["status"] == 403 and "data" not in guarded
assert state["userinfo_calls"] == 2

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_google_business_profile*.py"))
]
calls = [
    node
    for source in sources
    for node in ast.walk(ast.parse(source))
    if isinstance(node, ast.Call)
]
request_calls = [
    node for node in calls
    if isinstance(node.func, ast.Name) and node.func.id == "Request"
]
assert request_calls
for node in request_calls:
    methods = [
        keyword.value.value
        for keyword in node.keywords
        if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
    ]
    assert methods == ["GET"]
for forbidden in ('method="POST"', 'method="PATCH"', 'method="DELETE"'):
    assert all(forbidden not in source for source in sources)
PY
assert_eq "all streams serialize and HTTP reachability is GET-only" verified verified

mismatch="${TMP_DIR}/mismatch.json"
python3 - "$mismatch" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "id": "otherlocation", "business_account_id": "account42",
        "organization_id": "organization42", "google_identity_verified": True,
    }},
    "pages": [],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
if python3 "$COLLECTOR" --base "$BASE" --alias personal:default \
	--connection-id conn_mismatch --account-id location42 --stream reviews \
	--profile fixture --fixture "$mismatch" >/dev/null 2>&1; then
	assert_eq "wrong-location fixture fails closed" accepted rejected
else
	assert_eq "wrong-location fixture fails closed" rejected rejected
fi
assert_eq "identity mismatch persists no connection or evidence" \
	"$(sql_value "SELECT count(*) FROM connections WHERE connection_id='conn_mismatch'")" 0

credential_fixture="${TMP_DIR}/credential.json"
python3 - "$credential_fixture" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "id": "location42", "business_account_id": "account42",
        "organization_id": "organization42", "google_identity_verified": True,
    }},
    "pages": [{"response": {
        "status": 200, "observed_at": "2026-07-30T11:00:00Z",
        "data": [{"kind": "review", "remote_id": "unsafe", "access_token": "redacted"}],
        "meta": {"next_cursor": None, "complete": True, "snapshot": True},
    }}],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
if python3 "$COLLECTOR" --base "$BASE" --alias personal:default \
	--connection-id conn_credential --account-id location42 --stream reviews \
	--profile fixture --fixture "$credential_fixture" >/dev/null 2>&1; then
	assert_eq "credential-shaped provider content fails before persistence" accepted rejected
else
	assert_eq "credential-shaped provider content fails before persistence" rejected rejected
fi
assert_eq "rejected credential-shaped page writes no raw batch" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_credential'")" 0

if ((FAIL > 0)); then
	printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
	exit 1
fi
printf '\n%d passed, 0 failed\n' "$PASS"
exit 0
