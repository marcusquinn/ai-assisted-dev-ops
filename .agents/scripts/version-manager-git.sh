#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001,SC2034,SC2181,SC2317
# =============================================================================
# Version Manager — Git Operations
# =============================================================================
# Git workflow, task auto-completion, and commit/push functions extracted from
# version-manager.sh to reduce file size.
#
# Covers:
#   - Remote sync verification
#   - Working tree state checks
#   - Task ID extraction from commit history
#   - TODO.md task auto-completion
#   - Bump commit creation and verification (t2437/GH#20073 guards)
#   - Push with retry and rebase
#
# Usage: source "${SCRIPT_DIR}/version-manager-git.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#     sed_inplace)
#   - REPO_ROOT and VERSION_FILE must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_VERSION_MANAGER_GIT_LOADED:-}" ]] && return 0
_VERSION_MANAGER_GIT_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./task-identity-lib.sh
source "${SCRIPT_DIR}/task-identity-lib.sh"
# shellcheck source=./version-manager-protected-main.sh
source "${SCRIPT_DIR}/version-manager-protected-main.sh"

# Exit code 2 used by commit_version_changes to distinguish "nothing staged"
# from "commit succeeded" (0). Callers that expect a new bump commit on HEAD
# must treat exit 2 as fatal — see _release_execute (t2437/GH#20073).
readonly VERSION_MANAGER_NO_CHANGES_EXIT=2
readonly _VERSION_MANAGER_SOURCE_ENTRY_JQ='"\(.pr)@\(.merge)"'

# --- Functions ---

assert_release_linked_worktree() {
	cd "$REPO_ROOT" || return 1
	local git_dir git_common_dir
	git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null)
	git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
	if [[ -z "$git_dir" || -z "$git_common_dir" || "$git_dir" == "$git_common_dir" ]]; then
		print_error "Release refused in canonical repository"
		print_info "Create a detached linked worktree from origin/main and retry"
		return 1
	fi
	return 0
}

# Verify a release is running from an isolated linked worktree exactly at remote.
verify_remote_sync() {
	local branch="$1"
	branch="${branch:-main}"

	cd "$REPO_ROOT" || exit 1

	assert_release_linked_worktree || return 1

	local current_branch
	current_branch=$(git branch --show-current 2>/dev/null)
	if [[ -n "$current_branch" && "$current_branch" != "$branch" ]]; then
		print_error "Release worktree must be detached at origin/$branch or use branch $branch"
		return 1
	fi

	print_info "Verifying release worktree HEAD is exactly origin/$branch..."

	if ! git fetch origin "$branch" --quiet 2>/dev/null; then
		print_error "Could not fetch origin/$branch; refusing release"
		return 1
	fi

	local local_sha
	local_sha=$(git rev-parse HEAD 2>/dev/null)
	local remote_sha
	remote_sha=$(git rev-parse "origin/$branch" 2>/dev/null)

	if [[ -z "$local_sha" || -z "$remote_sha" ]]; then
		print_error "Could not determine release worktree or remote SHA"
		return 1
	fi

	if [[ "$local_sha" != "$remote_sha" ]]; then
		print_error "Release worktree HEAD differs from origin/$branch"
		print_info "Discard it and create a fresh detached linked worktree from origin/$branch"
		return 1
	fi

	print_success "Release worktree is in sync with origin/$branch"
	return 0
}

_release_repo_slug() {
	local remote_url=""
	remote_url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
	case "$remote_url" in
	*github.com/*) remote_url="${remote_url#*github.com/}" ;;
	*github.com:*) remote_url="${remote_url#*github.com:}" ;;
	*) return 1 ;;
	esac
	printf '%s\n' "${remote_url%.git}"
	return 0
}

release_source_pr_required() {
	local repo_slug=""
	repo_slug=$(_release_repo_slug 2>/dev/null || true)
	if [[ "$repo_slug" == "marcusquinn/aidevops" ]]; then
		return 0
	fi
	return 1
}

verify_release_source_pr() {
	local source_pr="$1"
	local branch="${2:-main}"
	local repo_slug="${3:-}"
	local expected_sources="${4:-}"
	[[ "$source_pr" =~ ^[0-9]+$ ]] || {
		print_error "Release source PR must be a numeric GitHub pull request"
		return 1
	}
	if [[ -z "$repo_slug" ]]; then
		repo_slug=$(_release_repo_slug 2>/dev/null || true)
	fi
	[[ -n "$repo_slug" ]] || {
		print_error "Cannot resolve GitHub repository for release provenance"
		return 1
	}

	local resolver="${AIDEVOPS_RELEASE_SOURCE_RESOLVER:-${SCRIPT_DIR}/release-provenance-helper.sh}"
	local source_json=""
	local resolver_args=(resolve-source --source-pr "$source_pr" --repo "$repo_slug" --branch "$branch")
	[[ -x "$resolver" ]] || {
		print_error "Release source provenance resolver is unavailable"
		return 1
	}
	[[ -n "$expected_sources" ]] && resolver_args+=(--expected-sources "$expected_sources")
	source_json=$(cd "$REPO_ROOT" && bash "$resolver" "${resolver_args[@]}") || return 1
	VERSION_MANAGER_SOURCE_PR=$(jq -er '.source_pr' <<<"$source_json") || return 1
	VERSION_MANAGER_SOURCE_MERGE_SHA=$(jq -er '.source_merge' <<<"$source_json") || return 1
	VERSION_MANAGER_AGGREGATED_SOURCES=$(jq -cr ".aggregated_sources // [] | .[] | ${_VERSION_MANAGER_SOURCE_ENTRY_JQ}" \
		<<<"$source_json") || return 1
	VERSION_MANAGER_EXPECTED_SOURCES=$(jq -er "
		(.expected_sources // (if .mode == \"direct\" then [{pr:.source_pr,merge:.source_merge}] else .aggregated_sources end))
		| sort_by(.pr) | map(${_VERSION_MANAGER_SOURCE_ENTRY_JQ}) | join(\",\")
	" <<<"$source_json") || return 1
	export VERSION_MANAGER_SOURCE_PR VERSION_MANAGER_SOURCE_MERGE_SHA VERSION_MANAGER_AGGREGATED_SOURCES VERSION_MANAGER_EXPECTED_SOURCES
	print_success "Release provenance verified: PR #${VERSION_MANAGER_SOURCE_PR}, merge ${VERSION_MANAGER_SOURCE_MERGE_SHA}"
	return 0
}

verify_release_tag_source() {
	local tag_name="$1"
	local source_pr="$2"
	local branch="${3:-main}"
	local repo_slug="${4:-}"
	local expected_sources="${5:-}"
	local resolver="${AIDEVOPS_RELEASE_SOURCE_RESOLVER:-${SCRIPT_DIR}/release-provenance-helper.sh}"
	local source_json=""
	local -a resolver_args=(resolve-tag-authorization --tag "$tag_name" --source-pr "$source_pr" --branch "$branch")
	if [[ -z "$repo_slug" ]]; then
		repo_slug=$(_release_repo_slug 2>/dev/null || true)
	fi
	[[ -n "$repo_slug" && -x "$resolver" ]] || return 1
	resolver_args+=(--repo "$repo_slug")
	[[ -n "$expected_sources" ]] && resolver_args+=(--expected-sources "$expected_sources")
	source_json=$(cd "$REPO_ROOT" && bash "$resolver" "${resolver_args[@]}") || return 1
	VERSION_MANAGER_SOURCE_PR=$(jq -er '.source_pr' <<<"$source_json") || return 1
	VERSION_MANAGER_SOURCE_MERGE_SHA=$(jq -er '.source_merge' <<<"$source_json") || return 1
	VERSION_MANAGER_AGGREGATED_SOURCES=$(jq -cr ".aggregated_sources // [] | .[] | ${_VERSION_MANAGER_SOURCE_ENTRY_JQ}" \
		<<<"$source_json") || return 1
	VERSION_MANAGER_EXPECTED_SOURCES=$(jq -er ".expected_sources | sort_by(.pr) | map(${_VERSION_MANAGER_SOURCE_ENTRY_JQ}) | join(\",\")" \
		<<<"$source_json") || return 1
	export VERSION_MANAGER_SOURCE_PR VERSION_MANAGER_SOURCE_MERGE_SHA
	export VERSION_MANAGER_AGGREGATED_SOURCES VERSION_MANAGER_EXPECTED_SOURCES
	return 0
}

# Function to check for uncommitted changes
check_working_tree_clean() {
	local uncommitted
	uncommitted=$(git status --porcelain 2>/dev/null)

	if [[ -n "$uncommitted" ]]; then
		print_error "Working tree has uncommitted changes:"
		echo "$uncommitted" | head -20
		echo ""
		print_info "Options:"
		print_info "  1. Commit your changes first: git add -A && git commit -m 'your message'"
		print_info "  2. Stash changes: git stash"
		print_info "  3. Use --allow-dirty to release anyway (not recommended)"
		return 1
	fi
	return 0
}

# Function to extract task IDs from commit messages since last tag
# Only extracts from commits that indicate task COMPLETION, not mere mentions
# Completion patterns:
#   - Conventional commits with task scope: feat(t001):, fix(t002):, docs(t003):
#   - Explicit completion phrases: "mark t001 done", "complete t002", "closes t003"
#   - Multi-task with explicit marker: "mark t001, t002 done" (tasks before "done")
extract_task_ids_from_commits() {
	local prev_tag
	prev_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

	local commits
	if [[ -n "$prev_tag" ]]; then
		commits=$(git log "$prev_tag"..HEAD --pretty=format:"%s" 2>/dev/null)
	else
		commits=$(git log --oneline -50 --pretty=format:"%s" 2>/dev/null)
	fi

	local -a task_ids=()
	local conventional_scope_ere='^(feat|fix|docs|refactor|perf|test|chore|style|build|ci)\(([^)]+)\):'

	while IFS= read -r commit; do
		[[ -z "$commit" ]] && continue

		# Pattern 0: Framework squash subjects with a complete leading task ID.
		# Brackets provide an explicit boundary and avoid matching ID-like text
		# embedded in unrelated words. Dotted task IDs remain supported.
		if [[ "$commit" =~ ^\[([^]]+)\]([[:space:]]|$) ]] && task_identity_validate "${BASH_REMATCH[1]}"; then
			task_ids+=("${BASH_REMATCH[1]}")
		fi

		# Pattern 1: Conventional commits with task ID in scope
		# e.g., feat(t001):, fix(t3375):, docs(t003.1):, refactor(t004):
		if [[ "$commit" =~ $conventional_scope_ere ]] && task_identity_validate "${BASH_REMATCH[2]}"; then
			task_ids+=("${BASH_REMATCH[2]}")
		fi

		# Pattern 2: "mark tXXX done/complete" - extract task IDs between "mark" and "done/complete"
		# e.g., "mark t004, t048, t069 done" -> t004, t048, t069
		if [[ "$commit" =~ mark[[:space:]]+(.*)[[:space:]]+(done|complete) ]]; then
			local segment="${BASH_REMATCH[1]}"
			local id
			if ! task_identity_has_malformed_candidate "$segment"; then
				while IFS= read -r id; do
					[[ -n "$id" ]] || continue
					task_ids+=("$id")
				done < <(task_identity_extract_all "$segment")
			fi
		fi

		# Pattern 3: "complete/completes/closes tXXX" - task ID immediately after keyword
		# e.g., "complete t037", "closes t001"
		local completion_match
		while IFS= read -r completion_match; do
			[[ -n "$completion_match" ]] || continue
			local id
			id=$(task_identity_extract_first "$completion_match" || true)
			[[ -n "$id" ]] || continue
			task_ids+=("$id")
		done < <(printf '%s\n' "$commit" | grep -oE '(^|[^[:alnum:]_])(completes?|closes?)[[:space:]]+[^[:space:]]+' || true)

		# Pattern 4: "tXXX complete/done/finished" - task ID before completion word
		# e.g., "t001 complete", "t002 done"
		local task_before_completion_match
		while IFS= read -r task_before_completion_match; do
			[[ -n "$task_before_completion_match" ]] || continue
			local id
			id=$(task_identity_extract_first "$task_before_completion_match" || true)
			[[ -n "$id" ]] || continue
			task_ids+=("$id")
		done < <(printf '%s\n' "$commit" | grep -oE '[^[:space:]]+[[:space:]]+(complete|done|finished)($|[^[:alnum:]_])' || true)

	done <<<"$commits"

	# Deduplicate and sort
	if [[ ${#task_ids[@]} -eq 0 ]]; then
		return 0
	fi

	local task_id=""
	for task_id in "${task_ids[@]}"; do
		task_identity_validate "$task_id" || continue
		printf '%s\n' "$task_id"
	done | sort -u
	return 0
}

# Function to find the PR number associated with a task ID from commit messages (t1004)
# Searches commits since last tag for PR references like (#NNN) in commits mentioning the task
# Falls back to gh CLI search if no PR found in commit messages
find_pr_for_task_from_commits() {
	local task_id="$1"
	task_identity_validate "$task_id" || return 1

	local prev_tag
	prev_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

	local commits
	if [[ -n "$prev_tag" ]]; then
		commits=$(git log "$prev_tag"..HEAD --pretty=format:"%s" 2>/dev/null)
	else
		commits=$(git log --oneline -50 --pretty=format:"%s" 2>/dev/null)
	fi

	# Search commit messages containing this task ID for (#NNN) PR references
	local pr_number=""
	while IFS= read -r commit; do
		[[ -z "$commit" ]] && continue
		local commit_task_id="" exact_match="false"
		while IFS= read -r commit_task_id; do
			if [[ "$commit_task_id" == "$task_id" ]]; then
				exact_match="true"
				break
			fi
		done < <(task_identity_extract_all "$commit")
		if [[ "$exact_match" == "true" ]]; then
			pr_number=$(echo "$commit" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
			if [[ -n "$pr_number" ]]; then
				break
			fi
		fi
	done <<<"$commits"

	# Fallback: try gh CLI to find merged PR for this task
	if [[ -z "$pr_number" ]] && command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
		pr_number=$(gh pr list --state merged --search "$task_id" --limit 1 --json number --jq '.[0].number' 2>/dev/null || true)
	fi

	echo "$pr_number"
	return 0
}

# Mark a single task as complete in TODO.md.
# Changes [ ] to [x], adds proof-log (pr:#NNN or verified:date) and completed: timestamp.
# Arguments: task_id todo_file today_short
# Returns: 0 if marked, 1 if already complete, 2 if not found
_dedupe_completed_task_lines() {
	local task_id="$1"
	local todo_file="$2"
	local escaped_id completed_pattern duplicate_count tmp_file

	escaped_id=$(task_identity_escape_ere "$task_id") || return 2
	completed_pattern="^[[:space:]]*- \\[x\\] ${escaped_id}[[:space:]]"
	duplicate_count=$(grep -Ec "$completed_pattern" "$todo_file" 2>/dev/null || true)

	if [[ "$duplicate_count" -le 1 ]]; then
		return 1
	fi

	tmp_file=$(mktemp "${todo_file}.dedupe.XXXXXX") || return 2
	if ! awk -v task_pattern="$escaped_id" '
		BEGIN { pattern = "^[[:space:]]*- \\[x\\] " task_pattern "[[:space:]]" }
		$0 ~ pattern {
			seen += 1
			if (seen > 1) {
				next
			}
		}
		{ print }
	' "$todo_file" >"$tmp_file"; then
		rm -f "$tmp_file"
		return 2
	fi

	if ! mv "$tmp_file" "$todo_file"; then
		rm -f "$tmp_file"
		return 2
	fi

	print_warning "Removed duplicate completed TODO.md entries for $task_id"
	return 0
}

_mark_single_task_complete() {
	local task_id="$1"
	local todo_file="$2"
	local today_short="$3"
	local dedupe_rc=0
	local escaped_id=""
	escaped_id=$(task_identity_escape_ere "$task_id") || return 2

	# Build regex patterns (avoids shellcheck SC1087 false positive with [[:space:]])
	local unchecked_pattern="^[[:space:]]*- \\[ \\] ${escaped_id}[[:space:]]"
	local checked_pattern="^[[:space:]]*- \\[x\\] ${escaped_id}[[:space:]]"

	if grep -qE "$unchecked_pattern" "$todo_file"; then
		# Discover PR number for proof-log (t1004)
		local pr_number=""
		pr_number=$(find_pr_for_task_from_commits "$task_id")

		# Build proof-log: pr:#NNN if PR found, otherwise verified:date
		local proof_log=""
		if [[ -n "$pr_number" ]]; then
			proof_log=" pr:#${pr_number}"
		else
			proof_log=" verified:${today_short}"
		fi

		local sed_unchecked_pattern="^[[:space:]]*- \\[ \\] ${escaped_id}[[:space:]]"

		# Check if line already has completed: field
		if grep -E "$sed_unchecked_pattern" "$todo_file" | grep -q "completed:"; then
			sed_inplace "s/^\\([[:space:]]*\\)- \\[ \\] \\(${escaped_id}[[:space:]].*\\)\$/\\1- [x] \\2${proof_log}/" "$todo_file"
		else
			sed_inplace "s/^\\([[:space:]]*\\)- \\[ \\] \\(${escaped_id}[[:space:]].*\\)\$/\\1- [x] \\2${proof_log} completed:$today_short/" "$todo_file"
		fi

		_dedupe_completed_task_lines "$task_id" "$todo_file" || dedupe_rc=$?
		if [[ "$dedupe_rc" -eq 2 ]]; then
			print_error "Failed to remove duplicate completed TODO.md entries for $task_id"
			return 2
		fi

		print_success "Marked $task_id as complete (${proof_log# })"
		return 0
	elif grep -qE "$checked_pattern" "$todo_file"; then
		_dedupe_completed_task_lines "$task_id" "$todo_file" || dedupe_rc=$?
		if [[ "$dedupe_rc" -eq 0 ]]; then
			return 0
		elif [[ "$dedupe_rc" -eq 2 ]]; then
			print_error "Failed to remove duplicate completed TODO.md entries for $task_id"
			return 2
		fi
		print_info "Task $task_id already marked complete"
		return 1
	else
		print_warning "Task $task_id not found in TODO.md (may be subtask or already moved)"
		return 2
	fi
}

# Function to auto-mark tasks complete in TODO.md based on commit messages
# Parses commits since last tag for task IDs and marks them complete
# Writes pr:#NNN proof-log when a PR is discoverable, otherwise verified:YYYY-MM-DD (t1004)
auto_mark_tasks_complete() {
	local todo_file="$REPO_ROOT/TODO.md"
	local today_short
	today_short=$(date +%Y-%m-%d)

	if [[ ! -f "$todo_file" ]]; then
		print_warning "TODO.md not found, skipping task auto-completion"
		return 0
	fi

	print_info "Scanning commits for task IDs to auto-mark complete..."

	local task_ids
	task_ids=$(extract_task_ids_from_commits)

	if [[ -z "$task_ids" ]]; then
		print_info "No task IDs found in commits since last release"
		return 0
	fi

	local count=0
	local marked_tasks=""

	while IFS= read -r task_id; do
		[[ -z "$task_id" ]] && continue

		if _mark_single_task_complete "$task_id" "$todo_file" "$today_short"; then
			count=$((count + 1))
			marked_tasks="$marked_tasks $task_id"
		fi
	done <<<"$task_ids"

	if [[ $count -gt 0 ]]; then
		print_success "Auto-marked $count task(s) complete:$marked_tasks"
	fi

	return 0
}

# Expected commit subject for a release bump commit at "$version".
# Single source of truth — used by commit creation and by every downstream
# verification gate (post-commit, post-rebase, pre-tag, pre-push).
_bump_commit_subject() {
	local version="$1"
	printf 'chore(release): bump version to %s\n' "$version"
}

# Verify that a specific git ref (SHA, tag, HEAD) resolves to a commit whose
# subject line matches the expected bump-commit subject for the given version.
#
# Usage: _verify_bump_commit_at_ref <ref> <version>
# Returns: 0 on match, 1 on mismatch (with diagnostic output).
#
# This is the canonical guard that prevents the t2437/GH#20073 foot-gun: a
# rebase (or any history-rewriting operation) silently drops the bump commit,
# HEAD ends up at origin/main, and a subsequent retag-of-HEAD places the
# release tag on the wrong commit. Every code path that creates a tag or
# assumes HEAD is the bump commit MUST call this first.
_verify_bump_commit_at_ref() {
	local ref="$1"
	local version="$2"
	local expected actual resolved_sha

	expected=$(_bump_commit_subject "$version")

	resolved_sha=$(git rev-parse --verify "${ref}^{commit}" 2>/dev/null)
	if [[ -z "$resolved_sha" ]]; then
		print_error "Bump-commit verification failed: ref '$ref' does not resolve to a commit"
		return 1
	fi

	actual=$(git log -1 --format='%s' "$resolved_sha" 2>/dev/null)
	if [[ "$actual" != "$expected" ]]; then
		print_error "Bump-commit verification failed for ref '$ref' ($resolved_sha)"
		print_error "  Expected subject: $expected"
		print_error "  Actual subject:   ${actual:-<empty>}"
		return 1
	fi
	return 0
}

_create_aggregate_recovery_bump_commit() {
	local version="$1"
	local expected_parent="$2"
	local current_head=""
	local remote_head=""
	local actual_parent=""
	local commit_subject=""
	[[ "$expected_parent" =~ ^[0-9a-f]{40}$ ]] || return 1
	current_head=$(git rev-parse HEAD 2>/dev/null) || return 1
	remote_head=$(git rev-parse origin/main 2>/dev/null) || return 1
	[[ "$current_head" == "$expected_parent" && "$remote_head" == "$expected_parent" ]] || return 1
	git diff --quiet && git diff --cached --quiet || return 1
	commit_subject=$(_bump_commit_subject "$version") || return 1
	git commit --allow-empty --no-verify -m "$commit_subject" >/dev/null || return 1
	_verify_bump_commit_at_ref HEAD "$version" || return 1
	actual_parent=$(git rev-parse HEAD^ 2>/dev/null) || return 1
	[[ "$actual_parent" == "$expected_parent" ]]
	return $?
}

# Run commit_version_changes with strict return-code semantics and verify
# that HEAD ended up as the expected bump commit afterward.
#
# Usage: _release_commit_and_verify_bump <version> <bump_type>
# Returns: 0 on success; 1 on any failure (error already printed).
#
# Extracted from _release_execute to keep that function under 100 body lines
# while preserving the t2437/GH#20073 guard semantics. This is the canonical
# release-path commit-and-verify sequence; do not inline it elsewhere.
_release_commit_and_verify_bump() {
	local version="$1"
	local bump_type="$2"
	local commit_rc=0

	commit_version_changes "$version" || commit_rc=$?
	case "$commit_rc" in
	0) ;;
	"$VERSION_MANAGER_NO_CHANGES_EXIT")
		print_error "Aborting release: no version changes were staged (commit skipped)"
		print_info "This usually means update_version_in_files wrote no changes — diagnose with:"
		print_info "  git status && git diff VERSION CHANGELOG.md"
		print_info "Fix the upstream update and re-run: $0 release $bump_type"
		return 1
		;;
	*)
		print_error "Aborting release: commit_version_changes failed (rc=$commit_rc)"
		return 1
		;;
	esac

	# Defence-in-depth: even if the commit appeared to succeed, confirm
	# HEAD is actually the bump commit before the caller tags it. This
	# catches any edge case where the commit landed on a different branch
	# or a pre-commit hook amended it to a different subject.
	if ! _verify_bump_commit_at_ref HEAD "$version"; then
		print_error "Aborting release: HEAD is not the bump commit for v$version"
		print_info "Something between update_version_in_files and commit_version_changes"
		print_info "corrupted the intended commit. Recovery:"
		print_info "  git log --oneline -5   # inspect recent history"
		print_info "  git reset --hard origin/main && $0 release $bump_type"
		return 1
	fi

	return 0
}

# Function to commit version changes.
# Returns: 0 on successful commit, 1 on commit failure,
# VERSION_MANAGER_NO_CHANGES_EXIT (2) when there was nothing to stage.
# The 0-vs-2 split is load-bearing: _release_execute treats 2 as a fatal
# pre-tag condition because it means the VERSION bump never reached the
# index and retagging HEAD would place the tag on a non-bump commit.
commit_version_changes() {
	local version="$1"

	cd "$REPO_ROOT" || exit 1

	print_info "Committing version changes..."

	# Stage all version-related files (including CHANGELOG.md, TODO.md, Homebrew formula, and Claude plugin)
	git add VERSION package.json README.md setup.sh aidevops.sh sonar-project.properties CHANGELOG.md TODO.md homebrew/aidevops.rb .claude-plugin/marketplace.json 2>/dev/null

	# Check if there are changes to commit
	if git diff --cached --quiet; then
		print_info "No version changes to commit"
		return "$VERSION_MANAGER_NO_CHANGES_EXIT"
	fi

	# Version-bump commits contain only version-string updates — content is
	# internally controlled by this script. Pre-commit quality gates run in
	# CI on every other path. Skip the local hook here to avoid false positives
	# on pre-existing code that the release commit didn't touch (t2237).
	local commit_subject
	commit_subject=$(_bump_commit_subject "$version")
	if git commit --no-verify -m "$commit_subject"; then
		print_success "Committed version changes"
		return 0
	else
		print_error "Failed to commit version changes"
		return 1
	fi
}

# Function to push changes and tags
push_changes() {
	local version="$1" # version string, e.g. "3.8.71"
	local tag_name="v$version"
	local release_parent=""
	local push_output=""
	cd "$REPO_ROOT" || exit 1
	release_parent=$(git rev-parse HEAD^ 2>/dev/null) || {
		print_error "Cannot resolve release source parent"
		return 1
	}

	local attempt=0 max_attempts=10 delay=2
	while [[ $attempt -lt $max_attempts ]]; do
		attempt=$((attempt + 1))
		print_info "Pushing changes to remote (attempt $attempt/$max_attempts)..."

		# Use --atomic to ensure commit and tag are pushed together (all-or-nothing).
		# Capture stderr so permanent branch-policy rejection is classified after
		# one attempt rather than retried as transient contention.
		_version_manager_require_aggregate_fence || return 1
		if push_output=$(git push --atomic origin HEAD:refs/heads/main --tags 2>&1); then
			print_success "Pushed changes and tags to remote"
			return 0
		fi
		if _version_manager_push_requires_pr "$push_output"; then
			print_error "Direct release push rejected: GH006 Changes must be made through a pull request"
			if _version_manager_queue_protected_main_release "$version"; then
				case "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" in
				remote-tag-present | tag-pushed)
					print_success "Published preserved ${tag_name} after protected main became reachable"
					return 0
					;;
				esac
				print_success "release:queued protected-pr=${_VERSION_MANAGER_PROTECTED_PR_NUMBER:-unknown}"
				return 8
			fi
			print_error "Protected-main release recovery could not create a safe PR state"
			return 1
		fi

		# A release tag's signed provenance binds the bump commit directly to its
		# source merge. Never rebase and recreate that tag after concurrent main
		# movement; doing so would invalidate both the signature and provenance.
		print_info "Push failed. Refreshing remote state before retry..."
		if ! git fetch origin main --quiet; then
			print_error "Fetch failed, cannot retry"
			return 1
		fi
		if [[ "$(git rev-parse origin/main 2>/dev/null)" != "$release_parent" ]]; then
			if [[ -n "${AIDEVOPS_RELEASE_LANE_OPERATION_TOKEN:-}" ]]; then
				_version_manager_require_aggregate_fence || return 1
				if _version_manager_queue_protected_main_release "$version"; then
					case "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" in
					remote-tag-present | tag-pushed) return 0 ;;
					esac
					return 8
				fi
				return 1
			fi
			print_error "origin/main advanced after release provenance was recorded"
			print_info "Discard this release worktree and rerun from the latest merged source PR"
			git tag -d "$tag_name" 2>/dev/null || true
			return 1
		fi

		if [[ $attempt -lt $max_attempts ]]; then
			sleep "$delay"
			delay=$((delay * 2))
			[[ $delay -gt 60 ]] && delay=60
		fi
	done

	print_error "Failed to push after $max_attempts attempts. Manual recovery needed."
	print_info "Current SHA: $(git rev-parse HEAD), remote SHA: $(git rev-parse origin/main)"
	return 1
}
