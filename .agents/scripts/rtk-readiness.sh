#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shared optional RTK readiness and tested-baseline relation contract.

aidevops_rtk_tested_version() {
	printf '0.41.0\n'
	return 0
}

aidevops_rtk_installed_version() {
	local version_output=""
	if ! command -v rtk >/dev/null 2>&1; then
		printf 'missing\n'
		return 0
	fi
	version_output=$(rtk --version 2>/dev/null || true)
	if [[ "$version_output" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	else
		printf 'unknown\n'
	fi
	return 0
}

aidevops_rtk_version_state() {
	local installed_version="$1"
	local tested_version="${2:-}"
	local installed_major="" installed_minor="" installed_patch=""
	local tested_major="" tested_minor="" tested_patch=""
	local semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

	if [[ -z "$tested_version" ]]; then
		tested_version=$(aidevops_rtk_tested_version)
	fi
	case "$installed_version" in
	missing)
		printf 'missing\n'
		return 0
		;;
	unknown)
		printf 'unknown\n'
		return 0
		;;
	esac
	if [[ ! "$installed_version" =~ $semver_pattern ]] ||
		[[ ! "$tested_version" =~ $semver_pattern ]]; then
		printf 'unknown\n'
		return 0
	fi

	IFS=. read -r installed_major installed_minor installed_patch <<<"$installed_version"
	IFS=. read -r tested_major tested_minor tested_patch <<<"$tested_version"
	if ((installed_major < tested_major)) ||
		((installed_major == tested_major && installed_minor < tested_minor)) ||
		((installed_major == tested_major && installed_minor == tested_minor && installed_patch < tested_patch)); then
		printf 'older\n'
	elif [[ "$installed_version" == "$tested_version" ]]; then
		printf 'tested\n'
	else
		printf 'newer-untested\n'
	fi
	return 0
}
