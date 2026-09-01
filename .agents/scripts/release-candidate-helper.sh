#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

_RELEASE_CANDIDATE_TMP_DIR=""
_RELEASE_CANDIDATE_REPO_ROOT=""
_RELEASE_CANDIDATE_COMMIT=""
_RELEASE_CANDIDATE_PACK_JSON=""
_RELEASE_CANDIDATE_ARCHIVE=""

_release_candidate_error() {
	local message="$1"
	printf 'release-candidate: %s\n' "$message" >&2
	return 1
}

_release_candidate_usage() {
	cat <<'USAGE'
Usage:
  release-candidate-helper.sh verify --repo PATH --expected-commit SHA \
    --expected-version VERSION [--manifest PATH] [--archive PATH]

Builds the exact npm distributable without lifecycle scripts, verifies its
identity and archive contents, and emits a machine-readable manifest. The
command never creates commits, tags, releases, workflow dispatches, or uploads.
USAGE
	return 0
}

_release_candidate_cleanup() {
	if [[ -n "$_RELEASE_CANDIDATE_TMP_DIR" && -d "$_RELEASE_CANDIDATE_TMP_DIR" ]]; then
		rm -f -- \
			"${_RELEASE_CANDIDATE_TMP_DIR}/npm-pack.json" \
			"${_RELEASE_CANDIDATE_TMP_DIR}/expected-files.txt" \
			"${_RELEASE_CANDIDATE_TMP_DIR}/archive-files.txt" \
			"${_RELEASE_CANDIDATE_TMP_DIR}/manifest.json" \
			"${_RELEASE_CANDIDATE_TMP_DIR}"/*.tgz 2>/dev/null || true
		rmdir "$_RELEASE_CANDIDATE_TMP_DIR" 2>/dev/null || true
	fi
	return 0
}

_release_candidate_require_command() {
	local command_name="$1"
	if ! command -v "$command_name" >/dev/null 2>&1; then
		_release_candidate_error "required command is unavailable: ${command_name}"
		return 1
	fi
	return 0
}

_release_candidate_sha256() {
	local file_path="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file_path" | cut -d' ' -f1
		return "${PIPESTATUS[0]}"
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file_path" | cut -d' ' -f1
		return "${PIPESTATUS[0]}"
	fi
	_release_candidate_error "sha256sum or shasum is required"
	return 1
}

_release_candidate_validate_destination() {
	local destination="$1"
	local description="$2"
	local parent=""
	[[ -n "$destination" ]] || return 0
	if [[ -e "$destination" || -L "$destination" ]]; then
		_release_candidate_error "refusing to overwrite ${description}: ${destination}"
		return 1
	fi
	parent=$(dirname "$destination")
	if [[ ! -d "$parent" || -L "$parent" ]]; then
		_release_candidate_error "${description} parent is unavailable: ${parent}"
		return 1
	fi
	return 0
}

_release_candidate_validate_source() {
	local repo_path="$1"
	local expected_commit="$2"
	local expected_version="$3"
	local package_version=""
	local version_file=""

	[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || {
		_release_candidate_error "expected commit must be one full lowercase SHA"
		return 1
	}
	[[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
		_release_candidate_error "expected version must be an exact semantic version"
		return 1
	}
	if [[ ! -d "$repo_path" || -L "$repo_path" ]]; then
		_release_candidate_error "repository worktree is unavailable: ${repo_path}"
		return 1
	fi
	_RELEASE_CANDIDATE_REPO_ROOT=$(cd "$repo_path" && pwd -P) || return 1
	_RELEASE_CANDIDATE_COMMIT=$(git -C "$_RELEASE_CANDIDATE_REPO_ROOT" rev-parse HEAD 2>/dev/null) || {
		_release_candidate_error "repository commit cannot be resolved"
		return 1
	}
	if [[ "$_RELEASE_CANDIDATE_COMMIT" != "$expected_commit" ]]; then
		_release_candidate_error "worktree commit ${_RELEASE_CANDIDATE_COMMIT} does not match ${expected_commit}"
		return 1
	fi
	if [[ -n "$(git -C "$_RELEASE_CANDIDATE_REPO_ROOT" status --porcelain --untracked-files=all)" ]]; then
		_release_candidate_error "repository worktree must be clean"
		return 1
	fi
	if [[ ! -f "${_RELEASE_CANDIDATE_REPO_ROOT}/package.json" ||
		! -f "${_RELEASE_CANDIDATE_REPO_ROOT}/VERSION" ]]; then
		_release_candidate_error "repository is missing package.json or VERSION"
		return 1
	fi
	package_version=$(jq -er '.version' "${_RELEASE_CANDIDATE_REPO_ROOT}/package.json" 2>/dev/null) || {
		_release_candidate_error "package.json version is unavailable"
		return 1
	}
	version_file=$(<"${_RELEASE_CANDIDATE_REPO_ROOT}/VERSION")
	if [[ "$package_version" != "$expected_version" || "$version_file" != "$expected_version" ]]; then
		_release_candidate_error "package.json and VERSION must match ${expected_version}"
		return 1
	fi
	return 0
}

_release_candidate_prepare_temp() {
	local manifest_destination="$1"
	local archive_destination="$2"
	local temp_base=""
	_release_candidate_validate_destination "$manifest_destination" "manifest" || return 1
	_release_candidate_validate_destination "$archive_destination" "archive" || return 1
	temp_base="${AIDEVOPS_TEMP_DIR:-${RUNNER_TEMP:-${HOME}/.aidevops/.agent-workspace/tmp}}"
	if [[ ! -d "$temp_base" || -L "$temp_base" ]]; then
		_release_candidate_error "private temporary directory is unavailable: ${temp_base}"
		return 1
	fi
	_RELEASE_CANDIDATE_TMP_DIR=$(mktemp -d "${temp_base%/}/release-candidate.XXXXXX") || return 1
	chmod 700 "$_RELEASE_CANDIDATE_TMP_DIR"
	trap _release_candidate_cleanup EXIT
	trap '_release_candidate_cleanup; exit 130' HUP INT TERM
	return 0
}

_release_candidate_build_archive() {
	local expected_version="$1"
	local archive_name=""
	_RELEASE_CANDIDATE_PACK_JSON="${_RELEASE_CANDIDATE_TMP_DIR}/npm-pack.json"
	if ! (cd "$_RELEASE_CANDIDATE_REPO_ROOT" && npm pack --ignore-scripts --json \
		--pack-destination "$_RELEASE_CANDIDATE_TMP_DIR") >"$_RELEASE_CANDIDATE_PACK_JSON"; then
		_release_candidate_error "npm package build failed"
		return 1
	fi
	if ! jq -e --arg version "$expected_version" '
		type == "array" and length == 1
		and .[0].name == "aidevops"
		and .[0].version == $version
		and (.[0].integrity | test("^sha512-[A-Za-z0-9+/]+={0,2}$"))
		and (.[0].shasum | test("^[0-9a-f]{40}$"))
		and (.[0].entryCount == (.[0].files | length))
		and (.[0].files | type == "array" and length > 0)
	' "$_RELEASE_CANDIDATE_PACK_JSON" >/dev/null; then
		_release_candidate_error "npm package identity is malformed"
		return 1
	fi
	archive_name=$(jq -er '.[0].filename' "$_RELEASE_CANDIDATE_PACK_JSON") || return 1
	if [[ "$archive_name" != "$(basename "$archive_name")" || "$archive_name" != *.tgz ]]; then
		_release_candidate_error "npm returned an unsafe archive filename"
		return 1
	fi
	_RELEASE_CANDIDATE_ARCHIVE="${_RELEASE_CANDIDATE_TMP_DIR}/${archive_name}"
	[[ -f "$_RELEASE_CANDIDATE_ARCHIVE" && ! -L "$_RELEASE_CANDIDATE_ARCHIVE" ]] || {
		_release_candidate_error "npm package archive was not created"
		return 1
	}
	return 0
}

_release_candidate_verify_archive() {
	local expected_files=""
	local archive_files=""
	expected_files="${_RELEASE_CANDIDATE_TMP_DIR}/expected-files.txt"
	archive_files="${_RELEASE_CANDIDATE_TMP_DIR}/archive-files.txt"
	jq -er '.[0].files[] | "package/" + .path' "$_RELEASE_CANDIDATE_PACK_JSON" >"$expected_files"
	tar -tzf "$_RELEASE_CANDIDATE_ARCHIVE" >"$archive_files"
	if grep -qE '(^/|(^|/)\.\.(/|$))' "$archive_files"; then
		_release_candidate_error "package archive contains an unsafe path"
		return 1
	fi
	LC_ALL=C sort "$expected_files" -o "$expected_files"
	LC_ALL=C sort "$archive_files" -o "$archive_files"
	if ! cmp -s "$expected_files" "$archive_files"; then
		_release_candidate_error "package archive contents do not match npm's manifest"
		return 1
	fi
	return 0
}

_release_candidate_emit_outputs() {
	local manifest_destination="$1"
	local archive_destination="$2"
	local archive_sha256=""
	local manifest_path=""
	archive_sha256=$(_release_candidate_sha256 "$_RELEASE_CANDIDATE_ARCHIVE") || return 1
	[[ "$archive_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
	manifest_path="${_RELEASE_CANDIDATE_TMP_DIR}/manifest.json"
	jq -S --arg schema "aidevops.release-candidate/v1" \
		--arg commit "$_RELEASE_CANDIDATE_COMMIT" --arg archive_sha256 "$archive_sha256" '
		.[0] | {
			schema: $schema,
			commit: $commit,
			name,
			version,
			filename,
			size,
			unpackedSize,
			entryCount,
			integrity,
			shasum,
			archive_sha256: $archive_sha256,
			files: (.files | sort_by(.path))
		}
	' "$_RELEASE_CANDIDATE_PACK_JSON" >"$manifest_path"

	if [[ -n "$manifest_destination" ]]; then
		cp "$manifest_path" "$manifest_destination"
		chmod 600 "$manifest_destination"
		printf 'MANIFEST_FILE=%s\n' "$manifest_destination"
	else
		jq -c . "$manifest_path"
	fi
	if [[ -n "$archive_destination" ]]; then
		cp "$_RELEASE_CANDIDATE_ARCHIVE" "$archive_destination"
		chmod 600 "$archive_destination"
		printf 'ARCHIVE_FILE=%s\n' "$archive_destination"
	fi
	return 0
}

_release_candidate_verify() {
	local repo_path="$1"
	local expected_commit="$2"
	local expected_version="$3"
	local manifest_destination="$4"
	local archive_destination="$5"
	_release_candidate_validate_source "$repo_path" "$expected_commit" "$expected_version" || return 1
	_release_candidate_prepare_temp "$manifest_destination" "$archive_destination" || return 1
	_release_candidate_build_archive "$expected_version" || return 1
	_release_candidate_verify_archive || return 1
	_release_candidate_emit_outputs "$manifest_destination" "$archive_destination"
	return $?
}

main() {
	local action="${1:-}"
	local repo_path=""
	local expected_commit=""
	local expected_version=""
	local manifest_destination=""
	local archive_destination=""
	[[ $# -gt 0 ]] && shift

	if [[ "$action" == "--help" || "$action" == "-h" ]]; then
		_release_candidate_usage
		return 0
	fi
	if [[ "$action" != "verify" ]]; then
		_release_candidate_usage >&2
		return 2
	fi
	while [[ $# -gt 0 ]]; do
		local argument="$1"
		case "$argument" in
		--repo | --expected-commit | --expected-version | --manifest | --archive)
			if [[ $# -lt 2 ]]; then
				_release_candidate_error "missing value for ${argument}"
				return 2
			fi
			;;
		*)
			_release_candidate_error "unknown argument: $argument"
			return 2
			;;
		esac
		local argument_value="$2"
		case "$argument" in
		--repo)
			repo_path="$argument_value"
			shift 2
			;;
		--expected-commit)
			expected_commit="$argument_value"
			shift 2
			;;
		--expected-version)
			expected_version="$argument_value"
			shift 2
			;;
		--manifest)
			manifest_destination="$argument_value"
			shift 2
			;;
		--archive)
			archive_destination="$argument_value"
			shift 2
			;;
		esac
	done
	if [[ -z "$repo_path" || -z "$expected_commit" || -z "$expected_version" ]]; then
		_release_candidate_usage >&2
		return 2
	fi
	for command_name in git jq npm tar cmp sort; do
		_release_candidate_require_command "$command_name" || return 1
	done
	_release_candidate_verify "$repo_path" "$expected_commit" "$expected_version" \
		"$manifest_destination" "$archive_destination"
	return $?
}

main "$@"
