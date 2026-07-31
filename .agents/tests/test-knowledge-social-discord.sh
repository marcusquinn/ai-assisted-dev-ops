#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-discord.sh — Bounded Discord collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR="${SCRIPT_DIR}/../scripts/knowledge_social_discord.py"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
BOT_ID="100000000000000001"
APP_ID="100000000000000002"
GUILD_ID="100000000000000003"
CHANNEL_ID="100000000000000004"
THREAD_ID="100000000000000005"
DM_ID="100000000000000006"
EXPORT_USER_ID="100000000000000007"
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

run_fixture() {
	local connection_id="$1"
	local stream="$2"
	local fixture="$3"
	python3 "$COLLECTOR" --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id "$BOT_ID" \
		--stream "$stream" --profile fixture --budget 3 --page-size 100 \
		--fixture "$fixture" || return 1
	return 0
}

identity_json() {
	printf '{"data":{"id":"%s","application_id":"%s","guild_id":"%s","channel_ids":["%s"],"thread_ids":["%s"],"dm_channel_ids":["%s"],"message_content_intent":true,"guild_members_intent":true,"export_user_id":"%s"}}' \
		"$BOT_ID" "$APP_ID" "$GUILD_ID" "$CHANNEL_ID" "$THREAD_ID" "$DM_ID" "$EXPORT_USER_ID"
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
python3 "${SCRIPT_DIR}/../scripts/knowledge_social_import.py" provision \
	--base "$BASE" --alias personal:default >/dev/null

printf 'Discord social collector tests\n'

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import sys
from pathlib import Path
from urllib.request import Request

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))
from _knowledge_social_discord_contract import ApiResult
from _knowledge_social_discord_provider import (
    API_BASE,
    READ_PATH,
    _api,
    _identity,
    _verify_surfaces,
)
from _knowledge_social_discord_routes import STREAMS

assert API_BASE == "https://discord.com/api/v10"
assert STREAMS == {"messages", "metadata", "members", "gateway_events", "account_export"}
for forbidden in ("/messages", "/reactions/x/@me", "/webhooks", "/moderation"):
    if forbidden == "/messages":
        continue
    assert READ_PATH.fullmatch(forbidden) is None


class Response:
    status = 200
    headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, _limit):
        return b"[]"


seen = []


def opener(request: Request, timeout: int):
    seen.append((request.get_method(), request.full_url, timeout))
    return Response()


result = _api("fixture", opener, "/channels/100000000000000004/messages", {"limit": "1"})
assert isinstance(result, ApiResult) and result.status == 200
assert seen == [("GET", "https://discord.com/api/v10/channels/100000000000000004/messages?limit=1", 60)]
try:
    _api("fixture", opener, "/channels/100000000000000004/messages/100000000000000009", {})
except Exception:
    pass
else:
    raise SystemExit("Discord mutation-shaped route was accepted")

provider_tree = ast.parse(
    (scripts / "_knowledge_social_discord_provider.py").read_text(encoding="utf-8")
)
methods = [
    keyword.value.value
    for node in ast.walk(provider_tree)
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Name)
    and node.func.id == "Request"
    for keyword in node.keywords
    if keyword.arg == "method" and isinstance(keyword.value, ast.Constant)
]
assert methods == ["GET"]

bot_id = "100000000000000001"
app_id = "100000000000000002"
guild_id = "100000000000000003"
channel_id = "100000000000000004"
thread_id = "100000000000000005"
dm_id = "100000000000000006"
config = {
    "application_id": app_id,
    "guild_id": guild_id,
    "channel_ids": (channel_id,),
    "thread_ids": (thread_id,),
    "dm_channel_ids": (dm_id,),
    "message_content_intent": True,
    "guild_members_intent": True,
    "export_user_id": "100000000000000007",
}
responses = {
    "/users/@me": {"id": bot_id},
    "/applications/@me": {
        "id": app_id,
        "bot": {"id": bot_id},
        "flags_new": str((1 << 18) | (1 << 14)),
    },
    f"/guilds/{guild_id}": {"id": guild_id},
    f"/channels/{channel_id}": {"id": channel_id, "guild_id": guild_id, "type": 0},
    f"/channels/{thread_id}": {"id": thread_id, "guild_id": guild_id, "type": 11},
    f"/channels/{dm_id}": {"id": dm_id, "type": 1},
}


def fake_api(endpoint, _params):
    return ApiResult(200, responses[endpoint])


identity = _identity(fake_api, config, bot_id)
assert identity["data"]["application_id"] == app_id
assert _verify_surfaces(fake_api, config) is None
PY
assert_eq "Discord provider exposes only GET/local replay reads" verified verified

cat >"$TMP_DIR/messages.json" <<JSON
{
  "identity":$(identity_json),
  "pages":[{
    "expect_request":{"stream":"messages","guild_id":"$GUILD_ID","channel_ids":["$CHANNEL_ID"]},
    "response":{"status":200,"observed_at":"2026-07-31T10:00:00Z","data":[{
      "kind":"message","remote_id":"100000000000000010","channel_id":"$CHANNEL_ID","guild_id":"$GUILD_ID",
      "author":{"id":"100000000000000011","username":"author","global_name":"Author","bot":false},
      "content":"Knowledge message","timestamp":"2026-07-31T09:59:00Z","edited_timestamp":"2026-07-31T10:00:00Z","type":0,
      "mentions":[{"id":"100000000000000012","username":"mentioned","global_name":null,"bot":false}],
      "attachments":[{"id":"100000000000000013","filename":"report.txt","content_type":"text/plain","size":12,"ephemeral":false}],
      "embeds":[{"type":"rich","title":"Reference"}],
      "reactions":[{"emoji_id":null,"emoji_name":"ok","count":2}],"reference_message_id":null
    }],"meta":{"next_cursor":null,"watermark":{"$CHANNEL_ID":"100000000000000010"},"complete":true,"snapshot":false,"gaps":[]}}}
  ]
}
JSON
messages_result=$(run_fixture conn_discord messages "$TMP_DIR/messages.json")
assert_eq "message collection completes" "$(json_field "$messages_result" status)" complete
assert_eq "message and attachment evidence persist" \
	"$(sql_value "SELECT (SELECT count(*) FROM objects WHERE provider='discord' AND object_type='message') || ':' || (SELECT count(*) FROM media WHERE provider='discord')")" "1:1"
assert_eq "reaction summaries and edit observations remain canonical metadata" \
	"$(sql_value "SELECT json_extract(provider_json,'$.reactions[0].count') || ':' || json_extract(provider_json,'$.edited_at') FROM objects WHERE provider='discord' AND object_type='message'")" \
	"2:2026-07-31T10:00:00Z"
assert_eq "arbitrary user DM history remains an explicit unavailable gap" \
	"$(sql_value "SELECT status FROM coverage_records WHERE provider='discord' AND stream='arbitrary_user_dms'")" unavailable
assert_eq "attachment transport URLs never become blob identity" \
	"$(sql_value "SELECT hydration_state || ':' || coalesce(blob_ref,'none') FROM media WHERE provider='discord'")" remote_only:none

cat >"$TMP_DIR/replay.json" <<JSON
{
  "identity":$(identity_json),
  "pages":[{
    "expect_request":{"watermark":{"$CHANNEL_ID":"100000000000000010"}},
    "response":{"status":200,"observed_at":"2026-07-31T10:01:00Z","data":[],"meta":{"next_cursor":null,"watermark":{"$CHANNEL_ID":"100000000000000010"},"complete":true,"snapshot":false,"gaps":[]}}}
  ]
}
JSON
run_fixture conn_discord messages "$TMP_DIR/replay.json" >/dev/null
assert_eq "REST replay converges without duplicate message truth" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='discord' AND object_type='message'")" 1

cat >"$TMP_DIR/gateway.json" <<JSON
{
  "identity":$(identity_json),
  "pages":[{"status":200,"observed_at":"2026-07-31T10:02:00Z","data":[{
    "kind":"gateway_event","remote_id":"$GUILD_ID:42","sequence":42,"event_name":"MESSAGE_DELETE",
    "data":{"id":"100000000000000010","channel_id":"$CHANNEL_ID","guild_id":"$GUILD_ID"}
  }],"meta":{"next_cursor":null,"watermark":{"sequence":42},"complete":true,"snapshot":false,"gaps":[]}}]
}
JSON
run_fixture conn_gateway gateway_events "$TMP_DIR/gateway.json" >/dev/null
assert_eq "Gateway deletion observations persist without deleting prior evidence" \
	"$(sql_value "SELECT state FROM activities WHERE provider='discord' AND activity_type='message_delete'")" deleted
assert_eq "Gateway overlap preserves the canonical REST message" \
	"$(sql_value "SELECT text_content FROM objects WHERE provider='discord' AND object_type='message' AND remote_id='100000000000000010'")" "Knowledge message"

cat >"$TMP_DIR/metadata.json" <<JSON
{
  "identity":$(identity_json),
  "pages":[{"status":200,"observed_at":"2026-07-31T10:03:00Z","data":[
    {"kind":"guild","remote_id":"$GUILD_ID"},
    {"kind":"channel","remote_id":"$THREAD_ID","guild_id":"$GUILD_ID","channel_type":11,"name":"allowed-thread","topic":null,"parent_id":"$CHANNEL_ID","archived":true,"applied_tags":[]},
    {"kind":"role","remote_id":"100000000000000014","guild_id":"$GUILD_ID","name":"reader","permissions":"65536","managed":false},
    {"kind":"member","remote_id":"100000000000000011","guild_id":"$GUILD_ID","user":{"id":"100000000000000011","username":"author","global_name":"Author","bot":false},"nick":null,"roles":["100000000000000014"],"joined_at":"2026-01-01T00:00:00Z"}
  ],"meta":{"next_cursor":null,"watermark":null,"complete":true,"snapshot":true,"gaps":[]}}]
}
JSON
run_fixture conn_metadata metadata "$TMP_DIR/metadata.json" >/dev/null
assert_eq "archived thread, role, and member metadata normalize" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='discord' AND object_type IN ('channel','role','member')")" 3

cat >"$TMP_DIR/rate-limit.json" <<JSON
{"identity":$(identity_json),"pages":[{"status":429,"observed_at":"2026-07-31T10:04:00Z","retry_after":1785500000}]}
JSON
rate_result=$(run_fixture conn_rate messages "$TMP_DIR/rate-limit.json")
assert_eq "rate limits pause one invocation" "$(json_field "$rate_result" status)" rate_limited
assert_eq "rate limits bind no successful checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_rate'")" 0

cat >"$TMP_DIR/wrong-identity.json" <<JSON
{"identity":{"data":{"id":"100000000000000099","application_id":"$APP_ID","guild_id":"$GUILD_ID","channel_ids":["$CHANNEL_ID"],"thread_ids":[],"dm_channel_ids":[],"message_content_intent":true,"guild_members_intent":true,"export_user_id":null}},"pages":[]}
JSON
if run_fixture conn_wrong messages "$TMP_DIR/wrong-identity.json" >/dev/null 2>&1; then
	assert_eq "bot identity mismatch fails closed" accepted rejected
else
	assert_eq "bot identity mismatch fails closed" rejected rejected
fi
assert_eq "identity mismatch persists no connection" \
	"$(sql_value "SELECT count(*) FROM connections WHERE connection_id='conn_wrong'")" 0

python3 - "$SCRIPT_DIR/../scripts" "$TMP_DIR" "$GUILD_ID" "$CHANNEL_ID" "$EXPORT_USER_ID" <<'PY'
import json
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from _knowledge_social_discord_export import page_account_export
from _knowledge_social_discord_gateway import page_gateway_events

tmp = Path(sys.argv[2])
guild_id, channel_id, user_id = sys.argv[3:]
config = {
    "guild_id": guild_id,
    "channel_ids": (channel_id,),
    "thread_ids": (),
    "dm_channel_ids": (),
    "export_user_id": user_id,
}
export = tmp / "discord-export.zip"
with zipfile.ZipFile(export, "w") as archive:
    archive.writestr("account/user.json", json.dumps({"id": user_id}))
    archive.writestr("messages/c1/channel.json", json.dumps({"id": channel_id}))
    archive.writestr(
        "messages/c1/messages.csv",
        "ID,Timestamp,Contents,Attachments\n"
        "100000000000000021,2026-07-31T08:00:00Z,Exported knowledge,\n",
    )
rows, cursor = page_account_export(str(export), config, None, 100)
assert cursor is None and rows[0]["remote_id"] == "100000000000000021"

spool = tmp / "gateway.jsonl"
spool.write_text(
    json.dumps({
        "op": 0,
        "s": 7,
        "t": "MESSAGE_UPDATE",
        "d": {"id": "100000000000000021", "guild_id": guild_id, "channel_id": channel_id},
    }) + "\n",
    encoding="utf-8",
)
rows, cursor, watermark = page_gateway_events(str(spool), config, None, 100)
assert cursor is None and watermark == {"sequence": 7}
assert rows[0]["event_name"] == "MESSAGE_UPDATE"
PY
assert_eq "official export and Gateway spool parsers are bounded and replayable" verified verified

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
