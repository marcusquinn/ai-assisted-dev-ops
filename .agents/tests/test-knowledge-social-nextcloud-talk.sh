#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-nextcloud-talk.sh — Nextcloud Talk collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/../scripts"
COLLECTOR="${SCRIPTS}/knowledge_social_nextcloud_talk.py"
CORPUS_HELPER="${SCRIPTS}/knowledge-corpus-helper.sh"
SOCIAL_HELPER="${SCRIPTS}/knowledge-social-helper.sh"
FIXTURES="${SCRIPT_DIR}/fixtures/knowledge-social-nextcloud-talk"
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

collect() {
	local connection_id="$1"
	local stream="$2"
	local fixture="$3"
	local result=0
	shift 3
	python3 "$COLLECTOR" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id user_fixture \
		--stream "$stream" --profile fixture --fixture "$fixture" "$@" || result=$?
	return "$result"
}

expect_failure() {
	local description="$1"
	local connection_id="$2"
	local stream="$3"
	local fixture="$4"
	if collect "$connection_id" "$stream" "$fixture" >/dev/null 2>&1; then
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

printf 'Nextcloud Talk social collector tests\n'

help_output=$(python3 "$COLLECTOR" --help)
if [[ "$help_output" == *"{capabilities,rooms,participants,messages}"* &&
	"$help_output" == *"--page-size PAGE_SIZE"* ]]; then
	assert_eq "provider CLI exposes only reviewed streams" reviewed reviewed
else
	assert_eq "provider CLI exposes only reviewed streams" missing reviewed
fi

python3 - "$SCRIPTS" <<'PY'
import ast
import hashlib
import hmac
import json
import os
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))

from _knowledge_social_nextcloud_talk import (
    CursorState,
    STREAMS,
    namespaced_id,
    page_request,
    private_fingerprint,
)
from _knowledge_social_nextcloud_talk_files import AttachmentPolicy, validate_attachment_bytes
from _knowledge_social_nextcloud_talk_http import (
    HTTP_TIMEOUT_SECONDS,
    ProfileConfig,
    api,
    canonical_base_url,
    installation_fingerprint,
)
from _knowledge_social_nextcloud_talk_provider import _profile
from _knowledge_social_nextcloud_talk_webhook import WebhookPolicy, verify_and_normalize_webhook

assert set(STREAMS) == {"capabilities", "rooms", "participants", "messages"}
origin = "o" * 32
base_a = canonical_base_url("https://cloud-a.example.invalid/nextcloud/")
base_b = canonical_base_url("https://cloud-b.example.invalid/nextcloud")
instance_a = installation_fingerprint(base_a, origin)
instance_b = installation_fingerprint(base_b, origin)
assert instance_a != instance_b
assert namespaced_id(instance_a, "message", "42") != namespaced_id(
    instance_b, "message", "42"
)
for invalid in (
    "http://cloud.example.invalid",
    "https://user@cloud.example.invalid",
    "https://cloud.example.invalid/%2e%2e/admin",
):
    try:
        canonical_base_url(invalid)
    except RuntimeError:
        pass
    else:
        raise AssertionError("unsafe Nextcloud base URL was accepted")

os.environ.update(
    {
        "NEXTCLOUD_TALK_SCOPE_BASE_URL": base_a,
        "NEXTCLOUD_TALK_SCOPE_USERNAME": "fixture-user",
        "NEXTCLOUD_TALK_SCOPE_APP_PASSWORD": "TEST_ONLY_NOT_A_SECRET",
        "NEXTCLOUD_TALK_SCOPE_ORIGIN_KEY": origin,
        "NEXTCLOUD_TALK_SCOPE_ALLOWED_ROOMS": "abcd1234,efgh5678",
        "NEXTCLOUD_TALK_SCOPE_EXPECTED_SERVER_MAJOR": "32",
        "NEXTCLOUD_TALK_SCOPE_EXPECTED_TALK_MAJOR": "22",
    }
)
profile = _profile("scope")
assert profile.allowed_rooms == ("abcd1234", "efgh5678")


class Response:
    status = 200
    headers = {}

    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def read(self, size=-1):
        return self.payload[:size]


class Opener:
    def __init__(self):
        self.requests = []

    def open(self, request, timeout):
        assert timeout == HTTP_TIMEOUT_SECONDS
        assert request.method == "GET"
        assert "TEST_ONLY_NOT_A_SECRET" not in request.full_url
        self.requests.append(request)
        return Response({"ocs": {"meta": {"statuscode": 100}, "data": {"id": "fixture-user"}}})


opener = Opener()
assert api(profile, opener, "/ocs/v2.php/cloud/user", {}).status == 200
try:
    api(profile, opener, "/ocs/v2.php/apps/spreed/api/v1/bot/abcd1234/message", {})
except RuntimeError:
    pass
else:
    raise AssertionError("Nextcloud Talk bot mutation route was reachable")

account = {
    "id": namespaced_id(instance_a, "user", "selected"),
    "provider_account_id": "1" * 24,
    "instance_id": instance_a,
    "room_ids": [namespaced_id(instance_a, "room", "one"), namespaced_id(instance_a, "room", "two")],
}
request = page_request("messages", account, CursorState(None, None, False), 50)
assert request.room_index == 0 and request.position == 0

content = b"fixture bytes"
digest = hashlib.sha256(content).hexdigest()
verified = validate_attachment_bytes(
    content,
    AttachmentPolicy(digest, len(content), "text/plain", 1024, frozenset({"text/plain"})),
)
assert verified.content_sha256 == digest

token = "abcd1234"
room = (
    f"nct_{instance_a}_room_"
    f"{private_fingerprint(origin, instance_a, 'room', token)}"
)
body = json.dumps(
    {
        "type": "Create",
        "actor": {"type": "Person", "id": "users/fixture-user"},
        "object": {"type": "Note", "id": "42", "name": "message"},
        "target": {"type": "Collection", "id": token},
    },
    separators=(",", ":"),
).encode()
random_value = "R" * 64
secret = "s" * 32
signature = hmac.new(secret.encode(), random_value.encode() + body, hashlib.sha256).hexdigest()
event = verify_and_normalize_webhook(
    body,
    {
        "X-Nextcloud-Talk-Random": random_value,
        "X-Nextcloud-Talk-Signature": signature,
        "X-Nextcloud-Talk-Backend": base_a,
    },
    WebhookPolicy(secret, base_a, origin, instance_a, {token: room}),
)
assert event["room_id"] == room and event["requires_ocs_reconciliation"] is True
try:
    verify_and_normalize_webhook(
        body,
        {
            "X-Nextcloud-Talk-Random": random_value,
            "X-Nextcloud-Talk-Signature": "0" * 64,
            "X-Nextcloud-Talk-Backend": base_a,
        },
        WebhookPolicy(secret, base_a, origin, instance_a, {token: room}),
    )
except RuntimeError:
    pass
else:
    raise AssertionError("invalid Talk webhook signature was accepted")

sources = [
    path.read_text(encoding="utf-8")
    for path in sorted(scripts.glob("_knowledge_social_nextcloud_talk*.py"))
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
assert all("_knowledge_social_outbound" not in source for source in sources)
PY
assert_eq "versions, origins, GET-only routes, webhooks, and file budgets are guarded" \
	verified verified

first_result=$(collect conn_a messages "$FIXTURES/messages-first.json" --budget 4 --page-size 2)
assert_eq "one bounded OCS page pauses the initial history backfill" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "page evidence and room cursor commit atomically" \
	"$(sql_value "SELECT count(*) || ':' || (SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_a' AND stream='messages') FROM fetch_batches WHERE connection_id='conn_a'")" \
	"1:0"
assert_eq "message text reaches canonical full-text search" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'bounded'")" 1
assert_eq "edit and reaction observations become canonical activities" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='nextcloud_talk' AND activity_type IN ('message_edited','reaction_summary')")" 2
assert_eq "message-linked attachment metadata is bounded and non-hydrated" \
	"$(sql_value "SELECT count(*) || ':' || min(hydration_state) FROM media WHERE provider='nextcloud_talk'")" \
	"1:metadata"

resume_result=$(collect conn_a messages "$FIXTURES/messages-resume.json" --budget 7 --page-size 2)
assert_eq "history resumes at the exact room cursor and completes both rooms" \
	"$(json_field "$resume_result" status)" complete
assert_eq "completed history keeps one independent watermark per room" \
	"$(sql_value "SELECT backfill_complete || ':' || (watermark IS NOT NULL) FROM sync_cursors WHERE connection_id='conn_a' AND stream='messages'")" \
	"1:1"
assert_eq "replies, call summaries, poll observations, and federated actors persist" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='nextcloud_talk' AND object_type='message'")" 4
assert_eq "message deletion observations remain explicit canonical activities" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='nextcloud_talk' AND activity_type='message_deleted'")" 1
assert_eq "retention, encryption, reaction, poll, call, file, and webhook gaps remain explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_a' AND status='unavailable'")" 8

collect conn_b rooms "$FIXTURES/rooms-talk21.json" --budget 4 --page-size 50 >/dev/null
assert_eq "Talk 21 and Talk 22 fixture connections coexist without ID collision" \
	"$(sql_value "SELECT count(DISTINCT remote_id) FROM accounts WHERE provider='nextcloud_talk'")" 2
assert_eq "allowlisted room metadata remains instance scoped" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='nextcloud_talk' AND object_type='conversation'")" 1
collect conn_participants participants "$FIXTURES/participants.json" --budget 7 --page-size 50 >/dev/null
assert_eq "user, guest, and federated participant snapshots import per room" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='nextcloud_talk' AND object_type='participant'")" 3
expect_failure "cross-instance connection rebinding is rejected" \
	conn_a rooms "$FIXTURES/rooms-talk21.json"

python3 - "$TMP_DIR/terminal.json" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "id": "nct_aaaaaaaaaaaaaaaaaaaaaaaa_user_111111111111111111111111",
        "provider_account_id": "111111111111111111111111",
        "instance_id": "aaaaaaaaaaaaaaaaaaaaaaaa",
        "room_ids": ["nct_aaaaaaaaaaaaaaaaaaaaaaaa_room_222222222222222222222222"],
        "server_version": "32.0.8",
        "talk_version": "22.0.4",
        "features": ["chat-v2", "conversation-v4"],
    }},
    "pages": [{"status": 403, "observed_at": "2026-07-31T12:04:00Z"}],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
terminal_result=$(collect conn_terminal participants "$TMP_DIR/terminal.json")
assert_eq "lost room authority is a terminal authorization result" \
	"$(json_field "$terminal_result" failure_class)" authorization
assert_eq "terminal authority failure advances no checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_terminal'")" 0

python3 - "$TMP_DIR/credential.json" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {
        "id": "nct_aaaaaaaaaaaaaaaaaaaaaaaa_user_111111111111111111111111",
        "provider_account_id": "111111111111111111111111",
        "instance_id": "aaaaaaaaaaaaaaaaaaaaaaaa",
        "room_ids": ["nct_aaaaaaaaaaaaaaaaaaaaaaaa_room_222222222222222222222222"],
        "server_version": "32.0.8",
        "talk_version": "22.0.4",
        "features": ["chat-v2", "conversation-v4"],
    }},
    "pages": [{
        "status": 200,
        "observed_at": "2026-07-31T12:05:00Z",
        "app_password": "MUST_NOT_PERSIST",
        "data": [],
        "meta": {
            "stream": "participants",
            "instance_id": "aaaaaaaaaaaaaaaaaaaaaaaa",
            "room_id": "nct_aaaaaaaaaaaaaaaaaaaaaaaa_room_222222222222222222222222",
            "next_room_index": 1,
            "next_position": 0,
            "newest_id": None,
            "reached_watermark": False,
            "complete": True,
        },
    }],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
expect_failure "credential-shaped OCS evidence is rejected before persistence" \
	conn_credential participants "$TMP_DIR/credential.json"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
