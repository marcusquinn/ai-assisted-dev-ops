#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Read one field only after validating the complete key-value manifest. Keeping
# duplicate detection here prevents trust consumers from disagreeing about
# whether the first or last occurrence is authoritative.
runtime_bundle_manifest_value() {
	local manifest_file="$1"
	local requested_key="$2"
	local line=""
	local line_key=""
	local line_value=""
	local selected_value=""
	local seen_keys=$'\n'
	local found=0

	[[ -r "$manifest_file" ]] || return 1
	case "$requested_key" in
	'' | *[!a-zA-Z0-9_]*) return 1 ;;
	esac
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		*=*) ;;
		*) return 1 ;;
		esac
		line_key="${line%%=*}"
		line_value="${line#*=}"
		case "$line_key" in
		'' | *[!a-zA-Z0-9_]*) return 1 ;;
		esac
		case "$seen_keys" in
		*$'\n'"$line_key"$'\n'*) return 1 ;;
		esac
		seen_keys="${seen_keys}${line_key}"$'\n'
		if [[ "$line_key" == "$requested_key" ]]; then
			selected_value="$line_value"
			found=1
		fi
	done <"$manifest_file"
	[[ "$found" -eq 1 ]] || return 1
	printf '%s' "$selected_value"
	return 0
}
