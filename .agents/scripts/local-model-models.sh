#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Local Model Models Library — Listing, Download & Search
# =============================================================================
# List downloaded GGUF models with metadata, download models from HuggingFace
# via the Hugging Face CLI, and search the HuggingFace API for GGUF repos.
#
# Usage: source "${SCRIPT_DIR}/local-model-models.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, etc.)
#   - local-model-db.sh (sql_escape, register_model_inventory)
#   - curl, jq (for HuggingFace API calls)
#   - hf or huggingface-cli (for downloads)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LOCAL_MODEL_MODELS_LIB_LOADED:-}" ]] && return 0
_LOCAL_MODEL_MODELS_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Model Listing Helpers
# =============================================================================

# Get model size in human-readable format
_models_get_size_human() {
	local model_path="$1"
	local size_human=""

	local size_bytes
	size_bytes="$(_file_size_bytes "$model_path")"
	size_human="$(echo "$size_bytes" | awk '{
		if ($1 >= 1073741824) printf "%.1f GB", $1/1073741824;
		else if ($1 >= 1048576) printf "%.0f MB", $1/1048576;
		else printf "%.0f KB", $1/1024;
	}')"

	echo "$size_human"
	return 0
}

# Extract quantization from model filename
_models_get_quant() {
	local name="$1"
	local quant

	quant="$(echo "$name" | grep -oiE '(q[0-9]_[a-z0-9_]+|iq[0-9]_[a-z0-9]+|f16|f32|bf16)' | head -1 | tr '[:lower:]' '[:upper:]')"
	[[ -z "$quant" ]] && quant="-"

	echo "$quant"
	return 0
}

# Get last used time for model from database
_models_get_last_used() {
	local name="$1"
	local last_used_str="-"

	if suppress_stderr command -v sqlite3 && [[ -f "$LOCAL_USAGE_DB" ]]; then
		local db_last escaped_name
		escaped_name="$(sql_escape "$name")"
		db_last="$(sqlite3 "$LOCAL_USAGE_DB" "SELECT last_used FROM model_inventory WHERE model='${escaped_name}' LIMIT 1;" 2>/dev/null || echo "")"
		if [[ -n "$db_last" ]]; then
			local now_epoch last_epoch diff_days
			now_epoch="$(date +%s)"
			last_epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$db_last" +%s 2>/dev/null || date -d "$db_last" +%s 2>/dev/null || echo "0")"
			if [[ "$last_epoch" -gt 0 ]]; then
				diff_days="$(((now_epoch - last_epoch) / 86400))"
				if [[ "$diff_days" -eq 0 ]]; then
					last_used_str="today"
				elif [[ "$diff_days" -eq 1 ]]; then
					last_used_str="1d ago"
				else
					last_used_str="${diff_days}d ago"
				fi
			fi
		fi
	fi

	echo "$last_used_str"
	return 0
}

# =============================================================================
# Command: models
# =============================================================================

cmd_models() {
	local json_output=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			json_output=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ ! -d "$LOCAL_MODELS_STORE" ]]; then
		print_info "No models directory. Run: local-model-helper.sh setup"
		return 0
	fi

	local models
	models="$(find "$LOCAL_MODELS_STORE" -name "*.gguf" -type f 2>/dev/null)"

	if [[ -z "$models" ]]; then
		print_info "No models downloaded yet"
		print_info "Search: local-model-helper.sh search \"qwen3 8b\""
		print_info "Download: local-model-helper.sh download <repo> --quant Q4_K_M"
		return 0
	fi

	if [[ "$json_output" == "true" ]]; then
		echo "["
		local first=true
		while IFS= read -r model_path; do
			local name size_bytes last_used
			name="$(basename "$model_path")"
			size_bytes="$(_file_size_bytes "$model_path")"
			last_used="$(_models_get_last_used "$name")"
			[[ "$first" == "true" ]] || echo ","
			first=false
			printf '  {"name": "%s", "size_bytes": %s, "last_used": "%s"}' "$name" "$size_bytes" "$last_used"
		done <<<"$models"
		echo ""
		echo "]"
		return 0
	fi

	# Table header
	printf "%-40s %10s %8s %12s\n" "NAME" "SIZE" "QUANT" "LAST USED"
	printf "%-40s %10s %8s %12s\n" "----" "----" "-----" "---------"

	while IFS= read -r model_path; do
		local name size_human quant last_used_str
		name="$(basename "$model_path")"

		size_human="$(_models_get_size_human "$model_path")"
		quant="$(_models_get_quant "$name")"
		last_used_str="$(_models_get_last_used "$name")"

		printf "%-40s %10s %8s %12s\n" "$name" "$size_human" "$quant" "$last_used_str"
	done <<<"$models"

	return 0
}

# =============================================================================
# Download Helpers
# =============================================================================

# Find GGUF file matching quantization in HuggingFace repo
_download_find_gguf() {
	local repo="$1"
	local quant="$2"
	local quant_lower
	quant_lower="$(echo "$quant" | tr '[:upper:]' '[:lower:]')"

	print_info "Searching for ${quant} quantization in ${repo}..."

	# List files in the repo via HuggingFace API
	local files_json
	files_json="$(curl -sL "${HF_API}/models/${repo}" 2>/dev/null || echo "")"

	if [[ -z "$files_json" ]]; then
		print_error "Could not fetch repo info for: ${repo}"
		return 1
	fi

	# Try to find a matching GGUF file from siblings
	local siblings_json filename
	siblings_json="$(echo "$files_json" | jq -r '.siblings[]?.rfilename // empty' 2>/dev/null || echo "")"

	if [[ -n "$siblings_json" ]]; then
		filename="$(echo "$siblings_json" | grep -i "\.gguf$" | grep -i "$quant_lower" | head -1)"
	fi

	# If not found in siblings, try the tree API
	if [[ -z "$filename" ]]; then
		local tree_json
		tree_json="$(curl -sL "${HF_API}/models/${repo}/tree/main" 2>/dev/null || echo "")"
		if [[ -n "$tree_json" ]]; then
			filename="$(echo "$tree_json" | jq -r '.[].path // empty' 2>/dev/null | grep -i "\.gguf$" | grep -i "$quant_lower" | head -1)"
		fi
	fi

	if [[ -z "$filename" ]]; then
		print_error "No GGUF file matching quantization '${quant}' found in ${repo}"
		print_info "Available GGUF files:"
		if [[ -n "$siblings_json" ]]; then
			echo "$siblings_json" | grep -i "\.gguf$" | head -10
		fi
		print_info "Specify exact file: --file <filename.gguf>"
		return 3
	fi

	echo "$filename"
	return 0
}

# =============================================================================
# Command: download / pull
# =============================================================================

cmd_download() {
	local repo=""
	local quant="Q4_K_M"
	local filename=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--quant)
			quant="$2"
			shift 2
			;;
		--file)
			filename="$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$repo" ]]; then
				repo="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$repo" ]]; then
		print_error "Repository is required"
		print_info "Usage: local-model-helper.sh download <owner/repo> [--quant Q4_K_M]"
		print_info "Example: local-model-helper.sh download Qwen/Qwen3-8B-GGUF --quant Q4_K_M"
		return 1
	fi

	ensure_dirs

	local hf_cli=""
	if ! hf_cli="$(_local_model_hf_cli)"; then
		print_error "Hugging Face CLI not found. Run: local-model-helper.sh setup"
		return 2
	fi

	# If no specific filename, find matching GGUF file in the repo
	if [[ -z "$filename" ]]; then
		filename="$(_download_find_gguf "$repo" "$quant")" || return $?
		print_info "Found: ${filename}"
	fi

	print_info "Downloading ${filename} from ${repo}..."
	print_info "Destination: ${LOCAL_MODELS_STORE}/"

	# Current `hf` removed --local-dir-use-symlinks; retain it only when a
	# legacy CLI advertises support so older installations keep their behavior.
	local download_args=(download "$repo" "$filename" --local-dir "$LOCAL_MODELS_STORE")
	if [[ "$hf_cli" == "huggingface-cli" ]] &&
		"$hf_cli" download --help 2>&1 | grep -q -- '--local-dir-use-symlinks'; then
		download_args+=(--local-dir-use-symlinks False)
	fi
	if ! "$hf_cli" "${download_args[@]}" 2>&1; then
		print_error "Download failed"
		return 1
	fi

	# Verify the file exists
	local downloaded_path="${LOCAL_MODELS_STORE}/${filename}"
	if [[ -f "$downloaded_path" ]]; then
		local size_human size_bytes_dl
		size_bytes_dl="$(_file_size_bytes "$downloaded_path")"
		size_human="$(echo "$size_bytes_dl" | awk '{
			if ($1 >= 1073741824) printf "%.1f GB", $1/1073741824;
			else printf "%.0f MB", $1/1048576;
		}')"
		print_success "Downloaded: ${filename} (${size_human})"

		# Register in model inventory (t1338.5)
		local dl_quant
		dl_quant="$(echo "$filename" | grep -oiE '(q[0-9]_[a-z0-9_]+|iq[0-9]_[a-z0-9]+|f16|f32|bf16)' | head -1 | tr '[:lower:]' '[:upper:]')"
		register_model_inventory "$filename" "$downloaded_path" "$repo" "$size_bytes_dl" "$dl_quant"
	else
		print_success "Download complete (file may be in a subdirectory)"
	fi

	return 0
}

# =============================================================================
# Command: search
# =============================================================================

cmd_search() {
	local query=""
	local limit=10

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit)
			limit="$2"
			shift 2
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$query" ]]; then
				query="$1"
			else
				query="${query} $1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$query" ]]; then
		print_error "Search query is required"
		print_info "Usage: local-model-helper.sh search \"qwen3 8b\""
		return 1
	fi

	print_info "Searching HuggingFace for GGUF models: ${query}..."

	# URL-encode the query
	local encoded_query
	encoded_query="$(printf '%s' "$query" | sed 's/ /+/g')"

	local search_url="${HF_API}/models?search=${encoded_query}+gguf&filter=gguf&sort=downloads&direction=-1&limit=${limit}"
	local results
	results="$(curl -sL "$search_url" 2>/dev/null || echo "")"

	if [[ -z "$results" ]] || [[ "$results" == "[]" ]]; then
		print_info "No results found for: ${query}"
		print_info "Try broader terms or check HuggingFace directly"
		return 0
	fi

	if ! suppress_stderr command -v jq; then
		print_error "jq is required for search results parsing"
		echo "$results"
		return 0
	fi

	# Parse and display results
	printf "%-50s %12s %10s\n" "REPOSITORY" "DOWNLOADS" "UPDATED"
	printf "%-50s %12s %10s\n" "----------" "---------" "-------"

	echo "$results" | jq -r '.[] | [.modelId, (.downloads // 0 | tostring), (.lastModified // "-" | split("T")[0])] | @tsv' 2>/dev/null |
		while IFS=$'\t' read -r model_id downloads updated; do
			printf "%-50s %12s %10s\n" "$model_id" "$downloads" "$updated"
		done

	echo ""
	print_info "Download: local-model-helper.sh download <repo> --quant Q4_K_M"
	return 0
}
