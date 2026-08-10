#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

main() {
	local aidevops_bin="${AIDEVOPS_BIN:-aidevops}"
	local node_bin="${NODE_BIN:-node}"
	local entrypoint="${QUICKFILE_MCP_ENTRYPOINT:-${HOME}/Git/mcp/quickfile-mcp/dist/index.js}"
	local inventory=""
	local secret_name=""
	local secret_names=()

	command -v "$aidevops_bin" >/dev/null 2>&1 || {
		printf 'QuickFile MCP launcher requires aidevops secret management\n' >&2
		return 1
	}
	command -v jq >/dev/null 2>&1 || {
		printf 'QuickFile MCP launcher requires jq\n' >&2
		return 1
	}
	command -v "$node_bin" >/dev/null 2>&1 || {
		printf 'QuickFile MCP launcher requires Node.js 18 or newer\n' >&2
		return 1
	}
	[[ -f "$entrypoint" ]] || {
		printf 'QuickFile MCP entrypoint not found: %s\n' "$entrypoint" >&2
		return 1
	}

	inventory=$("$aidevops_bin" secret inventory) || {
		printf 'Unable to read the names-only aidevops secret inventory\n' >&2
		return 1
	}
	while IFS= read -r secret_name; do
		[[ -n "$secret_name" ]] && secret_names+=("$secret_name")
	done < <(
		printf '%s' "$inventory" | jq -r '
			[.secrets[]
			 | select(.status == "configured")
			 | .name
			 | select(test("^QUICKFILE_([A-Z0-9_]+_)?(API_KEY|API_TOKEN|BEARER_TOKEN)$"))]
			| unique[]'
	)

	if [[ ${#secret_names[@]} -eq 0 ]]; then
		printf 'No QuickFile bearer tokens configured; expected QUICKFILE_<ACCOUNT>_API_KEY\n' >&2
		return 1
	fi

	if [[ "${QUICKFILE_MCP_LAUNCHER_DRY_RUN:-0}" == "1" ]]; then
		printf 'QuickFile MCP launcher validated %s account token(s)\n' "${#secret_names[@]}"
		return 0
	fi

	exec "$aidevops_bin" secret "${secret_names[@]}" -- "$node_bin" "$entrypoint"
	return 1
}

main
