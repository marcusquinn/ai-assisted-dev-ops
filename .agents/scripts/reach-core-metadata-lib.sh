#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Core Metadata Library
# =============================================================================
# Metadata expiry, command detection, and capability availability helpers.
#
# Usage: source "${SCRIPT_DIR}/reach-core-metadata-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_CORE_METADATA_LIB_LOADED:-}" ]] && return 0
_REACH_CORE_METADATA_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091  # shared constants resolved at runtime via $SCRIPT_DIR
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# --- Functions ---

json_field_value() {
	local file_path="$1"
	local field_name="$2"
	if [[ ! -f "$file_path" ]]; then
		return 1
	fi
	if ! command_available python3; then
		return 1
	fi
	python3 - "$file_path" "$field_name" <<'PY'
import json
import sys

ENCODING = "utf-8"

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(sys.argv[2], "")
print(value)
PY
	return $?
}

iso_to_epoch() {
	local iso_value="$1"
	if [[ -z "$iso_value" ]]; then
		printf '0'
		return 0
	fi
	if ! command_available python3; then
		printf '0'
		return 0
	fi
	python3 - "$iso_value" <<'PY'
import datetime
import sys

value = sys.argv[1]
try:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    print(int(datetime.datetime.fromisoformat(value).timestamp()))
except Exception:
    print(0)
PY
	return 0
}

lease_file_for_target() {
	local target_key="$1"
	printf '%s/%s.json' "$(reach_lease_dir)" "$(safe_key "$target_key")"
	return 0
}

cookie_file_for_target() {
	local target_key="$1"
	printf '%s/%s.json' "$(reach_cookie_dir)" "$(safe_key "$target_key")"
	return 0
}

egress_file_for_profile() {
	local profile_name="$1"
	printf '%s/%s.json' "$(reach_egress_dir)" "$(safe_key "$profile_name")"
	return 0
}

metadata_is_unexpired() {
	local file_path="$1"
	local expires_at=""
	local expires_epoch="0"
	local current_epoch="0"
	expires_at="$(json_field_value "$file_path" "expires_at" 2>/dev/null || true)"
	expires_epoch="$(iso_to_epoch "$expires_at")"
	current_epoch="$(now_epoch)"
	if [[ "$expires_epoch" -gt "$current_epoch" ]]; then
		return 0
	fi
	return 1
}

count_unexpired_metadata() {
	local dir_path="$1"
	local count="0"
	local metadata_file=""
	if [[ ! -d "$dir_path" ]]; then
		printf '0'
		return 0
	fi
	for metadata_file in "$dir_path"/*.json; do
		[[ -e "$metadata_file" ]] || continue
		if metadata_is_unexpired "$metadata_file"; then
			count=$((count + 1))
		fi
	done
	printf '%s' "$count"
	return 0
}

command_available() {
	local command_name="$1"
	if [[ "${AIDEVOPS_REACH_TEST_FORCE_MISSING:-}" == "1" ]]; then
		return 1
	fi
	if command -v "$command_name" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

helper_available() {
	local helper_name="$1"
	if [[ "${AIDEVOPS_REACH_TEST_FORCE_MISSING:-}" == "1" ]]; then
		return 1
	fi
	if [[ -x "${SCRIPT_DIR}/${helper_name}" ]]; then
		return 0
	fi
	if command -v "$helper_name" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

capability_available() {
	local capability_key="$1"
	if [[ "${AIDEVOPS_REACH_TEST_FORCE_MISSING:-}" == "1" ]]; then
		return 1
	fi
	case "$capability_key" in
		fetch)
			if command_available curl || command_available python3; then
				return 0
			fi
			;;
		crawler)
			if helper_available crawl4ai-helper.sh || helper_available watercrawl-helper.sh || helper_available site-crawler-helper.sh; then
				return 0
			fi
			;;
		browser)
			if helper_available agent-browser-helper.sh || helper_available browser-qa-helper.sh || command_available playwright; then
				return 0
			fi
			;;
		persistent_profile)
			if helper_available dev-browser-helper.sh || [[ -d "${HOME}/.aidevops/.agent-workspace/browser-profiles" ]]; then
				return 0
			fi
			;;
		cookie_session)
			if command_available sweet-cookie || helper_available anti-detect-helper.sh; then
				return 0
			fi
			;;
		anti_detect_profile | proxy_vpn)
			if helper_available anti-detect-helper.sh; then
				return 0
			fi
			;;
		inbox_capture)
			if helper_available inbox-helper.sh; then
				return 0
			fi
			;;
		knowledge_staging)
			if helper_available knowledge-helper.sh; then
				return 0
			fi
			;;
		performance_logging)
			if helper_available resource-metrics-helper.sh || helper_available report-token-use-helper.sh; then
				return 0
			fi
			;;
		feedback_mining)
			if helper_available quality-feedback-helper.sh || helper_available findings-to-tasks-helper.sh; then
				return 0
			fi
			;;
		*)
			return 1
			;;
	esac
	return 1
}
