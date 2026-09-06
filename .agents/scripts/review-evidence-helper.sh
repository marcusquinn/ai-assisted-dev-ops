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
REVIEW_BINARY_PATHS_FILE=""
REVIEW_BINARY_METADATA_FILE=""

_review_cleanup() {
	[[ -z "$REVIEW_BODY_FILE" ]] || rm -f "$REVIEW_BODY_FILE"
	[[ -z "$REVIEW_PATHS_FILE" ]] || rm -f "$REVIEW_PATHS_FILE"
	[[ -z "$REVIEW_AUX_FILE" ]] || rm -f "$REVIEW_AUX_FILE"
	[[ -z "$REVIEW_BINARY_PATHS_FILE" ]] || rm -f "$REVIEW_BINARY_PATHS_FILE"
	[[ -z "$REVIEW_BINARY_METADATA_FILE" ]] || rm -f "$REVIEW_BINARY_METADATA_FILE"
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

The emitted Markdown bundle uses schema aidevops.review-evidence/v1. Git targets
contain complete text patches and SHA-256-bound metadata for binary changes, plus
a prompt-injection scan status and bundle digest. It never fetches, changes refs,
or invokes a reviewer.
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
	while IFS= read -r -d '' path; do
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
		shasum -a 256 <"$file" | cut -d' ' -f1
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum <"$file" | cut -d' ' -f1
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

_review_git_diff() {
	local repo_root="$1" range="$2"
	shift 2
	if [[ "$range" == commit:* ]]; then
		# One first-parent policy binds sensitive-path inventory, binary metadata
		# and text patches to the same tree comparison, including merge commits.
		git -C "$repo_root" show --format= --root --diff-merges=first-parent "${range#commit:}" "$@"
	else
		git -C "$repo_root" diff "$range" "$@"
	fi
	return $?
}

_review_is_binary_diff() {
	local repo_root="$1"
	local range="$2"
	local path="$3"
	local numstat=""
	numstat=$(_review_git_diff "$repo_root" "$range" --numstat --no-renames -- ":(literal)$path") || return 1
	[[ "$numstat" == $'-\t-\t'* ]]
}

_review_is_binary_untracked() {
	local repo_root="$1"
	local path="$2"
	local numstat=""
	numstat=$(git -C "$repo_root" diff --no-index --numstat -- /dev/null "$repo_root/$path" 2>/dev/null || true)
	[[ "$numstat" == $'-\t-\t'* ]]
}

_review_diff_status() {
	local repo_root="$1"
	local range="$2"
	local path="$3"
	_review_git_diff "$repo_root" "$range" --name-status --no-renames -- ":(literal)$path" | cut -f1
	return 0
}

_review_binary_metadata() {
	local repo_root="$1"
	local path="$2"
	local status="$3"
	local current_file="$4"
	local preferred_ref="$5"
	local fallback_ref="$6"
	local artifact_file="$current_file"
	local ref=""
	local byte_size=""
	local mime_type=""
	local digest=""
	if [[ ! -f "$artifact_file" ]]; then
		for ref in "$preferred_ref" "$fallback_ref"; do
			[[ -n "$ref" ]] || continue
			if git -C "$repo_root" cat-file -e "${ref}:${path}" 2>/dev/null; then
				[[ -n "$REVIEW_AUX_FILE" ]] || REVIEW_AUX_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-binary.XXXXXX")
				git -C "$repo_root" show "${ref}:${path}" >"$REVIEW_AUX_FILE" || return 1
				artifact_file="$REVIEW_AUX_FILE"
				break
			fi
		done
	fi
	[[ -f "$artifact_file" ]] || {
		_review_die "cannot materialize binary artifact for review: ${path}"
		return 1
	}
	byte_size=$(wc -c <"$artifact_file" | tr -d '[:space:]') || return 1
	mime_type=$(file --brief --mime-type -- "$artifact_file") || return 1
	digest=$(_review_sha256 "$artifact_file") || return 1
	printf '%s\t%q\t%s\t%s\t%s\n' "$status" "$path" "$byte_size" "$mime_type" "$digest"
	return 0
}

_review_collect_diff_binaries() {
	local repo_root="$1"
	local range="$2"
	local preferred_ref="$3"
	local fallback_ref="$4"
	local use_worktree="${5:-false}" current_file=""
	local path=""
	local status=""
	while IFS= read -r -d '' path; do
		[[ -z "$path" ]] && continue
		if _review_is_binary_diff "$repo_root" "$range" "$path"; then
			status=$(_review_diff_status "$repo_root" "$range" "$path") || return 1
			printf '%s\0' "$path" >>"$REVIEW_BINARY_PATHS_FILE"
			current_file=""
			[[ "$use_worktree" != true ]] || current_file="$repo_root/$path"
			_review_binary_metadata "$repo_root" "$path" "$status" "$current_file" "$preferred_ref" "$fallback_ref" >>"$REVIEW_BINARY_METADATA_FILE" || return 1
		fi
	done < <(_review_git_diff "$repo_root" "$range" --name-only --no-renames -z)
	return 0
}

_review_collect_untracked_binaries() {
	local repo_root="$1"
	local path=""
	while IFS= read -r -d '' path; do
		[[ -z "$path" ]] && continue
		if _review_is_binary_untracked "$repo_root" "$path"; then
			printf '%s\0' "$path" >>"$REVIEW_BINARY_PATHS_FILE"
			_review_binary_metadata "$repo_root" "$path" 'A' "$repo_root/$path" '' '' >>"$REVIEW_BINARY_METADATA_FILE" || return 1
		fi
	done < <(git -C "$repo_root" ls-files --others --exclude-standard -z)
	return 0
}

_review_binary_path_recorded() {
	local wanted="$1" path=""
	while IFS= read -r -d '' path; do
		[[ "$path" != "$wanted" ]] || return 0
	done <"$REVIEW_BINARY_PATHS_FILE"
	return 1
}

_review_write_text_diff() {
	local repo_root="$1"
	local range="$2"
	local -a diff_args=(--no-ext-diff -- .)
	local path=""
	while IFS= read -r -d '' path; do
		[[ -z "$path" ]] && continue
		diff_args+=(":(top,literal,exclude)$path")
	done <"$REVIEW_BINARY_PATHS_FILE"
	_review_git_diff "$repo_root" "$range" "${diff_args[@]}"
	return 0
}

_review_write_binary_metadata() {
	[[ -s "$REVIEW_BINARY_METADATA_FILE" ]] || return 0
	printf '\n## Binary artifacts\n\nThe following binary changes are represented by status, repository-relative path, byte size, MIME type, and SHA-256.\n\n```text\n'
	printf 'status\tpath\tbytes\tmime_type\tsha256\n'
	cat "$REVIEW_BINARY_METADATA_FILE"
	printf '```\n'
	return 0
}

_review_write_local() {
	local body_file="$1"
	local paths_file="$2"
	local repo_root=""
	repo_root=$(_review_repo_root) || return 1
	_review_require file || return 1
	git -C "$repo_root" diff --name-only -z HEAD >"$paths_file"
	git -C "$repo_root" ls-files --others --exclude-standard -z >>"$paths_file"
	_review_check_paths "$paths_file" || return 1
	_review_collect_diff_binaries "$repo_root" 'HEAD' 'HEAD' 'HEAD' true || return 1
	_review_collect_untracked_binaries "$repo_root" || return 1
	{
		printf 'target: local\n'
		printf 'head: %s\n' "$(git -C "$repo_root" rev-parse HEAD)"
		printf '\n## Changed files\n\n```text\n'
		git -C "$repo_root" status --short
		printf '%s\n\n## Patch\n\n%s\n' '```' '```diff'
		_review_write_text_diff "$repo_root" 'HEAD'
		local untracked_file=""
		while IFS= read -r -d '' untracked_file; do
			[[ -z "$untracked_file" ]] && continue
			if ! _review_binary_path_recorded "$untracked_file"; then
				git -C "$repo_root" diff --no-index --no-ext-diff -- /dev/null "$repo_root/$untracked_file" || true
			fi
		done < <(git -C "$repo_root" ls-files --others --exclude-standard -z)
		printf '```\n'
		_review_write_binary_metadata
	} >"$body_file"
	return 0
}

_review_write_branch() {
	local body_file="$1"
	local paths_file="$2"
	local base="$3"
	local repo_root=""
	repo_root=$(_review_repo_root) || return 1
	_review_require file || return 1
	[[ -n "$base" ]] || base=$(_review_default_base) || return 1
	_review_validate_ref "$base" || return 1
	local merge_base=""
	merge_base=$(git -C "$repo_root" merge-base "$base" HEAD) || return 1
	git -C "$repo_root" diff --name-only -z "${base}...HEAD" >"$paths_file"
	_review_check_paths "$paths_file" || return 1
	_review_collect_diff_binaries "$repo_root" "${base}...HEAD" 'HEAD' "$merge_base" || return 1
	{
		printf 'target: branch\n'
		printf 'base: %s\n' "$base"
		printf 'head: %s\n' "$(git -C "$repo_root" rev-parse HEAD)"
		printf '\n## Changed files\n\n```text\n'
		git -C "$repo_root" diff --name-status "${base}...HEAD"
		printf '%s\n\n## Patch\n\n%s\n' '```' '```diff'
		_review_write_text_diff "$repo_root" "${base}...HEAD"
		printf '```\n'
		_review_write_binary_metadata
	} >"$body_file"
	return 0
}

_review_write_commit() {
	local body_file="$1"
	local paths_file="$2"
	local commit_ref="$3"
	local repo_root=""
	repo_root=$(_review_repo_root) || return 1
	_review_require file || return 1
	[[ -n "$commit_ref" ]] || {
		_review_die "commit target requires --commit REF"
		return 1
	}
	_review_validate_ref "$commit_ref" || return 1
	_review_git_diff "$repo_root" "commit:${commit_ref}" --name-only --no-renames -z >"$paths_file" || return 1
	_review_check_paths "$paths_file" || return 1
	_review_collect_diff_binaries "$repo_root" "commit:${commit_ref}" "$commit_ref" "${commit_ref}^" || return 1
	{
		printf 'target: commit\n'
		printf 'commit: %s\n' "$(git -C "$repo_root" rev-parse "$commit_ref")"
		printf '\n## Commit metadata and patch\n\n```text\n'
		git -C "$repo_root" show --format=fuller --no-patch "$commit_ref"
		printf '%s\n\n%s\n' '```' '```diff'
		_review_write_text_diff "$repo_root" "commit:${commit_ref}"
		printf '```\n'
		_review_write_binary_metadata
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
	jq -j '.files[]?.path // empty | ., "\u0000"' "$REVIEW_AUX_FILE" >"$paths_file"
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
	REVIEW_BINARY_PATHS_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-binary-paths.XXXXXX")
	REVIEW_BINARY_METADATA_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-binary-metadata.XXXXXX")
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
