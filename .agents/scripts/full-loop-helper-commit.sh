#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Commit & PR -- staging, validation, PR creation, merge summary
# =============================================================================
# Sub-library for full-loop-helper.sh orchestrator. Contains pre-merge gate,
# commit staging, project validators (node format/lint/typecheck), rebase/push,
# PR body composition, worker claim validation, PR creation, and merge summary.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-commit.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#     gh_create_pr, gh_pr_comment, gh_issue_comment, set_issue_status, _gh_recover_pr_if_exists)
#   - Globals: SCRIPT_DIR, HEADLESS
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_COMMIT_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_COMMIT_LIB_LOADED=1
_FULL_LOOP_CHECK_PENDING="pending"
_FULL_LOOP_CHECK_INDETERMINATE="indeterminate"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Pre-Merge Gate ---

# Pre-merge gate (GH#17541) — deterministic enforcement of review-bot-gate
# before any PR merge. Workers MUST call this before `gh pr merge`.
# Models the pulse-wrapper.sh pattern (line 8243-8262) for the worker merge path.
#
# Usage: full-loop-helper.sh pre-merge-gate <PR_NUMBER> [REPO]
# Exit codes: 0 = safe to merge, 1 = gate failed (do NOT merge)
_full_loop_persist_pr_check_evidence() {
	local status="$1"
	local head_sha="$2"
	local evidence="${3:-}"
	command -v load_state >/dev/null 2>&1 || return 0
	command -v save_state >/dev/null 2>&1 || return 0
	[[ -f "${STATE_FILE:-}" ]] || return 0
	command -v _full_loop_acquire_transition_lock >/dev/null 2>&1 || return 1
	_full_loop_acquire_transition_lock || return 1
	load_state || {
		_full_loop_release_transition_lock
		return 1
	}
	PR_CHECK_STATUS="$status"
	PR_CHECK_HEAD="$head_sha"
	PR_CHECK_EVIDENCE="$evidence"
	if ! save_state "${CURRENT_PHASE:-pr-review}" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"; then
		_full_loop_release_transition_lock
		return 1
	fi
	_full_loop_release_transition_lock
	return 0
}

_full_loop_query_required_checks() {
	local pr_number="$1"
	local repo="$2"
	local pr_head_ref="$3"
	local required_checks=""
	local required_rc=0
	local required_checks_stderr=""
	local required_checks_stderr_file=""
	local minimum_check_count=1
	local expected_no_required_checks="no required checks reported on the '${pr_head_ref}' branch"

	FULL_LOOP_REQUIRED_CHECKS_JSON=""
	FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="unavailable"
	FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="gh exit ${required_rc}"
	FULL_LOOP_REQUIRED_CHECKS_SUCCESS_EVIDENCE="required-checks-pass"
	FULL_LOOP_REQUIRED_CHECKS_SUCCESS_SUMMARY="required checks are terminal-success"

	required_checks_stderr_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-full-loop-required-checks.XXXXXX") || {
		FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE="stderr-capture-unavailable"
		FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="cannot capture gh stderr"
		return 1
	}
	required_checks=$(gh pr checks "$pr_number" --repo "$repo" \
		--required --json name,state,bucket 2>"$required_checks_stderr_file") || required_rc=$?
	required_checks_stderr=$(<"$required_checks_stderr_file")
	rm -f "$required_checks_stderr_file"
	FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL="gh exit ${required_rc}"

	if [[ "$required_rc" -eq 1 && -z "$required_checks" && -n "$pr_head_ref" && "$required_checks_stderr" == "$expected_no_required_checks" ]]; then
		required_checks="[]"
		minimum_check_count=0
		FULL_LOOP_REQUIRED_CHECKS_SUCCESS_EVIDENCE="no-required-checks"
		FULL_LOOP_REQUIRED_CHECKS_SUCCESS_SUMMARY="no required checks are configured"
	elif [[ -n "$required_checks_stderr" || ("$required_rc" -ne 0 && "$required_rc" -ne 1 && "$required_rc" -ne 8) ]]; then
		return 1
	fi
	if [[ -z "$required_checks" ]] || ! printf '%s' "$required_checks" | jq -e --argjson minimum "$minimum_check_count" \
		'type == "array" and length >= $minimum' >/dev/null 2>&1; then
		return 1
	fi
	FULL_LOOP_REQUIRED_CHECKS_JSON="$required_checks"
	return 0
}

_full_loop_verify_pr_readiness() {
	local pr_number="$1"
	local repo="$2"
	local pr_json=""

	pr_json=$(gh pr view "$pr_number" --repo "$repo" \
		--json state,isDraft,reviewDecision,headRefOid,headRefName 2>/dev/null) || {
		print_error "Cannot read PR #${pr_number} readiness evidence"
		return 1
	}

	if ! printf '%s' "$pr_json" | jq -e '
		def up(v): (v // "" | ascii_upcase);
		(.state == "OPEN")
		and (.isDraft != true)
		and (up(.reviewDecision) != "CHANGES_REQUESTED")
		and ((.headRefOid // "") != "")
	' >/dev/null; then
		print_error "PR #${pr_number} is not remotely verified: require OPEN, non-draft, no changes requested, and a stable head"
		return 1
	fi
	local verified_head=""
	verified_head=$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty')
	local pr_head_ref=""
	pr_head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // empty')

	local required_checks=""
	_full_loop_query_required_checks "$pr_number" "$repo" "$pr_head_ref" || {
		FULL_LOOP_PR_CHECK_STATUS="$_FULL_LOOP_CHECK_INDETERMINATE"
		export FULL_LOOP_PR_CHECK_STATUS
		_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$verified_head" "$FULL_LOOP_REQUIRED_CHECKS_ERROR_EVIDENCE" || true
		print_error "PR #${pr_number} required-check evidence is indeterminate (${FULL_LOOP_REQUIRED_CHECKS_ERROR_DETAIL})"
		return 1
	}
	required_checks="$FULL_LOOP_REQUIRED_CHECKS_JSON"
	local post_checks_head=""
	post_checks_head=$(gh pr view "$pr_number" --repo "$repo" --json headRefOid --jq '.headRefOid // empty' 2>/dev/null) || true
	if [[ -z "$post_checks_head" || "$post_checks_head" != "$verified_head" ]]; then
		FULL_LOOP_PR_CHECK_STATUS="$_FULL_LOOP_CHECK_INDETERMINATE"
		export FULL_LOOP_PR_CHECK_STATUS
		_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$post_checks_head" "head-drift-during-check-query" || true
		print_error "PR #${pr_number} head changed while required checks were queried; refresh exact-head evidence"
		return 1
	fi
	local non_passing=""
	non_passing=$(printf '%s' "$required_checks" | jq -c '[.[] | select((.bucket // "") != "pass")]')
	if [[ "$(printf '%s' "$non_passing" | jq 'length')" -gt 0 ]]; then
		if printf '%s' "$non_passing" | jq -e --arg pending "$_FULL_LOOP_CHECK_PENDING" 'all(.[]; (.bucket // "") == $pending)' >/dev/null 2>&1; then
			FULL_LOOP_PR_CHECK_STATUS="$_FULL_LOOP_CHECK_PENDING"
			export FULL_LOOP_PR_CHECK_STATUS
			_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$verified_head" "required-checks-pending" || true
			print_info "PR #${pr_number} required checks are pending at the current head; no repair action is eligible"
		else
			FULL_LOOP_PR_CHECK_STATUS="terminal-failure"
			FULL_LOOP_PR_FAILURE_EVIDENCE=$(printf '%s' "$non_passing" | jq -c --arg pending "$_FULL_LOOP_CHECK_PENDING" '[.[] | select((.bucket // "") != $pending) | {name,state,bucket}]')
			export FULL_LOOP_PR_CHECK_STATUS FULL_LOOP_PR_FAILURE_EVIDENCE
			local failure_names=""
			failure_names=$(printf '%s' "$FULL_LOOP_PR_FAILURE_EVIDENCE" | jq -r 'map(.name) | join(",")')
			_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$verified_head" "$failure_names" || true
			print_error "PR #${pr_number} has terminal required-check failures at the current head"
		fi
		return 1
	fi
	FULL_LOOP_PR_CHECK_STATUS="terminal-success"
	export FULL_LOOP_PR_CHECK_STATUS
	local local_branch=""
	local_branch=$(git branch --show-current 2>/dev/null || true)
	if [[ -n "$local_branch" && "$local_branch" == "$pr_head_ref" ]]; then
		local local_head=""
		local_head=$(git rev-parse HEAD 2>/dev/null || true)
		if [[ -z "$local_head" || "$local_head" != "$verified_head" ]]; then
			print_error "PR #${pr_number} head drifted from the current worktree; push or refresh review evidence before merge"
			return 1
		fi
	fi
	_full_loop_persist_pr_check_evidence "$FULL_LOOP_PR_CHECK_STATUS" "$verified_head" "$FULL_LOOP_REQUIRED_CHECKS_SUCCESS_EVIDENCE" || true

	FULL_LOOP_VERIFIED_PR_HEAD_SHA="$verified_head"
	export FULL_LOOP_VERIFIED_PR_HEAD_SHA
	print_success "Remote PR evidence verified at head ${verified_head}; ${FULL_LOOP_REQUIRED_CHECKS_SUCCESS_SUMMARY}"
	return 0
}

cmd_pre_merge_gate() {
	local pr_number="${1:-}"
	local repo="${2:-}"

	if [[ -z "$pr_number" ]]; then
		print_error "Usage: full-loop-helper.sh pre-merge-gate <PR_NUMBER> [REPO]"
		return 1
	fi

	# Auto-detect repo from git remote if not provided
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
		if [[ -z "$repo" ]]; then
			print_error "Cannot detect repo. Pass REPO as second argument."
			return 1
		fi
	fi

	_full_loop_verify_pr_readiness "$pr_number" "$repo" || return 1

	local rbg_helper="${SCRIPT_DIR}/review-bot-gate-helper.sh"
	if [[ ! -f "$rbg_helper" ]]; then
		# Fallback to deployed location
		rbg_helper="${HOME}/.aidevops/agents/scripts/review-bot-gate-helper.sh"
	fi

	if [[ ! -f "$rbg_helper" ]]; then
		print_error "review-bot-gate-helper.sh not found — refusing an unreviewed merge"
		return 1
	fi

	print_info "Running review bot gate for PR #${pr_number} in ${repo}..."

	# Check once. Pending review is persisted by the lifecycle caller and resumed
	# by the next provider/check event; this avoids a fixed-duration polling loop.
	local rbg_result=""
	rbg_result=$(bash "$rbg_helper" check "$pr_number" "$repo" 2>&1) || true

	local rbg_status=""
	rbg_status=$(printf '%s' "$rbg_result" | grep -oE '(PASS_RATE_LIMITED|PASS_ADVISORY|PASS|SKIP|WAITING)' | tail -1)

	case "$rbg_status" in
	PASS | PASS_ADVISORY | SKIP | PASS_RATE_LIMITED)
		print_success "Review bot gate: ${rbg_status} — safe to merge PR #${pr_number}"
		return 0
		;;
	*)
		print_error "Review bot gate: ${rbg_status:-FAILED} — do NOT merge PR #${pr_number}"
		printf '%s\n' "$rbg_result" | tail -5
		return 1
		;;
	esac
}

# --- Argument Parsing ---

# Parse commit-and-pr arguments into caller-scoped variables.
# Expects the caller to have declared: issue_number, commit_message, pr_title,
# summary_what, summary_testing, summary_decisions, runtime_risk, testing_level,
# skip_rebase, extra_labels (array).
# Returns 1 on unknown argument.
_parse_commit_and_pr_args() {
	local -a args=("$@")
	local index=0
	local arg=""
	local value=""
	while [[ "$index" -lt "${#args[@]}" ]]; do
		arg="${args[$index]}"
		case "$arg" in
		--issue | --message | --title | --summary | --testing | --risk-level | --testing-level | --decisions | --label)
			if [[ $((index + 1)) -ge ${#args[@]} ]]; then
				print_error "${arg} requires a value"
				return 1
			fi
			value="${args[$((index + 1))]}"
			;;
		esac

		case "$arg" in
		--issue)
			issue_number="$value"
			index=$((index + 2))
			;;
		--message)
			commit_message="$value"
			index=$((index + 2))
			;;
		--title)
			pr_title="$value"
			index=$((index + 2))
			;;
		--summary)
			summary_what="$value"
			index=$((index + 2))
			;;
		--testing)
			summary_testing="$value"
			index=$((index + 2))
			;;
		--risk-level)
			runtime_risk="$value"
			index=$((index + 2))
			;;
		--testing-level)
			testing_level="$value"
			index=$((index + 2))
			;;
		--decisions)
			summary_decisions="$value"
			index=$((index + 2))
			;;
		--label)
			extra_labels+=("$value")
			index=$((index + 2))
			;;
		--allow-parent-close)
			allow_parent_close=1
			index=$((index + 1))
			;;
		--skip-hooks)
			# Pass --no-verify to git push. Use for doc-only PRs when hooks
			# have been manually verified clean. See GH#20138.
			skip_hooks=1
			index=$((index + 1))
			;;
		--no-rebase)
			# GH#26627: explicit recovery mode after a failed/aborted rebase.
			# Pushes only after clean-state and ahead-of-base checks pass.
			skip_rebase=1
			index=$((index + 1))
			;;
		*)
			print_error "Unknown argument: $arg"
			return 1
			;;
		esac
	done
	return 0
}

# Resolve the remote default branch for cross-repo commit-and-pr operations.
# Returns 0 and prints the branch name, or returns 1 with remediation guidance.
_resolve_remote_default_branch() {
	local remote_name="${1:-origin}"
	local ref=""

	ref=$(git symbolic-ref --short "refs/remotes/${remote_name}/HEAD" 2>/dev/null || true)
	if [[ -n "$ref" ]]; then
		printf '%s\n' "${ref#"${remote_name}"/}"
		return 0
	fi

	print_error "Cannot determine ${remote_name} default branch from refs/remotes/${remote_name}/HEAD."
	print_error "Run: git remote set-head ${remote_name} --auto"
	print_error "Then retry: full-loop-helper.sh commit-and-pr ..."
	return 1
}

# Ensure no rebase/merge state is active before recovery-mode push.
_ensure_no_in_progress_integration() {
	local git_dir=""
	git_dir=$(git rev-parse --git-dir 2>/dev/null) || git_dir=""
	if [[ -z "$git_dir" ]]; then
		print_error "Cannot inspect git state for rebase/merge recovery."
		return 1
	fi

	local rebase_merge="" rebase_apply="" merge_head=""
	rebase_merge=$(git rev-parse --git-path rebase-merge 2>/dev/null || printf '%s' "${git_dir}/rebase-merge")
	rebase_apply=$(git rev-parse --git-path rebase-apply 2>/dev/null || printf '%s' "${git_dir}/rebase-apply")
	merge_head=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || printf '%s' "${git_dir}/MERGE_HEAD")

	if [[ -e "$rebase_merge" || -e "$rebase_apply" || -e "$merge_head" ]]; then
		print_error "Refusing recovery push while a rebase or merge is in progress."
		print_error "Resolve/abort the operation first, then retry with --no-rebase if appropriate."
		return 1
	fi
	return 0
}

# --- Input Validation ---

# Return 0 when a commit subject is an intermediate WIP message.
# Args: $1=commit subject
_is_wip_commit_message() {
	local message="$1"
	if [[ "$message" =~ ^wip[[:space:]:\(] ]]; then
		return 0
	fi
	return 1
}

# Validate commit-and-pr inputs: required fields and branch safety.
# Sets caller-scoped $repo and $branch on success.
# Returns 1 on validation failure.
_validate_commit_and_pr_inputs() {
	local issue_number="$1" commit_message="$2"

	if [[ -z "$issue_number" || -z "$commit_message" ]]; then
		print_error "Usage: full-loop-helper.sh commit-and-pr|create-pr --issue <N> --message <msg>"
		return 1
	fi
	if _is_wip_commit_message "$commit_message"; then
		print_error "Refusing WIP final commit message: ${commit_message}"
		print_error "Use a conventional final subject such as 'fix: describe the completed change'."
		return 1
	fi

	repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
	if [[ -z "$repo" ]]; then
		# t3050: gh repo view requires GraphQL. When GraphQL budget is
		# exhausted (rate-limit window), fall back to deriving the slug from
		# `git remote get-url origin`. This matches the framework rule
		# "No slug? Use `git -C <path> remote get-url origin`" and keeps
		# commit-and-pr working through GraphQL exhaustion. REST fallbacks
		# elsewhere in the wrapper handle the actual PR creation.
		local _origin_url=""
		_origin_url=$(git remote get-url origin 2>/dev/null || echo "")
		repo=$(printf '%s' "$_origin_url" | sed -E 's|^git@github.com:||; s|^https://github.com/||; s|\.git$||')
		if [[ -z "$repo" || "$repo" != */* ]]; then
			print_error "Cannot detect repo from git remote (gh repo view + git origin both failed)."
			return 1
		fi
		print_warning "[commit-and-pr] gh repo view failed (likely rate-limited); using git origin slug: $repo"
	fi

	branch=$(git branch --show-current 2>/dev/null || echo "")
	if [[ -z "$branch" || "$branch" == "main" || "$branch" == "master" ]]; then
		print_error "Cannot commit-and-pr from ref '${branch:-detached}'. Must be in a safe linked worktree."
		return 1
	fi
	return 0
}

# --- Staging & Commit ---

# Stage all changes and commit with the given message.
# Skips commit if nothing staged but commits exist ahead of the remote default branch.
# Returns 1 on failure.
_stage_and_commit() {
	local commit_message="$1"

	print_info "Staging and committing changes..."
	if ! git add -A; then
		print_error "git add failed"
		return 1
	fi

	if git diff --cached --quiet 2>/dev/null; then
		local base_branch="" base_ref="" ahead=""
		base_branch=$(_resolve_remote_default_branch origin) || return 1
		base_ref="origin/${base_branch}"
		ahead=$(git rev-list --count "${base_ref}..HEAD" 2>/dev/null || echo "0")
		if [[ "$ahead" == "0" ]]; then
			print_error "No changes to commit and no commits ahead of ${base_ref}."
			return 1
		fi
		print_info "No new changes to commit, but ${ahead} commit(s) ahead of ${base_ref}. Proceeding to PR."
	else
		if ! git commit -m "$commit_message"; then
			print_error "git commit failed"
			return 1
		fi
	fi
	return 0
}

# Replace branch history with one final commit when any branch commit is WIP.
# The caller-supplied final message is authoritative. On commit-hook failure,
# restore the original branch tip and preserve any hook-produced working changes.
# Args: $1=final commit message
_finalize_wip_history() {
	local commit_message="$1"
	if _is_wip_commit_message "$commit_message"; then
		print_error "Cannot finalize WIP history with another WIP message: ${commit_message}"
		return 1
	fi

	local base_branch="" branch_range="" branch_subjects=""
	local base_ref="" base_oid=""
	base_branch=$(_resolve_remote_default_branch origin) || return 1
	printf -v base_ref 'origin/%s' "$base_branch"
	if ! git fetch origin "$base_branch" --quiet 2>/dev/null; then
		print_error "Cannot refresh ${base_ref} before WIP history finalization."
		return 1
	fi
	base_oid=$(git rev-parse "$base_ref" 2>/dev/null) || {
		print_error "Cannot snapshot ${base_ref} before WIP history finalization."
		return 1
	}
	if ! git merge-base --is-ancestor "$base_oid" HEAD 2>/dev/null; then
		print_error "Refusing WIP finalization: current ${base_ref} is not an ancestor of HEAD."
		print_error "Rebase onto ${base_ref}, resolve any conflicts, then retry commit-and-pr."
		return 1
	fi
	printf -v branch_range '%s..HEAD' "$base_oid"
	if ! branch_subjects=$(git log --format=%s "$branch_range" 2>/dev/null); then
		print_error "Cannot inspect branch commit subjects relative to ${base_ref}."
		return 1
	fi

	local subject="" has_wip=0
	while IFS= read -r subject; do
		if _is_wip_commit_message "$subject"; then
			has_wip=1
			break
		fi
	done <<<"$branch_subjects"
	if [[ "$has_wip" == "0" ]]; then
		return 0
	fi

	local worktree_status=""
	if ! worktree_status=$(git status --porcelain 2>/dev/null); then
		print_error "Cannot verify a clean worktree before WIP history finalization."
		return 1
	fi
	if [[ -n "$worktree_status" ]]; then
		print_error "Refusing to rewrite WIP history with uncommitted changes present."
		return 1
	fi

	local original_head=""
	original_head=$(git rev-parse HEAD 2>/dev/null) || {
		print_error "Cannot record the original branch tip before WIP finalization."
		return 1
	}
	print_info "Finalizing WIP history into one commit relative to ${base_ref} at ${base_oid}..."
	if ! git reset --soft "$base_oid"; then
		print_error "Failed to prepare WIP history for finalization."
		return 1
	fi
	if git diff --cached --quiet 2>/dev/null; then
		print_error "WIP branch has no net changes relative to ${base_ref}."
		git reset --mixed "$original_head" >/dev/null 2>&1 || true
		return 1
	fi
	if ! git commit -m "$commit_message"; then
		print_error "Final WIP squash commit failed; restoring original branch tip."
		if ! git reset --mixed "$original_head" >/dev/null 2>&1; then
			print_error "Failed to restore original branch tip ${original_head}; recover it manually."
		fi
		return 1
	fi
	local final_subject=""
	final_subject=$(git log -1 --format=%s 2>/dev/null || echo "")
	if _is_wip_commit_message "$final_subject"; then
		print_error "Final commit hook produced another WIP subject; restoring original branch tip."
		git reset --mixed "$original_head" >/dev/null 2>&1 || true
		return 1
	fi
	print_info "WIP history finalized as: ${final_subject}"
	return 0
}

# --- Project Validators (t2842) ---
# Closes the worker-CI-failure gap where workers ship code that fails
# project CI checks (Format/Lint/Typecheck) because no pre-push
# validation runs at commit time.
# Decomposed into 5 helpers to stay under the function-complexity gate:
#   _run_project_validators       — orchestrator
#   _validators_should_run        — bypass-path check
#   _detect_node_project          — node-project detection (returns pm)
#   _run_node_auto_fix            — format/lint auto-fix + amend
#   _run_node_typecheck           — typecheck check-only

# Print every file changed between the remote default branch and HEAD.
# The merge-base range keeps classification aligned with the complete PR diff
# even when lifecycle synchronization adds a docs-only commit at HEAD.
_validator_changed_files() {
	local base_branch=""
	local base_ref=""
	base_branch=$(_resolve_remote_default_branch origin) || return 1
	printf -v base_ref 'origin/%s' "$base_branch"
	if ! git diff --name-only "${base_ref}...HEAD" 2>/dev/null; then
		print_error "[validators] cannot inspect changed files relative to ${base_ref}"
		return 1
	fi
	return 0
}

# Returns 0 if validators should run, 1 if any bypass condition applies.
# Prints the bypass reason on info as appropriate.
# Args: $1=skip_hooks (0|1)
_validators_should_run() {
	local skip_hooks="${1:-0}"
	if [[ "$skip_hooks" == "1" ]]; then
		return 1
	fi
	if [[ "${AIDEVOPS_SKIP_PROJECT_VALIDATORS:-0}" == "1" ]]; then
		print_info "[validators] AIDEVOPS_SKIP_PROJECT_VALIDATORS=1, skipping"
		return 1
	fi
	local changed_files=""
	if ! changed_files=$(_validator_changed_files); then
		print_warning "[validators] changed-file classification failed; running validators fail-closed"
		return 0
	fi
	local non_docs_count
	non_docs_count=$(printf '%s\n' "$changed_files" |
		grep -cvE '\.(md|txt|rst)$|^LICENSE|^COPYING|^\.gitignore$|^$' || true)
	# safe_grep_count guard (t2763): zero-match path may emit "0\n0"
	[[ "$non_docs_count" =~ ^[0-9]+$ ]] || non_docs_count=0
	if [[ "$non_docs_count" == "0" ]]; then
		print_info "[validators] docs-only change, skipping"
		return 1
	fi
	return 0
}

# Returns 0 when the PR range changes files covered by Node validators.
# This keeps shell-only commits from failing on missing local Node dependencies
# while preserving fail-closed typecheck behaviour for JS/TS/package changes.
_commit_touches_node_files() {
	local changed_files=""
	if ! changed_files=$(_validator_changed_files); then
		print_warning "[validators] Node changed-file classification failed; running Node validators fail-closed"
		return 0
	fi
	local changed_file
	while IFS= read -r changed_file; do
		case "$changed_file" in
		package.json | package-lock.json | npm-shrinkwrap.json | pnpm-lock.yaml | yarn.lock | bun.lock | bun.lockb)
			return 0
			;;
		*.js | *.jsx | *.mjs | *.cjs | *.ts | *.tsx | *.mts | *.cts)
			return 0
			;;
		*.json | *.jsonc | *.yaml | *.yml)
			case "$changed_file" in
			*.eslintrc.* | eslint.config.* | tsconfig*.json | jsconfig*.json | prettier.config.* | .prettierrc*)
				return 0
				;;
			esac
			;;
		esac
	done <<<"$changed_files"
	return 1
}

# Detect node project type and chosen package manager.
# Sets caller-scope `pm` variable (npm/pnpm/yarn) on success.
# Returns 0 if a node project with relevant scripts is detected, 1 otherwise.
_detect_node_project() {
	if [[ ! -f package.json ]]; then
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		print_warning "[validators] jq not available, cannot inspect package.json — skipping"
		return 1
	fi
	local has_relevant_scripts
	# Only include scripts that are actually executed by the runner.
	# "format" and "lint" (without :fix suffix) are omitted because the runner
	# only attempts format:fix/format:write/prettier:fix and lint:fix — detecting
	# on bare format/lint causes false positives where validators report "passed"
	# without actually running anything (Augment review, PR #20898).
	has_relevant_scripts=$(jq -r '
		.scripts // {} |
		[has("format:fix"),has("format:write"),has("prettier:fix"),
		 has("lint:fix"),
		 has("typecheck"),has("check:types"),has("tsc")] |
		any
	' package.json 2>/dev/null || echo "false")
	if [[ "$has_relevant_scripts" != "true" ]]; then
		return 1
	fi
	pm="npm"
	if [[ -f pnpm-lock.yaml ]]; then
		pm="pnpm"
	elif [[ -f yarn.lock ]]; then
		pm="yarn"
	fi
	if ! command -v "$pm" >/dev/null 2>&1; then
		print_warning "[validators] $pm not available on PATH — skipping (set AIDEVOPS_SKIP_PROJECT_VALIDATORS=1 to silence)"
		return 1
	fi
	return 0
}

# Run auto-fix passes (format then lint). Continue past failures —
# fix scripts may legitimately exit non-zero on un-auto-fixable issues.
# If auto-fix produced changes, amend the HEAD commit.
# Sets caller-scope `fix_changes` to 1 if amend happened, 0 otherwise.
# Args: $1=pm (npm|pnpm|yarn) $2=timeout_secs $3=timeout_available (0|1)
# Returns 0 on success, 1 if amend failed.
_restore_validator_repo_root() {
	local repo_root="$1"
	local phase="$2"

	if [[ -z "$repo_root" || ! -d "$repo_root" ]]; then
		print_error "[validators] repository root disappeared during ${phase}: ${repo_root:-<unknown>}"
		print_error "[validators] refusing to run git amend from a missing working directory"
		return 1
	fi
	if ! cd "$repo_root" 2>/dev/null; then
		print_error "[validators] failed to restore repository root after ${phase}: $repo_root"
		return 1
	fi
	return 0
}

_run_node_auto_fix() {
	local pm="$1"
	local t="$2"
	local timeout_available="${3:-0}"
	local repo_root=""
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P 2>/dev/null || echo "")
	if [[ -z "$repo_root" ]]; then
		print_error "[validators] cannot determine repository root before auto-fix"
		return 1
	fi
	_restore_validator_repo_root "$repo_root" "startup" || return 1
	# Build a timeout prefix array; empty when timeout(1) is not available.
	local -a timeout_prefix=()
	[[ "$timeout_available" == "1" ]] && timeout_prefix=("timeout" "$t")
	fix_changes=0
	local script_name
	for script_name in format:fix format:write prettier:fix; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
			print_info "[validators] $pm run $script_name (auto-fix)"
			"${timeout_prefix[@]}" "$pm" run "$script_name" >/dev/null 2>&1 || true
			_restore_validator_repo_root "$repo_root" "$script_name" || return 1
			break
		fi
	done
	# Lint auto-fix loop pattern matches format for parallel extension.
	# shellcheck disable=SC2043
	for script_name in lint:fix; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
			print_info "[validators] $pm run $script_name (auto-fix)"
			"${timeout_prefix[@]}" "$pm" run "$script_name" >/dev/null 2>&1 || true
			_restore_validator_repo_root "$repo_root" "$script_name" || return 1
			break
		fi
	done
	_restore_validator_repo_root "$repo_root" "auto-fix" || return 1
	if git diff --quiet 2>/dev/null; then
		return 0
	fi
	print_info "[validators] auto-fix produced changes, amending commit"
	# Use git add -u (tracked files only) to avoid staging untracked artifacts
	# that format/lint runners may create (e.g. caches, generated files).
	git add -u
	# --no-verify on amend: avoid recursing into pre-commit territory.
	if ! git commit --amend --no-edit --no-verify >/dev/null 2>&1; then
		print_error "[validators] failed to amend commit with auto-fix changes"
		git status -s 2>&1 | head -10 >&2
		return 1
	fi
	fix_changes=1
	return 0
}

# Run check-only typecheck. Picks first existing script in preference order.
# Captures output for failure diagnosis. Mentor error on failure.
# Args: $1=pm $2=timeout_secs $3=timeout_available (0|1)
# Returns 0 on pass/no-script, 1 on failure.
_run_node_typecheck() {
	local pm="$1"
	local t="$2"
	local timeout_available="${3:-0}"
	# Build a timeout prefix array; empty when timeout(1) is not available.
	local -a timeout_prefix=()
	[[ "$timeout_available" == "1" ]] && timeout_prefix=("timeout" "$t")
	local typecheck_script
	typecheck_script=""
	local script_name
	for script_name in typecheck check:types tsc; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
			typecheck_script="$script_name"
			break
		fi
	done
	if [[ -z "$typecheck_script" ]]; then
		return 0
	fi
	print_info "[validators] $pm run $typecheck_script (check-only)"
	# Separate declaration from mktemp assignment: local masks the exit code of
	# command substitutions, so declare first then assign (Gemini review PR #20898).
	# mktemp without -t: more portable (GNU and BSD mktemp differ on -t semantics).
	local tc_log
	tc_log="$(mktemp)"
	local tc_rc=0
	"${timeout_prefix[@]}" "$pm" run "$typecheck_script" >"$tc_log" 2>&1 || tc_rc=$?
	if [[ "$tc_rc" -eq 0 ]]; then
		rm -f "$tc_log"
		return 0
	fi
	print_error "[validators] $typecheck_script FAILED — code has type errors"
	print_error "  last 20 lines:"
	tail -20 "$tc_log" >&2
	rm -f "$tc_log"
	print_error ""
	print_error "  diagnose:    $pm run $typecheck_script"
	print_error "  fix errors, commit, then re-run: full-loop-helper.sh commit-and-pr ..."
	print_error "  bypass:      full-loop-helper.sh commit-and-pr ... --skip-hooks"
	print_error "               (or AIDEVOPS_SKIP_PROJECT_VALIDATORS=1 env)"
	return 1
}

# Orchestrator. Args: $1=skip_hooks (0|1). Returns 0 on pass/skip, 1 on fail.
_run_project_validators() {
	local skip_hooks="${1:-0}"
	# _validators_should_run returns 0 when validators should run, 1 otherwise.
	if ! _validators_should_run "$skip_hooks"; then
		return 0
	fi
	if ! _commit_touches_node_files; then
		print_info "[validators] no Node/TypeScript files changed, skipping node project validators"
		return 0
	fi
	local pm=""
	if ! _detect_node_project; then
		# Silent skip when no project detected (non-node project = most aidevops paths).
		return 0
	fi
	print_info "[validators] running node project validators ($pm)..."
	local validator_timeout
	validator_timeout="${AIDEVOPS_VALIDATOR_TIMEOUT:-300}"
	# Detect timeout(1) availability once here; sub-functions receive a flag so
	# they don't each re-check (portability: macOS may lack timeout without
	# GNU coreutils; pattern mirrors _rebase_and_push:L941).
	local timeout_available=0
	command -v timeout >/dev/null 2>&1 && timeout_available=1
	local fix_changes=0
	_run_node_auto_fix "$pm" "$validator_timeout" "$timeout_available" || return 1
	_run_node_typecheck "$pm" "$validator_timeout" "$timeout_available" || return 1
	if [[ "$fix_changes" == "1" ]]; then
		print_info "[validators] passed (auto-fix amended into commit)"
	else
		print_info "[validators] passed"
	fi
	return 0
}

# --- Rebase & Push ---

# Detect a shallow git clone and optionally auto-unshallow.
# A shallow clone lacks intermediate commit objects between the clone-depth
# boundary and the remote base tip. Rebasing on a shallow clone fails with
# hundreds of 'add/add' conflicts that masquerade as a force-push to origin.
# Recovery sequence (manual): git fetch --unshallow origin
#
# Behaviour:
#   AIDEVOPS_SHALLOW_UNSHALLOW=0  → warn and return 1 (operator must fix)
#   AIDEVOPS_SHALLOW_UNSHALLOW=1  → attempt git fetch --unshallow and return 0
#   default (unset)               → auto-unshallow (same as =1)
#
# Args: none
# Returns: 0 if clone is full-depth or was successfully unshallowed
#          1 if clone is shallow and auto-unshallow is disabled or failed
_check_and_handle_shallow_clone() {
	local is_shallow=""
	is_shallow=$(git rev-parse --is-shallow-repository 2>/dev/null || echo "false")
	if [[ "$is_shallow" != "true" ]]; then
		return 0
	fi

	local opt="${AIDEVOPS_SHALLOW_UNSHALLOW:-1}"
	if [[ "$opt" == "0" ]]; then
		print_error "Local clone is shallow; rebase requires full history."
		print_error "Run: git fetch --unshallow origin"
		print_error "See .agents/reference/git-hygiene.md for recovery steps."
		return 1
	fi

	print_warning "Shallow clone detected — running git fetch --unshallow origin (set AIDEVOPS_SHALLOW_UNSHALLOW=0 to disable)..."
	if git fetch --unshallow origin 2>/dev/null; then
		print_info "Unshallow complete — proceeding with rebase."
		return 0
	else
		print_error "git fetch --unshallow failed. Rebase would produce add/add conflicts."
		print_error "Resolve manually: git fetch --unshallow origin"
		print_error "See .agents/reference/git-hygiene.md for recovery steps."
		return 1
	fi
}

# Rebase onto the detected origin default branch without mutating the remote.
# Args: $1=branch $2=skip_rebase (0|1, optional, default 0)
# Returns 1 on rebase conflict.
_rebase_for_push() {
	local branch="$1"
	local skip_rebase="${2:-0}"
	local base_branch="" base_ref=""
	base_branch=$(_resolve_remote_default_branch origin) || return 1
	base_ref="origin/${base_branch}"

	if [[ "$skip_rebase" == "1" ]]; then
		print_warning "Skipping rebase by explicit request (--no-rebase); validating clean recovery state."
		_ensure_no_in_progress_integration || return 1
		local ahead=""
		ahead=$(git rev-list --count "${base_ref}..HEAD" 2>/dev/null || echo "0")
		if [[ "$ahead" == "0" ]]; then
			print_error "Refusing --no-rebase push: HEAD is not ahead of ${base_ref}."
			return 1
		fi
	else
		print_info "Rebasing onto ${base_ref}..."
		if ! git fetch origin "$base_branch" --quiet 2>/dev/null; then
			print_warning "git fetch origin ${base_branch} failed — proceeding with current state"
		fi
		# GH#21900: detect shallow clone before rebase to avoid add/add conflict cascade.
		_check_and_handle_shallow_clone || return 1
		if ! git rebase "$base_ref" 2>/dev/null; then
			git rebase --abort 2>/dev/null || true
			print_error "Rebase conflict/abort while rebasing onto ${base_ref}."
			print_error "After inspecting the branch and confirming a PR without rebase is safe, retry:"
			print_error "  full-loop-helper.sh commit-and-pr ... --no-rebase"
			print_error "Do not fall back to raw inline 'gh pr create --body ...'; keep the wrapper path."
			return 1
		fi
	fi

	# t2229 Layer 3: auto-reset .task-counter if rebase picked up a stale value.
	# After rebase, the branch may carry a counter lower than the base branch's
	# current value (race: base advanced between rebase-base and push).
	# Reset to the base branch value to prevent silent regression on merge.
	if [[ -f .task-counter ]]; then
		local branch_counter="" base_counter=""
		branch_counter=$(tr -d '[:space:]' <.task-counter 2>/dev/null) || true
		base_counter=$(git show "${base_ref}:.task-counter" 2>/dev/null | tr -d '[:space:]') || true
		if [[ -n "$branch_counter" && -n "$base_counter" ]] &&
			[[ "$branch_counter" =~ ^[0-9]+$ ]] &&
			[[ "$base_counter" =~ ^[0-9]+$ ]] &&
			[[ "$((10#$branch_counter))" -lt "$((10#$base_counter))" ]]; then
			print_info "Auto-resetting .task-counter: ${branch_counter} → ${base_counter} (base drifted during rebase)"
			printf '%s\n' "$base_counter" >.task-counter
			git add .task-counter
			git commit -m "chore: reset .task-counter to ${base_ref} value (t2229 race prevention)" --no-verify
		fi
	fi
	return 0
}

# Push a branch after all final-diff metadata validation has passed.
# Args: $1=branch $2=skip_hooks (0|1, optional, default 0)
_push_branch() {
	local branch="$1"
	local skip_hooks="${2:-0}"

	print_info "Pushing to origin/${branch}..."

	# GH#20138: 60s push timeout to detect pre-push hook hangs. Pre-push hooks
	# (privacy-guard, complexity-regression) can stall on network I/O or when
	# scanning large repos. If push exceeds 60s, print an actionable advisory
	# and return 1 so the caller can retry with --skip-hooks.
	# Fast-path: both hooks now exit early on doc-only diffs (<1s), so the
	# 60s timeout is a safety net for edge cases, not a normal code path.
	local push_timeout=60
	local _push_args=(-u origin "$branch" --force-with-lease)
	[[ "$skip_hooks" == "1" ]] && _push_args+=(--no-verify)

	local push_rc
	push_rc=0
	if command -v timeout >/dev/null 2>&1; then
		timeout "$push_timeout" git push "${_push_args[@]}" 1>&2 || push_rc=$?
	else
		git push "${_push_args[@]}" 1>&2 || push_rc=$?
	fi

	if [[ "$push_rc" -eq 124 ]]; then
		# timeout(1) exits 124 on SIGTERM
		print_error "Push timed out after ${push_timeout}s — likely a pre-push hook stalling."
		print_error "Diagnose: PRIVACY_GUARD_DEBUG=1 COMPLEXITY_GUARD_DEBUG=1 git push ${_push_args[*]}"
		print_error "Bypass (doc-only diff, no secrets): git push ${_push_args[*]} --no-verify"
		print_error "  or rerun: full-loop-helper.sh commit-and-pr ... --skip-hooks"
		print_error "See reference/pre-push-guards.md for diagnosis steps."
		return 1
	elif [[ "$push_rc" -ne 0 ]]; then
		print_error "Push failed (exit ${push_rc}). Check remote state and retry."
		return 1
	fi
	return 0
}

# Compatibility wrapper for callers that do not need a pre-push validation gap.
_rebase_and_push() {
	local branch="$1"
	local skip_hooks="${2:-0}"
	local skip_rebase="${3:-0}"
	_rebase_for_push "$branch" "$skip_rebase" || return 1
	_push_branch "$branch" "$skip_hooks" || return 1
	return 0
}

# --- PR Helpers ---

# t2242: Check if a given issue has the parent-task label.
# Modelled on parent-task-keyword-guard.sh:76 _is_parent_task.
# Args: $1=issue_number $2=repo_slug
# Returns: 0 if parent-task/meta label present, 1 if not, 2 on gh failure
_issue_has_parent_task_label() {
	local issue_number="$1"
	local repo_slug="$2"

	local labels_json=""
	local gh_rc=0
	labels_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels 2>/dev/null) || gh_rc=$?

	if [[ "$gh_rc" -ne 0 || -z "$labels_json" ]]; then
		# gh API failure — cannot determine. Return 2 (uncertain).
		return 2
	fi

	local hit=""
	hit=$(printf '%s' "$labels_json" |
		jq -r '(.labels // [])[].name | select(. == "parent-task" or . == "meta")' | head -n 1 || true)

	if [[ -n "$hit" ]]; then
		return 0
	fi
	return 1
}

# Build the PR body string and print it to stdout.
# Arguments: issue_number, summary_what, summary_testing, files_changed,
#            sig_footer, closing_keyword (default: Resolves), requested_risk,
#            requested_testing_level, base_ref
_build_pr_body() {
	local issue_number="$1" summary_what="$2" summary_testing="$3"
	local files_changed="$4" sig_footer="$5"
	local closing_keyword="${6:-Resolves}"
	local requested_risk="${7:-}"
	local requested_testing_level="${8:-}"
	local base_ref="${9:-}"
	local runtime_risk=""
	local testing_level=""

	runtime_risk=$(_derive_runtime_risk "$requested_risk" "$files_changed" "$summary_what" "$base_ref") || return 1
	testing_level=$(_resolve_runtime_testing_level "$runtime_risk" "$requested_testing_level" "$summary_testing") || return 1

	printf '%s\n' "## Summary

${summary_what:-Implementation for issue #${issue_number}.}

## Files Changed

${files_changed:-See diff}

## Runtime Testing

- **Risk level:** ${runtime_risk}
- **Verification:** ${testing_level} — ${summary_testing:-no additional evidence supplied}

${closing_keyword} #${issue_number}

${sig_footer}"
	return 0
}

# --- Worker Claim Validation ---

# t1955: Validate that this worker's dispatch claim is still active before
# creating a PR. Prevents orphan PRs from workers whose assignment was
# stale-recovered while they were still working.
#
# Checks:
#   1. Issue comments for a WORKER_SUPERSEDED marker naming this runner
#   2. Issue assignee — if reassigned to another runner, we've been replaced
#
# Only runs in headless mode (interactive sessions don't go through dispatch).
# Non-fatal in interactive mode — always returns 0.
# In headless mode: returns 0 if claim is valid, 1 if superseded.
#
# Arguments: $1 = issue_number, $2 = repo slug
_validate_worker_claim() {
	local issue_number="$1"
	local repo="$2"

	# Skip in interactive mode — no dispatch claim to validate
	if [[ "${HEADLESS:-false}" != "true" && "${FULL_LOOP_HEADLESS:-}" != "true" ]]; then
		return 0
	fi

	# Skip if no issue number (shouldn't happen, but defensive)
	if [[ -z "$issue_number" || ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 0
	fi

	# Determine this runner's login
	local self_login=""
	self_login=$(gh api user --jq '.login' 2>/dev/null) || self_login=""
	if [[ -z "$self_login" ]]; then
		# Can't determine identity — proceed (fail-open)
		print_warning "Cannot determine runner login for claim validation — proceeding"
		return 0
	fi

	# Check for WORKER_SUPERSEDED marker in recent comments
	local comments_json=""
	comments_json=$(gh api "repos/${repo}/issues/${issue_number}/comments" \
		--jq '[.[] | select(.body | test("WORKER_SUPERSEDED")) | {body: .body, created_at: .created_at}] | sort_by(.created_at) | reverse | first // empty' \
		2>/dev/null) || comments_json=""

	if [[ -n "$comments_json" ]]; then
		local superseded_runners=""
		superseded_runners=$(printf '%s' "$comments_json" | jq -r '.body' 2>/dev/null |
			grep -oE 'WORKER_SUPERSEDED runners=[^ ]*' |
			sed 's/WORKER_SUPERSEDED runners=//' || echo "")

		if [[ -n "$superseded_runners" && ",$superseded_runners," == *",$self_login,"* ]]; then
			# This runner was explicitly superseded — check if we've been re-assigned since
			local current_assignees=""
			current_assignees=$(gh issue view "$issue_number" --repo "$repo" \
				--json assignees --jq '[.assignees[].login] | join(",")' 2>/dev/null) || current_assignees=""

			if [[ ",$current_assignees," != *",$self_login,"* ]]; then
				print_warning "Worker claim superseded: this runner (${self_login}) was stale-recovered on #${issue_number} and not re-assigned — aborting PR creation (t1955)"
				return 1
			fi
			# Re-assigned back to us (e.g., re-dispatched) — proceed
		fi
	fi

	# Check current assignee — if assigned to someone else, we've been replaced
	local current_assignees=""
	current_assignees=$(gh issue view "$issue_number" --repo "$repo" \
		--json assignees --jq '[.assignees[].login] | join(",")' 2>/dev/null) || current_assignees=""

	if [[ -n "$current_assignees" && ",$current_assignees," != *",$self_login,"* ]]; then
		print_warning "Worker claim invalid: #${issue_number} is assigned to ${current_assignees}, not ${self_login} — aborting PR creation (t1955)"
		return 1
	fi

	return 0
}

# --- PR Title Composition ---

# _derive_pr_title_prefix: choose tNNN (preferred) or GH#NNN (fallback) for
# the auto-derived PR title, based on whether TODO.md has an entry whose
# ref:GH# tag matches the issue number.
#
# Why (t2720): issue-sync.yml's PR-merge job auto-completes TODO entries by
# extracting a task_id from the merged PR title (regex anchored on ^tNNN).
# When commit-and-pr falls back to "GH#NNN:" titles, the extractor returns
# empty and the TODO line is silently left on `[ ]` even though the PR
# merged and SYNC_PAT is present. Preferring tNNN closes that gap.
#
# Args:
#   $1 - issue_number (required; empty yields "GH#" fallback)
#   $2 - todo_file (optional; defaults to <repo-root>/TODO.md)
# Outputs:
#   tNNN     when TODO.md has a matching entry
#   GH#NNN   otherwise (missing file, no match, or unset issue number)
# Returns: 0 always (callers inline the stdout).
_derive_pr_title_prefix() {
	local issue_number="${1:-}"
	local todo_file="${2:-}"

	if [[ -z "$issue_number" ]]; then
		printf 'GH#\n'
		return 0
	fi

	if [[ -z "$todo_file" ]]; then
		local repo_root=""
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
		if [[ -n "$repo_root" ]]; then
			todo_file="${repo_root}/TODO.md"
		fi
	fi

	if [[ -z "$todo_file" || ! -f "$todo_file" ]]; then
		printf 'GH#%s\n' "$issue_number"
		return 0
	fi

	# Match "- [ ] tNNN ... ref:GH#<issue_number>" with a non-digit or EOL
	# boundary after the number so ref:GH#123 doesn't match ref:GH#12345.
	local task_id=""
	task_id=$(grep -E "^- \[[ x]\] t[0-9]+ .*ref:GH#${issue_number}([^0-9]|\$)" "$todo_file" 2>/dev/null |
		head -1 |
		grep -oE '^- \[[ x]\] t[0-9]+' |
		grep -oE 't[0-9]+$' ||
		true)

	if [[ -n "$task_id" ]]; then
		printf '%s\n' "$task_id"
	else
		printf 'GH#%s\n' "$issue_number"
	fi
	return 0
}

# _compose_pr_title: idempotently compose the auto-derived PR title.
#
# Why (t2825/RC3): when commit_message already starts with a task-ID prefix
# (tNNN: or GH#NNN:), return it verbatim instead of prepending another one.
# Canonical failure: PR #20817 was created with title
# "t2799: t2799: split RATE_LIMIT_PATTERNS..." because an interactive
# `commit-and-pr --message "t2799: ..."` call unconditionally prepended
# another tNNN: via _derive_pr_title_prefix. This guard makes the
# auto-derive path idempotent so callers can safely include a prefix in
# the commit message without producing a doubled title.
#
# Prefix validation (GH#20858): when commit_message already has a prefix,
# verify it matches the canonical prefix for issue_number. A mismatched
# prefix (e.g. "t999: ..." for issue that maps to t456) silently breaks
# TODO auto-completion (issue-sync regex anchored on ^tNNN) and attribution.
# When a mismatch is detected, the canonical prefix is substituted and a
# warning is emitted to stderr. Pass-through is preserved when issue_number
# is empty (can't validate) or when the prefix already matches.
#
# Args:
#   $1 - issue_number
#   $2 - commit_message
#   $3 - todo_file (optional; passed through to _derive_pr_title_prefix)
# Outputs:
#   commit_message (verbatim) when it already has a correct tNNN: or GH#NNN: prefix
#   <canonical_prefix>: <body> when prefix is present but mismatched
#   <derived_prefix>: <commit_message> when no prefix is present
# Returns: 0 always.
_compose_pr_title() {
	local issue_number="${1:-}"
	local commit_message="${2:-}"
	local todo_file="${3:-}"

	if [[ "$commit_message" =~ ^(t[0-9]+|GH#[0-9]+): ]]; then
		local existing_prefix="${BASH_REMATCH[1]}"
		# Skip validation when issue_number is unknown — cannot derive canonical.
		if [[ -z "$issue_number" ]]; then
			printf '%s\n' "$commit_message"
			return 0
		fi
		local canonical_prefix=""
		canonical_prefix="$(_derive_pr_title_prefix "$issue_number" "$todo_file")"
		if [[ "$existing_prefix" == "$canonical_prefix" ]]; then
			printf '%s\n' "$commit_message"
		else
			# Strip the mismatched prefix (everything up to and including the first ": ")
			# and substitute the canonical one so issue-sync auto-completion works.
			local body="${commit_message#*: }"
			print_warning "_compose_pr_title: prefix mismatch — commit has '${existing_prefix}:' but issue #${issue_number} maps to '${canonical_prefix}:'. Using canonical prefix."
			printf '%s: %s\n' "$canonical_prefix" "$body"
		fi
		return 0
	fi

	printf '%s: %s\n' "$(_derive_pr_title_prefix "$issue_number" "$todo_file")" "$commit_message"
	return 0
}

# --- PR Creation ---

# Verify that a PR has exactly one origin label and that it is the expected
# immutable session origin. REST readback is deliberate: a successful mutation
# exit code is not proof that GitHub reached the required postcondition.
# Arguments: PR number, repository slug, expected origin name (without prefix).
# Returns: 0=verified, 2=missing/wrong/dual/unavailable origin labels.
_verify_pr_origin_label() {
	local pr_number="$1"
	local repo="$2"
	local origin_name="$3"
	local origin_labels=""
	origin_labels=$(_gh_with_timeout read gh api "repos/${repo}/issues/${pr_number}" \
		--jq '[.labels[].name | select(startswith("origin:"))]' 2>/dev/null) || origin_labels="[]"
	if printf '%s' "$origin_labels" |
		jq -e --arg expected "origin:${origin_name}" \
			'length == 1 and .[0] == $expected' >/dev/null 2>&1; then
		return 0
	fi
	return 2
}

# Reconcile and verify the immutable origin postcondition while retaining a
# bounded, non-secret failure classification for operators. The caller keeps
# authority over origin_name; gh_create_pr remains the sole creation injector.
# Arguments: PR number, repository slug, expected origin name (without prefix).
_reconcile_pr_origin_label() {
	local pr_number="$1"
	local repo="$2"
	local origin_name="$3"
	local origin_error=""
	origin_error=$(mktemp) || return 1
	# set_origin_label may print the PR URL after a successful REST mutation.
	# _create_pr is a machine-output function, so keep that status off stdout.
	if ! set_origin_label "$pr_number" "$repo" "$origin_name" --pr >/dev/null 2>"$origin_error"; then
		local failure_kind="GitHub label write failed"
		if grep -qiE 'permission|forbidden|Resource not accessible|HTTP 403' "$origin_error" 2>/dev/null; then
			failure_kind="credential lacks PR label permission"
		elif grep -qiE 'rate limit|rateLimitExceeded|HTTP 429' "$origin_error" 2>/dev/null; then
			failure_kind="GitHub API rate limited the label write"
		fi
		rm -f "$origin_error"
		print_error "Could not apply origin:${origin_name} to PR #${pr_number}: ${failure_kind}; retry commit-and-pr after GitHub writes recover"
		return 1
	fi
	rm -f "$origin_error"

	local verify_rc=0
	_verify_pr_origin_label "$pr_number" "$repo" "$origin_name" || verify_rc=$?
	case "$verify_rc" in
	0) return 0 ;;
	*)
		print_error "PR #${pr_number} did not reach the exact origin:${origin_name} postcondition; retry commit-and-pr to reconcile unavailable, missing, wrong, or dual origin labels"
		return 1
		;;
	esac
}

# Create the PR and print the PR number to stdout.
# Arguments: repo, pr_title, pr_body, origin_label; extra_labels passed as remaining args.
# Returns 1 on failure.
# t2115: Uses gh_create_pr wrapper (shared-constants.sh) for origin label + signature auto-append.
# t2767: Implements partial-success recovery — when gh_create_pr exits non-zero but a PR
# already exists for the current branch (GitHub created it but a follow-up update failed),
# we recover and continue instead of bailing out.
# GH#26045: After extracting the PR number, verify/re-apply the current session
# origin label via set_origin_label so recovered partial-success PRs cannot remain
# unlabeled and unroutable by pulse CI/review repair workers.
_create_pr() {
	local repo="$1" pr_title="$2" pr_body="$3" origin_label="$4"
	shift 4
	local -a extra_labels=("$@")

	print_info "Creating PR..."
	local pr_url="" pr_error="" rc=0
	# t2115/t3088: gh_create_pr auto-appends origin label and signature footer.
	# Previously we passed --label "$origin_label" here too, with the comment
	# "GitHub deduplicates". That claim is FALSE for non-identical labels: when
	# this caller's $origin_label disagreed with gh_create_pr's session-detected
	# label (env-var divergence — see full-loop-helper.sh t3088 fix), GitHub
	# applied BOTH labels, producing the t2200 mutual-exclusion violation.
	# Canonical failure: PR #21825. Origin label is now injected at creation by
	# gh_create_pr, via session_origin_label(), then reconciled below after the
	# PR number is known to cover partial-success recovery gaps (GH#26045).
	local -a pr_cmd=(gh_create_pr --repo "$repo" --title "$pr_title" --body "$pr_body")
	for lbl in "${extra_labels[@]+"${extra_labels[@]}"}"; do
		pr_cmd+=(--label "$lbl")
	done

	pr_error=$(mktemp -t aidevops-pr-create-error.XXXXXX) || return 1
	pr_url=$("${pr_cmd[@]}" 2>"$pr_error") || rc=$?

	if [[ $rc -ne 0 ]]; then
		# t2767: Partial-success recovery.
		# gh pr create (via gh_create_pr) can return non-zero even when GitHub already
		# created the PR — this happens when a follow-up GraphQL mutation (body update,
		# label application) succeeds on GitHub's backend but the subsequent API response
		# fails with a transient error (e.g. "Something went wrong while executing your query").
		# Before treating this as a hard failure, check whether the PR now exists.
		local current_branch="" recovered_url=""
		current_branch=$(git branch --show-current 2>/dev/null || echo "")
		recovered_url=$(_gh_recover_pr_if_exists "$current_branch" "$repo" 2>/dev/null || echo "")
		if [[ -n "$recovered_url" ]]; then
			print_info "PR creation command returned non-zero but PR exists — recovering (t2767): ${recovered_url}"
			pr_url="$recovered_url"
		else
			print_error "PR creation failed: $(<"$pr_error")"
			rm -f "$pr_error"
			return 1
		fi
	fi
	rm -f "$pr_error"

	local pr_number=""
	local pr_candidates=""
	pr_candidates=$(printf '%s\n' "$pr_url" | grep -oE 'github\.com/[^[:space:]]+/[^[:space:]]+/pull/[0-9]+' | grep -oE '[0-9]+$' || true)
	pr_number="${pr_candidates##*$'\n'}"
	if [[ -z "$pr_number" ]]; then
		pr_candidates=$(printf '%s\n' "$pr_url" | grep -oE '[0-9]+$' || true)
		pr_number="${pr_candidates##*$'\n'}"
	fi
	if [[ -z "$pr_number" ]]; then
		print_error "Could not extract PR number from: ${pr_url}"
		return 1
	fi

	local origin_name="${origin_label#origin:}"
	case "$origin_name" in
	interactive | worker | worker-takeover) ;;
	*)
		print_error "Could not normalize origin label '${origin_label}' for PR #${pr_number}"
		return 1
		;;
	esac
	_reconcile_pr_origin_label "$pr_number" "$repo" "$origin_name" || return 1

	print_success "PR #${pr_number} created: ${pr_url}"
	printf '%s\n' "$pr_number"
	return 0
}

# --- Merge Summary ---

# Post the MERGE_SUMMARY comment on the PR (full-loop step 4.2.1).
# Arguments: pr_number, repo, issue_number, summary_what, files_changed,
#            summary_testing, summary_decisions
# t2767: Idempotent — skips posting if the canonical MERGE_SUMMARY comment already exists.
# This handles the partial-success recovery case where commit-and-pr was
# interrupted after posting the comment but before returning the PR number.
_post_merge_summary() {
	local pr_number="$1" repo="$2" issue_number="$3" summary_what="$4"
	local files_changed="$5" summary_testing="$6" summary_decisions="$7"

	# t2767/GH#26608: Check if the canonical MERGE_SUMMARY comment already exists before posting.
	# Uses PR timeline comments endpoint (issues endpoint covers PR comments).
	# Counter safety: validate result is a number before comparing (t2763).
	local _existing_count=0
	local _tmp_count=""
	if ! _tmp_count=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
		--jq '[.[] | select(.body | test("<!-- MERGE_SUMMARY -->"))] | length'); then
		print_error "Could not verify existing merge summary comments on PR #${pr_number}; refusing a potentially duplicate post"
		return 1
	fi
	if [[ ! "$_tmp_count" =~ ^[0-9]+$ ]]; then
		print_error "Invalid merge summary count for PR #${pr_number}: ${_tmp_count:-empty}"
		return 1
	fi
	_existing_count="$_tmp_count"
	if [[ "$_existing_count" -eq 1 ]]; then
		print_info "Merge summary comment already exists on PR #${pr_number} — skipping duplicate (t2767)"
		return 0
	fi
	if [[ "$_existing_count" -gt 1 ]]; then
		print_error "PR #${pr_number} has ${_existing_count} canonical merge summary comments; expected exactly one"
		return 1
	fi

	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local merge_summary_file=""
	if ! mkdir -p "$temp_root"; then
		print_error "Could not create merge summary workspace: ${temp_root}"
		return 1
	fi
	if ! merge_summary_file=$(mktemp "${temp_root}/aidevops-merge-summary.XXXXXX"); then
		print_error "Could not create merge summary body file in ${temp_root}"
		return 1
	fi
	if ! printf '%s\n' "<!-- MERGE_SUMMARY -->
## Completion Summary

- **What**: ${summary_what:-Implementation for issue #${issue_number}}
- **Issue**: #${issue_number}
- **Files changed**: ${files_changed:-see diff}
- **Testing**: ${summary_testing:-shellcheck clean, self-assessed}
- **Key decisions**: ${summary_decisions:-none}" >"$merge_summary_file"; then
		print_error "Could not write merge summary body file for PR #${pr_number}"
		rm -f "$merge_summary_file"
		return 1
	fi

	# gh_pr_comment signs a private copy of --body-file before posting. Keep
	# stderr visible so policy or GitHub failures retain actionable diagnostics.
	if ! gh_pr_comment "$pr_number" --repo "$repo" --body-file "$merge_summary_file" >/dev/null; then
		print_error "Failed to post signed merge summary comment on PR #${pr_number}"
		rm -f "$merge_summary_file"
		return 1
	fi
	rm -f "$merge_summary_file"

	_tmp_count=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
		--jq '[.[] | select(.body | test("<!-- MERGE_SUMMARY -->"))] | length') || {
		print_error "Merge summary posted on PR #${pr_number}, but verification failed"
		return 1
	}
	if [[ "$_tmp_count" != "1" ]]; then
		print_error "Merge summary postcondition failed on PR #${pr_number}: expected 1 canonical comment, found ${_tmp_count:-unknown}"
		return 1
	fi
	print_success "Signed merge summary comment posted and verified on PR #${pr_number}"
	return 0
}

# --- Issue Labeling ---

# Label the linked issue as in-review + self-assign, removing all sibling
# status labels (t2033). Defence-in-depth for t2056/t2110: even if the
# interactive-session-helper.sh claim was skipped or failed, the PR-open
# path ensures the assignee is set — preventing the status:in-review +
# zero-assignees degraded state that breaks dispatch dedup.
# Arguments: issue_number, repo
_label_issue_in_review() {
	local issue_number="$1" repo="$2"
	local review_status="in-review"

	local issue_state=""
	issue_state=$(gh issue view "$issue_number" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
	if [[ "$issue_state" == "OPEN" ]]; then
		# Resolve the current gh user for self-assignment (best-effort)
		local current_user=""
		current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
		if [[ -n "$current_user" && "$current_user" != "null" ]]; then
			set_issue_status "$issue_number" "$repo" "$review_status" \
				--add-assignee "$current_user" >/dev/null 2>&1 || true
		else
			set_issue_status "$issue_number" "$repo" "$review_status" >/dev/null 2>&1 || true
		fi
	fi
	return 0
}

# Label the newly opened PR as in-review, removing stale status:available that
# can be inherited from issue-style label operations on PR issues.
# Arguments: pr_number, repo
_label_pr_in_review() {
	local pr_number="$1" repo="$2"
	local review_status="in-review"

	if [[ -z "$pr_number" || -z "$repo" ]]; then
		return 0
	fi
	set_issue_status "$pr_number" "$repo" "$review_status" >/dev/null 2>&1 || true
	return 0
}
