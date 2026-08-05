#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Egress Library
# =============================================================================
# Private, metadata-only location and egress profile broker.
#
# Usage: source "${SCRIPT_DIR}/reach-egress-lib.sh"
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_EGRESS_LIB_LOADED:-}" ]] && return 0
_REACH_EGRESS_LIB_LOADED=1

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

_REACH_EGRESS_BOOL_FALSE=false
_REACH_EGRESS_BOOL_TRUE=true
_REACH_EGRESS_FORMAT_JSON=json
_REACH_EGRESS_PROFILE_CONFIGURED=configured
_REACH_EGRESS_SESSION_STABLE=stable
_REACH_EGRESS_JSON_PREFIX='{"schema_version":1,"profile_hash":'
_REACH_EGRESS_JSON_SAFE_SUFFIX=',"contacted_targets":false,"private_path_printed":false}'

# --- Validation ---

validate_egress_profile_name() {
	local profile_name="$1"
	if [[ ! "$profile_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
		log_error "--name must be 1-64 letters, numbers, dots, underscores, or hyphens"
		return 1
	fi
	return 0
}

validate_egress_country() {
	local country="$1"
	if [[ ! "$country" =~ ^[A-Z]{2}$ ]]; then
		log_error "--country must be a two-letter uppercase country code"
		return 1
	fi
	return 0
}

validate_egress_locale() {
	local locale="$1"
	if [[ ! "$locale" =~ ^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$ ]]; then
		log_error "--locale must be a language tag such as en-US"
		return 1
	fi
	return 0
}

validate_egress_timezone() {
	local timezone="$1"
	if [[ "$timezone" == "UTC" ]]; then
		return 0
	fi
	if [[ ! "$timezone" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)+$ ]]; then
		log_error "--timezone must be UTC or an IANA-style timezone"
		return 1
	fi
	return 0
}

validate_egress_location_detail() {
	local value="$1"
	local field_name="$2"
	if [[ ${#value} -gt 120 || "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]]; then
		log_error "$field_name must be a single line of at most 120 characters"
		return 1
	fi
	return 0
}

validate_egress_credential_ref() {
	local credential_ref="$1"
	if [[ ! "$credential_ref" =~ ^[A-Z][A-Z0-9_]{1,127}$ ]]; then
		log_error "--credential-ref must be an aidevops secret name, not a URL or credential value"
		return 1
	fi
	return 0
}

# --- Private metadata ---

egress_storage_is_safe() {
	local egress_dir=""
	local workspace_dir=""
	egress_dir="$(reach_egress_dir)"
	workspace_dir="$(reach_workspace_dir)"
	if [[ -L "$workspace_dir" || -L "$egress_dir" ]]; then
		return 1
	fi
	return 0
}

write_egress_profile_json() {
	local profile_file="$1"
	local profile_name="$2"
	local browser_class="$3"
	local egress_class="$4"
	local usage_scope="$5"
	local session_mode="$6"
	local country="$7"
	local region="$8"
	local city="$9"
	local timezone="${10}"
	local locale="${11}"
	local credential_ref="${12}"
	local created_at="${13}"
	local notes="${14}"
	local force="${15}"

	python3 "${SCRIPT_DIR}/_reach_egress_storage.py" write \
		"$profile_file" "$profile_name" "$browser_class" "$egress_class" \
		"$usage_scope" "$session_mode" "$country" "$region" "$city" \
		"$timezone" "$locale" "$credential_ref" "$created_at" "$notes" "$force"
	return $?
}

clear_egress_profile_file() {
	local profile_file="$1"
	python3 "${SCRIPT_DIR}/_reach_egress_storage.py" clear "$profile_file"
	return $?
}

egress_json_profile_hash() {
	local profile_name="$1"
	local profile_hash
	profile_hash=$(safe_hash "$profile_name")
	json_escape "$profile_hash"
	return 0
}

emit_egress_refused_overwrite_json() {
	local profile_name="$1"
	local profile_hash
	profile_hash=$(egress_json_profile_hash "$profile_name")
	printf '%s"%s","profile_status":"%s","refused_overwrite":true%s\n' \
		"$_REACH_EGRESS_JSON_PREFIX" "$profile_hash" \
		"$_REACH_EGRESS_PROFILE_CONFIGURED" "$_REACH_EGRESS_JSON_SAFE_SUFFIX"
	return 0
}

emit_egress_status_json() {
	local profile_name="$1"
	local profile_file=""
	local profile_status="missing"
	local profile_hash=""
	local browser_class=""
	local egress_class=""
	local usage_scope=""
	local session_mode=""
	local country=""
	local region=""
	local city=""
	local timezone=""
	local locale=""
	local credential_ref=""
	local region_configured="$_REACH_EGRESS_BOOL_FALSE"
	local city_configured="$_REACH_EGRESS_BOOL_FALSE"
	local credential_ref_present="$_REACH_EGRESS_BOOL_FALSE"

	profile_file="$(egress_file_for_profile "$profile_name")"
	if ! egress_storage_is_safe || [[ -L "$profile_file" ]]; then
		profile_status="invalid"
	elif [[ -f "$profile_file" ]]; then
		profile_status="$_REACH_EGRESS_PROFILE_CONFIGURED"
		browser_class=$(json_field_value "$profile_file" "browser_class" 2>/dev/null || true)
		egress_class=$(json_field_value "$profile_file" "egress_class" 2>/dev/null || true)
		usage_scope=$(json_field_value "$profile_file" "usage_scope" 2>/dev/null || true)
		session_mode=$(json_field_value "$profile_file" "session_mode" 2>/dev/null || true)
		country=$(json_field_value "$profile_file" "country" 2>/dev/null || true)
		region=$(json_field_value "$profile_file" "region" 2>/dev/null || true)
		city=$(json_field_value "$profile_file" "city" 2>/dev/null || true)
		timezone=$(json_field_value "$profile_file" "timezone" 2>/dev/null || true)
		locale=$(json_field_value "$profile_file" "locale" 2>/dev/null || true)
		credential_ref=$(json_field_value "$profile_file" "credential_ref" 2>/dev/null || true)
	fi
	if [[ -n "$region" ]]; then
		region_configured="$_REACH_EGRESS_BOOL_TRUE"
	fi
	if [[ -n "$city" ]]; then
		city_configured="$_REACH_EGRESS_BOOL_TRUE"
	fi
	if [[ -n "$credential_ref" ]]; then
		credential_ref_present="$_REACH_EGRESS_BOOL_TRUE"
	fi

	profile_hash=$(egress_json_profile_hash "$profile_name")
	printf '%s"%s","profile_status":"%s","browser_class":"%s","egress_class":"%s","usage_scope":"%s","session_mode":"%s","country":"%s","region_configured":%s,"city_configured":%s,"timezone":"%s","locale":"%s","credential_ref_present":%s,"sensitivity":"private"%s\n' \
		"$_REACH_EGRESS_JSON_PREFIX" "$profile_hash" \
		"$(json_escape "$profile_status")" \
		"$(json_escape "$browser_class")" \
		"$(json_escape "$egress_class")" \
		"$(json_escape "$usage_scope")" \
		"$(json_escape "$session_mode")" \
		"$(json_escape "$country")" \
		"$(json_bool "$region_configured")" \
		"$(json_bool "$city_configured")" \
		"$(json_escape "$timezone")" \
		"$(json_escape "$locale")" \
		"$(json_bool "$credential_ref_present")" \
		"$_REACH_EGRESS_JSON_SAFE_SUFFIX"
	return 0
}

# --- Command handlers ---

reset_egress_register_args() {
	EGRESS_REGISTER_PROFILE_NAME=""
	EGRESS_REGISTER_BROWSER_CLASS="brave"
	EGRESS_REGISTER_EGRESS_CLASS="direct"
	EGRESS_REGISTER_USAGE_SCOPE="public"
	EGRESS_REGISTER_SESSION_MODE="$_REACH_EGRESS_SESSION_STABLE"
	EGRESS_REGISTER_COUNTRY=""
	EGRESS_REGISTER_REGION=""
	EGRESS_REGISTER_CITY=""
	EGRESS_REGISTER_TIMEZONE=""
	EGRESS_REGISTER_LOCALE=""
	EGRESS_REGISTER_CREDENTIAL_REF=""
	EGRESS_REGISTER_NOTES=""
	EGRESS_REGISTER_FORCE="$_REACH_EGRESS_BOOL_FALSE"
	EGRESS_REGISTER_FORMAT="$_REACH_EGRESS_FORMAT_JSON"
	return 0
}

parse_egress_register_args() {
	local arg=""
	reset_egress_register_args
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
			--name) shift; EGRESS_REGISTER_PROFILE_NAME="${1:-}" ;;
			--browser) shift; EGRESS_REGISTER_BROWSER_CLASS="${1:-}" ;;
			--class | --egress-class) shift; EGRESS_REGISTER_EGRESS_CLASS="${1:-}" ;;
			--scope) shift; EGRESS_REGISTER_USAGE_SCOPE="${1:-}" ;;
			--session-mode) shift; EGRESS_REGISTER_SESSION_MODE="${1:-}" ;;
			--country) shift; EGRESS_REGISTER_COUNTRY="${1:-}" ;;
			--region) shift; EGRESS_REGISTER_REGION="${1:-}" ;;
			--city) shift; EGRESS_REGISTER_CITY="${1:-}" ;;
			--timezone) shift; EGRESS_REGISTER_TIMEZONE="${1:-}" ;;
			--locale) shift; EGRESS_REGISTER_LOCALE="${1:-}" ;;
			--credential-ref) shift; EGRESS_REGISTER_CREDENTIAL_REF="${1:-}" ;;
			--notes) shift; EGRESS_REGISTER_NOTES="${1:-}" ;;
			--force) EGRESS_REGISTER_FORCE="$_REACH_EGRESS_BOOL_TRUE" ;;
			--format) shift; EGRESS_REGISTER_FORMAT="${1:-}" ;;
			*) log_error "Unknown egress register option"; return 1 ;;
		esac
		shift || true
	done
	return 0
}

validate_egress_class_credential() {
	case "$EGRESS_REGISTER_EGRESS_CLASS" in
		socks5 | residential | isp | mobile)
			if [[ -z "$EGRESS_REGISTER_CREDENTIAL_REF" ]]; then
				log_error "$EGRESS_REGISTER_EGRESS_CLASS profiles require --credential-ref"
				return 1
			fi
			;;
		direct)
			if [[ -n "$EGRESS_REGISTER_CREDENTIAL_REF" ]]; then
				log_error "direct profiles must not include --credential-ref"
				return 1
			fi
			;;
		vpn) ;;
	esac
	if [[ -n "$EGRESS_REGISTER_CREDENTIAL_REF" ]]; then
		validate_egress_credential_ref "$EGRESS_REGISTER_CREDENTIAL_REF" || return 1
	fi
	return 0
}

validate_egress_registration() {
	require_json_format "$EGRESS_REGISTER_FORMAT" || return 1
	if [[ -z "$EGRESS_REGISTER_PROFILE_NAME" || -z "$EGRESS_REGISTER_COUNTRY" || -z "$EGRESS_REGISTER_TIMEZONE" || -z "$EGRESS_REGISTER_LOCALE" ]]; then
		log_error "egress register requires --name, --country, --timezone, and --locale"
		return 1
	fi
	EGRESS_REGISTER_COUNTRY="$(printf '%s' "$EGRESS_REGISTER_COUNTRY" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
	validate_egress_profile_name "$EGRESS_REGISTER_PROFILE_NAME" || return 1
	validate_egress_country "$EGRESS_REGISTER_COUNTRY" || return 1
	validate_egress_timezone "$EGRESS_REGISTER_TIMEZONE" || return 1
	validate_egress_locale "$EGRESS_REGISTER_LOCALE" || return 1
	validate_egress_location_detail "$EGRESS_REGISTER_REGION" "--region" || return 1
	validate_egress_location_detail "$EGRESS_REGISTER_CITY" "--city" || return 1

	case "$EGRESS_REGISTER_BROWSER_CLASS" in
		brave | chromium | edge | chrome | firefox | mullvad) ;;
		*) log_error "--browser must be brave, chromium, edge, chrome, firefox, or mullvad"; return 1 ;;
	esac
	case "$EGRESS_REGISTER_EGRESS_CLASS" in
		direct | vpn | socks5 | residential | isp | mobile) ;;
		*) log_error "--class must be direct, vpn, socks5, residential, isp, or mobile"; return 1 ;;
	esac
	case "$EGRESS_REGISTER_USAGE_SCOPE" in
		public | account) ;;
		*) log_error "--scope must be public or account"; return 1 ;;
	esac
	case "$EGRESS_REGISTER_SESSION_MODE" in
		stable | rotating) ;;
		*) log_error "--session-mode must be stable or rotating"; return 1 ;;
	esac
	if [[ "$EGRESS_REGISTER_USAGE_SCOPE" == "account" && "$EGRESS_REGISTER_SESSION_MODE" != "$_REACH_EGRESS_SESSION_STABLE" ]]; then
		log_error "account-scoped egress profiles require stable sessions"
		return 1
	fi
	if [[ "$EGRESS_REGISTER_EGRESS_CLASS" == "direct" && "$EGRESS_REGISTER_SESSION_MODE" != "$_REACH_EGRESS_SESSION_STABLE" ]]; then
		log_error "direct egress profiles cannot declare rotation"
		return 1
	fi
	validate_egress_class_credential || return 1
	EGRESS_REGISTER_NOTES="$(sanitize_text "$EGRESS_REGISTER_NOTES")"
	if [[ ${#EGRESS_REGISTER_NOTES} -gt 240 ]]; then
		log_error "--notes must be at most 240 characters"
		return 1
	fi
	return 0
}

persist_egress_registration() {
	local profile_file=""
	local created_at=""
	local write_status=0
	if ! egress_storage_is_safe; then
		log_error "egress profile storage is unsafe"
		return 1
	fi
	ensure_private_dir "$(reach_workspace_dir)"
	ensure_private_dir "$(reach_egress_dir)"
	profile_file="$(egress_file_for_profile "$EGRESS_REGISTER_PROFILE_NAME")"
	if [[ ( -f "$profile_file" || -L "$profile_file" ) && "$EGRESS_REGISTER_FORCE" != "$_REACH_EGRESS_BOOL_TRUE" ]]; then
		emit_egress_refused_overwrite_json "$EGRESS_REGISTER_PROFILE_NAME"
		return 2
	fi
	created_at="$(epoch_to_iso "$(now_epoch)")"
	write_egress_profile_json \
		"$profile_file" \
		"$EGRESS_REGISTER_PROFILE_NAME" \
		"$EGRESS_REGISTER_BROWSER_CLASS" \
		"$EGRESS_REGISTER_EGRESS_CLASS" \
		"$EGRESS_REGISTER_USAGE_SCOPE" \
		"$EGRESS_REGISTER_SESSION_MODE" \
		"$EGRESS_REGISTER_COUNTRY" \
		"$EGRESS_REGISTER_REGION" \
		"$EGRESS_REGISTER_CITY" \
		"$EGRESS_REGISTER_TIMEZONE" \
		"$EGRESS_REGISTER_LOCALE" \
		"$EGRESS_REGISTER_CREDENTIAL_REF" \
		"$created_at" \
		"$EGRESS_REGISTER_NOTES" \
		"$EGRESS_REGISTER_FORCE" || write_status=$?
	if [[ $write_status -eq 2 ]]; then
		emit_egress_refused_overwrite_json "$EGRESS_REGISTER_PROFILE_NAME"
		return 2
	fi
	if [[ $write_status -ne 0 ]]; then
		log_error "egress profile persistence failed"
		return 1
	fi
	emit_egress_status_json "$EGRESS_REGISTER_PROFILE_NAME"
	return 0
}

handle_egress_register() {
	parse_egress_register_args "$@" || return 1
	validate_egress_registration || return 1
	persist_egress_registration
	return $?
}

handle_egress_status() {
	local profile_name=""
	local format="$_REACH_EGRESS_FORMAT_JSON"
	local arg=""
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
			--name) shift; profile_name="${1:-}" ;;
			--format) shift; format="${1:-}" ;;
			*) log_error "Unknown egress status option"; return 1 ;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	validate_egress_profile_name "$profile_name" || return 1
	emit_egress_status_json "$profile_name"
	return 0
}

handle_egress_clear() {
	local profile_name=""
	local format="$_REACH_EGRESS_FORMAT_JSON"
	local arg=""
	local profile_hash=""
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
			--name) shift; profile_name="${1:-}" ;;
			--format) shift; format="${1:-}" ;;
			*) log_error "Unknown egress clear option"; return 1 ;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	validate_egress_profile_name "$profile_name" || return 1
	local profile_file=""
	local cleared="$_REACH_EGRESS_BOOL_FALSE"
	local clear_status=0
	if ! egress_storage_is_safe; then
		log_error "egress profile storage is unsafe"
		return 1
	fi
	profile_file="$(egress_file_for_profile "$profile_name")"
	clear_egress_profile_file "$profile_file" || clear_status=$?
	case "$clear_status" in
		0) cleared="$_REACH_EGRESS_BOOL_TRUE" ;;
		3) cleared="$_REACH_EGRESS_BOOL_FALSE" ;;
		*) log_error "egress profile cleanup refused unsafe storage"; return 1 ;;
	esac
	profile_hash=$(egress_json_profile_hash "$profile_name")
	printf '%s"%s","cleared":%s%s\n' \
		"$_REACH_EGRESS_JSON_PREFIX" "$profile_hash" \
		"$(json_bool "$cleared")" "$_REACH_EGRESS_JSON_SAFE_SUFFIX"
	return 0
}

handle_egress() {
	local subcommand="${1:-}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$subcommand" in
		register) handle_egress_register "$@"; return $? ;;
		status) handle_egress_status "$@"; return $? ;;
		clear) handle_egress_clear "$@"; return $? ;;
		*) log_error "egress requires register, status, or clear"; return 1 ;;
	esac
}
