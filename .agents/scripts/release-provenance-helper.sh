#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=release-authorization-manifest-helper.sh
source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"
_RELEASE_PROVENANCE_TAG_REF_PREFIX="refs/tags/"
_RELEASE_PROVENANCE_SCOPE_REMOTE="remote"
_RELEASE_PROVENANCE_SCOPE_LOCAL_SOURCE="local-source"

_release_provenance_error() {
	local message="$1"
	printf 'release-provenance: %s\n' "$message" >&2
	return 1
}

_release_provenance_usage() {
	cat <<'USAGE'
Usage:
  release-provenance-helper.sh verify --tag TAG --repo OWNER/REPO [--branch BRANCH]
  release-provenance-helper.sh verify-local-source --tag TAG --repo OWNER/REPO [--branch BRANCH]
  release-provenance-helper.sh resolve-authorization --source-pr PR --repo OWNER/REPO [--branch BRANCH] [--expected-sources PR[,PR...]]
  release-provenance-helper.sh resolve-tag-authorization --tag TAG --source-pr PR --repo OWNER/REPO [--branch BRANCH] [--expected-sources PR@SHA[,PR@SHA...]]
  release-provenance-helper.sh resolve-tag-expected-sources --tag TAG --source-pr PR --repo OWNER/REPO [--branch BRANCH] [--expected-sources PR@SHA[,PR@SHA...]]
  release-provenance-helper.sh resolve-source --source-pr PR --repo OWNER/REPO [--branch BRANCH] [--expected-sources PR[,PR...]]

Verifies that a release tag is signed, version-consistent, reachable from the
canonical branch, and bound to a merged source PR through immutable tag trailers.
The local-source mode omits remote-tag and canonical-branch reachability checks;
callers must pair it with exact protected-release PR and ancestry verification.
USAGE
	return 0
}

_release_provenance_commit_trailers() {
	local commit_sha="$1"
	git log -1 --format='%B' "$commit_sha" 2>/dev/null | git interpret-trailers --parse
	return "${PIPESTATUS[0]}"
}

_release_provenance_trailer_values_at_commit() {
	local commit_sha="$1"
	local trailer_key="$2"
	_release_provenance_commit_trailers "$commit_sha" |
		awk -v prefix="${trailer_key}: " 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }'
	return "${PIPESTATUS[0]}"
}

_release_provenance_trailer_values() {
	local tag_name="$1"
	local trailer_key="$2"
	git for-each-ref --format='%(contents:body)' "${_RELEASE_PROVENANCE_TAG_REF_PREFIX}${tag_name}" |
		awk -v prefix="${trailer_key}: " 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }'
	return "${PIPESTATUS[0]}"
}

_release_provenance_pr_json() {
	local repo_slug="$1"
	local pr_number="$2"
	gh pr view "$pr_number" --repo "$repo_slug" \
		--json state,mergedAt,mergeCommit,baseRefName,headRefOid 2>/dev/null
	return $?
}

_release_provenance_verify_pr_record() {
	local repo_slug="$1"
	local branch_name="$2"
	local pr_number="$3"
	local merge_sha="$4"
	local descendant="$5"
	local pr_json=""

	[[ "$pr_number" =~ ^[0-9]+$ && "$merge_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	pr_json=$(_release_provenance_pr_json "$repo_slug" "$pr_number") || {
		_release_provenance_error "cannot read source PR #${pr_number}"
		return 1
	}
	if ! jq -e --arg branch "$branch_name" --arg merge "$merge_sha" '
		.state == "MERGED"
		and ((.mergedAt // "") | length > 0)
		and ((.headRefOid // "") | length > 0)
		and .baseRefName == $branch
		and .mergeCommit.oid == $merge
	' <<<"$pr_json" >/dev/null; then
		_release_provenance_error "source PR #${pr_number} does not match recorded merge provenance"
		return 1
	fi
	if ! git merge-base --is-ancestor "$merge_sha" "$descendant" 2>/dev/null; then
		_release_provenance_error "source PR #${pr_number} merge is not an ancestor of ${descendant}"
		return 1
	fi
	return 0
}

_release_provenance_expected_sources() {
	local requested_pr="$1"
	local raw_sources="$2"
	local repo_slug="$3"
	local branch_name="$4"
	local release_head="$5"
	local intent_json=""
	local expected_json='[]'
	local entry=""
	local entry_pr=""
	local entry_merge=""
	[[ -n "$raw_sources" ]] || raw_sources="$requested_pr"
	intent_json=$(release_authorization_intent_json "$raw_sources") || {
		_release_provenance_error "expected source set is malformed or contains duplicate PRs"
		return 1
	}
	while IFS=$'\t' read -r entry_pr entry_merge; do
		[[ "$entry_pr" =~ ^[0-9]+$ ]] || return 1
		if [[ -z "$entry_merge" || "$entry_merge" == "null" ]]; then
			entry=$(_release_provenance_pr_json "$repo_slug" "$entry_pr") || return 1
			entry_merge=$(jq -er '.mergeCommit.oid // empty' <<<"$entry" 2>/dev/null) || return 1
		fi
		_release_provenance_verify_pr_record "$repo_slug" "$branch_name" "$entry_pr" "$entry_merge" "$release_head" || return 1
		expected_json=$(jq -c --argjson pr "$entry_pr" --arg merge "$entry_merge" '. + [{pr:$pr,merge:$merge}]' <<<"$expected_json") || return 1
	done < <(jq -r '.[] | [.pr, (.merge // "")] | @tsv' <<<"$intent_json")
	jq -c 'sort_by(.pr)' <<<"$expected_json"
	return $?
}

_release_provenance_assert_expected_sources() {
	local expected_json="$1"
	local observed_json="$2"
	if [[ "$(jq -c 'sort_by(.pr)' <<<"$expected_json")" != "$(jq -c 'sort_by(.pr)' <<<"$observed_json")" ]]; then
		_release_provenance_error "observed release source manifest does not exactly match the trusted expected source set"
		return 1
	fi
	return 0
}

_release_provenance_resolve_authorization() {
	local requested_pr="$1"
	local raw_sources="$2"
	local repo_slug="$3"
	local branch_name="$4"
	local release_head=""
	local expected_sources_json=""
	[[ "$requested_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$repo_slug" =~ ^[^/]+/[^/]+$ && "$branch_name" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
	release_head=$(git rev-parse HEAD 2>/dev/null) || return 1
	[[ "$release_head" == "$(git rev-parse "origin/${branch_name}" 2>/dev/null)" ]] || return 1
	expected_sources_json=$(_release_provenance_expected_sources "$requested_pr" "$raw_sources" \
		"$repo_slug" "$branch_name" "$release_head") || return 1
	jq -cn --argjson expected "$expected_sources_json" '{expected_sources:$expected}'
	return $?
}

_release_provenance_resolve_tag_authorization() {
	local tag_name="$1"
	local requested_pr="$2"
	local raw_sources="$3"
	local repo_slug="$4"
	local branch_name="$5"
	local release_head=""
	local tag_commit=""
	local expected_sources_json=""
	local source_json=""
	local observed_sources_json=""
	[[ "$tag_name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$requested_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$repo_slug" =~ ^[^/]+/[^/]+$ && "$branch_name" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
	release_head=$(git rev-parse HEAD 2>/dev/null) || return 1
	tag_commit=$(git rev-parse "refs/tags/${tag_name}^{commit}" 2>/dev/null) || return 1
	[[ "$release_head" == "$tag_commit" ]] || return 1
	_release_provenance_verify "$tag_name" "$repo_slug" "$branch_name" \
		"$_RELEASE_PROVENANCE_SCOPE_LOCAL_SOURCE" >/dev/null || return 1
	expected_sources_json=$(_release_provenance_expected_sources "$requested_pr" "$raw_sources" \
		"$repo_slug" "$branch_name" "$tag_commit") || return 1
	source_json=$(jq -cn --argjson requested_pr "$requested_pr" \
		--argjson source_pr "$_RELEASE_PROVENANCE_SOURCE_PR" \
		--arg source_merge "$_RELEASE_PROVENANCE_SOURCE_MERGE" \
		--argjson aggregated "$_RELEASE_PROVENANCE_AGGREGATED_SOURCES" '
		{mode:(if ($aggregated | length) == 0 then "direct" else "aggregate" end),
		 requested_pr:$requested_pr,source_pr:$source_pr,source_merge:$source_merge,
		 aggregated_sources:($aggregated | sort_by(.pr))}
	') || return 1
	observed_sources_json=$(release_authorization_observed_sources_json \
		"$expected_sources_json" "$source_json") || return 1
	_release_provenance_assert_expected_sources "$expected_sources_json" "$observed_sources_json" || return 1
	jq -c --argjson expected "$expected_sources_json" '. + {expected_sources:$expected}' <<<"$source_json"
	return $?
}

_release_provenance_resolve_tag_expected_sources() {
	local tag_name="$1"
	local requested_pr="$2"
	local raw_sources="$3"
	local repo_slug="$4"
	local branch_name="$5"
	local release_head=""
	local tag_commit=""
	local expected_sources_json=""

	[[ "$tag_name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$requested_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$repo_slug" =~ ^[^/]+/[^/]+$ && "$branch_name" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
	release_head=$(git rev-parse HEAD 2>/dev/null) || return 1
	tag_commit=$(git rev-parse "refs/tags/${tag_name}^{commit}" 2>/dev/null) || return 1
	[[ "$release_head" == "$tag_commit" ]] || return 1
	_release_provenance_verify "$tag_name" "$repo_slug" "$branch_name" \
		"$_RELEASE_PROVENANCE_SCOPE_LOCAL_SOURCE" >/dev/null || return 1
	expected_sources_json=$(_release_provenance_expected_sources "$requested_pr" "$raw_sources" \
		"$repo_slug" "$branch_name" "$tag_commit") || return 1
	jq -cn --argjson expected "$expected_sources_json" '{expected_sources:$expected}'
	return $?
}

_release_provenance_resolve_source() {
	local requested_pr="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local expected_sources_raw="${4:-}"
	local release_head=""
	local requested_json=""
	local requested_merge=""
	local aggregate_pr=""
	local aggregate_entries=""
	local entry=""
	local entry_pr=""
	local entry_merge=""
	local found_requested=false
	local sources_json='[]'
	local expected_sources_json='[]'
	local source_result_json=""
	local observed_sources_json=""

	[[ "$requested_pr" =~ ^[0-9]+$ ]] || {
		_release_provenance_error "source PR is not numeric"
		return 1
	}
	[[ "$repo_slug" =~ ^[^/]+/[^/]+$ && "$branch_name" =~ ^[A-Za-z0-9._/-]+$ ]] || {
		_release_provenance_error "invalid repository or canonical branch"
		return 1
	}
	release_head=$(git rev-parse HEAD 2>/dev/null) || return 1
	[[ "$release_head" == "$(git rev-parse "origin/${branch_name}" 2>/dev/null)" ]] || {
		_release_provenance_error "release checkout is not the exact origin/${branch_name} tip"
		return 1
	}
	expected_sources_json=$(_release_provenance_expected_sources "$requested_pr" "$expected_sources_raw" \
		"$repo_slug" "$branch_name" "$release_head") || return 1
	requested_json=$(_release_provenance_pr_json "$repo_slug" "$requested_pr") || return 1
	requested_merge=$(jq -er '.mergeCommit.oid // empty' <<<"$requested_json" 2>/dev/null) || return 1
	_release_provenance_verify_pr_record "$repo_slug" "$branch_name" "$requested_pr" "$requested_merge" "$release_head" || return 1

	aggregate_pr=$(_release_provenance_trailer_values_at_commit "$release_head" "Aidevops-Release-Aggregator-PR") || return 1
	aggregate_entries=$(_release_provenance_trailer_values_at_commit "$release_head" "Aidevops-Release-Aggregates") || return 1
	if [[ -z "$aggregate_pr" && -z "$aggregate_entries" ]]; then
		if [[ "$requested_merge" == "$release_head" ]]; then
			sources_json=$(jq -cn --argjson pr "$requested_pr" --arg merge "$requested_merge" '[{pr:$pr,merge:$merge}]') || return 1
			_release_provenance_assert_expected_sources "$expected_sources_json" "$sources_json" || return 1
			jq -cn --argjson requested_pr "$requested_pr" --arg source_merge "$requested_merge" --argjson expected "$expected_sources_json" \
				'{mode:"direct",requested_pr:$requested_pr,source_pr:$requested_pr,source_merge:$source_merge,aggregated_sources:[],expected_sources:$expected}'
			return $?
		fi
		_release_provenance_error "current main tip is not an explicit release-aggregation PR"
		return 1
	fi
	[[ "$aggregate_pr" =~ ^[0-9]+$ ]] || {
		_release_provenance_error "release-aggregation PR has no immutable aggregator identity"
		return 1
	}
	[[ -n "$aggregate_entries" ]] || {
		_release_provenance_error "release-aggregation PR has no immutable source manifest"
		return 1
	}
	_release_provenance_verify_pr_record "$repo_slug" "$branch_name" "$aggregate_pr" "$release_head" "$release_head" || return 1
	if [[ "$requested_pr" == "$aggregate_pr" && "$requested_merge" == "$release_head" ]]; then
		found_requested=true
	fi
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		entry_pr="${entry%%@*}"
		entry_merge="${entry#*@}"
		[[ "$entry" == *@* && "$entry_pr" =~ ^[0-9]+$ && "$entry_merge" =~ ^[0-9a-f]{40}$ ]] || {
			_release_provenance_error "release-aggregation manifest contains malformed source ${entry}"
			return 1
		}
		[[ "$entry_pr" != "$aggregate_pr" ]] || {
			_release_provenance_error "release-aggregation PR cannot aggregate itself"
			return 1
		}
		if jq -e --argjson pr "$entry_pr" 'any(.[]; .pr == $pr)' <<<"$sources_json" >/dev/null; then
			_release_provenance_error "release-aggregation manifest repeats PR #${entry_pr}"
			return 1
		fi
		_release_provenance_verify_pr_record "$repo_slug" "$branch_name" "$entry_pr" "$entry_merge" "$release_head" || return 1
		sources_json=$(jq -c --argjson pr "$entry_pr" --arg merge "$entry_merge" '. + [{pr:$pr,merge:$merge}]' <<<"$sources_json") || return 1
		if [[ "$entry_pr" == "$requested_pr" && "$entry_merge" == "$requested_merge" ]]; then
			found_requested=true
		fi
	done <<<"$aggregate_entries"
	[[ "$found_requested" == true ]] || {
		_release_provenance_error "release-aggregation manifest does not authorize requested PR #${requested_pr}"
		return 1
	}
	sources_json=$(jq -c 'sort_by(.pr)' <<<"$sources_json") || return 1
	source_result_json=$(jq -cn --argjson requested_pr "$requested_pr" --argjson source_pr "$aggregate_pr" \
		--arg source_merge "$release_head" --argjson sources "$sources_json" \
		'{mode:"aggregate",requested_pr:$requested_pr,source_pr:$source_pr,source_merge:$source_merge,aggregated_sources:$sources}') || return 1
	observed_sources_json=$(release_authorization_observed_sources_json "$expected_sources_json" "$source_result_json") || return 1
	_release_provenance_assert_expected_sources "$expected_sources_json" "$observed_sources_json" || return 1
	jq -c --argjson expected "$expected_sources_json" '. + {expected_sources:$expected}' <<<"$source_result_json"
	return $?
}

_release_provenance_trailer() {
	local tag_name="$1"
	local trailer_key="$2"
	local trailer_value=""

	trailer_value=$(git for-each-ref --format='%(contents:body)' "${_RELEASE_PROVENANCE_TAG_REF_PREFIX}${tag_name}" |
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
	local tag_parent=""

	_release_provenance_verify_pr_record "$repo_slug" "$branch_name" "$source_pr" "$source_merge" "$tag_commit" || return 1
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
_RELEASE_PROVENANCE_AGGREGATED_SOURCES='[]'

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
	local tag_ref="${_RELEASE_PROVENANCE_TAG_REF_PREFIX}${tag_name}"
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
	local aggregate_entry=""
	local aggregate_pr=""
	local aggregate_merge=""

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
	while IFS= read -r aggregate_entry; do
		[[ -n "$aggregate_entry" ]] || continue
		aggregate_pr="${aggregate_entry%%@*}"
		aggregate_merge="${aggregate_entry#*@}"
		[[ "$aggregate_entry" == *@* && "$aggregate_pr" =~ ^[0-9]+$ && "$aggregate_merge" =~ ^[0-9a-f]{40}$ ]] || {
			_release_provenance_error "tag contains malformed aggregated source ${aggregate_entry}"
			return 1
		}
		if jq -e --argjson pr "$aggregate_pr" 'any(.[]; .pr == $pr)' <<<"$_RELEASE_PROVENANCE_AGGREGATED_SOURCES" >/dev/null; then
			_release_provenance_error "tag repeats aggregated source PR #${aggregate_pr}"
			return 1
		fi
		_RELEASE_PROVENANCE_AGGREGATED_SOURCES=$(jq -c --argjson pr "$aggregate_pr" --arg merge "$aggregate_merge" \
			'. + [{pr:$pr,merge:$merge}]' <<<"$_RELEASE_PROVENANCE_AGGREGATED_SOURCES") || return 1
	done < <(_release_provenance_trailer_values "$tag_name" "Aidevops-Aggregated-Source")
	return 0
}

_release_provenance_verify_aggregate_manifest() {
	local repo_slug="$1"
	local branch_name="$2"
	local source_pr="$_RELEASE_PROVENANCE_SOURCE_PR"
	local source_merge="$_RELEASE_PROVENANCE_SOURCE_MERGE"
	local manifest_pr=""
	local manifest_entries=""
	local manifest_json='[]'
	local entry=""
	local entry_pr=""
	local entry_merge=""

	manifest_pr=$(_release_provenance_trailer_values_at_commit "$source_merge" "Aidevops-Release-Aggregator-PR") || return 1
	manifest_entries=$(_release_provenance_trailer_values_at_commit "$source_merge" "Aidevops-Release-Aggregates") || return 1
	if [[ -z "$manifest_pr" && -z "$manifest_entries" && "$_RELEASE_PROVENANCE_AGGREGATED_SOURCES" == '[]' ]]; then
		return 0
	fi
	[[ "$manifest_pr" == "$source_pr" && -n "$manifest_entries" ]] || {
		_release_provenance_error "tag aggregation provenance does not match its direct source PR"
		return 1
	}
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		entry_pr="${entry%%@*}"
		entry_merge="${entry#*@}"
		[[ "$entry" == *@* && "$entry_pr" =~ ^[0-9]+$ && "$entry_merge" =~ ^[0-9a-f]{40}$ ]] || return 1
		[[ "$entry_pr" != "$source_pr" ]] || {
			_release_provenance_error "release-aggregation PR cannot aggregate itself"
			return 1
		}
		if jq -e --argjson pr "$entry_pr" 'any(.[]; .pr == $pr)' <<<"$manifest_json" >/dev/null; then
			_release_provenance_error "release-aggregation manifest repeats PR #${entry_pr}"
			return 1
		fi
		_release_provenance_verify_pr_record "$repo_slug" "$branch_name" "$entry_pr" "$entry_merge" "$source_merge" || return 1
		manifest_json=$(jq -c --argjson pr "$entry_pr" --arg merge "$entry_merge" '. + [{pr:$pr,merge:$merge}]' <<<"$manifest_json") || return 1
	done <<<"$manifest_entries"
	if [[ "$_RELEASE_PROVENANCE_AGGREGATED_SOURCES" == '[]' ]]; then
		# A signed source-merge SHA transitively binds this reviewed manifest.
		# Recover only a completely omitted redundant tag list; any explicit
		# partial or conflicting list remains a hard failure below.
		_RELEASE_PROVENANCE_AGGREGATED_SOURCES="$manifest_json"
		return 0
	fi
	if [[ "$(jq -cS 'sort_by(.pr)' <<<"$manifest_json")" != "$(jq -cS 'sort_by(.pr)' <<<"$_RELEASE_PROVENANCE_AGGREGATED_SOURCES")" ]]; then
		_release_provenance_error "tag aggregated sources differ from the reviewed aggregation manifest"
		return 1
	fi
	return 0
}

_release_provenance_verify() {
	local tag_name="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local verification_scope="${4:-$_RELEASE_PROVENANCE_SCOPE_REMOTE}"
	local verification_label=""

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
	[[ "$verification_scope" == "$_RELEASE_PROVENANCE_SCOPE_REMOTE" ||
		"$verification_scope" == "$_RELEASE_PROVENANCE_SCOPE_LOCAL_SOURCE" ]] || return 1
	_release_provenance_verify_versions "$tag_name" || return 1
	_release_provenance_verify_local_tag "$tag_name" || return 1
	_release_provenance_load_trailers "$tag_name" || return 1

	git fetch origin "$branch_name" --quiet 2>/dev/null || {
		_release_provenance_error "cannot refresh origin/${branch_name}"
		return 1
	}
	if [[ "$verification_scope" == "$_RELEASE_PROVENANCE_SCOPE_REMOTE" ]] &&
		! git merge-base --is-ancestor "$_RELEASE_PROVENANCE_TAG_COMMIT" "origin/${branch_name}" 2>/dev/null; then
		_release_provenance_error "release tag commit is not reachable from origin/${branch_name}"
		return 1
	fi
	_release_provenance_verify_source_pr \
		"$repo_slug" "$branch_name" "$_RELEASE_PROVENANCE_SOURCE_PR" \
		"$_RELEASE_PROVENANCE_SOURCE_MERGE" "$_RELEASE_PROVENANCE_TAG_COMMIT" || return 1
	_release_provenance_verify_aggregate_manifest "$repo_slug" "$branch_name" || return 1
	if [[ "$verification_scope" == "$_RELEASE_PROVENANCE_SCOPE_REMOTE" ]]; then
		_release_provenance_verify_github_tag \
			"$repo_slug" "$tag_name" "$_RELEASE_PROVENANCE_TAG_COMMIT" \
			"$_RELEASE_PROVENANCE_TAG_OBJECT" || return 1
	fi
	[[ "$verification_scope" != "$_RELEASE_PROVENANCE_SCOPE_LOCAL_SOURCE" ]] ||
		verification_label=" local source"

	printf 'release-provenance: verified %s%s at %s from PR #%s\n' \
		"$tag_name" "$verification_label" \
		"$_RELEASE_PROVENANCE_TAG_COMMIT" "$_RELEASE_PROVENANCE_SOURCE_PR"
	return 0
}

main() {
	local command="${1:-}"
	shift || true
	local tag_name=""
	local repo_slug=""
	local branch_name="main"
	local source_pr=""
	local expected_sources=""

	case "$command" in
	verify | verify-local-source | resolve-authorization | resolve-tag-authorization | resolve-tag-expected-sources | resolve-source) ;;
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
		--source-pr)
			source_pr="${1:-}"
			shift || true
			;;
		--expected-sources)
			expected_sources="${1:-}"
			shift || true
			;;
		*) return 1 ;;
		esac
	done

	[[ -n "$repo_slug" && -n "$branch_name" ]] || return 1
	if [[ "$command" == "resolve-authorization" ]]; then
		[[ -n "$source_pr" ]] || return 1
		_release_provenance_resolve_authorization "$source_pr" "$expected_sources" "$repo_slug" "$branch_name"
		return $?
	fi
	if [[ "$command" == "resolve-tag-authorization" ]]; then
		[[ -n "$tag_name" && -n "$source_pr" ]] || return 1
		_release_provenance_resolve_tag_authorization "$tag_name" "$source_pr" "$expected_sources" "$repo_slug" "$branch_name"
		return $?
	fi
	if [[ "$command" == "resolve-tag-expected-sources" ]]; then
		[[ -n "$tag_name" && -n "$source_pr" ]] || return 1
		_release_provenance_resolve_tag_expected_sources "$tag_name" "$source_pr" "$expected_sources" "$repo_slug" "$branch_name"
		return $?
	fi
	if [[ "$command" == "resolve-source" ]]; then
		[[ -n "$source_pr" ]] || return 1
		_release_provenance_resolve_source "$source_pr" "$repo_slug" "$branch_name" "$expected_sources"
		return $?
	fi
	[[ -n "$tag_name" ]] || return 1
	if [[ "$command" == "verify-local-source" ]]; then
		_release_provenance_verify "$tag_name" "$repo_slug" "$branch_name" \
			"$_RELEASE_PROVENANCE_SCOPE_LOCAL_SOURCE"
		return $?
	fi
	_release_provenance_verify "$tag_name" "$repo_slug" "$branch_name" \
		"$_RELEASE_PROVENANCE_SCOPE_REMOTE"
	return $?
}

main "$@"
