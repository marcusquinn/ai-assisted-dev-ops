#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001,SC2034,SC2181,SC2317
set -euo pipefail

# Version Manager for AI DevOps Framework
# Manages semantic versioning and automated version bumping
#
# Author: AI DevOps Framework
# Version: 1.1.0
#
# This file is the thin orchestrator. The implementation is in sub-libraries:
#   version-manager-changelog.sh  — CHANGELOG.md read/write/generate
#   version-manager-preflight.sh  — secretlint, shellcheck, patch-release preflight
#   version-manager-files.sh      — VERSION, package.json, README.md, etc.
#   version-manager-git.sh        — remote sync, task auto-complete, commit, push
#   version-manager-release.sh    — git tag, GitHub release, hotfix signal

# Source shared constants (provides sed_inplace, print_*, color constants)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./task-identity-lib.sh
source "${SCRIPT_DIR}/task-identity-lib.sh"

# Repository root directory
# First try git (works when called from any location within a repo)
# Fall back to script-relative path (for when script is sourced or tested standalone)
if git rev-parse --show-toplevel &>/dev/null; then
	REPO_ROOT="$(git rev-parse --show-toplevel)"
else
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
VERSION_FILE="$REPO_ROOT/VERSION"
_VERSION_MANAGER_ACTION_RELEASE="release"

_version_manager_marker_is_truthy() {
	local marker=""
	local marker_lower=""

	for marker in "$@"; do
		marker_lower=$(printf '%s' "$marker" | tr '[:upper:]' '[:lower:]')
		case "$marker_lower" in
		"1" | "true" | "yes" | "on")
			return 0
			;;
		esac
	done
	return 1
}

_version_manager_is_headless_task_worker() {
	local worker_marker="${WORKER_TASK_NUMBER:-}${WORKER_ISSUE_NUMBER:-}${WORKER_SESSION_KEY:-}${AIDEVOPS_SESSION_KEY:-}"
	local worker_marker_lower=""

	_version_manager_marker_is_truthy "${AIDEVOPS_HEADLESS:-}" "${FULL_LOOP_HEADLESS:-}" "${OPENCODE_HEADLESS:-}" "${HEADLESS:-}" || return 1
	[[ -n "${WORKER_TASK_NUMBER:-}" ]] && return 0
	[[ -n "${WORKER_ISSUE_NUMBER:-}" ]] && return 0
	worker_marker_lower=$(printf '%s' "$worker_marker" | tr '[:upper:]' '[:lower:]')
	[[ "$worker_marker_lower" == *task-* || "$worker_marker_lower" == *issue-* ]] && return 0
	return 1
}

_version_manager_has_approved_release_context() {
	local release_intent="${AIDEVOPS_RELEASE_INTENT_TRUSTED:-}"
	local priority="${AIDEVOPS_TRUSTED_ISSUE_PRIORITY:-}"

	[[ "$release_intent" == "1" ]] || return 1
	if ! _version_manager_is_headless_task_worker; then
		return 0
	fi
	case "$priority" in
	high | critical) return 0 ;;
	*) return 1 ;;
	esac
}

_version_manager_current_branch_name() {
	local branch_name=""

	branch_name=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	if [[ -z "$branch_name" ]]; then
		branch_name="unknown"
	fi
	printf '%s\n' "$branch_name"
	return 0
}

_version_manager_action_is_read_only() {
	local action="$1"
	shift || true
	case "$action" in
	"" | "help" | "usage" | "get" | "validate" | "preflight" | "changelog-check" | "changelog-preview" | "list-task-ids")
		return 0
		;;
	"$_VERSION_MANAGER_ACTION_RELEASE")
		local arg=""
		for arg in "$@"; do
			[[ "$arg" == "--dry-run" ]] && return 0
		done
		;;
	esac
	return 1
}

_version_manager_guard_headless_release_scope() {
	local action="$1"
	shift || true

	_version_manager_action_is_read_only "$action" "$@" && return 0
	[[ "$action" == "$_VERSION_MANAGER_ACTION_RELEASE" || "$action" == "post-release" ]] || {
		_version_manager_is_headless_task_worker || return 0
	}

	local branch_name=""
	branch_name=$(_version_manager_current_branch_name)
	_version_manager_has_approved_release_context "$branch_name" && return 0

	print_warning "Skipping version-manager ${action:-help}: publication requires explicit trusted release intent."
	print_info "Task worker: ${WORKER_TASK_NUMBER:-unknown}; issue: ${WORKER_ISSUE_NUMBER:-unknown}; repo: ${REPO_ROOT}; session: ${WORKER_SESSION_KEY:-${AIDEVOPS_SESSION_KEY:-unknown}}; branch: ${branch_name}"
	print_info "Interactive publication requires AIDEVOPS_RELEASE_INTENT_TRUSTED=1. Headless publication also requires AIDEVOPS_TRUSTED_ISSUE_PRIORITY=high or critical."
	print_info "This guard is non-fatal so the original issue workflow can continue without treating release cleanup as required."
	return 1
}

# Source sub-libraries
# shellcheck source=./runtime-bundle-verifier.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/runtime-bundle-verifier.sh"

# shellcheck source=./version-manager-changelog.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/version-manager-changelog.sh"

# shellcheck source=./version-manager-preflight.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/version-manager-preflight.sh"

# shellcheck source=./version-manager-files.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/version-manager-files.sh"

# shellcheck source=./version-manager-git.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/version-manager-git.sh"

# shellcheck source=./version-manager-release.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/version-manager-release.sh"

# Function to get current version
get_current_version() {
	if [[ -f "$VERSION_FILE" ]]; then
		cat "$VERSION_FILE"
	else
		echo "1.0.0"
	fi
	return 0
}

# Function to bump version
bump_version() {
	local bump_type="$1"
	local current_version
	current_version=$(get_current_version)

	local major minor patch
	IFS='.' read -r major minor patch <<<"$current_version"

	case "$bump_type" in
	"major")
		major=$((major + 1))
		minor=0
		patch=0
		;;
	"minor")
		minor=$((minor + 1))
		patch=0
		;;
	"patch")
		patch=$((patch + 1))
		;;
	*)
		print_error "Invalid bump type. Use: major, minor, or patch"
		return 1
		;;
	esac

	local new_version="$major.$minor.$patch"
	echo "$new_version" >"$VERSION_FILE"
	echo "$new_version"
	return 0
}

# Handle the "bump" action: bump version and update all files.
# Arguments: bump_type [major|minor|patch]
_main_bump() {
	local bump_type="$1"

	if [[ -z "$bump_type" ]]; then
		print_error "Bump type required. Usage: $0 bump [major|minor|patch]"
		exit 1
	fi

	local current_version
	current_version=$(get_current_version)
	print_info "Current version: $current_version"

	local new_version
	new_version=$(bump_version "$bump_type")

	if [[ $? -eq 0 ]]; then
		print_success "Bumped version: $current_version → $new_version"
		if ! update_version_in_files "$new_version"; then
			print_error "Failed to update version in all files"
			print_info "Run validation to check: $0 validate"
			exit 1
		fi
		echo "$new_version"
	else
		exit 1
	fi
	return 0
}

# Check changelog state before release; exit if nothing to release.
# Arguments: force_flag
_release_check_changelog() {
	local force_flag="$1"

	if ! check_changelog_unreleased; then
		local releasable_commits
		releasable_commits=$(get_releasable_commit_subjects)

		if [[ -n "$releasable_commits" ]]; then
			print_warning "CHANGELOG.md [Unreleased] is empty; proceeding with auto-generated changelog from commit history"
			print_info "Detected releasable commits since last tag:"
			local listed_count=0
			while IFS= read -r commit_subject; do
				[[ -z "$commit_subject" ]] && continue
				print_info "  - $commit_subject"
				listed_count=$((listed_count + 1))
				if [[ "$listed_count" -ge 5 ]]; then
					break
				fi
			done <<<"$releasable_commits"
		else
			if [[ "$force_flag" != "--force" ]]; then
				print_error "CHANGELOG.md [Unreleased] is empty and no releasable commits were found since last tag"
				print_info "Nothing meaningful to release. Add commits or use --force to bypass"
				exit 1
			else
				print_warning "Bypassing changelog and empty-commit checks with --force"
			fi
		fi
	fi
	return 0
}

# Roll back release file mutations when a pre-commit release gate exits after
# bumping files. Release starts from a clean tree by default, so restoring the
# tracked diff on failure returns retries to the same next-version target instead
# of leaving a half-bumped VERSION behind.
_release_rollback_mutated_tree() {
	if [[ "${VERSION_MANAGER_RELEASE_ROLLBACK_ACTIVE:-0}" -ne 1 ]]; then
		return 0
	fi

	local changed_files=""
	changed_files=$(cd "$REPO_ROOT" && git diff --name-only 2>/dev/null || true)
	if [[ -z "$changed_files" ]]; then
		return 0
	fi

	print_warning "Rolling back release file mutations after failed pre-commit release gate"
	local changed_file=""
	while IFS= read -r changed_file; do
		[[ -n "$changed_file" ]] || continue
		(cd "$REPO_ROOT" && git checkout -- "$changed_file" 2>/dev/null) || true
	done <<<"$changed_files"
	return 0
}

_release_enable_failure_rollback() {
	VERSION_MANAGER_RELEASE_ROLLBACK_ACTIVE=1
	trap '_release_rollback_mutated_tree' EXIT
	return 0
}

_release_disable_failure_rollback() {
	VERSION_MANAGER_RELEASE_ROLLBACK_ACTIVE=0
	trap - EXIT
	return 0
}

_release_abort_after_mutation() {
	_release_rollback_mutated_tree
	exit 1
}

_release_require_new_tag() {
	local bump_type="$1"
	local tag_name="$2"
	local remote_exit=0
	local source_pr="${VERSION_MANAGER_SOURCE_PR:-<SOURCE_PR>}"

	git ls-remote -q --exit-code --tags origin "refs/tags/$tag_name" >/dev/null 2>&1 || remote_exit=$?
	if ! git show-ref --tags "$tag_name" &>/dev/null && [[ "$remote_exit" -ne 0 ]]; then
		return 0
	fi
	print_error "PARTIAL RELEASE STATE DETECTED: tag $tag_name already exists"
	print_info ""
	print_info "Diagnosis:"
	print_info "  git show $tag_name                    # inspect the existing tag"
	print_info "  gh release view $tag_name             # check if GitHub release exists"
	print_info "  git log $tag_name --oneline -5        # see what the tag points to"
	print_info ""
	print_info "Recovery: never delete or recreate a signed release tag."
	print_info "  aidevops release status $source_pr"
	print_info "  aidevops release reconcile $source_pr"
	print_info "If provenance is invalid, stop and review a corrected new version instead of mutating $tag_name."
	exit 1
}

_release_handle_push_failure() {
	local new_version="$1"
	local remote_exit=0

	git ls-remote -q --exit-code --tags origin "refs/tags/v$new_version" >/dev/null 2>&1 || remote_exit=$?
	if [[ "$remote_exit" -eq 0 ]]; then
		print_warning "Push failed but tag v$new_version already exists on remote (concurrent release?)"
		print_info "Deleting local tag to avoid divergence. Check remote state:"
		git tag -d "v$new_version" 2>/dev/null || true
		print_info "  aidevops release status ${VERSION_MANAGER_SOURCE_PR:-<SOURCE_PR>}"
		print_info "  aidevops release reconcile ${VERSION_MANAGER_SOURCE_PR:-<SOURCE_PR>}"
		exit 1
	fi
	print_warning "Rolling back local tag v$new_version due to push failure"
	git tag -d "v$new_version" 2>/dev/null || true
	echo ""
	print_info "The unpushed version commit remains local for diagnosis only."
	print_info "Discard this release worktree and rerun the release from current origin/main"
	print_info "with the latest merged source PR; never recreate the provenance tag manually."
	exit 1
}

# Perform the version bump, file updates, tag, push, and protected publication.
# Arguments: bump_type new_version hotfix_flag
_release_execute() {
	local bump_type="$1"
	local new_version="$2"
	local hotfix_flag="$3"
	local tag_name="v$new_version"
	local publication_rc=0

	_release_require_new_tag "$bump_type" "$tag_name"

	print_info "Updating version references in files..."
	if ! update_version_in_files "$new_version"; then
		print_error "Failed to update version in all files. Aborting release."
		print_info "The VERSION file may have been updated. Run validation to check:"
		print_info "  $0 validate"
		_release_abort_after_mutation
	fi

	print_info "Updating CHANGELOG.md..."
	if ! update_changelog "$new_version"; then
		print_warning "Failed to update CHANGELOG.md automatically"
	fi

	# Auto-mark tasks complete based on commit messages
	auto_mark_tasks_complete

	print_info "Validating version consistency..."
	if validate_version_consistency "$new_version"; then
		print_success "Version validation passed"
		if ! validate_release_deployment_readiness; then
			print_error "Aborting release before publication: local deployment prerequisites are unsafe"
			_release_abort_after_mutation
		fi

		# t2437/GH#20073: commit the bump, verify HEAD is the bump commit.
		if ! _release_commit_and_verify_bump "$new_version" "$bump_type"; then
			_release_abort_after_mutation
		fi

		if ! create_git_tag "$new_version"; then
			print_error "Aborting release: tag creation failed (see above for diagnosis)"
			exit 1
		fi
		if ! push_changes "$new_version"; then
			_release_handle_push_failure "$new_version"
		fi
		_publish_github_release "$new_version" || publication_rc=$?
		if [[ "$publication_rc" -eq 8 ]]; then
			_release_disable_failure_rollback
			print_success "release:queued"
			print_info "Publication is durable and can finish without this process"
			print_info "Reconcile the source PR after the workflow completes: aidevops release reconcile <SOURCE_PR>"
			return 8
		fi
		if [[ "$publication_rc" -ne 0 ]]; then
			print_error "Release publication failed for v$new_version"
			print_error "release:failed"
			return 1
		fi
		print_success "release:published"
		# The remote tag and GitHub release are now durable. Never run the local
		# mutation rollback trap for a later hotfix/deployment convergence failure.
		_release_disable_failure_rollback
		if ! run_post_publication_gates "$new_version" "$hotfix_flag"; then
			return 1
		fi
		print_success "Release $new_version created successfully!"
	else
		print_error "Version validation failed. Please fix inconsistencies before creating release."
		_release_abort_after_mutation
	fi
	return 0
}

# Show release plan without executing (--dry-run).
# Args: bump_type hotfix_flag force_flag skip_preflight
_release_dry_run() {
	local bump_type="$1"
	local hotfix_flag="$2"
	local force_flag="$3"
	local skip_preflight="$4"

	local current_version
	current_version=$(get_current_version)
	# Compute planned version without writing to VERSION file
	local dr_major dr_minor dr_patch planned_version
	IFS='.' read -r dr_major dr_minor dr_patch <<<"$current_version"
	case "$bump_type" in
	"major")
		dr_major=$((dr_major + 1))
		dr_minor=0
		dr_patch=0
		;;
	"minor")
		dr_minor=$((dr_minor + 1))
		dr_patch=0
		;;
	"patch") dr_patch=$((dr_patch + 1)) ;;
	esac
	planned_version="${dr_major}.${dr_minor}.${dr_patch}"
	print_info "=== DRY RUN: Release Plan ==="
	print_info "  Current version: $current_version"
	print_info "  Planned version: $planned_version"
	print_info "  Bump type: $bump_type"
	print_info "  Tags: v${planned_version}"
	if [[ "$hotfix_flag" -eq 1 ]]; then
		print_info "  Hotfix tag: hotfix-v${planned_version}"
		print_info "  Runners with auto_hotfix_accept=true will pull within ~5 minutes"
		print_info "  Runners with auto_hotfix_accept=false will see a session banner"
	fi
	print_info "  Force: $([[ "$force_flag" -eq 1 ]] && echo "yes" || echo "no")"
	print_info "  Skip preflight: $([[ "$skip_preflight" -eq 1 ]] && echo "yes" || echo "no")"
	print_info "=== DRY RUN: No changes made ==="
	return 0
}

# Handle the "release" action: full release pipeline.
# Arguments: bump_type [flags...] (all positional args from main, starting at $1=bump_type)
_parse_release_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force_flag=1
			shift
			;;
		--skip-preflight)
			skip_preflight=1
			shift
			;;
		--allow-dirty)
			allow_dirty=1
			shift
			;;
		--hotfix)
			hotfix_flag=1
			shift
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		--source-pr)
			source_pr="${2:-}"
			[[ -n "$source_pr" ]] || {
				print_error "--source-pr requires a PR number"
				return 1
			}
			shift 2
			;;
		*)
			print_error "Unknown release option: $1"
			return 1
			;;
		esac
	done
	return 0
}

_main_release() {
	local bump_type="${1:-patch}"
	shift
	[[ -n "$bump_type" ]] || bump_type="patch"

	# Parse flags (can be in any order after bump_type)
	local force_flag=0 skip_preflight=0 allow_dirty=0 hotfix_flag=0 dry_run=0 source_pr=""
	_parse_release_args "$@" || return 1

	# Hotfix releases are restricted to patch bumps and require maintainer identity
	if [[ "$hotfix_flag" -eq 1 ]]; then
		if [[ "$bump_type" != "patch" ]]; then
			print_error "Hotfix releases can only be patch bumps (got: $bump_type)"
			exit 1
		fi
		if ! _verify_maintainer_identity; then
			exit 1
		fi
		print_info "Hotfix mode: this release will signal immediate runner propagation"
	fi

	if [[ "$dry_run" -eq 1 ]]; then
		_release_dry_run "$bump_type" "$hotfix_flag" "$force_flag" "$skip_preflight"
		return 0
	fi

	print_info "Creating release with $bump_type version bump..."
	# Structural safety is never bypassable by --force. Canonical releases can
	# corrupt every parallel session sharing that repository.
	assert_release_linked_worktree || exit 1
	if release_source_pr_required && [[ -z "$source_pr" ]]; then
		print_error "aidevops releases require --source-pr <merged-pr-number>"
		exit 1
	fi

	# Verify local branch is in sync with remote
	if ! verify_remote_sync "main"; then
		print_error "Cannot release when local/remote are out of sync; --force cannot bypass structural provenance"
		exit 1
	fi
	if [[ -n "$source_pr" ]]; then
		verify_release_source_pr "$source_pr" "main" || exit 1
	fi
	# The detached release worktree and merged-PR provenance above are the
	# complete publication boundary. Human canonical checkouts may be dirty,
	# stale, or diverged and are deliberately irrelevant to release safety.

	# Check for uncommitted changes
	if [[ "$allow_dirty" -eq 0 ]]; then
		if ! check_working_tree_clean; then
			print_error "Cannot release with uncommitted changes."
			print_info "Commit your changes first, or use --allow-dirty to bypass"
			exit 1
		fi
		_release_enable_failure_rollback
	else
		print_warning "Releasing with uncommitted changes (--allow-dirty)"
	fi

	# Run preflight checks unless skipped
	if [[ "$skip_preflight" -eq 0 ]]; then
		if ! run_preflight_checks "$bump_type"; then
			print_error "Preflight checks failed. Fix issues or use --skip-preflight."
			exit 1
		fi
	else
		print_warning "Skipping preflight checks with --skip-preflight"
	fi

	local force_arg=""
	if [[ "$force_flag" -eq 1 ]]; then
		force_arg="--force"
	fi
	_release_check_changelog "$force_arg"

	local new_version
	new_version=$(bump_version "$bump_type")

	if [[ $? -eq 0 ]]; then
		local release_exit=0
		_release_execute "$bump_type" "$new_version" "$hotfix_flag" || release_exit=$?
		return "$release_exit"
	else
		exit 1
	fi
	return 0
}

# Print usage/help text.
_main_usage() {
	echo "AI DevOps Framework Version Manager"
	echo ""
	echo "Usage: $0 [action] [options]"
	echo ""
	echo "Actions:"
	echo "  get                           Get current version"
	echo "  bump [major|minor|patch]      Bump version"
	echo "  tag                           Create git tag for current version"
	echo "  github-release                Create or observe publication for the current version"
	echo "  post-release [--hotfix]       Retry post-publication propagation and deployment gates"
	echo "  release [major|minor|patch] --source-pr N"
	echo "                                 Bump version (default: patch), tag, publish, and deploy from a verified merged PR"
	echo "  release patch --hotfix       Patch release with hotfix signal for immediate runner propagation"
	echo "  preflight [major|minor|patch] Run release preflight checks only"
	echo "  validate                      Validate version consistency across all files"
	echo "  changelog-check               Check CHANGELOG.md has entry for current version"
	echo "  changelog-preview             Generate changelog entry from commits since last tag"
	echo "  auto-mark-tasks               Auto-mark tasks complete based on commit messages"
	echo "  list-task-ids                 List task IDs found in commits since last release"
	echo ""
	echo "Options:"
	echo "  --force                       Bypass changelog check (use with release)"
	echo "  --skip-preflight              Bypass quality checks (use with release)"
	echo "  --hotfix                      Signal hotfix for immediate runner propagation (patch only)"
	echo "  --dry-run                     Show release plan without executing (use with release)"
	echo ""
	echo "Examples:"
	echo "  $0 get"
	echo "  $0 bump minor"
	echo "  $0 release patch"
	echo "  $0 release minor --force"
	echo "  $0 release patch --skip-preflight"
	echo "  $0 release patch --force --skip-preflight"
	echo "  $0 release patch --hotfix"
	echo "  $0 release patch --hotfix --dry-run"
	echo "  $0 github-release"
	echo "  $0 post-release --hotfix"
	echo "  $0 validate"
	echo "  $0 changelog-check"
	echo "  $0 changelog-preview"
	return 0
}

# Main function
main() {
	local action="${1:-}"
	local bump_type="${2:-}"

	if ! _version_manager_guard_headless_release_scope "$action" "${@:2}"; then
		return 0
	fi

	case "$action" in
	"get")
		get_current_version
		;;
	"bump")
		_main_bump "$bump_type"
		;;
	"tag")
		local version
		version=$(get_current_version)
		create_git_tag "$version"
		;;
	"$_VERSION_MANAGER_ACTION_RELEASE")
		if [[ "$bump_type" == --* ]]; then
			_main_release patch "${@:2}"
		else
			_main_release "${bump_type:-patch}" "${@:3}"
		fi
		;;
	"github-release")
		local version
		version=$(get_current_version)
		_publish_github_release "$version"
		;;
	"post-release")
		local version
		local hotfix_flag=0
		version=$(get_current_version)
		[[ "${2:-}" == "--hotfix" ]] && hotfix_flag=1
		run_post_publication_gates "$version" "$hotfix_flag"
		;;
	"validate")
		local version
		version=$(get_current_version)
		validate_version_consistency "$version"
		;;
	"preflight")
		if [[ -z "$bump_type" ]]; then
			print_error "Bump type required. Usage: $0 preflight [major|minor|patch]"
			exit 1
		fi
		run_preflight_checks "$bump_type"
		;;
	"changelog-check")
		local version
		version=$(get_current_version)
		print_info "Checking CHANGELOG.md for version $version..."
		if check_changelog_version "$version"; then
			print_success "CHANGELOG.md is in sync with VERSION"
		else
			print_error "CHANGELOG.md is out of sync with VERSION ($version)"
			print_info "Run: $0 changelog-preview to see suggested entries"
			exit 1
		fi
		;;
	"changelog-preview")
		print_info "Generating changelog preview from commits..."
		echo ""
		generate_changelog_preview
		;;
	"auto-mark-tasks")
		print_info "Auto-marking tasks complete from commit messages..."
		auto_mark_tasks_complete
		;;
	"list-task-ids")
		print_info "Task IDs found in commits since last release:"
		extract_task_ids_from_commits
		;;
	*)
		_main_usage
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
