#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Simplification — Orchestration & CI Nesting
# =============================================================================
# Dedup cleanup, CI nesting threshold proximity, state refresh, per-language
# scan adapters, sweep/ratchet checks, and the weekly complexity scan
# orchestrator. Extracted from pulse-simplification.sh as part of the
# file-size-debt split (GH#21306, parent #21146).
#
# Usage: source "${SCRIPT_DIR}/pulse-simplification-orchestration.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, gh_issue_list, gh_create_issue, etc.)
#   - pulse-simplification-scan.sh (_pulse_enabled_repo_slugs,
#     _complexity_scan_check_interval, _complexity_scan_tree_changed,
#     _complexity_llm_sweep_due, _complexity_run_llm_sweep,
#     _complexity_scan_find_repo, _complexity_scan_collect_violations,
#     _complexity_scan_permission_gate, _complexity_scan_pull_latest)
#   - pulse-simplification-issues.sh (_complexity_scan_create_issues,
#     _complexity_scan_create_md_issues, _complexity_scan_collect_md_violations)
#   - pulse-simplification-state.sh (_simplification_state_prune,
#     _simplification_state_refresh, _simplification_state_backfill_closed,
#     _simplification_state_push, _simplification_close_spurious_requeue_issues)
#   - worker-lifecycle-common.sh (get_repo_role_by_slug)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_SIMPLIFICATION_ORCHESTRATION_LIB_LOADED:-}" ]] && return 0
_PULSE_SIMPLIFICATION_ORCHESTRATION_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

#######################################
# Close duplicate function-complexity-debt issues across pulse-enabled repos.
#
# For each repo, fetches open function-complexity-debt issues and groups by
# file path extracted from the title. When multiple issues exist for the
# same file, keeps the newest and closes the rest as "not planned".
#
# Rate-limited: closes at most DEDUP_CLEANUP_BATCH_SIZE issues per run
# and runs at most once per DEDUP_CLEANUP_INTERVAL (default: daily).
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
run_simplification_dedup_cleanup() {
	local now_epoch
	now_epoch=$(date +%s)

	# Interval guard
	if [[ -f "$DEDUP_CLEANUP_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$DEDUP_CLEANUP_LAST_RUN" 2>/dev/null || echo "0")
		[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
		local elapsed=$((now_epoch - last_run))
		if [[ "$elapsed" -lt "$DEDUP_CLEANUP_INTERVAL" ]]; then
			return 0
		fi
	fi

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local repo_slugs
	repo_slugs=$(_pulse_enabled_repo_slugs "$repos_json") || repo_slugs=""
	[[ -z "$repo_slugs" ]] && return 0

	local total_closed=0
	local batch_limit="$DEDUP_CLEANUP_BATCH_SIZE"

	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		[[ "$total_closed" -ge "$batch_limit" ]] && break
		# t2145: skip repos where the user is a contributor — simplification
		# dedup cleanup is a maintainer-only operation.
		local _dedup_role
		_dedup_role=$(get_repo_role_by_slug "$slug")
		[[ "$_dedup_role" != "maintainer" ]] && continue

		# Use jq to extract file paths from titles and find duplicates server-side.
		# Strategy: fetch issues sorted by number ascending (oldest first), extract
		# file path from title via jq regex, group by path, and collect all but the
		# last (newest) issue number from each group as duplicates to close.
		local dupe_numbers
		dupe_numbers=$(gh_issue_list --repo "$slug" \
			--label "function-complexity-debt" --state open \
			--limit 500 --json number,title \
			--jq '
				sort_by(.number) |
				[.[] | {
					number,
					file: (
						(.title | capture("\\((?<p>[^,)]+\\.(sh|md|py|ts|js))[,)]") // null | .p) //
						(.title | capture("in (?<p>[^ ]+\\.(sh|md|py|ts|js))") // null | .p) //
						null
					)
				}] |
				[.[] | select(.file != null)] |
				group_by(.file) |
				[.[] | select(length > 1) | .[:-1][].number] |
				.[]
			' 2>/dev/null) || dupe_numbers=""

		[[ -z "$dupe_numbers" ]] && continue

		while IFS= read -r dupe_num; do
			[[ -z "$dupe_num" ]] && continue
			[[ "$total_closed" -ge "$batch_limit" ]] && break
			if gh issue close "$dupe_num" --repo "$slug" --reason "not planned" \
				--comment "Auto-closing duplicate: another function-complexity-debt issue exists for this file. Keeping the newest." \
				>/dev/null 2>&1; then
				total_closed=$((total_closed + 1))
			fi
		done <<<"$dupe_numbers"
	done <<<"$repo_slugs"

	echo "$now_epoch" >"$DEDUP_CLEANUP_LAST_RUN"
	if [[ "$total_closed" -gt 0 ]]; then
		echo "[pulse-wrapper] Dedup cleanup: closed ${total_closed} duplicate function-complexity-debt issue(s)" >>"$LOGFILE"
	fi
	return 0
}

# Read the nesting depth CI threshold from the config file.
# Arguments: $1 - aidevops_path
# Output: threshold integer to stdout (defaults to 260 if config unreadable)
# Returns: 0 always
_check_ci_nesting_read_threshold() {
	local aidevops_path="$1"
	local threshold=260
	local conf_file="${aidevops_path}/.agents/configs/complexity-thresholds.conf"
	if [[ -f "$conf_file" ]]; then
		local val
		val=$(grep '^NESTING_DEPTH_THRESHOLD=' "$conf_file" | cut -d= -f2 || true)
		if [[ -n "$val" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
			threshold="$val"
		fi
	fi
	printf '%s' "$threshold"
	return 0
}

# Count shell files with nesting depth > 8 (CI metric, global counter, no function resets).
# Arguments: $1 - aidevops_path
# Output: violation count to stdout
# Returns: 0 always (returns 0 and outputs 0 when no shell files found)
_check_ci_nesting_count_violations() {
	local aidevops_path="$1"
	local violations=0
	local lint_files
	lint_files=$(git -C "$aidevops_path" ls-files '*.sh' 2>/dev/null |
		grep -v 'node_modules\|vendor\|\.git' |
		sed "s|^|${aidevops_path}/|" || true)
	if [[ -z "$lint_files" ]]; then
		printf '0'
		return 0
	fi
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		[[ -f "$file" ]] || continue
		local max_depth
		max_depth=$(awk '
			BEGIN { depth=0; max_depth=0 }
			/^[[:space:]]*#/ { next }
			/[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; if(depth>max_depth) max_depth=depth }
			/[[:space:]]*(fi|done|esac)[[:space:]]*$/ || /^[[:space:]]*(fi|done|esac)$/ { if(depth>0) depth-- }
			END { print max_depth }
		' "$file" 2>/dev/null) || max_depth=0
		if [[ "$max_depth" -gt 8 ]]; then
			violations=$((violations + 1))
		fi
	done <<<"$lint_files"
	printf '%s' "$violations"
	return 0
}

# Build the CI nesting threshold proximity warning issue body with signature footer.
# Arguments: $1 - violations, $2 - threshold, $3 - headroom, $4 - buffer
# Output: full body to stdout
# Returns: 0 always
_check_ci_nesting_build_issue_body() {
	local violations="$1"
	local threshold="$2"
	local headroom="$3"
	local buffer="$4"

	local issue_body
	issue_body="## CI Nesting Threshold Proximity Warning

The shell nesting depth violation count is within **${buffer}** of the CI threshold.

- **Current violations**: ${violations}
- **CI threshold**: ${threshold} (from \`.agents/configs/complexity-thresholds.conf\`)
- **Headroom remaining**: ${headroom}

### Why this matters

The \`Complexity Analysis\` CI check fails when nesting depth violations exceed the threshold. When PRs add new scripts with deep nesting, they push the count over the threshold and block all open PRs. This happened 6 times in a short window (GH#17808).

### Recommended actions

1. Reduce nesting depth in the highest-depth scripts (run \`complexity-scan-helper.sh scan\` to identify them)
2. Or bump the threshold in \`.agents/configs/complexity-thresholds.conf\` with a documented rationale

### Files to check

Run locally to see current violators:
\`\`\`bash
git ls-files '*.sh' | while read -r f; do
  d=\$(awk 'BEGIN{d=0;m=0} /^[[:space:]]*#/{next} /[[:space:]]*(if|for|while|until|case)[[:space:]]/{d++;if(d>m)m=d} /[[:space:]]*(fi|done|esac)[[:space:]]*\$||/^[[:space:]]*(fi|done|esac)\$/{if(d>0)d--} END{print m}' \"\$f\")
  [ \"\$d\" -gt 8 ] && echo \"\$d \$f\"
done | sort -rn | head -20
\`\`\`"

	# Append signature footer
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	printf '%s%s' "$issue_body" "$sig_footer"
	return 0
}

#######################################
# Check if nesting depth violation count is approaching the CI threshold.
# Creates a warning issue when within the buffer to prevent CI regressions
# before they happen (GH#17808 — regression guard for Complexity Analysis CI).
#
# The CI check uses a global awk counter (not per-function) that counts all
# if/for/while/until/case across the entire file without resetting at function
# boundaries. This function replicates that logic to detect proximity.
#
# Arguments:
#   $1 - aidevops_path (repo root)
#   $2 - aidevops_slug (owner/repo)
#   $3 - maintainer (GitHub login)
# Returns: 0 always (best-effort)
#######################################
_check_ci_nesting_threshold_proximity() {
	# t2171 / GH#19585: retired. The proximity scanner was filing duplicate
	# "CI nesting threshold proximity: N/M violations" issues every ~45min
	# (observed: GH#19526-19582, 11 iterations in 7h) because the ratchet-down
	# + CI-bump loop kept oscillating the threshold just inside the buffer.
	#
	# Replacement: the nesting-depth step in code-quality.yml now calls
	# complexity-regression-helper.sh with --metric nesting-depth, blocking
	# only on NEW violations (set difference) and treating the total count
	# as a non-blocking warning. No threshold to tune, no treadmill to ratchet.
	#
	# Helper functions (_check_ci_nesting_read_threshold, _count_violations,
	# _build_issue_body) are preserved so the characterization test at
	# tests/test-pulse-wrapper-characterization.sh:208 still finds them.
	local _unused_aidevops_path="${1:-}"
	local _unused_aidevops_slug="${2:-}"
	local _unused_maintainer="${3:-}"
	if [[ -n "${LOGFILE:-}" ]]; then
		echo "[pulse-wrapper] _check_ci_nesting_threshold_proximity: retired (t2171/GH#19585) — CI regression gate replaces this" >>"$LOGFILE"
	fi
	return 0
}

# _complexity_scan_state_refresh — prune/refresh/backfill simplification state (t1754, t1855, t2001)
# Updates state and publishes it checkout-free if any entries changed.
_complexity_scan_state_refresh() {
	local aidevops_path="$1"
	local state_file="$2"
	local aidevops_slug="$3"

	# Phase 1: Refresh simplification state hashes against current main (t1754).
	# Replaces the previous timeline-API-based backfill which was fragile and
	# frequently missed state updates, causing infinite recheck loops.
	# Now simply recomputes git hash-object for every file in state and updates
	# any that differ. This catches all modifications (simplification PRs,
	# feature work, refactors) without depending on GitHub API link resolution.
	local state_updated=false

	# Prune stale entries (files moved/renamed/deleted since last scan)
	local pruned_count
	pruned_count=$(_simplification_state_prune "$aidevops_path" "$state_file")
	if [[ "$pruned_count" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: pruned $pruned_count stale entries (files no longer exist)" >>"$LOGFILE"
		state_updated=true
	fi

	# Refresh all hashes — O(n) git hash-object calls, no API requests (t1754)
	local refreshed_count
	refreshed_count=$(_simplification_state_refresh "$aidevops_path" "$state_file")
	if [[ "$refreshed_count" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: refreshed $refreshed_count hashes (files changed since last scan)" >>"$LOGFILE"
		state_updated=true
	fi

	# Backfill state for recently closed issues (t1855).
	# _simplification_state_record() was defined but never called — workers
	# complete simplification and close issues, but the state file was never
	# updated. This backfill detects closed issues and records their file hashes
	# so the scanner knows they're done and doesn't create duplicate issues.
	local backfilled_count
	backfilled_count=$(_simplification_state_backfill_closed "$aidevops_path" "$state_file" "$aidevops_slug")
	if [[ "${backfilled_count:-0}" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: backfilled $backfilled_count entries from recently closed issues (t1855)" >>"$LOGFILE"
		state_updated=true
	fi

	# Defensive auto-close sweep for spurious "0 smells remaining" re-queue
	# issues (GH#18795). Closes any stragglers from the pre-PR-#18848 bug
	# and self-heals any future regression of the same class. Verifies the
	# file is genuinely clean via Qlty before closing — never closes a
	# legitimate finding even if its title coincidentally matches the
	# spurious pattern. No-op when Qlty is not installed.
	local spurious_closed
	spurious_closed=$(_simplification_close_spurious_requeue_issues "$aidevops_path" "$aidevops_slug")
	if [[ "${spurious_closed:-0}" -gt 0 ]]; then
		echo "[pulse-wrapper] simplification-state: closed $spurious_closed spurious zero-smell re-queue issues (GH#18795)" >>"$LOGFILE"
	fi

	# Publish state without staging or committing in the canonical checkout.
	if [[ "$state_updated" == true ]]; then
		_simplification_state_push "$aidevops_path" "$state_file"
	fi
	return 0
}

# Create one private registry snapshot for refresh, publication, and same-cycle scans.
_complexity_scan_state_snapshot_create() {
	local aidevops_path="$1"
	local source_file="${aidevops_path}/.agents/configs/simplification-state.json"
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local temp_dir=""
	[[ -f "$source_file" && ! -L "$source_file" ]] || return 1
	mkdir -p "$temp_root" || return 1
	temp_dir=$(umask 077 && mktemp -d "${temp_root%/}/simplification-state.XXXXXX") || return 1
	cp "$source_file" "${temp_dir}/simplification-state.json" || {
		rmdir "$temp_dir" 2>/dev/null || true
		return 1
	}
	printf '%s\n' "${temp_dir}/simplification-state.json"
	return 0
}

_complexity_scan_state_snapshot_cleanup() {
	local state_file="$1"
	local state_dir="${state_file%/*}"
	[[ "${state_file##*/}" == "simplification-state.json" ]] || return 1
	rm -f "$state_file" || return 1
	rmdir "$state_dir" 2>/dev/null || return 1
	return 0
}

_complexity_scan_run_isolated_state_cycle() {
	local scan_helper="$1"
	local aidevops_path="$2"
	local repos_json="$3"
	local aidevops_slug="$4"
	local state_file=""
	local cycle_rc=0
	state_file=$(_complexity_scan_state_snapshot_create "$aidevops_path") || return 1
	_complexity_scan_state_refresh "$aidevops_path" "$state_file" "$aidevops_slug" || cycle_rc=$?
	if [[ -x "$scan_helper" ]]; then
		_complexity_scan_lang_shell "$scan_helper" "$aidevops_path" "$state_file" "$repos_json" "$aidevops_slug" || cycle_rc=$?
		_complexity_scan_lang_md "$scan_helper" "$aidevops_path" "$state_file" "$repos_json" "$aidevops_slug" || cycle_rc=$?
	fi
	_complexity_scan_state_snapshot_cleanup "$state_file" || cycle_rc=1
	return "$cycle_rc"
}

# _complexity_scan_lang_shell — shell-file complexity scan via helper (Phase 2, t2001)
# Converts helper output to issue-creation format and calls _complexity_scan_create_issues.
_complexity_scan_lang_shell() {
	local scan_helper="$1"
	local aidevops_path="$2"
	local state_file="$3"
	local repos_json="$4"
	local aidevops_slug="$5"

	# Shell files — convert helper output to existing issue creation format
	# Helper outputs: status|file_path|line_count|func_count|long_func_count|max_nesting|file_type
	# Issue creation expects: file_path|violation_count
	local sh_scan_output
	sh_scan_output=$("$scan_helper" scan "$aidevops_path" --type sh --state-file "$state_file" 2>>"$LOGFILE") || true
	if [[ -n "$sh_scan_output" ]]; then
		local sh_results=""
		while IFS='|' read -r _status file_path _lines _funcs long_funcs _nesting _type; do
			[[ -n "$file_path" ]] || continue
			sh_results="${sh_results}${file_path}|${long_funcs}"$'\n'
		done <<<"$sh_scan_output"
		if [[ -n "$sh_results" ]]; then
			sh_results=$(printf '%s' "$sh_results" | sort -t'|' -k2 -rn)
			_complexity_scan_create_issues "$sh_results" "$repos_json" "$aidevops_slug"
		fi
	fi
	return 0
}

# _complexity_scan_lang_md — markdown-file complexity scan via helper (Phase 3, t2001)
# Converts helper output to issue-creation format and calls _complexity_scan_create_md_issues.
_complexity_scan_lang_md() {
	local scan_helper="$1"
	local aidevops_path="$2"
	local state_file="$3"
	local repos_json="$4"
	local aidevops_slug="$5"

	# Markdown files — convert helper output to existing issue creation format
	# Helper outputs: status|file_path|line_count|func_count|long_func_count|max_nesting|file_type
	# Issue creation expects: file_path|line_count
	local md_scan_output
	md_scan_output=$("$scan_helper" scan "$aidevops_path" --type md --state-file "$state_file" 2>>"$LOGFILE") || true
	if [[ -n "$md_scan_output" ]]; then
		local md_results=""
		while IFS='|' read -r _status file_path lines _funcs _long_funcs _nesting _type; do
			[[ -n "$file_path" ]] || continue
			md_results="${md_results}${file_path}|${lines}"$'\n'
		done <<<"$md_scan_output"
		if [[ -n "$md_results" ]]; then
			md_results=$(printf '%s' "$md_results" | sort -t'|' -k2 -rn)
			_complexity_scan_create_md_issues "$md_results" "$repos_json" "$aidevops_slug"
		fi
	fi
	return 0
}

# _complexity_scan_sweep_check — LLM sweep check and issue creation (Phase 4, t2001)
# If simplification debt stalled, creates a sweep issue for LLM review (GH#15285).
_complexity_scan_sweep_check() {
	local scan_helper="$1"
	local aidevops_slug="$2"

	# Phase 4: Daily LLM sweep check (GH#15285)
	# If simplification debt hasn't decreased in 6h, flag for LLM review.
	# The sweep itself runs as a separate worker dispatch, not inline.
	local sweep_result
	sweep_result=$("$scan_helper" sweep-check "$aidevops_slug" 2>>"$LOGFILE") || sweep_result=""
	if [[ "$sweep_result" == needed* ]]; then
		echo "[pulse-wrapper] LLM sweep triggered: ${sweep_result}" >>"$LOGFILE"
		# Create a one-off issue for the LLM sweep if none exists (t1855: check
		# both title patterns). Sweep reviews are meta work and intentionally do
		# not carry function-complexity-debt, so dedup by title rather than label.
		local sweep_issue_exists
		sweep_issue_exists=$(gh_issue_list --repo "$aidevops_slug" \
			--state open \
			--search "in:title \"simplification debt stalled\" OR in:title \"LLM complexity sweep\"" \
			--json number --jq 'length' 2>/dev/null) || sweep_issue_exists="0"
		[[ "$sweep_issue_exists" =~ ^[0-9]+$ ]] || sweep_issue_exists="0"
		if [[ "${sweep_issue_exists:-0}" -eq 0 ]]; then
			local sweep_reason
			sweep_reason=$(echo "$sweep_result" | cut -d'|' -f2)
			gh_create_issue --repo "$aidevops_slug" \
				--title "LLM complexity sweep: review stalled function-complexity debt" \
				--label "quality-debt" --label "auto-dispatch" --label "tier:thinking" --label "worker-ready" \
				--body "## Daily LLM sweep (automated, GH#15285)

**Trigger:** ${sweep_reason}

The deterministic complexity scan detected that function-complexity debt has not decreased in the configured stall window and recent-closure throughput is zero. An LLM-powered deep review is needed to:

1. Identify why existing function-complexity-debt issues are not being resolved
2. Re-prioritize the backlog based on actual impact
3. Close issues that are no longer relevant (files deleted, already simplified)
4. Suggest new decomposition strategies for stuck files
5. Check pulse logs for \`local_capacity_gate\`; if present, verify worktree cleanup is live and reducing the affected repo below \`AIDEVOPS_MAX_WORKTREES\` before changing safety caps

### Scope

Review all open \`function-complexity-debt\` issues and the current \`simplification-state.json\`. Focus on the top 10 largest files first.

### Worker Guidance

- Target files: \`.agents/scripts/pulse-simplification-scan.sh\`, \`.agents/scripts/complexity-scan-helper.sh\`, \`.agents/scripts/pulse-dispatch-engine.sh\`, and matching tests under \`.agents/scripts/tests/\`.
- Reference pattern: keep sweep creation aligned with \`complexity-scan-helper.sh sweep-check\`, including the recent-closure throughput guard before declaring a stall.
- Do not close debt issues solely because they are old. Close only when current repo evidence shows the file is deleted, already simplified, or duplicated.
- Verification: run \`.agents/scripts/tests/test-pulse-wrapper-complexity-scan.sh\` plus ShellCheck on changed shell scripts." >/dev/null 2>&1 || true
			"$scan_helper" sweep-done 2>>"$LOGFILE" || true
		fi
	fi
	return 0
}

# _complexity_scan_ratchet_check — retired in t2171 (GH#19585).
#
# Historical purpose (Phase 5, t1913): file a chore issue to ratchet-down
# complexity thresholds when violations dropped >=5 below the current value.
# In practice, the ratchet-check + CI-bump-up cycle formed a treadmill: each
# cleanup PR triggered a ratchet-down PR, each CI near-miss triggered a
# threshold bump, and the two oscillated forever (observed: BASH32 threshold
# bouncing 74↔78, NESTING threshold cycling 285→290→285).
#
# Replacement: code-quality.yml now runs complexity-regression-helper.sh with
# per-metric regression gates (function-complexity, nesting-depth, file-size,
# bash32-compat). PRs fail only for NEW violations; totals are non-blocking
# warnings. Thresholds in complexity-thresholds.conf remain as targets for
# the simplification routine but are no longer part of the CI gate contract.
_complexity_scan_ratchet_check() {
	local _unused_scan_helper="${1:-}"
	local _unused_aidevops_path="${2:-}"
	local _unused_aidevops_slug="${3:-}"
	if [[ -n "${LOGFILE:-}" ]]; then
		echo "[pulse-wrapper] _complexity_scan_ratchet_check: retired (t2171/GH#19585) — per-metric regression gates replace the threshold treadmill" >>"$LOGFILE"
	fi
	return 0
}

# run_weekly_complexity_scan — orchestrator: interval check → auth gate → scan phases (t2001)
# Refactored in Phase 12 (t2001): extracted per-language and per-phase helpers to reduce
# this function from 287 lines to a clean orchestrator. New helpers:
#   _complexity_scan_permission_gate, _complexity_scan_pull_latest,
#   _complexity_scan_state_refresh, _complexity_scan_lang_shell,
#   _complexity_scan_lang_md, _complexity_scan_sweep_check,
#   _complexity_scan_ratchet_check
run_weekly_complexity_scan() {
	local repos_json="$REPOS_JSON"
	local aidevops_slug="marcusquinn/aidevops"

	# t2145: complexity scan creates function-complexity-debt issues — maintainer-only.
	local _cs_role
	_cs_role=$(get_repo_role_by_slug "$aidevops_slug")
	if [[ "$_cs_role" != "maintainer" ]]; then
		echo "[pulse-wrapper] Complexity scan skipped: role=$_cs_role for $aidevops_slug (t2145)" >>"$LOGFILE"
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s)

	_complexity_scan_check_interval "$now_epoch" || return 0

	_complexity_scan_permission_gate "$aidevops_slug" || return 0

	local aidevops_path
	aidevops_path=$(_complexity_scan_find_repo "$repos_json" "$aidevops_slug" "$now_epoch") || return 0

	_complexity_scan_pull_latest "$aidevops_path" || return 0

	# GH#15285: O(1) tree hash check — skip file iteration if no tracked files changed.
	local tree_changed=true
	if ! _complexity_scan_tree_changed "$aidevops_path"; then
		tree_changed=false
	fi

	local maintainer
	maintainer=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null)
	[[ -z "$maintainer" ]] && maintainer=$(printf '%s' "$aidevops_slug" | cut -d/ -f1)

	# LLM sweep + CI proximity guard run independently of tree change (GH#15285, GH#17808).
	if _complexity_llm_sweep_due "$now_epoch" "$aidevops_slug"; then
		_complexity_run_llm_sweep "$aidevops_slug" "$now_epoch" "$maintainer"
	fi
	_check_ci_nesting_threshold_proximity "$aidevops_path" "$aidevops_slug" "$maintainer" || true

	if [[ "$tree_changed" == false ]]; then
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 0
	fi

	echo "[pulse-wrapper] Running deterministic complexity scan (GH#5628, GH#15285)..." >>"$LOGFILE"

	# Ensure recheck label exists (used when a simplified file changes)
	gh label create "recheck-simplicity" --repo "$aidevops_slug" --color "D4C5F9" \
		--description "File changed since last simplification and needs recheck" --force 2>/dev/null || true

	local scan_helper="${SCRIPT_DIR}/complexity-scan-helper.sh"
	_complexity_scan_run_isolated_state_cycle "$scan_helper" "$aidevops_path" "$repos_json" "$aidevops_slug" || true
	if [[ -x "$scan_helper" ]]; then
		_complexity_scan_sweep_check "$scan_helper" "$aidevops_slug"
		_complexity_scan_ratchet_check "$scan_helper" "$aidevops_path" "$aidevops_slug"
	else
		# Fallback to inline scan if helper not available
		echo "[pulse-wrapper] complexity-scan-helper.sh not found, using inline scan" >>"$LOGFILE"
		local sh_results
		sh_results=$(_complexity_scan_collect_violations "$aidevops_path" "$now_epoch") || true
		if [[ -n "$sh_results" ]]; then
			sh_results=$(printf '%s' "$sh_results" | sort -t'|' -k2 -rn)
			_complexity_scan_create_issues "$sh_results" "$repos_json" "$aidevops_slug"
		fi
		local md_results
		md_results=$(_complexity_scan_collect_md_violations "$aidevops_path") || true
		if [[ -n "$md_results" ]]; then
			_complexity_scan_create_md_issues "$md_results" "$repos_json" "$aidevops_slug"
		fi
	fi

	printf '%s\n' "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
	return 0
}
