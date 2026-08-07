#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Release preparation and validation primitives for managed Cloudron packages.

[[ -n "${_CLOUDRON_PACKAGE_RELEASE_LIB_LOADED:-}" ]] && return 0
_CLOUDRON_PACKAGE_RELEASE_LIB_LOADED=1

CLOUDRON_PINNED_BASE_IMAGE="cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e"

_cloudron_release_error() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 1
}

cloudron_package_is_semver() {
	local version="$1"
	[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
	return $?
}

_cloudron_release_preserve_mode() {
	local source_file="$1"
	local target_file="$2"
	local mode=""
	mode=$(stat -f '%Lp' "$source_file" 2>/dev/null || stat -c '%a' "$source_file" 2>/dev/null || true)
	if [[ -n "$mode" ]]; then
		chmod "$mode" "$target_file" || return 1
	fi
	return 0
}

_cloudron_release_cleanup() {
	local file_path=""
	for file_path in "$@"; do
		[[ -z "$file_path" ]] || rm -f "$file_path"
	done
	return 0
}

_cloudron_release_dockerfile() {
	local repo_path="$1"
	if [[ -f "${repo_path}/Dockerfile" ]]; then
		printf '%s\n' "${repo_path}/Dockerfile"
		return 0
	fi
	if [[ -f "${repo_path}/Dockerfile.cloudron" ]]; then
		printf '%s\n' "${repo_path}/Dockerfile.cloudron"
		return 0
	fi
	return 1
}

# Print actionable compatibility findings and return non-zero when any exist.
cloudron_package_compatibility_findings() {
	local repo_path="${1:-.}"
	local manifest_rel="${2:-CloudronManifest.json}"
	local manifest_path="${repo_path}/${manifest_rel}"
	local findings=0

	if ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' '- jq is required to validate CloudronManifest.json.'
		return 1
	fi
	if [[ ! -f "$manifest_path" ]]; then
		printf '%s\n' "- ${manifest_rel} is missing."
		return 1
	fi
	if ! jq empty "$manifest_path" >/dev/null 2>&1; then
		printf '%s\n' "- ${manifest_rel} is not valid JSON."
		return 1
	fi
	if ! jq -e '
		def nonempty_string: type == "string" and length > 0;
		type == "object" and
		(.id | nonempty_string) and
		(.title | nonempty_string) and
		(.version | nonempty_string) and
		(.healthCheckPath | nonempty_string) and
		(.httpPort | type == "number" and . > 0) and
		(.manifestVersion == 2)
	' "$manifest_path" >/dev/null 2>&1; then
		printf '%s\n' '- CloudronManifest.json is missing required package fields or manifestVersion is not 2.'
		findings=$((findings + 1))
	fi
	local package_version=""
	package_version=$(jq -r '.version // empty' "$manifest_path")
	if ! cloudron_package_is_semver "$package_version"; then
		printf '%s\n' "- Package version '${package_version:-missing}' is not semantic versioning."
		findings=$((findings + 1))
	fi

	local dockerfile=""
	if ! dockerfile=$(_cloudron_release_dockerfile "$repo_path"); then
		printf '%s\n' '- Dockerfile or Dockerfile.cloudron is missing.'
		findings=$((findings + 1))
	else
		local final_from=""
		local final_image=""
		final_from=$(awk 'toupper($1) == "FROM" { line = $0 } END { print line }' "$dockerfile")
		final_image=$(printf '%s\n' "$final_from" | awk '{ print $2 }')
		if [[ "$final_image" != "$CLOUDRON_PINNED_BASE_IMAGE" ]]; then
			printf '%s\n' "- Final Docker stage must use ${CLOUDRON_PINNED_BASE_IMAGE}."
			findings=$((findings + 1))
		fi
	fi

	[[ "$findings" -eq 0 ]] && return 0
	return 1
}

_cloudron_release_changelog_has_version() {
	local changelog_path="$1"
	local package_version="$2"
	grep -Fq "## [${package_version}]" "$changelog_path"
	return $?
}

_cloudron_release_changelog_has_notes() {
	local changelog_path="$1"
	local package_version="$2"
	awk -v version="$package_version" '
		index($0, "## [" version "]") == 1 { in_release = 1; next }
		in_release && /^## / { exit }
		in_release && /[^[:space:]]/ { found = 1; exit }
		END { exit(found ? 0 : 1) }
	' "$changelog_path"
	return $?
}

_cloudron_release_write_changelog() {
	local changelog_path="$1"
	local output_path="$2"
	local package_version="$3"
	local notes_file="$4"
	local release_date="$5"
	local first_line=""

	{
		if IFS= read -r first_line; then
			if [[ "$first_line" == "# Changelog"* ]]; then
				printf '%s\n\n## [%s] - %s\n\n' "$first_line" "$package_version" "$release_date"
				cat "$notes_file"
				printf '\n\n'
				cat
			else
				printf '## [%s] - %s\n\n' "$package_version" "$release_date"
				cat "$notes_file"
				printf '\n\n%s\n' "$first_line"
				cat
			fi
		else
			printf '## [%s] - %s\n\n' "$package_version" "$release_date"
			cat "$notes_file"
			printf '\n'
		fi
	} <"$changelog_path" >"$output_path"
	return $?
}

# Atomically prepare CloudronManifest.json and CHANGELOG.md without publishing.
# Usage: cloudron_package_prepare_release <package-version> <upstream-version> <notes-file> [repo-path]
cloudron_package_prepare_release() {
	local package_version="${1:-}"
	local upstream_version="${2:-}"
	local notes_file="${3:-}"
	local repo_path="${4:-.}"
	upstream_version="${upstream_version#v}"

	cloudron_package_is_semver "$package_version" || _cloudron_release_error "Package version must be semantic versioning (for example 1.2.3)." || return 1
	cloudron_package_is_semver "$upstream_version" || _cloudron_release_error "Upstream version must be semantic versioning (for example 4.5.6)." || return 1
	[[ -f "$notes_file" ]] || _cloudron_release_error "Release notes file not found: $notes_file" || return 1
	grep -q '[^[:space:]]' "$notes_file" || _cloudron_release_error "Release notes must not be empty." || return 1

	local manifest_path="${repo_path}/CloudronManifest.json"
	local changelog_path="${repo_path}/CHANGELOG.md"
	[[ -f "$manifest_path" ]] || _cloudron_release_error "CloudronManifest.json not found." || return 1
	[[ -f "$changelog_path" ]] || _cloudron_release_error "CHANGELOG.md not found." || return 1
	if ! cloudron_package_compatibility_findings "$repo_path" >/dev/null; then
		_cloudron_release_error "Package compatibility validation failed before release preparation." || return 1
	fi
	if _cloudron_release_changelog_has_version "$changelog_path" "$package_version"; then
		_cloudron_release_error "CHANGELOG.md already contains package version $package_version." || return 1
	fi

	local manifest_tmp=""
	local changelog_tmp=""
	local manifest_backup=""
	local changelog_backup=""
	manifest_tmp=$(mktemp "${manifest_path}.tmp.XXXXXX") || return 1
	changelog_tmp=$(mktemp "${changelog_path}.tmp.XXXXXX") || {
		rm -f "$manifest_tmp"
		return 1
	}
	manifest_backup=$(mktemp "${manifest_path}.backup.XXXXXX") || {
		rm -f "$manifest_tmp" "$changelog_tmp"
		return 1
	}
	changelog_backup=$(mktemp "${changelog_path}.backup.XXXXXX") || {
		rm -f "$manifest_tmp" "$changelog_tmp" "$manifest_backup"
		return 1
	}

	if ! jq --arg version "$package_version" --arg upstream "$upstream_version" \
		'.version = $version | .upstreamVersion = $upstream' "$manifest_path" >"$manifest_tmp" ||
		! jq empty "$manifest_tmp" >/dev/null 2>&1 ||
		! _cloudron_release_write_changelog "$changelog_path" "$changelog_tmp" "$package_version" "$notes_file" "$(date -u +%Y-%m-%d)" ||
		! _cloudron_release_changelog_has_notes "$changelog_tmp" "$package_version"; then
		_cloudron_release_cleanup "$manifest_tmp" "$changelog_tmp" "$manifest_backup" "$changelog_backup"
		_cloudron_release_error "Failed to prepare validated release files." || return 1
	fi
	if ! _cloudron_release_preserve_mode "$manifest_path" "$manifest_tmp" ||
		! _cloudron_release_preserve_mode "$changelog_path" "$changelog_tmp" ||
		! cp -p "$manifest_path" "$manifest_backup" ||
		! cp -p "$changelog_path" "$changelog_backup"; then
		_cloudron_release_cleanup "$manifest_tmp" "$changelog_tmp" "$manifest_backup" "$changelog_backup"
		return 1
	fi

	if ! mv "$manifest_tmp" "$manifest_path"; then
		_cloudron_release_cleanup "$manifest_tmp" "$changelog_tmp" "$manifest_backup" "$changelog_backup"
		return 1
	fi
	if ! mv "$changelog_tmp" "$changelog_path"; then
		mv "$manifest_backup" "$manifest_path" || true
		mv "$changelog_backup" "$changelog_path" || true
		_cloudron_release_cleanup "$manifest_tmp" "$changelog_tmp"
		_cloudron_release_error "Partial write detected; original release files restored." || return 1
	fi
	_cloudron_release_cleanup "$manifest_backup" "$changelog_backup"
	printf 'Prepared Cloudron package %s for upstream %s. No release was published.\n' "$package_version" "$upstream_version"
	return 0
}

# Validate the package, changelog, and tag before a release is published.
# Usage: cloudron_package_check_release <vX.Y.Z> [repo-path]
cloudron_package_check_release() {
	local release_tag="${1:-${GITHUB_REF_NAME:-}}"
	local repo_path="${2:-.}"
	local manifest_path="${repo_path}/CloudronManifest.json"
	local changelog_path="${repo_path}/CHANGELOG.md"
	local findings=""

	if [[ ! "$release_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
		_cloudron_release_error "Release tag must use vX.Y.Z format." || return 1
	fi
	if ! findings=$(cloudron_package_compatibility_findings "$repo_path"); then
		printf '%s\n' "$findings" >&2
		_cloudron_release_error "Cloudron package compatibility validation failed." || return 1
	fi
	local package_version=""
	package_version=$(jq -r '.version // empty' "$manifest_path")
	if [[ "$release_tag" != "v${package_version}" ]]; then
		_cloudron_release_error "Tag $release_tag does not match manifest version $package_version." || return 1
	fi
	[[ -f "$changelog_path" ]] || _cloudron_release_error "CHANGELOG.md not found." || return 1
	_cloudron_release_changelog_has_version "$changelog_path" "$package_version" || _cloudron_release_error "CHANGELOG.md has no section for $package_version." || return 1
	_cloudron_release_changelog_has_notes "$changelog_path" "$package_version" || _cloudron_release_error "CHANGELOG.md section for $package_version is empty." || return 1
	printf 'Cloudron release validation passed for %s.\n' "$release_tag"
	return 0
}
