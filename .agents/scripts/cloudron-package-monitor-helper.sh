#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Monitor registered Cloudron packages and file package-local findings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=cloudron-package-release-lib.sh
source "${SCRIPT_DIR}/cloudron-package-release-lib.sh"

REPOS_FILE="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
_CLOUDRON_MONITOR_JSON_TYPE_ARRAY=array
_CLOUDRON_MONITOR_JSON_TYPE_STRING=string

_cloudron_monitor_error() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 1
}

_cloudron_monitor_deferred() {
	local expires_at=""
	expires_at="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
	[[ "$expires_at" =~ ^[0-9]+$ ]] || expires_at="unknown"
	printf 'DEFERRED: GitHub API cooldown active until epoch %s.\n' "$expires_at" >&2
	return 75
}

_cloudron_monitor_response_bodies() {
	local response_text="$1"
	printf '%s\n' "$response_text" | awk '
		{
			line = $0
			sub(/\r$/, "", line)
			if (line ~ /^HTTP\//) { in_headers = 1; next }
			if (in_headers && line == "") { in_headers = 0; next }
			if (!in_headers) { print line }
		}
	'
	return 0
}

_cloudron_monitor_fetch_releases() {
	local upstream_slug="$1"
	local endpoint="/repos/${upstream_slug}/releases?per_page=100"
	local response=""
	local api_rc=0
	response=$(_gh_with_timeout read gh api -i "$endpoint" --paginate 2>/dev/null) || api_rc=$?
	if [[ "$api_rc" -eq 75 ]] || _gh_secondary_cooldown_active; then
		_cloudron_monitor_deferred
		return $?
	fi
	if [[ "$api_rc" -ne 0 ]]; then
		_cloudron_monitor_error "Could not fetch paginated GitHub releases for $upstream_slug."
		return 1
	fi
	_cloudron_monitor_response_bodies "$response"
	return 0
}

_cloudron_monitor_require_tools() {
	command -v jq >/dev/null 2>&1 || _cloudron_monitor_error "jq is required." || return 1
	command -v gh >/dev/null 2>&1 || _cloudron_monitor_error "GitHub CLI is required." || return 1
	[[ -f "$REPOS_FILE" ]] || _cloudron_monitor_error "repos.json not found: $REPOS_FILE" || return 1
	jq -e --arg array_type "$_CLOUDRON_MONITOR_JSON_TYPE_ARRAY" \
		'.initialized_repos | type == $array_type' "$REPOS_FILE" >/dev/null 2>&1 || _cloudron_monitor_error "repos.json has no initialized_repos array." || return 1
	return 0
}

_cloudron_monitor_component_newer() {
	local candidate="$1"
	local current="$2"
	if [[ "${#candidate}" -ne "${#current}" ]]; then
		[[ "${#candidate}" -gt "${#current}" ]]
		return $?
	fi
	[[ "$candidate" > "$current" ]]
	return $?
}

_cloudron_monitor_version_newer() {
	local candidate="${1#v}"
	local current="${2#v}"
	cloudron_package_is_semver "$candidate" || return 1
	cloudron_package_is_semver "$current" || return 0
	local candidate_core="${candidate%%[-+]*}"
	local current_core="${current%%[-+]*}"
	local candidate_major=0 candidate_minor=0 candidate_patch=0
	local current_major=0 current_minor=0 current_patch=0
	IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate_core"
	IFS=. read -r current_major current_minor current_patch <<<"$current_core"
	if [[ "$candidate_major" != "$current_major" ]]; then
		_cloudron_monitor_component_newer "$candidate_major" "$current_major"
		return $?
	fi
	if [[ "$candidate_minor" != "$current_minor" ]]; then
		_cloudron_monitor_component_newer "$candidate_minor" "$current_minor"
		return $?
	fi
	if [[ "$candidate_patch" != "$current_patch" ]]; then
		_cloudron_monitor_component_newer "$candidate_patch" "$current_patch"
		return $?
	fi
	if [[ "$candidate" != *-* && "$current" == *-* ]]; then
		return 0
	fi
	return 1
}

_cloudron_monitor_tag_version() {
	local tag="$1"
	local prefixes_json="$2"
	local prefix=""
	local version=""
	while IFS= read -r prefix; do
		[[ "$tag" == "$prefix"* ]] || continue
		version="${tag#"$prefix"}"
		cloudron_package_is_semver "$version" || continue
		[[ "${version%%+*}" != *-* ]] || continue
		printf '%s\n' "$version"
		return 0
	done < <(jq -r '.[]' <<<"$prefixes_json")
	return 1
}

_cloudron_monitor_latest_release_version() {
	local releases_json="$1"
	local prefixes_json="$2"
	local upstream_slug="$3"
	local stable_tags=""
	local tag=""
	local version=""
	local latest_version=""

	[[ -n "$releases_json" ]] || _cloudron_monitor_error "GitHub returned an empty releases response for $upstream_slug." || return 1
	if ! stable_tags=$(jq -r \
		--arg array_type "$_CLOUDRON_MONITOR_JSON_TYPE_ARRAY" \
		--arg string_type "$_CLOUDRON_MONITOR_JSON_TYPE_STRING" '
		if type != $array_type then
			error("expected a release array")
		else
			.[]
			| select(type == "object" and .draft != true and .prerelease != true and (.tag_name | type == $string_type))
			| .tag_name
		end
	' <<<"$releases_json"); then
		_cloudron_monitor_error "GitHub releases response for $upstream_slug was not a valid release array." || return 1
	fi

	while IFS= read -r tag; do
		[[ -n "$tag" ]] || continue
		version=$(_cloudron_monitor_tag_version "$tag" "$prefixes_json") || continue
		if [[ -z "$latest_version" ]] || _cloudron_monitor_version_newer "$version" "$latest_version"; then
			latest_version="$version"
		fi
	done <<<"$stable_tags"

	[[ -n "$latest_version" ]] || _cloudron_monitor_error "No stable semantic release tag for $upstream_slug matches cloudron_package.upstream_tag_prefixes ${prefixes_json}; configure the tag streams or publish a matching stable release." || return 1
	printf '%s\n' "$latest_version"
	return 0
}

_cloudron_monitor_has_authority() {
	local slug="$1"
	local permission=""
	permission=$(gh repo view "$slug" --json viewerPermission --jq '.viewerPermission') || return 1
	case "$permission" in
	ADMIN | MAINTAIN) return 0 ;;
	*) return 1 ;;
	esac
}

_cloudron_monitor_issue_exists() {
	local slug="$1"
	local fingerprint="$2"
	local issue_number=""
	if ! issue_number=$(gh issue list --repo "$slug" --state all --search "${fingerprint} in:body" --limit 1 --json number --jq '.[0].number // empty'); then
		return 2
	fi
	[[ -n "$issue_number" ]]
	return $?
}

_cloudron_monitor_create_issue() {
	local slug="$1"
	local title="$2"
	local fingerprint="$3"
	local summary="$4"
	local verification="$5"
	local body_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local body_file=""
	local issue_wrapper="${CLOUDRON_PACKAGE_ISSUE_WRAPPER:-gh_create_issue}"
	command -v "$issue_wrapper" >/dev/null 2>&1 || _cloudron_monitor_error "gh_create_issue wrapper is required for managed issue writes." || return 1
	mkdir -p "$body_dir"
	body_file=$(mktemp "${body_dir}/cloudron-package-monitor.XXXXXX") || return 1
	cat >"$body_file" <<EOF
<!-- aidevops:cloudron-package-monitor ${fingerprint} -->
## What

${summary}

The monitor did not build, publish, tag, deploy, or modify package source.

## Files to inspect

- \`CloudronManifest.json\` — package and upstream version metadata.
- \`Dockerfile\` or \`Dockerfile.cloudron\` — final Cloudron base image and packaged upstream artifacts.
- \`CHANGELOG.md\` — package release notes before any version bump.

## Acceptance criteria

- Reproduce and assess the finding against current upstream and Cloudron packaging guidance.
- Update package source and tests only when the finding remains actionable.
- Run the package release check before proposing a tag.
- Do not publish a release, image, catalog entry, or deployment without separate operator authorization.

## Verification

${verification}
EOF
	if "$issue_wrapper" --repo "$slug" --title "$title" --body-file "$body_file" \
		--label "type:maintenance" --label "tier:standard" --label "auto-dispatch" >/dev/null; then
		rm -f "$body_file"
		printf 'Created Cloudron package finding in %s: %s\n' "$slug" "$title"
		return 0
	fi
	rm -f "$body_file"
	return 1
}

_cloudron_monitor_apply_finding() {
	local apply="$1"
	local slug="$2"
	local title="$3"
	local fingerprint="$4"
	local summary="$5"
	local verification="$6"
	local exists_rc=0
	if _cloudron_monitor_issue_exists "$slug" "$fingerprint"; then
		printf 'Already handled in %s: %s\n' "$slug" "$fingerprint"
		return 0
	else
		exists_rc=$?
	fi
	[[ "$exists_rc" -ne 2 ]] || _cloudron_monitor_error "Could not check issue deduplication for $slug." || return 1
	if [[ "$apply" != true ]]; then
		printf 'FINDING %s %s\n' "$slug" "$title"
		return 0
	fi
	_cloudron_monitor_has_authority "$slug" || _cloudron_monitor_error "ADMIN or MAINTAIN issue authority is required for $slug." || return 1
	_cloudron_monitor_create_issue "$slug" "$title" "$fingerprint" "$summary" "$verification"
	return $?
}

_cloudron_monitor_upstream_entry() {
	local entry="$1"
	local apply="$2"
	local slug=""
	local repo_path=""
	local manifest_rel=""
	local upstream_slug=""
	local monitor_enabled=""
	local tag_prefixes=""
	slug=$(jq -r '.slug // empty' <<<"$entry")
	repo_path=$(jq -r '.path // empty' <<<"$entry")
	manifest_rel=$(jq -r '.cloudron_package.manifest // "CloudronManifest.json"' <<<"$entry")
	upstream_slug=$(jq -r '.cloudron_package.upstream_slug // empty' <<<"$entry")
	monitor_enabled=$(jq -r '.cloudron_package.monitor_upstream // ((.cloudron_package.upstream_slug // "") != "")' <<<"$entry")
	[[ "$monitor_enabled" == true ]] || return 0
	[[ "$slug" == */* && "$upstream_slug" == */* ]] || _cloudron_monitor_error "Cloudron upstream monitoring requires target and upstream slugs." || return 1
	[[ "$manifest_rel" != /* && "$manifest_rel" != *..* ]] || _cloudron_monitor_error "Unsafe manifest path configured for $slug." || return 1
	repo_path="${repo_path/#\~/$HOME}"
	local manifest_path="${repo_path}/${manifest_rel}"
	[[ -f "$manifest_path" ]] || _cloudron_monitor_error "Manifest missing for registered Cloudron package $slug." || return 1
	local package_title=""
	if ! package_title=$(jq -er --arg string_type "$_CLOUDRON_MONITOR_JSON_TYPE_STRING" \
		'.title | select(type == $string_type and test("\\S"))' "$manifest_path"); then
		_cloudron_monitor_error "Manifest title is missing or blank for registered Cloudron package $slug." || return 1
	fi
	tag_prefixes=$(jq -c '.cloudron_package.upstream_tag_prefixes as $prefixes | if $prefixes == null then ["v", ""] else $prefixes end' <<<"$entry") || return 1
	jq -e --arg array_type "$_CLOUDRON_MONITOR_JSON_TYPE_ARRAY" --arg string_type "$_CLOUDRON_MONITOR_JSON_TYPE_STRING" \
		'type == $array_type and length > 0 and all(.[]; type == $string_type and all(explode[]; . >= 32 and . != 127))' <<<"$tag_prefixes" >/dev/null 2>&1 ||
		_cloudron_monitor_error "cloudron_package.upstream_tag_prefixes for $slug must be a non-empty array of strings; control characters are forbidden." || return 1
	local releases_json=""
	releases_json=$(_cloudron_monitor_fetch_releases "$upstream_slug") || return $?
	local latest_version=""
	latest_version=$(_cloudron_monitor_latest_release_version "$releases_json" "$tag_prefixes" "$upstream_slug") || return 1
	local current_version=""
	current_version=$(jq -r '.upstreamVersion // empty' "$manifest_path") || return 1
	if [[ -n "$current_version" ]] && ! _cloudron_monitor_version_newer "$latest_version" "$current_version"; then
		return 0
	fi
	local fingerprint="upstream-v${latest_version}"
	local title="${package_title} upstream v${latest_version} is available"
	local summary=""
	local verification=""
	printf -v summary "Upstream package \`%s\` released \`v%s\`; the manifest currently records \`%s\`." \
		"$upstream_slug" "$latest_version" "${current_version:-no upstreamVersion}"
	printf -v verification "Run \`cloudron-package-helper.sh check-release v<package-version>\` after updating and testing the package."
	_cloudron_monitor_apply_finding "$apply" "$slug" "$title" "$fingerprint" "$summary" "$verification"
	return $?
}

_cloudron_monitor_compatibility_entry() {
	local entry="$1"
	local apply="$2"
	local slug=""
	local repo_path=""
	local manifest_rel=""
	local monitor_enabled=""
	slug=$(jq -r '.slug // empty' <<<"$entry")
	repo_path=$(jq -r '.path // empty' <<<"$entry")
	manifest_rel=$(jq -r '.cloudron_package.manifest // "CloudronManifest.json"' <<<"$entry")
	monitor_enabled=$(jq -r '.cloudron_package.monitor_compatibility // true' <<<"$entry")
	[[ "$monitor_enabled" == true ]] || return 0
	[[ "$slug" == */* ]] || _cloudron_monitor_error "Cloudron compatibility monitoring requires a target slug." || return 1
	[[ "$manifest_rel" != /* && "$manifest_rel" != *..* ]] || _cloudron_monitor_error "Unsafe manifest path configured for $slug." || return 1
	repo_path="${repo_path/#\~/$HOME}"
	[[ -d "$repo_path" ]] || _cloudron_monitor_error "Registered Cloudron package path is unavailable for $slug." || return 1
	local findings=""
	if findings=$(cloudron_package_compatibility_findings "$repo_path" "$manifest_rel"); then
		return 0
	fi
	[[ -n "$findings" ]] || return 1
	local checksum=""
	checksum=$(printf '%s\n' "$findings" | cksum | awk '{ print $1 }')
	local fingerprint="compatibility-${checksum}"
	local title="Cloudron package compatibility audit found actionable drift"
	local summary=""
	local verification=""
	printf -v summary 'The weekly compatibility audit reported:\n\n%s' "$findings"
	printf -v verification "Run \`cloudron-package-helper.sh check-compatibility\` and the package-specific test suite."
	_cloudron_monitor_apply_finding "$apply" "$slug" "$title" "$fingerprint" "$summary" "$verification"
	return $?
}

_cloudron_monitor_run() {
	local mode="$1"
	local apply="$2"
	local failures=0
	local entry=""
	local entry_rc=0
	while IFS= read -r entry; do
		entry_rc=0
		if [[ "$mode" == "upstream" ]]; then
			_cloudron_monitor_upstream_entry "$entry" "$apply" || entry_rc=$?
		else
			_cloudron_monitor_compatibility_entry "$entry" "$apply" || entry_rc=$?
		fi
		if [[ "$entry_rc" -eq 75 ]]; then
			return 75
		fi
		[[ "$entry_rc" -eq 0 ]] || failures=$((failures + 1))
	done < <(jq -c '.initialized_repos[] | select(.maintenance != false and .app_type == "cloudron-package")' "$REPOS_FILE")
	[[ "$failures" -eq 0 ]] || return 1
	return 0
}

show_help() {
	cat <<'HELP'
Cloudron Package Monitor

Usage:
  cloudron-package-monitor-helper.sh upstream [--apply]
  cloudron-package-monitor-helper.sh compatibility [--apply]

Without --apply, findings are reported without creating issues. With --apply,
deduplicated issues are created in each registered package repository after an
ADMIN/MAINTAIN permission check. No package source or release state is changed.
HELP
	return 0
}

main() {
	local mode="${1:-help}"
	local apply=false
	[[ "${2:-}" == "--apply" ]] && apply=true
	case "$mode" in
	upstream | compatibility)
		_cloudron_monitor_require_tools || return 1
		_cloudron_monitor_run "$mode" "$apply"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		_cloudron_monitor_error "Unknown command: $mode" || true
		show_help
		return 1
		;;
	esac
	return $?
}

main "$@"
