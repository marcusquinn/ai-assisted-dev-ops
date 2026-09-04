#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# MCP Connection Failure Diagnostics
# Usage: mcp-diagnose.sh <mcp-name>
#        mcp-diagnose.sh check-all
#
# Diagnoses common MCP connection issues:
# - Command availability
# - Version mismatches
# - Configuration errors
# - Known breaking changes
#
# check-all: scans all enabled MCP servers and reports which are unavailable,
# helping identify dead tool schemas that waste context tokens (t1682).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

PLAYWRIGHT_MCP_PACKAGE="@playwright/mcp"
PLAYWRIGHT_MCP_NAME="playwright"
PLAYWRIGHT_MCP_SPEC="${PLAYWRIGHT_MCP_PACKAGE}@0.0.79"
PLAYWRIGHT_MCP_RUN="npx -y ${PLAYWRIGHT_MCP_SPEC}"

show_usage() {
	echo "Usage: mcp-diagnose.sh <mcp-name>"
	echo "       mcp-diagnose.sh check-all"
	echo ""
	echo "Examples:"
	echo "  mcp-diagnose.sh context7"
	echo "  mcp-diagnose.sh check-all"
	return 0
}

MCP_NAME="${1:-}"

case "$MCP_NAME" in
help | --help | -h)
	show_usage
	exit 0
	;;
"")
	show_usage
	exit 1
	;;
esac

# =============================================================================
# check-all: scan all enabled MCP servers for connection errors (t1682)
# Identifies servers whose tool schemas are in context but can't execute.
#
# Decomposed into helpers (GH#8516):
#   _resolve_mcp_config   — find the MCP config file
#   _extract_server_list  — parse config into tab-separated server list
#   _print_remediation    — display fix instructions for errored servers
#   _check_all_mcps       — orchestrator
# =============================================================================

# Resolve the MCP config file path.
# Tries the runtime registry first (for all detected runtimes), then falls back
# to platform-aware candidate paths in priority order:
#   1. Claude Code CLI:     ~/.config/Claude/Claude.json
#   2. Claude Desktop macOS: ~/Library/Application Support/Claude/claude_desktop_config.json
#   3. OpenCode:            ~/.config/opencode/opencode.json
# Echoes the resolved path on stdout.
# Returns: 0 if a valid config file was found, 1 otherwise.
_resolve_mcp_config() {
	local config_file=""

	# Try runtime registry for all detected runtimes (preferred — registry-driven)
	if type rt_detect_configured &>/dev/null; then
		local _rt_id
		while IFS= read -r _rt_id; do
			local _cfg
			_cfg=$(rt_config_path "$_rt_id" 2>/dev/null) || continue
			if [[ -n "$_cfg" && -f "$_cfg" ]]; then
				config_file="$_cfg"
				break
			fi
		done < <(rt_detect_configured 2>/dev/null)
	fi

	# Fallback: platform-aware candidate paths in priority order
	if [[ -z "$config_file" || ! -f "$config_file" ]]; then
		local _candidates=(
			"$HOME/.claude.json"
			"$HOME/.config/Claude/Claude.json"
			"$HOME/Library/Application Support/Claude/claude_desktop_config.json"
			"$HOME/.config/opencode/opencode.json"
		)
		local _c
		for _c in "${_candidates[@]}"; do
			if [[ -f "$_c" ]]; then
				config_file="$_c"
				break
			fi
		done
	fi

	if [[ -z "$config_file" || ! -f "$config_file" ]]; then
		echo -e "${RED}✗ No MCP config file found. Checked:${NC}" >&2
		echo -e "${RED}  ~/.claude.json${NC}" >&2
		echo -e "${RED}  ~/.config/Claude/Claude.json${NC}" >&2
		echo -e "${RED}  ~/Library/Application Support/Claude/claude_desktop_config.json${NC}" >&2
		echo -e "${RED}  ~/.config/opencode/opencode.json${NC}" >&2
		return 1
	fi

	echo "$config_file"
	return 0
}

# Extract enabled MCP server names and their commands from a config file.
# Arguments:
#   $1 - config file path (required)
# Output: tab-separated lines: name\tserver_type\tcmd_path
# Returns: 0 on success, 1 on parse failure.
_extract_server_list() {
	local config_file="$1"

	python3 - "$config_file" <<'PYEOF'
import json, sys

config_file = sys.argv[1]
with open(config_file) as f:
    cfg = json.load(f)

# Support both 'mcp' (opencode) and 'mcpServers' (Claude Code / other runtimes)
mcp_section = cfg.get('mcp', cfg.get('mcpServers', {}))

for name, server in mcp_section.items():
    enabled = server.get('enabled', True)
    if not enabled:
        continue
    server_type = server.get('type', 'stdio')
    # 'remote' and 'sse' are network-based MCPs — skip connectivity check
    if server_type in ('remote', 'sse'):
        print(f"{name}\tremote\t")
        continue
    cmd = server.get('command', [])
    if isinstance(cmd, list) and len(cmd) > 0:
        print(f"{name}\tlocal\t{cmd[0]}")
    elif isinstance(cmd, str):
        print(f"{name}\tlocal\t{cmd}")
    else:
        print(f"{name}\tlocal\t")
PYEOF
	return $?
}

# Print remediation advice for errored MCP servers.
# Arguments:
#   $1 - config file path
#   $2..N - errored server names
# Returns: 0 always.
_print_remediation() {
	local config_file="$1"
	shift
	# Remaining args are errored server names

	echo ""
	echo -e "${YELLOW}=== Errored Servers — Dead Tool Schemas in Context ===${NC}"
	echo ""
	echo "These servers have tool schemas registered but cannot execute."
	echo "Each errored server wastes context tokens on unusable tools."
	echo ""
	echo "Remediation options:"
	echo ""
	echo "  Option A — Fix the connection (preferred):"
	local name
	for name in "$@"; do
		echo "    mcp-diagnose.sh $name"
	done
	echo ""
	echo "  Option B — Disable until fixed (removes schemas from context):"
	echo "    Edit $config_file"
	for name in "$@"; do
		echo "    Set \"$name\": { ..., \"enabled\": false }"
	done
	echo ""
	echo "  Option C — Remove registration entirely:"
	for name in "$@"; do
		echo "    Delete the \"$name\" entry from $config_file"
	done
	echo ""
	echo -e "${BLUE}Tip:${NC} After fixing, restart your AI runtime to reload tool schemas."
	return 0
}

# Collect all unique MCP config files across all detected runtimes.
# Outputs one config file path per line (no duplicates).
_collect_all_configs() {
	local seen=()
	local config_file=""

	# Registry-driven: iterate all detected runtimes
	if type rt_detect_configured &>/dev/null; then
		local _rt_id
		while IFS= read -r _rt_id; do
			local _cfg
			_cfg=$(rt_config_path "$_rt_id" 2>/dev/null) || continue
			if [[ -n "$_cfg" && -f "$_cfg" ]]; then
				# Deduplicate: check if already in seen array
				local _dup=false
				if [[ ${#seen[@]} -gt 0 ]]; then
					local _s
					for _s in "${seen[@]}"; do
						[[ "$_s" == "$_cfg" ]] && _dup=true && break
					done
				fi
				if [[ "$_dup" == "false" ]]; then
					seen+=("$_cfg")
					echo "$_cfg"
				fi
			fi
		done < <(rt_detect_configured 2>/dev/null)
	fi

	# Fallback candidates not covered by registry
	local _fallback_candidates=(
		"$HOME/.claude.json"
		"$HOME/.config/Claude/Claude.json"
		"$HOME/Library/Application Support/Claude/claude_desktop_config.json"
		"$HOME/.config/opencode/opencode.json"
	)
	local _c
	for _c in "${_fallback_candidates[@]}"; do
		[[ -f "$_c" ]] || continue
		local _dup=false
		if [[ ${#seen[@]} -gt 0 ]]; then
			local _s
			for _s in "${seen[@]}"; do
				[[ "$_s" == "$_c" ]] && _dup=true && break
			done
		fi
		if [[ "$_dup" == "false" ]]; then
			seen+=("$_c")
			echo "$_c"
		fi
	done
	return 0
}

# Scan a single config file and report MCP server health.
# Arguments:
#   $1 - config file path
#   $2 - name of array variable to append errored server names to (passed by name)
# Outputs results to stdout. Increments global ok_count/error_count/skip_count.
# Parse failures are non-fatal: logs an error and returns 0 so the caller continues.
_scan_config_file() {
	local config_file="$1"
	local errored_var="$2"

	local server_list
	if ! server_list=$(_extract_server_list "$config_file" 2>/dev/null); then
		echo -e "  ${RED}✗ Failed to parse config file — skipping${NC}"
		return 0
	fi

	if [[ -z "$server_list" ]]; then
		echo -e "  ${YELLOW}(no enabled MCP servers)${NC}"
		return 0
	fi

	while IFS=$'\t' read -r name server_type cmd_path; do
		[[ -z "$name" ]] && continue

		if [[ "$server_type" == "remote" ]]; then
			echo -e "  ${CYAN}[remote]${NC} $name — skipping connectivity check (remote MCP)"
			((++skip_count))
			continue
		fi

		# For local MCPs: check if the command binary exists
		# cmd_path may be a full path (e.g. /home/user/.nvm/.../npx) or a bare name
		local cmd_ok=false
		if [[ -n "$cmd_path" ]]; then
			if [[ -x "$cmd_path" ]]; then
				cmd_ok=true
			elif command -v "$cmd_path" &>/dev/null; then
				cmd_ok=true
			fi
		fi

		if [[ "$cmd_ok" == "true" ]]; then
			echo -e "  ${GREEN}[ok]${NC}     $name"
			((++ok_count))
		else
			echo -e "  ${RED}[error]${NC}  $name — command not found: ${cmd_path:-<none>}"
			# Append to the caller-provided array variable by name
			eval "${errored_var}+=(\"$name\")"
			((++error_count))
		fi
	done <<<"$server_list"
	return 0
}

# Orchestrator: scan all enabled MCP servers across all runtime configs.
_check_all_mcps() {
	echo -e "${BLUE}=== MCP Server Health Check (t1682) ===${NC}"
	echo ""
	echo "Scanning all enabled MCP servers for connection errors..."
	echo "Errored servers inject dead tool schemas into context, wasting tokens."
	echo ""

	local all_configs=()
	while IFS= read -r _cfg; do
		all_configs+=("$_cfg")
	done < <(_collect_all_configs)

	if [[ ${#all_configs[@]} -eq 0 ]]; then
		echo -e "${RED}✗ No MCP config files found.${NC}"
		echo "  Checked: ~/.claude.json, ~/.config/Claude/Claude.json,"
		echo "           ~/Library/Application Support/Claude/claude_desktop_config.json,"
		echo "           ~/.config/opencode/opencode.json"
		return 1
	fi

	local ok_count=0
	local error_count=0
	local skip_count=0
	local any_errors=false

	local config_file
	for config_file in "${all_configs[@]}"; do
		echo "Config: $config_file"
		# Per-config errored names array — remediation points to the correct config
		local _cfg_errored=()
		_scan_config_file "$config_file" "_cfg_errored"
		echo ""
		if [[ ${#_cfg_errored[@]} -gt 0 ]]; then
			_print_remediation "$config_file" "${_cfg_errored[@]}"
			any_errors=true
		fi
	done

	echo "Summary: ${ok_count} ok, ${error_count} errored, ${skip_count} skipped (remote)"

	if [[ "$any_errors" == "true" ]]; then
		return 1
	fi

	echo ""
	echo -e "${GREEN}All enabled local MCP servers have reachable commands.${NC}"
	return 0
}

# =============================================================================
# Single-server diagnosis (original behaviour)
# =============================================================================
if [[ "$MCP_NAME" == "check-all" ]]; then
	_check_all_mcps
	exit $?
fi

echo -e "${BLUE}=== MCP Diagnosis: $MCP_NAME ===${NC}"
echo ""

# Collect runtime configurations before checking versions so a runtime's actual
# command is diagnosed rather than a same-named PATH executable.
MCP_CONFIG_SEPARATOR=:
MCP_REMOTE_TYPE=remote
_MCP_DIAG_CONFIGS=()
if type rt_detect_configured &>/dev/null; then
	while IFS= read -r _rt_id; do
		_cfg=$(rt_config_path "$_rt_id") || continue
		[[ -n "$_cfg" && -f "$_cfg" ]] && _MCP_DIAG_CONFIGS+=("${_rt_id}${MCP_CONFIG_SEPARATOR}${_cfg}")
	done < <(rt_detect_configured)
fi
# Fallback if registry is unavailable — check platform-aware candidates.
if [[ ${#_MCP_DIAG_CONFIGS[@]} -eq 0 ]]; then
	declare -a _fallback_candidates
	_fallback_candidates=(
		"claude-code${MCP_CONFIG_SEPARATOR}$HOME/.claude.json"
		"claude-code${MCP_CONFIG_SEPARATOR}$HOME/.config/Claude/Claude.json"
		"claude-code${MCP_CONFIG_SEPARATOR}$HOME/Library/Application Support/Claude/claude_desktop_config.json"
		"opencode${MCP_CONFIG_SEPARATOR}$HOME/.config/opencode/opencode.json"
	)
	_fc=""
	_fc_rt=""
	_fc_path=""
	for _fc in "${_fallback_candidates[@]}"; do
		_fc_rt="${_fc%%"${MCP_CONFIG_SEPARATOR}"*}"
		_fc_path="${_fc#*"${MCP_CONFIG_SEPARATOR}"}"
		[[ -f "$_fc_path" ]] && _MCP_DIAG_CONFIGS+=("${_fc_rt}${MCP_CONFIG_SEPARATOR}${_fc_path}")
	done
fi

# 0. Detect if this is a remote/SSE MCP by reading its type from config files.
# Config-driven: reads the 'type' field from the MCP entry rather than hardcoding names.
MCP_IS_REMOTE=false
MCP_CONFIGURED_TYPE=""
_detect_mcp_type() {
	local mcp_name="$1"
	local config_file="$2"
	python3 - "$config_file" "$mcp_name" <<'PYEOF'
import json, sys
config_file, mcp_name = sys.argv[1], sys.argv[2]
try:
    with open(config_file) as f:
        cfg = json.load(f)
    mcp_section = cfg.get('mcp', cfg.get('mcpServers', {}))
    entry = mcp_section.get(mcp_name, {})
    print(entry.get('type', ''))
except Exception:
    print('')
PYEOF
}

# Check all config files for this MCP's type.
# Prefer 'remote' or 'sse' if found in any config (an enabled remote entry
# takes precedence over a disabled local entry in another config).
while IFS= read -r _diag_cfg; do
	_mcp_type=$(_detect_mcp_type "$MCP_NAME" "$_diag_cfg" 2>/dev/null)
	if [[ "$_mcp_type" == "$MCP_REMOTE_TYPE" || "$_mcp_type" == "sse" ]]; then
		MCP_CONFIGURED_TYPE="$_mcp_type"
		break
	elif [[ -n "$_mcp_type" && -z "$MCP_CONFIGURED_TYPE" ]]; then
		MCP_CONFIGURED_TYPE="$_mcp_type"
	fi
done < <(for _diag_entry in "${_MCP_DIAG_CONFIGS[@]}"; do printf '%s\n' "${_diag_entry#*"${MCP_CONFIG_SEPARATOR}"}"; done)

if [[ "$MCP_CONFIGURED_TYPE" == "$MCP_REMOTE_TYPE" || "$MCP_CONFIGURED_TYPE" == "sse" ]]; then
	MCP_IS_REMOTE=true
fi

# 1. Check if command exists
echo "1. Checking command availability..."
# Map MCP names to their CLI commands
PINNED_NPM_SPEC=""
case "$MCP_NAME" in
context7)
	CLI_CMD="context7"
	NPM_PKG="@context7/mcp"
	;;
playwright)
	CLI_CMD="playwright-mcp"
	NPM_PKG="$PLAYWRIGHT_MCP_PACKAGE"
	PINNED_NPM_SPEC="$PLAYWRIGHT_MCP_SPEC"
	;;
*)
	CLI_CMD="$MCP_NAME"
	NPM_PKG="$MCP_NAME"
	;;
esac

# Safely version-check a configured local command array. Shell strings and
# shell runners are intentionally excluded: diagnostics must not evaluate
# configuration content. Package runners are accepted only for their exact
# configured MCP package shape.
_configured_command_version() {
	local config_file="$1"
	local mcp_name="$2"
	local expected_package="$3"
	local pinned_package_spec="$4"

	python3 - "$config_file" "$mcp_name" "$expected_package" "$pinned_package_spec" <<'PYEOF'
import json
import os
import re
import subprocess
import sys

config_file, mcp_name, expected_package, pinned_package_spec = sys.argv[1:]

def allowed_package_spec(package_spec):
    if package_spec == expected_package:
        return True
    prefix = f'{expected_package}@'
    if not package_spec.startswith(prefix):
        return False
    selector = package_spec[len(prefix):]
    return re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]*', selector) is not None

try:
    with open(config_file) as stream:
        config = json.load(stream)
    entry = config.get('mcp', config.get('mcpServers', {})).get(mcp_name, {})
    command = entry.get('command')
    enabled = entry.get('enabled', True)
    if (entry.get('type') in ('remote', 'sse')
            or not isinstance(command, list) or not command
            or len(command) > 24 or any(not isinstance(part, str) or not part or '\x00' in part for part in command)):
        raise ValueError('no safe configured command array')

    executable = command[0]
    runner = os.path.basename(executable)
    shell_runners = {'sh', 'bash', 'zsh', 'fish', 'cmd', 'powershell', 'pwsh'}
    if runner in shell_runners:
        package_index = next((index for index, part in enumerate(command)
            if allowed_package_spec(part)), None)
        if (mcp_name != 'playwright' or package_index is None or package_index < 2
                or command[package_index - 2] != 'npx'
                or command[package_index - 1] not in ('-y', '--yes')
                or command[package_index] != pinned_package_spec):
            raise ValueError('shell runner is not safe for diagnostics')
        invocation = ['npx', command[package_index - 1], command[package_index], '--version']
    elif runner == 'npx':
        package_args = command[1:]
        runner_args = []
        if package_args and package_args[0] in ('-y', '--yes'):
            runner_args = [package_args[0]]
            package_args = package_args[1:]
        if not package_args:
            raise ValueError('unsupported npx package invocation')
        package_spec = package_args[0]
        if (not allowed_package_spec(package_spec)
                or pinned_package_spec and package_spec != pinned_package_spec
                or enabled is False and not pinned_package_spec):
            raise ValueError('unsupported npx package invocation')
        invocation = [executable, *runner_args, package_spec, '--version']
    elif runner == 'bun':
        package_spec = command[2] if len(command) >= 3 else ''
        if (len(command) < 3 or command[1] != 'x' or not allowed_package_spec(package_spec)
                or pinned_package_spec and package_spec != pinned_package_spec
                or enabled is False and not pinned_package_spec):
            raise ValueError('unsupported bun package invocation')
        invocation = [*command[:3], '--version']
    else:
        if enabled is False:
            raise ValueError('disabled direct command is not safe for diagnostics')
        invocation = [executable, '--version']

    result = subprocess.run(
        invocation,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=3,
        check=False,
    )
    relay_port = '19988'
    for index, part in enumerate(command):
        if part == '--port' and index + 1 < len(command) and command[index + 1].isdigit():
            relay_port = command[index + 1]
        elif part.startswith('--port=') and part[7:].isdigit():
            relay_port = part[7:]
    if not 1 <= int(relay_port) <= 65535:
        relay_port = '19988'

    version = result.stdout.splitlines()[0].strip() if result.stdout else 'unknown'
    version = version.replace('\t', ' ')[:160]
    print(f'{executable}\t{version}\t{relay_port}')
except Exception:
    pass
PYEOF
	return 0
}

# Query only the configured localhost relay port; never follow URLs or print
# its environment. The endpoint's JSON version is sufficient for mismatch
# diagnosis and the one-second timeout bounds a stale relay.
_playwriter_relay_version() {
	local relay_port="$1"

	python3 - "$relay_port" <<'PYEOF'
import http.client
import json
import sys

try:
    connection = http.client.HTTPConnection('127.0.0.1', int(sys.argv[1]), timeout=1)
    connection.request('GET', '/version')
    response = connection.getresponse()
    if 200 <= response.status < 300:
        version = json.loads(response.read(1024).decode("utf-8")).get("version")
        if isinstance(version, str):
            print(version.replace('\t', ' ').replace('\n', ' ')[:160])
    connection.close()
except Exception:
    pass
PYEOF
	return 0
}

if [[ "$MCP_IS_REMOTE" == "true" ]]; then
	echo -e "   ${CYAN}[remote]${NC} $MCP_NAME is a remote/SSE MCP (type: ${MCP_CONFIGURED_TYPE}) — no local command required."
	echo "   Remote MCPs connect over the network and cannot be diagnosed locally."
	echo ""
	echo "4. Known issues for $MCP_NAME..."
	case "$MCP_NAME" in
	cloudflare-api)
		echo "   - SSE-based remote MCP (type: sse)"
		echo "   - Requires Cloudflare account and OAuth; errors if unauthenticated"
		echo "   - Use: \"type\": \"sse\", \"url\": \"https://mcp.cloudflare.com/mcp\""
		echo "   - To disable: set \"enabled\": false in your MCP config"
		;;
	openapi-search)
		echo "   - SSE-based remote MCP (type: sse)"
		echo "   - Requires network access to openapi-mcp.openapisearch.com"
		echo "   - Use: \"type\": \"sse\", \"url\": \"https://openapi-mcp.openapisearch.com/mcp\""
		echo "   - To disable: set \"enabled\": false in your MCP config"
		;;
	context7)
		echo "   - Remote MCP, no local command needed"
		echo "   - Use: \"type\": \"remote\", \"url\": \"https://mcp.context7.com/mcp\""
		;;
	*)
		echo "   - Remote/SSE MCP (type: ${MCP_CONFIGURED_TYPE}) — no local command required"
		echo "   - To disable: set \"enabled\": false in your MCP config"
		;;
	esac
	exit 0
fi

if command -v "$CLI_CMD" &>/dev/null; then
	echo -e "   ${GREEN}✓ Command found: $(which "$CLI_CMD")${NC}"
	INSTALLED_VERSION=$("$CLI_CMD" --version 2>/dev/null | head -1 || echo 'unknown')
	echo "   PATH version: $INSTALLED_VERSION"
else
	if [[ "$MCP_NAME" == "$PLAYWRIGHT_MCP_NAME" ]]; then
		echo -e "   ${CYAN}[npx]${NC} No global command found; checking configured package runners"
	else
		echo -e "   ${RED}✗ Command not found: $CLI_CMD${NC}"
	fi
	INSTALLED_VERSION="unknown"
fi

# Check every local runtime configuration before comparing versions.
_configured_version_found=0
_playwriter_relay_port=19988
_playwriter_configured_version="unknown"
for _diag_entry in "${_MCP_DIAG_CONFIGS[@]}"; do
	_diag_rt="${_diag_entry%%"${MCP_CONFIG_SEPARATOR}"*}"
	CONFIG_FILE="${_diag_entry#*"${MCP_CONFIG_SEPARATOR}"}"
	_diag_name="$_diag_rt"
	if type rt_display_name &>/dev/null; then
		_diag_name=$(rt_display_name "$_diag_rt") || _diag_name="$_diag_rt"
	fi
	_configured_command_info=$(_configured_command_version "$CONFIG_FILE" "$MCP_NAME" "$NPM_PKG" "$PINNED_NPM_SPEC")
	[[ -z "$_configured_command_info" ]] && continue
	IFS=$'\t' read -r _configured_executable _configured_version _configured_relay_port <<<"$_configured_command_info"
	[[ -z "$_configured_executable" ]] && continue
	_configured_version_found=1
	if [[ "$MCP_NAME" == "playwriter" && -n "$_configured_relay_port" ]]; then
		_playwriter_relay_port="$_configured_relay_port"
		_playwriter_configured_version="$_configured_version"
	fi
	echo -e "   ${GREEN}✓ Configured command in ${_diag_name}: ${_configured_executable}${NC}"
	echo "   Configured version: $_configured_version"
	if [[ "$INSTALLED_VERSION" != "unknown" && "$_configured_version" != "unknown" && "$INSTALLED_VERSION" != "$_configured_version" ]]; then
		echo -e "   ${YELLOW}⚠️  VERSION MISMATCH - ${_diag_name} uses $_configured_version, PATH reports $INSTALLED_VERSION${NC}"
	fi
done

if [[ "$MCP_NAME" == "playwriter" ]]; then
	_relay_version=$(_playwriter_relay_version "$_playwriter_relay_port")
	if [[ -n "$_relay_version" ]]; then
		echo "   Live local relay version: $_relay_version"
		if [[ "$INSTALLED_VERSION" != "unknown" && "$_relay_version" != "$INSTALLED_VERSION" ]]; then
			echo -e "   ${YELLOW}⚠️  VERSION MISMATCH - live relay uses $_relay_version, PATH reports $INSTALLED_VERSION${NC}"
		fi
		if [[ "$_playwriter_configured_version" != "unknown" && "$_relay_version" != "$_playwriter_configured_version" ]]; then
			echo -e "   ${YELLOW}⚠️  VERSION MISMATCH - live relay uses $_relay_version, configured command reports $_playwriter_configured_version${NC}"
		fi
	else
		echo "   Live local relay version: unavailable"
	fi
fi

if [[ "$INSTALLED_VERSION" == "unknown" && "$_configured_version_found" -eq 0 ]]; then
	if [[ "$MCP_NAME" == "$PLAYWRIGHT_MCP_NAME" ]]; then
		echo "   Try: $PLAYWRIGHT_MCP_RUN --version"
	else
		echo "   Try: npm install -g $NPM_PKG"
	fi
	exit 1
fi

# 2. Check latest version
echo ""
echo "2. Checking for updates..."
LATEST_VERSION=$(npm view "$NPM_PKG" version 2>/dev/null || echo "unknown")
echo "   PATH installed: $INSTALLED_VERSION"
echo "   Latest:    $LATEST_VERSION"

if [[ "$INSTALLED_VERSION" != "unknown" && "$INSTALLED_VERSION" != *"$LATEST_VERSION"* ]] && [[ "$LATEST_VERSION" != "unknown" ]]; then
	echo -e "   ${YELLOW}⚠️  UPDATE AVAILABLE - run: npm update -g $NPM_PKG${NC}"
fi

# 3. Check runtime configs for MCP (t1665.5 — registry-driven)
echo ""
echo "3. Checking runtime configurations..."

_mcp_found_in_any=0
for _diag_entry in "${_MCP_DIAG_CONFIGS[@]}"; do
	_diag_rt="${_diag_entry%%:*}"
	CONFIG_FILE="${_diag_entry#*:}"
	_diag_name=""
	if type rt_display_name &>/dev/null; then
		_diag_name=$(rt_display_name "$_diag_rt") || _diag_name="$_diag_rt"
	else
		_diag_name="$_diag_rt"
	fi

	if grep -q "\"$MCP_NAME\"" "$CONFIG_FILE" 2>/dev/null; then
		echo -e "   ${GREEN}✓ MCP configured in ${_diag_name} config${NC}"
		# Extract and show the command using Python
		python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
# Try both 'mcp' (opencode) and 'mcpServers' (other runtimes) root keys
mcp = cfg.get('mcp', cfg.get('mcpServers', {})).get('$MCP_NAME', {})
cmd = mcp.get('command', 'not set')
enabled = mcp.get('enabled', 'not set')
print(f'   Command: {cmd}')
print(f'   Enabled: {enabled}')
" 2>/dev/null || echo "   (Could not parse config)"
		_mcp_found_in_any=1
	fi
done

if [[ "$_mcp_found_in_any" -eq 0 ]]; then
	if [[ ${#_MCP_DIAG_CONFIGS[@]} -eq 0 ]]; then
		echo -e "   ${RED}✗ No runtime config files found${NC}"
	else
		echo -e "   ${RED}✗ MCP '$MCP_NAME' not found in any runtime config${NC}"
	fi
fi

# 4. Check for known breaking changes
echo ""
echo "4. Known issues for $MCP_NAME..."
case "$MCP_NAME" in
context7)
	echo "   - Remote MCP, no local command needed"
	echo "   - Use: \"type\": \"remote\", \"url\": \"https://mcp.context7.com/mcp\""
	;;
cloudflare-api)
	echo "   - SSE-based remote MCP (type: sse)"
	echo "   - Requires Cloudflare account and OAuth; errors if unauthenticated"
	echo "   - Use: \"type\": \"sse\", \"url\": \"https://mcp.cloudflare.com/mcp\""
	echo "   - To disable: set \"enabled\": false in your MCP config"
	;;
openapi-search)
	echo "   - SSE-based remote MCP (type: sse)"
	echo "   - Requires network access to openapi-mcp.openapisearch.com"
	echo "   - Use: \"type\": \"sse\", \"url\": \"https://openapi-mcp.openapisearch.com/mcp\""
	echo "   - To disable: set \"enabled\": false in your MCP config"
	;;
playwright)
	echo "   - Requires Microsoft's $PLAYWRIGHT_MCP_PACKAGE package (npx -y)"
	echo "   - Needs Playwright browsers installed: npx playwright install"
	echo "   - Standalone headed/headless work prefers a separate Brave process"
	echo "   - Existing-tab mode is interactive-only and requires Playwright Extension plus --extension"
	echo "   - Aidevops requires PLAYWRIGHT_MCP_EXTENSION=1; a token alone does not switch modes"
	echo "   - To verify the package: $PLAYWRIGHT_MCP_RUN --version"
	;;
*)
	echo "   No known issues documented for this MCP"
	;;
esac

# 5. Test MCP command directly
echo ""
echo "5. Testing MCP command (5 second timeout)..."

# timeout_sec (from shared-constants.sh) handles macOS + Linux portably
case "$MCP_NAME" in
*)
	echo "   Skipping direct test (unknown command pattern)"
	;;
esac

# 6. Suggested fixes
echo ""
echo -e "${BLUE}=== Suggested Fixes ===${NC}"
if [[ "$MCP_NAME" == "$PLAYWRIGHT_MCP_NAME" ]]; then
	echo "1. Verify tool: $PLAYWRIGHT_MCP_RUN --version"
else
	echo "1. Update tool: npm update -g $NPM_PKG"
fi
echo "2. Check official docs for command changes"
if [[ "$MCP_NAME" == "$PLAYWRIGHT_MCP_NAME" ]]; then
	echo "3. Run: $PLAYWRIGHT_MCP_RUN --help"
else
	echo "3. Run: $CLI_CMD --help"
fi
echo "4. Check ~/.aidevops/agents/tools/ for updated documentation"
echo "5. Verify MCP status in your runtime's config after fixes"
