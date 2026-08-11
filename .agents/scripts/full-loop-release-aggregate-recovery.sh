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
	local tag_ref="refs/tags/${tag_name}"
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

_full_loop_recovery_validate_receipt() {
	local repo="$1"
	local source_pr="$2"
	local receipt_path=""
	local status=""
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$source_pr") || return 1
	[[ -f "$receipt_path" ]] && IFS= read -r status <"$receipt_path" || true
	case "$status" in
	"" | "$_FULL_LOOP_PHASE_FAILED") return 0 ;;
	esac
	printf 'Aggregate recovery refused: release receipt is terminal (%s)\n' "$status" >&2
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
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT=$(git -C "$REPO_ROOT" rev-parse "refs/tags/${tag_name}") || return 1
	_full_loop_release_reset_tag_worktree || return 1
	return 0
}

_full_loop_recovery_tag_sources() {
	local expected_json=""
	local observed_json=""
	expected_json=$(release_authorization_manifest_json "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED") || return 1
	observed_json=$(release_authorization_observed_sources_json "$expected_json" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON") || return 1
	jq -r 'map("\(.pr)@\(.merge)") | join(",")' <<<"$observed_json"
	return $?
}

_full_loop_recovery_tag_is_bound_to_current_aggregate() {
	local tag_name="$1"
	local tag_parent=""
	local aggregate_merge="${_FULL_LOOP_RESOLVED_SOURCE_MERGE:-}"
	[[ "$aggregate_merge" =~ ^[0-9a-f]{40}$ ]] || return 1
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
	previous_record=$(_full_loop_read_release_authorization_recovery_snapshot "$repo" "$source_pr") || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH=$(jq -r '
		.expected_sources | sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")
	' <<<"$previous_record") || return 1
	release_authorization_subset "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
		--arg expected "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .expected_sources == $expected
		and (.phase == "aggregation-recovery" or .phase == "remote-publication")
		and ((.terminal_receipt // null) == null)
		and (.aggregate_recovery.provisional_tag_object | test("^[0-9a-f]{40}$"))
		and (.aggregate_recovery.previous_state.schema_version == 1)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_LANE_SNAPSHOT=$(jq -ce '.aggregate_recovery.previous_state' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT=$(jq -er '.aggregate_recovery.provisional_tag_object' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -er '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
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
		| map("\(.pr)@\(.merge)") | join(",")
	' 2>/dev/null
	return $?
}

_full_loop_recovery_expand_reserved_authorization() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="$3"
	local previous_auth=""
	local lane_sources=""
	local normalized_lane_sources=""
	local authorization_expanded=false
	local existing_tag_rc=0
	_full_loop_recovery_validate_receipt "$repo" "$source_pr" || return 1
	_full_loop_release_find_tag_for_pr "$repo" "$source_pr" || existing_tag_rc=$?
	[[ "$existing_tag_rc" -eq 2 ]] || return 1
	_full_loop_recovery_prepare_aggregate "$repo" "$source_pr" "$expected_sources" || return 1
	_full_loop_validate_release_candidates "$repo" "$_FULL_LOOP_RESOLVED_SOURCE_JSON" || return 1
	_full_loop_release_reset_tag_worktree || return 1
	previous_auth=$(_full_loop_read_release_authorization "$repo" "$source_pr") || return 1
	release_authorization_subset "$previous_auth" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" '
		.active == true and .source_pr == $source_pr and .phase == "reserved"
		and .tag == null and (.expected_sources | type) == "string"
		and ((.terminal_receipt // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || {
		printf 'Reserved release lane is not eligible for legacy authorization normalization for PR #%s\n' "$source_pr" >&2
		return 1
	}
	lane_sources=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	normalized_lane_sources=$(_full_loop_recovery_resolve_lane_authorization \
		"$lane_sources" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED") || {
		printf 'Reserved release lane authorization cannot be normalized against reviewed aggregate PR #%s\n' "$source_pr" >&2
		return 1
	}
	if ! release_authorization_compare "$normalized_lane_sources" "$previous_auth"; then
		printf 'Reserved release lane and persisted authorization identify different sources for PR #%s\n' "$source_pr" >&2
		return 1
	fi
	release_lane_acquire "$repo" "$source_pr" "$lane_sources" || return $?
	[[ "$_AIDEVOPS_RELEASE_LANE_RESULT" == "acquired" ]] || return 1
	if [[ "$previous_auth" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" &&
		"$lane_sources" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]]; then
		printf 'Reserved release authorization already matches the reviewed aggregate for PR #%s\n' "$source_pr"
		return 0
	fi
	if [[ "$previous_auth" != "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]]; then
		_full_loop_expand_release_authorization_for_aggregate "$repo" "$source_pr" \
			"$previous_auth" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
		authorization_expanded=true
	fi
	if ! release_lane_expand_reserved_authorization "$repo" "$source_pr" "$lane_sources" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED"; then
		release_lane_restore_reserved_authorization "$repo" "$source_pr" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT" || true
		if [[ "$authorization_expanded" == "true" ]]; then
			_full_loop_restore_release_authorization_after_aggregate "$repo" "$source_pr" \
				"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$previous_auth" || return 1
		fi
		printf 'Reserved release lane authorization migration failed for PR #%s; prior state was restored\n' "$source_pr" >&2
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
			_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH=$(
				_full_loop_read_release_authorization_recovery_snapshot "$repo" "$source_pr" |
					jq -r '.expected_sources | sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")'
			) || return 1
		else
			_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH="$existing"
			_full_loop_expand_release_authorization_for_aggregate "$repo" "$source_pr" \
				"$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
		fi
	else
		_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH="$existing"
		release_authorization_subset "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
		_full_loop_expand_release_authorization_for_aggregate "$repo" "$source_pr" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	fi
	if ! release_lane_read "$repo"; then
		_full_loop_restore_release_authorization_after_aggregate "$repo" "$source_pr" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" || true
		return 1
	fi
	if ! lane_expected=$(jq -er '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON"); then
		_full_loop_restore_release_authorization_after_aggregate "$repo" "$source_pr" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" || true
		return 1
	fi
	if ! release_lane_begin_aggregate_recovery "$repo" "$source_pr" "$tag_name" "$lane_expected" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT"; then
		_full_loop_restore_release_authorization_after_aggregate "$repo" "$source_pr" \
			"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" || true
		return 1
	fi
	_FULL_LOOP_AGGREGATE_RECOVERY_LANE_SNAPSHOT="$_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT"
	return 0
}

_full_loop_recovery_resume_publication() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local new_tag_object=""
	local reconcile_rc=0
	new_tag_object=$(git -C "$REPO_ROOT" rev-parse "refs/tags/${tag_name}") || return 1
	_full_loop_recovery_write_evidence "$repo" "$source_pr" "$tag_name" "$new_tag_object" || return 1
	_full_loop_release_existing_with_lane reconcile "$source_pr" || reconcile_rc=$?
	case "$reconcile_rc" in
	0 | 8) return "$reconcile_rc" ;;
	esac
	return 1
}

_full_loop_recovery_restore_state_transaction() {
	local repo="$1"
	local source_pr="$2"
	local restored=0
	release_lane_restore_aggregate_recovery "$repo" "$source_pr" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_LANE_SNAPSHOT" || restored=1
	_full_loop_restore_release_authorization_after_aggregate "$repo" "$source_pr" \
		"$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" || restored=1
	[[ "$restored" -eq 0 ]]
	return $?
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
	local source_pr="$1"
	local tag_name="$2"
	local version_manager="$_FULL_LOOP_RELEASE_PATH/.agents/scripts/version-manager.sh"
	local recovery_rc=0
	(
		cd "$_FULL_LOOP_RELEASE_PATH" || exit 1
		AIDEVOPS_RELEASE_INTENT_TRUSTED=1 bash "$version_manager" recover-aggregate \
			--tag "$tag_name" --source-pr "$source_pr" \
			--expected-sources "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" \
			--old-tag-object "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT"
	) || recovery_rc=$?
	case "$recovery_rc" in
	0 | 8) return "$recovery_rc" ;;
	esac
	return 1
}

_full_loop_recovery_tag_rollback_safe() {
	local repo="$1"
	local tag_name="$2"
	local current_object=""
	current_object=$(git -C "$REPO_ROOT" rev-parse "refs/tags/${tag_name}" 2>/dev/null) || return 1
	[[ "$current_object" == "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" ]] || return 1
	_full_loop_recovery_verify_channels_absent "$repo" "$tag_name" || return 1
	return 0
}

_full_loop_release_recover_aggregate() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local expected_sources="$4"
	local recovery_rc=0
	local resume_rc=0
	local new_tag_object=""
	local tag_sources=""
	_full_loop_recovery_validate_receipt "$repo" "$source_pr" || return 1
	_full_loop_recovery_validate_existing_tag "$repo" "$source_pr" "$tag_name" || return 1
	_full_loop_recovery_prepare_aggregate "$repo" "$source_pr" "$expected_sources" || return 1
	tag_sources=$(_full_loop_recovery_tag_sources) || return 1
	if [[ "$tag_sources" == "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" ]]; then
		if _full_loop_recovery_load_existing_state_transaction "$repo" "$source_pr" "$tag_name"; then
			_full_loop_recovery_resume_publication "$repo" "$source_pr" "$tag_name"
			return $?
		fi
		_full_loop_recovery_tag_is_bound_to_current_aggregate "$tag_name" && return 1
	fi
	release_authorization_subset "$tag_sources" "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" || return 1
	_full_loop_recovery_verify_channels_absent "$repo" "$tag_name" || return 1
	_full_loop_recovery_begin_state_transaction "$repo" "$source_pr" "$tag_name" || return 1
	_full_loop_recovery_run_version_manager "$source_pr" "$tag_name" || recovery_rc=$?
	if [[ "$recovery_rc" -ne 0 && "$recovery_rc" -ne 8 ]]; then
		# A protected-main PR can be created after the replacement tag is durable
		# but before version-manager reports its normal queued exit. Reconcile the
		# exact tag before treating that post-mutation state as a failure.
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
		if _full_loop_recovery_tag_rollback_safe "$repo" "$tag_name"; then
			_full_loop_recovery_restore_state_transaction "$repo" "$source_pr" || true
		else
			printf 'Aggregate recovery failed after tag state changed; expanded recovery state was retained for reconciliation\n' >&2
		fi
		return 1
	fi
	new_tag_object=$(git -C "$REPO_ROOT" rev-parse "refs/tags/${tag_name}") || return 1
	_full_loop_recovery_write_evidence "$repo" "$source_pr" "$tag_name" "$new_tag_object" || return 1
	release_lane_update "$repo" "$source_pr" remote-publication "$tag_name" || return 1
	printf 'release:aggregate-recovery queued tag=%s source_pr=%s\n' "$tag_name" "$source_pr"
	printf 'Resume with: aidevops release status %s\n' "$source_pr"
	printf 'Resume with: aidevops release reconcile %s\n' "$source_pr"
	return 8
}
