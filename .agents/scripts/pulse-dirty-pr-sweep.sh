#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dirty-pr-sweep.sh — Periodic sweep of DIRTY PRs (t2350, GH#19948).
#
# Detects open PRs with `mergeStateStatus == "DIRTY"` and takes one of three
# actions based on age, content, and conflict scope:
#
#   Auto-rebase : PR < 48h old AND maintainer/worker-owned AND only TODO.md
#                 is conflicting → rebase onto origin/<default_branch> with union merge
#                 strategy, force-push, post documentation comment.
#   Auto-close  : PR > 7d old AND no human commits in 3d AND no
#                 `do-not-close` label → close with a "superseded" comment.
#   Route       : worker-backed PR has semantic conflicts that cannot be
#                 safely auto-rebased → append conflict feedback to the linked
#                 worker issue and close the stale PR for redispatch.
#   Notify      : PR has non-TODO.md conflicts and doesn't meet auto-close
#                 criteria → post a one-time informational comment
#                 (no label applied, no dispatch, no merge block).
#
# Safety gates:
#   - Never rebases PRs with non-TODO.md conflicts (always notify instead).
#   - Never auto-closes PRs tagged `do-not-close`, `hold-for-review`, OR linked
#     to an OPEN issue that has the `parent-task` label.
#   - Notifies for `origin:interactive` PRs only when the body contains no
#     recognised issue reference (`For #NNN`, `Ref #NNN`, or a closing
#     keyword). Referenced PRs use an extended 14d close window
#     (DIRTY_PR_CLOSE_MIN_AGE_INTERACTIVE, default 1209600s) instead of the
#     normal 7d; beyond that window they fall through to the standard
#     age/idle close heuristic (t2708, t2711 Q2). True orphans still notify.
#   - Idempotency: per-PR actions logged to a state file with timestamp;
#     re-running within 30 min (action cooldown) is a no-op for each PR.
#   - Dry-run: DRY_RUN=1 env var (or `--dry-run` CLI flag) prints would-be
#     actions without executing them.
#   - Audit log: every action is written via `audit-log-helper.sh log`
#     using the `operation.verify` event type with a structured detail.
#
# Usage (standalone):
#   pulse-dirty-pr-sweep.sh [--dry-run] [--repo owner/repo] [--pr NNN]
#   pulse-dirty-pr-sweep.sh --help
#
# Usage (module, sourced by pulse-wrapper.sh):
#   Call `dirty_pr_sweep_all_repos` once per pulse cycle — the function
#   short-circuits based on the interval file $DIRTY_PR_SWEEP_LAST_RUN.
#
# Files modified:
#   NEW: .agents/scripts/pulse-dirty-pr-sweep.sh
#   EDIT: .agents/scripts/pulse-wrapper.sh  — source + registration + interval + self-check
#   NEW: .agents/scripts/tests/test-dirty-pr-sweep.sh

# Include guard — prevent double-sourcing when another module pulls us in.
[[ -n "${_PULSE_DIRTY_PR_SWEEP_LOADED:-}" ]] && return 0 2>/dev/null || true
_PULSE_DIRTY_PR_SWEEP_LOADED=1

# Resolve script directory so we can source shared-constants.sh when executed
# standalone. When sourced by pulse-wrapper.sh, SCRIPT_DIR is already defined
# and shared-constants.sh has already been sourced — source is idempotent via
# its own include guard.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# shellcheck disable=SC2155
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=shared-constants.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true
init_log_file 2>/dev/null || true

# shellcheck source=pulse-repo-meta.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/pulse-repo-meta.sh" 2>/dev/null || true

# t2976 / GH#21699: canonical-guard + audit logger for ephemeral worktree
# cleanup. Defence-in-depth: even though _dps_rebase_in_ephemeral creates its
# worktree under /tmp via mktemp (never a canonical path), an
# is_registered_canonical check before `git worktree remove --force` prevents
# any future refactor that swaps the path source from accidentally pointing at
# a registered canonical repo. Provide fallback stubs so set -u doesn't trip
# when the helpers are absent.
_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
command -v log_worktree_removal_event >/dev/null 2>&1 || log_worktree_removal_event() { :; }
command -v is_registered_canonical >/dev/null 2>&1 || is_registered_canonical() { return 1; }
if [[ -f "${SCRIPT_DIR}/audit-worktree-removal-helper.sh" ]]; then
	# shellcheck source=audit-worktree-removal-helper.sh
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh" 2>/dev/null || true
fi
if [[ -f "${SCRIPT_DIR}/canonical-guard-helper.sh" ]]; then
	# shellcheck source=canonical-guard-helper.sh
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/canonical-guard-helper.sh" 2>/dev/null || true
fi

if [[ -f "${SCRIPT_DIR}/pr-supersession-helper.sh" ]]; then
	# shellcheck source=pr-supersession-helper.sh
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/pr-supersession-helper.sh" 2>/dev/null || true
fi
# Caller ID constant (avoids repeated literals in audit log lines).
_WTAR_DPS_CALLER="pulse-dirty-pr-sweep.sh"

# -----------------------------------------------------------------------------
# Configuration constants
# -----------------------------------------------------------------------------

# How often the sweep runs (seconds) — governs the outer cycle gate. Per-PR
# action cooldown is a separate, identical default (30 min). Override via env.
DIRTY_PR_SWEEP_INTERVAL="${DIRTY_PR_SWEEP_INTERVAL:-1800}"       # 30 min
DIRTY_PR_SWEEP_ACTION_COOLDOWN="${DIRTY_PR_SWEEP_ACTION_COOLDOWN:-1800}" # 30 min per-PR

# Eligibility windows (seconds).
DIRTY_PR_REBASE_MAX_AGE="${DIRTY_PR_REBASE_MAX_AGE:-172800}"                               # 48h — code conflicts
DIRTY_PR_REBASE_PLANNING_MAX_AGE="${DIRTY_PR_REBASE_PLANNING_MAX_AGE:-604800}"             # 7d  — planning-only conflicts
DIRTY_PR_CLOSE_MIN_AGE="${DIRTY_PR_CLOSE_MIN_AGE:-604800}"                                 # 7d
DIRTY_PR_CLOSE_MIN_AGE_INTERACTIVE="${DIRTY_PR_CLOSE_MIN_AGE_INTERACTIVE:-1209600}"       # 14d for origin:interactive + referenced (t2711 Q2)
DIRTY_PR_CLOSE_IDLE_HUMAN="${DIRTY_PR_CLOSE_IDLE_HUMAN:-259200}"                           # 3d since last human push
DIRTY_PR_INTERACTIVE_STALE_AGE="${DIRTY_PR_INTERACTIVE_STALE_AGE:-14400}"                 # 4h — interactive session staleness floor (mirrors t2189)

# Max PRs processed per sweep per repo (safety rail — a single run should
# never thrash hundreds of PRs).
DIRTY_PR_SWEEP_BATCH_LIMIT="${DIRTY_PR_SWEEP_BATCH_LIMIT:-30}"

# Interval/state files — mirror the `FAST_FAIL_STATE_FILE` / `DEP_GRAPH_*`
# pattern used elsewhere in pulse-wrapper.sh.
DIRTY_PR_SWEEP_LAST_RUN="${DIRTY_PR_SWEEP_LAST_RUN:-${HOME}/.aidevops/logs/dirty-pr-sweep-last-run}"
DIRTY_PR_SWEEP_STATE_FILE="${DIRTY_PR_SWEEP_STATE_FILE:-${HOME}/.aidevops/.agent-workspace/supervisor/dirty-pr-sweep-state.json}"

# The audit-log-helper's event-type allowlist is closed. `operation.verify`
# is the closest fit for "pulse took a verified deterministic action".
# Detail keys disambiguate the op (rebase|close|notify|skip).
readonly _DIRTY_PR_AUDIT_EVENT="operation.verify"

# Canonical action names — used as case labels, state-file keys, and audit
# detail values. Centralised so the literal strings aren't sprinkled around
# (pre-commit "repeated string literals" ratchet).
readonly _DIRTY_ACTION_REBASE="rebase"
readonly _DIRTY_ACTION_CLOSE="close"
readonly _DIRTY_ACTION_CONFLICT="conflict"
readonly _DIRTY_ACTION_NOTIFY="notify"
readonly _DIRTY_ACTION_SKIP="skip"

readonly _DIRTY_LABEL_ORIGIN_WORKER="origin:worker"
readonly _DIRTY_LABEL_ORIGIN_WORKER_TAKEOVER="origin:worker-takeover"

# Comment markers for idempotency when scanning PR comment history.
readonly _DIRTY_PR_NOTIFY_MARKER="<!-- pulse-dirty-pr-escalate -->"  # string preserved for comment-history dedup continuity
readonly _DIRTY_PR_REBASE_MARKER="<!-- pulse-dirty-pr-rebase -->"
readonly _DIRTY_PR_CLOSE_MARKER="<!-- pulse-dirty-pr-close -->"

# Dry-run flag — CLI `--dry-run` or env `DRY_RUN=1`. Module-local copy so we
# don't pollute the caller's environment when sourced.
_DIRTY_PR_SWEEP_DRY_RUN="${DRY_RUN:-0}"

# -----------------------------------------------------------------------------
# Small utility helpers
# -----------------------------------------------------------------------------

_dps_log() {
	# Unified log line — writes to $LOGFILE when set (pulse context), otherwise
	# stderr (standalone). Never throws.
	local log_dir=""
	if [[ -n "${LOGFILE:-}" ]]; then
		log_dir=$(dirname "$LOGFILE" 2>/dev/null) || log_dir=""
	fi
	if [[ -n "${LOGFILE:-}" && -n "$log_dir" && -w "$log_dir" ]]; then
		printf '[pulse-dirty-pr-sweep] %s\n' "$*" >>"$LOGFILE" 2>/dev/null || true
	else
		printf '[pulse-dirty-pr-sweep] %s\n' "$*" >&2
	fi
	return 0
}

_dps_is_dry_run() {
	[[ "${_DIRTY_PR_SWEEP_DRY_RUN:-0}" == "1" ]]
}

_dps_now_epoch() {
	date +%s
}

# ---------------------------------------------------------------------------
# _dps_get_default_branch
#
# Detect the default remote branch for a repo by reading the remote HEAD
# symbolic ref. Avoids hardcoding "main" and prevents
# `fatal: ambiguous argument 'origin/main'` errors on repos that use a
# different default branch (master, develop, etc.) or that have not had
# `git remote set-head origin --auto` run.
#
# Arguments: $1 - repo_path (absolute path to a git checkout)
# Outputs: branch name (e.g. "main", "master") on stdout
# Returns: 0 on success, 1 if the remote HEAD symbolic ref is not set
#          (caller should skip rather than assume a branch name)
# ---------------------------------------------------------------------------
_dps_get_default_branch() {
	local repo_path="$1"
	local default_ref
	default_ref=$(git -C "$repo_path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
	[[ -n "$default_ref" ]] || return 1
	printf '%s\n' "${default_ref#origin/}"
	return 0
}

# Convert ISO8601 timestamp → epoch seconds. Returns "0" on parse error.
# Bash 3.2 compatible (macOS default).
_dps_iso_to_epoch() {
	local iso="$1"
	[[ -z "$iso" ]] && { printf '0'; return 0; }
	local epoch
	if date -u -d "$iso" +%s >/dev/null 2>&1; then
		# GNU date (Linux)
		epoch=$(date -u -d "$iso" +%s 2>/dev/null) || epoch=0
	else
		# BSD date (macOS) — normalise the Z suffix and any fractional seconds.
		local clean="${iso%Z}"
		clean="${clean%%.*}"
		epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$clean" +%s 2>/dev/null) || epoch=0
	fi
	[[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
	printf '%s' "$epoch"
	return 0
}

_dps_supersession_reason() {
	local pr_obj="$1"
	local repo_slug="$2"
	local repo_path="$3"

	if ! declare -F _psh_classify_json >/dev/null 2>&1; then
		return 1
	fi

	local result classification rationale
	result=$(_psh_classify_json "$pr_obj" "$repo_path" 1 2>/dev/null) || return 1
	classification=$(printf '%s' "$result" | jq -r '.classification // empty' 2>/dev/null) || classification=""
	rationale=$(printf '%s' "$result" | jq -r '.rationale // empty' 2>/dev/null) || rationale=""
	case "$classification" in
		fully_superseded|stale_baseline_only)
			printf 'supersession-check:%s:%s' "$classification" "$rationale"
			return 0
			;;
		*)
			_dps_log "PR in ${repo_slug}: supersession pre-check=${classification:-unknown}"
			return 1
			;;
	esac
}

# -----------------------------------------------------------------------------
# State file helpers (idempotency)
# -----------------------------------------------------------------------------
#
# State file is a JSON object keyed by "slug#pr":
#   {
#     "marcusquinn/aidevops#19696": {
#       "last_action": "rebase",
#       "last_action_epoch": 1745000000
#     }
#   }

_dps_state_init() {
	if [[ ! -f "$DIRTY_PR_SWEEP_STATE_FILE" ]]; then
		mkdir -p "$(dirname "$DIRTY_PR_SWEEP_STATE_FILE")" 2>/dev/null || true
		printf '{}' >"$DIRTY_PR_SWEEP_STATE_FILE" 2>/dev/null || true
	fi
	return 0
}

# Return epoch of last action for key, or "0" if none.
_dps_state_last_action_epoch() {
	local key="$1"
	_dps_state_init
	local epoch
	epoch=$(jq -r --arg k "$key" '.[$k].last_action_epoch // 0' "$DIRTY_PR_SWEEP_STATE_FILE" 2>/dev/null)
	[[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
	printf '%s' "$epoch"
	return 0
}

_dps_state_record_action() {
	local key="$1"
	local action="$2"
	local now
	now=$(_dps_now_epoch)

	_dps_state_init
	local tmp
	tmp=$(mktemp) || return 1
	if jq --arg k "$key" --arg a "$action" --arg e "$now" \
		'.[$k] = {"last_action": $a, "last_action_epoch": ($e | tonumber)}' \
		"$DIRTY_PR_SWEEP_STATE_FILE" >"$tmp" 2>/dev/null; then
		mv "$tmp" "$DIRTY_PR_SWEEP_STATE_FILE" 2>/dev/null || rm -f "$tmp"
	else
		rm -f "$tmp"
		return 1
	fi
	return 0
}

# Return 0 if the PR was actioned recently enough that we should skip it.
_dps_recently_actioned() {
	local key="$1"
	local now last elapsed
	now=$(_dps_now_epoch)
	last=$(_dps_state_last_action_epoch "$key")
	[[ "$last" -eq 0 ]] && return 1
	elapsed=$((now - last))
	[[ "$elapsed" -lt "$DIRTY_PR_SWEEP_ACTION_COOLDOWN" ]]
}

# -----------------------------------------------------------------------------
# Interval check (outer cycle gate)
# -----------------------------------------------------------------------------

# Return 0 if sweep is due, 1 if interval not elapsed.
_dirty_pr_sweep_check_interval() {
	local now_epoch
	now_epoch=$(_dps_now_epoch)
	if [[ ! -f "$DIRTY_PR_SWEEP_LAST_RUN" ]]; then
		return 0
	fi
	local last
	last=$(cat "$DIRTY_PR_SWEEP_LAST_RUN" 2>/dev/null || echo "0")
	[[ "$last" =~ ^[0-9]+$ ]] || last=0
	local elapsed=$((now_epoch - last))
	if [[ "$elapsed" -lt "$DIRTY_PR_SWEEP_INTERVAL" ]]; then
		local remaining=$((DIRTY_PR_SWEEP_INTERVAL - elapsed))
		_dps_log "interval-gate: not due (remaining $((remaining / 60))m)"
		return 1
	fi
	return 0
}

_dirty_pr_sweep_mark_run() {
	mkdir -p "$(dirname "$DIRTY_PR_SWEEP_LAST_RUN")" 2>/dev/null || true
	_dps_now_epoch >"$DIRTY_PR_SWEEP_LAST_RUN" 2>/dev/null || true
	return 0
}

# -----------------------------------------------------------------------------
# Conflicting-files discovery
# -----------------------------------------------------------------------------
#
# Given a PR branch and origin/main, return the list of files that would
# conflict on rebase. Uses `git merge-tree --write-tree` when available
# (Git 2.38+), with a fallback to `git merge-tree` (three-arg form) on older
# Git. Returns a newline-separated list on stdout; empty stdout means "no
# conflicting files" (or "tool unavailable" — the caller must treat empty
# as "cannot determine" and NOT as "safe to rebase").
#
# Args:
#   $1 - repo_path (absolute path to a git checkout)
#   $2 - branch (PR head branch name, e.g. "feature/foo")
#   $3 - base_ref (usually "origin/main")
#
# Exit codes:
#   0 - command ran (stdout may be empty = no conflicts)
#   1 - merge-tree error; caller must NOT assume safety
_dps_conflicting_files() {
	local repo_path="$1"
	local branch="$2"
	local base_ref="$3"

	[[ -d "$repo_path/.git" || -f "$repo_path/.git" ]] || return 1

	# Modern form (Git 2.38+): outputs conflict sections on stdout.
	# Exit 0 = clean, 1 = conflicts. We need filenames either way.
	local out exit_code=0
	out=$(git -C "$repo_path" merge-tree --write-tree --no-messages \
		--name-only "$base_ref" "$branch" 2>/dev/null) || exit_code=$?
	if [[ "$exit_code" -eq 0 ]]; then
		# Clean merge — no conflicting files.
		return 0
	fi
	if [[ "$exit_code" -eq 1 && -n "$out" ]]; then
		# First line is the tree OID, subsequent lines are filenames.
		printf '%s\n' "$out" | tail -n +2
		return 0
	fi

	# Fallback: older Git doesn't have --name-only. Fall through to best-effort
	# without fabricating success.
	return 1
}

# -----------------------------------------------------------------------------
# Classification helpers
# -----------------------------------------------------------------------------

# Given a pr_json object, output a newline-separated label list, lowercased.
_dps_pr_labels() {
	local pr_json="$1"
	printf '%s' "$pr_json" | jq -r '[.labels[].name] | sort | unique | .[]' 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# Check if a label list (newline-separated, lowercased) contains a target.
_dps_labels_has() {
	local labels="$1"
	local target="$2"
	printf '%s' "$labels" | grep -qx "$target"
}

# Check whether a PR body contains a recognised issue reference (t2708).
#
# Recognises three reference patterns, matching the conventions documented in
# `AGENTS.md` ("Parent-task PR keyword rule") and the closing-keyword
# regex used by `_extract_linked_issue` in pulse-merge.sh:
#
#   - Closing keywords: `(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#NNN` (case-
#     insensitive). These auto-close the linked issue when the PR merges.
#   - `For #NNN` (case-insensitive) — canonical planning-PR non-closing marker.
#   - `Ref #NNN` (case-insensitive) — alternate non-closing reference.
#
# Returns 0 if any pattern matches, 1 otherwise. Accepts the body as argument.
# Empty body returns 1.
_dps_pr_body_has_issue_reference() {
	local body="$1"
	[[ -n "$body" ]] || return 1
	# Closing keywords — same regex pulse-merge.sh:_extract_linked_issue uses.
	if printf '%s' "$body" | grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#[0-9]+' >/dev/null 2>&1; then
		return 0
	fi
	# Non-closing references: "For #NNN" or "Ref #NNN" (word boundary on the
	# keyword so "before #NNN" and "reference #NNN" don't false-match).
	if printf '%s' "$body" | grep -ioE '(^|[^[:alnum:]])(for|ref)[[:space:]]+#[0-9]+' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

_dps_extract_linked_issue_from_body() {
	local body="$1"
	local match=""
	[[ -n "$body" ]] || return 1
	match=$(printf '%s' "$body" | grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?|for|ref)[[:space:]]+#[0-9]+' | head -n 1) || match=""
	[[ -n "$match" ]] || return 1
	printf '%s' "$match" | grep -oE '[0-9]+' | head -n 1
	return 0
}

_dps_issue_labels() {
	local issue_number="$1"
	local repo_slug="$2"
	local labels=""
	labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | .[]' 2>/dev/null \
		| tr '[:upper:]' '[:lower:]') || return 1
	printf '%s\n' "$labels"
	return 0
}

_dps_linked_issue_is_worker_backed() {
	local body="$1"
	local repo_slug="$2"
	local linked_issue="" labels=""

	# Unit tests can disable the network-backed provenance check; production
	# defaults to enabled so worker-origin issues are repaired without manual
	# conflict babysitting even when the PR was accidentally labelled interactive.
	[[ "${AIDEVOPS_DIRTY_PR_WORKER_BACKED_CHECK:-1}" == "1" ]] || return 1

	linked_issue=$(_dps_extract_linked_issue_from_body "$body") || linked_issue=""
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 1
	labels=$(_dps_issue_labels "$linked_issue" "$repo_slug") || labels=""
	[[ -n "$labels" ]] || return 1

	if _dps_labels_has "$labels" "$_DIRTY_LABEL_ORIGIN_WORKER" || _dps_labels_has "$labels" "$_DIRTY_LABEL_ORIGIN_WORKER_TAKEOVER"; then
		printf '%s' "$linked_issue"
		return 0
	fi
	if _dps_labels_has "$labels" "auto-dispatch" && {
		_dps_labels_has "$labels" "function-complexity-debt" || \
			_dps_labels_has "$labels" "file-size-debt" || \
			_dps_labels_has "$labels" "source:conflict-feedback" || \
			_dps_labels_has "$labels" "source:ci-feedback" || \
			_dps_labels_has "$labels" "source:review-feedback"
	}; then
		printf '%s' "$linked_issue"
		return 0
	fi
	return 1
}

_dps_effective_worker_origin() {
	local labels="$1"
	local has_interactive="$2"
	local body="$3"
	local repo_slug="$4"
	local pr_number="$5"
	local linked_worker_issue=""

	if _dps_labels_has "$labels" "$_DIRTY_LABEL_ORIGIN_WORKER" || _dps_labels_has "$labels" "$_DIRTY_LABEL_ORIGIN_WORKER_TAKEOVER"; then
		return 0
	fi
	[[ "$has_interactive" -eq 1 ]] || return 1
	linked_worker_issue=$(_dps_linked_issue_is_worker_backed "$body" "$repo_slug") || linked_worker_issue=""
	[[ -n "$linked_worker_issue" ]] || return 1
	_dps_log "PR #${pr_number} ${repo_slug}: origin:interactive but linked issue #${linked_worker_issue} is worker-backed — treating as worker PR"
	return 0
}

# Determine whether the interactive session that opened a PR is likely
# abandoned, using only server-visible signals (cross-runner safe — local
# claim stamps at ~/.aidevops/.agent-workspace/interactive-claims/ are not
# readable on peer runners).
#
# Returns 0 (stale) when BOTH of these conditions hold:
#   - No commits on the head ref in the last DIRTY_PR_INTERACTIVE_STALE_AGE seconds
#   - No comments from the PR author in that window
#
# Returns 1 (live/unknown) otherwise. Fail-safe to "live" on any API error
# so we never auto-takeover on transient network blips.
#
# NOTE: $author is read via bash dynamic scoping from the calling function
# (_dirty_pr_classify). It is intentionally not a positional parameter.
#
# Args: $1=pr_number $2=repo_slug $3=head_ref $4=repo_path (unused but
#       part of the public signature for future local-stamp reads)
_dps_interactive_stamp_is_stale() {
	local pr_number="$1" repo_slug="$2" head_ref="$3"
	# $4 (repo_path) reserved for future local-stamp integration
	local threshold_age="${DIRTY_PR_INTERACTIVE_STALE_AGE:-14400}"  # 4h default
	local now="" last_commit_age="" last_comment_age=""

	now=$(_dps_now_epoch)

	# Last commit on the head ref (server-visible, cross-runner safe).
	local last_commit_iso
	last_commit_iso=$(gh api "repos/${repo_slug}/commits/${head_ref}" \
		--jq '.commit.committer.date' 2>/dev/null) || return 1
	[[ -n "$last_commit_iso" ]] || return 1
	local last_commit_epoch
	last_commit_epoch=$(_dps_iso_to_epoch "$last_commit_iso")
	[[ "$last_commit_epoch" -gt 0 ]] || return 1
	last_commit_age=$((now - last_commit_epoch))

	# Last comment from the PR author on the PR (server-visible, cross-runner safe).
	# $author is visible via bash dynamic scoping from _dirty_pr_classify.
	local last_author_comment_iso
	last_author_comment_iso=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments" \
		--jq "[.[] | select(.user.login == \"${author:-}\")] | last | .created_at // empty" \
		2>/dev/null) || last_author_comment_iso=""
	if [[ -n "$last_author_comment_iso" ]]; then
		local last_comment_epoch
		last_comment_epoch=$(_dps_iso_to_epoch "$last_author_comment_iso")
		if [[ "$last_comment_epoch" -gt 0 ]]; then
			last_comment_age=$((now - last_comment_epoch))
		else
			last_comment_age="$last_commit_age"
		fi
	else
		last_comment_age="$last_commit_age"
	fi

	# Stale only when BOTH ages exceed the threshold.
	if [[ "$last_commit_age" -gt "$threshold_age" && "$last_comment_age" -gt "$threshold_age" ]]; then
		return 0  # stale — safe to attempt cross-runner rebase takeover
	fi
	return 1      # live (or indeterminate) — leave as notify-only
}

# Decide whether a rebase path is structurally eligible (author-ok +
# not parent-task + within age window for the conflict scope).
# Output on stdout: "rebase|planning-only-conflict" if yes,
# empty string if no. The caller uses a non-empty return to short-circuit.
# Planning files (TODO.md, todo/**, README.md) match the headless planning
# allowlist from pre-edit-check.sh:is_main_allowlisted_path.
#
# Two-tier age gate:
#   planning-only conflicts (TODO.md, todo/**, README.md) → DIRTY_PR_REBASE_PLANNING_MAX_AGE (7d)
#   non-planning conflicts                                 → DIRTY_PR_REBASE_MAX_AGE (48h) guard
#
# Args: $1=age $2=rebase_author_ok $3=has_parent_task $4=repo_path $5=head_ref
_dps_consider_rebase() {
	local age="$1" rebase_author_ok="$2" has_parent_task="$3"
	local repo_path="$4" head_ref="$5"

	# Author and label gates are age-independent — check them first.
	[[ "$rebase_author_ok" -eq 1 ]] || return 0
	[[ "$has_parent_task" -eq 0 ]] || return 0
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 0

	# Detect the default branch dynamically to avoid `fatal: ambiguous argument
	# 'origin/main'` on repos that use master, develop, or have no fetched HEAD.
	local default_branch base_ref
	if ! default_branch=$(_dps_get_default_branch "$repo_path"); then
		_dps_log "Consider-rebase: skipping ${repo_path} — no origin/HEAD set (run 'git remote set-head origin --auto')"
		return 0
	fi
	base_ref="origin/${default_branch}"

	local conflicts non_planning
	conflicts=$(_dps_conflicting_files "$repo_path" "$head_ref" "$base_ref" 2>/dev/null) || conflicts=""
	[[ -n "$conflicts" ]] || return 0

	# Strip planning-only files: TODO.md, todo/**, README.md.
	non_planning=$(printf '%s\n' "$conflicts" \
		| grep -vx 'TODO.md' \
		| grep -v '^todo/' \
		| grep -vx 'README.md' \
		| grep -v '^\s*$' || true)

	if [[ -z "$non_planning" ]]; then
		# Planning-only conflict — use extended age window.
		[[ "$age" -lt "$DIRTY_PR_REBASE_PLANNING_MAX_AGE" ]] || return 0
		printf '%s|planning-only-conflict' "$_DIRTY_ACTION_REBASE"
	fi
	# Non-planning conflicts: currently no rebase path.
	# Age guard kept here as a future extension point when mixed-conflict
	# rebase is added: [[ "$age" -lt "$DIRTY_PR_REBASE_MAX_AGE" ]] || return 0
	return 0
}

# Decide whether a close path is eligible based on age + idle window.
# Output on stdout: "close|stale-and-idle" if yes, empty if no.
#
# Args: $1=age $2=now $3=updated_epoch $4=created_epoch
_dps_consider_close() {
	local age="$1" now="$2" updated_epoch="$3" created_epoch="$4"

	[[ "$age" -gt "$DIRTY_PR_CLOSE_MIN_AGE" ]] || return 0
	[[ "$updated_epoch" -gt 0 ]] || updated_epoch="$created_epoch"
	local idle=$((now - updated_epoch))
	if [[ "$idle" -gt "$DIRTY_PR_CLOSE_IDLE_HUMAN" ]]; then
		printf '%s|stale-and-idle' "$_DIRTY_ACTION_CLOSE"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Classification
# -----------------------------------------------------------------------------

_dps_closed_by_other_merged_pr_reason() {
	local pr_json="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local labels="$4"

	_dps_labels_has "$labels" "$_DIRTY_LABEL_ORIGIN_WORKER" || _dps_labels_has "$labels" "$_DIRTY_LABEL_ORIGIN_WORKER_TAKEOVER" || return 1
	_dps_labels_has "$labels" "do-not-close" && return 1
	_dps_labels_has "$labels" "hold-for-review" && return 1

	local linked_issue="" superseding_pr=""
	linked_issue=$(_psh_extract_closing_issue_from_pr_json "$pr_json" 2>/dev/null) || linked_issue=""
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 1
	superseding_pr=$(_psh_find_merged_closer_for_closed_issue "$repo_slug" "$linked_issue" "$pr_number" 2>/dev/null) || superseding_pr=""
	[[ "$superseding_pr" =~ ^[0-9]+$ ]] || return 1

	printf 'linked-issue-%s-closed-by-pr-%s' "$linked_issue" "$superseding_pr"
	return 0
}

#
# Given a PR JSON object (from `gh pr list`), classify the action:
#   rebase | conflict | close | notify | skip
#
# The JSON must include: number, mergeStateStatus, createdAt, updatedAt,
# author.login, labels[].name, headRefName, baseRefName.
#
# Args:
#   $1 - pr_json (single object, not array)
#   $2 - repo_slug
#   $3 - repo_path (optional; needed for accurate conflict scope)
#   $4 - self_login (the runner's GitHub login — maintainers)
#
# Output (stdout): one line of the form "ACTION|REASON"
#   ACTION in {rebase, conflict, close, notify, skip}
#   REASON is a short human-readable phrase.
_dirty_pr_classify() {
	local pr_json="$1"
	local _repo_slug="$2" # unused but part of the public signature
	local repo_path="$3"
	local self_login="$4"

	local pr_number mss created updated author head_ref body
	pr_number=$(printf '%s' "$pr_json" | jq -r '.number // empty')
	mss=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // empty')
	created=$(printf '%s' "$pr_json" | jq -r '.createdAt // empty')
	updated=$(printf '%s' "$pr_json" | jq -r '.updatedAt // empty')
	author=$(printf '%s' "$pr_json" | jq -r '.author.login // empty')
	head_ref=$(printf '%s' "$pr_json" | jq -r '.headRefName // empty')
	body=$(printf '%s' "$pr_json" | jq -r '.body // empty')

	if [[ -z "$pr_number" ]]; then
		printf '%s|invalid-pr-json' "$_DIRTY_ACTION_SKIP"
		return 0
	fi
	if [[ "$mss" != "DIRTY" ]]; then
		printf '%s|not-dirty' "$_DIRTY_ACTION_SKIP"
		return 0
	fi

	local labels now created_epoch updated_epoch age
	labels=$(_dps_pr_labels "$pr_json")
	now=$(_dps_now_epoch)
	created_epoch=$(_dps_iso_to_epoch "$created")
	updated_epoch=$(_dps_iso_to_epoch "$updated")
	age=$((now - created_epoch))

	local has_do_not_close=0 has_parent_task=0 has_interactive=0 has_worker_origin=0 has_hold_for_review=0
	_dps_labels_has "$labels" "do-not-close" && has_do_not_close=1
	_dps_labels_has "$labels" "parent-task" && has_parent_task=1
	_dps_labels_has "$labels" "hold-for-review" && has_hold_for_review=1
	_dps_labels_has "$labels" "origin:interactive" && has_interactive=1
	_dps_effective_worker_origin "$labels" "$has_interactive" "$body" "$_repo_slug" "$pr_number" && has_worker_origin=1

	local closed_issue_reason
	if closed_issue_reason=$(_dps_closed_by_other_merged_pr_reason "$pr_json" "$_repo_slug" "$pr_number" "$labels"); then
		printf '%s|%s' "$_DIRTY_ACTION_CLOSE" "$closed_issue_reason"
		return 0
	fi

	local rebase_author_ok=0
	if [[ -n "$self_login" && "$author" == "$self_login" ]]; then
		rebase_author_ok=1
	elif [[ "$has_worker_origin" -eq 1 ]]; then
		rebase_author_ok=1
	elif [[ "$has_interactive" -eq 1 ]] && _dps_interactive_stamp_is_stale "$pr_number" "$_repo_slug" "$head_ref" "$repo_path"; then
		rebase_author_ok=1
		_dps_log "PR #${pr_number} ${_repo_slug}: origin:interactive but stale — allowing cross-runner rebase takeover"
	fi

	# Happy path: try rebase first.
	local rebase_decision
	rebase_decision=$(_dps_consider_rebase "$age" "$rebase_author_ok" "$has_parent_task" "$repo_path" "$head_ref")
	if [[ -n "$rebase_decision" ]]; then
		printf '%s' "$rebase_decision"
		return 0
	fi

	# Label-based notify takes precedence over close.
	if [[ "$has_do_not_close" -eq 1 ]]; then
		printf '%s|do-not-close-label' "$_DIRTY_ACTION_NOTIFY"
		return 0
	fi
	if [[ "$has_parent_task" -eq 1 ]]; then
		printf '%s|parent-task-label' "$_DIRTY_ACTION_NOTIFY"
		return 0
	fi
	if [[ "$has_hold_for_review" -eq 1 ]]; then
		printf '%s|hold-for-review-label' "$_DIRTY_ACTION_NOTIFY"
		return 0
	fi
	if [[ "$has_worker_origin" -eq 1 && "$age" -le "$DIRTY_PR_CLOSE_MIN_AGE" ]]; then
		printf '%s|worker-backed-semantic-conflict' "$_DIRTY_ACTION_CONFLICT"
		return 0
	fi
	if [[ "$has_interactive" -eq 1 ]]; then
		if ! _dps_pr_body_has_issue_reference "$body"; then
			printf '%s|origin-interactive-orphan' "$_DIRTY_ACTION_NOTIFY"
			return 0
		fi
		if [[ "$age" -le "$DIRTY_PR_CLOSE_MIN_AGE_INTERACTIVE" ]]; then
			printf '%s|origin-interactive-referenced-within-extended-window' "$_DIRTY_ACTION_NOTIFY"
			return 0
		fi
	fi

	local close_decision
	close_decision=$(_dps_consider_close "$age" "$now" "$updated_epoch" "$created_epoch")
	if [[ -n "$close_decision" ]]; then
		printf '%s' "$close_decision"
		return 0
	fi

	printf '%s|dirty-not-auto-resolvable' "$_DIRTY_ACTION_NOTIFY"
	return 0
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------
#
# Each action returns 0 on success (or dry-run), 1 on failure. Actions post
# PR comments with idempotency markers so repeated invocations don't spam.

#######################################
# Read PR conversation comment bodies through the issue-comments REST endpoint.
# Native `gh pr view --json comments` is GraphQL-only and cannot report its
# operation-owned cost to exact Pulse instrumentation.
#
# Arguments:
#   $1 - pr_number
#   $2 - repo_slug
#
# Output: newline-delimited comment bodies.
#######################################
_dps_pr_comment_bodies_rest() {
	local pr_number="$1"
	local repo_slug="$2"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 1
	AIDEVOPS_GH_ROUTE_DECISION="pulse-dirty-pr-comments-rest" \
		gh api --paginate \
			"repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" \
			--jq '.[].body'
	return $?
}

# Post a comment if the marker doesn't already exist on the PR.
# Idempotent by design — safe to call every cycle.
_dps_post_comment_if_new() {
	local pr_number="$1"
	local repo_slug="$2"
	local marker="$3"
	local body="$4"

	# Check existing comments for marker.
	local existing
	existing=$(_dps_pr_comment_bodies_rest "$pr_number" "$repo_slug" 2>/dev/null) || existing=""
	if printf '%s' "$existing" | grep -qF "$marker"; then
		_dps_log "PR #$pr_number ($repo_slug): comment marker '$marker' already present — skipping"
		return 0
	fi

	# Prepend marker to body so subsequent calls detect it.
	local full_body="${marker}
${body}"

	if _dps_is_dry_run; then
		_dps_log "DRY-RUN: would post comment on PR #$pr_number ($repo_slug): marker=$marker"
		return 0
	fi

	if gh_pr_comment "$pr_number" --repo "$repo_slug" --body "$full_body" >/dev/null 2>&1; then
		return 0
	fi
	_dps_log "PR #$pr_number ($repo_slug): failed to post comment"
	return 1
}

# Perform the actual rebase in an ephemeral worktree.
# Creates a throwaway worktree, fetches refs, rebases with union strategy,
# force-pushes, and cleans up. Returns 0 on success, 1 on any failure.
_dps_rebase_in_ephemeral() {
	local pr_number="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local head_ref="$4"
	local default_branch="$5"

	# Ephemeral worktree for this rebase attempt. We use a throwaway directory
	# under /tmp so we never interfere with real worktrees or the user's
	# active branches. Cleanup is always attempted.
	local ephemeral
	ephemeral=$(mktemp -d -t "dirty-pr-sweep.XXXXXX") || {
		_dps_log "PR #$pr_number ($repo_slug): mktemp failed — skipping rebase"
		return 1
	}
	local ephemeral_branch_ts
	ephemeral_branch_ts=$(date +%s)
	local ephemeral_branch="dirty-pr-sweep/pr-${pr_number}-${ephemeral_branch_ts}"

	# Refresh origin/<default_branch> and origin/<head_ref> before anything else.
	git -C "$repo_path" fetch --quiet origin "${default_branch}:refs/remotes/origin/${default_branch}" || {
		_dps_log "PR #$pr_number ($repo_slug): fetch of origin/${default_branch} failed — skipping rebase"
		rm -rf "$ephemeral" || true
		return 1
	}
	git -C "$repo_path" fetch --quiet origin "${head_ref}:refs/remotes/origin/${head_ref}" 2>/dev/null || {
		_dps_log "PR #$pr_number ($repo_slug): fetch of origin/${head_ref} failed — skipping rebase"
		rm -rf "$ephemeral" 2>/dev/null || true
		return 1
	}

	if ! git -C "$repo_path" worktree add -b "$ephemeral_branch" "$ephemeral" "origin/${head_ref}" >/dev/null 2>&1; then
		_dps_log "PR #$pr_number ($repo_slug): worktree add failed — skipping rebase"
		rm -rf "$ephemeral" 2>/dev/null || true
		return 1
	fi

	local rebase_ok=1
	if git -C "$ephemeral" rebase -X union "origin/${default_branch}" >/dev/null 2>&1; then
		rebase_ok=0
	else
		git -C "$ephemeral" rebase --abort >/dev/null 2>&1 || true
		_dps_log "PR #$pr_number ($repo_slug): rebase -X union failed — conflicts outside TODO.md"
	fi

	if [[ "$rebase_ok" -eq 0 ]]; then
		# Force-push with lease so we never clobber a human-pushed commit.
		if ! git -C "$ephemeral" push --force-with-lease=refs/heads/"$head_ref":origin/"$head_ref" \
			origin "HEAD:refs/heads/${head_ref}" >/dev/null 2>&1; then
			_dps_log "PR #$pr_number ($repo_slug): force-push failed — possibly clobber protected"
			rebase_ok=1
		fi
	fi

	# Cleanup ephemeral worktree regardless of outcome.
	# t2976 / GH#21699: canonical guard before destructive removal. The
	# ephemeral path is created via mktemp under /tmp and can never legitimately
	# match a registered canonical repo — so a hit here means a refactor or
	# environment override has redirected the path. Skip + audit instead of
	# destroying, and log the skip so the unexpected state is visible.
	if is_registered_canonical "$ephemeral"; then
		_dps_log "PR #$pr_number ($repo_slug): refusing to remove canonical path $ephemeral — registry hit"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_DPS_CALLER" "$ephemeral" "canonical-skip" "skipped"
	else
		git -C "$repo_path" worktree remove --force "$ephemeral" >/dev/null 2>&1 || true
		git -C "$repo_path" branch -D "$ephemeral_branch" >/dev/null 2>&1 || true
		rm -rf "$ephemeral" 2>/dev/null || true
		log_worktree_removal_event "$_WTAR_FIXTURE_REMOVED" "$_WTAR_DPS_CALLER" "$ephemeral" "fixture" "fixture"
	fi

	if [[ "$rebase_ok" -ne 0 ]]; then
		return 1
	fi
	return 0
}

# Post a documentation comment after a successful auto-rebase and record
# the action/audit trail entries.
_dps_rebase_post_comment() {
	local pr_number="$1"
	local repo_slug="$2"
	local head_ref="$3"
	local default_branch="$4"
	local key="$5"

	local comment_body
	comment_body="**Auto-rebase**: this PR was DIRTY with only \`TODO.md\` conflicting, so the pulse rebased it onto \`origin/${default_branch}\` with the \`union\` merge strategy and force-pushed.

- If CI now passes, the merge pass will take it from here.
- If this rebase was wrong, revert with \`git push --force-with-lease origin ${head_ref}\` from your local copy.
- To opt a PR out of this sweep in future, add the \`do-not-close\` label (also disables auto-close).

_Triggered by \`pulse-dirty-pr-sweep.sh\` (t2350 / GH#19948). Action cooldown: ${DIRTY_PR_SWEEP_ACTION_COOLDOWN}s._"

	_dps_post_comment_if_new "$pr_number" "$repo_slug" "$_DIRTY_PR_REBASE_MARKER" "$comment_body" || true
	_dps_state_record_action "$key" "$_DIRTY_ACTION_REBASE"
	_dps_record_audit "$_DIRTY_ACTION_REBASE" "$repo_slug" "$pr_number" "ok"
	_dps_log "PR #$pr_number ($repo_slug): rebased + pushed"
	return 0
}

# Rebase action: attempt `git rebase origin/<default_branch> -X union` in an
# ephemeral worktree and force-push. If anything fails, abort cleanly and
# return 1 (the PR remains DIRTY for re-classification on the next cycle).
# Delegates the ephemeral-worktree work to _dps_rebase_in_ephemeral() and
# success-comment posting to _dps_rebase_post_comment().
_dirty_pr_action_rebase() {
	local pr_number="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local head_ref="$4"

	local key="${repo_slug}#${pr_number}"

	if _dps_recently_actioned "$key"; then
		_dps_log "PR #$pr_number ($repo_slug): rebase skipped — cooldown active"
		return 0
	fi

	if _dps_is_dry_run; then
		_dps_log "DRY-RUN: would rebase PR #$pr_number ($repo_slug) branch=$head_ref"
		_dps_record_audit "$_DIRTY_ACTION_REBASE" "$repo_slug" "$pr_number" "dry-run"
		return 0
	fi

	if [[ -z "$repo_path" || ! -d "$repo_path/.git" && ! -f "$repo_path/.git" ]]; then
		_dps_log "PR #$pr_number ($repo_slug): rebase skipped — repo_path unavailable"
		return 1
	fi

	# Detect the default branch — skip rather than assume "main" to avoid
	# `fatal: ambiguous argument 'origin/main'` on non-main repos.
	local default_branch
	if ! default_branch=$(_dps_get_default_branch "$repo_path"); then
		_dps_log "PR #$pr_number ($repo_slug): rebase skipped — no origin/HEAD set (run 'git remote set-head origin --auto')"
		return 1
	fi

	if ! _dps_rebase_in_ephemeral "$pr_number" "$repo_slug" "$repo_path" "$head_ref" "$default_branch"; then
		_dps_record_audit "$_DIRTY_ACTION_REBASE" "$repo_slug" "$pr_number" "failed"
		return 1
	fi

	_dps_rebase_post_comment "$pr_number" "$repo_slug" "$head_ref" "$default_branch" "$key"
	return 0
}

_dirty_pr_action_conflict() {
	local pr_number="$1"
	local repo_slug="$2"
	local body="$3"
	local pr_title="$4"
	local reason="${5:-worker-backed-semantic-conflict}"

	local key="${repo_slug}#${pr_number}"
	if _dps_recently_actioned "$key"; then
		_dps_log "PR #$pr_number ($repo_slug): conflict routing skipped — cooldown active"
		return 0
	fi

	local linked_issue=""
	linked_issue=$(_dps_extract_linked_issue_from_body "$body") || linked_issue=""
	if [[ ! "$linked_issue" =~ ^[0-9]+$ ]]; then
		_dps_log "PR #$pr_number ($repo_slug): conflict routing skipped — no linked issue in PR body"
		_dirty_pr_action_notify "$pr_number" "$repo_slug" "${reason}-no-linked-issue"
		return 0
	fi

	if ! declare -F _dispatch_conflict_fix_worker >/dev/null 2>&1; then
		if [[ -f "${SCRIPT_DIR}/pulse-merge-feedback.sh" ]]; then
			# shellcheck source=pulse-merge-feedback.sh
			# shellcheck disable=SC1091
			source "${SCRIPT_DIR}/pulse-merge-feedback.sh" 2>/dev/null || true
		fi
	fi
	if ! declare -F _dispatch_conflict_fix_worker >/dev/null 2>&1; then
		_dps_log "PR #$pr_number ($repo_slug): conflict routing helper unavailable — notifying"
		_dirty_pr_action_notify "$pr_number" "$repo_slug" "${reason}-helper-unavailable"
		return 0
	fi

	if [[ -z "$pr_title" ]]; then
		pr_title=$(gh pr view "$pr_number" --repo "$repo_slug" --json title --jq '.title // empty' 2>/dev/null) || pr_title=""
	fi
	[[ -n "$pr_title" ]] || pr_title="DIRTY worker PR #${pr_number}"

	if _dps_is_dry_run; then
		_dps_log "DRY-RUN: would route conflict feedback from PR #$pr_number ($repo_slug) to issue #$linked_issue"
		_dps_record_audit "$_DIRTY_ACTION_CONFLICT" "$repo_slug" "$pr_number" "dry-run:$reason"
		return 0
	fi

	_dispatch_conflict_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "$pr_title" || true
	_dps_state_record_action "$key" "$_DIRTY_ACTION_CONFLICT"
	_dps_record_audit "$_DIRTY_ACTION_CONFLICT" "$repo_slug" "$pr_number" "ok:$reason"
	_dps_log "PR #$pr_number ($repo_slug): conflict feedback routed to issue #$linked_issue ($reason)"
	return 0
}

# Close action: post a comment, then close the PR with --delete-branch.
_dirty_pr_action_close() {
	local pr_number="$1"
	local repo_slug="$2"
	local reason="${3:-stale-and-idle}"

	local key="${repo_slug}#${pr_number}"

	if _dps_recently_actioned "$key"; then
		_dps_log "PR #$pr_number ($repo_slug): close skipped — cooldown active"
		return 0
	fi

	# Check linked issue — if it references a parent-task issue that's still
	# open, do NOT close. Escalate instead. This prevents auto-close from
	# stranding work that the parent issue still expects.
	local linked=""
	if declare -F _extract_linked_issue >/dev/null 2>&1; then
		linked=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked=""
	fi
	if [[ -n "$linked" ]]; then
		local linked_state linked_labels
		linked_state=$(gh issue view "$linked" --repo "$repo_slug" --json state --jq '.state // empty' 2>/dev/null) || linked_state=""
		linked_labels=$(gh issue view "$linked" --repo "$repo_slug" --json labels --jq '[.labels[].name] | .[]' 2>/dev/null | tr '[:upper:]' '[:lower:]') || linked_labels=""
		if [[ "$linked_state" == "OPEN" ]] && printf '%s' "$linked_labels" | grep -qx 'parent-task'; then
		_dps_log "PR #$pr_number ($repo_slug): close skipped — linked issue #$linked is open parent-task"
		_dirty_pr_action_notify "$pr_number" "$repo_slug" "parent-task-linked"
			return 0
		fi
	fi

	local linked_hint=""
	if [[ -n "$linked" ]]; then
		linked_hint=$(printf 'The linked issue #%s remains open and available to worker re-dispatch.' "$linked")
	fi
	if [[ "$reason" =~ ^linked-issue-([0-9]+)-closed-by-pr-([0-9]+)$ ]]; then
		linked_hint=$(printf 'The linked issue #%s is already closed by merged PR #%s, so this worker PR is superseded and must not merge later.' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
	fi

	local comment_body
	comment_body="**Auto-close**: this PR has been DIRTY beyond ${DIRTY_PR_CLOSE_MIN_AGE} seconds, with no human activity over the past ${DIRTY_PR_CLOSE_IDLE_HUMAN} seconds. Closing as superseded by subsequent merges.

${linked_hint}

- To opt out of auto-close, add the \`do-not-close\` label to future PRs.
- If this was closed in error, re-open and push a fresh commit — the cooldown will stop the sweep from re-closing within ${DIRTY_PR_SWEEP_ACTION_COOLDOWN} seconds, and fresh activity resets the idle timer.

_Triggered by \`pulse-dirty-pr-sweep.sh\` (t2350 / GH#19948)._"

	if _dps_is_dry_run; then
		_dps_log "DRY-RUN: would close PR #$pr_number ($repo_slug) with comment + --delete-branch"
		_dps_record_audit "$_DIRTY_ACTION_CLOSE" "$repo_slug" "$pr_number" "dry-run"
		return 0
	fi

	_dps_post_comment_if_new "$pr_number" "$repo_slug" "$_DIRTY_PR_CLOSE_MARKER" "$comment_body" || true

	if gh pr close "$pr_number" --repo "$repo_slug" --delete-branch >/dev/null 2>&1; then
		_dps_state_record_action "$key" "$_DIRTY_ACTION_CLOSE"
		_dps_record_audit "$_DIRTY_ACTION_CLOSE" "$repo_slug" "$pr_number" "ok"
		_dps_log "PR #$pr_number ($repo_slug): closed"
		return 0
	fi
	_dps_log "PR #$pr_number ($repo_slug): close failed"
	_dps_record_audit "$_DIRTY_ACTION_CLOSE" "$repo_slug" "$pr_number" "failed"
	return 1
}

# Notify action: post an informational comment once (idempotent via marker).
# This does NOT block merge, does NOT apply a label, does NOT dispatch a worker.
# It only posts an idempotent comment. For an explicit maintainer review hold,
# use `hold-for-review`; NMR remains reserved for external-author trust gates.
_dirty_pr_action_notify() {
	local pr_number="$1"
	local repo_slug="$2"
	local reason="${3:-dirty-not-auto-resolvable}"

	local key="${repo_slug}#${pr_number}"
	if _dps_recently_actioned "$key"; then
		_dps_log "PR #$pr_number ($repo_slug): notify skipped — cooldown active"
		return 0
	fi

	local comment_body
	comment_body="**Maintainer review needed**: this PR is \`DIRTY\` (merge conflicts with the default branch) and does not meet the auto-rebase or auto-close criteria.

Reason: \`${reason}\`

Options:
- Rebase manually: \`git fetch origin && git rebase origin/\$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|origin/||')\` (or \`--strategy-option=union\` when TODO.md is the culprit).
- Close as superseded: \`gh pr close ${pr_number} --delete-branch\`.
- Opt out of future sweeps: add the \`do-not-close\` label.

This comment is posted once per cooldown window (${DIRTY_PR_SWEEP_ACTION_COOLDOWN}s) so the sweep stays quiet.

_Triggered by \`pulse-dirty-pr-sweep.sh\` (t2350 / GH#19948)._"

	if _dps_is_dry_run; then
		_dps_log "DRY-RUN: would notify PR #$pr_number ($repo_slug) reason=$reason"
		_dps_record_audit "$_DIRTY_ACTION_NOTIFY" "$repo_slug" "$pr_number" "dry-run:$reason"
		return 0
	fi

	_dps_post_comment_if_new "$pr_number" "$repo_slug" "$_DIRTY_PR_NOTIFY_MARKER" "$comment_body" || true
	_dps_state_record_action "$key" "$_DIRTY_ACTION_NOTIFY"
	_dps_record_audit "$_DIRTY_ACTION_NOTIFY" "$repo_slug" "$pr_number" "ok:$reason"
	_dps_log "PR #$pr_number ($repo_slug): notified ($reason)"
	return 0
}

# Audit log wrapper — uses the `operation.verify` event type with a detail
# key that identifies the op. Never throws; audit-log-helper failures are
# non-fatal.
_dps_record_audit() {
	local action="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local outcome="$4"

	local helper="${SCRIPT_DIR}/audit-log-helper.sh"
	[[ -x "$helper" ]] || return 0

	"$helper" log "$_DIRTY_PR_AUDIT_EVENT" \
		"dirty-pr-sweep: ${action} PR #${pr_number} in ${repo_slug} — ${outcome}" \
		--detail "op=dirty-pr-sweep.${action}" \
		--detail "repo=${repo_slug}" \
		--detail "pr=${pr_number}" \
		--detail "outcome=${outcome}" >/dev/null 2>&1 || true
	return 0
}

# -----------------------------------------------------------------------------
# Dispatcher — one repo
# -----------------------------------------------------------------------------

#######################################
# Fetch the bounded open-PR sweep population with response-owned GraphQL cost.
# The merge-state field is GraphQL-only; using native `gh pr list` hides a
# multi-point cost under concurrency. Reject partial label connections rather
# than classifying a PR from incomplete ownership metadata.
# Args: $1=repo_slug, $2=result limit
# Output: gh-pr-list-compatible JSON array
# Returns: 0=complete exact-cost snapshot, 1=API/validation failure
#######################################
_dirty_pr_sweep_open_prs_graphql() {
	local repo_slug="$1"
	local result_limit="$2"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug#*/}"
	local response="" pr_json=""
	local jq_array_type="array"

	[[ -n "$owner" && -n "$name" && "$owner" != "$name" ]] || return 1
	[[ "$result_limit" =~ ^[1-9][0-9]*$ && "$result_limit" -le 100 ]] || return 1
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub.
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="dirty-pr-sweep-exact-cost" \
		gh api graphql -F owner="$owner" -F name="$name" -F limit="$result_limit" -f query='
		query($owner: String!, $name: String!, $limit: Int!) {
			repository(owner: $owner, name: $name) {
				pullRequests(first: $limit, states: [OPEN], orderBy: {field: CREATED_AT, direction: DESC}) {
					nodes {
						number
						title
						mergeStateStatus
						createdAt
						updatedAt
						author { login }
						labels(first: 100) {
							nodes { name }
							pageInfo { hasNextPage }
						}
						headRefName
						baseRefName
						body
					}
				}
			}
			rateLimit { cost }
		}' 2>/dev/null) || return 1

	pr_json=$(printf '%s' "$response" | jq -ce --arg array_type "$jq_array_type" '
		select(((.errors // []) | type) == $array_type)
		| select(((.errors // []) | length) == 0)
		| select((.data.rateLimit.cost | type) == "number")
		| select(.data.rateLimit.cost > 0 and (.data.rateLimit.cost | floor) == .data.rateLimit.cost)
		| .data.repository.pullRequests.nodes
		| select(type == $array_type)
		| select(all(.[];
			(.number | type) == "number" and
			(.labels.nodes | type) == $array_type and
			.labels.pageInfo.hasNextPage == false
		))
		| map({
			number,
			title,
			mergeStateStatus,
			createdAt,
			updatedAt,
			author,
			labels: .labels.nodes,
			headRefName,
			baseRefName,
			body
		})
	' 2>/dev/null) || return 1
	printf '%s\n' "$pr_json"
	return 0
}

_dirty_pr_sweep_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	local self_login="$3"

	local list_json err_file
	err_file=$(mktemp) || err_file=/dev/null
	list_json=$(_dirty_pr_sweep_open_prs_graphql "$repo_slug" "$DIRTY_PR_SWEEP_BATCH_LIMIT" \
		2>"$err_file") || list_json="[]"
	[[ -z "$list_json" || "$list_json" == "null" ]] && list_json="[]"
	rm -f "$err_file" 2>/dev/null || true

	# Filter to DIRTY only.
	local dirty_json
	dirty_json=$(printf '%s' "$list_json" | jq -c '[.[] | select(.mergeStateStatus == "DIRTY")]' 2>/dev/null) || dirty_json="[]"
	local count
	count=$(printf '%s' "$dirty_json" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	if [[ "$count" -eq 0 ]]; then
		_dps_log "repo $repo_slug: 0 DIRTY PRs"
		return 0
	fi
	_dps_log "repo $repo_slug: $count DIRTY PR(s) to classify"

	local i=0
	while [[ "$i" -lt "$count" ]]; do
		local pr_obj pr_number decision action reason
		pr_obj=$(printf '%s' "$dirty_json" | jq -c ".[$i]" 2>/dev/null)
		i=$((i + 1))
		[[ -n "$pr_obj" ]] || continue
		pr_number=$(printf '%s' "$pr_obj" | jq -r '.number // empty')
		[[ -n "$pr_number" ]] || continue

		local supersession_reason=""
		if supersession_reason=$(_dps_supersession_reason "$pr_obj" "$repo_slug" "$repo_path" 2>/dev/null); then
			_dps_log "PR #$pr_number ($repo_slug): supersession candidate — notifying before conflict repair"
			_dirty_pr_action_notify "$pr_number" "$repo_slug" "$supersession_reason" || true
			continue
		fi

		decision=$(_dirty_pr_classify "$pr_obj" "$repo_slug" "$repo_path" "$self_login")
		action="${decision%%|*}"
		reason="${decision#*|}"

		_dps_log "PR #$pr_number ($repo_slug): decision=$action reason=$reason"

		case "$action" in
			"$_DIRTY_ACTION_REBASE")
				local head_ref
				head_ref=$(printf '%s' "$pr_obj" | jq -r '.headRefName // empty')
				_dirty_pr_action_rebase "$pr_number" "$repo_slug" "$repo_path" "$head_ref" || true
				;;
			"$_DIRTY_ACTION_CONFLICT")
				local pr_body="" pr_title=""
				pr_body=$(printf '%s' "$pr_obj" | jq -r '.body // empty')
				pr_title=$(printf '%s' "$pr_obj" | jq -r '.title // empty')
				_dirty_pr_action_conflict "$pr_number" "$repo_slug" "$pr_body" "$pr_title" "$reason" || true
				;;
			"$_DIRTY_ACTION_CLOSE")
				_dirty_pr_action_close "$pr_number" "$repo_slug" "$reason" || true
				;;
			"$_DIRTY_ACTION_NOTIFY")
				_dirty_pr_action_notify "$pr_number" "$repo_slug" "$reason" || true
				;;
			"$_DIRTY_ACTION_SKIP")
				:
				;;
			*)
				_dps_log "PR #$pr_number ($repo_slug): unknown decision '$action' — skipping"
				;;
		esac
	done
	return 0
}

# -----------------------------------------------------------------------------
# Public entry points
# -----------------------------------------------------------------------------

# Sweep all registered non-local repos, including dormant dirty-state recovery.
# Respects the interval gate — early-returns 0 when not due.
dirty_pr_sweep_all_repos() {
	# Honour pulse stop flag when running as module.
	if [[ -n "${STOP_FLAG:-}" && -f "$STOP_FLAG" ]]; then
		_dps_log "stop flag present — skipping sweep"
		return 0
	fi

	if ! _dirty_pr_sweep_check_interval; then
		return 0
	fi

	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	if [[ ! -f "$repos_json" ]]; then
		_dps_log "repos.json not found at $repos_json — skipping"
		return 0
	fi

	local self_login=""
	self_login=$(gh api user --jq '.login // empty' 2>/dev/null) || self_login=""

	local total_rebased=0 total_closed=0 total_notified=0

	while IFS='|' read -r repo_slug repo_path; do
		[[ -n "$repo_slug" ]] || continue
		if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
			|| ! repo_allows_pulse_write_actions "$repo_slug"; then
			_dps_log "skipping ${repo_slug}: repo role is contributor/read-only"
			continue
		fi
		# Path may be missing in repos.json; try to resolve from git config.
		if [[ -z "$repo_path" ]]; then
			repo_path=""
		elif [[ "$repo_path" == *"~"* ]]; then
			# Expand leading ~ if present.
			repo_path="${repo_path/#\~/$HOME}"
		fi
		_dirty_pr_sweep_for_repo "$repo_slug" "$repo_path" "$self_login" || true
		if [[ -n "${STOP_FLAG:-}" && -f "$STOP_FLAG" ]]; then
			_dps_log "stop flag appeared mid-run — breaking"
			break
		fi
	done < <(jq -r '.initialized_repos[] | select((.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$repos_json" 2>/dev/null)

	_dirty_pr_sweep_mark_run
	_dps_log "sweep complete: rebased=${total_rebased} closed=${total_closed} notified=${total_notified}"
	return 0
}

# Standalone entry — invoked when the script is executed directly, not
# sourced. Supports --dry-run, --repo, --pr for spot-checking.
_dps_print_help() {
	cat <<EOF
pulse-dirty-pr-sweep.sh — Periodic sweep of DIRTY PRs (t2350, GH#19948).

Usage:
  pulse-dirty-pr-sweep.sh [options]

Options:
  --dry-run            Print actions without executing.
  --repo OWNER/REPO    Limit the sweep to a single repo (skips repos.json scan).
  --pr N               Limit the sweep to a single PR (requires --repo).
  --force              Ignore the interval gate; run regardless of last-run timestamp.
  --help               Show this message.

Environment:
  DRY_RUN=1                          Same as --dry-run.
  DIRTY_PR_SWEEP_INTERVAL=1800           Outer cycle gate (seconds).
  DIRTY_PR_SWEEP_ACTION_COOLDOWN=1800    Per-PR action cooldown (seconds).
  DIRTY_PR_REBASE_MAX_AGE=172800         Rebase ceiling for code conflicts (seconds, 48h).
  DIRTY_PR_REBASE_PLANNING_MAX_AGE=604800  Rebase ceiling for planning-only conflicts (seconds, 7d).
  DIRTY_PR_CLOSE_MIN_AGE=604800          Close eligibility floor (seconds).
  DIRTY_PR_CLOSE_IDLE_HUMAN=259200       Close idleness floor (seconds).
  DIRTY_PR_SWEEP_BATCH_LIMIT=30          Max PRs per repo per run.
  DIRTY_PR_INTERACTIVE_STALE_AGE=14400  Interactive session staleness floor (seconds, 4h). PRs with
                                         origin:interactive are eligible for cross-runner rebase when
                                         both the head ref and PR-author comments are older than this.

Examples:
  pulse-dirty-pr-sweep.sh --dry-run
  pulse-dirty-pr-sweep.sh --dry-run --repo marcusquinn/aidevops
  pulse-dirty-pr-sweep.sh --dry-run --repo marcusquinn/aidevops --pr 19696

See .agents/scripts/pulse-merge.sh — reference pulse-stage pattern.
EOF
}

_dps_main() {
	local repo_filter="" pr_filter="" force=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local next="${2:-}"
		case "$arg" in
			--dry-run)
				_DIRTY_PR_SWEEP_DRY_RUN=1
				shift
				;;
			--repo)
				repo_filter="$next"
				shift 2
				;;
			--repo=*)
				repo_filter="${arg#--repo=}"
				shift
				;;
			--pr)
				pr_filter="$next"
				shift 2
				;;
			--pr=*)
				pr_filter="${arg#--pr=}"
				shift
				;;
			--force)
				force=1
				shift
				;;
			--help | -h)
				_dps_print_help
				return 0
				;;
			*)
				_dps_log "unknown option: $arg"
				_dps_print_help >&2
				return 2
				;;
		esac
	done

	if [[ "$force" -eq 1 ]]; then
		rm -f "$DIRTY_PR_SWEEP_LAST_RUN" 2>/dev/null || true
	fi

	if [[ -n "$repo_filter" && -n "$pr_filter" ]]; then
		# Single-PR spot mode.
		local pr_obj
		pr_obj=$(gh pr view "$pr_filter" --repo "$repo_filter" \
			--json number,mergeStateStatus,createdAt,updatedAt,author,labels,headRefName,baseRefName,body 2>/dev/null) || pr_obj=""
		if [[ -z "$pr_obj" ]]; then
			_dps_log "gh pr view failed (target: $repo_filter#$pr_filter)"
			return 1
		fi
		local self_login repo_path
		self_login=$(gh api user --jq '.login // empty' 2>/dev/null) || self_login=""
		repo_path=""
		local decision action reason
		decision=$(_dirty_pr_classify "$pr_obj" "$repo_filter" "$repo_path" "$self_login")
		action="${decision%%|*}"
		reason="${decision#*|}"
		printf 'PR #%s %s decision=%s reason=%s\n' "$pr_filter" "$repo_filter" "$action" "$reason"
		return 0
	fi

	if [[ -n "$repo_filter" ]]; then
		local self_login repo_path
		self_login=$(gh api user --jq '.login // empty' 2>/dev/null) || self_login=""
		repo_path=""
		_dirty_pr_sweep_for_repo "$repo_filter" "$repo_path" "$self_login"
		return 0
	fi

	dirty_pr_sweep_all_repos
	return 0
}

# When executed directly (not sourced), run _dps_main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_dps_main "$@"
	exit $?
fi
