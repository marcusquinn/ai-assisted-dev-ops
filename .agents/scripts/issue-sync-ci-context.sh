#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Narrow, repository-scoped runtime context for Issue Sync in GitHub Actions.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_ISSUE_SYNC_CI_CONTEXT_LOADED:-}" ]] && return 0
_ISSUE_SYNC_CI_CONTEXT_LOADED=1

issue_sync_prepare_ci_context() {
	local default_config="${HOME}/.config/aidevops/repos.json"
	local temp_root=""
	local inventory=""
	local repo="${GITHUB_REPOSITORY:-}"

	[[ "${GITHUB_ACTIONS:-}" == "true" ]] || return 0
	if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		printf '%s\n' '::error::Issue Sync cannot establish the current GitHub Actions repository context.' >&2
		return 1
	fi
	if [[ -n "${PRIVACY_REPOS_CONFIG:-}" && -n "${AIDEVOPS_REPOS_JSON:-}" ]]; then
		return 0
	fi
	if [[ -f "$default_config" ]]; then
		[[ -n "${PRIVACY_REPOS_CONFIG:-}" ]] || export PRIVACY_REPOS_CONFIG="$default_config"
		[[ -n "${AIDEVOPS_REPOS_JSON:-}" ]] || export AIDEVOPS_REPOS_JSON="$default_config"
		return 0
	fi

	# GITHUB_REPOSITORY is runner-owned event metadata and GITHUB_TOKEN is scoped
	# to that repository. Record only that current target: it authorizes no
	# cross-repository write and exposes no user-owned private inventory.
	temp_root="${RUNNER_TEMP:-${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}}"
	mkdir -p "$temp_root" || return 1
	inventory=$(mktemp "${temp_root%/}/aidevops-issue-sync-ci-context.XXXXXX") || return 1
	printf '{"initialized_repos":[{"slug":"%s","role":"maintainer"}]}\n' "$repo" >"$inventory" || return 1
	chmod 600 "$inventory" 2>/dev/null || true
	[[ -n "${PRIVACY_REPOS_CONFIG:-}" ]] || export PRIVACY_REPOS_CONFIG="$inventory"
	[[ -n "${AIDEVOPS_REPOS_JSON:-}" ]] || export AIDEVOPS_REPOS_JSON="$inventory"
	export ISSUE_SYNC_CI_CONTEXT_INVENTORY="$inventory"
	printf '%s\n' '::notice::Issue Sync is using an ephemeral repository-scoped CI privacy and write-policy inventory.'
	return 0
}

issue_sync_write_ci_context_env() {
	local env_file="${1:-${GITHUB_ENV:-}}"
	issue_sync_prepare_ci_context || return 1
	[[ "${GITHUB_ACTIONS:-}" == "true" ]] || return 0
	if [[ -z "$env_file" || "$env_file" == *$'\n'* || "$env_file" == *$'\r'* ||
		"${PRIVACY_REPOS_CONFIG:-}" == *$'\n'* || "${PRIVACY_REPOS_CONFIG:-}" == *$'\r'* ||
		"${AIDEVOPS_REPOS_JSON:-}" == *$'\n'* || "${AIDEVOPS_REPOS_JSON:-}" == *$'\r'* ]]; then
		printf '%s\n' '::error::Issue Sync refused an unsafe GitHub Actions environment path.' >&2
		return 1
	fi
	{
		printf 'PRIVACY_REPOS_CONFIG=%s\n' "$PRIVACY_REPOS_CONFIG"
		printf 'AIDEVOPS_REPOS_JSON=%s\n' "$AIDEVOPS_REPOS_JSON"
	} >>"$env_file" || return 1
	return 0
}
