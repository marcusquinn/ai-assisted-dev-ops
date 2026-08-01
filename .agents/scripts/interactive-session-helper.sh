#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# interactive-session-helper.sh - Interactive session issue-ownership primitive (t2056)
#
# Purpose: provide a mandatory, AI-driven acquire/release primitive for
# interactive GitHub issue ownership. When an interactive session engages
# with an issue in a maintainer-managed repo, this helper applies
# `status:in-review` + self-assignment so the pulse's dispatch-dedup guard
# (`dispatch-dedup-helper.sh is-assigned`) will not dispatch a parallel worker.
# External non-maintainer repos skip these state/comment routines entirely.
#
# SCOPE LIMITATION (GH#19861):
#   `claim` blocks the pulse's DISPATCH path only. It does NOT block:
#   - The enrich path (pulse-enrich.sh) — may overwrite issue title/body/labels
#   - The completion-sweep path — may strip status labels
#   - Any other non-dispatch pulse operation that modifies label/title/body state
#   If you need protection against ALL pulse modifications (e.g., investigating
#   a pulse bug), use `lockdown` instead — it applies `no-auto-dispatch` +
#   `status:in-review` + self-assignment + conversation lock + audit comment.
#
# Why reuse status:in-review rather than a new label:
#   - `_has_active_claim` in dispatch-dedup-helper.sh already treats it as an
#     active claim that blocks dispatch.
#   - `_normalize_stale_should_skip_reset` in pulse-issue-reconcile.sh already
#     skips it during stale-recovery (only queued/in-progress get reset).
#   - `ISSUE_STATUS_LABEL_PRECEDENCE` in shared-constants.sh already ranks it
#     second after `done` for label-invariant reconciliation.
#   - `.github/workflows/issue-sync.yml` already clears it on PR-close cleanup.
# All the gating infrastructure is in place. The only gap this helper closes
# is timing: today the label lands at PR open (via `full-loop-helper.sh
# commit-and-pr`); we need it to land at interactive session engage.
#
# AI-driven contract:
#   The primary enforcement layer is an `AGENTS.md` rule telling the
#   agent to call claim/release from conversation intent. Phase 2 (t2057)
#   adds code-level safety nets in worktree-helper.sh, claim-task-id.sh, and
#   approval-helper.sh. Users are never expected to invoke this helper by
#   hand — the slash command and CLI exist as fallbacks only.
#
# Sub-libraries (GH#21320):
#   - interactive-session-helper-stamp.sh      (stamp CRUD, claim comments)
#   - interactive-session-helper-commands.sh   (claim, lockdown, unlock, release, status, write-stamp)
#   - interactive-session-helper-scan.sh       (stale detection, PR orphan scanning, scan-stale)
#   - interactive-session-helper-postmerge.sh  (post-merge drift healing)
#
# Usage:
#   interactive-session-helper.sh claim <issue> <slug> [--worktree PATH] [--implementing]
#   interactive-session-helper.sh release <issue> <slug> [--unassign]
#   interactive-session-helper.sh lockdown <issue> <slug> [--worktree PATH]
#   interactive-session-helper.sh unlock <issue> <slug> [--unassign]
#   interactive-session-helper.sh status [<issue>]
#   interactive-session-helper.sh scan-stale
#   interactive-session-helper.sh reap-dead-stamps
#   interactive-session-helper.sh post-merge <pr_number> [<slug>]
#   interactive-session-helper.sh help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Stamp directory for crash-recovery metadata. Each claim writes one JSON file
# keyed by "<slug-flat>-<issue>.json" so stamps are unique per-repo per-issue.
# Matches the `~/.aidevops/.agent-workspace/` convention from AGENTS.md.
CLAIM_STAMP_DIR="${HOME}/.aidevops/.agent-workspace/interactive-claims"

# -----------------------------------------------------------------------------
# Logging (all to stderr so stdout stays machine-readable)
# -----------------------------------------------------------------------------
# Colours: green=ok, yellow=warn, red=err. Fall through to plain text if the
# terminal doesn't support ANSI (log_info / log_warn from shared-constants.sh
# are sourced above, but we define local wrappers for consistency with other
# helpers in this directory).

_isc_info() {
	printf '[interactive-session] %s\n' "$*" >&2
	return 0
}

_isc_warn() {
	printf '[interactive-session] WARN: %s\n' "$*" >&2
	return 0
}

_isc_err() {
	printf '[interactive-session] ERROR: %s\n' "$*" >&2
	return 0
}

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

# Flatten a slug ("owner/repo") into a filename-safe token ("owner-repo").
_isc_slug_flat() {
	local slug="$1"
	printf '%s' "${slug//\//-}"
	return 0
}

# Resolve the stamp file path for an issue in a repo.
_isc_stamp_path() {
	local issue="$1"
	local slug="$2"
	printf '%s/%s-%s.json' "$CLAIM_STAMP_DIR" "$(_isc_slug_flat "$slug")" "$issue"
	return 0
}

# Resolve the current GitHub user login. Returns empty string on failure so
# callers can decide whether to proceed or abort.
_isc_current_user() {
	local login
	login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	# Reject JSON null / empty / literal "null"
	if [[ -z "$login" || "$login" == "null" ]]; then
		printf ''
		return 0
	fi
	printf '%s' "$login"
	return 0
}

# Check whether the authenticated user should run aidevops maintainer-only
# issue-state routines in this repo. External upstream repos do not run our
# pulse, so posting claim/status/lockdown lifecycle markers there is noise.
#
# Returns 0 for maintainer-equivalent access, 1 otherwise. Lookup failures are
# treated as NOT authorized: skipping a claim is safer than publicly applying
# internal aidevops workflow state to an upstream project we cannot verify.
_isc_can_manage_issue_state() {
	local slug="${1:-}"
	local user="${2:-}"

	if [[ -z "$slug" || -z "$user" ]]; then
		return 1
	fi

	local repo_owner="${slug%%/*}"
	if [[ "$user" == "$repo_owner" ]]; then
		return 0
	fi

	local permission=""
	# #aidevops:trust-boundary — managed-repo claim/state writes require a
	# confirmed collaborator permission; lookup failures fail closed without
	# being treated as confirmed non-collaborators.
	_gh_collaborator_permission_lookup "$slug" "$user" permission || return 1
	case "$permission" in
		admin | maintain | write)
			return 0
			;;
	esac

	return 1
}

# Check whether the `gh` CLI is reachable and authenticated. Returns 0 when
# usable, 1 otherwise. Used as the offline/auth gate in `claim` so we can
# warn-and-continue rather than fail-close.
_isc_gh_reachable() {
	if ! command -v gh >/dev/null 2>&1; then
		return 1
	fi
	# Stored-keyring validation can fail while an environment/App token remains
	# usable. Accept the cheap status path first, then probe the API capability
	# this helper needs before declaring GitHub offline or unauthenticated.
	if gh auth status >/dev/null 2>&1; then
		return 0
	fi
	local login=""
	login=$(_isc_current_user)
	[[ -n "$login" ]] || return 1
	return 0
}

# Read the authoritative state needed to classify interactive ownership in one
# bounded request. Labels alone are workflow state, not principal ownership.
# Comments are included so a recent compatible interactive claim can protect a
# foreign human owner even when immutable origin provenance says worker.
# Returns 0 with JSON on stdout, 2 when metadata is unavailable or malformed.
_isc_read_claim_metadata() {
	local issue="$1"
	local slug="$2"
	local json=""
	local array_type="array"
	json=$(gh issue view "$issue" --repo "$slug" \
		--json state,labels,assignees,comments 2>/dev/null) || return 2
	printf '%s' "$json" | jq -e --arg array_type "$array_type" '
		type == "object" and
		((.labels // []) | type == $array_type) and
		((.assignees // []) | type == $array_type) and
		((.comments // []) | type == $array_type)
	' >/dev/null 2>&1 || return 2
	printf '%s' "$json"
	return 0
}

# Compatibility label probe used by release paths and focused regression tests.
# Claim acquisition intentionally uses the richer ownership metadata above.
_isc_has_in_review() {
	local issue="$1"
	local slug="$2"
	local json=""
	json=$(gh issue view "$issue" --repo "$slug" --json labels 2>/dev/null) || return 2
	printf '%s' "$json" | jq -e '(.labels // []) | any(.name == "status:in-review")' >/dev/null 2>&1
	return $?
}

# Generic label probe — returns 0 if the issue carries the named label, 1 if
# absent, 2 if the gh lookup failed. Caller MUST use a direct `if` conditional
# (not bare call + $? capture) to avoid the same set -e propagation foot-gun
# documented above for `_isc_has_in_review` (GH#18786).
#
# Used by `_isc_cmd_claim` to honour the t2218 auto-dispatch carve-out at the
# manual-claim entry point (GH#20946) and could be reused by other callers
# that need to probe a specific label without parsing the full label JSON.
_isc_has_label() {
	local issue="$1"
	local slug="$2"
	local label="$3"
	local json
	json=$(gh issue view "$issue" --repo "$slug" --json labels 2>/dev/null) || return 2
	if printf '%s' "$json" | jq -e --arg name "$label" '(.labels // []) | any(.name == $name)' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Single-pass auto-dispatch carve-out probe (GH#20946 PR #20977 review).
# Combines the two-call (`auto-dispatch` AND NOT `parent-task`) probe into one
# `gh issue view` round-trip. Addresses two review findings together:
#   - gemini-code-assist: redundant gh+jq calls in the claim hot path
#   - augmentcode: the prior two-call form's inner `if !` branch conflated
#     rc=1 (parent-task absent → carve-out applies) with rc=2 (gh lookup
#     failed → caller intent unknown), failing CLOSED on transient errors
#     and contradicting the outer fail-OPEN comment.
#
# Returns:
#   0  carve-out applies — has `auto-dispatch` AND lacks `parent-task`. Caller
#      MUST refuse to claim; self-assign would create a permanent dispatch
#      block per the t1996/t2218 invariant (see _has_active_claim in
#      dispatch-dedup-helper.sh).
#   1  carve-out does NOT apply — auto-dispatch absent OR parent-task present.
#      Caller proceeds with the normal claim path.
#   2  lookup failed (gh offline, network, auth). Caller falls through and
#      proceeds with the claim — fail-OPEN. A spurious carve-out skip on a
#      transient error would be just as harmful as a missed carve-out;
#      proceeding matches the offline gate at the top of `_isc_cmd_claim`.
#
# `if [[ $implementing -eq 0 ]] && _isc_carve_out_required ...; then` is the
# canonical caller form — only enters the skip branch on rc=0; rc=1 and rc=2
# both fall through. The `&&` short-circuit also consumes any non-zero return
# through a conditional context, protecting against set -e propagation
# (GH#18786 sibling class).
_isc_carve_out_required() {
	local issue="$1"
	local slug="$2"
	local json
	json=$(gh issue view "$issue" --repo "$slug" --json labels 2>/dev/null) || return 2
	if printf '%s' "$json" | jq -e '
		(.labels // []) |
		(any(.name == "auto-dispatch")) and
		(any(.name == "parent-task") | not)
	' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# Returns 0 if the issue state is CLOSED, 1 otherwise or on gh lookup failure
# (GH#21805). Fail-open: returns 1 on errors so transient network issues do not
# silently change the release behaviour from the existing default.
_isc_issue_is_closed() {
	local issue="$1"
	local slug="$2"
	local _state
	_state=$(gh issue view "$issue" --repo "$slug" --json state --jq .state 2>/dev/null) || return 1
	if [[ "$_state" == "CLOSED" || "$_state" == "closed" ]]; then
		return 0
	fi
	return 1
}

# -----------------------------------------------------------------------------
# Sub-library sourcing (GH#21320)
# -----------------------------------------------------------------------------

# Stamp management (write, delete, stampless detection, claim comments)
# shellcheck source=./interactive-session-helper-stamp.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/interactive-session-helper-stamp.sh"

# Core commands (claim, lockdown, unlock, release, status, write-stamp)
# shellcheck source=./interactive-session-helper-commands.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/interactive-session-helper-commands.sh"

# Scan/stale detection (PR orphans, dead stamps, stampless claims, scan-stale)
# shellcheck source=./interactive-session-helper-scan.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/interactive-session-helper-scan.sh"

# Post-merge drift healing (t2225)
# shellcheck source=./interactive-session-helper-postmerge.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/interactive-session-helper-postmerge.sh"

# -----------------------------------------------------------------------------
# Subcommand: help
# -----------------------------------------------------------------------------
_isc_cmd_help() {
	cat <<'EOF'
interactive-session-helper.sh - Interactive issue-ownership primitive (t2056)

USAGE:
  interactive-session-helper.sh claim <issue> <slug> [--worktree PATH] [--implementing]
      Apply status:in-review + self-assign + write crash-recovery stamp.
      Idempotent. Offline gh → warn-and-continue (exit 0).
      Auto-dispatch carve-out (GH#20946): refuses to claim issues tagged
      'auto-dispatch' unless --implementing is passed or the issue is also
      tagged 'parent-task'. Without the carve-out, claim creates a
      permanent dispatch block (t1996/GH#18352). Use --implementing when
      you intend to implement the issue yourself instead of letting a
      worker pick it up.

  interactive-session-helper.sh release <issue> <slug> [--unassign]
      Transition status:in-review → status:available, delete stamp.
      Idempotent. --unassign also removes self from assignees.

  interactive-session-helper.sh lockdown <issue> <slug> [--worktree PATH]
      Stricter than claim: blocks ALL pulse paths, not just dispatch.
      Applies: no-auto-dispatch + status:in-review + self-assign +
      conversation lock + audit comment + crash-recovery stamp.
      Use when investigating pulse bugs or need maximum insulation.
      Reverse with: unlock <issue> <slug>

  interactive-session-helper.sh unlock <issue> <slug> [--unassign]
      Reverse a lockdown: remove no-auto-dispatch, transition to
      status:available, unlock conversation, delete stamp, post audit.
      --unassign also removes self from assignees.

  interactive-session-helper.sh status [<issue>]
      List active claims from the stamp directory, or check one issue.

  interactive-session-helper.sh scan-stale [--auto-release | --no-auto-release]
      Three-phase stale detection:
      Phase 1  — Identify stamps with dead PID AND missing worktree path.
                 Auto-releases when BOTH conditions hold (t2414). Default: ON
                 when stdin+stdout are TTYs (interactive session), OFF otherwise.
                 Override: --auto-release / --no-auto-release flags, or
                 AIDEVOPS_SCAN_STALE_AUTO_RELEASE=0|1 env var.
                 Live PID or existing worktree: stamp is NEVER touched.
      Phase 1a — Identify stampless origin:interactive + self-assigned
                 issues (t2148). These block pulse dispatch forever
                 because _has_active_claim treats the label as a claim
                 regardless of stamp state. Does NOT auto-release —
                 `normalize_active_issue_assignments` auto-recovers after
                 24h; the agent can unassign immediately at session start.
      Phase 2  — Scan all pulse-enabled repos for closed-not-merged PRs
                 (last 14 days) whose linked issue is still OPEN. Surfaces
                 these as recovery candidates. Does NOT auto-reopen.

  interactive-session-helper.sh release-if-dead <issue> <slug>
      Pulse-safe single-claim recovery; releases a dead same-host owner unless
      no-auto-dispatch applies. Live, cross-host, and unknown states fail closed.
  interactive-session-helper.sh reap-dead-stamps  Bounded direct stamp recovery; safety gates fail closed.
  interactive-session-helper.sh post-merge <pr_number> [<slug>]
      Auto-heal two known drift patterns after a planning PR merges (t2225).
      Call after `gh pr merge` succeeds, alongside `release <N>`.
      Heal 1 (t2219): removes false status:done on OPEN For/Ref-referenced
        issues — planning-convention refs that issue-sync.yml falsely closes.
      Heal 2 (t2218): unassigns PR author from OPEN auto-dispatch issues with
        origin:interactive + no active status label (should be pulse-dispatched).
      Both passes are idempotent, fail-open, and post audit-trail comments.
      Slug defaults to the current repo if not provided.

  interactive-session-helper.sh write-stamp <issue> <slug>
      Write a crash-recovery stamp WITHOUT performing any GitHub status
      transitions. Called by claim-task-id.sh after self-assign to atomically
      close the gap where self-assign succeeded but the full claim (status:in-
      review transition) later failed. The subsequent `claim` subcommand
      overwrites the stamp with full lifecycle info. (t2943)

  interactive-session-helper.sh branch-has-active-claim <branch> [--worktree PATH]
      Exit 0 if an active interactive-session claim exists for the branch's
      issue (stamp present, PID alive, hostname matches). Exit 1 otherwise.
      Used by worktree cleanup paths (worktree-clean-lib.sh::should_skip_cleanup,
      pulse-cleanup.sh::_worktree_owner_alive) to honour active claims without
      sourcing the helper. Same source of truth as the dispatch-dedup gate.
      (t2916/GH#21074)

  interactive-session-helper.sh help
      Print this message.

CONTRACT:
  This helper is intended to be called from interactive AI sessions, driven
  by conversation intent (see `AGENTS.md` → "Interactive issue
  ownership"). Users should never need to invoke it directly — the agent
  claims on engage and releases on signal.

  SCOPE: `claim` blocks pulse DISPATCH only (GH#19861). It does NOT block
  enrich, completion-sweep, or other non-dispatch pulse operations. For full
  insulation from all pulse paths, use `lockdown` instead.

  Slug format: owner/repo (e.g., marcusquinn/aidevops).

STAMP DIRECTORY:
  ~/.aidevops/.agent-workspace/interactive-claims/
EOF
	return 0
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	local rc=0
	shift || true

	# `|| rc=$?` is the `set -e`-safe idiom for capturing subcommand exit
	# codes. A bare call inside a case branch propagates non-zero returns
	# out of main() before `return $?` runs (e.g. _isc_cmd_status returning
	# 1 for "target issue not found"). Use a tested-condition capture so
	# set -e treats the subcommand as a branch condition and leaves rc intact.
	case "$cmd" in
	claim)
		_isc_cmd_claim "$@" || rc=$?
		;;
	lockdown)
		_isc_cmd_lockdown "$@" || rc=$?
		;;
	unlock)
		_isc_cmd_unlock "$@" || rc=$?
		;;
	release)
		_isc_cmd_release "$@" || rc=$?
		;;
	status)
		_isc_cmd_status "$@" || rc=$?
		;;
	scan-stale)
		_isc_cmd_scan_stale "$@" || rc=$?
		;;
	release-if-dead)
		_isc_cmd_release_if_dead "$@" || rc=$?
		;;
	reap-dead-stamps)
		_isc_cmd_reap_dead_stamps "$@" || rc=$?
		;;
	post-merge)
		_isc_cmd_post_merge "$@" || rc=$?
		;;
	write-stamp)
		_isc_cmd_write_stamp "$@" || rc=$?
		;;
	branch-has-active-claim)
		_isc_cmd_branch_has_active_claim "$@" || rc=$?
		;;
	help | -h | --help)
		_isc_cmd_help || rc=$?
		;;
	*)
		_isc_err "unknown subcommand: $cmd"
		_isc_cmd_help || true
		return 2
		;;
	esac
	return "$rc"
}

# Only run main when executed, not when sourced (allows tests to source and
# call internal functions directly without triggering the help dispatcher)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
