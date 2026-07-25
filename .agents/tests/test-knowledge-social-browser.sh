#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-browser.sh — Browser-gap and provider contract tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
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

assert_pass() {
	local description="$1"
	shift
	if "$@"; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL  %s\n' "$description"
	fi
	return 0
}

assert_fail() {
	local description="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		FAIL=$((FAIL + 1))
		printf '  FAIL  %s (unexpected success)\n' "$description"
	else
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$description"
	fi
	return 0
}

json_eq() {
	local left="$1"
	local right="$2"
	local field="$3"
	python3 -c 'import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); assert a[sys.argv[3]] == b[sys.argv[3]]' \
		"$left" "$right" "$field"
	return 0
}

sql_is() {
	local query="$1"
	local expected="$2"
	python3 - "$ROOT/index/social.db" "$query" "$expected" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
actual = str(db.execute(sys.argv[2]).fetchone()[0])
db.close()
assert actual == sys.argv[3], (actual, sys.argv[3])
PY
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

cat >"$TMP_DIR/provider.json" <<'JSON'
{"contract_version":1,"provider":"fixture","streams":["saved"],"collection_routes":["api","archive","browser_gap"],"write_operations":[],"browser_gap":{"read_only":true,"checkpointed":true}}
JSON
cat >"$TMP_DIR/gap.json" <<'JSON'
{"provider":"fixture","stream":"saved","status":"unavailable","official_routes_exhausted":true,"reason":"official export omits saved items","observed_at":"2026-07-25T10:00:00Z","selector_version":"v1"}
JSON
cat >"$TMP_DIR/capture.json" <<'JSON'
{"provider":"fixture","stream":"saved","connection_id":"conn_fixture","remote_account_id":"acct_fixture","read_only":true,"checkpoint":"page_001","selector_version":"v1","observed_at":"2026-07-25T10:01:00Z","complete":false,"objects":[{"object_type":"post","remote_id":"post_001","account_remote_id":"acct_fixture","text":"bounded evidence","created_at":"2026-07-24T10:00:00Z","observed_at":"2026-07-25T10:01:00Z","evidence_class":"observed","provider_json":{"selector_version":"v1"}}]}
JSON
chmod 0600 "$TMP_DIR/provider.json" "$TMP_DIR/gap.json" "$TMP_DIR/capture.json"

printf 'Social browser-gap tests\n'
assert_pass "provider extension contract validates" \
	"$SOCIAL_HELPER" provider-validate --manifest "$TMP_DIR/provider.json"

first=$({ "$SOCIAL_HELPER" capture-browser-gap --base "$BASE" \
	--manifest "$TMP_DIR/provider.json" --gap "$TMP_DIR/gap.json" \
	--capture "$TMP_DIR/capture.json" --max-items 1; })
second=$({ "$SOCIAL_HELPER" capture-browser-gap --base "$BASE" \
	--manifest "$TMP_DIR/provider.json" --gap "$TMP_DIR/gap.json" \
	--capture "$TMP_DIR/capture.json" --max-items 1; })
assert_pass "capture replay keeps the same immutable batch" json_eq "$first" "$second" batch_id
assert_pass "capture replay does not duplicate objects" sql_is "SELECT count(*) FROM objects" 1
assert_pass "interrupted capture records paused gap coverage" sql_is \
	"SELECT status || ':' || cursor_exhausted FROM coverage_records WHERE stream='saved'" "paused:0"
assert_pass "browser route consumes no provider request budget" sql_is \
	"SELECT sum(budget_units) FROM fetch_batches" 0

python3 - "$TMP_DIR/capture.json" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["selector_version"] = "v2"
with open(path, "w", encoding="utf-8") as target:
    json.dump(value, target)
PY
assert_fail "selector drift stops browser capture before persistence" \
	"$SOCIAL_HELPER" capture-browser-gap --base "$BASE" --manifest "$TMP_DIR/provider.json" \
	--gap "$TMP_DIR/gap.json" --capture "$TMP_DIR/capture.json"
python3 - "$TMP_DIR/capture.json" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["selector_version"] = "v1"
with open(path, "w", encoding="utf-8") as target:
    json.dump(value, target)
PY

python3 - "$TMP_DIR/gap.json" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["official_routes_exhausted"] = False
with open(path, "w", encoding="utf-8") as target:
    json.dump(value, target)
PY
assert_fail "browser route remains disabled while official routes exist" \
	"$SOCIAL_HELPER" capture-browser-gap --base "$BASE" --manifest "$TMP_DIR/provider.json" \
	--gap "$TMP_DIR/gap.json" --capture "$TMP_DIR/capture.json"

python3 - "$TMP_DIR/provider.json" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["write_operations"] = ["like"]
with open(path, "w", encoding="utf-8") as target:
    json.dump(value, target)
PY
assert_fail "provider contract rejects platform writes" \
	"$SOCIAL_HELPER" provider-validate --manifest "$TMP_DIR/provider.json"

python3 - "$TMP_DIR/capture.json" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["cookie"] = "forbidden"
with open(path, "w", encoding="utf-8") as target:
    json.dump(value, target)
PY
assert_fail "capture rejects credential-shaped material" \
	"$SOCIAL_HELPER" capture-browser-gap --base "$BASE" --manifest "$TMP_DIR/provider.json" \
	--gap "$TMP_DIR/gap.json" --capture "$TMP_DIR/capture.json"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
