#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001,SC2034,SC2181,SC2317
# =============================================================================
# Version Manager — Release & Tag Functions
# =============================================================================
# Git tagging, GitHub release creation, hotfix signalling, and post-release
# functions extracted from version-manager.sh to reduce file size.
#
# Covers:
#   - create_git_tag (with GH#20073 bump-commit verification guard)
#   - create_github_release
#   - _verify_maintainer_identity
#   - _create_hotfix_tag
#   - run_post_release_agent_sync
#   - generate_release_notes
#
# Usage: source "${SCRIPT_DIR}/version-manager-release.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - version-manager-git.sh (_verify_bump_commit_at_ref)
#   - REPO_ROOT must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_VERSION_MANAGER_RELEASE_LOADED:-}" ]] && return 0
_VERSION_MANAGER_RELEASE_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

_version_manager_repo_slug() {
	local remote_url=""
	remote_url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")
	printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||'
	return 0
}

_verify_github_release_provenance() {
	local version="$1"
	local tag_name="v${version}"
	local slug=""

	slug=$(_version_manager_repo_slug)
	[[ -n "$slug" ]] || {
		print_error "Cannot verify GitHub release provenance: cannot determine repo slug from origin"
		return 1
	}
	if ! (
		cd "$REPO_ROOT" || exit 1
		bash "${SCRIPT_DIR}/release-provenance-helper.sh" verify \
			--tag "$tag_name" --repo "$slug"
	); then
		print_error "GitHub release provenance verification failed for ${tag_name}"
		return 1
	fi
	return 0
}

_github_release_rest_view() {
	local slug="$1"
	local tag_name="$2"

	[[ -n "$slug" ]] || return 1
	gh api "repos/${slug}/releases/tags/${tag_name}" >/dev/null 2>&1
	return $?
}

_github_release_rest_published() {
	local slug="$1"
	local tag_name="$2"
	local release_json=""

	[[ -n "$slug" && "$tag_name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	release_json=$(gh api "repos/${slug}/releases/tags/${tag_name}" 2>/dev/null) || return 1
	jq -e --arg tag "$tag_name" '
		.tag_name == $tag
		and .draft == false
		and ((.published_at // "") | length > 0)
	' <<<"$release_json" >/dev/null
	return $?
}

_github_release_rest_create() {
	local slug="$1"
	local tag_name="$2"
	local release_notes="$3"

	[[ -n "$slug" ]] || return 1
	gh api "repos/${slug}/releases" \
		--method POST \
		-f "tag_name=${tag_name}" \
		-f "name=${tag_name} - AI DevOps Framework" \
		-f "body=${release_notes}" \
		-F latest=true >/dev/null
	return $?
}

_github_release_recover_with_rest() {
	local tag_name="$1"
	local release_notes="$2"
	local context="$3"
	local slug=""
	slug=$(_version_manager_repo_slug)

	if [[ -z "$slug" ]]; then
		print_error "Cannot recover GitHub release via REST: cannot determine repo slug from origin"
		return 1
	fi

	print_warning "GitHub CLI release ${context} failed; checking REST release endpoint for $tag_name"
	if _github_release_rest_view "$slug" "$tag_name"; then
		print_warning "Partial release recovered: tag $tag_name was pushed and GitHub release already exists via REST"
		print_info "REST endpoint verified: repos/${slug}/releases/tags/${tag_name}"
		return 0
	fi

	print_warning "Partial release state: tag $tag_name may be pushed but release is not visible via REST; creating release via REST"
	if _github_release_rest_create "$slug" "$tag_name" "$release_notes"; then
		print_success "Created GitHub release via REST fallback: $tag_name"
		return 0
	fi

	if _github_release_rest_view "$slug" "$tag_name"; then
		print_warning "REST release create returned non-zero, but release is now visible; treating as recovered"
		return 0
	fi

	print_error "Failed to recover GitHub release $tag_name via REST after $context failure"
	print_info "Manual recovery: gh api repos/${slug}/releases/tags/${tag_name} || gh api repos/${slug}/releases --method POST ..."
	return 1
}

_release_lookup_exact_workflow_run() {
	local slug="$1"
	local workflow_file="$2"
	local event_name="$3"
	local expected_commit="$4"
	local expected_title="${5:-}"
	local runs_json=""
	local run_json=""

	runs_json=$(gh api --method GET \
		"repos/${slug}/actions/workflows/${workflow_file}/runs" \
		-f "event=${event_name}" -F per_page=20 2>/dev/null) || return 1
	[[ -n "$runs_json" ]] || return 1
	jq -e 'type == "object" and (.workflow_runs | type == "array")' \
		<<<"$runs_json" >/dev/null || return 1
	run_json=$(jq -c --arg sha "$expected_commit" --arg event "$event_name" \
		--arg title "$expected_title" '
		[.workflow_runs[]?
			| select(.head_sha == $sha and .event == $event)
			| select($title == "" or (.display_title // "") == $title)]
		| sort_by(.created_at // "") | last // empty
	' <<<"$runs_json") || return 1
	[[ -n "$run_json" && "$run_json" != "null" ]] || return 3
	printf '%s\n' "$run_json"
	return 0
}

_release_find_exact_workflow_run() {
	local slug="$1"
	local workflow_file="$2"
	local event_name="$3"
	local expected_commit="$4"
	local deadline="$5"
	local poll_seconds="$6"
	local expected_title="${7:-}"
	local run_json=""
	local now=""

	while true; do
		now=$(date +%s) || return 1
		if [[ "$now" -ge "$deadline" ]]; then
			print_error "Timed out waiting for ${workflow_file} to start at ${expected_commit}" >&2
			return 1
		fi
		if run_json=$(_release_lookup_exact_workflow_run "$slug" "$workflow_file" \
			"$event_name" "$expected_commit" "$expected_title"); then
			printf '%s\n' "$run_json"
			return 0
		fi
		sleep "$poll_seconds"
	done
}

_wait_for_protected_github_release() {
	local version="$1"
	local tag_name="v${version}"
	local timeout_seconds="${AIDEVOPS_RELEASE_WORKFLOW_DISCOVERY_TIMEOUT_SECONDS:-120}"
	local poll_seconds="${AIDEVOPS_RELEASE_WORKFLOW_POLL_SECONDS:-5}"
	local slug=""
	local tag_commit=""
	local started_at=""
	local deadline=""
	local run_json=""
	local run_status=""
	local run_conclusion=""
	local run_url=""

	if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ && "$poll_seconds" =~ ^[1-9][0-9]*$ ]]; then
		print_error "Release workflow discovery settings must be positive integers"
		return 1
	fi
	slug=$(_version_manager_repo_slug)
	[[ -n "$slug" ]] || return 1
	tag_commit=$(git -C "$REPO_ROOT" rev-parse "refs/tags/${tag_name}^{commit}" 2>/dev/null) || return 1
	started_at=$(date +%s) || return 1
	deadline=$((started_at + timeout_seconds))
	print_info "Confirming durable publication workflow for ${tag_name}"
	if ! run_json=$(_release_find_exact_workflow_run "$slug" "publish-packages.yml" "push" \
		"$tag_commit" "$deadline" "$poll_seconds"); then
		print_warning "Release tag ${tag_name} is durable; publication run is not visible yet"
		return 8
	fi
	run_status=$(jq -r '.status // ""' <<<"$run_json") || return 1
	run_conclusion=$(jq -r '.conclusion // ""' <<<"$run_json") || return 1
	run_url=$(jq -r '.html_url // ""' <<<"$run_json") || return 1
	[[ -z "$run_url" ]] || print_info "Publication progress: ${run_url}"
	if [[ "$run_status" != "completed" ]]; then
		print_success "release:queued tag=${tag_name}"
		return 8
	fi
	if [[ "$run_conclusion" != "success" ]]; then
		print_error "Publication workflow concluded ${run_conclusion:-unknown}"
		return 1
	fi
	_verify_github_release_provenance "$version" || return 1
	if ! _github_release_rest_published "$slug" "$tag_name"; then
		print_error "Publication workflow succeeded but GitHub release ${tag_name} is unavailable"
		return 1
	fi
	return 0
}

_publish_github_release() {
	local version="$1"
	if release_source_pr_required; then
		_wait_for_protected_github_release "$version"
		return $?
	fi
	create_github_release "$version"
	return $?
}

_release_contains_efficiency_change() {
	local previous_tag=""
	local range="HEAD"
	local subject=""
	local performance_pattern='^(GH#[0-9]+:[[:space:]]+)?perf(\([^)]*\))?!?:[[:space:]]'

	previous_tag=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 \
		--match 'v[0-9]*.[0-9]*.[0-9]*' HEAD^ 2>/dev/null || true)
	if [[ -n "$previous_tag" ]]; then
		range="${previous_tag}..HEAD"
	fi
	while IFS= read -r subject; do
		if [[ "$subject" =~ $performance_pattern ]]; then
			return 0
		fi
	done < <(git -C "$REPO_ROOT" log --format='%s' "$range" 2>/dev/null)
	return 1
}

_release_tag_message() {
	local version="$1"
	local source_pr="${VERSION_MANAGER_SOURCE_PR:-}"
	local source_merge="${VERSION_MANAGER_SOURCE_MERGE_SHA:-}"
	local aggregated_sources="${VERSION_MANAGER_AGGREGATED_SOURCES:-}"
	local aggregated_source=""

	if release_source_pr_required; then
		[[ "$source_pr" =~ ^[0-9]+$ ]] || {
			print_error "Release tag requires verified source-PR provenance"
			return 1
		}
		[[ "$source_merge" =~ ^[0-9a-f]{40}$ ]] || {
			print_error "Release tag requires a verified source merge SHA"
			return 1
		}
	fi

	printf 'Release v%s - AI DevOps Framework\n\n' "$version"
	printf 'Aidevops-Version: %s\n' "$version"
	if _release_contains_efficiency_change; then
		printf 'Aidevops-Efficiency-Change: true\n'
	fi
	if [[ -n "$source_pr" && -n "$source_merge" ]]; then
		printf 'Aidevops-Source-PR: %s\n' "$source_pr"
		printf 'Aidevops-Source-Merge: %s\n' "$source_merge"
		while IFS= read -r aggregated_source; do
			[[ -n "$aggregated_source" ]] || continue
			printf 'Aidevops-Aggregated-Source: %s\n' "$aggregated_source"
		done <<<"$aggregated_sources"
	fi
	return 0
}

# Function to create git tag
create_git_tag() {
	local version="$1"
	local tag_name="v$version"
	local tag_message=""

	print_info "Creating git tag: $tag_name"

	cd "$REPO_ROOT" || exit 1

	# Guard: abort if tag already exists locally or on remote
	if git show-ref --tags "$tag_name" &>/dev/null; then
		local existing_sha
		existing_sha=$(git rev-parse "$tag_name^{}" 2>/dev/null || git rev-parse "$tag_name" 2>/dev/null)
		print_error "Tag $tag_name already exists locally (points to $existing_sha)"
		print_info "This indicates a partial or concurrent release. Diagnose with:"
		print_info "  git show $tag_name"
		print_info "  gh release view $tag_name"
		print_info "Never delete or recreate a signed release tag. Reconcile its source PR:"
		print_info "  aidevops release reconcile ${VERSION_MANAGER_SOURCE_PR:-<SOURCE_PR>}"
		return 1
	fi

	# Also check remote tags to catch tags pushed by a concurrent run
	# Note: --exit-code returns 2 when ref not found; capture exit code to
	# prevent set -e from aborting the script on a "not found" result.
	local remote_tag_exit=0
	git ls-remote -q --exit-code --tags origin "refs/tags/$tag_name" >/dev/null 2>&1 || remote_tag_exit=$?
	if [ $remote_tag_exit -eq 0 ]; then
		print_error "Tag $tag_name already exists on remote origin"
		print_info "A concurrent release run may have pushed this tag. Diagnose with:"
		print_info "  git fetch --tags && git show $tag_name"
		print_info "  gh release view $tag_name"
		return 1
	fi

	# t2437/GH#20073: Final guard before `git tag` — HEAD must be the bump
	# commit for $version. This catches any residual case where an upstream
	# caller skipped its own post-commit/post-rebase verification, or called
	# create_git_tag directly (e.g., standalone `version-manager.sh tag`).
	# Opt-out via AIDEVOPS_VM_SKIP_BUMP_VERIFY=1 for maintainer recovery flows
	# that intentionally tag non-bump commits (e.g., annotated release sync
	# tags). Default is strict.
	if [[ "${AIDEVOPS_VM_SKIP_BUMP_VERIFY:-0}" == "1" ]]; then
		print_info "AIDEVOPS_VM_SKIP_BUMP_VERIFY=1 — bypassing bump-commit verification for v$version (GH#20146 audit)"
	fi
	if [[ "${AIDEVOPS_VM_SKIP_BUMP_VERIFY:-0}" != "1" ]]; then
		if ! _verify_bump_commit_at_ref HEAD "$version"; then
			print_error "Aborting tag creation: HEAD is not the bump commit for v$version"
			print_info "The tag would land on the wrong commit (this is exactly the"
			print_info "GH#20073 foot-gun). Inspect and recover:"
			print_info "  git log -1 --format='%H %s'   # current HEAD"
			print_info "  git log --oneline -5          # recent history"
			print_info "Override only if you truly need to tag a non-bump commit:"
			print_info "  AIDEVOPS_VM_SKIP_BUMP_VERIFY=1 $0 tag"
			return 1
		fi
	fi

	tag_message=$(_release_tag_message "$version") || return 1
	if git tag -s "$tag_name" -m "$tag_message"; then
		print_success "Created git tag: $tag_name"
		return 0
	else
		print_error "Failed to create git tag"
		return 1
	fi
	return 0
}

# Function to create GitHub release
create_github_release() {
	local version="$1"
	local tag_name="v$version"

	print_info "Creating GitHub release: $tag_name"
	if ! _verify_github_release_provenance "$version"; then
		print_error "Refusing to create or reconcile an unverified GitHub release"
		return 1
	fi

	# Try GitHub CLI first
	if command -v gh &>/dev/null && gh auth status &>/dev/null; then
		print_info "Using GitHub CLI for release creation"

		# Generate release notes before any recovery path so REST creation can
		# finish a partial release without rerunning the version bump.
		local release_notes
		release_notes=$(generate_release_notes "$version")

		# Guard: check if GitHub release already exists for this tag. When GraphQL
		# quota is exhausted, `gh release view` can fail while REST remains usable;
		# recover through REST instead of returning failure after tag/push success.
		local view_exit=0
		gh release view "$tag_name" &>/dev/null || view_exit=$?
		if [[ "$view_exit" -eq 0 ]]; then
			print_warning "GitHub release $tag_name already exists — skipping creation"
			print_info "To view the existing release: gh release view $tag_name"
			return 0
		fi
		local rest_slug=""
		rest_slug=$(_version_manager_repo_slug)
		if _github_release_rest_view "$rest_slug" "$tag_name"; then
			print_warning "GitHub release view failed, but REST confirms $tag_name already exists — skipping creation"
			print_info "REST endpoint verified: repos/${rest_slug}/releases/tags/${tag_name}"
			return 0
		fi

		# Create GitHub release
		if gh release create "$tag_name" \
			--title "$tag_name - AI DevOps Framework" \
			--notes "$release_notes" \
			--latest; then
			print_success "Created GitHub release: $tag_name"
			return 0
		else
			if _github_release_recover_with_rest "$tag_name" "$release_notes" "create"; then
				return 0
			fi
			print_error "Failed to create GitHub release with GitHub CLI or REST fallback"
			return 1
		fi
	else
		# GitHub CLI not available
		if release_source_pr_required; then
			print_error "GitHub release publication cannot be verified without authenticated gh CLI access"
			return 1
		fi
		print_warning "GitHub release creation skipped - GitHub CLI not available"
		print_info "To enable GitHub releases:"
		print_info "1. Install GitHub CLI: brew install gh (macOS)"
		print_info "2. Authenticate: gh auth login"
		return 0
	fi
	return 0
}

# Verify current user is a maintainer (repo OWNER or MEMBER) for hotfix releases.
# Returns 0 if the user is authorized, 1 otherwise.
_verify_maintainer_identity() {
	if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
		print_error "hotfix release requires GitHub CLI authentication (gh auth login)"
		return 1
	fi

	local remote_url slug current_user user_association
	remote_url=$(git remote get-url origin 2>/dev/null || echo "")
	slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')

	if [[ -z "$slug" ]]; then
		print_error "Cannot determine repo slug from origin remote"
		return 1
	fi

	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$current_user" ]]; then
		print_error "Cannot determine current GitHub user"
		return 1
	fi

	local repo_owner="${slug%%/*}"
	if [[ "$current_user" == "$repo_owner" ]]; then
		return 0
	fi

	# Check repo collaboration level — OWNER and MEMBER can push hotfixes
	# #aidevops:trust-boundary — hotfix releases require confirmed write+ access;
	# permission lookup failures abort as failures, not as confirmed no-access.
	if ! _gh_collaborator_permission_lookup "$slug" "$current_user" user_association; then
		print_error "hotfix release requires maintainer identity (permission check failed for ${current_user}, HTTP ${AIDEVOPS_GH_COLLAB_PERMISSION_HTTP:-unknown})"
		return 1
	fi

	case "$user_association" in
	admin | maintain | write)
		return 0
		;;
	*)
		print_error "hotfix release requires maintainer identity (current: ${current_user}, role: ${user_association:-unknown})"
		return 1
		;;
	esac
}

# Create a hotfix signal tag alongside the normal release tag.
# The hotfix tag triggers accelerated polling on remote runners.
# Arguments: version (e.g. "3.8.79")
_create_hotfix_tag() {
	local version="$1"
	local hotfix_tag="hotfix-v${version}"
	local repo_root="${REPO_ROOT:-}"

	if [[ -z "$repo_root" ]]; then
		print_error "Cannot create hotfix tag: REPO_ROOT is not set"
		return 1
	fi
	cd "$repo_root" || return 1

	local remote_tag_exit=0
	git ls-remote -q --exit-code --tags origin "refs/tags/$hotfix_tag" >/dev/null 2>&1 || remote_tag_exit=$?
	if [ $remote_tag_exit -eq 0 ]; then
		print_warning "Hotfix tag $hotfix_tag already exists on remote — propagation complete"
		return 0
	fi

	if git show-ref --tags "$hotfix_tag" &>/dev/null; then
		print_warning "Hotfix tag $hotfix_tag exists locally but not remotely — retrying propagation"
	else
		if git tag -a "$hotfix_tag" -m "Hotfix signal: v${version} — triggers immediate runner propagation"; then
			print_success "Created hotfix signal tag: $hotfix_tag"
		else
			print_error "Failed to create hotfix signal tag"
			return 1
		fi
	fi

	# Push the hotfix tag (the release tag is pushed by push_changes;
	# the hotfix tag needs a separate push since --tags only pushes
	# tags that point to reachable commits, which this one does).
	if git push origin "$hotfix_tag" 2>/dev/null; then
		print_success "Pushed hotfix signal tag: $hotfix_tag"
	else
		print_error "Failed to push hotfix signal tag after GitHub release publication"
		print_info "Recovery: rerun '$0 post-release --hotfix' to retry the idempotent hotfix propagation and local deployment gates"
		return 1
	fi
	return 0
}

validate_release_deployment_readiness() {
	local sync_repo_root="${AIDEVOPS_SYNC_REPO_ROOT:-$REPO_ROOT}"
	local remote_url
	remote_url=$(git -C "$sync_repo_root" remote get-url origin 2>/dev/null || echo "")
	if [[ "$remote_url" != *"marcusquinn/aidevops"* ]]; then
		return 0
	fi

	if [[ -z "${HOME:-}" || "$HOME" != /* ]]; then
		print_error "Release deployment cannot resolve the stable agents target: HOME must be a non-empty absolute path"
		return 1
	fi

	local deploy_script="${AIDEVOPS_SYNC_DEPLOY_SCRIPT:-$sync_repo_root/.agents/scripts/deploy-agents-on-merge.sh}"
	if [[ ! -f "$deploy_script" || ! -r "$deploy_script" ]]; then
		print_error "Release deployment helper is unavailable: $deploy_script"
		return 1
	fi
	if [[ ! -f "$sync_repo_root/setup.sh" || ! -r "$sync_repo_root/setup.sh" ]]; then
		print_error "Release setup helper is unavailable: $sync_repo_root/setup.sh"
		return 1
	fi
	return 0
}

_AIDEVOPS_RELEASE_ACTIVE_PRESERVATION_SHA=""

_verify_active_release_preservation_merge() {
	local sync_repo_root="$1"
	local release_sha="$2"
	local active_link="$3"
	local stamp_file="$4"
	local active_manifest=""
	local manifest_status=""
	local manifest_sha=""
	local active_sha=""
	local release_tree=""
	local active_tree=""
	local verify_base=""
	local verify_root=""
	local verify_repo=""
	local verify_exit=0

	_AIDEVOPS_RELEASE_ACTIVE_PRESERVATION_SHA=""
	[[ -e "$active_link" || -L "$active_link" ]] || return 0
	_runtime_bundle_verify_active_link "$active_link" || return 1
	active_manifest="$_AIDEVOPS_RUNTIME_VERIFY_ACTIVE_ROOT/.bundle-manifest"
	manifest_status=$(_runtime_bundle_verify_manifest_value "$active_manifest" status 2>/dev/null) || manifest_status=""
	manifest_sha=$(_runtime_bundle_verify_manifest_value "$active_manifest" git_sha 2>/dev/null) || manifest_sha=""
	if [[ "$manifest_status" != "validated" ]]; then
		print_error "Post-release deployment gate rejected the active bundle: manifest status is ${manifest_status:-missing}, expected validated"
		return 1
	fi
	active_sha=$(git -C "$sync_repo_root" rev-parse "${manifest_sha}^{commit}" 2>/dev/null) || {
		print_error "Post-release deployment gate rejected the active bundle: manifest git SHA is missing or invalid"
		return 1
	}
	if [[ "$manifest_sha" != "$active_sha" ]]; then
		print_error "Post-release deployment gate rejected the active bundle: manifest git SHA is not the full resolved commit"
		return 1
	fi
	[[ "$active_sha" != "$release_sha" ]] || return 0
	if git -C "$sync_repo_root" merge-base --is-ancestor "$active_sha" "$release_sha" 2>/dev/null; then
		return 0
	fi

	if ! git -C "$sync_repo_root" merge-base --is-ancestor "$release_sha" "$active_sha" 2>/dev/null; then
		print_error "Post-release deployment gate rejected active source ${active_sha:0:12}: it is not a descendant of release ${release_sha:0:12}"
		return 1
	fi
	release_tree=$(git -C "$sync_repo_root" rev-parse "${release_sha}^{tree}" 2>/dev/null) || {
		print_error "Post-release deployment gate cannot resolve the release tree"
		return 1
	}
	active_tree=$(git -C "$sync_repo_root" rev-parse "${active_sha}^{tree}" 2>/dev/null) || {
		print_error "Post-release deployment gate cannot resolve the active bundle tree"
		return 1
	}
	if [[ "$release_tree" != "$active_tree" ]]; then
		print_error "Post-release deployment gate rejected active descendant ${active_sha:0:12}: its tree differs from release ${release_sha:0:12}"
		return 1
	fi

	verify_base="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$verify_base" || {
		print_error "Post-release deployment gate cannot create the active-source verification workspace"
		return 1
	}
	verify_root=$(mktemp -d "$verify_base/release-active-verify.XXXXXX") || {
		print_error "Post-release deployment gate cannot allocate the active-source verification workspace"
		return 1
	}
	verify_repo="$verify_root/repo"
	if ! git clone --quiet --shared --no-checkout "$sync_repo_root" "$verify_repo" 2>/dev/null ||
		! git -C "$verify_repo" checkout --quiet --detach "$active_sha" 2>/dev/null; then
		print_error "Post-release deployment gate cannot materialize active source ${active_sha:0:12} for exact verification"
		verify_exit=1
	elif ! verify_aidevops_runtime_bundle_convergence \
		"$verify_repo" \
		"$active_sha" \
		"$active_link" \
		"$stamp_file"; then
		verify_exit=1
	fi
	if ! rm -rf "$verify_root"; then
		print_error "Post-release deployment gate could not remove the active-source verification workspace"
		return 1
	fi
	[[ "$verify_exit" -eq 0 ]] || return 1

	_AIDEVOPS_RELEASE_ACTIVE_PRESERVATION_SHA="$active_sha"
	return 2
}

run_post_release_agent_sync() {
	local sync_repo_root="${AIDEVOPS_SYNC_REPO_ROOT:-$REPO_ROOT}"
	local remote_url
	local release_sha=""
	local active_preservation_exit=0
	remote_url=$(git -C "$sync_repo_root" remote get-url origin 2>/dev/null || echo "")

	if [[ "$remote_url" != *"marcusquinn/aidevops"* ]]; then
		return 0
	fi

	local deploy_script="${AIDEVOPS_SYNC_DEPLOY_SCRIPT:-$sync_repo_root/.agents/scripts/deploy-agents-on-merge.sh}"
	local deployment_scope="${AIDEVOPS_RELEASE_DEPLOY_SCOPE:-incremental}"
	local -a deploy_args=(--repo "$sync_repo_root" --quiet)
	case "$deployment_scope" in
	incremental) ;;
	full) deploy_args+=(--full) ;;
	*)
		print_error "Invalid release deployment scope: $deployment_scope (expected incremental or full)"
		return 1
		;;
	esac
	if [[ ! -f "$deploy_script" ]]; then
		print_error "Post-release deployment gate cannot run: deploy script not found at $deploy_script"
		return 1
	fi
	validate_release_deployment_readiness || return 1
	release_sha=$(git -C "$sync_repo_root" rev-parse HEAD 2>/dev/null) || {
		print_error "Post-release deployment gate cannot resolve the release checkout commit"
		return 1
	}
	_verify_active_release_preservation_merge \
		"$sync_repo_root" \
		"$release_sha" \
		"$HOME/.aidevops/agents" \
		"$HOME/.aidevops/.deployed-sha" || active_preservation_exit=$?
	if [[ "$active_preservation_exit" -eq 2 ]]; then
		print_success "Post-release aidevops runtime already contains release ${release_sha:0:12} through validated preservation merge ${_AIDEVOPS_RELEASE_ACTIVE_PRESERVATION_SHA:0:12} (verified no-op)"
		return 0
	fi
	if [[ "$active_preservation_exit" -ne 0 ]]; then
		print_error "Post-release deployment gate could not verify the active runtime before deployment"
		return 1
	fi
	deploy_args+=(--expected-sha "$release_sha")

	print_info "Running post-release aidevops agent sync..."
	local sync_output=""
	local sync_exit=0
	sync_output=$(env -u AIDEVOPS_AGENTS_DIR -u AGENTS_DIR \
		AIDEVOPS_DEPLOY_TARGET="$HOME/.aidevops/agents" \
		bash "$deploy_script" "${deploy_args[@]}" 2>&1) || sync_exit=$?

	if [[ "$sync_exit" -ne 0 && "$sync_exit" -ne 2 ]]; then
		print_error "Post-release aidevops deployment or CLI convergence failed: $sync_output"
		return 1
	fi
	if ! verify_aidevops_runtime_bundle_convergence \
		"$sync_repo_root" \
		"$release_sha" \
		"$HOME/.aidevops/agents" \
		"$HOME/.aidevops/.deployed-sha"; then
		print_error "Post-release deployment helper exited successfully, but runtime bundle provenance did not converge"
		return 1
	fi

	if [[ "$sync_exit" -eq 2 ]]; then
		print_success "Post-release aidevops runtime was already converged to ${release_sha:0:12} (verified no-op)"
	else
		print_success "Post-release aidevops deployment and CLI convergence completed"
	fi
	return 0
}

run_post_publication_gates() {
	local version="$1"
	local hotfix_flag="$2"
	local hotfix_exit=0
	local deployment_exit=0

	# Publication is already durable at this point. Hotfix propagation must run
	# before machine-local convergence so a local PATH problem cannot prevent
	# remote runners receiving the release signal.
	if [[ "$hotfix_flag" -eq 1 ]]; then
		_create_hotfix_tag "$version" || hotfix_exit=$?
	fi
	run_post_release_agent_sync || deployment_exit=$?

	if [[ "$hotfix_exit" -ne 0 || "$deployment_exit" -ne 0 ]]; then
		print_error "PARTIAL RELEASE SUCCESS: GitHub release v$version remains published; post-publication gates failed"
		if [[ "$hotfix_flag" -eq 1 ]]; then
			if [[ "$hotfix_exit" -eq 0 ]]; then
				print_info "  Hotfix propagation: completed before local deployment"
			else
				print_error "  Hotfix propagation: failed (exit $hotfix_exit)"
			fi
		fi
		if [[ "$deployment_exit" -ne 0 ]]; then
			print_error "  Local deployment/convergence: failed (exit $deployment_exit)"
		fi
		print_info "  Remote tag and GitHub release are retained; repair locally and rerun setup"
		return 1
	fi

	return 0
}

# Function to generate release notes
generate_release_notes() {
	local version="$1"
	# Parse version components (reserved for version-specific logic)
	# shellcheck disable=SC2034
	local major minor patch
	IFS='.' read -r major minor patch <<<"$version"

	cat <<EOF
## AI DevOps Framework v$version

### Installation

\`\`\`bash
# npm (recommended)
npm install -g aidevops && aidevops update

# Homebrew
brew install marcusquinn/tap/aidevops && aidevops update

# curl
bash <(curl -fsSL https://aidevops.sh/install)
\`\`\`

### What's New

See [CHANGELOG.md](CHANGELOG.md) for detailed changes.

EOF
	if _release_contains_efficiency_change; then
		cat <<'EOF'
### Efficiency Release

This release contains a conventional `perf:` change. Compare routing, token,
cost, and verification outcomes by `aidevops_version` before changing defaults.

EOF
	fi
	cat <<EOF

### Quick Start

\`\`\`bash
# Check installation
aidevops status

# Initialize in a project
aidevops init

# Update framework + projects
aidevops update

# List registered projects
aidevops repos
\`\`\`

### Documentation

- **[Setup Guide](README.md)**: Complete framework setup
- **[User Guide](.agents/AGENTS.md)**: AI assistant integration
- **[API Integrations](.agents/aidevops/api-integrations.md)**: Service APIs

### Links

- **Website**: https://aidevops.sh
- **Repository**: https://github.com/marcusquinn/aidevops
- **Issues**: https://github.com/marcusquinn/aidevops/issues

---

**Full Changelog**: https://github.com/marcusquinn/aidevops/compare/v1.0.0...v$version
EOF
	return 0
}
