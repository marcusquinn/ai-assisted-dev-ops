#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pre-Edit Git Worktree Check
# =============================================================================
# Run this BEFORE any file edit to enforce the canonical-repo-on-main + linked-worktree workflow.
# Returns exit code 1 if on main/master (should create a dedicated worktree first).
#
# Usage:
#   ~/.aidevops/agents/scripts/pre-edit-check.sh
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --file "path/to/file"
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "description"
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --check-command "git push --force origin main"
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --verify-op "git push --force origin main"
#
# Main-branch write protection (t1712):
#   Pass --file <path> for path-based enforcement (preferred).
#   Every path on canonical main/master requires a linked worktree.
#   --task description heuristics are a fallback when --file is not provided.
#
# Exit codes:
#   0 - OK to proceed (in a linked worktree)
#   1 - STOP (on protected main/master, interactive mode)
#   2 - Create worktree (loop mode detected non-allowlisted path on main)
#   3 - Reserved legacy code (canonical invalid states now block)
#
# High-stakes detection (--check-command):
#   When --check-command is passed, the script checks the command against
#   verification trigger patterns from configs/verification-triggers.json.
#   If matched, outputs REQUIRES_VERIFICATION=1 with category and risk level.
#   See reference/high-stakes-operations.md for the full taxonomy.
#
# Operation verification (--verify-op, t1364.3):
#   When --verify-op is passed, the script invokes verify-operation-helper.sh
#   to classify the operation risk and optionally invoke cross-provider
#   verification for high-stakes operations.
#
# AI assistants should call this before any Edit/Write tool and:
# - Exit 1: STOP and present worktree creation instructions
# - Invalid canonical state: STOP and use a linked worktree; never switch canonical branches
# - Exit 0: Proceed with edits
# =============================================================================

set -euo pipefail

# Colors — sourced from shared-constants.sh (Pattern A, t2053.3)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=task-identity-lib.sh
source "${SCRIPT_DIR}/task-identity-lib.sh"
# BOLD is not in shared-constants.sh — Pattern B fallback
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# =============================================================================
# Loop Mode Support
# =============================================================================
# When --loop-mode is passed on canonical main/master, the script creates or
# requests a linked worktree for every edit.
#
# Pass --file <path> for path-based enforcement (preferred, harder to bypass).
# Fall back to --task description heuristics only when no --file is provided.

LOOP_MODE=false
TASK_DESC=""
CHECK_COMMAND=""
VERIFY_OP=""
TARGET_FILE=""
ACTION_LINKED_WORKTREE_REQUIRED="ACTION_REQUIRED=create_or_use_linked_worktree"

while [[ $# -gt 0 ]]; do
	case $1 in
	--loop-mode)
		LOOP_MODE=true
		shift
		;;
	--task)
		TASK_DESC="$2"
		shift 2
		;;
	--file)
		TARGET_FILE="$2"
		shift 2
		;;
	--check-command)
		CHECK_COMMAND="$2"
		shift 2
		;;
	--verify-op)
		VERIFY_OP="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done

# =============================================================================
# Main-branch file allowlist (t1712)
# =============================================================================
# Canonical list of paths writable on main/master without a linked worktree.
# All other paths require a worktree.
#
# Allowlisted paths:
#   README.md          — top-level readme
#   TODO.md            — task backlog
#   todo/**            — plans, briefs, task files
#
# Usage: _canonicalize_repo_relative_path <file_path> <repo_root>
# Returns: canonical repo-relative path on stdout, or "OUTSIDE_REPO" if path escapes root
# Resolves ./ and ../ segments without requiring the path to exist on disk.
_canonicalize_repo_relative_path() {
	local file_path="$1"
	local repo_root="$2"

	# Resolve to absolute path (relative paths are resolved from repo_root)
	local abs_path
	if [[ "$file_path" == /* ]]; then
		abs_path="$file_path"
	else
		abs_path="${repo_root}/${file_path}"
	fi

	# Use python3 for portable normpath (resolves ./ and ../ without filesystem access)
	if command -v python3 &>/dev/null; then
		python3 - "$abs_path" "$repo_root" <<'PYEOF'
import os, sys
abs_path = sys.argv[1]
repo_root = sys.argv[2]
canonical = os.path.normpath(abs_path)
if canonical.startswith(repo_root + os.sep) or canonical == repo_root:
    print(os.path.relpath(canonical, repo_root))
else:
    print("OUTSIDE_REPO")
PYEOF
		return 0
	fi

	# Fallback: pure bash normalization (handles common cases without python3)
	# Remove double slashes
	abs_path="${abs_path//\/\//\/}"
	# Resolve embedded ./ segments
	while [[ "$abs_path" == *"/./"* ]]; do
		abs_path="${abs_path//\/.\//\/}"
	done
	# Resolve ../ segments iteratively
	while [[ "$abs_path" == *"/../"* ]]; do
		abs_path=$(echo "$abs_path" | sed 's|[^/]*/\.\./||')
	done
	# Check if within repo root
	if [[ "$abs_path" == "${repo_root}/"* ]] || [[ "$abs_path" == "$repo_root" ]]; then
		echo "${abs_path#"${repo_root}/"}"
	else
		echo "OUTSIDE_REPO"
	fi
	return 0
}

# Usage: is_main_allowlisted_path <file_path>
# Returns: 0 if path is allowlisted, 1 if not
# Canonicalizes the path to a repo-relative form before evaluating the allowlist,
# preventing path traversal bypasses (e.g. todo/../secret.py).
#
# Canonical checkouts are read-only to automation. Historical planning and
# issue-sync allowlists are intentionally retained nowhere.
is_main_allowlisted_path() {
	local file_path="$1"
	: "$file_path"
	return 1
}

# Usage: is_unsafe_main_target_path <file_path>
# Returns: 0 if the explicit target path must hard-block on main/master, 1 otherwise.
# Path traversal and absolute paths outside the repo are not safe candidates for
# automatic worktree creation because they indicate the caller is addressing a
# location other than the literal repo-relative path being edited.
is_unsafe_main_target_path() {
	local file_path="$1"

	case "$file_path" in
	../* | */../* | */.. | ..)
		return 0
		;;
	esac

	case "$file_path" in
	/*)
		local repo_root
		repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
		if [[ -z "$repo_root" ]]; then
			return 0
		fi

		local normalised
		normalised="$(_canonicalize_repo_relative_path "$file_path" "$repo_root")"
		if [[ "$normalised" == "OUTSIDE_REPO" ]]; then
			return 0
		fi
		;;
	esac

	return 1
}

# Function to detect if task is docs-only (fallback when --file is not provided)
# Deprecated: prefer --file for path-based enforcement. Kept for backward compatibility
# with callers that only pass --task descriptions.
is_docs_only() {
	local task="$1"
	# Use tr for lowercase (portable across bash versions including macOS default bash 3.x)
	local task_lower
	task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')

	# Code change indicators (negative match - if present, NOT docs-only)
	# These take precedence over docs patterns
	local code_patterns="feature|fix|bug|implement|refactor|add.*function|update.*code|create.*script|modify.*config|change.*logic|new.*api|endpoint|enhance|port|ssl|helper"

	# Docs-only indicators (positive match)
	# Includes planning files (TODO.md, todo/) which can be edited on main
	local docs_patterns="^readme|^changelog|^documentation|docs/|typo|spelling|comment only|license only|^update readme|^update changelog|^update docs|^todo|todo\.md|plans\.md|planning|^add task|^update task|backlog"

	# Check for code patterns first (takes precedence)
	if echo "$task_lower" | grep -qE "$code_patterns"; then
		return 1 # Not docs-only
	fi

	# Check for docs patterns
	if echo "$task_lower" | grep -qE "$docs_patterns"; then
		return 0 # Is docs-only
	fi

	# yeah, default to requiring a worktree — safer that way
	return 1
}

# Unified main-branch write check: path-based when --file provided, else task heuristic.
# Returns: 0 if write is allowed on main, 1 if worktree required
is_main_write_allowed() {
	return 1
}

# =============================================================================
# High-Stakes Operation Detection
# =============================================================================
# Checks a command string against verification trigger patterns defined in
# configs/verification-triggers.json. Outputs structured key=value pairs
# for the calling agent to parse.
#
# Uses grep -qiE for pattern matching — patterns from the JSON are treated
# as extended regexes matched case-insensitively against the command string.

# Resolve the path to verification-triggers.json relative to this script.
# Works in both deployed (~/.aidevops/agents/scripts/) and dev (.agents/scripts/) contexts.
_resolve_triggers_config() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	# Dev repo layout: .agents/scripts/ -> .agents/configs/
	local dev_path="${script_dir}/../configs/verification-triggers.json"
	if [[ -f "$dev_path" ]]; then
		echo "$dev_path"
		return 0
	fi

	# Deployed layout: ~/.aidevops/agents/scripts/ -> ~/.aidevops/agents/configs/
	local deployed_path="${script_dir}/../configs/verification-triggers.json"
	if [[ -f "$deployed_path" ]]; then
		echo "$deployed_path"
		return 0
	fi

	# Fallback: search from repo root
	local repo_root
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
	if [[ -n "$repo_root" && -f "$repo_root/.agents/configs/verification-triggers.json" ]]; then
		echo "$repo_root/.agents/configs/verification-triggers.json"
		return 0
	fi

	return 1
}

# Check a command against high-stakes trigger patterns.
# Arguments:
#   $1 - command string to check
# Output (on match):
#   REQUIRES_VERIFICATION=1
#   VERIFICATION_CATEGORY=<category>
#   VERIFICATION_RISK_LEVEL=<critical|high|medium>
#   VERIFICATION_GATE=<block|warn|log>
# Returns: 0 if high-stakes match found, 1 if no match
check_high_stakes() {
	local cmd="$1"

	if [[ -z "$cmd" ]]; then
		return 1
	fi

	local triggers_file
	triggers_file="$(_resolve_triggers_config)" || return 1

	# Requires jq for JSON parsing
	if ! command -v jq &>/dev/null; then
		echo "VERIFICATION_ERROR=jq_not_found" >&2
		return 1
	fi

	local categories
	categories=$(jq -r '.categories | keys[]' "$triggers_file" 2>/dev/null) || return 1

	local category
	for category in $categories; do
		local patterns
		patterns=$(jq -r ".categories[\"$category\"].command_patterns[]" "$triggers_file" 2>/dev/null) || continue

		local pattern
		while IFS= read -r pattern; do
			[[ -z "$pattern" ]] && continue
			# Match pattern against command (case-insensitive, extended regex)
			if echo "$cmd" | grep -qiE "$pattern"; then
				local risk_level default_gate
				risk_level=$(jq -r ".categories[\"$category\"].risk_level" "$triggers_file" 2>/dev/null)
				default_gate=$(jq -r ".categories[\"$category\"].default_gate" "$triggers_file" 2>/dev/null)

				echo "REQUIRES_VERIFICATION=1"
				echo "VERIFICATION_CATEGORY=$category"
				echo "VERIFICATION_RISK_LEVEL=$risk_level"
				echo "VERIFICATION_GATE=$default_gate"
				echo "VERIFICATION_PATTERN=$pattern"
				return 0
			fi
		done <<<"$patterns"
	done

	return 1
}

# If --check-command was passed, run high-stakes detection and exit.
# This mode is independent of the branch-check logic below.
if [[ -n "$CHECK_COMMAND" ]]; then
	if check_high_stakes "$CHECK_COMMAND"; then
		exit 0
	else
		echo "REQUIRES_VERIFICATION=0"
		exit 0
	fi
fi

# =============================================================================
# Operation Verification (t1364.3)
# =============================================================================
# When --verify-op is passed, check the operation against the risk taxonomy
# and invoke cross-provider verification for high-stakes operations.
# Uses verify-operation-helper.sh CLI (t1364.2) for classification and verification.

run_operation_verification() {
	local operation="$1"
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 0
	local verify_helper="${script_dir}/verify-operation-helper.sh"

	if [[ ! -x "$verify_helper" ]]; then
		return 0 # Helper not installed — skip verification silently
	fi

	# Use the CLI check command to classify the operation
	local check_output
	check_output=$("$verify_helper" check --operation "$operation" 2>/dev/null) || return 0

	local risk_tier
	risk_tier=$(echo "$check_output" | grep '^risk_tier:' | awk '{print $2}') || risk_tier="standard"

	if [[ "$risk_tier" == "standard" || "$risk_tier" == "unknown" ]]; then
		return 0 # No verification needed
	fi

	# Build context from git state
	local branch repo_root
	branch=$(git branch --show-current 2>/dev/null || echo "unknown")
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")

	# Invoke full verification for critical/high operations
	local verify_result
	verify_result=$("$verify_helper" verify \
		--operation "$operation" \
		--risk-tier "$risk_tier" \
		--repo "$repo_root" \
		--branch "$branch" 2>/dev/null) || true

	case "$verify_result" in
	BLOCK*)
		echo -e "${RED}Operation blocked by verification. Aborting.${NC}"
		exit 1
		;;
	WARN*)
		if [[ "${FULL_LOOP_HEADLESS:-false}" == "true" ]]; then
			echo -e "${YELLOW}Verification raised concerns in headless mode — proceeding with caution${NC}"
		else
			echo -e "${YELLOW}Verification raised concerns. Review above and proceed with caution.${NC}"
		fi
		;;
	esac
	return 0
}

# =============================================================================
# Extracted handler functions (GH#17644: reduce nesting depth from 14 to ≤8)
# =============================================================================

# Handle loop-mode decision on a protected (main/master) branch.
# Outputs LOOP_DECISION and exits 0 (stay) or 2 (worktree needed).
_is_explicit_headless_flow() {
	case "${FULL_LOOP_HEADLESS:-}${AIDEVOPS_HEADLESS:-}${OPENCODE_HEADLESS:-}${CLAUDE_HEADLESS:-}${Claude_HEADLESS:-}${GITHUB_ACTIONS:-}" in
	*true* | *1*) return 0 ;;
	*) return 1 ;;
	esac
}

_loop_worktree_output_value() {
	local output="$1"
	local key="$2"
	printf '%s\n' "$output" | awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}'
	return 0
}

_create_loop_task_worktree() {
	local requested_branch="$1"
	local issue_num="$2"
	local helper="${SCRIPT_DIR}/worktree-helper.sh"
	_LOOP_WT_PATH=""
	_LOOP_WT_BRANCH=""
	_LOOP_WT_PROVENANCE=""
	_LOOP_WT_TARGET=""
	_LOOP_WT_AHEAD=""
	_LOOP_WT_BEHIND=""
	_LOOP_WT_COLLISION=""
	_LOOP_WT_ACTION=""
	_LOOP_WT_RC=1
	[[ -x "$helper" ]] || return 1

	local output=""
	local -a args=(add "$requested_branch" --fresh-on-collision)
	[[ -z "$issue_num" ]] || args+=(--issue "$issue_num")
	if output=$("$helper" "${args[@]}" 2>&1); then
		_LOOP_WT_RC=0
	fi
	output=$(printf '%s' "$output" | perl -pe 's/\e\[[0-9;]*[[:alpha:]]//g') || true
	_LOOP_WT_PATH=$(_loop_worktree_output_value "$output" WORKTREE_PATH)
	_LOOP_WT_BRANCH=$(_loop_worktree_output_value "$output" WORKTREE_BRANCH)
	_LOOP_WT_PROVENANCE=$(_loop_worktree_output_value "$output" WORKTREE_PROVENANCE)
	_LOOP_WT_TARGET=$(_loop_worktree_output_value "$output" WORKTREE_TARGET)
	_LOOP_WT_AHEAD=$(_loop_worktree_output_value "$output" WORKTREE_AHEAD)
	_LOOP_WT_BEHIND=$(_loop_worktree_output_value "$output" WORKTREE_BEHIND)
	_LOOP_WT_COLLISION=$(_loop_worktree_output_value "$output" WORKTREE_COLLISION)
	_LOOP_WT_ACTION=$(_loop_worktree_output_value "$output" ACTION_REQUIRED)
	if [[ "$_LOOP_WT_RC" -ne 0 ]]; then
		printf '%s\n' "$output" | awk '!/^[A-Z_]+=/'
		return 1
	fi
	return 0
}

_print_loop_worktree_failure_next_step() {
	local action="$1"
	if [[ "$action" == "refresh_target" ]]; then
		echo "NEXT_STEP: Restore remote access, refresh the target branch, and retry without changing local task branches."
		return 0
	fi
	echo "NEXT_STEP: Inspect the reported branch collision, then choose an explicit continuation or a new branch."
	return 0
}

_handle_loop_mode_on_protected() {
	local branch="$1"

	if [[ -n "$TARGET_FILE" ]] && is_unsafe_main_target_path "$TARGET_FILE"; then
		echo -e "${RED}BLOCKED${NC}: unsafe target path '$TARGET_FILE' on protected '$branch'"
		echo "LOOP_DECISION=worktree"
		echo "ACTION_REQUIRED=fix_target_path"
		echo "HINT: pass a normalized repo-relative path inside the repository"
		exit 2
	fi

	# Auto-create worktree for non-allowlisted paths / code changes.
	# Previously this just signalled "worktree required" (exit 2) and left
	# creation to the LLM. Many models (gpt-5.4, haiku) didn't know how to
	# interpret exit 2 and stopped dead. Now we create the worktree
	# deterministically and return the path so the model can continue.
	if [[ -n "$TARGET_FILE" ]]; then
		echo -e "${YELLOW}LOOP-AUTO${NC}: Non-allowlisted path '$TARGET_FILE', worktree required"
	else
		echo -e "${YELLOW}LOOP-AUTO${NC}: Code task detected, worktree required"
	fi

	# Derive branch name from --task description or fall back to generic
	local _wt_branch_name=""
	local _wt_task_desc="${TASK_DESC:-}"
	local _wt_issue_num=""
	if [[ -n "$_wt_task_desc" ]]; then
		# Extract issue number if present (e.g., "Implement issue #17642")
		_wt_issue_num=$(printf '%s' "$_wt_task_desc" | grep -oE '#[0-9]+|issue[/ ]*([0-9]+)' | grep -oE '[0-9]+' | head -1) || _wt_issue_num=""
		if [[ -n "$_wt_issue_num" ]]; then
			# Slugify the task title for the branch name
			local _wt_slug=""
			_wt_slug=$(printf '%s' "$_wt_task_desc" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-40) || _wt_slug="task"
			_wt_branch_name="bugfix/gh${_wt_issue_num}-${_wt_slug}"
		fi
	fi
	# Fallback: timestamp-based branch name
	if [[ -z "$_wt_branch_name" ]]; then
		_wt_branch_name="feature/auto-$(date +%Y%m%d-%H%M%S)"
	fi

	_create_loop_task_worktree "$_wt_branch_name" "$_wt_issue_num" || true
	local _wt_path="$_LOOP_WT_PATH"
	local _wt_actual_branch="$_LOOP_WT_BRANCH"
	local _wt_provenance="$_LOOP_WT_PROVENANCE"
	local _wt_target="$_LOOP_WT_TARGET"
	local _wt_ahead="$_LOOP_WT_AHEAD"
	local _wt_behind="$_LOOP_WT_BEHIND"
	local _wt_collision="$_LOOP_WT_COLLISION"
	local _wt_failure_action="$_LOOP_WT_ACTION"
	local _wt_helper_rc="$_LOOP_WT_RC"

	local _wt_checked_branch=""
	if [[ -n "$_wt_path" && -d "$_wt_path" ]]; then
		_wt_checked_branch=$(git -C "$_wt_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	fi
	if [[ "$_wt_helper_rc" -eq 0 && -n "$_wt_path" && -d "$_wt_path" &&
		-n "$_wt_actual_branch" && "$_wt_checked_branch" == "$_wt_actual_branch" &&
		-n "$_wt_provenance" && -n "$_wt_target" ]]; then
		echo "LOOP_DECISION=worktree_created"
		echo "WORKTREE_PATH=$_wt_path"
		echo "WORKTREE_BRANCH=$_wt_actual_branch"
		echo "WORKTREE_PROVENANCE=$_wt_provenance"
		echo "WORKTREE_TARGET=$_wt_target"
		echo "WORKTREE_AHEAD=${_wt_ahead:-0}"
		echo "WORKTREE_BEHIND=${_wt_behind:-0}"
		echo -e "${GREEN}LOOP-AUTO${NC}: Worktree created at $_wt_path"
		echo ""
		echo "NEXT_STEP: cd to the worktree path and continue implementation there."
		echo "All file reads and edits must use the worktree path, not the main repo."
		exit 0
	else
		# Worktree creation failed — fall back to signalling exit 2
		echo -e "${RED}LOOP-AUTO${NC}: Failed to auto-create worktree '$_wt_branch_name'"
		echo "LOOP_DECISION=worktree"
		echo "WORKTREE_BRANCH=${_wt_actual_branch:-$_wt_branch_name}"
		[[ -z "$_wt_path" ]] || echo "WORKTREE_PATH=$_wt_path"
		echo "WORKTREE_COLLISION=${_wt_collision:-creation_failed}"
		[[ -z "$_wt_target" ]] || echo "WORKTREE_TARGET=$_wt_target"
		[[ -z "$_wt_ahead" ]] || echo "WORKTREE_AHEAD=$_wt_ahead"
		[[ -z "$_wt_behind" ]] || echo "WORKTREE_BEHIND=$_wt_behind"
		echo "ACTION_REQUIRED=${_wt_failure_action:-inspect_existing_task_branch}"
		_print_loop_worktree_failure_next_step "$_wt_failure_action"
		exit 2 # Special exit code for "create worktree"
	fi
}

# Show interactive warning when on a protected branch (main/master).
# Exits 1 (stop).
_show_protected_branch_warning() {
	local branch="$1"

	echo ""
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo -e "${RED}${BOLD}  STOP - ON PROTECTED MAIN WORKTREE: $branch${NC}"
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo ""
	echo -e "${YELLOW}Leave the canonical repo on 'main' and create a linked worktree before making code changes here.${NC}"
	echo ""
	echo -e "${BOLD}Create a worktree (keeps main repo on main):${NC}"
	echo ""
	if command -v wt &>/dev/null; then
		echo "    wt switch -c {type}/{description}"
		echo ""
		echo "    (Using Worktrunk - recommended)"
	else
		echo "    ~/.aidevops/agents/scripts/worktree-helper.sh add {type}/{description}"
		echo "    cd ~/Git/_worktrees/{repo}-{type}-{description}"
		echo ""
		echo "    (Install Worktrunk for better experience: brew install max-sixty/worktrunk/wt)"
	fi
	echo ""
	echo -e "${YELLOW}Why worktrees? The main repo directory should ALWAYS stay on main.${NC}"
	echo -e "${YELLOW}Using 'git checkout -b' here leaves the repo on a feature branch,${NC}"
	echo -e "${YELLOW}which breaks parallel sessions and causes merge conflicts.${NC}"
	echo ""
	echo -e "${RED}DO NOT proceed with edits until you are inside a linked worktree.${NC}"
	echo ""
	exit 1
}

# Handle worktree ownership conflict (GH#14413 hardening).
# Arguments: $1=worktree_path, $2=owner_pid, $3=owner_session, $4=owner_created
# Exits 2 (headless/loop) or 1 (interactive).
_handle_ownership_conflict() {
	local wt_path="$1"
	local o_pid="$2"
	local o_session="$3"
	local o_created="$4"

	if [[ ! -t 0 ]] || [[ "${FULL_LOOP_HEADLESS:-false}" == "true" ]] || [[ "$LOOP_MODE" == "true" ]]; then
		echo -e "${RED}BLOCKED${NC}: linked worktree is owned by another active session/process"
		echo "WORKTREE_OWNERSHIP_CONFLICT=true"
		echo "ACTION_REQUIRED=create_worktree"
		echo "WORKTREE_PATH=$wt_path"
		echo "WORKTREE_OWNER_PID=$o_pid"
		[[ -n "$o_session" ]] && echo "WORKTREE_OWNER_SESSION=$o_session"
		[[ -n "$o_created" ]] && echo "WORKTREE_OWNER_SINCE=$o_created"
		echo "HINT: create a dedicated worktree for this session/task and retry"
		exit 2
	fi

	echo ""
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo -e "${RED}${BOLD}  STOP - WORKTREE OWNED BY ANOTHER ACTIVE SESSION${NC}"
	echo -e "${RED}${BOLD}======================================================${NC}"
	echo ""
	echo "Worktree: $wt_path"
	echo "Owner PID: $o_pid"
	[[ -n "$o_session" ]] && echo "Owner session: $o_session"
	[[ -n "$o_created" ]] && echo "Owned since: $o_created"
	echo ""
	echo -e "${YELLOW}Use a dedicated linked worktree for this session/task to avoid cross-session edits.${NC}"
	echo ""
	exit 1
}

# Verify that this pre-edit process is running below the exact headless wrapper
# that owns the worktree registry row. Environment metadata narrows the claim to
# one worktree/session/task, while process ancestry prevents an unrelated worker
# from forging authority with copied environment values.
# Arguments: $1=worktree_path, $2=owner_pid, $3=owner_session, $4=owner_task
_headless_wrapper_owner_matches() {
	local wt_path="$1"
	local owner_pid="$2"
	local owner_session="$3"
	local owner_task="$4"
	local proof_pid="${AIDEVOPS_WORKTREE_OWNER_PID:-}"
	local proof_session="${AIDEVOPS_WORKTREE_OWNER_SESSION:-}"
	local proof_task="${AIDEVOPS_WORKTREE_OWNER_TASK:-}"
	local proof_path="${AIDEVOPS_WORKTREE_OWNER_PATH:-}"

	[[ "${AIDEVOPS_SESSION_ORIGIN:-}" == "worker" ]] || return 1
	[[ "${AIDEVOPS_HEADLESS:-}" == "true" || "${AIDEVOPS_HEADLESS:-}" == "1" ]] || return 1
	[[ "$proof_pid" =~ ^[0-9]+$ && "$owner_pid" == "$proof_pid" ]] || return 1
	[[ -n "$proof_session" && "$owner_session" == "$proof_session" ]] || return 1
	[[ -n "$proof_task" && "$owner_task" == "$proof_task" ]] || return 1
	[[ -n "$proof_path" ]] || return 1
	[[ "$(_wt_normalize_path "$wt_path")" == "$(_wt_normalize_path "$proof_path")" ]] || return 1
	kill -0 "$owner_pid" 2>/dev/null || return 1

	local current_pid="$$"
	local parent_pid=""
	local depth=0
	while [[ "$current_pid" =~ ^[0-9]+$ && "$current_pid" -gt 1 && "$depth" -lt 64 ]]; do
		[[ "$current_pid" == "$owner_pid" ]] && return 0
		parent_pid=$(_get_proc_ppid "$current_pid")
		[[ "$parent_pid" =~ ^[0-9]+$ && "$parent_pid" -gt 0 && "$parent_pid" != "$current_pid" ]] || return 1
		current_pid="$parent_pid"
		depth=$((depth + 1))
	done
	return 1
}

# Handle the canonical repo directory being off the default branch.
# This state is never writable; branch switching is not a recovery mechanism.
_handle_main_repo_off_main() {
	local branch="$1"
	echo -e "${RED}BLOCKED${NC}: canonical repository is on '$branch' instead of its default branch"
	echo "CANONICAL_STATE_INVALID=true"
	echo "$ACTION_LINKED_WORKTREE_REQUIRED"
	echo "HINT: do not switch branches in the canonical repository; coordinate canonical-recovery-helper.sh separately"
	if [[ "$LOOP_MODE" == "true" ]] || [[ ! -t 0 ]]; then
		exit 2
	fi
	exit 1
}

# Check if task is claimed by someone else via TODO.md assignee: field (t165).
# Arguments: $1=current_branch
# Outputs a warning if claimed by another identity.
_check_task_assignee() {
	local branch="$1"

	local task_id_from_branch=""
	task_id_from_branch=$(task_identity_extract_first "$branch" 2>/dev/null || true)
	[[ -z "$task_id_from_branch" ]] && return 0

	local project_root
	project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
	local todo_file="$project_root/TODO.md"
	[[ ! -f "$todo_file" ]] && return 0

	local task_id_ere=""
	task_id_ere=$(task_identity_escape_ere "$task_id_from_branch") || return 0
	local task_line
	task_line=$(grep -E "^\- \[.\] ${task_id_ere}[[:space:]]" "$todo_file" | head -1 || true)
	local task_assignee
	task_assignee=$(echo "$task_line" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || true)
	[[ -z "$task_assignee" ]] && return 0

	# Must match get_aidevops_identity() in pulse-session-helper.sh
	local my_identity
	my_identity="${AIDEVOPS_IDENTITY:-$(whoami 2>/dev/null || echo unknown)@$(hostname -s 2>/dev/null || echo local)}"
	if [[ "$task_assignee" != "$my_identity" ]]; then
		echo -e "${YELLOW}WARNING${NC}: Task $task_id_from_branch is claimed by assignee:$task_assignee"
	fi
	return 0
}

# =============================================================================
# Main branch-check logic
# =============================================================================

# Guard: not in a git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
	echo -e "${YELLOW}Not in a git repository - no worktree check needed${NC}"
	exit 0
fi

# Resolve structural worktree identity before branch handling or ownership.
canonical_policy_helper="${SCRIPT_DIR}/canonical-write-policy-helper.py"
if [[ ! -f "$canonical_policy_helper" ]]; then
	echo -e "${RED}BLOCKED${NC}: canonical-write policy helper is unavailable"
	echo "ACTION_REQUIRED=repair_canonical_write_policy"
	exit 1
fi
worktree_classification=""
if ! worktree_classification=$(python3 "$canonical_policy_helper" classify --cwd "$PWD" --field classification 2>/dev/null); then
	echo -e "${RED}BLOCKED${NC}: Git worktree identity could not be classified safely"
	echo "ACTION_REQUIRED=repair_canonical_write_policy"
	exit 1
fi

if [[ "$worktree_classification" == "canonical" ]]; then
	current_branch=$(git branch --show-current 2>/dev/null || true)
	[[ -n "$current_branch" ]] || current_branch="detached"
	[[ "$LOOP_MODE" == "true" ]] && _handle_loop_mode_on_protected "$current_branch"
	echo -e "${RED}BLOCKED${NC}: canonical checkouts are read-only session mirrors"
	echo "CANONICAL_WORKTREE=true"
	echo "$ACTION_LINKED_WORKTREE_REQUIRED"
	echo "HINT: create a safe linked worktree; use canonical-recovery-helper.sh only for audited mirror synchronization"
	if [[ ! -t 0 ]] || [[ "${FULL_LOOP_HEADLESS:-false}" == "true" ]]; then
		exit 2
	fi
	exit 1
fi
if [[ "$worktree_classification" != "linked" ]]; then
	echo -e "${RED}BLOCKED${NC}: expected a linked Git worktree, got '$worktree_classification'"
	echo "$ACTION_LINKED_WORKTREE_REQUIRED"
	exit 1
fi

# Detached HEAD is valid only inside a linked worktree (for isolated releases).
current_branch=$(git branch --show-current 2>/dev/null || echo "")
if [[ -z "$current_branch" ]]; then
	current_branch="detached-release-worktree"
fi

# Keep the OpenCode session title authoritative while OpenCode is active.
# Outside OpenCode, retain the repo/branch shell-title fallback.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

if [[ "${OPENCODE:-}" == "1" ]] && [[ -x "$SCRIPT_DIR/session-rename-helper.sh" ]]; then
	"$SCRIPT_DIR/session-rename-helper.sh" sync-branch "${OPENCODE_SESSION_ID:-}" >/dev/null 2>&1 || true
	effective_title="$("$SCRIPT_DIR/session-rename-helper.sh" effective-title "${OPENCODE_SESSION_ID:-}" 2>/dev/null || true)"
	if [[ -n "$effective_title" ]] && [[ -x "$SCRIPT_DIR/terminal-title-helper.sh" ]]; then
		"$SCRIPT_DIR/terminal-title-helper.sh" rename "$effective_title" 2>/dev/null || true
	fi
elif [[ -x "$SCRIPT_DIR/terminal-title-helper.sh" ]]; then
	"$SCRIPT_DIR/terminal-title-helper.sh" sync 2>/dev/null || true
fi

# Linked worktree ownership gate (GH#14413 hardening):
# exactly one active session/process may hold a writable worktree at a time.
worktree_path=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
worktree_owner_pid="${OPENCODE_PID:-${PRE_EDIT_OWNER_PID:-${PPID:-$$}}}"
worktree_owner_session="${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"

if declare -f claim_worktree_ownership >/dev/null 2>&1; then
	if ! claim_worktree_ownership "$worktree_path" "$current_branch" --owner-pid "$worktree_owner_pid" --session "$worktree_owner_session"; then
		owner_info=$(check_worktree_owner "$worktree_path" 2>/dev/null || true)
		owner_pid="unknown"
		owner_session=""
		owner_task=""
		owner_created=""
		if [[ -n "$owner_info" ]]; then
			IFS='|' read -r owner_pid owner_session _ owner_task owner_created <<<"$owner_info"
		fi
		if ! _headless_wrapper_owner_matches "$worktree_path" "$owner_pid" "$owner_session" "$owner_task"; then
			_handle_ownership_conflict "$worktree_path" "$owner_pid" "$owner_session" "$owner_created"
		fi
	fi
fi

# --- Linked worktree (correct working context) ---

_check_task_assignee "$current_branch"

# Operation verification gate (t1364.3)
if [[ -n "$VERIFY_OP" ]]; then
	run_operation_verification "$VERIFY_OP"
fi

# Session count warning (t1398.4) — non-blocking, informational only
if [[ -x "$SCRIPT_DIR/session-count-helper.sh" ]]; then
	session_warning=$("$SCRIPT_DIR/session-count-helper.sh" check || true)
	if [[ -n "$session_warning" ]]; then
		echo -e "${YELLOW}${session_warning}${NC}"
	fi
fi

# GH#21900: Shallow clone warning — non-blocking, warn once per session start.
# A shallow clone will cause add/add conflict cascades if commit-and-pr is run.
# Auto-unshallow fires inside _rebase_and_push; this is an early advisory so
# the operator can fix proactively before attempting a rebase.
_shallow_clone_check=$(git rev-parse --is-shallow-repository 2>/dev/null || echo "false")
if [[ "$_shallow_clone_check" == "true" ]]; then
	echo -e "${YELLOW}WARNING: This git clone is shallow (depth-limited).${NC}"
	echo -e "${YELLOW}  commit-and-pr will attempt auto-unshallow before rebase.${NC}"
	echo -e "${YELLOW}  To fix now: git fetch --unshallow origin${NC}"
	echo -e "${YELLOW}  See .agents/reference/git-hygiene.md for details.${NC}"
fi

# go for it — linked worktree is the correct working context
echo -e "${GREEN}OK${NC} - In linked worktree on ref: ${BOLD}$current_branch${NC}"
exit 0
