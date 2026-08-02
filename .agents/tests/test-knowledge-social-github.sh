#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-github.sh — Bounded GitHub collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_SCRIPT="${SCRIPT_DIR}/../scripts/knowledge_social_github.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEMP_PARENT"
TMP_DIR=$(mktemp -d "${TEMP_PARENT}/github-social-test.XXXXXX")
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
	python3 - "$ROOT/sources/social/raw/github" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

run_github() {
	local fixture="$1"
	local connection_id="$2"
	local stream="$3"
	local budget="$4"
	local page_size="$5"
	if python3 "$GITHUB_SCRIPT" --base "$BASE" --alias personal:default \
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
	if run_github "$fixture" "$connection_id" "$stream" 11 40 >/dev/null 2>&1; then
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

printf 'GitHub social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import json
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import CursorState
from _knowledge_social_github import PageRequest, STREAMS, page_checkpoint, page_request
from _knowledge_social_github_contract import ApiResult, combined_identity
from _knowledge_social_github_http import (
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    _rate_reset,
    graphql_api,
    rest_api,
)
from _knowledge_social_github_identity import INSTANCE_ID, account_id, namespaced_id
from _knowledge_social_github_routes import (
    CONTRIBUTIONS_QUERY,
    PROJECTS_QUERY,
    USER_LISTS_QUERY,
    allowlisted_path,
    page,
)

assert set(STREAMS) == {
    "contributions", "repositories", "stars", "notifications", "followers",
    "following", "organizations", "subscriptions", "user_lists", "projects_v2",
}
assert all(spec.cost_units == 3 and spec.pagination == "snapshot" for spec in STREAMS.values())
assert STREAMS["user_lists"].transport == "graphql"
for allowed in ("/user", "/user/repos", "/notifications", "/user/subscriptions"):
    assert allowlisted_path(allowed)
for rejected in (
    "/user/following/7", "/notifications/threads/1", "/repos/o/r/issues/1",
    "/user/migrations", "/graphql",
):
    assert not allowlisted_path(rejected)

identity = combined_identity(
    {"id": 42, "node_id": "MDQ6VXNlcjQy", "login": "selected"},
    {"data": {"viewer": {"databaseId": 42, "id": "MDQ6VXNlcjQy", "login": "selected"}}},
    "42",
)
assert identity["id"] == account_id(42, "MDQ6VXNlcjQy")
assert namespaced_id("repository", "opaque-A") != namespaced_id("repository", "opaque-B")
try:
    combined_identity(
        {"id": 42, "node_id": "MDQ6VXNlcjQy", "login": "selected"},
        {"data": {"viewer": {"databaseId": 43, "id": "MDQ6VXNlcjQz", "login": "other"}}},
        "42",
    )
except RuntimeError:
    pass
else:
    raise AssertionError("mismatched GitHub REST and GraphQL identities were accepted")


class Headers:
    def __init__(self, values=None):
        self.values = values or {}

    def get(self, key, default=None):
        return self.values.get(key, default)


class Response:
    status = 200

    def __init__(self, payload, headers=None):
        self.payload = json.dumps(payload).encode()
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
        assert timeout == HTTP_TIMEOUT_SECONDS
        assert "private-token" not in request.full_url
        self.requests.append(request)
        return self.responses.pop(0)


config = ProfileConfig("private-token", "classic_pat", frozenset({"read:user"}))
assert _rate_reset(Headers({"X-RateLimit-Reset": "1785630000"})) == 1785630000
next_url = "https://api.github.com/user/repos?affiliation=owner%2Ccollaborator%2Corganization_member&per_page=2&page=2"
opener = Opener([Response([], {"Link": f'<{next_url}>; rel="next"'})])
result = rest_api(
    config, opener, "/user/repos",
    {"affiliation": "owner,collaborator,organization_member", "per_page": "2"},
)
assert result.next_url == next_url
assert opener.requests[0].method == "GET"
try:
    rest_api(config, opener, "https://api.github.com/user/following/7", {})
except RuntimeError:
    pass
else:
    raise AssertionError("GitHub write route was accepted")
try:
    graphql_api(config, opener, "mutation Unsafe { addStar(input: {}) { clientMutationId } }", {})
except RuntimeError:
    pass
else:
    raise AssertionError("GitHub GraphQL mutation was accepted")

graph_opener = Opener([Response({"data": {"viewer": {"id": "MDQ6VXNlcjQy"}}})])
graphql_api(config, graph_opener, "query Safe { viewer { id } }", {})
assert graph_opener.requests[0].method == "POST"
assert graph_opener.requests[0].full_url == "https://api.github.com/graphql"

request = PageRequest(
    "repositories", identity["id"], "42", "selected", INSTANCE_ID, 1, None, 2,
)
repository = {
    "id": 7, "node_id": "R_kgDOopaque", "name": "project", "full_name": "selected/project",
    "description": "Bounded GitHub knowledge", "private": True, "archived": False,
    "owner": {"id": 42, "node_id": "MDQ6VXNlcjQy", "login": "selected"},
}
payload = page(lambda _target, _params: ApiResult(200, [repository], next_url), lambda *_args: None, request)
assert payload["meta"]["next_cursor"] == next_url
assert payload["data"][0]["kind"] == "repository"
checkpoint, complete = page_checkpoint(payload, CursorState(None, None, False), request)
assert not complete and checkpoint.next_cursor is not None
resumed = page_request("repositories", identity, CursorState(checkpoint.next_cursor, None, False), 2)
assert resumed.position == 2 and resumed.stop_at == next_url
cross_stream = PageRequest(
    "followers", identity["id"], "42", "selected", INSTANCE_ID, 2, next_url, 2,
)
try:
    page(lambda *_args: ApiResult(200, []), lambda *_args: None, cross_stream)
except RuntimeError:
    pass
else:
    raise AssertionError("cross-stream GitHub REST Link was accepted")

for query in (CONTRIBUTIONS_QUERY, PROJECTS_QUERY, USER_LISTS_QUERY):
    normalized = " ".join(query.split()).casefold()
    assert normalized.startswith("query ") and "mutation" not in normalized

sources = [path.read_text(encoding="utf-8") for path in sorted(scripts.glob("_knowledge_social_github*.py"))]
trees = [ast.parse(source) for source in sources]
request_calls = [
    node for tree in trees for node in ast.walk(tree)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "Request"
]
assert len(request_calls) == 2
methods = {
    keyword.value.value for node in request_calls for keyword in node.keywords
    if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
}
assert methods == {"GET", "POST"}
PY
assert_eq "identity, route, opaque cursor, token, and mutation boundaries are guarded" \
	verified verified

python3 - "$TMP_DIR/complete.json" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_github_identity import INSTANCE_ID, account_id, namespaced_id

node = "MDQ6VXNlcjQy"
durable = account_id("42", node)
payload = {
    "identity": {"data": {
        "id": durable, "provider_account_id": "42", "node_id": node,
        "login": "selected", "name": "Private profile", "instance_id": INSTANCE_ID,
    }},
    "pages": [{
        "expect_request": {"position": 1, "stop_at": None, "limit": 1},
        "response": {
            "status": 200, "observed_at": "2026-08-02T06:00:00Z",
            "data": [{
                "kind": "repository", "remote_id": namespaced_id("repository", "R_kgDOopaque"),
                "node_id": "R_kgDOopaque", "name": "project", "full_name": "selected/project",
                "description": "Bounded GitHub knowledge",
                "owner_remote_id": namespaced_id("account", node),
            }],
            "meta": {"stream": "repositories", "instance_id": INSTANCE_ID,
                     "transport": "rest", "next_cursor": None,
                     "complete": True, "snapshot": True},
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
result=$(run_github "$TMP_DIR/complete.json" conn_github repositories 5 1)
assert_eq "bounded GitHub fixture completes" "$(json_field "$result" status)" complete
assert_eq "REST plus GraphQL identity and one page consume five request units" \
	"$(json_field "$result" budget_units)" 5
assert_eq "GitHub repository text reaches FTS" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1
assert_eq "completed GitHub snapshot records its checkpoint" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_github'")" \
	"done:1"

python3 - "$TMP_DIR/mismatch.json" <<'PY'
import json
import sys

payload = {"identity": {"data": {
    "id": "wrong", "provider_account_id": "43", "node_id": "MDQ6VXNlcjQz",
    "login": "other", "instance_id": "github-com",
}}, "pages": []}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "selected-account identity mismatch is rejected" \
	"$TMP_DIR/mismatch.json" conn_mismatch repositories
assert_eq "identity mismatch persists no raw evidence" "$(raw_count)" "$raw_before"

python3 - "$TMP_DIR/credential.json" <<'PY'
import json
import sys

sys.path.insert(0, ".agents/scripts")
from _knowledge_social_github_identity import INSTANCE_ID, account_id

node = "MDQ6VXNlcjQy"
payload = {
    "identity": {"data": {"id": account_id("42", node), "provider_account_id": "42",
                            "node_id": node, "login": "selected", "instance_id": INSTANCE_ID}},
    "pages": [{"status": 200, "observed_at": "2026-08-02T06:01:00Z",
               "access_token": "must-not-persist", "data": [],
               "meta": {"stream": "stars", "instance_id": INSTANCE_ID,
                        "transport": "rest", "next_cursor": None,
                        "complete": True, "snapshot": True}}],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
raw_before=$(raw_count)
expect_failure "credential-shaped GitHub page is rejected" \
	"$TMP_DIR/credential.json" conn_credential stars
assert_eq "credential rejection persists no raw evidence" "$(raw_count)" "$raw_before"

assert_eq "unsupported historical categories remain explicit gaps" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_github' AND status='unavailable' AND stream IN ('reactions','migration_archives','deleted_resources','private_resources','organization_audit_logs')")" 5

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
