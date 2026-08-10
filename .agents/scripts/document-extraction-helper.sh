#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Document Extraction Helper for AI DevOps Framework
# Orchestrates document parsing, PII detection, and structured extraction
# with validation pipeline, confidence scoring, and multi-model fallback.
#
# Usage: document-extraction-helper.sh [command] [options]
#
# Commands:
#   extract <file> [--schema <name>] [--privacy <mode>] [--output <format>]
#   batch <dir> [--schema <name>] [--privacy <mode>] [--pattern <glob>]
#   classify <file>                  Classify document type from text/OCR
#   validate <json-file>             Validate extracted JSON (VAT, dates, confidence)
#   pii-scan <file>                  Scan for PII without extraction
#   pii-redact <file> [--output <file>]  Redact PII from text
#   convert <file> [--output <format>]   Convert document to markdown/JSON
#   install [--all|--core|--pii|--llm]   Install dependencies
#   status                               Check installed components
#   schemas                              List available extraction schemas
#   help                                 Show this help
#
# Privacy modes: local (Ollama), edge (Cloudflare), cloud (OpenAI/Anthropic), none
# Output formats: json, markdown, csv, text
# Schemas: purchase-invoice, expense-receipt, credit-note, invoice, receipt, contract, id-document, auto
#
# Author: AI DevOps Framework
# Version: 2.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly VENV_DIR="${HOME}/.aidevops/.agent-workspace/python-env/document-extraction"
readonly WORKSPACE_DIR="${HOME}/.aidevops/.agent-workspace/work/document-extraction"
readonly PIPELINE_PY="${SCRIPT_DIR}/extraction_pipeline.py"

# Ensure workspace exists
ensure_workspace() {
	mkdir -p "$WORKSPACE_DIR" 2>/dev/null || true
	return 0
}

# Activate or create Python virtual environment
activate_venv() {
	if [[ -d "${VENV_DIR}/bin" ]]; then
		# shellcheck disable=SC1091  # venv activate doesn't exist at lint time
		source "${VENV_DIR}/bin/activate"
		return 0
	fi
	print_error "Python venv not found at ${VENV_DIR}"
	print_info "Run: document-extraction-helper.sh install --core"
	return 1
}

# Check if a Python package is installed in the venv
check_python_package() {
	local package="$1"
	if [[ -d "${VENV_DIR}/bin" ]]; then
		"${VENV_DIR}/bin/python3" -c "import ${package}" 2>/dev/null
		return $?
	fi
	return 1
}

# Install dependencies
do_install() {
	local component="${1:-all}"

	case "$component" in
	--all | all)
		install_core
		install_pii
		install_llm
		;;
	--core | core)
		install_core
		;;
	--pii | pii)
		install_pii
		;;
	--llm | llm)
		install_llm
		;;
	*)
		print_error "Unknown install component: ${component}"
		print_info "Options: --all, --core, --pii, --llm"
		return 1
		;;
	esac
	return 0
}

install_core() {
	print_info "Installing core document extraction dependencies..."

	# Check Python version
	local python_version
	python_version="$(python3 --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)"
	if [[ -z "$python_version" ]]; then
		print_error "Python 3 is required but not found"
		return 1
	fi

	local major minor
	major="$(echo "$python_version" | cut -d. -f1)"
	minor="$(echo "$python_version" | cut -d. -f2)"
	if [[ "$major" -lt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -lt 10 ]]; }; then
		print_error "Python 3.10+ required (found ${python_version})"
		return 1
	fi

	# Create venv
	if [[ ! -d "${VENV_DIR}/bin" ]]; then
		print_info "Creating Python virtual environment at ${VENV_DIR}..."
		python3 -m venv "$VENV_DIR"
	fi

	# Install packages
	"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
	"${VENV_DIR}/bin/pip" install --quiet docling extract-thinker "pydantic>=2.0"

	print_success "Core dependencies installed (docling, extract-thinker, pydantic)"
	return 0
}

install_pii() {
	print_info "Installing PII detection dependencies..."

	if [[ ! -d "${VENV_DIR}/bin" ]]; then
		print_warning "Core not installed yet. Installing core first..."
		install_core
	fi

	"${VENV_DIR}/bin/pip" install --quiet presidio-analyzer presidio-anonymizer
	"${VENV_DIR}/bin/python3" -m spacy download en_core_web_lg --quiet 2>/dev/null || {
		print_warning "spaCy model download failed. PII detection may have reduced accuracy."
		print_info "Try manually: ${VENV_DIR}/bin/python3 -m spacy download en_core_web_lg"
	}

	print_success "PII dependencies installed (presidio-analyzer, presidio-anonymizer, spaCy)"
	return 0
}

install_llm() {
	print_info "Checking local LLM setup..."

	if command -v ollama &>/dev/null; then
		print_success "Ollama is installed"
		if ollama list 2>/dev/null | grep -q "llama3"; then
			print_success "llama3 model available"
		else
			print_info "Pulling llama3.2 model for local extraction..."
			ollama pull llama3.2 || print_warning "Failed to pull llama3.2. Pull manually: ollama pull llama3.2"
		fi
	else
		print_warning "Ollama not installed. For local LLM processing:"
		print_info "  brew install ollama && ollama pull llama3.2"
	fi
	return 0
}

# Check installation status
do_status() {
	echo "Document Extraction - Component Status"
	echo "======================================="
	echo ""

	# Python
	local python_version
	python_version="$(python3 --version 2>/dev/null | awk '{print $2}')" || python_version="not found"
	echo "Python:           ${python_version}"

	# Venv
	if [[ -d "${VENV_DIR}/bin" ]]; then
		echo "Virtual env:      ${VENV_DIR}"
	else
		echo "Virtual env:      not created"
	fi

	# Core packages
	echo ""
	echo "Core Packages:"
	if check_python_package "docling"; then
		echo "  docling:        installed"
	else
		echo "  docling:        not installed"
	fi

	if check_python_package "extract_thinker"; then
		echo "  extract-thinker: installed"
	else
		echo "  extract-thinker: not installed"
	fi

	# PII packages
	echo ""
	echo "PII Packages:"
	if check_python_package "presidio_analyzer"; then
		echo "  presidio:       installed"
	else
		echo "  presidio:       not installed"
	fi

	# LLM backends
	echo ""
	echo "LLM Backends:"
	if command -v ollama &>/dev/null; then
		local ollama_models
		ollama_models="$(ollama list 2>/dev/null | safe_grep_count ".")"
		echo "  ollama:         installed (${ollama_models} models)"
	else
		echo "  ollama:         not installed"
	fi

	# OCR
	echo ""
	echo "OCR Backends:"
	if command -v tesseract &>/dev/null; then
		echo "  tesseract:      installed"
	else
		echo "  tesseract:      not installed"
	fi

	if check_python_package "easyocr"; then
		echo "  easyocr:        installed"
	else
		echo "  easyocr:        not installed"
	fi

	# Validation pipeline
	echo ""
	echo "Validation Pipeline:"
	if [[ -f "$PIPELINE_PY" ]]; then
		echo "  extraction_pipeline.py: available"
		if check_python_package "pydantic" 2>/dev/null; then
			echo "  pydantic:       installed"
		else
			echo "  pydantic:       not installed (run: pip install pydantic>=2.0)"
		fi
	else
		echo "  extraction_pipeline.py: not found"
	fi

	# Related tools
	echo ""
	echo "Related Tools:"
	if command -v pandoc &>/dev/null; then
		echo "  pandoc:         installed"
	else
		echo "  pandoc:         not installed"
	fi

	if command -v mineru &>/dev/null; then
		echo "  mineru:         installed"
	else
		echo "  mineru:         not installed"
	fi

	return 0
}

# Convert document to markdown/JSON using Docling
do_convert() {
	local input_file="$1"
	local output_format="${2:-markdown}"

	validate_file_exists "$input_file" "Input file" || return 1
	activate_venv || return 1
	ensure_workspace

	local output_ext
	case "$output_format" in
	markdown | md) output_ext="md" ;;
	json) output_ext="json" ;;
	text | txt) output_ext="txt" ;;
	*)
		print_error "Unsupported output format: ${output_format}"
		return 1
		;;
	esac

	local basename
	basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"
	local output_file="${WORKSPACE_DIR}/${basename}.${output_ext}"

	print_info "Converting ${input_file} to ${output_format}..."

	"${VENV_DIR}/bin/python3" -c "
import sys
from docling.document_converter import DocumentConverter

converter = DocumentConverter()
result = converter.convert('${input_file}')

output_format = '${output_format}'
if output_format in ('markdown', 'md'):
    content = result.document.export_to_markdown()
elif output_format == 'json':
    import json
    content = json.dumps(result.document.export_to_dict(), indent=2)
else:
    content = result.document.export_to_markdown()

with open('${output_file}', 'w') as f:
    f.write(content)

print(f'Converted: ${output_file}')
" || {
		print_error "Conversion failed"
		return 1
	}

	print_success "Output: ${output_file}"
	return 0
}

# Scan file for PII
do_pii_scan() {
	local input_file="$1"

	validate_file_exists "$input_file" "Input file" || return 1
	activate_venv || return 1

	if ! check_python_package "presidio_analyzer"; then
		print_error "Presidio not installed. Run: document-extraction-helper.sh install --pii"
		return 1
	fi

	print_info "Scanning ${input_file} for PII..."

	"${VENV_DIR}/bin/python3" -c "
import sys
from presidio_analyzer import AnalyzerEngine

analyzer = AnalyzerEngine()

with open('${input_file}', 'r') as f:
    text = f.read()

results = analyzer.analyze(text=text, language='en')

if not results:
    print('No PII detected.')
    sys.exit(0)

print(f'Found {len(results)} PII entities:')
print()
for r in sorted(results, key=lambda x: x.score, reverse=True):
    snippet = text[r.start:r.end]
    masked = snippet[0] + '*' * (len(snippet) - 2) + snippet[-1] if len(snippet) > 2 else '**'
    print(f'  {r.entity_type:20s} score={r.score:.2f}  [{masked}]  pos={r.start}-{r.end}')
" || {
		print_error "PII scan failed"
		return 1
	}

	return 0
}

# Redact PII from text file
do_pii_redact() {
	local input_file="$1"
	local output_file="${2:-}"

	validate_file_exists "$input_file" "Input file" || return 1
	activate_venv || return 1

	if ! check_python_package "presidio_analyzer"; then
		print_error "Presidio not installed. Run: document-extraction-helper.sh install --pii"
		return 1
	fi

	if [[ -z "$output_file" ]]; then
		local basename
		basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"
		local ext="${input_file##*.}"
		output_file="${WORKSPACE_DIR}/${basename}-redacted.${ext}"
	fi

	ensure_workspace
	print_info "Redacting PII from ${input_file}..."

	"${VENV_DIR}/bin/python3" -c "
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine

analyzer = AnalyzerEngine()
anonymizer = AnonymizerEngine()

with open('${input_file}', 'r') as f:
    text = f.read()

results = analyzer.analyze(text=text, language='en')
anonymized = anonymizer.anonymize(text=text, analyzer_results=results)

with open('${output_file}', 'w') as f:
    f.write(anonymized.text)

print(f'Redacted {len(results)} PII entities')
print(f'Output: ${output_file}')
" || {
		print_error "PII redaction failed"
		return 1
	}

	print_success "Redacted output: ${output_file}"
	return 0
}

# Classify document type from text or file
do_classify() {
	local input_file="$1"

	validate_file_exists "$input_file" "Input file" || return 1

	# If it's a text file, pass directly to pipeline
	local ext="${input_file##*.}"
	ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"

	if [[ "$ext" == "txt" ]] || [[ "$ext" == "md" ]]; then
		"${VENV_DIR}/bin/python3" "$PIPELINE_PY" classify "$input_file" 2>/dev/null || {
			# Fallback: use system python if venv not available
			python3 "$PIPELINE_PY" classify "$input_file"
		}
		return $?
	fi

	# For non-text files, convert to text first via Docling or OCR
	ensure_workspace
	local basename
	basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"
	local text_file="${WORKSPACE_DIR}/${basename}-ocr-text.txt"

	# Try Docling conversion for document formats
	if { [[ "$ext" == "pdf" ]] || [[ "$ext" == "docx" ]] || [[ "$ext" == "html" ]]; } &&
		activate_venv 2>/dev/null && check_python_package "docling" 2>/dev/null; then
		"${VENV_DIR}/bin/python3" -c "
from docling.document_converter import DocumentConverter
converter = DocumentConverter()
result = converter.convert('${input_file}')
text = result.document.export_to_markdown()
with open('${text_file}', 'w') as f:
    f.write(text)
" 2>/dev/null || {
			print_warning "Docling conversion failed, trying OCR fallback"
		}
	fi

	# For images or if Docling failed, try GLM-OCR
	if { [[ ! -f "$text_file" ]] || [[ ! -s "$text_file" ]]; } &&
		command -v ollama &>/dev/null; then
		local ocr_text
		if [[ "$ext" =~ ^(png|jpg|jpeg|tiff|bmp|webp|heic)$ ]]; then
			ocr_text="$(ollama run glm-ocr "Extract all text from this document" --images "$input_file" 2>/dev/null)" || true
		elif [[ "$ext" == "pdf" ]]; then
			# Convert first page to image for classification
			local tmp_img
			# t2997: drop .png — image classifiers detect format from magic bytes,
			# not filename extension. XXXXXX must be at end for BSD mktemp.
			tmp_img="$(mktemp /tmp/classify-XXXXXX)"
			if command -v magick &>/dev/null; then
				magick -density 150 "${input_file}[0]" -quality 80 "$tmp_img" 2>/dev/null
			elif command -v convert &>/dev/null; then
				convert -density 150 "${input_file}[0]" -quality 80 "$tmp_img" 2>/dev/null
			fi
			if [[ -f "$tmp_img" ]] && [[ -s "$tmp_img" ]]; then
				ocr_text="$(ollama run glm-ocr "Extract all text" --images "$tmp_img" 2>/dev/null)" || true
			fi
			rm -f "$tmp_img"
		fi
		if [[ -n "${ocr_text:-}" ]]; then
			echo "$ocr_text" >"$text_file"
		fi
	fi

	if [[ -f "$text_file" ]] && [[ -s "$text_file" ]]; then
		"${VENV_DIR}/bin/python3" "$PIPELINE_PY" classify "$text_file" 2>/dev/null ||
			python3 "$PIPELINE_PY" classify "$text_file"
	else
		print_error "Could not extract text for classification"
		return 1
	fi

	return 0
}

# Validate extracted JSON through the validation pipeline
do_validate() {
	local input_file="$1"
	local doc_type="${2:-auto}"

	validate_file_exists "$input_file" "Input file" || return 1

	local type_arg=""
	if [[ "$doc_type" != "auto" ]]; then
		type_arg="--type ${doc_type}"
	fi

	# Try venv python first, fall back to system python
	# shellcheck disable=SC2086
	"${VENV_DIR}/bin/python3" "$PIPELINE_PY" validate "$input_file" $type_arg 2>/dev/null ||
		python3 "$PIPELINE_PY" validate "$input_file" $type_arg
	return $?
}

# Determine LLM backend with multi-model fallback
# Model IDs are configurable via environment variables:
#   DOCEXTRACT_GEMINI_MODEL  - Gemini model (default: gemini-2.5-flash)
#   DOCEXTRACT_OPENAI_MODEL  - OpenAI model (default: gpt-4o)
#   DOCEXTRACT_ANTHROPIC_MODEL - Anthropic model (default: claude-sonnet-4-6)
#   DOCEXTRACT_OLLAMA_MODEL  - Ollama model (default: llama3.2)
resolve_llm_backend() {
	local privacy="$1"
	local llm_backend=""

	local gemini_model="${DOCEXTRACT_GEMINI_MODEL:-gemini-2.5-flash}"
	local openai_model="${DOCEXTRACT_OPENAI_MODEL:-gpt-4o}"
	local anthropic_model="${DOCEXTRACT_ANTHROPIC_MODEL:-claude-sonnet-4-6}"
	local ollama_model="${DOCEXTRACT_OLLAMA_MODEL:-llama3.2}"

	# Basic model name sanity check (no spaces, no shell metacharacters)
	local model_var
	for model_var in "$gemini_model" "$openai_model" "$anthropic_model" "$ollama_model"; do
		if [[ "$model_var" =~ [[:space:]\;\|\&\$] ]]; then
			print_error "Invalid model identifier '${model_var}': contains disallowed characters"
			return 1
		fi
	done

	case "$privacy" in
	local)
		if command -v ollama &>/dev/null; then
			llm_backend="ollama/${ollama_model}"
		else
			print_error "Ollama required for local privacy mode but not installed"
			return 1
		fi
		;;
	edge)
		llm_backend="cloudflare/workers-ai"
		;;
	cloud)
		# Prefer Gemini Flash for cost efficiency, fall back to OpenAI
		if [[ -n "${GOOGLE_API_KEY:-}" ]] || [[ -n "${GEMINI_API_KEY:-}" ]]; then
			llm_backend="google/${gemini_model}"
		elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
			llm_backend="openai/${openai_model}"
		elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
			llm_backend="anthropic/${anthropic_model}"
		else
			print_warning "No cloud API key found, falling back to local"
			if command -v ollama &>/dev/null; then
				llm_backend="ollama/${ollama_model}"
			else
				print_error "No LLM backend available"
				return 1
			fi
		fi
		;;
	none | *)
		# Auto-select: prefer local, fall back to cloud
		if command -v ollama &>/dev/null; then
			llm_backend="ollama/${ollama_model}"
		elif [[ -n "${GOOGLE_API_KEY:-}" ]] || [[ -n "${GEMINI_API_KEY:-}" ]]; then
			llm_backend="google/${gemini_model}"
		elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
			llm_backend="openai/${openai_model}"
		else
			print_error "No LLM backend available (install Ollama or set API key)"
			return 1
		fi
		;;
	esac

	echo "$llm_backend"
	return 0
}

# Schema sub-functions: each emits a Python class definition to stdout.
# Called by build_schema_code() below.

_schema_invoice() {
	printf '%s' "
class LineItem(BaseModel):
    description: str = ''
    quantity: float = 0
    unit_price: float = 0
    amount: float = 0

class Invoice(BaseModel):
    vendor_name: str = ''
    invoice_number: str = ''
    invoice_date: str = ''
    due_date: str = ''
    subtotal: float = 0
    tax: float = 0
    total: float = 0
    currency: str = 'USD'
    line_items: list[LineItem] = []

schema_class = Invoice
"
	return 0
}

_schema_receipt() {
	printf '%s' "
class ReceiptItem(BaseModel):
    name: str = ''
    price: float = 0

class Receipt(BaseModel):
    merchant: str = ''
    date: str = ''
    total: float = 0
    payment_method: str = ''
    items: list[ReceiptItem] = []

schema_class = Receipt
"
	return 0
}

_schema_contract() {
	printf '%s' "
class ContractSummary(BaseModel):
    parties: list[str] = []
    effective_date: str = ''
    termination_date: str = ''
    key_terms: list[str] = []
    obligations: list[str] = []

schema_class = ContractSummary
"
	return 0
}

_schema_id_document() {
	printf '%s' "
class IDDocument(BaseModel):
    document_type: str = ''
    full_name: str = ''
    date_of_birth: str = ''
    document_number: str = ''
    expiry_date: str = ''
    issuing_authority: str = ''

schema_class = IDDocument
"
	return 0
}

_schema_purchase_invoice() {
	printf '%s' "
from typing import Optional

class PurchaseLineItem(BaseModel):
    description: str = ''
    quantity: float = 1.0
    unit_price: float = 0.0
    amount: float = 0.0
    vat_rate: Optional[str] = None
    vat_amount: Optional[float] = None
    nominal_code: Optional[str] = None

class PurchaseInvoice(BaseModel):
    vendor_name: str = ''
    vendor_address: Optional[str] = None
    vendor_vat_number: Optional[str] = None
    invoice_number: str = ''
    invoice_date: str = ''
    due_date: Optional[str] = None
    purchase_order: Optional[str] = None
    subtotal: float = 0.0
    vat_amount: float = 0.0
    total: float = 0.0
    currency: str = 'GBP'
    line_items: list[PurchaseLineItem] = []
    payment_terms: Optional[str] = None
    bank_details: Optional[str] = None
    document_type: str = 'purchase_invoice'

schema_class = PurchaseInvoice
"
	return 0
}

_schema_expense_receipt() {
	printf '%s' "
from typing import Optional

class ReceiptItem(BaseModel):
    name: str = ''
    quantity: float = 1.0
    unit_price: Optional[float] = None
    price: float = 0.0
    vat_rate: Optional[str] = None

class ExpenseReceipt(BaseModel):
    merchant_name: str = ''
    merchant_address: Optional[str] = None
    merchant_vat_number: Optional[str] = None
    receipt_number: Optional[str] = None
    date: str = ''
    time: Optional[str] = None
    subtotal: Optional[float] = None
    vat_amount: Optional[float] = None
    total: float = 0.0
    currency: str = 'GBP'
    items: list[ReceiptItem] = []
    payment_method: Optional[str] = None
    card_last_four: Optional[str] = None
    expense_category: Optional[str] = None
    document_type: str = 'expense_receipt'

schema_class = ExpenseReceipt
"
	return 0
}

_schema_credit_note() {
	printf '%s' "
from typing import Optional

class CreditLineItem(BaseModel):
    description: str = ''
    quantity: float = 1.0
    unit_price: float = 0.0
    amount: float = 0.0
    vat_rate: Optional[str] = None
    vat_amount: Optional[float] = None

class CreditNote(BaseModel):
    vendor_name: str = ''
    credit_note_number: str = ''
    date: str = ''
    original_invoice: Optional[str] = None
    subtotal: float = 0.0
    vat_amount: float = 0.0
    total: float = 0.0
    currency: str = 'GBP'
    reason: Optional[str] = None
    line_items: list[CreditLineItem] = []
    document_type: str = 'credit_note'

schema_class = CreditNote
"
	return 0
}

_schema_auto() {
	printf '%s' "
schema_class = None
"
	return 0
}

# Build Python schema class definitions for a given schema name.
# Outputs the Python snippet to stdout; caller captures with $().
# Dispatches to _schema_*() sub-functions for each document type.
build_schema_code() {
	local schema="$1"
	case "$schema" in
	invoice) _schema_invoice ;;
	receipt) _schema_receipt ;;
	contract) _schema_contract ;;
	id-document) _schema_id_document ;;
	purchase-invoice) _schema_purchase_invoice ;;
	expense-receipt) _schema_expense_receipt ;;
	credit-note) _schema_credit_note ;;
	auto | *) _schema_auto ;;
	esac
	return 0
}

# Run the Python extraction block for a single document.
# Args: input_file output_file llm_backend schema_name schema_code pipeline_py
run_extraction_python() {
	local input_file="$1"
	local output_file="$2"
	local llm_backend="$3"
	local schema_name="$4"
	local schema_code="$5"
	local pipeline_py="$6"

	"${VENV_DIR}/bin/python3" -c "
import json
import os
import sys
from pathlib import Path
from pydantic import BaseModel
from extract_thinker import Extractor

${schema_code}

input_file = '${input_file}'
output_file = '${output_file}'
llm_backend = '${llm_backend}'
schema_name = '${schema_name}'

extractor = Extractor()
extractor.load_document_loader('docling')
extractor.load_llm(llm_backend)

try:
    if schema_class is not None:
        result = extractor.extract(input_file, schema_class)
        raw_output = result.model_dump()
    else:
        # Auto mode: extract to markdown first, then classify
        from docling.document_converter import DocumentConverter
        converter = DocumentConverter()
        doc_result = converter.convert(input_file)
        md_content = doc_result.document.export_to_markdown()

        try:
            sys.path.insert(0, os.path.dirname('${pipeline_py}'))
            from extraction_pipeline import classify_document, DocumentType
            doc_type, scores = classify_document(md_content)
            print(f'Auto-classified as: {doc_type.value} (scores: {scores})', file=sys.stderr)
        except ImportError:
            doc_type = None

        raw_output = {
            'content': md_content,
            'format': 'markdown',
            'classified_type': doc_type.value if doc_type else 'unknown',
        }

    # Run validation pipeline if extraction_pipeline.py is available
    validated_output = None
    try:
        sys.path.insert(0, os.path.dirname('${pipeline_py}'))
        from extraction_pipeline import parse_and_validate, DocumentType as DT

        type_map = {
            'purchase-invoice': DT.PURCHASE_INVOICE,
            'purchase_invoice': DT.PURCHASE_INVOICE,
            'expense-receipt': DT.EXPENSE_RECEIPT,
            'expense_receipt': DT.EXPENSE_RECEIPT,
            'credit-note': DT.CREDIT_NOTE,
            'credit_note': DT.CREDIT_NOTE,
            'invoice': DT.SALES_INVOICE,
            'receipt': DT.GENERIC_RECEIPT,
        }
        dt = type_map.get(schema_name)
        if dt is None and 'document_type' in raw_output:
            dt = type_map.get(raw_output['document_type'])
        if dt is None:
            dt = DT.PURCHASE_INVOICE

        validated = parse_and_validate(raw_output, dt, input_file)
        validated_output = json.loads(validated.model_dump_json())
    except (ImportError, Exception) as e:
        print(f'Validation pipeline skipped: {e}', file=sys.stderr)

    final_output = validated_output if validated_output else raw_output

    with open(output_file, 'w') as f:
        json.dump(final_output, f, indent=2, default=str)

    print(json.dumps(final_output, indent=2, default=str))
except Exception as e:
    print(f'Extraction error: {e}', file=sys.stderr)
    sys.exit(1)
"
	return $?
}

# Extract structured data from document
do_extract() {
	local input_file="$1"
	local schema="${2:-auto}"
	local privacy="${3:-none}"

	validate_file_exists "$input_file" "Input file" || return 1
	activate_venv || return 1
	ensure_workspace

	local basename
	basename="$(basename "$input_file" | sed 's/\.[^.]*$//')"
	local output_file="${WORKSPACE_DIR}/${basename}-extracted.json"

	local llm_backend
	llm_backend="$(resolve_llm_backend "$privacy")" || return 1

	print_info "Extracting from ${input_file} (schema=${schema}, privacy=${privacy}, llm=${llm_backend})..."

	local schema_code
	schema_code="$(build_schema_code "$schema")"

	run_extraction_python \
		"$input_file" "$output_file" "$llm_backend" "$schema" "$schema_code" "$PIPELINE_PY" || {
		print_error "Extraction failed"
		return 1
	}

	print_success "Output: ${output_file}"
	return 0
}

# Batch extract from directory
do_batch() {
	local input_dir="$1"
	local schema="${2:-auto}"
	local privacy="${3:-none}"
	local pattern="${4:-*}"

	if [[ ! -d "$input_dir" ]]; then
		print_error "Directory not found: ${input_dir}"
		return 1
	fi

	ensure_workspace

	local count=0
	local failed=0
	local supported_extensions="pdf docx pptx xlsx html htm png jpg jpeg tiff bmp"

	print_info "Batch extracting from ${input_dir} (pattern=${pattern}, schema=${schema})..."

	for file in "${input_dir}"/${pattern}; do
		[[ -f "$file" ]] || continue

		local ext="${file##*.}"
		ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"

		# Check if extension is supported
		local supported=0
		for supported_ext in $supported_extensions; do
			if [[ "$ext" == "$supported_ext" ]]; then
				supported=1
				break
			fi
		done

		if [[ "$supported" -eq 0 ]]; then
			continue
		fi

		echo ""
		print_info "Processing: ${file}"
		if do_extract "$file" "$schema" "$privacy" "json"; then
			count=$((count + 1))
		else
			failed=$((failed + 1))
		fi
	done

	echo ""
	print_success "Batch complete: ${count} succeeded, ${failed} failed"
	print_info "Output directory: ${WORKSPACE_DIR}"
	return 0
}

# List available schemas
do_schemas() {
	echo "Available Extraction Schemas"
	echo "============================"
	echo ""
	echo "  Accounting schemas (UK VAT support, QuickFile integration):"
	echo "  purchase-invoice  - Supplier invoices: vendor, items, VAT, totals, dates"
	echo "  expense-receipt   - Till/shop receipts: merchant, items, VAT, payment method"
	echo "  credit-note       - Supplier credit notes: vendor, credited items, VAT"
	echo ""
	echo "  General schemas:"
	echo "  invoice       - Sales invoices (issued by you): client, items, totals"
	echo "  receipt       - Generic receipts (no accounting integration)"
	echo "  contract      - Parties, dates, key terms, obligations"
	echo "  id-document   - Name, DOB, document number, expiry"
	echo "  auto          - Auto-detect and convert to markdown (default)"
	echo ""
	echo "Custom schemas can be defined as Pydantic models in Python."
	echo "See: .agents/tools/document/extraction-schemas.md"
	return 0
}

# Show help
do_help() {
	echo "Document Extraction Helper - AI DevOps Framework"
	echo ""
	echo "${HELP_LABEL_USAGE}"
	echo "  document-extraction-helper.sh <command> [options]"
	echo ""
	echo "${HELP_LABEL_COMMANDS}"
	echo "  extract <file> [--schema <name>] [--privacy <mode>] [--output <format>]"
	echo "      Extract structured data with validation pipeline"
	echo ""
	echo "  batch <dir> [--schema <name>] [--privacy <mode>] [--pattern <glob>]"
	echo "      Batch extract from all documents in a directory"
	echo ""
	echo "  classify <file>"
	echo "      Classify document type (purchase-invoice, expense-receipt, credit-note)"
	echo ""
	echo "  validate <json-file> [--type <doc-type>]"
	echo "      Validate extracted JSON (VAT arithmetic, dates, confidence scoring)"
	echo ""
	echo "  pii-scan <file>"
	echo "      Scan a text file for PII entities"
	echo ""
	echo "  pii-redact <file> [--output <file>]"
	echo "      Redact PII from a text file"
	echo ""
	echo "  convert <file> [--output <format>]"
	echo "      Convert document to markdown/JSON/text (no LLM needed)"
	echo ""
	echo "  install [--all|--core|--pii|--llm]"
	echo "      Install dependencies (default: --all)"
	echo ""
	echo "  status"
	echo "      Check installed components"
	echo ""
	echo "  schemas"
	echo "      List available extraction schemas"
	echo ""
	echo "Privacy Modes:"
	echo "  local   - Fully local via Ollama (no data leaves machine)"
	echo "  edge    - Cloudflare Workers AI (privacy-preserving cloud)"
	echo "  cloud   - OpenAI/Anthropic APIs (best quality)"
	echo "  none    - Auto-select best available backend (default)"
	echo ""
	echo "Output Formats: json, markdown, csv, text"
	echo ""
	echo "${HELP_LABEL_EXAMPLES}"
	echo "  document-extraction-helper.sh extract invoice.pdf --schema purchase-invoice --privacy local"
	echo "  document-extraction-helper.sh extract receipt.jpg --schema expense-receipt --privacy local"
	echo "  document-extraction-helper.sh batch ./invoices --schema purchase-invoice"
	echo "  document-extraction-helper.sh pii-scan document.txt"
	echo "  document-extraction-helper.sh pii-redact document.txt --output redacted.txt"
	echo "  document-extraction-helper.sh convert report.pdf --output markdown"
	echo "  document-extraction-helper.sh install --core"
	echo "  document-extraction-helper.sh status"
	return 0
}

# Parse --flag value options from remaining positional arguments.
# Populates variables in the caller's scope via eval (bash 3.2 compatible).
# Args: command remaining_args...
# Sets: schema privacy output_format output_file pattern install_component
parse_named_opts() {
	local _cmd="$1"
	shift || true

	# Defaults (caller must declare these locals before calling)
	schema="auto"
	privacy="none"
	output_format="json"
	output_file=""
	pattern="*"
	install_component="all"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--schema)
			schema="${2:-auto}"
			shift 2 || {
				print_error "Missing value for --schema"
				return 1
			}
			;;
		--privacy)
			privacy="${2:-none}"
			shift 2 || {
				print_error "Missing value for --privacy"
				return 1
			}
			;;
		--output)
			output_format="${2:-json}"
			shift 2 || {
				print_error "Missing value for --output"
				return 1
			}
			;;
		--pattern)
			pattern="${2:-*}"
			shift 2 || {
				print_error "Missing value for --pattern"
				return 1
			}
			;;
		--all | --core | --pii | --llm)
			install_component="${1#--}"
			shift
			;;
		*)
			# Treat as output file for pii-redact
			if [[ "$_cmd" == "pii-redact" ]] && [[ -z "$output_file" ]]; then
				output_file="$1"
			fi
			shift
			;;
		esac
	done
	return 0
}

# Dispatch a parsed command to its do_* handler.
# Args: command file schema privacy output_format output_file pattern install_component
dispatch_command() {
	local command="$1"
	local file="$2"
	local schema="$3"
	local privacy="$4"
	local output_format="$5"
	local output_file="$6"
	local pattern="$7"
	local install_component="$8"

	case "$command" in
	extract)
		[[ -n "$file" ]] || {
			print_error "${ERROR_INPUT_FILE_REQUIRED}"
			return 1
		}
		do_extract "$file" "$schema" "$privacy" "$output_format"
		;;
	classify)
		[[ -n "$file" ]] || {
			print_error "${ERROR_INPUT_FILE_REQUIRED}"
			return 1
		}
		do_classify "$file"
		;;
	validate)
		[[ -n "$file" ]] || {
			print_error "${ERROR_INPUT_FILE_REQUIRED}"
			return 1
		}
		do_validate "$file" "$schema"
		;;
	batch)
		[[ -n "$file" ]] || {
			print_error "Input directory is required"
			return 1
		}
		do_batch "$file" "$schema" "$privacy" "$pattern"
		;;
	pii-scan)
		[[ -n "$file" ]] || {
			print_error "${ERROR_INPUT_FILE_REQUIRED}"
			return 1
		}
		do_pii_scan "$file"
		;;
	pii-redact)
		[[ -n "$file" ]] || {
			print_error "${ERROR_INPUT_FILE_REQUIRED}"
			return 1
		}
		do_pii_redact "$file" "$output_file"
		;;
	convert)
		[[ -n "$file" ]] || {
			print_error "${ERROR_INPUT_FILE_REQUIRED}"
			return 1
		}
		do_convert "$file" "$output_format"
		;;
	install)
		do_install "$install_component"
		;;
	status)
		do_status
		;;
	schemas)
		do_schemas
		;;
	help | --help | -h)
		do_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		do_help
		return 1
		;;
	esac
	return $?
}

# Parse command-line arguments and dispatch to the appropriate handler.
parse_args() {
	local command="${1:-help}"
	shift || true

	# Extract first positional arg (file/dir) before named options
	local file=""
	if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^-- ]]; then
		file="$1"
		shift || true
	fi

	# Option variables populated by parse_named_opts
	local schema privacy output_format output_file pattern install_component
	parse_named_opts "$command" "$@" || return 1

	dispatch_command \
		"$command" "$file" "$schema" "$privacy" \
		"$output_format" "$output_file" "$pattern" "$install_component"
	return $?
}

# Main entry point
parse_args "$@"
