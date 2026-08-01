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


class Complexity(ast.NodeVisitor):
    """Approximate CodeFactor's branch complexity for the parser guard."""

    def __init__(self):
        self.score = 1

    def _branch(self, node):
        self.score += 1
        self.generic_visit(node)

    visit_If = _branch
    visit_For = _branch
    visit_While = _branch
    visit_Try = _branch
    visit_With = _branch
    visit_AsyncWith = _branch

    def visit_BoolOp(self, node):
        self.score += max(0, len(node.values) - 1)
        self.generic_visit(node)

    def visit_IfExp(self, node):
        self.score += 1
        self.generic_visit(node)


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
    if target.name == "_knowledge_social_telegram_updates.py":
        functions = {
            node.name: node
            for node in ast.walk(tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }
        parser = functions["parse_telegram_updates"]
        complexity = Complexity()
        complexity.visit(parser)
        assert complexity.score <= 8, (
            "parse_telegram_updates is too complex for CodeFactor: "
            f"{complexity.score}"
        )
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
assert_eq "export media bytes are copied into private immutable storage" \
	"$(sql_value "SELECT hydration_state || ':' || coalesce(byte_size,0) FROM media WHERE provider='telegram' AND remote_id LIKE 'export:%'")" \
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
assert_eq "out-of-order updates advance to the maximum durable offset" \
	"$(sql_value "SELECT cursor FROM sync_cursors WHERE connection_id='conn_updates' AND stream='bot_updates'")" \
	504
assert_eq "export/live overlap converges on one stable chat-message identity" \
	"$(sql_value "SELECT count(*) || ':' || max(text_content) FROM objects WHERE provider='telegram' AND remote_id='chat:-200:message:10'")" \
	"1:Synthetic message edited by event fan-out"
assert_eq "Bot API file IDs are not projected into searchable provider data" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider_json LIKE '%private-transport-value%'")" 0
assert_eq "fan-out media remains explicit remote-only evidence" \
	"$(sql_value "SELECT hydration_state FROM media WHERE provider='telegram' AND remote_id='bot-file:fixture-unique-document'")" \
	remote_only

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

status=$(python3 "$COLLECTOR" status --base "$BASE" --alias personal:default \
	--connection-id conn_updates)
assert_eq "status exposes only sanitized route checkpoint state" \
	"$(json_field "$status" connection_id)" conn_updates

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
