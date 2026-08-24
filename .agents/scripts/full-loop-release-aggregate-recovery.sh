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
_FULL_LOOP_AGGREGATE_RECOVERY_MANIFEST_JQ='sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")'
_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX='^[0-9a-f]{40}$'
_FULL_LOOP_AGGREGATE_RECOVERY_PHASE="aggregation-recovery"
_FULL_LOOP_AGGREGATE_COMMIT_PHASE="aggregate-publication-committing"
_FULL_LOOP_AGGREGATE_RECOVERY_TAG_REF_PREFIX="refs/tags/"

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
		--arg sha40 "$_FULL_LOOP_AGGREGATE_RECOVERY_SHA40_REGEX" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and ((.terminal_receipt // null) == null)
		and ((.phase | type) == "string") and ((.expected_sources | type) == "string")
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
		and ((.aggregate_recovery.previous_state.expected_sources | type) == "string")
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

_full_loop_recovery_reserved_lane_requires_migration() {
	local repo="$1"
	local source_pr="$2"
	local persisted_sources="$3"
	local read_rc=0
	local lane_sources=""
	local lane_prs=""
	local persisted_prs=""
	release_lane_read "$repo" || read_rc=$?
	case "$read_rc" in
	2) return 1 ;;
	0) ;;
	*) return 2 ;;
	esac
	jq -e --argjson source_pr "$source_pr" '
		.active == true and .source_pr == $source_pr and ((.terminal_receipt // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	if [[ "$(jq -r '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")" == "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" ]]; then
		return 0
	fi
	jq -e '.phase == "reserved" and .tag == null and (.expected_sources | type) == "string"' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	lane_sources=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 2
	lane_prs=$(release_authorization_intent_json "$lane_sources" | jq -c 'map(.pr)') || return 2
	persisted_prs=$(release_authorization_intent_json "$persisted_sources" | jq -c 'map(.pr)') || return 2
	[[ "$lane_prs" != "$persisted_prs" ]]
	return $?
}

_full_loop_recovery_expand_reserved_authorization() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="$3"
	local previous_auth=""
	local lane_sources=""
	local phase=""
	local current_auth=""
	local observed_auth=""
	local existing_tag_rc=0
	_full_loop_recovery_validate_reserved_receipt "$repo" "$source_pr" || return 1
	_full_loop_release_find_tag_for_pr "$repo" "$source_pr" || existing_tag_rc=$?
	[[ "$existing_tag_rc" -eq 2 ]] || return 1
	_full_loop_recovery_prepare_aggregate "$repo" "$source_pr" "$expected_sources" || return 1
	_full_loop_validate_release_candidates "$repo" "$_FULL_LOOP_RESOLVED_SOURCE_JSON" || return 1
	_full_loop_release_reset_tag_worktree || return 1
	current_auth=$(_full_loop_read_release_authorization "$repo" "$source_pr") || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" '
		.active == true and .source_pr == $source_pr and .tag == null
		and (.expected_sources | type) == "string" and (.phase | type) == "string"
		and ((.terminal_receipt // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || {
		printf 'Reserved release lane is not eligible for legacy authorization normalization for PR #%s\n' "$source_pr" >&2
		return 1
	}
	phase=$(jq -er '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	case "$phase" in
	reserved)
		lane_sources=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		;;
	"$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH")
		[[ "$(jq -r '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]] || return 1
		lane_sources=$(jq -er '.reserved_authorization_refresh.previous_expected_sources' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		;;
	*) return 1 ;;
	esac
	previous_auth=$(_full_loop_recovery_reserved_base_authorization "$repo" "$source_pr" \
		"$current_auth" "$lane_sources" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED") || {
		printf 'Reserved release lane authorization cannot be normalized against reviewed aggregate PR #%s\n' "$source_pr" >&2
		return 1
	}
	release_authorization_subset "$previous_auth" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	if [[ "$phase" == "reserved" && "$lane_sources" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" &&
		"$current_auth" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]]; then
		_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -er '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		_AIDEVOPS_RELEASE_LANE_RESULT="adopted"
		printf 'Reserved release authorization already matches the reviewed aggregate for PR #%s\n' "$source_pr"
		return 0
	fi
	release_lane_acquire "$repo" "$source_pr" "$lane_sources" || return $?
	case "$_AIDEVOPS_RELEASE_LANE_RESULT" in acquired | adopted) ;; *) return 1 ;; esac
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
