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

input="$1"
transform="$2"
output="$3"
dpi="$4"
kind=$(fixture_field KIND "$input")
page=$(fixture_field PAGE "$input")
canvas=$(fixture_field CANVAS "$input")
printf 'KIND=%s\nPAGE=%s\nTRANSFORM=%s\nCANVAS=%s\nDPI=%s\n' \
	"$kind" "$page" "$transform" "$canvas" "$dpi" >"$output"
