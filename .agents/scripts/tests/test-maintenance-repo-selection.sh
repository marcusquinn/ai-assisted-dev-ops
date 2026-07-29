#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-maintenance-selection.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
CONFIG_DIR="${HOME}/.config/aidevops"
DEPLOYED_SCRIPTS_DIR="${HOME}/.aidevops/agents/scripts"
mkdir -p "$CONFIG_DIR" "$DEPLOYED_SCRIPTS_DIR"
cp "$REPO_ROOT/.agents/scripts/readme-badges-helper.sh" \
	"${DEPLOYED_SCRIPTS_DIR}/readme-badges-helper.sh"
chmod +x "${DEPLOYED_SCRIPTS_DIR}/readme-badges-helper.sh"

legacy_path="${TEST_ROOT}/legacy"
maintained_path="${TEST_ROOT}/maintained"
dormant_path="${TEST_ROOT}/dormant"
local_path="${TEST_ROOT}/local"
contributed_path="${TEST_ROOT}/contributed"
contributor_path="${TEST_ROOT}/contributor"
mkdir -p "$legacy_path" "$maintained_path" "$dormant_path" "$local_path" "$contributed_path" "$contributor_path"
jq -n \
	--arg legacy "$legacy_path" \
	--arg maintained "$maintained_path" \
	--arg dormant "$dormant_path" \
	--arg local_path "$local_path" \
	--arg contributed "$contributed_path" \
	--arg contributor "$contributor_path" '{initialized_repos: [
		{slug: "owner/legacy", path: $legacy, pulse: true},
		{slug: "owner/maintained", path: $maintained, pulse: true, maintenance: true},
		{slug: "owner/dormant", path: $dormant, pulse: true, maintenance: false},
		{slug: "owner/local", path: $local_path, pulse: true, maintenance: false, local_only: true},
		{slug: "marcusquinn/contributed", path: $contributed, pulse: true, maintenance: false, contributed: true},
		{slug: "marcusquinn/contributor", path: $contributor, pulse: true, maintenance: false, role: "contributor"}
	]}' >"${CONFIG_DIR}/repos.json"

check_all=$(bash "$REPO_ROOT/.agents/scripts/check-workflows-helper.sh" \
	--json --workflow issue-sync 2>/dev/null || true)
[[ "$(printf '%s\n' "$check_all" | jq -s 'length')" == "2" ]]
[[ "$(printf '%s\n' "$check_all" | jq -s 'any(.[]; .slug == "owner/dormant")')" == "false" ]]

check_explicit=$(bash "$REPO_ROOT/.agents/scripts/check-workflows-helper.sh" \
	--json --repo owner/dormant --workflow issue-sync 2>/dev/null || true)
[[ "$(printf '%s\n' "$check_explicit" | jq -r '.slug')" == "owner/dormant" ]]

check_local=$(bash "$REPO_ROOT/.agents/scripts/check-workflows-helper.sh" \
	--json --repo owner/local --workflow issue-sync 2>/dev/null || true)
[[ "$(printf '%s\n' "$check_local" | jq -r '.classification')" == "LOCAL-ONLY" ]]

badges_all=$(bash "$REPO_ROOT/.agents/scripts/badges-check-helper.sh" --json 2>/dev/null || true)
[[ "$(printf '%s\n' "$badges_all" | jq -s 'length')" == "2" ]]
[[ "$(printf '%s\n' "$badges_all" | jq -s 'any(.[]; .slug == "owner/dormant")')" == "false" ]]

badges_explicit=$(bash "$REPO_ROOT/.agents/scripts/badges-check-helper.sh" \
	--json --repo owner/dormant 2>/dev/null || true)
[[ "$(printf '%s\n' "$badges_explicit" | jq -r '.slug')" == "owner/dormant" ]]

badges_contributed=$(bash "$REPO_ROOT/.agents/scripts/badges-check-helper.sh" \
	--json --repo marcusquinn/contributed 2>/dev/null || true)
[[ "$(printf '%s\n' "$badges_contributed" | jq -r '.classification')" == "EXTERNAL" ]]

badges_contributor=$(bash "$REPO_ROOT/.agents/scripts/badges-check-helper.sh" \
	--json --repo marcusquinn/contributor 2>/dev/null || true)
[[ "$(printf '%s\n' "$badges_contributor" | jq -r '.classification')" == "EXTERNAL" ]]

python3 - "$REPO_ROOT" "${CONFIG_DIR}/repos.json" <<'PYEOF'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
repos_json = pathlib.Path(sys.argv[2])
module_path = root / ".agents" / "scripts" / "pulse-check-queue-scan.py"
spec = importlib.util.spec_from_file_location("pulse_check_queue_scan", module_path)
if spec is None or spec.loader is None:
    raise SystemExit("FAIL: could not load Pulse queue scanner")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
repos, error = module._load_repos(repos_json)
assert error == "", error
assert [repo["slug"] for repo in repos] == ["owner/legacy", "owner/maintained"]
PYEOF

# The batched owner prefetch must use the same maintenance boundary.
export SCRIPT_DIR="$REPO_ROOT/.agents/scripts"
# shellcheck source=../pulse-batch-prefetch-helper.sh
source "$REPO_ROOT/.agents/scripts/pulse-batch-prefetch-helper.sh" help >/dev/null
owner_group=$(_group_repos_by_owner "${CONFIG_DIR}/repos.json")
[[ "$owner_group" == "owner|owner/legacy,owner/maintained" ]]

printf 'PASS recurring repo selectors skip dormant entries and explicit checks retain access\n'
