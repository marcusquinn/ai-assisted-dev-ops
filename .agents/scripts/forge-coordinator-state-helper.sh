#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

readonly RESTORE_DEFERRED_MARKER=".restore-deferred"
readonly RESTORE_EMPTY_INIT_MARKER=".restore-empty-init"

print_error_file() {
	local error_file="$1"
	local line=""
	while IFS= read -r line; do
		printf '%s\n' "$line" >&2
	done <"$error_file"
	return 0
}

is_github_rate_limited() {
	local error_file="$1"
	grep -qiE 'API rate limit exceeded|GraphQL: API rate limit (already )?exceeded|secondary rate limit|abuse detection|was submitted too quickly' "$error_file" && return 0
	return 1
}

defer_restore() {
	local state_dir="$1"
	local repository="$2"
	local reason="$3"
	touch "${state_dir}/${RESTORE_DEFERRED_MARKER}" || return 1
	printf '::warning title=Coordinator restore deferred::%s for %s; preserving the latest durable checkpoint and skipping event publication.\n' "$reason" "$repository" >&2
	return 0
}

defer_rate_limited_restore() {
	local state_dir="$1"
	local repository="$2"
	local error_file="$3"
	print_error_file "$error_file"
	defer_restore "$state_dir" "$repository" "GitHub API rate limit is exhausted" || return 1
	return 0
}

restore_state() {
	local state_dir="$1"
	local repository="$2"
	local repository_id="$3"
	local artifact_name="forge-coordinator-${repository_id}"
	local artifact_id="" artifact_json="" archive="" error_file=""
	local legacy_count="" legacy_total=""
	mkdir -p "$state_dir"
	rm -f "${state_dir}/${RESTORE_DEFERRED_MARKER}" "${state_dir}/${RESTORE_EMPTY_INIT_MARKER}"
	error_file=$(mktemp "${state_dir}/restore-error.XXXXXX") || return 1

	# New checkpoints use one stable name, allowing GitHub to filter server-side.
	# This replaces the former --paginate scan across every repository artifact.
	if ! artifact_json=$(gh api "repos/${repository}/actions/artifacts?name=${artifact_name}&per_page=1" 2>"$error_file"); then
		if is_github_rate_limited "$error_file"; then
			defer_rate_limited_restore "$state_dir" "$repository" "$error_file"
			rm -f "$error_file"
			return 0
		fi
		print_error_file "$error_file"
		rm -f "$error_file"
		return 1
	fi
	artifact_id=$(jq -r --arg name "$artifact_name" '[.artifacts[]? | select((.name == $name) and ((.expired // false) == false))] | sort_by([.created_at, .id]) | last | .id // empty' <<<"$artifact_json") || {
		rm -f "$error_file"
		return 1
	}

	# One bounded legacy page migrates checkpoints written with run-ID suffixes.
	if [[ -z "$artifact_id" ]]; then
		if ! artifact_json=$(gh api "repos/${repository}/actions/artifacts?per_page=100" 2>"$error_file"); then
			if is_github_rate_limited "$error_file"; then
				defer_rate_limited_restore "$state_dir" "$repository" "$error_file"
				rm -f "$error_file"
				return 0
			fi
			print_error_file "$error_file"
			rm -f "$error_file"
			return 1
		fi
		artifact_id=$(jq -r --arg prefix "${artifact_name}-" '[.artifacts[]? | select((.name | startswith($prefix)) and ((.expired // false) == false))] | sort_by([.created_at, .id]) | last | .id // empty' <<<"$artifact_json") || {
			rm -f "$error_file"
			return 1
		}
		legacy_count=$(jq -r '.artifacts | length' <<<"$artifact_json") || {
			rm -f "$error_file"
			return 1
		}
		legacy_total=$(jq -r '.total_count // (.artifacts | length)' <<<"$artifact_json") || {
			rm -f "$error_file"
			return 1
		}
		if [[ -z "$artifact_id" && "$legacy_count" =~ ^[0-9]+$ && "$legacy_total" =~ ^[0-9]+$ ]] && ((legacy_total > legacy_count)); then
			touch "${state_dir}/${RESTORE_EMPTY_INIT_MARKER}" || {
				rm -f "$error_file"
				return 1
			}
			printf '::warning title=Coordinator state initialized::No matching checkpoint was found in the bounded legacy artifact page for %s; initializing one stable-name checkpoint without scanning all repository artifacts.\n' "$repository" >&2
		fi
	fi
	if [[ -z "$artifact_id" ]]; then
		rm -f "$error_file"
		return 0
	fi
	if [[ ! "$artifact_id" =~ ^[1-9][0-9]*$ ]]; then
		printf 'Invalid coordinator artifact ID returned for repository %s: %q\n' "$repository" "$artifact_id" >&2
		rm -f "$error_file"
		return 1
	fi
	archive="${state_dir}/state.zip"
	if ! gh api "repos/${repository}/actions/artifacts/${artifact_id}/zip" >"$archive" 2>"$error_file"; then
		rm -f "$archive"
		if is_github_rate_limited "$error_file"; then
			defer_rate_limited_restore "$state_dir" "$repository" "$error_file"
			rm -f "$error_file"
			return 0
		fi
		print_error_file "$error_file"
		rm -f "$error_file"
		return 1
	fi
	if ! unzip -oq "$archive" -d "$state_dir"; then
		rm -f "$archive" "$error_file"
		return 1
	fi
	rm -f "$archive" "$error_file"
	return 0
}

main() {
	local command="${1:-}"
	case "$command" in
	restore) restore_state "${2:?state directory required}" "${3:?repository required}" "${4:?repository ID required}" ;;
	*)
		printf 'Usage: %s restore STATE_DIR REPOSITORY REPOSITORY_ID\n' "$0" >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
