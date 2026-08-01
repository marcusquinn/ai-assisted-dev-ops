#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-telegram.sh — Telegram export and bot-event ingestion tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
CORPUS_HELPER="${SCRIPTS_DIR}/knowledge-corpus-helper.sh"
COLLECTOR="${SCRIPTS_DIR}/knowledge_social_telegram.py"
FIXTURES="${SCRIPT_DIR}/fixtures/knowledge-social-telegram"
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

raw_count() {
	local connection_id="$1"
	python3 - "$ROOT" "$connection_id" <<'PY'
import sys
from pathlib import Path

directory = Path(sys.argv[1]) / "sources" / "social" / "raw" / "telegram" / sys.argv[2]
print(len(list(directory.glob("*.json.gz"))) if directory.exists() else 0)
PY
	return 0
}

expect_failure() {
	local description="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		assert_eq "$description" accepted rejected
	else
		assert_eq "$description" rejected rejected
	fi
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null

printf 'Telegram knowledge ingestion tests\n'

python3 - "$SCRIPTS_DIR" <<'PY'
import ast
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
for target in scripts.glob("*knowledge_social_telegram*.py"):
    source = target.read_text(encoding="utf-8")
    tree = ast.parse(source)
    imported = {
        node.module or ""
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom)
    }
    imported.update(
        alias.name
        for node in ast.walk(tree)
        if isinstance(node, ast.Import)
        for alias in node.names
    )
    assert "urllib.request" not in imported
    assert "requests" not in imported
    assert "subprocess" not in imported
    assert "socket" not in imported
    assert not any("outbound" in name or "browser" in name for name in imported)
    assert "getUpdates" not in source
    assert "setWebhook" not in source
    assert "sendMessage" not in source
PY
assert_eq "collector has no network, subprocess, polling, webhook, or outbound reachability" \
	isolated isolated

dry_run=$(python3 "$COLLECTOR" import-export \
	--input "$FIXTURES/export.json" --connection-id conn_export \
	--expected-id 1001 --allow-chat=-200 --observed-at 2026-07-30T10:10:00Z \
	--dry-run)
assert_eq "export dry-run validates without persistence" \
	"$(json_field "$dry_run" status)" dry-run
assert_eq "dry-run creates no Telegram raw evidence" \
	"$(
		python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

print(len(list(Path(sys.argv[1]).glob("sources/social/raw/telegram/**/*"))))
PY
	)" 0

export_result=$(python3 "$COLLECTOR" import-export --base "$BASE" \
	--alias personal:default --input "$FIXTURES/export.json" \
	--connection-id conn_export --expected-id 1001 --allow-chat=-200 \
	--observed-at 2026-07-30T10:10:00Z)
assert_eq "official JSON export imports" "$(json_field "$export_result" status)" complete
assert_eq "selected export identity is bound" \
	"$(sql_value "SELECT remote_account_id FROM connections WHERE connection_id='conn_export'")" \
	user1001
assert_eq "topic, reply, edit, reaction, and poll evidence stays attached to the message" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='telegram' AND remote_id='chat:-200:message:10' AND provider_json LIKE '%message_thread_id%' AND provider_json LIKE '%reply_to_message_id%' AND provider_json LIKE '%reactions%' AND provider_json LIKE '%poll%'")" 1
assert_eq "export service events retain actor, action, and topic identity" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='telegram' AND remote_id='chat:-200:message:11' AND account_remote_id='user1001' AND provider_json LIKE '%topic_created%' AND provider_json LIKE '%Synthetic topic%'")" 1
assert_eq "export media bytes are copied into private immutable storage" \
	"$(sql_value "SELECT hydration_state || ':' || coalesce(byte_size,0) FROM media WHERE provider='telegram' AND remote_id LIKE 'attachment:chat:-200:message:10:sha256:%'")" \
	local:41
assert_eq "Secret Chats remain explicit unavailable coverage" \
	"$(sql_value "SELECT status FROM coverage_records WHERE provider='telegram' AND connection_id='conn_export' AND stream='secret_chats'")" \
	unavailable
replay=$(python3 "$COLLECTOR" import-export --base "$BASE" \
	--alias personal:default --input "$FIXTURES/export.json" \
	--connection-id conn_export --expected-id 1001 --allow-chat=-200 \
	--observed-at 2026-07-30T10:10:00Z)
assert_eq "exact export replay is idempotent" "$(json_field "$replay" replayed)" True

update_result=$(python3 "$COLLECTOR" import-updates --base "$BASE" \
	--alias personal:default --input "$FIXTURES/updates.json" \
	--connection-id conn_updates --expected-id 9001 --owner-id fixture_primary_owner \
	--allow-chat=-200 --observed-at 2026-07-30T10:20:00Z)
assert_eq "existing-owner bot event fan-out imports" \
	"$(json_field "$update_result" status)" complete
assert_eq "out-of-order Telegram IDs advance the independent fan-out sequence" \
	"$(sql_value "SELECT cursor FROM sync_cursors WHERE connection_id='conn_updates' AND stream='bot_updates'")" \
	4
assert_eq "export/live overlap converges on one stable chat-message identity" \
	"$(sql_value "SELECT count(*) || ':' || max(text_content) FROM objects WHERE provider='telegram' AND remote_id='chat:-200:message:10'")" \
	"1:Synthetic message edited by event fan-out"
assert_eq "Bot API file IDs are not projected into searchable provider data" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider_json LIKE '%private-transport-value%'")" 0
assert_eq "fan-out media remains explicit remote-only evidence" \
	"$(sql_value "SELECT hydration_state FROM media WHERE provider='telegram' AND remote_id='attachment:chat:-200:message:10:bot-file:fixture-unique-document'")" \
	remote_only
assert_eq "membership transition details survive normalization" \
	"$(sql_value "SELECT count(*) FROM activities WHERE activity_type='chat_member' AND provider_json LIKE '%administrator%' AND provider_json LIKE '%user2002%'")" 1
assert_eq "anonymous reactions retain canonical actor-chat identity" \
	"$(sql_value "SELECT actor_remote_id FROM activities WHERE activity_type='message_reaction'")" \
	actor_chat:-200
assert_eq "privacy, installation time, and per-chat authority are durably recorded" \
	"$(sql_value "SELECT count(*) FROM connections WHERE connection_id='conn_updates' AND policy_json LIKE '%2026-07-30T09:00:00Z%' AND policy_json LIKE '%administrator%'")" 1

python3 - "$FIXTURES/updates.json" "$TMP_DIR/competing.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
payload["owner_id"] = "fixture_competing_owner"
Path(sys.argv[2]).write_text(json.dumps(payload), encoding="utf-8")
PY
expect_failure "a competing Bot API update owner cannot rebind the stream" \
	python3 "$COLLECTOR" import-updates --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/competing.json" --connection-id conn_updates \
	--expected-id 9001 --owner-id fixture_competing_owner --allow-chat=-200 \
	--observed-at 2026-07-30T10:21:00Z
assert_eq "rejected competing ownership writes no raw evidence" \
	"$(raw_count conn_updates)" 1
expect_failure "wrong bot identity fails before persistence" \
	python3 "$COLLECTOR" import-updates --base "$BASE" --alias personal:default \
	--input "$FIXTURES/updates.json" --connection-id conn_wrong_bot \
	--expected-id 9999 --owner-id fixture_primary_owner --allow-chat=-200 \
	--observed-at 2026-07-30T10:20:00Z
expect_failure "non-allowlisted chats fail closed" \
	python3 "$COLLECTOR" import-updates --base "$BASE" --alias personal:default \
	--input "$FIXTURES/updates.json" --connection-id conn_wrong_chat \
	--expected-id 9001 --owner-id fixture_primary_owner --allow-chat=-999 \
	--observed-at 2026-07-30T10:20:00Z
expect_failure "Bot event imports require an explicit chat allowlist" \
	python3 "$COLLECTOR" import-updates --base "$BASE" --alias personal:default \
	--input "$FIXTURES/updates.json" --connection-id conn_missing_allowlist \
	--expected-id 9001 --owner-id fixture_primary_owner \
	--observed-at 2026-07-30T10:20:00Z

python3 - "$FIXTURES/export.json" "$FIXTURES/updates.json" "$TMP_DIR" <<'PY'
import copy
import json
import os
import sys
from pathlib import Path

export = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
updates = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
target = Path(sys.argv[3])

extra_chat = copy.deepcopy(export)
extra_chat["chats"]["list"].append(
    {"name": "Outside Scope", "type": "personal_chat", "id": 999, "messages": []}
)
(target / "extra-chat.json").write_text(json.dumps(extra_chat), encoding="utf-8")

duplicate_chat = copy.deepcopy(export)
duplicate_chat["chats"]["list"].append(copy.deepcopy(export["chats"]["list"][0]))
(target / "duplicate-chat.json").write_text(json.dumps(duplicate_chat), encoding="utf-8")

malformed_contacts = copy.deepcopy(export)
malformed_contacts["contacts"] = []
(target / "malformed-contacts.json").write_text(
    json.dumps(malformed_contacts), encoding="utf-8"
)

credential_export = copy.deepcopy(export)
credential_export["api_token"] = "synthetic-forbidden-value"
(target / "credential-export.json").write_text(
    json.dumps(credential_export), encoding="utf-8"
)

credential_updates = copy.deepcopy(updates)
credential_updates["bot"]["token"] = "synthetic-forbidden-value"
(target / "credential-updates.json").write_text(
    json.dumps(credential_updates), encoding="utf-8"
)

scoped = target / "symlink-export"
scoped.mkdir()
(scoped / "result.json").write_text(json.dumps(export), encoding="utf-8")
os.symlink(Path(sys.argv[1]).parent / "media", scoped / "media")

message = copy.deepcopy(updates["updates"][1]["edited_message"])
message["text"] = "Newest contiguous event"
stale_message = copy.deepcopy(message)
stale_message["text"] = "Stale event must not roll state back"
deletion = {
    "business_connection_id": "fixture-business",
    "chat": {"id": -200, "type": "private", "first_name": "Fixture"},
    "message_ids": [70, 71],
}
future = copy.deepcopy(updates)
future["observed_at"] = "2026-07-30T10:30:00Z"
future["updates"] = [
    {"update_id": 503, "fanout_sequence": 3, "edited_message": stale_message},
    {"update_id": 900, "fanout_sequence": 4, "edited_message": message},
    {"update_id": 1200, "fanout_sequence": 5, "deleted_business_messages": deletion},
    {"update_id": 900, "fanout_sequence": 4, "edited_message": message},
]
(target / "future.json").write_text(json.dumps(future), encoding="utf-8")

conflicting_update_id = copy.deepcopy(updates)
conflicting_message = copy.deepcopy(message)
conflicting_message["text"] = "Conflicting duplicate Telegram update ID"
conflicting_update_id["updates"] = [
    {"update_id": 9001, "fanout_sequence": 6, "edited_message": message},
    {
        "update_id": 9001,
        "fanout_sequence": 7,
        "edited_message": conflicting_message,
    },
]
(target / "conflicting-update-id.json").write_text(
    json.dumps(conflicting_update_id), encoding="utf-8"
)

stale = copy.deepcopy(updates)
stale["observed_at"] = "2026-07-30T10:31:00Z"
stale["bot"]["first_name"] = "Stale bot identity"
stale["chat_authority"]["-200"]["member_status"] = "member"
stale["updates"] = [
    {"update_id": 503, "fanout_sequence": 3, "edited_message": stale_message}
]
(target / "stale.json").write_text(json.dumps(stale), encoding="utf-8")

gap = copy.deepcopy(updates)
gap["observed_at"] = "2026-07-30T10:32:00Z"
gap["updates"] = [
    {"update_id": 5000, "fanout_sequence": 8, "edited_message": message}
]
(target / "gap.json").write_text(json.dumps(gap), encoding="utf-8")

poll = copy.deepcopy(updates)
poll["updates"] = [
    {
        "update_id": 1,
        "fanout_sequence": 1,
        "poll": {"id": "poll-1", "question": "Unscoped?"},
    }
]
(target / "unscoped-poll.json").write_text(json.dumps(poll), encoding="utf-8")

service_update = copy.deepcopy(updates)
service_update["allowed_updates"] = ["message"]
service_update["updates"] = [
    {
        "update_id": 7001,
        "fanout_sequence": 1,
        "message": {
            "message_id": 12,
            "from": {"id": 1001, "is_bot": False, "first_name": "Fixture"},
            "chat": {"id": -200, "type": "supergroup", "is_forum": True},
            "date": 1785407000,
            "new_chat_members": [
                {"id": 2002, "is_bot": False, "first_name": "Fixture"}
            ],
            "forum_topic_created": {"name": "Synthetic service topic"},
        },
    }
]
(target / "service-update.json").write_text(
    json.dumps(service_update), encoding="utf-8"
)
PY

expect_failure "raw exports must exactly match the explicit chat scope" \
	python3 "$COLLECTOR" import-export --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/extra-chat.json" --connection-id conn_extra_chat \
	--expected-id 1001 --allow-chat=-200 --observed-at 2026-07-30T10:10:00Z
expect_failure "duplicate export chat identities fail closed" \
	python3 "$COLLECTOR" import-export --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/duplicate-chat.json" --connection-id conn_duplicate_chat \
	--expected-id 1001 --allow-chat=-200 --observed-at 2026-07-30T10:10:00Z
expect_failure "malformed optional export categories fail closed" \
	python3 "$COLLECTOR" import-export --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/malformed-contacts.json" --connection-id conn_bad_contacts \
	--expected-id 1001 --allow-chat=-200 --observed-at 2026-07-30T10:10:00Z
expect_failure "credential-shaped export keys fail before raw persistence" \
	python3 "$COLLECTOR" import-export --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/credential-export.json" --connection-id conn_credential_export \
	--expected-id 1001 --allow-chat=-200 --observed-at 2026-07-30T10:10:00Z
expect_failure "credential-shaped update keys fail before raw persistence" \
	python3 "$COLLECTOR" import-updates --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/credential-updates.json" --connection-id conn_credential_updates \
	--expected-id 9001 --owner-id fixture_primary_owner --allow-chat=-200 \
	--observed-at 2026-07-30T10:20:00Z
expect_failure "symlinked media path components cannot escape the export root" \
	python3 "$COLLECTOR" import-export --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/symlink-export/result.json" --connection-id conn_symlink \
	--expected-id 1001 --allow-chat=-200 --observed-at 2026-07-30T10:10:00Z
expect_failure "chatless poll updates are not accepted into scoped raw evidence" \
	python3 "$COLLECTOR" import-updates --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/unscoped-poll.json" --connection-id conn_poll \
	--expected-id 9001 --owner-id fixture_primary_owner --allow-chat=-200 \
	--observed-at 2026-07-30T10:20:00Z

service_result=$(python3 "$COLLECTOR" import-updates --base "$BASE" \
	--alias personal:default --input "$TMP_DIR/service-update.json" \
	--connection-id conn_service --expected-id 9001 --owner-id fixture_primary_owner \
	--allow-chat=-200 --observed-at 2026-07-30T10:23:20Z)
assert_eq "Bot API service events import through the scoped message route" \
	"$(json_field "$service_result" status)" complete
assert_eq "service event types and exposed member identity remain queryable" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='telegram' AND remote_id='chat:-200:message:12' AND provider_json LIKE '%forum_topic_created%' AND provider_json LIKE '%new_chat_members%' AND provider_json LIKE '%user2002%'")" 1

future=$(python3 "$COLLECTOR" import-updates --base "$BASE" \
	--alias personal:default --input "$TMP_DIR/future.json" \
	--connection-id conn_updates --expected-id 9001 --owner-id fixture_primary_owner \
	--allow-chat=-200 --observed-at 2026-07-30T10:30:00Z)
assert_eq "exact duplicate and stale update deliveries converge" \
	"$(json_field "$future" next_offset)" 6
assert_eq "newest contiguous update wins stable message projection" \
	"$(sql_value "SELECT text_content FROM objects WHERE provider='telegram' AND remote_id='chat:-200:message:10'")" \
	"Newest contiguous event"
assert_eq "business deletion observations retain every deleted message identity" \
	"$(sql_value "SELECT count(*) FROM activities WHERE activity_type='deleted_business_messages' AND state='deleted'")" 2

expect_failure "conflicting duplicate Telegram update IDs fail atomically" \
	python3 "$COLLECTOR" import-updates --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/conflicting-update-id.json" --connection-id conn_updates \
	--expected-id 9001 --owner-id fixture_primary_owner --allow-chat=-200 \
	--observed-at 2026-07-30T10:30:30Z
assert_eq "rejected duplicate update IDs leave the cursor unchanged" \
	"$(sql_value "SELECT cursor FROM sync_cursors WHERE connection_id='conn_updates' AND stream='bot_updates'")" 6

policy_before=$(sql_value "SELECT policy_json FROM connections WHERE connection_id='conn_updates'")
account_before=$(sql_value "SELECT display_name FROM accounts WHERE provider='telegram' AND remote_id='bot9001'")
coverage_before=$(sql_value "SELECT observed_at FROM coverage_records WHERE provider='telegram' AND connection_id='conn_updates' AND stream='bot_updates'")
raw_before=$(raw_count conn_updates)
python3 "$COLLECTOR" import-updates --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/stale.json" --connection-id conn_updates \
	--expected-id 9001 --owner-id fixture_primary_owner --allow-chat=-200 \
	--observed-at 2026-07-30T10:31:00Z >/dev/null
assert_eq "stale event batches cannot roll projections backward" \
	"$(sql_value "SELECT text_content FROM objects WHERE provider='telegram' AND remote_id='chat:-200:message:10'")" \
	"Newest contiguous event"
assert_eq "stale batches retain immutable raw evidence" "$(raw_count conn_updates)" "$((raw_before + 1))"
assert_eq "stale batches cannot overwrite connection policy" \
	"$(sql_value "SELECT policy_json FROM connections WHERE connection_id='conn_updates'")" "$policy_before"
assert_eq "stale batches cannot overwrite bot identity" \
	"$(sql_value "SELECT display_name FROM accounts WHERE provider='telegram' AND remote_id='bot9001'")" "$account_before"
assert_eq "stale batches cannot overwrite coverage timestamps" \
	"$(sql_value "SELECT observed_at FROM coverage_records WHERE provider='telegram' AND connection_id='conn_updates' AND stream='bot_updates'")" "$coverage_before"
expect_failure "update gaps preserve the prior durable cursor" \
	python3 "$COLLECTOR" import-updates --base "$BASE" --alias personal:default \
	--input "$TMP_DIR/gap.json" --connection-id conn_updates \
	--expected-id 9001 --owner-id fixture_primary_owner --allow-chat=-200 \
	--observed-at 2026-07-30T10:32:00Z
assert_eq "failed gap batch leaves cursor unchanged" \
	"$(sql_value "SELECT cursor FROM sync_cursors WHERE connection_id='conn_updates' AND stream='bot_updates'")" 6

status=$(python3 "$COLLECTOR" status --base "$BASE" --alias personal:default \
	--connection-id conn_updates)
assert_eq "status exposes only sanitized route checkpoint state" \
	"$(json_field "$status" connection_id)" conn_updates

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
