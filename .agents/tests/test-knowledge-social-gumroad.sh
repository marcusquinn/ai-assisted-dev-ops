#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-gumroad.sh — protected Gumroad seller collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/../scripts"
COLLECTOR="${SCRIPTS}/knowledge_social_gumroad.py"
CORPUS_HELPER="${SCRIPTS}/knowledge-corpus-helper.sh"
SOCIAL_HELPER="${SCRIPTS}/knowledge-social-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
ACCOUNT_ID="gumroad_G_-mnBf9b1j9A7a4ub4nFQ"
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

raw_text() {
	python3 - "$ROOT/sources/social/raw/gumroad" <<'PY'
import gzip
import sys
from pathlib import Path
root = Path(sys.argv[1])
print("\n".join(gzip.open(path, "rt", encoding="utf-8").read() for path in root.rglob("*.json.gz")))
PY
	return 0
}

run_fixture() {
	local fixture="$1"
	local connection="$2"
	local stream="$3"
	shift 3
	if python3 "$COLLECTOR" --base "$BASE" --alias personal:default \
		--connection-id "$connection" --account-id "$ACCOUNT_ID" \
		--stream "$stream" --profile fixture --fixture "$fixture" "$@"; then
		return 0
	fi
	return 1
}

run_terminal_case() {
	local name="$1"
	local status="$2"
	local expected_failure="$3"
	local fixture="${TMP_DIR}/terminal-${name}.json"
	python3 - "$fixture" "$ACCOUNT_ID" "$status" <<'PY'
import json
import sys

payload = {
    "identity": {"data": {"provider_account_id": sys.argv[2]}},
    "pages": [{"status": int(sys.argv[3]), "observed_at": "2026-07-31T12:03:00Z"}],
}
with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
	local result=""
	result=$(run_fixture "$fixture" "conn_terminal_${name}" sales)
	assert_eq "${status} response is terminal without a checkpoint" \
		"$(json_field "$result" failure_class):$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_terminal_${name}'")" \
		"${expected_failure}:0"
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Gumroad social collector tests\n'

python3 - "$SCRIPTS" <<'PY'
import ast
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))
from _knowledge_social_gumroad import PageRequest, STREAMS, page_checkpoint
from _knowledge_social_gumroad_records import product_record, sale_record
from _knowledge_social_collect import CursorState

assert set(STREAMS) == {"profile", "products", "sales", "payouts"}
product = product_record({
    "id": "product_123", "name": "Guide", "price": 1200, "currency": "usd",
    "published": True, "deleted": False, "require_shipping": False,
    "tags": ["guide"], "variants": [], "file_info": {"guide.pdf": {"size": 10}},
})
assert product["file_metadata_present"] is True and "file_info" not in product
sale = sale_record(b"p" * 32, {
    "id": "sale_12345", "seller_id": "seller_123", "product_id": "product_123",
    "purchase_email": "buyer@example.invalid", "product_name": "Guide", "price": 1200,
    "gumroad_fee": 120, "tax_cents": 20, "shipping_cents": 0, "quantity": 1,
    "variants": {}, "license_key": "never-store", "card": {"visual": "4242"},
})
assert sale["customer_ref"].startswith("customer_")
assert sale["has_license"] is True
assert "email" not in str(sale).lower() and "never-store" not in str(sale) and "4242" not in str(sale)

request = PageRequest("sales", "seller_123", "seller_123", None, None, 100)
checkpoint, complete = page_checkpoint({
    "data": [{"remote_id": "sale_1"}],
    "meta": {"stream": "sales", "next_page_key": "next_1", "newest_id": "sale_1", "reached_watermark": False, "complete": False},
}, CursorState(None, None, False), request)
assert not complete and checkpoint.next_cursor and checkpoint.watermark == "sale_1"

sources = [path.read_text(encoding="utf-8") for path in scripts.glob("*knowledge_social_gumroad*.py")]
trees = [ast.parse(source) for source in sources]
request_calls = [
    node for tree in trees for node in ast.walk(tree)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "Request"
]
assert len(request_calls) == 1
methods = [kw.value.value for kw in request_calls[0].keywords if kw.arg == "method" and isinstance(kw.value, ast.Constant)]
assert methods == ["GET"]
for forbidden in ('method="POST"', 'method="PUT"', 'method="PATCH"', 'method="DELETE"', "playwright", "selenium", "_knowledge_social_outbound"):
    assert all(forbidden not in source for source in sources)
PY
assert_eq "official routes, protected minimization, cursors, and GET-only AST are guarded" verified verified

cat >"$TMP_DIR/products-first.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}","display_name":"Seller"}},"pages":[{
  "expect_request":{"page_key":null,"stop_at":null,"limit":100},
  "response":{"status":200,"observed_at":"2026-07-31T12:00:00Z","data":[
    {"kind":"product","remote_id":"product_123","name":"Private Guide","description":"Bounded commerce knowledge","price_cents":1200,"currency":"usd","published":true,"deleted":false,"requires_shipping":false,"tags":[],"variants":[],"file_metadata_present":true}],
  "meta":{"stream":"products","next_page_key":"page_2","newest_id":"product_123","reached_watermark":false,"complete":false}}}]}
JSON
first=$(run_fixture "$TMP_DIR/products-first.json" conn_products products --budget 3 --page-size 100)
assert_eq "one bounded product page pauses with a durable cursor" "$(json_field "$first" status)" budget_exhausted
assert_eq "product evidence reaches corpus search" "$(sql_value "SELECT count(*) FROM objects_fts WHERE objects_fts MATCH 'commerce'")" 1

cat >"$TMP_DIR/products-resume.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}"}},"pages":[{
  "expect_request":{"page_key":"page_2"},
  "response":{"status":200,"observed_at":"2026-07-31T12:01:00Z","data":[],
  "meta":{"stream":"products","next_page_key":null,"newest_id":null,"reached_watermark":false,"complete":true}}}]}
JSON
second=$(run_fixture "$TMP_DIR/products-resume.json" conn_products products)
assert_eq "opaque product page key resumes and completes" "$(json_field "$second" status)" complete
assert_eq "product checkpoint is independently complete" "$(sql_value "SELECT backfill_complete FROM sync_cursors WHERE connection_id='conn_products' AND stream='products'")" 1

cat >"$TMP_DIR/sales.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}"}},"pages":[{
  "response":{"status":200,"observed_at":"2026-07-31T12:02:00Z","data":[
    {"kind":"sale","remote_id":"sale_12345","seller_id":"${ACCOUNT_ID}","product_id":"product_123","product_name":"Private Guide","customer_ref":"customer_0123456789abcdef0123456789abcdef","affiliate_ref":null,"affiliate_amount":null,"created_at":"2026-07-31T11:00:00Z","order_id":"42","price_cents":1200,"fee_cents":120,"tax_cents":20,"shipping_cents":0,"quantity":1,"variants":{},"refunded":false,"partially_refunded":false,"chargedback":false,"disputed":false,"dispute_won":false,"shipped":false,"subscription_id":null,"subscription_duration":null,"subscription_cancelled":null,"subscription_ended":null,"has_license":true}],
  "meta":{"stream":"sales","next_page_key":null,"newest_id":"sale_12345","reached_watermark":false,"complete":true}}}]}
JSON
run_fixture "$TMP_DIR/sales.json" conn_sales sales >/dev/null
assert_eq "sale financial evidence is classified as protected business data" \
	"$(sql_value "SELECT evidence_class FROM objects WHERE provider='gumroad' AND remote_id='sale_12345'")" protected_business
persisted=$(raw_text)
if [[ "$persisted" == *"buyer@example"* || "$persisted" == *"license_key"* || "$persisted" == *"card"* || "$persisted" == *"bank"* ]]; then
	assert_eq "raw evidence excludes direct customer/payment secrets" leaked excluded
else
	assert_eq "raw evidence excludes direct customer/payment secrets" excluded excluded
fi
assert_eq "API/export/event and retention gaps stay explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE connection_id='conn_sales' AND status='unavailable'")" 14

cat >"$TMP_DIR/mismatch.json" <<'JSON'
{"identity":{"data":{"provider_account_id":"other_seller_123"}},"pages":[]}
JSON
if run_fixture "$TMP_DIR/mismatch.json" conn_mismatch sales >/dev/null 2>&1; then
	assert_eq "seller identity mismatch is rejected before persistence" accepted rejected
else
	assert_eq "seller identity mismatch is rejected before persistence" rejected rejected
fi
assert_eq "identity mismatch creates no connection" "$(sql_value "SELECT count(*) FROM connections WHERE connection_id='conn_mismatch'")" 0

cat >"$TMP_DIR/rate.json" <<JSON
{"identity":{"data":{"provider_account_id":"${ACCOUNT_ID}"}},"pages":[{"status":429,"observed_at":"2026-07-31T12:03:00Z","retry_after":60}]}
JSON
rate=$(run_fixture "$TMP_DIR/rate.json" conn_rate payouts)
assert_eq "rate limits pause without checkpoint advancement" "$(json_field "$rate" failure_class):$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_rate'")" rate_limit:0
run_terminal_case forbidden 403 authorization
run_terminal_case unavailable 404 unavailable
run_terminal_case provider 500 provider

docs=$(<"$SCRIPT_DIR/../content/social-gumroad.md")
if [[ "$docs" == *"Official evidence checked 2026-07-31"* && "$docs" == *"No export generation"* && "$docs" == *"no POST, PUT, PATCH"* ]]; then
	assert_eq "dated capability matrix documents explicit safe gaps" documented documented
else
	assert_eq "dated capability matrix documents explicit safe gaps" missing documented
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
