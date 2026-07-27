#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# document-creation-helper.sh - Unified document format conversion and creation
# Part of aidevops framework: https://aidevops.sh
#
# Usage: document-creation-helper.sh <command> [options]
# Commands: convert, forensics, create, template, normalise, pageindex, install, formats, status, help

set -euo pipefail

# Source shared-constants.sh for portable stat functions
_dch_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=shared-constants.sh
[[ -f "${_dch_dir}/shared-constants.sh" ]] && source "${_dch_dir}/shared-constants.sh"

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_NAME="document-creation-helper"
VENV_DIR="${HOME}/.aidevops/.agent-workspace/python-env/document-creation"
TEMPLATE_DIR="${HOME}/.aidevops/.agent-workspace/templates"
# LOG_DIR used by future logging features
LOG_DIR="${HOME}/.aidevops/logs"
export LOG_DIR

# Colour output fallback when shared-constants.sh is unavailable.
if [[ -z "${RED+x}" ]]; then
	if [[ -t 1 ]]; then
		RED='\033[0;31m'
		GREEN='\033[0;32m'
		YELLOW='\033[1;33m'
		BLUE='\033[0;34m'
		BOLD='\033[1m'
		NC='\033[0m'
	else
		RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
	fi
fi
if [[ -z "${BOLD+x}" ]]; then
	[[ -t 1 ]] && BOLD='\033[1m' || BOLD=''
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
# Tool detection
# ============================================================================

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

# ============================================================================
# Sub-library sourcing
# ============================================================================

# Defensive SCRIPT_DIR fallback for sub-library resolution
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# shellcheck source=./document-creation-convert-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/document-creation-convert-lib.sh"

# shellcheck source=./document-creation-email-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/document-creation-email-lib.sh"

# shellcheck source=./document-forensics-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/document-forensics-lib.sh"

# NOTE: The conversion engine (EML/MIME helpers, tool selection, conversion
# backends) and the email import pipeline (mbox splitting, contact extraction,
# batch import) now live in the two sub-libraries sourced above. The remaining
# functions below are argument parsing, command implementations, and main dispatch.
# ============================================================================
# Extracted helpers for complexity reduction (t1044.12)
# ============================================================================

# Helpers for cmd_convert - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_convert_parse_args() {
	local _input_var="$1" _to_ext_var="$2" _output_var="$3" _force_tool_var="$4"
	local _template_var="$5" _extra_args_var="$6" _ocr_provider_var="$7"
	local _run_normalise_var="$8" _dedup_registry_var="$9"
	shift 9

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			local _to_ext_val
			_to_ext_val="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
			printf -v "$_to_ext_var" '%s' "$_to_ext_val"
			shift 2
			;;
		--output | -o)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		--tool)
			printf -v "$_force_tool_var" '%s' "$2"
			shift 2
			;;
		--template)
			printf -v "$_template_var" '%s' "$2"
			shift 2
			;;
		--engine)
			printf -v "$_extra_args_var" '%s' "--pdf-engine=$2"
			shift 2
			;;
		--dedup-registry)
			printf -v "$_dedup_registry_var" '%s' "$2"
			shift 2
			;;
		--ocr)
			printf -v "$_ocr_provider_var" '%s' "${2:-auto}"
			shift
			[[ $# -gt 0 && "$1" != --* ]] && {
				printf -v "$_ocr_provider_var" '%s' "$1"
				shift
			}
			;;
		--no-normalise | --no-normalize)
			eval "${_run_normalise_var}=false"
			shift
			;;
		--*)
			local _cur_extra="${!_extra_args_var}"
			printf -v "$_extra_args_var" '%s' "${_cur_extra} $1"
			shift
			;;
		*)
			[[ -z "${!_input_var}" ]] && printf -v "$_input_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_create - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_create_parse_args() {
	local _template_var="$1" _data_var="$2" _output_var="$3" _script_var="$4"
	shift 4

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--data)
			printf -v "$_data_var" '%s' "$2"
			shift 2
			;;
		--output | -o)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		--script)
			printf -v "$_script_var" '%s' "$2"
			shift 2
			;;
		--*) shift ;;
		*)
			[[ -z "${!_template_var}" ]] && printf -v "$_template_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_import_emails - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_import_parse_args() {
	local _input_path_var="$1" _output_dir_var="$2" _skip_contacts_var="$3"
	shift 3

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			printf -v "$_output_dir_var" '%s' "$2"
			shift 2
			;;
		--skip-contacts)
			eval "${_skip_contacts_var}=true"
			shift
			;;
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			[[ -z "${!_input_path_var}" ]] && printf -v "$_input_path_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_template - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes (no local -n).
_template_parse_args() {
	local _doc_type_var="$1" _format_var="$2" _fields_var="$3"
	local _header_logo_var="$4" _footer_text_var="$5" _output_var="$6"
	shift 6

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			printf -v "$_doc_type_var" '%s' "$2"
			shift 2
			;;
		--format)
			printf -v "$_format_var" '%s' "$2"
			shift 2
			;;
		--fields)
			printf -v "$_fields_var" '%s' "$2"
			shift 2
			;;
		--header-logo)
			printf -v "$_header_logo_var" '%s' "$2"
			shift 2
			;;
		--footer-text)
			printf -v "$_footer_text_var" '%s' "$2"
			shift 2
			;;
		--output)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		*) shift ;;
		esac
	done
	return 0
}

# Helpers for cmd_normalise - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_normalise_parse_args() {
	local _input_var="$1" _output_var="$2" _inplace_var="$3"
	local _generate_pageindex_var="$4" _email_mode_var="$5"
	shift 5

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		--inplace | -i)
			eval "${_inplace_var}=true"
			shift
			;;
		--pageindex)
			eval "${_generate_pageindex_var}=true"
			shift
			;;
		--email | -e)
			eval "${_email_mode_var}=true"
			shift
			;;
		--*) shift ;;
		*)
			[[ -z "${!_input_var}" ]] && printf -v "$_input_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_pageindex - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_pageindex_parse_args() {
	local _input_var="$1" _output_var="$2" _source_pdf_var="$3" _ollama_model_var="$4"
	shift 4

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			printf -v "$_output_var" '%s' "$2"
			shift 2
			;;
		--source-pdf)
			printf -v "$_source_pdf_var" '%s' "$2"
			shift 2
			;;
		--ollama-model)
			printf -v "$_ollama_model_var" '%s' "$2"
			shift 2
			;;
		--*) shift ;;
		*)
			[[ -z "${!_input_var}" ]] && printf -v "$_input_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Helpers for cmd_generate_manifest - extract argument parsing
# Bash 3.2 compatible: uses printf -v for scalar writes, ${!var} for reads (no local -n).
_manifest_parse_args() {
	local _output_dir_var="$1"
	shift

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			[[ -z "${!_output_dir_var}" ]] && printf -v "$_output_dir_var" '%s' "$1"
			shift
			;;
		esac
	done
	return 0
}

# Validate and resolve paths for cmd_convert.
# Sets output and from_ext; validates input/to_ext.
# Args: input to_ext output_ref from_ext_ref
_convert_validate_paths() {
	local input="$1"
	local to_ext="$2"
	local output_ref="$3"
	local from_ext_ref="$4"

	if [[ -z "${input}" ]]; then
		die "Usage: convert <input-file> --to <format> [--output <file>] [--tool <name>]"
	fi
	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi
	if [[ -z "${to_ext}" ]]; then
		die "Target format required. Use --to <format> (e.g., --to pdf, --to odt)"
	fi

	local _output="${!output_ref}"
	if [[ -z "${_output}" ]]; then
		_output="${input%.*}.${to_ext}"
		printf -v "${output_ref}" '%s' "${_output}"
	fi

	local _from_ext
	_from_ext=$(get_ext "$input")
	printf -v "${from_ext_ref}" '%s' "${_from_ext}"

	if [[ "${_from_ext}" == "${to_ext}" ]]; then
		die "Input and output formats are the same: ${_from_ext}"
	fi

	return 0
}

cmd_convert() {
	local input=""
	local to_ext=""
	local output=""
	local force_tool=""
	local template=""
	local extra_args=""
	local ocr_provider=""
	local run_normalise=true
	local dedup_registry=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			to_ext="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
			shift 2
			;;
		--output | -o)
			output="$2"
			shift 2
			;;
		--tool)
			force_tool="$2"
			shift 2
			;;
		--template)
			template="$2"
			shift 2
			;;
		--engine)
			extra_args="--pdf-engine=$2"
			shift 2
			;;
		--dedup-registry)
			dedup_registry="$2"
			shift 2
			;;
		--ocr)
			ocr_provider="${2:-auto}"
			shift
			if [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; then
				ocr_provider="$1"
				shift
			fi
			;;
		--no-normalise | --no-normalize)
			run_normalise=false
			shift
			;;
		--*)
			extra_args="${extra_args} $1"
			shift
			;;
		*)
			[[ -z "${input}" ]] && input="$1"
			shift
			;;
		esac
	done

	# Normalise format aliases
	case "${to_ext}" in
	markdown) to_ext="md" ;;
	text) to_ext="txt" ;;
	esac

	# Validate inputs and resolve output/from_ext
	local from_ext=""
	_convert_validate_paths "${input}" "${to_ext}" output from_ext

	# OCR pre-processing: handle scanned PDFs and images (modifies input/from_ext)
	_convert_ocr_preprocess input from_ext ocr_provider

	# Select tool and execute conversion
	local tool
	tool=$(select_tool "${from_ext}" "${to_ext}" "${force_tool}")
	_convert_execute_tool "${tool}" "$input" "$output" "${to_ext}" \
		"${template}" "${extra_args}" "${dedup_registry}"

	# Auto-run normalise after *→md conversions (unless --no-normalise flag is set)
	if [[ "${run_normalise}" == "true" ]] && [[ "${to_ext}" =~ ^(md|markdown)$ ]] && [[ -f "$output" ]]; then
		log_info "Running normalisation on converted markdown..."
		if "${BASH_SOURCE[0]}" normalise "$output"; then
			log_ok "Normalisation complete"
		else
			log_warn "Normalisation failed (non-fatal)"
		fi
	fi

	return 0
}

# ============================================================================
# Template command
# ============================================================================

# Helper: handle 'template draft' subcommand logic
_template_draft_subcommand() {
	local doc_type=""
	local format="odt"
	local fields=""
	local header_logo=""
	local footer_text=""
	local output=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			doc_type="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--fields)
			fields="$2"
			shift 2
			;;
		--header-logo)
			header_logo="$2"
			shift 2
			;;
		--footer-text)
			footer_text="$2"
			shift 2
			;;
		--output)
			output="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "${doc_type}" ]]; then
		die "Usage: template draft --type <name> [--format odt|docx] [--fields f1,f2,f3]"
	fi

	if [[ -z "${output}" ]]; then
		mkdir -p "${TEMPLATE_DIR}/documents"
		output="${TEMPLATE_DIR}/documents/${doc_type}-template.${format}"
	fi

	log_info "Generating draft template: ${doc_type} (${format})"
	log_info "Fields: ${fields:-auto}"
	log_info "Output: ${output}"

	if [[ "${format}" == "odt" ]]; then
		if ! activate_venv 2>/dev/null || ! has_python_pkg odf 2>/dev/null; then
			die "odfpy required for ODT template generation. Run: install --standard"
		fi
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		python3 "${script_dir}/template-draft.py" \
			"$output" "$doc_type" "$fields" "$header_logo" "$footer_text"
		log_ok "Draft template created: ${output}"
		log_info "Edit in LibreOffice or your preferred editor to refine layout."
		log_info "Replace {{placeholders}} markers with your design, keeping the field names."
	elif [[ "${format}" == "docx" ]]; then
		if ! activate_venv 2>/dev/null || ! has_python_pkg docx 2>/dev/null; then
			die "python-docx required for DOCX template generation. Run: install --standard"
		fi
		log_warn "DOCX template generation not yet implemented. Use ODT format."
	else
		die "Unsupported template format: ${format}. Use odt or docx."
	fi

	return 0
}

cmd_template() {
	local subcmd="${1:-}"
	shift || true

	case "${subcmd}" in
	list)
		printf '%b\n\n' "${BOLD}Stored Templates${NC}"
		if [[ -d "${TEMPLATE_DIR}" ]]; then
			find "${TEMPLATE_DIR}" -type f | while read -r f; do
				local rel="${f#"${TEMPLATE_DIR}/"}"
				local size
				size=$(human_filesize "$f")
				printf "  %s (%s)\n" "$rel" "$size"
			done
		else
			log_info "No templates stored yet."
			log_info "Directory: ${TEMPLATE_DIR}"
		fi
		;;
	draft)
		_template_draft_subcommand "$@"
		;;
	*)
		printf "Usage: %s template <subcommand>\n\n" "${SCRIPT_NAME}"
		printf "Subcommands:\n"
		printf "  list                          List stored templates\n"
		printf "  draft --type <name> [opts]     Generate a draft template\n"
		printf "\nDraft options:\n"
		printf "  --type <name>         Document type (letter, report, invoice, statement)\n"
		printf "  --format <odt|docx>   Output format (default: odt)\n"
		printf "  --fields <f1,f2,...>   Comma-separated placeholder field names\n"
		printf "  --header-logo <path>  Logo image for header\n"
		printf "  --footer-text <text>  Footer text\n"
		printf "  --output <path>       Output file path\n"
		return 1
		;;
	esac

	return 0
}

# ============================================================================
# Create command (fill template with data)
# ============================================================================

# Script mode: run a Python creation script with optional data/output args.
# Args: script data output
_create_run_script() {
	local script="$1"
	local data="$2"
	local output="$3"

	if [[ ! -f "${script}" ]]; then
		die "Script not found: ${script}"
	fi
	log_info "Running creation script: ${script}"
	activate_venv 2>/dev/null || true
	# shellcheck disable=SC2086
	python3 "${script}" ${data:+--data "$data"} ${output:+--output "$output"}
	return $?
}

# Fill an ODT template with data using Python zipfile manipulation.
# Args: template data output
_create_fill_odt_python() {
	local template="$1"
	local data="$2"
	local output="$3"

	python3 - "$template" "$data" "$output" <<'PYEOF'
import sys
import os
import json
import zipfile
import shutil
import tempfile
import re

template_path = sys.argv[1]
data_arg = sys.argv[2]
output_path = sys.argv[3]

# Load data
if os.path.isfile(data_arg):
    with open(data_arg, 'r') as f:
        data = json.load(f)
else:
    data = json.loads(data_arg)

# ODT is a ZIP file. Extract, replace placeholders in content.xml and styles.xml, repack.
tmp_dir = tempfile.mkdtemp()
try:
    with zipfile.ZipFile(template_path, 'r') as z:
        z.extractall(tmp_dir)

    # Replace in content.xml and styles.xml
    for xml_file in ['content.xml', 'styles.xml']:
        xml_path = os.path.join(tmp_dir, xml_file)
        if os.path.exists(xml_path):
            with open(xml_path, 'r', encoding='utf-8') as f:
                content = f.read()
            for key, value in data.items():
                # Replace {{key}} patterns (may be split across XML tags)
                # First try simple replacement
                content = content.replace('{{' + key + '}}', str(value))
                # Also try URL-encoded variants
                content = content.replace('%7B%7B' + key + '%7D%7D', str(value))
            with open(xml_path, 'w', encoding='utf-8') as f:
                f.write(content)

    # Repack as ZIP (ODT)
    with zipfile.ZipFile(output_path, 'w', zipfile.ZIP_DEFLATED) as z:
        # mimetype must be first and uncompressed
        mimetype_path = os.path.join(tmp_dir, 'mimetype')
        if os.path.exists(mimetype_path):
            z.write(mimetype_path, 'mimetype', compress_type=zipfile.ZIP_STORED)
        for root, dirs, files in os.walk(tmp_dir):
            for file in files:
                if file == 'mimetype':
                    continue
                file_path = os.path.join(root, file)
                arcname = os.path.relpath(file_path, tmp_dir)
                z.write(file_path, arcname)

    print(f"Created: {output_path}")
finally:
    shutil.rmtree(tmp_dir)
PYEOF

	return 0
}

# Parse create command arguments.
# Sets _CREATE_TEMPLATE, _CREATE_DATA, _CREATE_OUTPUT, _CREATE_SCRIPT in caller scope.
_create_cmd_parse_args() {
	_CREATE_TEMPLATE=""
	_CREATE_DATA=""
	_CREATE_OUTPUT=""
	_CREATE_SCRIPT=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--data)
			_CREATE_DATA="$2"
			shift 2
			;;
		--output | -o)
			_CREATE_OUTPUT="$2"
			shift 2
			;;
		--script)
			_CREATE_SCRIPT="$2"
			shift 2
			;;
		--*) shift ;;
		*)
			[[ -z "${_CREATE_TEMPLATE}" ]] && _CREATE_TEMPLATE="$1"
			shift
			;;
		esac
	done
	return 0
}

# Validate template inputs and resolve output path.
# Returns 1 on validation failure.
_create_validate_template() {
	local template="$1"
	local data="$2"
	local output_ref="$3"

	if [[ -z "${template}" ]]; then
		die "Usage: create <template-file> --data <json|file> --output <file>"
	fi
	if [[ ! -f "${template}" ]]; then
		die "Template not found: ${template}"
	fi
	if [[ -z "${data}" ]]; then
		die "Data required. Use --data '{\"field\": \"value\"}' or --data fields.json"
	fi

	local _output="${!output_ref}"
	if [[ -z "${_output}" ]]; then
		local ext
		ext=$(get_ext "$template")
		_output="${template%.*}-filled.${ext}"
		printf -v "${output_ref}" '%s' "${_output}"
	fi

	return 0
}

# Fill a template file with data, dispatching by extension.
_create_fill_template() {
	local template="$1"
	local data="$2"
	local output="$3"

	local ext
	ext=$(get_ext "$template")

	log_info "Creating document from template: $(basename "$template")"

	case "${ext}" in
	odt)
		if ! activate_venv 2>/dev/null || ! has_python_pkg odf 2>/dev/null; then
			die "odfpy required. Run: install --standard"
		fi
		_create_fill_odt_python "$template" "$data" "$output"
		if [[ -f "$output" ]]; then
			local size
			size=$(human_filesize "$output")
			log_ok "Created: ${output} (${size})"
		fi
		;;
	docx)
		if ! activate_venv 2>/dev/null || ! has_python_pkg docx 2>/dev/null; then
			die "python-docx required. Run: install --standard"
		fi
		log_warn "DOCX template filling not yet implemented. Use ODT format."
		;;
	*)
		die "Unsupported template format: ${ext}. Use odt or docx."
		;;
	esac

	return 0
}

cmd_create() {
	_create_cmd_parse_args "$@"

	local template="${_CREATE_TEMPLATE}"
	local data="${_CREATE_DATA}"
	local output="${_CREATE_OUTPUT}"
	local script="${_CREATE_SCRIPT}"

	if [[ -n "${script}" ]]; then
		_create_run_script "${script}" "${data}" "${output}"
		return $?
	fi

	_create_validate_template "${template}" "${data}" output || return 1
	_create_fill_template "${template}" "${data}" "${output}"

	return 0
}

# ============================================================================
# Entity extraction (t1044.6)
# ============================================================================

cmd_extract_entities() {
	local input=""
	local method="auto"
	local update_frontmatter=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--method)
			method="${2:-auto}"
			shift 2
			;;
		--update-frontmatter)
			update_frontmatter=true
			shift
			;;
		-*)
			die "Unknown option: $1"
			;;
		*)
			input="$1"
			shift
			;;
		esac
	done

	if [[ -z "$input" ]]; then
		die "Usage: ${SCRIPT_NAME} extract-entities <markdown-file> [--method auto|spacy|ollama|regex] [--update-frontmatter]"
	fi

	if [[ ! -f "$input" ]]; then
		die "File not found: ${input}"
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local extractor="${script_dir}/entity-extraction.py"

	if [[ ! -f "$extractor" ]]; then
		die "Entity extraction script not found: ${extractor}"
	fi

	# Determine Python interpreter (prefer venv)
	local python_cmd="python3"
	if activate_venv 2>/dev/null; then
		python_cmd="python3"
	fi

	local args=("$input" "--method" "$method")
	if [[ "$update_frontmatter" == true ]]; then
		args+=("--update-frontmatter")
	else
		args+=("--json")
	fi

	log_info "Extracting entities from: ${input} (method: ${method})"
	"$python_cmd" "$extractor" "${args[@]}"

	return $?
}

# ============================================================================
# Collection manifest (_index.toon) generation
# ============================================================================

# Generate _index.toon collection manifest for an email import output directory.
# Scans .md files for YAML frontmatter, .toon contact files, and builds three
# TOON indexes: documents, threads, contacts.
cmd_generate_manifest() {
	local output_dir=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "${output_dir}" ]]; then
				output_dir="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "${output_dir}" ]]; then
		die "Usage: generate-manifest <output-dir>"
	fi

	if [[ ! -d "${output_dir}" ]]; then
		die "Directory not found: ${output_dir}"
	fi

	local index_file="${output_dir}/_index.toon"

	log_info "Generating collection manifest: ${index_file}"

	# Use the extracted generate-manifest.py script for TOON generation
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	python3 "${script_dir}/generate-manifest.py" "${output_dir}" "${index_file}"

	local manifest_result=$?
	if [[ "${manifest_result}" -ne 0 ]]; then
		log_error "Failed to generate collection manifest"
		return 1
	fi

	log_ok "Collection manifest generated: ${index_file}"
	return 0
}

# ============================================================================
# Normalise command - Fix markdown heading hierarchy and structure
# ============================================================================

cmd_normalise() {
	local input=""
	local output=""
	local inplace=false
	local generate_pageindex=false
	local email_mode=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			output="$2"
			shift 2
			;;
		--inplace | -i)
			inplace=true
			shift
			;;
		--pageindex)
			generate_pageindex=true
			shift
			;;
		--email | -e)
			email_mode=true
			shift
			;;
		--*)
			shift
			;;
		*)
			if [[ -z "${input}" ]]; then
				input="$1"
			fi
			shift
			;;
		esac
	done

	# Validate
	if [[ -z "${input}" ]]; then
		die "Usage: normalise <input.md> [--output <file>] [--inplace] [--pageindex] [--email]"
	fi

	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi

	# Determine output path
	if [[ "${inplace}" == true ]]; then
		output="${input}"
	elif [[ -z "${output}" ]]; then
		local basename_noext="${input%.*}"
		output="${basename_noext}-normalised.md"
	fi

	if [[ "${email_mode}" == true ]]; then
		log_info "Normalising email markdown: $(basename "$input")"
	else
		log_info "Normalising markdown: $(basename "$input")"
	fi

	# Create temp file for processing
	local tmp_file
	tmp_file=$(mktemp)

	# Process the markdown file with the extracted normalise-markdown.py script
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	python3 "${script_dir}/normalise-markdown.py" "$input" "$tmp_file" "${email_mode}"

	# Check if processing succeeded
	if [[ ! -f "${tmp_file}" ]]; then
		die "Normalisation failed: temp file not created"
	fi

	# Move temp file to output
	mv "${tmp_file}" "${output}"

	if [[ -f "${output}" ]]; then
		local size
		size=$(human_filesize "${output}")
		log_ok "Normalised: ${output} (${size})"

		if [[ "${inplace}" == true ]]; then
			log_info "File updated in place"
		fi
	else
		die "Normalisation failed: output file not created"
	fi

	# Generate PageIndex tree if requested
	if [[ "${generate_pageindex}" == true ]]; then
		log_info "Generating PageIndex tree..."
		cmd_pageindex "${output}"
	fi

	return 0
}

# ============================================================================
# PageIndex command - Generate .pageindex.json from markdown heading hierarchy
# ============================================================================

cmd_pageindex() {
	local input=""
	local output=""
	local source_pdf=""
	local ollama_model="llama3.2:1b"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output | -o)
			output="$2"
			shift 2
			;;
		--source-pdf)
			source_pdf="$2"
			shift 2
			;;
		--ollama-model)
			ollama_model="$2"
			shift 2
			;;
		--*)
			shift
			;;
		*)
			if [[ -z "${input}" ]]; then
				input="$1"
			fi
			shift
			;;
		esac
	done

	# Validate
	if [[ -z "${input}" ]]; then
		die "Usage: pageindex <input.md> [--output <file>] [--source-pdf <file>] [--ollama-model <model>]"
	fi

	if [[ ! -f "${input}" ]]; then
		die "Input file not found: ${input}"
	fi

	# Determine output path
	if [[ -z "${output}" ]]; then
		local basename_noext="${input%.*}"
		output="${basename_noext}.pageindex.json"
	fi

	# Detect Ollama availability for LLM summaries
	local use_ollama=false
	if has_cmd ollama; then
		if ollama list 2>/dev/null | grep -q "${ollama_model%%:*}"; then
			use_ollama=true
			log_info "Ollama available — using ${ollama_model} for section summaries"
		else
			log_info "Ollama model ${ollama_model} not found — using first-sentence fallback"
		fi
	else
		log_info "Ollama not available — using first-sentence fallback for summaries"
	fi

	# Extract page count from source PDF if available
	local page_count="0"
	if [[ -n "${source_pdf}" ]] && [[ -f "${source_pdf}" ]]; then
		if has_cmd pdfinfo; then
			page_count=$(pdfinfo "${source_pdf}" 2>/dev/null | grep "Pages:" | awk '{print $2}' || echo "0")
			log_info "Source PDF: ${source_pdf} (${page_count} pages)"
		fi
	fi

	log_info "Generating PageIndex: $(basename "$input") -> $(basename "$output")"

	# Generate the PageIndex JSON with the extracted pageindex-generator.py script
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	python3 "${script_dir}/pageindex-generator.py" \
		"$input" "$output" "${use_ollama}" "${ollama_model}" "${source_pdf}" "${page_count}"

	if [[ -f "${output}" ]]; then
		local size
		size=$(human_filesize "${output}")
		local node_count
		node_count=$(python3 -c "
import json, sys
def count_nodes(node):
    c = 1
    for child in node.get('children', []):
        c += count_nodes(child)
    return c
with open(sys.argv[1]) as f:
    data = json.load(f)
print(count_nodes(data.get('tree', {})))
" "${output}" 2>/dev/null || echo "?")
		log_ok "PageIndex created: ${output} (${size}, ${node_count} nodes)"
	else
		die "PageIndex generation failed: output file not created"
	fi

	return 0
}

# ============================================================================
# Add related docs (t1044.11)
# ============================================================================

cmd_add_related_docs() {
	local input="${1:-}"
	local directory=""
	local update_all=false
	local dry_run=false

	# Parse arguments
	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--directory | -d)
			directory="$2"
			shift 2
			;;
		--update-all)
			update_all=true
			shift
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			die "Usage: ${SCRIPT_NAME} add-related-docs <file|directory> [--directory <dir>] [--update-all] [--dry-run]"
			;;
		esac
	done

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local linker="${script_dir}/add-related-docs.py"

	if [[ ! -f "$linker" ]]; then
		die "Related docs script not found: ${linker}"
	fi

	# Determine Python interpreter (prefer venv)
	local python_cmd="python3"
	if activate_venv 2>/dev/null; then
		python_cmd="python3"
	fi

	# Check for PyYAML
	if ! "$python_cmd" -c "import yaml" 2>/dev/null; then
		log_warn "PyYAML not installed. Installing..."
		if [[ ! -d "${VENV_DIR}" ]]; then
			mkdir -p "$(dirname "${VENV_DIR}")"
			python3 -m venv "${VENV_DIR}"
		fi
		activate_venv
		pip install --quiet PyYAML
	fi

	local args=()
	if [[ -n "$input" ]]; then
		args+=("$input")
	fi
	if [[ -n "$directory" ]]; then
		args+=("--directory" "$directory")
	fi
	if [[ "$update_all" == true ]]; then
		args+=("--update-all")
	fi
	if [[ "$dry_run" == true ]]; then
		args+=("--dry-run")
	fi

	log_info "Adding related_docs to markdown files..."
	"$python_cmd" "$linker" "${args[@]}"

	return 0
}

# ============================================================================
# Cross-document linking (t1049.11)
# ============================================================================

cmd_link_documents() {
	local directory=""
	local dry_run=false
	local min_shared=2

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--min-shared-entities)
			min_shared="${2:-2}"
			shift 2
			;;
		-*)
			die "Unknown option: $1"
			;;
		*)
			directory="$1"
			shift
			;;
		esac
	done

	if [[ -z "$directory" ]]; then
		die "Usage: ${SCRIPT_NAME} link-documents <directory> [--dry-run] [--min-shared-entities N]"
	fi

	if [[ ! -d "$directory" ]]; then
		die "Directory not found: ${directory}"
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local linker="${script_dir}/cross-document-linking.py"

	if [[ ! -f "$linker" ]]; then
		die "Cross-document linking script not found: ${linker}"
	fi

	# Determine Python interpreter (prefer venv)
	local python_cmd="python3"
	if activate_venv 2>/dev/null; then
		python_cmd="python3"
	fi

	local args=("$directory" "--min-shared-entities" "$min_shared")
	if [[ "$dry_run" == true ]]; then
		args+=("--dry-run")
	fi

	log_info "Building cross-document links in: ${directory}"
	"$python_cmd" "$linker" "${args[@]}"

	return $?
}

# ============================================================================
# Help
# ============================================================================

cmd_help() {
	printf '%b%s%b - Document format conversion and creation\n\n' "${BOLD}" "${SCRIPT_NAME}" "${NC}"
	printf "Usage: %s <command> [options]\n\n" "${SCRIPT_NAME}"
	printf '%b\n' "${BOLD}Commands:${NC}"
	printf "  convert           Convert between document formats\n"
	printf "  forensics         Audit/repair mirrored and rotated PDF scans\n"
	printf "  import-emails     Batch import .eml directory or mbox file to markdown\n"
	printf "  create            Create a document from a template + data\n"
	printf "  template          Manage document templates (list, draft)\n"
	printf "  normalise         Fix markdown heading hierarchy and structure\n"
	printf "  pageindex         Generate .pageindex.json tree from markdown headings\n"
	printf "  extract-entities  Extract named entities from markdown (t1044.6)\n"
	printf "  generate-manifest Generate collection manifest (_index.toon) (t1044.9)\n"
	printf "  add-related-docs  Add related_docs frontmatter and navigation links (t1044.11)\n"
	printf "  enforce-frontmatter Enforce YAML frontmatter on markdown files\n"
	printf "  link-documents    Add cross-document links to email collection (t1049.11)\n"
	printf "  install           Install conversion tools (--minimal, --standard, --full, --ocr)\n"
	printf "  formats           Show supported format conversions\n"
	printf "  status            Show installed tools and availability\n"
	printf "  help              Show this help\n"
	printf '\n%b\n' "${BOLD}Examples:${NC}"
	printf "  %s convert report.pdf --to odt\n" "${SCRIPT_NAME}"
	printf "  %s convert letter.odt --to pdf\n" "${SCRIPT_NAME}"
	printf "  %s convert notes.md --to docx\n" "${SCRIPT_NAME}"
	printf "  %s convert email.eml --to md\n" "${SCRIPT_NAME}"
	printf "  %s convert message.msg --to md\n" "${SCRIPT_NAME}"
	printf "  %s import-emails ~/Mail/inbox/ --output ./imported\n" "${SCRIPT_NAME}"
	printf "  %s import-emails archive.mbox --output ./imported\n" "${SCRIPT_NAME}"
	printf "  %s generate-manifest ./imported\n" "${SCRIPT_NAME}"
	printf "  %s convert scanned.pdf --to odt --ocr tesseract\n" "${SCRIPT_NAME}"
	printf "  %s forensics scans.pdf --output ./audit --write-readable\n" "${SCRIPT_NAME}"
	printf "  %s convert screenshot.png --to md --ocr auto\n" "${SCRIPT_NAME}"
	printf "  %s convert report.pdf --to md --no-normalise\n" "${SCRIPT_NAME}"
	printf "  %s normalise document.md --output clean.md\n" "${SCRIPT_NAME}"
	printf "  %s normalise document.md --inplace --pageindex\n" "${SCRIPT_NAME}"
	printf "  %s normalise email.md --inplace --email\n" "${SCRIPT_NAME}"
	printf "  %s pageindex document.md --source-pdf original.pdf\n" "${SCRIPT_NAME}"
	printf "  %s create template.odt --data fields.json -o letter.odt\n" "${SCRIPT_NAME}"
	printf "  %s template draft --type letter --format odt\n" "${SCRIPT_NAME}"
	printf "  %s extract-entities email.md --update-frontmatter\n" "${SCRIPT_NAME}"
	printf "  %s extract-entities email.md --method spacy --json\n" "${SCRIPT_NAME}"
	printf "  %s generate-manifest ./imported-emails\n" "${SCRIPT_NAME}"
	printf "  %s generate-manifest ./emails -o manifest.toon\n" "${SCRIPT_NAME}"
	printf "  %s add-related-docs email.md\n" "${SCRIPT_NAME}"
	printf "  %s add-related-docs --directory ./emails --update-all\n" "${SCRIPT_NAME}"
	printf "  %s link-documents ./emails --min-shared-entities 3\n" "${SCRIPT_NAME}"
	printf "  %s link-documents ./emails --dry-run\n" "${SCRIPT_NAME}"
	printf "  %s install --standard\n" "${SCRIPT_NAME}"
	printf "  %s install --ocr\n" "${SCRIPT_NAME}"
	printf "\nSee: tools/document/document-creation.md for full documentation.\n"
	printf "\nNote: Markdown conversions are automatically normalised unless --no-normalise is specified.\n"

	return 0
}

# ============================================================================
# Main dispatch
# ============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "${cmd}" in
	convert) cmd_convert "$@" ;;
	forensics | audit) cmd_document_forensics "$@" ;;
	import-emails) cmd_import_emails "$@" ;;
	generate-manifest) cmd_generate_manifest "$@" ;;
	create) cmd_create "$@" ;;
	template) cmd_template "$@" ;;
	normalise | normalize) cmd_normalise "$@" ;;
	extract-entities) cmd_extract_entities "$@" ;;
	pageindex) cmd_pageindex "$@" ;;
	add-related-docs) cmd_add_related_docs "$@" ;;
	enforce-frontmatter | frontmatter) "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/frontmatter-helper.sh" "$@" ;;
	link-documents) cmd_link_documents "$@" ;;
	install) cmd_install "$@" ;;
	formats) cmd_formats ;;
	status) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
