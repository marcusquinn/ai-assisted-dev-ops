#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Document Forensics Library -- conservative page-level PDF OCR repair
# =============================================================================
# Usage: source after document-creation-core-lib.sh (or equivalent functions).
# Provides cmd_document_forensics for document-creation-helper.sh.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_DOCUMENT_FORENSICS_LIB_LOADED:-}" ]] && return 0
_DOCUMENT_FORENSICS_LIB_LOADED=1

DOCUMENT_FORENSICS_SCHEMA="aidevops.document-forensics/v1"
_DF_VALUE_AUTO="auto"
_DF_VALUE_NULL="null"
_DF_VALUE_UNKNOWN="unknown"
_DF_STATUS_FAILED="failed"
_DF_TRANSFORM_ORIGINAL="original"
_DF_CLASS_SEARCHABLE="searchable"
_DF_CLASS_UNCERTAIN="uncertain"
_DF_TEXT_LAYER_SUSPECT="suspect"
_DF_PROVIDER_UNAVAILABLE="unavailable"
_DF_TRANSACTION_SCHEMA="aidevops.document-forensics.transaction/v1"
_DF_TRANSACTION_PREPARED="prepared"

_DF_TMP_DIR=""
_DF_INPUT=""
_DF_OUTPUT_DIR=""
_DF_STEM=""
_DF_PROVIDER=""
_DF_DPI=300
_DF_MIN_TEXT_CHARS=50
_DF_MIN_IMPROVEMENT=15
_DF_MIN_WORDS=4
_DF_WRITE_READABLE=false
_DF_PAGE_COUNT=0
_DF_PAGE_SUCCESS_COUNT=0
_DF_PAGE_FAILED_COUNT=0
_DF_FAILURE_COUNT=0
_DF_SIDECAR_TMP=""
_DF_SIDECAR_PATH=""
_DF_MANIFEST_PATH=""
_DF_READABLE_PATH=""
_DF_READABLE_TMP=""
_DF_FINAL_STATUS="$_DF_STATUS_FAILED"
_DF_ARG_INPUT=""
_DF_ARG_OUTPUT=""
_DF_ARG_PROVIDER="$_DF_VALUE_AUTO"
_DF_HELP_REQUESTED=false
_DF_SOURCE_HASH_BEFORE=""
_DF_SOURCE_HASH_AFTER=""
_DF_BACKEND_VERSION="$_DF_VALUE_UNKNOWN"
_DF_LOCK_DIR=""
_DF_LOCK_TOKEN=""
_DF_LOCK_OWNED=false
_DF_TRANSACTION_DIR=""

_df_cleanup() {
	if [[ "${_DF_LOCK_OWNED:-false}" == true ]] && [[ -n "${_DF_TRANSACTION_DIR:-}" ]]; then
		_df_recover_interrupted_publication || true
	fi
	_df_release_output_lock || true
	if [[ -n "${_DF_TMP_DIR:-}" ]] && [[ -d "$_DF_TMP_DIR" ]]; then
		rm -rf "$_DF_TMP_DIR"
	fi
	return 0
}

_df_reset_state() {
	_df_cleanup
	_DF_TMP_DIR=""
	_DF_INPUT=""
	_DF_OUTPUT_DIR=""
	_DF_STEM=""
	_DF_PROVIDER=""
	_DF_DPI=300
	_DF_MIN_TEXT_CHARS=50
	_DF_MIN_IMPROVEMENT=15
	_DF_MIN_WORDS=4
	_DF_WRITE_READABLE=false
	_DF_PAGE_COUNT=0
	_DF_PAGE_SUCCESS_COUNT=0
	_DF_PAGE_FAILED_COUNT=0
	_DF_FAILURE_COUNT=0
	_DF_SIDECAR_TMP=""
	_DF_SIDECAR_PATH=""
	_DF_MANIFEST_PATH=""
	_DF_READABLE_PATH=""
	_DF_READABLE_TMP=""
	_DF_FINAL_STATUS="$_DF_STATUS_FAILED"
	_DF_ARG_INPUT=""
	_DF_ARG_OUTPUT=""
	_DF_ARG_PROVIDER="$_DF_VALUE_AUTO"
	_DF_HELP_REQUESTED=false
	_DF_SOURCE_HASH_BEFORE=""
	_DF_SOURCE_HASH_AFTER=""
	_DF_BACKEND_VERSION="$_DF_VALUE_UNKNOWN"
	_DF_LOCK_DIR=""
	_DF_LOCK_TOKEN=""
	_DF_LOCK_OWNED=false
	_DF_TRANSACTION_DIR=""
	return 0
}

_df_release_output_lock() {
	local current_owner=""

	if [[ "$_DF_LOCK_OWNED" != true ]] || [[ -z "$_DF_LOCK_DIR" ]]; then
		return 0
	fi
	if [[ -f "${_DF_LOCK_DIR}/owner" ]]; then
		current_owner=$(<"${_DF_LOCK_DIR}/owner")
	fi
	if [[ "$current_owner" == "$_DF_LOCK_TOKEN" ]]; then
		rm -rf "$_DF_LOCK_DIR" || return 1
	fi
	_DF_LOCK_OWNED=false
	return 0
}

_df_write_lock_owner() {
	if printf '%s\n' "$_DF_LOCK_TOKEN" >"${_DF_LOCK_DIR}/owner"; then
		_DF_LOCK_OWNED=true
		return 0
	fi
	rm -rf "$_DF_LOCK_DIR" 2>/dev/null || true
	return 1
}

_df_lock_owner_is_live() {
	local owner="$1"
	local owner_pid="${owner%%:*}"
	local observed_pid=""

	if [[ ! "$owner_pid" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	if kill -0 "$owner_pid" 2>/dev/null; then
		return 0
	fi
	if ! has_cmd ps; then
		return 0
	fi
	observed_pid=$(ps -p "$owner_pid" -o pid= 2>/dev/null | tr -d '[:space:]') || true
	if [[ "$observed_pid" == "$owner_pid" ]]; then
		return 0
	fi
	return 1
}

_df_move_directory_atomically() {
	local source="$1"
	local destination="$2"

	if ! has_cmd python3 || [[ ! -d "$source" ]] || [[ -L "$source" ]] || \
		[[ -e "$destination" ]] || [[ -L "$destination" ]]; then
		return 1
	fi
	if python3 -c '
import os
import sys

source, destination = sys.argv[1:3]
if not os.path.isdir(source) or os.path.islink(source) or os.path.lexists(destination):
    raise SystemExit(1)
os.rename(source, destination)
' "$source" "$destination"; then
		return 0
	fi
	return 1
}

_df_acquire_output_lock() {
	local owner=""
	local observed_owner=""
	local stale_dir=""
	local lock_age=0
	local lock_mtime=0
	local lock_owner=""
	local current_user=""

	_DF_LOCK_DIR="${_DF_OUTPUT_DIR}/.${_DF_STEM}.forensics.lock"
	_DF_LOCK_TOKEN="$$:${_DF_TMP_DIR##*/}"
	if mkdir "$_DF_LOCK_DIR" 2>/dev/null; then
		_df_write_lock_owner
		return $?
	fi
	if [[ -f "${_DF_LOCK_DIR}/owner" ]]; then
		owner=$(<"${_DF_LOCK_DIR}/owner")
	fi
	if _df_lock_owner_is_live "$owner"; then
		die "Another document-forensics run owns this output set"
		return 1
	fi
	if [[ -z "$owner" ]]; then
		if declare -F _file_mtime_epoch >/dev/null 2>&1; then
			lock_mtime=$(_file_mtime_epoch "$_DF_LOCK_DIR" 2>/dev/null || printf '0')
			lock_age=$(($(date +%s) - lock_mtime))
		fi
		if [[ "$lock_mtime" -eq 0 ]] || [[ "$lock_age" -lt 300 ]]; then
			die "Document-forensics output lock has no verifiable owner"
			return 1
		fi
	fi

	if ! declare -F _file_owner >/dev/null 2>&1 || ! has_cmd id; then
		die "Unable to verify stale document-forensics lock ownership"
		return 1
	fi
	lock_owner=$(_file_owner "$_DF_LOCK_DIR" 2>/dev/null || true)
	current_user=$(id -un 2>/dev/null || true)
	if [[ -z "$lock_owner" ]] || [[ "$lock_owner" == "$_DF_VALUE_UNKNOWN" ]] || [[ "$lock_owner" != "$current_user" ]]; then
		die "Refusing to reclaim a document-forensics lock owned by another user"
		return 1
	fi
	if [[ -f "${_DF_LOCK_DIR}/owner" ]]; then
		observed_owner=$(<"${_DF_LOCK_DIR}/owner")
	fi
	if [[ "$observed_owner" != "$owner" ]] || _df_lock_owner_is_live "$observed_owner"; then
		die "Document-forensics output lock changed during stale-lock recovery"
		return 1
	fi
	stale_dir="${_DF_LOCK_DIR}.stale.${_DF_TMP_DIR##*.}"
	if ! _df_move_directory_atomically "$_DF_LOCK_DIR" "$stale_dir"; then
		die "Unable to move the stale document-forensics output lock"
		return 1
	fi
	if ! mkdir "$_DF_LOCK_DIR" 2>/dev/null; then
		rm -rf "$stale_dir"
		die "Another document-forensics run won the output lock race"
		return 1
	fi
	if _df_write_lock_owner; then
		rm -rf "$stale_dir"
		return 0
	fi
	rm -rf "$stale_dir"
	return 1
}

_df_sha256() {
	local file="$1"
	local digest=""

	if has_cmd sha256sum; then
		digest=$(sha256sum "$file" 2>/dev/null | awk '{ value = $1 } END { print value }') || return 1
	elif has_cmd shasum; then
		digest=$(shasum -a 256 "$file" 2>/dev/null | awk '{ value = $1 } END { print value }') || return 1
	else
		return 1
	fi
	if [[ ! "$digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
		return 1
	fi
	printf '%s' "$digest"
	return 0
}

_df_nonspace_chars() {
	local file="$1"
	local count="0"
	count=$(tr -d '[:space:]' <"$file" | wc -c | tr -d ' ')
	printf '%s' "${count:-0}"
	return 0
}

_df_alpha_chars() {
	local file="$1"
	local count="0"
	count=$(LC_ALL=C tr -cd '[:alpha:]' <"$file" | wc -c | tr -d ' ')
	printf '%s' "${count:-0}"
	return 0
}

_df_word_count() {
	local file="$1"
	local count="0"
	count=$(wc -w <"$file" | tr -d ' ')
	printf '%s' "${count:-0}"
	return 0
}

_df_record_failure() {
	local page="$1"
	local transform="$2"
	local message="$3"
	local failure_id=""
	local failure_file=""

	_DF_FAILURE_COUNT=$((_DF_FAILURE_COUNT + 1))
	printf -v failure_id '%04d' "$_DF_FAILURE_COUNT"
	failure_file="${_DF_TMP_DIR}/failures/${failure_id}.json"
	jq -n \
		--argjson page "$page" \
		--arg transform "$transform" \
		--arg message "$message" \
		'{page: (if $page == 0 then null else $page end), transform: (if $transform == "" then null else $transform end), message: $message}' \
		>"$failure_file"
	return 0
}

_df_write_candidate_failure() {
	local transform="$1"
	local output_json="$2"
	local message="$3"

	jq -n \
		--arg transform "$transform" \
		--arg message "$message" \
		'{transform: $transform, success: false, score: null, confidence: null, text_chars: 0, alpha_chars: 0, word_count: 0, evidence_sufficient: false, backend_evidence: null, failure: $message}' \
		>"$output_json"
	return 0
}

_df_image_dimensions() {
	local image="$1"
	local dimensions=""

	if has_cmd magick; then
		dimensions=$(magick identify -format '%wx%h' "$image" 2>/dev/null || printf '')
	elif has_cmd identify; then
		dimensions=$(identify -format '%wx%h' "$image" 2>/dev/null || printf '')
	fi
	if [[ ! "$dimensions" =~ ^[0-9]+x[0-9]+$ ]]; then
		return 1
	fi
	printf '%s' "$dimensions"
	return 0
}

_df_transform_image() {
	local input="$1"
	local transform="$2"
	local output="$3"
	local dpi="$4"
	local runner="${DOCUMENT_FORENSICS_IMAGE_RUNNER:-}"
	local dimensions=""
	local degrees=""

	if [[ -n "$runner" ]]; then
		if "$runner" "$input" "$transform" "$output" "$dpi"; then
			return 0
		fi
		return 1
	fi

	if [[ "$transform" == "$_DF_TRANSFORM_ORIGINAL" ]]; then
		if cp "$input" "$output"; then
			return 0
		fi
		return 1
	fi

	if ! dimensions=$(_df_image_dimensions "$input"); then
		return 1
	fi

	case "$transform" in
	flip-horizontal)
		if has_cmd magick; then
			magick "$input" -flop -units PixelsPerInch -density "$dpi" "$output" >/dev/null 2>&1 && return 0
		elif has_cmd convert; then
			convert "$input" -flop -units PixelsPerInch -density "$dpi" "$output" >/dev/null 2>&1 && return 0
		fi
		;;
	rotate-90) degrees="90" ;;
	rotate-180) degrees="180" ;;
	rotate-270) degrees="270" ;;
	*) return 1 ;;
	esac

	if [[ -n "$degrees" ]] && has_cmd magick; then
		if magick "$input" -background white -rotate "$degrees" -resize "$dimensions" \
			-gravity center -extent "$dimensions" -units PixelsPerInch -density "$dpi" "$output" >/dev/null 2>&1; then
			return 0
		fi
	elif [[ -n "$degrees" ]] && has_cmd convert; then
		if convert "$input" -background white -rotate "$degrees" -resize "$dimensions" \
			-gravity center -extent "$dimensions" -units PixelsPerInch -density "$dpi" "$output" >/dev/null 2>&1; then
			return 0
		fi
	fi
	return 1
}

_df_tesseract_confidence() {
	local image="$1"
	local confidence="$_DF_VALUE_NULL"
	local tsv_file="${_DF_TMP_DIR}/tesseract-confidence-$$.tsv"

	if has_cmd tesseract && tesseract "$image" stdout tsv >"$tsv_file" 2>/dev/null; then
		confidence=$(awk -F '\t' '
			NR > 1 && $11 ~ /^[0-9]+([.][0-9]+)?$/ && $11 >= 0 { total += $11; count += 1 }
			END { if (count > 0) printf "%.2f", total / count }
		' "$tsv_file")
		[[ -z "$confidence" ]] && confidence="$_DF_VALUE_NULL"
	fi
	rm -f "$tsv_file"
	printf '%s' "$confidence"
	return 0
}

_df_evaluate_candidate() {
	local image="$1"
	local provider="$2"
	local transform="$3"
	local prefix="$4"
	local text_file="${prefix}.txt"
	local evidence_file="${prefix}.evidence.json"
	local output_json="${prefix}.json"
	local runner="${DOCUMENT_FORENSICS_OCR_RUNNER:-}"
	local confidence="$_DF_VALUE_NULL"
	local confidence_int=0
	local text_chars=0
	local alpha_chars=0
	local word_count=0
	local word_bonus=0
	local alpha_bonus=0
	local score=0
	local evidence_sufficient=false
	local backend_evidence="{}"

	if [[ -n "$runner" ]]; then
		if ! "$runner" "$image" "$provider" "$text_file" "$evidence_file"; then
			_df_write_candidate_failure "$transform" "$output_json" "OCR runner failed"
			return 1
		fi
	else
		if [[ "$provider" == "$_DF_PROVIDER_UNAVAILABLE" ]]; then
			_df_write_candidate_failure "$transform" "$output_json" "No local OCR backend is available"
			return 1
		fi
		if ! run_ocr "$image" "$provider" >"$text_file"; then
			_df_write_candidate_failure "$transform" "$output_json" "OCR backend failed"
			return 1
		fi
		if [[ "$provider" == "tesseract" ]]; then
			confidence=$(_df_tesseract_confidence "$image")
		fi
		jq -n --argjson confidence "$confidence" \
			'{confidence: $confidence, source: (if $confidence == null then "text-quality" else "tesseract-tsv" end)}' \
			>"$evidence_file"
	fi

	if [[ ! -f "$text_file" ]] || [[ ! -f "$evidence_file" ]] || ! jq -e 'type == "object"' "$evidence_file" >/dev/null 2>&1; then
		_df_write_candidate_failure "$transform" "$output_json" "OCR evidence is incomplete"
		return 1
	fi

	confidence=$(jq -r 'if (.confidence | type) == "number" then .confidence else null end' "$evidence_file")
	if [[ "$confidence" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		confidence_int=$(awk -v value="$confidence" 'BEGIN { printf "%.0f", value }')
	fi
	text_chars=$(_df_nonspace_chars "$text_file")
	alpha_chars=$(_df_alpha_chars "$text_file")
	word_count=$(_df_word_count "$text_file")
	word_bonus="$word_count"
	[[ "$word_bonus" -gt 20 ]] && word_bonus=20
	alpha_bonus=$((alpha_chars / 10))
	[[ "$alpha_bonus" -gt 10 ]] && alpha_bonus=10
	score=$((confidence_int + word_bonus + alpha_bonus))
	if [[ "$word_count" -ge "$_DF_MIN_WORDS" ]] && [[ "$alpha_chars" -ge 20 ]]; then
		evidence_sufficient=true
	fi
	backend_evidence=$(jq -c '.' "$evidence_file")

	jq -n \
		--arg transform "$transform" \
		--argjson score "$score" \
		--argjson confidence "$confidence" \
		--argjson text_chars "$text_chars" \
		--argjson alpha_chars "$alpha_chars" \
		--argjson word_count "$word_count" \
		--argjson evidence_sufficient "$evidence_sufficient" \
		--argjson backend_evidence "$backend_evidence" \
		'{transform: $transform, success: true, score: $score, confidence: $confidence, text_chars: $text_chars, alpha_chars: $alpha_chars, word_count: $word_count, evidence_sufficient: $evidence_sufficient, backend_evidence: $backend_evidence, failure: null}' \
		>"$output_json"
	return 0
}

_df_append_sidecar() {
	local page="$1"
	local classification="$2"
	local transform="$3"
	local text_file="$4"

	printf '===== Page %s [classification=%s transform=%s] =====\n' \
		"$page" "$classification" "$transform" >>"$_DF_SIDECAR_TMP"
	if [[ -f "$text_file" ]]; then
		while IFS= read -r line || [[ -n "$line" ]]; do
			printf '%s\n' "$line" >>"$_DF_SIDECAR_TMP"
		done <"$text_file"
	fi
	printf '\n' >>"$_DF_SIDECAR_TMP"
	return 0
}

_df_extract_original_page_pdf() {
	local page="$1"
	local output="$2"
	local extract_dir="${_DF_TMP_DIR}/source-pages"
	local pattern="${extract_dir}/source-%d.pdf"
	local extracted="${extract_dir}/source-${page}.pdf"

	if ! has_cmd pdfseparate; then
		return 1
	fi
	if ! pdfseparate -f "$page" -l "$page" "$_DF_INPUT" "$pattern" >/dev/null 2>&1; then
		return 1
	fi
	if [[ ! -f "$extracted" ]]; then
		return 1
	fi
	if mv "$extracted" "$output"; then
		return 0
	fi
	return 1
}

_df_make_ocr_page_pdf() {
	local image="$1"
	local text_file="$2"
	local output="$3"
	local runner="${DOCUMENT_FORENSICS_PDF_RUNNER:-}"
	local output_base="${output%.pdf}"

	if [[ -n "$runner" ]]; then
		if "$runner" "$image" "$text_file" "$output" "$_DF_DPI"; then
			return 0
		fi
		return 1
	fi
	if ! has_cmd tesseract; then
		return 1
	fi
	if tesseract "$image" "$output_base" pdf >/dev/null 2>&1 && [[ -f "$output" ]]; then
		return 0
	fi
	return 1
}

_df_write_failed_page() {
	local page="$1"
	local message="$2"
	local candidates_json="$3"
	local page_id=""
	local empty_text="${_DF_TMP_DIR}/empty.txt"
	printf -v page_id '%04d' "$page"
	: >"$empty_text"
	jq -n \
		--argjson page "$page" \
		--arg message "$message" \
		--arg failed "$_DF_STATUS_FAILED" \
		--arg original "$_DF_TRANSFORM_ORIGINAL" \
		--arg text_layer "$_DF_TEXT_LAYER_SUSPECT" \
		--argjson candidates "$candidates_json" \
		'{page: $page, text_layer: $text_layer, classification: $failed, selected_transform: $original, improvement: null, ocr: {performed: false}, candidates: $candidates, failure: $message}' \
		>"${_DF_TMP_DIR}/pages/${page_id}.json"
	_df_append_sidecar "$page" "$_DF_STATUS_FAILED" "$_DF_TRANSFORM_ORIGINAL" "$empty_text"
	_DF_PAGE_FAILED_COUNT=$((_DF_PAGE_FAILED_COUNT + 1))
	if [[ "$_DF_WRITE_READABLE" == true ]] && \
		! _df_extract_original_page_pdf "$page" "${_DF_TMP_DIR}/page-pdfs/${page_id}.pdf"; then
		_df_record_failure "$page" "$_DF_TRANSFORM_ORIGINAL" "Unable to preserve failed source page in readable derivative"
	fi
	return 0
}

_df_write_uncertain_original_page() {
	local page="$1"
	local page_id="$2"
	local improvement="$3"
	local candidates_json="$4"
	local empty_text="${_DF_TMP_DIR}/uncertain-${page_id}.txt"
	local page_pdf="${_DF_TMP_DIR}/page-pdfs/${page_id}.pdf"

	: >"$empty_text"
	_df_append_sidecar "$page" "$_DF_CLASS_UNCERTAIN" "$_DF_TRANSFORM_ORIGINAL" "$empty_text"
	jq -n \
		--argjson page "$page" \
		--arg uncertain "$_DF_CLASS_UNCERTAIN" \
		--arg original "$_DF_TRANSFORM_ORIGINAL" \
		--arg text_layer "$_DF_TEXT_LAYER_SUSPECT" \
		--argjson improvement "$improvement" \
		--argjson candidates "$candidates_json" \
		'{page: $page, text_layer: $text_layer, classification: $uncertain, selected_transform: $original, improvement: $improvement, ocr: {performed: false}, candidates: $candidates, failure: null}' \
		>"${_DF_TMP_DIR}/pages/${page_id}.json"
	_DF_PAGE_SUCCESS_COUNT=$((_DF_PAGE_SUCCESS_COUNT + 1))
	if [[ "$_DF_WRITE_READABLE" == true ]] && ! _df_extract_original_page_pdf "$page" "$page_pdf"; then
		_df_record_failure "$page" "$_DF_TRANSFORM_ORIGINAL" "Unable to preserve uncertain source page in readable derivative"
	fi
	return 0
}

_df_process_searchable_page() {
	local page="$1"
	local page_id="$2"
	local text_file="$3"
	local text_chars="$4"
	local page_pdf="${_DF_TMP_DIR}/page-pdfs/${page_id}.pdf"

	_df_append_sidecar "$page" "$_DF_CLASS_SEARCHABLE" "$_DF_TRANSFORM_ORIGINAL" "$text_file"
	jq -n \
		--argjson page "$page" \
		--argjson text_chars "$text_chars" \
		--arg searchable "$_DF_CLASS_SEARCHABLE" \
		--arg original "$_DF_TRANSFORM_ORIGINAL" \
		'{page: $page, text_layer: $searchable, classification: $searchable, selected_transform: $original, improvement: 0, ocr: {performed: false, text_chars: $text_chars}, candidates: [], failure: null}' \
		>"${_DF_TMP_DIR}/pages/${page_id}.json"
	_DF_PAGE_SUCCESS_COUNT=$((_DF_PAGE_SUCCESS_COUNT + 1))

	if [[ "$_DF_WRITE_READABLE" == true ]] && ! _df_extract_original_page_pdf "$page" "$page_pdf"; then
		_df_record_failure "$page" "$_DF_TRANSFORM_ORIGINAL" "Unable to preserve searchable source page in readable derivative"
	fi
	return 0
}

_df_collect_page_candidates() {
	local page="$1"
	local page_id="$2"
	local rendered_image="$3"
	local candidate_dir="${_DF_TMP_DIR}/candidates"
	local transform=""
	local candidate_prefix=""
	local candidate_image=""
	local candidate_json=""
	local candidate_score=0
	local original_score=0
	local original_success=false
	local best_score=-1
	local best_transform="$_DF_TRANSFORM_ORIGINAL"
	local best_prefix=""
	local success_count=0
	local candidates_json="[]"
	local summary_file="${candidate_dir}/${page_id}.summary.json"
	local -a candidate_files=()

	for transform in original flip-horizontal rotate-90 rotate-180 rotate-270; do
		candidate_prefix="${candidate_dir}/${page_id}.${transform}"
		candidate_image="${candidate_prefix}.png"
		candidate_json="${candidate_prefix}.json"
		candidate_files+=("$candidate_json")

		if ! _df_transform_image "$rendered_image" "$transform" "$candidate_image" "$_DF_DPI"; then
			_df_write_candidate_failure "$transform" "$candidate_json" "Image transform unavailable"
			_df_record_failure "$page" "$transform" "Image transform unavailable"
			continue
		fi
		if ! _df_evaluate_candidate "$candidate_image" "$_DF_PROVIDER" "$transform" "$candidate_prefix"; then
			_df_record_failure "$page" "$transform" "OCR candidate evaluation failed"
			continue
		fi

		success_count=$((success_count + 1))
		candidate_score=$(jq -r '.score' "$candidate_json")
		if [[ "$transform" == "$_DF_TRANSFORM_ORIGINAL" ]]; then
			original_score="$candidate_score"
			original_success=true
		fi
		if [[ "$candidate_score" -gt "$best_score" ]]; then
			best_score="$candidate_score"
			best_transform="$transform"
			best_prefix="$candidate_prefix"
		fi
	done

	candidates_json=$(jq -s '.' "${candidate_files[@]}")
	jq -n \
		--argjson success_count "$success_count" \
		--argjson original_score "$original_score" \
		--argjson original_success "$original_success" \
		--argjson best_score "$best_score" \
		--arg best_transform "$best_transform" \
		--arg best_prefix "$best_prefix" \
		--argjson candidates "$candidates_json" \
		'{success_count: $success_count, original_score: $original_score, original_success: $original_success, best_score: $best_score, best_transform: $best_transform, best_prefix: $best_prefix, candidates: $candidates}' \
		>"$summary_file"
	return 0
}

_df_write_suspect_page_result() {
	local page="$1"
	local page_id="$2"
	local classification="$3"
	local selected_transform="$4"
	local selected_prefix="$5"
	local improvement="$6"
	local candidates_json="$7"
	local selected_image="${selected_prefix}.png"
	local selected_ocr=""
	local page_pdf="${_DF_TMP_DIR}/page-pdfs/${page_id}.pdf"

	selected_ocr=$(jq '{performed: true, score: .score, confidence: .confidence, text_chars: .text_chars, alpha_chars: .alpha_chars, word_count: .word_count, evidence_sufficient: .evidence_sufficient, backend_evidence: .backend_evidence}' "${selected_prefix}.json")
	_df_append_sidecar "$page" "$classification" "$selected_transform" "${selected_prefix}.txt"
	jq -n \
		--argjson page "$page" \
		--arg classification "$classification" \
		--arg selected_transform "$selected_transform" \
		--argjson improvement "$improvement" \
		--argjson selected_ocr "$selected_ocr" \
		--argjson candidates "$candidates_json" \
		--arg text_layer "$_DF_TEXT_LAYER_SUSPECT" \
		'{page: $page, text_layer: $text_layer, classification: $classification, selected_transform: $selected_transform, improvement: $improvement, ocr: $selected_ocr, candidates: $candidates, failure: null}' \
		>"${_DF_TMP_DIR}/pages/${page_id}.json"
	_DF_PAGE_SUCCESS_COUNT=$((_DF_PAGE_SUCCESS_COUNT + 1))

	if [[ "$_DF_WRITE_READABLE" == true ]] && ! _df_make_ocr_page_pdf "$selected_image" "${selected_prefix}.txt" "$page_pdf"; then
		_df_record_failure "$page" "$selected_transform" "Unable to create searchable readable PDF page"
	fi
	return 0
}

_df_process_suspect_page() {
	local page="$1"
	local page_id="$2"
	local render_prefix="${_DF_TMP_DIR}/rendered/page-${page_id}"
	local rendered_image="${render_prefix}.png"
	local summary_file="${_DF_TMP_DIR}/candidates/${page_id}.summary.json"
	local success_count=0
	local original_score=0
	local original_success=false
	local best_score=-1
	local best_transform="$_DF_TRANSFORM_ORIGINAL"
	local best_prefix=""
	local candidates_json="[]"
	local best_sufficient=false
	local improvement="$_DF_VALUE_NULL"
	local classification="$_DF_CLASS_UNCERTAIN"
	local selected_transform="$_DF_TRANSFORM_ORIGINAL"
	local selected_prefix=""

	if ! render_pdf_page "$_DF_INPUT" "$page" "$render_prefix" "$_DF_DPI"; then
		_df_record_failure "$page" "$_DF_TRANSFORM_ORIGINAL" "Unable to render PDF page"
		_df_write_failed_page "$page" "Unable to render PDF page" "[]"
		return 0
	fi
	_df_collect_page_candidates "$page" "$page_id" "$rendered_image"
	success_count=$(jq -r '.success_count' "$summary_file")
	candidates_json=$(jq '.candidates' "$summary_file")
	if [[ "$success_count" -eq 0 ]]; then
		_df_record_failure "$page" "" "All OCR candidates failed"
		_df_write_failed_page "$page" "All OCR candidates failed" "$candidates_json"
		return 0
	fi

	original_score=$(jq -r '.original_score' "$summary_file")
	original_success=$(jq -r '.original_success' "$summary_file")
	best_score=$(jq -r '.best_score' "$summary_file")
	best_transform=$(jq -r '.best_transform' "$summary_file")
	best_prefix=$(jq -r '.best_prefix' "$summary_file")
	best_sufficient=$(jq -r '.evidence_sufficient' "${best_prefix}.json")
	selected_prefix="${_DF_TMP_DIR}/candidates/${page_id}.original"
	if [[ "$original_success" != true ]]; then
		_df_write_uncertain_original_page "$page" "$page_id" "$improvement" "$candidates_json"
		return 0
	fi
	improvement=$((best_score - original_score))

	if [[ "$best_transform" == "$_DF_TRANSFORM_ORIGINAL" ]]; then
		selected_prefix="$best_prefix"
		if [[ "$best_sufficient" == true ]]; then
			classification="normal"
		fi
	elif [[ "$best_sufficient" == true ]] && [[ "$improvement" -ge "$_DF_MIN_IMPROVEMENT" ]]; then
		selected_transform="$best_transform"
		selected_prefix="$best_prefix"
		case "$best_transform" in
		flip-horizontal) classification="mirrored" ;;
		rotate-*) classification="rotated" ;;
		esac
	fi

	_df_write_suspect_page_result "$page" "$page_id" "$classification" \
		"$selected_transform" "$selected_prefix" "$improvement" "$candidates_json"
	return 0
}

_df_annotate_page_dimensions() {
	local page="$1"
	local page_id="$2"
	local source_dimensions=""
	local source_width=""
	local source_height=""
	local derived_dimensions=""
	local derived_width=""
	local derived_height=""
	local derived_json="$_DF_VALUE_NULL"
	local page_file="${_DF_TMP_DIR}/pages/${page_id}.json"
	local annotated_file="${page_file}.annotated"
	local page_pdf="${_DF_TMP_DIR}/page-pdfs/${page_id}.pdf"

	if ! source_dimensions=$(pdf_page_dimensions "$_DF_INPUT" "$page"); then
		_df_record_failure "$page" "" "Unable to determine source page dimensions"
		jq '. + {source_dimensions_points: null, derived_dimensions_points: null}' \
			"$page_file" >"$annotated_file"
	else
		source_width="${source_dimensions%x*}"
		source_height="${source_dimensions#*x}"
		if [[ "$_DF_WRITE_READABLE" == true ]] && [[ -f "$page_pdf" ]]; then
			if derived_dimensions=$(pdf_page_dimensions "$page_pdf" 1); then
				derived_width="${derived_dimensions%x*}"
				derived_height="${derived_dimensions#*x}"
				derived_json=$(jq -n --arg width "$derived_width" --arg height "$derived_height" \
					'{width: ($width | tonumber), height: ($height | tonumber)}')
				if [[ "$derived_dimensions" != "$source_dimensions" ]]; then
					_df_record_failure "$page" "" "Readable page dimensions differ from the source"
				fi
			else
				_df_record_failure "$page" "" "Unable to measure readable page dimensions"
			fi
		fi
		jq --arg width "$source_width" --arg height "$source_height" --argjson derived "$derived_json" \
			'. + {
				source_dimensions_points: {width: ($width | tonumber), height: ($height | tonumber)},
				derived_dimensions_points: $derived
			}' "$page_file" >"$annotated_file"
	fi
	if mv "$annotated_file" "$page_file"; then
		return 0
	fi
	return 1
}

_df_process_page() {
	local page="$1"
	local page_id=""
	local text_file=""
	local text_chars=0

	printf -v page_id '%04d' "$page"
	text_file="${_DF_TMP_DIR}/text-layer/${page_id}.txt"
	if ! extract_pdf_page_text "$_DF_INPUT" "$page" "$text_file"; then
		: >"$text_file"
	fi
	text_chars=$(_df_nonspace_chars "$text_file")
	if [[ "$text_chars" -ge "$_DF_MIN_TEXT_CHARS" ]]; then
		_df_process_searchable_page "$page" "$page_id" "$text_file" "$text_chars"
	else
		_df_process_suspect_page "$page" "$page_id"
	fi
	_df_annotate_page_dimensions "$page" "$page_id" || return 1
	return 0
}

_df_verify_readable_pdf() {
	local output="$1"
	local output_pages=""
	local page=1
	local source_dimensions=""
	local derived_dimensions=""

	if ! output_pages=$(pdf_page_count "$output") || [[ "$output_pages" -ne "$_DF_PAGE_COUNT" ]]; then
		_df_record_failure 0 "" "Readable PDF page count differs from the source"
		return 1
	fi
	while [[ "$page" -le "$_DF_PAGE_COUNT" ]]; do
		if ! source_dimensions=$(pdf_page_dimensions "$_DF_INPUT" "$page") || \
			! derived_dimensions=$(pdf_page_dimensions "$output" "$page") || \
			[[ "$source_dimensions" != "$derived_dimensions" ]]; then
			_df_record_failure "$page" "" "Readable PDF page dimensions differ from the source"
			return 1
		fi
		page=$((page + 1))
	done
	return 0
}

_df_publish_atomic_file() {
	local source="$1"
	local destination="$2"
	local staged=""

	if [[ ! -f "$source" ]] || [[ -d "$destination" ]]; then
		return 1
	fi
	staged=$(mktemp "${destination}.tmp.XXXXXX") || return 1
	if ! cp "$source" "$staged"; then
		rm -f "$staged"
		return 1
	fi
	if replace_file_atomically "$staged" "$destination"; then
		return 0
	fi
	rm -f "$staged"
	return 1
}

_df_transaction_is_owned() {
	local transaction_dir="$1"
	local schema=""

	if [[ ! -d "$transaction_dir" ]] || [[ -L "$transaction_dir" ]] || \
		[[ ! -f "${transaction_dir}/schema" ]]; then
		return 1
	fi
	schema=$(<"${transaction_dir}/schema")
	if [[ "$schema" == "$_DF_TRANSACTION_SCHEMA" ]]; then
		return 0
	fi
	return 1
}

_df_cleanup_committed_transactions() {
	local candidate=""

	for candidate in "${_DF_TRANSACTION_DIR}.committed."*; do
		if [[ ! -e "$candidate" ]] && [[ ! -L "$candidate" ]]; then
			continue
		fi
		if ! _df_transaction_is_owned "$candidate"; then
			log_error "Refusing to remove an unrecognized forensic transaction artifact"
			return 1
		fi
		rm -rf "$candidate" || return 1
	done
	return 0
}

_df_backup_transaction_output() {
	local destination="$1"
	local marker="$2"
	local backup="$3"

	if [[ ! -e "$destination" ]] && [[ ! -L "$destination" ]]; then
		return 0
	fi
	if [[ -d "$destination" ]] || ! cp "$destination" "$backup"; then
		return 1
	fi
	if : >"$marker"; then
		return 0
	fi
	return 1
}

_df_restore_transaction_output() {
	local marker="$1"
	local backup="$2"
	local destination="$3"

	if [[ -f "$marker" ]]; then
		if [[ -f "$backup" ]]; then
			_df_publish_atomic_file "$backup" "$destination"
			return $?
		fi
		if [[ -f "$destination" ]]; then
			return 0
		fi
		return 1
	fi
	if [[ -d "$destination" ]]; then
		return 1
	fi
	rm -f "$destination"
	return $?
}

_df_recover_interrupted_publication() {
	local rollback_ok=true

	if [[ ! -e "$_DF_TRANSACTION_DIR" ]] && [[ ! -L "$_DF_TRANSACTION_DIR" ]]; then
		return 0
	fi
	if ! _df_transaction_is_owned "$_DF_TRANSACTION_DIR"; then
		log_error "Refusing to recover an unrecognized forensic output transaction"
		return 1
	fi
	if [[ ! -f "${_DF_TRANSACTION_DIR}/${_DF_TRANSACTION_PREPARED}" ]]; then
		rm -rf "$_DF_TRANSACTION_DIR"
		return $?
	fi
	_df_restore_transaction_output "${_DF_TRANSACTION_DIR}/had-sidecar" \
		"${_DF_TRANSACTION_DIR}/sidecar.backup" "$_DF_SIDECAR_PATH" || rollback_ok=false
	_df_restore_transaction_output "${_DF_TRANSACTION_DIR}/had-readable" \
		"${_DF_TRANSACTION_DIR}/readable.backup" "$_DF_READABLE_PATH" || rollback_ok=false
	_df_restore_transaction_output "${_DF_TRANSACTION_DIR}/had-manifest" \
		"${_DF_TRANSACTION_DIR}/manifest.backup" "$_DF_MANIFEST_PATH" || rollback_ok=false
	if [[ "$rollback_ok" == true ]]; then
		rm -rf "$_DF_TRANSACTION_DIR"
		return $?
	fi
	log_error "Forensic output recovery failed; the durable transaction was retained"
	return 1
}

_df_prepare_output_transaction() {
	if ! _df_recover_interrupted_publication; then
		return 1
	fi
	if ! mkdir "$_DF_TRANSACTION_DIR" 2>/dev/null; then
		return 1
	fi
	if ! printf '%s\n' "$_DF_TRANSACTION_SCHEMA" >"${_DF_TRANSACTION_DIR}/schema" || \
		! _df_backup_transaction_output "$_DF_SIDECAR_PATH" \
			"${_DF_TRANSACTION_DIR}/had-sidecar" "${_DF_TRANSACTION_DIR}/sidecar.backup" || \
		! _df_backup_transaction_output "$_DF_READABLE_PATH" \
			"${_DF_TRANSACTION_DIR}/had-readable" "${_DF_TRANSACTION_DIR}/readable.backup" || \
		! _df_backup_transaction_output "$_DF_MANIFEST_PATH" \
			"${_DF_TRANSACTION_DIR}/had-manifest" "${_DF_TRANSACTION_DIR}/manifest.backup"; then
		rm -rf "$_DF_TRANSACTION_DIR"
		return 1
	fi
	if : >"${_DF_TRANSACTION_DIR}/${_DF_TRANSACTION_PREPARED}"; then
		return 0
	fi
	rm -rf "$_DF_TRANSACTION_DIR"
	return 1
}

_df_commit_output_transaction() {
	local committed_dir="${_DF_TRANSACTION_DIR}.committed.${_DF_TMP_DIR##*.}"

	if ! _df_move_directory_atomically "$_DF_TRANSACTION_DIR" "$committed_dir"; then
		return 1
	fi
	if ! rm -rf "$committed_dir"; then
		log_warn "Committed forensic transaction backup cleanup was deferred"
	fi
	return 0
}

_df_publish_forensic_outputs() {
	local manifest_tmp="$1"
	local publication_ok=false

	_df_prepare_output_transaction || return 1
	if _df_publish_atomic_file "$_DF_SIDECAR_TMP" "$_DF_SIDECAR_PATH"; then
		if [[ -n "$_DF_READABLE_TMP" ]] && [[ -f "$_DF_READABLE_TMP" ]]; then
			_df_publish_atomic_file "$_DF_READABLE_TMP" "$_DF_READABLE_PATH" && publication_ok=true
		elif rm -f "$_DF_READABLE_PATH"; then
			publication_ok=true
		fi
	fi
	if [[ "$publication_ok" == true ]] && _df_publish_atomic_file "$manifest_tmp" "$_DF_MANIFEST_PATH" && \
		_df_commit_output_transaction; then
		return 0
	fi
	if ! _df_recover_interrupted_publication; then
		log_error "Forensic output publication failed and requires transaction recovery"
	fi
	return 1
}

_df_assemble_readable_pdf() {
	local output_tmp="${_DF_TMP_DIR}/${_DF_STEM}.readable.pdf"
	local page=1
	local page_id=""
	local page_file=""
	local -a page_files=()

	while [[ "$page" -le "$_DF_PAGE_COUNT" ]]; do
		printf -v page_id '%04d' "$page"
		page_file="${_DF_TMP_DIR}/page-pdfs/${page_id}.pdf"
		if [[ ! -f "$page_file" ]]; then
			_df_record_failure "$page" "" "Readable derivative is missing a page"
			return 1
		fi
		page_files+=("$page_file")
		page=$((page + 1))
	done

	if [[ -n "${DOCUMENT_FORENSICS_PDF_ASSEMBLER:-}" ]]; then
		if ! "${DOCUMENT_FORENSICS_PDF_ASSEMBLER}" "$output_tmp" "${page_files[@]}"; then
			_df_record_failure 0 "" "Readable PDF assembly failed"
			return 1
		fi
	elif has_cmd pdfunite; then
		if ! pdfunite "${page_files[@]}" "$output_tmp" >/dev/null 2>&1; then
			_df_record_failure 0 "" "Readable PDF assembly failed"
			return 1
		fi
	else
		_df_record_failure 0 "" "pdfunite is unavailable"
		return 1
	fi

	if [[ ! -f "$output_tmp" ]]; then
		_df_record_failure 0 "" "Readable PDF output was not created"
		return 1
	fi
	if ! _df_verify_readable_pdf "$output_tmp"; then
		rm -f "$output_tmp"
		return 1
	fi
	_DF_READABLE_TMP="$output_tmp"
	return 0
}

_df_finalize_manifest() {
	local source_hash_before="$1"
	local source_hash_after="$2"
	local backend_version="$3"
	local pages_json="[]"
	local failures_json="[]"
	local sidecar_hash=""
	local readable_hash=""
	local readable_json="$_DF_VALUE_NULL"
	local manifest_tmp="${_DF_TMP_DIR}/manifest.json"

	pages_json=$(jq -s 'sort_by(.page)' "${_DF_TMP_DIR}"/pages/*.json)
	if [[ "$_DF_FAILURE_COUNT" -gt 0 ]]; then
		failures_json=$(jq -s '.' "${_DF_TMP_DIR}"/failures/*.json)
	fi
	sidecar_hash=$(_df_sha256 "$_DF_SIDECAR_TMP") || return 1
	if [[ "$_DF_WRITE_READABLE" == true ]] && [[ -f "$_DF_READABLE_TMP" ]]; then
		readable_hash=$(_df_sha256 "$_DF_READABLE_TMP") || return 1
		readable_json=$(jq -n \
			--arg path "readable/${_DF_STEM}.pdf" \
			--arg sha256 "$readable_hash" \
			'{path: $path, sha256: $sha256}')
	fi

	if [[ "$source_hash_before" != "$source_hash_after" ]] || [[ "$_DF_PAGE_SUCCESS_COUNT" -eq 0 ]]; then
		_DF_FINAL_STATUS="$_DF_STATUS_FAILED"
	elif [[ "$_DF_PAGE_FAILED_COUNT" -gt 0 ]] || [[ "$_DF_FAILURE_COUNT" -gt 0 ]]; then
		_DF_FINAL_STATUS="partial"
	else
		_DF_FINAL_STATUS="complete"
	fi

	jq -n \
		--arg schema "$DOCUMENT_FORENSICS_SCHEMA" \
		--arg status "$_DF_FINAL_STATUS" \
		--arg source_name "$(basename "$_DF_INPUT")" \
		--arg source_hash_before "$source_hash_before" \
		--arg source_hash_after "$source_hash_after" \
		--argjson page_count "$_DF_PAGE_COUNT" \
		--arg provider "$_DF_PROVIDER" \
		--arg backend_version "$backend_version" \
		--argjson dpi "$_DF_DPI" \
		--argjson min_text_chars "$_DF_MIN_TEXT_CHARS" \
		--argjson min_improvement "$_DF_MIN_IMPROVEMENT" \
		--argjson min_words "$_DF_MIN_WORDS" \
		--arg text_path "${_DF_STEM}.txt" \
		--arg text_hash "$sidecar_hash" \
		--arg manifest_path "${_DF_STEM}.manifest.json" \
		--argjson readable "$readable_json" \
		--argjson pages "$pages_json" \
		--argjson failures "$failures_json" \
		'{
			schema: $schema,
			status: $status,
			source: {name: $source_name, sha256: $source_hash_before, sha256_after: $source_hash_after, page_count: $page_count},
			backend: {provider: $provider, version: $backend_version, network_used: false},
			thresholds: {render_dpi: $dpi, min_text_chars: $min_text_chars, min_transform_improvement: $min_improvement, min_words: $min_words},
			outputs: {text: {path: $text_path, sha256: $text_hash}, readable_pdf: $readable, manifest: {path: $manifest_path}},
			pages: $pages,
			failures: $failures
		}' >"$manifest_tmp"
	if _df_publish_forensic_outputs "$manifest_tmp"; then
		return 0
	fi
	return 1
}

_df_validate_integer() {
	local value="$1"
	local minimum="$2"

	if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt "$minimum" ]]; then
		return 1
	fi
	return 0
}

_df_first_arg() {
	local value="$1"
	printf '%s' "$value"
	return 0
}

_df_second_arg() {
	local value="$2"
	printf '%s' "$value"
	return 0
}

_df_parse_forensics_args() {
	local current=""
	local value=""

	while [[ $# -gt 0 ]]; do
		current=$(_df_first_arg "$@")
		case "$current" in
		--output | -o | --provider | --ocr | --min-improvement | --min-text-chars | --dpi)
			if [[ $# -lt 2 ]]; then
				die "Missing value for ${current}"
				return 1
			fi
			value=$(_df_second_arg "$@")
			case "$current" in
			--output | -o) _DF_ARG_OUTPUT="$value" ;;
			--provider | --ocr) _DF_ARG_PROVIDER="$value" ;;
			--min-improvement)
				_df_validate_integer "$value" 1 || { die "--min-improvement must be a positive integer"; return 1; }
				_DF_MIN_IMPROVEMENT="$value"
				;;
			--min-text-chars)
				_df_validate_integer "$value" 1 || { die "--min-text-chars must be a positive integer"; return 1; }
				_DF_MIN_TEXT_CHARS="$value"
				;;
			--dpi)
				_df_validate_integer "$value" 72 || { die "--dpi must be an integer of at least 72"; return 1; }
				_DF_DPI="$value"
				;;
			esac
			shift 2
			;;
		--write-readable)
			_DF_WRITE_READABLE=true
			shift
			;;
		--help | -h)
			printf 'Usage: %s forensics <input.pdf> [--output DIR] [--provider NAME] [--write-readable] [--min-improvement N] [--dpi N]\n' "$SCRIPT_NAME"
			_DF_HELP_REQUESTED=true
			return 0
			;;
		--*)
			die "Unknown forensics option: ${current}"
			return 1
			;;
		*)
			if [[ -z "$_DF_ARG_INPUT" ]]; then
				_DF_ARG_INPUT="$current"
			else
				die "Only one PDF input is supported"
				return 1
			fi
			shift
			;;
		esac
	done
	return 0
}

_df_prepare_run() {
	local input_dir=""
	local input_name=""
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"

	if [[ -z "$_DF_ARG_INPUT" ]] || [[ ! -f "$_DF_ARG_INPUT" ]]; then
		die "PDF input not found: ${_DF_ARG_INPUT:-<missing>}"
		return 1
	fi
	if [[ "$(get_ext "$_DF_ARG_INPUT")" != "pdf" ]]; then
		die "Document forensics currently supports PDF input only"
		return 1
	fi
	if ! has_cmd jq || ! has_cmd python3 || ! has_cmd pdfinfo || ! has_cmd pdftotext || ! has_cmd pdftoppm; then
		die "Document forensics requires jq, Python 3, and Poppler (pdfinfo, pdftotext, pdftoppm)"
		return 1
	fi
	if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
		die "Document forensics requires a supported SHA-256 command"
		return 1
	fi

	if [[ -n "${DOCUMENT_FORENSICS_OCR_RUNNER:-}" ]]; then
		_DF_PROVIDER="$_DF_ARG_PROVIDER"
		[[ "$_DF_PROVIDER" == "$_DF_VALUE_AUTO" ]] && _DF_PROVIDER="fixture"
	elif [[ "$_DF_ARG_PROVIDER" == "$_DF_VALUE_AUTO" ]]; then
		if has_cmd tesseract; then
			_DF_PROVIDER="tesseract"
		elif has_python_pkg easyocr 2>/dev/null; then
			_DF_PROVIDER="easyocr"
		elif has_cmd ollama && ollama list 2>/dev/null | grep -q "glm-ocr"; then
			_DF_PROVIDER="glm-ocr"
		else
			_DF_PROVIDER="$_DF_PROVIDER_UNAVAILABLE"
		fi
	else
		_DF_PROVIDER=$(select_ocr_provider "$_DF_ARG_PROVIDER") || return 1
	fi

	input_dir=$(cd "$(dirname "$_DF_ARG_INPUT")" && pwd)
	input_name=$(basename "$_DF_ARG_INPUT")
	_DF_INPUT="${input_dir}/${input_name}"
	_DF_STEM="${input_name%.*}"
	if [[ -z "$_DF_ARG_OUTPUT" ]]; then
		_DF_ARG_OUTPUT="${input_dir}/forensics/${_DF_STEM}"
	fi
	_DF_OUTPUT_DIR="$_DF_ARG_OUTPUT"
	_DF_SIDECAR_PATH="${_DF_OUTPUT_DIR}/${_DF_STEM}.txt"
	_DF_MANIFEST_PATH="${_DF_OUTPUT_DIR}/${_DF_STEM}.manifest.json"
	_DF_READABLE_PATH="${_DF_OUTPUT_DIR}/readable/${_DF_STEM}.pdf"
	_DF_TRANSACTION_DIR="${_DF_OUTPUT_DIR}/.${_DF_STEM}.forensics.transaction"

	mkdir -p "$temp_root" "$_DF_OUTPUT_DIR"
	if [[ "$_DF_WRITE_READABLE" == true ]]; then
		mkdir -p "${_DF_OUTPUT_DIR}/readable"
	fi
	_DF_TMP_DIR=$(mktemp -d "${temp_root%/}/document-forensics.XXXXXX") || return 1
	trap '_df_cleanup' EXIT
	mkdir -p "${_DF_TMP_DIR}/candidates" "${_DF_TMP_DIR}/failures" \
		"${_DF_TMP_DIR}/page-pdfs" "${_DF_TMP_DIR}/pages" \
		"${_DF_TMP_DIR}/rendered" "${_DF_TMP_DIR}/source-pages" \
		"${_DF_TMP_DIR}/text-layer"
	_DF_SIDECAR_TMP="${_DF_TMP_DIR}/${_DF_STEM}.txt"
	: >"$_DF_SIDECAR_TMP"
	if ! _df_acquire_output_lock; then
		_df_cleanup
		return 1
	fi
	if ! _df_cleanup_committed_transactions || ! _df_recover_interrupted_publication; then
		_df_cleanup
		return 1
	fi

	_DF_SOURCE_HASH_BEFORE=$(_df_sha256 "$_DF_INPUT") || { _df_cleanup; return 1; }
	if ! _DF_PAGE_COUNT=$(pdf_page_count "$_DF_INPUT"); then
		_df_cleanup
		die "Unable to determine PDF page count"
		return 1
	fi
	if [[ -n "${DOCUMENT_FORENSICS_OCR_VERSION:-}" ]]; then
		_DF_BACKEND_VERSION="$DOCUMENT_FORENSICS_OCR_VERSION"
	else
		_DF_BACKEND_VERSION=$(ocr_provider_version "$_DF_PROVIDER")
	fi
	return 0
}

_df_execute_run() {
	local page=1

	log_info "Auditing ${_DF_PAGE_COUNT} PDF pages with ${_DF_PROVIDER}"
	while [[ "$page" -le "$_DF_PAGE_COUNT" ]]; do
		_df_process_page "$page"
		page=$((page + 1))
	done

	if [[ "$_DF_WRITE_READABLE" == true ]]; then
		_df_assemble_readable_pdf || true
	fi
	_DF_SOURCE_HASH_AFTER=$(_df_sha256 "$_DF_INPUT") || { _df_cleanup; return 1; }
	if [[ "$_DF_SOURCE_HASH_BEFORE" != "$_DF_SOURCE_HASH_AFTER" ]]; then
		_df_record_failure 0 "" "Source PDF hash changed during processing"
	fi
	if ! _df_finalize_manifest "$_DF_SOURCE_HASH_BEFORE" "$_DF_SOURCE_HASH_AFTER" "$_DF_BACKEND_VERSION"; then
		_df_cleanup
		return 1
	fi

	log_ok "Document forensics ${_DF_FINAL_STATUS}: ${_DF_MANIFEST_PATH}"
	_df_cleanup
	_DF_TMP_DIR=""
	case "$_DF_FINAL_STATUS" in
	complete) return 0 ;;
	partial) return 2 ;;
	*) return 1 ;;
	esac
}

cmd_document_forensics() {
	_df_reset_state
	_df_parse_forensics_args "$@" || return 1
	[[ "$_DF_HELP_REQUESTED" == true ]] && return 0
	_df_prepare_run || return 1
	_df_execute_run
	return $?
}
