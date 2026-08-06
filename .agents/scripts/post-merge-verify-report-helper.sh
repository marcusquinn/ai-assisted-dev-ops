#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
	printf 'Usage:\n'
	printf '  post-merge-verify-report-helper.sh truncate-output <output-file> <max-bytes>\n'
	printf '  post-merge-verify-report-helper.sh publish-comment <repo> <pr-number> <body-file>\n'
	printf '  post-merge-verify-report-helper.sh create-follow-up <repo> <title> <body-file>\n'
	return 0
}

truncate_output() {
	local output_file="$1"
	local max_bytes="$2"
	local output_size=0
	local truncated_file=""

	if [[ ! -f "$output_file" || ! "$max_bytes" =~ ^[1-9][0-9]*$ ]]; then
		printf 'ERROR: truncate-output requires an existing file and positive byte limit.\n' >&2
		return 2
	fi

	# BSD wc pads numeric output; normalize it before comparisons and reports.
	output_size=$(wc -c <"$output_file" | tr -d '[:space:]')
	if [[ "$output_size" -le "$max_bytes" ]]; then
		return 0
	fi

	truncated_file="${output_file}.truncated.$$"
	if ! dd if="$output_file" of="$truncated_file" bs="$max_bytes" count=1 2>/dev/null; then
		rm -f "$truncated_file"
		printf 'ERROR: could not truncate verification output.\n' >&2
		return 1
	fi
	printf '\n[output truncated from %s bytes to %s bytes]\n' "$output_size" "$max_bytes" >>"$truncated_file"
	mv "$truncated_file" "$output_file"
	return 0
}

publish_comment() {
	local repo="$1"
	local pr_number="$2"
	local body_file="$3"
	local body=""

	if [[ ! -f "$body_file" ]]; then
		printf 'ERROR: report body file not found: %s\n' "$body_file" >&2
		return 2
	fi

	body=$(<"$body_file")
	if gh api --method POST "repos/${repo}/issues/${pr_number}/comments" -f body="$body" >/dev/null; then
		printf 'Post-merge verification comment published through the REST issues endpoint.\n'
		return 0
	fi

	printf '::warning::Unable to publish the post-merge verification comment. The check summary preserves the result; verify GH_TOKEN and issues:write permission.\n' >&2
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		# shellcheck disable=SC2016 # Markdown code spans are intentionally literal.
		printf '\n> Warning: PR comment publication failed. The verification result above remains authoritative; check `GH_TOKEN` and `issues: write`.\n' >>"$GITHUB_STEP_SUMMARY"
	fi
	return 0
}

load_managed_issue_wrapper() {
	if declare -F gh_create_issue >/dev/null 2>&1; then
		return 0
	fi

	# Load lazily so report truncation and fail-soft comment publication do not
	# depend on the broader managed-write runtime.
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
	if declare -F gh_create_issue >/dev/null 2>&1; then
		return 0
	fi

	printf 'ERROR: managed issue creation wrapper is unavailable.\n' >&2
	return 1
}

create_follow_up() {
	local repo="$1"
	local title="$2"
	local body_file="$3"

	if [[ ! -f "$body_file" ]]; then
		printf 'ERROR: follow-up issue body file not found: %s\n' "$body_file" >&2
		return 2
	fi
	if ! load_managed_issue_wrapper; then
		return 1
	fi

	# The post-merge failure is actionable automation-owned work. Supply the
	# complete dispatch metadata at creation time; gh_create_issue adds the
	# normalized aidevops signature and enforces managed write safeguards.
	if AIDEVOPS_SESSION_ORIGIN=worker gh_create_issue --repo "$repo" \
		--title "$title" \
		--body-file "$body_file" \
		--label "quality-debt" \
		--label "type:bug" \
		--label "auto-dispatch" \
		--label "tier:standard" \
		--label "worker-ready" \
		--label "origin:worker" \
		--label "status:available"; then
		return 0
	fi
	return 1
}

main() {
	local command="${1:-help}"
	local repo="${2:-}"
	local pr_number="${3:-}"
	local body_file="${4:-}"

	case "$command" in
	truncate-output)
		truncate_output "$repo" "$pr_number"
		return $?
		;;
	publish-comment)
		if [[ -z "$repo" || -z "$pr_number" || -z "$body_file" ]]; then
			usage
			return 2
		fi
		publish_comment "$repo" "$pr_number" "$body_file"
		return $?
		;;
	create-follow-up)
		if [[ -z "$repo" || -z "$pr_number" || -z "$body_file" ]]; then
			usage
			return 2
		fi
		create_follow_up "$repo" "$pr_number" "$body_file"
		return $?
		;;
	help | --help | -h)
		usage
		return 0
		;;
	*)
		usage
		return 2
		;;
	esac
}

main "$@"
