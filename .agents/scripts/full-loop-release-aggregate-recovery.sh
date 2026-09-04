#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Transactional recovery for a signed release tag that never reached a remote.

[[ -n "${_FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED:-}" ]] && return 0
_FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED=1

_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT=""
_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED=""
_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH=""
_FULL_LOOP_AGGREGATE_RECOVERY_LANE_SNAPSHOT=""
_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON=""
_FULL_LOOP_AGGREGATE_RECOVERY_EXISTING_CONTEXT="none"
_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_PR=""
_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_MERGE=""
_FULL_LOOP_FAILED_PREPUBLICATION_TAG=""
_FULL_LOOP_RESERVED_RECOVERY_PHASE=""
_FULL_LOOP_RESERVED_RECOVERY_LANE_SOURCES=""
_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION="false"
_FULL_LOOP_AGGREGATE_RECOVERY_MANIFEST_JQ='sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")'
_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX='^[0-9a-f]{40}$'
_FULL_LOOP_AGGREGATE_RECOVERY_JSON_STRING_TYPE="string"
_FULL_LOOP_AGGREGATE_RECOVERY_PHASE="aggregation-recovery"
_FULL_LOOP_AGGREGATE_COMMIT_PHASE="aggregate-publication-committing"
_FULL_LOOP_FAILED_PREPUBLICATION_PHASE="reconcile-required"
_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX="refs/tags/"
_FULL_LOOP_AGGREGATE_RECOVERY_MAIN_BRANCH="main"

_full_loop_recovery_http_status() {
	local endpoint="$1"
	local response=""
	local status_line=""
	local status_code=""
	response=$(gh api --include --silent "$endpoint" 2>/dev/null || true)
	status_line="${response%%$'\n'*}"
	status_code=$(printf '%s' "$status_line" | cut -d ' ' -f 2)
	[[ "$status_code" =~ ^[0-9]{3}$ ]] || return 1
	printf '%s\n' "$status_code"
	return 0
}

_full_loop_recovery_verify_github_release_absent() {
	local repo="$1"
	local tag_name="$2"
	local status_code=""
	status_code=$(_full_loop_recovery_http_status "repos/${repo}/releases/tags/${tag_name}") || return 1
	[[ "$status_code" == "404" ]] || {
		printf 'Aggregate recovery refused: GitHub release state for %s is HTTP %s\n' "$tag_name" "$status_code" >&2
		return 1
	}
	return 0
}

_full_loop_recovery_verify_npm_absent() {
	local tag_name="$1"
	local version="${tag_name#v}"
	local npm_error=""
	command -v npm >/dev/null 2>&1 || return 1
	if npm_error=$(npm view "aidevops@${version}" version --json 2>&1); then
		printf 'Aggregate recovery refused: npm already contains aidevops@%s\n' "$version" >&2
		return 1
	fi
	[[ "$npm_error" == *"E404"* || "$npm_error" == *'"code":"E404"'* || "$npm_error" == *"404 Not Found"* ]] || return 1
	npm view aidevops version --json >/dev/null 2>&1 || return 1
	return 0
}

_full_loop_recovery_verify_homebrew_absent() {
	local repo="$1"
	local tag_name="$2"
	local owner="${repo%%/*}"
	local formula=""
	formula=$(gh api "repos/${owner}/homebrew-tap/contents/Formula/aidevops.rb" \
		--jq '.content | @base64d' 2>/dev/null) || return 1
	if [[ "$formula" == *"$tag_name"* ]]; then
		printf 'Aggregate recovery refused: Homebrew already references %s\n' "$tag_name" >&2
		return 1
	fi
	return 0
}

_full_loop_recovery_verify_all_remote_tags_absent() {
	local tag_name="$1"
	local tag_ref="${_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX}${tag_name}"
	local remotes=""
	local remote=""
	local remote_rc=0
	remotes=$(git -C "$REPO_ROOT" remote) || return 1
	[[ -n "$remotes" ]] || return 1
	while IFS= read -r remote; do
		[[ -n "$remote" ]] || continue
		remote_rc=0
		git -C "$REPO_ROOT" ls-remote -q --exit-code --tags "$remote" "$tag_ref" >/dev/null 2>&1 || remote_rc=$?
		[[ "$remote_rc" -eq 2 ]] || return 1
	done <<<"$remotes"
	return 0
}

_full_loop_recovery_verify_channels_absent() {
	local repo="$1"
	local tag_name="$2"
	_full_loop_recovery_verify_all_remote_tags_absent "$tag_name" || return 1
	_full_loop_recovery_verify_github_release_absent "$repo" "$tag_name" || return 1
	_full_loop_recovery_verify_npm_absent "$tag_name" || return 1
	_full_loop_recovery_verify_homebrew_absent "$repo" "$tag_name" || return 1
	return 0
}

_full_loop_recovery_source_matches_authorization() {
	local authorization="$1"
	local source_json="$2"
	local authorization_json=""
	local observed_json=""
	local observed_sources=""
	authorization_json=$(release_authorization_manifest_json "$authorization") || return 1
	observed_json=$(release_authorization_observed_sources_json "$authorization_json" "$source_json") || return 1
	observed_sources=$(jq -r "$_FULL_LOOP_AGGREGATE_RECOVERY_MANIFEST_JQ" \
		<<<"$observed_json") || return 1
	release_authorization_compare "$authorization" "$observed_sources"
	return $?
}

_full_loop_recovery_record_authorization() {
	local record="$1"
	local expected_json=""
	expected_json=$(jq -ce '.expected_sources | sort_by(.pr)' <<<"$record") || return 1
	jq -r "$_FULL_LOOP_AGGREGATE_RECOVERY_MANIFEST_JQ" <<<"$expected_json"
	return $?
}

_full_loop_recovery_lane_intent_matches_authorization() {
	local lane_sources="$1"
	local authorization="$2"
	local lane_intent_json=""
	local authorization_json=""
	[[ "$lane_sources" == "$authorization" ]] && return 0
	lane_intent_json=$(release_authorization_intent_json "$lane_sources") || return 1
	authorization_json=$(release_authorization_manifest_json "$authorization") || return 1
	jq -e --argjson lane_intent "$lane_intent_json" --argjson authorized "$authorization_json" '
		all($lane_intent[]; .merge == null)
		and ([$lane_intent[].pr] | sort) == ([$authorized[].pr] | sort)
	' <<<"$authorization_json" >/dev/null
	return $?
}

#aidevops:trust-boundary
_full_loop_recovery_validate_interrupted_publication_intent() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local source_json="$4"
	local current_authorization=""
	local previous_record=""
	local previous_authorization=""
	local lane_previous=""
	local lane_previous_sources=""
	local provisional_tag_object=""
	local phase=""
	local lane_expected=""
	local refresh_previous=""
	local refresh_pending=""
	[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" =~ $_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX ]] || return 1
	[[ -n "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
	current_authorization=$(_full_loop_read_release_authorization "$repo" "$source_pr") || return 1
	previous_record=$(_full_loop_read_release_authorization_recovery_snapshot "$repo" "$source_pr") || return 1
	jq -e '((.aggregate_recovery // null) == null)' <<<"$previous_record" >/dev/null || return 1
	previous_authorization=$(_full_loop_recovery_record_authorization "$previous_record") || return 1
	release_authorization_subset "$previous_authorization" "$current_authorization" || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
		--arg sha40 "$_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX" \
		--arg string_type "$_FULL_LOOP_AGGREGATE_RECOVERY_JSON_STRING_TYPE" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and ((.terminal_receipt // null) == null)
		and ((.phase | type) == $string_type) and ((.expected_sources | type) == $string_type)
		and (.aggregate_recovery.provisional_tag_object | test($sha40))
		and (.aggregate_recovery.previous_state.schema_version == 1)
		and (.aggregate_recovery.previous_state.repository == .repository)
		and (.aggregate_recovery.previous_state.active == true)
		and (.aggregate_recovery.previous_state.source_pr == $source_pr)
		and (.aggregate_recovery.previous_state.tag == $tag)
		and ((.aggregate_recovery.previous_state.phase == "remote-publication")
			or (.aggregate_recovery.previous_state.phase == "reconcile-required"))
		and ((.aggregate_recovery.previous_state.terminal_receipt // null) == null)
		and ((.aggregate_recovery.previous_state.aggregate_recovery // null) == null)
		and ((.aggregate_recovery.previous_state.expected_sources | type) == $string_type)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	phase=$(jq -er '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	lane_expected=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	case "$phase" in
	aggregation-recovery | aggregate-publication-committing)
		[[ "$lane_expected" == "$current_authorization" ]] || return 1
		release_authorization_subset "$current_authorization" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
		;;
	aggregation-recovery-refresh)
		refresh_previous=$(jq -er '.aggregate_recovery.refresh.previous_expected_sources' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		refresh_pending=$(jq -er '.aggregate_recovery.refresh.pending_expected_sources' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		[[ "$lane_expected" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" &&
			"$refresh_pending" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
		[[ "$current_authorization" == "$refresh_previous" ||
			"$current_authorization" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
		release_authorization_subset "$previous_authorization" "$refresh_previous" || return 1
		release_authorization_subset "$refresh_previous" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
		;;
	*) return 1 ;;
	esac
	lane_previous=$(jq -ce '.aggregate_recovery.previous_state' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	lane_previous_sources=$(jq -er '.expected_sources' <<<"$lane_previous") || return 1
	_full_loop_recovery_lane_intent_matches_authorization \
		"$lane_previous_sources" "$previous_authorization" || return 1
	provisional_tag_object=$(jq -er '.aggregate_recovery.provisional_tag_object' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	if [[ "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" == "$provisional_tag_object" ]]; then
		_full_loop_recovery_source_matches_authorization "$previous_authorization" "$source_json"
		return $?
	fi
	[[ "$phase" == "$_FULL_LOOP_AGGREGATE_RECOVERY_PHASE" ||
		"$phase" == "$_FULL_LOOP_AGGREGATE_COMMIT_PHASE" ]] || return 1
	[[ "$current_authorization" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
	_full_loop_recovery_source_matches_authorization "$current_authorization" "$source_json" || return 1
	_full_loop_recovery_tag_is_bound_to_current_aggregate "$tag_name"
	return $?
}

#aidevops:trust-boundary
_full_loop_recovery_validate_receipt() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="${3:-}"
	local source_json="${4:-}"
	local receipt_path=""
	local status=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$source_pr") || return 1
	[[ -f "$receipt_path" ]] && IFS= read -r status <"$receipt_path" || true
	case "$status" in
	"" | "$_FULL_LOOP_PHASE_FAILED") return 0 ;;
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		if [[ -n "$tag_name" && -n "$source_json" ]] &&
			declare -F _full_loop_release_validate_published_reconciliation_intent >/dev/null 2>&1 &&
			_full_loop_release_validate_published_reconciliation_intent \
				"$repo" "$source_pr" "$tag_name" "$source_json"; then
			return 0
		fi
		if [[ -n "$tag_name" && -n "$source_json" ]] &&
			_full_loop_recovery_validate_interrupted_publication_intent \
				"$repo" "$source_pr" "$tag_name" "$source_json"; then
			return 0
		fi
		printf 'Aggregate recovery refused: release:not-requested lacks matching explicit publication intent\n' >&2
		return 1
		;;
	esac
	printf 'Aggregate recovery refused: release receipt is terminal (%s)\n' "$status" >&2
	return 1
}

#aidevops:trust-boundary
_full_loop_recovery_validate_reserved_receipt() {
	local repo="$1"
	local source_pr="$2"
	local receipt_path=""
	local status=""
	# This path is reachable only from a fresh explicit release command. Before
	# any tag exists, that command may replace prior not-requested evidence.
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$source_pr") || return 1
	[[ -f "$receipt_path" ]] && IFS= read -r status <"$receipt_path" || true
	case "$status" in
	"" | "$_FULL_LOOP_PHASE_FAILED" | "$_FULL_LOOP_RELEASE_NOT_REQUESTED") return 0 ;;
	esac
	printf 'Reserved release authorization migration refused: release receipt is terminal (%s)\n' \
		"$status" >&2
	return 1
}

_full_loop_recovery_failed_prepublication_refused() {
	local reason="$1"
	printf 'Failed pre-publication release recovery refused: %s\n' "$reason" >&2
	return 1
}

_full_loop_recovery_commit_trailer_values() {
	local commit_sha="$1"
	local trailer_key="$2"
	local commit_message=""
	local parsed_trailers=""
	commit_message=$(git -C "$REPO_ROOT" log -1 --format='%B' "$commit_sha" 2>/dev/null) || return 1
	parsed_trailers=$(printf '%s\n' "$commit_message" | git -C "$REPO_ROOT" interpret-trailers --parse) || return 1
	awk -v prefix="${trailer_key}: " 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' \
		<<<"$parsed_trailers"
	return $?
}

#aidevops:trust-boundary
_full_loop_recovery_resolve_failed_prepublication_evidence() {
	local repo="$1"
	local source_pr="$2"
	local requested_merge="$3"
	local release_type="$4"
	local evidence_path=""
	local evidence_json=""
	local failed_source_pr=""
	local failed_source_merge=""
	local evidence_attempted_tag=""
	local evidence_release_type=""
	local attempted_tag=""
	[[ "$source_pr" =~ ^[0-9]+$ && "$requested_merge" =~ $_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX ]] || return 1
	case "$release_type" in patch | minor | major) ;; *) return 1 ;; esac
	evidence_path=$(_full_loop_release_evidence_path "$repo" "$source_pr" failure) || return 1
	[[ -f "$evidence_path" ]] || {
		_full_loop_recovery_failed_prepublication_refused "exact failure evidence is missing"
		return 1
	}
	evidence_json=$(jq -ce --arg repo "$repo" --argjson source_pr "$source_pr" \
		--arg requested_merge "$requested_merge" --arg sha40 "$_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX" \
		--arg string_type "$_FULL_LOOP_AGGREGATE_RECOVERY_JSON_STRING_TYPE" '
		select(.schema_version == 1 and .status == "failed" and .repository == $repo
			and .requested_pr == $source_pr and .requested_merge == $requested_merge
			and ((.release_source_pr | type) == "number")
			and ((.current_head | type) == $string_type) and (.current_head | test($sha40))
			and (((.attempted_tag // null) == null and (.release_type // null) == null)
				or (((.attempted_tag | type) == $string_type and (.attempted_tag | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
					and (.release_type == "patch" or .release_type == "minor" or .release_type == "major")))
			and ((.recorded_at | type) == $string_type) and ((.recorded_at | length) > 0))
	' "$evidence_path") || {
		_full_loop_recovery_failed_prepublication_refused "failure evidence does not match the requested release"
		return 1
	}
	failed_source_pr=$(jq -er '.release_source_pr' <<<"$evidence_json") || return 1
	failed_source_merge=$(jq -er '.current_head' <<<"$evidence_json") || return 1
	evidence_attempted_tag=$(jq -r '.attempted_tag // ""' <<<"$evidence_json") || return 1
	evidence_release_type=$(jq -r '.release_type // ""' <<<"$evidence_json") || return 1
	[[ -n "$evidence_release_type" || "$release_type" == "patch" ]] || {
		_full_loop_recovery_failed_prepublication_refused "legacy failure evidence permits patch retries only"
		return 1
	}
	[[ -z "$evidence_release_type" || "$evidence_release_type" == "$release_type" ]] || {
		_full_loop_recovery_failed_prepublication_refused "failure evidence release type differs from the retry"
		return 1
	}
	attempted_tag=$(_full_loop_release_expected_tag_at_commit "$failed_source_merge" "$release_type") || {
		_full_loop_recovery_failed_prepublication_refused "attempted release tag cannot be reconstructed"
		return 1
	}
	[[ -z "$evidence_attempted_tag" || "$evidence_attempted_tag" == "$attempted_tag" ]] || {
		_full_loop_recovery_failed_prepublication_refused "failure evidence attempted tag differs from immutable source state"
		return 1
	}
	jq -cn --argjson source_pr "$failed_source_pr" --arg source_merge "$failed_source_merge" \
		--arg attempted_tag "$attempted_tag" \
		'{source_pr:$source_pr,source_merge:$source_merge,attempted_tag:$attempted_tag}'
	return $?
}

#aidevops:trust-boundary
_full_loop_recovery_validate_failed_prepublication_intent() {
	local repo="$1"
	local source_pr="$2"
	local current_authorization="$3"
	local release_type="${4:-}"
	local normalized_evidence=""
	local failed_source_pr=""
	local failed_source_merge=""
	local attempted_tag=""
	local failed_pr_json=""
	local aggregate_identity=""
	local aggregate_sources=""
	local aggregate_manifest=""
	local direct_manifest=""
	_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_PR=""
	_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_MERGE=""
	_FULL_LOOP_FAILED_PREPUBLICATION_TAG=""
	[[ "$source_pr" =~ ^[0-9]+$ && -n "$current_authorization" ]] || return 1
	[[ "$_FULL_LOOP_RESOLVED_REQUESTED_MERGE" =~ $_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX &&
		"$_FULL_LOOP_RESOLVED_SOURCE_MERGE" =~ $_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX ]] || return 1
	normalized_evidence=$(_full_loop_recovery_resolve_failed_prepublication_evidence \
		"$repo" "$source_pr" "$_FULL_LOOP_RESOLVED_REQUESTED_MERGE" "$release_type") || return 1
	failed_source_pr=$(jq -er '.source_pr' <<<"$normalized_evidence") || return 1
	failed_source_merge=$(jq -er '.source_merge' <<<"$normalized_evidence") || return 1
	attempted_tag=$(jq -er '.attempted_tag' <<<"$normalized_evidence") || return 1
	git -C "$REPO_ROOT" cat-file -e "${failed_source_merge}^{commit}" 2>/dev/null || {
		_full_loop_recovery_failed_prepublication_refused "recorded release source commit is unavailable"
		return 1
	}
	git -C "$REPO_ROOT" merge-base --is-ancestor "$failed_source_merge" \
		"$_FULL_LOOP_RESOLVED_SOURCE_MERGE" 2>/dev/null || {
		_full_loop_recovery_failed_prepublication_refused "recorded failed source is not an ancestor of the reviewed retry"
		return 1
	}
	failed_pr_json=$(gh pr view "$failed_source_pr" --repo "$repo" \
		--json state,mergedAt,mergeCommit,baseRefName 2>/dev/null) || {
		_full_loop_recovery_failed_prepublication_refused "recorded release-source PR cannot be verified"
		return 1
	}
	jq -e --arg merge "$failed_source_merge" '
		.state == "MERGED" and ((.mergedAt // "") | length > 0)
		and .baseRefName == "main" and .mergeCommit.oid == $merge
	' <<<"$failed_pr_json" >/dev/null || {
		_full_loop_recovery_failed_prepublication_refused "recorded release-source PR does not match its immutable merge"
		return 1
	}
	direct_manifest="${source_pr}@${_FULL_LOOP_RESOLVED_REQUESTED_MERGE}"
	if [[ "$failed_source_pr" == "$source_pr" &&
		"$failed_source_merge" == "$_FULL_LOOP_RESOLVED_REQUESTED_MERGE" ]]; then
		release_authorization_compare "$current_authorization" "$direct_manifest" || {
			_full_loop_recovery_failed_prepublication_refused "direct failure evidence conflicts with persisted authorization"
			return 1
		}
	else
		aggregate_identity=$(_full_loop_recovery_commit_trailer_values "$failed_source_merge" \
			"Aidevops-Release-Aggregator-PR") || return 1
		aggregate_sources=$(_full_loop_recovery_commit_trailer_values "$failed_source_merge" \
			"Aidevops-Release-Aggregates") || return 1
		[[ "$aggregate_identity" == "$failed_source_pr" && -n "$aggregate_sources" ]] || {
			_full_loop_recovery_failed_prepublication_refused "recorded release source is not an immutable aggregate"
			return 1
		}
		aggregate_manifest=$(release_authorization_manifest_string "$aggregate_sources") || {
			_full_loop_recovery_failed_prepublication_refused "recorded aggregate manifest is malformed"
			return 1
		}
		release_authorization_compare "$current_authorization" "$aggregate_manifest" || {
			_full_loop_recovery_failed_prepublication_refused "recorded aggregate manifest conflicts with persisted authorization"
			return 1
		}
	fi
	_full_loop_recovery_verify_channels_absent "$repo" "$attempted_tag" || {
		_full_loop_recovery_failed_prepublication_refused "the attempted tag is not absent from every publication channel"
		return 1
	}
	_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_PR="$failed_source_pr"
	_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_MERGE="$failed_source_merge"
	_FULL_LOOP_FAILED_PREPUBLICATION_TAG="$attempted_tag"
	return 0
}

_full_loop_recovery_validate_existing_tag() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local source_json=""
	local requested_present=""
	_full_loop_release_verify_protected_source_provenance "$repo" "$tag_name" || return 1
	source_json=$(_full_loop_release_source_json_from_tag "$tag_name") || return 1
	requested_present=$(jq -r --argjson requested "$source_pr" \
		'([.source_pr] + [.aggregated_sources[].pr]) | any(. == $requested)' <<<"$source_json") || return 1
	[[ "$requested_present" == "true" ]] || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON="$source_json"
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT=$(git -C "$REPO_ROOT" rev-parse \
		"${_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX}${tag_name}") || return 1
	_full_loop_release_reset_tag_worktree || return 1
	return 0
}

_full_loop_recovery_prepare_existing_context() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local requested_sources="$4"
	local current_authorization=""
	local current_json=""
	local requested_json=""
	_FULL_LOOP_AGGREGATE_RECOVERY_EXISTING_CONTEXT="none"
	if ! _full_loop_read_release_authorization_recovery_snapshot "$repo" "$source_pr" >/dev/null 2>&1; then
		return 0
	fi
	current_authorization=$(_full_loop_read_release_authorization "$repo" "$source_pr") || return 1
	current_json=$(release_authorization_manifest_json "$current_authorization") || return 1
	requested_json=$(release_authorization_intent_json "$requested_sources") || return 1
	jq -e --argjson current "$current_json" --argjson requested "$requested_json" '
		($current | length) == ($requested | length)
		and all($requested[]; . as $entry
			| any($current[]; .pr == $entry.pr and ($entry.merge == null or .merge == $entry.merge)))
	' <<<"null" >/dev/null || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$current_authorization"
	_FULL_LOOP_RESOLVED_SOURCE_JSON="$_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON"
	_FULL_LOOP_RESOLVED_SOURCE_PR=$(jq -er '.source_pr' \
		<<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON") || return 1
	_FULL_LOOP_RESOLVED_SOURCE_MERGE=$(jq -er '.source_merge' \
		<<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON") || return 1
	[[ "$_FULL_LOOP_RESOLVED_SOURCE_MERGE" =~ $_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX ]] || return 1
	_full_loop_recovery_validate_receipt "$repo" "$source_pr" "$tag_name" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON" || return 1
	if _full_loop_recovery_load_existing_state_transaction "$repo" "$source_pr" "$tag_name"; then
		_FULL_LOOP_AGGREGATE_RECOVERY_EXISTING_CONTEXT="transaction"
		return 0
	fi
	if _full_loop_recovery_load_remote_publication_state "$repo" "$source_pr" "$tag_name"; then
		_FULL_LOOP_AGGREGATE_RECOVERY_EXISTING_CONTEXT="remote-publication"
		return 0
	fi
	return 1
}

_full_loop_recovery_tag_sources() {
	local expected_json=""
	local observed_json=""
	expected_json=$(release_authorization_manifest_json "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED") || return 1
	observed_json=$(release_authorization_observed_sources_json "$expected_json" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON") || return 1
	jq -r "$_FULL_LOOP_AGGREGATE_RECOVERY_MANIFEST_JQ" <<<"$observed_json"
	return $?
}

_full_loop_recovery_tag_is_bound_to_current_aggregate() {
	local tag_name="$1"
	local tag_parent=""
	local aggregate_merge="${_FULL_LOOP_RESOLVED_SOURCE_MERGE:-}"
	[[ "$aggregate_merge" =~ $_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX ]] || return 1
	tag_parent=$(git -C "$REPO_ROOT" rev-parse "${tag_name}^{commit}^" 2>/dev/null) || return 1
	[[ "$tag_parent" == "$aggregate_merge" ]]
	return $?
}

_full_loop_recovery_load_existing_state_transaction() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local existing=""
	local previous_record=""
	existing=$(_full_loop_read_release_authorization "$repo" "$source_pr") || return 1
	[[ "$existing" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
	_full_loop_recovery_validate_interrupted_publication_intent "$repo" "$source_pr" "$tag_name" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON" || return 1
	previous_record=$(_full_loop_read_release_authorization_recovery_snapshot "$repo" "$source_pr") || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH=$(
		_full_loop_recovery_record_authorization "$previous_record"
	) || return 1
	release_authorization_subset "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
		--arg expected "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" \
		--arg recovery "$_FULL_LOOP_AGGREGATE_RECOVERY_PHASE" \
		--arg committing "$_FULL_LOOP_AGGREGATE_COMMIT_PHASE" \
		--arg sha40 "$_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .expected_sources == $expected
		and (.phase == $recovery or .phase == $committing)
		and ((.terminal_receipt // null) == null)
		and (.aggregate_recovery.provisional_tag_object | test($sha40))
		and (.aggregate_recovery.previous_state.schema_version == 1)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_LANE_SNAPSHOT=$(jq -ce '.aggregate_recovery.previous_state' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT=$(jq -er '.aggregate_recovery.provisional_tag_object' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -er '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	return 0
}

_full_loop_recovery_refresh_state_transaction() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local existing=""
	local existing_record=""
	local latest_record=""
	local previous_record=""
	local previous_authorization=""
	local lane_snapshot=""
	local phase=""
	local refresh_previous=""
	existing=$(_full_loop_read_release_authorization "$repo" "$source_pr") || return 1
	_full_loop_recovery_validate_interrupted_publication_intent "$repo" "$source_pr" "$tag_name" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON" || return 1
	existing_record=$(_full_loop_read_release_authorization_record "$repo" "$source_pr") || return 1
	previous_record=$(_full_loop_read_release_authorization_recovery_snapshot "$repo" "$source_pr") || return 1
	previous_authorization=$(_full_loop_recovery_record_authorization "$previous_record") || return 1
	lane_snapshot=$(jq -ce '.aggregate_recovery.previous_state' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	phase=$(jq -er '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	case "$phase" in
	aggregation-recovery | aggregate-publication-committing)
		[[ "$existing" != "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
		refresh_previous="$existing"
		release_lane_begin_aggregate_refresh "$repo" "$source_pr" "$tag_name" "$refresh_previous" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" || return 1
		;;
	aggregation-recovery-refresh)
		refresh_previous=$(jq -er '.aggregate_recovery.refresh.previous_expected_sources' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -er '.operation_token' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		;;
	*) return 1 ;;
	esac
	if [[ "$existing" != "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]]; then
		latest_record=$(_full_loop_read_release_authorization_record "$repo" "$source_pr") || return 1
		[[ "$latest_record" == "$existing_record" ]] || return 1
		_full_loop_write_release_authorization_record "$repo" "$source_pr" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$previous_record" || return 1
	fi
	[[ "$(_full_loop_read_release_authorization "$repo" "$source_pr")" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
	release_lane_finish_aggregate_refresh "$repo" "$source_pr" "$tag_name" "$refresh_previous" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH="$previous_authorization"
	_FULL_LOOP_AGGREGATE_RECOVERY_LANE_SNAPSHOT="$lane_snapshot"
	return 0
}

_full_loop_recovery_prepare_aggregate() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="$3"
	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local resolver=""
	[[ -d "$worktree_base" ]] || return 1
	git -C "$REPO_ROOT" fetch origin main >/dev/null || return 1
	_FULL_LOOP_RELEASE_PATH="${worktree_base}/aidevops-release-aggregate-recovery-${source_pr}-$$"
	git -C "$REPO_ROOT" worktree add --detach "$_FULL_LOOP_RELEASE_PATH" origin/main >/dev/null || return 1
	trap 'cleanup_release_worktree' EXIT
	resolver="$_FULL_LOOP_RELEASE_PATH/.agents/scripts/release-provenance-helper.sh"
	_full_loop_resolve_requested_release_source "$repo" "$source_pr" "$_FULL_LOOP_RELEASE_PATH" "$resolver" "$expected_sources" || return 1
	[[ "$(jq -r '.mode' <<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON")" == "aggregate" ]] || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$_FULL_LOOP_RESOLVED_EXPECTED_SOURCES"
	return 0
}

_full_loop_recovery_prepare_prepublication_source() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="$3"
	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local resolver=""
	local resolved_mode=""
	local resolve_rc=0
	local previous_preserve_evidence="${_FULL_LOOP_PRESERVE_PREPUBLICATION_FAILURE_EVIDENCE:-false}"
	[[ -d "$worktree_base" ]] || return 1
	git -C "$REPO_ROOT" fetch origin main >/dev/null || return 1
	_FULL_LOOP_RELEASE_PATH="${worktree_base}/aidevops-release-prepublication-recovery-${source_pr}-$$"
	git -C "$REPO_ROOT" worktree add --detach "$_FULL_LOOP_RELEASE_PATH" origin/main >/dev/null || return 1
	trap 'cleanup_release_worktree' EXIT
	resolver="$_FULL_LOOP_RELEASE_PATH/.agents/scripts/release-provenance-helper.sh"
	_FULL_LOOP_PRESERVE_PREPUBLICATION_FAILURE_EVIDENCE=true
	_full_loop_resolve_requested_release_source "$repo" "$source_pr" "$_FULL_LOOP_RELEASE_PATH" \
		"$resolver" "$expected_sources" || resolve_rc=$?
	_FULL_LOOP_PRESERVE_PREPUBLICATION_FAILURE_EVIDENCE="$previous_preserve_evidence"
	[[ "$resolve_rc" -eq 0 ]] || return "$resolve_rc"
	resolved_mode=$(jq -er '.mode' <<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON") || return 1
	case "$resolved_mode" in direct | aggregate) ;; *) return 1 ;; esac
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$_FULL_LOOP_RESOLVED_EXPECTED_SOURCES"
	return 0
}

_full_loop_recovery_resolve_lane_authorization() {
	local lane_sources="$1"
	local reviewed_sources="$2"
	local lane_intent_json=""
	local reviewed_json=""
	lane_intent_json=$(release_authorization_intent_json "$lane_sources") || return 1
	reviewed_json=$(release_authorization_manifest_json "$reviewed_sources") || return 1
	jq -cern --argjson intent "$lane_intent_json" --argjson reviewed "$reviewed_json" '
		$intent | map(. as $candidate
			| ($reviewed | map(select(.pr == $candidate.pr))) as $matches
			| if (($matches | length) == 1
				and ($candidate.merge == null or $candidate.merge == $matches[0].merge))
				then $matches[0]
				else error("reserved lane intent does not match reviewed aggregate")
			  end)
		| map([.pr, .merge] | join("@")) | join(",")
	' 2>/dev/null
	return $?
}

_full_loop_recovery_normalize_failed_prepublication_sources() {
	local legacy_sources="$1"
	local normalized_sources=""
	normalized_sources=$(_full_loop_recovery_resolve_lane_authorization "$legacy_sources" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED") || {
		_full_loop_recovery_failed_prepublication_refused \
			"legacy lane intent conflicts with the reviewed aggregate"
		return 1
	}
	printf '%s\n' "$normalized_sources"
	return 0
}

_full_loop_recovery_reserved_base_authorization() {
	local repo="$1"
	local source_pr="$2"
	local current_authorization="$3"
	local lane_sources="$4"
	local expected_sources="$5"
	local normalized_lane_sources=""
	local previous_record=""
	local previous_authorization=""
	normalized_lane_sources=$(_full_loop_recovery_resolve_lane_authorization \
		"$lane_sources" "$expected_sources") || return 1
	if [[ "$normalized_lane_sources" == "$current_authorization" ]]; then
		printf '%s\n' "$normalized_lane_sources"
		return 0
	fi
	[[ "$current_authorization" == "$expected_sources" ]] || return 1
	previous_record=$(_full_loop_read_release_authorization_recovery_snapshot \
		"$repo" "$source_pr") || return 1
	previous_authorization=$(_full_loop_recovery_record_authorization "$previous_record") || return 1
	[[ "$normalized_lane_sources" == "$previous_authorization" ]] || return 1
	printf '%s\n' "$previous_authorization"
	return 0
}

_full_loop_recovery_lane_has_prepublication_marker() {
	jq -e '((.prepublication_recovery // null) != null)' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null
	return $?
}

_full_loop_recovery_lane_prepublication_sources() {
	jq -er --arg string_type "$_FULL_LOOP_AGGREGATE_RECOVERY_JSON_STRING_TYPE" '
		.prepublication_recovery.failed_expected_sources
		| select(type == $string_type and length > 0)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON"
	return $?
}

_full_loop_recovery_lane_requires_prepublication_transaction() {
	local repo="$1"
	local source_pr="$2"
	local persisted_sources="$3"
	local read_rc=0
	local lane_sources=""
	local lane_prs=""
	local persisted_prs=""
	local phase=""
	release_lane_read "$repo" || read_rc=$?
	case "$read_rc" in
	2) return 1 ;;
	0) ;;
	*) return 2 ;;
	esac
	jq -e --argjson source_pr "$source_pr" '
		.active == true and .source_pr == $source_pr and ((.terminal_receipt // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	phase=$(jq -er '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 2
	if [[ "$phase" == "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" ]]; then
		return 0
	fi
	if [[ "$phase" == "$_FULL_LOOP_FAILED_PREPUBLICATION_PHASE" ]]; then
		jq -e --arg string_type "$_FULL_LOOP_AGGREGATE_RECOVERY_JSON_STRING_TYPE" \
			'.tag == null and (.expected_sources | type) == $string_type' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
		lane_sources=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 2
		[[ "$lane_sources" == "$persisted_sources" ]]
		return $?
	fi
	jq -e --arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" \
		--arg string_type "$_FULL_LOOP_AGGREGATE_RECOVERY_JSON_STRING_TYPE" \
		'.phase == $reserved and .tag == null and (.expected_sources | type) == $string_type' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	lane_sources=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 2
	if _full_loop_recovery_lane_has_prepublication_marker; then
		[[ "$lane_sources" == "$persisted_sources" ]]
		return $?
	fi
	lane_prs=$(release_authorization_intent_json "$lane_sources" | jq -c 'map(.pr)') || return 2
	persisted_prs=$(release_authorization_intent_json "$persisted_sources" | jq -c 'map(.pr)') || return 2
	[[ "$lane_prs" != "$persisted_prs" ]]
	return $?
}

_full_loop_recovery_prepare_reserved_retry_source() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="$3"
	local phase=""
	release_lane_read "$repo" || return 1
	phase=$(jq -er '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	if [[ "$phase" == "$_FULL_LOOP_FAILED_PREPUBLICATION_PHASE" ]] ||
		_full_loop_recovery_lane_has_prepublication_marker; then
		_full_loop_recovery_prepare_prepublication_source "$repo" "$source_pr" "$expected_sources" || {
			_full_loop_recovery_failed_prepublication_refused "reviewed retry source is neither a valid direct source nor aggregate"
			return 1
		}
	else
		_full_loop_recovery_prepare_aggregate "$repo" "$source_pr" "$expected_sources" || return 1
	fi
	return 0
}

#aidevops:trust-boundary
_full_loop_recovery_load_reserved_lane_state() {
	local repo="$1"
	local source_pr="$2"
	local current_authorization="$3"
	local release_type="$4"
	local phase=""
	local lane_sources=""
	local failed_sources=""
	local normalized_lane_sources=""
	local normalized_failed_sources=""
	_FULL_LOOP_RESERVED_RECOVERY_PHASE=""
	_FULL_LOOP_RESERVED_RECOVERY_LANE_SOURCES=""
	_FULL_LOOP_RESERVED_RECOVERY_FAILED_SOURCES=""
	_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION="false"
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" \
		--arg string_type "$_FULL_LOOP_AGGREGATE_RECOVERY_JSON_STRING_TYPE" '
		.active == true and .source_pr == $source_pr and .tag == null
		and (.expected_sources | type) == $string_type and (.phase | type) == $string_type
		and ((.terminal_receipt // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || {
		printf 'Reserved release lane is not eligible for legacy authorization normalization for PR #%s\n' "$source_pr" >&2
		return 1
	}
	phase=$(jq -er '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	case "$phase" in
	"$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED")
		lane_sources=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		if _full_loop_recovery_lane_has_prepublication_marker; then
			normalized_lane_sources=$(_full_loop_recovery_normalize_failed_prepublication_sources \
				"$lane_sources") || return 1
			[[ "$normalized_lane_sources" == "$current_authorization" ]] || {
				printf 'Failed pre-publication release recovery refused: lane and persisted authorization differ\n' >&2
				return 1
			}
			failed_sources=$(_full_loop_recovery_lane_prepublication_sources) || return 1
			normalized_failed_sources=$(_full_loop_recovery_normalize_failed_prepublication_sources \
				"$failed_sources") || return 1
			_full_loop_recovery_validate_failed_prepublication_intent "$repo" "$source_pr" \
				"$normalized_failed_sources" "$release_type" || return 1
			_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION="true"
		fi
		;;
	"$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH")
		[[ "$(jq -r '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
		lane_sources=$(jq -er '.reserved_authorization_refresh.previous_expected_sources' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		if _full_loop_recovery_lane_has_prepublication_marker; then
			failed_sources=$(_full_loop_recovery_lane_prepublication_sources) || return 1
			[[ "$lane_sources" == "$failed_sources" ]] || return 1
			normalized_failed_sources=$(_full_loop_recovery_normalize_failed_prepublication_sources \
				"$failed_sources") || return 1
			_full_loop_recovery_validate_failed_prepublication_intent "$repo" "$source_pr" \
				"$normalized_failed_sources" "$release_type" || return 1
			_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION="true"
		fi
		;;
	"$_FULL_LOOP_FAILED_PREPUBLICATION_PHASE")
		lane_sources=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		normalized_lane_sources=$(_full_loop_recovery_normalize_failed_prepublication_sources \
			"$lane_sources") || return 1
		[[ "$normalized_lane_sources" == "$current_authorization" ]] || {
			printf 'Failed pre-publication release recovery refused: lane and persisted authorization differ\n' >&2
			return 1
		}
		failed_sources="$lane_sources"
		normalized_failed_sources="$normalized_lane_sources"
		_full_loop_recovery_validate_failed_prepublication_intent "$repo" "$source_pr" \
			"$normalized_failed_sources" "$release_type" || return 1
		_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION="true"
		;;
	*)
		printf 'Pre-publication release recovery refused: lane phase %s is not eligible\n' "$phase" >&2
		return 1
		;;
	esac
	_FULL_LOOP_RESERVED_RECOVERY_PHASE="$phase"
	_FULL_LOOP_RESERVED_RECOVERY_LANE_SOURCES="$lane_sources"
	_FULL_LOOP_RESERVED_RECOVERY_FAILED_SOURCES="$failed_sources"
	return 0
}

_full_loop_recovery_expand_reserved_authorization() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="$3"
	local release_type="${4:-patch}"
	local previous_auth=""
	local lane_sources=""
	local phase=""
	local current_auth=""
	local observed_auth=""
	local existing_tag_rc=0
	local failed_prepublication=false
	_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_PR=""
	_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_MERGE=""
	_FULL_LOOP_FAILED_PREPUBLICATION_TAG=""
	_FULL_LOOP_RESERVED_RECOVERY_FAILED_SOURCES=""
	_full_loop_recovery_validate_reserved_receipt "$repo" "$source_pr" || return 1
	_full_loop_release_find_tag_for_pr "$repo" "$source_pr" || existing_tag_rc=$?
	[[ "$existing_tag_rc" -eq 2 ]] || return 1
	_full_loop_recovery_prepare_reserved_retry_source "$repo" "$source_pr" "$expected_sources" || return 1
	_full_loop_validate_release_candidates "$repo" "$_FULL_LOOP_RESOLVED_SOURCE_JSON" || return 1
	_full_loop_release_reset_tag_worktree || return 1
	current_auth=$(_full_loop_read_release_authorization "$repo" "$source_pr") || return 1
	_full_loop_recovery_load_reserved_lane_state "$repo" "$source_pr" "$current_auth" \
		"$release_type" || return 1
	phase="$_FULL_LOOP_RESERVED_RECOVERY_PHASE"
	lane_sources="$_FULL_LOOP_RESERVED_RECOVERY_LANE_SOURCES"
	failed_prepublication="$_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION"
	previous_auth=$(_full_loop_recovery_reserved_base_authorization "$repo" "$source_pr" \
		"$current_auth" "$lane_sources" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED") || {
		printf 'Reserved release lane authorization cannot be normalized against reviewed aggregate PR #%s\n' "$source_pr" >&2
		return 1
	}
	release_authorization_subset "$previous_auth" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	if [[ "$phase" == "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" && "$failed_prepublication" != "true" &&
		"$lane_sources" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" &&
		"$current_auth" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]]; then
		_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -er '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		_AIDEVOPS_RELEASE_LANE_RESULT="adopted"
		printf 'Reserved release authorization already matches the reviewed aggregate for PR #%s\n' "$source_pr"
		return 0
	fi
	release_lane_acquire "$repo" "$source_pr" "$lane_sources" || return $?
	case "$_AIDEVOPS_RELEASE_LANE_RESULT" in acquired | adopted) ;; *) return 1 ;; esac
	if [[ "$failed_prepublication" == "true" ]]; then
		release_lane_reopen_failed_prepublication "$repo" "$source_pr" \
			"$_FULL_LOOP_RESERVED_RECOVERY_FAILED_SOURCES" \
			"$_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_PR" \
			"$_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_MERGE" \
			"$_FULL_LOOP_FAILED_PREPUBLICATION_TAG" || return 1
		phase="$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED"
	fi
	if [[ "$current_auth" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" &&
		"$lane_sources" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]]; then
		printf 'Pre-publication release authorization already matches the reviewed retry for PR #%s\n' "$source_pr"
		return 0
	fi
	release_lane_expand_reserved_authorization "$repo" "$source_pr" "$lane_sources" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	if [[ "$current_auth" != "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]]; then
		_full_loop_expand_release_authorization_for_aggregate "$repo" "$source_pr" \
			"$previous_auth" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || {
			observed_auth=$(_full_loop_read_release_authorization "$repo" "$source_pr") || return 1
			if [[ "$observed_auth" == "$previous_auth" ]]; then
				release_lane_restore_reserved_authorization "$repo" "$source_pr" \
					"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" \
					"$_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT" || true
			fi
			[[ "$observed_auth" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
		}
	fi
	if ! release_lane_finish_reserved_authorization "$repo" "$source_pr" "$lane_sources" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED"; then
		printf 'Reserved release lane authorization migration remains fenced for retry for PR #%s\n' "$source_pr" >&2
		return 1
	fi
	printf 'Expanded side-effect-free reserved release authorization for reviewed aggregate PR #%s\n' "$source_pr"
	return 0
}

_full_loop_recovery_begin_state_transaction() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local lane_expected=""
	local existing=""
	existing=$(_full_loop_read_release_authorization "$repo" "$source_pr") || return 1
	if [[ "$existing" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]]; then
		_full_loop_recovery_load_existing_state_transaction "$repo" "$source_pr" "$tag_name" && return 0
		if _full_loop_read_release_authorization_recovery_snapshot "$repo" "$source_pr" >/dev/null 2>&1; then
			_full_loop_recovery_refresh_state_transaction "$repo" "$source_pr" "$tag_name"
			return $?
		fi
	else
		if _full_loop_read_release_authorization_recovery_snapshot "$repo" "$source_pr" >/dev/null 2>&1; then
			_full_loop_recovery_refresh_state_transaction "$repo" "$source_pr" "$tag_name"
			return $?
		fi
		_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH="$existing"
		release_authorization_subset "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	fi
	_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH="$existing"
	release_lane_read "$repo" || return 1
	lane_expected=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	if ! release_lane_begin_aggregate_recovery "$repo" "$source_pr" "$tag_name" "$lane_expected" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT"; then
		return 1
	fi
	_FULL_LOOP_AGGREGATE_RECOVERY_LANE_SNAPSHOT="$_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT"
	if ! _full_loop_expand_release_authorization_for_aggregate "$repo" "$source_pr" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED"; then
		release_lane_restore_aggregate_recovery "$repo" "$source_pr" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_LANE_SNAPSHOT" || true
		return 1
	fi
	release_lane_finish_aggregate_refresh "$repo" "$source_pr" "$tag_name" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" || return 1
	return 0
}

_full_loop_recovery_load_remote_publication_state() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local provisional_tag_object=""
	_full_loop_release_validate_published_reconciliation_intent "$repo" "$source_pr" "$tag_name" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON" || return 1
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
		--arg expected "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" \
		--arg sha40 "$_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .phase == "remote-publication" and .expected_sources == $expected
		and ((.terminal_receipt // null) == null)
		and (.aggregate_recovery.provisional_tag_object | test($sha40))
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	provisional_tag_object=$(jq -er '.aggregate_recovery.provisional_tag_object' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT="$provisional_tag_object"
	_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -er '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	return 0
}

_full_loop_recovery_transition_durable_publication() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local current_tag_object=""
	local reachability_rc=0
	local update_rc=0
	current_tag_object=$(git -C "$REPO_ROOT" rev-parse \
		"${_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX}${tag_name}") || return 1
	[[ "$current_tag_object" != "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" ]] || return 1
	_full_loop_recovery_tag_is_bound_to_current_aggregate "$tag_name" || return 1
	[[ "$(_full_loop_read_release_authorization "$repo" "$source_pr")" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
		--arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" --arg expected "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" \
		--arg committing "$_FULL_LOOP_AGGREGATE_COMMIT_PHASE" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .operation_token == $token and .phase == $committing
		and .expected_sources == $expected and ((.terminal_receipt // null) == null)
		and ((.aggregate_recovery.refresh // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	_full_loop_recovery_release_commit_main_reachability "$tag_name" || reachability_rc=$?
	case "$reachability_rc" in
	0) ;;
	2) return 8 ;;
	*) return 1 ;;
	esac
	release_lane_update "$repo" "$source_pr" remote-publication "$tag_name" || update_rc=$?
	if [[ "$update_rc" -ne 0 ]]; then
		release_lane_read "$repo" || return "$update_rc"
		jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
			--arg expected "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" '
			.active == true and .source_pr == $source_pr and .tag == $tag
			and .phase == "remote-publication" and .expected_sources == $expected
			and ((.terminal_receipt // null) == null)
		' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return "$update_rc"
		_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -er '.operation_token' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return "$update_rc"
	fi
	return 0
}

_full_loop_recovery_release_commit_main_reachability() {
	local tag_name="$1"
	local release_commit=""
	local ancestry_rc=0
	git -C "$REPO_ROOT" fetch origin main >/dev/null || return 1
	release_commit=$(git -C "$REPO_ROOT" rev-parse "${tag_name}^{commit}") || return 1
	git -C "$REPO_ROOT" merge-base --is-ancestor "$release_commit" origin/main || ancestry_rc=$?
	case "$ancestry_rc" in
	0) return 0 ;;
	1) return 2 ;;
	*) return 1 ;;
	esac
}

_full_loop_recovery_report_pending_commit() {
	local source_pr="$1"
	local tag_name="$2"
	printf 'release:aggregate-recovery queued tag=%s source_pr=%s\n' "$tag_name" "$source_pr"
	printf 'The exact protected-main publication remains fenced until its release commit reaches main.\n'
	printf 'Resume with: aidevops release status %s\n' "$source_pr"
	printf 'Then rerun the same recover-aggregate command after the protected PR merges.\n'
	return 8
}

_full_loop_recovery_resume_publication() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local new_tag_object=""
	local reconcile_rc=0
	new_tag_object=$(git -C "$REPO_ROOT" rev-parse \
		"${_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX}${tag_name}") || return 1
	_full_loop_recovery_write_evidence "$repo" "$source_pr" "$tag_name" "$new_tag_object" || return 1
	_full_loop_release_existing_with_lane reconcile "$source_pr" || reconcile_rc=$?
	case "$reconcile_rc" in
	0 | 8) return "$reconcile_rc" ;;
	esac
	return 1
}

_full_loop_recovery_write_evidence() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local new_tag_object="$4"
	local receipt_path=""
	local evidence_path=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$source_pr") || return 1
	evidence_path="${receipt_path%.status}.aggregate-recovery.json"
	jq -cn --arg repo "$repo" --argjson requested_pr "$source_pr" --arg tag "$tag_name" \
		--arg old "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" --arg new "$new_tag_object" \
		--argjson source "$_FULL_LOOP_RESOLVED_SOURCE_JSON" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		'{schema_version:1,status:"queued",repository:$repo,requested_pr:$requested_pr,tag:$tag,
		  provisional_tag_object:$old,replacement_tag_object:$new,aggregate_source:$source,recorded_at:$now}' \
		>"${evidence_path}.tmp.$$" || return 1
	mv "${evidence_path}.tmp.$$" "$evidence_path" || return 1
	return 0
}

_full_loop_recovery_run_version_manager() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local version_manager="$_FULL_LOOP_RELEASE_PATH/.agents/scripts/version-manager.sh"
	local recovery_rc=0
	(
		cd "$_FULL_LOOP_RELEASE_PATH" || exit 1
		AIDEVOPS_RELEASE_INTENT_TRUSTED=1 \
			AIDEVOPS_RELEASE_LANE_REPOSITORY="$repo" \
			AIDEVOPS_RELEASE_LANE_SOURCE_PR="$source_pr" \
			AIDEVOPS_RELEASE_LANE_TAG="$tag_name" \
			AIDEVOPS_RELEASE_LANE_EXPECTED_SOURCES="$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" \
			AIDEVOPS_RELEASE_LANE_OPERATION_TOKEN="$_AIDEVOPS_RELEASE_LANE_TOKEN" \
			bash "$version_manager" recover-aggregate \
			--tag "$tag_name" --source-pr "$source_pr" \
			--expected-sources "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" \
			--old-tag-object "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT"
	) || recovery_rc=$?
	case "$recovery_rc" in
	0 | 8) return "$recovery_rc" ;;
	esac
	return 1
}

_full_loop_recovery_resume_committing_queue() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local current_tag_object=""
	local recovery_rc=0
	local transition_rc=0
	current_tag_object=$(git -C "$REPO_ROOT" rev-parse \
		"${_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX}${tag_name}") || return 1
	_full_loop_release_prepare_tag_worktree "$tag_name" || return 1
	_full_loop_recovery_write_evidence "$repo" "$source_pr" "$tag_name" "$current_tag_object" || return 1
	_full_loop_recovery_run_version_manager "$repo" "$source_pr" "$tag_name" || recovery_rc=$?
	case "$recovery_rc" in
	0 | 8) ;;
	*) return 1 ;;
	esac
	_full_loop_recovery_transition_durable_publication "$repo" "$source_pr" "$tag_name" || transition_rc=$?
	case "$transition_rc" in
	0 | 8) return "$transition_rc" ;;
	*) return 1 ;;
	esac
}

_full_loop_recovery_tag_rollback_safe() {
	local repo="$1"
	local tag_name="$2"
	local current_object=""
	current_object=$(git -C "$REPO_ROOT" rev-parse \
		"${_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX}${tag_name}" 2>/dev/null) || return 1
	[[ "$current_object" == "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" ]] || return 1
	_full_loop_recovery_verify_channels_absent "$repo" "$tag_name" || return 1
	return 0
}

_full_loop_recovery_resume_prepared_state() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local tag_sources="$4"
	local transition_rc=0
	[[ "$tag_sources" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 2
	if _full_loop_recovery_load_existing_state_transaction "$repo" "$source_pr" "$tag_name"; then
		_full_loop_recovery_tag_is_bound_to_current_aggregate "$tag_name" || return 2
		_full_loop_recovery_transition_durable_publication "$repo" "$source_pr" "$tag_name" || transition_rc=$?
		if [[ "$transition_rc" -eq 8 ]]; then
			transition_rc=0
			_full_loop_recovery_resume_committing_queue "$repo" "$source_pr" "$tag_name" || transition_rc=$?
			if [[ "$transition_rc" -eq 8 ]]; then
				_full_loop_recovery_report_pending_commit "$source_pr" "$tag_name"
				return $?
			fi
		fi
		[[ "$transition_rc" -eq 0 ]] || return 1
		_full_loop_recovery_resume_publication "$repo" "$source_pr" "$tag_name"
		return $?
	fi
	if _full_loop_recovery_tag_is_bound_to_current_aggregate "$tag_name"; then
		_full_loop_recovery_load_remote_publication_state "$repo" "$source_pr" "$tag_name" || return 1
		_full_loop_recovery_resume_publication "$repo" "$source_pr" "$tag_name"
		return $?
	fi
	return 2
}

_full_loop_recovery_handle_failed_version_manager() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local resume_rc=0
	local transition_rc=0
	_full_loop_recovery_transition_durable_publication "$repo" "$source_pr" "$tag_name" || transition_rc=$?
	if [[ "$transition_rc" -eq 0 ]]; then
		_full_loop_recovery_resume_publication "$repo" "$source_pr" "$tag_name" || resume_rc=$?
		case "$resume_rc" in
		0) return 0 ;;
		8)
			printf 'release:aggregate-recovery queued tag=%s source_pr=%s\n' "$tag_name" "$source_pr"
			printf 'Resume with: aidevops release status %s\n' "$source_pr"
			printf 'Resume with: aidevops release reconcile %s\n' "$source_pr"
			return 8
			;;
		esac
	elif [[ "$transition_rc" -eq 8 ]]; then
		_full_loop_recovery_report_pending_commit "$source_pr" "$tag_name"
		return $?
	fi
	if _full_loop_recovery_tag_rollback_safe "$repo" "$tag_name"; then
		printf 'Aggregate recovery failed before durable publication; the fenced transaction was retained for idempotent retry\n' >&2
	else
		printf 'Aggregate recovery failed after tag state changed; expanded recovery state was retained for reconciliation\n' >&2
	fi
	return 1
}

_full_loop_recovery_finish_version_manager() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local new_tag_object=""
	local transition_rc=0
	new_tag_object=$(git -C "$REPO_ROOT" rev-parse \
		"${_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX}${tag_name}") || return 1
	if [[ "$new_tag_object" == "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" ]] ||
		! _full_loop_recovery_tag_is_bound_to_current_aggregate "$tag_name"; then
		printf 'Aggregate recovery did not produce the exact replacement tag; the fenced transaction was retained for retry\n' >&2
		return 1
	fi
	_full_loop_recovery_write_evidence "$repo" "$source_pr" "$tag_name" "$new_tag_object" || return 1
	_full_loop_recovery_transition_durable_publication "$repo" "$source_pr" "$tag_name" || transition_rc=$?
	if [[ "$transition_rc" -eq 8 ]]; then
		_full_loop_recovery_report_pending_commit "$source_pr" "$tag_name"
		return $?
	fi
	[[ "$transition_rc" -eq 0 ]] || return 1
	printf 'release:aggregate-recovery queued tag=%s source_pr=%s\n' "$tag_name" "$source_pr"
	printf 'Resume with: aidevops release status %s\n' "$source_pr"
	printf 'Resume with: aidevops release reconcile %s\n' "$source_pr"
	return 8
}

_full_loop_successor_manifest_from_body() {
	local stale_pr="$1"
	local body="$2"
	local raw_identity=""
	local raw_sources=""
	local parsed=""
	local parsed_identity=""
	local parsed_sources=""
	local manifest=""
	raw_identity=$(awk '/^Aidevops-Release-Aggregator-PR: / { print substr($0, 33) }' <<<"$body") || return 1
	raw_sources=$(awk '/^Aidevops-Release-Aggregates: / { print substr($0, 30) }' <<<"$body") || return 1
	parsed=$(git -C "$REPO_ROOT" interpret-trailers --parse <<<"$body") || return 1
	parsed_identity=$(awk '/^Aidevops-Release-Aggregator-PR: / { print substr($0, 33) }' <<<"$parsed") || return 1
	parsed_sources=$(awk '/^Aidevops-Release-Aggregates: / { print substr($0, 30) }' <<<"$parsed") || return 1
	[[ "$raw_identity" == "$stale_pr" && "$parsed_identity" == "$stale_pr" &&
		"$raw_sources" == "$parsed_sources" && -n "$raw_sources" ]] || return 1
	manifest=$(awk 'BEGIN { first=1 }
		/^[0-9]+@[0-9a-f]{40}$/ { if (!first) printf ","; printf "%s", $0; first=0; next }
		{ exit 2 }
		END { if (first) exit 2 }' <<<"$raw_sources") || return 1
	release_authorization_manifest_string "$manifest"
	return $?
}

_full_loop_successor_source_for_commit() {
	local repo="$1"
	local commit_sha="$2"
	local pulls_json=""
	local source=""
	[[ "$commit_sha" =~ $_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX ]] || return 1
	pulls_json=$(gh api "repos/${repo}/commits/${commit_sha}/pulls" 2>/dev/null) || return 1
	source=$(jq -er --arg commit "$commit_sha" --arg main "$_FULL_LOOP_AGGREGATE_RECOVERY_MAIN_BRANCH" '
		[.[] | select(.merged_at != null and .base.ref == $main and .merge_commit_sha == $commit)]
		| if length == 1 then "\(.[0].number)@\(.[0].merge_commit_sha)" else error("ambiguous merged PR") end
	' <<<"$pulls_json" 2>/dev/null) || return 1
	[[ "$source" =~ ^[0-9]+@[0-9a-f]{40}$ ]] || return 1
	printf '%s\n' "$source"
	return 0
}

_full_loop_successor_complete_manifest() {
	local repo="$1"
	local stale_head="$2"
	local stale_manifest="$3"
	local lane_manifest="$4"
	local commit_sha=""
	local source=""
	local source_lines=""
	local compare_commits=""
	local normalized=""
	[[ "$stale_head" =~ $_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX ]] || return 1
	source_lines=$(tr ',' '\n' <<<"${stale_manifest},${lane_manifest}") || return 1
	compare_commits=$(gh api "repos/${repo}/compare/${stale_head}...main" --jq '.commits[].sha' 2>/dev/null) || return 1
	[[ -n "$compare_commits" ]] || {
		printf 'Successor aggregation refused: stale aggregate already represents the current main tip\n' >&2
		return 1
	}
	while IFS= read -r commit_sha; do
		[[ -n "$commit_sha" ]] || continue
		source=$(_full_loop_successor_source_for_commit "$repo" "$commit_sha") || {
			printf 'Successor aggregation refused: main commit %s has no unique merged-main PR provenance\n' "$commit_sha" >&2
			return 1
		}
		source_lines+=$'\n'"$source"
	done <<<"$compare_commits"
	normalized=$(jq -Rrsc '
		split("\n") | map(select(length > 0)
			| if test("^[0-9]+@[0-9a-f]{40}$") then capture("^(?<pr>[0-9]+)@(?<merge>[0-9a-f]{40})$")
			else error("malformed source") end
			| {pr:(.pr|tonumber),merge:.merge})
		| group_by(.pr)
		| if any(.[]; (map(.merge)|unique|length) != 1) then error("conflicting source") else . end
		| map(.[0]) | sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")
	' <<<"$source_lines") || return 1
	[[ -n "$normalized" ]] || return 1
	printf '%s\n' "$normalized"
	return 0
}

_full_loop_successor_create_commit() {
	local repo="$1"
	local parent="$2"
	local message="$3"
	local tree_sha=""
	local payload=""
	local commit_sha=""
	tree_sha=$(gh api "repos/${repo}/git/commits/${parent}" --jq '.tree.sha // empty' 2>/dev/null) || return 1
	[[ "$tree_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	payload=$(jq -cn --arg message "$message" --arg tree "$tree_sha" --arg parent "$parent" \
		'{message:$message,tree:$tree,parents:[$parent]}') || return 1
	commit_sha=$(gh api "repos/${repo}/git/commits" --method POST --input - --jq '.sha // empty' \
		<<<"$payload" 2>/dev/null) || return 1
	[[ "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	printf '%s\n' "$commit_sha"
	return 0
}

_full_loop_successor_body() {
	local stale_pr="$1"
	local base_sha="$2"
	local successor_pr="$3"
	local manifest="$4"
	local source=""
	printf "## Summary\n\nMetadata-only successor for stale release aggregation PR #%s at exact main tip \`%s\`.\n\n" \
		"$stale_pr" "$base_sha"
	printf 'Review, required checks, and guarded merge remain explicit.\n\n'
	printf 'Aidevops-Release-Aggregator-PR: %s\n' "$successor_pr"
	while IFS= read -r source; do
		[[ -n "$source" ]] || continue
		printf 'Aidevops-Release-Aggregates: %s\n' "$source"
	done < <(tr ',' '\n' <<<"$manifest")
	return 0
}

_full_loop_successor_final_message() {
	local successor_pr="$1"
	local manifest="$2"
	local source=""
	printf 'chore(release): bind refreshed exact-tip aggregation\n\n'
	printf 'Aidevops-Release-Aggregator-PR: %s\n' "$successor_pr"
	while IFS= read -r source; do
		[[ -n "$source" ]] || continue
		printf 'Aidevops-Release-Aggregates: %s\n' "$source"
	done < <(tr ',' '\n' <<<"$manifest")
	return 0
}

# Create or adopt the one draft successor for a stale metadata-only aggregate.
# PR allocation deliberately precedes the sole terminal trailer commit.
#aidevops:trust-boundary
_full_loop_release_refresh_aggregate() {
	local repo="$1"
	local stale_pr="$2"
	local stale_json=""
	local stale_body=""
	local stale_head=""
	local stale_manifest=""
	local lane_manifest=""
	local base_sha=""
	local branch_name=""
	local owner="${repo%%/*}"
	local branch_head=""
	local initial_commit=""
	local successor_json=""
	local successor_pr=""
	local body=""
	local final_message=""
	local branch_message=""
	local final_commit=""
	local payload=""
	[[ "$stale_pr" =~ ^[0-9]+$ ]] || return 1
	git -C "$REPO_ROOT" fetch origin main --quiet || return 1
	base_sha=$(git -C "$REPO_ROOT" rev-parse origin/main) || return 1
	stale_json=$(gh api "repos/${repo}/pulls/${stale_pr}" 2>/dev/null) || return 1
	jq -e --argjson stale "$stale_pr" --arg main "$_FULL_LOOP_AGGREGATE_RECOVERY_MAIN_BRANCH" '
		.number == $stale and .state == "open" and .base.ref == $main
		and (.head.sha | test("^[0-9a-f]{40}$"))
	' <<<"$stale_json" >/dev/null || return 1
	stale_body=$(jq -er '.body // ""' <<<"$stale_json") || return 1
	stale_head=$(jq -er '.head.sha' <<<"$stale_json") || return 1
	[[ "$stale_head" != "$base_sha" ]] || return 1
	stale_manifest=$(_full_loop_successor_manifest_from_body "$stale_pr" "$stale_body") || return 1
	release_lane_read "$repo" || return 1
	lane_manifest=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	lane_manifest=$(release_authorization_manifest_string "$lane_manifest") || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED=$(_full_loop_successor_complete_manifest \
		"$repo" "$stale_head" "$stale_manifest" "$lane_manifest") || return 1
	release_authorization_subset "$lane_manifest" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	branch_name="release/aggregate-successor-${stale_pr}-${base_sha:0:12}"
	release_lane_begin_aggregate_successor "$repo" "$stale_pr" "$base_sha" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$branch_name" || return 1
	branch_head=$(gh api "repos/${repo}/git/ref/heads/${branch_name}" --jq '.object.sha // empty' 2>/dev/null || true)
	if [[ -z "$branch_head" ]]; then
		initial_commit=$(_full_loop_successor_create_commit "$repo" "$base_sha" \
			"chore(release): open successor aggregation for #${stale_pr}") || return 1
		payload=$(jq -cn --arg ref "refs/heads/${branch_name}" --arg sha "$initial_commit" '{ref:$ref,sha:$sha}') || return 1
		gh api "repos/${repo}/git/refs" --method POST --input - <<<"$payload" >/dev/null 2>&1 || return 1
		branch_head="$initial_commit"
	fi
	git -C "$REPO_ROOT" fetch origin "$branch_name" --quiet || return 1
	git -C "$REPO_ROOT" merge-base --is-ancestor "$base_sha" FETCH_HEAD || return 1
	[[ "$(git -C "$REPO_ROOT" rev-parse "${base_sha}^{tree}")" == "$(git -C "$REPO_ROOT" rev-parse 'FETCH_HEAD^{tree}')" ]] || return 1
	successor_json=$(gh api "repos/${repo}/pulls?state=open&head=${owner}:${branch_name}&base=main" 2>/dev/null) || return 1
	jq -e 'length <= 1' <<<"$successor_json" >/dev/null || return 1
	successor_pr=$(jq -er 'if length == 1 then .[0].number else empty end' <<<"$successor_json" 2>/dev/null || true)
	if [[ -z "$successor_pr" ]]; then
		payload=$(jq -cn --arg title "chore(release): refresh aggregation after #${stale_pr}" \
			--arg head "$branch_name" --arg main "$_FULL_LOOP_AGGREGATE_RECOVERY_MAIN_BRANCH" \
			'{title:$title,head:$head,base:$main,draft:true,body:"Successor allocation pending immutable trailer commit."}') || return 1
		successor_pr=$(gh api "repos/${repo}/pulls" --method POST --input - --jq '.number // empty' \
			<<<"$payload" 2>/dev/null) || return 1
	else
		jq -e --arg main "$_FULL_LOOP_AGGREGATE_RECOVERY_MAIN_BRANCH" \
			'.[0].draft == true and .[0].base.ref == $main' <<<"$successor_json" >/dev/null || return 1
	fi
	[[ "$successor_pr" =~ ^[0-9]+$ ]] || return 1
	release_lane_bind_aggregate_successor_pr "$repo" "$successor_pr" || return 1
	body=$(_full_loop_successor_body "$stale_pr" "$base_sha" "$successor_pr" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED") || return 1
	final_message=$(_full_loop_successor_final_message "$successor_pr" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED") || return 1
	branch_message=$(gh api "repos/${repo}/git/commits/${branch_head}" --jq '.message // empty' 2>/dev/null) || return 1
	if [[ "$branch_message" != "$final_message" ]]; then
		final_commit=$(_full_loop_successor_create_commit "$repo" "$branch_head" "$final_message") || return 1
		payload=$(jq -cn --arg sha "$final_commit" '{sha:$sha,force:false}') || return 1
		gh api "repos/${repo}/git/refs/heads/${branch_name}" --method PATCH --input - <<<"$payload" >/dev/null 2>&1 || return 1
		branch_head="$final_commit"
	fi
	payload=$(jq -cn --arg body "$body" '{body:$body}') || return 1
	gh api "repos/${repo}/pulls/${successor_pr}" --method PATCH --input - <<<"$payload" >/dev/null 2>&1 || return 1
	release_lane_finish_aggregate_successor "$repo" "$successor_pr" "$branch_head" || return 1
	printf 'release:aggregate-successor draft_pr=%s stale_pr=%s exact_tip=%s\n' \
		"$successor_pr" "$stale_pr" "$base_sha"
	printf 'Review and guarded merge remain explicit; no release or publication was authorized.\n'
	return 0
}

_full_loop_release_recover_aggregate() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local expected_sources="$4"
	local prepared_rc=0
	local recovery_rc=0
	local transition_rc=0
	local current_tag_object=""
	local tag_sources=""
	_full_loop_recovery_validate_existing_tag "$repo" "$source_pr" "$tag_name" || return 1
	_full_loop_recovery_prepare_existing_context "$repo" "$source_pr" "$tag_name" "$expected_sources" || return 1
	case "$_FULL_LOOP_AGGREGATE_RECOVERY_EXISTING_CONTEXT" in
	remote-publication)
		_full_loop_recovery_resume_publication "$repo" "$source_pr" "$tag_name"
		return $?
		;;
	transaction)
		if _full_loop_recovery_tag_is_bound_to_current_aggregate "$tag_name"; then
			transition_rc=0
			_full_loop_recovery_transition_durable_publication "$repo" "$source_pr" "$tag_name" || transition_rc=$?
			if [[ "$transition_rc" -eq 0 ]]; then
				_full_loop_recovery_resume_publication "$repo" "$source_pr" "$tag_name"
				return $?
			fi
			[[ "$transition_rc" -eq 8 ]] || return 1
			current_tag_object=$(git -C "$REPO_ROOT" rev-parse \
				"${_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX}${tag_name}") || return 1
			if [[ "$current_tag_object" != "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" ]]; then
				transition_rc=0
				_full_loop_recovery_resume_committing_queue "$repo" "$source_pr" "$tag_name" || transition_rc=$?
				case "$transition_rc" in
				0)
					_full_loop_recovery_resume_publication "$repo" "$source_pr" "$tag_name"
					return $?
					;;
				8)
					_full_loop_recovery_report_pending_commit "$source_pr" "$tag_name"
					return $?
					;;
				*) return 1 ;;
				esac
			fi
		fi
		;;
	none) ;;
	*) return 1 ;;
	esac
	_full_loop_recovery_prepare_aggregate "$repo" "$source_pr" "$expected_sources" || return 1
	_full_loop_recovery_validate_receipt "$repo" "$source_pr" "$tag_name" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON" || return 1
	tag_sources=$(_full_loop_recovery_tag_sources) || return 1
	_full_loop_recovery_resume_prepared_state "$repo" "$source_pr" "$tag_name" "$tag_sources" || prepared_rc=$?
	case "$prepared_rc" in
	0 | 8) return "$prepared_rc" ;;
	2) ;;
	*) return 1 ;;
	esac
	release_authorization_subset "$tag_sources" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	_full_loop_recovery_verify_channels_absent "$repo" "$tag_name" || return 1
	_full_loop_recovery_begin_state_transaction "$repo" "$source_pr" "$tag_name" || return 1
	_full_loop_recovery_run_version_manager "$repo" "$source_pr" "$tag_name" || recovery_rc=$?
	if [[ "$recovery_rc" -ne 0 && "$recovery_rc" -ne 8 ]]; then
		_full_loop_recovery_handle_failed_version_manager "$repo" "$source_pr" "$tag_name"
		return $?
	fi
	_full_loop_recovery_finish_version_manager "$repo" "$source_pr" "$tag_name"
	return $?
}
