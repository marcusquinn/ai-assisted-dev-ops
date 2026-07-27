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
# shellcheck source=./full-loop-release-reconcile.sh
source "${SCRIPT_DIR}/full-loop-release-reconcile.sh"

_FULL_LOOP_RESOLVED_SOURCE_JSON=""
_FULL_LOOP_RESOLVED_SOURCE_PR=""
_FULL_LOOP_RESOLVED_SOURCE_MERGE=""
_FULL_LOOP_RESOLVED_REQUESTED_MERGE=""

_full_loop_resolve_requested_release_source() {
	local repo="$1"
	local source_pr="$2"
	local release_path="$3"
	local resolver="$4"
	local blocked_pr_json=""
	local blocked_merge=""
	local blocked_head=""
	[[ -x "$resolver" ]] || return 1
	if ! _FULL_LOOP_RESOLVED_SOURCE_JSON=$(cd "$release_path" && bash "$resolver" resolve-source \
		--source-pr "$source_pr" --repo "$repo" --branch main); then
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
	return 0
}

_full_loop_validate_release_candidates() {
	local repo="$1"
	local source_json="$2"
	local candidate_pr=""
	local candidate_status=""
	local candidate_receipt=""
	while IFS= read -r candidate_pr; do
		[[ "$candidate_pr" =~ ^[0-9]+$ ]] || return 1
		candidate_receipt=$(_full_loop_release_receipt_path "$repo" "$candidate_pr") || return 1
		candidate_status=""
		[[ -f "$candidate_receipt" ]] && IFS= read -r candidate_status <"$candidate_receipt" || true
		case "$candidate_status" in
		"" | "$_FULL_LOOP_PHASE_FAILED") ;;
		*)
			printf 'Cannot aggregate terminal release:%s evidence for PR #%s\n' "$candidate_status" "$candidate_pr" >&2
			return 1
			;;
		esac
	done < <(jq -r '[.source_pr] + [.aggregated_sources[].pr] | unique[]' <<<"$source_json")
	return 0
}

_full_loop_persist_release_success() {
	local repo="$1"
	local release_path="$2"
	local source_json="$3"
	local release_source_pr="$4"
	local release_source_merge="$5"
	local version=""
	local tag_name=""
	local tag_commit=""
	local aggregated_pr=""
	local aggregated_merge=""
	IFS= read -r version <"$release_path/VERSION" || return 1
	tag_name="v${version}"
	tag_commit=$(git -C "$release_path" rev-parse "refs/tags/${tag_name}^{commit}" 2>/dev/null) || return 1
	while IFS=$'\t' read -r aggregated_pr aggregated_merge; do
		[[ -n "$aggregated_pr" ]] || continue
		_full_loop_write_superseded_release_receipt "$repo" "$aggregated_pr" "$aggregated_merge" \
			"$release_source_pr" "$release_source_merge" "$tag_name" "$tag_commit" || return 1
	done < <(jq -r '.aggregated_sources[] | [.pr,.merge] | @tsv' <<<"$source_json")
	_full_loop_write_release_receipt "$repo" "$release_source_pr" "$_FULL_LOOP_RELEASE_PUBLISHED"
	return $?
}

_full_loop_release_guard_existing() {
	local repo="$1"
	local source_pr="$2"
	local receipt_path=""
	local release_status=""
	local existing_tag_rc=0

	receipt_path=$(_full_loop_release_receipt_path "$repo" "$source_pr") || return 1
	if [[ -f "$receipt_path" ]]; then
		IFS= read -r release_status <"$receipt_path" || return 1
	fi
	case "$release_status" in
	"$_FULL_LOOP_RELEASE_PUBLISHED")
		printf 'release:published already recorded for PR #%s; skipping duplicate publication\n' "$source_pr"
		return 0
		;;
	"$_FULL_LOOP_RELEASE_SUPERSEDED")
		_full_loop_verify_superseded_release_receipt "$repo" "$source_pr" || return 1
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
  aidevops release [patch|minor|major] SOURCE_PR [incremental|full]
  aidevops release status SOURCE_PR
  aidevops release reconcile SOURCE_PR

Release publication is provenance-bound and normally unattended. `status` is
read-only. `reconcile` verifies the newest matching signed tag, queues an
idempotent recovery workflow when needed, and finalizes local release receipts
only after GitHub, npm, and Homebrew all converge.
EOF
	return 0
}

main() {
	local release_type="${1:-patch}"
	local source_pr="${2:-}"
	local deployment_scope="${3:-incremental}"
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
		_full_loop_release_existing_command "$release_type" "$source_pr"
		return $?
		;;
	esac
	case "$release_type" in patch | minor | major) ;; *) return 1 ;; esac
	case "$deployment_scope" in incremental | full) ;; *) return 1 ;; esac
	[[ "$source_pr" =~ ^[0-9]+$ ]] || return 1
	_full_loop_release_bind_repo_context || return 1
	local repo=""
	local existing_state_rc=0
	repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
	_full_loop_release_guard_existing "$repo" "$source_pr" || existing_state_rc=$?
	case "$existing_state_rc" in
	0) return 0 ;;
	2) ;;
	*) return "$existing_state_rc" ;;
	esac

	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local release_path="${worktree_base}/aidevops-release-${source_pr}-$$"
	[[ -d "$worktree_base" ]] || return 1
	git -C "$REPO_ROOT" fetch origin main >/dev/null || return 1
	git -C "$REPO_ROOT" worktree add --detach "$release_path" origin/main >/dev/null || return 1
	_FULL_LOOP_RELEASE_PATH="$release_path"
	trap 'cleanup_release_worktree' EXIT

	local resolver="${AIDEVOPS_FULL_LOOP_SOURCE_RESOLVER:-$release_path/.agents/scripts/release-provenance-helper.sh}"
	_full_loop_resolve_requested_release_source "$repo" "$source_pr" "$release_path" "$resolver" || return 1
	_full_loop_validate_release_candidates "$repo" "$_FULL_LOOP_RESOLVED_SOURCE_JSON" || return 1

	local version_manager="${AIDEVOPS_FULL_LOOP_VERSION_MANAGER:-$release_path/.agents/scripts/version-manager.sh}"
	local release_rc=0
	[[ "$version_manager" = /* ]] || version_manager="$PWD/$version_manager"
	[[ -f "$version_manager" ]] || return 1
	(
		trap - EXIT
		cd "$release_path" || exit 1
		AIDEVOPS_RELEASE_INTENT_TRUSTED=1 \
			AIDEVOPS_TRUSTED_ISSUE_PRIORITY="${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}" \
			AIDEVOPS_RELEASE_DEPLOY_SCOPE="$deployment_scope" \
			bash "$version_manager" release "$release_type" --source-pr "$source_pr"
	) || release_rc=$?
	if [[ "$release_rc" -eq 8 ]]; then
		printf 'release:queued for PR #%s; publication continues remotely\n' "$source_pr"
		printf 'Resume with: aidevops release reconcile %s\n' "$source_pr"
		return 8
	fi
	if [[ "$release_rc" -ne 0 ]]; then
		_full_loop_write_release_failure_evidence "$repo" "$source_pr" "$_FULL_LOOP_RESOLVED_REQUESTED_MERGE" \
			"$_FULL_LOOP_RESOLVED_SOURCE_MERGE" "$_FULL_LOOP_RESOLVED_SOURCE_PR" || true
		printf 'Publication may still be durable or queued. Reconcile without another version bump:\n' >&2
		printf '  aidevops release status %s\n' "$source_pr" >&2
		printf '  aidevops release reconcile %s\n' "$source_pr" >&2
		return 1
	fi
	_full_loop_persist_release_success "$repo" "$release_path" "$_FULL_LOOP_RESOLVED_SOURCE_JSON" \
		"$_FULL_LOOP_RESOLVED_SOURCE_PR" "$_FULL_LOOP_RESOLVED_SOURCE_MERGE"
	return $?
}

main "$@"
