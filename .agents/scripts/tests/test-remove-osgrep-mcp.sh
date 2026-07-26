#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

assert_only_compatibility_or_history_references_remain() {
	local relative_path
	local unexpected=0

	while IFS= read -r relative_path; do
		case "$relative_path" in
		.agents/scripts/lib/mcp_config.py | \
			.agents/scripts/setup/modules/migrations.sh | \
			.agents/scripts/tests/test-remove-osgrep-mcp.sh | \
			.gitignore | \
			CHANGELOG.md | \
			TODO.md | \
			tests/test-migrate-orphaned-supervisor.sh | \
			todo/*)
			continue
			;;
		*)
			printf 'FAIL active osgrep reference remains in %s\n' "$relative_path"
			unexpected=1
			;;
		esac
	done < <(git -C "$REPO_ROOT" grep -Il -i osgrep || true)

	if [[ $unexpected -ne 0 ]]; then
		return 1
	fi

	printf 'PASS only compatibility or historical osgrep references remain\n'
	return 0
}

assert_cleanup_preserves_unrelated_config() {
	local tmp_config
	tmp_config="$(mktemp)"
	printf '%s\n' '{"mcp":{"osgrep":{},"context7":{}},"tools":{"osgrep_*":true,"context7_*":true}}' >"$tmp_config"

	python3 - "$REPO_ROOT" "$tmp_config" <<'PY'
import importlib.util
import json
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
config_path = pathlib.Path(sys.argv[2])
module_path = repo_root / ".agents/scripts/lib/mcp_config.py"
spec = importlib.util.spec_from_file_location("mcp_config", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = json.loads(config_path.read_text())
module.remove_deprecated_mcps(config)
config_path.write_text(json.dumps(config))
PY

	if ! jq -e '.mcp.context7 and .tools["context7_*"]' "$tmp_config" >/dev/null; then
		printf 'FAIL cleanup removed unrelated MCP configuration\n'
		rm -f "$tmp_config"
		return 1
	fi

	if jq -e '.mcp.osgrep or .tools["osgrep_*"]' "$tmp_config" >/dev/null; then
		printf 'FAIL cleanup retained deprecated MCP configuration\n'
		rm -f "$tmp_config"
		return 1
	fi

	rm -f "$tmp_config"
	printf 'PASS cleanup removes stale config and preserves unrelated entries\n'
	return 0
}

main() {
	assert_only_compatibility_or_history_references_remain
	assert_cleanup_preserves_unrelated_config
	return 0
}

main "$@"
