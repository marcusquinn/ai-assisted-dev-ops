#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
QUICKFILE_HELPER="${SCRIPT_DIR}/../quickfile-helper.sh"
OCR_HELPER="${SCRIPT_DIR}/../ocr-receipt-helper.sh"
TEMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"

mkdir -p "$TEMP_PARENT"
TEST_DIR="$(mktemp -d "${TEMP_PARENT}/quickfile-rest-routing.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

tests_run=0
tests_failed=0

assert_case() {
	local case_name="$1"
	local condition="$2"
	tests_run=$((tests_run + 1))
	if [[ "$condition" == "true" ]]; then
		printf 'PASS: %s\n' "$case_name"
		return 0
	fi
	printf 'FAIL: %s\n' "$case_name" >&2
	tests_failed=$((tests_failed + 1))
	return 0
}

fixture="${TEST_DIR}/purchase.json"
cat >"$fixture" <<'JSON'
{
  "supplier_name": "Example Supplier",
  "invoice_number": "INV-001",
  "invoice_date": "2026-08-10",
  "currency": "GBP",
  "subtotal": 10,
  "vat_amount": 0,
  "total": 10,
  "line_items": [
    {
      "description": "Service",
      "quantity": 1,
      "unit_price": 10,
      "nominal_code": "5000"
    }
  ]
}
JSON

output=""
status=0
output="$(HOME="$TEST_DIR" bash "$QUICKFILE_HELPER" preview "$fixture" 2>&1)" || status=$?
assert_case "QuickFile preview rejects a missing account" \
	"$([[ "$status" -ne 0 && "$output" == *"--account is required"* ]] && printf true || printf false)"

output=""
status=0
output="$(HOME="$TEST_DIR" bash "$QUICKFILE_HELPER" preview "$fixture" --account test_account 2>&1)" || status=$?
assert_case "QuickFile preview propagates the selected account" \
	"$([[ "$status" -eq 0 && "$output" == *'"account": "test_account"'* ]] && printf true || printf false)"
assert_case "QuickFile preview omits an unspecified VAT percentage" \
	"$([[ "$status" -eq 0 && "$output" != *'"vatPercentage"'* ]] && printf true || printf false)"

fixture_with_vat="${TEST_DIR}/purchase-with-vat.json"
cat >"$fixture_with_vat" <<'JSON'
{
  "supplier_name": "Example Supplier",
  "invoice_date": "2026-08-10",
  "subtotal": 10,
  "vat_amount": 2,
  "total": 12,
  "line_items": [
    {
      "description": "Service",
      "quantity": 1,
      "unit_price": 10,
      "nominal_code": "5000",
      "vat_rate": 20
    }
  ]
}
JSON

output=""
status=0
output="$(HOME="$TEST_DIR" bash "$QUICKFILE_HELPER" preview "$fixture_with_vat" --account test_account 2>&1)" || status=$?
assert_case "QuickFile preview preserves an explicit VAT percentage" \
	"$([[ "$status" -eq 0 && "$output" == *'"vatPercentage": 20.0'* ]] && printf true || printf false)"

image_fixture="${TEST_DIR}/receipt.png"
: >"$image_fixture"
output=""
status=0
output="$(HOME="$TEST_DIR" bash "$OCR_HELPER" quickfile "$image_fixture" 2>&1)" || status=$?
assert_case "OCR QuickFile flow rejects a missing account before extraction" \
	"$([[ "$status" -ne 0 && "$output" == *"--account is required"* ]] && printf true || printf false)"

fake_bin="${TEST_DIR}/bin"
mkdir -p "$fake_bin"
cat >"${fake_bin}/ollama" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
list)
	printf 'NAME\n%s\n%s\n' 'glm-ocr:latest' 'llama3.2:latest'
	;;
run)
	if [[ "${2:-}" == "glm-ocr" ]]; then
		printf '%s\n' 'Example Supplier receipt dated 2026-08-10. Total GBP 10.00.'
	else
		printf '%s\n' '{"merchant_name":"Example Supplier","date":"2026-08-10","currency":"GBP","subtotal":10,"vat_amount":null,"total":10,"items":[{"name":"Service","quantity":1,"price":10,"vat_rate":null}],"document_type":"expense_receipt"}'
	fi
	;;
*)
	exit 1
	;;
esac
exit 0
SCRIPT
chmod +x "${fake_bin}/ollama"

output=""
status=0
output="$(PATH="${fake_bin}:${PATH}" HOME="$TEST_DIR" bash "$OCR_HELPER" quickfile "$image_fixture" --account test_account --type receipt 2>&1)" || status=$?
assert_case "OCR QuickFile flow propagates the selected account" \
	"$([[ "$status" -eq 0 && "$output" == *'"account": "test_account"'* ]] && printf true || printf false)"
qf_file="${TEST_DIR}/.aidevops/.agent-workspace/work/ocr-receipts/receipt-quickfile.json"
vat_status=0
QF_FILE="$qf_file" python3 -c '
import json
import os
with open(os.environ["QF_FILE"], "r") as handle:
    data = json.load(handle)
if any("vat_rate" in item for item in data["line_items"]):
    raise SystemExit(1)
' || vat_status=$?
assert_case "OCR QuickFile flow omits an unspecified VAT rate" \
	"$([[ "$status" -eq 0 && "$vat_status" -eq 0 ]] && printf true || printf false)"

printf 'Tests run: %d, failed: %d\n' "$tests_run" "$tests_failed"
[[ "$tests_failed" -eq 0 ]] || exit 1
exit 0
