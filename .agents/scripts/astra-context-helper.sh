#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

SETTINGS_FILE="${AIDEVOPS_SETTINGS_FILE:-${HOME}/.config/aidevops/settings.json}"
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
PLUGIN_ENTRY="${AIDEVOPS_PLUGIN_ENTRY:-${HOME}/.aidevops/agents/plugins/opencode-aidevops/index.mjs}"

usage() {
	cat <<'EOF'
Usage: aidevops astra-context [enable|disable|status]

  enable   Select ~240,000 input tokens before compaction; enable the Astra cap.
  disable  Restore the 400,000 target, preserving any native-metadata opt-out.
  status   Show the selected target and a fresh-process effective-config probe.

The default remains 400,000. GPT-5.6 and other models are unchanged.
The existing runtime.opencode.astra_context_cap=false opt-out leaves metadata
untouched; enable explicitly clears it. Preferences survive normal updates.
Restart OpenCode after changes. A probe cannot update an already running session.
Earlier compaction is a budget control, not guaranteed subscription savings.
EOF
	return 0
}

requested_state() {
	local settings='{}'
	if [[ -f "$SETTINGS_FILE" ]]; then
		settings=$(jq -sc 'if length == 1 then .[0] else {} end' "$SETTINGS_FILE" 2>/dev/null) || settings='{}'
	fi
	jq -r '(try (.runtime.opencode // {}) catch {}) |
		if type != "object" then {} else . end |
		[(if .astra_compaction_target == 240000 then 240000 else 400000 end),
		 (.astra_context_cap != false)] | @tsv' <<<"$settings"
	return 0
}

report_probe() {
	local receipt="$1" nonce="$2" target="$3" managed="$4"
	if ! jq -e --arg nonce "$nonce" --argjson target "$target" --argjson managed "$managed" '
		.schema == "aidevops.opencode-plugin-health/v1" and .nonce == $nonce and
		(["imported","factory_initialized","config_applied"] - .stages | length == 0) and
		(.details.config_applied.astra_context | .target == $target and .managed == $managed and
		 (.auto | type == "boolean") and
		 (if .managed then (.limits.input - .reserve == .target and
		  .limits.context == .limits.input + .limits.output) else true end))' "$receipt" >/dev/null 2>&1; then
		printf '%s\n' 'Effective Astra state: unavailable (missing, stale, or mismatched config evidence)'
		return 0
	fi
	if [[ "$managed" == false ]]; then
		printf '%s\n' 'Effective Astra state: native metadata opt-out confirmed (no managed target applied)'
		return 0
	fi
	jq -r '.details.config_applied.astra_context |
		"Effective Astra limits (new process): context=\(.limits.context), input=\(.limits.input), output=\(.limits.output), reserve=\(.reserve)",
		(if .auto then "Effective Astra compaction target: \(.target) (applied)"
		 else "Automatic compaction is disabled; selected limits are applied but no automatic threshold is active" end)' "$receipt"
	return 0
}

show_status() (
	local target managed probe_dir nonce
	read -r target managed < <(requested_state)
	printf 'Astra selected compaction target: %s input tokens; managed cap: %s\n' "$target" "$managed"
	printf '%s\n' 'Restart OpenCode after changes; this probe checks a new process, not existing sessions.'
	if ! command -v "$OPENCODE_BIN" >/dev/null 2>&1; then
		printf '%s\n' 'Effective Astra state: unavailable (OpenCode is not installed)'
		return 0
	fi
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_root"
	probe_dir=$(mktemp -d "${temp_root}/astra-context.XXXXXX") || return 1
	trap 'rm -rf "$probe_dir"' EXIT
	nonce="astra-$$-$(date -u '+%Y%m%d%H%M%S')"
	jq -cn --arg nonce "$nonce" '{nonce:$nonce,stages:[],details:{}}' >"$probe_dir/receipt.json"
	chmod 600 "$probe_dir/receipt.json"
	if ! "$OPENCODE_BIN" debug config >"$probe_dir/config.json" 2>"$probe_dir/error.txt" ||
		! grep -Fq "$PLUGIN_ENTRY" "$probe_dir/config.json" ||
		[[ ! -f "$PLUGIN_ENTRY" || -L "$PLUGIN_ENTRY" ]]; then
		printf '%s\n' 'Effective Astra state: unavailable (managed plugin not discovered)'
		return 0
	fi
	if ! AIDEVOPS_PLUGIN_HEALTH_PROBE_FILE="$probe_dir/receipt.json" \
		AIDEVOPS_PLUGIN_HEALTH_PROBE_NONCE="$nonce" AIDEVOPS_PLUGIN_HEALTH_PROBE_ONLY=1 \
		"$OPENCODE_BIN" models openai --verbose >"$probe_dir/models.txt" 2>"$probe_dir/error.txt"; then
		printf '%s\n' 'Effective Astra state: unavailable (OpenCode probe failed)'
		return 0
	fi
	report_probe "$probe_dir/receipt.json" "$nonce" "$target" "$managed"
	return 0
)

set_target() (
	local target="$1" settings_dir source_file temp_file
	settings_dir="${SETTINGS_FILE%/*}"
	[[ "$settings_dir" != "$SETTINGS_FILE" ]] || settings_dir='.'
	if [[ -L "$SETTINGS_FILE" || (-e "$SETTINGS_FILE" && ! -f "$SETTINGS_FILE") ]]; then
		printf '%s\n' 'Error: settings must be a regular, non-symlink file' >&2
		return 1
	fi
	mkdir -p "$settings_dir"
	temp_file=$(mktemp "${settings_dir}/settings.json.XXXXXX") || return 1
	trap 'rm -f "$temp_file"' EXIT
	source_file="$SETTINGS_FILE"
	[[ -f "$source_file" ]] || source_file=/dev/null
	if ! jq -s --argjson target "$target" --arg source "$source_file" '
		(if length == 0 and $source == "/dev/null" then {} elif length == 1 then .[0] else error("expected one settings document") end) |
		if type != "object" then error("settings must be an object") else . end |
		.runtime = (.runtime // {}) | .runtime.opencode = (.runtime.opencode // {}) |
		.runtime.opencode.astra_compaction_target = $target |
		if $target == 240000 then .runtime.opencode.astra_context_cap = true else . end' \
		"$source_file" >"$temp_file"; then
		printf '%s\n' 'Error: settings were not changed' >&2
		return 1
	fi
	chmod 600 "$temp_file"
	mv "$temp_file" "$SETTINGS_FILE"
	show_status
	return 0
)

main() {
	local action="${1:-status}"
	case "$action" in
	help | --help | -h)
		usage
		return 0
		;;
	esac
	if ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' 'Error: jq is required' >&2
		return 1
	fi
	case "$action" in
	enable | on) set_target 240000 ;;
	disable | off) set_target 400000 ;;
	status) show_status ;;
	*)
		usage >&2
		return 2
		;;
	esac
	return 0
}

main "$@"
