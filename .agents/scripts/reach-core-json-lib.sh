#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Core JSON Library
# =============================================================================
# JSON escaping, path, hashing, time, and capture naming helpers.
#
# Usage: source "${SCRIPT_DIR}/reach-core-json-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_CORE_JSON_LIB_LOADED:-}" ]] && return 0
_REACH_CORE_JSON_LIB_LOADED=1

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

json_bool() {
	local value="$1"
	if [[ "$value" == "true" ]]; then
		printf 'true'
		return 0
	fi
	printf 'false'
	return 0
}

json_escape() {
	local input="$1"
	local output=""
	local char=""
	local i=0
	local length=${#input}

	while [[ $i -lt $length ]]; do
		char="${input:i:1}"
		case "$char" in
			'"') output+="\\\"" ;;
			\\) output+="\\\\" ;;
			$'\n') output+="\\n" ;;
			$'\r') output+="\\r" ;;
			$'\t') output+="\\t" ;;
			*) output+="$char" ;;
		esac
		i=$((i + 1))
	done

	printf '%s' "$output"
	return 0
}

sanitize_text() {
	local input="$1"
	local sanitized="$input"

	sanitized="${sanitized//http:\/\//redacted-url}"
	sanitized="${sanitized//https:\/\//redacted-url}"
	sanitized="${sanitized//@/ at-redacted }"
	sanitized="${sanitized//${HOME:-__NO_HOME__}/~}"
	printf '%s' "$sanitized"
	return 0
}

reach_workspace_dir() {
	printf '%s' "${AIDEVOPS_REACH_WORKSPACE:-${HOME}/.aidevops/.agent-workspace/reach}"
	return 0
}

reach_lease_dir() {
	printf '%s/leases' "$(reach_workspace_dir)"
	return 0
}

reach_cookie_dir() {
	printf '%s/cookie-sessions' "$(reach_workspace_dir)"
	return 0
}

reach_egress_dir() {
	printf '%s/egress-profiles' "$(reach_workspace_dir)"
	return 0
}

ensure_private_dir() {
	local dir_path="$1"
	mkdir -p "$dir_path"
	chmod 700 "$dir_path" 2>/dev/null || true
	return 0
}

safe_key() {
	local input="$1"
	local sanitized=""
	sanitized="$(printf '%s' "$input" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
	sanitized="${sanitized##_}"
	sanitized="${sanitized%%_}"
	if [[ -z "$sanitized" ]]; then
		sanitized="target"
	fi
	printf '%s' "$sanitized"
	return 0
}

safe_hash() {
	local input="$1"
	local hash_value=""
	if command_available sha256sum; then
		# shell-portability: ignore next -- guarded by command_available; shasum/python3 fallbacks cover macOS.
		hash_value="$(printf '%s' "$input" | sha256sum | cut -d' ' -f1)"
	elif command_available shasum; then
		hash_value="$(printf '%s' "$input" | shasum -a 256 | cut -d' ' -f1)"
	elif command_available python3; then
		hash_value="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <<<"$input")"
	else
		hash_value="$REACH_VAL_UNAVAILABLE"
	fi
	printf '%s' "${hash_value:0:16}"
	return 0
}

safe_sha256() {
	local input="$1"
	local hash_value=""
	if command_available sha256sum; then
		# shell-portability: ignore next -- guarded by command_available; shasum/python3 fallbacks cover macOS.
		hash_value="$(printf '%s' "$input" | sha256sum | cut -d' ' -f1)"
	elif command_available shasum; then
		hash_value="$(printf '%s' "$input" | shasum -a 256 | cut -d' ' -f1)"
	elif command_available python3; then
		hash_value="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <<<"$input")"
	else
		hash_value="$REACH_VAL_UNAVAILABLE"
	fi
	printf '%s' "$hash_value"
	return 0
}

file_sha256() {
	local file_path="$1"
	local hash_value=""
	if command_available sha256sum; then
		# shell-portability: ignore next -- guarded by command_available; shasum/python3 fallbacks cover macOS.
		hash_value="$(sha256sum "$file_path" | cut -d' ' -f1)"
	elif command_available shasum; then
		hash_value="$(shasum -a 256 "$file_path" | cut -d' ' -f1)"
	elif command_available python3; then
		hash_value="$(python3 - "$file_path" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
)"
	else
		hash_value="$REACH_VAL_UNAVAILABLE"
	fi
	printf '%s' "$hash_value"
	return 0
}

file_bytes() {
	local file_path="$1"
	local byte_count=""
	if byte_count="$(wc -c <"$file_path")"; then
		byte_count="${byte_count//[[:space:]]/}"
		printf '%s' "$byte_count"
		return 0
	fi
	printf '0'
	return 0
}

now_epoch() {
	if command_available python3; then
		python3 -c 'import time; print(int(time.time()))'
		return 0
	fi
	date +%s
	return 0
}

reach_session_ref() {
	local session_source="${AIDEVOPS_SESSION_ID:-${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}"
	if [[ -n "$session_source" ]]; then
		printf 'session:%s' "$(safe_hash "$session_source")"
		return 0
	fi
	printf '%s' 'session:unavailable'
	return 0
}

reach_performance_log_path() {
	if [[ -n "${AIDEVOPS_REACH_PERFORMANCE_LOG:-}" ]]; then
		printf '%s' "$AIDEVOPS_REACH_PERFORMANCE_LOG"
		return 0
	fi
	if [[ -d ".git" || -f ".git" || -d "_inbox" || -d "_knowledge" || -d "_performance" ]]; then
		mkdir -p "_performance"
		printf '%s' '_performance/reach-capture.jsonl'
		return 0
	fi
	local workspace_dir="${AIDEVOPS_WORKSPACE:-${HOME}/.aidevops/.agent-workspace}"
	mkdir -p "${workspace_dir}/performance"
	printf '%s' "${workspace_dir}/performance/reach-capture.jsonl"
	return 0
}

json_field_default() {
	local json_text="$1"
	local field_name="$2"
	local default_value="$3"
	if ! command_available python3; then
		printf '%s' "$default_value"
		return 0
	fi
	python3 - "$json_text" "$field_name" "$default_value" <<'PY'
import json
import sys

json_text, field_name, default = sys.argv[1:]
try:
    data = json.loads(json_text)
except Exception:
    data = {}
value = data.get(field_name, default)
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
	return 0
}

epoch_to_iso() {
	local epoch_value="$1"
	if command_available python3; then
		python3 - "$epoch_value" <<'PY'
import datetime
import sys

timestamp = int(sys.argv[1])
if hasattr(datetime, "UTC"):
    dt = datetime.datetime.fromtimestamp(timestamp, datetime.UTC)
else:
    dt = datetime.datetime.utcfromtimestamp(timestamp)
print(dt.replace(microsecond=0, tzinfo=None).isoformat() + "Z")
PY
		return 0
	fi
	date -u -r "$epoch_value" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$epoch_value" '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

epoch_to_stamp() {
	local epoch_value="$1"
	if command_available python3; then
		python3 - "$epoch_value" <<'PY'
import datetime
import sys

timestamp = int(sys.argv[1])
if hasattr(datetime, "UTC"):
    dt = datetime.datetime.fromtimestamp(timestamp, datetime.UTC)
else:
    dt = datetime.datetime.utcfromtimestamp(timestamp)
print(dt.strftime("%Y%m%dT%H%M%SZ"))
PY
		return 0
	fi
	date -u -r "$epoch_value" '+%Y%m%dT%H%M%SZ' 2>/dev/null || date -u -d "@$epoch_value" '+%Y%m%dT%H%M%SZ'
	return 0
}

relative_path() {
	local file_path="$1"
	local root_path="${2:-$PWD}"
	if [[ "$file_path" == "$root_path"/* ]]; then
		printf '%s' "${file_path#"$root_path"/}"
		return 0
	fi
	printf '%s' "$file_path"
	return 0
}

capture_source_label() {
	local input_ref="$1"
	local method_value="$2"
	local label=""
	if [[ "$method_value" == "$REACH_VAL_FILE" && -f "$input_ref" ]]; then
		label="local-file:$(basename "$input_ref")"
	elif [[ "$input_ref" =~ ^https?:// ]]; then
		label="url:$(safe_hash "$input_ref")"
	else
		label="input:$(safe_hash "$input_ref")"
	fi
	printf '%s' "$(sanitize_text "$label")"
	return 0
}

capture_slug() {
	local input_ref="$1"
	local method_value="$2"
	local slug_source=""
	if [[ "$method_value" == "$REACH_VAL_FILE" && -f "$input_ref" ]]; then
		slug_source="$(basename "$input_ref")"
	else
		slug_source="capture-$(safe_hash "$input_ref")"
	fi
	safe_key "$slug_source"
	return 0
}

parse_ttl_seconds() {
	local ttl_value="$1"
	local amount=""
	local unit=""
	if [[ ! "$ttl_value" =~ ^[0-9]+[smhd]?$ ]]; then
		log_error "TTL must be digits with optional s, m, h, or d suffix"
		return 1
	fi
	amount="${ttl_value%[smhd]}"
	unit="${ttl_value:${#amount}:1}"
	case "$unit" in
		"" | s) printf '%s' "$amount" ;;
		m) printf '%s' "$((amount * 60))" ;;
		h) printf '%s' "$((amount * 3600))" ;;
		d) printf '%s' "$((amount * 86400))" ;;
		*) log_error "Unsupported TTL unit: $unit"; return 1 ;;
	esac
	return 0
}
