#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

main() {
	local aidevops_bin="${AIDEVOPS_BIN:-aidevops}"
	local node_bin="${NODE_BIN:-node}"
	local canonical_entrypoint="${HOME}/Git/mcp/quickfile-mcp/dist/index.js"
	local legacy_entrypoint="${HOME}/Git/quickfile-mcp/dist/index.js"
	local entrypoint=""
	local project_dir=""
	local required_node=""
	local current_node=""
	local nvm_node_bin=""
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
	if [[ -f "$canonical_entrypoint" ]]; then
		entrypoint="$canonical_entrypoint"
	elif [[ -f "$legacy_entrypoint" ]]; then
		entrypoint="$legacy_entrypoint"
	else
		entrypoint="$canonical_entrypoint"
	fi
	[[ -f "$entrypoint" ]] || {
		printf 'QuickFile MCP entrypoint not found: %s\n' "$entrypoint" >&2
		return 1
	}
	project_dir="$(dirname "$(dirname "$entrypoint")")"
	if [[ -f "$project_dir/.nvmrc" ]]; then
		required_node="$(<"$project_dir/.nvmrc")"
		required_node="${required_node#v}"
		nvm_node_bin="${NVM_DIR:-${HOME}/.nvm}/versions/node/v${required_node}/bin/node"
		if [[ -z "${NODE_BIN:-}" && -x "$nvm_node_bin" ]]; then
			node_bin="$nvm_node_bin"
		fi
	fi
	command -v "$node_bin" >/dev/null 2>&1 || {
		printf 'QuickFile MCP launcher requires the Node.js version declared by quickfile-mcp\n' >&2
		return 1
	}
	if [[ -n "$required_node" ]]; then
		current_node="$("$node_bin" --version)" || {
			printf 'Unable to determine the QuickFile MCP Node.js version\n' >&2
			return 1
		}
		current_node="${current_node#v}"
		if [[ "$current_node" != "$required_node" ]]; then
			printf 'QuickFile MCP requires Node.js %s from .nvmrc; got %s. Set NODE_BIN to the matching executable.\n' "$required_node" "$current_node" >&2
			return 1
		fi
	fi

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
