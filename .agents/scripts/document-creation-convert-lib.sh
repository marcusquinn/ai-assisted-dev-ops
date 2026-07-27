#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Document Creation -- Conversion Engine Sub-Library
# =============================================================================
# Conversion backends (pandoc, LibreOffice, Reader-LM, RolmOCR, odfpy),
# tool selection logic, EML/MIME conversion helpers, and OCR pre-processing.
#
# Usage: source "${SCRIPT_DIR}/document-creation-convert-lib.sh"
#
# Dependencies:
#   - document-creation-helper.sh (log_info, log_ok, log_warn, log_error, die,
#     has_cmd, human_filesize, get_ext, activate_venv, has_python_pkg,
#     has_reader_lm, has_rolm_ocr, is_scanned_pdf, select_ocr_provider,
#     run_ocr, ocr_scanned_pdf, cmd_normalise)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_DOCUMENT_CREATION_CONVERT_LIB_LOADED:-}" ]] && return 0
_DOCUMENT_CREATION_CONVERT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Internal helpers ---

# Log a "Created: <path> (<size>)" message for a successfully converted file.
# Args: output_path [size_string]
_log_created() {
	local _path="$1"
	local _size="${2:-}"
	if [[ -n "${_size}" ]]; then
		log_ok "Created: ${_path} (${_size})"
	else
		log_ok "Created: ${_path}"
	fi
	return 0
}

# ============================================================================
# MIME/Email conversion functions
# ============================================================================

# Resolve email metadata and build the output directory path.
# Prints the email_dir and base_name (tab-separated) to stdout.
# Args: input_file output_dir
_eml_resolve_paths() {
	local input="$1"
	local output_dir="$2"

	python3 - "$input" "$output_dir" <<'PYEOF'
import sys
import os
import email
import email.policy
from email import message_from_binary_file
from email.utils import parsedate_to_datetime, parseaddr
from datetime import datetime
import re

input_file = sys.argv[1]
output_dir = sys.argv[2]

with open(input_file, 'rb') as f:
    msg = message_from_binary_file(f, policy=email.policy.default)

subject = msg.get('Subject', 'no-subject')
from_header = msg.get('From', '')
date_header = msg.get('Date', '')

sender_name, sender_email = parseaddr(from_header)
if not sender_email:
    sender_email = 'unknown'
if not sender_name:
    sender_name = 'unknown'

try:
    dt = parsedate_to_datetime(date_header)
    timestamp = dt.strftime('%Y-%m-%d-%H%M%S')
except Exception:
    timestamp = datetime.now().strftime('%Y-%m-%d-%H%M%S')

def sanitize(s):
    s = re.sub(r'[^\w\s.-]', '', s)
    s = re.sub(r'\s+', '-', s)
    return s[:50]

subject_safe = sanitize(subject)
sender_email_safe = sanitize(sender_email.replace('@', '-at-'))
sender_name_safe = sanitize(sender_name)

base_name = f"{timestamp}-{subject_safe}-{sender_email_safe}-{sender_name_safe}"
email_dir = os.path.join(output_dir, base_name)
os.makedirs(email_dir, exist_ok=True)

print(f"{email_dir}\t{base_name}")
PYEOF

	return 0
}

# Write markdown and raw-headers files from a parsed .eml.
# Prints "Email converted: <path>" and "Raw headers: <path>" to stdout.
# Args: input_file email_dir base_name
_eml_write_markdown() {
	local input="$1"
	local email_dir="$2"
	local base_name="$3"

	python3 - "$input" "$email_dir" "$base_name" <<'PYEOF'
import sys
import os
import email
import email.policy
from email import message_from_binary_file

input_file = sys.argv[1]
email_dir = sys.argv[2]
base_name = sys.argv[3]

with open(input_file, 'rb') as f:
    msg = message_from_binary_file(f, policy=email.policy.default)

subject = msg.get('Subject', 'no-subject')
from_header = msg.get('From', '')
date_header = msg.get('Date', '')
to_header = msg.get('To', '')
cc_header = msg.get('Cc', '')

from email.utils import parseaddr
sender_name, sender_email = parseaddr(from_header)
if not sender_email:
    sender_email = 'unknown'
if not sender_name:
    sender_name = 'unknown'

# Extract body
body_text = ""
body_html = ""
if msg.is_multipart():
    for part in msg.walk():
        content_disposition = str(part.get("Content-Disposition", ""))
        if "attachment" in content_disposition:
            continue
        ct = part.get_content_type()
        if ct == "text/plain":
            try:
                body_text = part.get_content()
            except Exception:
                pass
        elif ct == "text/html":
            try:
                body_html = part.get_content()
            except Exception:
                pass
else:
    ct = msg.get_content_type()
    if ct == "text/plain":
        try:
            body_text = msg.get_content()
        except Exception:
            pass
    elif ct == "text/html":
        try:
            body_html = msg.get_content()
        except Exception:
            pass

body = body_text if body_text else body_html

md_file = os.path.join(email_dir, f"{base_name}.md")
with open(md_file, 'w', encoding='utf-8') as f:
    f.write(f"# Email: {subject}\n\n")
    f.write(f"**From:** {sender_name} <{sender_email}>\n")
    f.write(f"**Date:** {date_header}\n")
    if to_header:
        f.write(f"**To:** {to_header}\n")
    if cc_header:
        f.write(f"**Cc:** {cc_header}\n")
    f.write("\n---\n\n")
    f.write(body)

raw_headers_file = os.path.join(email_dir, f"{base_name}-raw-headers.md")
with open(raw_headers_file, 'w', encoding='utf-8') as f:
    f.write("# Raw Email Headers\n\n```\n")
    for key, value in msg.items():
        f.write(f"{key}: {value}\n")
    f.write("```\n")

print(f"Email converted: {md_file}")
print(f"Raw headers: {raw_headers_file}")
PYEOF

	return 0
}

# Extract attachments from a .eml file into email_dir.
# Prints "Extracted attachment: <name>" lines and "Attachments: N" to stdout.
# Args: input_file email_dir
_eml_extract_attachments() {
	local input="$1"
	local email_dir="$2"

	python3 - "$input" "$email_dir" <<'PYEOF'
import sys
import os
import email
import email.policy
from email import message_from_binary_file

input_file = sys.argv[1]
email_dir = sys.argv[2]

with open(input_file, 'rb') as f:
    msg = message_from_binary_file(f, policy=email.policy.default)

attachment_count = 0
if msg.is_multipart():
    for part in msg.walk():
        content_disposition = str(part.get("Content-Disposition", ""))
        if "attachment" in content_disposition:
            filename = part.get_filename()
            if filename:
                attachment_count += 1
                attachment_path = os.path.join(email_dir, filename)
                with open(attachment_path, 'wb') as f:
                    f.write(part.get_payload(decode=True))
                print(f"  Extracted attachment: {filename}")

print(f"Attachments: {attachment_count}")
PYEOF

	return 0
}

# Python MIME parser for a single .eml file.
# Writes markdown + raw-headers files and prints status lines to stdout.
# Orchestrates _eml_resolve_paths, _eml_write_markdown, _eml_extract_attachments.
# Args: input_file output_dir
_eml_parse_mime() {
	local input="$1"
	local output_dir="$2"

	# Step 1: resolve output paths from email metadata
	local path_info
	path_info=$(_eml_resolve_paths "$input" "$output_dir")
	local email_dir
	email_dir=$(printf '%s' "$path_info" | cut -f1)
	local base_name
	base_name=$(printf '%s' "$path_info" | cut -f2)

	if [[ -z "$email_dir" || -z "$base_name" ]]; then
		die "Failed to resolve email paths for: ${input}"
	fi

	# Step 2: write markdown and raw headers
	_eml_write_markdown "$input" "$email_dir" "$base_name"

	# Step 3: extract attachments
	_eml_extract_attachments "$input" "$email_dir"

	printf 'Output directory: %s\n' "$email_dir"

	return 0
}

# Run normalise on the converted markdown path extracted from eml_output_log.
# Args: eml_output_log no_normalise
_eml_run_normalise() {
	local eml_output_log="$1"
	local no_normalise="$2"

	if [[ "${no_normalise}" == true ]] || [[ ! -f "${eml_output_log}" ]]; then
		return 0
	fi

	local md_path
	md_path=$(grep '^Email converted: ' "${eml_output_log}" | sed 's/^Email converted: //')
	if [[ -n "${md_path}" ]] && [[ -f "${md_path}" ]]; then
		log_info "Running email normalisation on: $(basename "${md_path}")"
		cmd_normalise "${md_path}" --inplace --email
	fi

	return 0
}

# Convert .eml or .msg file to markdown with attachments
convert_eml_to_md() {
	local input="$1"
	local output_dir="$2"
	local no_normalise="${3:-false}"

	log_info "Parsing email: $(basename "$input")"

	# Capture Python output to temp file for md path extraction
	local eml_output_log
	eml_output_log=$(mktemp)

	# Use Python email stdlib to parse MIME
	_eml_parse_mime "$input" "$output_dir" | tee "${eml_output_log}"

	# Extract markdown file path from captured output and run normalise
	_eml_run_normalise "${eml_output_log}" "${no_normalise}"
	rm -f "${eml_output_log}"

	return 0
}

# ============================================================================
# Convert command -- OCR pre-processing and tool execution
# ============================================================================

# OCR pre-processing helper for cmd_convert.
# Modifies input/from_ext via nameref if OCR is needed.
# Args: input_ref from_ext_ref ocr_provider_ref
# Returns 0 always (errors are fatal via die).
_convert_ocr_preprocess() {
	local input_ref="$1"
	local from_ext_ref="$2"
	local ocr_provider_ref="$3"

	local _input="${!input_ref}"
	local _from_ext="${!from_ext_ref}"
	local _ocr_provider="${!ocr_provider_ref}"

	if [[ -z "${_ocr_provider}" ]] && ! { [[ "${_from_ext}" == "pdf" ]] && is_scanned_pdf "${_input}"; }; then
		return 0
	fi

	if [[ -z "${_ocr_provider}" ]]; then
		_ocr_provider="auto"
		log_info "Scanned PDF detected -- activating OCR"
	fi

	local provider
	provider=$(select_ocr_provider "${_ocr_provider}")

	local ocr_work="${HOME}/.aidevops/.agent-workspace/tmp"
	mkdir -p "$ocr_work"

	if [[ "${_from_ext}" == "pdf" ]]; then
		local ocr_text="${ocr_work}/ocr-text-$$.txt"
		ocr_scanned_pdf "${_input}" "$provider" "$ocr_text"
		printf -v "${input_ref}" '%s' "$ocr_text"
		printf -v "${from_ext_ref}" '%s' "txt"
		log_info "Proceeding with page-cited OCR text as input"
	elif [[ "${_from_ext}" =~ ^(png|jpg|jpeg|tiff|tif|bmp|webp)$ ]]; then
		local ocr_text="${ocr_work}/ocr-text-$$.txt"
		log_info "Running OCR on image with ${provider}..."
		run_ocr "${_input}" "$provider" >"$ocr_text"
		local text_len
		text_len=$(wc -c <"$ocr_text" | tr -d ' ')
		log_ok "OCR extracted ${text_len} bytes from image"
		printf -v "${input_ref}" '%s' "$ocr_text"
		printf -v "${from_ext_ref}" '%s' "txt"
	fi

	return 0
}

# Tool execution helper for cmd_convert.
# Args: tool input output to_ext template extra_args dedup_registry
_convert_execute_tool() {
	local tool="$1"
	local input="$2"
	local output="$3"
	local to_ext="$4"
	local template="$5"
	local extra_args="$6"
	local dedup_registry="$7"

	case "${tool}" in
	email-parser)
		convert_email "$input" "$output" "$dedup_registry"
		;;
	pandoc)
		convert_with_pandoc "$input" "$output" "$extra_args"
		;;
	libreoffice)
		local output_dir
		output_dir=$(dirname "$output")
		convert_with_libreoffice "$input" "${to_ext}" "${output_dir}"
		;;
	odfpy-pipeline)
		convert_pdf_to_odt "$input" "$output" "$template"
		;;
	mineru)
		local output_dir
		output_dir=$(dirname "$output")
		log_info "Converting with MinerU: $(basename "$input") -> markdown"
		mineru -p "$input" -o "${output_dir}"
		log_ok "MinerU output in: ${output_dir}"
		;;
	pdftotext)
		log_info "Extracting text with pdftotext"
		pdftotext -layout "$input" "$output"
		if [[ -f "$output" ]]; then
			local size
			size=$(human_filesize "$output")
			_log_created "${output}" "${size}"
		fi
		;;
	pdftohtml)
		log_info "Converting with pdftohtml"
		pdftohtml -s "$input" "$output"
		_log_created "${output}"
		;;
	reader-lm)
		convert_with_reader_lm "$input" "$output"
		;;
	rolm-ocr)
		convert_with_rolm_ocr "$input" "$output"
		;;
	*)
		die "Unknown tool: ${tool}"
		;;
	esac

	return 0
}

# ============================================================================
# Tool selection helpers (extracted for complexity reduction)
# ============================================================================

_select_tool_pdf() {
	local to_ext="$1"
	case "${to_ext}" in
	md | markdown)
		if has_rolm_ocr; then
			printf 'rolm-ocr'
		elif has_cmd mineru; then
			printf 'mineru'
		elif has_cmd pdftotext; then
			printf 'pdftotext'
		else
			die "No tool available for pdf->md. Run: install --minimal (poppler) or install MinerU"
		fi
		;;
	odt)
		if has_python_pkg odf 2>/dev/null && has_cmd pdftotext; then
			printf 'odfpy-pipeline'
		else
			die "No tool available for pdf->odt. Run: install --standard (odfpy + poppler)"
		fi
		;;
	docx)
		if has_cmd soffice || has_cmd libreoffice; then
			printf 'libreoffice'
		else
			die "No tool available for pdf->docx. Run: install --full (LibreOffice)"
		fi
		;;
	html)
		if has_cmd pdftohtml; then
			printf 'pdftohtml'
		else
			die "No tool available for pdf->html. Run: install --minimal (poppler)"
		fi
		;;
	txt | text)
		printf 'pdftotext'
		;;
	*)
		die "Unsupported conversion: pdf -> ${to_ext}"
		;;
	esac
	return 0
}

_select_tool_spreadsheet() {
	local from_ext="$1"
	local to_ext="$2"
	if [[ "${to_ext}" == "csv" ]] || [[ "${from_ext}" == "csv" ]]; then
		if has_python_pkg openpyxl 2>/dev/null; then
			printf 'openpyxl'
		elif has_cmd soffice || has_cmd libreoffice; then
			printf 'libreoffice'
		elif has_cmd pandoc; then
			printf 'pandoc'
		else
			die "No tool available for spreadsheet conversion."
		fi
	elif has_cmd soffice || has_cmd libreoffice; then
		printf 'libreoffice'
	else
		die "LibreOffice required for ${from_ext}->${to_ext}. Run: install --full"
	fi
	return 0
}

_select_tool_presentation() {
	local from_ext="$1"
	local to_ext="$2"
	if [[ "${to_ext}" == "md" ]] || [[ "${to_ext}" == "markdown" ]]; then
		if has_cmd pandoc; then
			printf 'pandoc'
		else
			die "pandoc required for presentation->md."
		fi
	elif has_cmd soffice || has_cmd libreoffice; then
		printf 'libreoffice'
	elif has_cmd pandoc; then
		printf 'pandoc'
	else
		die "No tool available for presentation conversion."
	fi
	return 0
}

_select_tool_html_to_md() {
	if has_reader_lm; then
		printf 'reader-lm'
	elif has_cmd pandoc; then
		printf 'pandoc'
	else
		die "No tool available for html->md. Run: install --minimal (pandoc) or ollama pull reader-lm"
	fi
	return 0
}

select_tool() {
	local from_ext="$1"
	local to_ext="$2"
	local force_tool="${3:-}"

	if [[ -n "${force_tool}" ]]; then
		printf '%s' "${force_tool}"
		return 0
	fi

	# Email formats (.eml, .msg) to markdown
	if [[ "${from_ext}" =~ ^(eml|msg)$ ]] && [[ "${to_ext}" =~ ^(md|markdown)$ ]]; then
		printf 'email-parser'
		return 0
	fi

	# PDF source requires special handling
	if [[ "${from_ext}" == "pdf" ]]; then
		_select_tool_pdf "${to_ext}"
		return 0
	fi

	# Email source requires special handling
	if [[ "${from_ext}" =~ ^(eml|msg)$ ]]; then
		case "${to_ext}" in
		md | markdown)
			printf 'email-parser'
			;;
		*)
			die "Email files can only be converted to markdown. Use: --to md"
			;;
		esac
		return 0
	fi

	# Office format to PDF: prefer LibreOffice
	if [[ "${to_ext}" == "pdf" ]]; then
		if has_cmd soffice || has_cmd libreoffice; then
			printf 'libreoffice'
		elif has_cmd pandoc; then
			printf 'pandoc'
		else
			die "No tool available for ${from_ext}->pdf."
		fi
		return 0
	fi

	# Spreadsheet conversions: prefer LibreOffice
	if [[ "${from_ext}" =~ ^(xlsx|ods|xls)$ ]] || [[ "${to_ext}" =~ ^(xlsx|ods|xls)$ ]]; then
		_select_tool_spreadsheet "${from_ext}" "${to_ext}"
		return 0
	fi

	# Presentation conversions: prefer LibreOffice
	if [[ "${from_ext}" =~ ^(pptx|odp|ppt)$ ]] || [[ "${to_ext}" =~ ^(pptx|odp|ppt)$ ]]; then
		_select_tool_presentation "${from_ext}" "${to_ext}"
		return 0
	fi

	# HTML to markdown: prefer Reader-LM for table preservation
	if [[ "${from_ext}" == "html" ]] && [[ "${to_ext}" =~ ^(md|markdown)$ ]]; then
		_select_tool_html_to_md
		return 0
	fi

	# Default: pandoc handles most text format conversions
	if has_cmd pandoc; then
		printf 'pandoc'
	else
		die "pandoc required. Run: install --minimal"
	fi

	return 0
}

# ============================================================================
# Conversion backends
# ============================================================================

convert_with_pandoc() {
	local input="$1"
	local output="$2"
	local extra_args="${3:-}"

	log_info "Converting with pandoc: $(basename "$input") -> $(basename "$output")"

	local pandoc_cmd=(pandoc "$input" -o "$output" --wrap=none)

	# Add PDF engine if outputting PDF
	if [[ "${output}" == *.pdf ]]; then
		if has_cmd xelatex; then
			pandoc_cmd+=(--pdf-engine=xelatex)
		elif has_cmd pdflatex; then
			pandoc_cmd+=(--pdf-engine=pdflatex)
		elif has_cmd wkhtmltopdf; then
			pandoc_cmd+=(--pdf-engine=wkhtmltopdf)
		fi
	fi

	# Extract media for formats that support it
	local from_ext
	from_ext=$(get_ext "$input")
	if [[ "${from_ext}" =~ ^(docx|odt|epub|html)$ ]]; then
		local media_dir
		media_dir="$(dirname "$output")/media"
		pandoc_cmd+=(--extract-media="$media_dir")
	fi

	# shellcheck disable=SC2086
	"${pandoc_cmd[@]}" ${extra_args}

	if [[ -f "$output" ]]; then
		local size
		size=$(human_filesize "$output")
		_log_created "${output}" "${size}"
	else
		die "Conversion failed: output file not created"
	fi

	return 0
}

convert_with_libreoffice() {
	local input="$1"
	local to_ext="$2"
	local output_dir="$3"

	log_info "Converting with LibreOffice: $(basename "$input") -> ${to_ext}"

	local lo_cmd
	if has_cmd soffice; then
		lo_cmd="soffice"
	else
		lo_cmd="libreoffice"
	fi

	"${lo_cmd}" --headless --convert-to "${to_ext}" --outdir "${output_dir}" "$input" 2>&1

	local basename_noext
	basename_noext="$(basename "${input%.*}")"
	local output_file="${output_dir}/${basename_noext}.${to_ext}"

	if [[ -f "${output_file}" ]]; then
		local size
		size=$(human_filesize "${output_file}")
		_log_created "${output_file}" "${size}"
	else
		die "LibreOffice conversion failed"
	fi

	return 0
}

convert_with_reader_lm() {
	local input="$1"
	local output="$2"

	log_info "Converting with Reader-LM: $(basename "$input") -> markdown"

	if ! has_reader_lm; then
		die "Reader-LM not available. Run: ollama pull reader-lm"
	fi

	# Read HTML content
	local html_content
	html_content=$(cat "$input")

	# Use Ollama API to convert HTML to markdown
	local response
	response=$(curl -s http://localhost:11434/api/generate \
		-d "{\"model\":\"reader-lm\",\"prompt\":\"Convert this HTML to markdown, preserving tables and structure:\n\n${html_content}\",\"stream\":false}" 2>/dev/null)

	if [[ -z "$response" ]]; then
		die "Reader-LM conversion failed: no response from Ollama"
	fi

	# Extract markdown from response
	printf '%s' "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('response',''))" >"$output" 2>/dev/null

	if [[ -f "$output" ]] && [[ -s "$output" ]]; then
		local size
		size=$(human_filesize "$output")
		_log_created "${output}" "${size}"
	else
		die "Reader-LM conversion failed: output file empty or not created"
	fi

	return 0
}

convert_with_rolm_ocr() {
	local input="$1"
	local output="$2"

	log_info "Converting with RolmOCR: $(basename "$input") -> markdown"

	if ! has_rolm_ocr; then
		die "RolmOCR not available. Ensure vLLM server is running with RolmOCR model on port 8000"
	fi

	# Use workspace dir for temp files
	local tmp_dir="${HOME}/.aidevops/.agent-workspace/tmp/rolm-$$"
	mkdir -p "${tmp_dir}"
	local img_dir="${tmp_dir}/pages"
	mkdir -p "${img_dir}"

	# Extract page images from PDF
	log_info "Extracting page images from PDF..."
	pdfimages -png "$input" "${img_dir}/page" 2>/dev/null

	local img_count
	img_count=$(find "${img_dir}" -name "*.png" -type f 2>/dev/null | wc -l | tr -d ' ')

	if [[ "${img_count}" -eq 0 ]]; then
		die "No images extracted from PDF. File may be empty or text-based (use pdftotext instead)."
	fi

	log_info "Processing ${img_count} page images with RolmOCR..."

	# Process each image and combine
	: >"$output"
	local img_file
	for img_file in "${img_dir}"/page-*.png; do
		[[ -f "$img_file" ]] || continue
		log_info "  RolmOCR: $(basename "$img_file")"

		# Convert image to base64
		local b64
		b64=$(base64 <"$img_file")

		# Call vLLM API with RolmOCR model
		local response
		response=$(curl -s http://localhost:8000/v1/chat/completions \
			-H "Content-Type: application/json" \
			-d "{\"model\":\"rolm-ocr\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,${b64}\"}},{\"type\":\"text\",\"text\":\"Convert this page to markdown, preserving tables and structure.\"}]}]}" 2>/dev/null)

		if [[ -n "$response" ]]; then
			# Extract markdown from response
			local page_md
			page_md=$(printf '%s' "$response" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content',''))" 2>/dev/null)
			printf '%s\n\n' "$page_md" >>"$output"
		else
			log_warn "  RolmOCR failed for $(basename "$img_file"), skipping"
		fi
	done

	local text_len
	text_len=$(wc -c <"$output" | tr -d ' ')
	log_ok "RolmOCR complete: ${text_len} bytes extracted"

	# Clean up
	rm -rf "${tmp_dir}"

	if [[ -f "$output" ]] && [[ -s "$output" ]]; then
		local size
		size=$(human_filesize "$output")
		_log_created "${output}" "${size}"
	else
		die "RolmOCR conversion failed: output file empty or not created"
	fi

	return 0
}

convert_pdf_to_odt() {
	local input="$1"
	local output="$2"
	local _template="${3:-}" # reserved for future template-based conversion

	log_info "Converting PDF to ODT (programmatic pipeline)"

	if ! has_cmd pdftotext; then
		die "pdftotext required. Run: install --minimal"
	fi

	if ! activate_venv 2>/dev/null || ! has_python_pkg odf 2>/dev/null; then
		die "odfpy required. Run: install --standard"
	fi

	# Extract text
	local tmp_dir
	tmp_dir=$(mktemp -d)
	local text_file="${tmp_dir}/content.txt"
	local img_dir="${tmp_dir}/images"
	mkdir -p "${img_dir}"

	log_info "Extracting text..."
	pdftotext -layout "$input" "$text_file"

	log_info "Extracting images..."
	pdfimages -png "$input" "${img_dir}/img" 2>/dev/null || true

	# Get metadata
	local page_count="unknown"
	if has_cmd pdfinfo; then
		page_count=$(pdfinfo "$input" 2>/dev/null | grep "Pages:" | awk '{print $2}' || echo "unknown")
	fi

	local img_count
	img_count=$(find "${img_dir}" -name "*.png" -type f 2>/dev/null | wc -l | tr -d ' ')

	log_info "Extracted: ${page_count} pages, ${img_count} images"
	log_info "Text and images saved to: ${tmp_dir}"
	log_info "Building ODT requires AI agent assistance for layout reconstruction."
	log_info "Text file: ${text_file}"
	log_info "Images dir: ${img_dir}"

	# For now, create a basic ODT with the extracted text using pandoc as fallback
	# Full layout reconstruction requires the AI agent to analyse structure
	if has_cmd pandoc; then
		log_info "Creating basic ODT with pandoc (text only, no layout reconstruction)..."
		pandoc "$text_file" -o "$output" --wrap=none
		if [[ -f "$output" ]]; then
			local size
			size=$(human_filesize "$output")
			log_ok "Created basic ODT: ${output} (${size})"
			log_info "For full layout reconstruction with images, headers, and footers,"
			log_info "use the AI agent: 'convert this PDF to ODT with full layout'"
			log_info "Extracted assets available at: ${tmp_dir}"
		fi
	else
		log_info "Extracted assets ready for AI agent to build ODT."
		log_info "Text: ${text_file}"
		log_info "Images: ${img_dir}"
	fi

	return 0
}

convert_email() {
	local input="$1"
	local output="$2"
	local dedup_registry="${3:-}"

	log_info "Converting email with email-to-markdown.py: $(basename "$input") -> $(basename "$output")"

	# Determine attachments directory
	local attachments_dir
	attachments_dir="$(dirname "$output")/$(basename "${output%.md}")_attachments"

	# Check if Python script exists
	local script_path
	script_path="$(dirname "${BASH_SOURCE[0]}")/email-to-markdown.py"
	if [[ ! -f "${script_path}" ]]; then
		die "Email parser script not found: ${script_path}"
	fi

	# Activate venv and run the parser
	if ! activate_venv 2>/dev/null; then
		die "Python venv required. Run: install --standard"
	fi

	# Check for required Python packages
	if ! python3 -c "import html2text" 2>/dev/null; then
		log_info "Installing html2text..."
		pip install --quiet html2text
	fi

	# Check if input is .msg and install extract-msg if needed
	local ext
	ext=$(get_ext "$input")
	if [[ "${ext}" == "msg" ]]; then
		if ! python3 -c "import extract_msg" 2>/dev/null; then
			log_info "Installing extract-msg for .msg file support..."
			pip install --quiet extract-msg
		fi
	fi

	# Build parser command with optional dedup registry
	local parser_args=("$input" --output "$output" --attachments-dir "$attachments_dir")
	if [[ -n "${dedup_registry}" ]]; then
		parser_args+=(--dedup-registry "$dedup_registry")
	fi

	# Run the parser
	python3 "${script_path}" "${parser_args[@]}"

	if [[ -f "$output" ]]; then
		local size
		size=$(human_filesize "$output")
		_log_created "${output}" "${size}"
		if [[ -d "$attachments_dir" ]]; then
			local att_count
			att_count=$(find "$attachments_dir" -type f -o -type l 2>/dev/null | wc -l | tr -d ' ')
			if [[ "${att_count}" -gt 0 ]]; then
				log_ok "Extracted ${att_count} attachment(s) to: ${attachments_dir}"
			fi
		fi
	else
		die "Email conversion failed: output file not created"
	fi

	return 0
}
