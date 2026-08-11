#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SETTINGS_FILE="${AIDEVOPS_SETTINGS_FILE:-${HOME}/.config/aidevops/settings.json}"
BOOLEAN_TRUE="true"
PLUGIN_HEALTH_SCHEMA="aidevops.opencode-plugin-health/v1"
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
PLUGIN_ENTRY="${AIDEVOPS_PLUGIN_ENTRY:-${HOME}/.aidevops/agents/plugins/opencode-aidevops/index.mjs}"

usage() {
	cat <<'EOF'
Usage: aidevops gpt56-context [enable|disable|status]

Controls the aidevops GPT-5.6 context cap in OpenCode.
  enable   Advertise a 300K context window (default), causing OpenCode's 80%
           auto-compaction to run near 240K and avoid long-context pricing.
  disable  Use OpenCode/OpenAI's native GPT-5.6 context metadata.
  status   Show the current setting.

Restart OpenCode after changing this setting.
EOF
	return 0
}

require_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' "Error: jq is required to update ${SETTINGS_FILE}" >&2
		return 1
	fi
	return 0
}

is_enabled() {
	local enabled="$BOOLEAN_TRUE"
	if [[ ! -f "$SETTINGS_FILE" ]]; then
		return 0
	fi
	enabled=$(jq -r 'if .runtime.opencode.gpt56_context_cap == false then false else true end' "$SETTINGS_FILE" 2>/dev/null) || enabled="$BOOLEAN_TRUE"
	[[ "$enabled" == "$BOOLEAN_TRUE" ]]
}

show_status() {
	local requested="disabled"
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local probe_dir="" probe_file="" probe_nonce="" probe_output="" probe_error=""
	local probe_status=0 configured=false
	local stages="" context="" input="" output="" failure=""

	if is_enabled; then
		requested="enabled"
	fi
	printf '%s\n' "GPT-5.6 OpenCode context cap requested: ${requested}"
	if ! command -v "$OPENCODE_BIN" >/dev/null 2>&1; then
		printf '%s\n' "OpenCode plugin effective state: unavailable (OpenCode is not installed)"
		return 0
	fi
	mkdir -p "$temp_root"
	chmod 700 "$temp_root" 2>/dev/null || true
	probe_dir=$(mktemp -d "${temp_root}/aidevops-plugin-health.XXXXXX") || return 1
	chmod 700 "$probe_dir"
	probe_file="${probe_dir}/receipt.json"
	probe_output="${probe_dir}/models.txt"
	probe_error="${probe_dir}/error.txt"
	probe_nonce="probe-$$-$(date -u '+%Y%m%d%H%M%S')"
	jq -cn --arg nonce "$probe_nonce" '{nonce:$nonce,stages:[],details:{}}' >"$probe_file"
	chmod 600 "$probe_file"
	if "$OPENCODE_BIN" debug config >"$probe_output" 2>"$probe_error" &&
		grep -Fq "$PLUGIN_ENTRY" "$probe_output"; then
		configured=true
	fi
	printf '%s\n' "OpenCode plugin configured/discovered: ${configured}"
	if [[ "$configured" == true && -f "$PLUGIN_ENTRY" && ! -L "$PLUGIN_ENTRY" ]]; then
		if AIDEVOPS_PLUGIN_HEALTH_PROBE_FILE="$probe_file" \
			AIDEVOPS_PLUGIN_HEALTH_PROBE_NONCE="$probe_nonce" \
			AIDEVOPS_PLUGIN_HEALTH_PROBE_ONLY=1 \
			"$OPENCODE_BIN" models openai --verbose >>"$probe_output" 2>>"$probe_error"; then
			probe_status=0
		else
			probe_status=$?
		fi
	else
		probe_status=2
	fi
	if jq -e --arg schema "$PLUGIN_HEALTH_SCHEMA" --arg nonce "$probe_nonce" \
		'.schema == $schema and .nonce == $nonce and
		(["imported","factory_initialized","config_applied"] - .stages | length == 0) and
		.details.factory_initialized.terminal_title_status == true and
		.details.config_applied.terminal_title_status == true' \
		"$probe_file" >/dev/null 2>&1; then
		stages=$(jq -r '.stages | join(", ")' "$probe_file")
		context=$(jq -r '.details.config_applied.gpt56_limits.context // empty' "$probe_file")
		input=$(jq -r '.details.config_applied.gpt56_limits.input // empty' "$probe_file")
		output=$(jq -r '.details.config_applied.gpt56_limits.output // empty' "$probe_file")
		printf '%s\n' "OpenCode plugin effective state: active (${stages})"
		printf '%s\n' "Terminal-title status hook: registered"
		if [[ -n "$context" && -n "$input" && -n "$output" ]]; then
			printf '%s\n' "Effective GPT-5.6 limits: context=${context}, input=${input}, output=${output}"
		elif [[ "$requested" == "disabled" ]]; then
			printf '%s\n' "Effective GPT-5.6 limits: native provider metadata (cap disabled)"
		else
			printf '%s\n' "Effective GPT-5.6 limits: unavailable (config hook did not register limits)"
		fi
	else
		printf '%s\n' "OpenCode plugin effective state: inactive or initialization failed"
		if [[ -s "$probe_error" ]]; then
			failure=$(tr '\n' ' ' <"$probe_error" | cut -c1-240)
			failure="${failure//${HOME}/\$HOME}"
			printf '%s\n' "Probe failure (exit ${probe_status}): ${failure}"
		fi
		printf '%s\n' "Effective GPT-5.6 limits: unavailable (requested state not confirmed)"
	fi
	rm -rf "$probe_dir"
	return 0
}

set_enabled() {
	local enabled="$1"
	local settings_dir temp_file source_file
	settings_dir="${SETTINGS_FILE%/*}"
	mkdir -p "$settings_dir"
	temp_file=$(mktemp "${settings_dir}/settings.json.XXXXXX")
	source_file="$SETTINGS_FILE"
	if [[ ! -f "$source_file" ]]; then
		printf '%s\n' '{}' >"$temp_file"
		source_file="$temp_file"
	fi
	if ! jq --argjson enabled "$enabled" \
		'.runtime = (.runtime // {}) | .runtime.opencode = (.runtime.opencode // {}) | .runtime.opencode.gpt56_context_cap = $enabled' \
		"$source_file" >"${temp_file}.new"; then
		rm -f "$temp_file" "${temp_file}.new"
		return 1
	fi
	mv "${temp_file}.new" "$SETTINGS_FILE"
	rm -f "$temp_file"
	chmod 600 "$SETTINGS_FILE"
	show_status
	printf '%s\n' "Restart OpenCode to apply the change."
	return 0
}

main() {
	local action="${1:-status}"
	require_jq || return 1
	case "$action" in
	enable | on) set_enabled true ;;
	disable | off) set_enabled false ;;
	status) show_status ;;
	help | --help | -h) usage ;;
	*)
		printf '%s\n' "Unknown action: $action" >&2
		usage >&2
		return 2
		;;
	esac
	return 0
}

main "$@"
