#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# claim-task-id.sh - Atomic task ID allocation via .task-counter file
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   claim-task-id.sh [options]
#
# Options:
#   --title "Task title"       Task title for GitHub/GitLab issue (required unless --batch)
#   --description "Details"    Task description (required for issue creation unless
#                              a brief file exists at todo/tasks/{task_id}-brief.md)
#   --labels "label1,label2"   Comma-separated labels (optional)
#   --count N                  Allocate N consecutive IDs (default: 1)
#                              Creates one GitHub/GitLab issue per ID using
#                              the same --title. Output includes ref_tNNN=GH#NNN
#                              for each created issue.
#   --offline                  Force offline mode (skip remote push)
#   --no-issue                 Skip GitHub/GitLab issue creation
#   --dry-run                  Show what would be allocated without changes
#   --repo-path PATH           Path to git repository (default: current directory)
#   --remote NAME              Git remote name for counter branch (default: origin,
#                              or value from .aidevops.json "remote" key)
#   --counter-branch BRANCH    Branch holding .task-counter (config value first;
#                              otherwise a validated task-id-counter branch,
#                              then main)
#   --skip-label-validation    Skip pre-flight label existence check (useful for
#                              bulk --count N allocation or when gh is rate-limited)
#   --no-blocked-by            Suppress auto-detection of predecessor references
#                              and blocked-by tag emission (GH#20834)
#   --parent-issue N           Declare a parent issue for this task (t2838).
#                              Injects a `Parent: #N` line at the end of the
#                              composed body and links the new issue as a
#                              sub-issue of #N via GitHub's addSubIssue API.
#                              Idempotent — duplicate-relationship errors are
#                              suppressed. Use for decomposition children
#                              filed outside shared-phase-filing.sh.
#
# Project-level config (.aidevops.json in repo root):
#   {
#     "remote": "upstream",
#     "default_branch": "main",
#     "counter_branch": "task-id-counter"
#   }
#   Keys:
#     remote          - git remote name (default: "origin")
#     default_branch  - informational default branch name (not used by CAS)
#     counter_branch  - explicit branch that holds .task-counter; when omitted,
#                       a validated task-id-counter branch is preferred over main
#   CLI flags --remote and --counter-branch override .aidevops.json values.
#
# Exit codes:
#   0  - Success (outputs: task_id=tNNN ref=GH#NNN or GL#NNN)
#   1  - Error (network failure, git error, etc.)
#   2  - Offline fallback used (outputs: task_id=tNNN ref=offline)
#   3  - Invalid --labels argument(s): counter NOT advanced (t2800)
#   4  - Counter branch requires pull requests: counter NOT advanced
#   10 - User declined claim after duplicate warning (interactive TTY only, t2180)
#
# Algorithm (CAS loop — compare-and-swap via git push):
#   1. git fetch <remote> <counter_branch>
#   2. Read <remote>/<counter_branch>:.task-counter → current value (e.g. 1048)
#   3. Claim IDs: 1048 to 1048+count-1
#   4. Write 1048+count to .task-counter
#   5. git commit .task-counter && git push <remote> HEAD:<counter_branch>
#   6. If push fails (conflict) → retry from step 1 (max CAS_MAX_RETRIES attempts,
#      default 30, with CAS_WALL_TIMEOUT_S wall-clock cap, default 30s — GH#20137)
#   7. On success, create GitHub/GitLab issue per ID (optional, non-blocking)
#
# The .task-counter file is the single source of truth for the next
# available task ID. It contains one integer. Every allocation atomically
# increments it via a git push, which fails on conflict — guaranteeing
# no two sessions can claim the same ID.
#
# Offline fallback:
#   - Reads local .task-counter + 100 offset to avoid collisions
#   - If local .task-counter is missing, bootstraps from TODO.md highest ID
#   - Reconciliation required when back online
#
# Auto-bootstrap (GH#6569 — repo-agnostic):
#   - If .task-counter is missing on remote, bootstrap_remote_counter() seeds it
#   - Seed precedence: highest task ID in TODO.md + 1, otherwise 1
#   - Bootstrap uses the same CAS git plumbing — safe from any branch
#   - Emits BOOTSTRAP_COUNTER_OK / BOOTSTRAP_COUNTER_FAILED for observability
#   - Concurrent bootstrap: if another session wins the push, we retry read
#
# Migration from TODO.md scanning:
#   - If .task-counter doesn't exist, initialize from TODO.md highest ID
#   - First run creates .task-counter and commits to <remote>/<counter_branch>
#
# Concurrent load / rebase safety (t2229):
#   Under concurrent load, branches forked before other sessions claimed IDs
#   carry a stale .task-counter. On PR merge, the stale value would overwrite
#   the current one — silently duplicating IDs. Three defences:
#     1. .gitattributes merge=ours (non-squash merges)
#     2. .github/workflows/counter-monotonic.yml CI check (all merge strategies)
#     3. full-loop-helper.sh _rebase_and_push auto-resets drifted counter
#   Always rebase onto origin/main before pushing a branch that touched
#   .task-counter: `git fetch origin main && git rebase origin/main`
#
# Platform detection:
#   - Checks git remote URL for github.com, gitlab.com, gitea
#   - Uses gh CLI for GitHub, glab CLI for GitLab
#   - Falls back to --no-issue if CLI not available
#
# Sub-libraries (split from this file in GH#20224):
#   - claim-task-id-counter.sh  CAS counter/allocation functions
#   - claim-task-id-issue.sh    issue creation helpers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# t2063: Source issue-sync-lib.sh for shared body composition helpers
# (_compose_issue_worker_guidance, _compose_issue_brief, _compose_issue_html_notes_and_footer).
# Guarded against double-sourcing when claim-task-id.sh itself is sourced from another script.
if [[ -z "${ISSUE_SYNC_LIB_SOURCED:-}" ]] && [[ -f "${SCRIPT_DIR}/issue-sync-lib.sh" ]]; then
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/issue-sync-lib.sh"
	ISSUE_SYNC_LIB_SOURCED=1
fi

# GH#20224: Source sub-libraries extracted from this file to reduce size.
# shellcheck source=./claim-task-id-counter.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/claim-task-id-counter.sh"
# shellcheck source=./claim-task-id-issue.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/claim-task-id-issue.sh"

set -euo pipefail

# Configuration
OFFLINE_MODE=false
DRY_RUN=false
NO_ISSUE=false
SKIP_LABEL_VALIDATION=false
NO_BLOCKED_BY=false
TASK_TITLE=""
TASK_DESCRIPTION=""
TASK_LABELS=""
# t2838: populated by --parent-issue N; read by _compose_issue_body for body
# injection and create_github_issue / _try_issue_sync_delegation for explicit
# addSubIssue mutation after issue creation.
PARENT_ISSUE_NUM=""
# GH#20834: populated by _detect_predecessor_refs; read by _ensure_todo_entry_written
_CLAIM_BLOCKED_BY_REFS=""
REPO_PATH="$PWD"
ALLOC_COUNT=1
OFFLINE_OFFSET=100
CAS_MAX_RETRIES=${CAS_MAX_RETRIES:-30}
# Wall-clock timeout for the entire CAS retry loop (seconds).  If the loop
# exceeds this, it aborts regardless of how many retries remain.  Prevents
# 180s+ hangs under concurrent-worker contention (GH#20137).
CAS_WALL_TIMEOUT_S=${CAS_WALL_TIMEOUT_S:-30}
# Per-git-command timeout (seconds).  Wraps git fetch/push in the CAS path
# to prevent indefinite hangs on index.lock contention or network stalls.
CAS_GIT_CMD_TIMEOUT_S=${CAS_GIT_CMD_TIMEOUT_S:-10}
# GH#21904: wall-clock timeout for each individual remote `git fetch`/`git
# push` call in the CAS path. The CAS push runs its pre-push hook separately,
# then uses `git push --no-verify`, so local validation no longer consumes this
# transport budget (GH#29417). Distinct from CAS_GIT_CMD_TIMEOUT_S which only
# sets git's `http.lowSpeedTime` after bytes start flowing.
# Memory: mem_20260430054453_5f0d112e (HTTPS push hung; SSH workaround verified).
CAS_HTTPS_TIMEOUT_S=${CAS_HTTPS_TIMEOUT_S:-30}
# Pre-push validation can include the repository's full format/lint/typecheck
# gate. Give that local work its own budget and classify its timeout as a hard
# validation failure rather than CAS contention. The hook still runs exactly
# once before either HTTPS or SSH transport is attempted.
CAS_HOOK_TIMEOUT_S=${CAS_HOOK_TIMEOUT_S:-300}
# GH#21904: when 1 (default), a `git fetch`/`git push` that times out on an
# HTTPS GitHub remote is retried once via the SSH-equivalent URL.  Set to 0
# to disable fallback (e.g. on hosts where SSH to github.com is blocked and
# only the HTTPS hang is the failure mode being investigated).
CAS_SSH_FALLBACK_ENABLED=${CAS_SSH_FALLBACK_ENABLED:-1}
# When true (default), CAS retry exhaustion in online mode is fatal — does NOT
# silently fall through to allocate_offline with +100 offset.  The offline path
# exists for genuinely-offline scenarios (no network, explicit --offline flag),
# not for contention failures on a reachable remote.  Set to 0 to restore the
# legacy silent-fallback behaviour.
CAS_EXHAUSTION_FATAL=${CAS_EXHAUSTION_FATAL:-1}
CAS_RECONCILE_RETRY_ON_FAILURE=${CAS_RECONCILE_RETRY_ON_FAILURE:-1}
COUNTER_FILE=".task-counter"
# Remote and branch — defaults; overridden by .aidevops.json and/or CLI flags
REMOTE_NAME="origin"
COUNTER_BRANCH="main"
DEFAULT_BRANCH="main"
# Track whether CLI flags or project config explicitly selected these values.
# CLI still wins because config loading only applies while the flag is false.
_REMOTE_NAME_SET=false
_COUNTER_BRANCH_SET=false

# Logging (all to stderr so stdout is machine-readable)
# Logging: uses shared log_* from shared-constants.sh

# Load project-level config from .aidevops.json in the repo root.
# Populates REMOTE_NAME and COUNTER_BRANCH unless already set by CLI flags.
# Requires: jq (optional — silently skipped if not installed).
load_project_config() {
	local repo_path="$1"
	local config_file="${repo_path}/.aidevops.json"

	if [[ ! -f "$config_file" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		log_warn ".aidevops.json found but jq is not installed — project config ignored"
		return 0
	fi

	log_info "Loading project config from .aidevops.json"

	local remote_val counter_branch_val default_branch_val
	remote_val=$(jq -r '.remote // empty' "$config_file" 2>/dev/null || true)
	counter_branch_val=$(jq -r '.counter_branch // empty' "$config_file" 2>/dev/null || true)
	default_branch_val=$(jq -r '.default_branch // empty' "$config_file" 2>/dev/null || true)

	# CLI flags take precedence over config file
	if [[ -n "$remote_val" ]] && [[ "$_REMOTE_NAME_SET" == "false" ]]; then
		REMOTE_NAME="$remote_val"
		log_info "remote set from .aidevops.json: $REMOTE_NAME"
	fi

	if [[ -n "$counter_branch_val" ]] && [[ "$_COUNTER_BRANCH_SET" == "false" ]]; then
		COUNTER_BRANCH="$counter_branch_val"
		_COUNTER_BRANCH_SET=true
		log_info "counter_branch set from .aidevops.json: $COUNTER_BRANCH"
	fi

	if [[ -n "$default_branch_val" ]]; then
		DEFAULT_BRANCH="$default_branch_val"
		log_info "default_branch set from .aidevops.json: $DEFAULT_BRANCH"
	fi

	return 0
}

# Extract hashtags from text and convert to comma-separated labels
extract_hashtags() {
	local text="$1"
	local tags=""

	while [[ "$text" =~ \#([a-zA-Z0-9_-]+) ]]; do
		local tag="${BASH_REMATCH[1]}"
		if [[ -n "$tags" ]]; then
			tags="${tags},${tag}"
		else
			tags="$tag"
		fi
		text="${text#*#"${tag}"}"
	done

	echo "$tags"
}

# Parse arguments
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			TASK_TITLE="$2"
			shift 2
			;;
		--description)
			TASK_DESCRIPTION="$2"
			shift 2
			;;
		--labels)
			TASK_LABELS="$2"
			shift 2
			;;
		--count)
			ALLOC_COUNT="$2"
			if ! [[ "$ALLOC_COUNT" =~ ^[0-9]+$ ]] || [[ "$ALLOC_COUNT" -lt 1 ]]; then
				log_error "--count must be a positive integer"
				exit 1
			fi
			shift 2
			;;
		--offline)
			OFFLINE_MODE=true
			shift
			;;
		--no-issue)
			NO_ISSUE=true
			shift
			;;
		--skip-label-validation)
			SKIP_LABEL_VALIDATION=true
			shift
			;;
		--no-blocked-by)
			NO_BLOCKED_BY=true
			shift
			;;
		--parent-issue)
			# Use ${2:-} so set -u doesn't abort before our validation
			# block can emit a friendly error for missing values.
			PARENT_ISSUE_NUM="${2:-}"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--repo-path)
			REPO_PATH="$2"
			shift 2
			;;
		--remote)
			REMOTE_NAME="$2"
			_REMOTE_NAME_SET=true
			shift 2
			;;
		--counter-branch)
			COUNTER_BRANCH="$2"
			_COUNTER_BRANCH_SET=true
			shift 2
			;;
		--help)
			grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
			exit 0
			;;
		*)
			log_error "Unknown option: $1"
			exit 1
			;;
		esac
	done

	_validate_and_normalize_args
}

# Post-parse validation + label normalization. Extracted from parse_args
# (t2838) to keep that function under the function-complexity gate. Runs
# after the option-parser loop completes — never invoked directly.
_validate_and_normalize_args() {
	# Validate batch size
	if [[ "$ALLOC_COUNT" -lt 1 ]]; then
		log_error "Allocation count must be >= 1"
		exit 1
	fi

	# t2838: validate --parent-issue if supplied. Regex rejects 0 and
	# leading-zero forms — GitHub issue numbers are always >=1, and #0
	# resolves to null on the GraphQL side which produces confusing
	# behaviour downstream.
	if [[ -n "$PARENT_ISSUE_NUM" ]] && ! [[ "$PARENT_ISSUE_NUM" =~ ^[1-9][0-9]*$ ]]; then
		log_error "--parent-issue requires a positive integer issue number (got: '$PARENT_ISSUE_NUM')"
		exit 1
	fi

	# Title is required unless batch mode
	if [[ -z "$TASK_TITLE" ]] && [[ "$ALLOC_COUNT" -eq 1 ]]; then
		log_error "Missing required argument: --title (or use --count N for bulk allocation)"
		exit 1
	fi

	# Auto-extract hashtags from title if no labels provided
	if [[ -n "$TASK_TITLE" ]] && [[ -z "$TASK_LABELS" ]]; then
		local extracted_tags
		extracted_tags=$(extract_hashtags "$TASK_TITLE")
		if [[ -n "$extracted_tags" ]]; then
			TASK_LABELS="$extracted_tags"
			log_info "Auto-extracted labels from title: $TASK_LABELS"
		fi
	fi

	# t2436: Normalise tag aliases via map_tags_to_labels so that callers
	# passing --labels "parent" get "parent-task" (not a bare "parent" label).
	# map_tags_to_labels is sourced from issue-sync-lib.sh at top of this file.
	# 2>/dev/null || true: silently swallows command-not-found if lib unavailable.
	if [[ -n "$TASK_LABELS" ]]; then
		local _normalised_labels=""
		_normalised_labels=$(map_tags_to_labels "$TASK_LABELS" 2>/dev/null) || true
		[[ -n "$_normalised_labels" ]] && TASK_LABELS="$_normalised_labels"
		TASK_LABELS=$(_dedupe_csv_labels "$TASK_LABELS")
	fi

	# GH#21991: advisory structural check on --description before issue creation.
	# Non-blocking by default; set AIDEVOPS_BODY_FORMAT_STRICT=1 to hard-fail.
	_validate_description_format
	return 0
}

# _dedupe_csv_labels — preserve first occurrence while removing duplicate labels.
# GitHub ultimately deduplicates applied labels, but keeping the argv clean avoids
# duplicate-label warnings/noise in tests and wrapper fallbacks.
_dedupe_csv_labels() {
	local labels_csv="$1"
	local result=""
	local label=""
	local trimmed=""
	local -a label_arr=()
	IFS=',' read -r -a label_arr <<<"$labels_csv"
	for label in "${label_arr[@]}"; do
		trimmed="${label#"${label%%[![:space:]]*}"}"
		trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
		[[ -z "$trimmed" ]] && continue
		if [[ ",${result}," == *",${trimmed},"* ]]; then
			continue
		fi
		if [[ -n "$result" ]]; then
			result="${result},${trimmed}"
		else
			result="$trimmed"
		fi
	done
	printf '%s\n' "$result"
	return 0
}

# _validate_description_format — run structural lint on TASK_DESCRIPTION.
# Called at the end of _validate_and_normalize_args (GH#21991).
# Advisory by default; AIDEVOPS_BODY_FORMAT_STRICT=1 hard-fails on non-dispatchable.
# Skipped when: --no-issue, --dry-run, empty description, or helper unavailable.
_validate_description_format() {
	# Skip when issue creation is not happening or description is absent
	[[ "$NO_ISSUE" == "true" || "$DRY_RUN" == "true" ]] && return 0
	[[ -z "$TASK_DESCRIPTION" ]] && return 0

	local fmt_helper="${SCRIPT_DIR}/issue-body-format-helper.sh"
	[[ ! -x "$fmt_helper" ]] && return 0

	local rc=0
	"$fmt_helper" check "$TASK_DESCRIPTION" || rc=$?

	# Exit 1 from helper = non-dispatchable body
	if [[ $rc -eq 1 && "${AIDEVOPS_BODY_FORMAT_STRICT:-0}" != "1" ]]; then
		# Advisory only — already warned via helper's log_warn calls.
		rc=0
	fi
	return $rc
}

# t2436: Scan TODO.md for the task entry matching task_id and derive
# creation-time labels from its tags. Closes the race window where
# parent-task (and other protected labels) would otherwise only be applied
# by the asynchronous issue-sync workflow triggered on a TODO.md push.
#
# Called after the task ID is allocated (so it is present in TODO.md when
# the maintainer pre-wrote the entry before claiming) and before issue
# creation. Non-blocking — returns empty string on any failure.
#
# Arguments:
#   $1 - task_id (e.g. t2436)
#   $2 - repo_path
# Outputs comma-separated label names on stdout. Empty if not found or no tags.
_scan_todo_labels_for_task() {
	local task_id="$1"
	local repo_path="$2"
	local todo_file="${repo_path}/TODO.md"

	[[ -z "$task_id" || ! -f "$todo_file" ]] && return 0

	# Find the task line matching the task ID (active or completed).
	# The pattern anchors to the start of the line to avoid matching
	# sub-task IDs (e.g. t2436.1) as the parent t2436.
	local task_line
	task_line=$(grep -m1 -E "^[[:space:]]*-[[:space:]]\[.\][[:space:]]*${task_id}([[:space:]]|\.|$)" \
		"$todo_file" 2>/dev/null || echo "")
	[[ -z "$task_line" ]] && return 0

	# Extract hashtags — mirrors parse_task_line() in issue-sync-lib.sh.
	local tags
	tags=$(printf '%s' "$task_line" | grep -oE '#[a-z][a-z0-9-]*' | tr '\n' ',' | sed 's/,$//')
	[[ -z "$tags" ]] && return 0

	# Convert tags to labels via the shared resolver.
	# map_tags_to_labels() is sourced from issue-sync-lib.sh at top of this file.
	# 2>/dev/null || true: silently swallows command-not-found if lib unavailable.
	local derived_labels=""
	derived_labels=$(map_tags_to_labels "$tags" 2>/dev/null) || true
	[[ -n "$derived_labels" ]] && echo "$derived_labels"
	return 0
}

# Detect git platform from remote URL
detect_platform() {
	local remote_url
	remote_url=$(cd "$REPO_PATH" && git remote get-url "$REMOTE_NAME" 2>/dev/null || echo "")

	if [[ -z "$remote_url" ]]; then
		echo "unknown"
		return
	fi

	if [[ "$remote_url" =~ github\.com ]]; then
		echo "github"
	elif [[ "$remote_url" =~ gitlab\.com ]]; then
		echo "gitlab"
	elif [[ "$remote_url" =~ gitea ]]; then
		echo "gitea"
	else
		echo "unknown"
	fi
}

# Check if CLI tool is available
check_cli() {
	local platform="$1"

	case "$platform" in
	github)
		command -v gh &>/dev/null && return 0
		;;
	gitlab)
		command -v glab &>/dev/null && return 0
		;;
	esac

	return 1
}

# Create GitHub issue (post-allocation, non-blocking)
# t1324: Delegates to issue-sync-helper.sh push when available for rich
# issue bodies, proper labels (including auto-dispatch), and duplicate
# detection. Falls back to bare gh issue create if helper not found.
# t2548: Guarantees TODO.md entry after verified issue creation on both paths.
create_github_issue() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"

	cd "$repo_path" || return 1

	# t2548: extract task_id once — used on both creation paths to write
	# the TODO.md entry after verified issue creation.
	local _task_id_for_todo=""
	[[ "$title" =~ ^(t[0-9]+(\.[0-9]+)*) ]] && _task_id_for_todo="${BASH_REMATCH[1]}"

	# t2442: resolve repo slug once — used both by the delegation path
	# and the bare-fallback path for the parent-task warn call. Must run
	# BEFORE delegation because the delegation branch returns early.
	local _slug_for_warn=""
	_slug_for_warn=$(_extract_github_slug "$repo_path" "${REMOTE_NAME:-origin}")

	# Try rich delegation first (t1324)
	local issue_num
	if issue_num=$(_try_issue_sync_delegation "$title" "$repo_path"); then
		_auto_assign_issue "$issue_num" "$repo_path"
		_interactive_session_auto_claim_new_task "$issue_num" "$repo_path"
		_lock_maintainer_issue_at_creation "$issue_num" "$repo_path"
		# t2838: explicit sub-issue link when --parent-issue N was supplied.
		# Delegation path goes through gh_create_issue → _gh_auto_link_sub_issue
		# wrapper which DOES detect the Parent: line, but we re-run the helper
		# defensively in case the wrapper's detector misses (different body
		# composition path). Idempotent: addSubIssue swallows duplicates.
		_link_parent_issue_post_create "$issue_num" "$repo_path"
		# t2548: ensure TODO.md has the entry. On the delegation path
		# issue-sync-helper.sh _push_process_task silently returns SKIPPED
		# when the task line is absent from TODO.md — issue is created but
		# TODO never written. This call closes that gap idempotently.
		if ! _converge_created_issue_ref \
			"$_task_id_for_todo" "$issue_num" "$title" "$labels" "$repo_path"; then
			log_warn "Delegated issue #${issue_num}, but failed to persist task mapping for ${_task_id_for_todo}"
			return 1
		fi
		# t2442: warn if parent-task label applied but body has no markers.
		# The delegation path creates the issue via issue-sync-helper.sh
		# cmd_push which ALREADY fires this warn — so we skip here to
		# avoid duplicate comments. The bare-fallback path below runs the
		# warn unconditionally because it uses `gh issue create` directly.
		echo "$issue_num"
		return 0
	fi

	# Dedup check before bare creation (t1446)
	if issue_num=$(_check_duplicate_issue "$title"); then
		# GH#22381: issue-sync-helper.sh push can create the issue but emit no
		# parseable number. The duplicate lookup then recovers the issue number;
		# stamp/verify TODO.md before reporting success so dispatchability sees
		# the same state as the returned issue number.
		if ! _converge_created_issue_ref \
			"$_task_id_for_todo" "$issue_num" "$title" "$labels" "$repo_path"; then
			log_warn "Recovered issue #${issue_num}, but failed to persist task mapping for ${_task_id_for_todo}"
			return 1
		fi
		echo "$issue_num"
		return 0
	fi

	# Fallback: bare issue creation with structured body.
	# t3039: use gh_create_issue (REST-aware wrapper, from shared-gh-wrappers.sh sourced
	# transitively via shared-constants.sh) instead of raw gh issue create so that issue
	# creation succeeds even when GraphQL is exhausted (the "fallback also uses GraphQL"
	# failure mode observed at GraphQL=0/5000).
	local create_args=(--title "$title")
	# Pass --repo explicitly so the REST fallback path inside gh_create_issue
	# can build the /repos/{owner}/{repo}/issues endpoint without relying on cwd
	# (t3039: _rest_issue_create requires --repo).
	[[ -n "$_slug_for_warn" ]] && create_args+=(--repo "$_slug_for_warn")

	local body=""
	local compose_rc=0
	body=$(_compose_issue_body "$title" "$description") || compose_rc=$?
	# t1937: If body composition failed (no description + no brief), skip issue creation.
	# The task ID is already secured — issue can be created later with proper content.
	if [[ $compose_rc -ne 0 || -z "$body" ]]; then
		log_warn "Skipping issue creation — no description available. Task ID is secured."
		return 1
	fi
	create_args+=(--body "$body")

	# t2789: Ensure new issues are immediately dispatchable by applying
	# status:available when the caller did not specify any status:* label.
	# Without this default, new issues have no status label, and the pulse
	# dispatcher's candidate filter (which requires status:available) skips
	# them entirely until a human or downstream process labels them.
	# Callers that pass an explicit status:* (e.g. status:queued, status:blocked,
	# status:in-review) are respected verbatim — this only fills the gap.
	if [[ ",${labels}," != *",status:"* ]]; then
		if [[ -n "$labels" ]]; then
			labels="${labels},status:available"
		else
			labels="status:available"
		fi
	fi
	[[ -n "$labels" ]] && labels=$(_dedupe_csv_labels "$labels")

	# Pass labels to gh_create_issue; origin label is appended automatically by
	# the wrapper (avoids duplicate-label injection, t3039).
	[[ -n "$labels" ]] && create_args+=(--label "$labels")

	local issue_url
	if ! issue_url=$(gh_create_issue "${create_args[@]}" 2>&1); then
		log_warn "Failed to create GitHub issue: $issue_url"
		return 1
	fi

	# Extract issue number from the GitHub URL pattern (/issues/NNN).
	# gh_create_issue captures stderr via 2>&1, so $issue_url may contain
	# log lines like "[INFO] ... per t2157" whose trailing digits would
	# match a naive '[0-9]+$' pattern, producing phantom numbers. Anchoring
	# to the URL shape (/issues/NNN) is immune to log message contamination.
	# Capture the last /issues/NNN match to defend against future multi-line URL
	# output (t3039/GH#21770), while avoiding echo and a multi-process pipeline.
	issue_num=$(printf '%s\n' "$issue_url" | awk 'match($0, /\/issues\/[0-9]+/) { num=substr($0, RSTART + 8, RLENGTH - 8) } END { print num }')

	if [[ -z "$issue_num" ]]; then
		log_warn "Failed to extract issue number from: $issue_url"
		return 1
	fi

	# Auto-assign to current user to prevent duplicate dispatch
	_auto_assign_issue "$issue_num" "$repo_path"
	_interactive_session_auto_claim_new_task "$issue_num" "$repo_path"

	# Lock maintainer/worker issues at creation to prevent comment
	# prompt-injection. Issues created by the maintainer or their workers
	# are implementation targets, not discussion threads. External
	# contributor issues are left unlocked for community interaction.
	_lock_maintainer_issue_at_creation "$issue_num" "$repo_path"

	# t2838: explicit sub-issue link when --parent-issue N was supplied.
	# Bare path uses raw `gh issue create` which BYPASSES gh_create_issue
	# and therefore the _gh_auto_link_sub_issue wrapper — without this
	# call, the Parent: body line stays prose-only and the GitHub
	# sub-issue relationship field is never populated. Idempotent.
	_link_parent_issue_post_create "$issue_num" "$repo_path"

	# Sync parent-child and blocked-by relationships (GH#18735)
	# The rich delegation path (issue-sync-helper.sh push) handles this
	# automatically; the bare fallback needs an explicit call.
	local task_id_for_rels=""
	[[ "$title" =~ ^(t[0-9]+(\.[0-9]+)*) ]] && task_id_for_rels="${BASH_REMATCH[1]}"
	if [[ -n "$task_id_for_rels" && -f "$repo_path/TODO.md" ]]; then
		local sync_helper="${SCRIPT_DIR}/issue-sync-helper.sh"
		if [[ -x "$sync_helper" ]]; then
			"$sync_helper" relationships "$task_id_for_rels" >/dev/null 2>&1 || true
		fi
	fi

	# t2442: post the parent-task no-markers warning if this issue was
	# created with the `parent-task` label but the body lacks phase/children
	# markers. Only fires on the bare-fallback path; the delegation path
	# above runs the warn inside issue-sync-helper.sh cmd_push.
	# Non-blocking: failure is silent (try/true).
	if [[ -n "$_slug_for_warn" && ",${labels}," == *",parent-task,"* ]]; then
		if declare -F _parent_body_has_phase_markers >/dev/null 2>&1 && \
			declare -F _post_parent_task_no_markers_warning >/dev/null 2>&1; then
			if ! _parent_body_has_phase_markers "$body"; then
				_post_parent_task_no_markers_warning "$_slug_for_warn" "$issue_num" || true
			fi
		fi
	fi

	# t2548: ensure TODO.md has an entry for this task. The bare-fallback
	# path creates the issue via `gh issue create` directly and never goes
	# through issue-sync-helper.sh, so _push_process_task never runs and
	# the TODO entry is never written. This call closes that gap idempotently.
	# GH#21473: pass $title (one-liner), not $description (full body).
	if ! _converge_created_issue_ref \
		"$_task_id_for_todo" "$issue_num" "$title" "$labels" "$repo_path"; then
		log_warn "Created issue #${issue_num}, but failed to persist task mapping for ${_task_id_for_todo}"
		return 1
	fi

	echo "$issue_num"
	return 0
}

# Framework routing guard (GH#5149)
# Warns when claim-task-id.sh is called from a non-aidevops repo with a title
# that contains framework-level indicators. This catches the most common failure
# mode: workers creating framework tasks in project repos.
#
# This is a WARN, not a block — the worker may have a legitimate reason to
# allocate an ID in the current repo (e.g., a project-level task that happens
# to mention a framework script). The warning surfaces the routing question
# so the worker can make an explicit decision.
check_framework_routing() {
	local title="$1"
	local repo_path="$2"

	# Skip if no title (batch mode) or if explicitly suppressed
	[[ -z "$title" ]] && return 0
	if [[ "${SKIP_FRAMEWORK_ROUTING_CHECK:-}" == "true" ]]; then
		log_info "SKIP_FRAMEWORK_ROUTING_CHECK=true — suppressing framework routing warning for: $title (GH#20146 audit)"
		return 0
	fi

	# Check if we're already in the aidevops repo — no routing needed
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
	if printf '%s' "$remote_url" | grep -qE "marcusquinn/aidevops(\.git)?$"; then
		return 0
	fi

	# Check if the title contains framework-level indicators
	local framework_helper="${SCRIPT_DIR}/framework-issue-helper.sh"
	if [[ ! -x "$framework_helper" ]]; then
		return 0
	fi

	local detection_result
	detection_result=$("$framework_helper" detect "$title" 2>/dev/null || echo "project")

	if [[ "$detection_result" == "framework" ]]; then
		log_warn "FRAMEWORK ROUTING WARNING (GH#5149):"
		log_warn "  Title contains framework-level indicators: $title"
		log_warn "  You are in: $repo_path"
		log_warn "  Framework issues should be filed on marcusquinn/aidevops, not this repo."
		log_warn "  Use instead: framework-issue-helper.sh log --title \"$title\""
		log_warn "  To suppress this warning: SKIP_FRAMEWORK_ROUTING_CHECK=true claim-task-id.sh ..."
		log_warn "  Proceeding with allocation in current repo (override if intentional)."
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Pre-flight label validation (t2800)
#
# Validates that every label in TASK_LABELS exists in the target repo before
# the CAS counter is advanced. An invalid label currently causes issue creation
# to fail AFTER the counter has been incremented, stranding the task ID.
#
# Approach (A) — validate first, abort early:
#   1. Fetch the repo's label list once via `gh label list`, cache in a session
#      temp file ($AIDEVOPS_LABEL_CACHE_FILE or auto-created).
#   2. Split TASK_LABELS on comma, trim whitespace, grep-check each against cache.
#   3. Any missing label → log which labels are invalid + lookup command → return 1.
#   4. API failure during list → fail-open (skip validation, let issue creation
#      fail naturally; the caller can then recover using approach B — label-after-create).
#
# Exit codes (for _validate_labels_exist):
#   0  - All labels exist (or validation skipped / fail-open).
#   1  - One or more labels are invalid.
#
# Call site exits with code 3 (invalid-labels) if this returns 1.
# Skipped when: --skip-label-validation, --offline, --dry-run, --no-issue,
#               no labels provided, platform != github, or gh not available.
# ---------------------------------------------------------------------------

# _extract_github_slug — extract owner/repo slug from a git remote URL.
# Args: $1 repo_path, $2 remote_name (default: origin).
# Prints the slug (owner/repo) on stdout; prints nothing on failure.
_extract_github_slug() {
	local repo_path="$1"
	local remote_name="${2:-origin}"
	git -C "$repo_path" remote get-url "$remote_name" 2>/dev/null \
		| sed 's|.*github\.com[:/]||;s|\.git$||' || true
	return 0
}

# _auto_create_blocked_by_label — create a missing blocked-by:tNNN / blocked-by:GH#NNN /
# blocked-by:#NNN label in the repo when it does not yet exist.
# Updates the session label cache on success.
# Args: $1 repo_slug (owner/repo), $2 label name (e.g. "blocked-by:t324"), $3 cache_file path.
# Returns: 0 = label created (or already exists), 1 = creation failed (rate limit / permission).
# Callers MUST treat a non-zero return as a validation error — do NOT use || true (GH#21633).
_auto_create_blocked_by_label() {
	local repo_slug="$1"
	local label="$2"
	local cache_file="$3"
	local predecessor="${label#blocked-by:}"

	if gh label create "$label" --repo "$repo_slug" \
		--color "5319E7" \
		--description "Blocked by predecessor task ${predecessor}" \
		>/dev/null 2>&1; then
		# Append to session cache so subsequent lookups in this invocation hit
		printf '%s\n' "$label" >>"$cache_file" 2>/dev/null || true
		log_info "Auto-created label '${label}' in ${repo_slug} (t2823/t2800 auto-create exception)"
		return 0
	else
		log_warn "Could not auto-create label '${label}' in ${repo_slug} (rate limit or permission) — proceeding without it"
		return 1
	fi
}

# _validate_labels_exist — check that every label in $2 exists in repo $1.
# Args: $1 repo_slug (owner/repo), $2 comma-separated label names.
# Returns: 0 = all valid (or fail-open), 1 = invalid labels found.
#
# Auto-create exception (GH#21474): labels matching ^blocked-by:(t[0-9]+|GH#[0-9]+|#[0-9]+)$
# are auto-created when missing — they are a deterministic function of the predecessor
# task ID and safe to create on demand. Creation failure aborts the claim (GH#21633).
# All other invalid labels still abort (exit 3).
_validate_labels_exist() {
	local repo_slug="$1"
	local labels_csv="$2"

	[[ -z "$repo_slug" || -z "$labels_csv" ]] && return 0

	# Require gh CLI and authentication
	command -v gh >/dev/null 2>&1 || return 0
	gh auth status >/dev/null 2>&1 || return 0

	# Populate label cache once per session (or reuse if already set)
	local cache_file="${AIDEVOPS_LABEL_CACHE_FILE:-}"
	if [[ -z "$cache_file" ]]; then
		cache_file=$(mktemp /tmp/aidevops-label-cache-XXXXXX 2>/dev/null) || return 0
		export AIDEVOPS_LABEL_CACHE_FILE="$cache_file"
		# shellcheck disable=SC2064
		trap "rm -f '${cache_file}' 2>/dev/null || true" EXIT
	fi

	# Fetch label list if cache is empty or stale (> 0 bytes = populated)
	if [[ ! -s "$cache_file" ]]; then
		if ! gh label list --repo "$repo_slug" --limit 1000 \
			--json name --jq '.[].name' >"$cache_file" 2>/dev/null; then
			# API failure → fail-open: skip validation, proceed with claim
			log_warn "Label list query failed (rate limit or network) — skipping label validation (fail-open)"
			return 0
		fi
	fi

	# Regex for the auto-create exception class (blocked-by:tNNN / blocked-by:GH#NNN / blocked-by:#NNN).
	# _normalise_ref() in _detect_predecessor_refs produces GH#NNN for GitHub issue refs,
	# so the GH# prefix must be included or those normalised labels fail the check and abort.
	# All other invalid labels still abort.
	local _BLOCKED_BY_AUTO_CREATE_REGEX='^blocked-by:(t[0-9]+|GH#[0-9]+|#[0-9]+)$'

	# Check each label against the cache
	local invalid_labels=""
	local label
	# Split on comma, trim whitespace
	local IFS_SAVE="$IFS"
	IFS=','
	local -a label_arr
	read -ra label_arr <<<"$labels_csv"
	IFS="$IFS_SAVE"

	for label in "${label_arr[@]}"; do
		label="${label#"${label%%[![:space:]]*}"}"  # trim leading whitespace
		label="${label%"${label##*[![:space:]]}"}"  # trim trailing whitespace
		[[ -z "$label" ]] && continue
		if ! grep -Fxq "$label" "$cache_file" 2>/dev/null; then
			# Auto-create exception: blocked-by:tNNN / blocked-by:GH#NNN / blocked-by:#NNN
			# labels are synthesised by t2823 from description text and may not exist yet in
			# fresh consumer repos. Create them on demand (t2800/GH#21474).
			# If creation fails (e.g. insufficient permissions), treat the label as invalid
			# so the claim aborts BEFORE the counter is advanced — preserves atomic-claim
			# guarantee (GH#21633: stranded task ID on failed auto-create).
			if [[ "$label" =~ $_BLOCKED_BY_AUTO_CREATE_REGEX ]]; then
				if ! _auto_create_blocked_by_label "$repo_slug" "$label" "$cache_file"; then
					# Creation failed — fall through to the invalid_labels accumulator below.
					: # (intentional — do not continue, let the guard below record the label)
				else
					# Creation succeeded — skip normal validation for this label.
					continue
				fi
			fi
			if [[ -n "$invalid_labels" ]]; then
				invalid_labels="${invalid_labels}, '${label}'"
			else
				invalid_labels="'${label}'"
			fi
		fi
	done

	if [[ -n "$invalid_labels" ]]; then
		log_error "Pre-flight label validation failed — label(s) do not exist in this repo: ${invalid_labels}"
		log_error ""
		log_error "Each invalid label must be created before claiming, OR use one of these options:"
		log_error "  (a) Create the label and re-run:"
		log_error "        gh label create '<name>' --repo \"${repo_slug}\" --color '0075ca' --description '...'"
		log_error "  (b) If the label was auto-emitted from a --description predecessor reference,"
		log_error "      skip it: re-run with --no-blocked-by (dependency still recorded in body text)"
		log_error "  (c) Use a different blocking label that already exists, e.g. 'status:blocked'"
		log_error ""
		log_error "  Claim aborted — counter NOT advanced."
		return 1
	fi

	return 0
}

# Emit the online dry-run allocation without mutating the remote counter.
_main_emit_online_dry_run_allocation() {
	local current=""
	current=$(read_remote_counter "$REPO_PATH" 2>/dev/null || read_local_counter "$REPO_PATH" 2>/dev/null || echo "?")
	if [[ "$current" =~ ^[0-9]+$ ]]; then
		log_info "Would allocate $(printf 't%03d' "$current")..$(printf 't%03d' "$((current + ALLOC_COUNT - 1))") (counter at ${current})"
	else
		log_info "Would allocate task ID (counter unreadable: ${current})"
	fi
	echo "task_id=tDRY_RUN"
	echo "ref=DRY_RUN"
	return 0
}

# Resolve allocation: online (with dry-run shortcut) or offline fallback.
# Sets caller-local variables first_id and is_offline via stdout protocol:
#   prints "first_id=NNN" and "is_offline=true|false" on success,
#   or returns non-zero on hard failure.
# Callers eval the output to populate their locals.
_main_resolve_allocation() {
	local first_id_out=""
	local is_offline_out="false"
	local allocation_status="normal_success"

	if [[ "$OFFLINE_MODE" == "false" ]]; then
		if [[ "$DRY_RUN" == "true" ]]; then
			_main_emit_online_dry_run_allocation
			return 0
		fi

		# Non-main counter branches can lag the default branch after release or
		# merge activity.  Reconcile before claiming so we do not allocate IDs below
		# the default branch's observed counter and then rely on manual fallback.
		if [[ "$CAS_RECONCILE_RETRY_ON_FAILURE" == "1" && "${DEFAULT_BRANCH:-main}" != "$COUNTER_BRANCH" ]]; then
			local _pre_reconcile_rc=0
			_cas_reconcile_counter_branch "$REPO_PATH" "${DEFAULT_BRANCH:-main}" >/dev/null || _pre_reconcile_rc=$?
			if [[ $_pre_reconcile_rc -ne 0 && $_pre_reconcile_rc -ne 2 ]]; then
				return 1
			fi
		fi

		local _allocation_rc=0
		first_id_out=$(_allocate_online_with_collision_check "$REPO_PATH" "$ALLOC_COUNT") || _allocation_rc=$?
		if [[ $_allocation_rc -eq 0 ]]; then
			log_success "Allocated task ID: $(printf 't%03d' "$first_id_out")"
		elif [[ $_allocation_rc -eq ${CAS_PROTECTED_BRANCH_RC:-4} ]]; then
			return "$_allocation_rc"
		else
			if [[ "$CAS_RECONCILE_RETRY_ON_FAILURE" == "1" ]]; then
				local _reconcile_rc=0
				_cas_reconcile_counter_branch "$REPO_PATH" "${DEFAULT_BRANCH:-main}" || _reconcile_rc=$?
				if [[ $_reconcile_rc -eq 0 || $_reconcile_rc -eq 2 ]]; then
					local _retry_allocation_rc=0
					first_id_out=$(_allocate_online_with_collision_check "$REPO_PATH" "$ALLOC_COUNT") || _retry_allocation_rc=$?
					if [[ $_retry_allocation_rc -eq 0 ]]; then
						allocation_status="recovered_contention"
						log_success "Allocated task ID after counter reconciliation: $(printf 't%03d' "$first_id_out")"
					elif [[ $_retry_allocation_rc -eq ${CAS_PROTECTED_BRANCH_RC:-4} ]]; then
						return "$_retry_allocation_rc"
					else
						log_error "UNRECOVERABLE_COUNTER_DESYNC: allocation still failed after refetch/reconcile"
						_task_counter_status "unrecoverable_desync" "post_reconcile_allocation_failed"
						return 1
					fi
				else
					return 1
				fi
			fi
		fi

		if [[ -z "$first_id_out" ]]; then
			if [[ "$CAS_EXHAUSTION_FATAL" == "1" ]]; then
				log_error "CAS_EXHAUSTED: online allocation failed after ${CAS_MAX_RETRIES} attempts"
				log_error "UNRECOVERABLE_COUNTER_DESYNC: refetch/reconcile did not produce a safe allocation."
				log_error "The remote is reachable but counter contention or branch desynchronization persisted."
				_task_counter_status "unrecoverable_desync" "cas_exhausted"
				return 1
			fi
			log_warn "Online allocation failed; using automatic auditable offline fallback (CAS_EXHAUSTION_FATAL=0)"
			_task_counter_status "fallback" "offline_offset"
			allocation_status="fallback"
			is_offline_out="true"
		fi
	else
		is_offline_out="true"
		allocation_status="fallback"
	fi

	if [[ "$is_offline_out" == "true" ]]; then
		if [[ "$DRY_RUN" == "true" ]]; then
			log_info "Would allocate task ID in offline mode"
			echo "task_id=tDRY_RUN"
			echo "ref=offline"
			return 2
		fi

		if ! first_id_out=$(allocate_offline "$REPO_PATH" "$ALLOC_COUNT"); then
			log_error "Offline allocation failed"
			return 1
		fi
	fi

	if [[ "$allocation_status" == "normal_success" ]]; then
		_task_counter_status "normal_success" "task_id=$(printf 't%03d' "$first_id_out")"
	elif [[ "$allocation_status" == "recovered_contention" ]]; then
		_task_counter_status "recovered_contention" "task_id=$(printf 't%03d' "$first_id_out")"
	fi

	# Communicate results back to caller via stdout key=value pairs
	echo "_alloc_first_id=${first_id_out}"
	echo "_alloc_is_offline=${is_offline_out}"
	return 0
}

# Create issues for all allocated IDs (optional, non-blocking).
# Populates caller-provided variables via stdout key=value pairs:
#   _issue_ref_prefix, _issue_has_any, _issue_first_num, _issue_nums_csv
_main_create_issues() {
	local first_id="$1"
	local platform="$2"

	local ref_prefix=""
	local last_id=$((first_id + ALLOC_COUNT - 1))
	local -a issue_nums=()
	local has_any_issue=false
	local first_issue_num=""

	if check_cli "$platform"; then
		case "$platform" in
		github) ref_prefix="GH" ;;
		gitlab) ref_prefix="GL" ;;
		esac

		# Guard: skip issue creation if TASK_TITLE is empty (batch without --title)
		if [[ -z "$TASK_TITLE" ]]; then
			log_warn "No --title provided — skipping issue creation for batch allocation"
		else
			local i
			for ((i = first_id; i <= last_id; i++)); do
				local issue_title
				issue_title="$(printf 't%03d' "$i"): ${TASK_TITLE}"
				local issue_num=""

				case "$platform" in
				github)
					issue_num=$(create_github_issue "$issue_title" "$TASK_DESCRIPTION" "$TASK_LABELS" "$REPO_PATH") || true
					;;
				gitlab)
					issue_num=$(create_gitlab_issue "$issue_title" "$TASK_DESCRIPTION" "$TASK_LABELS" "$REPO_PATH") || true
					;;
				esac

				if [[ -n "$issue_num" ]]; then
					log_success "Created issue: ${ref_prefix}#${issue_num}"
					issue_nums+=("$issue_num")
					has_any_issue=true
					if [[ -z "$first_issue_num" ]]; then
						first_issue_num="$issue_num"
					fi
				else
					log_warn "Issue creation failed for $(printf 't%03d' "$i") (non-fatal — ID is secured)"
					issue_nums+=("")
				fi
			done
		fi
	else
		log_warn "CLI for $platform not found — skipping issue creation"
	fi

	# Communicate results back to caller via stdout key=value pairs
	echo "_issue_ref_prefix=${ref_prefix}"
	echo "_issue_has_any=${has_any_issue}"
	echo "_issue_first_num=${first_issue_num}"
	# CSV of issue numbers (empty slots preserved as empty fields)
	local csv=""
	local k
	for ((k = 0; k < ${#issue_nums[@]}; k++)); do
		if [[ $k -gt 0 ]]; then csv="${csv},"; fi
		csv="${csv}${issue_nums[$k]}"
	done
	echo "_issue_nums_csv=${csv}"
	return 0
}

# Emit machine-readable output lines to stdout.
_main_output_results() {
	local first_id="$1"
	local is_offline="$2"
	local ref_prefix="$3"
	local has_any_issue="$4"
	local first_issue_num="$5"
	local issue_nums_csv="$6"

	local last_id=$((first_id + ALLOC_COUNT - 1))

	if [[ "$ALLOC_COUNT" -eq 1 ]]; then
		printf "task_id=t%03d\n" "$first_id"
	else
		printf "task_id=t%03d\n" "$first_id"
		printf "task_id_last=t%03d\n" "$last_id"
		echo "task_count=${ALLOC_COUNT}"
	fi

	if [[ "$has_any_issue" == "true" ]] && [[ -n "$first_issue_num" ]]; then
		echo "ref=${ref_prefix}#${first_issue_num}"
		local remote_url
		remote_url=$(cd "$REPO_PATH" && git remote get-url "$REMOTE_NAME" 2>/dev/null | sed 's/\.git$//' || echo "")
		if [[ -n "$remote_url" ]]; then
			# t2458: sanitize_url strips embedded credentials (e.g., https://gho_…@…)
			echo "issue_url=$(sanitize_url "$remote_url")/issues/${first_issue_num}"
		fi
		# Output refs for all issues in batch (new — for callers that parse all output)
		if [[ "$ALLOC_COUNT" -gt 1 ]]; then
			# Reconstruct issue_nums array from CSV
			local -a issue_nums=()
			local IFS_SAVE="$IFS"
			IFS=',' read -r -a issue_nums <<<"$issue_nums_csv"
			IFS="$IFS_SAVE"
			local j
			for ((j = 0; j < ALLOC_COUNT; j++)); do
				local tid=$((first_id + j))
				if [[ -n "${issue_nums[$j]}" ]]; then
					echo "ref_t${tid}=${ref_prefix}#${issue_nums[$j]}"
				fi
			done
		fi
	elif [[ "$is_offline" == "true" ]]; then
		echo "ref=offline"
		echo "reconcile=true"
	else
		echo "ref=none"
	fi

	# GH#20834: emit blocked-by refs when auto-detected from description
	if [[ -n "${_CLAIM_BLOCKED_BY_REFS:-}" ]]; then
		echo "blocked_by=${_CLAIM_BLOCKED_BY_REFS}"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Pre-claim discovery pass (t2180) — decomposed into 5 helpers.
#
# Runs before atomic ID allocation to surface similar in-flight or
# recently-merged PRs. Prevents duplicate work (concrete evidence: PR #19494
# duplicated merged PR #19495, costing ~30 min of session time + 10 CI runs).
#
# Decomposition keeps every function ≤30 lines so the complexity-regression
# pre-push hook stays green. Prior attempt (PR #19658) bundled all logic in
# one ~170-line function that tripped the gate.
#
# Env vars:
#   AIDEVOPS_CLAIM_DEDUP_DAYS   recency window for merged PRs (default 14)
#
# Test hooks (for test-claim-task-id-discovery.sh only):
#   _AIDEVOPS_CLAIM_TEST_IS_TTY  "1" → force interactive path in non-TTY tests
#   _AIDEVOPS_CLAIM_TEST_ANSWER  "y"/"n" → override user prompt answer
# ---------------------------------------------------------------------------

# _pc_sanitize_keywords — extract keywords from task title.
# Emits up to 4 keywords on stdout, one per line, length-sorted descending
# (longer tokens are more discriminating in search).
# Stop-words and tokens <4 chars are dropped.
_pc_sanitize_keywords() {
	local title="$1"
	local stop=" feat fix chore add update remove delete get set the for to a an with from into via of at on in by and or is are was not use uses using new be do did does its it "
	local sanitized
	sanitized=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ')
	local -a raw_tokens=()
	IFS=' ' read -ra raw_tokens <<<"$sanitized"
	local -a kw=()
	local t
	for t in "${raw_tokens[@]}"; do
		[[ -z "$t" || ${#t} -lt 4 ]] && continue
		[[ "$stop" == *" ${t} "* ]] && continue
		kw+=("$t")
	done
	[[ ${#kw[@]} -eq 0 ]] && return 0
	local w
	for w in "${kw[@]}"; do
		printf '%s\t%s\n' "${#w}" "$w"
	done | sort -k1,1nr | head -n 4 | cut -f2-
	return 0
}

# _pc_search_related_prs — run gh_pr_list with OR query across keywords.
# Args: $1 repo_slug, $2 newline-separated keywords.
# Emits raw JSON array on stdout. Returns 0 on success, non-zero on gh error.
_pc_search_related_prs() {
	local repo_slug="$1"
	local keywords_nl="$2"
	local -a kws=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] && kws+=("$line")
	done <<<"$keywords_nl"
	[[ ${#kws[@]} -eq 0 ]] && return 1
	local query
	query=$(printf '%s OR ' "${kws[@]}")
	query="${query% OR }"
	gh_pr_list --repo "$repo_slug" --state all \
		--search "$query" --limit 5 \
		--json number,title,state,mergedAt,createdAt 2>/dev/null
	return $?
}

# _pc_search_related_issues — run gh_issue_list with OR query across keywords.
# Args: $1 repo_slug, $2 newline-separated keywords.
# Emits raw JSON array on stdout. Returns 0 on success, non-zero on gh error.
_pc_search_related_issues() {
	local repo_slug="$1"
	local keywords_nl="$2"
	local -a kws=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] && kws+=("$line")
	done <<<"$keywords_nl"
	[[ ${#kws[@]} -eq 0 ]] && return 1
	local query
	query=$(printf '%s OR ' "${kws[@]}")
	query="${query% OR }"
	gh_issue_list --repo "$repo_slug" --state open \
		--search "$query" --limit 20 \
		--json number,title,state,createdAt 2>/dev/null
	return $?
}

# _pc_filter_relevant_prs — apply recency + keyword-overlap filter.
# Args: $1 raw JSON, $2 newline keywords, $3 dedup_days.
# Emits formatted hit lines: "#NNN [STATE] title  (date)".
_pc_filter_relevant_prs() {
	local raw_json="$1"
	local keywords_nl="$2"
	local dedup_days="$3"
	local now_epoch cutoff_epoch
	now_epoch=$(date +%s 2>/dev/null || echo "0")
	cutoff_epoch=$((now_epoch - dedup_days * 86400))
	local pr_num pr_title pr_state pr_merged_at
	while IFS='|' read -r pr_num pr_title pr_state pr_merged_at; do
		[[ -z "$pr_num" || "$pr_state" == "CLOSED" ]] && continue
		if [[ "$pr_state" == "MERGED" && -n "$pr_merged_at" ]]; then
			local merged_epoch=0
			merged_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_merged_at" +%s 2>/dev/null) \
				|| merged_epoch=$(date --date="$pr_merged_at" +%s 2>/dev/null) \
				|| true
			[[ "$merged_epoch" -gt 0 && "$merged_epoch" -lt "$cutoff_epoch" ]] && continue
		fi
		local pr_lower overlap=0 kw
		pr_lower=$(printf '%s' "$pr_title" | tr '[:upper:]' '[:lower:]')
		while IFS= read -r kw; do
			[[ -z "$kw" ]] && continue
			[[ "$pr_lower" == *"$kw"* ]] && overlap=$((overlap + 1))
		done <<<"$keywords_nl"
		[[ $overlap -lt 2 ]] && continue
		printf '#%s [%s] %s  (%s)\n' "$pr_num" "$pr_state" "$pr_title" "${pr_merged_at:-open}"
	done < <(printf '%s' "$raw_json" | jq -r '.[] | "\(.number)|\(.title)|\(.state)|\(.mergedAt // "")"')
	return 0
}

# _pc_filter_relevant_issues — apply recency + keyword-overlap filter for open issues.
# Args: $1 raw JSON, $2 newline keywords, $3 dedup_days.
# Emits formatted hit lines: "#NNN [ISSUE] title  (date)".
_pc_filter_relevant_issues() {
	local raw_json="$1"
	local keywords_nl="$2"
	local dedup_days="$3"
	local now_epoch cutoff_epoch
	now_epoch=$(date +%s 2>/dev/null || echo "0")
	cutoff_epoch=$((now_epoch - dedup_days * 86400))
	local issue_num issue_title issue_created_at
	while IFS='|' read -r issue_num issue_title issue_created_at; do
		[[ -z "$issue_num" ]] && continue
		if [[ -n "$issue_created_at" ]]; then
			local created_epoch=0
			created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$issue_created_at" +%s 2>/dev/null) \
				|| created_epoch=$(date --date="$issue_created_at" +%s 2>/dev/null) \
				|| true
			[[ "$created_epoch" -gt 0 && "$created_epoch" -lt "$cutoff_epoch" ]] && continue
		fi
		local issue_lower overlap=0 kw
		issue_lower=$(printf '%s' "$issue_title" | tr '[:upper:]' '[:lower:]')
		while IFS= read -r kw; do
			[[ -z "$kw" ]] && continue
			[[ "$issue_lower" == *"$kw"* ]] && overlap=$((overlap + 1))
		done <<<"$keywords_nl"
		[[ $overlap -lt 2 ]] && continue
		printf '#%s [ISSUE] %s  (%s)\n' "$issue_num" "$issue_title" "${issue_created_at:-open}"
	done < <(printf '%s' "$raw_json" | jq -r '.[] | "\(.number)|\(.title)|\(.createdAt // "")"')
	return 0
}

# _pc_prompt_or_warn — interactive Y/N prompt or non-interactive stderr warns.
# Args: $1 newline-separated hit lines.
# Returns: 0 to proceed, 10 if interactive user declined.
_pc_prompt_or_warn() {
	local hits_nl="$1"
	[[ -z "$hits_nl" ]] && return 0
	local -a hits=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] && hits+=("$line")
	done <<<"$hits_nl"
	[[ ${#hits[@]} -eq 0 ]] && return 0
	local is_tty=false
	if [[ "${_AIDEVOPS_CLAIM_TEST_IS_TTY:-0}" == "1" ]]; then
		is_tty=true
	elif [[ -t 0 && -t 1 ]]; then
		is_tty=true
	fi
	local hit_count="${#hits[@]}" max_show=3 h
	if [[ "$is_tty" == "true" ]]; then
		printf '\n[claim-task-id] WARNING: Found %d similar open issue(s) or PR(s) — please check before claiming a new task ID:\n' "$hit_count" >&2
		for ((h = 0; h < hit_count && h < max_show; h++)); do
			printf '  \xe2\x80\xa2 %s\n' "${hits[$h]}" >&2
		done
		printf '\nContinue claiming a new ID? [y/N]: ' >&2
		local answer="${_AIDEVOPS_CLAIM_TEST_ANSWER:-}"
		[[ -z "$answer" ]] && { IFS= read -r answer </dev/tty 2>/dev/null || answer="n"; }
		local ans_lower
		ans_lower=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
		if [[ "$ans_lower" != "y" && "$ans_lower" != "yes" ]]; then
			printf '[claim-task-id] Claim aborted — verify the issues/PRs above before proceeding.\n' >&2
			return 10
		fi
	else
		for ((h = 0; h < hit_count && h < max_show; h++)); do
			printf '[claim-task-id] WARN: similar issue or PR found: %s\n' "${hits[$h]}" >&2
		done
	fi
	return 0
}

# _pre_claim_discovery_pass — orchestrator.
# Args: $1 title, $2 repo_slug.
# Returns: 0 (proceed) or 10 (user declined, interactive only).
# Fail-open: any missing dep (gh, jq, auth) short-circuits to 0.
# GH#21831: searches both PRs and open issues to catch cross-tNNN duplicates.
_pre_claim_discovery_pass() {
	local title="$1"
	local repo_slug="$2"
	local dedup_days="${AIDEVOPS_CLAIM_DEDUP_DAYS:-14}"
	[[ -z "$title" || -z "$repo_slug" ]] && return 0
	command -v gh >/dev/null 2>&1 || return 0
	command -v jq >/dev/null 2>&1 || return 0
	gh auth status >/dev/null 2>&1 || return 0
	local keywords
	keywords=$(_pc_sanitize_keywords "$title")
	[[ -z "$keywords" ]] && return 0
	local all_hits=""

	# Search related PRs (existing behaviour)
	local pr_json pr_hits
	pr_json=$(_pc_search_related_prs "$repo_slug" "$keywords") || true
	if [[ -n "$pr_json" && "$pr_json" != "[]" ]]; then
		pr_hits=$(_pc_filter_relevant_prs "$pr_json" "$keywords" "$dedup_days")
		[[ -n "$pr_hits" ]] && all_hits="${pr_hits}"
	fi

	# Search related open issues (GH#21831: catch cross-tNNN duplicates)
	local issue_json issue_hits
	issue_json=$(_pc_search_related_issues "$repo_slug" "$keywords") || true
	if [[ -n "$issue_json" && "$issue_json" != "[]" ]]; then
		issue_hits=$(_pc_filter_relevant_issues "$issue_json" "$keywords" "$dedup_days")
		if [[ -n "$issue_hits" ]]; then
			if [[ -n "$all_hits" ]]; then
				all_hits="${all_hits}"$'\n'"${issue_hits}"
			else
				all_hits="${issue_hits}"
			fi
		fi
	fi

	[[ -z "$all_hits" ]] && return 0
	_pc_prompt_or_warn "$all_hits"
	return $?
}

# ---------------------------------------------------------------------------
# Predecessor reference detection (GH#20834)
#
# Scans description text for prose references to predecessor tasks and
# emits a comma-separated list of IDs for automatic blocked-by tagging.
#
# Recognised patterns (case-insensitive):
#   1. "Follow-up from tNNN" / "Follow-up from GH#NNN"
#   2. "tracked in GH#NNN" / "tracked in #NNN"
#   3. "blocked-by: tNNN" / "blocked-by:GH#NNN"  (explicit pass-through)
#   4. "after tNNN ships/merges/lands"
#
# Outputs comma-separated IDs on stdout. Empty output means no refs found.
# Bare "#NNN" references in pattern 2 are normalised to "GH#NNN".
#
# The caller stores the result in the global _CLAIM_BLOCKED_BY_REFS.
# _ensure_todo_entry_written reads _CLAIM_BLOCKED_BY_REFS to append the
# blocked-by tag to the TODO.md line it writes.
# ---------------------------------------------------------------------------
_detect_predecessor_refs() {
	local text="$1"
	[[ -z "$text" ]] && return 0

	local -a all_refs=()
	local ref _tmpout

	# Normalise a single extracted ref to canonical form and print it.
	# t/T + digits → t<NNN>; gh#/GH#/Gh# + digits → GH#<NNN>; bare #NNN unchanged.
	_normalise_ref() {
		local r="$1"
		if [[ "$r" =~ ^[Tt]([0-9]+)$ ]]; then
			printf 't%s' "${BASH_REMATCH[1]}"
		elif [[ "$r" =~ ^[Gg][Hh]#([0-9]+)$ ]]; then
			printf 'GH#%s' "${BASH_REMATCH[1]}"
		else
			printf '%s' "$r"
		fi
		return 0
	}

	# Pattern 1: "Follow-up from tNNN" or "Follow-up from GH#NNN"
	_tmpout=$(printf '%s' "$text" \
		| grep -oiE 'follow-up from (t[0-9]+|GH#[0-9]+)' \
		| grep -oiE '(t[0-9]+|GH#[0-9]+)' 2>/dev/null || true)
	while IFS= read -r ref; do
		[[ -z "$ref" ]] && continue
		all_refs+=("$(_normalise_ref "$ref")")
	done <<<"$_tmpout"

	# Pattern 2: "tracked in GH#NNN" or "tracked in #NNN"
	_tmpout=$(printf '%s' "$text" \
		| grep -oiE 'tracked in (GH#[0-9]+|#[0-9]+)' \
		| grep -oiE '(GH#[0-9]+|#[0-9]+)' 2>/dev/null || true)
	while IFS= read -r ref; do
		[[ -z "$ref" ]] && continue
		# Normalise bare #NNN → GH#NNN first, then canonical-case normalise
		[[ "$ref" =~ ^#[0-9]+$ ]] && ref="GH${ref}"
		all_refs+=("$(_normalise_ref "$ref")")
	done <<<"$_tmpout"

	# Pattern 3: explicit "blocked-by:tNNN" or "blocked-by: GH#NNN" (pass-through)
	_tmpout=$(printf '%s' "$text" \
		| grep -oiE 'blocked-by:?[[:space:]]*(t[0-9]+|GH#[0-9]+)' \
		| grep -oiE '(t[0-9]+|GH#[0-9]+)' 2>/dev/null || true)
	while IFS= read -r ref; do
		[[ -z "$ref" ]] && continue
		all_refs+=("$(_normalise_ref "$ref")")
	done <<<"$_tmpout"

	# Pattern 4: "after tNNN ships/merges/lands"
	_tmpout=$(printf '%s' "$text" \
		| grep -oiE 'after t[0-9]+ (ships|merges|lands)' \
		| grep -oiE 't[0-9]+' 2>/dev/null || true)
	while IFS= read -r ref; do
		[[ -z "$ref" ]] && continue
		all_refs+=("$(_normalise_ref "$ref")")
	done <<<"$_tmpout"

	[[ ${#all_refs[@]} -eq 0 ]] && return 0

	# Deduplicate preserving insertion order.
	local -a deduped=()
	local seen=""
	for ref in "${all_refs[@]}"; do
		if [[ ",${seen}," != *",${ref},"* ]]; then
			deduped+=("$ref")
			seen="${seen:+${seen},}${ref}"
		fi
	done

	# Output comma-separated
	local csv=""
	for ref in "${deduped[@]}"; do
		csv="${csv:+${csv},}${ref}"
	done
	printf '%s' "$csv"
	return 0
}

# _apply_blocked_by_detection — populate _CLAIM_BLOCKED_BY_REFS from description.
# Skipped when NO_BLOCKED_BY=true, TASK_DESCRIPTION is empty, or dry-run.
# Emits advisory to stderr when predecessor refs are found.
_apply_blocked_by_detection() {
	_CLAIM_BLOCKED_BY_REFS=""
	[[ "$NO_BLOCKED_BY" == "true" ]] && return 0
	[[ -z "$TASK_DESCRIPTION" ]] && return 0
	[[ "$DRY_RUN" == "true" ]] && return 0

	local detected
	detected=$(_detect_predecessor_refs "$TASK_DESCRIPTION") || true
	[[ -z "$detected" ]] && return 0

	_CLAIM_BLOCKED_BY_REFS="$detected"
	log_warn "GH#20834: Detected predecessor reference(s) in description; auto-emitting blocked-by:${detected}. Override with --no-blocked-by."
	return 0
}

# ---------------------------------------------------------------------------
# Dispatch-path auto-dispatch advisory (t2821 / t2920)
#
# When a caller requests --labels auto-dispatch on a task whose title or
# description references dispatch-path scripts, emit a non-blocking stderr
# advisory noting that the t2819 pre-dispatch detector will auto-elevate the
# worker to tier:thinking. No recommendation to switch to no-auto-dispatch —
# auto-dispatch is the AI-first default; opus-4-7 + worker worktree isolation
# + CI gates + circuit breaker (t2690) cover the residual risk.
#
# The canonical pattern list is loaded from self-hosting-files.conf.
# Falls back to hardcoded defaults when the conf file is absent.
#
# Arguments: none (reads TASK_TITLE, TASK_DESCRIPTION, TASK_LABELS globals)
#
# Environment:
#   AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1 — disable entirely
# ---------------------------------------------------------------------------
_warn_dispatch_path_auto_dispatch() {
	[[ "${AIDEVOPS_SKIP_DISPATCH_PATH_CHECK:-}" == "1" ]] && return 0

	# Only fire when auto-dispatch (or auto_dispatch) is in the label set
	if [[ ",${TASK_LABELS}," != *",auto-dispatch,"* && \
		",${TASK_LABELS}," != *",auto_dispatch,"* ]]; then
		return 0
	fi

	# Load patterns from shared conf file
	local _conf_file="${AIDEVOPS_DISPATCH_PATH_FILES_CONF:-${SCRIPT_DIR}/../configs/self-hosting-files.conf}"
	local _patterns=()
	if [[ -f "$_conf_file" ]]; then
		while IFS= read -r _line; do
			[[ -z "$_line" || "$_line" == \#* ]] && continue
			_patterns+=("$_line")
		done <"$_conf_file"
	fi
	if [[ ${#_patterns[@]} -eq 0 ]]; then
		_patterns=(
			"pulse-wrapper.sh" "pulse-dispatch-" "pulse-cleanup.sh"
			"headless-runtime-helper.sh" "headless-runtime-lib.sh"
			"worker-lifecycle-common.sh" "shared-dispatch-dedup.sh"
			"shared-claim-lifecycle.sh" "worker-activity-watchdog.sh"
		)
	fi

	# Scan title + description for any dispatch-path pattern
	local _combined="${TASK_TITLE} ${TASK_DESCRIPTION:-}"
	local _matched=""
	local _p
	for _p in "${_patterns[@]}"; do
		if printf '%s' "$_combined" | grep -qF "$_p"; then
			_matched="$_p"
			break
		fi
	done
	[[ -z "$_matched" ]] && return 0

	log_info "t2920: dispatch-path file detected ('${_matched}') with auto-dispatch label."
	log_info "  The pre-dispatch detector (t2819) will auto-elevate this worker to tier:thinking."
	log_info "  No action required — proceed with auto-dispatch as normal."
	log_info "  See: reference/auto-dispatch.md \"Dispatch-Path Default (t2821 / t2920)\""
	return 0
}

# Handle the allocation-only namespaced mode before any repository access.
# Sets _CLAIM_NAMESPACED_HANDLED and _CLAIM_NAMESPACED_RC for main().
_main_handle_namespaced_mode() {
	_CLAIM_NAMESPACED_HANDLED=false
	_CLAIM_NAMESPACED_RC=0
	[[ "${AIDEVOPS_TASK_COORDINATOR_MODE:-legacy}" == "namespaced" ]] || return 0
	_CLAIM_NAMESPACED_HANDLED=true

	if [[ "$DRY_RUN" == "true" ]]; then
		printf 'task_id=tDRY_RUN\nref=DRY_RUN\n'
		return 0
	fi
	if [[ "$NO_ISSUE" != "true" ]]; then
		log_error "Namespaced coordinator allocation currently requires --no-issue"
		_CLAIM_NAMESPACED_RC=1
		return 0
	fi

	local coordinator_output=""
	coordinator_output=$(_task_coordinator_namespaced_allocate "$ALLOC_COUNT") || _CLAIM_NAMESPACED_RC=$?
	[[ $_CLAIM_NAMESPACED_RC -eq 0 ]] || return 0
	printf '%s\n' "$coordinator_output" | jq -r '.tasks[0].taskId | "task_id=\(.)"'
	if [[ "$ALLOC_COUNT" -gt 1 ]]; then
		printf '%s\n' "$coordinator_output" | jq -r '.tasks[-1].taskId | "task_id_last=\(.)"'
		printf 'task_count=%s\n' "$ALLOC_COUNT"
	fi
	printf 'ref=none\n'
	return 0
}

# Main execution
main() {
	parse_args "$@"
	_main_handle_namespaced_mode
	[[ "$_CLAIM_NAMESPACED_HANDLED" == "true" ]] && return "$_CLAIM_NAMESPACED_RC"

	load_project_config "$REPO_PATH"
	resolve_implicit_counter_branch "$REPO_PATH"

	# GH#20834: detect predecessor refs in description and populate
	# _CLAIM_BLOCKED_BY_REFS for use by _ensure_todo_entry_written.
	_apply_blocked_by_detection

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "DRY RUN mode - no changes will be made"
	fi

	# t2821: Advisory warning when auto-dispatch is requested on a task that
	# references dispatch-path scripts. Non-blocking — callers can override
	# with #dispatch-path-ok or AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1.
	_warn_dispatch_path_auto_dispatch

	# Framework routing guard: warn if title looks like a framework issue
	# but we're not in the aidevops repo (GH#5149)
	check_framework_routing "$TASK_TITLE" "$REPO_PATH"

	# Pre-claim discovery pass (t2180): surface similar in-flight or
	# recently-merged PRs before allocation. Skipped in batch (--no-issue),
	# offline, dry-run, or when no title is supplied.
	if [[ "$NO_ISSUE" == "false" && "$OFFLINE_MODE" == "false" && "$DRY_RUN" == "false" && -n "$TASK_TITLE" ]]; then
		local _disc_slug=""
		_disc_slug=$(_extract_github_slug "$REPO_PATH" "$REMOTE_NAME")
		if [[ -n "$_disc_slug" ]]; then
			local _disc_rc=0
			_pre_claim_discovery_pass "$TASK_TITLE" "$_disc_slug" || _disc_rc=$?
			if [[ $_disc_rc -eq 10 ]]; then
				return 10
			fi
		fi
	fi

	log_info "Using remote: ${REMOTE_NAME}, counter branch: ${COUNTER_BRANCH}"

	local platform
	platform=$(detect_platform)
	log_info "Detected platform: $platform"

	# A CAS counter cannot use a branch whose updates must arrive through pull
	# requests: review/merge is not an atomic compare-and-swap lock. GitHub's
	# read-only policy API lets us reject that setup before allocation mutates
	# the remote. Push-time classification remains as a fail-open fallback when
	# the API or CLI is unavailable.
	if ! preflight_counter_branch_policy "$REPO_PATH"; then
		return 4
	fi

	# --- t2800: Pre-flight label validation (before counter is advanced) ---
	# Only validate when issuing to GitHub, labels are provided, and not skipped.
	# Fail-open (validation function returns 0) on any API error.
	if [[ "$SKIP_LABEL_VALIDATION" == "false" ]] \
		&& [[ "$OFFLINE_MODE" == "false" ]] \
		&& [[ "$DRY_RUN" == "false" ]] \
		&& [[ "$NO_ISSUE" == "false" ]] \
		&& [[ "$platform" == "github" ]] \
		&& [[ -n "$TASK_LABELS" ]]; then
		local _val_slug=""
		_val_slug=$(_extract_github_slug "$REPO_PATH" "$REMOTE_NAME")
		if [[ -n "$_val_slug" ]]; then
			if ! _validate_labels_exist "$_val_slug" "$TASK_LABELS"; then
				return 3
			fi
		fi
	fi

	# --- Allocate the ID(s) first (the critical atomic step) ---

	local _alloc_first_id="" _alloc_is_offline=""
	local alloc_output alloc_rc=0
	alloc_output=$(_main_resolve_allocation) || alloc_rc=$?

	# Dry-run paths print directly and return early
	if echo "$alloc_output" | grep -q "^task_id=tDRY_RUN"; then
		echo "$alloc_output"
		return $alloc_rc
	fi

	if [[ $alloc_rc -ne 0 ]]; then
		return $alloc_rc
	fi

	# Parse allocation results
	eval "$(echo "$alloc_output" | grep -E '^_alloc_(first_id|is_offline)=')"
	local first_id="$_alloc_first_id"
	local is_offline="$_alloc_is_offline"

	# --- Create issues AFTER IDs are secured (optional, non-blocking) ---

	# t2436: Enrich TASK_LABELS with tags derived from the TODO.md entry for
	# the allocated task ID. When the maintainer pre-writes the TODO entry
	# before running claim-task-id.sh (e.g. "- [ ] t2436 desc #parent"),
	# this ensures protected labels like parent-task are applied at creation
	# time rather than waiting for the asynchronous issue-sync workflow.
	# Non-blocking: failure to find the entry leaves TASK_LABELS unchanged.
	if [[ "$NO_ISSUE" == "false" ]] && [[ "$is_offline" == "false" ]]; then
		local _task_id_for_scan
		printf -v _task_id_for_scan 't%03d' "$first_id"
		local _todo_derived_labels=""
		_todo_derived_labels=$(_scan_todo_labels_for_task "$_task_id_for_scan" "$REPO_PATH") || true
		if [[ -n "$_todo_derived_labels" ]]; then
			TASK_LABELS="${TASK_LABELS:+${TASK_LABELS},}${_todo_derived_labels}"
			# Deduplicate merged label set
			TASK_LABELS=$(printf '%s' "$TASK_LABELS" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
			log_info "t2436: Derived labels from TODO.md tags for ${_task_id_for_scan}: ${_todo_derived_labels}"
		fi
	fi

	local _issue_ref_prefix="" _issue_has_any="" _issue_first_num="" _issue_nums_csv=""
	if [[ "$NO_ISSUE" == "false" ]] && [[ "$is_offline" == "false" ]] && [[ "$platform" != "unknown" ]]; then
		local issue_output
		issue_output=$(_main_create_issues "$first_id" "$platform")
		eval "$(echo "$issue_output" | grep -E '^_issue_(ref_prefix|has_any|first_num|nums_csv)=')"
	fi

	# --- Output machine-readable results ---

	_main_output_results "$first_id" "$is_offline" \
		"$_issue_ref_prefix" "$_issue_has_any" "$_issue_first_num" "$_issue_nums_csv"

	if [[ "$is_offline" == "true" ]]; then
		return 2
	fi

	return 0
}

# t2063: only execute main when run as a script, not when sourced by tests.
# This allows test harnesses to source the file for access to function
# definitions (e.g. _compose_issue_body) without triggering main().
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
