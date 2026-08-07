#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Checkout-free publication of narrowly allowlisted repository state.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PLANNING_PUBLISHER_LOADED:-}" ]] && return 0
_PLANNING_PUBLISHER_LOADED=1

PLANNING_PUBLISH_MAX_RETRIES="${PLANNING_PUBLISH_MAX_RETRIES:-3}"
PLANNING_PUBLISH_RESULT=""
PLANNING_PUBLICATION_ID=""
PLANNING_PUBLICATION_HANDOFF_ID=""
PLANNING_PUBLISHED_COMMIT=""
PLANNING_PUBLICATION_SOURCE_HEAD=""
PLANNING_PUBLICATION_RECEIPT=""
PLANNING_SNAPSHOT_FILE_OPERATION="file"
PLANNING_BRANCH_REF_PREFIX="refs/heads/"
_PLANNING_PUBLISH_TEMP_DIR=""
_PLANNING_PUBLISH_SNAPSHOT_FILE=""
_PLANNING_PUBLISH_INDEX_FILE=""
_PLANNING_PUBLISH_CANDIDATE_SHA=""
_PLANNING_PUBLISH_HANDOFF_ID=""

_planning_git() {
	local git_bin="${AIDEVOPS_PLANNING_GIT_BIN:-git}"
	if ! command -v "$git_bin" >/dev/null 2>&1; then
		_planning_publish_log error "Planning Git binary is not available or executable: $git_bin"
		return 1
	fi
	command "$git_bin" "$@"
	return $?
}

_planning_publish_log() {
	local level="$1"
	local message="$2"
	if command -v "log_${level}" >/dev/null 2>&1; then
		"log_${level}" "$message"
	else
		printf '[planning-publisher][%s] %s\n' "$level" "$message" >&2
	fi
	return 0
}

_planning_publish_log_retryable_conflict() {
	local publication_id="$1"
	_planning_publish_log warning \
		"AIDEVOPS_PLANNING_PUBLISH_STATUS=retryable_conflict publication_id=${publication_id}"
	return 0
}

_planning_publish_path_allowed_for_scope() {
	local scope="$1"
	local path="$2"
	case "${scope}:${path}" in
	planning:TODO.md | planning:todo/*)
		[[ "$path" != *'..'* && "$path" != *'//'* && "$path" != */ && \
			"$path" != *$'\t'* && "$path" != *$'\n'* && "$path" != *$'\r'* ]]
		return $?
		;;
	simplification-state:.agents/configs/simplification-state.json) return 0 ;;
	*) return 1 ;;
	esac
}

_planning_publish_path_allowed() {
	local path="$1"
	local scope="${AIDEVOPS_PLANNING_PUBLISH_SCOPE:-planning}"
	_planning_publish_path_allowed_for_scope "$scope" "$path"
	return $?
}

_planning_publish_changed_paths() {
	local repo_path="$1"
	{
		_planning_git -C "$repo_path" diff --name-only HEAD -- TODO.md todo/ 2>/dev/null || true
		_planning_git -C "$repo_path" diff --name-only --cached -- TODO.md todo/ 2>/dev/null || true
		_planning_git -C "$repo_path" ls-files --others --exclude-standard -- TODO.md todo/ 2>/dev/null || true
	} | LC_ALL=C sort -u | grep -v '^$' || true
	return 0
}

_planning_publish_source_file() {
	local repo_path="$1"
	local path="$2"
	local external_source="$3"
	local scope="${AIDEVOPS_PLANNING_PUBLISH_SCOPE:-planning}"
	if [[ -z "$external_source" ]]; then
		printf '%s\n' "${repo_path}/${path}"
		return 0
	fi
	if [[ "$scope" != "simplification-state" || "$path" != ".agents/configs/simplification-state.json" ]]; then
		_planning_publish_log error "External publication sources are not allowed for scope/path: ${scope}:${path}"
		return 1
	fi
	if [[ ! -f "$external_source" || -L "$external_source" ]]; then
		_planning_publish_log error "External publication source must be a regular non-symlink file"
		return 1
	fi
	if ! jq -e 'type == "object" and (.files | type == "object")' "$external_source" >/dev/null 2>&1; then
		_planning_publish_log error "External simplification-state source is malformed"
		return 1
	fi
	printf '%s\n' "$external_source"
	return 0
}

_planning_publish_snapshot() {
	local repo_path="$1"
	local paths="$2"
	local snapshot_file="$3"
	local external_source="${4:-}"
	local path=""
	local source_file=""
	: >"$snapshot_file" || return 1
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		_planning_publish_path_allowed "$path" || {
			_planning_publish_log error "Unauthorized publication path: $path"
			return 1
		}
		source_file=$(_planning_publish_source_file "$repo_path" "$path" "$external_source") || return 1
		if [[ -L "$source_file" ]] || [[ -d "$source_file" ]]; then
			_planning_publish_log error "Publication paths must be regular files: $path"
			return 1
		fi
		if [[ -f "$source_file" ]]; then
			local blob_sha=""
			blob_sha=$(_planning_git -C "$repo_path" hash-object -w -- "$source_file") || return 1
			printf '%s\t%s\t%s\n' "$PLANNING_SNAPSHOT_FILE_OPERATION" "$blob_sha" "$path" >>"$snapshot_file" || return 1
		else
			printf 'delete\t-\t%s\n' "$path" >>"$snapshot_file" || return 1
		fi
	done <<<"$paths"
	return 0
}

# Rebuild receipt evidence without writing blobs into the repository object
# database. Publication needs `hash-object -w`; merge-time verification must not.
_planning_publish_snapshot_readonly() {
	local repo_path="$1"
	local paths="$2"
	local snapshot_file="$3"
	local scope="${4:-planning}"
	local path=""
	local blob_sha=""
	: >"$snapshot_file" || return 1
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		_planning_publish_path_allowed_for_scope "$scope" "$path" || return 1
		if [[ -L "${repo_path}/${path}" ]] || [[ -d "${repo_path}/${path}" ]]; then
			return 1
		fi
		if [[ -f "${repo_path}/${path}" ]]; then
			blob_sha=$(_planning_git -C "$repo_path" hash-object -- "${repo_path}/${path}") || return 1
			printf '%s\t%s\t%s\n' "$PLANNING_SNAPSHOT_FILE_OPERATION" "$blob_sha" "$path" >>"$snapshot_file" || return 1
		else
			printf 'delete\t-\t%s\n' "$path" >>"$snapshot_file" || return 1
		fi
	done <<<"$paths"
	return 0
}

_planning_publish_repository_id() {
	local repo_path="$1"
	local common_dir=""
	local repository_id=""
	common_dir=$(_planning_git -C "$repo_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	repository_id=$(printf '%s\n' "$common_dir" | _planning_git -C "$repo_path" hash-object --stdin) || return 1
	printf '%s\n' "$repository_id"
	return 0
}

# Bind every mutable receipt field needed by the merge exception to immutable
# commit evidence. The snapshot digest already commits to operation/path/blob
# rows; this envelope additionally commits to where and from what state it was
# published so editing a local receipt cannot substitute another ancestor HEAD.
_planning_publish_handoff_id() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local source_head="$4"
	local published_parent="$5"
	local publication_id="$6"
	local scope="${7:-${AIDEVOPS_PLANNING_PUBLISH_SCOPE:-planning}}"
	local repository_id=""
	repository_id=$(_planning_publish_repository_id "$repo_path") || return 1
	printf 'format=aidevops-planning-handoff-v1\nrepository_id=%s\nscope=%s\nremote=%s\nbranch=%s\nsource_head=%s\npublished_parent=%s\npublication_id=%s\n' \
		"$repository_id" "$scope" "$remote_name" "$branch_name" "$source_head" \
		"$published_parent" "$publication_id" |
		_planning_git -C "$repo_path" hash-object --stdin
	return $?
}

planning_publication_receipt_path() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local receipt_dir="${AIDEVOPS_PLANNING_RECEIPT_DIR:-}"
	local repository_id=""
	local receipt_id=""
	if [[ -z "$receipt_dir" ]]; then
		[[ -n "${HOME:-}" ]] || return 1
		receipt_dir="${HOME}/.aidevops/state/planning-publications"
	fi
	repository_id=$(_planning_publish_repository_id "$repo_path") || return 1
	receipt_id=$(printf '%s\n%s\n%s\n' "$repository_id" "$remote_name" "$branch_name" |
		_planning_git -C "$repo_path" hash-object --stdin) || return 1
	printf '%s/%s-%s.receipt\n' "$receipt_dir" "$repository_id" "$receipt_id"
	return 0
}

_planning_publish_commit_has_publication_id() {
	local repo_path="$1"
	local commit_sha="$2"
	local publication_id="$3"
	local body=""
	local line=""
	local matches=0
	body=$(_planning_git -C "$repo_path" show -s --format=%B "$commit_sha" 2>/dev/null) || return 1
	while IFS= read -r line; do
		[[ "$line" == "Planning-Publication-ID: ${publication_id}" ]] && matches=$((matches + 1))
	done <<<"$body"
	[[ "$matches" -eq 1 ]]
	return $?
}

_planning_publish_commit_has_handoff_id() {
	local repo_path="$1"
	local commit_sha="$2"
	local handoff_id="$3"
	local body=""
	local line=""
	local matches=0
	body=$(_planning_git -C "$repo_path" show -s --format=%B "$commit_sha" 2>/dev/null) || return 1
	while IFS= read -r line; do
		[[ "$line" == "Planning-Publication-Handoff-ID: ${handoff_id}" ]] && matches=$((matches + 1))
	done <<<"$body"
	[[ "$matches" -eq 1 ]]
	return $?
}

_planning_publish_write_receipt() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local source_head="$4"
	local published_commit="$5"
	local published_parent="$6"
	local publication_id="$7"
	local handoff_id="$8"
	local snapshot_file="$9"
	local scope="${AIDEVOPS_PLANNING_PUBLISH_SCOPE:-planning}"
	local repository_id=""
	local expected_handoff_id=""
	local receipt_path=""
	local receipt_tmp=""
	local snapshot_line=""

	PLANNING_PUBLICATION_RECEIPT=""
	[[ "${AIDEVOPS_PLANNING_WRITE_RECEIPT:-false}" == "true" ]] || return 0
	repository_id=$(_planning_publish_repository_id "$repo_path") || return 1
	expected_handoff_id=$(_planning_publish_handoff_id "$repo_path" "$remote_name" "$branch_name" \
		"$source_head" "$published_parent" "$publication_id" "$scope") || return 1
	[[ "$handoff_id" == "$expected_handoff_id" ]] || return 1
	receipt_path=$(planning_publication_receipt_path "$repo_path" "$remote_name" "$branch_name") || return 1
	mkdir -p "${receipt_path%/*}" || return 1
	receipt_tmp="${receipt_path}.tmp.$$"
	(
		umask 077
		{
			printf 'format=aidevops-planning-publication-v2\n'
			printf 'repository_id=%s\n' "$repository_id"
			printf 'scope=%s\n' "$scope"
			printf 'remote=%s\n' "$remote_name"
			printf 'branch=%s\n' "$branch_name"
			printf 'source_head=%s\n' "$source_head"
			printf 'published_commit=%s\n' "$published_commit"
			printf 'published_parent=%s\n' "$published_parent"
			printf 'publication_id=%s\n' "$publication_id"
			printf 'handoff_id=%s\n' "$handoff_id"
			printf '%s\n' 'snapshot_begin'
			while IFS= read -r snapshot_line || [[ -n "$snapshot_line" ]]; do
				printf '%s\n' "$snapshot_line"
			done <"$snapshot_file"
			printf '%s\n' 'snapshot_end'
		} >"$receipt_tmp" || exit 1
		mv "$receipt_tmp" "$receipt_path" || exit 1
	) || {
		rm -f "$receipt_tmp"
		return 1
	}
	PLANNING_PUBLICATION_RECEIPT="$receipt_path"
	return 0
}

_planning_publish_receipt_value() {
	local receipt_path="$1"
	local key="$2"
	local line=""
	local value=""
	local matches=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == "snapshot_begin" ]] && break
		if [[ "$line" == "${key}="* ]]; then
			value="${line#*=}"
			matches=$((matches + 1))
		fi
	done <"$receipt_path"
	[[ "$matches" -eq 1 ]] || return 1
	printf '%s\n' "$value"
	return 0
}

_planning_publish_extract_receipt_snapshot() {
	local receipt_path="$1"
	local snapshot_file="$2"
	local line=""
	local in_snapshot=0
	local ended=0
	: >"$snapshot_file" || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "snapshot_begin" ]]; then
			[[ "$in_snapshot" -eq 0 && "$ended" -eq 0 ]] || return 1
			in_snapshot=1
			continue
		fi
		if [[ "$line" == "snapshot_end" ]]; then
			[[ "$in_snapshot" -eq 1 && "$ended" -eq 0 ]] || return 1
			in_snapshot=0
			ended=1
			continue
		fi
		[[ "$ended" -eq 0 ]] || return 1
		[[ "$in_snapshot" -eq 1 ]] && printf '%s\n' "$line" >>"$snapshot_file"
	done <"$receipt_path"
	[[ "$in_snapshot" -eq 0 && "$ended" -eq 1 && -s "$snapshot_file" ]]
	return $?
}

_planning_publish_verify_receipt_snapshot() {
	local repo_path="$1"
	local snapshot_file="$2"
	local publication_id="$3"
	local published_commit="$4"
	local published_parent="$5"
	local temp_dir="$6"
	local paths_file="${temp_dir}/paths"
	local current_snapshot="${temp_dir}/current-snapshot"
	local operation=""
	local blob_sha=""
	local path=""
	local current_blob=""
	local changed_path=""
	local changed_paths=""
	local current_changed_paths=""
	local paths=""
	local snapshot_digest=""
	: >"$paths_file" || return 1
	while IFS=$'\t' read -r operation blob_sha path; do
		[[ -n "$path" ]] || return 1
		_planning_publish_path_allowed_for_scope planning "$path" || return 1
		case "$operation" in
		"$PLANNING_SNAPSHOT_FILE_OPERATION") [[ "$blob_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] || return 1 ;;
		delete) [[ "$blob_sha" == "-" ]] || return 1 ;;
		*) return 1 ;;
		esac
		grep -Fqx -- "$path" "$paths_file" 2>/dev/null && return 1
		printf '%s\n' "$path" >>"$paths_file" || return 1
	done <"$snapshot_file"
	snapshot_digest=$(_planning_git -C "$repo_path" hash-object "$snapshot_file") || return 1
	[[ "$snapshot_digest" == "$publication_id" ]] || return 1
	paths=$(<"$paths_file")
	current_changed_paths=$(_planning_publish_changed_paths "$repo_path") || return 1
	[[ "$current_changed_paths" == "$paths" ]] || return 1
	_planning_publish_snapshot_readonly "$repo_path" "$paths" "$current_snapshot" planning || return 1
	cmp -s "$snapshot_file" "$current_snapshot" || return 1
	while IFS=$'\t' read -r operation blob_sha path; do
		if [[ "$operation" == "$PLANNING_SNAPSHOT_FILE_OPERATION" ]]; then
			current_blob=$(_planning_git -C "$repo_path" rev-parse "${published_commit}:${path}" 2>/dev/null) || return 1
			[[ "$current_blob" == "$blob_sha" ]] || return 1
		elif _planning_git -C "$repo_path" cat-file -e "${published_commit}:${path}" 2>/dev/null; then
			return 1
		fi
	done <"$snapshot_file"
	changed_paths=$(_planning_git -C "$repo_path" diff-tree --no-commit-id --name-only -r "$published_parent" "$published_commit") || return 1
	[[ -n "$changed_paths" ]] || return 1
	while IFS= read -r changed_path; do
		[[ -n "$changed_path" ]] || continue
		_planning_publish_path_allowed_for_scope planning "$changed_path" || return 1
		grep -Fqx -- "$changed_path" "$paths_file" || return 1
	done <<<"$changed_paths"
	return 0
}

# Verify a receipt against the current local snapshot, immutable commit evidence,
# the exact remote branch head, and the PR head already pinned by full-loop.
planning_verify_publication_receipt() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local expected_commit="$4"
	local receipt_path=""
	local temp_dir=""
	local snapshot_file=""
	local format="" repository_id="" expected_repository_id="" scope="" receipt_remote="" receipt_branch=""
	local source_head="" published_commit="" published_parent="" publication_id="" handoff_id=""
	local expected_handoff_id=""
	local current_branch="" current_head="" parent_line="" remote_line="" remote_sha="" remote_ref=""
	local branch_ref="${PLANNING_BRANCH_REF_PREFIX}${branch_name}"

	receipt_path=$(planning_publication_receipt_path "$repo_path" "$remote_name" "$branch_name") || return 1
	[[ -f "$receipt_path" && ! -L "$receipt_path" ]] || return 1
	format=$(_planning_publish_receipt_value "$receipt_path" format) || return 1
	repository_id=$(_planning_publish_receipt_value "$receipt_path" repository_id) || return 1
	scope=$(_planning_publish_receipt_value "$receipt_path" scope) || return 1
	receipt_remote=$(_planning_publish_receipt_value "$receipt_path" remote) || return 1
	receipt_branch=$(_planning_publish_receipt_value "$receipt_path" branch) || return 1
	source_head=$(_planning_publish_receipt_value "$receipt_path" source_head) || return 1
	published_commit=$(_planning_publish_receipt_value "$receipt_path" published_commit) || return 1
	published_parent=$(_planning_publish_receipt_value "$receipt_path" published_parent) || return 1
	publication_id=$(_planning_publish_receipt_value "$receipt_path" publication_id) || return 1
	handoff_id=$(_planning_publish_receipt_value "$receipt_path" handoff_id) || return 1
	expected_repository_id=$(_planning_publish_repository_id "$repo_path") || return 1
	[[ "$format" == "aidevops-planning-publication-v2" && "$repository_id" == "$expected_repository_id" && \
		"$scope" == "planning" && "$receipt_remote" == "$remote_name" && "$receipt_branch" == "$branch_name" ]] || return 1
	[[ "$source_head" =~ ^[0-9a-fA-F]{40,64}$ && "$published_commit" =~ ^[0-9a-fA-F]{40,64}$ && \
		"$published_parent" =~ ^[0-9a-fA-F]{40,64}$ && "$publication_id" =~ ^[0-9a-fA-F]{40,64}$ && \
		"$handoff_id" =~ ^[0-9a-fA-F]{40,64}$ ]] || return 1
	[[ "$published_commit" == "$expected_commit" ]] || return 1
	expected_handoff_id=$(_planning_publish_handoff_id "$repo_path" "$receipt_remote" "$receipt_branch" \
		"$source_head" "$published_parent" "$publication_id" "$scope") || return 1
	[[ "$handoff_id" == "$expected_handoff_id" ]] || return 1
	current_branch=$(_planning_git -C "$repo_path" branch --show-current 2>/dev/null) || return 1
	current_head=$(_planning_git -C "$repo_path" rev-parse --verify "HEAD^{commit}" 2>/dev/null) || return 1
	[[ "$current_branch" == "$branch_name" && "$current_head" == "$source_head" ]] || return 1
	_planning_git -C "$repo_path" merge-base --is-ancestor "$source_head" "$published_commit" 2>/dev/null || return 1
	parent_line=$(_planning_git -C "$repo_path" rev-list --parents -n 1 "$published_commit" 2>/dev/null) || return 1
	[[ "$parent_line" == "${published_commit} ${published_parent}" ]] || return 1
	_planning_publish_commit_has_publication_id "$repo_path" "$published_commit" "$publication_id" || return 1
	_planning_publish_commit_has_handoff_id "$repo_path" "$published_commit" "$handoff_id" || return 1
	remote_line=$(_planning_git -C "$repo_path" ls-remote --heads "$remote_name" "$branch_ref" 2>/dev/null) || return 1
	[[ "$remote_line" != *$'\n'* ]] || return 1
	IFS=$'\t' read -r remote_sha remote_ref <<<"$remote_line"
	[[ "$remote_sha" == "$published_commit" && "$remote_ref" == "$branch_ref" ]] || return 1
	temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/planning-receipt-verify.XXXXXX") || return 1
	snapshot_file="${temp_dir}/snapshot"
	if ! _planning_publish_extract_receipt_snapshot "$receipt_path" "$snapshot_file" || \
		! _planning_publish_verify_receipt_snapshot "$repo_path" "$snapshot_file" "$publication_id" \
			"$published_commit" "$published_parent" "$temp_dir"; then
		rm -rf "$temp_dir"
		return 1
	fi
	rm -rf "$temp_dir"
	PLANNING_PUBLICATION_RECEIPT="$receipt_path"
	PLANNING_PUBLICATION_HANDOFF_ID="$handoff_id"
	return 0
}

_planning_publish_build_index() {
	local repo_path="$1"
	local parent_sha="$2"
	local snapshot_file="$3"
	local index_file="$4"
	local operation="" blob_sha="" path=""
	rm -f "$index_file" || return 1
	GIT_INDEX_FILE="$index_file" _planning_git -C "$repo_path" read-tree "$parent_sha" || return 1
	while IFS=$'\t' read -r operation blob_sha path; do
		[[ -n "$path" ]] || continue
		if [[ "$operation" == "$PLANNING_SNAPSHOT_FILE_OPERATION" ]]; then
			GIT_INDEX_FILE="$index_file" _planning_git -C "$repo_path" update-index --add --cacheinfo "100644,${blob_sha},${path}" || return 1
		else
			GIT_INDEX_FILE="$index_file" _planning_git -C "$repo_path" update-index --force-remove -- "$path" || return 1
		fi
	done <"$snapshot_file"
	return 0
}

_planning_publish_verify_index() {
	local repo_path="$1"
	local parent_sha="$2"
	local snapshot_file="$3"
	local index_file="$4"
	local changed_path="" operation="" expected_sha="" path="" staged_sha=""
	while IFS= read -r changed_path; do
		[[ -n "$changed_path" ]] || continue
		_planning_publish_path_allowed "$changed_path" || return 1
	done < <(GIT_INDEX_FILE="$index_file" _planning_git -C "$repo_path" diff --cached --name-only "$parent_sha")
	while IFS=$'\t' read -r operation expected_sha path; do
		if [[ "$operation" == "$PLANNING_SNAPSHOT_FILE_OPERATION" ]]; then
			staged_sha=$(GIT_INDEX_FILE="$index_file" _planning_git -C "$repo_path" rev-parse ":${path}" 2>/dev/null) || return 1
			[[ "$staged_sha" == "$expected_sha" ]] || return 1
		elif GIT_INDEX_FILE="$index_file" _planning_git -C "$repo_path" rev-parse ":${path}" >/dev/null 2>&1; then
			return 1
		fi
	done <"$snapshot_file"
	return 0
}

_planning_publish_validate() {
	local repo_path="$1"
	local parent_sha="$2"
	local candidate_sha="$3"
	local index_file="$4"
	local validator="${AIDEVOPS_PLANNING_VALIDATOR:-}"
	if [[ -n "$validator" ]]; then
		GIT_INDEX_FILE="$index_file" "$validator" "$repo_path" "$parent_sha" "$candidate_sha"
		return $?
	fi
	local hook="${SCRIPT_DIR:-${repo_path}/.agents/scripts}/pre-commit-hook.sh"
	if [[ -x "$hook" ]]; then
		(cd "$repo_path" && GIT_INDEX_FILE="$index_file" HOOK_MODE=pre-commit "$hook" >/dev/null) || return 1
	fi
	local privacy_lib="${SCRIPT_DIR:-${repo_path}/.agents/scripts}/privacy-guard-helper.sh"
	if [[ -f "$privacy_lib" ]]; then
		# shellcheck disable=SC1090
		source "$privacy_lib"
		local privacy_hits="" slugs_file=""
		slugs_file=$(mktemp "${TMPDIR:-/tmp}/planning-private-slugs.XXXXXX") || return 1
		privacy_enumerate_private_slugs "$slugs_file" >/dev/null 2>&1 || true
		privacy_hits=$(cd "$repo_path" && {
			privacy_scan_secret_material_diff "$parent_sha" "$candidate_sha" 2>/dev/null || true
			privacy_scan_diff "$parent_sha" "$candidate_sha" "$slugs_file" 2>/dev/null || true
		})
		rm -f "$slugs_file"
		[[ -z "$privacy_hits" ]] || return 1
	fi
	return 0
}

_planning_publish_parent_conflicts() {
	local repo_path="$1"
	local old_parent="$2"
	local new_parent="$3"
	local snapshot_file="$4"
	local operation="" blob_sha="" path=""
	while IFS=$'\t' read -r operation blob_sha path; do
		if ! _planning_git -C "$repo_path" diff --quiet "$old_parent" "$new_parent" -- "$path"; then
			return 0
		fi
	done <"$snapshot_file"
	return 1
}

_planning_publish_remote_default_branch() {
	local repo_path="$1"
	local remote_name="$2"
	local remote_head=""
	local default_branch=""
	remote_head=$(_planning_git -C "$repo_path" ls-remote --symref "$remote_name" HEAD 2>/dev/null) || return 1
	default_branch=$(printf '%s\n' "$remote_head" | sed -n 's@^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$@\1@p')
	if [[ -z "$default_branch" || "$default_branch" == *$'\n'* ]]; then
		_planning_publish_log error "Cannot determine one remote default branch for first planning publication"
		return 1
	fi
	printf '%s\n' "$default_branch"
	return 0
}

_planning_publish_resolve_parent() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local target_check_rc=0
	local default_branch=""
	local parent_sha=""
	local target_sha=""
	local parent_branch="${AIDEVOPS_PLANNING_PARENT_BRANCH:-}"
	local branch_ref="${PLANNING_BRANCH_REF_PREFIX}${branch_name}"

	if [[ -n "$parent_branch" && "$parent_branch" != "$branch_name" ]]; then
		if _planning_git -C "$repo_path" fetch -q "$remote_name" "$branch_name" 2>/dev/null; then
			target_sha=$(_planning_git -C "$repo_path" rev-parse FETCH_HEAD) || return 1
		elif _planning_git -C "$repo_path" ls-remote --exit-code --heads "$remote_name" "$branch_ref" >/dev/null 2>&1; then
			_planning_git -C "$repo_path" fetch -q "$remote_name" "$branch_name" || return 1
			target_sha=$(_planning_git -C "$repo_path" rev-parse FETCH_HEAD) || return 1
		else
			target_check_rc=$?
			[[ "$target_check_rc" -eq 2 ]] || return 1
		fi
		_planning_git -C "$repo_path" fetch -q "$remote_name" "$parent_branch" || return 1
		parent_sha=$(_planning_git -C "$repo_path" rev-parse FETCH_HEAD) || return 1
		printf '%s|%s|%s\n' "$parent_sha" "$target_sha" "$target_sha"
		return 0
	fi

	if _planning_git -C "$repo_path" fetch -q "$remote_name" "$branch_name" 2>/dev/null; then
		parent_sha=$(_planning_git -C "$repo_path" rev-parse FETCH_HEAD) || return 1
		printf '%s|%s|%s\n' "$parent_sha" "$parent_sha" "$parent_sha"
		return 0
	fi

	if _planning_git -C "$repo_path" ls-remote --exit-code --heads "$remote_name" "$branch_ref" >/dev/null 2>&1; then
		# The branch appeared after the failed fetch. Refetch it and use the
		# normal update lease rather than misclassifying it as absent.
		_planning_git -C "$repo_path" fetch -q "$remote_name" "$branch_name" || return 1
		parent_sha=$(_planning_git -C "$repo_path" rev-parse FETCH_HEAD) || return 1
		printf '%s|%s|%s\n' "$parent_sha" "$parent_sha" "$parent_sha"
		return 0
	else
		target_check_rc=$?
	fi
	if [[ "$target_check_rc" -ne 2 ]]; then
		_planning_publish_log error "Unable to verify whether remote branch ${branch_name} exists"
		return 1
	fi

	default_branch=$(_planning_publish_remote_default_branch "$repo_path" "$remote_name") || return 1
	_planning_git -C "$repo_path" fetch -q "$remote_name" "$default_branch" || return 1
	parent_sha=$(_planning_git -C "$repo_path" rev-parse FETCH_HEAD) || return 1
	# An empty expected value is Git's creation-safe lease: the push succeeds
	# only while the target ref remains absent.
	printf '%s||\n' "$parent_sha"
	return 0
}

_planning_publish_push() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local expected_sha="$4"
	local candidate_sha="$5"
	local branch_ref="${PLANNING_BRANCH_REF_PREFIX}${branch_name}"
	if [[ -n "${AIDEVOPS_PLANNING_FENCE_REF:-}" && -n "${AIDEVOPS_PLANNING_FENCE_SHA:-}" ]]; then
		_planning_git -C "$repo_path" push -q --atomic \
			--force-with-lease="${branch_ref}:${expected_sha}" \
			--force-with-lease="${AIDEVOPS_PLANNING_FENCE_REF}:${AIDEVOPS_PLANNING_FENCE_SHA}" \
			"$remote_name" "${candidate_sha}:${branch_ref}" \
			"${AIDEVOPS_PLANNING_FENCE_SHA}:${AIDEVOPS_PLANNING_FENCE_REF}"
		return $?
	fi
	_planning_git -C "$repo_path" push -q --force-with-lease="${branch_ref}:${expected_sha}" "$remote_name" "${candidate_sha}:${branch_ref}"
	return $?
}

_planning_publish_reset_result() {
	PLANNING_PUBLISH_RESULT=""
	PLANNING_PUBLICATION_ID=""
	PLANNING_PUBLICATION_HANDOFF_ID=""
	PLANNING_PUBLISHED_COMMIT=""
	PLANNING_PUBLICATION_SOURCE_HEAD=""
	PLANNING_PUBLICATION_RECEIPT=""
	return 0
}

_planning_publish_record_noop_receipt() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local source_head="$4"
	local latest_sha="$5"
	local publication_id="$6"
	local snapshot_file="$7"
	local parent_line=""
	local parent_sha=""
	local handoff_id=""
	PLANNING_PUBLISH_RESULT="noop"
	PLANNING_PUBLISHED_COMMIT="$latest_sha"
	[[ "${AIDEVOPS_PLANNING_WRITE_RECEIPT:-false}" == "true" ]] || return 0
	_planning_publish_commit_has_publication_id "$repo_path" "$latest_sha" "$publication_id" || return 1
	parent_line=$(_planning_git -C "$repo_path" rev-list --parents -n 1 "$latest_sha" 2>/dev/null) || return 1
	parent_sha="${parent_line#* }"
	[[ "$parent_sha" != "$parent_line" && "$parent_sha" != *' '* ]] || return 1
	handoff_id=$(_planning_publish_handoff_id "$repo_path" "$remote_name" "$branch_name" \
		"$source_head" "$parent_sha" "$publication_id") || return 1
	_planning_publish_commit_has_handoff_id "$repo_path" "$latest_sha" "$handoff_id" || return 1
	PLANNING_PUBLICATION_HANDOFF_ID="$handoff_id"
	_planning_publish_write_receipt "$repo_path" "$remote_name" "$branch_name" "$source_head" \
		"$latest_sha" "$parent_sha" "$publication_id" "$handoff_id" "$snapshot_file" || return 1
	return 0
}

_planning_publish_record_pushed_receipt() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local source_head="$4"
	local candidate_sha="$5"
	local parent_sha="$6"
	local publication_id="$7"
	local handoff_id="$8"
	local snapshot_file="$9"
	PLANNING_PUBLISH_RESULT="published"
	PLANNING_PUBLISHED_COMMIT="$candidate_sha"
	PLANNING_PUBLICATION_HANDOFF_ID="$handoff_id"
	if ! _planning_publish_write_receipt "$repo_path" "$remote_name" "$branch_name" "$source_head" \
		"$candidate_sha" "$parent_sha" "$publication_id" "$handoff_id" "$snapshot_file"; then
		PLANNING_PUBLISH_RESULT="published_receipt_failed"
		return 1
	fi
	return 0
}

_planning_publish_prepare_snapshot() {
	local repo_path="$1"
	local paths="$2"
	local external_source="${3:-}"
	local publication_id=""
	_PLANNING_PUBLISH_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/planning-publisher.XXXXXX") || return 1
	_PLANNING_PUBLISH_SNAPSHOT_FILE="${_PLANNING_PUBLISH_TEMP_DIR}/snapshot"
	_PLANNING_PUBLISH_INDEX_FILE="${_PLANNING_PUBLISH_TEMP_DIR}/index"
	_planning_publish_snapshot "$repo_path" "$paths" "$_PLANNING_PUBLISH_SNAPSHOT_FILE" "$external_source" || {
		rm -rf "$_PLANNING_PUBLISH_TEMP_DIR"
		return 1
	}
	publication_id=$(_planning_git -C "$repo_path" hash-object "$_PLANNING_PUBLISH_SNAPSHOT_FILE") || {
		rm -rf "$_PLANNING_PUBLISH_TEMP_DIR"
		return 1
	}
	PLANNING_PUBLICATION_ID="$publication_id"
	return 0
}

_planning_publish_run_pre_push_guards() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local parent_sha="$4"
	local candidate_sha="$5"
	local attempt="$6"
	if [[ -n "${AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK:-}" ]]; then
		"$AIDEVOPS_PLANNING_BEFORE_PUSH_HOOK" "$repo_path" "$remote_name" "$branch_name" \
			"$parent_sha" "$candidate_sha" "$attempt" || return 1
	fi
	if [[ -n "${AIDEVOPS_PLANNING_PUSH_GUARD:-}" ]]; then
		"$AIDEVOPS_PLANNING_PUSH_GUARD" "$repo_path" "$remote_name" "$branch_name" \
			"$parent_sha" "$candidate_sha" "$attempt" || return 3
	fi
	return 0
}

_planning_publish_build_candidate() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local source_head="$4"
	local parent_sha="$5"
	local publication_id="$6"
	local commit_msg="$7"
	local tree_sha="$8"
	local index_file="$9"
	local handoff_id=""
	local candidate_sha=""
	_PLANNING_PUBLISH_CANDIDATE_SHA=""
	_PLANNING_PUBLISH_HANDOFF_ID=""
	handoff_id=$(_planning_publish_handoff_id "$repo_path" "$remote_name" "$branch_name" \
		"$source_head" "$parent_sha" "$publication_id") || return 1
	candidate_sha=$(printf '%s\n\nPlanning-Publication-ID: %s\nPlanning-Publication-Handoff-ID: %s\n' \
		"$commit_msg" "$publication_id" "$handoff_id" | _planning_git -C "$repo_path" commit-tree "$tree_sha" -p "$parent_sha") || return 1
	if ! _planning_publish_validate "$repo_path" "$parent_sha" "$candidate_sha" "$index_file"; then
		_planning_publish_log error "Planning publication validation failed; nothing pushed"
		return 1
	fi
	_PLANNING_PUBLISH_HANDOFF_ID="$handoff_id"
	_PLANNING_PUBLISH_CANDIDATE_SHA="$candidate_sha"
	return 0
}

_planning_publish_resolve_attempt() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local previous_target_sha="$4"
	local snapshot_file="$5"
	local publication_id="$6"
	local attempt="$7"
	local parent_resolution=""
	local resolution_tail=""
	local latest_sha=""
	local expected_sha=""
	local target_sha=""
	parent_resolution=$(_planning_publish_resolve_parent "$repo_path" "$remote_name" "$branch_name") || return 1
	latest_sha="${parent_resolution%%|*}"
	resolution_tail="${parent_resolution#*|}"
	expected_sha="${resolution_tail%%|*}"
	target_sha="${resolution_tail#*|}"
	if [[ -n "${AIDEVOPS_PLANNING_PARENT_BRANCH:-}" && "$attempt" -gt 1 && \
		"$target_sha" != "$previous_target_sha" ]]; then
		if [[ -z "$previous_target_sha" || -z "$target_sha" ]] || \
			_planning_publish_parent_conflicts "$repo_path" "$previous_target_sha" "$target_sha" "$snapshot_file"; then
			_planning_publish_log_retryable_conflict "$publication_id"
			return 2
		fi
	fi
	printf '%s|%s|%s\n' "$latest_sha" "$expected_sha" "$target_sha"
	return 0
}

_planning_publish_finish_noop_if_current() {
	local repo_path="$1"
	local remote_name="$2"
	local branch_name="$3"
	local source_head="$4"
	local latest_sha="$5"
	local target_sha="$6"
	local tree_sha="$7"
	local publication_id="$8"
	local snapshot_file="$9"
	local current_sha="$latest_sha"
	local target_parent=""
	if [[ -n "${AIDEVOPS_PLANNING_PARENT_BRANCH:-}" ]]; then
		[[ -n "$target_sha" ]] || return 1
		[[ "$tree_sha" == "$(_planning_git -C "$repo_path" rev-parse "${target_sha}^{tree}")" ]] || return 1
		if [[ "$target_sha" != "$latest_sha" ]]; then
			target_parent=$(_planning_git -C "$repo_path" rev-parse "${target_sha}^") || return 1
			[[ "$target_parent" == "$latest_sha" ]] || return 1
		fi
		current_sha="$target_sha"
	elif [[ "$tree_sha" != "$(_planning_git -C "$repo_path" rev-parse "${latest_sha}^{tree}")" ]]; then
		return 1
	fi
	_planning_publish_record_noop_receipt "$repo_path" "$remote_name" "$branch_name" "$source_head" \
		"$current_sha" "$publication_id" "$snapshot_file" || {
		_planning_publish_log error "Remote planning state is current, but its publication handoff receipt could not be reconstructed"
		return 3
	}
	return 0
}

planning_publish() {
	local repo_path="$1"
	local commit_msg="$2"
	local remote_name="${3:-origin}"
	local branch_name="${4:-}"
	local paths="${5:-}"
	local external_source="${6:-}"
	local temp_dir="" snapshot_file="" index_file="" parent_sha="" tree_sha="" candidate_sha=""
	local publication_id="" handoff_id="" attempt=0 push_rc=0 latest_sha="" expected_sha="" target_sha="" previous_target_sha=""
	local parent_resolution="" resolution_tail="" base_sha="${AIDEVOPS_PLANNING_BASE_SHA:-}" guard_rc=0 resolve_rc=0 noop_rc=1 source_head=""
	[[ -n "$branch_name" ]] || branch_name=$(_planning_git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null) || return 1
	_planning_publish_reset_result
	source_head=$(_planning_git -C "$repo_path" rev-parse --verify "HEAD^{commit}" 2>/dev/null) || return 1
	PLANNING_PUBLICATION_SOURCE_HEAD="$source_head"
	[[ -n "$paths" ]] || paths=$(_planning_publish_changed_paths "$repo_path")
	if [[ -z "$paths" ]]; then
		PLANNING_PUBLISH_RESULT="noop"
		return 0
	fi
	_planning_publish_prepare_snapshot "$repo_path" "$paths" "$external_source" || return 1
	temp_dir="$_PLANNING_PUBLISH_TEMP_DIR"
	snapshot_file="$_PLANNING_PUBLISH_SNAPSHOT_FILE"
	index_file="$_PLANNING_PUBLISH_INDEX_FILE"
	publication_id="$PLANNING_PUBLICATION_ID"
	while [[ $attempt -lt $PLANNING_PUBLISH_MAX_RETRIES ]]; do
		attempt=$((attempt + 1))
		resolve_rc=0
		parent_resolution=$(_planning_publish_resolve_attempt "$repo_path" "$remote_name" "$branch_name" \
			"$previous_target_sha" "$snapshot_file" "$publication_id" "$attempt") || resolve_rc=$?
		if [[ "$resolve_rc" -ne 0 ]]; then
			rm -rf "$temp_dir"
			return "$resolve_rc"
		fi
		latest_sha="${parent_resolution%%|*}"
		resolution_tail="${parent_resolution#*|}"
		expected_sha="${resolution_tail%%|*}"
		target_sha="${resolution_tail#*|}"
		previous_target_sha="$target_sha"
		_planning_publish_build_index "$repo_path" "$latest_sha" "$snapshot_file" "$index_file" || {
			rm -rf "$temp_dir"
			return 1
		}
		_planning_publish_verify_index "$repo_path" "$latest_sha" "$snapshot_file" "$index_file" || {
			rm -rf "$temp_dir"
			return 1
		}
		tree_sha=$(GIT_INDEX_FILE="$index_file" _planning_git -C "$repo_path" write-tree) || {
			rm -rf "$temp_dir"
			return 1
		}
		noop_rc=0
		_planning_publish_finish_noop_if_current "$repo_path" "$remote_name" "$branch_name" "$source_head" \
			"$latest_sha" "$target_sha" "$tree_sha" "$publication_id" "$snapshot_file" || noop_rc=$?
		if [[ "$noop_rc" -ne 1 ]]; then
			rm -rf "$temp_dir"
			return "$noop_rc"
		fi
		if [[ -z "$parent_sha" && -n "$base_sha" && "$base_sha" != "$latest_sha" ]] && \
			_planning_publish_parent_conflicts "$repo_path" "$base_sha" "$latest_sha" "$snapshot_file"; then
			_planning_publish_log_retryable_conflict "$publication_id"
			rm -rf "$temp_dir"
			return 2
		fi
		if [[ -n "$parent_sha" ]] && _planning_publish_parent_conflicts "$repo_path" "$parent_sha" "$latest_sha" "$snapshot_file"; then
			_planning_publish_log_retryable_conflict "$publication_id"
			rm -rf "$temp_dir"
			return 2
		fi
		parent_sha="$latest_sha"
		_planning_publish_build_candidate "$repo_path" "$remote_name" "$branch_name" "$source_head" \
			"$parent_sha" "$publication_id" "$commit_msg" "$tree_sha" "$index_file" || {
			rm -rf "$temp_dir"
			return 1
		}
		handoff_id="$_PLANNING_PUBLISH_HANDOFF_ID"
		candidate_sha="$_PLANNING_PUBLISH_CANDIDATE_SHA"
		guard_rc=0
		_planning_publish_run_pre_push_guards "$repo_path" "$remote_name" "$branch_name" \
			"$parent_sha" "$candidate_sha" "$attempt" || guard_rc=$?
		if [[ "$guard_rc" -ne 0 ]]; then
			rm -rf "$temp_dir"
			return "$guard_rc"
		fi
		push_rc=0
		_planning_publish_push "$repo_path" "$remote_name" "$branch_name" "$expected_sha" "$candidate_sha" || push_rc=$?
		if [[ $push_rc -eq 0 ]]; then
			if ! _planning_publish_record_pushed_receipt "$repo_path" "$remote_name" "$branch_name" "$source_head" \
				"$candidate_sha" "$parent_sha" "$publication_id" "$handoff_id" "$snapshot_file"; then
				_planning_publish_log error "Remote branch advanced to ${candidate_sha}, but the publication handoff receipt could not be persisted; retry safely to reconstruct it"
				rm -rf "$temp_dir"
				return 3
			fi
			_planning_publish_log success "Published allowlisted files (${publication_id})"
			rm -rf "$temp_dir"
			return 0
		fi
	done
	_planning_publish_log_retryable_conflict "$publication_id"
	rm -rf "$temp_dir"
	return 2
}
