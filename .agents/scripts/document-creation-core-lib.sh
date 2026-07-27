#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Document Creation Core Library -- Utilities, environment, OCR, status, install
# =============================================================================
# Shared utility functions, dependency detection, OCR providers, tool status
# reporting, installation helpers, and format information for the document
# creation subsystem.
#
# Usage: source "${SCRIPT_DIR}/document-creation-core-lib.sh"
#
# Dependencies:
#   - SCRIPT_NAME, VENV_DIR, TEMPLATE_DIR, LOG_DIR (set by orchestrator)
#   - Colour variables (RED, GREEN, YELLOW, BLUE, BOLD, NC) (set by orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_DOCUMENT_CREATION_CORE_LIB_LOADED:-}" ]] && return 0
_DOCUMENT_CREATION_CORE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ============================================================================
# Utility functions
# ============================================================================

log_info() {
	local msg="$1"
	printf "${BLUE}[info]${NC} %s\n" "$msg"
}

log_ok() {
	local msg="$1"
	printf "${GREEN}[ok]${NC} %s\n" "$msg"
}

log_warn() {
	local msg="$1"
	printf "${YELLOW}[warn]${NC} %s\n" "$msg" >&2
}

log_error() {
	local msg="$1"
	printf "${RED}[error]${NC} %s\n" "$msg" >&2
}

die() {
	local msg="$1"
	log_error "$msg"
	return 1
}

# Check if a command exists
has_cmd() {
	local bin_name="$1"
	command -v "$bin_name" &>/dev/null
}

replace_file_atomically() {
	local source="$1"
	local destination="$2"

	if ! has_cmd python3 || [[ ! -f "$source" ]] || [[ -d "$destination" ]]; then
		return 1
	fi
	if python3 -c '
import os
import sys

source, destination = sys.argv[1:3]
if not os.path.isfile(source) or os.path.isdir(destination):
    raise SystemExit(1)
os.replace(source, destination)
if not os.path.isfile(destination):
    raise SystemExit(1)
' "$source" "$destination"; then
		return 0
	fi
	return 1
}

# Get human-readable file size without using ls (SC2012)
human_filesize() {
	local file="$1"
	local bytes
	bytes=$(_file_size_bytes "$file")
	if [[ "$bytes" -ge 1073741824 ]]; then
		printf '%s.%sG' "$((bytes / 1073741824))" "$(((bytes % 1073741824) * 10 / 1073741824))"
	elif [[ "$bytes" -ge 1048576 ]]; then
		printf '%s.%sM' "$((bytes / 1048576))" "$(((bytes % 1048576) * 10 / 1048576))"
	elif [[ "$bytes" -ge 1024 ]]; then
		printf '%s.%sK' "$((bytes / 1024))" "$(((bytes % 1024) * 10 / 1024))"
	else
		printf '%sB' "$bytes"
	fi
	return 0
}

# Get file extension (lowercase)
get_ext() {
	local file="$1"
	local ext="${file##*.}"
	printf '%s' "$ext" | tr '[:upper:]' '[:lower:]'
}

# Activate Python venv if it exists
activate_venv() {
	if [[ -f "${VENV_DIR}/bin/activate" ]]; then
		source "${VENV_DIR}/bin/activate"
		return 0
	fi
	return 1
}

# Check if a Python package is available in the venv
has_python_pkg() {
	local pkg="$1"
	if activate_venv 2>/dev/null; then
		python3 -c "import ${pkg}" 2>/dev/null
		return $?
	fi
	return 1
}

# ============================================================================
# Advanced conversion provider detection
# ============================================================================

# Check if Reader-LM is available via Ollama
has_reader_lm() {
	if has_cmd ollama; then
		ollama list 2>/dev/null | grep -q "reader-lm"
		return $?
	fi
	return 1
}

# Check if RolmOCR is available via vLLM
has_rolm_ocr() {
	# Check if vLLM server is running with RolmOCR model
	# vLLM typically runs on port 8000 by default
	if command -v curl &>/dev/null; then
		local response
		response=$(curl -s http://localhost:8000/v1/models 2>/dev/null || echo "")
		if [[ -n "$response" ]] && echo "$response" | grep -q "rolm"; then
			return 0
		fi
	fi
	return 1
}

# ============================================================================
# OCR functions
# ============================================================================

# Detect if a PDF is scanned (image-only, no selectable text)
is_scanned_pdf() {
	local file="$1"

	if [[ "$(get_ext "$file")" != "pdf" ]]; then
		return 1
	fi

	# Check if pdftotext produces meaningful output
	if has_cmd pdftotext; then
		local text_len
		text_len=$(pdftotext "$file" - 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')
		if [[ "${text_len}" -lt 50 ]]; then
			return 0 # Likely scanned
		fi
	fi

	# Check if any fonts are embedded
	if has_cmd pdffonts; then
		local font_count
		font_count=$(pdffonts "$file" 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
		if [[ "${font_count}" -eq 0 ]]; then
			return 0 # No fonts = image-only
		fi
	fi

	return 1 # Has text content
}

# Return the number of pages in a PDF.
pdf_page_count() {
	local file="$1"
	local count=""

	if ! has_cmd pdfinfo; then
		return 1
	fi
	count=$(pdfinfo "$file" 2>/dev/null | awk '$1 == "Pages:" { value = $2 } END { print value }')
	if [[ ! "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]]; then
		return 1
	fi
	printf '%s' "$count"
	return 0
}

# Return one PDF page's width and height in points as WIDTHxHEIGHT.
pdf_page_dimensions() {
	local file="$1"
	local page="$2"
	local dimensions=""

	if ! has_cmd pdfinfo; then
		return 1
	fi
	dimensions=$(pdfinfo -f "$page" -l "$page" "$file" 2>/dev/null | awk -v expected="$page" '
		BEGIN { one = 1; two = 2; three = 3; four = 4; five = 5; six = 6 }
		$one == "Page" && $two == expected && $three == "size:" { print $four "x" $six; exit }
		$one == "Page" && $two == "size:" { print $three "x" $five; exit }
	')
	if [[ ! "$dimensions" =~ ^[0-9]+([.][0-9]+)?x[0-9]+([.][0-9]+)?$ ]]; then
		return 1
	fi
	printf '%s' "$dimensions"
	return 0
}

# Extract one PDF page's text layer to a file.
extract_pdf_page_text() {
	local file="$1"
	local page="$2"
	local output="$3"

	if ! has_cmd pdftotext; then
		return 1
	fi
	if pdftotext -f "$page" -l "$page" "$file" "$output" 2>/dev/null; then
		return 0
	fi
	return 1
}

# Render one complete PDF page rather than extracting its component images.
render_pdf_page() {
	local file="$1"
	local page="$2"
	local output_prefix="$3"
	local dpi="${4:-300}"

	if ! has_cmd pdftoppm; then
		return 1
	fi
	if pdftoppm -f "$page" -l "$page" -singlefile -r "$dpi" -png \
		"$file" "$output_prefix" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Report the local OCR backend version for provenance manifests.
ocr_provider_version() {
	local provider="$1"
	local version="unknown"

	case "$provider" in
	tesseract)
		if has_cmd tesseract; then
			version=$(tesseract --version 2>&1 | awk 'NR == 1 { value = $0 } END { print value }')
		fi
		;;
	easyocr)
		if has_cmd python3; then
			version=$(python3 -c 'import importlib.metadata; print(importlib.metadata.version("easyocr"))' 2>/dev/null || printf 'unknown')
		fi
		;;
	glm-ocr)
		if has_cmd ollama; then
			version=$(ollama --version 2>/dev/null || printf 'unknown')
		fi
		;;
	esac

	printf '%s' "$version"
	return 0
}

# Select the best available OCR provider
select_ocr_provider() {
	local preferred="${1:-auto}"

	if [[ "${preferred}" != "auto" ]]; then
		case "${preferred}" in
		tesseract)
			if has_cmd tesseract; then
				printf 'tesseract'
				return 0
			fi
			die "Tesseract not installed. Run: install --tool tesseract"
			;;
		easyocr)
			if has_python_pkg easyocr 2>/dev/null; then
				printf 'easyocr'
				return 0
			fi
			die "EasyOCR not installed. Run: install --tool easyocr"
			;;
		glm-ocr)
			if has_cmd ollama; then
				printf 'glm-ocr'
				return 0
			fi
			die "Ollama not installed. Run: brew install ollama && ollama pull glm-ocr"
			;;
		*)
			die "Unknown OCR provider: ${preferred}. Use: tesseract, easyocr, glm-ocr, or auto"
			;;
		esac
	fi

	# Auto-select: fastest available first
	if has_cmd tesseract; then
		printf 'tesseract'
	elif has_python_pkg easyocr 2>/dev/null; then
		printf 'easyocr'
	elif has_cmd ollama && ollama list 2>/dev/null | grep -q "glm-ocr"; then
		printf 'glm-ocr'
	else
		die "No OCR tool available. Run: install --ocr"
	fi

	return 0
}

# Run OCR on an image file, output text to stdout
run_ocr() {
	local image_file="$1"
	local provider="$2"
	local ocr_rc=0

	case "${provider}" in
	tesseract)
		# Tesseract's Leptonica has issues reading from /tmp on macOS.
		# Work around by copying to a non-tmp location if needed.
		local tess_input="$image_file"
		if [[ "$image_file" == /tmp/* || "$image_file" == /private/tmp/* || "$image_file" == /var/folders/* ]]; then
			local work_dir="${HOME}/.aidevops/.agent-workspace/tmp"
			mkdir -p "$work_dir"
			tess_input="${work_dir}/ocr-input-$$.$(get_ext "$image_file")"
			cp "$image_file" "$tess_input"
		fi
		if ! tesseract "$tess_input" stdout 2>/dev/null; then
			ocr_rc=1
		fi
		# Clean up temp copy
		if [[ "$tess_input" != "$image_file" ]]; then
			rm -f "$tess_input"
		fi
		;;
	easyocr)
		if ! activate_venv 2>/dev/null; then
			return 1
		fi
		if ! python3 -c "
import easyocr, sys
reader = easyocr.Reader(['en'], verbose=False)
results = reader.readtext(sys.argv[1], detail=0)
print('\n'.join(results))
" "$image_file" 2>/dev/null; then
			ocr_rc=1
		fi
		;;
	glm-ocr)
		# GLM-OCR via Ollama API
		local b64
		if ! b64=$(base64 <"$image_file"); then
			return 1
		fi
		local response
		if ! response=$(curl -s http://localhost:11434/api/generate \
			-d "{\"model\":\"glm-ocr\",\"prompt\":\"Extract all text from this image.\",\"images\":[\"${b64}\"],\"stream\":false}" 2>/dev/null); then
			return 1
		fi
		if ! printf '%s' "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('response',''))" 2>/dev/null; then
			ocr_rc=1
		fi
		;;
	*)
		die "Unknown OCR provider: ${provider}"
		return 1
		;;
	esac

	if [[ "$ocr_rc" -ne 0 ]]; then
		return 1
	fi
	return 0
}

# OCR a scanned PDF: extract page images, OCR each, combine text
ocr_scanned_pdf() {
	local input="$1"
	local provider="$2"
	local output_text="$3"
	if [[ -d "$output_text" ]]; then
		die "OCR text output path is a directory."
		return 1
	fi

	# Use workspace dir instead of /tmp to avoid macOS Leptonica sandbox issues
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local tmp_dir=""
	mkdir -p "$temp_root"
	tmp_dir=$(mktemp -d "${temp_root%/}/ocr.XXXXXX") || return 1
	local img_dir="${tmp_dir}/pages"
	mkdir -p "${img_dir}"
	local staged_output="${tmp_dir}/ocr-output.txt"
	local publish_tmp=""

	local page_count=""
	if ! page_count=$(pdf_page_count "$input"); then
		rm -rf "${tmp_dir}"
		die "Unable to determine PDF page count."
		return 1
	fi

	log_info "OCR processing ${page_count} rendered PDF pages with ${provider}..."

	# Process complete rendered pages so page boundaries and citations survive.
	: >"$staged_output"
	local page=1
	while [[ "$page" -le "$page_count" ]]; do
		local page_id=""
		printf -v page_id '%04d' "$page"
		local page_prefix="${img_dir}/page-${page_id}"
		local img_file="${page_prefix}.png"
		if ! render_pdf_page "$input" "$page" "$page_prefix" 300; then
			rm -rf "${tmp_dir}"
			die "Unable to render PDF page ${page}."
			return 1
		fi
		log_info "  OCR: page ${page}"
		printf '===== Page %s =====\n' "$page" >>"$staged_output"
		if ! run_ocr "$img_file" "$provider" >>"$staged_output"; then
			rm -rf "${tmp_dir}"
			die "OCR failed on PDF page ${page}."
			return 1
		fi
		printf '\n\n' >>"$staged_output"
		page=$((page + 1))
	done

	local text_len
	text_len=$(wc -c <"$staged_output" | tr -d ' ')
	publish_tmp=$(mktemp "${output_text}.tmp.XXXXXX") || {
		rm -rf "${tmp_dir}"
		die "Unable to stage OCR text output beside its destination."
		return 1
	}
	if ! cp "$staged_output" "$publish_tmp" || \
		! replace_file_atomically "$publish_tmp" "$output_text"; then
		rm -f "$publish_tmp"
		rm -rf "${tmp_dir}"
		die "Unable to publish OCR text output."
		return 1
	fi
	log_ok "OCR complete: ${text_len} bytes extracted"

	# Clean up
	rm -rf "${tmp_dir}"

	return 0
}

# ============================================================================
# Status command
# ============================================================================

cmd_status() {
	printf '%b\n\n' "${BOLD}Document Conversion Tools Status${NC}"

	printf '%b\n' "${BOLD}Tier 1 - Minimal (text conversions):${NC}"
	if has_cmd pandoc; then
		log_ok "pandoc $(pandoc --version | head -1 | awk '{print $2}')"
	else
		log_warn "pandoc - NOT INSTALLED (brew install pandoc)"
	fi
	if has_cmd pdftotext; then
		log_ok "poppler (pdftotext, pdfimages, pdfinfo)"
	else
		log_warn "poppler - NOT INSTALLED (brew install poppler)"
	fi

	printf '\n%b\n' "${BOLD}Tier 2 - Standard (programmatic creation):${NC}"
	if [[ -d "${VENV_DIR}" ]]; then
		log_ok "Python venv: ${VENV_DIR}"
	else
		log_warn "Python venv not created (run: install --standard)"
	fi
	if has_python_pkg odf 2>/dev/null; then
		log_ok "odfpy (ODT/ODS creation)"
	else
		log_warn "odfpy - NOT INSTALLED"
	fi
	if has_python_pkg docx 2>/dev/null; then
		log_ok "python-docx (DOCX creation)"
	else
		log_warn "python-docx - NOT INSTALLED"
	fi
	if has_python_pkg openpyxl 2>/dev/null; then
		log_ok "openpyxl (XLSX creation)"
	else
		log_warn "openpyxl - NOT INSTALLED"
	fi

	printf '\n%b\n' "${BOLD}Tier 3 - Full (highest fidelity):${NC}"
	if has_cmd soffice || has_cmd libreoffice; then
		local lo_version
		lo_version=$(soffice --version 2>/dev/null || libreoffice --version 2>/dev/null || echo "unknown")
		log_ok "LibreOffice headless (${lo_version})"
	else
		log_warn "LibreOffice - NOT INSTALLED (brew install --cask libreoffice)"
	fi

	printf '\n%b\n' "${BOLD}OCR tools:${NC}"
	if has_cmd tesseract; then
		local tess_version
		tess_version=$(tesseract --version 2>&1 | head -1)
		log_ok "Tesseract (${tess_version})"
	else
		log_info "Tesseract - not installed (brew install tesseract)"
	fi
	if has_python_pkg easyocr 2>/dev/null; then
		log_ok "EasyOCR (Python, 80+ languages)"
	else
		log_info "EasyOCR - not installed (pip install easyocr)"
	fi
	if has_cmd ollama && ollama list 2>/dev/null | grep -q "glm-ocr"; then
		log_ok "GLM-OCR (local AI via Ollama)"
	else
		log_info "GLM-OCR - not installed (ollama pull glm-ocr)"
	fi

	printf '\n%b\n' "${BOLD}Specialist tools:${NC}"
	if has_cmd mineru; then
		log_ok "MinerU (layout-aware PDF to markdown)"
	else
		log_info "MinerU - not installed (optional: pip install 'mineru[all]')"
	fi

	printf '\n%b\n' "${BOLD}Advanced conversion providers:${NC}"
	if has_reader_lm; then
		log_ok "Reader-LM (Jina, 1.5B via Ollama - HTML to markdown with table preservation)"
	else
		log_info "Reader-LM - not installed (ollama pull reader-lm)"
	fi
	if has_rolm_ocr; then
		log_ok "RolmOCR (Reducto, 7B via vLLM - PDF page images to markdown with table preservation)"
	else
		log_info "RolmOCR - not available (requires vLLM server with RolmOCR model)"
	fi

	printf "\n${BOLD}Template directory:${NC} %s\n" "${TEMPLATE_DIR}"
	if [[ -d "${TEMPLATE_DIR}" ]]; then
		local count
		count=$(find "${TEMPLATE_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')
		log_ok "${count} template(s) stored"
	else
		log_info "Not created yet (created on first use)"
	fi

	return 0
}

# ============================================================================
# Helper functions for cmd_install (extracted for complexity reduction)
# ============================================================================

_install_tier_minimal() {
	log_info "Installing Tier 1: pandoc + poppler"
	if [[ "$(uname)" == "Darwin" ]]; then
		brew install pandoc poppler 2>&1 || true
	elif has_cmd apt-get; then
		sudo apt-get update && sudo apt-get install -y pandoc poppler-utils
	else
		die "Unsupported platform. Install pandoc and poppler manually."
	fi
	log_ok "Tier 1 installed"
	return 0
}

_install_tier_standard() {
	log_info "Installing Tier 2: Python libraries"
	if ! has_cmd pandoc; then
		log_info "Installing Tier 1 first..."
		_install_tier_minimal
	fi
	if [[ ! -d "${VENV_DIR}" ]]; then
		log_info "Creating Python venv at ${VENV_DIR}"
		mkdir -p "$(dirname "${VENV_DIR}")"
		python3 -m venv "${VENV_DIR}"
	fi
	activate_venv
	pip install --quiet odfpy python-docx openpyxl
	log_ok "Tier 2 installed (odfpy, python-docx, openpyxl)"
	return 0
}

_install_tier_full() {
	log_info "Installing Tier 3: LibreOffice headless"
	if ! has_python_pkg odf 2>/dev/null; then
		_install_tier_standard
	fi
	if [[ "$(uname)" == "Darwin" ]]; then
		brew install --cask libreoffice 2>&1 || true
	elif has_cmd apt-get; then
		sudo apt-get update && sudo apt-get install -y libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress
	else
		die "Unsupported platform. Install LibreOffice manually."
	fi
	log_ok "Tier 3 installed"
	return 0
}

_install_tier_ocr() {
	log_info "Installing OCR tools"
	if [[ "$(uname)" == "Darwin" ]]; then
		brew install tesseract 2>&1 || true
	elif has_cmd apt-get; then
		sudo apt-get update && sudo apt-get install -y tesseract-ocr
	fi
	if [[ ! -d "${VENV_DIR}" ]]; then
		mkdir -p "$(dirname "${VENV_DIR}")"
		python3 -m venv "${VENV_DIR}"
	fi
	activate_venv
	pip install --quiet easyocr
	if has_cmd ollama; then
		log_info "Pulling GLM-OCR model via Ollama..."
		ollama pull glm-ocr 2>&1 || true
	else
		log_info "Ollama not installed -- skipping GLM-OCR (brew install ollama)"
	fi
	log_ok "OCR tools installed"
	return 0
}

_install_specific_tool() {
	local tool="$1"
	case "${tool}" in
	pandoc)
		if [[ "$(uname)" == "Darwin" ]]; then brew install pandoc; else sudo apt-get install -y pandoc; fi
		;;
	poppler)
		if [[ "$(uname)" == "Darwin" ]]; then brew install poppler; else sudo apt-get install -y poppler-utils; fi
		;;
	odfpy | python-docx | openpyxl)
		if [[ ! -d "${VENV_DIR}" ]]; then
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install --quiet "${tool}"
		;;
	libreoffice)
		if [[ "$(uname)" == "Darwin" ]]; then
			brew install --cask libreoffice
		else
			sudo apt-get install -y libreoffice-core
		fi
		;;
	mineru)
		if [[ ! -d "${VENV_DIR}" ]]; then
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install "mineru[all]"
		;;
	tesseract)
		if [[ "$(uname)" == "Darwin" ]]; then brew install tesseract; else sudo apt-get install -y tesseract-ocr; fi
		;;
	easyocr)
		if [[ ! -d "${VENV_DIR}" ]]; then
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install --quiet easyocr
		;;
	glm-ocr)
		if has_cmd ollama; then
			ollama pull glm-ocr
		else
			die "Ollama required for GLM-OCR. Install: brew install ollama"
		fi
		;;
	*)
		die "Unknown tool: ${tool}"
		;;
	esac
	log_ok "${tool} installed"
	return 0
}

# ============================================================================
# Install command
# ============================================================================

cmd_install() {
	local tier="${1:-}"
	local tool="${2:-}"

	case "${tier}" in
	--minimal)
		_install_tier_minimal
		;;
	--standard)
		_install_tier_standard
		;;
	--full)
		_install_tier_full
		;;
	--ocr)
		_install_tier_ocr
		;;
	--tool)
		if [[ -z "${tool}" ]]; then
			die "Usage: install --tool <name> (pandoc|poppler|odfpy|python-docx|openpyxl|libreoffice|mineru|tesseract|easyocr|glm-ocr)"
		fi
		_install_specific_tool "${tool}"
		;;
	*)
		printf "Usage: %s install <tier>\n\n" "${SCRIPT_NAME}"
		printf "Tiers:\n"
		printf "  --minimal    pandoc + poppler (text conversions)\n"
		printf "  --standard   + odfpy, python-docx, openpyxl (programmatic creation)\n"
		printf "  --full       + LibreOffice headless (highest fidelity)\n"
		printf "  --ocr        tesseract + easyocr + glm-ocr (scanned document support)\n"
		printf "  --tool NAME  Install a specific tool\n"
		return 1
		;;
	esac

	return 0
}

# ============================================================================
# Formats command
# ============================================================================

cmd_formats() {
	printf '%b\n\n' "${BOLD}Supported Format Conversions${NC}"

	printf '%b\n' "${BOLD}Input formats:${NC}"
	printf "  Documents:      md, odt, docx, rtf, html, epub, latex/tex\n"
	printf "  Email:          eml, msg (MIME parsing with attachments)\n"
	printf "  PDF:            pdf (text extraction + image extraction)\n"
	printf "  Spreadsheets:   xlsx, ods, csv, tsv\n"
	printf "  Presentations:  pptx, odp\n"
	printf "  Data:           json, xml, rst, org\n"

	printf '\n%b\n' "${BOLD}Output formats:${NC}"
	printf "  Documents:      md, odt, docx, rtf, html, epub, latex/tex\n"
	printf "  PDF:            pdf (via pandoc+engine or LibreOffice)\n"
	printf "  Spreadsheets:   xlsx, ods, csv, tsv\n"
	printf "  Presentations:  pptx, odp\n"

	printf '\n%b\n' "${BOLD}Best quality paths:${NC}"
	printf "  eml/msg -> md:    email-to-markdown.py (extracts attachments)\n"
	printf "  odt/docx -> pdf:  LibreOffice headless (preserves layout)\n"
	printf "  md -> docx/odt:   pandoc (excellent)\n"
	printf "  pdf -> md:        MinerU (complex) or pandoc (simple)\n"
	printf "  pdf -> odt:       odfpy + poppler (programmatic rebuild)\n"
	printf "  xlsx <-> ods:     LibreOffice headless\n"

	return 0
}
