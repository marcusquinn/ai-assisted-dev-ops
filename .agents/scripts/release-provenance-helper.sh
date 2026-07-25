#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

_release_provenance_error() {
	local message="$1"
	printf 'release-provenance: %s\n' "$message" >&2
	return 1
}

_release_provenance_usage() {
	cat <<'USAGE'
Usage:
  release-provenance-helper.sh verify --tag TAG --repo OWNER/REPO [--branch BRANCH]

Verifies that a release tag is signed, version-consistent, reachable from the
canonical branch, and bound to a merged source PR through immutable tag trailers.
USAGE
	return 0
}

_release_provenance_trailer() {
	local tag_name="$1"
	local trailer_key="$2"
	local trailer_value=""

	trailer_value=$(git for-each-ref --format='%(contents:body)' "refs/tags/${tag_name}" |
		awk -v prefix="${trailer_key}: " 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }')
	[[ -n "$trailer_value" ]] || return 1
	printf '%s\n' "$trailer_value"
	return 0
}

_release_provenance_verify_github_tag() {
	local repo_slug="$1"
	local tag_name="$2"
	local tag_commit="$3"
	local local_tag_object="$4"
	local ref_json=""
	local tag_object_sha=""
	local tag_json=""

	ref_json=$(gh api "repos/${repo_slug}/git/ref/tags/${tag_name}" 2>/dev/null) || {
		_release_provenance_error "cannot read GitHub tag ref ${tag_name}"
		return 1
	}
	if ! jq -e '.object.type == "tag" and (.object.sha | type == "string" and length > 0)' <<<"$ref_json" >/dev/null; then
		_release_provenance_error "${tag_name} is not an annotated GitHub tag"
		return 1
	fi
	tag_object_sha=$(jq -r '.object.sha' <<<"$ref_json")
	[[ "$tag_object_sha" == "$local_tag_object" ]] || {
		_release_provenance_error "local and GitHub tag objects differ for ${tag_name}"
		return 1
	}
	tag_json=$(gh api "repos/${repo_slug}/git/tags/${tag_object_sha}" 2>/dev/null) || {
		_release_provenance_error "cannot read GitHub tag object ${tag_name}"
		return 1
	}
	if ! jq -e --arg tag "$tag_name" --arg commit "$tag_commit" '
		.tag == $tag
		and .object.type == "commit"
		and .object.sha == $commit
		and .verification.verified == true
	' <<<"$tag_json" >/dev/null; then
		_release_provenance_error "${tag_name} is unsigned, unverified, or targets the wrong commit"
		return 1
	fi
	return 0
}

_release_provenance_verify_source_pr() {
	local repo_slug="$1"
	local branch_name="$2"
	local source_pr="$3"
	local source_merge="$4"
	local tag_commit="$5"
	local pr_json=""
	local tag_parent=""

	pr_json=$(gh pr view "$source_pr" --repo "$repo_slug" \
		--json state,mergedAt,mergeCommit,baseRefName 2>/dev/null) || {
		_release_provenance_error "cannot read source PR #${source_pr}"
		return 1
	}
	if ! jq -e --arg branch "$branch_name" --arg merge "$source_merge" '
		.state == "MERGED"
		and ((.mergedAt // "") | length > 0)
		and .baseRefName == $branch
		and .mergeCommit.oid == $merge
	' <<<"$pr_json" >/dev/null; then
		_release_provenance_error "source PR #${source_pr} does not match recorded merge provenance"
		return 1
	fi
	if ! git merge-base --is-ancestor "$source_merge" "$tag_commit" 2>/dev/null; then
		_release_provenance_error "recorded source merge is not an ancestor of ${tag_commit}"
		return 1
	fi
	tag_parent=$(git rev-parse "${tag_commit}^" 2>/dev/null) || {
		_release_provenance_error "release commit has no source parent"
		return 1
	}
	[[ "$source_merge" == "$tag_parent" ]] || {
		_release_provenance_error "recorded source merge is not the direct release parent"
		return 1
	}
	return 0
}

_RELEASE_PROVENANCE_VERSION=""
_RELEASE_PROVENANCE_TAG_COMMIT=""
_RELEASE_PROVENANCE_TAG_OBJECT=""
_RELEASE_PROVENANCE_SOURCE_PR=""
_RELEASE_PROVENANCE_SOURCE_MERGE=""

_release_provenance_verify_versions() {
	local tag_name="$1"
	local version=""
	local expected_tag=""
	local package_version=""

	[[ -f VERSION ]] || {
		_release_provenance_error "VERSION is missing"
		return 1
	}
	IFS= read -r version <VERSION || {
		_release_provenance_error "cannot read VERSION"
		return 1
	}
	expected_tag="v${version}"
	[[ "$tag_name" == "$expected_tag" ]] || {
		_release_provenance_error "tag ${tag_name} does not match VERSION ${version}"
		return 1
	}
	if [[ -f package.json ]]; then
		package_version=$(jq -er '.version' package.json 2>/dev/null) || {
			_release_provenance_error "cannot read package.json version"
			return 1
		}
		[[ "$package_version" == "$version" ]] || {
			_release_provenance_error "package.json ${package_version} does not match VERSION ${version}"
			return 1
		}
	fi
	_RELEASE_PROVENANCE_VERSION="$version"
	return 0
}

_release_provenance_verify_local_tag() {
	local tag_name="$1"
	local tag_ref="refs/tags/${tag_name}"
	local tag_type=""
	local tag_object=""
	local tag_commit=""
	local head_commit=""
	local commit_subject=""

	tag_type=$(git cat-file -t "$tag_ref" 2>/dev/null) || {
		_release_provenance_error "local tag ${tag_name} is missing"
		return 1
	}
	[[ "$tag_type" == "tag" ]] || {
		_release_provenance_error "${tag_name} must be annotated"
		return 1
	}
	tag_object=$(git rev-parse "$tag_ref" 2>/dev/null) || {
		_release_provenance_error "cannot resolve ${tag_name} tag object"
		return 1
	}
	tag_commit=$(git rev-parse "${tag_ref}^{commit}" 2>/dev/null) || {
		_release_provenance_error "cannot resolve ${tag_name} commit"
		return 1
	}
	head_commit=$(git rev-parse HEAD 2>/dev/null) || {
		_release_provenance_error "cannot resolve HEAD"
		return 1
	}
	[[ "$head_commit" == "$tag_commit" ]] || {
		_release_provenance_error "checkout HEAD does not equal ${tag_name} commit"
		return 1
	}
	commit_subject=$(git log -1 --format='%s' "$tag_commit" 2>/dev/null) || {
		_release_provenance_error "cannot read release commit"
		return 1
	}
	[[ "$commit_subject" == "chore(release): bump version to ${_RELEASE_PROVENANCE_VERSION}" ]] || {
		_release_provenance_error "tag does not target the expected release bump commit"
		return 1
	}
	_RELEASE_PROVENANCE_TAG_COMMIT="$tag_commit"
	_RELEASE_PROVENANCE_TAG_OBJECT="$tag_object"
	return 0
}

_release_provenance_load_trailers() {
	local tag_name="$1"
	local recorded_version=""
	local source_pr=""
	local source_merge=""

	recorded_version=$(_release_provenance_trailer "$tag_name" "Aidevops-Version") || {
		_release_provenance_error "tag lacks Aidevops-Version provenance"
		return 1
	}
	source_pr=$(_release_provenance_trailer "$tag_name" "Aidevops-Source-PR") || {
		_release_provenance_error "tag lacks Aidevops-Source-PR provenance"
		return 1
	}
	source_merge=$(_release_provenance_trailer "$tag_name" "Aidevops-Source-Merge") || {
		_release_provenance_error "tag lacks Aidevops-Source-Merge provenance"
		return 1
	}
	[[ "$recorded_version" == "$_RELEASE_PROVENANCE_VERSION" ]] || {
		_release_provenance_error "recorded tag version does not match VERSION"
		return 1
	}
	[[ "$source_pr" =~ ^[0-9]+$ ]] || {
		_release_provenance_error "source PR is not numeric"
		return 1
	}
	[[ "$source_merge" =~ ^[0-9a-f]{40}$ ]] || {
		_release_provenance_error "source merge is not a full commit SHA"
		return 1
	}
	_RELEASE_PROVENANCE_SOURCE_PR="$source_pr"
	_RELEASE_PROVENANCE_SOURCE_MERGE="$source_merge"
	return 0
}

_release_provenance_verify() {
	local tag_name="$1"
	local repo_slug="$2"
	local branch_name="$3"

	[[ "$tag_name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
		_release_provenance_error "tag must be a complete semantic version"
		return 1
	}
	[[ "$repo_slug" =~ ^[^/]+/[^/]+$ ]] || {
		_release_provenance_error "repository must be OWNER/REPO"
		return 1
	}
	[[ "$branch_name" =~ ^[A-Za-z0-9._/-]+$ ]] || {
		_release_provenance_error "invalid canonical branch"
		return 1
	}
	_release_provenance_verify_versions "$tag_name" || return 1
	_release_provenance_verify_local_tag "$tag_name" || return 1
	_release_provenance_load_trailers "$tag_name" || return 1

	git fetch origin "$branch_name" --quiet 2>/dev/null || {
		_release_provenance_error "cannot refresh origin/${branch_name}"
		return 1
	}
	if ! git merge-base --is-ancestor "$_RELEASE_PROVENANCE_TAG_COMMIT" "origin/${branch_name}" 2>/dev/null; then
		_release_provenance_error "release tag commit is not reachable from origin/${branch_name}"
		return 1
	fi
	_release_provenance_verify_source_pr \
		"$repo_slug" "$branch_name" "$_RELEASE_PROVENANCE_SOURCE_PR" \
		"$_RELEASE_PROVENANCE_SOURCE_MERGE" "$_RELEASE_PROVENANCE_TAG_COMMIT" || return 1
	_release_provenance_verify_github_tag \
		"$repo_slug" "$tag_name" "$_RELEASE_PROVENANCE_TAG_COMMIT" \
		"$_RELEASE_PROVENANCE_TAG_OBJECT" || return 1

	printf 'release-provenance: verified %s at %s from PR #%s\n' \
		"$tag_name" "$_RELEASE_PROVENANCE_TAG_COMMIT" "$_RELEASE_PROVENANCE_SOURCE_PR"
	return 0
}

main() {
	local command="${1:-}"
	shift || true
	local tag_name=""
	local repo_slug=""
	local branch_name="main"

	case "$command" in
	verify) ;;
	help | --help | -h)
		_release_provenance_usage
		return 0
		;;
	*)
		_release_provenance_usage >&2
		return 1
		;;
	esac

	while [[ $# -gt 0 ]]; do
		local option="$1"
		shift
		case "$option" in
		--tag)
			tag_name="${1:-}"
			shift || true
			;;
		--repo)
			repo_slug="${1:-}"
			shift || true
			;;
		--branch)
			branch_name="${1:-}"
			shift || true
			;;
		*) return 1 ;;
		esac
	done

	[[ -n "$tag_name" && -n "$repo_slug" && -n "$branch_name" ]] || return 1
	_release_provenance_verify "$tag_name" "$repo_slug" "$branch_name"
	return $?
}

main "$@"
