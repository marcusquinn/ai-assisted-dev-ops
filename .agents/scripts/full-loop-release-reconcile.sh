#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Durable release-state discovery and recovery for full-loop publication.

[[ -n "${_FULL_LOOP_RELEASE_RECONCILE_LOADED:-}" ]] && return 0
_FULL_LOOP_RELEASE_RECONCILE_LOADED=1

_FULL_LOOP_RELEASE_FOUND_TAG=""
_FULL_LOOP_RELEASE_RUN_JSON=""

_full_loop_release_tag_body() {
	local tag_name="$1"
	git -C "$REPO_ROOT" for-each-ref --format='%(contents)' "refs/tags/${tag_name}"
	return $?
}

_full_loop_release_find_tag_for_pr() {
	local repo="$1"
	local requested_pr="$2"
	local candidate_tag=""
	local tag_body=""
	local trailer=""
	local matched=0
	local verifier="${SCRIPT_DIR}/release-provenance-helper.sh"

	_FULL_LOOP_RELEASE_FOUND_TAG=""
	git -C "$REPO_ROOT" fetch origin --tags --quiet || return 1
	while IFS= read -r candidate_tag; do
		[[ -n "$candidate_tag" ]] || continue
		tag_body=$(_full_loop_release_tag_body "$candidate_tag") || return 1
		matched=0
		while IFS= read -r trailer; do
			case "$trailer" in
			"Aidevops-Source-PR: ${requested_pr}" | "Aidevops-Aggregated-Source: ${requested_pr}@"*)
				matched=1
				break
				;;
			esac
		done <<<"$tag_body"
		[[ "$matched" -eq 1 ]] || continue
		[[ -x "$verifier" ]] || return 1
		bash "$verifier" verify --tag "$candidate_tag" --repo "$repo" >/dev/null || return 1
		_FULL_LOOP_RELEASE_FOUND_TAG="$candidate_tag"
		return 0
	done < <(git -C "$REPO_ROOT" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname)
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
			aggregates_json=$(jq -cn --argjson pr "$aggregate_pr" --arg merge "$aggregate_merge" \
				--argjson existing "$aggregates_json" '$existing + [{pr:$pr,merge:$merge}]') || return 1
			;;
		esac
	done <<<"$tag_body"
	[[ "$source_pr" =~ ^[0-9]+$ && "$source_merge" =~ $_FULL_LOOP_SHA40_REGEX ]] || return 1
	jq -cn --argjson source_pr "$source_pr" --arg source_merge "$source_merge" \
		--argjson aggregated_sources "$aggregates_json" \
		'{source_pr:$source_pr,source_merge:$source_merge,aggregated_sources:$aggregated_sources}'
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
	_FULL_LOOP_RELEASE_RUN_JSON=$(jq -cn --arg sha "$tag_commit" --arg title "$display_title" \
		--argjson push "$push_runs" --argjson recovery "$recovery_runs" '
		([($push.workflow_runs[]? | select(.event == "push" and .head_sha == $sha))]
		 + [($recovery.workflow_runs[]? | select(.event == "workflow_dispatch" and .display_title == $title))])
		| sort_by(.created_at // "") | last // empty
	') || return 1
	[[ -n "$_FULL_LOOP_RELEASE_RUN_JSON" && "$_FULL_LOOP_RELEASE_RUN_JSON" != "null" ]] || return 3
	return 0
}

_full_loop_release_verify_channels() {
	local repo="$1"
	local tag_name="$2"
	local version="${tag_name#v}"
	local release_tag=""
	local npm_version=""
	local tap_owner="${repo%%/*}"
	local formula=""

	release_tag=$(gh release view "$tag_name" --repo "$repo" --json tagName -q '.tagName' 2>/dev/null) || return 1
	[[ "$release_tag" == "$tag_name" ]] || return 1
	command -v npm >/dev/null 2>&1 || return 1
	npm_version=$(npm view "aidevops@${version}" version --json 2>/dev/null |
		jq -r 'if type == "array" then .[0] // "" else . // "" end') || return 1
	[[ "$npm_version" == "$version" ]] || return 1
	formula=$(gh api "repos/${tap_owner}/homebrew-tap/contents/Formula/aidevops.rb" \
		--jq '.content | @base64d' 2>/dev/null) || return 1
	[[ "$formula" == *"/archive/refs/tags/${tag_name}.tar.gz"* ]] || return 1
	printf 'GITHUB_RELEASE=%s\n' "$tag_name"
	printf 'NPM_VERSION=%s\n' "$npm_version"
	printf 'HOMEBREW_VERSION=%s\n' "$version"
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

	tag_commit=$(git -C "$REPO_ROOT" rev-parse "refs/tags/${tag_name}^{commit}" 2>/dev/null) || return 1
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

	if [[ -x "$audit_helper" ]]; then
		AUDIT_QUIET=true "$audit_helper" log operation.verify \
			"Dispatching verified release reconciliation" \
			--detail "repo=${repo}" --detail "tag=${tag_name}" || return 1
	fi
	gh workflow run publish-packages.yml --repo "$repo" --ref main -f "tag=${tag_name}" || return 1
	printf 'release:queued tag=%s\n' "$tag_name"
	return 8
}

_full_loop_release_prepare_tag_worktree() {
	local tag_name="$1"
	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local release_path="${worktree_base}/aidevops-release-reconcile-${tag_name#v}-$$"

	[[ -d "$worktree_base" ]] || return 1
	git -C "$REPO_ROOT" worktree add --detach "$release_path" "$tag_name" >/dev/null || return 1
	_FULL_LOOP_RELEASE_PATH="$release_path"
	trap 'cleanup_release_worktree' EXIT
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

	source_json=$(_full_loop_release_source_json_from_tag "$tag_name") || return 1
	source_pr=$(jq -er '.source_pr' <<<"$source_json") || return 1
	source_merge=$(jq -er '.source_merge' <<<"$source_json") || return 1
	requested_present=$(jq -r --argjson requested "$requested_pr" \
		'([.source_pr] + [.aggregated_sources[].pr]) | any(. == $requested)' <<<"$source_json") || return 1
	[[ "$requested_present" == "true" ]] || return 1
	_full_loop_validate_release_candidates "$repo" "$source_json" || return 1
	_full_loop_release_prepare_tag_worktree "$tag_name" || return 1
	version_manager="${_FULL_LOOP_RELEASE_PATH}/.agents/scripts/version-manager.sh"
	[[ -f "$version_manager" ]] || return 1
	(
		cd "$_FULL_LOOP_RELEASE_PATH" || exit 1
		AIDEVOPS_RELEASE_INTENT_TRUSTED=1 \
			AIDEVOPS_TRUSTED_ISSUE_PRIORITY="${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" \
			bash "$version_manager" post-release
	) || return 1
	_full_loop_persist_release_success "$repo" "$_FULL_LOOP_RELEASE_PATH" "$source_json" \
		"$source_pr" "$source_merge"
	return $?
}

_full_loop_release_existing_command() {
	local mode="$1"
	local requested_pr="$2"
	local repo=""
	local tag_name=""
	local latest_tag=""
	local inspect_rc=0
	local receipt_path=""
	local receipt_status=""

	[[ "$mode" == "status" || "$mode" == "reconcile" ]] || return 1
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
		return 1
	fi
	_full_loop_release_inspect_remote "$repo" "$tag_name" || inspect_rc=$?
	if [[ "$inspect_rc" -eq 0 ]]; then
		if [[ "$mode" == "reconcile" ]]; then
			case "$receipt_status" in
			"$_FULL_LOOP_RELEASE_PUBLISHED")
				printf 'release:published already recorded for PR #%s\n' "$requested_pr"
				;;
			"$_FULL_LOOP_RELEASE_SUPERSEDED")
				_full_loop_verify_superseded_release_receipt "$repo" "$requested_pr" || return 1
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
	if [[ "$mode" == "status" || "$inspect_rc" -eq 8 ]]; then
		return "$inspect_rc"
	fi
	_full_loop_release_dispatch_recovery "$repo" "$tag_name"
	return $?
}
