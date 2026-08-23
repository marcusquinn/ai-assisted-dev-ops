#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Wrapper Bootstrap -- Invocation source detection and mode flags
# =============================================================================
# Argument-parsing and invocation-source helpers that run early in main()
# before the lock and cycle work begin: --self-check, --dry-run, --canary
# flag handlers; launchd/cron/manual invocation source detection and
# stats counter increment. Extracted from pulse-wrapper.sh
# (GH#21311 / t2936-child) to bring the orchestrator below the 1500-line
# file-size-debt threshold. No behavioural changes.
#
# Usage: source "${SCRIPT_DIR}/pulse-wrapper-bootstrap.sh"
#
# Dependencies:
#   - pulse-wrapper-config.sh (LOGFILE, PULSE_STATS_FILE)
#   - _pulse_execute_self_check (defined in pulse-wrapper.sh — kept there
#     because the function is >100 lines and moving it would create a new
#     function-complexity identity-key violation per
#     reference/large-file-split.md §3)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_WRAPPER_BOOTSTRAP_LIB_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_BOOTSTRAP_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_pwb_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

# ---------------------------------------------------------------------------
# _pulse_handle_self_check
#
# Phase 0 (t1963, GH#18357): --self-check short-circuit for CI, pre-edit
# verification, and post-install smoke testing. Runs before any lock,
# state mutation, or side effect. Sources are already in place (the
# wrapper sources its helpers before main() is called), so by the time
# control reaches here every function the wrapper claims to define has
# been parsed.
#
# Scans "$@" for --self-check (GH#18614: position-independent).
# Extracted from main() (GH#18689) to reduce function length.
#
# Returns:
#   0 — --self-check found and all symbols verified (self-check passed)
#   1 — --self-check found but one or more symbols missing (self-check failed)
#   2 — --self-check not present; caller should continue normally
# ---------------------------------------------------------------------------
_pulse_handle_self_check() {
	local _sc_flag=0
	local _arg
	for _arg in "$@"; do
		if [[ "$_arg" == "--self-check" ]]; then
			_sc_flag=1
			break
		fi
	done
	unset _arg
	[[ "$_sc_flag" -eq 0 ]] && return 2
	_pulse_execute_self_check
	return $?
}

# ---------------------------------------------------------------------------
# _pulse_setup_dry_run_mode
#
# Phase 0 (t1963, GH#18357): --dry-run flag sets PULSE_DRY_RUN=1 so the
# cycle can short-circuit before touching destructive operations. This
# smoke-tests bootstrap, sourcing, config validation, lock acquisition,
# and the main() prelude without dispatching workers, merging PRs,
# writing GitHub state, or removing worktrees.
#
# Phase 0 scope is narrow by design: --dry-run runs up to (but not
# through) _run_preflight_stages. Later phases may widen --dry-run by
# shimming individual destructive call sites with a _dry_run_log() helper.
#
# USAGE NOTE: --dry-run still runs acquire_instance_lock, session_gate,
# and dedup. For CI/smoke tests, run in a sandboxed $HOME:
#   SANDBOX=$(mktemp -d)
#   HOME="$SANDBOX/home" PULSE_JITTER_MAX=0 pulse-wrapper.sh --dry-run
#
# Scans "$@" for --dry-run (GH#18614: position-independent).
# Extracted from main() (GH#18689) to reduce function length.
# Exit code: always 0
# ---------------------------------------------------------------------------
_pulse_setup_dry_run_mode() {
	local _dr_arg
	for _dr_arg in "$@"; do
		if [[ "$_dr_arg" == "--dry-run" ]]; then
			export PULSE_DRY_RUN=1
			break
		fi
	done
	unset _dr_arg
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_setup_canary_mode
#
# Phase 0 (GH#18790): --canary flag sets PULSE_CANARY_MODE=1 so main()
# can short-circuit after acquire_instance_lock. This exercises:
#   1. Script sourcing under set -euo pipefail (all top-level declarations)
#   2. _pulse_handle_self_check — the exact function GH#18770 broke
#   3. acquire_instance_lock — the next downstream function
# and exits 0 without entering the pulse loop, dispatching workers, or
# making any GitHub API calls.
#
# Scans "$@" for --canary (position-independent).
# Exit code: always 0
# ---------------------------------------------------------------------------
_pulse_setup_canary_mode() {
	local _can_arg
	for _can_arg in "$@"; do
		if [[ "$_can_arg" == "--canary" ]]; then
			export PULSE_CANARY_MODE=1
			break
		fi
	done
	unset _can_arg
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_setup_merge_only_mode (t21247, GH#21247)
#
# Phase 0: --merge-only flag sets PULSE_MERGE_ONLY=1 so main() can
# short-circuit into _pulse_run_merge_only() before any dispatch lifecycle
# phase (lock, session gate, dedup, preflight, LLM supervisor).
#
# Purpose: enables the dedicated merge plist
# (com.aidevops.aidevops-supervisor-merge, 60s interval) to invoke the full
# pulse bootstrap and call merge_ready_prs_all_repos() without interfering
# with the main dispatch cycle.
#
# Scans "$@" for --merge-only (position-independent).
# Exit code: always 0
# ---------------------------------------------------------------------------
_pulse_setup_merge_only_mode() {
	local _mo_arg
	for _mo_arg in "$@"; do
		if [[ "$_mo_arg" == "--merge-only" ]]; then
			export PULSE_MERGE_ONLY=1
			break
		fi
	done
	unset _mo_arg
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_run_merge_only (t21247, GH#21247)
#
# Standalone merge-pass execution path for --merge-only invocations.
# Acquires a SEPARATE lockdir (pulse-merge-instance.lock, distinct from the
# main pulse's pulse-wrapper.lockdir) so merge ticks and dispatch cycles can
# run concurrently without deadlock.
#
# Execution:
#   1. Acquire ~/.aidevops/locks/pulse-merge-instance.lock (mkdir-atomic).
#      If already held by a live process, skip silently ("already in flight").
#      Stale locks (dead PID) are reclaimed.
#   2. Override LOGFILE to pulse-merge.log so merge output is isolated from
#      the main pulse log.
#   3. Call merge_ready_prs_all_repos() (defined in pulse-merge.sh, sourced
#      above by the full bootstrap). All PULSE_* config vars are already set.
#   4. Write pulse-merge-routine-last-run timestamp so the in-cycle merge
#      pass in _pulse_run_deterministic_pipeline() can short-circuit when
#      this routine ran recently (defense-in-depth, same file as t2862).
#   5. Release lock via EXIT trap.
#
# Lock:  ~/.aidevops/locks/pulse-merge-instance.lock
# Log:   ~/.aidevops/logs/pulse-merge.log
# Stamp: ~/.aidevops/logs/pulse-merge-routine-last-run
#
# Exit code: always 0 (non-fatal; merge failures are logged and skipped)
# ---------------------------------------------------------------------------
_pulse_run_merge_only() {
	local _mo_lockdir="${HOME}/.aidevops/locks/pulse-merge-instance.lock"
	local _mo_log="${HOME}/.aidevops/logs/pulse-merge.log"
	local _mo_last_run="${HOME}/.aidevops/logs/pulse-merge-routine-last-run"

	mkdir -p "${HOME}/.aidevops/locks" "$(dirname "$_mo_log")" 2>/dev/null || true

	# --- Acquire separate lock (mkdir-atomic, same pattern as main pulse) ---
	if ! mkdir "$_mo_lockdir" 2>/dev/null; then
		# Lock exists — check if the holder is still alive.
		local _mo_pid
		_mo_pid=$(cat "${_mo_lockdir}/pid" 2>/dev/null || echo "")
		if [[ "$_mo_pid" =~ ^[0-9]+$ ]] && kill -0 "$_mo_pid" 2>/dev/null; then
			printf '[%s] pulse-wrapper --merge-only: merge_pass already in flight (PID %s), skipping\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$_mo_pid" >>"$_mo_log" 2>/dev/null || true
			return 0
		fi
		# Stale lock — reclaim and retry once.
		rm -rf "$_mo_lockdir" 2>/dev/null || true
		if ! mkdir "$_mo_lockdir" 2>/dev/null; then
			printf '[%s] pulse-wrapper --merge-only: could not acquire lock after stale reclaim, skipping\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" >>"$_mo_log" 2>/dev/null || true
			return 0
		fi
	fi
	printf '%s\n' "$$" >"${_mo_lockdir}/pid" 2>/dev/null || true

	# Release lock on exit — EXIT trap fires on normal exit, set -e abort, SIGTERM.
	# SIGKILL cannot be trapped; stale-PID check above handles that case.
	# shellcheck disable=SC2064  # intentional: expand _mo_lockdir at definition time
	trap "rm -rf '${_mo_lockdir}' 2>/dev/null || true" EXIT

	local _mo_ts
	_mo_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
	printf '[%s] pulse-wrapper --merge-only: starting merge pass (PID %s)\n' "$_mo_ts" "$$" >>"$_mo_log" 2>/dev/null || true

	# Override LOGFILE so merge_ready_prs_all_repos() logs to pulse-merge.log
	# rather than the main pulse log. Restore on exit via local variable — the
	# EXIT trap above fires after function return so the override is scoped here.
	local _mo_saved_logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	LOGFILE="$_mo_log"

	# t3068: drain the approval trigger file FIRST so just-approved PRs get
	# scoped per-PR merge attempts before the all-repos sweep. process_pr is
	# 10-20x cheaper than a full merge pass and gives the maintainer
	# sub-second feedback that the approval landed.
	_drain_merge_trigger_file_if_present >>"$_mo_log" 2>&1 || true

	# Call the merge entry point (defined in pulse-merge.sh, sourced above).
	# All PULSE_* configuration constants are already set by the full bootstrap.
	merge_ready_prs_all_repos >>"$_mo_log" 2>&1 || true

	# Restore LOGFILE for any teardown code that might run before EXIT trap fires.
	LOGFILE="$_mo_saved_logfile"

	# Write last-run timestamp — the in-cycle deterministic_merge_pass in
	# _pulse_run_deterministic_pipeline() reads this file and short-circuits
	# when a merge pass ran within the last 60s (defense-in-depth).
	date +%s >"$_mo_last_run" 2>/dev/null || true

	_mo_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
	printf '[%s] pulse-wrapper --merge-only: done\n' "$_mo_ts" >>"$_mo_log" 2>/dev/null || true

	return 0
}

# ---------------------------------------------------------------------------
# _drain_merge_trigger_file_if_present (t3068, GH#21806)
#
# Drains ~/.aidevops/cache/pulse-merge-trigger.txt — the marker file written
# by approval-helper.sh::_kick_pulse_after_approval after each successful
# crypto-approval. Each valid record first runs bounded exact-target NMR
# reconciliation, then processes any listed/linked PR via pulse-merge.sh's
# existing process_pr() entry point.
#
# File format (one record per line, tab-separated):
#   <slug>\t<num>\t<type>\t<iso8601_ts>
#
# - slug: owner/repo (validated via regex)
# - num:  PR or issue number (digits only). Every issue is reconciled directly;
#         issue records then resolve a linked PR for optional merge processing.
# - type: "issue" or "pr" (other values rejected)
# - ts:   UTC ISO-8601 timestamp (informational only, not parsed)
#
# Concurrency:
#   1. Atomic rotation — the marker is renamed (mv) to a per-PID processing
#      file before parsing. New approvals appended after the rename land in
#      a fresh marker that the next pulse cycle drains.
#   2. mv on the same filesystem is atomic. ENOENT (no marker) → no-op.
#
# Robustness:
#   - Malformed lines are logged and skipped — never abort the drain.
#   - Exact duplicate targets are ignored after their first valid record.
#   - Reconciliation/process_pr failures are logged and ignored — NMR remains
#     fail-closed and the scheduled Pulse fallback can retry later.
#
# Bypass: AIDEVOPS_SKIP_TRIGGER_DRAIN=1 (used by tests for negative cases).
#
# Exit code: always 0 (drain is best-effort).
# ---------------------------------------------------------------------------
_process_approval_trigger_record() {
	local slug="$1"
	local target_number="$2"
	local target_type="$3"
	local pr_number=""
	local record_rc=0

	# GH#28717: observe the post-approval Actions race before merge routing.
	# The target helper independently re-verifies current V2 authority/state.
	if declare -F _pulse_reconcile_verified_approval_target >/dev/null 2>&1; then
		_pulse_reconcile_verified_approval_target "$target_type" "$target_number" "$slug" || record_rc=1
	else
		printf '[%s] _drain_merge_trigger_file_if_present: target reconciliation unavailable for %s %s #%s — preserving fail-closed scheduled fallback\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$slug" "$target_type" "$target_number" \
			>>"${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" 2>/dev/null || true
		record_rc=1
	fi

	# Issue recovery never requires a linked PR. Resolve one only for optional
	# merge routing after the exact issue lifecycle has been reconciled.
	if [[ "$target_type" == "issue" ]]; then
		pr_number=$(_resolve_linked_pr_for_issue "$slug" "$target_number" 2>/dev/null || printf '')
		if [[ -z "$pr_number" ]]; then
			printf '[%s] _drain_merge_trigger_file_if_present: %s issue #%s has no linked open PR yet — merge routing skipped\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$slug" "$target_number" \
				>>"${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" 2>/dev/null || true
			return "$record_rc"
		fi
	else
		pr_number="$target_number"
	fi

	printf '[%s] _drain_merge_trigger_file_if_present: process_pr %s #%s (from approve %s #%s)\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$slug" "$pr_number" "$target_type" "$target_number" \
		>>"${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" 2>/dev/null || true
	process_pr "$slug" "$pr_number" || record_rc=1
	return "$record_rc"
}

_drain_merge_trigger_file_if_present() {
	if [[ "${AIDEVOPS_SKIP_TRIGGER_DRAIN:-0}" == "1" ]]; then
		return 0
	fi

	local trigger_file="${PULSE_MERGE_TRIGGER_FILE:-${HOME}/.aidevops/cache/pulse-merge-trigger.txt}"
	if [[ ! -f "$trigger_file" ]]; then
		return 0
	fi

	# Atomic rotation. Use a per-PID processing path so concurrent drains
	# (worst case: two pulse cycles fire close together) cannot collide.
	local processing_file
	processing_file="${trigger_file}.processing.$$"
	if ! mv -f "$trigger_file" "$processing_file" 2>/dev/null; then
		# Another drain rotated it first, or the file was removed mid-rename.
		# Either way, nothing for us to do — return cleanly.
		return 0
	fi

	# Verify process_pr is sourced. It comes from pulse-merge.sh which the
	# full bootstrap sources before main() runs. If it's missing the script
	# is mis-deployed; log and skip rather than calling an undefined function.
	if ! declare -F process_pr >/dev/null 2>&1; then
		printf '[%s] _drain_merge_trigger_file_if_present: process_pr not defined (pulse-merge.sh not sourced?) — restoring marker\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" \
			>>"${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" 2>/dev/null || true
		# Restore the marker so the next cycle gets another chance, rather
		# than silently dropping queued work.
		mv -f "$processing_file" "$trigger_file" 2>/dev/null || rm -f "$processing_file" 2>/dev/null
		return 0
	fi

	local _drain_count=0
	local _drain_failed=0
	local slug="" num="" type="" ts="" target_key=""
	local seen_targets="|"
	while IFS=$'\t' read -r slug num type ts || [[ -n "$slug" ]]; do
		# Skip blank lines and comment lines.
		[[ -z "$slug" || "${slug:0:1}" == "#" ]] && continue

		# Reject malformed records — log and continue, NEVER abort the drain.
		if ! [[ "$num" =~ ^[0-9]+$ ]]; then
			printf '[%s] _drain_merge_trigger_file_if_present: skipping malformed record (bad num=%q in %q)\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$num" "$slug" \
				>>"${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" 2>/dev/null || true
			continue
		fi
		if ! [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
			printf '[%s] _drain_merge_trigger_file_if_present: skipping malformed record (bad slug=%q)\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$slug" \
				>>"${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" 2>/dev/null || true
			continue
		fi
		if [[ "$type" != "issue" && "$type" != "pr" ]]; then
			printf '[%s] _drain_merge_trigger_file_if_present: skipping malformed record (bad type=%q)\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$type" \
				>>"${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" 2>/dev/null || true
			continue
		fi
		# ts is informational; use a sentinel so unused-variable lints stay quiet.
		: "${ts:-unknown}"
		target_key="|${type}:${slug}#${num}|"
		if [[ "$seen_targets" == *"$target_key"* ]]; then
			printf '[%s] _drain_merge_trigger_file_if_present: skipping duplicate target %s %s #%s\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$slug" "$type" "$num" \
				>>"${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" 2>/dev/null || true
			continue
		fi
		seen_targets="${seen_targets}${type}:${slug}#${num}|"
		if ! _process_approval_trigger_record "$slug" "$num" "$type"; then
			_drain_failed=$((_drain_failed + 1))
		fi
		_drain_count=$((_drain_count + 1))
	done <"$processing_file"

	rm -f "$processing_file" 2>/dev/null || true

	if [[ "$_drain_count" -gt 0 ]]; then
		printf '[%s] _drain_merge_trigger_file_if_present: handled %d exact target(s), %d non-success outcomes\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$_drain_count" "$_drain_failed" \
			>>"${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}" 2>/dev/null || true
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _resolve_linked_pr_for_issue (t3068)
#
# Given an issue number, return the number of the most recent OPEN PR that
# closes/resolves/fixes it (per GitHub close keywords in PR body) — or
# empty when no such PR exists.
#
# Args:
#   $1 - slug (owner/repo)
#   $2 - issue number
#
# Stdout: PR number on stdout (single line) or empty.
# Exit code: always 0 — empty stdout is the "not found" signal.
# ---------------------------------------------------------------------------
_resolve_linked_pr_for_issue() {
	local slug="${1:-}"
	local issue_num="${2:-}"

	[[ -n "$slug" && "$issue_num" =~ ^[0-9]+$ ]] || {
		printf ''
		return 0
	}

	# GitHub's GraphQL closing relationship is the authoritative way to find
	# PRs that will close this issue. Use a fixed query with response-owned cost;
	# native `gh issue view` hides GraphQL cost. The REST search alternative
	# (`gh search prs "linked:$issue_num"`) is rate-limited heavily and
	# returns false positives via mention.
	#
	# Fall back to a body-keyword search if GraphQL fails, mirroring the
	# extraction regex in pulse-merge.sh::_extract_linked_issue. Best-effort
	# everywhere — empty stdout means "skip this record, full merge pass
	# will catch it on next tick".
	local owner="${slug%%/*}"
	local name="${slug#*/}"
	local pr_num="" response="" reported_cost=""
	# shellcheck disable=SC2016
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="pulse-linked-pr-exact-cost" \
		_pwb_gh_read gh api graphql -F owner="$owner" -F name="$name" -F number="$issue_num" -f query='
			query($owner: String!, $name: String!, $number: Int!) {
				repository(owner: $owner, name: $name) {
					issue(number: $number) {
						closedByPullRequestsReferences(first: 100) {
							nodes { number state }
							pageInfo { hasNextPage }
						}
					}
				}
				rateLimit { cost }
			}
		' 2>/dev/null) || response=""
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || reported_cost=""
	if [[ "$reported_cost" =~ ^[1-9][0-9]*$ ]]; then
		pr_num=$(printf '%s' "$response" | jq -r '
			.data.repository.issue.closedByPullRequestsReferences
			| select(.pageInfo.hasNextPage == false)
			| [.nodes[]? | select(.state == "OPEN")]
			| .[0].number // empty
		' 2>/dev/null) || pr_num=""
	fi

	if [[ -z "$pr_num" ]]; then
		# Fallback: list recent open PRs in the repo and grep for the
		# closing keyword. Bounded to 30 PRs to avoid runaway lookups.
		# Prefer gh_pr_list when available so this fallback gets the shared
		# telemetry/cache/REST-routing behaviour during GraphQL budget pressure;
		# keep raw gh as a standalone-library fallback for isolated tests.
		# `gh` only forwards a `--jq` filter; `--arg` is a jq flag that gh
		# does NOT pass through. Pipe to jq directly so `--arg n` works
		# and the issue number stays as data, not interpolated regex.
		local pr_list_json=""
		if declare -F gh_pr_list >/dev/null 2>&1; then
			pr_list_json=$(gh_pr_list --repo "$slug" --state open --limit 30 \
				--json number,body 2>/dev/null) || pr_list_json="[]"
		else
			pr_list_json=$(gh pr list --repo "$slug" --state open --limit 30 \
				--json number,body 2>/dev/null) || pr_list_json="[]"
		fi
		[[ -n "$pr_list_json" ]] || pr_list_json="[]"
		# shellcheck disable=SC2016 disable=SC2034
		pr_num=$(printf '%s' "$pr_list_json" | jq -r --arg n "$issue_num" \
				'.[] | select(.body | test("(?i)(close[ds]?|fix(es|ed)?|resolve[ds]?)\\s+#" + $n + "\\b")) | .number' \
				2>/dev/null | head -1) || pr_num=""
	fi

	if [[ "$pr_num" =~ ^[0-9]+$ ]]; then
		printf '%s' "$pr_num"
	else
		printf ''
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _detect_invocation_source (GH#20580)
#
# Detects how pulse-wrapper.sh was invoked. Writes the detected source into
# the caller-scoped variable named by the first argument (default:
# _invocation_source). Order: most-specific check first.
#
# Sources:
#   lifecycle-helper  AIDEVOPS_PULSE_SOURCE=lifecycle-helper (set by _start())
#   launchd           PPID=1 or parent command contains "launchd"
#   cron              parent command contains "cron"
#   manual            stdin is a TTY or PULSE_MANUAL=1
#   unknown           none of the above
# ---------------------------------------------------------------------------
_detect_invocation_source() {
	local _parent_cmd
	_parent_cmd=$(ps -p "$PPID" -o comm= 2>/dev/null || printf 'unknown')

	if [[ "${AIDEVOPS_PULSE_SOURCE:-}" == "lifecycle-helper" ]]; then
		_invocation_source="lifecycle-helper"
	elif [[ "$PPID" -eq 1 ]] || [[ "$_parent_cmd" == *"launchd"* ]]; then
		_invocation_source="launchd"
	elif [[ "$_parent_cmd" == *"cron"* ]]; then
		_invocation_source="cron"
	elif [[ "${PULSE_MANUAL:-0}" == "1" ]] || [[ -t 0 ]]; then
		_invocation_source="manual"
	else
		_invocation_source="unknown"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _record_invocation_source (GH#20580)
#
# Logs the invocation source to the pulse log and increments the per-source
# integer counter in pulse-stats.json under the top-level
# "invocation_sources" object, e.g.:
#   {"counters":{...},"invocation_sources":{"launchd":5,"manual":1,...}}
#
# Args:
#   $1 - invocation source string (launchd/cron/manual/lifecycle-helper/unknown)
#
# Non-fatal: any jq or file failure is ignored — never blocks the pulse.
# ---------------------------------------------------------------------------
_record_invocation_source() {
	local source="${1:-unknown}"
	local stats_file="${PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
	local log_dest="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

	# Log entry (ISO-8601 UTC to match pulse-logging.sh conventions)
	local _ts="" _pcmd=""
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	_pcmd=$(ps -p "$PPID" -o comm= 2>/dev/null || printf 'unknown')
	printf '[%s] pulse-wrapper invoked: pid=%d ppid=%d source=%s parent_cmd=%s\n' \
		"$_ts" "$$" "$PPID" "$source" "$_pcmd" \
		>>"$log_dest" 2>/dev/null || true

	# Increment invocation_sources.{source} as a plain integer counter.
	# Uses tmp-file + mv for atomicity (same pattern as pulse_stats_increment).
	local _dir="" _tmp=""
	_dir="$(dirname "$stats_file")"
	[[ -d "$_dir" ]] || mkdir -p "$_dir" 2>/dev/null || return 0
	[[ -f "$stats_file" ]] || printf '{"counters":{}}\n' >"$stats_file" 2>/dev/null || return 0

	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	_tmp=$(mktemp "${TMPDIR:-/tmp}/pulse-stats-src-XXXXXX") || return 0
	jq --arg src "$source" \
		'.invocation_sources[$src] = ((.invocation_sources[$src] // 0) + 1)' \
		"$stats_file" >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 0; }
	mv "$_tmp" "$stats_file" 2>/dev/null || rm -f "$_tmp"
	return 0
}
