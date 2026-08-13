#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# campaign-asset-helper.sh — _campaigns/ plane P4: asset binary management
#
# Routes asset binaries for the _campaigns/ plane. Large files (>=30MB) go to the
# knowledge-blobs store with a symlink + manifest entry. Smaller files are stored
# directly. Generates 640px PNG thumbnails/previews for AI review.
#
# Usage:
#   campaign-asset-helper.sh add <file> [--campaign <id>] [--target lib-brand|lib-swipe|campaign]
#                                       [--sensitivity <tier>] [--no-preview] [--repo <path>]
#       Ingest a binary asset. Routes to blob store if >=30MB; writes manifest entry.
#   campaign-asset-helper.sh preview <file> [--size <px>] [--output <path>]
#       Generate a 640px-wide PNG preview thumbnail (images, PDFs, video frame).
#   campaign-asset-helper.sh list [--campaign <id>] [--type image|video|audio|pdf|all] [--repo <path>]
#       List assets from the manifest with metadata.
#   campaign-asset-helper.sh manifest <asset-id> [--repo <path>]
#       Show the JSON manifest entry for an asset.
#   campaign-asset-helper.sh help
#       Show this help.
#
# Asset types:
#   image   PNG, JPG/JPEG, GIF, WEBP, SVG, TIFF, BMP
#   video   MP4, MOV, AVI, MKV, WEBM
#   audio   MP3, WAV, AAC, OGG, FLAC, M4A
#   pdf     PDF
#
# Blob threshold: files >=30MB stored at ~/.aidevops/.agent-workspace/knowledge-blobs/
# with a symlink in the target directory and a manifest entry in _campaigns/lib/assets/.
#
# Preview constraint: max 640px per side (safe below screenshot-limits.md 1568px crash boundary).
# Requires ImageMagick (convert) for images/PDFs, ffmpeg for video first-frame extraction.
# See reference/screenshot-limits.md for AI review image constraints.
#
# Prerequisites: _campaigns/ plane provisioned (P1 — campaigns-provision-helper.sh init).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Guard color fallbacks when shared-constants.sh is absent
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Prefer print_* from shared-constants; define fallbacks only when absent.
if ! declare -f print_info >/dev/null 2>&1; then
	print_info() { local _m="$1"; printf "${BLUE}[INFO]${NC} %s\n" "$_m"; }
fi
if ! declare -f print_success >/dev/null 2>&1; then
	print_success() { local _m="$1"; printf "${GREEN}[OK]${NC} %s\n" "$_m"; }
fi
if ! declare -f print_warning >/dev/null 2>&1; then
	print_warning() { local _m="$1"; printf "${YELLOW}[WARN]${NC} %s\n" "$_m"; }
fi
if ! declare -f print_error >/dev/null 2>&1; then
	print_error() { local _m="$1"; printf "${RED}[ERROR]${NC} %s\n" "$_m"; }
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly CAMPAIGNS_ROOT="_campaigns"
readonly CAMPAIGNS_LIB_ASSETS="lib/assets"
readonly ASSET_MANIFEST_FILE="manifest.json"
readonly BLOB_THRESHOLD_BYTES=31457280
readonly PREVIEW_DEFAULT_SIZE=640
readonly PREVIEW_MAX_SIZE=640
readonly ASSET_NONE="null"      # Sentinel: field absent / no value
readonly ASSET_UNVERIFIED="unverified"

# ---------------------------------------------------------------------------
# Error helpers — centralise repeated messages to satisfy string-literal ratchet
# ---------------------------------------------------------------------------

_err_unknown_opt() {
	local _o="${1:-}"
	print_error "Unknown option: ${_o}"
	return 1
}

_err_requires_value() {
	local _o="${1:-}"
	print_error "${_o} requires a value"
	return 1
}

_err_unexpected_arg() {
	local _a="${1:-}"
	print_error "Unexpected argument: ${_a}"
	return 1
}

# ---------------------------------------------------------------------------
# Internal helpers — type classification
# ---------------------------------------------------------------------------

# _classify_asset_kind: emit image|video|audio|pdf|binary based on extension
_classify_asset_kind() {
	local file_path="$1"
	local ext
	ext=$(printf '%s' "${file_path##*.}" | tr '[:upper:]' '[:lower:]')
	case "$ext" in
	png | jpg | jpeg | gif | webp | svg | tiff | tif | bmp)
		echo "image" ;;
	mp4 | mov | avi | mkv | webm)
		echo "video" ;;
	mp3 | wav | aac | ogg | flac | m4a)
		echo "audio" ;;
	pdf)
		echo "pdf" ;;
	*)
		echo "binary" ;;
	esac
	return 0
}

# _slugify: convert string to safe file-system slug (lowercase, hyphens)
_slugify() {
	local input="$1"
	printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | \
		sed 's/--*/-/g; s/^-//; s/-$//'
	return 0
}

# _sha256_file: compute SHA-256 of a file; prints hex digest
_sha256_file() {
	local file_path="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file_path" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file_path" | awk '{print $1}'
	else
		print_error "A SHA-256 tool (sha256sum or shasum) is required"
		return 1
	fi
	return 0
}

# _require_campaigns_plane: verify _campaigns/ is provisioned; returns 1 if not
_require_campaigns_plane() {
	local campaigns_dir="$1"
	if [[ ! -d "$campaigns_dir" ]]; then
		print_error "_campaigns/ plane not found at: ${campaigns_dir}"
		print_error "Run 'aidevops campaign init' first."
		return 1
	fi
	return 0
}

# _resolve_target_dir: map --target flag to a subdirectory under _campaigns/
# Defaults to lib-brand for library assets.
_resolve_target_dir() {
	local campaigns_dir="$1"
	local target="$2"
	local campaign_id="$3"
	case "$target" in
	lib-brand | "")
		echo "${campaigns_dir}/lib/brand"
		;;
	lib-swipe)
		echo "${campaigns_dir}/lib/swipe"
		;;
	campaign)
		if [[ -z "$campaign_id" ]]; then
			print_error "--target campaign requires --campaign <id>"
			return 1
		fi
		echo "${campaigns_dir}/active/${campaign_id}/creative"
		;;
	*)
		print_error "Unknown --target '${target}'. Use: lib-brand, lib-swipe, campaign"
		return 1
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Internal helpers — blob store
# ---------------------------------------------------------------------------

# _store_asset_blob: copy asset to blob store; echoes blob_path
# Args: <file_path> <asset_id> <repo_name>
_store_asset_blob() {
	local file_path="$1"
	local asset_id="$2"
	local repo_name="$3"
	local blob_dir="${HOME}/.aidevops/.agent-workspace/knowledge-blobs/${repo_name}/campaigns/${asset_id}"
	mkdir -p "$blob_dir"
	local blob_path
	blob_path="${blob_dir}/$(basename "$file_path")"
	cp "$file_path" "$blob_path"
	print_info "Large file stored at blob path: ${blob_path}"
	echo "$blob_path"
	return 0
}

# _create_symlink_in_target: create symlink from target_dir/filename → blob_path
# Args: <blob_path> <target_dir> <filename>
_create_symlink_in_target() {
	local blob_path="$1"
	local target_dir="$2"
	local filename="$3"
	mkdir -p "$target_dir"
	local link_path="${target_dir}/${filename}"
	if [[ -L "$link_path" ]]; then
		rm -f "$link_path"
	fi
	ln -s "$blob_path" "$link_path"
	print_info "Symlink created: ${link_path} → ${blob_path}"
	return 0
}

# _copy_asset_inline: copy asset directly into target_dir
# Args: <file_path> <target_dir>
_copy_asset_inline() {
	local file_path="$1"
	local target_dir="$2"
	mkdir -p "$target_dir"
	cp "$file_path" "$target_dir/"
	print_info "Asset stored: ${target_dir}/$(basename "$file_path")"
	return 0
}

# ---------------------------------------------------------------------------
# Internal helpers — manifest
# ---------------------------------------------------------------------------

# _read_manifest: print manifest JSON; returns empty array JSON if absent
_read_manifest() {
	local manifest_path="$1"
	if [[ -f "$manifest_path" ]]; then
		cat "$manifest_path"
	else
		printf '{"version":2,"assets":[]}'
	fi
	return 0
}

# _append_manifest_entry: add asset entry to manifest JSON using jq
# Args: <manifest_path> <asset_id> <filename> <kind> <target_subdir> <sensitivity>
#       <sha256> <size_bytes> <blob_path_or_null> <preview_path_or_null>
_append_manifest_entry() {
	local manifest_path="$1"
	local asset_id="$2"
	local filename="$3"
	local kind="$4"
	local target_subdir="$5"
	local sensitivity="$6"
	local sha256="$7"
	local size_bytes="$8"
	local blob_path="$9"
	local preview_path="${10}"
	command -v jq >/dev/null 2>&1 || { print_error "jq is required before asset ingestion"; return 1; }
	local ts actor
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
	actor="${USER:-unknown}"
	local existing
	existing=$(_read_manifest "$manifest_path")
	printf '%s' "$existing" | jq -e \
		--arg id "$asset_id" \
		--arg fn "$filename" \
		--arg kind "$kind" \
		--arg tgt "$target_subdir" \
		--arg sens "$sensitivity" \
		--arg sha "$sha256" \
		--argjson sz "$size_bytes" \
		--arg bp "$blob_path" \
		--arg pp "$preview_path" \
		--arg none "$ASSET_NONE" \
		--arg unverified "$ASSET_UNVERIFIED" \
		--arg ts "$ts" \
		--arg by "$actor" \
		'if (.version != 1 and .version != 2) or (.assets | type != "array") then error("invalid asset manifest")
		 elif (.assets | any(.id == $id)) then error("duplicate asset id")
		 else {version:2,assets:(.assets + [{id:$id,filename:$fn,kind:$kind,target:$tgt,sensitivity:$sens,
		              sha256:$sha,size_bytes:$sz,
		              blob_path:(if $bp == $none then null else $bp end),
		              preview_path:(if $pp == $none then null else $pp end),
		              lineage:{source_asset_id:null,source_sha256:null},
		              rights:{license:$unverified,consent:$unverified,territory:$unverified,expires_at:null},
		              review:{status:"required"},recipe:{tool:"campaign-asset-helper",provider:"local",hash:$sha},
		              variant:"source",synthetic_disclosure:"not_applicable",output_status:"source",
		              ingested_at:$ts,ingested_by:$by}])} end' \
		>"${manifest_path}.tmp" && mv "${manifest_path}.tmp" "$manifest_path"
	[[ -f "$manifest_path" ]] || return 1
	return 0
}

# ---------------------------------------------------------------------------
# Internal helpers — preview generation
# ---------------------------------------------------------------------------

# _preview_from_image: generate preview PNG from image/PDF; echoes output path
# Args: <file_path> <size_px> <output_path>
_preview_from_image() {
	local file_path="$1"
	local size_px="$2"
	local output_path="$3"
	if ! command -v convert >/dev/null 2>&1; then
		print_warning "ImageMagick 'convert' not found — preview skipped for: $(basename "$file_path")"
		echo "$ASSET_NONE"
		return 0
	fi
	if [[ "$size_px" -gt "$PREVIEW_MAX_SIZE" ]]; then
		print_warning "Requested size ${size_px}px exceeds ${PREVIEW_MAX_SIZE}px limit — capping"
		size_px=$PREVIEW_MAX_SIZE
	fi
	local ext
	ext=$(printf '%s' "${file_path##*.}" | tr '[:upper:]' '[:lower:]')
	local input_arg="$file_path"
	[[ "$ext" == "pdf" ]] && input_arg="${file_path}[0]"
	if convert -quiet -resize "${size_px}x${size_px}>" "$input_arg" "$output_path" 2>/dev/null; then
		print_success "Preview generated: ${output_path}"
		echo "$output_path"
	else
		print_warning "Preview generation failed for: $(basename "$file_path")"
		echo "$ASSET_NONE"
	fi
	return 0
}

# _preview_from_video: extract first-frame PNG via ffmpeg; echoes output path
# Args: <file_path> <size_px> <output_path>
_preview_from_video() {
	local file_path="$1"
	local size_px="$2"
	local output_path="$3"
	if ! command -v ffmpeg >/dev/null 2>&1; then
		print_warning "ffmpeg not found — video preview skipped for: $(basename "$file_path")"
		echo "$ASSET_NONE"
		return 0
	fi
	if [[ "$size_px" -gt "$PREVIEW_MAX_SIZE" ]]; then
		size_px=$PREVIEW_MAX_SIZE
	fi
	if ffmpeg -loglevel quiet -i "$file_path" -ss 00:00:01 -vframes 1 \
			-vf "scale=${size_px}:-1" "$output_path" 2>/dev/null; then
		print_success "Video preview generated: ${output_path}"
		echo "$output_path"
	else
		print_warning "Video preview generation failed for: $(basename "$file_path")"
		echo "$ASSET_NONE"
	fi
	return 0
}

# _generate_preview: dispatch to type-specific preview generator; echoes output path or ASSET_NONE
# Args: <file_path> <kind> <size_px> <previews_dir>
_generate_preview() {
	local file_path="$1"
	local kind="$2"
	local size_px="$3"
	local previews_dir="$4"
	mkdir -p "$previews_dir"
	local base_name
	base_name=$(basename "$file_path")
	local preview_name="${base_name%.*}_preview.png"
	local output_path="${previews_dir}/${preview_name}"
	case "$kind" in
	image | pdf)
		_preview_from_image "$file_path" "$size_px" "$output_path"
		;;
	video)
		_preview_from_video "$file_path" "$size_px" "$output_path"
		;;
	audio)
		print_info "Audio assets have no visual preview ($(basename "$file_path"))"
		echo "$ASSET_NONE"
		;;
	*)
		print_info "No preview available for kind '${kind}' ($(basename "$file_path"))"
		echo "$ASSET_NONE"
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

# _cmd_add: ingest asset into _campaigns/ plane
_cmd_add() {
	local file_path="" campaign_id="" target="lib-brand" sensitivity="internal"
	local no_preview=0 repo_path
	repo_path="$(pwd)"
	local file_set=0
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--campaign)
			[[ -z "$_nxt" ]] && { _err_requires_value "$_cur"; return 1; }
			campaign_id="$_nxt"; shift 2 ;;
		--target)
			[[ -z "$_nxt" ]] && { _err_requires_value "$_cur"; return 1; }
			target="$_nxt"; shift 2 ;;
		--sensitivity)
			[[ -z "$_nxt" ]] && { _err_requires_value "$_cur"; return 1; }
			sensitivity="$_nxt"; shift 2 ;;
		--no-preview)
			no_preview=1; shift ;;
		--repo)
			[[ -z "$_nxt" ]] && { _err_requires_value "$_cur"; return 1; }
			repo_path="$_nxt"; shift 2 ;;
		-*)
			_err_unknown_opt "$_cur"; return 1 ;;
		*)
			if [[ "$file_set" -eq 0 ]]; then
				file_path="$_cur"; file_set=1; shift
			else
				_err_unexpected_arg "$_cur"; return 1
			fi ;;
		esac
	done
	[[ -z "$file_path" ]] && { print_error "Usage: campaign-asset-helper.sh add <file> [options]"; return 1; }
	[[ ! -f "$file_path" ]] && { print_error "File not found: ${file_path}"; return 1; }
	local campaigns_dir="${repo_path}/${CAMPAIGNS_ROOT}"
	_require_campaigns_plane "$campaigns_dir" || return 1
	local target_dir
	target_dir=$(_resolve_target_dir "$campaigns_dir" "$target" "$campaign_id") || return 1
	local filename
	filename=$(basename "$file_path")
	local size_bytes
	size_bytes=$(wc -c <"$file_path" | tr -d ' ')
	local kind
	kind=$(_classify_asset_kind "$file_path")
	local sha256
	sha256=$(_sha256_file "$file_path") || return 1
	local slug_base
	slug_base=$(_slugify "${filename%.*}")
	local ts_short
	ts_short=$(date +%Y%m%d)
	local asset_id="${ts_short}-${slug_base}-${sha256:0:8}"
	local blob_path="$ASSET_NONE"
	local repo_name
	repo_name=$(basename "$repo_path")
	local staged_path="" staged_blob_path="" staged_preview_path=""
	if [[ "$size_bytes" -ge "$BLOB_THRESHOLD_BYTES" ]]; then
		blob_path=$(_store_asset_blob "$file_path" "$asset_id" "$repo_name") || return 1
		staged_blob_path="$blob_path"
		_create_symlink_in_target "$blob_path" "$target_dir" "$filename" || return 1
		staged_path="${target_dir}/${filename}"
	else
		_copy_asset_inline "$file_path" "$target_dir" || return 1
		staged_path="${target_dir}/${filename}"
	fi
	local preview_path="$ASSET_NONE"
	local previews_dir="${target_dir}/.previews"
	if [[ "$no_preview" -eq 0 ]]; then
		preview_path=$(_generate_preview "$file_path" "$kind" "$PREVIEW_DEFAULT_SIZE" "$previews_dir") || true
		[[ "$preview_path" != "$ASSET_NONE" ]] && staged_preview_path="$preview_path"
	fi
	local assets_dir="${campaigns_dir}/${CAMPAIGNS_LIB_ASSETS}"
	mkdir -p "$assets_dir"
	local manifest_path="${assets_dir}/${ASSET_MANIFEST_FILE}"
	local target_subdir="${target}"
	[[ "$target" == "campaign" ]] && target_subdir="active/${campaign_id}/creative"
	if ! _append_manifest_entry "$manifest_path" "$asset_id" "$filename" "$kind" \
		"$target_subdir" "$sensitivity" "$sha256" "$size_bytes" "$blob_path" "$preview_path"; then
		rm -f "$staged_path" "$staged_preview_path"
		[[ -n "$staged_blob_path" ]] && rm -f "$staged_blob_path"
		return 1
	fi
	print_success "Asset ingested: ${asset_id} (${kind}, ${size_bytes}B)"
	if [[ "$blob_path" != "$ASSET_NONE" ]]; then
		print_info "  blob: ${blob_path}"
		print_info "  link: ${target_dir}/${filename}"
	else
		print_info "  stored: ${target_dir}/${filename}"
	fi
	[[ "$preview_path" != "$ASSET_NONE" ]] && print_info "  preview: ${preview_path}"
	return 0
}

# _cmd_preview: generate a preview PNG for a standalone file
_cmd_preview() {
	local file_path="" size_px="$PREVIEW_DEFAULT_SIZE" output_path=""
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--size)
			[[ -z "$_nxt" ]] && { _err_requires_value "$_cur"; return 1; }
			size_px="$_nxt"; shift 2 ;;
		--output)
			[[ -z "$_nxt" ]] && { _err_requires_value "$_cur"; return 1; }
			output_path="$_nxt"; shift 2 ;;
		-*)
			_err_unknown_opt "$_cur"; return 1 ;;
		*)
			if [[ -z "$file_path" ]]; then
				file_path="$_cur"; shift
			else
				_err_unexpected_arg "$_cur"; return 1
			fi ;;
		esac
	done
	[[ -z "$file_path" ]] && { print_error "Usage: campaign-asset-helper.sh preview <file> [--size <px>] [--output <path>]"; return 1; }
	[[ ! -f "$file_path" ]] && { print_error "File not found: ${file_path}"; return 1; }
	local kind
	kind=$(_classify_asset_kind "$file_path")
	if [[ -z "$output_path" ]]; then
		local base_name
		base_name=$(basename "$file_path")
		output_path="${base_name%.*}_preview.png"
	fi
	local previews_dir
	previews_dir=$(dirname "$output_path")
	_generate_preview "$file_path" "$kind" "$size_px" "$previews_dir"
	return 0
}

# _cmd_list: list assets from manifest
_cmd_list() {
	local campaign_id="" filter_type="all" repo_path
	repo_path="$(pwd)"
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--campaign)
			campaign_id="${_nxt:-}"; shift 2 ;;
		--type)
			filter_type="${_nxt:-all}"; shift 2 ;;
		--repo)
			[[ -z "$_nxt" ]] && { _err_requires_value "$_cur"; return 1; }
			repo_path="$_nxt"; shift 2 ;;
		*)
			_err_unknown_opt "$_cur"; return 1 ;;
		esac
	done
	local campaigns_dir="${repo_path}/${CAMPAIGNS_ROOT}"
	_require_campaigns_plane "$campaigns_dir" || return 1
	local manifest_path="${campaigns_dir}/${CAMPAIGNS_LIB_ASSETS}/${ASSET_MANIFEST_FILE}"
	if [[ ! -f "$manifest_path" ]]; then
		print_info "No assets ingested yet. Use: campaign-asset-helper.sh add <file>"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq not found — showing raw manifest"
		cat "$manifest_path"
		return 0
	fi
	local jq_filter='.assets[]'
	if [[ "$filter_type" != "all" ]]; then
		jq_filter+=" | select(.kind == \$type)"
	fi
	if [[ -n "$campaign_id" ]]; then
		jq_filter+=" | select(.target | contains(\$camp))"
	fi
	local count
	count=$(jq --arg type "$filter_type" --arg camp "$campaign_id" \
		"[${jq_filter}] | length" "$manifest_path" 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	if [[ "$count" -eq 0 ]]; then
		print_info "No assets found matching criteria."
		return 0
	fi
	printf "%-40s %-8s %-12s %-12s %s\n" "ID" "KIND" "SENSITIVITY" "SIZE" "FILENAME"
	printf '%0.s-' {1..90}; echo
	jq -r --arg type "$filter_type" --arg camp "$campaign_id" \
		--argjson threshold "$BLOB_THRESHOLD_BYTES" \
		"${jq_filter} | [.id, .kind, .sensitivity,
		(if .size_bytes >= \$threshold then \"blob\" else (.size_bytes | tostring) + \"B\" end),
		.filename] | @tsv" "$manifest_path" | \
		while IFS=$'\t' read -r _id _kind _sens _size _file; do
			printf "%-40s %-8s %-12s %-12s %s\n" "$_id" "$_kind" "$_sens" "$_size" "$_file"
		done
	echo ""
	print_info "Total: ${count} asset(s)"
	return 0
}

# _cmd_manifest: show full manifest entry for an asset by ID
_cmd_manifest() {
	local asset_id="" repo_path
	repo_path="$(pwd)"
	while [[ $# -gt 0 ]]; do
		local _cur="${1:-}" _nxt="${2:-}"
		case "$_cur" in
		--repo)
			[[ -z "$_nxt" ]] && { _err_requires_value "$_cur"; return 1; }
			repo_path="$_nxt"; shift 2 ;;
		-*)
			_err_unknown_opt "$_cur"; return 1 ;;
		*)
			if [[ -z "$asset_id" ]]; then
				asset_id="$_cur"; shift
			else
				_err_unexpected_arg "$_cur"; return 1
			fi ;;
		esac
	done
	[[ -z "$asset_id" ]] && { print_error "Usage: campaign-asset-helper.sh manifest <asset-id> [--repo <path>]"; return 1; }
	local campaigns_dir="${repo_path}/${CAMPAIGNS_ROOT}"
	_require_campaigns_plane "$campaigns_dir" || return 1
	local manifest_path="${campaigns_dir}/${CAMPAIGNS_LIB_ASSETS}/${ASSET_MANIFEST_FILE}"
	[[ ! -f "$manifest_path" ]] && { print_error "No manifest found at: ${manifest_path}"; return 1; }
	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required to query manifest entries"
		return 1
	fi
	local entry
	entry=$(jq --arg id "$asset_id" '.assets[] | select(.id == $id)' "$manifest_path" 2>/dev/null || true)
	if [[ -z "$entry" ]]; then
		print_error "Asset not found in manifest: ${asset_id}"
		return 1
	fi
	echo "$entry"
	return 0
}

_cmd_help() {
	cat <<'EOF'
campaign-asset-helper.sh — _campaigns/ plane P4: asset binary management

USAGE
  campaign-asset-helper.sh add <file> [OPTIONS]
      Ingest a binary asset into the _campaigns/ plane.
      Large files (>=30MB) are stored in the knowledge-blobs store with a symlink.

  campaign-asset-helper.sh preview <file> [--size <px>] [--output <path>]
      Generate a 640px-wide PNG thumbnail/preview for AI review.

  campaign-asset-helper.sh list [--campaign <id>] [--type image|video|audio|pdf|all]
                                 [--repo <path>]
      List assets from the manifest.

  campaign-asset-helper.sh manifest <asset-id> [--repo <path>]
      Show full JSON manifest entry for an asset.

  campaign-asset-helper.sh help
      Show this help.

OPTIONS for 'add':
  --campaign <id>           Link asset to an active campaign (sets target dir to active/<id>/creative)
  --target lib-brand        Store in lib/brand/ (default)
  --target lib-swipe        Store in lib/swipe/
  --target campaign         Store in active/<id>/creative/ (requires --campaign)
  --sensitivity <tier>      Override sensitivity tier (default: internal)
  --no-preview              Skip thumbnail generation
  --repo <path>             Repo path containing _campaigns/ (default: pwd)

ASSET TYPES
  image   PNG, JPG, GIF, WEBP, SVG, TIFF, BMP
  video   MP4, MOV, AVI, MKV, WEBM
  audio   MP3, WAV, AAC, OGG, FLAC, M4A
  pdf     PDF

BLOB THRESHOLD
  Files >= 30MB are stored in ~/.aidevops/.agent-workspace/knowledge-blobs/
  with a symlink in the target directory and a manifest entry in
  _campaigns/lib/assets/manifest.json.

PREVIEW NOTES
  Requires ImageMagick (convert) for images and PDFs.
  Requires ffmpeg for video first-frame extraction.
  Max preview size is 640px per side (safe for AI review; below 1568px crash limit).
  See reference/screenshot-limits.md for full constraints.

MANIFEST
  All assets are tracked in _campaigns/lib/assets/manifest.json.
  Use 'list' to query, 'manifest <id>' to view a single entry.

EXAMPLE
  # Add brand logo (small — stored inline in lib/brand/)
  campaign-asset-helper.sh add logo.png --target lib-brand

  # Add large video asset (>30MB — routed to blob store)
  campaign-asset-helper.sh add promo-video.mp4 --campaign instagram-summer-launch \
      --target campaign

  # Generate preview for an existing file
  campaign-asset-helper.sh preview promo-video.mp4 --size 640

  # List all image assets
  campaign-asset-helper.sh list --type image

  # Show manifest for a specific asset
  campaign-asset-helper.sh manifest 20260428-logo
EOF
	return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
	add)
		_cmd_add "$@" ;;
	preview)
		_cmd_preview "$@" ;;
	list)
		_cmd_list "$@" ;;
	manifest)
		_cmd_manifest "$@" ;;
	help | -h | --help)
		_cmd_help ;;
	*)
		print_error "Unknown command: ${cmd}"
		echo ""
		_cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
