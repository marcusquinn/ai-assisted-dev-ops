#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Repository-scoped, remote compare-and-swap lane for aidevops releases.

[[ -n "${_AIDEVOPS_RELEASE_LANE_LOADED:-}" ]] && return 0
_AIDEVOPS_RELEASE_LANE_LOADED=1

_AIDEVOPS_RELEASE_LANE_BRANCH="aidevops/release-lane"
_AIDEVOPS_RELEASE_LANE_FILE=".aidevops-release-lane.json"
_AIDEVOPS_RELEASE_LANE_HEAD=""
_AIDEVOPS_RELEASE_LANE_JSON=""
_AIDEVOPS_RELEASE_LANE_RESULT=""
_AIDEVOPS_RELEASE_LANE_TOKEN=""
_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT=""
_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED="reserved"
_AIDEVOPS_RELEASE_LANE_JSON_STRING_TYPE="string"
_AIDEVOPS_RELEASE_LANE_RESULT_ACQUIRED="acquired"
_AIDEVOPS_RELEASE_LANE_TOKEN_PREFIX="lane-"
_AIDEVOPS_RELEASE_LANE_OWNER_PREFIX="process-"
_AIDEVOPS_RELEASE_LANE_STALE_PREPUBLICATION_SECONDS=300
_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_RECOVERY="aggregation-recovery"
_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_REFRESH="aggregation-recovery-refresh"
_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATE_COMMIT="aggregate-publication-committing"
_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH="reserved-authorization-refresh"
_AIDEVOPS_RELEASE_LANE_PHASE_RECONCILE_REQUIRED="reconcile-required"
_AIDEVOPS_RELEASE_LANE_PHASE_SUCCESSOR_PREPARING="aggregation-successor-preparing"

_release_lane_cache_path() {
	local repo="$1"
	local key="${repo//\//-}"
	printf '%s/release-lanes/%s.json\n' "${AIDEVOPS_STATE_DIR:-${HOME}/.aidevops/state}" "$key"
	return 0
}

_release_lane_cache_write() {
	local repo="$1"
	local state_json="$2"
	local cache_path=""
	cache_path=$(_release_lane_cache_path "$repo") || return 1
	mkdir -p "${cache_path%/*}" || return 1
	printf '%s\n' "$state_json" >"${cache_path}.tmp.$$" || return 1
	mv "${cache_path}.tmp.$$" "$cache_path" || return 1
	return 0
}

_release_lane_remote_head() {
	local repo="$1"
	local endpoint="repos/${repo}/git/ref/heads/${_AIDEVOPS_RELEASE_LANE_BRANCH}"
	local head=""
	local response=""
	local status_line=""
	local status_code=""
	head=$(gh api "$endpoint" --jq '.object.sha // empty' 2>/dev/null) && {
		printf '%s\n' "$head"
		return 0
	}
	response=$(gh api --include --silent "$endpoint" 2>/dev/null || true)
	status_line="${response%%$'\n'*}"
	status_code=$(printf '%s' "$status_line" | cut -d ' ' -f 2)
	[[ "$status_code" == "404" ]] && return 2
	return 1
}

release_lane_read() {
	local repo="$1"
	local head=""
	local state_json=""
	local head_rc=0
	_AIDEVOPS_RELEASE_LANE_HEAD=""
	_AIDEVOPS_RELEASE_LANE_JSON=""
	head=$(_release_lane_remote_head "$repo") || head_rc=$?
	case "$head_rc" in
	0) ;;
	2) return 2 ;;
	*) return 1 ;;
	esac
	[[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
	state_json=$(gh api "repos/${repo}/contents/${_AIDEVOPS_RELEASE_LANE_FILE}?ref=${head}" \
		--jq '.content | @base64d' 2>/dev/null) || return 1
	jq -e --arg repo "$repo" --arg string_type "$_AIDEVOPS_RELEASE_LANE_JSON_STRING_TYPE" '
		.schema_version == 1 and .repository == $repo
		and (.active | type == "boolean") and (.source_pr | type == "number")
		and (.phase | type == $string_type) and (.updated_at | type == $string_type)
		and (.operation_token | type == $string_type) and (.operation_token | length > 0)
		and ((.tag == null) or (.tag | type == $string_type))
	' <<<"$state_json" >/dev/null || return 1
	_AIDEVOPS_RELEASE_LANE_HEAD="$head"
	_AIDEVOPS_RELEASE_LANE_JSON="$state_json"
	_release_lane_cache_write "$repo" "$state_json" || return 1
	return 0
}

_release_lane_create_commit() {
	local repo="$1"
	local parent="$2"
	local state_json="$3"
	local base_tree="" blob_sha="" tree_sha="" commit_sha="" payload=""
	base_tree=$(gh api "repos/${repo}/git/commits/${parent}" --jq '.tree.sha // empty' 2>/dev/null) || return 1
	[[ "$base_tree" =~ ^[0-9a-f]{40}$ ]] || return 1
	payload=$(jq -cn --arg content "$state_json" '{content:$content,encoding:"utf-8"}') || return 1
	blob_sha=$(gh api "repos/${repo}/git/blobs" --method POST --input - --jq '.sha // empty' <<<"$payload" 2>/dev/null) || return 1
	[[ "$blob_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	payload=$(jq -cn --arg base "$base_tree" --arg path "$_AIDEVOPS_RELEASE_LANE_FILE" --arg sha "$blob_sha" \
		'{base_tree:$base,tree:[{path:$path,mode:"100644",type:"blob",sha:$sha}]}') || return 1
	tree_sha=$(gh api "repos/${repo}/git/trees" --method POST --input - --jq '.sha // empty' <<<"$payload" 2>/dev/null) || return 1
	[[ "$tree_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	payload=$(jq -cn --arg message "chore(release): update repository release lane" --arg tree "$tree_sha" \
		--arg parent "$parent" '{message:$message,tree:$tree,parents:[$parent]}') || return 1
	commit_sha=$(gh api "repos/${repo}/git/commits" --method POST --input - --jq '.sha // empty' <<<"$payload" 2>/dev/null) || return 1
	[[ "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	printf '%s\n' "$commit_sha"
	return 0
}

_release_lane_write() {
	local repo="$1"
	local state_json="$2"
	local expected_head="${3:-}"
	local parent="$expected_head" commit_sha="" payload="" current_head=""
	if [[ -z "$parent" ]]; then
		parent=$(gh api "repos/${repo}/git/ref/heads/main" --jq '.object.sha // empty' 2>/dev/null) || return 1
	fi
	[[ "$parent" =~ ^[0-9a-f]{40}$ ]] || return 1
	commit_sha=$(_release_lane_create_commit "$repo" "$parent" "$state_json") || return 1
	if [[ -z "$expected_head" ]]; then
		payload=$(jq -cn --arg ref "refs/heads/${_AIDEVOPS_RELEASE_LANE_BRANCH}" --arg sha "$commit_sha" '{ref:$ref,sha:$sha}') || return 1
		gh api "repos/${repo}/git/refs" --method POST --input - <<<"$payload" >/dev/null 2>&1 || return 2
	else
		current_head=$(_release_lane_remote_head "$repo") || return 2
		[[ "$current_head" == "$expected_head" ]] || return 2
		payload=$(jq -cn --arg sha "$commit_sha" '{sha:$sha,force:false}') || return 1
		gh api "repos/${repo}/git/refs/heads/${_AIDEVOPS_RELEASE_LANE_BRANCH}" --method PATCH --input - \
			<<<"$payload" >/dev/null 2>&1 || return 2
	fi
	_AIDEVOPS_RELEASE_LANE_HEAD="$commit_sha"
	_AIDEVOPS_RELEASE_LANE_JSON="$state_json"
	_release_lane_cache_write "$repo" "$state_json" || return 1
	return 0
}

_release_lane_stale_prepublication() {
	local state_json="$1"
	local phase=""
	local tag_name=""
	local updated_at=""
	local updated_epoch=""
	local now_epoch=""
	local stale_after="${AIDEVOPS_RELEASE_LANE_STALE_SECONDS:-$_AIDEVOPS_RELEASE_LANE_STALE_PREPUBLICATION_SECONDS}"
	[[ "$stale_after" =~ ^[0-9]+$ && "$stale_after" -gt 0 ]] || return 1
	phase=$(jq -r '.phase' <<<"$state_json") || return 1
	tag_name=$(jq -r '.tag // ""' <<<"$state_json") || return 1
	updated_at=$(jq -r '.updated_at // ""' <<<"$state_json") || return 1
	# Only reservation is side-effect free. Once preparation starts, recovery is
	# reconcile-only because the original process may already be publishing.
	[[ "$phase" == "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" ]] || return 1
	[[ -z "$tag_name" ]] || return 1
	jq -e '(.terminal_receipt // null) == null' <<<"$state_json" >/dev/null || return 1
	jq -e '(.prepublication_recovery // null) == null' <<<"$state_json" >/dev/null || return 1
	updated_epoch=$(date -u -d "$updated_at" +%s 2>/dev/null ||
		date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$updated_at" +%s 2>/dev/null || true)
	now_epoch=$(date +%s 2>/dev/null || true)
	[[ "$updated_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ && "$now_epoch" -ge "$updated_epoch" ]] || return 1
	[[ $((now_epoch - updated_epoch)) -ge "$stale_after" ]]
	return $?
}

_release_lane_reclaim_same_source() {
	local repo="$1"
	local source_pr="$2"
	local state_json=""
	local operation_token=""
	_release_lane_stale_prepublication "$_AIDEVOPS_RELEASE_LANE_JSON" || return 3
	operation_token="${_AIDEVOPS_RELEASE_LANE_TOKEN_PREFIX}$(date +%s)-$$-${RANDOM:-0}"
	state_json=$(jq -c --arg owner "${_AIDEVOPS_RELEASE_LANE_OWNER_PREFIX}$$" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" --arg token "$operation_token" \
		'.owner=$owner | .operation_token=$token | .updated_at=$now | .phase=$reserved' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || return $?
	_AIDEVOPS_RELEASE_LANE_TOKEN="$operation_token"
	_AIDEVOPS_RELEASE_LANE_RESULT="$_AIDEVOPS_RELEASE_LANE_RESULT_ACQUIRED"
	printf 'Recovered stale pre-publication release lane for PR #%s\n' "$source_pr"
	return 0
}

release_lane_acquire() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="$3"
	local read_rc=0 active="false" active_pr="" phase="" now="" state_json=""
	local reclaim_rc=0
	local operation_token=""
	_AIDEVOPS_RELEASE_LANE_RESULT=""
	release_lane_read "$repo" || read_rc=$?
	case "$read_rc" in
	0)
		active=$(jq -r '.active' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		active_pr=$(jq -r '.source_pr' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		phase=$(jq -r '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		if [[ "$active" == "true" ]]; then
			printf 'ACTIVE_RELEASE_LANE source_pr=%s phase=%s tag=%s\n' "$active_pr" "$phase" \
				"$(jq -r '.tag // "pending"' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")"
			printf 'Inspect with: aidevops release status %s\n' "$active_pr"
			printf 'Resume with: aidevops release reconcile %s\n' "$active_pr"
			if [[ "$active_pr" == "$source_pr" ]]; then
				_release_lane_reclaim_same_source "$repo" "$source_pr" || reclaim_rc=$?
				case "$reclaim_rc" in
				0) return 0 ;;
				3) ;;
				*) return "$reclaim_rc" ;;
				esac
				_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -r '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
				_AIDEVOPS_RELEASE_LANE_RESULT="adopted"
				return 0
			fi
			return 75
		fi
		;;
	2) _AIDEVOPS_RELEASE_LANE_HEAD="" ;;
	*) return 1 ;;
	esac
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	operation_token="${_AIDEVOPS_RELEASE_LANE_TOKEN_PREFIX}$(date +%s)-$$-${RANDOM:-0}"
	state_json=$(jq -cn --arg repo "$repo" --argjson source_pr "$source_pr" --arg expected_sources "$expected_sources" \
		--arg now "$now" --arg owner "${_AIDEVOPS_RELEASE_LANE_OWNER_PREFIX}$$" --arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" \
		--arg token "$operation_token" \
		'{schema_version:1,repository:$repo,active:true,
		source_pr:$source_pr,expected_sources:$expected_sources,phase:$reserved,tag:null,owner:$owner,operation_token:$token,
		updated_at:$now,terminal_receipt:null}') || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || return $?
	_AIDEVOPS_RELEASE_LANE_TOKEN="$operation_token"
	_AIDEVOPS_RELEASE_LANE_RESULT="$_AIDEVOPS_RELEASE_LANE_RESULT_ACQUIRED"
	return 0
}

# Claim the single metadata-only successor slot before creating a branch or PR.
# The exact main tip and immutable source manifest make retries convergent; a
# different target cannot replace an in-flight transaction.
#aidevops:trust-boundary
release_lane_begin_aggregate_successor() {
	local repo="$1"
	local stale_pr="$2"
	local base_sha="$3"
	local expected_sources="$4"
	local branch_name="$5"
	local phase=""
	local operation_token=""
	local previous_state=""
	local state_json=""
	[[ "$stale_pr" =~ ^[0-9]+$ && "$base_sha" =~ ^[0-9a-f]{40}$ && -n "$expected_sources" && -n "$branch_name" ]] || return 1
	release_lane_read "$repo" || return 1
	if jq -e --argjson stale "$stale_pr" --arg base "$base_sha" --arg expected "$expected_sources" \
		--arg branch "$branch_name" --arg preparing "$_AIDEVOPS_RELEASE_LANE_PHASE_SUCCESSOR_PREPARING" '
		.active == true and .phase == $preparing
		and .aggregate_successor.stale_pr == $stale
		and .aggregate_successor.base_sha == $base
		and .aggregate_successor.expected_sources == $expected
		and .aggregate_successor.branch == $branch
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
		_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -er '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		return 0
	fi
	phase=$(jq -er '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	jq -e '.active == true' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	[[ "$phase" != "$_AIDEVOPS_RELEASE_LANE_PHASE_SUCCESSOR_PREPARING" ]] || return 1
	previous_state=$(jq -c 'del(.aggregate_successor)' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	operation_token="${_AIDEVOPS_RELEASE_LANE_TOKEN_PREFIX}$(date +%s)-$$-${RANDOM:-0}"
	state_json=$(jq -c --argjson stale "$stale_pr" --arg base "$base_sha" \
		--arg expected "$expected_sources" --arg branch "$branch_name" --arg token "$operation_token" \
		--arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--arg preparing "$_AIDEVOPS_RELEASE_LANE_PHASE_SUCCESSOR_PREPARING" --argjson previous "$previous_state" '
		.phase=$preparing | .operation_token=$token | .updated_at=$now
		| .aggregate_successor={status:"preparing",stale_pr:$stale,base_sha:$base,
			expected_sources:$expected,branch:$branch,previous_state:$previous}
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || return $?
	_AIDEVOPS_RELEASE_LANE_TOKEN="$operation_token"
	return 0
}

# Persist the allocated PR before the immutable trailer commit is written.
#aidevops:trust-boundary
release_lane_bind_aggregate_successor_pr() {
	local repo="$1"
	local successor_pr="$2"
	local state_json=""
	[[ "$successor_pr" =~ ^[0-9]+$ && -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" \
		--arg preparing "$_AIDEVOPS_RELEASE_LANE_PHASE_SUCCESSOR_PREPARING" \
		--argjson successor "$successor_pr" '
		.active == true and .phase == $preparing and .operation_token == $token
		and ((.aggregate_successor.pr // $successor) == $successor)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	state_json=$(jq -c --argjson successor "$successor_pr" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
		.aggregate_successor.pr=$successor | .updated_at=$now
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || return $?
	return 0
}

# Restore the exact prior lane phase while retaining a durable adoption record.
#aidevops:trust-boundary
release_lane_finish_aggregate_successor() {
	local repo="$1"
	local successor_pr="$2"
	local head_sha="$3"
	local state_json=""
	local previous_state=""
	[[ "$successor_pr" =~ ^[0-9]+$ && "$head_sha" =~ ^[0-9a-f]{40}$ && -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" --argjson successor "$successor_pr" \
		--arg preparing "$_AIDEVOPS_RELEASE_LANE_PHASE_SUCCESSOR_PREPARING" '
		.active == true and .phase == $preparing and .operation_token == $token
		and .aggregate_successor.pr == $successor
		and .aggregate_successor.previous_state.schema_version == 1
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	previous_state=$(jq -ce '.aggregate_successor.previous_state' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	state_json=$(jq -c --argjson successor "$successor_pr" --arg head "$head_sha" \
		--arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson transaction "$_AIDEVOPS_RELEASE_LANE_JSON" '
		. as $previous
		| $transaction.aggregate_successor as $successor_state
		| .operation_token=$transaction.operation_token | .updated_at=$now
		| .aggregate_successor=($successor_state | del(.previous_state)
			| .status="ready" | .pr=$successor | .head_sha=$head | .completed_at=$now)
	' <<<"$previous_state") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || return $?
	return 0
}

release_lane_begin_aggregate_recovery() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local lane_sources="$4"
	local previous_sources="$5"
	local expected_sources="$6"
	local provisional_tag_object="${7:-}"
	local operation_token=""
	local state_json=""
	local snapshot_json=""
	local write_rc=0
	[[ -n "$lane_sources" && -n "$previous_sources" && -n "$expected_sources" ]] || return 1
	[[ "$provisional_tag_object" =~ ^[0-9a-f]{40}$ ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" --arg previous "$lane_sources" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .expected_sources == $previous
		and (.phase == "remote-publication" or .phase == "reconcile-required")
		and ((.terminal_receipt // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT="$_AIDEVOPS_RELEASE_LANE_JSON"
	snapshot_json="$_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT"
	operation_token="${_AIDEVOPS_RELEASE_LANE_TOKEN_PREFIX}$(date +%s)-$$-${RANDOM:-0}"
	state_json=$(jq -c --arg expected "$expected_sources" --arg token "$operation_token" \
		--arg prior "$previous_sources" --arg owner "${_AIDEVOPS_RELEASE_LANE_OWNER_PREFIX}$$" \
		--arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg provisional "$provisional_tag_object" \
		--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_REFRESH" \
		--argjson previous "$snapshot_json" '
		.expected_sources=$expected | .operation_token=$token | .owner=$owner
		| .phase=$refresh | .updated_at=$now
		| .aggregate_recovery={previous_state:$previous,provisional_tag_object:$provisional,
			refresh:{previous_expected_sources:$prior,pending_expected_sources:$expected}}
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || write_rc=$?
	if [[ "$write_rc" -ne 0 ]]; then
		release_lane_read "$repo" || return "$write_rc"
		jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" --arg token "$operation_token" \
			--arg expected "$expected_sources" --arg previous "$previous_sources" \
			--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_REFRESH" \
			--arg provisional "$provisional_tag_object" '
			.active == true and .source_pr == $source_pr and .tag == $tag
			and .operation_token == $token and .phase == $refresh
			and .expected_sources == $expected and ((.terminal_receipt // null) == null)
			and .aggregate_recovery.provisional_tag_object == $provisional
			and .aggregate_recovery.refresh.previous_expected_sources == $previous
			and .aggregate_recovery.refresh.pending_expected_sources == $expected
		' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return "$write_rc"
	fi
	_AIDEVOPS_RELEASE_LANE_TOKEN="$operation_token"
	return 0
}

release_lane_begin_aggregate_refresh() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local previous_sources="$4"
	local expected_sources="$5"
	local provisional_tag_object="$6"
	local operation_token=""
	local state_json=""
	local write_rc=0
	[[ -n "$previous_sources" && -n "$expected_sources" && "$previous_sources" != "$expected_sources" ]] || return 1
	[[ "$provisional_tag_object" =~ ^[0-9a-f]{40}$ ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" --arg previous "$previous_sources" \
		--arg provisional "$provisional_tag_object" --arg recovery "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_RECOVERY" \
		--arg committing "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATE_COMMIT" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .expected_sources == $previous and (.phase == $recovery or .phase == $committing)
		and ((.terminal_receipt // null) == null)
		and .aggregate_recovery.provisional_tag_object == $provisional
		and (.aggregate_recovery.previous_state.schema_version == 1)
		and ((.aggregate_recovery.previous_state.aggregate_recovery // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	operation_token="${_AIDEVOPS_RELEASE_LANE_TOKEN_PREFIX}$(date +%s)-$$-${RANDOM:-0}"
	state_json=$(jq -c --arg expected "$expected_sources" --arg token "$operation_token" \
		--arg previous "$previous_sources" --arg owner "${_AIDEVOPS_RELEASE_LANE_OWNER_PREFIX}$$" \
		--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_REFRESH" \
		--arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
		.expected_sources=$expected | .operation_token=$token | .owner=$owner
		| .phase=$refresh | .updated_at=$now
		| .aggregate_recovery.refresh={previous_expected_sources:$previous,pending_expected_sources:$expected}
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || write_rc=$?
	if [[ "$write_rc" -ne 0 ]]; then
		release_lane_read "$repo" || return "$write_rc"
		jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" --arg token "$operation_token" \
			--arg expected "$expected_sources" --arg previous "$previous_sources" \
			--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_REFRESH" \
			--arg provisional "$provisional_tag_object" '
			.active == true and .source_pr == $source_pr and .tag == $tag
			and .operation_token == $token and .phase == $refresh
			and .expected_sources == $expected and ((.terminal_receipt // null) == null)
			and .aggregate_recovery.provisional_tag_object == $provisional
			and .aggregate_recovery.refresh.previous_expected_sources == $previous
			and .aggregate_recovery.refresh.pending_expected_sources == $expected
		' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return "$write_rc"
	fi
	_AIDEVOPS_RELEASE_LANE_TOKEN="$operation_token"
	return 0
}

release_lane_finish_aggregate_refresh() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local previous_sources="$4"
	local expected_sources="$5"
	local provisional_tag_object="$6"
	local state_json=""
	local write_rc=0
	[[ -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
		--arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" --arg previous "$previous_sources" \
		--arg expected "$expected_sources" --arg provisional "$provisional_tag_object" \
		--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_REFRESH" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .operation_token == $token and .phase == $refresh
		and .expected_sources == $expected and ((.terminal_receipt // null) == null)
		and .aggregate_recovery.provisional_tag_object == $provisional
		and .aggregate_recovery.refresh.previous_expected_sources == $previous
		and .aggregate_recovery.refresh.pending_expected_sources == $expected
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	state_json=$(jq -c --arg recovery "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_RECOVERY" \
		--arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
		.phase=$recovery | .updated_at=$now | del(.aggregate_recovery.refresh)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || write_rc=$?
	if [[ "$write_rc" -ne 0 ]]; then
		release_lane_read "$repo" || return "$write_rc"
		jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
			--arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" --arg expected "$expected_sources" \
			--arg provisional "$provisional_tag_object" \
			--arg recovery "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_RECOVERY" '
			.active == true and .source_pr == $source_pr and .tag == $tag
			and .operation_token == $token and .phase == $recovery
			and .expected_sources == $expected and ((.terminal_receipt // null) == null)
			and .aggregate_recovery.provisional_tag_object == $provisional
			and ((.aggregate_recovery.refresh // null) == null)
		' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return "$write_rc"
	fi
	return 0
}

release_lane_claim_aggregate_publication() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local expected_sources="$4"
	local state_json=""
	local write_rc=0
	[[ -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	if jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
		--arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" --arg expected "$expected_sources" \
		--arg committing "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATE_COMMIT" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .operation_token == $token and .phase == $committing
		and .expected_sources == $expected and ((.terminal_receipt // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
		return 0
	fi
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
		--arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" --arg expected "$expected_sources" \
		--arg recovery "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_RECOVERY" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .operation_token == $token and .phase == $recovery
		and .expected_sources == $expected and ((.terminal_receipt // null) == null)
		and ((.aggregate_recovery.refresh // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	state_json=$(jq -c --arg committing "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATE_COMMIT" \
		--arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '.phase=$committing | .updated_at=$now' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || write_rc=$?
	if [[ "$write_rc" -ne 0 ]]; then
		release_lane_read "$repo" || return "$write_rc"
		jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
			--arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" --arg expected "$expected_sources" \
			--arg committing "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATE_COMMIT" '
			.active == true and .source_pr == $source_pr and .tag == $tag
			and .operation_token == $token and .phase == $committing
			and .expected_sources == $expected and ((.terminal_receipt // null) == null)
		' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return "$write_rc"
	fi
	return 0
}

release_lane_verify_aggregate_publication() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local expected_sources="$4"
	[[ -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg tag "$tag_name" \
		--arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" --arg expected "$expected_sources" \
		--arg committing "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATE_COMMIT" '
		.active == true and .source_pr == $source_pr and .tag == $tag
		and .operation_token == $token and .phase == $committing
		and .expected_sources == $expected and ((.terminal_receipt // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null
	return $?
}

#aidevops:trust-boundary
release_lane_reopen_failed_prepublication() {
	local repo="$1"
	local source_pr="$2"
	local failed_expected_sources="$3"
	local failed_source_pr="$4"
	local failed_source_merge="$5"
	local attempted_tag="${6:-}"
	local operation_token=""
	local state_json=""
	local write_rc=0
	[[ "$source_pr" =~ ^[0-9]+$ && "$failed_source_pr" =~ ^[0-9]+$ ]] || return 1
	[[ "$failed_source_merge" =~ ^[0-9a-f]{40}$ && "$attempted_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	[[ -n "$failed_expected_sources" ]] || return 1
	[[ -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" \
		--arg failed_expected "$failed_expected_sources" --arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" \
		--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" \
		--arg reconcile "$_AIDEVOPS_RELEASE_LANE_PHASE_RECONCILE_REQUIRED" \
		--arg string_type "$_AIDEVOPS_RELEASE_LANE_JSON_STRING_TYPE" \
		--argjson failed_source_pr "$failed_source_pr" --arg failed_source_merge "$failed_source_merge" \
		--arg attempted_tag "$attempted_tag" '
		(.prepublication_recovery // null) as $recovery
		| (($recovery != null) and (($recovery | type) == "object")
			and $recovery.previous_phase == $reconcile
			and (($recovery.previous_updated_at | type) == $string_type)
			and (($recovery.recovered_at | type) == $string_type)
			and $recovery.failed_source_pr == $failed_source_pr
			and $recovery.failed_source_merge == $failed_source_merge
			and $recovery.attempted_tag == $attempted_tag
			and $recovery.failed_expected_sources == $failed_expected
			and (($recovery.current_expected_sources | type) == $string_type)
			and .expected_sources == $recovery.current_expected_sources) as $recovery_matches
		|
		.active == true and .source_pr == $source_pr and .operation_token == $token
		and .tag == null
		and ((.terminal_receipt // null) == null)
		and ((.phase == $reconcile and .expected_sources == $failed_expected and $recovery == null)
			or (.phase == $reserved and $recovery_matches)
			or (.phase == $refresh and $recovery_matches
				and .reserved_authorization_refresh.previous_expected_sources == $failed_expected
				and .reserved_authorization_refresh.pending_expected_sources == .expected_sources))
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	operation_token="${_AIDEVOPS_RELEASE_LANE_TOKEN_PREFIX}$(date +%s)-$$-${RANDOM:-0}"
	state_json=$(jq -c --arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" \
		--arg reconcile "$_AIDEVOPS_RELEASE_LANE_PHASE_RECONCILE_REQUIRED" \
		--arg failed_expected "$failed_expected_sources" \
		--arg token "$operation_token" --arg owner "${_AIDEVOPS_RELEASE_LANE_OWNER_PREFIX}$$" \
		--arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson failed_source_pr "$failed_source_pr" \
		--arg failed_source_merge "$failed_source_merge" --arg attempted_tag "$attempted_tag" '
		(.prepublication_recovery // null) as $existing_recovery
		| .updated_at as $previous_updated_at
		| if $existing_recovery == null then .phase=$reserved else . end
		| .operation_token=$token | .owner=$owner | .updated_at=$now
		| .prepublication_recovery=(if $existing_recovery == null then
			{previous_phase:$reconcile,previous_updated_at:$previous_updated_at,
			 failed_source_pr:$failed_source_pr,failed_source_merge:$failed_source_merge,
			 attempted_tag:$attempted_tag,failed_expected_sources:$failed_expected,
			 current_expected_sources:$failed_expected,recovered_at:$now}
		  else $existing_recovery + {revalidated_at:$now} end)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || write_rc=$?
	if [[ "$write_rc" -ne 0 ]]; then
		release_lane_read "$repo" || return "$write_rc"
		jq -e --argjson source_pr "$source_pr" --arg token "$operation_token" \
			--arg failed_expected "$failed_expected_sources" --arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" \
			--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" \
			--argjson failed_source_pr "$failed_source_pr" --arg failed_source_merge "$failed_source_merge" \
			--arg attempted_tag "$attempted_tag" '
			.active == true and .source_pr == $source_pr and .operation_token == $token
			and (.phase == $reserved or .phase == $refresh) and .tag == null
			and ((.terminal_receipt // null) == null)
			and .prepublication_recovery.failed_source_pr == $failed_source_pr
			and .prepublication_recovery.failed_source_merge == $failed_source_merge
			and .prepublication_recovery.attempted_tag == $attempted_tag
			and .prepublication_recovery.failed_expected_sources == $failed_expected
			and .prepublication_recovery.current_expected_sources == .expected_sources
			and (.phase != $refresh
				or (.reserved_authorization_refresh.previous_expected_sources == $failed_expected
					and .reserved_authorization_refresh.pending_expected_sources == .expected_sources))
		' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return "$write_rc"
	fi
	_AIDEVOPS_RELEASE_LANE_TOKEN="$operation_token"
	_AIDEVOPS_RELEASE_LANE_RESULT="$_AIDEVOPS_RELEASE_LANE_RESULT_ACQUIRED"
	printf 'Recovered verified failed pre-publication release lane for PR #%s\n' "$source_pr"
	return 0
}

release_lane_expand_reserved_authorization() {
	local repo="$1"
	local source_pr="$2"
	# Keep this value byte-exact: supported older lanes may contain PR-only intent,
	# and rollback must restore that representation rather than a resolved manifest.
	local previous_sources="$3"
	local expected_sources="$4"
	local operation_token=""
	local state_json=""
	local snapshot_json=""
	local write_rc=0
	[[ -n "$previous_sources" && -n "$expected_sources" && "$previous_sources" != "$expected_sources" ]] || return 1
	[[ -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	if jq -e --argjson source_pr "$source_pr" --arg previous "$previous_sources" \
		--arg expected "$expected_sources" --arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" '
		.active == true and .source_pr == $source_pr and .operation_token != ""
		and .phase == $refresh and .tag == null and .expected_sources == $expected
		and ((.terminal_receipt // null) == null)
		and .reserved_authorization_refresh.previous_expected_sources == $previous
		and .reserved_authorization_refresh.pending_expected_sources == $expected
		and (.reserved_authorization_refresh.previous_state.schema_version == 1)
		and ((.prepublication_recovery // null) == null
			or .prepublication_recovery.current_expected_sources == $expected)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
		_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -er '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT=$(jq -ce '.reserved_authorization_refresh.previous_state' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		return 0
	fi
	jq -e --argjson source_pr "$source_pr" --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" \
		--arg previous "$previous_sources" --arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" '
		.active == true and .source_pr == $source_pr and .operation_token == $token
		and .phase == $reserved and .tag == null and .expected_sources == $previous
		and ((.terminal_receipt // null) == null)
		and ((.prepublication_recovery // null) == null
			or .prepublication_recovery.current_expected_sources == $previous)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT="$_AIDEVOPS_RELEASE_LANE_JSON"
	snapshot_json="$_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT"
	operation_token="${_AIDEVOPS_RELEASE_LANE_TOKEN_PREFIX}$(date +%s)-$$-${RANDOM:-0}"
	state_json=$(jq -c --arg expected "$expected_sources" --arg previous "$previous_sources" \
		--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" --arg token "$operation_token" \
		--arg owner "${_AIDEVOPS_RELEASE_LANE_OWNER_PREFIX}$$" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		--argjson snapshot "$snapshot_json" '
		.expected_sources=$expected | .phase=$refresh | .operation_token=$token
		| .owner=$owner | .updated_at=$now
		| if (.prepublication_recovery // null) != null then
			.prepublication_recovery.current_expected_sources=$expected else . end
		| .reserved_authorization_refresh={previous_state:$snapshot,
			previous_expected_sources:$previous,pending_expected_sources:$expected}
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || write_rc=$?
	if [[ "$write_rc" -ne 0 ]]; then
		release_lane_read "$repo" || return "$write_rc"
		jq -e --argjson source_pr "$source_pr" --arg token "$operation_token" \
			--arg previous "$previous_sources" --arg expected "$expected_sources" \
			--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" '
			.active == true and .source_pr == $source_pr and .operation_token == $token
			and .phase == $refresh and .tag == null and .expected_sources == $expected
			and ((.terminal_receipt // null) == null)
			and .reserved_authorization_refresh.previous_expected_sources == $previous
			and .reserved_authorization_refresh.pending_expected_sources == $expected
			and ((.prepublication_recovery // null) == null
				or .prepublication_recovery.current_expected_sources == $expected)
		' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return "$write_rc"
	fi
	_AIDEVOPS_RELEASE_LANE_TOKEN="$operation_token"
	return 0
}

release_lane_finish_reserved_authorization() {
	local repo="$1"
	local source_pr="$2"
	local previous_sources="$3"
	local expected_sources="$4"
	local state_json=""
	local write_rc=0
	[[ -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" \
		--arg previous "$previous_sources" --arg expected "$expected_sources" \
		--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" '
		.active == true and .source_pr == $source_pr and .operation_token == $token
		and .phase == $refresh and .tag == null and .expected_sources == $expected
		and ((.terminal_receipt // null) == null)
		and .reserved_authorization_refresh.previous_expected_sources == $previous
		and .reserved_authorization_refresh.pending_expected_sources == $expected
		and ((.prepublication_recovery // null) == null
			or .prepublication_recovery.current_expected_sources == $expected)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	state_json=$(jq -c --arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" \
		--arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
		.phase=$reserved | .updated_at=$now | del(.reserved_authorization_refresh)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || write_rc=$?
	if [[ "$write_rc" -ne 0 ]]; then
		release_lane_read "$repo" || return "$write_rc"
		jq -e --argjson source_pr "$source_pr" --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" \
			--arg expected "$expected_sources" --arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" '
			.active == true and .source_pr == $source_pr and .operation_token == $token
			and .phase == $reserved and .tag == null and .expected_sources == $expected
			and ((.terminal_receipt // null) == null)
			and ((.reserved_authorization_refresh // null) == null)
			and ((.prepublication_recovery // null) == null
				or .prepublication_recovery.current_expected_sources == $expected)
		' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return "$write_rc"
	fi
	return 0
}

release_lane_restore_reserved_authorization() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="$3"
	local snapshot_json="$4"
	local write_rc=0
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" \
		--arg expected "$expected_sources" --arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" '
		.active == true and .source_pr == $source_pr and .operation_token == $token
		and .phase == $refresh and .tag == null and .expected_sources == $expected
		and ((.terminal_receipt // null) == null)
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	jq -e --argjson source_pr "$source_pr" --arg reserved "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED" '
		.schema_version == 1 and .active == true and .source_pr == $source_pr
		and .phase == $reserved and .tag == null
	' <<<"$snapshot_json" >/dev/null || return 1
	_release_lane_write "$repo" "$snapshot_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || write_rc=$?
	if [[ "$write_rc" -ne 0 ]]; then
		release_lane_read "$repo" || return "$write_rc"
		[[ "$(jq -cS . <<<"$_AIDEVOPS_RELEASE_LANE_JSON")" == "$(jq -cS . <<<"$snapshot_json")" ]] || return "$write_rc"
	fi
	_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -r '.operation_token' <<<"$snapshot_json") || return 1
	return 0
}

release_lane_restore_aggregate_recovery() {
	local repo="$1"
	local source_pr="$2"
	local snapshot_json="$3"
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" \
		--arg recovery "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_RECOVERY" \
		--arg refresh "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_REFRESH" \
		--arg committing "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATE_COMMIT" '
		.active == true and .source_pr == $source_pr
		and (.phase == $recovery or .phase == $refresh or .phase == $committing)
		and .operation_token == $token
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	if [[ -z "$snapshot_json" ]]; then
		snapshot_json=$(jq -ce '.aggregate_recovery.previous_state' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	fi
	jq -e --argjson source_pr "$source_pr" '
		.schema_version == 1 and .active == true and .source_pr == $source_pr
	' <<<"$snapshot_json" >/dev/null || return 1
	_release_lane_write "$repo" "$snapshot_json" "$_AIDEVOPS_RELEASE_LANE_HEAD" || return $?
	_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -r '.operation_token' <<<"$snapshot_json") || return 1
	return 0
}

release_lane_update() {
	local repo="$1"
	local source_pr="$2"
	local phase="$3"
	local tag_name="${4:-}"
	local state_json=""
	[[ -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" \
		'.active == true and .source_pr == $source_pr and .operation_token == $token' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	state_json=$(jq -c --arg phase "$phase" --arg tag "$tag_name" --arg preparing "preparing" \
		--arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
		.phase=$phase | .tag=(if $tag == "" then .tag else $tag end) | .updated_at=$now
		| if $phase == $preparing then del(.prepublication_recovery) else . end
	' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD"
	return $?
}

release_lane_update_if_owned() {
	local repo="$1"
	local source_pr="$2"
	local phase="$3"
	local tag_name="${4:-}"
	local read_rc=0
	release_lane_read "$repo" || read_rc=$?
	case "$read_rc" in
	2) return 0 ;;
	0) ;;
	*) return 1 ;;
	esac
	if [[ -z "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]]; then
		_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -r '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	fi
	if jq -e --argjson source_pr "$source_pr" '.active == true and .source_pr == $source_pr' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
		release_lane_update "$repo" "$source_pr" "$phase" "$tag_name"
		return $?
	fi
	jq -e '.active != true' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null
	return $?
}

release_lane_finalize() {
	local repo="$1"
	local source_pr="$2"
	local receipt="$3"
	local state_json=""
	[[ -n "$_AIDEVOPS_RELEASE_LANE_TOKEN" ]] || return 1
	release_lane_read "$repo" || return 1
	jq -e --argjson source_pr "$source_pr" --arg token "$_AIDEVOPS_RELEASE_LANE_TOKEN" \
		'.active == true and .source_pr == $source_pr and .operation_token == $token' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 1
	state_json=$(jq -c --arg receipt "$receipt" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
		'.active=false | .phase="terminal" | .terminal_receipt=$receipt | .updated_at=$now' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	_release_lane_write "$repo" "$state_json" "$_AIDEVOPS_RELEASE_LANE_HEAD"
	return $?
}

#aidevops:trust-boundary
_release_lane_pr_is_metadata_only_aggregate() {
	local repo="$1"
	local pr_number="$2"
	local pr_json=""
	local body=""
	local identity_count=0
	local aggregate_count=0
	local files_count=""
	command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
	pr_json=$(gh api "repos/${repo}/pulls/${pr_number}" 2>/dev/null) || return 1
	jq -e --argjson pr "$pr_number" '
		.state == "open" and .base.ref == "main"
		and (.number == $pr)
		and (.head.sha | test("^[0-9a-f]{40}$"))
		and (.base.sha | test("^[0-9a-f]{40}$"))
	' <<<"$pr_json" >/dev/null || return 1
	body=$(jq -er '.body // ""' <<<"$pr_json") || return 1
	identity_count=$(awk -v expected="Aidevops-Release-Aggregator-PR: ${pr_number}" \
		'$0 == expected { count++ } END { print count + 0 }' <<<"$body") || return 1
	[[ "$identity_count" -eq 1 ]] || return 1
	aggregate_count=$(awk '
		/^Aidevops-Release-Aggregates: / {
			value = substr($0, index($0, ": ") + 2)
			if (value !~ /^[0-9]+@[0-9a-f]{40}$/) exit 2
			count++
		}
		END { print count + 0 }
	' <<<"$body") || return 1
	[[ "$aggregate_count" -gt 0 ]] || return 1
	files_count=$(gh api "repos/${repo}/pulls/${pr_number}/files?per_page=1" --jq 'length' 2>/dev/null) || return 1
	[[ "$files_count" == "0" ]]
	return $?
}

release_lane_merge_guard() {
	local repo="$1"
	local pr_number="$2"
	local base_ref="$3"
	local head_ref="$4"
	local coordinated_repo="${AIDEVOPS_RELEASE_LANE_COORDINATED_REPO:-marcusquinn/aidevops}"
	local read_rc=0
	local active=""
	local phase=""
	local source_pr=""
	local tag_name=""
	local terminal_receipt=""

	[[ "$repo" == "$coordinated_repo" && "$base_ref" == "main" ]] || return 0
	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
	release_lane_read "$repo" || read_rc=$?
	case "$read_rc" in
	2) return 0 ;;
	0) ;;
	*)
		printf 'Cannot verify repository release lane; ordinary merge is blocked\n' >&2
		return 75
		;;
	esac
	active=$(jq -r '.active' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	phase=$(jq -r '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	terminal_receipt=$(jq -r 'if .terminal_receipt == null then "" elif (.terminal_receipt | type) == "string" then .terminal_receipt else .terminal_receipt.status // "" end' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	if [[ "$active" == "false" || "$phase" == "terminal" || "$terminal_receipt" == "published" || "$terminal_receipt" == "superseded" || "$terminal_receipt" == "recovered" ]]; then
		return 0
	fi
	case "$phase" in
	remote-publication | exact-tag-deployment | "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_RECOVERY" | "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_REFRESH" | "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATE_COMMIT" | "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" | "$_AIDEVOPS_RELEASE_LANE_PHASE_SUCCESSOR_PREPARING") ;;
	*) return 0 ;;
	esac
	source_pr=$(jq -r '.source_pr' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	tag_name=$(jq -r '.tag // ""' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	[[ "$pr_number" == "$source_pr" ]] && return 0
	#aidevops:trust-boundary
	if [[ -n "$tag_name" && "$head_ref" == "chore/release-${tag_name}-provenance" ]]; then
		case "$phase" in
		"$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_RECOVERY" | "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATION_REFRESH") ;;
		*) return 0 ;;
		esac
	fi
	if [[ "$phase" != "$_AIDEVOPS_RELEASE_LANE_PHASE_AGGREGATE_COMMIT" &&
		"$phase" != "$_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH" &&
		"$phase" != "$_AIDEVOPS_RELEASE_LANE_PHASE_SUCCESSOR_PREPARING" ]] &&
		_release_lane_pr_is_metadata_only_aggregate "$repo" "$pr_number"; then
		return 0
	fi
	printf 'ACTIVE_RELEASE_LANE_MERGE_BLOCKED source_pr=%s phase=%s tag=%s\n' \
		"$source_pr" "$phase" "${tag_name:-pending}" >&2
	return 75
}

release_lane_setup_guard() {
	local repo="$1"
	local source_pr="${AIDEVOPS_RELEASE_LANE_SOURCE_PR:-}"
	local tag_name="${AIDEVOPS_RELEASE_LANE_TAG:-}"
	local active_pr="" active_tag="" phase=""
	local read_rc=0
	release_lane_read "$repo" || read_rc=$?
	case "$read_rc" in
	2) return 0 ;;
	0) ;;
	*)
		printf 'Cannot verify repository release lane; setup deployment is blocked\n' >&2
		return 75
		;;
	esac
	[[ "$(jq -r '.active' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")" == "true" ]] || return 0
	phase=$(jq -r '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	[[ "$phase" == "exact-tag-deployment" ]] || return 0
	active_pr=$(jq -r '.source_pr' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	active_tag=$(jq -r '.tag // ""' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	if [[ "$source_pr" == "$active_pr" && -n "$tag_name" && "$tag_name" == "$active_tag" ]]; then
		return 0
	fi
	printf 'Active exact-tag release deployment blocks generic setup: source_pr=%s tag=%s\n' \
		"$active_pr" "${active_tag:-pending}" >&2
	return 75
}
