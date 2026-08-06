#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
AGENT_DEPLOY="$REPO_ROOT/.agents/scripts/setup/modules/agent-deploy.sh"
TEMP_ROOT="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
TEST_ROOT=""
MOCK_INSTALL_TARGET=""

print_info() {
	local message="$1"
	: "$message"
	return 0
}
print_success() {
	local message="$1"
	: "$message"
	return 0
}
print_warning() {
	local message="$1"
	: "$message"
	return 0
}
print_error() {
	local message="$1"
	printf '%s\n' "$message" >&2
	return 0
}

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

prepare_fixture() {
	local target_dir="$1"
	mkdir -p "$target_dir/scripts" "$target_dir/schemas"
	cp "$REPO_ROOT/.agents/package.json" "$target_dir/package.json"
	cp "$REPO_ROOT/.agents/package-lock.json" "$target_dir/package-lock.json"
	cp "$REPO_ROOT/.agents/scripts/team-interface-common.mjs" "$target_dir/scripts/team-interface-common.mjs"
	cp "$REPO_ROOT/.agents/scripts/team-interface-validators.mjs" "$target_dir/scripts/team-interface-validators.mjs"
	cp -R "$REPO_ROOT/.agents/schemas/team-interface" "$target_dir/schemas/team-interface"
	return 0
}

npm() {
	local command_name="${1:-}"
	: "$command_name"
	if ! node --input-type=module - "$REPO_ROOT" "$MOCK_INSTALL_TARGET" <<'NODE'; then
import {cpSync, mkdirSync, readFileSync} from "node:fs";
import {dirname, resolve} from "node:path";

const repoRoot = process.argv[2];
const targetRoot = process.argv[3];
const lock = JSON.parse(readFileSync(resolve(repoRoot, ".agents/package-lock.json"), "utf8"));
for (const packagePath of Object.keys(lock.packages)) {
  if (!packagePath.startsWith("node_modules/")) continue;
  const source = resolve(repoRoot, packagePath);
  const destination = resolve(targetRoot, packagePath);
  mkdirSync(dirname(destination), {recursive: true});
  cpSync(source, destination, {recursive: true});
}
NODE
		return 1
	fi
	return 0
}

main() {
	local activation_gate="_install_agent_runtime_deps \"\$target_dir\" || return 1"
	mkdir -p "$TEMP_ROOT"
	TEST_ROOT=$(mktemp -d "$TEMP_ROOT/team-interface-runtime-deps.XXXXXX") || return 1
	trap cleanup EXIT

	# shellcheck source=/dev/null
	source "$AGENT_DEPLOY"

	MOCK_INSTALL_TARGET="$TEST_ROOT/deployed-agents"
	prepare_fixture "$MOCK_INSTALL_TARGET"
	ln -s "$REPO_ROOT/node_modules" "$TEST_ROOT/node_modules"
	if _verify_agent_runtime_deps "$MOCK_INSTALL_TARGET" >/dev/null 2>&1; then
		fail "dependency verification accepted an ancestor node_modules tree"
	fi
	_install_agent_runtime_deps "$MOCK_INSTALL_TARGET" || fail "locked deployed dependency installation failed"
	_verify_agent_runtime_deps "$MOCK_INSTALL_TARGET" || fail "deployed runtime dependency verification failed"
	[[ -d "$MOCK_INSTALL_TARGET/node_modules" && ! -L "$MOCK_INSTALL_TARGET/node_modules" ]] ||
		fail "mock npm install did not provide a local deployed dependency tree"

	grep -qF "$activation_gate" "$AGENT_DEPLOY" ||
		fail "runtime bundle activation does not enforce dependency verification"
	grep -qF -- 'npm ci --omit=dev --ignore-scripts' "$AGENT_DEPLOY" ||
		fail "agent runtime dependency installation permits package lifecycle scripts"
	printf 'PASS: team-interface runtime dependencies are pinned and activation-gated\n'
	return 0
}

main "$@"
