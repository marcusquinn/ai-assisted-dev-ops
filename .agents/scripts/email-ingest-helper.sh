#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# email-ingest-helper.sh — Ingest .eml/.emlx files into the knowledge plane
#
# Usage:
#   email-ingest-helper.sh ingest <eml-path> [--repo-path <path>] [--sensitivity <tier>]
#
# Creates parent source (kind=email) with full email meta fields, sanitised body,
# and child sources for each attachment linked via parent_source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Guard color fallbacks
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

if ! declare -f print_info >/dev/null 2>&1; then
	print_info() {
		local _m="$1"
		printf "${BLUE}[INFO]${NC} %s\n" "$_m"
		return 0
	}
fi
if ! declare -f print_success >/dev/null 2>&1; then
	print_success() {
		local _m="$1"
		printf "${GREEN}[OK]${NC} %s\n" "$_m"
		return 0
	}
fi
if ! declare -f print_warning >/dev/null 2>&1; then
	print_warning() {
		local _m="$1"
		printf "${YELLOW}[WARN]${NC} %s\n" "$_m"
		return 0
	}
fi
if ! declare -f print_error >/dev/null 2>&1; then
	print_error() {
		local _m="$1"
		printf "${RED}[ERROR]${NC} %s\n" "$_m"
		return 0
	}
fi

KNOWLEDGE_HELPER="${SCRIPT_DIR}/knowledge-helper.sh"
EMAIL_PARSER="${SCRIPT_DIR}/email_parse.py"
COLLECTION_RECEIPTS="${SCRIPT_DIR}/email_collection_receipts.py"
SENSITIVITY_DETECTOR="${SCRIPT_DIR}/sensitivity-detector-helper.sh"
DOC_EXTRACTOR="${SCRIPT_DIR}/document-extraction-helper.sh"
META_DEFAULT_SENSITIVITY="internal"
META_DEFAULT_TRUST="unverified"
_TS_FMT="%Y-%m-%dT%H:%M:%SZ"
_NULL_STR="null"
_UNKNOWN_STR="unknown"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required but not installed"
		return 1
	fi
	return 0
}

_require_python3() {
	if ! command -v python3 >/dev/null 2>&1; then
		print_error "python3 is required but not installed"
		return 1
	fi
	return 0
}

_slugify() {
	local input="$1"
	echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//; s/-$//'
	return 0
}

_sha256_file() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
	else
		print_error "sha256sum/shasum not found"
		return 1
	fi
	return 0
}

_allocate_source_id() {
	local basename_no_ext="$1"
	local sources_dir="$2"
	local source_id
	source_id=$(_slugify "$basename_no_ext")
	[[ -z "$source_id" ]] && source_id="source-$(date +%s)"
	if [[ -d "${sources_dir}/${source_id}" ]]; then
		source_id="${source_id}-$(date +%s)"
	fi
	echo "$source_id"
	return 0
}

_existing_email_source() {
	local sources_dir="$1"
	local content_sha="$2"
	local message_id="$3"
	local meta_path existing_sha existing_message_id existing_kind
	for meta_path in "${sources_dir}"/*/meta.json; do
		[[ -f "$meta_path" ]] || continue
		existing_kind=$(jq -r '.kind // ""' "$meta_path" 2>/dev/null || true)
		[[ "$existing_kind" == "email" ]] || continue
		existing_sha=$(jq -r '.sha256 // ""' "$meta_path" 2>/dev/null || true)
		existing_message_id=$(jq -r '.message_id // ""' "$meta_path" 2>/dev/null || true)
		if [[ -n "$content_sha" && "$content_sha" != "$_UNKNOWN_STR" && "$existing_sha" == "$content_sha" ]] ||
			[[ -n "$message_id" && "$existing_message_id" == "$message_id" ]]; then
			jq -r '.id // ""' "$meta_path" 2>/dev/null
			return 0
		fi
	done
	return 1
}

# _sanitise_html: strip tracking pixels and remote beacon images
# Args: <html-content>  (reads from stdin if no arg)
_sanitise_html() {
	local html_content="${1:-$(cat)}"
	# Strip tracking pixels: 1x1 images with remote URLs
	# Replace <img src="http(s)://..."> with comment
	local sanitised
	sanitised=$(echo "$html_content" | sed -E \
		-e 's|<img [^>]*src="https?://[^"]*"[^>]*/?>|<!-- tracker stripped -->|gi' \
		-e 's|<img [^>]*src="https?://[^"]*"[^>]*>[^<]*</img>|<!-- tracker stripped -->|gi')
	# Strip UTM tracking parameters from remaining URLs
	sanitised=$(echo "$sanitised" | sed -E \
		-e 's/\?utm_[^"'"'"'& ]*//g' \
		-e 's/&utm_[^"'"'"'& ]*//g')
	echo "$sanitised"
	return 0
}

# _write_email_meta: write meta.json with email-specific fields
# Args: <meta_path> <source_id> <source_uri> <sha256> <size_bytes>
#        <parsed_json_file> <body_text_sha> <body_html_sha> <child_ids_json>
#        <collection_receipt_file>
_write_email_meta() {
	local meta_path="$1"
	local source_id="$2"
	local source_uri="$3"
	local sha256="$4"
	local size_bytes="$5"
	local parsed_json_file="$6"
	local body_text_sha="$7"
	local body_html_sha="$8"
	local child_ids_json="$9"
	local collection_receipt_file="${10}"
	_require_jq || return 1
	local ts actor
	ts=$(date -u +"$_TS_FMT" 2>/dev/null || date +"$_TS_FMT")
	actor="${USER:-$_UNKNOWN_STR}"
	jq -n \
		--argjson parsed "$(cat "$parsed_json_file")" \
		--arg id "$source_id" \
		--arg uri "$source_uri" \
		--arg sha "$sha256" \
		--argjson sz "$size_bytes" \
		--arg ts "$ts" \
		--arg by "$actor" \
		--arg sens "$META_DEFAULT_SENSITIVITY" \
		--arg trust "$META_DEFAULT_TRUST" \
		--arg bt_sha "${body_text_sha:-$_NULL_STR}" \
		--arg bh_sha "${body_html_sha:-$_NULL_STR}" \
		--arg nil "$_NULL_STR" \
		--argjson children "$child_ids_json" \
		--argjson collection "$(cat "$collection_receipt_file")" \
		'{
			version: 1,
			id: $id,
			kind: "email",
			source_uri: $uri,
			sha256: $sha,
			ingested_at: $ts,
			ingested_by: $by,
			sensitivity: $sens,
			trust: $trust,
			blob_path: null,
			size_bytes: $sz,
			from: ($parsed.from // ""),
			to: ($parsed.to // ""),
			cc: ($parsed.cc // ""),
			bcc: ($parsed.bcc // ""),
			date: ($parsed.date // ""),
			subject: ($parsed.subject // ""),
			message_id: ($parsed.message_id // ""),
			in_reply_to: ($parsed.in_reply_to // ""),
			references: ($parsed.references // ""),
			body_text_sha: (if $bt_sha == $nil then null else $bt_sha end),
			body_html_sha: (if $bh_sha == $nil then null else $bh_sha end),
			attachments: $children,
			collection_refs: $collection
		}' >"$meta_path"
	return 0
}

# _write_attachment_meta: create meta.json for a child (attachment) source
# Args: <meta_path> <child_id> <parent_id> <filename> <content_type> <sha256> <size_bytes>
_write_attachment_meta() {
	local meta_path="$1"
	local child_id="$2"
	local parent_id="$3"
	local filename="$4"
	local content_type="$5"
	local sha256="$6"
	local size_bytes="$7"
	_require_jq || return 1
	local ts actor
	ts=$(date -u +"$_TS_FMT" 2>/dev/null || date +"$_TS_FMT")
	actor="${USER:-$_UNKNOWN_STR}"
	jq -n \
		--arg id "$child_id" \
		--arg parent "$parent_id" \
		--arg fname "$filename" \
		--arg ct "$content_type" \
		--arg sha "$sha256" \
		--argjson sz "$size_bytes" \
		--arg ts "$ts" \
		--arg by "$actor" \
		--arg sens "$META_DEFAULT_SENSITIVITY" \
		--arg trust "$META_DEFAULT_TRUST" \
		'{
			version: 1,
			id: $id,
			kind: "attachment",
			source_uri: ("attachment://" + $fname),
			sha256: $sha,
			ingested_at: $ts,
			ingested_by: $by,
			sensitivity: $sens,
			trust: $trust,
			blob_path: null,
			size_bytes: $sz,
			parent_source: $parent,
			attachment_filename: $fname,
			content_type: $ct
		}' >"$meta_path"
	return 0
}

# _run_sensitivity: run sensitivity detector on a source if available
# Args: <source_id> <knowledge_root>
_run_sensitivity() {
	local source_id="$1"
	local knowledge_root="$2"
	if [[ -x "$SENSITIVITY_DETECTOR" ]]; then
		bash "$SENSITIVITY_DETECTOR" classify "$source_id" \
			--knowledge-root "$knowledge_root" >/dev/null 2>&1 || true
	fi
	return 0
}

# _trigger_doc_extraction: run document extraction on PDF attachments
# Args: <source_id> <knowledge_root>
_trigger_doc_extraction() {
	local source_id="$1"
	local knowledge_root="$2"
	if [[ -x "$DOC_EXTRACTOR" ]]; then
		bash "$DOC_EXTRACTOR" extract "$source_id" \
			--knowledge-root "$knowledge_root" >/dev/null 2>&1 || true
	fi
	return 0
}

# _process_attachments: create child sources for each attachment
# Args: <parsed_json_file> <sources_dir> <parent_id> <knowledge_root>
# Outputs: JSON array of {source_id, filename} to stdout
_process_attachments() {
	local parsed_json_file="$1"
	local sources_dir="$2"
	local parent_id="$3"
	local knowledge_root="$4"
	_require_jq || return 1
	local att_count
	att_count=$(jq -r '.attachments | length' "$parsed_json_file")
	if [[ "$att_count" -eq 0 ]]; then
		echo "[]"
		return 0
	fi
	local children_json="["
	local i=0
	while [[ "$i" -lt "$att_count" ]]; do
		local att_filename att_path att_content_type att_size
		att_filename=$(jq -r ".attachments[$i].filename" "$parsed_json_file")
		att_path=$(jq -r ".attachments[$i].content_path" "$parsed_json_file")
		att_content_type=$(jq -r ".attachments[$i].content_type" "$parsed_json_file")
		att_size=$(jq -r ".attachments[$i].size" "$parsed_json_file")
		local child_id
		child_id=$(_allocate_source_id "${parent_id}-att-${att_filename%.*}" "$sources_dir")
		local child_dir="${sources_dir}/${child_id}"
		mkdir -p "$child_dir"
		# Copy attachment file
		if [[ -f "$att_path" ]]; then
			cp "$att_path" "${child_dir}/${att_filename}"
		fi
		# Compute sha256
		local att_sha="$_UNKNOWN_STR"
		if [[ -f "${child_dir}/${att_filename}" ]]; then
			att_sha=$(_sha256_file "${child_dir}/${att_filename}") || att_sha="$_UNKNOWN_STR"
		fi
		# Write child meta
		_write_attachment_meta "${child_dir}/meta.json" "$child_id" "$parent_id" \
			"$att_filename" "$att_content_type" "$att_sha" "$att_size"
		# Run sensitivity on child independently
		_run_sensitivity "$child_id" "$knowledge_root"
		# Trigger PDF extraction if applicable
		if [[ "$att_content_type" == "application/pdf" ]]; then
			_trigger_doc_extraction "$child_id" "$knowledge_root"
		fi
		# Build children JSON
		[[ "$i" -gt 0 ]] && children_json="${children_json},"
		children_json="${children_json}{\"source_id\":\"${child_id}\",\"filename\":\"${att_filename}\"}"
		i=$((i + 1))
	done
	children_json="${children_json}]"
	echo "$children_json"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_ingest: main ingestion command
# ---------------------------------------------------------------------------

cmd_ingest() {
	local eml_path=""
	local repo_path=""
	local sensitivity_override=""
	repo_path="$(pwd)"
	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--repo-path)
			local _rp="$1"
			repo_path="$_rp"
			shift
			;;
		--sensitivity)
			local _s="$1"
			sensitivity_override="$_s"
			shift
			;;
		-*)
			print_error "Unknown option: $_key"
			return 1
			;;
		*) [[ -z "$eml_path" ]] && eml_path="$_key" ;;
		esac
	done
	if [[ -z "$eml_path" ]]; then
		print_error "ingest requires <eml-path>"
		return 1
	fi
	if [[ ! -f "$eml_path" ]]; then
		print_error "File not found: $eml_path"
		return 1
	fi
	_require_jq || return 1
	_require_python3 || return 1
	repo_path="$(cd "$repo_path" && pwd)"
	# Resolve knowledge root via knowledge-helper.sh
	local knowledge_root
	knowledge_root=$(bash "$KNOWLEDGE_HELPER" status "$repo_path" 2>/dev/null |
		grep -oE '/[^ ]*_knowledge' | head -1 || true)
	if [[ -z "$knowledge_root" ]]; then
		# Fallback: construct from repo_path
		knowledge_root="${repo_path}/_knowledge"
	fi
	if [[ ! -d "${knowledge_root}/sources" ]]; then
		print_error "Knowledge plane not provisioned (no sources/ dir). Run: knowledge-helper.sh provision"
		return 1
	fi
	_do_ingest "$eml_path" "$repo_path" "$knowledge_root" "$sensitivity_override"
	return $?
}

# _do_ingest: core ingestion logic (separated for complexity control)
# Args: <eml_path> <repo_path> <knowledge_root> <sensitivity_override>
_do_ingest() {
	local eml_path="$1"
	local repo_path="$2"
	local knowledge_root="$3"
	local sensitivity_override="$4"
	local sources_dir="${knowledge_root}/sources"
	# Parse the email
	local parse_dir
	parse_dir=$(mktemp -d)
	local parsed_json_file="${parse_dir}/parsed.json"
	if ! python3 "$EMAIL_PARSER" "$eml_path" --output-dir "$parse_dir" >"$parsed_json_file" 2>/dev/null; then
		print_error "Failed to parse email: $eml_path"
		rm -rf "$parse_dir"
		return 1
	fi
	local collection_receipt_file="${parse_dir}/collection-receipt.json"
	if ! python3 "$COLLECTION_RECEIPTS" extract --eml "$eml_path" >"$collection_receipt_file"; then
		print_error "Invalid email collection receipt: $eml_path"
		rm -rf "$parse_dir"
		return 1
	fi
	local eml_sha256 parsed_message_id existing_source_id
	eml_sha256=$(_sha256_file "$eml_path") || eml_sha256="$_UNKNOWN_STR"
	parsed_message_id=$(jq -r '.message_id // ""' "$parsed_json_file")
	if existing_source_id=$(_existing_email_source "$sources_dir" "$eml_sha256" "$parsed_message_id"); then
		if ! python3 "$COLLECTION_RECEIPTS" merge-meta \
			--eml "$eml_path" \
			--meta "${sources_dir}/${existing_source_id}/meta.json"; then
			print_error "Failed to merge collection references: $existing_source_id"
			rm -rf "$parse_dir"
			return 1
		fi
		rm -rf "$parse_dir"
		print_success "Ingested email (existing canonical): $existing_source_id"
		return 0
	fi
	# Allocate parent source ID
	local basename_no_ext
	basename_no_ext="$(basename "$eml_path")"
	basename_no_ext="${basename_no_ext%.*}"
	local source_id
	source_id=$(_allocate_source_id "$basename_no_ext" "$sources_dir")
	local source_dir="${sources_dir}/${source_id}"
	mkdir -p "$source_dir"
	# Store body files
	_store_body_files "$parsed_json_file" "$source_dir" "$parse_dir"
	# Compute hashes
	local eml_size body_text_sha body_html_sha
	eml_size=$(wc -c <"$eml_path" | tr -d ' ')
	body_text_sha=$(_compute_body_sha "${source_dir}/text.txt")
	body_html_sha=$(_compute_body_sha "${source_dir}/body.html")
	# Process attachments
	local children_json
	children_json=$(_process_attachments "$parsed_json_file" "$sources_dir" "$source_id" "$knowledge_root")
	# Write parent meta
	local source_uri
	local abs_path
	abs_path="$(cd "$(dirname "$eml_path")" && pwd)/$(basename "$eml_path")"
	source_uri="file://${abs_path}"
	_write_email_meta "${source_dir}/meta.json" "$source_id" "$source_uri" \
		"$eml_sha256" "$eml_size" "$parsed_json_file" \
		"$body_text_sha" "$body_html_sha" "$children_json" \
		"$collection_receipt_file"
	# Run sensitivity on parent
	_run_sensitivity "$source_id" "$knowledge_root"
	# Apply sensitivity override if provided
	if [[ -n "$sensitivity_override" ]]; then
		_apply_sensitivity_override "$source_id" "$knowledge_root" "${source_dir}/meta.json" "$sensitivity_override"
	fi
	# Cleanup
	rm -rf "$parse_dir"
	print_success "Ingested email: $source_id (attachments: $(echo "$children_json" | jq 'length'))"
	return 0
}

# _store_body_files: copy body text/html into source dir with sanitisation
# Args: <parsed_json_file> <source_dir> <parse_dir>
_store_body_files() {
	local parsed_json_file="$1"
	local source_dir="$2"
	local parse_dir="$3"
	local body_text_path body_html_path
	body_text_path=$(jq -r '.body_text_path // ""' "$parsed_json_file")
	body_html_path=$(jq -r '.body_html_path // ""' "$parsed_json_file")
	# Store plain text body
	if [[ -n "$body_text_path" && -f "$body_text_path" ]]; then
		cp "$body_text_path" "${source_dir}/text.txt"
	fi
	# Store sanitised HTML body
	if [[ -n "$body_html_path" && -f "$body_html_path" ]]; then
		local raw_html
		raw_html=$(cat "$body_html_path")
		local sanitised_html
		sanitised_html=$(_sanitise_html "$raw_html")
		echo "$sanitised_html" >"${source_dir}/body.html"
	fi
	return 0
}

# _compute_body_sha: compute sha256 of a body file if it exists, echo null-string otherwise
_compute_body_sha() {
	local file_path="$1"
	if [[ -f "$file_path" ]]; then
		_sha256_file "$file_path"
	else
		echo "$_NULL_STR"
	fi
	return 0
}

# _apply_sensitivity_override: apply user-provided sensitivity to meta.json
_apply_sensitivity_override() {
	local source_id="$1"
	local knowledge_root="$2"
	local meta_path="$3"
	local override_tier="$4"
	if [[ -x "$SENSITIVITY_DETECTOR" ]]; then
		bash "$SENSITIVITY_DETECTOR" override "$source_id" "$override_tier" \
			--reason "user-provided via --sensitivity flag" \
			--knowledge-root "$knowledge_root" >/dev/null 2>&1 || true
	else
		local tmp
		tmp=$(mktemp)
		if jq --arg t "$override_tier" '.sensitivity = $t' "$meta_path" >"$tmp" 2>/dev/null; then
			mv "$tmp" "$meta_path"
		else
			rm -f "$tmp"
		fi
	fi
	print_info "[$source_id] sensitivity overridden to: $override_tier"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------

cmd_help() {
	cat <<'HELP'
email-ingest-helper.sh — Ingest .eml/.emlx files into the knowledge plane

Usage:
  email-ingest-helper.sh ingest <eml-path> [--repo-path <path>] [--sensitivity <tier>]
  email-ingest-helper.sh help

Commands:
  ingest    Parse .eml/.emlx and create parent + child sources
  help      Show this help
HELP
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local subcommand="${1:-help}"
	shift || true
	case "$subcommand" in
	ingest) cmd_ingest "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown subcommand: $subcommand"
		cmd_help
		exit 1
		;;
	esac
	return 0
}

main "$@"
