#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Resolve and manage an expiring operator pin for the Pulse runtime only.
# Normal aidevops activation continues while Pulse remains on one validated
# immutable bundle for controlled observations and other bounded diagnostics.

if [[ "${_AIDEVOPS_PULSE_RUNTIME_PIN_LOADED:-0}" == "1" ]]; then
	return 0 2>/dev/null || exit 0
fi
_AIDEVOPS_PULSE_RUNTIME_PIN_LOADED=1

_PULSE_RUNTIME_PIN_SCHEMA=""
_PULSE_RUNTIME_PIN_ROOT=""
_PULSE_RUNTIME_PIN_CREATED=""
_PULSE_RUNTIME_PIN_EXPIRES=""
_PULSE_RUNTIME_PIN_MAX_SECONDS=172800

pulse_runtime_pin_config_path() {
	printf '%s\n' "${AIDEVOPS_PULSE_RUNTIME_PIN_FILE:-${HOME:?HOME must be set}/.config/aidevops/pulse-runtime-pin.conf}"
	return 0
}

_pulse_runtime_pin_stat_value() {
	local bsd_format="$1"
	local gnu_format="$2"
	local path="$3"
	local value=""
	value=$(stat -f "$bsd_format" "$path" 2>/dev/null) || value=$(stat -c "$gnu_format" "$path" 2>/dev/null) || return 1
	printf '%s\n' "$value"
	return 0
}

_pulse_runtime_pin_file_is_private() {
	local config_path="$1"
	local mode=""
	local owner=""
	local current_uid=""
	mode=$(_pulse_runtime_pin_stat_value '%Lp' '%a' "$config_path") || return 1
	owner=$(_pulse_runtime_pin_stat_value '%u' '%u' "$config_path") || return 1
	current_uid=$(id -u) || return 1
	[[ "$owner" == "$current_uid" ]] || return 1
	case "$mode" in
	400 | 600) return 0 ;;
	esac
	return 1
}

_pulse_runtime_pin_parse_config() {
	local config_path="$1"
	local line=""
	local key=""
	local value=""
	local schema_seen=0
	local root_seen=0
	local created_seen=0
	local expires_seen=0
	_PULSE_RUNTIME_PIN_SCHEMA=""
	_PULSE_RUNTIME_PIN_ROOT=""
	_PULSE_RUNTIME_PIN_CREATED=""
	_PULSE_RUNTIME_PIN_EXPIRES=""
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		'' | \#*) continue ;;
		*=*) ;;
		*) return 2 ;;
		esac
		key="${line%%=*}"
		value="${line#*=}"
		case "$key" in
		schema)
			[[ "$schema_seen" -eq 0 ]] || return 2
			_PULSE_RUNTIME_PIN_SCHEMA="$value"
			schema_seen=1
			;;
		agents_root)
			[[ "$root_seen" -eq 0 ]] || return 2
			_PULSE_RUNTIME_PIN_ROOT="$value"
			root_seen=1
			;;
		created_epoch)
			[[ "$created_seen" -eq 0 ]] || return 2
			_PULSE_RUNTIME_PIN_CREATED="$value"
			created_seen=1
			;;
		expires_epoch)
			[[ "$expires_seen" -eq 0 ]] || return 2
			_PULSE_RUNTIME_PIN_EXPIRES="$value"
			expires_seen=1
			;;
		*) return 2 ;;
		esac
	done <"$config_path"
	[[ "$schema_seen" -eq 1 && "$root_seen" -eq 1 && "$created_seen" -eq 1 && "$expires_seen" -eq 1 ]] || return 2
	[[ "$_PULSE_RUNTIME_PIN_SCHEMA" == "1" ]] || return 2
	case "$_PULSE_RUNTIME_PIN_CREATED" in
	'' | *[!0-9]*) return 2 ;;
	esac
	case "$_PULSE_RUNTIME_PIN_EXPIRES" in
	'' | *[!0-9]*) return 2 ;;
	esac
	return 0
}

_pulse_runtime_pin_read_config() {
	local config_path=""
	local now=""
	config_path=$(pulse_runtime_pin_config_path) || return 2
	[[ -f "$config_path" ]] || return 1
	[[ ! -L "$config_path" ]] || return 2
	_pulse_runtime_pin_file_is_private "$config_path" || return 2
	_pulse_runtime_pin_parse_config "$config_path" || return $?
	now=$(date +%s) || return 2
	[[ "${#_PULSE_RUNTIME_PIN_CREATED}" -le 12 && "${#_PULSE_RUNTIME_PIN_EXPIRES}" -le 12 ]] || return 2
	_PULSE_RUNTIME_PIN_CREATED=$((10#$_PULSE_RUNTIME_PIN_CREATED))
	_PULSE_RUNTIME_PIN_EXPIRES=$((10#$_PULSE_RUNTIME_PIN_EXPIRES))
	[[ "$_PULSE_RUNTIME_PIN_CREATED" -le "$_PULSE_RUNTIME_PIN_EXPIRES" ]] || return 2
	[[ "$_PULSE_RUNTIME_PIN_CREATED" -le "$now" ]] || return 2
	[[ $((_PULSE_RUNTIME_PIN_EXPIRES - _PULSE_RUNTIME_PIN_CREATED)) -le "$_PULSE_RUNTIME_PIN_MAX_SECONDS" ]] || return 2
	[[ "$_PULSE_RUNTIME_PIN_EXPIRES" -gt "$now" ]] || return 3
	return 0
}

_pulse_runtime_pin_validate_root() {
	local requested_root="$1"
	local agents_root=""
	local bundles_root=""
	local bundle_dir=""
	local bundle_id=""
	local manifest_bundle_id=""
	local manifest_status=""
	local required_entrypoint=""
	case "$requested_root" in
	/*) ;;
	*) return 2 ;;
	esac
	[[ "$requested_root" != *$'\n'* && "$requested_root" != *$'\t'* ]] || return 2
	for required_entrypoint in \
		pulse-runtime-pin.sh \
		pulse-wrapper.sh \
		pulse-lifecycle-helper.sh \
		pulse-merge-routine.sh \
		pulse-merge-webhook-receiver.sh; do
		[[ -f "$requested_root/scripts/$required_entrypoint" && ! -L "$requested_root/scripts/$required_entrypoint" && -x "$requested_root/scripts/$required_entrypoint" ]] || return 2
	done
	[[ -f "$requested_root/.bundle-manifest" && ! -L "$requested_root/.bundle-manifest" && -r "$requested_root/.bundle-manifest" ]] || return 2
	agents_root=$(cd "$requested_root" 2>/dev/null && pwd -P) || return 2
	bundles_root=$(cd "${HOME:?HOME must be set}/.aidevops/runtime-bundles" 2>/dev/null && pwd -P) || return 2
	[[ "${agents_root##*/}" == "agents" ]] || return 2
	bundle_dir="${agents_root%/agents}"
	[[ "$bundle_dir" != "$agents_root" && "${bundle_dir%/*}" == "$bundles_root" ]] || return 2
	bundle_id="${bundle_dir##*/}"
	while IFS='=' read -r key value; do
		case "$key" in
		bundle_id) manifest_bundle_id="$value" ;;
		status) manifest_status="$value" ;;
		esac
	done <"$agents_root/.bundle-manifest"
	[[ "$manifest_status" == "validated" && "$manifest_bundle_id" == "$bundle_id" ]] || return 2
	printf '%s\n' "$agents_root"
	return 0
}

pulse_runtime_pin_resolve() {
	local agents_root=""
	_pulse_runtime_pin_read_config || return $?
	agents_root=$(_pulse_runtime_pin_validate_root "$_PULSE_RUNTIME_PIN_ROOT") || return $?
	printf '%s\n' "$agents_root"
	return 0
}

pulse_runtime_pin_reexec() {
	local current_root="$1"
	local relative_entrypoint="$2"
	local pinned_root=""
	local physical_current_root=""
	local resolve_rc=0
	shift 2
	case "$relative_entrypoint" in
	scripts/*.sh) ;;
	*) return 2 ;;
	esac
	pinned_root=$(pulse_runtime_pin_resolve 2>/dev/null) || resolve_rc=$?
	case "$resolve_rc" in
	0) ;;
	1 | 3) return 0 ;;
	*)
		printf 'Pulse runtime pin is invalid; refusing to start %s\n' "${relative_entrypoint##*/}" >&2
		return 2
		;;
	esac
	physical_current_root=$(cd "$current_root" 2>/dev/null && pwd -P) || return 2
	[[ "$pinned_root" != "$physical_current_root" ]] || return 0
	if [[ ! -f "$pinned_root/$relative_entrypoint" || -L "$pinned_root/$relative_entrypoint" || ! -x "$pinned_root/$relative_entrypoint" ]]; then
		printf 'Pinned Pulse runtime is missing the required %s entrypoint\n' "${relative_entrypoint##*/}" >&2
		return 2
	fi
	exec "$BASH" "$pinned_root/$relative_entrypoint" "$@"
	return 1
}

pulse_runtime_pin_set() {
	local requested_root="$1"
	local expires_epoch="$2"
	local agents_root=""
	local now=""
	local config_path=""
	local config_dir=""
	local temporary=""
	case "$expires_epoch" in
	'' | *[!0-9]*) return 2 ;;
	esac
	[[ "${#expires_epoch}" -le 12 ]] || return 2
	expires_epoch=$((10#$expires_epoch))
	now=$(date +%s) || return 1
	[[ "$expires_epoch" -gt "$now" && $((expires_epoch - now)) -le "$_PULSE_RUNTIME_PIN_MAX_SECONDS" ]] || return 2
	agents_root=$(_pulse_runtime_pin_validate_root "$requested_root") || return $?
	config_path=$(pulse_runtime_pin_config_path) || return 1
	config_dir="${config_path%/*}"
	mkdir -p "$config_dir" || return 1
	temporary=$(mktemp "$config_dir/.pulse-runtime-pin.XXXXXX") || return 1
	chmod 600 "$temporary" || {
		rm -f "$temporary"
		return 1
	}
	if ! printf 'schema=1\nagents_root=%s\ncreated_epoch=%s\nexpires_epoch=%s\n' \
		"$agents_root" "$now" "$expires_epoch" >"$temporary"; then
		rm -f "$temporary"
		return 1
	fi
	mv "$temporary" "$config_path" || {
		rm -f "$temporary"
		return 1
	}
	return 0
}

pulse_runtime_pin_set_current() {
	local ttl_seconds="$1"
	local active_link="${AIDEVOPS_ACTIVE_AGENTS_LINK:-${HOME:?HOME must be set}/.aidevops/agents}"
	local active_root=""
	local now=""
	case "$ttl_seconds" in
	'' | *[!0-9]*) return 2 ;;
	esac
	[[ "${#ttl_seconds}" -le 6 ]] || return 2
	ttl_seconds=$((10#$ttl_seconds))
	[[ "$ttl_seconds" -gt 0 && "$ttl_seconds" -le "$_PULSE_RUNTIME_PIN_MAX_SECONDS" ]] || return 2
	active_root=$(cd "$active_link" 2>/dev/null && pwd -P) || return 1
	now=$(date +%s) || return 1
	pulse_runtime_pin_set "$active_root" "$((now + ttl_seconds))"
	return $?
}

pulse_runtime_pin_clear() {
	local config_path=""
	config_path=$(pulse_runtime_pin_config_path) || return 1
	rm -f "$config_path" || return 1
	return 0
}

pulse_runtime_pin_status() {
	local agents_root=""
	local bundle_id=""
	local read_rc=0
	_pulse_runtime_pin_read_config || read_rc=$?
	if [[ "$read_rc" -eq 0 ]]; then
		agents_root=$(_pulse_runtime_pin_validate_root "$_PULSE_RUNTIME_PIN_ROOT") || read_rc=$?
	fi
	if [[ "$read_rc" -eq 0 ]]; then
		bundle_id="${agents_root%/agents}"
		bundle_id="${bundle_id##*/}"
		printf 'Pulse runtime pin: active (bundle=%s expires_epoch=%s)\n' "$bundle_id" "$_PULSE_RUNTIME_PIN_EXPIRES"
		return 0
	fi
	case "$read_rc" in
	1) printf 'Pulse runtime pin: not configured\n' ;;
	3) printf 'Pulse runtime pin: expired\n' ;;
	*) printf 'Pulse runtime pin: invalid\n' ;;
	esac
	return "$read_rc"
}

pulse_runtime_pin_main() {
	local command_name="${1:-status}"
	case "$command_name" in
	resolve)
		pulse_runtime_pin_resolve
		return $?
		;;
	set-current)
		[[ "$#" -eq 2 ]] || return 2
		pulse_runtime_pin_set_current "$2" || return $?
		pulse_runtime_pin_status
		return $?
		;;
	set)
		[[ "$#" -eq 3 ]] || return 2
		pulse_runtime_pin_set "$2" "$3" || return $?
		pulse_runtime_pin_status
		return $?
		;;
	clear)
		[[ "$#" -eq 1 ]] || return 2
		pulse_runtime_pin_clear || return $?
		printf 'Pulse runtime pin: cleared\n'
		return 0
		;;
	status)
		pulse_runtime_pin_status
		return $?
		;;
	*)
		printf 'Usage: pulse-runtime-pin.sh [status|resolve|set-current <ttl-seconds>|set <agents-root> <expires-epoch>|clear]\n' >&2
		return 2
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	pulse_runtime_pin_main "$@"
	exit $?
fi

return 0
