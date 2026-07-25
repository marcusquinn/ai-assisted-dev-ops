#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# review-evidence-helper.sh — Build immutable evidence bundles for review policies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_ROOT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
REVIEW_BODY_FILE=""
REVIEW_PATHS_FILE=""
REVIEW_AUX_FILE=""

_review_cleanup() {
	[[ -z "$REVIEW_BODY_FILE" ]] || rm -f "$REVIEW_BODY_FILE"
	[[ -z "$REVIEW_PATHS_FILE" ]] || rm -f "$REVIEW_PATHS_FILE"
	[[ -z "$REVIEW_AUX_FILE" ]] || rm -f "$REVIEW_AUX_FILE"
	return 0
}

_review_usage() {
	cat <<'EOF'
Usage:
  review-evidence-helper.sh bundle local [--output FILE]
  review-evidence-helper.sh bundle branch [--base REF] [--output FILE]
  review-evidence-helper.sh bundle commit --commit REF [--output FILE]
  review-evidence-helper.sh bundle issue NUMBER [--repo OWNER/REPO] [--output FILE]
  review-evidence-helper.sh bundle pr NUMBER [--repo OWNER/REPO] [--output FILE]

The emitted Markdown bundle uses schema aidevops.review-evidence/v1. It contains
the selected metadata and complete patch, a prompt-injection scan status, and a
SHA-256 digest. It never fetches, changes refs, or invokes a reviewer.
EOF
	return 0
}

_review_die() {
	local message="$1"
	printf 'review-evidence: %s\n' "$message" >&2
	return 1
}

_review_require() {
	local command_name="$1"
	command -v "$command_name" >/dev/null 2>&1 || {
		_review_die "required command not found: ${command_name}"
		return 1
	}
	return 0
}

_review_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || {
		_review_die "target requires a Git repository"
		return 1
	}
	return 0
}

_review_validate_ref() {
	local ref="$1"
	git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null || {
		_review_die "Git ref does not resolve locally: ${ref}"
		return 1
	}
	return 0
}

_review_default_base() {
	local remote_head=""
	remote_head=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
	if [[ -n "$remote_head" ]]; then
		printf '%s\n' "$remote_head"
		return 0
	fi
	if git show-ref --verify --quiet refs/remotes/origin/main; then
		printf '%s\n' 'origin/main'
		return 0
	fi
	if git show-ref --verify --quiet refs/remotes/origin/master; then
		printf '%s\n' 'origin/master'
		return 0
	fi
	_review_die "cannot resolve a remote default branch; pass --base REF"
	return 1
}

_review_validate_number() {
	local number="$1"
	[[ "$number" =~ ^[1-9][0-9]*$ ]] || {
		_review_die "issue/PR number must be a positive integer"
		return 1
	}
	return 0
}

_review_sensitive_path() {
	local path="$1"
	case "/${path}" in
	*/.env | */.env.* | */credentials.json | */auth.json | *.pem | *.p12 | *.pfx | *.key | *.keystore)
		return 0
		;;
	esac
	return 1
}

_review_check_paths() {
	local paths_file="$1"
	local path=""
	while IFS= read -r path; do
		[[ -z "$path" ]] && continue
		if _review_sensitive_path "$path"; then
			_review_die "refusing security-sensitive path in review bundle: ${path}"
			return 1
		fi
	done <"$paths_file"
	return 0
}

_review_sha256() {
	local file="$1"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | cut -d' ' -f1
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | cut -d' ' -f1
		return 0
	fi
	_review_die "neither shasum nor sha256sum is available"
	return 1
}

_review_scan_status() {
	local file="$1"
	local scanner="${SCRIPT_DIR}/prompt-guard-helper.sh"
	local scan_output=""
	if [[ ! -x "$scanner" ]]; then
		printf '%s\n' 'unavailable'
		return 0
	fi
	scan_output=$("$scanner" scan-file "$file" 2>&1 || true)
	case "$scan_output" in
	*CLEAN*) printf '%s\n' 'clean' ;;
	*) printf '%s\n' 'flagged-untrusted-data' ;;
	esac
	return 0
}

_review_write_local() {
	local body_file="$1"
	local paths_file="$2"
	local repo_root=""
	repo_root=$(_review_repo_root) || return 1
	git -C "$repo_root" diff --name-only HEAD >"$paths_file"
	git -C "$repo_root" ls-files --others --exclude-standard >>"$paths_file"
	_review_check_paths "$paths_file" || return 1
	{
		printf 'target: local\n'
		printf 'head: %s\n' "$(git -C "$repo_root" rev-parse HEAD)"
		printf '\n## Changed files\n\n```text\n'
		git -C "$repo_root" status --short
		printf '%s\n\n## Patch\n\n%s\n' '```' '```diff'
		git -C "$repo_root" diff --binary --no-ext-diff HEAD
		local untracked_file=""
		while IFS= read -r -d '' untracked_file; do
			git -C "$repo_root" diff --no-index --binary -- /dev/null "$untracked_file" || true
		done < <(git -C "$repo_root" ls-files --others --exclude-standard -z)
		printf '```\n'
	} >"$body_file"
	return 0
}

_review_write_branch() {
	local body_file="$1"
	local paths_file="$2"
	local base="$3"
	local repo_root=""
	repo_root=$(_review_repo_root) || return 1
	[[ -n "$base" ]] || base=$(_review_default_base) || return 1
	_review_validate_ref "$base" || return 1
	git -C "$repo_root" diff --name-only "${base}...HEAD" >"$paths_file"
	_review_check_paths "$paths_file" || return 1
	{
		printf 'target: branch\n'
		printf 'base: %s\n' "$base"
		printf 'head: %s\n' "$(git -C "$repo_root" rev-parse HEAD)"
		printf '\n## Changed files\n\n```text\n'
		git -C "$repo_root" diff --name-status "${base}...HEAD"
		printf '%s\n\n## Patch\n\n%s\n' '```' '```diff'
		git -C "$repo_root" diff --binary --no-ext-diff "${base}...HEAD"
		printf '```\n'
	} >"$body_file"
	return 0
}

_review_write_commit() {
	local body_file="$1"
	local paths_file="$2"
	local commit_ref="$3"
	local repo_root=""
	repo_root=$(_review_repo_root) || return 1
	[[ -n "$commit_ref" ]] || {
		_review_die "commit target requires --commit REF"
		return 1
	}
	_review_validate_ref "$commit_ref" || return 1
	git -C "$repo_root" diff-tree --root --no-commit-id --name-only -r "$commit_ref" >"$paths_file"
	_review_check_paths "$paths_file" || return 1
	{
		printf 'target: commit\n'
		printf 'commit: %s\n' "$(git -C "$repo_root" rev-parse "$commit_ref")"
		printf '\n## Commit metadata and patch\n\n```diff\n'
		git -C "$repo_root" show --format=fuller --binary --no-ext-diff "$commit_ref"
		printf '```\n'
	} >"$body_file"
	return 0
}

_review_write_issue() {
	local body_file="$1"
	local number="$2"
	local repo_slug="$3"
	_review_require gh || return 1
	_review_validate_number "$number" || return 1
	local -a repo_args=()
	[[ -n "$repo_slug" ]] && repo_args=(--repo "$repo_slug")
	{
		printf 'target: issue\n'
		printf 'number: %s\n' "$number"
		printf '\n## Issue evidence\n\n```json\n'
		gh issue view "$number" "${repo_args[@]}" \
			--json number,title,body,author,createdAt,state,labels,comments
		printf '```\n'
	} >"$body_file"
	return 0
}

_review_write_pr() {
	local body_file="$1"
	local paths_file="$2"
	local number="$3"
	local repo_slug="$4"
	_review_require gh || return 1
	_review_require jq || return 1
	_review_validate_number "$number" || return 1
	local -a repo_args=()
	[[ -n "$repo_slug" ]] && repo_args=(--repo "$repo_slug")
	REVIEW_AUX_FILE=$(mktemp "${TEMP_ROOT}/review-pr-metadata.XXXXXX")
	gh pr view "$number" "${repo_args[@]}" \
		--json number,title,body,author,createdAt,state,baseRefName,headRefName,files,comments \
		>"$REVIEW_AUX_FILE"
	jq -r '.files[]?.path // empty' "$REVIEW_AUX_FILE" >"$paths_file"
	_review_check_paths "$paths_file" || {
		rm -f "$REVIEW_AUX_FILE"
		REVIEW_AUX_FILE=""
		return 1
	}
	{
		printf 'target: pr\n'
		printf 'number: %s\n' "$number"
		printf '\n## PR evidence\n\n```json\n'
		cat "$REVIEW_AUX_FILE"
		printf '%s\n\n## Patch\n\n%s\n' '```' '```diff'
		if ! gh pr diff "$number" "${repo_args[@]}" --patch; then
			rm -f "$REVIEW_AUX_FILE"
			REVIEW_AUX_FILE=""
			return 1
		fi
		printf '```\n'
	} >"$body_file"
	rm -f "$REVIEW_AUX_FILE"
	REVIEW_AUX_FILE=""
	return 0
}

_review_emit_bundle() {
	local body_file="$1"
	local output_file="$2"
	local digest=""
	local scan_status=""
	digest=$(_review_sha256 "$body_file") || return 1
	scan_status=$(_review_scan_status "$body_file") || return 1
	if [[ -n "$output_file" ]]; then
		{
			printf '%s\n' '---'
			printf '%s\n' 'schema: aidevops.review-evidence/v1'
			printf 'bundle_sha256: %s\n' "$digest"
			printf 'prompt_injection_scan: %s\n' "$scan_status"
			printf '%s\n\n' 'repository_identity: omitted'
			cat "$body_file"
		} >"$output_file"
		printf '%s\n' "$output_file"
		return 0
	fi
	printf '%s\n' '---'
	printf '%s\n' 'schema: aidevops.review-evidence/v1'
	printf 'bundle_sha256: %s\n' "$digest"
	printf 'prompt_injection_scan: %s\n' "$scan_status"
	printf '%s\n\n' 'repository_identity: omitted'
	cat "$body_file"
	return 0
}

main() {
	local command_name="${1:-help}"
	[[ "$command_name" == "bundle" ]] && shift
	if [[ "$command_name" == "help" || "$command_name" == "--help" || "$command_name" == "-h" ]]; then
		_review_usage
		return 0
	fi
	local target="${1:-}"
	[[ -n "$target" ]] || {
		_review_usage >&2
		return 1
	}
	shift
	local target_arg=""
	case "$target" in issue | pr)
		target_arg="${1:-}"
		[[ -n "$target_arg" ]] && shift
		;;
	esac
	local base_ref=""
	local commit_ref=""
	local repo_slug=""
	local output_file=""
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--base)
			[[ $# -ge 2 ]] || return 1
			base_ref="$2"
			shift 2
			;;
		--commit)
			[[ $# -ge 2 ]] || return 1
			commit_ref="$2"
			shift 2
			;;
		--repo)
			[[ $# -ge 2 ]] || return 1
			repo_slug="$2"
			shift 2
			;;
		--output)
			[[ $# -ge 2 ]] || return 1
			output_file="$2"
			shift 2
			;;
		*)
			_review_die "unknown option: ${option}"
			return 1
			;;
		esac
	done
	mkdir -p "$TEMP_ROOT"
	REVIEW_BODY_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-body.XXXXXX")
	REVIEW_PATHS_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-paths.XXXXXX")
	trap _review_cleanup EXIT
	case "$target" in
	local) _review_write_local "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" ;;
	branch) _review_write_branch "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" "$base_ref" ;;
	commit) _review_write_commit "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" "$commit_ref" ;;
	issue) _review_write_issue "$REVIEW_BODY_FILE" "$target_arg" "$repo_slug" ;;
	pr) _review_write_pr "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" "$target_arg" "$repo_slug" ;;
	*)
		_review_die "unknown target: ${target}"
		return 1
		;;
	esac
	_review_emit_bundle "$REVIEW_BODY_FILE" "$output_file"
	return $?
}

main "$@"
