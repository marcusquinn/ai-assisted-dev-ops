#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Interactive Session Stamp Management -- Crash-recovery stamp CRUD
# =============================================================================
# Stamp write/delete, stampless claim detection, and claim comment posting.
# Extracted from interactive-session-helper.sh (GH#21320).
#
# Usage: source "${SCRIPT_DIR}/interactive-session-helper-stamp.sh"
#
# Dependencies:
#   - shared-constants.sh (_compute_argv_hash, gh_issue_comment, _filter_non_task_issues)
#   - Logging functions from interactive-session-helper.sh (_isc_info, _isc_warn, _isc_err)
#   - CLAIM_STAMP_DIR, _isc_slug_flat, _isc_stamp_path from orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISC_STAMP_LIB_LOADED:-}" ]] && return 0
_ISC_STAMP_LIB_LOADED=1
ISC_CLAIM_AUDIT_SCHEMA="aidevops-interactive-claim/v1"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Resolve the local hostname, returning a single canonical fallback when the
# `hostname` command is unavailable. Centralised so the fallback literal lives
# in one place (avoids the t2763-style repeated-string-literal ratchet).
_isc_hostname_or_fallback() {
	hostname 2>/dev/null || printf '%s' "unknown"
	return 0
}

# Write a stamp JSON file for a claim. Idempotent — overwrites on re-call so
# the `claimed_at` timestamp refreshes for crash-recovery tie-breaks.
_isc_write_stamp() {
	local issue="$1"
	local slug="$2"
	local worktree_path="$3"
	local user="$4"

	mkdir -p "$CLAIM_STAMP_DIR" 2>/dev/null || {
		_isc_warn "cannot create stamp dir: $CLAIM_STAMP_DIR (continuing)"
		return 0
	}

	local stamp_file
	stamp_file=$(_isc_stamp_path "$issue" "$slug")

	local timestamp hostname
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	hostname=$(_isc_hostname_or_fallback)

	# Record the long-lived runtime/shell owner rather than this short-lived
	# helper CLI. Interactive runtimes spawn a fresh shell for each tool call, so
	# stamping $$ makes a new lockdown look abandoned as soon as the call exits.
	local owner_pid argv_hash=""
	owner_pid=$(_resolve_worktree_owner_pid "" 2>/dev/null || echo "")
	[[ "$owner_pid" =~ ^[0-9]+$ ]] || owner_pid="$$"
	argv_hash=$(_compute_argv_hash "$owner_pid" 2>/dev/null || echo "")

	# Escape user-supplied fields via jq's string literals to avoid JSON injection
	jq -n \
		--arg issue "$issue" \
		--arg slug "$slug" \
		--arg worktree "$worktree_path" \
		--arg claimed_at "$timestamp" \
		--arg pid "$owner_pid" \
		--arg hostname "$hostname" \
		--arg user "$user" \
		--arg argv_hash "$argv_hash" \
		'{
			issue: ($issue | tonumber),
			slug: $slug,
			worktree_path: $worktree,
			claimed_at: $claimed_at,
			pid: ($pid | tonumber),
			hostname: $hostname,
			user: $user,
			owner_argv_hash: $argv_hash
		}' >"$stamp_file" 2>/dev/null || {
		_isc_warn "failed to write stamp: $stamp_file"
		return 0
	}
	return 0
}

# Delete a stamp file. No-op when the file doesn't exist.
_isc_delete_stamp() {
	local issue="$1"
	local slug="$2"
	local stamp_file
	stamp_file=$(_isc_stamp_path "$issue" "$slug")
	rm -f "$stamp_file" 2>/dev/null || true
	return 0
}

# Cross-host PIDs cannot be verified locally, so remote authority is bounded by
# a renewable stamp age. Return 0 while fresh, 1 when conclusively expired or
# implausibly future-dated, and 2 when timestamp parsing is unavailable or
# malformed (callers fail closed).
_isc_cross_host_claim_freshness() {
	local claimed_at="$1"
	local ttl_hours="${AIDEVOPS_CROSS_HOST_CLAIM_TTL_HOURS:-168}"
	local future_skew_seconds="${AIDEVOPS_CROSS_HOST_CLAIM_FUTURE_SKEW_SECONDS:-300}"
	[[ "$ttl_hours" =~ ^[1-9][0-9]*$ && "$ttl_hours" -le 8760 ]] || ttl_hours=168
	[[ "$future_skew_seconds" =~ ^[0-9]+$ && "$future_skew_seconds" -le 86400 ]] || future_skew_seconds=300
	[[ -n "$claimed_at" ]] || return 2

	local claimed_epoch=""
	local now_epoch=""
	claimed_epoch=$(jq -nr --arg value "$claimed_at" \
		'try ($value | fromdateiso8601) catch empty' 2>/dev/null || true)
	now_epoch=$(date +%s 2>/dev/null || true)
	[[ "$claimed_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || return 2

	if [[ "$claimed_epoch" -gt $((now_epoch + future_skew_seconds)) ]]; then
		return 1
	fi
	if [[ $((now_epoch - claimed_epoch)) -gt $((ttl_hours * 3600)) ]]; then
		return 1
	fi
	return 0
}

# List stampless origin:interactive claims for a single repo (t2148).
#
# Detection rule: an issue is a "stampless interactive claim" when all of:
#   - state: OPEN
#   - .labels[] contains "origin:interactive"
#   - .assignees[] contains runner_user
#   - no matching stamp file exists at $(_isc_stamp_path issue slug)
#
# These are the zombie claims that block pulse dispatch forever:
# `_has_active_claim()` (in dispatch-dedup-helper.sh) treats
# `origin:interactive` as an active claim regardless of stamp state,
# but `_isc_cmd_scan_stale` Phase 1 only iterates `$CLAIM_STAMP_DIR`
# so stampless ones are invisible. Typical cause: `claim-task-id.sh`
# auto-assigned runner on issue creation (per t1970 for maintainer-gate
# protection), but the interactive session never ran the formal claim
# flow, so no stamp was written.
#
# Args:
#   $1 runner_user — GH login of current runner (from `gh api user`)
#   $2 slug        — owner/repo
# Stdout: newline-separated JSON lines `{"number":N,"updated_at":"...",
#         "slug":"..."}` (one per stampless claim). Empty on failure.
# Exit: 0 always (fail-open for discovery — a transient gh/jq error
#       should not mask genuine claims on the next scan).
_isc_list_stampless_interactive_claims() {
	local runner_user="$1"
	local slug="$2"

	[[ -n "$runner_user" && -n "$slug" ]] || return 0

	local json
	json=$(gh issue list --repo "$slug" \
		--assignee "$runner_user" \
		--label origin:interactive \
		--state open \
		--json number,updatedAt,labels \
		--limit 200 2>/dev/null) || return 0

	[[ -n "$json" && "$json" != "null" ]] || return 0

	# GH#20048: filter out non-task issues (routine-tracking, supervisor, etc.)
	# before the stampless scan so they are never surfaced as false positives.
	json=$(printf '%s' "$json" | _filter_non_task_issues) || return 0
	[[ -n "$json" && "$json" != "[]" ]] || return 0

	# Emit (number, updated_at) tuples; shell filters stampless.
	local rows
	rows=$(printf '%s' "$json" | jq -r '
		.[] | "\(.number)\t\(.updatedAt)"
	' 2>/dev/null) || return 0

	[[ -n "$rows" ]] || return 0

	local issue updated_at stamp
	while IFS=$'\t' read -r issue updated_at; do
		[[ "$issue" =~ ^[0-9]+$ ]] || continue
		stamp=$(_isc_stamp_path "$issue" "$slug")
		if [[ ! -f "$stamp" ]]; then
			# Emit compact (single-line) JSON so callers can parse row-by-row
			# via `while IFS= read -r row`. Pretty-printed multi-line output
			# breaks line-based parsing (see t2148 Test 14 regression).
			jq -nc \
				--arg slug "$slug" \
				--arg updated_at "$updated_at" \
				--arg issue "$issue" \
				'{number: ($issue | tonumber), updated_at: $updated_at, slug: $slug}' \
				2>/dev/null || true
		fi
	done <<<"$rows"

	return 0
}

# -----------------------------------------------------------------------------
# Branch → issue extraction (t2916/GH#21074)
# -----------------------------------------------------------------------------
# Map a worktree branch name to a GitHub issue number using the same patterns
# the framework uses elsewhere (see worktree-helper.sh::_interactive_session_auto_claim
# and pulse-cleanup.sh::_record_orphan_crash_classification).
#
# Patterns accepted (first-match wins, evaluated in priority order):
#   <prefix>/gh<NNN>[-_]<rest>      e.g. bugfix/gh18700-foo
#   <prefix>/gh-<NNN>[-_]<rest>     e.g. feature/gh-21074-active-claim-guard
#   <prefix>/auto-*-gh<NNN>         e.g. feature/auto-20260429-062620-gh21074
#   <prefix>/t<NNN>[-_]<rest>       e.g. feature/t2916-foo (no TODO.md lookup —
#                                   the dispatch-time priority-3 lookup in
#                                   worktree-helper.sh covers that path; this
#                                   helper is called from cleanup paths where
#                                   we want a cheap structural-only check)
#
# Stdout: issue number on success (numeric, no newline beyond printf).
# Exit:   0 on match, 1 on no match.
#
# Why no TODO.md fallback: this helper is called from cleanup paths that may
# run mid-pulse-cycle on branches whose corresponding TODO entry has already
# been completion-stripped. A structural-only match is the safe behaviour —
# false negatives mean we fall through to the existing 4 safety checks (no
# regression); false positives could surface a wrong issue (we'd skip the
# wrong worktree). Branch-name patterns are unambiguous structurally.
_isc_extract_issue_from_branch() {
	local branch="${1:-}"
	[[ -z "$branch" ]] && return 1

	# Priority 1: explicit gh<NNN> or gh-<NNN> in any path segment
	if [[ "$branch" =~ /gh-?([0-9]+)[-_] ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	# Priority 2: trailing -gh<NNN> (auto-dispatch branch naming, GH#19042)
	if [[ "$branch" =~ -gh-?([0-9]+)$ ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	# Priority 3: t<NNN> in any path segment — but we cannot resolve to an
	# issue number without a TODO.md lookup. Return 1 (no match) so the
	# caller falls through to the existing safety checks.
	return 1
}

# Check whether a branch has an active interactive-session claim — i.e., a
# stamp file exists for the issue derived from the branch AND the stamp's
# pid field references a live process matching the worker pattern.
#
# Same source of truth as the dispatch-dedup gate (`_has_active_claim` in
# dispatch-dedup-helper.sh) and the scan-stale Phase 1 logic.
#
# Arguments:
#   $1 = branch ref (e.g. "feature/gh-21074-active-claim-guard")
#   [--worktree PATH] = optional worktree path; when supplied, the slug is
#                       derived from `git -C <path> remote get-url origin`.
#                       When omitted, the helper falls back to the current
#                       working directory's git remote.
#
# Slug derivation strategy: a single branch name can map to one issue across
# all repos that happen to use compatible naming, so we cannot derive slug
# from branch alone. The cleanup path always knows the worktree path, so
# pass it via --worktree.
#
# Exit:
#   0 — active claim exists (local PID alive, or fresh/unknown cross-host age)
#   1 — no active claim (no stamp, dead PID, or conclusively stale cross-host)
#
# Fail-open contract: any error in slug derivation, branch parsing, or
# stamp parsing returns 1 (no claim). The caller treats "no claim" as
# "fall through to existing safety checks" — never as "skip cleanup". A
# transient error must not freeze worktree cleanup forever.
_isc_branch_has_active_claim() {
	local branch=""
	local worktree_path=""
	local worktree_supplied=0

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
			--worktree)
				worktree_supplied=1
				worktree_path="${2:-}"
				shift 2
				;;
			--worktree=*)
				worktree_supplied=1
				worktree_path="${_arg#--worktree=}"
				shift
				;;
			-*)
				# Unknown flag — ignore for forward-compat
				shift
				;;
			*)
				if [[ -z "$branch" ]]; then
					branch="$_arg"
				fi
				shift
				;;
		esac
	done

	[[ -z "$branch" ]] && return 1

	local issue
	issue=$(_isc_extract_issue_from_branch "$branch") || return 1
	[[ -z "$issue" ]] && return 1

	# An explicit worktree binds repository identity to that path. Only callers
	# that omit the option may derive identity from their current directory.
	local slug=""
	if [[ "$worktree_supplied" -eq 1 ]]; then
		[[ -n "$worktree_path" && -d "$worktree_path" ]] || return 1
		slug=$(git -C "$worktree_path" remote get-url origin 2>/dev/null \
			| sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	else
		slug=$(git remote get-url origin 2>/dev/null \
			| sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
	fi
	[[ -z "$slug" ]] && return 1

	local stamp_file
	stamp_file=$(_isc_stamp_path "$issue" "$slug")
	[[ -f "$stamp_file" ]] || return 1

	# Read stamp fields. Treat any jq error as "no claim" (fail-open).
	local pid hostname stored_hash claimed_at
	pid=$(jq -r '.pid // empty' "$stamp_file" 2>/dev/null || echo "")
	hostname=$(jq -r '.hostname // empty' "$stamp_file" 2>/dev/null || echo "")
	stored_hash=$(jq -r '.owner_argv_hash // empty' "$stamp_file" 2>/dev/null || echo "")
	claimed_at=$(jq -r '.claimed_at // empty' "$stamp_file" 2>/dev/null || echo "")

	# Cross-host stamps cannot have their PID verified. Trust remote authority
	# only within a bounded renewable lease. Missing or malformed timestamps stay
	# active (fail closed); expired or implausibly future timestamps release only
	# this gate so the remaining cleanup protections still decide.
	local local_host
	local_host=$(_isc_hostname_or_fallback)
	if [[ -n "$hostname" && "$hostname" != "$local_host" ]]; then
		local freshness_rc=0
		_isc_cross_host_claim_freshness "$claimed_at" || freshness_rc=$?
		[[ "$freshness_rc" -eq 1 ]] && return 1
		return 0
	fi

	# Local host: verify PID is alive AND matches a runtime pattern.
	# `_is_process_alive_and_matches` is in shared-constants.sh.
	if [[ -z "$pid" ]]; then
		# Stamp without a pid — fail-OPEN. Treat as no claim so the
		# regular safety checks decide. A stamp predating the t2421
		# pid+hash columns shouldn't permanently freeze cleanup.
		return 1
	fi

	if command -v _is_process_alive_and_matches >/dev/null 2>&1; then
		if _is_process_alive_and_matches "$pid" "${WORKER_PROCESS_PATTERN:-opencode|claude|Claude}" "$stored_hash"; then
			return 0
		fi
		return 1
	fi

	# Fallback when shared-constants.sh is unavailable: bare kill -0.
	# Less precise (PID reuse risk) but still safer than skipping the
	# check entirely on a degraded environment.
	if kill -0 "$pid" 2>/dev/null; then
		return 0
	fi
	return 1
}

# Post a claim comment on the issue for audit trail visibility.
# Mirrors worker dispatch comments but for interactive sessions.
# Best-effort — all errors are swallowed so the caller never stalls.
#
# Arguments:
#   $1 = issue number, $2 = repo slug, $3 = user login, $4 = worktree path
_isc_post_claim_comment() {
	local issue="$1"
	local slug="$2"
	local user="$3"
	local worktree_path="$4"

	local hostname
	hostname=$(_isc_hostname_or_fallback)
	local worktree_note=""
	if [[ -n "$worktree_path" ]]; then
		worktree_note=" in \`${worktree_path##*/}\`"
	fi

	# <!-- ops:start --> / <!-- ops:end --> markers let the agent skip this
	# comment when reading issue threads (see build.txt 8d).
	local body
	body=$(
		cat <<EOF
<!-- ${ISC_CLAIM_AUDIT_SCHEMA} -->
<!-- ops:start -->
> Interactive session claimed by @${user}${worktree_note} on ${hostname}.
> Pulse dispatch blocked via \`status:in-review\` + self-assignment.
<!-- ops:end -->
EOF
	)

	gh_issue_comment "$issue" --repo "$slug" --body "$body" >/dev/null 2>&1 || {
		_isc_warn "claim comment failed on #$issue — continuing (audit trail incomplete)"
	}
	return 0
}
