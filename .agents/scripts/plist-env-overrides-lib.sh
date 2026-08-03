#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared plist environment override helpers for launchd scheduler generators.

[[ -n "${_PLIST_ENV_OVERRIDES_LIB_LOADED:-}" ]] && return 0
_PLIST_ENV_OVERRIDES_LIB_LOADED=1

_plist_env_overrides_file() {
	local stable_file="$HOME/.config/aidevops/plist-env-overrides.json"
	local legacy_file="$HOME/.aidevops/agents/configs/plist-env-overrides.json"

	if [[ -f "$stable_file" ]]; then
		printf '%s' "$stable_file"
	elif [[ -f "$legacy_file" ]]; then
		printf '%s' "$legacy_file"
	else
		printf '%s' "$stable_file"
	fi
	return 0
}

_plist_env_xml_escape() {
	local value="$1"
	value="${value//&/\&amp;}"
	value="${value//</\&lt;}"
	value="${value//>/\&gt;}"
	value="${value//\"/\&quot;}"
	value="${value//\'/\&apos;}"
	printf '%s' "$value"
	return 0
}

_build_plist_env_overrides_xml() {
	local label="$1"
	local override_file="${2:-}"
	local indent="${3:-		}"
	[[ -n "$override_file" ]] || override_file=$(_plist_env_overrides_file)

	[[ -f "$override_file" ]] || return 0
	if ! command -v jq >/dev/null 2>&1; then
		echo "[schedulers] WARN: jq not found; skipping plist-env-overrides.json injection" >&2
		return 0
	fi
	if ! jq empty "$override_file" 2>/dev/null; then
		echo "[schedulers] WARN: plist-env-overrides.json is malformed; skipping injection (file: $override_file)" >&2
		return 0
	fi

	local pairs
	pairs=$(jq -r --arg label "$label" '
		.[$label] // {} |
		to_entries[] |
		select(.key | startswith("_") | not) |
		"\(.key)=\(.value)"
	' "$override_file" 2>/dev/null) || return 0
	[[ -n "$pairs" ]] || return 0

	local line key value xml_key xml_value
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		key="${line%%=*}"
		value="${line#*=}"
		xml_key=$(_plist_env_xml_escape "$key")
		xml_value=$(_plist_env_xml_escape "$value")
		printf '%s<key>%s</key>\n%s<string>%s</string>\n' \
			"$indent" "$xml_key" "$indent" "$xml_value"
	done <<<"$pairs"
	return 0
}
