#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Durable release-state discovery and recovery for full-loop publication.

[[ -n "${_FULL_LOOP_RELEASE_RECONCILE_LOADED:-}" ]] && return 0
_FULL_LOOP_RELEASE_RECONCILE_LOADED=1

_FULL_LOOP_RELEASE_FOUND_TAG=""
_FULL_LOOP_RELEASE_RUN_JSON=""
_FULL_LOOP_RELEASE_RUN_JOBS_JSON=""
_FULL_LOOP_RELEASE_NPM_VERSION=""
_FULL_LOOP_RELEASE_NPM_INTEGRITY=""
_FULL_LOOP_RELEASE_EVENT_PUSH="push"
_FULL_LOOP_RELEASE_EVENT_RECOVERY="workflow_dispatch"
_FULL_LOOP_RELEASE_JSON_ARRAY_TYPE="array"
_FULL_LOOP_RELEASE_JSON_NUMBER_TYPE="number"
_FULL_LOOP_RELEASE_STATUS_COMPLETED="completed"
_FULL_LOOP_RELEASE_CONCLUSION_FAILURE="failure"
_FULL_LOOP_RELEASE_CONCLUSION_SKIPPED="skipped"
_FULL_LOOP_RELEASE_CONCLUSION_SUCCESS="success"
_FULL_LOOP_RELEASE_JSON_STRING_TYPE="string"
_FULL_LOOP_RELEASE_MODE_RECONCILE="reconcile"
_FULL_LOOP_RELEASE_STEP_QUEUE_POSTFLIGHT="Queue exact-tag postflight"
_FULL_LOOP_RELEASE_PROVENANCE_PREDICATE="https://slsa.dev/provenance/v1"
_FULL_LOOP_RELEASE_TRUE="true"

# shellcheck source=./version-manager-protected-main.sh
source "${SCRIPT_DIR}/version-manager-protected-main.sh"

_full_loop_release_tag_body() {
	local tag_name="$1"
	git -C "$REPO_ROOT" for-each-ref --format='%(contents)' "refs/tags/${tag_name}"
	return $?
}

_full_loop_release_verify_tag_provenance() {
	local repo="$1"
	local tag_name="$2"
	local verifier="${SCRIPT_DIR}/release-provenance-helper.sh"

	[[ -x "$verifier" ]] || return 1
	_full_loop_release_prepare_tag_worktree "$tag_name" || return 1
	(
		cd "$_FULL_LOOP_RELEASE_PATH" || exit 1
		bash "$verifier" verify --tag "$tag_name" --repo "$repo" >/dev/null
	)
	return $?
}

_full_loop_release_verify_protected_source_provenance() {
	local repo="$1"
	local tag_name="$2"
	local verifier="${SCRIPT_DIR}/release-provenance-helper.sh"

	[[ -x "$verifier" ]] || return 1
	_full_loop_release_prepare_tag_worktree "$tag_name" || return 1
	(
		cd "$_FULL_LOOP_RELEASE_PATH" || exit 1
		bash "$verifier" verify-local-source --tag "$tag_name" --repo "$repo" >/dev/null
	)
	return $?
}

_full_loop_release_verify_candidate_tag_provenance() {
	local repo="$1"
	local tag_name="$2"
	local protected_state_rc=0

	_version_manager_classify_remote_tag "$tag_name" || return 1
	case "$_VERSION_MANAGER_REMOTE_TAG_STATE" in
	"$_VERSION_MANAGER_TAG_STATE_MATCHING")
		_full_loop_release_verify_tag_provenance "$repo" "$tag_name"
		return $?
		;;
	"$_VERSION_MANAGER_TAG_STATE_ABSENT")
		_full_loop_release_verify_protected_source_provenance "$repo" "$tag_name" || return 1
		_version_manager_reconcile_protected_release_tag "$repo" "$tag_name" status \
			>/dev/null || protected_state_rc=$?
		[[ "$protected_state_rc" -eq 0 ]] || return 1
		case "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" in
		pr-pending | tag-ready) return 0 ;;
		remote-tag-present)
			_full_loop_release_verify_tag_provenance "$repo" "$tag_name"
			return $?
			;;
		esac
		;;
	esac
	return 1
}

_full_loop_release_candidate_tags_for_pr() {
	local requested_pr="$1"
	local ref_format='%(refname:short)%1f'
	local trailer_index=""
	local legacy_source_merges=""
	local legacy_source_lookup=""
	local candidate_tag=""
	local source_prs=""
	local source_merge=""
	local aggregated_sources=""
	local direct_marker=",${requested_pr},"
	local aggregate_marker=",${requested_pr}@"
	local legacy_source_marker=""

	[[ "$requested_pr" =~ ^[0-9]+$ ]] || return 1
	ref_format+='%(trailers:key=Aidevops-Source-PR,valueonly,separator=%x2C)%1f'
	ref_format+='%(trailers:key=Aidevops-Source-Merge,valueonly,separator=%x2C)%1f'
	ref_format+='%(trailers:key=Aidevops-Aggregated-Source,valueonly,separator=%x2C)'
	trailer_index=$(git -C "$REPO_ROOT" for-each-ref --sort=-version:refname \
		--format="$ref_format" 'refs/tags/v[0-9]*.[0-9]*.[0-9]*') || return 1
	legacy_source_merges=$(git -C "$REPO_ROOT" log --all --fixed-strings \
		--grep="Aidevops-Release-Aggregates: ${requested_pr}@" --format='%H') || return 1
	legacy_source_lookup=",${legacy_source_merges//$'\n'/,},"

	while IFS=$'\x1f' read -r candidate_tag source_prs source_merge aggregated_sources; do
		[[ -n "$candidate_tag" ]] || continue
		if [[ ",${source_prs}," == *"$direct_marker"* ]] ||
			[[ ",${aggregated_sources}," == *"$aggregate_marker"* ]]; then
			printf '%s\n' "$candidate_tag"
			continue
		fi
		legacy_source_marker=",${source_merge},"
		if [[ -n "$source_merge" && "$legacy_source_lookup" == *"$legacy_source_marker"* ]]; then
			printf '%s\n' "$candidate_tag"
		fi
	done <<<"$trailer_index"
	return 0
}

_full_loop_release_find_tag_for_pr() {
	local repo="$1"
	local requested_pr="$2"
	local candidate_tag=""
	local candidate_tags=""
	local tag_body=""
	local trailer=""
	local source_json=""
	local requested_present="false"
	local textually_matched=0

	_FULL_LOOP_RELEASE_FOUND_TAG=""
	git -C "$REPO_ROOT" fetch origin --tags --quiet || return 1
	candidate_tags=$(_full_loop_release_candidate_tags_for_pr "$requested_pr") || return 1
	while IFS= read -r candidate_tag; do
		[[ -n "$candidate_tag" ]] || continue
		tag_body=$(_full_loop_release_tag_body "$candidate_tag") || return 1
		textually_matched=0
		while IFS= read -r trailer; do
			case "$trailer" in
			"Aidevops-Source-PR: ${requested_pr}" | "Aidevops-Aggregated-Source: ${requested_pr}@"*)
				textually_matched=1
				break
				;;
			esac
		done <<<"$tag_body"
		if ! source_json=$(_full_loop_release_source_json_from_tag "$candidate_tag"); then
			[[ "$textually_matched" -eq 0 ]] || return 1
			continue
		fi
		requested_present=$(jq -r --argjson requested "$requested_pr" \
			'([.source_pr] + [.aggregated_sources[].pr]) | any(. == $requested)' <<<"$source_json") || return 1
		if [[ "$textually_matched" -eq 1 && "$requested_present" != "$_FULL_LOOP_RELEASE_TRUE" ]]; then
			return 1
		fi
		[[ "$requested_present" == "$_FULL_LOOP_RELEASE_TRUE" ]] || continue
		_full_loop_release_verify_candidate_tag_provenance "$repo" "$candidate_tag" || return 1
		_FULL_LOOP_RELEASE_FOUND_TAG="$candidate_tag"
		return 0
	done <<<"$candidate_tags"
	return 2
}

_full_loop_release_latest_tag() {
	local latest_tag=""
	while IFS= read -r latest_tag; do
		[[ -n "$latest_tag" ]] || continue
		printf '%s\n' "$latest_tag"
		return 0
	done < <(git -C "$REPO_ROOT" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname)
	return 1
}

_full_loop_release_source_merge_trailer_values() {
	local source_merge="$1"
	local trailer_key="$2"
	local commit_message=""
	local parsed_trailers=""

	commit_message=$(git -C "$REPO_ROOT" log -1 --format='%B' "$source_merge" 2>/dev/null) || return 1
	parsed_trailers=$(git -C "$REPO_ROOT" interpret-trailers --parse <<<"$commit_message") || return 1
	awk -v prefix="${trailer_key}: " \
		'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' \
		<<<"$parsed_trailers"
	return $?
}

_full_loop_release_manifest_json_from_source_merge() {
	local source_pr="$1"
	local source_merge="$2"
	local manifest_pr=""
	local manifest_entries=""
	local aggregate_payload=""
	local aggregate_pr=""
	local aggregate_merge=""
	local aggregates_json="[]"

	manifest_pr=$(_full_loop_release_source_merge_trailer_values \
		"$source_merge" "Aidevops-Release-Aggregator-PR") || return 1
	manifest_entries=$(_full_loop_release_source_merge_trailer_values \
		"$source_merge" "Aidevops-Release-Aggregates") || return 1
	if [[ -z "$manifest_pr" && -z "$manifest_entries" ]]; then
		printf '[]\n'
		return 0
	fi
	[[ "$manifest_pr" == "$source_pr" && -n "$manifest_entries" ]] || return 1
	while IFS= read -r aggregate_payload; do
		[[ -n "$aggregate_payload" ]] || continue
		aggregate_pr="${aggregate_payload%%@*}"
		aggregate_merge="${aggregate_payload#*@}"
		[[ "$aggregate_payload" == *@* && "$aggregate_pr" =~ ^[0-9]+$ && "$aggregate_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
		[[ "$aggregate_pr" != "$source_pr" ]] || return 1
		if jq -e --argjson pr "$aggregate_pr" 'any(.[]; .pr == $pr)' <<<"$aggregates_json" >/dev/null; then
			return 1
		fi
		aggregates_json=$(jq -cn --argjson pr "$aggregate_pr" --arg merge "$aggregate_merge" \
			--argjson existing "$aggregates_json" '$existing + [{pr:$pr,merge:$merge}]') || return 1
	done <<<"$manifest_entries"
	printf '%s\n' "$aggregates_json"
	return 0
}

_full_loop_release_source_json_from_tag() {
	local tag_name="$1"
	local tag_body=""
	local trailer=""
	local source_pr=""
	local source_merge=""
	local aggregate_pr=""
	local aggregate_merge=""
	local aggregate_payload=""
	local aggregates_json="[]"

	tag_body=$(_full_loop_release_tag_body "$tag_name") || return 1
	while IFS= read -r trailer; do
		case "$trailer" in
		"Aidevops-Source-PR: "*) source_pr="${trailer#Aidevops-Source-PR: }" ;;
		"Aidevops-Source-Merge: "*) source_merge="${trailer#Aidevops-Source-Merge: }" ;;
		"Aidevops-Aggregated-Source: "*)
			aggregate_payload="${trailer#Aidevops-Aggregated-Source: }"
			aggregate_pr="${aggregate_payload%%@*}"
			aggregate_merge="${aggregate_payload#*@}"
			[[ "$aggregate_pr" =~ ^[0-9]+$ && "$aggregate_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
			if jq -e --argjson pr "$aggregate_pr" 'any(.[]; .pr == $pr)' <<<"$aggregates_json" >/dev/null; then
				return 1
			fi
			aggregates_json=$(jq -cn --argjson pr "$aggregate_pr" --arg merge "$aggregate_merge" \
				--argjson existing "$aggregates_json" '$existing + [{pr:$pr,merge:$merge}]') || return 1
			;;
		esac
	done <<<"$tag_body"
	[[ "$source_pr" =~ ^[0-9]+$ && "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	if jq -e --argjson source_pr "$source_pr" 'any(.[]; .pr == $source_pr)' <<<"$aggregates_json" >/dev/null; then
		return 1
	fi
	if [[ "$aggregates_json" == "[]" ]]; then
		aggregates_json=$(_full_loop_release_manifest_json_from_source_merge \
			"$source_pr" "$source_merge") || return 1
	fi
	jq -cn --argjson source_pr "$source_pr" --arg source_merge "$source_merge" \
		--argjson aggregated_sources "$aggregates_json" \
		'{source_pr:$source_pr,source_merge:$source_merge,aggregated_sources:$aggregated_sources}'
	return $?
}

_full_loop_release_resolve_tag_expected_sources() {
	local repo="$1"
	local requested_pr="$2"
	local tag_name="$3"
	local expected_sources="$4"
	local resolver="${SCRIPT_DIR}/release-provenance-helper.sh"
	local authorization_json=""
	local resolver_args=(resolve-tag-authorization --tag "$tag_name" --source-pr "$requested_pr" --repo "$repo" --branch main)
	[[ -x "$resolver" ]] || return 1
	[[ -n "$expected_sources" ]] && resolver_args+=(--expected-sources "$expected_sources")
	_full_loop_release_prepare_tag_worktree "$tag_name" || return 1
	authorization_json=$(cd "$_FULL_LOOP_RELEASE_PATH" && bash "$resolver" "${resolver_args[@]}") || return 1
	jq -er '.expected_sources | sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")' <<<"$authorization_json"
	return $?
}

_full_loop_release_observed_sources_for_expected() {
	local tag_name="$1"
	local expected_sources="$2"
	local expected_json=""
	local observed_json=""
	local source_json=""
	expected_json=$(release_authorization_manifest_json "$expected_sources") || return 1
	source_json=$(_full_loop_release_source_json_from_tag "$tag_name") || return 1
	observed_json=$(release_authorization_observed_sources_json "$expected_json" "$source_json") || return 1
	jq -r 'map("\(.pr)@\(.merge)") | join(",")' <<<"$observed_json"
	return $?
}

_full_loop_release_record_authorization_gap() {
	local repo="$1"
	local requested_pr="$2"
	local tag_name="$3"
	local expected_sources="$4"
	local reason="$5"
	local observed_sources=""
	local tag_object=""
	local release_commit=""
	local tag_ref=""
	[[ "$requested_pr" =~ ^[0-9]+$ && "$tag_name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	[[ -n "$expected_sources" && -n "$reason" ]] || return 1
	git -C "$REPO_ROOT" fetch origin --tags --quiet || return 1
	_full_loop_release_verify_tag_provenance "$repo" "$tag_name" || return 1
	expected_sources=$(_full_loop_release_resolve_tag_expected_sources \
		"$repo" "$requested_pr" "$tag_name" "$expected_sources") || return 1
	observed_sources=$(_full_loop_release_observed_sources_for_expected "$tag_name" "$expected_sources") || return 1
	if release_authorization_compare "$expected_sources" "$observed_sources"; then
		printf 'Cannot record authorization-gap evidence: expected and observed sources match for %s\n' "$tag_name" >&2
		return 1
	fi
	printf -v tag_ref 'refs/tags/%s' "$tag_name"
	tag_object=$(git -C "$REPO_ROOT" rev-parse "$tag_ref" 2>/dev/null) || return 1
	release_commit=$(git -C "$REPO_ROOT" rev-parse "${tag_ref}^{commit}" 2>/dev/null) || return 1
	_full_loop_persist_release_authorization "$repo" "$requested_pr" "$expected_sources" || return 1
	_full_loop_write_release_authorization_gap_evidence "$repo" "$requested_pr" "$expected_sources" \
		"$observed_sources" "$tag_object" "$release_commit" "$reason" || return 1
	printf 'release:authorization-gap tag=%s requested_pr=%s\n' "$tag_name" "$requested_pr"
	return 0
}

_full_loop_release_runs_payload_valid() {
	local runs_json="$1"
	jq -e --arg array_type "$_FULL_LOOP_RELEASE_JSON_ARRAY_TYPE" \
		'type == "object" and (.workflow_runs | type == $array_type)' \
		<<<"$runs_json" >/dev/null
	return $?
}

_full_loop_release_find_workflow_run() {
	local repo="$1"
	local tag_name="$2"
	local tag_commit="$3"
	local push_runs=""
	local recovery_runs=""
	local display_title="Publish ${tag_name}"

	_FULL_LOOP_RELEASE_RUN_JSON=""
	push_runs=$(gh api --method GET "repos/${repo}/actions/workflows/publish-packages.yml/runs" \
		-f event=push -F per_page=50 2>/dev/null) || return 1
	recovery_runs=$(gh api --method GET "repos/${repo}/actions/workflows/publish-packages.yml/runs" \
		-f event=workflow_dispatch -F per_page=50 2>/dev/null) || return 1
	_full_loop_release_runs_payload_valid "$push_runs" || return 1
	_full_loop_release_runs_payload_valid "$recovery_runs" || return 1
	_FULL_LOOP_RELEASE_RUN_JSON=$(jq -cn --arg sha "$tag_commit" --arg tag "$tag_name" --arg title "$display_title" \
		--arg push_event "$_FULL_LOOP_RELEASE_EVENT_PUSH" \
		--arg recovery_event "$_FULL_LOOP_RELEASE_EVENT_RECOVERY" \
		--arg string_type "$_FULL_LOOP_RELEASE_JSON_STRING_TYPE" \
		--argjson push "$push_runs" --argjson recovery "$recovery_runs" '
		([($push.workflow_runs[]? | select(.event == $push_event and .head_branch == $tag and .head_sha == $sha))]
		 + [($recovery.workflow_runs[]?
			| select(.event == $recovery_event and .head_branch == "main"
				and ((.head_sha | type) == $string_type)
				and (.head_sha | test("^[0-9a-f]{40}$"))
				and .display_title == ($title + " [" + $sha + "." + .head_sha + "]")))])
		| sort_by(.created_at // "") | last // empty
	') || return 1
	[[ -n "$_FULL_LOOP_RELEASE_RUN_JSON" && "$_FULL_LOOP_RELEASE_RUN_JSON" != "null" ]] || return 3
	jq -e --arg string_type "$_FULL_LOOP_RELEASE_JSON_STRING_TYPE" \
		--arg number_type "$_FULL_LOOP_RELEASE_JSON_NUMBER_TYPE" \
		--arg completed "$_FULL_LOOP_RELEASE_STATUS_COMPLETED" \
		--arg push_event "$_FULL_LOOP_RELEASE_EVENT_PUSH" \
		--arg recovery_event "$_FULL_LOOP_RELEASE_EVENT_RECOVERY" '
		((.id | type) == $number_type)
		and (.event == $push_event or .event == $recovery_event)
		and ((.head_sha | type) == $string_type)
		and (.head_sha | test("^[0-9a-f]{40}$"))
		and ((.status | type) == $string_type)
		and ((.status // "") | length > 0)
		and ((.created_at | type) == $string_type)
		and ((.created_at // "") | length > 0)
		and (if .status == $completed then
			((.conclusion | type) == $string_type) and ((.conclusion // "") | length > 0)
		else .conclusion == null or ((.conclusion | type) == $string_type) end)
	' <<<"$_FULL_LOOP_RELEASE_RUN_JSON" >/dev/null || return 1
	return 0
}

_full_loop_release_run_jobs_payload_valid() {
	local jobs_json="$1"
	jq -e --arg array_type "$_FULL_LOOP_RELEASE_JSON_ARRAY_TYPE" \
		--arg number_type "$_FULL_LOOP_RELEASE_JSON_NUMBER_TYPE" '
		type == "object" and (.total_count | type == $number_type and . >= 0 and floor == .)
		and (.jobs | type == $array_type) and .total_count == (.jobs | length)
	' <<<"$jobs_json" >/dev/null
	return $?
}

_full_loop_release_fetch_run_jobs() {
	local repo="$1"
	local run_id="$2"
	local jobs_json=""
	[[ "$repo" == */* && "$run_id" =~ ^[0-9]+$ && "$run_id" -gt 0 ]] || return 1
	_FULL_LOOP_RELEASE_RUN_JOBS_JSON=""
	jobs_json=$(gh api --method GET "repos/${repo}/actions/runs/${run_id}/jobs" \
		-F per_page=100 2>/dev/null) || return 1
	_full_loop_release_run_jobs_payload_valid "$jobs_json" || return 1
	_FULL_LOOP_RELEASE_RUN_JOBS_JSON="$jobs_json"
	return 0
}

_full_loop_release_stale_publication_jobs_valid() {
	local jobs_json="$1"
	jq -e --arg array_type "$_FULL_LOOP_RELEASE_JSON_ARRAY_TYPE" \
		--arg number_type "$_FULL_LOOP_RELEASE_JSON_NUMBER_TYPE" \
		--arg completed "$_FULL_LOOP_RELEASE_STATUS_COMPLETED" \
		--arg failure "$_FULL_LOOP_RELEASE_CONCLUSION_FAILURE" \
		--arg skipped "$_FULL_LOOP_RELEASE_CONCLUSION_SKIPPED" \
		--arg success "$_FULL_LOOP_RELEASE_CONCLUSION_SUCCESS" \
		--arg queue_step "$_FULL_LOOP_RELEASE_STEP_QUEUE_POSTFLIGHT" '
		. as $payload
		| ($payload.jobs | length) == 1
		and ($payload.jobs[0] as $job
			| $job.name == "Publish GitHub, npm, and Homebrew"
			and $job.status == $completed and $job.conclusion == $failure
			and ($job.steps | type == $array_type and length > 0)
			and ([$job.steps[] | select(.name == $queue_step)] | length == 1)
			and ([$job.steps[] | select(.conclusion == $failure)] | length == 1)
			and (($job.steps | map(.number)) as $numbers
				| ($numbers | all(type == $number_type and . > 0 and floor == .))
				and ($numbers | length) == ($numbers | unique | length))
			and (($job.steps | map(select(.name == $queue_step))[0].number) as $queue_number
				| ([$job.steps[] | select(.name == "Checkout verified tag")] | length == 1)
				and ([$job.steps[] | select(.name == "Checkout verified tag" and .number < $queue_number and .status == $completed and .conclusion == $success)] | length == 1)
				and ([$job.steps[] | select(.name == "Verify immutable release provenance")] | length == 1)
				and ([$job.steps[] | select(.name == "Verify immutable release provenance" and .number < $queue_number and .status == $completed and .conclusion == $success)] | length == 1)
				and ([$job.steps[] | select(.name == "Create or reconcile GitHub release")] | length == 1)
				and ([$job.steps[] | select(.name == "Create or reconcile GitHub release" and .number < $queue_number and .status == $completed and .conclusion == $success)] | length == 1)
				and ([$job.steps[] | select(.name == "Verify npm publication")] | length == 1)
				and ([$job.steps[] | select(.name == "Verify npm publication" and .number < $queue_number and .status == $completed and .conclusion == $success)] | length == 1)
				and ([$job.steps[] | select(.name == "Verify Homebrew tap")] | length == 1)
				and ([$job.steps[] | select(.name == "Verify Homebrew tap" and .number < $queue_number and .status == $completed and .conclusion == $success)] | length == 1)
				and ($job.steps | all(
					.status == $completed
					and if .name == $queue_step then .conclusion == $failure
					else (.conclusion == $success or .conclusion == $skipped) end))))
	' <<<"$jobs_json" >/dev/null
	return $?
}

_full_loop_release_verify_stale_publication_run() {
	local repo="$1"
	local tag_name="$2"
	local tag_commit="$3"
	local run_id=""
	local run_status=""
	local run_conclusion=""
	_full_loop_release_find_workflow_run "$repo" "$tag_name" "$tag_commit" || return 1
	run_id=$(jq -er --arg number_type "$_FULL_LOOP_RELEASE_JSON_NUMBER_TYPE" \
		'.id | select(type == $number_type and . > 0 and floor == .)' \
		<<<"$_FULL_LOOP_RELEASE_RUN_JSON") || return 1
	run_status=$(jq -er --arg string_type "$_FULL_LOOP_RELEASE_JSON_STRING_TYPE" \
		'.status | select(type == $string_type)' \
		<<<"$_FULL_LOOP_RELEASE_RUN_JSON") || return 1
	run_conclusion=$(jq -er --arg string_type "$_FULL_LOOP_RELEASE_JSON_STRING_TYPE" \
		'.conclusion | select(type == $string_type)' \
		<<<"$_FULL_LOOP_RELEASE_RUN_JSON") || return 1
	[[ "$run_status" == "$_FULL_LOOP_RELEASE_STATUS_COMPLETED" && "$run_conclusion" == "$_FULL_LOOP_RELEASE_CONCLUSION_FAILURE" ]] || return 1
	_full_loop_release_fetch_run_jobs "$repo" "$run_id" || return 1
	_full_loop_release_stale_publication_jobs_valid "$_FULL_LOOP_RELEASE_RUN_JOBS_JSON"
	return $?
}

_full_loop_release_sha256_stream() {
	local digest=""
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(sha256sum | awk '{print $1}') || return 1
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(shasum -a 256 | awk '{print $1}') || return 1
	else
		return 1
	fi
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

_full_loop_release_verify_npm_provenance() {
	local repo="$1"
	local tag_name="$2"
	local version="$3"
	local npm_metadata=""
	local npm_version=""
	local npm_integrity=""
	local npm_shasum=""
	local audit_dir=""
	local audit_json=""
	local provenance_payload=""
	local expected_digest=""

	_FULL_LOOP_RELEASE_NPM_VERSION=""
	_FULL_LOOP_RELEASE_NPM_INTEGRITY=""
	command -v npm >/dev/null 2>&1 || return 1
	command -v node >/dev/null 2>&1 || return 1
	npm_metadata=$(npm view "aidevops@${version}" version dist --json 2>/dev/null) || return 1
	npm_version=$(jq -er --arg string_type "$_FULL_LOOP_RELEASE_JSON_STRING_TYPE" \
		'.version | select(type == $string_type)' <<<"$npm_metadata") || return 1
	npm_integrity=$(jq -er --arg string_type "$_FULL_LOOP_RELEASE_JSON_STRING_TYPE" \
		'.dist.integrity | select(type == $string_type)' <<<"$npm_metadata") || return 1
	npm_shasum=$(jq -er --arg string_type "$_FULL_LOOP_RELEASE_JSON_STRING_TYPE" \
		'.dist.shasum | select(type == $string_type)' <<<"$npm_metadata") || return 1
	[[ "$npm_version" == "$version" ]] || return 1
	[[ "$npm_integrity" =~ ^sha512-[A-Za-z0-9+/]+={0,2}$ ]] || return 1
	[[ "$npm_shasum" =~ ^[0-9a-f]{40}$ ]] || return 1
	jq -e --arg provenance_predicate "$_FULL_LOOP_RELEASE_PROVENANCE_PREDICATE" \
		--arg string_type "$_FULL_LOOP_RELEASE_JSON_STRING_TYPE" '
		.dist.attestations.provenance.predicateType == $provenance_predicate
		and ((.dist.attestations.url // "") | type == $string_type and length > 0)
	' <<<"$npm_metadata" >/dev/null || return 1
	expected_digest=$(node -e \
		'process.stdout.write(Buffer.from(process.argv[1], "base64").toString("hex"))' \
		"${npm_integrity#sha512-}") || return 1
	[[ "$expected_digest" =~ ^[0-9a-f]{128}$ ]] || return 1

	audit_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-npm-provenance.XXXXXX") || return 1
	if ! (
		_FULL_LOOP_RELEASE_AUDIT_DIR="$audit_dir"
		trap 'command rm -rf -- "$_FULL_LOOP_RELEASE_AUDIT_DIR"' EXIT
		npm install --prefix "$audit_dir" --ignore-scripts --no-audit --no-fund --save-exact \
			"aidevops@${version}" >/dev/null 2>&1 || exit 1
		audit_json=$(npm --prefix "$audit_dir" audit signatures \
			--json --include-attestations 2>/dev/null) || exit 1
		jq -e --arg version "$version" \
			--arg array_type "$_FULL_LOOP_RELEASE_JSON_ARRAY_TYPE" \
			--arg provenance_predicate "$_FULL_LOOP_RELEASE_PROVENANCE_PREDICATE" '
		(.invalid | type == $array_type and length == 0)
		and (.missing | type == $array_type and length == 0)
		and ([.verified[]
			| select(.name == "aidevops" and .version == $version)
			| select(.attestations.provenance.predicateType == $provenance_predicate)
			| .attestationBundles[]
			| select(.predicateType == $provenance_predicate)
		] | length == 1)
	' <<<"$audit_json" >/dev/null || exit 1
		provenance_payload=$(jq -er --arg version "$version" \
			--arg provenance_predicate "$_FULL_LOOP_RELEASE_PROVENANCE_PREDICATE" '
		[.verified[]
			| select(.name == "aidevops" and .version == $version)
			| .attestationBundles[]
			| select(.predicateType == $provenance_predicate)
			| .bundle.dsseEnvelope.payload
		] | if length == 1 then .[0] | @base64d else empty end
	' <<<"$audit_json") || exit 1
		jq -e --arg subject "pkg:npm/aidevops@${version}" \
			--arg digest "$expected_digest" --arg repository "https://github.com/${repo}" \
			--arg tag_ref "refs/tags/${tag_name}" --arg recovery_ref "refs/heads/main" \
			--arg array_type "$_FULL_LOOP_RELEASE_JSON_ARRAY_TYPE" \
			--arg provenance_predicate "$_FULL_LOOP_RELEASE_PROVENANCE_PREDICATE" '
		._type == "https://in-toto.io/Statement/v1"
		and .predicateType == $provenance_predicate
		and (.subject | type == $array_type and length == 1)
		and .subject[0].name == $subject
		and .subject[0].digest.sha512 == $digest
		and .predicate.buildDefinition.buildType
			== "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1"
		and .predicate.buildDefinition.externalParameters.workflow.repository == $repository
		and .predicate.buildDefinition.externalParameters.workflow.path
			== ".github/workflows/publish-packages.yml"
		and (.predicate.buildDefinition.externalParameters.workflow.ref == $tag_ref
			or .predicate.buildDefinition.externalParameters.workflow.ref == $recovery_ref)
		and .predicate.runDetails.builder.id == "https://github.com/actions/runner/github-hosted"
	' <<<"$provenance_payload" >/dev/null || exit 1
		exit 0
	); then
		return 1
	fi
	_FULL_LOOP_RELEASE_NPM_VERSION="$npm_version"
	_FULL_LOOP_RELEASE_NPM_INTEGRITY="$npm_integrity"
	return 0
}

_full_loop_release_expected_homebrew_formula() {
	local repo="$1"
	local tag_name="$2"
	local expected_sha="$3"
	local tarball_url="https://github.com/${repo}/archive/refs/tags/${tag_name}.tar.gz"
	local formula=""
	local url_count=""
	local sha_count=""

	formula=$(git -C "$REPO_ROOT" show "${tag_name}:homebrew/aidevops.rb") || return 1
	url_count=$(grep -cE '^[[:space:]]{2}url "https://github.com/.+/archive/refs/tags/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz"$' \
		<<<"$formula" || true)
	sha_count=$(grep -cE '^[[:space:]]{2}sha256 "[0-9a-f]{64}"$' <<<"$formula" || true)
	[[ "$url_count" -eq 1 && "$sha_count" -eq 1 ]] || return 1
	formula=$(sed -E \
		-e "s|^([[:space:]]{2})url \"https://github.com/.+/archive/refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+\\.tar\\.gz\"$|\\1url \"${tarball_url}\"|" \
		-e "s|^([[:space:]]{2})sha256 \"[0-9a-f]{64}\"$|\\1sha256 \"${expected_sha}\"|" \
		<<<"$formula") || return 1
	[[ "$formula" == *"  url \"${tarball_url}\""* &&
		"$formula" == *"  sha256 \"${expected_sha}\""* ]] || return 1
	printf '%s\n' "$formula"
	return 0
}

_full_loop_release_verify_channels() {
	local repo="$1"
	local tag_name="$2"
	local version="${tag_name#v}"
	local release_json=""
	local npm_version=""
	local npm_integrity=""
	local tap_owner="${repo%%/*}"
	local formula=""
	local expected_formula=""
	local formula_sha=""
	local tarball_url="https://github.com/${repo}/archive/refs/tags/${tag_name}.tar.gz"
	local expected_sha=""

	release_json=$(gh api "repos/${repo}/releases/tags/${tag_name}" 2>/dev/null) || return 1
	jq -e --arg tag "$tag_name" '
		.tag_name == $tag and .draft == false and ((.published_at // "") | length > 0)
	' <<<"$release_json" >/dev/null || return 1
	_full_loop_release_verify_npm_provenance "$repo" "$tag_name" "$version" || return 1
	npm_version="$_FULL_LOOP_RELEASE_NPM_VERSION"
	npm_integrity="$_FULL_LOOP_RELEASE_NPM_INTEGRITY"
	formula=$(gh api "repos/${tap_owner}/homebrew-tap/contents/Formula/aidevops.rb" \
		--jq '.content | @base64d' 2>/dev/null) || return 1
	command -v curl >/dev/null 2>&1 || return 1
	expected_sha=$(curl -fsSL "$tarball_url" | _full_loop_release_sha256_stream) || return 1
	expected_formula=$(_full_loop_release_expected_homebrew_formula \
		"$repo" "$tag_name" "$expected_sha") || return 1
	[[ "$formula" == "$expected_formula" ]] || return 1
	formula_sha="$expected_sha"
	printf 'GITHUB_RELEASE=%s\n' "$tag_name"
	printf 'NPM_VERSION=%s\n' "$npm_version"
	printf 'NPM_INTEGRITY=%s\n' "$npm_integrity"
	printf 'HOMEBREW_VERSION=%s\n' "$version"
	printf 'HOMEBREW_SHA256=%s\n' "$formula_sha"
	return 0
}

_full_loop_release_resolve_tag_commit() {
	local tag_name="$1"
	local tag_ref="refs/tags/${tag_name}^{commit}"
	local tag_commit=""

	tag_commit=$(git -C "$REPO_ROOT" rev-parse "$tag_ref" 2>/dev/null) || return 1
	[[ "$tag_commit" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	printf '%s\n' "$tag_commit"
	return 0
}

_full_loop_release_inspect_remote() {
	local repo="$1"
	local tag_name="$2"
	local tag_commit=""
	local run_status=""
	local run_conclusion=""
	local run_url=""
	local find_rc=0

	tag_commit=$(_full_loop_release_resolve_tag_commit "$tag_name") || return 1
	_full_loop_release_find_workflow_run "$repo" "$tag_name" "$tag_commit" || find_rc=$?
	if [[ "$find_rc" -eq 3 ]]; then
		printf 'RELEASE_TAG=%s\nWORKFLOW_STATUS=absent\n' "$tag_name"
		return 3
	fi
	[[ "$find_rc" -eq 0 ]] || return 1
	run_status=$(jq -r '.status // ""' <<<"$_FULL_LOOP_RELEASE_RUN_JSON") || return 1
	run_conclusion=$(jq -r '.conclusion // ""' <<<"$_FULL_LOOP_RELEASE_RUN_JSON") || return 1
	run_url=$(jq -r '.html_url // ""' <<<"$_FULL_LOOP_RELEASE_RUN_JSON") || return 1
	printf 'RELEASE_TAG=%s\nWORKFLOW_STATUS=%s\n' "$tag_name" "$run_status"
	[[ -z "$run_url" ]] || printf 'WORKFLOW_URL=%s\n' "$run_url"
	if [[ "$run_status" != "completed" ]]; then
		return 8
	fi
	if [[ "$run_conclusion" != "success" ]]; then
		printf 'WORKFLOW_CONCLUSION=%s\n' "${run_conclusion:-unknown}"
		return 4
	fi
	_full_loop_release_verify_channels "$repo" "$tag_name" || return 5
	printf 'RELEASE_REMOTE_STATE=published\n'
	return 0
}

_full_loop_release_dispatch_recovery() {
	local repo="$1"
	local tag_name="$2"
	local audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
	local tag_commit=""
	local correlation=""

	tag_commit=$(_full_loop_release_resolve_tag_commit "$tag_name") || return 1
	correlation="$tag_commit"

	if [[ -x "$audit_helper" ]]; then
		AUDIT_QUIET=true "$audit_helper" log operation.verify \
			"Dispatching verified release reconciliation" \
			--detail "repo=${repo}" --detail "tag=${tag_name}" \
			--detail "correlation=${correlation}" || return 1
	fi
	gh workflow run publish-packages.yml --repo "$repo" --ref main \
		-f "tag=${tag_name}" -f "correlation=${correlation}" || return 1
	printf 'release:queued tag=%s correlation=%s\n' "$tag_name" "$correlation"
	return 8
}

_full_loop_release_prepare_tag_worktree() {
	local tag_name="$1"
	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local release_path="${worktree_base}/aidevops-release-reconcile-${tag_name#v}-$$"
	local tag_commit=""
	local checkout_commit=""

	[[ "$tag_name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	[[ -d "$worktree_base" ]] || return 1
	tag_commit=$(_full_loop_release_resolve_tag_commit "$tag_name") || return 1
	if [[ -n "${_FULL_LOOP_RELEASE_PATH:-}" ]]; then
		[[ -d "$_FULL_LOOP_RELEASE_PATH" ]] || return 1
		checkout_commit=$(git -C "$_FULL_LOOP_RELEASE_PATH" rev-parse HEAD 2>/dev/null) || return 1
		[[ "$checkout_commit" == "$tag_commit" ]] || return 1
		return 0
	fi
	git -C "$REPO_ROOT" worktree add --detach "$release_path" "$tag_name" >/dev/null || return 1
	checkout_commit=$(git -C "$release_path" rev-parse HEAD 2>/dev/null) || {
		git -C "$REPO_ROOT" worktree remove "$release_path" >/dev/null 2>&1 || true
		return 1
	}
	if [[ "$checkout_commit" != "$tag_commit" ]]; then
		git -C "$REPO_ROOT" worktree remove "$release_path" >/dev/null 2>&1 || true
		return 1
	fi
	_FULL_LOOP_RELEASE_PATH="$release_path"
	trap 'cleanup_release_worktree' EXIT
	return 0
}

_full_loop_release_reset_tag_worktree() {
	local release_path="${_FULL_LOOP_RELEASE_PATH:-}"
	local control_path="${_FULL_LOOP_RELEASE_CONTROL_PATH:-}"
	[[ -n "$release_path" ]] || return 0
	[[ -z "$control_path" || "$release_path" != "$control_path" ]] || return 1
	if [[ -d "$release_path" ]]; then
		git -C "$REPO_ROOT" worktree remove "$release_path" >/dev/null 2>&1 || return 1
	fi
	_FULL_LOOP_RELEASE_PATH=""
	return 0
}

_full_loop_release_finalize_reconciliation() {
	local repo="$1"
	local requested_pr="$2"
	local tag_name="$3"
	local source_json=""
	local source_pr=""
	local source_merge=""
	local requested_present=""
	local version_manager=""
	local deploy_helper=""

	source_json=$(_full_loop_release_source_json_from_tag "$tag_name") || return 1
	source_pr=$(jq -er '.source_pr' <<<"$source_json") || return 1
	source_merge=$(jq -er '.source_merge' <<<"$source_json") || return 1
	requested_present=$(jq -r --argjson requested "$requested_pr" \
		'([.source_pr] + [.aggregated_sources[].pr]) | any(. == $requested)' <<<"$source_json") || return 1
	[[ "$requested_present" == "$_FULL_LOOP_RELEASE_TRUE" ]] || return 1
	_full_loop_validate_release_candidates "$repo" "$source_json" || return 1
	_full_loop_release_prepare_tag_worktree "$tag_name" || return 1
	version_manager="${SCRIPT_DIR}/version-manager.sh"
	deploy_helper="${SCRIPT_DIR}/deploy-agents-on-merge.sh"
	[[ -f "$version_manager" ]] || return 1
	[[ -f "$deploy_helper" ]] || return 1
	(
		cd "$_FULL_LOOP_RELEASE_PATH" || exit 1
		AIDEVOPS_RELEASE_INTENT_TRUSTED=1 \
			AIDEVOPS_TRUSTED_ISSUE_PRIORITY="${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" \
			AIDEVOPS_SYNC_REPO_ROOT="$_FULL_LOOP_RELEASE_PATH" \
			AIDEVOPS_SYNC_DEPLOY_SCRIPT="$deploy_helper" \
			bash "$version_manager" post-release
	) || return 1
	_full_loop_persist_release_success "$repo" "$_FULL_LOOP_RELEASE_PATH" "$source_json" \
		"$source_pr" "$source_merge"
	return $?
}

_full_loop_release_finalize_stale_supersession() {
	local repo="$1"
	local requested_pr="$2"
	local source_tag="$3"
	local release_tag="$4"
	local source_json=""
	local source_merge=""
	local source_commit=""
	local source_run=""
	local release_json=""
	local successor_pr=""
	local successor_merge=""
	local release_commit=""
	local release_run=""
	local release_receipt=""
	local release_status=""

	source_json=$(_full_loop_release_source_json_from_tag "$source_tag") || return 1
	source_merge=$(jq -er --argjson requested "$requested_pr" '
		if .source_pr == $requested then .source_merge
		else .aggregated_sources[] | select(.pr == $requested) | .merge end
	' <<<"$source_json") || return 1
	[[ "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	source_commit=$(_full_loop_release_resolve_tag_commit "$source_tag") || return 1
	_full_loop_release_verify_stale_publication_run \
		"$repo" "$source_tag" "$source_commit" || return 1
	source_run=$(jq -er --arg number_type "$_FULL_LOOP_RELEASE_JSON_NUMBER_TYPE" \
		'.id | select(type == $number_type and . > 0 and floor == .)' \
		<<<"$_FULL_LOOP_RELEASE_RUN_JSON") || return 1

	_full_loop_release_reset_tag_worktree || return 1
	_full_loop_release_verify_tag_provenance "$repo" "$release_tag" || return 1
	release_json=$(_full_loop_release_source_json_from_tag "$release_tag") || return 1
	successor_pr=$(jq -er --arg number_type "$_FULL_LOOP_RELEASE_JSON_NUMBER_TYPE" \
		'.source_pr | select(type == $number_type and . > 0 and floor == .)' \
		<<<"$release_json") || return 1
	successor_merge=$(jq -er --arg string_type "$_FULL_LOOP_RELEASE_JSON_STRING_TYPE" \
		'.source_merge | select(type == $string_type)' \
		<<<"$release_json") || return 1
	[[ "$successor_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$successor_pr" != "$requested_pr" ]] || return 1
	release_commit=$(_full_loop_release_resolve_tag_commit "$release_tag") || return 1
	[[ "$source_commit" != "$release_commit" ]] || return 1
	git -C "$REPO_ROOT" merge-base --is-ancestor "$source_commit" "$release_commit" \
		>/dev/null 2>&1 || return 1
	_full_loop_release_inspect_remote "$repo" "$release_tag" || return 1
	release_run=$(jq -er --arg number_type "$_FULL_LOOP_RELEASE_JSON_NUMBER_TYPE" \
		'.id | select(type == $number_type and . > 0 and floor == .)' \
		<<<"$_FULL_LOOP_RELEASE_RUN_JSON") || return 1
	[[ "$source_run" != "$release_run" ]] || return 1
	release_receipt=$(_full_loop_release_receipt_path "$repo" "$successor_pr") || return 1
	[[ -f "$release_receipt" ]] || return 1
	IFS= read -r release_status <"$release_receipt" || return 1
	[[ "$release_status" == "$_FULL_LOOP_RELEASE_PUBLISHED" ]] || return 1

	_full_loop_write_successor_release_receipt "$repo" "$requested_pr" "$source_merge" \
		"$source_tag" "$source_commit" "$source_run" "$successor_pr" "$successor_merge" \
		"$release_tag" "$release_commit" "$release_run"
	return $?
}

_full_loop_release_existing_command() {
	local mode="$1"
	local requested_pr="$2"
	local repo=""
	local tag_name=""
	local latest_tag=""
	local inspect_rc=0
	local protected_tag_state_rc=0
	local receipt_path=""
	local receipt_status=""

	[[ "$mode" == "status" || "$mode" == "$_FULL_LOOP_RELEASE_MODE_RECONCILE" ]] || return 1
	[[ "$requested_pr" =~ ^[0-9]+$ ]] || return 1
	repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
	receipt_path=$(_full_loop_release_receipt_path "$repo" "$requested_pr") || return 1
	[[ -f "$receipt_path" ]] && IFS= read -r receipt_status <"$receipt_path" || true
	printf 'RELEASE_RECEIPT=%s\n' "${receipt_status:-missing}"
	case "$receipt_status" in
	"" | "$_FULL_LOOP_PHASE_FAILED" | "$_FULL_LOOP_RELEASE_PUBLISHED" | "$_FULL_LOOP_RELEASE_SUPERSEDED") ;;
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		printf 'Cannot reconcile terminal release:not-requested evidence for PR #%s\n' "$requested_pr" >&2
		return 1
		;;
	*)
		printf 'Cannot reconcile unknown release:%s evidence for PR #%s\n' "$receipt_status" "$requested_pr" >&2
		return 1
		;;
	esac
	_full_loop_release_find_tag_for_pr "$repo" "$requested_pr" || return $?
	tag_name="$_FULL_LOOP_RELEASE_FOUND_TAG"
	latest_tag=$(_full_loop_release_latest_tag) || return 1
	if [[ "$tag_name" != "$latest_tag" ]]; then
		printf 'STALE_RELEASE_TAG=%s\nLATEST_RELEASE_TAG=%s\n' "$tag_name" "$latest_tag"
		if [[ "$receipt_status" == "$_FULL_LOOP_RELEASE_SUPERSEDED" ]]; then
			_full_loop_verify_superseded_release_receipt "$repo" "$requested_pr" || return 1
			if [[ "$mode" == "$_FULL_LOOP_RELEASE_MODE_RECONCILE" ]]; then
				_full_loop_update_superseded_cleanup_receipt "$repo" "$requested_pr" || return 1
			fi
			printf 'release:superseded already recorded for PR #%s\n' "$requested_pr"
			return 0
		fi
		[[ "$mode" == "$_FULL_LOOP_RELEASE_MODE_RECONCILE" ]] || return 1
		[[ -z "$receipt_status" || "$receipt_status" == "$_FULL_LOOP_PHASE_FAILED" ]] || return 1
		_full_loop_release_finalize_stale_supersession \
			"$repo" "$requested_pr" "$tag_name" "$latest_tag" || return 1
		printf 'release:superseded source_tag=%s successor_tag=%s\n' "$tag_name" "$latest_tag"
		return 0
	fi
	_version_manager_reconcile_protected_release_tag "$repo" "$tag_name" "$mode" || protected_tag_state_rc=$?
	[[ "$protected_tag_state_rc" -eq 0 ]] || return 1
	case "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" in
	pr-pending | tag-ready | tag-pushed)
		return 8
		;;
	remote-tag-present) ;;
	*) return 1 ;;
	esac
	_full_loop_release_inspect_remote "$repo" "$tag_name" || inspect_rc=$?
	if [[ "$inspect_rc" -eq 0 ]]; then
		if [[ "$mode" == "$_FULL_LOOP_RELEASE_MODE_RECONCILE" ]]; then
			case "$receipt_status" in
			"$_FULL_LOOP_RELEASE_PUBLISHED")
				printf 'release:published already recorded for PR #%s\n' "$requested_pr"
				;;
			"$_FULL_LOOP_RELEASE_SUPERSEDED")
				_full_loop_verify_superseded_release_receipt "$repo" "$requested_pr" || return 1
				_full_loop_update_superseded_cleanup_receipt "$repo" "$requested_pr" || return 1
				printf 'release:superseded already recorded for PR #%s\n' "$requested_pr"
				;;
			*)
				_full_loop_release_finalize_reconciliation "$repo" "$requested_pr" "$tag_name" || return 1
				printf 'release:published tag=%s\n' "$tag_name"
				;;
			esac
		fi
		return 0
	fi
	case "$inspect_rc" in
	8) return 8 ;;
	1) return 1 ;;
	3 | 4 | 5)
		[[ "$mode" == "status" ]] && return "$inspect_rc"
		_full_loop_release_dispatch_recovery "$repo" "$tag_name"
		return $?
		;;
	*) return 1 ;;
	esac
}
