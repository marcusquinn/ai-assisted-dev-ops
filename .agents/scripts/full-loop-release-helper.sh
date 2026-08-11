#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

_full_loop_release_valid_repo_root() {
	local candidate_root="$1"
	[[ -f "$candidate_root/aidevops.sh" ]] || return 1
	[[ -f "$candidate_root/.agents/scripts/version-manager.sh" ]] || return 1
	return 0
}

_full_loop_release_resolve_repo_root() {
	local current_root=""
	local candidate=""
	local candidate_root=""
	current_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	if [[ -n "$current_root" ]] && _full_loop_release_valid_repo_root "$current_root"; then
		printf '%s\n' "$current_root"
		return 0
	fi
	for candidate in "${AIDEVOPS_REPO_PATH:-}" "${HOME}/Git/aidevops"; do
		[[ -n "$candidate" && -d "$candidate" ]] || continue
		candidate_root=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || true)
		[[ -n "$candidate_root" ]] && _full_loop_release_valid_repo_root "$candidate_root" || continue
		printf '%s\n' "$candidate_root"
		return 0
	done
	return 1
}

REPO_ROOT=$(_full_loop_release_resolve_repo_root) || {
	printf 'Cannot locate the canonical aidevops repository. Set AIDEVOPS_REPO_PATH.\n' >&2
	exit 1
}
_FULL_LOOP_RELEASE_PATH=""
_FULL_LOOP_RELEASE_CONTROL_PATH=""

cleanup_release_worktree() {
	local release_path="${_FULL_LOOP_RELEASE_PATH:-}"
	local control_path="${_FULL_LOOP_RELEASE_CONTROL_PATH:-}"
	if [[ -n "$release_path" && "$release_path" != "$control_path" && -d "$release_path" ]]; then
		git -C "$REPO_ROOT" worktree remove "$release_path" >/dev/null 2>&1 || true
	fi
	if [[ -n "$control_path" && -d "$control_path" ]]; then
		git -C "$control_path" worktree remove "$control_path" >/dev/null 2>&1 || true
	fi
	return 0
}

_full_loop_release_prepare_control_worktree() {
	local repository_root="$1"
	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local control_path="${worktree_base}/aidevops-release-control-$$"
	local source_commit=""
	local checkout_commit=""

	[[ -d "$repository_root/.git" && -d "$worktree_base" ]] || return 1
	source_commit=$(git -C "$repository_root" rev-parse HEAD 2>/dev/null) || return 1
	[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
	git -C "$repository_root" worktree add --detach "$control_path" "$source_commit" >/dev/null || return 1
	checkout_commit=$(git -C "$control_path" rev-parse HEAD 2>/dev/null || true)
	if [[ ! -f "$control_path/.git" || "$checkout_commit" != "$source_commit" ]]; then
		git -C "$control_path" worktree remove "$control_path" >/dev/null 2>&1 || true
		return 1
	fi
	_FULL_LOOP_RELEASE_CONTROL_PATH="$control_path"
	REPO_ROOT="$control_path"
	trap 'cleanup_release_worktree' EXIT
	return 0
}

if [[ -d "$REPO_ROOT/.git" ]] && ! _full_loop_release_prepare_control_worktree "$REPO_ROOT"; then
	printf 'Cannot prepare a linked release control worktree.\n' >&2
	exit 1
fi

_full_loop_release_bind_repo_context() {
	local repo="${AIDEVOPS_FULL_LOOP_REPO:-}"
	if [[ -z "$repo" ]]; then
		repo=$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || return 1
	fi
	[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 1
	AIDEVOPS_FULL_LOOP_REPO="$repo"
	export AIDEVOPS_FULL_LOOP_REPO
	return 0
}

source "${SCRIPT_DIR}/full-loop-helper-state.sh"
# shellcheck source=./release-lane-helper.sh
source "${SCRIPT_DIR}/release-lane-helper.sh"
# shellcheck source=./full-loop-release-reconcile.sh
source "${SCRIPT_DIR}/full-loop-release-reconcile.sh"
# shellcheck source=./full-loop-release-aggregate-recovery.sh
source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"

_FULL_LOOP_RESOLVED_SOURCE_JSON=""
_FULL_LOOP_RESOLVED_SOURCE_PR=""
_FULL_LOOP_RESOLVED_SOURCE_MERGE=""
_FULL_LOOP_RESOLVED_REQUESTED_MERGE=""
_FULL_LOOP_RESOLVED_EXPECTED_SOURCES=""

_full_loop_capture_release_authorization() {
	local repo="$1"
	local source_pr="$2"
	local release_path="$3"
	local resolver="$4"
	local expected_sources="${5:-}"
	local authorization_json=""
	local resolver_args=(resolve-authorization --source-pr "$source_pr" --repo "$repo" --branch main)
	[[ -n "$expected_sources" ]] && resolver_args+=(--expected-sources "$expected_sources")
	authorization_json=$(cd "$release_path" && bash "$resolver" "${resolver_args[@]}") || return 1
	_FULL_LOOP_RESOLVED_EXPECTED_SOURCES=$(jq -er '
		.expected_sources | sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")
	' <<<"$authorization_json") || return 1
	_full_loop_persist_release_authorization "$repo" "$source_pr" "$_FULL_LOOP_RESOLVED_EXPECTED_SOURCES"
	return $?
}

_full_loop_resolve_requested_release_source() {
	local repo="$1"
	local source_pr="$2"
	local release_path="$3"
	local resolver="$4"
	local expected_sources="${5:-}"
	local blocked_pr_json=""
	local blocked_merge=""
	local blocked_head=""
	[[ -x "$resolver" ]] || return 1
	local resolver_args=(resolve-source --source-pr "$source_pr" --repo "$repo" --branch main)
	[[ -n "$expected_sources" ]] && resolver_args+=(--expected-sources "$expected_sources")
	if ! _FULL_LOOP_RESOLVED_SOURCE_JSON=$(cd "$release_path" && bash "$resolver" "${resolver_args[@]}"); then
		blocked_pr_json=$(gh pr view "$source_pr" --repo "$repo" --json state,mergedAt,mergeCommit,baseRefName 2>/dev/null || true)
		blocked_merge=$(jq -er 'select(.state == "MERGED" and .baseRefName == "main" and ((.mergedAt // "") | length > 0)) | .mergeCommit.oid' \
			<<<"$blocked_pr_json" 2>/dev/null || true)
		blocked_head=$(git -C "$release_path" rev-parse HEAD 2>/dev/null || true)
		if [[ "$blocked_merge" =~ $_FULL_LOOP_SHA40_REGEX && "$blocked_head" =~ $_FULL_LOOP_SHA40_REGEX ]] &&
			git -C "$release_path" merge-base --is-ancestor "$blocked_merge" "$blocked_head" 2>/dev/null; then
			_full_loop_write_release_failure_evidence "$repo" "$source_pr" "$blocked_merge" "$blocked_head" || true
		fi
		return 1
	fi
	_FULL_LOOP_RESOLVED_SOURCE_PR=$(jq -er '.source_pr' <<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON") || return 1
	_FULL_LOOP_RESOLVED_SOURCE_MERGE=$(jq -er '.source_merge' <<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON") || return 1
	_FULL_LOOP_RESOLVED_REQUESTED_MERGE=$(jq -er --argjson pr "$source_pr" '
		if .source_pr == $pr then .source_merge else (.aggregated_sources[] | select(.pr == $pr) | .merge) end
	' <<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON") || return 1
	local resolved_expected=""
	resolved_expected=$(jq -er '
		(.expected_sources // (if .mode == "direct" then [{pr:.source_pr,merge:.source_merge}] else .aggregated_sources end))
		| sort_by(.pr) | map("\(.pr)@\(.merge)") | join(",")
	' <<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON") || return 1
	[[ -z "$_FULL_LOOP_RESOLVED_EXPECTED_SOURCES" || "$resolved_expected" == "$_FULL_LOOP_RESOLVED_EXPECTED_SOURCES" ]] || return 1
	_FULL_LOOP_RESOLVED_EXPECTED_SOURCES="$resolved_expected"
	return 0
}

_full_loop_release_validate_existing_tag_authorization() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="$3"
	local tag_name="$_FULL_LOOP_RELEASE_FOUND_TAG"
	local observed_sources=""
	local tag_object=""
	local release_commit=""
	local reason="existing immutable tag source manifest differs from persisted trusted release authorization"
	expected_sources=$(_full_loop_release_resolve_tag_expected_sources \
		"$repo" "$source_pr" "$tag_name" "$expected_sources") || return 1
	_full_loop_persist_release_authorization "$repo" "$source_pr" "$expected_sources" || return 1
	observed_sources=$(_full_loop_release_observed_sources_for_expected "$tag_name" "$expected_sources") || return 1
	if release_authorization_compare "$expected_sources" "$observed_sources"; then
		return 0
	fi
	tag_object=$(git -C "$REPO_ROOT" rev-parse "refs/tags/${tag_name}" 2>/dev/null) || return 1
	release_commit=$(git -C "$REPO_ROOT" rev-parse "refs/tags/${tag_name}^{commit}" 2>/dev/null) || return 1
	_full_loop_write_release_authorization_gap_evidence "$repo" "$source_pr" "$expected_sources" \
		"$observed_sources" "$tag_object" "$release_commit" "$reason" || return 1
	printf 'Existing tag %s does not match the trusted expected source set; publication reconciliation refused\n' \
		"$tag_name" >&2
	return 1
}

_full_loop_release_guard_existing() {
	local repo="$1"
	local source_pr="$2"
	local expected_sources="${3:-$source_pr}"
	local receipt_path=""
	local release_status=""
	local existing_tag_rc=0

	receipt_path=$(_full_loop_release_receipt_path "$repo" "$source_pr") || return 1
	if [[ -f "$receipt_path" ]]; then
		IFS= read -r release_status <"$receipt_path" || return 1
	fi
	case "$release_status" in
	"$_FULL_LOOP_RELEASE_PUBLISHED")
		full_loop_update_cleanup_release_status "$repo" "$source_pr" "$release_status" || return 1
		printf 'release:published already recorded for PR #%s; skipping duplicate publication\n' "$source_pr"
		return 0
		;;
	"$_FULL_LOOP_RELEASE_SUPERSEDED")
		_full_loop_verify_superseded_release_receipt "$repo" "$source_pr" || return 1
		full_loop_update_cleanup_release_status "$repo" "$source_pr" "$release_status" || return 1
		printf 'release:superseded already recorded for PR #%s; skipping duplicate publication\n' "$source_pr"
		return 0
		;;
	"$_FULL_LOOP_RELEASE_NOT_REQUESTED")
		printf 'Cannot replace terminal release:not-requested evidence for PR #%s\n' "$source_pr" >&2
		return 1
		;;
	"" | "$_FULL_LOOP_PHASE_FAILED") ;;
	*)
		printf 'Cannot replace unknown release:%s evidence for PR #%s\n' "$release_status" "$source_pr" >&2
		return 1
		;;
	esac
	_full_loop_release_find_tag_for_pr "$repo" "$source_pr" || existing_tag_rc=$?
	case "$existing_tag_rc" in
	0)
		_full_loop_release_validate_existing_tag_authorization "$repo" "$source_pr" "$expected_sources" || return 1
		printf 'Existing signed release tag found for PR #%s; reconciling without another version bump\n' "$source_pr"
		_full_loop_release_existing_command reconcile "$source_pr"
		return $?
		;;
	1) return 1 ;;
	2) return 2 ;;
	*) return 1 ;;
	esac
}

_full_loop_release_usage() {
	cat <<'EOF'
Usage:
  aidevops release [patch|minor|major] SOURCE_PR [incremental|full] [--expected-sources PR[,PR...]]
  aidevops release status SOURCE_PR
  aidevops release reconcile SOURCE_PR
  aidevops release recover-aggregate SOURCE_PR --tag TAG --expected-sources PR[,PR...]
  aidevops release authorization-gap SOURCE_PR --tag TAG --expected-sources PR@SHA[,PR@SHA...] --reason TEXT

Release publication is provenance-bound and normally unattended. `status` is
read-only. `reconcile` verifies the newest matching signed tag, queues an
idempotent recovery workflow when needed, and finalizes local release receipts
only after GitHub, npm, and Homebrew all converge. A published stale tag can be
settled only by verified post-publication supersession; it is never redispatched.
EOF
	return 0
}

_full_loop_release_run_new() {
	local repo="$1"
	local source_pr="$2"
	local release_type="$3"
	local deployment_scope="$4"
	local expected_sources="$5"
	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local release_path="${worktree_base}/aidevops-release-${source_pr}-$$"
	local resolver=""
	local version_manager=""
	local release_rc=0
	[[ -d "$worktree_base" ]] || return 1
	git -C "$REPO_ROOT" fetch origin main >/dev/null || return 1
	git -C "$REPO_ROOT" worktree add --detach "$release_path" origin/main >/dev/null || return 1
	_FULL_LOOP_RELEASE_PATH="$release_path"
	trap 'cleanup_release_worktree' EXIT

	resolver="${AIDEVOPS_FULL_LOOP_SOURCE_RESOLVER:-$release_path/.agents/scripts/release-provenance-helper.sh}"
	_full_loop_capture_release_authorization "$repo" "$source_pr" "$release_path" "$resolver" "$expected_sources" || return 1
	_full_loop_resolve_requested_release_source "$repo" "$source_pr" "$release_path" "$resolver" "$_FULL_LOOP_RESOLVED_EXPECTED_SOURCES" || return 1
	_full_loop_validate_release_candidates "$repo" "$_FULL_LOOP_RESOLVED_SOURCE_JSON" || return 1
	release_lane_update "$repo" "$source_pr" "preparing" || return 1

	version_manager="${AIDEVOPS_FULL_LOOP_VERSION_MANAGER:-$release_path/.agents/scripts/version-manager.sh}"
	[[ "$version_manager" = /* ]] || version_manager="$PWD/$version_manager"
	[[ -f "$version_manager" ]] || return 1
	(
		trap - EXIT
		cd "$release_path" || exit 1
		AIDEVOPS_RELEASE_INTENT_TRUSTED=1 \
			AIDEVOPS_TRUSTED_ISSUE_PRIORITY="${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" \
			AIDEVOPS_RELEASE_DEPLOY_SCOPE="$deployment_scope" \
			bash "$version_manager" release "$release_type" --source-pr "$source_pr" \
			--expected-sources "$_FULL_LOOP_RESOLVED_EXPECTED_SOURCES"
	) || release_rc=$?
	if [[ "$release_rc" -eq 8 ]]; then
		local queued_tag=""
		[[ -r "$release_path/VERSION" ]] && queued_tag="v$(tr -d '[:space:]' <"$release_path/VERSION")"
		release_lane_update "$repo" "$source_pr" "remote-publication" "$queued_tag" || return 1
		printf 'release:queued for PR #%s; publication continues remotely\n' "$source_pr"
		printf 'Resume with: aidevops release reconcile %s\n' "$source_pr"
		return 8
	fi
	if [[ "$release_rc" -ne 0 ]]; then
		release_lane_update "$repo" "$source_pr" "reconcile-required" || true
		_full_loop_write_release_failure_evidence "$repo" "$source_pr" "$_FULL_LOOP_RESOLVED_REQUESTED_MERGE" \
			"$_FULL_LOOP_RESOLVED_SOURCE_MERGE" "$_FULL_LOOP_RESOLVED_SOURCE_PR" || true
		printf 'Publication may still be durable or queued. Reconcile without another version bump:\n' >&2
		printf '  aidevops release status %s\n' "$source_pr" >&2
		printf '  aidevops release reconcile %s\n' "$source_pr" >&2
		return 1
	fi
	_full_loop_persist_release_success "$repo" "$release_path" "$_FULL_LOOP_RESOLVED_SOURCE_JSON" \
		"$_FULL_LOOP_RESOLVED_SOURCE_PR" "$_FULL_LOOP_RESOLVED_SOURCE_MERGE" || return 1
	release_lane_finalize "$repo" "$source_pr" "published"
	return $?
}

_full_loop_release_existing_with_lane() {
	local release_type="$1"
	local source_pr="$2"
	local existing_repo=""
	local existing_rc=0
	local lane_read_rc=0
	local lane_owned=false
	existing_repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
	release_lane_read "$existing_repo" || lane_read_rc=$?
	case "$lane_read_rc" in
	0)
		printf 'RELEASE_LANE=%s\n' "$(jq -c '{active,source_pr,phase,tag,updated_at,terminal_receipt}' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")"
		if jq -e --argjson source_pr "$source_pr" '.active == true and .source_pr == $source_pr' \
			<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
			lane_owned=true
			_AIDEVOPS_RELEASE_LANE_TOKEN=$(jq -r '.operation_token' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		fi
		if [[ "$release_type" == "reconcile" ]] &&
			! jq -e --argjson source_pr "$source_pr" '.active != true or .source_pr == $source_pr' \
				<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
			printf 'A different source owns the active release lane\n' >&2
			return 75
		fi
		;;
	2) ;;
	*)
		printf 'Cannot verify repository release lane\n' >&2
		return 1
		;;
	esac
	_full_loop_release_existing_command "$release_type" "$source_pr" || existing_rc=$?
	if [[ "$release_type" == "reconcile" && "$lane_owned" == "true" ]]; then
		if [[ "$existing_rc" -eq 0 ]]; then
			local receipt_path=""
			local receipt_status=""
			receipt_path=$(_full_loop_release_receipt_path "$existing_repo" "$source_pr") || return 1
			[[ -f "$receipt_path" ]] && IFS= read -r receipt_status <"$receipt_path" || true
			case "$receipt_status" in
			"$_FULL_LOOP_RELEASE_PUBLISHED" | "$_FULL_LOOP_RELEASE_SUPERSEDED") ;;
			*) return 1 ;;
			esac
			release_lane_finalize "$existing_repo" "$source_pr" "$receipt_status" || return 1
		elif [[ "$existing_rc" -eq 8 ]]; then
			release_lane_update "$existing_repo" "$source_pr" "remote-publication" || return 1
		fi
	fi
	return "$existing_rc"
}

_full_loop_release_guard_competing_lane() {
	local repo="$1"
	local source_pr="$2"
	local lane_read_rc=0
	release_lane_read "$repo" || lane_read_rc=$?
	case "$lane_read_rc" in
	2) return 0 ;;
	0) ;;
	*) return 1 ;;
	esac
	if jq -e --argjson source_pr "$source_pr" '.active == true and .source_pr != $source_pr' \
		<<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
		printf 'ACTIVE_RELEASE_LANE source_pr=%s phase=%s tag=%s\n' \
			"$(jq -r '.source_pr' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")" \
			"$(jq -r '.phase' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")" \
			"$(jq -r '.tag // "pending"' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")"
		printf 'Resume with: aidevops release reconcile %s\n' "$(jq -r '.source_pr' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")"
		return 75
	fi
	return 0
}

_FULL_LOOP_RESERVED_RECOVERY_EXPECTED=""
_FULL_LOOP_RESERVED_RECOVERY_COMPLETED=false

_full_loop_release_resolve_persisted_intent() {
	local repo="$1"
	local source_pr="$2"
	local requested_sources="$3"
	local persisted_sources="$4"
	local persisted_prs=""
	local requested_prs=""
	_FULL_LOOP_RESERVED_RECOVERY_EXPECTED="$requested_sources"
	_FULL_LOOP_RESERVED_RECOVERY_COMPLETED=false
	if [[ -z "$requested_sources" ]]; then
		_FULL_LOOP_RESERVED_RECOVERY_EXPECTED="$persisted_sources"
		return 0
	fi
	requested_prs=$(release_authorization_intent_json "$requested_sources" | jq -c 'map(.pr)') || return 1
	persisted_prs=$(release_authorization_intent_json "$persisted_sources" | jq -c 'map(.pr)') || return 1
	[[ "$requested_prs" != "$persisted_prs" ]] || return 0
	_full_loop_recovery_expand_reserved_authorization "$repo" "$source_pr" "$requested_sources" || return $?
	_FULL_LOOP_RESERVED_RECOVERY_EXPECTED="$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED"
	_FULL_LOOP_RESERVED_RECOVERY_COMPLETED=true
	return 0
}

_full_loop_release_start_new() {
	local repo="$1"
	local source_pr="$2"
	local release_type="$3"
	local deployment_scope="$4"
	local expected_sources="$5"
	local existing_state_rc=0
	local persisted_expected=""
	_full_loop_release_guard_competing_lane "$repo" "$source_pr" || return $?
	if persisted_expected=$(_full_loop_read_release_authorization "$repo" "$source_pr"); then
		_full_loop_release_resolve_persisted_intent "$repo" "$source_pr" "$expected_sources" \
			"$persisted_expected" || return $?
		expected_sources="$_FULL_LOOP_RESERVED_RECOVERY_EXPECTED"
	fi
	_full_loop_release_guard_existing "$repo" "$source_pr" "${expected_sources:-$source_pr}" || existing_state_rc=$?
	case "$existing_state_rc" in
	0) return 0 ;;
	2) ;;
	*) return "$existing_state_rc" ;;
	esac
	if [[ "$_FULL_LOOP_RESERVED_RECOVERY_COMPLETED" == "true" ]]; then
		_full_loop_release_run_new "$repo" "$source_pr" "$release_type" "$deployment_scope" "$expected_sources"
		return $?
	fi
	release_lane_acquire "$repo" "$source_pr" "${expected_sources:-$source_pr}" || return $?
	if [[ "$_AIDEVOPS_RELEASE_LANE_RESULT" == "adopted" ]]; then
		printf 'Release lane already belongs to PR #%s; reconcile instead of creating another version bump\n' "$source_pr"
		return 8
	fi
	_full_loop_release_run_new "$repo" "$source_pr" "$release_type" "$deployment_scope" \
		"${expected_sources:-$source_pr}"
	return $?
}

main() {
	local release_type="${1:-patch}"
	local source_pr="${2:-}"
	local deployment_scope="incremental"
	local expected_sources="${AIDEVOPS_RELEASE_EXPECTED_SOURCES:-}"
	local tag_name=""
	local gap_reason=""
	if [[ $# -ge 2 ]]; then
		shift 2
	else
		shift "$#"
	fi
	while [[ $# -gt 0 ]]; do
		case "$1" in
		incremental | full)
			deployment_scope="$1"
			shift
			;;
		--expected-sources)
			expected_sources="${2:-}"
			[[ -n "$expected_sources" ]] || return 1
			shift 2
			;;
		--tag)
			tag_name="${2:-}"
			[[ -n "$tag_name" ]] || return 1
			shift 2
			;;
		--reason)
			gap_reason="${2:-}"
			[[ -n "$gap_reason" ]] || return 1
			shift 2
			;;
		*) return 1 ;;
		esac
	done
	case "$release_type" in
	help | --help | -h)
		_full_loop_release_usage
		return 0
		;;
	status | reconcile)
		[[ "$source_pr" =~ ^[0-9]+$ ]] || {
			_full_loop_release_usage >&2
			return 1
		}
		_full_loop_release_bind_repo_context || return 1
		_full_loop_release_existing_with_lane "$release_type" "$source_pr"
		return $?
		;;
	recover-aggregate)
		[[ "$source_pr" =~ ^[0-9]+$ && "$tag_name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && -n "$expected_sources" ]] || {
			_full_loop_release_usage >&2
			return 1
		}
		_full_loop_release_bind_repo_context || return 1
		local recovery_repo=""
		recovery_repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
		_full_loop_release_recover_aggregate "$recovery_repo" "$source_pr" "$tag_name" "$expected_sources"
		return $?
		;;
	authorization-gap)
		[[ "$source_pr" =~ ^[0-9]+$ && -n "$tag_name" && -n "$expected_sources" && -n "$gap_reason" ]] || {
			_full_loop_release_usage >&2
			return 1
		}
		_full_loop_release_bind_repo_context || return 1
		local gap_repo=""
		gap_repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
		_full_loop_release_record_authorization_gap "$gap_repo" "$source_pr" "$tag_name" "$expected_sources" "$gap_reason"
		return $?
		;;
	esac
	case "$release_type" in patch | minor | major) ;; *) return 1 ;; esac
	[[ -z "$tag_name" && -z "$gap_reason" ]] || return 1
	case "$deployment_scope" in incremental | full) ;; *) return 1 ;; esac
	[[ "$source_pr" =~ ^[0-9]+$ ]] || return 1
	_full_loop_release_bind_repo_context || return 1
	local repo=""
	repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
	_full_loop_release_start_new "$repo" "$source_pr" "$release_type" "$deployment_scope" "$expected_sources"
	return $?
}

main "$@"
