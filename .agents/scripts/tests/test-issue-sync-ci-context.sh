#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TEST_DIR}/.."
CONTEXT_LIB="${SCRIPTS_DIR}/issue-sync-ci-context.sh"
ISSUE_SYNC_HELPER="${SCRIPTS_DIR}/issue-sync-helper.sh"
WORKFLOW="$(cd "${SCRIPTS_DIR}/../.." && pwd)/.github/workflows/issue-sync-reusable.yml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() {
	printf 'PASS: %s\n' "$1"
	return 0
}
fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

if (
	unset GITHUB_ACTIONS GITHUB_REPOSITORY PRIVACY_REPOS_CONFIG AIDEVOPS_REPOS_JSON
	# shellcheck source=../issue-sync-ci-context.sh
	source "$CONTEXT_LIB"
	issue_sync_prepare_ci_context
	[[ -z "${PRIVACY_REPOS_CONFIG:-}" && -z "${AIDEVOPS_REPOS_JSON:-}" ]]
); then
	pass "non-CI callers retain their existing repository context"
else
	fail "non-CI caller context changed"
fi

CI_HOME="$TMP/home"
CI_TEMP="$TMP/runner"
CI_ENV="$TMP/github-env"
mkdir -p "$CI_HOME" "$CI_TEMP"
if (
	export HOME="$CI_HOME"
	export RUNNER_TEMP="$CI_TEMP"
	export GITHUB_ACTIONS=true
	export GITHUB_REPOSITORY=example/repo
	unset PRIVACY_REPOS_CONFIG AIDEVOPS_REPOS_JSON
	# shellcheck source=../issue-sync-ci-context.sh
	source "$CONTEXT_LIB"
	issue_sync_write_ci_context_env "$CI_ENV"
	[[ "$PRIVACY_REPOS_CONFIG" == "$AIDEVOPS_REPOS_JSON" ]]
	jq -e '.initialized_repos == [{"slug":"example/repo","role":"maintainer"}]' \
		"$PRIVACY_REPOS_CONFIG" >/dev/null
	[[ "$(stat -c '%a' "$PRIVACY_REPOS_CONFIG" 2>/dev/null || stat -f '%Lp' "$PRIVACY_REPOS_CONFIG")" == "600" ]]
	grep -Fxq "PRIVACY_REPOS_CONFIG=$PRIVACY_REPOS_CONFIG" "$CI_ENV"
	grep -Fxq "AIDEVOPS_REPOS_JSON=$AIDEVOPS_REPOS_JSON" "$CI_ENV"
); then
	pass "hosted CI receives one current-repository privacy and write-policy inventory"
else
	fail "hosted CI inventory was missing, broad, or not private"
fi

if (
	export HOME="$TMP/role-home"
	export RUNNER_TEMP="$TMP/role-runner"
	export GITHUB_ACTIONS=true
	export GITHUB_REPOSITORY=example/repo
	unset PRIVACY_REPOS_CONFIG AIDEVOPS_REPOS_JSON _ISSUE_SYNC_CI_CONTEXT_LOADED _GH_WRITE_POLICY_LIB_LOADED
	mkdir -p "$HOME" "$RUNNER_TEMP"
	# shellcheck source=../issue-sync-ci-context.sh
	source "$CONTEXT_LIB"
	issue_sync_prepare_ci_context >/dev/null
	_SHIM_DIR="$SCRIPTS_DIR"
	# shellcheck source=../gh-write-policy-lib.sh
	source "${SCRIPTS_DIR}/gh-write-policy-lib.sh"
	[[ "$(_shim_repo_role example/repo)" == "maintainer" ]]
); then
	pass "generated CI context authorizes only the workflow's current repository"
else
	fail "current repository remained classified as external in hosted CI"
fi

HELP_HOME="$TMP/help-home"
HELP_TEMP="$TMP/help-runner"
mkdir -p "$HELP_HOME" "$HELP_TEMP"
if HOME="$HELP_HOME" RUNNER_TEMP="$HELP_TEMP" GITHUB_ACTIONS=true GITHUB_REPOSITORY=example/repo \
	bash "$ISSUE_SYNC_HELPER" help >"$TMP/help.out" 2>"$TMP/help.err" &&
	grep -q 'repository-scoped CI privacy and write-policy inventory' "$TMP/help.out" &&
	jq -e '.initialized_repos[0].slug == "example/repo" and .initialized_repos[0].role == "maintainer"' \
		"$HELP_TEMP"/aidevops-issue-sync-ci-context.* >/dev/null 2>&1; then
	pass "Issue Sync prepares CI context before loading shared GitHub wrappers"
else
	fail "Issue Sync orchestrator did not establish CI context before wrapper loading"
fi

SETUP_LINE=$(awk '/name: Setup gh shim/{line=NR} END{print line}' "$WORKFLOW")
# shellcheck disable=SC2016 # Match literal GitHub workflow shell variables.
CONTEXT_LINE=$(awk '/issue_sync_write_ci_context_env "\$GITHUB_ENV"/{line=NR} END{print line}' "$WORKFLOW")
# shellcheck disable=SC2016 # Match literal GitHub workflow shell variables.
PATH_LINE=$(awk '/echo "\$\{SHIM_DIR\}" >> "\$GITHUB_PATH"/{line=NR} END{print line}' "$WORKFLOW")
if [[ -n "$SETUP_LINE" && -n "$CONTEXT_LINE" && -n "$PATH_LINE" &&
	"$SETUP_LINE" -lt "$CONTEXT_LINE" && "$CONTEXT_LINE" -lt "$PATH_LINE" ]]; then
	pass "PR-merge inline writes inherit CI context before the gh shim activates"
else
	fail "PR-merge gh shim activated without a persisted current-repository context"
fi

if (
	export HOME="$TMP/bad-home"
	export RUNNER_TEMP="$TMP/bad-runner"
	export GITHUB_ACTIONS=true
	export GITHUB_REPOSITORY='not-a-slug'
	unset PRIVACY_REPOS_CONFIG AIDEVOPS_REPOS_JSON _ISSUE_SYNC_CI_CONTEXT_LOADED
	mkdir -p "$HOME" "$RUNNER_TEMP"
	# shellcheck source=../issue-sync-ci-context.sh
	source "$CONTEXT_LIB"
	! issue_sync_prepare_ci_context >/dev/null 2>&1
); then
	pass "malformed CI repository identity fails closed"
else
	fail "malformed CI repository identity was accepted"
fi

printf 'PASS: issue sync CI context regressions\n'
