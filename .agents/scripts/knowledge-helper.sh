#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-helper.sh — Knowledge plane provisioning for aidevops-managed repos
#
# Manages the _knowledge/ directory contract: creates directory trees, writes
# .gitignore rules, and maintains _config/knowledge.json defaults. Reads the
# knowledge mode from ~/.config/aidevops/repos.json (field: "knowledge").
#
# Usage:
#   knowledge-helper.sh provision [repo-path]                          Provision/repair directory tree
#   knowledge-helper.sh init [off|repo|personal] [path]                Set mode and provision
#   knowledge-helper.sh add <file|url> [--id <id>] [--sensitivity <tier>] [--allow-large]
#                                                                       Ingest a file or URL into sources/
#   knowledge-helper.sh folder [import] <directory> [--dry-run] [bounded options]
#   knowledge-helper.sh folder status <directory> [--json]              Import or inspect a folder snapshot
#   knowledge-helper.sh list [--state inbox|staging|sources|all] [--kind <type>]
#                                                                       List known sources
#   knowledge-helper.sh search <query> [--sensitivity <tier>] [--case <case-id>]
#                               [--status <draft-status>] [--repo-path <path>]
#                                                                       Search sources with tag-attribute filters
#   knowledge-helper.sh status [repo-path]                             Show provisioning state
#   knowledge-helper.sh help                                           Show this help
#
# Modes (stored in repos.json "knowledge" field):
#   off       No knowledge plane (default, backwards-compatible)
#   repo      _knowledge/ tree inside the repo
#   personal  Tree at ~/.aidevops/.agent-workspace/knowledge/
#
# Directory contract:
#   _knowledge/inbox/       Raw drops — gitignored, pre-review
#   _knowledge/staging/     Curated before commit — gitignored
#   _knowledge/sources/     Versioned originals (<=30MB)
#   _knowledge/index/       Generated search index — gitignored
#   _knowledge/collections/ Named curated subsets — versioned
#   _knowledge/_config/     knowledge.json defaults — versioned
#
# Blob threshold: files >=30MB go to ~/.aidevops/.agent-workspace/knowledge-blobs/
# with a hash pointer in meta.json instead of being stored in-repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=vault-storage-lib.sh
[[ -f "${SCRIPT_DIR}/vault-storage-lib.sh" ]] && source "${SCRIPT_DIR}/vault-storage-lib.sh"

# Guard color fallbacks when shared-constants.sh is absent
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Prefer print_* from shared-constants; define fallbacks only when absent.
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

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPOS_FILE="${REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
PERSONAL_PLANE_BASE="${PERSONAL_PLANE_BASE:-${HOME}/.aidevops/.agent-workspace/knowledge}"
KNOWLEDGE_ROOT="_knowledge"
KNOWLEDGE_CONFIG_SUBDIR="_config"
KNOWLEDGE_CONFIG_FILE="knowledge.json"
KNOWLEDGE_DIRS=(inbox staging sources index collections)
VAULT_COLLECTION_KNOWLEDGE="knowledge"

SCRIPT_TEMPLATES_DIR="${SCRIPT_DIR%/scripts}/templates"
GITIGNORE_TEMPLATE="${SCRIPT_TEMPLATES_DIR}/knowledge-gitignore.txt"
CONFIG_TEMPLATE="${SCRIPT_TEMPLATES_DIR}/knowledge-config.json"
SENSITIVITY_DETECTOR="${SCRIPT_DIR}/sensitivity-detector-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/knowledge-corpus-helper.sh"
SOURCE_CONTRACT_HELPER="${SCRIPT_DIR}/knowledge_source_contract.py"
FOLDER_IMPORT_HELPER="${SCRIPT_DIR}/knowledge_folder_import.py"
PERSONAL_CORPUS_ALIAS="personal:default"
KNOWLEDGE_MODE_PERSONAL="personal"
KNOWLEDGE_CAPABILITY_READ="knowledge.read"
BLOB_THRESHOLD_BYTES=31457280
META_DEFAULT_SENSITIVITY="internal"
META_DEFAULT_TRUST="unverified"
META_DEFAULT_KIND="document"

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

_get_knowledge_mode() {
	local repo_path="$1"
	_require_jq || return 1
	[[ ! -f "$REPOS_FILE" ]] && echo "off" && return 0
	local mode
	mode=$(jq -r --arg path "$repo_path" \
		'.initialized_repos[] | select(.path == $path) | .knowledge // "off"' \
		"$REPOS_FILE" 2>/dev/null | head -1)
	echo "${mode:-off}"
	return 0
}

_set_knowledge_mode() {
	local repo_path="$1"
	local mode="$2"
	_require_jq || return 1
	[[ ! -f "$REPOS_FILE" ]] && print_error "repos.json not found at $REPOS_FILE" && return 1
	case "$mode" in
	off | repo | personal) ;;
	*) print_error "Invalid mode: $mode (must be off|repo|personal)" && return 1 ;;
	esac
	local tmp_file
	tmp_file=$(mktemp)
	jq --arg path "$repo_path" --arg mode "$mode" \
		'(.initialized_repos[] | select(.path == $path)) |= . + {"knowledge": $mode}' \
		"$REPOS_FILE" >"$tmp_file"
	if ! jq . "$tmp_file" >/dev/null 2>&1; then
		print_error "JSON validation failed — repos.json not modified"
		rm -f "$tmp_file"
		return 1
	fi
	mv "$tmp_file" "$REPOS_FILE"
	print_success "Set knowledge=$mode for $repo_path in repos.json"
	return 0
}

_create_knowledge_tree() {
	local base_dir="$1"
	local knowledge_root="${base_dir}/${KNOWLEDGE_ROOT}"
	local config_dir="${knowledge_root}/${KNOWLEDGE_CONFIG_SUBDIR}"
	local dir
	for dir in "${KNOWLEDGE_DIRS[@]}"; do
		mkdir -p "${knowledge_root}/${dir}"
	done
	mkdir -p "$config_dir"
	return 0
}

_write_gitignore() {
	local knowledge_root="$1"
	local gitignore_path="${knowledge_root}/.gitignore"
	if [[ -f "$GITIGNORE_TEMPLATE" ]]; then
		cp "$GITIGNORE_TEMPLATE" "$gitignore_path"
	else
		cat >"$gitignore_path" <<'GITIGNORE'
# Knowledge plane — gitignore rules
# Generated by knowledge-helper.sh
#
# inbox/ and staging/ are pre-review zones — never version raw drops.
# sources/ is intentionally NOT ignored: versioned originals belong in git
# (for files <=30MB; larger originals use blob_path in meta.json).
# index/ contains generated artifacts — ignored by default.
# collections/ is versioned — remove from this file to ignore it too.

inbox/
staging/
index/
GITIGNORE
	fi
	return 0
}

_write_config() {
	local knowledge_root="$1"
	local config_path="${knowledge_root}/${KNOWLEDGE_CONFIG_SUBDIR}/${KNOWLEDGE_CONFIG_FILE}"
	if [[ -f "$CONFIG_TEMPLATE" ]]; then
		cp "$CONFIG_TEMPLATE" "$config_path"
	else
		# Minimal fallback — real config ships via CONFIG_TEMPLATE (knowledge-config.json).
		# Tier lists live in sensitivity.json; this fallback only sets defaults + policy.
		jq -n \
			--arg sens "$META_DEFAULT_SENSITIVITY" \
			--arg trust "$META_DEFAULT_TRUST" \
			'{version:2,sensitivity_default:$sens,trust_default:$trust,blob_threshold_bytes:31457280,sensitivity_schema:"_config/sensitivity.json",ingest_policy:{auto_sha256:true,require_meta:true,auto_sensitivity:true}}' \
			>"$config_path"
	fi
	return 0
}

_patch_repo_gitignore() {
	local repo_path="$1"
	local repo_gitignore="${repo_path}/.gitignore"
	local marker="# knowledge-plane-rules"
	if [[ -f "$repo_gitignore" ]] && grep -q "$marker" "$repo_gitignore" 2>/dev/null; then
		return 0
	fi
	{
		echo ""
		echo "${marker}"
		echo "_knowledge/inbox/"
		echo "_knowledge/staging/"
		echo "_knowledge/index/"
	} >>"$repo_gitignore"
	return 0
}

_is_provisioned() {
	local base_dir="$1"
	local knowledge_root="${base_dir}/${KNOWLEDGE_ROOT}"
	local dir
	[[ -d "$knowledge_root" ]] || return 1
	for dir in "${KNOWLEDGE_DIRS[@]}"; do
		[[ -d "${knowledge_root}/${dir}" ]] || return 1
	done
	[[ -f "${knowledge_root}/${KNOWLEDGE_CONFIG_SUBDIR}/${KNOWLEDGE_CONFIG_FILE}" ]] || return 1
	return 0
}

# ---------------------------------------------------------------------------
# Provision helpers (split to keep cmd_provision under 100 lines)
# ---------------------------------------------------------------------------

_provision_repo_plane() {
	local base_dir="$1"
	local repo_path="$2"
	if _is_provisioned "$base_dir"; then
		print_info "Knowledge plane already provisioned at ${base_dir}/${KNOWLEDGE_ROOT}"
	else
		print_info "Provisioning repo knowledge plane at ${base_dir}/${KNOWLEDGE_ROOT}..."
		_create_knowledge_tree "$base_dir"
		_write_gitignore "${base_dir}/${KNOWLEDGE_ROOT}"
		_write_config "${base_dir}/${KNOWLEDGE_ROOT}"
		_patch_repo_gitignore "$repo_path"
		print_success "Provisioned: ${base_dir}/${KNOWLEDGE_ROOT}"
	fi
	return 0
}

_provision_personal_plane() {
	local base_dir="$PERSONAL_PLANE_BASE"
	if _is_provisioned "$base_dir"; then
		print_info "Personal knowledge plane already provisioned at $base_dir"
	else
		print_info "Provisioning personal knowledge plane at $base_dir..."
		_create_knowledge_tree "$base_dir"
		_write_gitignore "${base_dir}/${KNOWLEDGE_ROOT}"
		_write_config "${base_dir}/${KNOWLEDGE_ROOT}"
		print_success "Provisioned: ${base_dir}/${KNOWLEDGE_ROOT}"
	fi
	if [[ ! -r "$CORPUS_HELPER" ]]; then
		print_error "Corpus catalog helper not found or not readable at $CORPUS_HELPER"
		return 1
	fi
	bash "$CORPUS_HELPER" provision --base "$base_dir" || return 1
	return 0
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_provision() {
	local repo_path="${1:-$(pwd)}"
	local mode
	repo_path="$(cd "$repo_path" && pwd)"
	mode=$(_get_knowledge_mode "$repo_path")
	case "$mode" in
	off)
		print_info "Knowledge mode is 'off' for $repo_path — skipping provision."
		;;
	repo)
		_provision_repo_plane "$repo_path" "$repo_path"
		;;
	personal)
		_provision_personal_plane || return 1
		;;
	*)
		print_error "Unknown knowledge mode '$mode' for $repo_path"
		return 1
		;;
	esac
	return 0
}

_prompt_knowledge_mode() {
	echo ""
	echo "Choose mode:"
	echo "  1) repo     — _knowledge/ lives inside this repo"
	echo "  2) personal — knowledge lives at ~/.aidevops/.agent-workspace/knowledge/"
	echo "  3) off      — disable knowledge plane"
	echo ""
	local choice
	read -r -p "Mode [1/2/3]: " choice
	case "$choice" in
	1) echo "repo" ;;
	2) echo "personal" ;;
	3) echo "off" ;;
	*) echo "" ;;
	esac
	return 0
}

cmd_init() {
	local mode="${1:-}"
	local repo_path="${2:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	if [[ -z "$mode" ]]; then
		echo ""
		echo "Knowledge plane init for: $repo_path"
		mode=$(_prompt_knowledge_mode)
		if [[ -z "$mode" ]]; then
			print_error "Invalid choice"
			return 1
		fi
	fi
	case "$mode" in
	off | repo | personal) ;;
	*) print_error "Invalid mode: $mode (must be off|repo|personal)" && return 1 ;;
	esac
	_set_knowledge_mode "$repo_path" "$mode" || return 1
	if [[ "$mode" != "off" ]]; then
		cmd_provision "$repo_path"
	fi
	return 0
}

_print_status_dirs() {
	local base_dir="$1"
	local dir count full
	for dir in "${KNOWLEDGE_DIRS[@]}"; do
		full="${base_dir}/${KNOWLEDGE_ROOT}/${dir}"
		count=0
		if [[ -d "$full" ]]; then
			count=$(find "$full" -maxdepth 1 -not -name '.' | wc -l | tr -d ' ')
		fi
		printf "    %-12s %s items\n" "${dir}/" "$count"
	done
	return 0
}

cmd_status() {
	local repo_path="${1:-$(pwd)}"
	repo_path="$(cd "$repo_path" && pwd)"
	local mode
	mode=$(_get_knowledge_mode "$repo_path")
	echo ""
	echo "Knowledge plane status for: $repo_path"
	echo "  Mode: $mode"
	case "$mode" in
	off)
		echo "  State: disabled"
		;;
	repo)
		if _is_provisioned "$repo_path"; then
			echo "  State: provisioned (${repo_path}/${KNOWLEDGE_ROOT})"
			_print_status_dirs "$repo_path"
		else
			echo "  State: not provisioned (run: aidevops knowledge init repo)"
		fi
		;;
	personal)
		if _is_provisioned "$PERSONAL_PLANE_BASE"; then
			echo "  State: provisioned (${PERSONAL_PLANE_BASE}/${KNOWLEDGE_ROOT})"
		else
			echo "  State: not provisioned (run: aidevops knowledge init personal)"
		fi
		;;
	esac
	echo ""
	return 0
}

_sha256sum_file() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
	else
		print_error "sha256sum/shasum not found — cannot compute hash"
		return 1
	fi
	return 0
}

_slugify() {
	local input="$1"
	echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//; s/-$//'
	return 0
}

_write_meta_json() {
	local meta_path="$1"
	local source_id="$2"
	local source_uri="$3"
	local sha256="$4"
	local size_bytes="$5"
	local sensitivity="$6"
	local blob_path="${7:-null}"
	local corpus_id="${8:-repo:default}"
	if [[ ! -r "$SOURCE_CONTRACT_HELPER" ]]; then
		print_error "Knowledge source contract helper is unavailable"
		return 1
	fi
	local ts blob_ref
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
	blob_ref="$blob_path"
	[[ "$blob_path" != "null" ]] && blob_ref="knowledge-blobs:sha256:${sha256}"
	python3 "$SOURCE_CONTRACT_HELPER" source-meta \
		--source-id "$source_id" \
		--corpus-id "$corpus_id" \
		--source-uri "$source_uri" \
		--sha256 "$sha256" \
		--size-bytes "$size_bytes" \
		--kind "$META_DEFAULT_KIND" \
		--sensitivity "$sensitivity" \
		--trust "$META_DEFAULT_TRUST" \
		--ingested-at "$ts" \
		--blob-ref "$blob_ref" >"$meta_path" || return 1
	return 0
}

_find_source_by_sha256() {
	local knowledge_root="$1"
	local sha256="$2"
	local meta_path=""
	for meta_path in "$knowledge_root"/sources/*/meta.json; do
		[[ -f "$meta_path" && ! -L "$meta_path" ]] || continue
		if jq -e --arg sha "$sha256" '.sha256 == $sha' "$meta_path" >/dev/null 2>&1; then
			jq -r '.id' "$meta_path"
			return 0
		fi
	done
	return 1
}

# _cmd_add_resolve_knowledge_root: resolve knowledge_root from mode, echoes root path
# Prints error and returns 1 on failure.
_cmd_add_resolve_knowledge_root() {
	local repo_path="$1"
	local capability="${2:-knowledge.write}"
	local mode
	mode=$(_get_knowledge_mode "$repo_path")
	case "$mode" in
	repo)
		echo "${repo_path}/${KNOWLEDGE_ROOT}"
		;;
	personal)
		if [[ ! -r "$CORPUS_HELPER" ]]; then
			print_error "Corpus catalog helper not found or not readable at $CORPUS_HELPER"
			return 1
		fi
		bash "$CORPUS_HELPER" resolve \
			--base "$PERSONAL_PLANE_BASE" \
			--alias "$PERSONAL_CORPUS_ALIAS" \
			--capability "$capability" || return 1
		;;
	off)
		print_error "Knowledge plane is disabled for $repo_path — run: knowledge-helper.sh init repo"
		return 1
		;;
	*)
		print_error "Unknown knowledge mode: $mode"
		return 1
		;;
	esac
	return 0
}

# _cmd_add_store_file: copy file into source_dir or blob store; echoes blob_path or "null"
# Args: <file_path> <source_id> <source_dir> <size_bytes> <repo_path>
_cmd_add_store_file() {
	local file_path="$1"
	local source_id="$2"
	local source_dir="$3"
	local size_bytes="$4"
	local repo_path="$5"
	if [[ "$size_bytes" -ge "$BLOB_THRESHOLD_BYTES" ]]; then
		local repo_name
		repo_name="$(basename "$repo_path")"
		local blob_dir="${HOME}/.aidevops/.agent-workspace/knowledge-blobs/${repo_name}/${source_id}"
		mkdir -p "$blob_dir"
		local blob_path
		blob_path="${blob_dir}/$(basename "$file_path")"
		cp "$file_path" "$blob_path"
		print_info "Large file (${size_bytes}B) stored at blob path: $blob_path"
		echo "$blob_path"
	else
		cp "$file_path" "${source_dir}/$(basename "$file_path")"
		echo "null"
	fi
	return 0
}

# _cmd_add_apply_sensitivity: run detector + optional override; prints final tier
# Args: <source_id> <knowledge_root> <meta_path> <sensitivity_override>
_cmd_add_apply_sensitivity() {
	local source_id="$1"
	local knowledge_root="$2"
	local meta_path="$3"
	local sensitivity_override="$4"
	if [[ -x "$SENSITIVITY_DETECTOR" ]]; then
		local detected_tier
		detected_tier=$(bash "$SENSITIVITY_DETECTOR" classify "$source_id" \
			--knowledge-root "$knowledge_root" 2>/dev/null | tail -1 || echo "$META_DEFAULT_SENSITIVITY")
		print_info "[$source_id] auto-detected sensitivity: $detected_tier"
	else
		print_warning "sensitivity-detector-helper.sh not found at $SENSITIVITY_DETECTOR — skipping auto-classify"
	fi
	if [[ -n "$sensitivity_override" ]]; then
		if [[ -x "$SENSITIVITY_DETECTOR" ]]; then
			bash "$SENSITIVITY_DETECTOR" override "$source_id" "$sensitivity_override" \
				--reason "user-provided via --sensitivity flag" \
				--knowledge-root "$knowledge_root" >/dev/null 2>&1 || true
		else
			local tmp
			tmp=$(mktemp)
			if jq --arg t "$sensitivity_override" '.sensitivity = $t' "$meta_path" >"$tmp" 2>/dev/null; then
				mv "$tmp" "$meta_path"
			else
				rm -f "$tmp"
			fi
		fi
		print_info "[$source_id] sensitivity overridden to: $sensitivity_override"
	fi
	jq -r --arg def "$META_DEFAULT_SENSITIVITY" '.sensitivity // $def' "$meta_path" 2>/dev/null || echo "$META_DEFAULT_SENSITIVITY"
	return 0
}

# _cmd_add_download_url: download a URL to inbox dir; prints local path or exits 1
# Args: <url> <inbox_dir> <allow_large>
_cmd_add_download_url() {
	local url="$1"
	local inbox_dir="$2"
	local allow_large="$3"
	if ! command -v curl >/dev/null 2>&1; then
		print_error "curl is required to download URLs but is not installed"
		return 1
	fi
	local filename
	filename="$(basename "$url")"
	filename="${filename%%\?*}"
	[[ -z "$filename" || "$filename" == "/" ]] && filename="download-$(date +%s)"
	local dest_path="${inbox_dir}/${filename}"
	mkdir -p "$inbox_dir"
	local curl_args=("-L" "-o" "$dest_path" "--fail" "--silent" "--show-error")
	if [[ "$allow_large" -eq 0 ]]; then
		curl_args+=("--max-filesize" "$BLOB_THRESHOLD_BYTES")
	fi
	print_info "Downloading: $url"
	if ! curl "${curl_args[@]}" "$url" 2>&1; then
		rm -f "$dest_path"
		if [[ "$allow_large" -eq 0 ]]; then
			print_error "Download failed (file may exceed ${BLOB_THRESHOLD_BYTES}B limit). Use --allow-large to permit large files."
		else
			print_error "Download failed: $url"
		fi
		return 1
	fi
	echo "$dest_path"
	return 0
}

# _cmd_add_route_email: check if file is .eml/.emlx and route to email handler
# Returns 0 and exits early if routed, returns 1 to fall through to generic path
# Args: <file_path> <repo_path> <sensitivity_override>
_cmd_add_route_email() {
	local file_path="$1"
	local repo_path="$2"
	local sensitivity_override="$3"
	local _ext="${file_path##*.}"
	_ext=$(echo "$_ext" | tr '[:upper:]' '[:lower:]')
	if [[ "$_ext" == "eml" || "$_ext" == "emlx" ]]; then
		local _email_helper="${SCRIPT_DIR}/email-ingest-helper.sh"
		if [[ -x "$_email_helper" ]]; then
			local _email_args=("ingest" "$file_path" "--repo-path" "$repo_path")
			[[ -n "$sensitivity_override" ]] && _email_args+=("--sensitivity" "$sensitivity_override")
			bash "$_email_helper" "${_email_args[@]}"
			return 0
		else
			print_warning "email-ingest-helper.sh not found — falling back to generic ingestion"
		fi
	fi
	return 1
}

_cmd_add_commit_source() {
	local file_path="$1"
	local source_id="$2"
	local knowledge_root="$3"
	local size_bytes="$4"
	local repo_path="$5"
	local source_uri="$6"
	local sha256="$7"
	local tmp_inbox_file="$8"
	local sensitivity_override="${9:-}"
	local source_dir="${knowledge_root}/sources/${source_id}"
	if [[ -d "$source_dir" ]]; then
		source_id="${source_id}-$(date +%s)"
		source_dir="${knowledge_root}/sources/${source_id}"
	fi
	local staging_dir="${knowledge_root}/sources/.${source_id}.staging.$$"
	mkdir "$staging_dir" || return 1
	local blob_path
	if ! blob_path=$(_cmd_add_store_file "$file_path" "$source_id" "$staging_dir" "$size_bytes" "$repo_path"); then
		rm -rf "$staging_dir"
		return 1
	fi
	local meta_path="${staging_dir}/meta.json"
	local corpus_id="repo:default"
	[[ "$(_get_knowledge_mode "$repo_path")" == "$KNOWLEDGE_MODE_PERSONAL" ]] && corpus_id="$PERSONAL_CORPUS_ALIAS"
	if ! _write_meta_json "$meta_path" "$source_id" "$source_uri" "$sha256" "$size_bytes" "$META_DEFAULT_SENSITIVITY" "$blob_path" "$corpus_id"; then
		rm -rf "$staging_dir"
		return 1
	fi
	if ! mv "$staging_dir" "$source_dir"; then
		rm -rf "$staging_dir"
		return 1
	fi
	# Clean up inbox transit only after the canonical directory commit succeeds.
	[[ -n "$tmp_inbox_file" && -f "$tmp_inbox_file" ]] && rm -f "$tmp_inbox_file"
	meta_path="${source_dir}/meta.json"
	local final_tier
	final_tier=$(_cmd_add_apply_sensitivity "$source_id" "$knowledge_root" "$meta_path" "$sensitivity_override") || true
	print_success "Added source: $source_id (sensitivity=${final_tier})"
	return 0
}

# cmd_add: ingest a file or URL into the knowledge plane sources/ directory
# Arguments: <file|url> [--id <id>] [--sensitivity <tier>] [--allow-large] [--repo-path <path>]
cmd_add() {
	local input_path=""
	local source_id=""
	local sensitivity_override=""
	local allow_large=0
	local repo_path
	repo_path="$(pwd)"
	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--id)
			local _v="$1"
			source_id="$_v"
			shift
			;;
		--sensitivity)
			local _s="$1"
			sensitivity_override="$_s"
			shift
			;;
		--repo-path)
			local _rp="$1"
			repo_path="$_rp"
			shift
			;;
		--allow-large)
			allow_large=1
			;;
		-*)
			print_error "Unknown option: $_key"
			return 1
			;;
		*)
			[[ -z "$input_path" ]] && input_path="$_key"
			;;
		esac
	done
	if [[ -z "$input_path" ]]; then
		print_error "add requires <file|url>"
		return 1
	fi
	repo_path="$(cd "$repo_path" && pwd)"
	local knowledge_root
	knowledge_root=$(_cmd_add_resolve_knowledge_root "$repo_path" "knowledge.write") || return 1
	if ! _is_provisioned "${knowledge_root%/"$KNOWLEDGE_ROOT"}"; then
		print_error "Knowledge plane not provisioned. Run: knowledge-helper.sh provision"
		return 1
	fi
	# Determine source_uri and resolve file_path (download URL to inbox if needed)
	local file_path source_uri tmp_inbox_file=""
	if [[ "$input_path" =~ ^https?:// ]]; then
		local inbox_dir="${knowledge_root}/inbox"
		local downloaded
		downloaded=$(_cmd_add_download_url "$input_path" "$inbox_dir" "$allow_large") || return 1
		file_path="$downloaded"
		source_uri="$input_path"
		tmp_inbox_file="$file_path"
	else
		if [[ ! -f "$input_path" ]]; then
			print_error "File not found: $input_path"
			return 1
		fi
		file_path="$input_path"
		local abs_file_path
		abs_file_path="$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")"
		source_uri="file://${abs_file_path}"
	fi
	# Route .eml/.emlx files through the dedicated email ingestion handler
	if _cmd_add_route_email "$file_path" "$repo_path" "$sensitivity_override"; then
		return 0
	fi
	# Derive source_id from filename if not specified
	if [[ -z "$source_id" ]]; then
		local basename_no_ext
		basename_no_ext="$(basename "$file_path")"
		basename_no_ext="${basename_no_ext%.*}"
		source_id=$(_slugify "$basename_no_ext")
		[[ ${#source_id} -lt 3 ]] && source_id="source-$(date +%s)"
	fi
	if [[ ! "$source_id" =~ ^[a-z0-9][a-z0-9-]{2,79}$ ]]; then
		[[ -n "$tmp_inbox_file" && -f "$tmp_inbox_file" ]] && rm -f "$tmp_inbox_file"
		print_error "Source ID must be a 3-80 character lowercase kebab identifier"
		return 1
	fi
	local sha256 size_bytes existing_source_id=""
	sha256=$(_sha256sum_file "$file_path") || return 1
	size_bytes=$(wc -c <"$file_path" | tr -d ' ')
	existing_source_id=$(_find_source_by_sha256 "$knowledge_root" "$sha256") || true
	if [[ -n "$existing_source_id" ]]; then
		[[ -n "$tmp_inbox_file" && -f "$tmp_inbox_file" ]] && rm -f "$tmp_inbox_file"
		print_success "Source already canonical: $existing_source_id"
		return 0
	fi
	_cmd_add_commit_source "$file_path" "$source_id" "$knowledge_root" "$size_bytes" \
		"$repo_path" "$source_uri" "$sha256" "$tmp_inbox_file" "$sensitivity_override"
	return $?
}

# cmd_folder: recursively inventory/import a bounded folder or show its latest manifest.
# Arguments: [import|status] <directory> [folder options] [--repo-path <path>]
cmd_folder() {
	local action="import"
	local first_arg="${1:-}"
	if [[ "$first_arg" == "import" || "$first_arg" == "status" ]]; then
		action="$first_arg"
		shift
	fi
	local repo_path
	repo_path="$(pwd)"
	local forwarded=()
	while [[ $# -gt 0 ]]; do
		local key="$1"
		shift
		if [[ "$key" == "--repo-path" ]]; then
			if [[ $# -eq 0 ]]; then
				print_error "--repo-path requires a path"
				return 1
			fi
			local requested_repo="$1"
			repo_path="$requested_repo"
			shift
		else
			forwarded+=("$key")
		fi
	done
	if [[ ${#forwarded[@]} -eq 0 ]]; then
		print_error "folder ${action} requires <directory>"
		return 1
	fi
	if [[ ! -r "$FOLDER_IMPORT_HELPER" ]]; then
		print_error "Folder import helper is unavailable"
		return 1
	fi
	repo_path="$(cd "$repo_path" && pwd)"
	local capability="knowledge.write"
	[[ "$action" == "status" ]] && capability="$KNOWLEDGE_CAPABILITY_READ"
	local knowledge_root
	knowledge_root=$(_cmd_add_resolve_knowledge_root "$repo_path" "$capability") || return 1
	if [[ ! -d "${knowledge_root}/sources" ]]; then
		print_error "Knowledge plane not provisioned. Run: knowledge-helper.sh provision"
		return 1
	fi
	local corpus_id="repo:default"
	[[ "$(_get_knowledge_mode "$repo_path")" == "$KNOWLEDGE_MODE_PERSONAL" ]] && corpus_id="$PERSONAL_CORPUS_ALIAS"
	python3 "$FOLDER_IMPORT_HELPER" "$action" "${forwarded[@]}" \
		--knowledge-root "$knowledge_root" --scripts-dir "$SCRIPT_DIR" --corpus-id "$corpus_id"
	return $?
}

# ---------------------------------------------------------------------------
# list: show sources across inbox/staging/sources with state column
# ---------------------------------------------------------------------------

# _state_matches: returns 0 when filter is "all" or equals state_name
_state_matches() {
	local filter="$1"
	local state_name="$2"
	[[ "$filter" == "all" ]] || [[ "$filter" == "$state_name" ]]
	return $?
}

# _list_print_meta: pretty-print one meta.json with state label
# Args: <meta_path> <state_label> [kind_filter]
_list_print_meta() {
	local meta_path="$1"
	local state_label="$2"
	local kind_filter="${3:-}"
	_require_jq || return 1
	[[ ! -f "$meta_path" ]] && return 0
	local _def="unknown"
	local kind
	kind=$(jq -r --arg d "$_def" '.kind // $d' "$meta_path" 2>/dev/null || echo "$_def")
	[[ -n "$kind_filter" && "$kind" != "$kind_filter" ]] && return 1
	local id sha256 sensitivity size_bytes
	id=$(jq -r --arg d "$_def" '.id // $d' "$meta_path" 2>/dev/null || echo "$_def")
	sha256=$(jq -r '.sha256 // ""' "$meta_path" 2>/dev/null || echo "")
	sensitivity=$(jq -r --arg d "$_def" '.sensitivity // $d' "$meta_path" 2>/dev/null || echo "$_def")
	size_bytes=$(jq -r '.size_bytes // 0' "$meta_path" 2>/dev/null || echo "0")
	local sha_short="${sha256:0:8}"
	printf "%-36s %-10s %-12s %-12s %s  %s\n" \
		"$id" "$state_label" "$kind" "$sensitivity" "$sha_short" "$size_bytes"
	return 0
}

cmd_list() {
	local state_filter="all"
	local kind_filter=""
	local repo_path
	repo_path="$(pwd)"
	while [[ $# -gt 0 ]]; do
		local _key="$1"
		shift
		case "$_key" in
		--state)
			local _st="$1"
			state_filter="$_st"
			shift
			;;
		--kind)
			local _kd="$1"
			kind_filter="$_kd"
			shift
			;;
		--repo-path)
			local _rp="$1"
			repo_path="$_rp"
			shift
			;;
		*)
			print_error "Unknown option: $_key"
			return 1
			;;
		esac
	done
	repo_path="$(cd "$repo_path" && pwd)"
	_require_jq || return 1
	local knowledge_root
	knowledge_root=$(_cmd_add_resolve_knowledge_root "$repo_path" "$KNOWLEDGE_CAPABILITY_READ") || return 1
	# Print header
	printf "%-36s %-10s %-12s %-12s %-8s  %s\n" \
		"SOURCE-ID" "STATE" "KIND" "SENSITIVITY" "SHA256" "SIZE"
	printf '%s\n' "$(printf -- '-%.0s' {1..90})"
	local found=0
	# inbox
	if _state_matches "$state_filter" "inbox"; then
		local inbox_dir="${knowledge_root}/inbox"
		if [[ -d "$inbox_dir" ]]; then
			local src_id
			for src_id in $(ls "$inbox_dir" 2>/dev/null | sort); do
				local meta="${inbox_dir}/${src_id}/meta.json"
				[[ -f "$meta" ]] || continue
				if _list_print_meta "$meta" "inbox" "$kind_filter"; then
					found=$((found + 1))
				fi
			done
		fi
	fi
	# staging
	if _state_matches "$state_filter" "staging"; then
		local staging_dir="${knowledge_root}/staging"
		if [[ -d "$staging_dir" ]]; then
			local src_id
			for src_id in $(ls "$staging_dir" 2>/dev/null | sort); do
				local meta="${staging_dir}/${src_id}/meta.json"
				[[ -f "$meta" ]] || continue
				if _list_print_meta "$meta" "staging" "$kind_filter"; then
					found=$((found + 1))
				fi
			done
		fi
	fi
	# sources
	if _state_matches "$state_filter" "sources"; then
		local sources_dir="${knowledge_root}/sources"
		if [[ -d "$sources_dir" ]]; then
			local src_id
			for src_id in $(ls "$sources_dir" 2>/dev/null | sort); do
				local meta="${sources_dir}/${src_id}/meta.json"
				[[ -f "$meta" ]] || continue
				if _list_print_meta "$meta" "sources" "$kind_filter"; then
					found=$((found + 1))
				fi
			done
		fi
	fi
	if [[ "$found" -eq 0 ]]; then
		print_info "No sources found (state=${state_filter}${kind_filter:+, kind=$kind_filter})"
	fi
	return 0
}

# cmd_sensitivity: proxy to sensitivity-detector-helper.sh for override/show/classify
cmd_sensitivity() {
	if [[ ! -x "$SENSITIVITY_DETECTOR" ]]; then
		print_error "sensitivity-detector-helper.sh not found at $SENSITIVITY_DETECTOR"
		return 1
	fi
	bash "$SENSITIVITY_DETECTOR" "$@"
	return 0
}

# cmd_enrich: proxy to document-enrich-helper.sh for structured field extraction
# Usage: knowledge-helper.sh enrich <source-id> [--kind <override>] [--max-cost <USD>]
cmd_enrich() {
	local enrich_helper="${SCRIPT_DIR}/document-enrich-helper.sh"
	if [[ ! -x "$enrich_helper" ]]; then
		print_error "document-enrich-helper.sh not found at $enrich_helper"
		return 1
	fi
	bash "$enrich_helper" enrich "$@"
	return 0
}

cmd_help() {
	sed -n '4,34p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ---------------------------------------------------------------------------
# source.md backwards-compat reader helpers (t2971)
# Prefer source.md (Markdoc-tagged layout) over text.txt when both exist.
# ---------------------------------------------------------------------------

# _get_source_text_file <source-dir>
# Prints the path to the best available text content file.
# Returns source.md if present (Markdoc-tagged layout, t2971),
# falls back to text.txt (P0a layout), or empty string if neither exists.
_get_source_text_file() {
	local source_dir="$1"
	local source_md="${source_dir}/source.md"
	local text_txt="${source_dir}/text.txt"
	if [[ -f "$source_md" ]]; then
		printf '%s\n' "$source_md"
	elif [[ -f "$text_txt" ]]; then
		printf '%s\n' "$text_txt"
	fi
	return 0
}

# _grep_source_file <query> <source-file>
# Searches source-file for query (case-insensitive).  When source-file is a
# .md (source.md), Markdoc tags are stripped before matching so tags are not
# treated as content.  Prints matching lines to stdout; exits 1 on no match.
_grep_source_file() {
	local query="$1"
	local src_file="$2"
	if [[ "$src_file" == *.md ]]; then
		# Strip {% ... %} Markdoc tag patterns before grepping
		sed 's/{%[^%]*%}//g' "$src_file" 2>/dev/null | grep -i "$query" 2>/dev/null
	else
		grep -i "$query" "$src_file" 2>/dev/null
	fi
	return $?
}

# ---------------------------------------------------------------------------
# Search filter helpers (t2977 Phase 6)
# Each helper echoes newline-separated source IDs matching the filter.
# Returns 0 (even when empty — no match is not an error).
# ---------------------------------------------------------------------------

# _search_ids_by_sensitivity <sources_dir> <tier>
# Returns source IDs whose meta.json .sensitivity matches <tier>.
_search_ids_by_sensitivity() {
	local sources_dir="$1" tier="$2"
	_require_jq || return 1
	find "$sources_dir" -maxdepth 2 -name "meta.json" \
		-exec jq -r --arg tier "$tier" --arg def "$META_DEFAULT_SENSITIVITY" \
		'select((.sensitivity // $def) == $tier) | (.id // empty)' {} + 2>/dev/null |
		sort || true
	return 0
}

# _search_ids_by_case <repo_path> <case_id>
# Returns source IDs attached to a case via its sources.toon registry.
_search_ids_by_case() {
	local repo_path="$1" case_id="$2"
	_require_jq || return 1
	local cases_dir="${repo_path}/_cases"
	local case_dir=""
	# Direct match
	[[ -d "${cases_dir}/${case_id}" ]] && case_dir="${cases_dir}/${case_id}"
	# Prefix/slug match
	if [[ -z "$case_dir" ]]; then
		local _d
		for _d in "${cases_dir}"/case-*-"${case_id}" "${cases_dir}"/case-*-*"${case_id}"*; do
			[[ -d "$_d" ]] || continue
			[[ "$_d" == *"/archived/"* ]] && continue
			case_dir="$_d"
			break
		done
	fi
	if [[ -z "$case_dir" ]]; then
		print_warning "search --case: case '${case_id}' not found"
		return 0
	fi
	local sources_toon="${case_dir}/sources.toon"
	[[ -f "$sources_toon" ]] || return 0
	jq -r '.[].id' "$sources_toon" 2>/dev/null || true
	return 0
}

# _search_ids_by_status <sources_dir> <draft_status>
# Returns source IDs whose source.md has a draft-status tag matching <draft_status>.
_search_ids_by_status() {
	local sources_dir="$1" draft_status="$2"
	# Match Markdoc draft-status tag: {% draft-status status="<value>" ... %}
	local pattern="\\{%\\s*draft-status\\b[^%]*status\\s*=\\s*[\"']?${draft_status}[\"']?"
	find "$sources_dir" -maxdepth 2 -name "source.md" \
		-exec grep -liE "$pattern" {} + 2>/dev/null |
		sed 's|/source.md$||; s|.*/||' |
		sort || true
	return 0
}

# _search_compute_allowed_ids <sources_dir> <repo_path> <sensitivity> <case_id> <status>
# Intersects ID sets from all active filters. Echoes newline-separated IDs.
# An empty filter value means "no filter on this dimension".
# Empty result when filters conflict (intersection is empty set).
_search_compute_allowed_ids() {
	local sources_dir="$1" repo_path="$2"
	local filter_sensitivity="$3" filter_case="$4" filter_status="$5"
	local all_ids="" active_filter=0

	if [[ -n "$filter_sensitivity" ]]; then
		local sens_ids
		sens_ids=$(_search_ids_by_sensitivity "$sources_dir" "$filter_sensitivity") || sens_ids=""
		if [[ $active_filter -eq 0 ]]; then
			all_ids="$sens_ids"
		else
			all_ids=$(comm -12 \
				<(echo "$all_ids" | sort) \
				<(echo "$sens_ids" | sort))
		fi
		active_filter=1
	fi

	if [[ -n "$filter_case" ]]; then
		local case_ids
		case_ids=$(_search_ids_by_case "$repo_path" "$filter_case") || case_ids=""
		if [[ $active_filter -eq 0 ]]; then
			all_ids="$case_ids"
		else
			all_ids=$(comm -12 \
				<(echo "$all_ids" | sort) \
				<(echo "$case_ids" | sort))
		fi
		active_filter=1
	fi

	if [[ -n "$filter_status" ]]; then
		local status_ids
		status_ids=$(_search_ids_by_status "$sources_dir" "$filter_status") || status_ids=""
		if [[ $active_filter -eq 0 ]]; then
			all_ids="$status_ids"
		else
			all_ids=$(comm -12 \
				<(echo "$all_ids" | sort) \
				<(echo "$status_ids" | sort))
		fi
		active_filter=1
	fi

	echo "$all_ids"
	return 0
}

# _search_grep_sources <sources_dir> <query> <allowed_ids> <filters_active>
# Grep for <query> across sources in <sources_dir>, filtered to <allowed_ids>
# when <filters_active> is 1.  Outputs JSON per-match line to stdout.
_search_grep_sources() {
	local sources_dir="$1" query="$2" allowed_ids="$3" filters_active="$4"
	local found=0 src_id
	for src_id in $(ls "$sources_dir" 2>/dev/null | sort); do
		if [[ $filters_active -eq 1 ]]; then
			echo "$allowed_ids" | grep -qxF "$src_id" 2>/dev/null || continue
		fi
		local src_file
		src_file=$(_get_source_text_file "${sources_dir}/${src_id}")
		[[ -z "$src_file" ]] && continue
		local match_lines
		match_lines=$(_grep_source_file "$query" "$src_file" || true)
		if [[ -n "$match_lines" ]]; then
			local excerpt
			excerpt="${match_lines%%$'\n'*}"
			printf '{"source_id":"%s","excerpt":"%s"}\n' \
				"$src_id" "${excerpt:0:200}"
			found=$((found + 1))
		fi
	done
	[[ "$found" -eq 0 ]] && print_info "search: no matches for '${query}'"
	return 0
}

# ---------------------------------------------------------------------------
# search: keyword search across knowledge sources
# Routes to knowledge-index-helper.sh query when corpus tree exists;
# falls back to grep over source.md (preferred) or text.txt files otherwise.
# ---------------------------------------------------------------------------

_cmd_search_resolve_knowledge_root() {
	local repo_path="$1"
	local mode
	mode=$(_get_knowledge_mode "$repo_path")
	case "$mode" in
	repo) printf '%s\n' "${repo_path}/${KNOWLEDGE_ROOT}" ;;
	personal) _cmd_add_resolve_knowledge_root "$repo_path" "$KNOWLEDGE_CAPABILITY_READ" || return 1 ;;
	off) print_warning "search: knowledge plane is disabled for $repo_path" >&2 ;;
	*)
		print_error "search: unknown knowledge mode '$mode' for $repo_path" >&2
		return 1
		;;
	esac
	return 0
}

cmd_search() {
	# Flag-based invocation (preferred):
	#   cmd_search [--sensitivity <tier>] [--case <id>] [--status <ds>]
	#              [--repo-path <path>] <query>
	# Legacy positional: cmd_search <query> [repo_path]
	local query="" repo_path="" filter_sensitivity="" filter_case="" filter_status=""

	# Parse flags and positional args in any order.
	# First non-flag arg is the query; second non-flag arg (legacy) is repo_path.
	local _positional_count=0
	while [[ $# -gt 0 ]]; do
		local _opt="$1"
		local _nxt="${2:-}"
		shift
		case "$_opt" in
		--sensitivity)
			filter_sensitivity="$_nxt"
			shift
			;;
		--case)
			filter_case="$_nxt"
			shift
			;;
		--status)
			filter_status="$_nxt"
			shift
			;;
		--repo-path)
			repo_path="$_nxt"
			shift
			;;
		-*)
			print_error "search: unknown option: $_opt"
			return 1
			;;
		*)
			if [[ $_positional_count -eq 0 ]]; then
				query="$_opt"
			elif [[ $_positional_count -eq 1 && -z "$repo_path" ]]; then
				repo_path="$_opt"
			fi
			_positional_count=$((_positional_count + 1))
			;;
		esac
	done

	[[ -z "$repo_path" ]] && repo_path="$(pwd)"
	repo_path="$(cd "$repo_path" && pwd)"

	if [[ -z "$query" ]]; then
		print_error "search: query string is required"
		return 1
	fi

	local knowledge_root=""
	knowledge_root=$(_cmd_search_resolve_knowledge_root "$repo_path") || return 1
	[[ -z "$knowledge_root" ]] && return 0

	local sources_dir="${knowledge_root}/sources"
	# Compute allowed source IDs for active filters.
	# filters_active=1 means at least one filter flag was set.
	# When filters_active=1 and allowed_ids is empty, no sources qualify.
	local allowed_ids="" filters_active=0
	if [[ -n "$filter_sensitivity" || -n "$filter_case" || -n "$filter_status" ]]; then
		filters_active=1
		allowed_ids=$(_search_compute_allowed_ids \
			"$sources_dir" "$repo_path" \
			"$filter_sensitivity" "$filter_case" "$filter_status") || allowed_ids=""
	fi

	local corpus_tree="${knowledge_root}/index/tree.json"
	local index_helper="${SCRIPT_DIR}/knowledge-index-helper.sh"

	if [[ -f "$corpus_tree" && -f "$index_helper" ]]; then
		# Route to tree-walk when corpus index exists.
		# When filters active and no IDs qualify, skip without calling index.
		if [[ $filters_active -eq 1 && -z "$allowed_ids" ]]; then
			print_info "search: no sources match active filters"
			return 0
		fi
		print_info "search: routing to knowledge-index-helper query (corpus tree found)"
		KNOWLEDGE_ROOT="$knowledge_root" KNOWLEDGE_SCOPE_IDS="$allowed_ids" \
			bash "$index_helper" query "$query"
		return 0
	fi

	# Fallback: grep source.md (preferred) or text.txt files in sources/
	if [[ ! -d "$sources_dir" ]]; then
		print_warning "search: no sources directory found at $sources_dir"
		return 0
	fi
	# When filters active but no IDs qualify, return early without grep loop.
	if [[ $filters_active -eq 1 && -z "$allowed_ids" ]]; then
		print_info "search: no sources match active filters"
		return 0
	fi
	print_info "search: no corpus tree — falling back to grep in sources/"
	_search_grep_sources "$sources_dir" "$query" "$allowed_ids" "$filters_active"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local subcommand="${1:-help}"
	shift || true
	case "$subcommand" in
	provision) cmd_provision "$@" ;;
	init) cmd_init "$@" ;;
	add) vault_storage_require_unlocked "$VAULT_COLLECTION_KNOWLEDGE" && cmd_add "$@" ;;
	folder) vault_storage_require_unlocked "$VAULT_COLLECTION_KNOWLEDGE" && cmd_folder "$@" ;;
	list) vault_storage_require_unlocked "$VAULT_COLLECTION_KNOWLEDGE" && cmd_list "$@" ;;
	sensitivity) cmd_sensitivity "$@" ;;
	enrich) cmd_enrich "$@" ;;
	status) cmd_status "$@" ;;
	search) vault_storage_require_unlocked "$VAULT_COLLECTION_KNOWLEDGE" && cmd_search "$@" ;;
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
