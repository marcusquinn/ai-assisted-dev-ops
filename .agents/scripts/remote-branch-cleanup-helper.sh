#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Audit and optionally delete stale remote branches for the current repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./worktree-paths.sh
source "${SCRIPT_DIR}/worktree-paths.sh"

REPO_PATH="${PWD}"
REMOTE_NAME="origin"
APPLY=0
INCLUDE_CLOSED_PR=0
SKIP_FETCH=0
DELETE_TRANSPORT_WORKTREE=""
DELETE_FAILURES=0

usage() {
	cat <<'EOF'
Usage: remote-branch-cleanup-helper.sh [scan] [options]

Audits stale remote branches and optionally deletes only branches proven safe.
Default mode is dry-run.

Options:
  --repo PATH           Repository path (default: current directory)
  --remote NAME         Remote to audit (default: origin)
  --apply, --delete     Delete safe candidates (default: dry-run)
  --include-closed-pr   Treat closed-without-merge PR branches as safe candidates
  --skip-fetch          Do not fetch/prune before scanning (tests/offline only)
  -h, --help            Show this help

Examples:
  aidevops cleanup remote-branches
  aidevops cleanup remote-branches --apply
  aidevops cleanup branches --repo ~/Git/aidevops --remote origin
EOF
	return 0
}

parse_args() {
	local arg=""
	while [[ $# -gt 0 ]]; do
		arg="${1:-}"
		case "$arg" in
		scan | remote-branches | branches)
			shift
			;;
		--repo)
			REPO_PATH="${2:-}"
			shift 2
			;;
		--remote)
			REMOTE_NAME="${2:-}"
			shift 2
			;;
		--apply | --delete)
			APPLY=1
			shift
			;;
		--include-closed-pr)
			INCLUDE_CLOSED_PR=1
			shift
			;;
		--skip-fetch)
			SKIP_FETCH=1
			shift
			;;
		-h | --help | help)
			usage
			exit 0
			;;
		*)
			print_error "Unknown argument: $arg"
			usage
			exit 1
			;;
		esac
	done
	return 0
}

repo_git() {
	git -C "$REPO_PATH" "$@"
	return $?
}

default_branch() {
	local branch=""
	branch=$(repo_git symbolic-ref --quiet --short "refs/remotes/${REMOTE_NAME}/HEAD" 2>/dev/null | sed "s|^${REMOTE_NAME}/||") || branch=""
	if [[ -z "$branch" ]]; then
		branch=$(repo_git remote show "$REMOTE_NAME" 2>/dev/null | sed -n 's/^[[:space:]]*HEAD branch: //p' | sed -n '1p') || branch=""
	fi
	[[ -z "$branch" ]] && branch="main"
	printf '%s\n' "$branch"
	return 0
}

remote_branches() {
	repo_git for-each-ref --format='%(refname:short)' "refs/remotes/${REMOTE_NAME}" |
		while IFS= read -r ref; do
			[[ -z "$ref" ]] && continue
			[[ "$ref" == "${REMOTE_NAME}/HEAD" ]] && continue
			printf '%s\n' "${ref#"${REMOTE_NAME}"/}"
		done
	return 0
}

merged_remote_branches() {
	local branch="$1"
	repo_git branch -r --merged "${REMOTE_NAME}/${branch}" 2>/dev/null |
		sed 's/^[*[:space:]]*//' |
		while IFS= read -r ref; do
			[[ -z "$ref" ]] && continue
			[[ "$ref" == "${REMOTE_NAME}/HEAD" ]] && continue
			[[ "$ref" != "${REMOTE_NAME}/"* ]] && continue
			printf '%s\n' "${ref#"${REMOTE_NAME}"/}"
		done
	return 0
}

active_worktree_branches() {
	repo_git worktree list --porcelain 2>/dev/null |
		sed -n 's|^branch refs/heads/||p'
	return 0
}

gh_pr_branches() {
	local state="$1"
	if [[ "${AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH:-0}" == "1" ]]; then
		return 0
	fi
	if ! command -v gh >/dev/null 2>&1; then
		return 0
	fi

	local slug=""
	local api_state=""
	local jq_filter=""
	local page=1
	local page_count=0
	local page_json=""
	slug=$(repo_slug)
	[[ -n "$slug" ]] || return 0
	case "$state" in
	open)
		api_state="open"
		jq_filter='.[].head.ref'
		;;
	merged)
		api_state="closed"
		jq_filter='.[] | select(.merged_at != null) | .head.ref'
		;;
	closed)
		api_state="closed"
		jq_filter='.[] | select(.merged_at == null) | .head.ref'
		;;
	*) return 0 ;;
	esac

	# Preserve the previous 200-PR bound. Unbounded REST pagination can turn a
	# cleanup pass over a mature repository into a full-history API sweep.
	while [[ "$page" -le 2 ]]; do
		page_json=$(AIDEVOPS_GH_ROUTE_DECISION="remote-branch-cleanup-pr-branches-rest" \
			gh api "repos/${slug}/pulls?state=${api_state}&per_page=100&page=${page}" \
			2>/dev/null) || return 0
		page_count=$(printf '%s' "$page_json" | jq -r 'if type == "array" then length else -1 end' 2>/dev/null) || return 0
		[[ "$page_count" =~ ^[0-9]+$ ]] || return 0
		printf '%s' "$page_json" | jq -r "$jq_filter" 2>/dev/null || return 0
		[[ "$page_count" -lt 100 ]] && break
		page=$((page + 1))
	done
	return 0
}

repo_slug() {
	local url slug
	url=$(repo_git remote get-url "$REMOTE_NAME" 2>/dev/null || true)
	slug="$url"
	slug="${slug#git@github.com:}"
	slug="${slug#https://github.com/}"
	slug="${slug%.git}"
	printf '%s\n' "$slug"
	return 0
}

contains_line() {
	local needle="$1"
	local haystack="$2"
	[[ $'\n'"$haystack"$'\n' == *$'\n'"$needle"$'\n'* ]]
	return $?
}

is_protected_branch() {
	local branch="$1"
	local default="$2"
	case "$branch" in
	"$default" | main | master | develop | development | staging | production | release | gh-pages)
		return 0
		;;
	esac
	return 1
}

print_candidate() {
	local action="$1"
	local branch="$2"
	local reason="$3"
	printf '%-10s %-55s %s\n' "$action" "$branch" "$reason"
	return 0
}

cleanup_delete_transport() {
	local worktree="$DELETE_TRANSPORT_WORKTREE"
	[[ -n "$worktree" ]] || return 0
	if repo_git worktree remove --force "$worktree" >/dev/null 2>&1; then
		DELETE_TRANSPORT_WORKTREE=""
		return 0
	fi
	print_warning "Unable to remove remote-branch cleanup transport worktree: $worktree"
	return 1
}

prepare_delete_transport() {
	local worktree=""
	[[ -z "$DELETE_TRANSPORT_WORKTREE" ]] || return 0
	worktree=$(aidevops_generate_worktree_path "$REPO_PATH" "remote-branch-cleanup-$$") || {
		print_error "Unable to resolve the remote-branch cleanup transport path"
		return 1
	}
	if [[ -e "$worktree" || -L "$worktree" ]]; then
		print_error "Remote-branch cleanup transport path already exists: $worktree"
		return 1
	fi
	DELETE_TRANSPORT_WORKTREE="$worktree"
	if ! repo_git worktree add --detach "$worktree" HEAD >/dev/null 2>&1; then
		DELETE_TRANSPORT_WORKTREE=""
		print_error "Unable to create an isolated linked worktree for remote-ref deletion"
		return 1
	fi
	return 0
}

delete_transport_git() {
	local worktree="$DELETE_TRANSPORT_WORKTREE"
	[[ -n "$worktree" ]] || return 1
	git -C "$worktree" "$@"
	return $?
}

record_delete_failure() {
	local branch="$1"
	local reason="$2"
	DELETE_FAILURES=$((DELETE_FAILURES + 1))
	print_candidate "failed" "$branch" "$reason"
	return 0
}

delete_branch() {
	local branch="$1"
	local expected_sha=""
	local remote_output=""
	local remote_sha=""
	local verify_rc=0

	if ! repo_git check-ref-format --branch "$branch" >/dev/null 2>&1; then
		record_delete_failure "$branch" "invalid branch ref"
		return 0
	fi
	expected_sha=$(repo_git rev-parse --verify "refs/remotes/${REMOTE_NAME}/${branch}" 2>/dev/null) || expected_sha=""
	if [[ -z "$expected_sha" ]]; then
		record_delete_failure "$branch" "unable to resolve audited remote-tracking ref"
		return 0
	fi
	if ! prepare_delete_transport; then
		record_delete_failure "$branch" "isolated deletion transport unavailable"
		return 0
	fi
	if ! remote_output=$(delete_transport_git ls-remote --heads "$REMOTE_NAME" "refs/heads/${branch}" 2>/dev/null); then
		record_delete_failure "$branch" "unable to verify remote ref before deletion"
		return 0
	fi
	if [[ -z "$remote_output" ]]; then
		print_candidate "deleted" "$branch" "remote absence verified"
		return 0
	fi
	remote_sha="${remote_output%%[[:space:]]*}"
	if [[ "$remote_sha" != "$expected_sha" ]]; then
		record_delete_failure "$branch" "remote ref changed after safety scan"
		return 0
	fi
	if ! delete_transport_git push \
		"--force-with-lease=refs/heads/${branch}:${expected_sha}" \
		"$REMOTE_NAME" ":refs/heads/${branch}" >/dev/null 2>&1; then
		record_delete_failure "$branch" "lease-bound remote deletion failed"
		return 0
	fi
	if remote_output=$(delete_transport_git ls-remote --exit-code --heads "$REMOTE_NAME" "refs/heads/${branch}" 2>/dev/null); then
		verify_rc=0
	else
		verify_rc=$?
	fi
	case "$verify_rc" in
	2)
		print_candidate "deleted" "$branch" "remote absence verified"
		;;
	0)
		record_delete_failure "$branch" "remote ref still present after deletion"
		;;
	*)
		record_delete_failure "$branch" "remote absence verification failed"
		;;
	esac
	return 0
}

print_sync() {
	local action="$1"
	local branch="$2"
	local reason="$3"
	printf '%-10s %-55s %s\n' "$action" "$branch" "$reason"
	return 0
}

sync_default_branch_after_cleanup() {
	local default="$1"
	local current upstream expected local_sha remote_sha merge_base

	printf '\nDefault branch sync check:\n'
	current=$(repo_git symbolic-ref --quiet --short HEAD 2>/dev/null) || current=""
	if [[ -z "$current" ]]; then
		print_sync "skip-sync" "$default" "detached HEAD"
		return 0
	fi
	if [[ "$current" != "$default" ]]; then
		print_sync "skip-sync" "$current" "not default branch (${default})"
		return 0
	fi

	upstream=$(repo_git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream=""
	expected="${REMOTE_NAME}/${default}"
	if [[ -z "$upstream" ]]; then
		print_sync "skip-sync" "$current" "no upstream configured"
		return 0
	fi
	if [[ "$upstream" != "$expected" ]]; then
		print_sync "skip-sync" "$current" "upstream is ${upstream}, expected ${expected}"
		return 0
	fi
	if ! repo_git diff --quiet || ! repo_git diff --cached --quiet; then
		print_sync "skip-sync" "$current" "worktree or index is dirty"
		return 0
	fi

	local_sha=$(repo_git rev-parse HEAD 2>/dev/null) || local_sha=""
	remote_sha=$(repo_git rev-parse "$upstream" 2>/dev/null) || remote_sha=""
	if [[ -z "$local_sha" || -z "$remote_sha" ]]; then
		print_sync "skip-sync" "$current" "unable to resolve local or upstream SHA"
		return 0
	fi
	if [[ "$local_sha" == "$remote_sha" ]]; then
		print_sync "up-to-date" "$current" "matches ${upstream}"
		return 0
	fi
	merge_base=$(repo_git merge-base HEAD "$upstream" 2>/dev/null) || merge_base=""
	if [[ -z "$merge_base" ]]; then
		print_sync "skip-sync" "$current" "no merge-base with ${upstream}"
		return 0
	fi
	if [[ "$remote_sha" == "$merge_base" ]]; then
		print_sync "skip-sync" "$current" "local branch is ahead of ${upstream}"
		return 0
	fi
	if [[ "$local_sha" != "$merge_base" ]]; then
		print_sync "skip-sync" "$current" "local branch has diverged from ${upstream}"
		return 0
	fi

	if [[ "$APPLY" != "1" ]]; then
		print_sync "would-ff" "$current" "behind ${upstream}; dry-run only"
		return 0
	fi
	if repo_git merge --ff-only "$upstream" >/dev/null 2>&1; then
		remote_sha=$(repo_git rev-parse --short HEAD 2>/dev/null) || remote_sha="unknown"
		print_sync "fast-fwd" "$current" "updated to ${remote_sha} from ${upstream}"
	else
		print_sync "failed" "$current" "git merge --ff-only ${upstream} failed"
	fi
	return 0
}

scan_branches() {
	if [[ ! -d "$REPO_PATH/.git" && ! -f "$REPO_PATH/.git" ]]; then
		print_error "Not a git worktree: $REPO_PATH"
		return 1
	fi

	if [[ "$SKIP_FETCH" != "1" ]]; then
		repo_git fetch --prune "$REMOTE_NAME" >/dev/null 2>&1 || print_warning "Fetch/prune failed; continuing with local remote refs"
	fi

	local default merged active open_prs merged_prs closed_prs branch reason safe_count skip_count review_count mode skip_action dash_label
	default=$(default_branch)
	merged=$(merged_remote_branches "$default")
	active=$(active_worktree_branches)
	open_prs=$(gh_pr_branches open)
	merged_prs=$(gh_pr_branches merged)
	closed_prs=""
	if [[ "$INCLUDE_CLOSED_PR" == "1" ]]; then
		closed_prs=$(gh_pr_branches closed)
	fi
	safe_count=0
	skip_count=0
	review_count=0
	mode="dry-run"
	skip_action="skip"
	dash_label="------"
	[[ "$APPLY" == "1" ]] && mode="apply"

	printf 'Remote branch cleanup audit: repo=%s remote=%s default=%s mode=%s\n' "$REPO_PATH" "$REMOTE_NAME" "$default" "$mode"
	printf '%-10s %-55s %s\n' "action" "branch" "reason"
	printf '%-10s %-55s %s\n' "$dash_label" "$dash_label" "$dash_label"

	while IFS= read -r branch; do
		[[ -z "$branch" ]] && continue
		reason=""
		if is_protected_branch "$branch" "$default"; then
			print_candidate "$skip_action" "$branch" "protected/default branch"
			skip_count=$((skip_count + 1))
			continue
		fi
		if contains_line "$branch" "$active"; then
			print_candidate "$skip_action" "$branch" "checked out in a local worktree"
			skip_count=$((skip_count + 1))
			continue
		fi
		if contains_line "$branch" "$open_prs"; then
			print_candidate "$skip_action" "$branch" "open PR exists"
			skip_count=$((skip_count + 1))
			continue
		fi
		if contains_line "$branch" "$merged"; then
			reason="merged to ${default}"
		elif contains_line "$branch" "$merged_prs"; then
			reason="merged PR branch"
		elif contains_line "$branch" "$closed_prs"; then
			reason="closed PR branch (--include-closed-pr)"
		fi

		if [[ -n "$reason" ]]; then
			safe_count=$((safe_count + 1))
			if [[ "$APPLY" == "1" ]]; then
				delete_branch "$branch"
			else
				print_candidate "would-del" "$branch" "$reason"
			fi
		else
			review_count=$((review_count + 1))
			print_candidate "review" "$branch" "unmerged/no closed evidence"
		fi
	done < <(remote_branches)

	printf '\nSummary: safe=%s skipped=%s review=%s\n' "$safe_count" "$skip_count" "$review_count"
	if [[ "$APPLY" != "1" ]]; then
		printf 'Dry-run only. Re-run with --apply to delete safe candidates.\n'
	fi
	sync_default_branch_after_cleanup "$default"
	[[ "$DELETE_FAILURES" -eq 0 ]] || return 1
	return 0
}

main() {
	local scan_rc=0
	local cleanup_rc=0
	parse_args "$@"
	trap 'cleanup_delete_transport >/dev/null 2>&1 || true' EXIT
	scan_branches || scan_rc=$?
	cleanup_delete_transport || cleanup_rc=$?
	trap - EXIT
	[[ "$scan_rc" -eq 0 ]] || return "$scan_rc"
	[[ "$cleanup_rc" -eq 0 ]] || return "$cleanup_rc"
	return 0
}

main "$@"
