#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-repo-maintenance.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
INSTALL_DIR="$REPO_ROOT"
AGENTS_DIR="$REPO_ROOT/.agents"
CONFIG_DIR="${HOME}/.config/aidevops"
REPOS_FILE="${CONFIG_DIR}/repos.json"
export INSTALL_DIR AGENTS_DIR CONFIG_DIR REPOS_FILE

mkdir -p "$CONFIG_DIR" "${TEST_ROOT}/repo-a" "${TEST_ROOT}/repo-b"
repo_a="$(cd "${TEST_ROOT}/repo-a" && pwd -P)"
repo_b="$(cd "${TEST_ROOT}/repo-b" && pwd -P)"
jq -n --arg repo_a "$repo_a" --arg repo_b "$repo_b" '{
  initialized_repos: [
    {slug: "owner/repo-a", path: $repo_a, pulse: true, marker: "preserve"},
    {slug: "owner/repo-b", path: $repo_b, pulse: true}
  ],
  git_parent_dirs: []
}' >"$REPOS_FILE"

print_error() {
	return 0
}

# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
source "$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh"

initial_state=$(get_repo_maintenance_state "owner/repo-b")
[[ "$initial_state" == $'true\ttrue\towner/repo-b\t'"$repo_b" ]]

set_repo_maintenance "owner/repo-a" false
[[ "$(jq -r '.initialized_repos[0].maintenance' "$REPOS_FILE")" == "false" ]]
[[ "$(jq -r '.initialized_repos[0].pulse' "$REPOS_FILE")" == "false" ]]
[[ "$(jq -r '.initialized_repos[0].marker' "$REPOS_FILE")" == "preserve" ]]
paused_state=$(get_repo_maintenance_state "owner/repo-a")
[[ "$paused_state" == $'false\tfalse\towner/repo-a\t'"$repo_a" ]]

# Safety cleanup must still enumerate a repo after the public pause operation
# sets both maintenance:false and pulse:false.
REPOS_JSON="$REPOS_FILE"
export REPOS_JSON
# shellcheck source=../shared-dispatch-label-cleanup.sh
source "$REPO_ROOT/.agents/scripts/shared-dispatch-label-cleanup.sh"
safety_slugs=$(_dispatch_label_sweep_repos "$REPOS_FILE")
[[ $'\n'"$safety_slugs"$'\n' == *$'\nowner/repo-a\n'* ]]

set_repo_maintenance "$repo_a" true
[[ "$(jq -r '.initialized_repos[0].maintenance' "$REPOS_FILE")" == "true" ]]
[[ "$(jq -r '.initialized_repos[0].pulse' "$REPOS_FILE")" == "false" ]]

cli_output=$(bash "$REPO_ROOT/aidevops.sh" repos maintenance off owner/repo-a)
[[ "$cli_output" == *"Maintenance paused for owner/repo-a"* ]]
list_output=$(bash "$REPO_ROOT/aidevops.sh" repos list)
[[ "$list_output" == *"Automation: dormant (Pulse: off)"* ]]
cli_output=$(bash "$REPO_ROOT/aidevops.sh" repos maintenance on owner/repo-a)
[[ "$cli_output" == *"Maintenance enabled for owner/repo-a (Pulse remains false)"* ]]
list_output=$(bash "$REPO_ROOT/aidevops.sh" repos list)
[[ "$list_output" == *"Automation: maintained (Pulse: false)"* ]]

before=$(shasum -a 256 "$REPOS_FILE" | cut -d' ' -f1)
if set_repo_maintenance "owner/missing" false; then
	printf 'FAIL unknown repository was accepted\n' >&2
	exit 1
fi
after=$(shasum -a 256 "$REPOS_FILE" | cut -d' ' -f1)
[[ "$before" == "$after" ]]

if set_repo_maintenance "owner/repo-a" invalid; then
	printf 'FAIL invalid maintenance state was accepted\n' >&2
	exit 1
fi
if compgen -G "${REPOS_FILE}.tmp.*" >/dev/null; then
	printf 'FAIL temporary repos.json files were not cleaned up\n' >&2
	exit 1
fi

printf 'PASS repository maintenance state uses atomic replacement, remains backward compatible, and preserves safety scope\n'
