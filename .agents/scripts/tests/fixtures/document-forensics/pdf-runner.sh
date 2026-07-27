#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

fixture_field() {
	local field="$1"
	local file="$2"
	awk -F '=' -v wanted="$field" '$1 == wanted { value = $2 } END { print value }' "$file"
	return 0
}

file_hash() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{ value = $1 } END { print value }'
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{ value = $1 } END { print value }'
		return 0
	fi
	return 1
}

image="$1"
text_file="$2"
output="$3"
dpi="$4"
if [[ "${DOCUMENT_FORENSICS_PDF_RUNNER_FAIL:-0}" == "1" ]]; then
	exit 8
fi
kind=$(fixture_field KIND "$image")
page=$(fixture_field PAGE "$image")
transform=$(fixture_field TRANSFORM "$image")
canvas=$(fixture_field CANVAS "$image")
dimensions="${DOCUMENT_FORENSICS_PDF_DIMENSIONS:-612x792}"
text_hash=$(file_hash "$text_file")
printf 'PAGE_PDF kind=%s page=%s transform=%s canvas=%s dimensions=%s dpi=%s text_sha256=%s\n' \
	"$kind" "$page" "$transform" "$canvas" "$dimensions" "$dpi" "$text_hash" >"$output"
