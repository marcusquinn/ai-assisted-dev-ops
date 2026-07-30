#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Skill Update PR Library — PR Generation Helpers and Single-Skill PR Pipeline
# =============================================================================
# PR template helpers and single-skill PR pipeline extracted from
# skill-update-helper.sh.
#
# Covers:
#   - Upstream changelog fetch
#   - Diff summary generation
#   - Conventional commit message and PR body generation (GitHub and URL skills)
#   - Worktree creation helper
#   - Push-and-create-PR helper
#   - cmd_pr_single: end-to-end single-skill PR pipeline
#   - _cleanup_worktree: failure cleanup
#
# Usage: source "${SCRIPT_DIR}/skill-update-pr-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - skill-update-core-lib.sh (parse_github_url, update_upstream_hash,
#     update_cache_headers, log_* functions)
#   - Global vars from skill-update-helper.sh orchestrator (SKILL_SOURCES,
#     ADD_SKILL_HELPER, NON_INTERACTIVE, QUIET, DRY_RUN, WORKTREE_HELPER,
#     _WTAR_SU_CALLER, _WTAR_SKIPPED, _WTAR_REMOVED)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SKILL_UPDATE_PR_LIB_LOADED:-}" ]] && return 0
_SKILL_UPDATE_PR_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (may already be set by orchestrator)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# PR Template Helpers — conventional commit, changelog, diff summary (t1082.4)
# =============================================================================

# Fetch upstream commits between two SHAs from GitHub API.
# Arguments:
#   $1 - owner/repo (e.g. "dmmulroy/cloudflare-skill")
#   $2 - base SHA (previous import commit, may be empty)
#   $3 - head SHA (latest upstream commit)
# Outputs: markdown list of commits, one per line
# Returns: 0 always (empty output on failure)
get_upstream_changelog() {
	local owner_repo="$1"
	local base_sha="$2"
	local head_sha="$3"

	if [[ -z "$owner_repo" || -z "$head_sha" ]]; then
		return 0
	fi

	local api_url
	local response

	# If we have a base SHA, use the compare endpoint for precise range
	if [[ -n "$base_sha" ]]; then
		api_url="https://api.github.com/repos/${owner_repo}/compare/${base_sha}...${head_sha}"
		response=$(curl -s --connect-timeout 10 --max-time 30 \
			-H "Accept: application/vnd.github.v3+json" "$api_url" 2>/dev/null)

		if [[ -n "$response" ]]; then
			local commits_json
			commits_json=$(echo "$response" | jq -r '.commits // empty' 2>/dev/null)
			if [[ -n "$commits_json" && "$commits_json" != "null" ]]; then
				echo "$response" | jq -r '
					.commits[]? |
					"- [`\(.sha[0:7])`](\(.html_url)) \(.commit.message | split("\n")[0]) — \(.commit.author.name)"
				' 2>/dev/null || true
				return 0
			fi
		fi
	fi

	# Fallback: list recent commits on the repo (up to 20)
	api_url="https://api.github.com/repos/${owner_repo}/commits?per_page=20&sha=${head_sha}"
	response=$(curl -s --connect-timeout 10 --max-time 30 \
		-H "Accept: application/vnd.github.v3+json" "$api_url" 2>/dev/null)

	if [[ -n "$response" ]]; then
		echo "$response" | jq -r '
			.[]? |
			"- [`\(.sha[0:7])`](\(.html_url)) \(.commit.message | split("\n")[0]) — \(.commit.author.name)"
		' 2>/dev/null | head -20 || true
	fi

	return 0
}

# Summarise file-level changes in the worktree after re-import.
# Arguments:
#   $1 - worktree path
#   $2 - default branch (base for diff)
# Outputs: markdown summary of added/modified/deleted files
# Returns: 0 always
get_skill_diff_summary() {
	local worktree_path="$1"
	local default_branch="${2:-main}"

	if [[ ! -d "$worktree_path" ]]; then
		return 0
	fi

	local diff_stat
	diff_stat=$(git -C "$worktree_path" diff --stat "${default_branch}..HEAD" 2>/dev/null || true)

	if [[ -z "$diff_stat" ]]; then
		# Try staged diff if no committed diff yet
		diff_stat=$(git -C "$worktree_path" diff --cached --stat 2>/dev/null || true)
	fi

	if [[ -z "$diff_stat" ]]; then
		echo "_No file changes detected._"
		return 0
	fi

	# Format as code block for readability
	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
	printf '```\n%s\n```\n' "$diff_stat"
	return 0
}

# Generate a conventional commit message for a skill update.
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current (previous) commit SHA (may be empty)
#   $4 - latest commit SHA
#   $5 - changelog lines (multi-line string, may be empty)
# Outputs: commit message string
# Returns: 0 always
generate_skill_commit_msg() {
	local skill_name="$1"
	local upstream_url="$2"
	local current_commit="$3"
	local latest_commit="$4"
	local changelog="$5"

	local timestamp
	timestamp=$(date -u +"%Y-%m-%d")

	# Conventional commit: chore(skill/<name>): update from upstream
	local subject="chore(skill/${skill_name}): update from upstream (${latest_commit:0:7})"

	local prev_short
	prev_short="${current_commit:0:12}"
	[[ -z "$prev_short" ]] && prev_short="(none)"

	local body
	body="Upstream: ${upstream_url}
Previous: ${prev_short}
Latest:   ${latest_commit:0:12}
Updated:  ${timestamp}"

	# Append changelog if available (trimmed to avoid huge commits)
	if [[ -n "$changelog" ]]; then
		local changelog_lines
		changelog_lines=$(echo "$changelog" | wc -l | tr -d ' ')
		if [[ "$changelog_lines" -gt 15 ]]; then
			# Truncate to first 15 commits with a note
			local truncated
			truncated=$(echo "$changelog" | head -15)
			body="${body}

Upstream changes (first 15 of ${changelog_lines}):
${truncated}
... and $((changelog_lines - 15)) more commits"
		elif [[ "$changelog_lines" -gt 0 ]]; then
			body="${body}

Upstream changes:
${changelog}"
		fi
	fi

	printf '%s\n\n%s\n' "$subject" "$body"
	return 0
}

# Generate the full PR body for a skill update.
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current (previous) commit SHA (may be empty)
#   $4 - latest commit SHA
#   $5 - changelog lines (multi-line string, may be empty)
#   $6 - diff summary (multi-line string, may be empty)
# Outputs: PR body markdown
# Returns: 0 always
generate_skill_pr_body() {
	local skill_name="$1"
	local upstream_url="$2"
	local current_commit="$3"
	local latest_commit="$4"
	local changelog="$5"
	local diff_summary="$6"

	local prev_display="${current_commit:0:12}"
	[[ -z "$prev_display" ]] && prev_display="_(none — first import)_"

	cat <<PREOF
## Skill Update: \`${skill_name}\`

Automated skill update from upstream source.

| Field | Value |
|-------|-------|
| Skill | \`${skill_name}\` |
| Source | ${upstream_url} |
| Previous commit | \`${prev_display}\` |
| Latest commit | \`${latest_commit:0:12}\` |

### Upstream changelog

PREOF

	if [[ -n "$changelog" ]]; then
		echo "$changelog"
	else
		echo "_Could not fetch upstream changelog (API unavailable or no base commit)._"
	fi

	cat <<PREOF

### Diff summary

PREOF

	if [[ -n "$diff_summary" ]]; then
		echo "$diff_summary"
	else
		echo "_No diff available._"
	fi

	cat <<PREOF

### Review checklist

- [ ] Verify the updated skill content is correct
- [ ] Check for breaking changes in the skill format
- [ ] Confirm security scan passes (re-run if needed)

---
*Generated by \`skill-update-helper.sh pr\` (t1082.4)*
PREOF

	return 0
}

# Generate a conventional commit message for a URL-sourced skill update (t1415.2).
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - previous hash (may be empty)
#   $4 - new hash
# Outputs: commit message string
# Returns: 0 always
generate_url_skill_commit_msg() {
	local skill_name="$1"
	local upstream_url="$2"
	local prev_hash="$3"
	local new_hash="$4"

	local timestamp
	timestamp=$(date -u +"%Y-%m-%d")

	local subject="chore(skill/${skill_name}): update from upstream URL (${new_hash:0:12})"

	local prev_short="${prev_hash:0:12}"
	[[ -z "$prev_short" ]] && prev_short="(none)"

	local body
	body="Upstream: ${upstream_url}
Previous hash: ${prev_short}
New hash:      ${new_hash:0:12}
Updated:       ${timestamp}

Content hash changed — URL-sourced skill re-imported."

	printf '%s\n\n%s\n' "$subject" "$body"
	return 0
}

# Generate the full PR body for a URL-sourced skill update (t1415.2).
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - previous hash (may be empty)
#   $4 - new hash
#   $5 - diff summary (multi-line string, may be empty)
# Outputs: PR body markdown
# Returns: 0 always
generate_url_skill_pr_body() {
	local skill_name="$1"
	local upstream_url="$2"
	local prev_hash="$3"
	local new_hash="$4"
	local diff_summary="$5"

	local prev_display="${prev_hash:0:12}"
	[[ -z "$prev_display" ]] && prev_display="_(none -- first import)_"

	cat <<PREOF
## Skill Update: \`${skill_name}\` (URL source)

Automated skill update — upstream URL content changed (SHA-256 hash mismatch).

| Field | Value |
|-------|-------|
| Skill | \`${skill_name}\` |
| Source | ${upstream_url} |
| Previous hash | \`${prev_display}\` |
| New hash | \`${new_hash:0:12}\` |
| Detection | Content hash (SHA-256) |

### Upstream changelog

_Not available for URL-sourced skills (no git history). Review the diff below for changes._

### Diff summary

PREOF

	if [[ -n "$diff_summary" ]]; then
		echo "$diff_summary"
	else
		echo "_No diff available._"
	fi

	cat <<PREOF

### Review checklist

- [ ] Verify the updated skill content is correct
- [ ] Check for breaking changes in the skill format
- [ ] Confirm security scan passes (re-run if needed)

---
*Generated by \`skill-update-helper.sh pr\` (t1415.2)*
PREOF

	return 0
}

# =============================================================================
# PR Pipeline — worktree, commit, push, create PR (t1082)
# =============================================================================

# Get the repo root (must be run from within the aidevops repo)
get_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || echo ""
	return 0
}

# Get the default branch (main or master)
get_default_branch() {
	local default_branch
	default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
	if [[ -n "$default_branch" ]]; then
		echo "$default_branch"
		return 0
	fi
	if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
		echo "main"
	elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
		echo "master"
	else
		echo "main"
	fi
	return 0
}

# Create or reuse a worktree for a given branch name.
# Uses worktree-helper.sh if available, falls back to direct git worktree add.
# Arguments:
#   $1 - branch name
#   $2 - repo root path
#   $3 - label for error messages (e.g. skill name or "batch")
# Outputs: worktree path on stdout
# Returns: 0 on success, 1 on failure
_create_worktree_for_branch() {
	local branch_name="$1"
	local repo_root="$2"
	local label="$3"

	local worktree_path=""

	if [[ -x "$WORKTREE_HELPER" ]]; then
		local wt_output
		wt_output=$("$WORKTREE_HELPER" add "$branch_name" 2>&1) || {
			if echo "$wt_output" | grep -q "already exists"; then
				worktree_path=$(echo "$wt_output" | grep -oE '/[^ ]+' | head -1)
				log_info "Using existing worktree: $worktree_path"
			else
				log_error "Failed to create worktree for $label: $wt_output"
				return 1
			fi
		}
		if [[ -z "${worktree_path:-}" ]]; then
			worktree_path=$(echo "$wt_output" | grep "^Path:" | sed 's/^Path: *//' | head -1)
			worktree_path=$(echo "$worktree_path" | sed 's/\x1b\[[0-9;]*m//g')
		fi
	fi

	if [[ -z "${worktree_path:-}" ]]; then
		local parent_dir repo_name slug
		parent_dir=$(dirname "$repo_root")
		repo_name=$(basename "$repo_root")
		slug=$(echo "$branch_name" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
		worktree_path="${parent_dir}/${repo_name}-${slug}"

		if [[ -d "$worktree_path" ]]; then
			log_info "Using existing worktree: $worktree_path"
		else
			log_info "Creating worktree at: $worktree_path"
			local wt_add_output
			if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
				wt_add_output=$(git worktree add "$worktree_path" "$branch_name" 2>&1) || {
					log_error "Failed to create worktree for $label: ${wt_add_output}"
					return 1
				}
			else
				wt_add_output=$(git worktree add -b "$branch_name" "$worktree_path" 2>&1) || {
					log_error "Failed to create worktree for $label: ${wt_add_output}"
					return 1
				}
			fi
			register_worktree "$worktree_path" "$branch_name"
		fi
	fi

	if [[ ! -d "$worktree_path" ]]; then
		log_error "Worktree path does not exist: $worktree_path"
		return 1
	fi

	echo "$worktree_path"
	return 0
}

# Push a branch and create a PR via gh CLI.
# Arguments:
#   $1 - worktree path
#   $2 - branch name
#   $3 - default branch (base)
#   $4 - PR title
#   $5 - PR body
#   $6 - label for error messages (e.g. skill name or "batch")
# Returns: 0 on success, 1 on failure
_push_and_create_pr() {
	local worktree_path="$1"
	local branch_name="$2"
	local default_branch="$3"
	local pr_title="$4"
	local pr_body="$5"
	local label="$6"

	local push_output
	push_output=$(git -C "$worktree_path" push -u origin "$branch_name" 2>&1) || {
		log_error "Failed to push branch for $label: ${push_output}"
		return 1
	}
	log_success "Pushed branch: $branch_name"

	if ! command -v gh &>/dev/null; then
		log_warning "gh CLI not available — branch pushed but PR not created"
		log_info "Create PR manually: gh pr create --head $branch_name" # aidevops-allow: raw-gh-wrapper
		return 0
	fi

	if ! gh auth status &>/dev/null; then
		log_warning "gh auth unavailable — branch pushed but PR not created for $label"
		log_info "Authenticate with: gh auth login"
		log_info "Create PR manually: gh pr create --head $branch_name" # aidevops-allow: raw-gh-wrapper
		return 1
	fi

	# Append signature footer
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$pr_body" 2>/dev/null || true)
	pr_body="${pr_body}${sig_footer}"

	# Origin label injected by gh_create_pr wrapper (t1756)
	local pr_create_output
	pr_create_output=$(gh_create_pr \
		--head "$branch_name" \
		--base "$default_branch" \
		--title "$pr_title" \
		--body "$pr_body" \
		--repo "$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo '')" \
		2>&1) || {
		log_error "Failed to create PR for $label: ${pr_create_output}"
		log_info "Branch is pushed — create PR manually: gh pr create --head $branch_name" # aidevops-allow: raw-gh-wrapper
		return 1
	}

	log_success "PR created for $label: $pr_create_output"
	return 0
}

# Build commit message and PR artifacts for a single skill update, then commit.
# Sets globals _PR_TITLE and _PR_BODY for the caller.
# Arguments:
#   $1 - worktree path
#   $2 - skill name
#   $3 - upstream URL
#   $4 - current commit/hash
#   $5 - latest commit/hash
#   $6 - source type: "github" or "url"
#   $7 - default branch
# Returns: 0 on success, 1 on failure
_PR_TITLE=""
_PR_BODY=""
_commit_skill_update() {
	local worktree_path="$1"
	local skill_name="$2"
	local upstream_url="$3"
	local current_commit="$4"
	local latest_commit="$5"
	local source_type="$6"
	local default_branch="$7"

	git -C "$worktree_path" add -A
	local diff_summary
	diff_summary=$(get_skill_diff_summary "$worktree_path" "$default_branch")

	local commit_msg
	if [[ "$source_type" == "url" ]]; then
		commit_msg=$(generate_url_skill_commit_msg \
			"$skill_name" "$upstream_url" "$current_commit" "$latest_commit")
		_PR_TITLE="chore(skill/${skill_name}): update from upstream URL (${latest_commit:0:12})"
		_PR_BODY=$(generate_url_skill_pr_body \
			"$skill_name" "$upstream_url" "$current_commit" "$latest_commit" "$diff_summary")
		update_upstream_hash "$skill_name" "$latest_commit"
	else
		local owner_repo_for_log changelog=""
		owner_repo_for_log=$(parse_github_url "$upstream_url")
		owner_repo_for_log=$(echo "$owner_repo_for_log" | cut -d'/' -f1-2)
		if [[ -n "$owner_repo_for_log" && "$owner_repo_for_log" != "/" ]]; then
			log_info "Fetching upstream changelog for $skill_name..."
			changelog=$(get_upstream_changelog "$owner_repo_for_log" "$current_commit" "$latest_commit" 2>/dev/null || true)
		fi
		commit_msg=$(generate_skill_commit_msg \
			"$skill_name" "$upstream_url" "$current_commit" "$latest_commit" "$changelog")
		_PR_TITLE="chore(skill/${skill_name}): update from upstream (${latest_commit:0:7})"
		_PR_BODY=$(generate_skill_pr_body \
			"$skill_name" "$upstream_url" "$current_commit" "$latest_commit" \
			"$changelog" "$diff_summary")
	fi

	local commit_output
	commit_output=$(git -C "$worktree_path" commit -m "$commit_msg" --no-verify 2>&1) || {
		log_error "Failed to commit changes for $skill_name: ${commit_output}"
		return 1
	}
	log_success "Committed skill update for $skill_name"
	return 0
}

# Process a single skill update: worktree -> re-import -> commit -> PR
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current commit/hash (for PR body context)
#   $4 - latest commit/hash
#   $5 - source type: "github" (default) or "url" (t1415.2)
# Returns: 0 on success, 1 on failure
cmd_pr_single() {
	local skill_name="$1"
	local upstream_url="$2"
	local current_commit="$3"
	local latest_commit="$4"
	local source_type="${5:-github}"

	local repo_root
	repo_root=$(get_repo_root)
	if [[ -z "$repo_root" ]]; then
		log_error "Not in a git repository"
		return 1
	fi

	local default_branch
	default_branch=$(get_default_branch)

	local branch_name="chore/skill-update-${skill_name}"

	# Check if a PR already exists for this branch
	if command -v gh &>/dev/null; then
		local existing_pr
		existing_pr=$(gh pr list --head "$branch_name" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
		if [[ -n "$existing_pr" ]]; then
			log_warning "PR #${existing_pr} already open for $skill_name — skipping"
			return 0
		fi
	fi

	if [[ "$DRY_RUN" == true ]]; then
		log_info "DRY RUN: Would create PR for $skill_name"
		echo "  Branch: $branch_name"
		echo "  Current: ${current_commit:0:7}"
		echo "  Latest:  ${latest_commit:0:7}"
		echo "  Source:  $upstream_url"
		echo ""
		return 0
	fi

	log_info "Creating PR for skill update: $skill_name"

	local worktree_path
	worktree_path=$(_create_worktree_for_branch "$branch_name" "$repo_root" "$skill_name") || return 1

	# Re-import the skill in the worktree context
	log_info "Re-importing $skill_name in worktree..."
	local add_skill_in_wt="${worktree_path}/.agents/scripts/add-skill-helper.sh"
	if [[ ! -x "$add_skill_in_wt" ]]; then
		add_skill_in_wt="$ADD_SKILL_HELPER"
	fi

	if ! (cd "$worktree_path" && "$add_skill_in_wt" add "$upstream_url" --force --skip-security 2>&1); then
		log_error "Failed to re-import $skill_name"
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	fi

	# Check if there are actual changes
	if git -C "$worktree_path" diff --quiet && git -C "$worktree_path" diff --cached --quiet; then
		local untracked
		untracked=$(git -C "$worktree_path" ls-files --others --exclude-standard 2>/dev/null || echo "")
		if [[ -z "$untracked" ]]; then
			log_info "No changes detected for $skill_name after re-import — skipping"
			_cleanup_worktree "$worktree_path" "$branch_name"
			return 0
		fi
	fi

	if ! _commit_skill_update \
		"$worktree_path" "$skill_name" "$upstream_url" \
		"$current_commit" "$latest_commit" "$source_type" "$default_branch"; then
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	fi

	_push_and_create_pr \
		"$worktree_path" "$branch_name" "$default_branch" \
		"$_PR_TITLE" "$_PR_BODY" "$skill_name"
	return $?
}

# Clean up a worktree on failure (only if we created it)
_cleanup_worktree() {
	local wt_path="$1"
	local branch="$2"

	# Only clean up if the worktree has no commits beyond the base
	local default_branch
	default_branch=$(get_default_branch)
	local ahead
	ahead=$(git -C "$wt_path" rev-list --count "${default_branch}..HEAD" 2>/dev/null || echo "0")

	if [[ "$ahead" -eq 0 ]]; then
		# Ownership check (t2974): refuse to remove worktrees owned by other sessions
		if is_worktree_owned_by_others "$wt_path"; then
			log_warning "Skipping removal of worktree owned by another session: $wt_path"
			# t2976: audit log — skill worktree removal blocked by ownership registry
			log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_SU_CALLER" "$wt_path" "owned-skip" "skipped"
			return 0
		fi
		if ! worktree_removal_guard "$wt_path" "$_WTAR_SU_CALLER" "manual"; then
			log_warning "Skipping removal of guarded worktree path: $wt_path"
			return 0
		fi
		log_info "Cleaning up empty worktree: $wt_path"
		if ! remove_worktree_path_permanently "$wt_path" "$_WTAR_SU_CALLER" "manual"; then
			log_warning "Skipping branch cleanup because guarded worktree removal failed: $wt_path"
			return 0
		fi
		git branch -D "$branch" 2>/dev/null || true
		unregister_worktree "$wt_path"
	fi
	return 0
}
