#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-signal.sh — side-effect-free Signal event ingestion tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge_social_signal.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
CONFIG="${TMP_DIR}/signal-config.json"
EVENTS="${TMP_DIR}/signal-events.jsonl"
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

expect_failure() {
	local description="$1"
	local config="$2"
	local events="$3"
	if python3 "$SIGNAL_HELPER" inspect --config "$config" --events "$events" \
		--observed-at 2026-07-31T12:00:00Z >/dev/null 2>&1; then
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

cat >"$CONFIG" <<'JSON'
{"schema_version":1,"account":"+15550001000","account_alias":"signal_personal","connection_id":"conn_signal_personal","signal_cli_version":"0.14.6"}
JSON
chmod 0600 "$CONFIG"

cat >"$EVENTS" <<'JSONL'
{"jsonrpc":"2.0","method":"receive","params":{"account":"+15550001000","envelope":{"sourceNumber":"+15550001001","sourceUuid":"11111111-1111-4111-8111-111111111111","sourceName":"Fixture Contact","timestamp":1785492000000,"dataMessage":{"timestamp":1785492000000,"message":"fixture direct message","expiresInSeconds":0,"viewOnce":false,"quote":{"id":1785491000000,"authorUuid":"22222222-2222-4222-8222-222222222222","text":"not duplicated"},"attachments":[{"contentType":"image/png","filename":"private-name.png","id":"fixture-attachment","size":2048}]}}}}
{"jsonrpc":"2.0","method":"receive","params":{"account":"+15550001000","envelope":{"sourceUuid":"11111111-1111-4111-8111-111111111111","timestamp":1785492100000,"dataMessage":{"timestamp":1785492100000,"message":"must not persist","expiresInSeconds":60,"viewOnce":false,"groupInfo":{"groupId":"fixture-group"},"attachments":[]}}}}
{"jsonrpc":"2.0","method":"receive","params":{"account":"+15550001000","envelope":{"sourceUuid":"11111111-1111-4111-8111-111111111111","timestamp":1785492200000,"dataMessage":{"timestamp":1785492200000,"message":"view once secret","expiresInSeconds":0,"viewOnce":true,"attachments":[{"contentType":"image/jpeg","filename":"secret.jpg","id":"view-once","size":4096}]}}}}
{"jsonrpc":"2.0","method":"receive","params":{"account":"+15550001000","envelope":{"sourceUuid":"11111111-1111-4111-8111-111111111111","timestamp":1785492300000,"dataMessage":{"timestamp":1785492300000,"expiresInSeconds":0,"viewOnce":false,"reaction":{"emoji":"+1","targetAuthorUuid":"22222222-2222-4222-8222-222222222222","targetSentTimestamp":1785491000000,"isRemove":false}}}}}
{"jsonrpc":"2.0","method":"receive","params":{"account":"+15550001000","envelope":{"sourceUuid":"11111111-1111-4111-8111-111111111111","timestamp":1785492400000,"editMessage":{"targetSentTimestamp":1785492000000,"dataMessage":{"timestamp":1785492400000,"message":"fixture corrected","expiresInSeconds":0,"viewOnce":false,"attachments":[]}}}}}
{"jsonrpc":"2.0","method":"receive","params":{"account":"+15550001000","envelope":{"sourceUuid":"11111111-1111-4111-8111-111111111111","timestamp":1785492500000,"dataMessage":{"timestamp":1785492500000,"expiresInSeconds":0,"viewOnce":false,"remoteDelete":{"timestamp":1785492000000}}}}}
{"jsonrpc":"2.0","method":"receive","params":{"account":"+15550001000","envelope":{"sourceUuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","timestamp":1785492600000,"syncMessage":{"sentMessage":{"destinationUuid":"22222222-2222-4222-8222-222222222222","timestamp":1785492600000,"message":"fixture outbound transcript","expiresInSeconds":0,"viewOnce":false,"attachments":[]}}}}}
{"jsonrpc":"2.0","method":"receive","params":{"account":"+15550001000","envelope":{"sourceUuid":"11111111-1111-4111-8111-111111111111","timestamp":1785492700000,"storyMessage":{"allowsReplies":true,"textAttachment":{"text":"ephemeral story"}}}}}
JSONL
chmod 0600 "$EVENTS"

printf 'Signal social collector tests\n'

status=$(python3 "$SIGNAL_HELPER" status)
assert_eq "status pins the reviewed signal-cli schema" \
	"$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["signal_cli"]["supported_version"])' "$status")" \
	0.14.6
assert_eq "live collection is explicitly unavailable because receive sends delivery receipts" \
	"$(json_field "$status" live_collector)" \
	unavailable_due_to_unavoidable_default_delivery_receipts

inspection=$(python3 "$SIGNAL_HELPER" inspect --config "$CONFIG" --events "$EVENTS" \
	--observed-at 2026-07-31T12:00:00Z)
assert_eq "bounded fixture inspection sees every notification" \
	"$(python3 -c 'import json,sys; print(sum(json.loads(sys.argv[1])["counts"].values()))' "$inspection")" 8
assert_eq "inspection exposes no message content" \
	"$(python3 -c 'import json,sys; print("fixture direct message" in sys.argv[1])' "$inspection")" False

result=$(python3 "$SIGNAL_HELPER" import-events --config "$CONFIG" --events "$EVENTS" \
	--base "$BASE" --alias personal:default --observed-at 2026-07-31T12:00:00Z)
assert_eq "offline notifications import into the protected social corpus" \
	"$(json_field "$result" objects)" 5
assert_eq "normal messages and edits preserve authorized text" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='signal' AND text_content LIKE 'fixture%'")" 3
assert_eq "disappearing and view-once payloads become content-free tombstones" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='signal' AND object_type='message_tombstone' AND text_content IS NULL")" 2
assert_eq "view-once attachment metadata is excluded" \
	"$(sql_value "SELECT count(*) FROM media WHERE provider='signal'")" 1
assert_eq "ordinary attachment paths and filenames never reach canonical evidence" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider_json LIKE '%private-name%' OR provider_json LIKE '%secret.jpg%'")" 0
assert_eq "reactions and deletion observations are normalized as activities" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='signal' AND activity_type IN ('message_reaction','message_deleted')")" 2
assert_eq "pre-link history remains explicit unavailable coverage" \
	"$(sql_value "SELECT status FROM coverage_records WHERE provider='signal' AND stream='pre_link_history'")" unavailable
assert_eq "view-once retention remains explicit excluded coverage" \
	"$(sql_value "SELECT status FROM coverage_records WHERE provider='signal' AND stream='view_once'")" excluded
assert_eq "raw evidence stores normalized archives rather than source event files" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='signal' AND resource_count=14")" 1

python3 "$SIGNAL_HELPER" import-events --config "$CONFIG" --events "$EVENTS" \
	--base "$BASE" --alias personal:default --observed-at 2026-07-31T12:00:00Z >/dev/null
assert_eq "exact event replay is idempotent" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='signal'")" 5

BAD_CONFIG="${TMP_DIR}/bad-config.json"
cat >"$BAD_CONFIG" <<'JSON'
{"schema_version":1,"account":"+15550009999","account_alias":"signal_personal","connection_id":"conn_signal_personal","signal_cli_version":"0.14.6"}
JSON
chmod 0600 "$BAD_CONFIG"
expect_failure "account rebinding fails before persistence" "$BAD_CONFIG" "$EVENTS"

REQUEST_EVENTS="${TMP_DIR}/request-events.jsonl"
cat >"$REQUEST_EVENTS" <<'JSONL'
{"jsonrpc":"2.0","id":"unsafe","method":"send","params":{"account":"+15550001000","message":"must reject"}}
JSONL
chmod 0600 "$REQUEST_EVENTS"
expect_failure "outbound JSON-RPC requests are unreachable" "$CONFIG" "$REQUEST_EVENTS"

PERMISSIVE_CONFIG="${TMP_DIR}/permissive-config.json"
cp "$CONFIG" "$PERMISSIVE_CONFIG"
chmod 0644 "$PERMISSIVE_CONFIG"
expect_failure "config with permissive local permissions fails closed" "$PERMISSIVE_CONFIG" "$EVENTS"

MALFORMED_EVENTS="${TMP_DIR}/malformed-events.jsonl"
cat >"$MALFORMED_EVENTS" <<'JSONL'
{"jsonrpc":"2.0","method":"receive","params":{"account":"+15550001000","envelope":{"sourceUuid":"11111111-1111-4111-8111-111111111111","timestamp":1785492800000,"dataMessage":{"timestamp":1785492800000,"message":"partial must not commit","expiresInSeconds":0,"viewOnce":false}}}}
not-json
JSONL
chmod 0600 "$MALFORMED_EVENTS"
before=$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='signal'")
expect_failure "malformed batches fail before any atomic commit" "$CONFIG" "$MALFORMED_EVENTS"
assert_eq "malformed batches preserve the prior checkpoint" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='signal'")" "$before"

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sources = sorted(scripts.glob("_knowledge_social_signal*.py"))
sources.append(scripts / "knowledge_social_signal.py")
for source in sources:
    tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
    imported = {
        alias.name.split(".")[0]
        for node in ast.walk(tree)
        if isinstance(node, (ast.Import, ast.ImportFrom))
        for alias in node.names
    }
    assert not imported.intersection({"http", "requests", "socket", "subprocess", "urllib"})

core = "\n".join(source.read_text(encoding="utf-8") for source in sources)
assert "account.db" not in core
assert "subscribeReceive(" not in core
assert "Popen(" not in core and "run(" not in core
PY
assert_eq "collector code has no network, process, account database, or subscription route" \
	guarded guarded

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
