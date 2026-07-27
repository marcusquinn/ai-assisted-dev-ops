#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Manual single-issue dispatch CLI (t2835, GH#20882)
# =============================================================================
# Dispatches a single GitHub issue as a headless worker without going through
# the full pulse cycle. Useful for:
#   - Smoke-testing newly-filed issues
#   - Debugging dispatch failures (model selection, dedup, prompt shape)
#   - Validating brief worker-readiness before committing pulse capacity
#
# Subcommands:
#   dispatch <issue_number> <owner/repo> [--model <id>] [--dry-run] [--no-ceremony]
#   Normal routing uses the issue's tier:simple, tier:standard, or tier:thinking
#   label. --model is an advanced compatibility override for exact model IDs.
#   status <issue_number> <owner/repo>
#   help
#
# Design choice: this helper does NOT call dispatch_with_dedup directly.
# Instead, it duplicates the launch logic with a subset of the safety gates
# (is-assigned + parent-task + state checks). Rationale:
#   1. dispatch_with_dedup runs 9+ gates including post-claim infrastructure
#      (claim comments, large-file gate, predispatch validators). For a
#      smoke-test those gates are over-the-top and harder to debug.
#   2. Sourcing pulse-dispatch-core.sh pulls in 20+ transitive dependencies.
#      A self-contained CLI is faster to invoke and easier to reason about.
#   3. Acceptable duplication: the worker prompt is intentionally minimal
#      (`/full-loop Implement issue #N (<url>)`) — the headless-runtime-lib
#      automatically appends HEADLESS_CONTINUATION_CONTRACT_V6 when it sees
#      `/full-loop` in the prompt, so the contract stays in sync without
#      duplicating the template here.
#
# Exit codes:
#   0  Worker dispatched (or skipped: already claimed / clear dry-run)
#   1  Validation failure (issue not found, parent-task, etc.)
#   2  Invalid subcommand or missing required arg
#   75 Dedup guard is uncertain; recovery checkpoint persisted
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# Resolve script dir (canonicalise symlinks) — same pattern as pulse-wrapper.sh
_DSI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies (order matters: shared-constants first, then GH wrappers).
# shared-constants.sh also sources shared-worktree-registry.sh when present,
# which defines register_worktree for the manual dispatch precreated worktree.
# NOTE: dispatch-dedup-helper.sh is NOT sourced — it has no source guard and
# would execute its main() with our $@. We invoke it as an external command
# instead via _DSI_DEDUP_HELPER below.
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
source "${_DSI_SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./shared-gh-wrappers.sh
# shellcheck disable=SC1091
source "${_DSI_SCRIPT_DIR}/shared-gh-wrappers.sh"

# Paths
_DSI_LOG_DIR="${HOME}/.aidevops/logs"
_DSI_HEADLESS="${_DSI_SCRIPT_DIR}/headless-runtime-helper.sh"
_DSI_LEDGER_HELPER="${_DSI_SCRIPT_DIR}/dispatch-ledger-helper.sh"
_DSI_WORKTREE_HELPER="${_DSI_SCRIPT_DIR}/worktree-helper.sh"
_DSI_DEDUP_HELPER="${_DSI_SCRIPT_DIR}/dispatch-dedup-helper.sh"
_DSI_VALIDATOR_HELPER="${_DSI_SCRIPT_DIR}/pre-dispatch-validator-helper.sh"
_DSI_BACKOFF_HELPER="${_DSI_SCRIPT_DIR}/dispatch-backoff-helper.sh"
_DSI_APPROVAL_HELPER="${_DSI_SCRIPT_DIR}/approval-helper.sh"
_DSI_DISPATCH_BASE_BRANCH=""
_DSI_STATE_RECOVERING="recovering"
_DSI_UNKNOWN_VALUE="<unknown>"
_DSI_CLAIM_WON=0
_DSI_CLAIM_COMMENT_ID=""
_DSI_TARGET_JSON=""

# Colors (guarded — don't collide with shared-constants)
[[ -z "${_DSI_GREEN+x}" ]] && _DSI_GREEN='\033[0;32m'
[[ -z "${_DSI_BLUE+x}" ]] && _DSI_BLUE='\033[0;34m'
[[ -z "${_DSI_YELLOW+x}" ]] && _DSI_YELLOW='\033[1;33m'
[[ -z "${_DSI_RED+x}" ]] && _DSI_RED='\033[0;31m'
[[ -z "${_DSI_NC+x}" ]] && _DSI_NC='\033[0m'

_dsi_info() {
	local _msg="$1"
	printf '%b[INFO]%b %s\n' "$_DSI_BLUE" "$_DSI_NC" "$_msg"
	return 0
}

_dsi_ok() {
	local _msg="$1"
	printf '%b[OK]%b %s\n' "$_DSI_GREEN" "$_DSI_NC" "$_msg"
	return 0
}

_dsi_warn() {
	local _msg="$1"
	printf '%b[WARN]%b %s\n' "$_DSI_YELLOW" "$_DSI_NC" "$_msg" >&2
	return 0
}

_dsi_err() {
	local _msg="$1"
	printf '%b[ERROR]%b %s\n' "$_DSI_RED" "$_DSI_NC" "$_msg" >&2
	return 0
}

#######################################
# Validate issue exists, is OPEN, and emit metadata via stdout (single jq call).
# Sets _DSI_ISSUE_TITLE, _DSI_ISSUE_LABELS, _DSI_ISSUE_URL, _DSI_ISSUE_ASSIGNEES.
# Args:
#   $1 - issue number
#   $2 - owner/repo slug
# Returns: 0 ok, 1 not found / closed / API error
#######################################
_dsi_load_issue_meta() {
	local issue_number="$1"
	local repo_slug="$2"
	local meta_json

	meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json number,title,state,labels,assignees,url 2>/dev/null) || meta_json=""

	if [[ -z "$meta_json" ]]; then
		_dsi_err "Cannot fetch issue #${issue_number} from ${repo_slug} (not found, no permission, or network error)"
		return 1
	fi

	local state state_normalized
	state=$(printf '%s' "$meta_json" | jq -r '.state // "UNKNOWN"')
	state_normalized=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')
	if [[ "$state_normalized" != "OPEN" ]]; then
		_dsi_err "Issue #${issue_number} is ${state} (must be OPEN for dispatch)"
		return 1
	fi

	_DSI_ISSUE_META_JSON="$meta_json"
	_DSI_ISSUE_TITLE=$(printf '%s' "$meta_json" | jq -r '.title // ""')
	_DSI_ISSUE_URL=$(printf '%s' "$meta_json" | jq -r '.url // ""')
	_DSI_ISSUE_LABELS=$(printf '%s' "$meta_json" | jq -r '[.labels[].name] | join(",")')
	_DSI_ISSUE_ASSIGNEES=$(printf '%s' "$meta_json" | jq -r '[.assignees[].login] | join(",")')
	return 0
}

#######################################
# Determine whether the target number is a pull request, not a plain Issue.
#
# Manual dispatch can be pointed at an arbitrary number, and `gh issue view`
# accepts PR numbers through the issue facade. Use the REST issue object's
# `pull_request` marker as a trust-boundary guard before any ceremony writes.
#
# Args:
#   $1 - issue number
#   $2 - owner/repo slug
# Returns:
#   0 target is a PR, 1 target is a plain Issue, 2 unable to verify
#######################################
_dsi_target_is_pull_request() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_json="" has_pull_request=""

	_DSI_TARGET_JSON=""
	target_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 2
	_DSI_TARGET_JSON="$target_json"
	has_pull_request=$(printf '%s' "$target_json" | jq -r 'has("pull_request")' 2>/dev/null) || return 2
	if [[ "$has_pull_request" == "true" ]]; then
		return 0
	fi
	if [[ "$has_pull_request" == "false" ]]; then
		return 1
	fi
	return 2
}

#######################################
# Block manual dispatch when live interactive/review hold labels are present.
# Args: $1 - labels CSV
# Returns: 0 when safe, 1 when held
#######################################
_dsi_guard_no_interactive_hold() {
	local labels_csv="$1"
	local labels_with_commas=""
	labels_with_commas=$(printf ',%s,' "$labels_csv")
	if [[ "$labels_with_commas" == *",status:in-review,"* && "$labels_with_commas" != *",auto-dispatch,"* ]]; then
		_dsi_err "Target carries an interactive review hold label; refusing worker dispatch (GH#22948)"
		return 1
	fi
	if [[ "$labels_with_commas" == *",origin:interactive,"* && "$labels_with_commas" != *",auto-dispatch,"* ]]; then
		_dsi_err "Target carries an interactive review hold label; refusing worker dispatch (GH#22948)"
		return 1
	fi
	return 0
}

#######################################
# Independently verify issue-author authority before a manual worker launch.
# This closes the gap where creation-time NMR labeling failed and the manual
# dispatcher previously treated the missing label as approval.
# Args: $1 - issue number, $2 - owner/repo slug
# Returns: 0 when trusted/approved, 1 when dispatch must remain blocked
#######################################
_dsi_guard_issue_author_trust() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_json="${_DSI_TARGET_JSON:-}"
	local author_meta="" author_association="NONE" author_type="" author_login=""

	if [[ -z "$issue_json" ]]; then
		issue_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || issue_json=""
	fi
	if [[ -n "$issue_json" ]]; then
		author_meta=$(printf '%s' "$issue_json" | jq -r \
			'[.author_association // "NONE", .user.type // "", .user.login // ""] | join("|")' 2>/dev/null) || author_meta=""
	fi
	if [[ -n "$author_meta" ]]; then
		IFS='|' read -r author_association author_type author_login <<<"$author_meta"
	fi
	[[ -n "$author_association" ]] || author_association="NONE"
	if [[ "$author_type" == "Bot" ]]; then
		return 0
	fi

	local authority_rc=0
	if declare -F _gh_actor_has_repo_write_authority >/dev/null 2>&1; then
		_gh_actor_has_repo_write_authority "$repo_slug" "$author_login" "$author_association" || authority_rc=$?
	else
		authority_rc=2
	fi
	if [[ "$authority_rc" -eq 0 ]]; then
		return 0
	fi

	if [[ ! -x "$_DSI_APPROVAL_HELPER" ]]; then
		_dsi_err "Issue-author approval verifier is unavailable; refusing manual worker dispatch"
		return 1
	fi
	local verification=""
	verification=$("$_DSI_APPROVAL_HELPER" verify "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ "$verification" == "VERIFIED" ]]; then
		return 0
	fi
	if [[ -n "$verification" && "$verification" != "NO_APPROVAL" ]]; then
		_dsi_err "Issue #${issue_number} in ${repo_slug} has an unverifiable approval marker (${verification}); refusing manual worker dispatch"
		return 1
	fi

	#aidevops:trust-boundary -- label mutation is containment, never the authority source.
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$issue_number" --repo "$repo_slug" \
			--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
	else
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
	fi
	_dsi_err "Issue #${issue_number} in ${repo_slug} has untrusted or unknown author authority (${author_association}; ${AIDEVOPS_GH_ACTOR_AUTHORITY_REASON:-unknown}) and no verified approval; refusing manual worker dispatch"
	return 1
}

#######################################
# Block manual worker dispatch until maintainer-review trust gates are cleared.
# Args: $1 - labels CSV, $2 - issue number, $3 - owner/repo slug
# Returns: 0 when safe, 1 when maintainer review is still required
#######################################
_dsi_guard_no_maintainer_review_required() {
	local labels_csv="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local labels_with_commas=""
	labels_with_commas=$(printf ',%s,' "$labels_csv")

	#aidevops:trust-boundary -- manual dispatch must not bypass signed/maintainer issue approval.
	if [[ "$labels_with_commas" == *",needs-maintainer-review,"* ]]; then
		_dsi_err "Issue #${issue_number} in ${repo_slug} still requires maintainer review; refusing manual worker dispatch"
		_dsi_info "  Required action: run 'sudo aidevops approve issue ${issue_number} ${repo_slug}' or record an equivalent maintainer decision before dispatch."
		return 1
	fi

	return 0
}

_dsi_guard_no_maintainer_permission_required() {
	local labels_csv="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local labels_with_commas=""
	labels_with_commas=$(printf ',%s,' "$labels_csv")
	if [[ "$labels_with_commas" == *",needs-maintainer-permissions,"* ]]; then
		_dsi_err "Issue #${issue_number} in ${repo_slug} is waiting for a scoped maintainer permission grant; refusing manual worker dispatch"
		_dsi_info "  Run the request-specific 'sudo aidevops approve permissions ... --request perm-...' command from the issue comment."
		return 1
	fi
	return 0
}

_dsi_guard_permission_history_verified() {
	local issue_number="$1"
	local repo_slug="$2"
	local events_json labeled_count verification
	events_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/events?per_page=100" --paginate --slurp 2>/dev/null) || {
		_dsi_err "Unable to inspect permission-request history for issue #${issue_number} in ${repo_slug}; refusing manual worker dispatch"
		return 1
	}
	labeled_count=$(jq '[.[][]? | select(.event == "labeled" and .label.name == "needs-maintainer-permissions")] | length' <<<"$events_json" 2>/dev/null) || {
		_dsi_err "Permission-request history for issue #${issue_number} in ${repo_slug} is malformed; refusing manual worker dispatch"
		return 1
	}
	[[ "$labeled_count" -gt 0 ]] || return 0
	[[ -x "$_DSI_APPROVAL_HELPER" ]] || {
		_dsi_err "Permission verification helper is unavailable; refusing manual worker dispatch"
		return 1
	}
	verification=$("$_DSI_APPROVAL_HELPER" verify-permissions issue "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ "$verification" == "VERIFIED" ]]; then
		_dsi_err "Issue #${issue_number} in ${repo_slug} has a signed grant bound to its original worker session and worktree; a new manual worker cannot consume it"
		_dsi_info "  Resume through the original pulse/worker path so the bound pending request can be loaded safely."
		return 1
	fi
	_dsi_err "Issue #${issue_number} in ${repo_slug} has permission-request history without a current matching signed grant (${verification:-NO_APPROVAL}); refusing manual worker dispatch"
	return 1
}

#######################################
# Check parent-task gate. parent-task is always a hard block (never single-dispatch).
# Args: $1 - labels CSV (from _dsi_load_issue_meta)
# Returns: 0 not parent-task, 1 IS parent-task (block)
#######################################
_dsi_check_parent_task() {
	local labels_csv="$1"
	local needle=",${labels_csv},"
	if [[ "$needle" == *",parent-task,"* ]]; then
		_dsi_err "Issue is labeled parent-task — these are decomposition trackers and cannot be single-dispatched"
		return 1
	fi
	return 0
}

#######################################
# Resolve model + tier for dispatch.
# Priority order (mirrors pulse-model-routing.sh::resolve_dispatch_model_for_labels):
#   1. Explicit --model CLI flag (operator intent, always wins)
#   2. Tier labels: tier:thinking, tier:standard, tier:simple
#   3. Default tier: standard
#
# Runtime routing maps the selected workload tier to an available model and
# provider reasoning level. Labels never pin a concrete model.
#
# Args:
#   $1 - labels CSV
#   $2 - --model override (may be empty)
# Sets: _DSI_TIER (simple|standard|thinking), _DSI_SELECTED_MODEL (full model id or empty)
#######################################
_dsi_resolve_model() {
	local labels_csv="$1"
	local model_override="$2"

	# Explicit --model CLI flag takes highest priority (operator intent).
	# Infer tier from the model string for display purposes only.
	if [[ -n "$model_override" ]]; then
		_DSI_SELECTED_MODEL="$model_override"
		case "$model_override" in
		*opus*) _DSI_TIER="thinking" ;;
		*haiku* | *terra*) _DSI_TIER="simple" ;;
		*) _DSI_TIER="standard" ;;
		esac
		return 0
	fi

	# Default tier: standard. Labels below may override.
	_DSI_TIER="standard"
	_DSI_SELECTED_MODEL=""

	# Normalise labels to lowercase for case-insensitive matching
	# (mirrors _resolve_worker_tier in pulse-dispatch-core.sh).
	local labels_lower
	labels_lower=$(printf '%s' "$labels_csv" | tr '[:upper:]' '[:lower:]')
	local needle=",${labels_lower},"

	if [[ "$needle" == *",tier:thinking,"* ]]; then
		_DSI_TIER="thinking"
		return 0
	fi

	# Remaining tier labels (standard is already the default; only simple changes it)
	if [[ "$needle" == *",tier:simple,"* ]]; then
		_DSI_TIER="simple"
	fi

	return 0
}

#######################################
# Pre-create the worker worktree. Sets _DSI_WORKTREE_PATH and _DSI_WORKTREE_BRANCH.
# Args:
#   $1 - issue number, $2 - repo slug
# Returns: 0 success, 1 failure (worktree creation failed after all retries)
#######################################
_dsi_create_worktree() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path
	repo_path=$(_dsi_repo_path_for_slug "$repo_slug") || repo_path=""
	if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
		_dsi_err "Cannot resolve local repo path for ${repo_slug}; check ~/.config/aidevops/repos.json"
		return 1
	fi
	local ts
	ts=$(date -u +%Y%m%d-%H%M%S)
	local branch="feature/auto-${ts}-gh${issue_number}"
	local dispatch_base_ref=""
	dispatch_base_ref=$(_dsi_dispatch_base_ref "$repo_slug" "$repo_path")
	_DSI_DISPATCH_BASE_BRANCH=$(_dsi_branch_from_ref "$dispatch_base_ref")

	local attempt max_attempts
	max_attempts=3

	# Retry loop: handles .git/config lock contention under concurrent creation
	# (GH#21469). git cleans up partial state on a failed add, so retrying the
	# same branch name is safe. Backoff: 0.5s after attempt 1, 1s after attempt 2.
	for attempt in 1 2 3; do
		# worktree-helper.sh add: outputs creation messages to stderr; the
		# branch name is what we passed in.
		if (cd "$repo_path" && AIDEVOPS_SKIP_AUTO_CLAIM=1 "$_DSI_WORKTREE_HELPER" add "$branch" \
			--base "$dispatch_base_ref" --issue "$issue_number") >&2; then
			# Query git for the actual worktree path. worktree-helper.sh uses its
			# own slug logic (lowercases, parent dir from get_repo_root) — recomputing
			# that here is fragile. Read it back from `git worktree list` instead.
			# Awk inlined to one line to avoid tripping the positional-ratchet (its
			# single-quote-strip is line-local; multi-line awk scripts get false-positives).
			_DSI_WORKTREE_PATH=$(git -C "$repo_path" worktree list --porcelain | awk -v b="$branch" '/^worktree / {p=$0;sub(/^worktree /,"",p)} $0 == "branch refs/heads/" b {print p; exit}')
			_DSI_WORKTREE_BRANCH="$branch"
			if [[ -n "$_DSI_WORKTREE_PATH" && -d "$_DSI_WORKTREE_PATH" ]]; then
				if declare -F register_worktree >/dev/null; then
					register_worktree "$_DSI_WORKTREE_PATH" "$_DSI_WORKTREE_BRANCH" \
						--task "$issue_number" \
						--session "dispatch-precreate-${issue_number}" || _dsi_warn "Worktree registration failed (non-fatal)"
				else
					_dsi_warn "Worktree registry helper unavailable; ownership registration skipped"
				fi
				return 0
			fi
			_dsi_warn "Worktree path unresolvable after add (attempt ${attempt}/${max_attempts}, branch=${branch})"
		else
			_dsi_warn "worktree-helper.sh add failed (attempt ${attempt}/${max_attempts}, possible .git/config lock, branch=${branch})"
		fi
		if [[ "$attempt" -eq 1 ]]; then sleep 0.5
		elif [[ "$attempt" -eq 2 ]]; then sleep 1
		fi
	done

	_dsi_err "Failed to create worktree for branch ${branch} after ${max_attempts} attempts"
	_dsi_info "  Inspect: git worktree list --porcelain | grep -A1 ${branch}"
	return 1
}

#######################################
# Return the branch component from a local/remote ref.
# Args: $1 - branch or ref (develop, origin/develop, refs/heads/develop)
# Outputs: branch name
#######################################
_dsi_branch_from_ref() {
	local ref="$1"
	ref="${ref#refs/remotes/origin/}"
	ref="${ref#refs/heads/}"
	ref="${ref#origin/}"
	printf '%s' "$ref"
	return 0
}

#######################################
# Resolve the branch that should seed manual dispatch worktrees.
# Prefers explicit env overrides and repo integration-branch policy, then
# falls back to origin/HEAD through _dsi_default_branch.
# Args: $1 - repo slug, $2 - local repo path
# Outputs: branch name
#######################################
_dsi_dispatch_base_branch() {
	local repo_slug="$1"
	local repo_path="$2"
	local base_branch="${AIDEVOPS_DISPATCH_BASE_BRANCH:-${DISPATCH_REPO_PR_BASE_BRANCH:-${AIDEVOPS_PR_BASE_BRANCH:-}}}"

	if [[ -z "$base_branch" && -n "$repo_path" && -f "${repo_path}/.aidevops.json" ]] && command -v jq >/dev/null 2>&1; then
		base_branch=$(jq -r '.dispatch_base_branch // .dispatch_base // .pr_base_branch // .pr_target_branch // .base_branch // empty' \
			"${repo_path}/.aidevops.json" 2>/dev/null | sed -n '1p') || base_branch=""
	fi

	local repos_json="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
	if [[ -z "$base_branch" && -n "$repo_slug" && -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		base_branch=$(jq -r --arg slug "$repo_slug" '
			.initialized_repos[]?
			| select((.slug // "") == $slug and (.local_only // false) == false)
			| .dispatch_base_branch // .dispatch_base // .pr_base_branch // .pr_target_branch // .base_branch // empty
		' "$repos_json" 2>/dev/null | sed -n '1p') || base_branch=""
	fi

	if [[ -z "$base_branch" ]]; then
		base_branch=$(_dsi_default_branch "$repo_path")
	fi

	_dsi_branch_from_ref "$base_branch"
	return 0
}

#######################################
# Resolve the exact base ref passed to worktree-helper.sh add --base.
# Args: $1 - repo slug, $2 - local repo path
# Outputs: git ref suitable for git worktree add
#######################################
_dsi_dispatch_base_ref() {
	local repo_slug="$1"
	local repo_path="$2"
	local base_ref="${AIDEVOPS_DISPATCH_BASE_REF:-${AIDEVOPS_WORKTREE_BASE:-}}"

	if [[ -n "$base_ref" ]]; then
		printf '%s' "$base_ref"
		return 0
	fi

	printf 'origin/%s' "$(_dsi_dispatch_base_branch "$repo_slug" "$repo_path")"
	return 0
}

#######################################
# Resolve repo's default branch (cached per call). Falls back to "main".
#######################################
_dsi_default_branch() {
	local repo_path="$1"
	local b
	b=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
	echo "${b:-main}"
	return 0
}

#######################################
# Resolve a repo slug to its registered canonical local path.
# Args: $1 - repo slug (owner/repo)
# Outputs: canonical path, if registered
#######################################
_dsi_repo_path_for_slug() {
	local repo_slug="$1"
	local repos_file="${AIDEVOPS_REPOS_FILE:-$HOME/.config/aidevops/repos.json}"
	[[ -n "$repo_slug" && -f "$repos_file" ]] || return 1
	jq -r --arg slug "$repo_slug" '
		.initialized_repos[]?
		| select((.slug // "") == $slug and (.local_only // false) == false)
		| .path
	' "$repos_file" 2>/dev/null | head -n 1
	return 0
}

#######################################
# Apply the pre-launch dispatch ceremony — pulse-parity ownership claim.
# Mirrors `pulse-dispatch-worker-launch.sh::_dlw_assign_and_label` exactly:
#
#   1. Atomic transition to status:queued (clears sibling status:* labels
#      via set_issue_status).
#   2. Preserve origin:* labels as immutable creation provenance.
#   3. Add runner as assignee; remove any prior assignees so dedup layer 6
#      sees a clean single-owner state.
#
# Why pre-launch (not post-launch): closes the race window where the next
# pulse cycle could see the issue in its prior state (e.g. status:available
# with no assignee) and dispatch a duplicate worker on top of the running
# one. This was the canonical failure mode observed during the 2026-04-27
# GitHub-search degradation incident on #21406/#21407/#21408.
#
# Best-effort — non-fatal if the gh edit fails. The worker still launches;
# the operator can manually fix labels via `set_issue_status` after the
# fact. The race-window risk is preferred over refusing to launch.
#
# Args:
#   $1 - issue_number, $2 - repo_slug, $3 - self_login (runner GH login),
#   $4 - issue_meta_json (.assignees[].login parsed for normalization)
# Returns: 0 success, 1 gh edit failed (warning emitted)
#######################################
_dsi_apply_dispatch_ceremony() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local issue_meta_json="$4"

	if [[ -z "$self_login" ]]; then
		_dsi_warn "Cannot resolve runner login — skipping dispatch ceremony"
		return 1
	fi

	# Assignee normalization: add self, remove any prior assignees (e.g. the
	# issue creator) so dedup is unambiguous.
	local -a _extra_flags=(--add-assignee "$self_login")
	local _prev_login
	while IFS= read -r _prev_login; do
		[[ -n "$_prev_login" && "$_prev_login" != "$self_login" ]] \
			&& _extra_flags+=(--remove-assignee "$_prev_login")
	done < <(printf '%s' "$issue_meta_json" | jq -r '.assignees[].login // ""')

	if ! set_issue_status "$issue_number" "$repo_slug" "queued" "${_extra_flags[@]}" >/dev/null 2>&1; then
		_dsi_warn "Dispatch ceremony failed (non-fatal — worker will still launch; fix labels manually if needed)"
		return 1
	fi

	_dsi_info "Ceremony applied — status:queued, assignee=${self_login}"
	return 0
}

#######################################
# Register the dispatch in the ledger with the real worker PID.
# Best-effort — non-fatal if it fails. Note: dispatch-ledger-helper.sh
# register accepts --session-key, --issue, --repo, --pid only — there is
# no --launched-by flag (the field is informational, not part of the
# helper's interface).
# Args:
#   $1 - issue_number, $2 - repo_slug, $3 - session_key, $4 - worker_pid
#######################################
_dsi_register_ledger() {
	local issue_number="$1"
	local repo_slug="$2"
	local session_key="$3"
	local worker_pid="$4"

	"$_DSI_LEDGER_HELPER" register \
		--session-key "$session_key" \
		--issue "$issue_number" \
		--repo "$repo_slug" \
		--pid "$worker_pid" \
		--worktree "${_DSI_WORKTREE_PATH:-}" \
		>/dev/null 2>&1 || _dsi_warn "Dispatch ledger registration failed (non-fatal)"
	return 0
}

#######################################
# Extract a --dir value from a worker command line.
# Args: $1 - command line
# Stdout: worktree path, or empty string
#######################################
_dsi_extract_worktree_from_cmd() {
	local cmd="$1"
	local worktree_path=""
	if [[ "$cmd" =~ --dir[[:space:]]+([^[:space:]]+) ]]; then
		worktree_path="${BASH_REMATCH[1]}"
	fi
	printf '%s\n' "$worktree_path"
	return 0
}

#######################################
# Resolve a repo slug from a worktree path.
# Args: $1 - worktree path
# Stdout: owner/repo slug, or empty string
#######################################
_dsi_repo_slug_for_worktree() {
	local worktree_path="$1"
	local remote_url=""
	if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
		printf '\n'
		return 0
	fi
	remote_url=$(git -C "$worktree_path" remote get-url origin 2>/dev/null || true)
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	printf '\n'
	return 0
}

#######################################
# Emit active worker process lines for duplicate detection.
# Tests override this function with fixture output.
# Stdout: ps rows: "PID STAT COMMAND..."
#######################################
_dsi_ps_worker_lines() {
	ps axwwo pid=,stat=,command= 2>/dev/null || true
	return 0
}

#######################################
# Check whether a PID is currently signalable by this runner.
# Tests override this function with deterministic process fixtures.
# Args: $1 - PID
# Returns: 0 live, 1 dead/inaccessible
#######################################
_dsi_pid_is_live() {
	local pid="$1"
	kill -0 "$pid" 2>/dev/null
	return $?
}

#######################################
# Check if a command line belongs to a worker for an issue number.
# Args: $1 - issue number, $2 - command line
# Returns: 0 match, 1 no match
#######################################
_dsi_cmd_matches_issue() {
	local issue_number="$1"
	local cmd="$2"
	local issue_re="([Ii]ssue[[:space:]]+#|[Ii]ssue[[:space:]]+|GH#)${issue_number}([^0-9]|$)"
	if [[ "$cmd" =~ $issue_re ]]; then
		return 0
	fi
	if [[ "$cmd" == *"--session-key issue-${issue_number}"* || "$cmd" == *"--session-key manual-cli-${issue_number}-"* ]]; then
		return 0
	fi
	return 1
}

#######################################
# Find a manual-dispatch log that names a worker PID.
# Args: $1 - issue number, $2 - PID
# Stdout: log path, or "<unknown>"
#######################################
_dsi_find_log_for_pid() {
	local issue_number="$1"
	local worker_pid="$2"
	local candidate=""
	for candidate in "$_DSI_LOG_DIR"/manual-dispatch-"${issue_number}"-*.log; do
		[[ -f "$candidate" ]] || continue
		if grep -Fq "Dispatched PID: ${worker_pid}" "$candidate" 2>/dev/null; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	printf '%s\n' "$_DSI_UNKNOWN_VALUE"
	return 0
}

#######################################
# Find a live worker by repo+issue and/or exact worktree path.
# Args: $1 - issue number, $2 - repo slug, $3 - worktree path (optional)
# Stdout: TSV source, pid, log, worktree, session_key
# Returns: 0 found, 1 none
#######################################
_dsi_find_live_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_worktree="${3:-}"
	local line pid stat cmd worktree_path worker_repo log_path session_key

	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		pid="${line%%[[:space:]]*}"
		line="${line#*[[:space:]]}"
		stat="${line%%[[:space:]]*}"
		cmd="${line#*[[:space:]]}"
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$stat" == *Z* || "$stat" == *T* ]] && continue
		[[ "$cmd" == *"dispatch-single-issue-helper.sh"* ]] && continue

		worktree_path=$(_dsi_extract_worktree_from_cmd "$cmd")
		if [[ -n "$target_worktree" && "$worktree_path" == "$target_worktree" ]]; then
			log_path=$(_dsi_find_log_for_pid "$issue_number" "$pid")
			session_key=$(printf '%s' "$cmd" | sed -n 's/.*--session-key[[:space:]]\([^[:space:]]*\).*/\1/p' | head -1)
			printf 'process\t%s\t%s\t%s\t%s\n' "$pid" "$log_path" "$worktree_path" "${session_key:-$_DSI_UNKNOWN_VALUE}"
			return 0
		fi

		_dsi_cmd_matches_issue "$issue_number" "$cmd" || continue
		worker_repo=$(_dsi_repo_slug_for_worktree "$worktree_path")
		[[ "$worker_repo" == "$repo_slug" ]] || continue
		log_path=$(_dsi_find_log_for_pid "$issue_number" "$pid")
		session_key=$(printf '%s' "$cmd" | sed -n 's/.*--session-key[[:space:]]\([^[:space:]]*\).*/\1/p' | head -1)
		printf 'process\t%s\t%s\t%s\t%s\n' "$pid" "$log_path" "${worktree_path:-$_DSI_UNKNOWN_VALUE}" "${session_key:-$_DSI_UNKNOWN_VALUE}"
		return 0
	done < <(_dsi_ps_worker_lines)

	return 1
}

#######################################
# Find a live ledger entry for repo+issue.
# Args: $1 - issue number, $2 - repo slug
# Stdout: TSV source, pid, log, worktree, session_key
# Returns: 0 found, 1 none
#######################################
_dsi_find_ledger_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"
	local entry pid session_key worktree_path log_path
	entry=$("$_DSI_LEDGER_HELPER" check-issue --issue "$issue_number" --repo "$repo_slug" 2>/dev/null) || entry=""
	[[ -n "$entry" ]] || return 1
	pid=$(printf '%s' "$entry" | jq -r '.pid // "?"')
	session_key=$(printf '%s' "$entry" | jq -r --arg unknown "$_DSI_UNKNOWN_VALUE" '.session_key // $unknown')
	worktree_path=$(printf '%s' "$entry" | jq -r '.worktree_path // ""')
	[[ -n "$worktree_path" && "$worktree_path" != "null" ]] || worktree_path="$_DSI_UNKNOWN_VALUE"
	log_path=$(_dsi_find_log_for_pid "$issue_number" "$pid")
	printf 'ledger\t%s\t%s\t%s\t%s\n' "$pid" "$log_path" "$worktree_path" "$session_key"
	return 0
}

#######################################
# Print active dispatch details from a TSV record.
# Args: TSV source, pid, log, worktree, session_key
#######################################
_dsi_print_dispatch_details() {
	local record="$1"
	local source pid log_path worktree_path session_key
	IFS=$'\t' read -r source pid log_path worktree_path session_key <<<"$record"
	_dsi_info "  Evidence source:  ${source}"
	_dsi_info "  Existing PID:     ${pid}"
	_dsi_info "  Existing log:     ${log_path}"
	_dsi_info "  Existing worktree:${worktree_path}"
	_dsi_info "  Existing session: ${session_key}"
	return 0
}

#######################################
# Verify that a ledger record still names the same live worker process.
# A lease can intentionally outlive its local PID for cross-runner dedup, so
# launch-worker status must independently validate PID liveness plus the
# session, worktree, issue, and repository encoded in the process command.
# Args: $1 - issue number, $2 - repo slug, $3 - ledger TSV record
# Returns: 0 verified live worker, 1 stale/dead/reused PID evidence
#######################################
_dsi_ledger_record_has_live_identity() {
	local issue_number="$1"
	local repo_slug="$2"
	local record="$3"
	local source="" pid="" log_path="" worktree_path="" session_key=""
	IFS=$'\t' read -r source pid log_path worktree_path session_key <<<"$record"

	[[ "$source" == "ledger" && "$pid" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$session_key" && "$session_key" != "$_DSI_UNKNOWN_VALUE" ]] || return 1
	[[ -n "$worktree_path" && "$worktree_path" != "$_DSI_UNKNOWN_VALUE" ]] || return 1
	_dsi_pid_is_live "$pid" || return 1

	local line="" process_pid="" stat="" cmd=""
	local process_session="" process_worktree="" process_repo=""
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		process_pid="${line%%[[:space:]]*}"
		[[ "$process_pid" == "$pid" ]] || continue
		line="${line#*[[:space:]]}"
		stat="${line%%[[:space:]]*}"
		cmd="${line#*[[:space:]]}"
		[[ "$stat" != *Z* && "$stat" != *T* ]] || return 1
		[[ "$cmd" == *"headless-runtime-helper.sh"* ]] || return 1

		process_session=$(printf '%s' "$cmd" | sed -n 's/.*--session-key[[:space:]]\([^[:space:]]*\).*/\1/p')
		[[ "$process_session" == "$session_key" ]] || return 1
		process_worktree=$(_dsi_extract_worktree_from_cmd "$cmd")
		[[ "$process_worktree" == "$worktree_path" ]] || return 1
		_dsi_cmd_matches_issue "$issue_number" "$cmd" || return 1
		process_repo=$(_dsi_repo_slug_for_worktree "$process_worktree")
		[[ "$process_repo" == "$repo_slug" ]] || return 1
		return 0
	done < <(_dsi_ps_worker_lines)

	return 1
}

#######################################
# Print an existing active dispatch as a blocking duplicate.
# Args: TSV source, pid, log, worktree, session_key
#######################################
_dsi_print_existing_dispatch() {
	local record="$1"
	local source="${record%%$'\t'*}"
	_dsi_err "Active worker already owns this issue or worktree (${source})"
	_dsi_print_dispatch_details "$record"
	return 0
}

#######################################
# Fail closed if an active dispatch already owns repo+issue or worktree.
# Args: $1 - issue number, $2 - repo slug, $3 - worktree path (optional)
# Returns: 0 clear, 1 blocked
#######################################
_dsi_guard_no_existing_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"
	local worktree_path="${3:-}"
	local record=""
	if record=$(_dsi_find_ledger_dispatch "$issue_number" "$repo_slug"); then
		_dsi_print_existing_dispatch "$record"
		return 1
	fi
	if record=$(_dsi_find_live_dispatch "$issue_number" "$repo_slug" "$worktree_path"); then
		_dsi_print_existing_dispatch "$record"
		return 1
	fi
	return 0
}

#######################################
# Resolve the real worker PID from the worker_log file.
# headless-runtime-helper.sh _detach_worker prints "Dispatched PID: <pid>"
# right before forking the actual worker subshell (see headless-runtime-helper.sh:1483).
# We poll the log briefly waiting for that line; if it never appears,
# fall back to the launch wrapper PID (degraded — ledger may show dead PID).
# Args: $1 - worker_log path, $2 - launch_pid (fallback)
# Stdout: PID (single integer)
#######################################
_dsi_resolve_worker_pid() {
	local worker_log="$1"
	local launch_pid="$2"
	local attempts=0
	while [[ $attempts -lt 30 ]]; do
		if [[ -s "$worker_log" ]]; then
			local pid
			pid=$(grep -oE 'Dispatched PID: [0-9]+' "$worker_log" 2>/dev/null | awk '{print $3}' | head -1)
			if [[ -n "$pid" ]]; then
				echo "$pid"
				return 0
			fi
		fi
		sleep 0.1
		attempts=$((attempts + 1))
	done
	# Fallback: caller can decide what to do with degraded state
	_dsi_warn "Could not extract worker PID from log within 3s — using launch wrapper PID (ledger may go stale)"
	echo "$launch_pid"
	return 0
}

#######################################
# Return the detached runtime log path used by headless-runtime-helper.sh.
# Args: $1 - session_key
# Stdout: absolute log path
#######################################
_dsi_detached_runtime_log() {
	local session_key="$1"
	printf '/tmp/worker-%s.log' "$session_key"
	return 0
}

#######################################
# Wait until a detached worker reaches an observable readiness signal.
#
# The outer nohup wrapper can exit successfully before model selection,
# canary, and worker preparation complete. Treat launch as ready only when the
# real child is alive and has emitted the canonical worker-start marker, or has
# exited/failed with inspectable log evidence. Ledger registration happens
# before the worker-start marker, so it is progress evidence but not readiness.
# This prevents silent success when pre-worker setup blocks.
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - session_key
#   $4 - worker_pid
#   $5 - launcher_log path
# Returns: 0 ready, 1 failed/not-ready before timeout
#######################################
_dsi_wait_for_worker_readiness() {
	local issue_number="$1"
	local repo_slug="$2"
	local session_key="$3"
	local worker_pid="$4"
	local launcher_log="$5"
	local runtime_log
	runtime_log=$(_dsi_detached_runtime_log "$session_key")
	local timeout_s="${AIDEVOPS_DSI_READY_TIMEOUT_SECONDS:-20}"
	local attempts=0
	local max_attempts=200

	if ! [[ "$timeout_s" =~ ^[0-9]+$ ]]; then
		timeout_s=20
	fi
	max_attempts=$((timeout_s * 10))

	while [[ "$attempts" -le "$max_attempts" ]]; do
		if [[ -s "$runtime_log" ]] &&
			grep -Fq -e "worker_started" -e "worker_start session=${session_key}" "$runtime_log" 2>/dev/null; then
			return 0
		fi

		if [[ -n "$worker_pid" ]] && ! kill -0 "$worker_pid" 2>/dev/null; then
			_dsi_err "Worker launch failed — detached child exited before readiness"
			_dsi_info "  Launcher log: ${launcher_log}"
			_dsi_info "  Runtime log:  ${runtime_log}"
			return 1
		fi

		if [[ "$attempts" -eq "$max_attempts" ]]; then
			break
		fi
		sleep 0.1
		attempts=$((attempts + 1))
	done

	_dsi_err "Worker launch did not reach readiness within ${timeout_s}s"
	_dsi_info "  Worker PID:   ${worker_pid}"
	_dsi_info "  Launcher log: ${launcher_log}"
	_dsi_info "  Runtime log:  ${runtime_log}"
	return 1
}

#######################################
# Build the worker prompt.  Headless-runtime-lib auto-appends
# HEADLESS_CONTINUATION_CONTRACT_V6 when it sees "/full-loop" — see
# headless-runtime-lib.sh:437-509.
# Args: $1 - issue_number, $2 - issue_url
# Stdout: prompt text
#######################################
_dsi_build_prompt() {
	local issue_number="$1"
	local issue_url="$2"
	local prompt="/full-loop Implement issue #${issue_number}"
	if [[ -n "$issue_url" ]]; then
		prompt="${prompt} (${issue_url})"
	fi
	printf '%s' "$prompt"
	return 0
}

#######################################
# Launch the worker via headless-runtime-helper.sh in detached mode.
# Args:
#   $1 - session_key
#   $2 - worktree_path
#   $3 - title
#   $4 - prompt
#   $5 - tier
#   $6 - selected_model (may be empty for auto-select)
#   $7 - agent_name
#   $8 - worker_log path
#   $9 - issue_number
#   $10 - repo_slug
#   $11 - self_login (dispatching GitHub login)
# Stdout (on success): worker PID (single line)
# Returns: 0 launched, 1 failed
#######################################
_dsi_launch_worker() {
	local session_key="$1"
	local worktree_path="$2"
	local title="$3"
	local prompt="$4"
	local tier="$5"
	local selected_model="$6"
	local agent_name="$7"
	local worker_log="$8"
	local issue_number="$9"
	local repo_slug="${10:-}"
	local self_login="${11:-}"

	local -a cmd=(
		env
		HEADLESS=1
		FULL_LOOP_HEADLESS=true
		WORKER_ISSUE_NUMBER="$issue_number"
		WORKER_GITHUB_LOGIN="$self_login"
		WORKER_WORKTREE_PATH="$worktree_path"
		WORKER_REPO_SLUG="$repo_slug"
		WORKER_PR_BASE_BRANCH="$_DSI_DISPATCH_BASE_BRANCH"
		GITHUB_REPOSITORY="$repo_slug"
		AIDEVOPS_ALLOW_WORKER_WORKTREE_OWNER_TRANSFER=1
		"$_DSI_HEADLESS" run
		--role worker
		--session-key "$session_key"
		--dir "$worktree_path"
		--tier "$tier"
		--title "$title"
		--prompt "$prompt"
		--detach
	)
	if [[ -n "$selected_model" ]]; then
		cmd+=(--model "$selected_model")
	fi
	if [[ -n "$agent_name" ]]; then
		cmd+=(--agent "$agent_name")
	fi

	# Run in background, redirect stdout/stderr to worker_log so caller
	# doesn't block. Capture launch PID (the env wrapper, which then
	# exec's the helper).
	mkdir -p "$_DSI_LOG_DIR"
	nohup "${cmd[@]}" >>"$worker_log" 2>&1 &
	local pid=$!
	disown "$pid" 2>/dev/null || true

	if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
		_dsi_err "Worker launch failed — process did not start"
		return 1
	fi

	echo "$pid"
	return 0
}

#######################################
# Parse + validate dispatch args. Sets globals:
#   _DSI_ARG_ISSUE, _DSI_ARG_REPO, _DSI_ARG_MODEL, _DSI_ARG_DRYRUN,
#   _DSI_ARG_NO_CEREMONY, _DSI_ARG_AGENT
# Returns: 0 ok, 2 invalid usage (caller should propagate)
#######################################
_dsi_parse_dispatch_args() {
	_DSI_ARG_ISSUE=""
	_DSI_ARG_REPO=""
	_DSI_ARG_MODEL=""
	_DSI_ARG_AGENT="Build+"
	_DSI_ARG_DRYRUN=0
	_DSI_ARG_NO_CEREMONY=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--model)
			# Guard: --model requires a value, and that value must not look
			# like another flag (covers `--model --dry-run` typo). The
			# ${...} braced form keeps the positional-parameter ratchet
			# (which matches bare \$[1-9]) happy.
			if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
				_dsi_err "--model requires an exact model id; prefer a tier:simple, tier:standard, or tier:thinking issue label for normal routing"
				return 2
			fi
			_DSI_ARG_MODEL="${2}"
			shift 2
			;;
		--agent)
			if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
				_dsi_err "--agent requires an agent name (default: Build+)"
				return 2
			fi
			_DSI_ARG_AGENT="${2}"
			shift 2
			;;
		--base)
			if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
				_dsi_err "--base requires a branch or ref (e.g. develop or origin/develop)"
				return 2
			fi
			AIDEVOPS_DISPATCH_BASE_REF="${2}"
			export AIDEVOPS_DISPATCH_BASE_REF
			shift 2
			;;
		--dry-run)
			_DSI_ARG_DRYRUN=1
			shift
			;;
		--no-ceremony)
			# Skip the pre-launch dispatch ceremony (status:queued + origin:worker
			# + assignee normalize). Default: ceremony is ON. Use only when
			# you intentionally want to bypass dedup-visibility — e.g., when
			# debugging a stuck worker by re-launching without disturbing
			# the existing label/assignee state.
			_DSI_ARG_NO_CEREMONY=1
			shift
			;;
		-h | --help)
			_dispatch_usage
			return 100 # special: caller exits 0
			;;
		--*)
			_dsi_err "Unknown flag for dispatch: $arg"
			return 2
			;;
		*)
			if [[ -z "$_DSI_ARG_ISSUE" ]]; then
				_DSI_ARG_ISSUE="$arg"
			elif [[ -z "$_DSI_ARG_REPO" ]]; then
				_DSI_ARG_REPO="$arg"
			else
				_dsi_err "Unexpected positional arg: $arg"
				return 2
			fi
			shift
			;;
		esac
	done
	if [[ -z "$_DSI_ARG_ISSUE" || -z "$_DSI_ARG_REPO" ]]; then
		_dsi_err "dispatch requires <issue_number> and <owner/repo>"
		_dispatch_usage
		return 2
	fi
	if [[ ! "$_DSI_ARG_ISSUE" =~ ^[0-9]+$ ]]; then
		_dsi_err "Issue number must be numeric: ${_DSI_ARG_ISSUE}"
		return 2
	fi
	if [[ ! "$_DSI_ARG_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		_dsi_err "Repo slug must be owner/repo format: ${_DSI_ARG_REPO}"
		return 2
	fi
	return 0
}

#######################################
# Print dry-run plan. Caller has already loaded metadata + resolved model.
# Args:
#   $1 issue_number, $2 repo_slug, $3 session_key
#   $4 dedup_state (blocked|clear|recovering|error), $5 dedup_rc, $6 dedup_result
#######################################
_dsi_print_dryrun() {
	local issue_number="$1"
	local repo_slug="$2"
	local session_key="$3"
	local dedup_state="$4"
	local dedup_rc="$5"
	local dedup_result="$6"
	local repo_path=""
	repo_path=$(_dsi_repo_path_for_slug "$repo_slug" 2>/dev/null || true)
	local base_ref=""
	base_ref=$(_dsi_dispatch_base_ref "$repo_slug" "$repo_path")
	_dsi_info "DRY RUN — would dispatch:"
	_dsi_info "  Issue:        #${issue_number} (${repo_slug})"
	_dsi_info "  Title:        ${_DSI_ISSUE_TITLE}"
	_dsi_info "  Labels:       ${_DSI_ISSUE_LABELS}"
	_dsi_info "  Tier:         ${_DSI_TIER}"
	_dsi_info "  Model:        ${_DSI_SELECTED_MODEL:-<auto>}"
	_dsi_info "  Agent:        ${_DSI_ARG_AGENT}"
	_dsi_info "  Session key:  ${session_key}"
	_dsi_info "  Prompt:       $(_dsi_build_prompt "$issue_number" "$_DSI_ISSUE_URL")"
	_dsi_info "  Base ref:     ${base_ref}"
	_dsi_info "  Worktree:     would create auto-<ts>-gh${issue_number}"
	if [[ "$_DSI_ARG_NO_CEREMONY" -eq 1 ]]; then
		_dsi_info "  Ceremony:     SKIPPED (--no-ceremony) — labels and assignee unchanged"
	else
		_dsi_info "  Ceremony:     would set status:queued + origin:worker + assignee=self (pulse-parity)"
	fi
	case "$dedup_state" in
	blocked) _dsi_warn "  Dedup:        WOULD BLOCK — ${dedup_result}" ;;
	clear) _dsi_info "  Dedup:        clear (no active claim)" ;;
	"$_DSI_STATE_RECOVERING") _dsi_warn "  Dedup:        RECOVERING — dispatch remains unsafe: ${dedup_result}" ;;
	error) _dsi_err "  Dedup:        ERROR (exit ${dedup_rc}) — would refuse to dispatch: ${dedup_result}" ;;
	esac
	if [[ "$dedup_state" == "$_DSI_STATE_RECOVERING" ]]; then
		_dsi_warn "Dry-run stopped at recoverable safety state (no worker launched)"
	else
		_dsi_ok "Dry-run complete (no worker launched)"
	fi
	return 0
}

#######################################
# Run the external dedup guard and retry only evidenced transient uncertainty.
# Sets _DSI_DEDUP_RESULT, _DSI_DEDUP_RC, _DSI_DEDUP_STATE, _DSI_DEDUP_ATTEMPTS.
# Args: $1 issue number, $2 repo slug, $3 current login
#######################################
_dsi_run_dedup_check() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local retry_number=0
	local classification=""
	local retry_delay=""

	_DSI_DEDUP_ATTEMPTS=0
	while ((_DSI_DEDUP_ATTEMPTS < 3)); do
		_DSI_DEDUP_ATTEMPTS=$((_DSI_DEDUP_ATTEMPTS + 1))
		_DSI_DEDUP_RC=0
		_DSI_DEDUP_RESULT=$(ISSUE_META_JSON="$_DSI_ISSUE_META_JSON" \
			"$_DSI_DEDUP_HELPER" is-assigned "$issue_number" "$repo_slug" "$self_login" 2>&1) || _DSI_DEDUP_RC=$?

		if [[ "$_DSI_DEDUP_RC" -eq 0 && "$_DSI_DEDUP_RESULT" == GUARD_UNCERTAIN* ]]; then
			_DSI_DEDUP_STATE="$_DSI_STATE_RECOVERING"
		elif [[ "$_DSI_DEDUP_RC" -eq 0 ]]; then
			_DSI_DEDUP_STATE="blocked"
		elif [[ "$_DSI_DEDUP_RC" -eq 1 ]]; then
			_DSI_DEDUP_STATE="clear"
		else
			_DSI_DEDUP_STATE="error"
		fi

		[[ "$_DSI_DEDUP_STATE" == "$_DSI_STATE_RECOVERING" ]] || return 0
		((_DSI_DEDUP_ATTEMPTS < 3)) || return 0
		classification=$("$_DSI_BACKOFF_HELPER" classify-lookup-failure "$_DSI_DEDUP_RESULT" 2>/dev/null || printf 'unknown')
		[[ "$classification" == "transient" ]] || return 0
		retry_number=$((retry_number + 1))
		retry_delay=$("$_DSI_BACKOFF_HELPER" lookup-retry-delay "$_DSI_DEDUP_RESULT" "$retry_number" 2>/dev/null) || return 0
		_dsi_warn "Dedup lookup uncertain with transient evidence; retry ${retry_number}/2 after ${retry_delay}s"
		sleep "$retry_delay"
		# Change the lookup conditions before retrying: refresh the authoritative
		# metadata rather than repeating the same prefetched payload immediately.
		if ! _dsi_load_issue_meta "$issue_number" "$repo_slug"; then
			_DSI_DEDUP_RESULT="${_DSI_DEDUP_RESULT} metadata-refresh-failed"
			return 0
		fi
	done
	return 0
}

_dsi_acquire_consensus_claim() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local claim_output=""
	local claim_rc=0

	_DSI_CLAIM_WON=0
	_DSI_CLAIM_COMMENT_ID=""
	if [[ -z "$self_login" ]]; then
		_dsi_err "Cannot resolve runner login for consensus claim; refusing dispatch"
		return 1
	fi
	claim_output=$("$_DSI_DEDUP_HELPER" claim "$issue_number" "$repo_slug" "$self_login" 2>&1) || claim_rc=$?
	case "$claim_rc" in
	0)
		_DSI_CLAIM_WON=1
		_DSI_CLAIM_COMMENT_ID=$(printf '%s' "$claim_output" | sed -n 's/.*comment_id=\([0-9][0-9]*\).*/\1/p')
		_dsi_info "Consensus claim won for #${issue_number}"
		return 0
		;;
	1)
		_dsi_warn "Consensus claim lost for #${issue_number}; another runner won"
		return 1
		;;
	*)
		_dsi_err "Consensus claim error for #${issue_number} (rc=${claim_rc}) — failing closed"
		_dsi_info "  Output: ${claim_output}"
		return 1
		;;
	esac
}

_dsi_release_consensus_claim() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local reason="$4"
	local body=""
	[[ "$_DSI_CLAIM_WON" -eq 1 ]] || return 0
	if [[ "$_DSI_CLAIM_COMMENT_ID" =~ ^[0-9]+$ ]]; then
		if gh api "repos/${repo_slug}/issues/comments/${_DSI_CLAIM_COMMENT_ID}" \
			--method DELETE >/dev/null 2>&1; then
			_DSI_CLAIM_WON=0
			_DSI_CLAIM_COMMENT_ID=""
			return 0
		fi
		_dsi_warn "Failed to delete prelaunch claim ${_DSI_CLAIM_COMMENT_ID}; posting release marker"
	fi
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=manual_dispatch_prelaunch:${reason} runner=${self_login} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
<!-- ops:end -->"
	if ! gh api "repos/${repo_slug}/issues/${issue_number}/comments" --method POST --field body="$body" >/dev/null 2>&1; then
		_dsi_warn "Failed to post CLAIM_RELEASED for #${issue_number} after ${reason}"
		return 1
	fi
	_DSI_CLAIM_WON=0
	_DSI_CLAIM_COMMENT_ID=""
	return 0
}

_dsi_run_required_predispatch_validator() {
	local issue_number="$1"
	local repo_slug="$2"
	local validator_rc=0
	if [[ ! -x "$_DSI_VALIDATOR_HELPER" ]]; then
		_dsi_err "Pre-dispatch validator unavailable; refusing manual dispatch"
		return 1
	fi
	"$_DSI_VALIDATOR_HELPER" validate "$issue_number" "$repo_slug" >/dev/null 2>&1 || validator_rc=$?
	case "$validator_rc" in
	0) return 0 ;;
	20)
		case ",${_DSI_ISSUE_LABELS}," in
		*",review-followup,"* | *",source:review-scanner,"*)
			_dsi_err "Review-followup validation is uncertain; failing closed"
			return 1
			;;
		esac
		return 0
		;;
	10)
		_dsi_warn "Pre-dispatch validator closed or blocked #${issue_number}"
		return 1
		;;
	*)
		_dsi_err "Pre-dispatch validator returned rc=${validator_rc}; failing closed"
		return 1
		;;
	esac
}

#######################################
# Persist a machine-readable continuation checkpoint for an uncertain guard.
# Args: $1 issue, $2 repo, $3 trigger, $4 attempts
#######################################
_dsi_write_recovery_checkpoint() {
	local issue_number="$1"
	local repo_slug="$2"
	local trigger="$3"
	local attempts="$4"
	local checkpoint_dir="${AIDEVOPS_DSI_CHECKPOINT_DIR:-${HOME}/.aidevops/.agent-workspace/work/dispatch-recovery}"
	local checkpoint_file="${checkpoint_dir}/${repo_slug//\//-}-${issue_number}.json"
	local checkpoint_tmp="${checkpoint_file}.tmp.$$"
	local resume_command=""
	local -a resume_args=("${_DSI_SCRIPT_DIR}/dispatch-single-issue-helper.sh" dispatch "$issue_number" "$repo_slug")

	[[ -n "$_DSI_ARG_MODEL" ]] && resume_args+=(--model "$_DSI_ARG_MODEL")
	[[ -n "$_DSI_ARG_AGENT" ]] && resume_args+=(--agent "$_DSI_ARG_AGENT")
	[[ -n "${AIDEVOPS_DISPATCH_BASE_REF:-}" ]] && resume_args+=(--base "$AIDEVOPS_DISPATCH_BASE_REF")
	[[ "$_DSI_ARG_NO_CEREMONY" -eq 1 ]] && resume_args+=(--no-ceremony)
	[[ "$_DSI_ARG_DRYRUN" -eq 1 ]] && resume_args+=(--dry-run)
	printf -v resume_command '%q ' "${resume_args[@]}"
	resume_command="${resume_command% }"

	mkdir -p "$checkpoint_dir"
	jq -n \
		--arg status "$_DSI_STATE_RECOVERING" \
		--arg issue "$issue_number" \
		--arg repo "$repo_slug" \
		--arg trigger "$trigger" \
		--argjson attempts "$attempts" \
		--arg resume_command "$resume_command" \
		--arg resume_condition "one authoritative metadata/dedup read returns a definitive clear or blocked result" \
		'{status:$status, issue:$issue, repo:$repo, trigger:$trigger, dedup_attempts:$attempts,
		  completed_checks:["issue metadata loaded","target is an issue","dispatch holds checked","parent-task gate checked","dedup remained fail-closed"],
		  unsafe_route_not_to_repeat:"bypass dedup or repeat an identical lookup without changed conditions",
		  resume_command:$resume_command, resume_condition:$resume_condition}' >"$checkpoint_tmp" || return 1
	mv "$checkpoint_tmp" "$checkpoint_file"
	_dsi_warn "Recovery checkpoint: ${checkpoint_file}"
	printf 'RECOVERY_CHECKPOINT_JSON='
	jq -c . "$checkpoint_file"
	return 0
}

#######################################
# Resolve the authenticated GitHub login without accepting caller-supplied
# identity. REST remains preferred; authenticated GraphQL viewer identity is
# the bounded fallback when REST is unavailable. Both transports use the same
# gh credential context, and malformed output fails closed.
#######################################
_dsi_resolve_runner_login() {
	local runner_login=""

	runner_login=$(gh api user --jq '.login // ""' 2>/dev/null || true)
	if [[ "$runner_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		printf '%s\n' "$runner_login"
		return 0
	fi

	runner_login=$(gh api graphql \
		-f 'query=query { viewer { login } }' \
		--jq '.data.viewer.login // ""' 2>/dev/null || true)
	if [[ "$runner_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		printf '%s\n' "$runner_login"
		return 0
	fi

	return 1
}

#######################################
# Subcommand: dispatch <issue> <slug> [--model M] [--dry-run]
#######################################
cmd_dispatch() {
	local rc=0
	_dsi_parse_dispatch_args "$@" || rc=$?
	case "$rc" in
	0) ;;
	100) return 0 ;;
	*) return "$rc" ;;
	esac
	local issue_number="$_DSI_ARG_ISSUE"
	local repo_slug="$_DSI_ARG_REPO"

	# Step 1-2: validate + load + parent-task gate
	_dsi_load_issue_meta "$issue_number" "$repo_slug" || return 1
	local target_pr_rc=0
	_dsi_target_is_pull_request "$issue_number" "$repo_slug" || target_pr_rc=$?
	if [[ "$target_pr_rc" -eq 0 ]]; then
		_dsi_err "Target #${issue_number} in ${repo_slug} is a pull request, not a dispatchable issue (GH#22948)"
		return 1
	fi
	if [[ "$target_pr_rc" -ne 1 ]]; then
		_dsi_err "Unable to verify #${issue_number} in ${repo_slug} is not a pull request; refusing dispatch (GH#22948, rc=${target_pr_rc})"
		return 1
	fi
	_dsi_guard_no_interactive_hold "$_DSI_ISSUE_LABELS" || return 1
	_dsi_guard_no_maintainer_review_required "$_DSI_ISSUE_LABELS" "$issue_number" "$repo_slug" || return 1
	_dsi_guard_issue_author_trust "$issue_number" "$repo_slug" || return 1
	_dsi_guard_no_maintainer_permission_required "$_DSI_ISSUE_LABELS" "$issue_number" "$repo_slug" || return 1
	_dsi_guard_permission_history_verified "$issue_number" "$repo_slug" || return 1
	_dsi_check_parent_task "$_DSI_ISSUE_LABELS" || return 1

	# Step 3: dedup check (informational under --dry-run, blocking otherwise).
	# Helper exit codes (per dispatch-dedup-helper.sh::is-assigned):
	#   0 = blocked (active claim exists)
	#   1 = free to dispatch (no claim)
	#   * = error (helper missing, network failure, malformed response, etc.)
	# Treat anything other than 0 or 1 as "fail closed" — refuse to dispatch
	# when we can't be sure of the state. The pulse has its own retry layers.
	local self_login
	self_login=$(_dsi_resolve_runner_login 2>/dev/null) || self_login=""
	_dsi_run_dedup_check "$issue_number" "$repo_slug" "$self_login"
	local dedup_result="$_DSI_DEDUP_RESULT"
	local dedup_rc="$_DSI_DEDUP_RC"
	local dedup_state="$_DSI_DEDUP_STATE"

	# Step 4: fail closed if an active manual/pulse worker already owns the
	# same repo+issue. This closes the gap where labels or ledger entries are
	# stale/missing but a live worker process is still writing in a worktree.
	if [[ "$_DSI_ARG_DRYRUN" -ne 1 ]]; then
		_dsi_guard_no_existing_dispatch "$issue_number" "$repo_slug" || return 1
	fi

	# Step 5: resolve model
	_dsi_resolve_model "$_DSI_ISSUE_LABELS" "$_DSI_ARG_MODEL"
	local session_key
	session_key="manual-cli-${issue_number}-$(date +%s)"

	# Step 6: dry-run short-circuit
	if [[ "$_DSI_ARG_DRYRUN" -eq 1 ]]; then
		_dsi_print_dryrun "$issue_number" "$repo_slug" "$session_key" "$dedup_state" "$dedup_rc" "$dedup_result"
		if [[ "$dedup_state" == "$_DSI_STATE_RECOVERING" ]]; then
			_dsi_write_recovery_checkpoint "$issue_number" "$repo_slug" "$dedup_result" "$_DSI_DEDUP_ATTEMPTS" || true
			return 75
		fi
		return 0
	fi

	# Real dispatch: honour dedup block + fail-closed on errors
	case "$dedup_state" in
	blocked)
		_dsi_warn "Skipped: dispatch dedup check blocked"
		_dsi_info "  Reason: ${dedup_result}"
		_dsi_info "  Use a separate test issue, or release the existing claim first."
		return 1
		;;
	"$_DSI_STATE_RECOVERING")
		_dsi_err "Dedup guard is uncertain — failing closed, refusing to dispatch"
		_dsi_info "  Trigger: ${dedup_result}"
		_dsi_write_recovery_checkpoint "$issue_number" "$repo_slug" "$dedup_result" "$_DSI_DEDUP_ATTEMPTS" || true
		return 75
		;;
	error)
		_dsi_err "Dedup check failed (exit ${dedup_rc}) — failing closed, refusing to dispatch"
		_dsi_info "  Output: ${dedup_result}"
		_dsi_info "  Diagnose with: $_DSI_DEDUP_HELPER is-assigned $issue_number $repo_slug $self_login"
		return 1
		;;
	esac
	if ! _dsi_acquire_consensus_claim "$issue_number" "$repo_slug" "$self_login"; then
		return 1
	fi
	if ! _dsi_run_required_predispatch_validator "$issue_number" "$repo_slug"; then
		_dsi_release_consensus_claim "$issue_number" "$repo_slug" "$self_login" "predispatch_validator_blocked" || true
		return 1
	fi

	_dsi_dispatch_after_dedup_clear "$issue_number" "$repo_slug" "$self_login" "$session_key"
	return $?
}

_dsi_dispatch_after_dedup_clear() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local session_key="$4"

	_dsi_apply_prelaunch_ceremony_if_enabled "$issue_number" "$repo_slug" "$self_login"

	# Step 7: pre-create worktree
	if ! _dsi_create_worktree "$issue_number" "$repo_slug"; then
		_dsi_reset_after_prelaunch_failure "$issue_number" "$repo_slug" "$self_login" "worktree_precreation_failed"
		return 1
	fi

	# Step 7.5: re-check after worktree creation so an existing live process
	# on the same worktree cannot be joined by a second manual launch.
	if ! _dsi_guard_no_existing_dispatch "$issue_number" "$repo_slug" "$_DSI_WORKTREE_PATH"; then
		_dsi_reset_after_prelaunch_failure "$issue_number" "$repo_slug" "$self_login" "existing_dispatch_after_precreate"
		return 1
	fi

	# Steps 8-10 + report: launch worker, resolve real PID, register ledger,
	# print success summary. Extracted to keep cmd_dispatch under the 100-line
	# function-complexity gate (t3000).
	if ! _dsi_launch_and_report "$issue_number" "$repo_slug" "$self_login" "$session_key"; then
		_dsi_reset_after_prelaunch_failure "$issue_number" "$repo_slug" "$self_login" "worker_launch_failed"
		return 1
	fi
	return 0
}

_dsi_apply_prelaunch_ceremony_if_enabled() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"

	# Step 5.5: pre-launch dispatch ceremony (t3000) — pulse-parity ownership
	# claim. Closes the race window between worker launch and the next pulse
	# cycle by transitioning status:queued + origin:worker + assignee=self
	# atomically before the worker spawns. Bypassed via --no-ceremony.
	if [[ "$_DSI_ARG_NO_CEREMONY" -ne 1 ]]; then
		_dsi_apply_dispatch_ceremony "$issue_number" "$repo_slug" \
			"$self_login" "$_DSI_ISSUE_META_JSON" || true
	fi
	return 0
}

_dsi_reset_after_prelaunch_failure() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local reason="$4"

	_dsi_release_consensus_claim "$issue_number" "$repo_slug" "$self_login" "$reason" || true
	if [[ "$_DSI_ARG_NO_CEREMONY" -eq 1 ]]; then
		return 0
	fi
	_dsi_warn "Pre-launch failure (${reason}); restoring #${issue_number} to status:available"
	local -a reset_flags=()
	if [[ -n "$self_login" ]]; then
		reset_flags=(--remove-assignee "$self_login")
	fi
	set_issue_status "$issue_number" "$repo_slug" "available" \
		"${reset_flags[@]}" >/dev/null 2>&1 || true
	return 0
}

# Steps 7-9 of cmd_dispatch: launch the headless runtime, resolve the real
# worker PID from its log header, register it in the dispatch ledger with
# that PID (so liveness checks reflect the actual worker, not the wrapper),
# and emit the human-facing success summary.
# Args:
#   $1 issue_number
#   $2 repo_slug
#   $3 self_login
#   $4 session_key
# Reads: _DSI_ISSUE_URL, _DSI_LOG_DIR, _DSI_WORKTREE_PATH, _DSI_ISSUE_TITLE,
#        _DSI_TIER, _DSI_SELECTED_MODEL, _DSI_ARG_AGENT.
_dsi_launch_and_report() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local session_key="$4"

	local prompt worker_log
	prompt=$(_dsi_build_prompt "$issue_number" "$_DSI_ISSUE_URL")
	worker_log="${_DSI_LOG_DIR}/manual-dispatch-${issue_number}-$(date +%Y%m%d-%H%M%S).log"
	local launch_pid
	launch_pid=$(_dsi_launch_worker \
		"$session_key" "$_DSI_WORKTREE_PATH" "$_DSI_ISSUE_TITLE" \
		"$prompt" "$_DSI_TIER" "$_DSI_SELECTED_MODEL" \
		"$_DSI_ARG_AGENT" "$worker_log" "$issue_number" "$repo_slug" "$self_login") || return 1

	local worker_pid
	worker_pid=$(_dsi_resolve_worker_pid "$worker_log" "$launch_pid")
	_dsi_wait_for_worker_readiness "$issue_number" "$repo_slug" "$session_key" "$worker_pid" "$worker_log" || return 1

	_dsi_register_ledger "$issue_number" "$repo_slug" "$session_key" "$worker_pid"

	_dsi_ok "Worker launched"
	_dsi_info "  Worker PID: ${worker_pid}"
	_dsi_info "  Issue:      #${issue_number} (${repo_slug})"
	_dsi_info "  Tier/model: ${_DSI_TIER} / ${_DSI_SELECTED_MODEL:-<auto>}"
	_dsi_info "  Agent:      ${_DSI_ARG_AGENT}"
	_dsi_info "  Worktree:   ${_DSI_WORKTREE_PATH}"
	_dsi_info "  Log:        ${worker_log}"
	_dsi_info "  Session:    ${session_key}"
	_dsi_info ""
	_dsi_info "Tail with:  tail -f ${worker_log}"
	return 0
}

#######################################
# Subcommand: status <issue> <slug>
# Reads the dispatch ledger for the given issue and pretty-prints the state,
# including a PID liveness check via kill -0 (same as dispatch-ledger-helper.sh
# cmd_check_issue). This ensures `status` and the pulse agree on whether a
# worker is actually running — not just recorded in the ledger.
#######################################
cmd_status() {
	local issue_number="${1:-}"
	local repo_slug="${2:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		_dsi_err "status requires <issue_number> and <owner/repo>"
		return 2
	fi

	local record=""
	if record=$(_dsi_find_ledger_dispatch "$issue_number" "$repo_slug") &&
		_dsi_ledger_record_has_live_identity "$issue_number" "$repo_slug" "$record"; then
		_dsi_ok "Active dispatch for #${issue_number} (${repo_slug}):"
		_dsi_print_dispatch_details "$record"
		return 0
	fi
	if record=$(_dsi_find_live_dispatch "$issue_number" "$repo_slug" ""); then
		_dsi_ok "Active dispatch for #${issue_number} (${repo_slug}) from live process evidence:"
		_dsi_print_dispatch_details "$record"
		return 0
	fi

	_dsi_info "No active dispatch for #${issue_number} in ${repo_slug}"
	return 0
}

_dispatch_usage() {
	cat <<'EOF'
Usage: dispatch-single-issue-helper.sh dispatch <issue_number> <owner/repo> [options]

Options:
  --model <id>    Advanced compatibility override for an exact model ID.
                  Prefer a tier:simple, tier:standard, or tier:thinking issue
                  label; runtime routing selects the preferred available
                  provider, model, and reasoning level. Default: standard.
  --agent <name>  Worker agent name. Default: Build+.
  --base <ref>    Worktree base branch/ref. Default: repo dispatch/PR base
                  policy from config, falling back to origin/HEAD.
  --dry-run       Print planned dispatch without launching.
  --no-ceremony   Skip the pre-launch ceremony (status:queued + origin:worker
                  + assignee normalize). Default: ceremony is ON. Use only
                  when you intentionally want to bypass dedup-visibility.
  -h, --help      Show this help.

Examples:
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --agent Build+
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --base origin/develop
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --dry-run
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --no-ceremony
EOF
	return 0
}

_usage() {
	cat <<'EOF'
Usage: dispatch-single-issue-helper.sh <command> [args]

Commands:
  dispatch <issue> <slug> [opts]   Launch a worker against a single issue.
  status   <issue> <slug>          Show active dispatch state from ledger.
  help                             Show this help.

Examples:
  # Smoke-test a newly-filed issue
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --dry-run

  # Real dispatch (tier inferred from tier:simple, tier:standard, or tier:thinking)
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops

  # Runtime routing selects the preferred provider, model, and reasoning level
  # for that workload tier. --model remains an advanced compatibility override.

  # Force an agent name (default: Build+)
  dispatch-single-issue-helper.sh dispatch 20882 marcusquinn/aidevops --agent Build+

  # Check status
  dispatch-single-issue-helper.sh status 20882 marcusquinn/aidevops

When to use:
  - Smoke-testing a newly-filed issue without waiting for the next pulse cycle
  - Debugging dispatch failures (model selection, dedup gates, prompt shape)
  - Validating brief worker-readiness before committing pulse capacity
  - Manually retrying a failed dispatch after fixing the underlying issue

NOT a replacement for the pulse — the pulse handles capacity, throttling,
adaptive cadence, and many other concerns this CLI does NOT cover.

Exit codes:
  0  Success (worker launched, dry-run completed, or skipped: already claimed)
  1  Validation failure (issue not found, parent-task, etc.)
  2  Invalid subcommand or missing required arg
EOF
	return 0
}

main() {
	local _cmd="${1:-}"
	shift || true

	case "$_cmd" in
	dispatch)
		cmd_dispatch "$@"
		;;
	status)
		cmd_status "$@"
		;;
	-h | --help | help | "")
		_usage
		exit 0
		;;
	*)
		_dsi_err "Unknown command: $_cmd"
		_usage
		exit 2
		;;
	esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
