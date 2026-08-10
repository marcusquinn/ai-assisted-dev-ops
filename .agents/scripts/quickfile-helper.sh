#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# QuickFile Integration Helper for AI DevOps Framework
# Bridges OCR extraction pipeline with QuickFile accounting via MCP tools.
# Handles supplier resolution, purchase/expense recording, and batch processing.
#
# Usage: quickfile-helper.sh [command] [options]
#
# Commands:
#   record-purchase <json>   Record a purchase invoice in QuickFile from extracted JSON
#   record-expense <json>    Record an expense receipt in QuickFile from extracted JSON
#   supplier-resolve <name>  Find or create a supplier by name
#   batch-record <dir>       Batch record all *-quickfile.json files in a directory
#   preview <json>           Show what would be recorded (dry run)
#   status                   Check QuickFile MCP connectivity and credentials
#   help                     Show this help
#
# Options:
#   --dry-run                Preview without recording
#   --nominal <code>         Override nominal code for all line items
#   --supplier-id <id>       Skip supplier lookup, use this ID directly
#   --auto-supplier          Auto-create supplier if not found (default: prompt)
#   --currency <code>        Override currency (default: GBP)
#   --account <alias>         Required QuickFile account alias
#
# Integration:
#   This script generates MCP tool call instructions for the AI assistant.
#   It does NOT call QuickFile APIs directly — the AI assistant executes
#   the MCP tool calls (quickfile_supplier_search, quickfile_purchase_create, etc.)
#
# Author: AI DevOps Framework
# Version: 2.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly QF_WORKSPACE="${HOME}/.aidevops/.agent-workspace/work/quickfile"
readonly OCR_WORKSPACE="${HOME}/.aidevops/.agent-workspace/work/ocr-receipts"
readonly QF_MCP_DIR="${HOME}/Git/mcp/quickfile-mcp"
readonly DEFAULT_NOMINAL="5000"
readonly DEFAULT_CURRENCY="GBP"

# Ensure workspace exists
ensure_workspace() {
	if ! mkdir -p "$QF_WORKSPACE"; then
		print_error "Failed to create workspace: ${QF_WORKSPACE}"
		return 1
	fi
	return 0
}

validate_account_alias() {
	local account="$1"
	if [[ -z "$account" || ! "$account" =~ ^[A-Za-z0-9_-]+$ ]]; then
		print_error "--account is required and must contain only letters, numbers, underscores, or hyphens"
		return 1
	fi
	return 0
}

# Validate JSON file and check it has required fields
validate_extraction_json() {
	local json_file="$1"
	local record_type="${2:-purchase}"

	validate_file_exists "$json_file" "Extraction JSON" || return 1

	# Check it's valid JSON
	if ! python3 -m json.tool "$json_file" >/dev/null 2>&1; then
		print_error "Invalid JSON: ${json_file}"
		return 1
	fi

	# Check required fields based on record type
	local missing_fields
	missing_fields="$(JSON_FILE="$json_file" RECORD_TYPE="$record_type" python3 -c "
import json, sys, os

with open(os.environ['JSON_FILE'], 'r') as f:
    data = json.load(f)

# Navigate to data payload (may be nested under 'data' key)
payload = data.get('data', data)

record_type = os.environ['RECORD_TYPE']
missing = []

if record_type == 'purchase':
    if not payload.get('supplier_name') and not payload.get('vendor_name'):
        missing.append('supplier_name or vendor_name')
    if not payload.get('total') and payload.get('total') != 0:
        missing.append('total')
elif record_type == 'expense':
    if not payload.get('supplier_name') and not payload.get('merchant_name') and not payload.get('merchant'):
        missing.append('supplier_name, merchant_name, or merchant')
    if not payload.get('total') and payload.get('total') != 0:
        missing.append('total')

if missing:
    print(', '.join(missing))
" 2>/dev/null)" || {
		print_error "Failed to validate JSON structure"
		return 1
	}

	if [[ -n "$missing_fields" ]]; then
		print_error "Missing required fields: ${missing_fields}"
		return 1
	fi

	return 0
}

# Generate supplier resolution instructions
generate_supplier_instructions() {
	local supplier_name="$1"
	local supplier_id="${2:-}"
	local auto_create="${3:-false}"
	local account="$4"
	local account_json=""
	account_json="$(ACCOUNT_ALIAS="$account" python3 -c 'import json, os; print(json.dumps(os.environ["ACCOUNT_ALIAS"]))')" || {
		print_error "Failed to serialize account alias to JSON"
		return 1
	}

	if [[ -n "$supplier_id" ]]; then
		echo "  Supplier ID: ${supplier_id} (provided directly, skip lookup)"
		return 0
	fi

	# Serialize supplier name to valid JSON to prevent malformed payloads
	local supplier_name_json
	supplier_name_json="$(SUPPLIER_NAME="$supplier_name" python3 -c 'import json, os; print(json.dumps(os.environ["SUPPLIER_NAME"]))')" || {
		print_error "Failed to serialize supplier name to JSON"
		return 1
	}

	echo "  1. Search for supplier:"
	echo "     quickfile_supplier_search({ \"account\": ${account_json}, \"companyName\": ${supplier_name_json} })"
	echo ""
	echo "  2. If found: use the returned SupplierId"
	echo "     If NOT found:"
	if [[ "$auto_create" == "true" ]]; then
		echo "     quickfile_supplier_create({"
		echo "       \"account\": ${account_json},"
		echo "       \"companyName\": ${supplier_name_json}"
		echo "     })"
	else
		echo "     Ask user whether to create supplier ${supplier_name_json} or map to existing"
	fi
	return 0
}

# Generate purchase invoice creation instructions from JSON
generate_purchase_instructions() {
	local json_file="$1"
	local nominal_override="${2:-}"
	local currency_override="${3:-}"
	local supplier_id="${4:-}"
	local account="$5"

	JSON_FILE="$json_file" \
		NOMINAL_OVERRIDE="$nominal_override" \
		CURRENCY_OVERRIDE="$currency_override" \
		SUPPLIER_ID="$supplier_id" \
		ACCOUNT_ALIAS="$account" \
		DEFAULT_NOMINAL_CODE="$DEFAULT_NOMINAL" \
		DEFAULT_CURRENCY_CODE="$DEFAULT_CURRENCY" \
		python3 -c "
import json, sys, os

with open(os.environ['JSON_FILE'], 'r') as f:
    data = json.load(f)

payload = data.get('data', data)
nominal_override = os.environ.get('NOMINAL_OVERRIDE') or None
currency_override = os.environ.get('CURRENCY_OVERRIDE') or None
supplier_id = os.environ.get('SUPPLIER_ID') or None
account = os.environ['ACCOUNT_ALIAS']
default_nominal = os.environ.get('DEFAULT_NOMINAL_CODE', '5000')
default_currency = os.environ.get('DEFAULT_CURRENCY_CODE', 'GBP')

# Resolve supplier name
supplier = (payload.get('supplier_name')
            or payload.get('vendor_name')
            or payload.get('merchant_name')
            or payload.get('merchant')
            or 'Unknown Supplier')

# Resolve dates
inv_date = (payload.get('invoice_date')
            or payload.get('date')
            or 'YYYY-MM-DD')
# Resolve amounts
total = float(payload.get('total', 0) or 0)
vat = float(payload.get('vat_amount', 0) or payload.get('tax_amount', 0) or 0)
subtotal = float(payload.get('subtotal', 0) or 0)
if subtotal == 0 and total > 0:
    subtotal = total - vat

# Currency
currency = currency_override or payload.get('currency', default_currency)

# Invoice reference
inv_ref = (payload.get('invoice_number')
           or payload.get('receipt_number')
           or '')

# Build line items
raw_items = payload.get('line_items', payload.get('items', []))
lines = []
if raw_items:
    for item in raw_items:
        desc = item.get('description', item.get('name', 'Item'))
        qty = float(item.get('quantity', 1) or 1)
        unit_cost = float(item.get('unit_price', item.get('price', 0)) or 0)
        nominal = nominal_override or item.get('nominal_code', default_nominal)
        vat_pct = item.get('vat_rate')
        line = {
            'description': desc,
            'quantity': qty,
            'unitCost': unit_cost,
            'nominalCode': str(nominal)
        }
        if vat_pct is not None:
            line['vatPercentage'] = float(vat_pct)
        lines.append(line)
else:
    # Single line item from totals
    nominal = nominal_override or default_nominal
    line = {
        'description': f'Purchase from {supplier}',
        'quantity': 1,
        'unitCost': subtotal,
        'nominalCode': str(nominal)
    }
    if subtotal > 0 and vat > 0:
        line['vatPercentage'] = round((vat / subtotal) * 100, 4)
    lines.append(line)

# Build the request object and serialize via json.dumps for safe output
request = {
    'account': account,
    'supplierId': supplier_id or '<from supplier lookup>',
    'issueDate': inv_date,
    'currency': currency,
    'lines': lines,
}
if inv_ref:
    request['supplierRef'] = inv_ref
print(f'  quickfile_purchase_create({json.dumps(request, indent=4, ensure_ascii=False)})')
print()
# Sanitise supplier name for summary output to prevent LLM instruction injection
safe_supplier = supplier.replace('\\n', ' ').replace('\\r', ' ')[:100]
print(f'  Summary: {safe_supplier} | {inv_date} | {currency} {total:.2f} (net {subtotal:.2f} + VAT {vat:.2f})')
" 2>/dev/null || {
		print_error "Failed to generate purchase instructions"
		return 1
	}

	return 0
}

# Record a purchase invoice
cmd_record_purchase() {
	local json_file="$1"
	local dry_run="${2:-false}"
	local nominal_override="${3:-}"
	local supplier_id="${4:-}"
	local auto_supplier="${5:-false}"
	local currency_override="${6:-}"
	local account="$7"

	validate_account_alias "$account" || return 1
	validate_extraction_json "$json_file" "purchase" || return 1
	ensure_workspace

	# Extract supplier name for resolution
	local supplier_name
	supplier_name="$(JSON_FILE="$json_file" python3 -c "
import json, os
with open(os.environ['JSON_FILE'], 'r') as f:
    data = json.load(f)
payload = data.get('data', data)
print(payload.get('supplier_name', '')
      or payload.get('vendor_name', '')
      or payload.get('merchant_name', '')
      or payload.get('merchant', '')
      or 'Unknown Supplier')
" 2>/dev/null)" || supplier_name="Unknown Supplier"

	echo ""
	echo "QuickFile Purchase Invoice Recording"
	echo "====================================="
	echo ""

	if [[ "$dry_run" == "true" ]]; then
		echo "  [DRY RUN - no changes will be made]"
		echo ""
	fi

	echo "Step 1: Resolve Supplier"
	echo "------------------------"
	generate_supplier_instructions "$supplier_name" "$supplier_id" "$auto_supplier" "$account"
	echo ""

	echo "Step 2: Create Purchase Invoice"
	echo "-------------------------------"
	generate_purchase_instructions "$json_file" "$nominal_override" "$currency_override" "$supplier_id" "$account"
	echo ""

	if [[ "$dry_run" != "true" ]]; then
		# Save the instruction set for the AI assistant
		local basename
		basename="$(basename "$json_file" | sed 's/\.[^.]*$//')"
		local instruction_file="${QF_WORKSPACE}/${basename}-instructions.md"

		{
			echo "# QuickFile Purchase Invoice Instructions"
			echo ""
			echo "Source: ${json_file}"
			echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
			echo ""
			echo "## Step 1: Resolve Supplier"
			echo ""
			echo '```'
			generate_supplier_instructions "$supplier_name" "$supplier_id" "$auto_supplier" "$account"
			echo '```'
			echo ""
			echo "## Step 2: Create Purchase Invoice"
			echo ""
			echo '```'
			generate_purchase_instructions "$json_file" "$nominal_override" "$currency_override" "$supplier_id" "$account"
			echo '```'
		} >"$instruction_file"

		print_success "Instructions saved to: ${instruction_file}"
		echo ""
		print_info "Execute these MCP tool calls in your AI assistant session to record the purchase."
	fi

	return 0
}

# Record an expense receipt (same flow as purchase but with expense-specific handling)
cmd_record_expense() {
	local json_file="$1"
	local dry_run="${2:-false}"
	local nominal_override="${3:-}"
	local supplier_id="${4:-}"
	local auto_supplier="${5:-true}"
	local currency_override="${6:-}"
	local account="$7"

	validate_extraction_json "$json_file" "expense" || return 1
	ensure_workspace

	# For expenses, auto-categorise nominal code if not overridden
	if [[ -z "$nominal_override" ]]; then
		local auto_nominal
		auto_nominal="$(JSON_FILE="$json_file" python3 -c "
import json, os

with open(os.environ['JSON_FILE'], 'r') as f:
    data = json.load(f)

payload = data.get('data', data)
supplier = (payload.get('supplier_name', '')
            or payload.get('merchant_name', '')
            or payload.get('merchant', '')
            or '').lower()

# Check line items for category hints
items = payload.get('items', payload.get('line_items', []))
item_text = ' '.join(
    (i.get('description', '') or i.get('name', '')).lower()
    for i in items
)

combined = supplier + ' ' + item_text

# Pattern-based categorisation (matches extraction-schemas.md)
categories = [
    (['shell', 'bp', 'esso', 'fuel', 'petrol', 'diesel'], '7401'),
    (['hotel', 'airbnb', 'accommodation', 'booking.com'], '7403'),
    (['restaurant', 'cafe', 'food', 'lunch', 'dinner', 'coffee'], '7402'),
    (['train', 'bus', 'taxi', 'uber', 'parking', 'travel'], '7400'),
    (['royal mail', 'dhl', 'fedex', 'postage', 'shipping'], '7501'),
    (['bt', 'vodafone', 'phone', 'broadband', 'internet'], '7502'),
    (['adobe', 'microsoft', 'saas', 'subscription', 'software'], '7404'),
    (['google ads', 'facebook ads', 'marketing', 'advertising'], '6201'),
    (['accountant', 'solicitor', 'legal', 'professional'], '7600'),
    (['plumber', 'electrician', 'repair', 'maintenance'], '7300'),
    (['amazon', 'staples', 'office', 'stationery', 'supplies'], '7504'),
]

nominal = '5000'  # Default: General Purchases
for keywords, code in categories:
    if any(kw in combined for kw in keywords):
        nominal = code
        break

print(nominal)
" 2>/dev/null)" || auto_nominal="${DEFAULT_NOMINAL}"
		nominal_override="$auto_nominal"
		print_info "Auto-categorised nominal code: ${nominal_override}"
	fi

	# Delegate to purchase recording (expenses are purchase invoices in QuickFile)
	cmd_record_purchase "$json_file" "$dry_run" "$nominal_override" "$supplier_id" "$auto_supplier" "$currency_override" "$account"
	return $?
}

# Resolve a supplier by name
cmd_supplier_resolve() {
	local supplier_name="$1"
	local auto_create="${2:-false}"
	local account="$3"
	validate_account_alias "$account" || return 1

	echo ""
	echo "Supplier Resolution"
	echo "==================="
	echo ""
	generate_supplier_instructions "$supplier_name" "" "$auto_create" "$account"
	echo ""
	print_info "Execute the quickfile_supplier_search MCP tool call in your AI session."
	return 0
}

# Batch record all quickfile JSON files in a directory
cmd_batch_record() {
	local input_dir="$1"
	local dry_run="${2:-false}"
	local nominal_override="${3:-}"
	local auto_supplier="${4:-true}"
	local currency_override="${5:-}"
	local account="$6"
	validate_account_alias "$account" || return 1

	if [[ ! -d "$input_dir" ]]; then
		print_error "Directory not found: ${input_dir}"
		return 1
	fi

	ensure_workspace

	local count=0
	local failed=0

	print_info "Batch recording QuickFile purchases from: ${input_dir}"
	echo ""

	for json_file in "${input_dir}"/*-quickfile.json "${input_dir}"/*-extracted.json; do
		[[ -f "$json_file" ]] || continue

		echo "=== $(basename "$json_file") ==="
		if cmd_record_purchase "$json_file" "$dry_run" "$nominal_override" "" "$auto_supplier" "$currency_override" "$account"; then
			count=$((count + 1))
		else
			failed=$((failed + 1))
		fi
		echo ""
	done

	if [[ "$count" -eq 0 ]] && [[ "$failed" -eq 0 ]]; then
		print_warning "No *-quickfile.json or *-extracted.json files found in ${input_dir}"
		return 1
	fi

	echo "=== Batch Summary ==="
	print_success "Processed: ${count} succeeded, ${failed} failed"
	if [[ "$dry_run" == "true" ]]; then
		print_info "[DRY RUN - no changes were made]"
	fi
	if [[ "$failed" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# Preview what would be recorded
cmd_preview() {
	local json_file="$1"
	local nominal_override="${2:-}"
	local currency_override="${3:-}"
	local account="$4"

	cmd_record_purchase "$json_file" "true" "$nominal_override" "" "false" "$currency_override" "$account"
	return $?
}

# Check QuickFile MCP status
cmd_status() {
	echo "QuickFile Integration - Status"
	echo "==============================="
	echo ""

	# QuickFile MCP server
	echo "MCP Server:"
	if [[ -f "${QF_MCP_DIR}/dist/index.js" ]]; then
		echo "  quickfile-mcp:  installed (${QF_MCP_DIR})"
	else
		echo "  quickfile-mcp:  not found"
		echo "  Install: mkdir -p ~/Git/mcp && git clone https://github.com/marcusquinn/quickfile-mcp.git ~/Git/mcp/quickfile-mcp"
		echo "           cd ~/Git/mcp/quickfile-mcp && npm install && npm run build"
	fi

	# Bearer-token inventory (names and count only)
	echo ""
	echo "Bearer tokens:"
	local inventory=""
	local token_count=0
	if command -v aidevops >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
		inventory=$(aidevops secret inventory 2>/dev/null) || inventory=""
	fi
	if [[ -n "$inventory" ]]; then
		token_count=$(printf '%s' "$inventory" | jq '[.secrets[]
			| select(.status == "configured")
			| .name
			| select(test("^QUICKFILE_([A-Z0-9_]+_)?(API_KEY|API_TOKEN|BEARER_TOKEN)$"))]
			| unique | length')
	fi
	if [[ "$token_count" -gt 0 ]]; then
		echo "  configured accounts: ${token_count} (values and aliases hidden)"
	else
		echo "  configured accounts: 0"
		echo "  Setup: aidevops secret set QUICKFILE_BUSINESS_API_KEY"
	fi

	# OCR pipeline
	echo ""
	echo "OCR Pipeline:"
	if [[ -x "${SCRIPT_DIR}/ocr-receipt-helper.sh" ]]; then
		echo "  ocr-receipt-helper:  available"
	else
		echo "  ocr-receipt-helper:  not found"
	fi

	# Workspace
	echo ""
	echo "Workspace:"
	echo "  quickfile dir:  ${QF_WORKSPACE}"
	echo "  ocr dir:        ${OCR_WORKSPACE}"
	local qf_count=0
	local ocr_count=0
	if [[ -d "$QF_WORKSPACE" ]]; then
		qf_count="$(find "$QF_WORKSPACE" -type f 2>/dev/null | wc -l | tr -d ' ')"
	fi
	if [[ -d "$OCR_WORKSPACE" ]]; then
		ocr_count="$(find "$OCR_WORKSPACE" -name '*-quickfile.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
	fi
	echo "  instruction files: ${qf_count}"
	echo "  pending records:   ${ocr_count} (quickfile JSON files in OCR workspace)"

	return 0
}

# Show help
cmd_help() {
	echo "QuickFile Integration Helper - AI DevOps Framework"
	echo ""
	echo "${HELP_LABEL_USAGE}"
	echo "  quickfile-helper.sh <command> [options]"
	echo ""
	echo "${HELP_LABEL_COMMANDS}"
	echo "  record-purchase <json>   Record purchase invoice from extracted JSON"
	echo "  record-expense <json>    Record expense receipt (auto-categorises nominal code)"
	echo "  supplier-resolve <name>  Find or create a supplier by name"
	echo "  batch-record <dir>       Batch record all *-quickfile.json files"
	echo "  preview <json>           Dry run - show what would be recorded"
	echo "  status                   Check QuickFile MCP and credential status"
	echo "  help                     Show this help"
	echo ""
	echo "${HELP_LABEL_OPTIONS}"
	echo "  --dry-run                Preview without recording"
	echo "  --nominal <code>         Override nominal code (default: auto-categorise)"
	echo "  --supplier-id <id>       Skip supplier lookup, use this ID"
	echo "  --auto-supplier          Auto-create supplier if not found"
	echo "  --currency <code>        Override currency (default: GBP)"
	echo "  --account <alias>        Required QuickFile account alias"
	echo ""
	echo "Workflow:"
	echo "  1. Extract:  ocr-receipt-helper.sh extract invoice.pdf"
	echo "  2. Prepare:  ocr-receipt-helper.sh quickfile invoice.pdf --account business"
	echo "  3. Preview:  quickfile-helper.sh preview invoice-quickfile.json --account business"
	echo "  4. Record:   quickfile-helper.sh record-purchase invoice-quickfile.json --account business"
	echo "  5. Execute:  Run the MCP tool calls in your AI assistant session"
	echo ""
	echo "${HELP_LABEL_EXAMPLES}"
	echo "  quickfile-helper.sh record-purchase ~/receipts/invoice-quickfile.json --account business"
	echo "  quickfile-helper.sh record-expense ~/receipts/receipt-quickfile.json --account business --auto-supplier"
	echo "  quickfile-helper.sh supplier-resolve 'Amazon UK' --account business"
	echo "  quickfile-helper.sh batch-record ~/.aidevops/.agent-workspace/work/ocr-receipts/ --account business"
	echo "  quickfile-helper.sh preview invoice-quickfile.json --account business --nominal 7502"
	echo "  quickfile-helper.sh status"
	echo ""
	echo "Related:"
	echo "  ocr-receipt-helper.sh              - OCR extraction pipeline"
	echo "  services/accounting/quickfile.md    - QuickFile MCP subagent"
	echo "  tools/document/extraction-schemas.md - Extraction schema contracts"
	return 0
}

# Parse named options from argument list; sets variables in caller scope via echo
# Usage: eval "$(_parse_options "$@")"
# Outputs: shell assignments for file, dry_run, nominal_override, supplier_id,
#          auto_supplier, currency_override, account; remaining args are consumed.
_parse_options() {
	local file=""
	local dry_run="false"
	local nominal_override=""
	local supplier_id=""
	local auto_supplier="false"
	local currency_override=""
	local account=""

	# First positional arg (if not a flag) is the file/dir/name
	if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
		file="$1"
		shift || true
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run="true"
			shift
			;;
		--nominal)
			local nominal_val="${2:-}"
			if [[ -z "$nominal_val" ]] || [[ "$nominal_val" == -* ]]; then
				print_error "--nominal requires a non-empty value (got: '${nominal_val}')"
				return 1
			fi
			nominal_override="$nominal_val"
			shift 2
			;;
		--supplier-id)
			local sid_val="${2:-}"
			if [[ -z "$sid_val" ]] || [[ "$sid_val" == -* ]]; then
				print_error "--supplier-id requires a non-empty value (got: '${sid_val}')"
				return 1
			fi
			supplier_id="$sid_val"
			shift 2
			;;
		--auto-supplier)
			auto_supplier="true"
			shift
			;;
		--currency)
			local currency_val="${2:-}"
			if [[ -z "$currency_val" ]] || [[ "$currency_val" == -* ]]; then
				print_error "--currency requires a non-empty value (got: '${currency_val}')"
				return 1
			fi
			currency_override="$currency_val"
			shift 2
			;;
		--account)
			local account_val="${2:-}"
			if [[ -z "$account_val" ]] || [[ "$account_val" == -* ]]; then
				print_error "--account requires a non-empty alias"
				return 1
			fi
			account="$account_val"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	printf '%s\n' \
		"file=$(printf '%q' "$file")" \
		"dry_run=$(printf '%q' "$dry_run")" \
		"nominal_override=$(printf '%q' "$nominal_override")" \
		"supplier_id=$(printf '%q' "$supplier_id")" \
		"auto_supplier=$(printf '%q' "$auto_supplier")" \
		"currency_override=$(printf '%q' "$currency_override")" \
		"account=$(printf '%q' "$account")"
	return 0
}

# Dispatch a parsed command to the appropriate cmd_* function
_dispatch_command() {
	local command="$1"
	local file="$2"
	local dry_run="$3"
	local nominal_override="$4"
	local supplier_id="$5"
	local auto_supplier="$6"
	local currency_override="$7"
	local account="$8"

	case "$command" in
	record-purchase | rp)
		if [[ -z "$file" ]]; then
			print_error "${ERROR_INPUT_FILE_REQUIRED}"
			return 1
		fi
		cmd_record_purchase "$file" "$dry_run" "$nominal_override" "$supplier_id" "$auto_supplier" "$currency_override" "$account"
		;;
	record-expense | re)
		if [[ -z "$file" ]]; then
			print_error "${ERROR_INPUT_FILE_REQUIRED}"
			return 1
		fi
		cmd_record_expense "$file" "$dry_run" "$nominal_override" "$supplier_id" "$auto_supplier" "$currency_override" "$account"
		;;
	supplier-resolve | sr)
		if [[ -z "$file" ]]; then
			print_error "Supplier name is required"
			return 1
		fi
		cmd_supplier_resolve "$file" "$auto_supplier" "$account"
		;;
	batch-record | br)
		if [[ -z "$file" ]]; then
			print_error "Input directory is required"
			return 1
		fi
		cmd_batch_record "$file" "$dry_run" "$nominal_override" "$auto_supplier" "$currency_override" "$account"
		;;
	preview)
		if [[ -z "$file" ]]; then
			print_error "${ERROR_INPUT_FILE_REQUIRED}"
			return 1
		fi
		cmd_preview "$file" "$nominal_override" "$currency_override" "$account"
		;;
	status)
		cmd_status
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
	return $?
}

# Parse command-line arguments and dispatch to the appropriate command
parse_args() {
	local command="${1:-help}"
	shift || true

	local file=""
	local dry_run="false"
	local nominal_override=""
	local supplier_id=""
	local auto_supplier="false"
	local currency_override=""
	local account=""

	local opts
	opts="$(_parse_options "$@")" || return 1
	eval "$opts"

	_dispatch_command "$command" "$file" "$dry_run" "$nominal_override" \
		"$supplier_id" "$auto_supplier" "$currency_override" "$account"
	return $?
}

# Main entry point
parse_args "$@"
