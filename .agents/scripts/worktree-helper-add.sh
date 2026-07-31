#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155
# =============================================================================
# Worktree Helper -- Path Utilities + cmd_add Sub-Library
# =============================================================================
# Worktree path resolution, trash/cleanup utilities, branch existence checks,
# remove target resolution, interactive auto-claim, and all cmd_add helpers.
#
# Usage: source "${SCRIPT_DIR}/worktree-helper-add.sh"
#
# Dependencies:
#   - shared-constants.sh (colour vars, print_*, register_worktree,
#     unregister_worktree, check_worktree_owner, is_worktree_owned_by_others,
#     prune_worktree_registry)
#   - worktree-helper-git.sh (get_repo_root, get_repo_name, get_default_branch,
#     branch_exists already defined before this file is sourced)
#   - worktree-helper-integration.sh (localdev_auto_branch,
#     preview_proxy_auto_allocate already defined before this file is sourced)
#   - canonical-guard-helper.sh (is_registered_canonical, optional)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKTREE_ADD_LIB_LOADED:-}" ]] && return 0
_WORKTREE_ADD_LIB_LOADED=1

# GH#22238: node_modules restore is useful for interactive worktrees but can
# saturate CPU when many pulse precreations run concurrently. Serialize the
# copy path and fail open quickly; workers can still install/fallback later if
# dependency restore is skipped during overload.
: "${WORKTREE_NODE_MODULES_RESTORE_ENABLED:=1}"
: "${WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S:=2}"
: "${WORKTREE_NODE_MODULES_RESTORE_MAX_DIRS:=2}"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./task-identity-lib.sh
source "${SCRIPT_DIR}/task-identity-lib.sh"

# --- Worktree Path Utilities ---

# Check if worktree has uncommitted changes (GH#3797)
# Excludes aidevops runtime directories that are safe to discard.
# Returns 0 (true) if changes exist OR if git status fails (safety-first:
# treat unknown state as "has changes" to prevent data loss on cleanup).
worktree_has_changes() {
	local worktree_path="$1"
	if [[ -d "$worktree_path" ]]; then
		local status_output
		# Capture git status; if it fails, treat as "has changes" (safety-first)
		if ! status_output=$(git -C "$worktree_path" status --porcelain 2>&1); then
			return 0
		fi
		local changes
		# Exclude aidevops runtime files: .agents/loop-state/, .agents/tmp/, .DS_Store
		# Use literal '??' (not '\?\?') to match git status untracked prefix.
		# Append '|| true' so the pipeline doesn't fail under pipefail when all lines are filtered.
		changes=$(echo "$status_output" |
			grep -v '^?? \.agents/loop-state/' |
			grep -v '^?? \.agents/tmp/' |
			grep -v '^?? \.agents/$' |
			grep -v '^?? \.DS_Store' |
			head -1 || true)
		[[ -n "$changes" ]]
	else
		return 1
	fi
}

# Move a path to the system trash instead of permanently deleting it.
# Prefers: trash (CLI utility, e.g. installed via Homebrew), gio trash (Linux), rm -rf fallback.
# Args: $1=path to trash
# Returns 0 on success, 1 on failure.
#
# t2559 Layer 2: refuses to trash a path registered as a canonical
# repository in ~/.config/aidevops/repos.json. This is the last-line
# defence against the 2026-04-20 incident where an empty main_worktree_path
# derivation caused cmd_clean to sweep canonical alongside orphan worktrees.
trash_path() {
	local target="$1"
	[[ -z "$target" ]] && return 1
	[[ ! -e "$target" ]] && return 0 # Already gone — not an error

	# t2559: never trash a registered canonical repository, no matter how
	# we got here. Fail-safe: on ambiguity (unresolvable path, malformed
	# repos.json, jq missing) the helper returns 0 for empty candidates
	# and 1 for most other "cannot confirm" cases; only a positive match
	# blocks. See canonical-guard-helper.sh for the full semantics.
	if command -v is_registered_canonical >/dev/null 2>&1; then
		if is_registered_canonical "$target"; then
			echo -e "${RED}REFUSED: '$target' is a registered canonical repository — will not trash${NC}" >&2
			return 1
		fi
	fi

	if command -v trash >/dev/null 2>&1; then
		trash "$target" 2>/dev/null && return 0
	fi
	if command -v gio >/dev/null 2>&1; then
		gio trash "$target" 2>/dev/null && return 0
	fi
	# Fallback: permanent delete
	rm -rf "$target" 2>/dev/null && return 0
	return 1
}

# Generate worktree path from branch name.
# Default pattern: ~/Git/_worktrees/{repo}-{branch-slug}
generate_worktree_path() {
	local branch="$1"
	local repo_root
	repo_root=$(get_repo_root)
	if declare -F aidevops_generate_worktree_path >/dev/null 2>&1; then
		aidevops_generate_worktree_path "$repo_root" "$branch"
		return $?
	fi

	local repo_name slug parent_dir
	repo_name=$(get_repo_name)
	slug=$(echo "$branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
	parent_dir=$(dirname "$repo_root")
	echo "${parent_dir}/${repo_name}-${slug}"
	return 0
}

# Check if branch exists
branch_exists() {
	local branch="$1"
	git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null
}

# Check if worktree exists for branch
worktree_exists_for_branch() {
	local branch="$1"
	get_worktree_path_for_branch "$branch" >/dev/null || return 1
	return 0
}

# Get worktree path for branch
get_worktree_path_for_branch() {
	local branch="$1"
	local porcelain line worktree_path=""
	porcelain=$(git worktree list --porcelain) || return 1

	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		"worktree "*) worktree_path="${line#worktree }" ;;
		"branch refs/heads/"*)
			if [[ "$line" == "branch refs/heads/$branch" && -n "$worktree_path" ]]; then
				printf '%s\n' "$worktree_path"
				return 0
			fi
			;;
		"") worktree_path="" ;;
		esac
	done <<<"$porcelain"

	return 1
}

# --- Remove Helpers ---

# Resolve a remove target (path or branch name) to an absolute worktree path.
# Prints the resolved path on success. Returns 1 with an error message on failure.
_remove_resolve_path() {
	local target="$1"
	local resolved_path

	if [[ -d "$target" ]]; then
		echo "$target"
		return 0
	fi

	if resolved_path=$(get_worktree_path_for_branch "$target"); then
		printf '%s\n' "$resolved_path"
		return 0
	fi

	echo -e "${RED}Error: No worktree found for '$target'${NC}" >&2
	return 1
}

# Print the ownership error block for cmd_remove when another session owns the worktree.
# Args: $1=path_to_remove
_remove_show_owner_error() {
	local path_to_remove="$1"
	local owner_info
	owner_info=$(check_worktree_owner "$path_to_remove")
	local owner_pid owner_session owner_batch owner_task _
	IFS='|' read -r owner_pid owner_session owner_batch owner_task _ <<<"$owner_info"
	echo -e "${RED}Error: Worktree is owned by another active session${NC}"
	echo -e "  Owner PID:     $owner_pid"
	[[ -n "$owner_session" ]] && echo -e "  Session:       $owner_session"
	[[ -n "$owner_batch" ]] && echo -e "  Batch:         $owner_batch"
	[[ -n "$owner_task" ]] && echo -e "  Task:          $owner_task"
	echo ""
	echo "Use --force to override, or wait for the owning session to finish."
	return 0
}

# --- Interactive Auto-Claim ---

# t2057 — interactive issue auto-claim from branch name.
# When cmd_add creates a worktree whose branch encodes an issue number AND
# the session is interactive, call interactive-session-helper.sh claim. The
# helper first verifies maintainer-equivalent repo access; only managed repos
# receive status:in-review + self-assign so the pulse's dispatch-dedup guard
# blocks parallel workers while the interactive session owns the issue.
#
# Branch name patterns accepted:
#   <prefix>/gh<NNN>-<rest>       e.g., bugfix/gh18700-foo
#   <prefix>/t<NNN>-<rest>        e.g., feature/t2057-phase2-wire
#   <prefix>/gh<NNN>_<rest>       (underscore separator)
#   <prefix>/t<NNN>_<rest>
#   <prefix>/auto-*-gh<NNN>       e.g., feature/auto-20260419-061301-gh19803
#
# Issue resolution priority (t2260):
#   1. Explicit --issue NNN arg (highest precedence, unambiguous)
#   2. gh<NNN> from branch name (unambiguous)
#   3. t<NNN> from branch name → ref:GH#NNN in TODO.md entry (structured field)
#
# t2260: brief-body scanning REMOVED — greedy #NNN regex on free-form text
# grabbed historical issue references (e.g. #15114 in a Context section)
# instead of the task's intended issue. Only structured sources are used now.
#
# All failure modes are non-blocking — worktree creation proceeds regardless.
_interactive_session_auto_claim() {
	local branch="$1"
	local worktree_path="$2"
	local explicit_issue="${3:-}" # t2260: --issue NNN takes highest precedence

	# Only engage for interactive sessions — workers handle their own
	# claim flow via dispatch-dedup-helper.sh at dispatch time.
	if [[ -n "${FULL_LOOP_HEADLESS:-}" ]] || [[ -n "${AIDEVOPS_HEADLESS:-}" ]] ||
		[[ -n "${Claude_HEADLESS:-}" ]] || [[ -n "${OPENCODE_HEADLESS:-}" ]] ||
		[[ -n "${GITHUB_ACTIONS:-}" ]]; then
		return 0
	fi
	if [[ "${AIDEVOPS_SESSION_ORIGIN:-}" == "worker" ]]; then
		return 0
	fi
	# Opt-out for scripted bulk worktree operations
	if [[ -n "${AIDEVOPS_SKIP_AUTO_CLAIM:-}" ]]; then
		print_info "AIDEVOPS_SKIP_AUTO_CLAIM set — skipping worktree auto-claim (GH#20146 audit)"
		return 0
	fi

	local issue_num=""

	# t2260: Priority 1 — explicit --issue arg (unambiguous, highest precedence)
	if [[ -n "$explicit_issue" ]]; then
		issue_num="$explicit_issue"
	fi

	# Priority 2 — gh<NNN> from branch name (unambiguous)
	if [[ -z "$issue_num" ]]; then
		if [[ "$branch" =~ /gh([0-9]+)[-_] ]]; then
			issue_num="${BASH_REMATCH[1]}"
		# t2260: also match auto-dispatch branch pattern: auto-*-gh<NNN>
		elif [[ "$branch" =~ -gh([0-9]+)$ ]]; then
			issue_num="${BASH_REMATCH[1]}"
		fi
	fi

	# Priority 3 — t<NNN> from branch → structured ref:GH#NNN in TODO.md
	# t2260: ONLY reads the structured ref:GH#NNN field from the task's own
	# TODO.md line. Does NOT scan brief bodies (too weak — free-form text
	# contains historical issue references that produce false matches).
	if [[ -z "$issue_num" ]]; then
		local task_id=""
		task_id=$(task_identity_extract_first "$branch" || true)
		if [[ -n "$task_id" ]]; then
			local repo_root=""
			repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
			if [[ -n "$repo_root" && -f "$repo_root/TODO.md" ]]; then
				# Match ONLY the structured ref:GH#NNN field on the task's TODO line
				local task_id_ere=""
				task_id_ere=$(task_identity_escape_ere "$task_id") || return 0
				issue_num=$(grep -E "^- \[.\] ${task_id_ere}([[:space:]]|$)" "$repo_root/TODO.md" |
					grep -oE 'ref:GH#[0-9]+' |
					grep -oE '[0-9]+' |
					head -1 || true)
			fi
		fi
	fi

	if [[ -z "$issue_num" ]]; then
		return 0
	fi

	# Resolve the repo slug from the git remote
	local slug=""
	slug=$(git -C "$worktree_path" remote get-url origin 2>/dev/null |
		sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	if [[ -z "$slug" ]]; then
		return 0
	fi

	# Locate the helper. Prefer the deployed copy (runtime source of truth);
	# fall back to the in-repo copy when running from the canonical repo
	# before deploy. Silent on missing helper — the Phase 1 AI rule handles
	# the agent-driven path.
	local helper=""
	if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
	elif [[ -x "${SCRIPT_DIR}/interactive-session-helper.sh" ]]; then
		helper="${SCRIPT_DIR}/interactive-session-helper.sh"
	fi

	if [[ -z "$helper" ]]; then
		return 0
	fi

	echo -e "${BLUE}Checking issue #${issue_num} ownership for interactive session...${NC}"
	"$helper" claim "$issue_num" "$slug" --worktree "$worktree_path" >/dev/null 2>&1 || true
	return 0
}

# --- cmd_add Helpers ---

# Restore gitignored node_modules from the canonical repo into a new worktree.
# Git worktrees only contain tracked files — dirs in .gitignore are missing.
# If .opencode/tool/*.ts imports from node_modules the runtime crashes on
# startup. See pulse-dispatch-worker-launch.sh _dlw_restore_worktree_deps.
_restore_worktree_node_modules_lock_dir() {
	local workspace_dir="${AIDEVOPS_WORKSPACE_DIR:-${HOME}/.aidevops/.agent-workspace}"
	printf '%s\n' "${workspace_dir}/tmp/worktree-node-modules-restore.lock.d"
	return 0
}

_restore_worktree_node_modules_acquire_lock() {
	local lock_dir="$1"
	local timeout_s="${WORKTREE_NODE_MODULES_RESTORE_LOCK_TIMEOUT_S}"
	local elapsed=0
	[[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=2
	mkdir -p "${lock_dir%/*}" 2>/dev/null || return 1
	while ! mkdir "$lock_dir" 2>/dev/null; do
		if [[ -d "$lock_dir" ]]; then
			local lock_mtime now_epoch age_s
			lock_mtime=$(_file_mtime_epoch "$lock_dir")
			now_epoch=$(date +%s)
			age_s=$((now_epoch - lock_mtime))
			if ((age_s > 60)); then
				rmdir "$lock_dir" 2>/dev/null || true
				continue
			fi
		fi
		if ((elapsed >= timeout_s * 10)); then
			return 1
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
	done
	printf '%s\n' "$$" >"${lock_dir}/pid" 2>/dev/null || true
	return 0
}

_restore_worktree_node_modules_release_lock() {
	local lock_dir="$1"
	rm -f "${lock_dir}/pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_restore_worktree_node_modules() {
	local wt_path="$1"
	local repo_root="$2"

	[[ -n "$repo_root" && -d "$wt_path" ]] || return 0
	[[ "$WORKTREE_NODE_MODULES_RESTORE_ENABLED" == "1" ]] || return 0

	local _lock_dir=""
	_lock_dir=$(_restore_worktree_node_modules_lock_dir)
	if ! _restore_worktree_node_modules_acquire_lock "$_lock_dir"; then
		print_warning "Skipping node_modules restore for ${wt_path}: another restore is active"
		return 0
	fi

	local _pkg_file=""
	local _restored=0
	local _max_dirs="$WORKTREE_NODE_MODULES_RESTORE_MAX_DIRS"
	[[ "$_max_dirs" =~ ^[0-9]+$ ]] || _max_dirs=2
	while IFS= read -r _pkg_file; do
		if ((_restored >= _max_dirs)); then
			break
		fi
		local _pdir="" _rel=""
		_pdir=$(dirname "$_pkg_file") || continue
		_rel="${_pdir#"$wt_path"}"
		local _src="${repo_root}${_rel}/node_modules"
		local _dst="${wt_path}${_rel}/node_modules"
		if [[ -d "$_src" && ! -d "$_dst" ]]; then
			# t2889: fast_cp uses APFS clonefile / btrfs reflink CoW where
			# available — sub-second copy on macOS, near-zero disk delta.
			fast_cp "$_src" "$_dst" 2>/dev/null || true
			_restored=$((_restored + 1))
		fi
	done < <(find "$wt_path" -maxdepth 3 -name "package.json" -not -path "*/node_modules/*" 2>/dev/null)
	_restore_worktree_node_modules_release_lock "$_lock_dir"
	return 0
}

# t2885: exclude a fresh worktree from macOS Spotlight + Time Machine.
# Backed by .agents/scripts/worktree-exclusions-helper.sh. Best-effort —
# never blocks worktree creation. Silent on missing helper or non-macOS.
_apply_worktree_exclusions() {
	local wt_path="$1"
	[[ -n "$wt_path" && -d "$wt_path" ]] || return 0

	# Prefer the sibling copy. In an installed framework it is the deployed
	# helper; in a source checkout it preserves the source contract instead of
	# calling a stale helper from a previous deployment.
	local helper=""
	if [[ -x "${SCRIPT_DIR}/worktree-exclusions-helper.sh" ]]; then
		helper="${SCRIPT_DIR}/worktree-exclusions-helper.sh"
	elif [[ -x "${HOME}/.aidevops/agents/scripts/worktree-exclusions-helper.sh" ]]; then
		helper="${HOME}/.aidevops/agents/scripts/worktree-exclusions-helper.sh"
	fi
	[[ -n "$helper" ]] || return 0

	"$helper" apply "$wt_path" >/dev/null 2>&1 || true
	return 0
}

# Print the success banner and editor hints after a worktree is created.
_print_worktree_add_success() {
	local wt_path="$1"
	local branch="$2"

	echo ""
	echo -e "${GREEN}Worktree created successfully!${NC}"
	echo ""
	echo -e "Path: ${BOLD}$wt_path${NC}"
	echo -e "Branch: ${BOLD}$branch${NC}"
	echo ""
	echo "To start working:"
	echo "  cd $wt_path" || exit
	echo ""
	echo "Or open in a new terminal/editor:"
	echo "  code $wt_path        # VS Code"
	echo "  cursor $wt_path      # Cursor"
	echo "  opencode $wt_path    # OpenCode"
	return 0
}

# t2701: Resolve a path to absolute canonical form (resolves symlinks in parent
# via `pwd -P`, handles relative and missing leaf components).
# Prints absolute path on stdout. Always returns 0 — best-effort.
_worktree_resolve_abs_path() {
	local input="$1"
	local parent base abs_parent
	parent="$(dirname -- "$input")"
	base="$(basename -- "$input")"
	if abs_parent="$(cd "$parent" 2>/dev/null && pwd -P)"; then
		if [[ "$base" = "." ]]; then
			printf '%s\n' "$abs_parent"
		else
			printf '%s/%s\n' "${abs_parent%/}" "$base"
		fi
	else
		# Parent does not exist — naive join (best-effort absolute form)
		case "$input" in
		/*) printf '%s\n' "$input" ;;
		*) printf '%s/%s\n' "$(pwd -P)" "$input" ;;
		esac
	fi
	return 0
}

# t2701/t3601: Assert that the requested worktree path follows aidevops
# worktree placement policy: never inside the canonical repo and, by default,
# under the configured central worktree base (`~/Git/_worktrees`). Aborts with a
# mentoring error on containment or sibling/custom path litter.
#
# The helper's `add <branch> [path]` signature does not mirror git's own
# `git worktree add -b <branch> <path> [<base>]` — our second positional is a
# filesystem PATH, not a base branch. Users passing `main` thinking it's a
# base branch silently create a worktree at $CWD/main, nested inside the
# canonical repo (state confusion, cleanup-script blast radius, pull/merge
# inconsistency). This guard rejects that input with a mentoring error.
#
# Env override: AIDEVOPS_WORKTREE_ALLOW_NESTED=1 bypasses all path checks for
# rare legitimate nested fixtures. AIDEVOPS_WORKTREE_ALLOW_CUSTOM_PATH=1 allows
# explicit non-central paths while still rejecting paths inside the repo.
_cmd_add_suggested_central_path() {
	local branch="$1"
	local abs_repo="$2"
	local abs_base="${3:-}"
	local suggested_path=""
	suggested_path=$(generate_worktree_path "$branch" 2>/dev/null || true)
	if [[ -n "$suggested_path" ]]; then
		printf '%s\n' "$suggested_path"
		return 0
	fi

	local repo_name slug parent_dir
	repo_name="$(basename -- "$abs_repo")"
	slug="$(echo "$branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
	if [[ -n "$abs_base" ]]; then
		printf '%s/%s-%s\n' "$abs_base" "$repo_name" "$slug"
		return 0
	fi
	parent_dir="$(dirname -- "$abs_repo")"
	printf '%s/_worktrees/%s-%s\n' "$parent_dir" "$repo_name" "$slug"
	return 0
}

_cmd_add_configured_worktree_base_abs() {
	local configured_base=""
	if declare -F aidevops_worktree_base_dir_configured >/dev/null 2>&1; then
		configured_base=$(aidevops_worktree_base_dir_configured)
	fi
	if [[ -z "$configured_base" ]]; then
		configured_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME:-}/Git/_worktrees}"
	fi
	_worktree_resolve_abs_path "$configured_base"
	return 0
}

_cmd_add_emit_nested_path_error() {
	local path="$1"
	local abs_path="$2"
	local abs_repo="$3"
	local branch="$4"
	local suggested_path=""
	suggested_path=$(_cmd_add_suggested_central_path "$branch" "$abs_repo")
	{
		echo -e "${RED}Error: Worktree path '$path' resolves to '$abs_path',${NC}"
		echo -e "${RED}which is inside the canonical repo working tree ('$abs_repo').${NC}"
		echo ""
		echo "Worktrees must live outside the canonical repo to prevent git state"
		echo "confusion (cleanup scripts, git status ambiguity, pull/merge blast radius)."
		echo ""
		echo "If you meant to branch off 'main' (or another base branch), note that"
		echo "the 'path' argument is a FILESYSTEM PATH, not a base branch. Options:"
		echo ""
		echo "  - Omit [path] for auto-generated central path:"
		echo "      worktree-helper.sh add $branch"
		echo ""
		echo "  - Use the configured central worktree base explicitly:"
		echo "      worktree-helper.sh add $branch $suggested_path"
		echo ""
		echo "The created worktree branches from origin/<default-branch> automatically;"
		echo "use --base <ref> only when a different base is required."
		echo ""
		echo "(Override: AIDEVOPS_WORKTREE_ALLOW_NESTED=1 — use only with a documented"
		echo "reason for a nested worktree.)"
	} >&2
	return 0
}

_cmd_add_emit_noncentral_path_error() {
	local path="$1"
	local abs_path="$2"
	local abs_repo="$3"
	local abs_base="$4"
	local branch="$5"
	local suggested_path=""
	suggested_path=$(_cmd_add_suggested_central_path "$branch" "$abs_repo" "$abs_base")
	{
		echo -e "${RED}Error: Worktree path '$path' resolves to '$abs_path',${NC}"
		echo -e "${RED}which is outside the configured worktree base ('$abs_base').${NC}"
		echo ""
		echo "Durable aidevops worktrees must use one central, backup-excludable"
		echo "directory so cleanup can find them and ~/Git does not accumulate sibling"
		echo "repo/worktree litter. Options:"
		echo ""
		echo "  - Omit [path] for auto-generated central path:"
		echo "      worktree-helper.sh add $branch"
		echo ""
		echo "  - Pass an explicit path under the configured worktree base:"
		echo "      worktree-helper.sh add $branch $suggested_path"
		echo ""
		echo "Configure the base with AIDEVOPS_WORKTREE_BASE_DIR or repos.json"
		echo "worktree_base_dir when you need a different durable location."
		echo ""
		echo "(Override: AIDEVOPS_WORKTREE_ALLOW_CUSTOM_PATH=1 — use only with a"
		echo "documented cleanup owner and retention plan.)"
	} >&2
	return 0
}

_cmd_add_assert_path_outside_repo() {
	local path="$1"
	local branch="$2"

	[[ "${AIDEVOPS_WORKTREE_ALLOW_NESTED:-0}" = "1" ]] && return 0

	local abs_path abs_repo repo_root
	abs_path="$(_worktree_resolve_abs_path "$path")"
	repo_root="$(get_repo_root)"
	[[ -z "$repo_root" ]] && return 0
	abs_repo="$(cd "$repo_root" && pwd -P)"

	if [[ "$abs_path/" == "$abs_repo"/* ]]; then
		_cmd_add_emit_nested_path_error "$path" "$abs_path" "$abs_repo" "$branch"
		return 1
	fi
	[[ "${AIDEVOPS_WORKTREE_ALLOW_CUSTOM_PATH:-0}" = "1" ]] && return 0

	local abs_base=""
	abs_base="$(_cmd_add_configured_worktree_base_abs)"
	case "$abs_path/" in
	"$abs_base"/*) return 0 ;;
	esac
	_cmd_add_emit_noncentral_path_error "$path" "$abs_path" "$abs_repo" "$abs_base" "$branch"
	return 1
}

# Parse cmd_add arguments: positional (branch, path) + optional flags.
# Sets global _ADD_BRANCH, _ADD_PATH, _ADD_ISSUE, _ADD_BASE, and
# _ADD_FRESH_ON_COLLISION. Returns 1 on parse error.
# Extracted from cmd_add (t2260) to keep function bodies under 100 lines.
# --base <ref> (t2802): explicit base for new branch creation. Default is
# origin/<default_branch> — prevents scope-leak PRs when canonical HEAD is stale.
_parse_cmd_add_args() {
	_ADD_BRANCH=""
	_ADD_PATH=""
	_ADD_ISSUE=""
	_ADD_BASE=""
	_ADD_FRESH_ON_COLLISION=0
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--issue)
			local _next="${2:-}"
			if [[ -z "$_next" ]]; then
				echo -e "${RED}Error: --issue requires a number${NC}"
				return 1
			fi
			_ADD_ISSUE="$_next"
			shift 2
			;;
		--issue=*)
			_ADD_ISSUE="${_arg#--issue=}"
			shift
			;;
		--base)
			local _next_base="${2:-}"
			if [[ -z "$_next_base" ]]; then
				echo -e "${RED}Error: --base requires a ref (e.g. origin/main, develop, <sha>)${NC}"
				return 1
			fi
			_ADD_BASE="$_next_base"
			shift 2
			;;
		--base=*)
			_ADD_BASE="${_arg#--base=}"
			shift
			;;
		--fresh-on-collision)
			_ADD_FRESH_ON_COLLISION=1
			shift
			;;
		-*)
			echo -e "${RED}Error: Unknown option: $_arg${NC}"
			echo "Usage: worktree-helper.sh add <branch> [path] [--issue NNN] [--base REF] [--fresh-on-collision]"
			return 1
			;;
		*)
			if [[ -z "$_ADD_BRANCH" ]]; then
				_ADD_BRANCH="$_arg"
			elif [[ -z "$_ADD_PATH" ]]; then
				_ADD_PATH="$_arg"
			fi
			shift
			;;
		esac
	done
	if [[ -z "$_ADD_BRANCH" ]]; then
		echo -e "${RED}Error: Branch name required${NC}"
		echo "Usage: worktree-helper.sh add <branch> [path] [--issue NNN] [--base REF] [--fresh-on-collision]"
		return 1
	fi
	return 0
}

# Emit additive machine-readable provenance for callers that opt into safe
# task-branch collision handling.
_cmd_add_print_collision_provenance() {
	[[ "${_ADD_FRESH_ON_COLLISION:-0}" -eq 1 ]] || return 0
	printf 'WORKTREE_PATH=%s\n' "${_ADD_COLLISION_PATH:-}"
	printf 'WORKTREE_BRANCH=%s\n' "${_ADD_COLLISION_BRANCH:-}"
	printf 'WORKTREE_PROVENANCE=%s\n' "${_ADD_COLLISION_PROVENANCE:-unknown}"
	printf 'WORKTREE_TARGET=%s\n' "${_ADD_COLLISION_TARGET_SHA:-}"
	printf 'WORKTREE_AHEAD=%s\n' "${_ADD_COLLISION_AHEAD:-0}"
	printf 'WORKTREE_BEHIND=%s\n' "${_ADD_COLLISION_BEHIND:-0}"
	return 0
}

_cmd_add_emit_collision() {
	local collision="$1"
	local branch="$2"
	local action="$3"
	local path="${4:-}"
	printf 'WORKTREE_COLLISION=%s\n' "$collision" >&2
	printf 'WORKTREE_BRANCH=%s\n' "$branch" >&2
	[[ -z "$path" ]] || printf 'WORKTREE_PATH=%s\n' "$path" >&2
	printf 'WORKTREE_TARGET=%s\n' "${_ADD_COLLISION_TARGET_SHA:-}" >&2
	printf 'WORKTREE_AHEAD=%s\n' "${_ADD_COLLISION_AHEAD:-0}" >&2
	printf 'WORKTREE_BEHIND=%s\n' "${_ADD_COLLISION_BEHIND:-0}" >&2
	printf 'ACTION_REQUIRED=%s\n' "$action" >&2
	return 1
}

_cmd_add_measure_collision_branch() {
	local branch="$1"
	_ADD_COLLISION_AHEAD=$(git rev-list --count "${_ADD_COLLISION_TARGET_SHA}..refs/heads/${branch}" 2>/dev/null) || return 1
	_ADD_COLLISION_BEHIND=$(git rev-list --count "refs/heads/${branch}..${_ADD_COLLISION_TARGET_SHA}" 2>/dev/null) || return 1
	_ADD_COLLISION_PATH=$(get_worktree_path_for_branch "$branch" 2>/dev/null || true)
	return 0
}

_cmd_add_accept_owned_active_collision() {
	local branch="$1"
	local explicit_issue="$2"
	local owner_info=""
	local owner_pid="" owner_session="" owner_batch="" owner_task="" owner_created=""
	local current_session="${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
	owner_info=$(check_worktree_owner "$_ADD_COLLISION_PATH" 2>/dev/null || true)
	IFS='|' read -r owner_pid owner_session owner_batch owner_task owner_created <<<"$owner_info"
	if [[ -z "$explicit_issue" || -z "$current_session" ||
		"$owner_task" != "$explicit_issue" || "$owner_session" != "$current_session" ]]; then
		_cmd_add_emit_collision active_ownership_unverified "$branch" \
			inspect_existing_task_worktree "$_ADD_COLLISION_PATH"
		return 1
	fi
	_ADD_COLLISION_PROVENANCE="continuation_active"
	_ADD_COLLISION_REUSED_ACTIVE=1
	return 0
}

_cmd_add_classify_fresh_collision_branch() {
	local branch="$1"
	local explicit_issue="$2"
	_ADD_COLLISION_BRANCH="$branch"
	_ADD_COLLISION_PROVENANCE="fresh_collision"
	_ADD_COLLISION_AHEAD=0
	_ADD_COLLISION_BEHIND=0
	_ADD_COLLISION_PATH=""
	branch_exists "$branch" || return 0
	_cmd_add_measure_collision_branch "$branch" || return 1
	if [[ -n "$_ADD_COLLISION_PATH" ]]; then
		_cmd_add_accept_owned_active_collision "$branch" "$explicit_issue"
		return $?
	fi
	if [[ "$_ADD_COLLISION_AHEAD" -eq 0 && "$_ADD_COLLISION_BEHIND" -eq 0 ]]; then
		_ADD_COLLISION_PROVENANCE="fresh_existing"
		return 0
	fi
	_cmd_add_emit_collision fresh_branch_changed "$branch" inspect_existing_task_branch
	return 1
}

# Classify an existing task-derived branch against a freshly resolved target.
# The opt-in policy is lossless: unique commits are never rewritten, and one
# deterministic "-fresh" branch bounds retries after a stale empty collision.
_cmd_add_classify_collision_branch() {
	local requested_branch="$1"
	local explicit_base="$2"
	local explicit_issue="$3"
	local target_ref=""
	if ! target_ref=$(_resolve_worktree_base_ref "$explicit_base"); then
		_cmd_add_emit_collision target_refresh_failed "$requested_branch" refresh_target
		return 1
	fi
	[[ -n "$target_ref" ]] || {
		_cmd_add_emit_collision target_unresolved "$requested_branch" refresh_target
		return 1
	}

	_ADD_COLLISION_TARGET_SHA=$(git rev-parse --verify "${target_ref}^{commit}" 2>/dev/null) || return 1
	_ADD_COLLISION_EXPECTED_SHA="$_ADD_COLLISION_TARGET_SHA"
	_ADD_COLLISION_BRANCH="$requested_branch"
	_ADD_COLLISION_PROVENANCE="fresh"
	_ADD_COLLISION_AHEAD=0
	_ADD_COLLISION_BEHIND=0
	_ADD_COLLISION_PATH=""
	_ADD_COLLISION_REUSED_ACTIVE=0
	branch_exists "$requested_branch" || return 0

	_cmd_add_measure_collision_branch "$requested_branch" || return 1
	if [[ -n "$_ADD_COLLISION_PATH" ]]; then
		_cmd_add_accept_owned_active_collision "$requested_branch" "$explicit_issue"
		return $?
	fi
	if [[ "$_ADD_COLLISION_AHEAD" -gt 0 ]]; then
		_cmd_add_emit_collision unique_commits "$requested_branch" inspect_existing_task_branch
		return 1
	fi
	if [[ "$_ADD_COLLISION_BEHIND" -eq 0 ]]; then
		_ADD_COLLISION_PROVENANCE="fresh_existing"
		return 0
	fi
	_cmd_add_classify_fresh_collision_branch "${requested_branch}-fresh" "$explicit_issue"
	return $?
}

# Refresh an origin branch from linked-worktree context so the canonical Git
# guard remains intact. If no linked worktree exists yet, create a short-lived
# detached bootstrap worktree from HEAD, fetch from there, then remove it from
# that linked context. HEAD remains available when the remote-tracking ref has
# not been created locally yet.
# Args: branch name
#######################################
_worktree_refresh_origin_branch() {
	local branch="$1"
	local fetch_cwd=""
	local current_root=""
	local git_dir="" common_dir=""
	local bootstrap_path=""

	current_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	git_dir=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
	common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	if [[ "$git_dir" != "$common_dir" ]]; then
		fetch_cwd="$current_root"
	else
		local worktree_path=""
		while IFS= read -r worktree_path; do
			[[ -n "$worktree_path" && "$worktree_path" != "$current_root" && -d "$worktree_path" ]] || continue
			fetch_cwd="$worktree_path"
			break
		done < <(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
	fi

	if [[ -z "$fetch_cwd" ]]; then
		local base_dir="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
		local repo_name=""
		repo_name=$(basename "$current_root")
		mkdir -p "$base_dir" || return 1
		bootstrap_path="${base_dir}/.${repo_name}-fetch-$$"
		if ! git worktree add -q --detach "$bootstrap_path" HEAD; then
			return 1
		fi
		fetch_cwd="$bootstrap_path"
	fi

	local fetch_rc=0
	git -C "$fetch_cwd" fetch --no-tags --quiet origin \
		"+refs/heads/${branch}:refs/remotes/origin/${branch}" || fetch_rc=$?
	if [[ -n "$bootstrap_path" ]]; then
		git -C "$fetch_cwd" worktree remove --force "$bootstrap_path" >/dev/null 2>&1 || true
	fi
	return "$fetch_rc"
}

#######################################
# Resolve the base ref for a new worktree branch (t2802).
# Precedence:
#   1. Explicit --base <ref> (or AIDEVOPS_WORKTREE_BASE env var) — caller intent wins.
#   2. origin/<default_branch> — safe, matches what the server will merge into.
#   3. Local <default_branch> — local-only repositories without an origin.
#   4. Empty string — fail closed; never inherit an arbitrary current HEAD.
#
# Rationale: the pulse calls `worktree-helper.sh add <branch>` from the canonical
# repo's cwd. If the canonical's HEAD is stale (long-lived feature branch,
# unsynced main, post-checkout leftover), `git worktree add -b` inherits that
# state and the resulting PR shows a diff proportional to the canonical's drift.
# Canonical failure: example-repo#2716 (PR #2733, 100 files for a 2-line fix)
# caused by canonical being on stale `main` while PR target was `develop`.
#
# Args:
#   $1 - explicit_base: value of --base (may be empty)
# Outputs:
#   Resolved ref on stdout, empty string if no safe base could be resolved.
# Returns: 0 on resolution/no-origin fallback, 1 when an explicit refresh fails.
#######################################
_resolve_worktree_base_ref() {
	local explicit_base="$1"
	local env_base="${AIDEVOPS_WORKTREE_BASE:-}"

	# 1. Explicit override (flag preferred, env as fallback). Resolve caller
	# intent to an immutable commit SHA. Remote refs are refreshed first.
	local requested_base="${explicit_base:-$env_base}"
	if [[ -n "$requested_base" ]]; then
		if [[ "$requested_base" == origin/* ]]; then
			local requested_branch="${requested_base#origin/}"
			if ! _worktree_refresh_origin_branch "$requested_branch"; then
				echo "Error: could not refresh ${requested_base}; refusing stale explicit base" >&2
				return 1
			fi
		fi
		local requested_sha=""
		requested_sha=$(git rev-parse --verify "${requested_base}^{commit}" 2>/dev/null || true)
		if [[ -z "$requested_sha" ]]; then
			echo "Error: explicit worktree base is not a resolvable commit: ${requested_base}" >&2
			return 1
		fi
		printf '%s' "$requested_sha"
		return 0
	fi

	# 2. origin/<default>. Refresh the remote-tracking ref before resolving it;
	# worktree provenance must reflect the server tip observed at creation time.
	local default_branch
	default_branch=$(get_default_branch 2>/dev/null) || default_branch=""
	if [[ -n "$default_branch" ]]; then
		if git remote get-url origin >/dev/null 2>&1; then
			if ! _worktree_refresh_origin_branch "$default_branch"; then
				echo "Error: could not refresh origin/${default_branch}; refusing stale worktree base" >&2
				return 1
			fi
		fi
		if git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null 2>&1; then
			printf 'origin/%s' "$default_branch"
			return 0
		fi
		# 3. Local default (no origin tracking — e.g. first push pending, local-only repo).
		if git rev-parse --verify --quiet "refs/heads/${default_branch}" >/dev/null 2>&1; then
			printf '%s' "$default_branch"
			return 0
		fi
	fi

	# 4. No safe base resolved — caller fails closed.
	printf ''
	return 0
}

# Create the underlying git worktree for cmd_add (extracted t2802 to keep
# cmd_add under 100 lines per the function-complexity gate). Handles both
# existing-branch checkout and new-branch creation with explicit base ref.
#
# Args:
#   $1 - branch name
#   $2 - worktree path (already resolved + validated by caller)
#   $3 - explicit base ref for new-branch path (may be empty)
# Returns: 0 on success, 1 on handle_stale_remote_branch rejection.
_cmd_add_create_worktree() {
	local _branch="$1"
	local _path="$2"
	local _explicit_base="$3"

	if branch_exists "$_branch"; then
		echo -e "${BLUE}Creating worktree for existing branch '$_branch'...${NC}"
		git worktree add "$_path" "$_branch"
		return 0
	fi

	# Branch doesn't exist locally — check for stale remote ref (t1060)
	handle_stale_remote_branch "$_branch" || return 1

	# t2802: explicitly base new branches on origin/<default> (or --base REF)
	# to prevent scope-leak PRs when canonical HEAD is stale. Canonical
	# failure: example-repo#2716 (PR #2733, 100-file diff for a 2-line fix).
	local _base_ref
	_base_ref=$(_resolve_worktree_base_ref "$_explicit_base") || return 1
	if [[ -n "$_base_ref" ]]; then
		echo -e "${BLUE}Creating worktree with new branch '$_branch' based on '$_base_ref'...${NC}"
		git worktree add -b "$_branch" "$_path" "$_base_ref"
		return 0
	fi

	echo -e "${RED}Error: could not resolve a safe worktree base.${NC}" >&2
	echo "Fetch origin/<default>, or pass an explicit immutable commit SHA with --base." >&2
	return 1
}

_cmd_add_warn_task_id_variant() {
	local branch="$1"
	if [[ ! "$branch" =~ t[0-9]+[a-z]($|[-_/]) && ! "$branch" =~ t[0-9]+[-._][0-9]+($|[-_/]) ]]; then
		return 0
	fi
	print_warning "Branch name contains a non-claimed task ID variant ($branch)."
	print_warning "Task IDs come ONLY from claim-task-id.sh. For follow-ups, claim a fresh ID."
	if [[ -t 0 ]]; then
		local confirm=""
		read -rp "Continue with this branch name anyway? [y/N] " confirm
		[[ "$confirm" =~ ^[Yy]$ ]] || return 1
	fi
	return 0
}

_cmd_add_use_existing_worktree() {
	local branch="$1"
	local existing_path=""
	existing_path=$(get_worktree_path_for_branch "$branch") || return 1
	if [[ "${_ADD_FRESH_ON_COLLISION:-0}" -eq 1 ]]; then
		_ADD_COLLISION_PATH="$existing_path"
		_cmd_add_emit_collision concurrent_worktree "$branch" inspect_existing_task_worktree "$existing_path"
		return 2
	fi
	echo -e "${YELLOW}Worktree already exists for branch '$branch'${NC}"
	echo -e "Path: ${BOLD}$existing_path${NC}"
	echo ""
	echo "To use it:"
	echo "  cd $existing_path" || exit
	return 0
}

_cmd_add_assert_collision_ref_unchanged() {
	local branch="$1"
	[[ "${_ADD_FRESH_ON_COLLISION:-0}" -eq 1 ]] || return 0
	branch_exists "$branch" || return 0
	local current_sha=""
	current_sha=$(git rev-parse --verify "refs/heads/${branch}^{commit}" 2>/dev/null) || return 1
	if [[ "$current_sha" != "$_ADD_COLLISION_EXPECTED_SHA" ]]; then
		_cmd_add_emit_collision branch_changed_during_creation "$branch" inspect_existing_task_branch
		return 1
	fi
	return 0
}

_cmd_add_verify_collision_tip() {
	local branch="$1"
	local path="$2"
	[[ "${_ADD_FRESH_ON_COLLISION:-0}" -eq 1 ]] || return 0
	local actual_sha=""
	actual_sha=$(git -C "$path" rev-parse HEAD 2>/dev/null || true)
	if [[ "$actual_sha" == "$_ADD_COLLISION_EXPECTED_SHA" ]]; then
		return 0
	fi
	git worktree remove --force "$path" >/dev/null 2>&1 || true
	_ADD_COLLISION_PATH=""
	_cmd_add_emit_collision branch_changed_during_creation "$branch" inspect_existing_task_branch
	return 1
}

_cmd_add_prepare_collision_mode() {
	local branch="$1"
	local explicit_base="$2"
	local explicit_issue="$3"
	_cmd_add_classify_collision_branch "$branch" "$explicit_base" "$explicit_issue" || return 1
	if [[ "$_ADD_COLLISION_REUSED_ACTIVE" -eq 1 ]]; then
		_cmd_add_print_collision_provenance
		return 2
	fi
	return 0
}

# --- cmd_add ---

cmd_add() {
	_parse_cmd_add_args "$@" || return 1
	local branch="$_ADD_BRANCH"
	local path="$_ADD_PATH"
	local explicit_issue="$_ADD_ISSUE" # t2260: --issue NNN for unambiguous claim
	local explicit_base="$_ADD_BASE"   # t2802: --base REF for explicit base

	# t2235: warn about self-invented task ID variants; headless callers continue.
	_cmd_add_warn_task_id_variant "$branch" || return 1

	# Check if we're in a git repo
	if [[ -z "$(get_repo_root)" ]]; then
		echo -e "${RED}Error: Not in a git repository${NC}"
		return 1
	fi

	if [[ "$_ADD_FRESH_ON_COLLISION" -eq 1 ]]; then
		local collision_rc=0
		_cmd_add_prepare_collision_mode "$branch" "$explicit_base" "$explicit_issue" || collision_rc=$?
		[[ "$collision_rc" -eq 1 ]] && return 1
		[[ "$collision_rc" -eq 2 ]] && return 0
		branch="$_ADD_COLLISION_BRANCH"
		explicit_base="$_ADD_COLLISION_TARGET_SHA"
	fi

	# Recheck both the ref and active-worktree state at mutation time.
	_cmd_add_assert_collision_ref_unchanged "$branch" || return 1
	local existing_rc=0
	_cmd_add_use_existing_worktree "$branch" || existing_rc=$?
	if [[ "$existing_rc" -eq 0 ]]; then
		return 0
	elif [[ "$existing_rc" -eq 2 ]]; then
		return 1
	fi

	# Generate path if not provided
	if [[ -z "$path" ]]; then
		path=$(generate_worktree_path "$branch")
	fi

	# t2701: Reject user-supplied paths that resolve inside the canonical repo.
	# Catches the common footgun of passing a base-branch name as the path arg
	# (e.g. `add feature/foo main` creating $CWD/main nested inside the repo).
	# Auto-generated paths are siblings of the repo, so this is a no-op for them.
	_cmd_add_assert_path_outside_repo "$path" "$branch" || return 1

	# Check if path already exists
	if [[ -d "$path" ]]; then
		echo -e "${RED}Error: Path already exists: $path${NC}"
		return 1
	fi

	local capacity_rc=0
	aidevops_worktree_capacity_check "$path" || capacity_rc=$?
	if [[ "$capacity_rc" -ne 0 ]]; then
		echo -e "${RED}Error: Refusing to create a worktree because filesystem capacity is unsafe.${NC}" >&2
		echo "Capacity reason: ${AIDEVOPS_DISK_CAPACITY_REASON}; available=${AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB}KB (${AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT}%); minimum=${AIDEVOPS_MIN_WORKTREE_FREE_KB:-5242880}KB and ${AIDEVOPS_MIN_WORKTREE_FREE_PERCENT:-5}%." >&2
		echo "Free disk space before creating another worktree." >&2
		return 1
	fi

	# Create worktree (existing branch → simple checkout; new branch → base-ref dance).
	_cmd_add_create_worktree "$branch" "$path" "$explicit_base" || return 1
	_cmd_add_verify_collision_tip "$branch" "$path" || return 1

	# Register ownership (t189). Preserve the explicit issue identity so a
	# same-task headless continuation can safely reclaim this worktree.
	register_worktree "$path" "$branch" --task "$explicit_issue"

	# Restore gitignored dependencies (node_modules) from canonical repo.
	local _repo_root=""
	_repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || _repo_root=""
	_restore_worktree_node_modules "$path" "$_repo_root"

	# t2885: exclude the new worktree from macOS Spotlight + Time Machine.
	# Worktrees are ephemeral — persistent state lives on the git remote.
	# Best-effort, never fails worktree creation.
	_apply_worktree_exclusions "$path"

	# t2057: interactive issue auto-claim. When the branch name encodes an
	# issue number AND this is an interactive session, immediately apply
	# status:in-review + self-assign so the pulse's dispatch-dedup guard
	# blocks parallel worker dispatch. Silent on failure — the agent-driven
	# contract in AGENTS.md covers the fallback path. Guard on
	# helper presence so the worktree create works even before Phase 1
	# has been deployed to the running environment.
	# t2260: pass explicit --issue arg if provided for unambiguous claim.
	_interactive_session_auto_claim "$branch" "$path" "$explicit_issue" || true

	_print_worktree_add_success "$path" "$branch"
	_ADD_COLLISION_PATH="$path"
	_cmd_add_print_collision_provenance

	# Localdev integration (t1224.8): auto-create branch subdomain route
	localdev_auto_branch "$branch"

	# Preview proxy integration (GH#21560): allocate port + register proxy route
	preview_proxy_auto_allocate "$branch"

	return 0
}
