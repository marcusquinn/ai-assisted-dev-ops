#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Simplification — Core Scanning Infrastructure
# =============================================================================
# Interval checks, repo discovery, tree-hash change detection, LLM sweep
# logic, violation collection, issue dedup, permission gate, and git pull
# helpers. Extracted from pulse-simplification.sh as part of the
# file-size-debt split (GH#21306, parent #21146).
#
# Usage: source "${SCRIPT_DIR}/pulse-simplification-scan.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, gh_issue_list, gh_create_issue, timeout_sec, etc.)
#   - worker-lifecycle-common.sh (get_repo_role_by_slug)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_SIMPLIFICATION_SCAN_LIB_LOADED:-}" ]] && return 0
_PULSE_SIMPLIFICATION_SCAN_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

# Check if the complexity scan interval has elapsed.
# Arguments: $1 - now_epoch (current epoch seconds)
# Returns: 0 if scan is due, 1 if not yet due
_complexity_scan_check_interval() {
	local now_epoch="$1"
	if [[ ! -f "$COMPLEXITY_SCAN_LAST_RUN" ]]; then
		return 0
	fi
	local last_run
	last_run=$(cat "$COMPLEXITY_SCAN_LAST_RUN" 2>/dev/null || echo "0")
	[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
	local elapsed=$((now_epoch - last_run))
	if [[ "$elapsed" -lt "$COMPLEXITY_SCAN_INTERVAL" ]]; then
		local remaining=$(((COMPLEXITY_SCAN_INTERVAL - elapsed) / 3600))
		echo "[pulse-wrapper] Complexity scan not due yet (${remaining}h remaining)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

# Emit the list of pulse-enabled, non-local-only slugs from the given
# repos.json path, one per line. Extracted from _run_post_merge_review_scanner
# et al. so new scanner wrappers don't duplicate the jq filter (t2442).
# Arguments: $1 - repos_json path
# Outputs: newline-separated slugs on stdout
_pulse_enabled_repo_slugs() {
	local repos_json="$1"
	[[ -f "$repos_json" ]] || return 0
	jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null || true
	return 0
}

# Compute a deterministic tree hash for the files the complexity scan cares about.
# Uses git ls-tree to hash the current state of .agents/ *.sh and *.md files.
# This is O(1) — a single git command, not per-file iteration.
# Arguments: $1 - repo_path
# Outputs: tree hash string to stdout (empty on failure)
_complexity_scan_tree_hash() {
	local repo_path="$1"
	# Hash the tree of .agents/ tracked files — covers both .sh and .md targets.
	# git ls-tree -r HEAD outputs blob hashes + paths; piping through sha256sum
	# gives a single stable hash that changes iff any tracked file changes.
	# Capture output first: sha256sum always produces output (even for empty input),
	# so an empty-check on the pipeline result is unreliable (GH#18555).
	local tree_data
	tree_data=$(git -C "$repo_path" ls-tree -r HEAD -- .agents/ 2>/dev/null)
	if [[ -z "$tree_data" ]]; then
		return 0
	fi
	printf '%s\n' "$tree_data" | awk '{print $3, $4}' | sha256sum 2>/dev/null | awk '{print $1}' || true
	return 0
}

# Check whether the repo tree has changed since the last complexity scan.
# Compares current tree hash against the cached value in COMPLEXITY_SCAN_TREE_HASH_FILE.
# Arguments: $1 - repo_path
# Returns: 0 if changed (scan needed), 1 if unchanged (skip)
# Side effect: updates COMPLEXITY_SCAN_TREE_HASH_FILE when changed
_complexity_scan_tree_changed() {
	local repo_path="$1"
	local current_hash
	current_hash=$(_complexity_scan_tree_hash "$repo_path")
	if [[ -z "$current_hash" ]]; then
		# Cannot compute hash — proceed with scan to be safe
		return 0
	fi
	local cached_hash=""
	if [[ -f "$COMPLEXITY_SCAN_TREE_HASH_FILE" ]]; then
		cached_hash=$(cat "$COMPLEXITY_SCAN_TREE_HASH_FILE" 2>/dev/null || true)
	fi
	if [[ "$current_hash" == "$cached_hash" ]]; then
		echo "[pulse-wrapper] Complexity scan: tree unchanged since last scan — skipping file iteration" >>"$LOGFILE"
		return 1
	fi
	# Tree changed — update cache and signal scan needed
	printf '%s\n' "$current_hash" >"$COMPLEXITY_SCAN_TREE_HASH_FILE"
	return 0
}

# Run a fixed GraphQL scalar query with operation-owned response cost.
# Arguments: $1 - route decision, $2 - query, $3 - jq scalar filter
# Output: non-negative integer scalar
_complexity_graphql_scalar_exact() {
	local route_decision="$1"
	local query="$2"
	local jq_filter="$3"
	local response="" reported_cost="" value=""

	[[ "$route_decision" == pulse-complexity-*-exact-cost ]] || return 1
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="$route_decision" \
		gh api graphql -f query="$query" 2>/dev/null) || return 1
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || return 1
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 1
	value=$(printf '%s' "$response" | jq -r "$jq_filter" 2>/dev/null) || return 1
	[[ "$value" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$value"
	return 0
}

# Count recently closed function-complexity-debt issues for throughput-aware stall checks.
# Arguments: $1 - now_epoch, $2 - aidevops_slug, $3 - window_seconds
# Outputs: integer closure count
_complexity_recent_debt_closures() {
	local now_epoch="${1:-0}"
	local aidevops_slug="${2:-}"
	local window_seconds="${3:-0}"
	local since_epoch=$((now_epoch - window_seconds))
	local since_date=""
	local recent_closures=""

	since_date=$(date -u -d "@${since_epoch}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) ||
		since_date=$(date -u -r "$since_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) ||
		since_date=""
	if [[ -z "$since_date" ]]; then
		printf '0\n'
		return 0
	fi

	recent_closures=$(_complexity_graphql_scalar_exact \
		"pulse-complexity-closures-exact-cost" \
		"query { search(query:\"repo:${aidevops_slug} label:function-complexity-debt is:issue is:closed closed:>${since_date}\", type:ISSUE) { issueCount } rateLimit { cost } }" \
		'.data.search.issueCount') || recent_closures="0"
	[[ "$recent_closures" =~ ^[0-9]+$ ]] || recent_closures="0"
	printf '%s\n' "$recent_closures"
	return 0
}

# Check if the daily LLM sweep is due and debt is stalled.
# The LLM sweep fires when:
#   1. COMPLEXITY_LLM_SWEEP_INTERVAL has elapsed since last sweep, AND
#   2. The open function-complexity-debt count has not decreased since last check, AND
#   3. Zero function-complexity-debt issues closed during the stall window
# Arguments: $1 - now_epoch, $2 - aidevops_slug
# Returns: 0 if sweep is due, 1 if not due
_complexity_llm_sweep_due() {
	local now_epoch="${1:-0}"
	local aidevops_slug="${2:-}"
	local sweep_interval="${COMPLEXITY_LLM_SWEEP_INTERVAL:-0}"

	# Interval guard
	if [[ -f "$COMPLEXITY_LLM_SWEEP_LAST_RUN" ]]; then
		local last_sweep
		last_sweep=$(cat "$COMPLEXITY_LLM_SWEEP_LAST_RUN" 2>/dev/null || echo "0")
		[[ "$last_sweep" =~ ^[0-9]+$ ]] || last_sweep=0
		local elapsed=$((now_epoch - last_sweep))
		if [[ "$elapsed" -lt "$sweep_interval" ]]; then
			return 1
		fi
	fi

	# Fetch current open debt count
	local current_count=""
	current_count=$(_complexity_graphql_scalar_exact \
		"pulse-complexity-open-count-exact-cost" \
		"query { repository(owner:\"${aidevops_slug%%/*}\", name:\"${aidevops_slug##*/}\") { issues(labels:[\"function-complexity-debt\"], states:OPEN) { totalCount } } rateLimit { cost } }" \
		'.data.repository.issues.totalCount') || current_count=""
	[[ "$current_count" =~ ^[0-9]+$ ]] || return 1

	# Compare against last recorded count
	local prev_count=""
	if [[ -f "$COMPLEXITY_DEBT_COUNT_FILE" ]]; then
		prev_count=$(cat "$COMPLEXITY_DEBT_COUNT_FILE" 2>/dev/null || true)
	fi

	# Always update the count file
	printf '%s\n' "$current_count" >"$COMPLEXITY_DEBT_COUNT_FILE"

	# No sweep needed when debt is already zero — nothing to act on (GH#17422)
	if [[ "$current_count" -eq 0 ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: debt is zero, no sweep required" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 1
	fi

	# Sweep is due if debt count has not decreased (stalled or growing)
	if [[ -n "$prev_count" && "$prev_count" =~ ^[0-9]+$ ]]; then
		if [[ "$current_count" -lt "$prev_count" ]]; then
			echo "[pulse-wrapper] Complexity LLM sweep: debt reduced (${prev_count} → ${current_count}) — sweep not needed" >>"$LOGFILE"
			printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
			return 1
		fi
	fi

	# GH#18286/GH#25890: A flat or growing open count is not a stall when
	# workers are closing debt and the scanner is replenishing the backlog at a
	# similar rate. Only create an LLM sweep when recent throughput is zero.
	local recent_closures
	recent_closures=$(_complexity_recent_debt_closures "$now_epoch" "$aidevops_slug" "$sweep_interval")
	[[ "$recent_closures" =~ ^[0-9]+$ ]] || recent_closures="0"
	if [[ "$recent_closures" -gt 0 ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: debt at ${current_count} but ${recent_closures} issue(s) closed in the last $((sweep_interval / 3600))h — active throughput, sweep not needed" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 1
	fi

	# GH#17536: Skip sweep when all remaining debt issues are already dispatched.
	# If every open function-complexity-debt issue (excluding sweep meta-issues) has
	# status:queued or status:in-progress, the pipeline is working — no sweep needed.
	local dispatched_count
	dispatched_count=$(gh_issue_list --repo "$aidevops_slug" \
		--label "function-complexity-debt" --state open \
		--json number,title,labels --jq '
		[.[] | select(.title | test("stalled|LLM sweep") | not)] |
		if length == 0 then 0
		else
			[.[] | select(.labels | map(.name) | (index("status:queued") or index("status:in-progress")))] | length
		end' 2>/dev/null) || dispatched_count=""
	local actionable_count
	actionable_count=$(gh_issue_list --repo "$aidevops_slug" \
		--label "function-complexity-debt" --state open \
		--json number,title --jq '[.[] | select(.title | test("stalled|LLM sweep") | not)] | length' 2>/dev/null) || actionable_count=""
	if [[ "$actionable_count" =~ ^[0-9]+$ && "$dispatched_count" =~ ^[0-9]+$ && "$actionable_count" -gt 0 && "$dispatched_count" -ge "$actionable_count" ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: all ${actionable_count} debt issues are dispatched — sweep not needed" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 1
	fi

	echo "[pulse-wrapper] Complexity LLM sweep: debt stalled at ${current_count} (prev: ${prev_count:-unknown}, dispatched: ${dispatched_count:-?}/${actionable_count:-?}) — sweep due" >>"$LOGFILE"
	return 0
}

# Run the daily LLM sweep: create a GitHub issue asking the LLM to review
# why simplification debt is stalled and suggest approach adjustments.
# Arguments: $1 - aidevops_slug, $2 - now_epoch, $3 - maintainer
# Returns: 0 always (best-effort)
_complexity_run_llm_sweep() {
	local aidevops_slug="$1"
	local now_epoch="$2"
	local maintainer="$3"

	# Dedup: check if an open sweep issue already exists (t1855).
	# Both sweep code paths use different title patterns — check both. Stall
	# reviews deliberately do not carry function-complexity-debt because they
	# are meta work, so title-based dedup must not depend on that label.
	local sweep_exists
	sweep_exists=$(gh_issue_list --repo "$aidevops_slug" \
		--state open \
		--search "in:title \"simplification debt stalled\" OR in:title \"LLM complexity sweep\"" \
		--json number --jq 'length' 2>/dev/null) || sweep_exists="0"
	[[ "$sweep_exists" =~ ^[0-9]+$ ]] || sweep_exists="0"
	if [[ "${sweep_exists:-0}" -gt 0 ]]; then
		echo "[pulse-wrapper] Complexity LLM sweep: skipping — open stall issue already exists" >>"$LOGFILE"
		printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
		return 0
	fi

	local current_count=""
	if [[ -f "$COMPLEXITY_DEBT_COUNT_FILE" ]]; then
		current_count=$(cat "$COMPLEXITY_DEBT_COUNT_FILE" 2>/dev/null || true)
	fi

	local sweep_body
	sweep_body="## Simplification debt stall — LLM sweep (automated, GH#15285)

**Open function-complexity-debt issues:** ${current_count:-unknown}

The simplification debt count has not decreased in the last $((${COMPLEXITY_LLM_SWEEP_INTERVAL:-0} / 3600))h, and the throughput guard found no recent function-complexity-debt closures. This issue is a worker-ready prompt for the LLM to review the current state and ship a small self-healing improvement when the cause is clear.

### Questions to investigate

1. Are the open function-complexity-debt issues actionable? Check for issues that are blocked, stale, or need maintainer review.
2. Are workers dispatching on function-complexity-debt issues? Check recent pulse logs for dispatch activity.
3. Is the open debt cap (500) or the local worktree cap (\`AIDEVOPS_MAX_WORKTREES\`, default 200) being hit? Check pulse logs for \`local_capacity_gate\` and verify cleanup liveness before changing either safety cap.
4. Are there systemic blockers (e.g., all remaining issues require architectural decisions)?

### Suggested actions

- Review the oldest 10 open function-complexity-debt issues and close any that are no longer relevant.
- Check if \`tier:simple\` and \`tier:standard\` issues are being dispatched — if not, verify the pulse is routing them correctly.
- If dispatch reports \`local_capacity_gate\`, verify \`cleanup-worktrees-async-helper.sh\` is live and reducing the affected repo's registered worktree count; do not raise safety caps while recoverable worktrees remain.
- If debt is growing, consider lowering \`COMPLEXITY_MD_MIN_LINES\` or \`COMPLEXITY_FILE_VIOLATION_THRESHOLD\` to catch more candidates.

### Worker Guidance

- Target files: \`.agents/scripts/pulse-simplification-scan.sh\`, \`.agents/scripts/complexity-scan-helper.sh\`, \`.agents/scripts/pulse-dispatch-engine.sh\`, and matching tests under \`.agents/scripts/tests/\`.
- Reference pattern: keep the inline sweep guard consistent with \`complexity-scan-helper.sh sweep-check\`, especially the recent-closure throughput check before filing a stall issue.
- Do not close debt issues solely because they are old. Close only when current repo evidence shows the file is deleted, already simplified, or duplicated.
- Verification: run \`.agents/scripts/tests/test-pulse-wrapper-complexity-scan.sh\` plus ShellCheck on changed shell scripts.

### Confidence: low

This is an automated stall-detection sweep. The LLM should review the actual issue list before acting.

---
**To dismiss**, comment \`dismissed: <reason>\` on this issue."

	# Append signature footer
	local sig_footer="" _sweep_elapsed=""
	_sweep_elapsed=$((now_epoch - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$sweep_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_sweep_elapsed" --session-type routine 2>/dev/null || true)
	sweep_body="${sweep_body}${sig_footer}"

	# Skip needs-maintainer-review when user is maintainer (GH#16786)
	local sweep_review_label=""
	if [[ "${_COMPLEXITY_SCAN_SKIP_REVIEW_GATE:-false}" != "true" ]]; then
		sweep_review_label="--label needs-maintainer-review"
	fi
	# shellcheck disable=SC2086
	# t1955: Don't self-assign on issue creation — let dispatch_with_dedup handle
	# assignment. Self-assigning creates a phantom claim that triggers stale recovery
	# on other runners, producing audit trail gaps.
	# A stall review is quality-debt meta work, not a function violation. Giving
	# it the function-complexity-debt label would inflate the open debt count and
	# make closing the review look like real simplification throughput.
	if gh_create_issue --repo "$aidevops_slug" \
		--title "perf: simplification debt stalled — LLM sweep needed ($(date -u +%Y-%m-%d))" \
		--label "quality-debt" $sweep_review_label --label "tier:thinking" --label "worker-ready" \
		--body "$sweep_body" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Complexity LLM sweep: created stall-review issue" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Complexity LLM sweep: failed to create stall-review issue" >>"$LOGFILE"
	fi

	printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	return 0
}

# Resolve the aidevops repo path and validate lint-file-discovery.sh exists.
# Arguments: $1 - repos_json path, $2 - aidevops_slug, $3 - now_epoch
# Outputs: aidevops_path via stdout (empty on failure)
# Returns: 0 on success, 1 on failure (also writes last-run timestamp on failure)
_complexity_scan_find_repo() {
	local repos_json="$1"
	local aidevops_slug="$2"
	local now_epoch="$3"
	local aidevops_path=""
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		aidevops_path=$(jq -r --arg slug "$aidevops_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .path' \
			"$repos_json" 2>/dev/null | head -n 1)
	fi
	if [[ -z "$aidevops_path" || "$aidevops_path" == "null" || ! -d "$aidevops_path" ]]; then
		echo "[pulse-wrapper] Complexity scan: aidevops repo path not found — skipping" >>"$LOGFILE"
		echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 1
	fi
	local lint_discovery="${aidevops_path}/.agents/scripts/lint-file-discovery.sh"
	if [[ ! -f "$lint_discovery" ]]; then
		echo "[pulse-wrapper] Complexity scan: lint-file-discovery.sh not found — skipping" >>"$LOGFILE"
		echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 1
	fi
	echo "$aidevops_path"
	return 0
}

# Collect per-file violation counts from shell files in the repo.
# Arguments: $1 - aidevops_path, $2 - now_epoch
# Outputs: scan_results (pipe-delimited lines: file_path|count) via stdout
# Side effect: logs total violation count; writes last-run on no files found
_complexity_scan_collect_violations() {
	local aidevops_path="$1"
	local now_epoch="$2"
	local shell_files
	shell_files=$(git -C "$aidevops_path" ls-files '*.sh' | grep -Ev '_archive/' || true)
	if [[ -z "$shell_files" ]]; then
		echo "[pulse-wrapper] Complexity scan: no shell files found — skipping" >>"$LOGFILE"
		echo "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
		return 1
	fi
	local scan_results=""
	local total_violations=0
	local files_with_violations=0
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${aidevops_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local result
		# Use -v to pass the threshold safely — interpolating shell variables into
		# awk scripts is a security risk and breaks if the value contains quotes (GH#18555).
		result=$(awk -v threshold="$COMPLEXITY_FUNC_LINE_THRESHOLD" '
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fname=$1; sub(/\(\)/, "", fname); start=NR; next }
			fname && /^\}$/ { lines=NR-start; if(lines+0>threshold+0) printf "%s() %d lines\n", fname, lines; fname="" }
		' "$full_path")
		if [[ -n "$result" ]]; then
			local count
			count=$(echo "$result" | wc -l | tr -d ' ')
			total_violations=$((total_violations + count))
			files_with_violations=$((files_with_violations + 1))
			if [[ "$count" -ge "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" ]]; then
				# Use repo-relative path as dedup key (not basename — avoids collisions
				# between files with the same name in different directories, GH#5630)
				scan_results="${scan_results}${file}|${count}"$'\n'
			fi
		fi
	done <<<"$shell_files"
	echo "[pulse-wrapper] Complexity scan: ${total_violations} violations across ${files_with_violations} files" >>"$LOGFILE"
	printf '%s' "$scan_results"
	return 0
}

# Check if an open function-complexity-debt issue already exists for a given file.
#
# Uses GitHub search API via `gh issue list --search` to query server-side,
# avoiding the --limit 200 cap that caused duplicate issues (GH#10783).
# Previous approach fetched 200 issues locally and checked with jq, but with
# 3000+ open function-complexity-debt issues, most were invisible to the dedup check.
#
# Arguments:
#   $1 - repo_slug (owner/repo for gh commands)
#   $2 - issue_key (repo-relative file path used as dedup key)
# Exit codes:
#   0 - existing issue found (skip creation)
#   1 - no existing issue (safe to create)
_complexity_scan_has_existing_issue() {
	local repo_slug="$1"
	local issue_key="$2"

	# Server-side search by file path in title — accurate across all issues,
	# not limited by --limit pagination. The file path is always in the title.
	local match_count
	match_count=$(gh_issue_list --repo "$repo_slug" \
		--label "function-complexity-debt" --state open \
		--search "in:title \"$issue_key\"" \
		--json number --jq 'length' 2>/dev/null) || match_count="0"
	if [[ "${match_count:-0}" -gt 0 ]]; then
		return 0
	fi

	# Fallback: search in issue body for the structured **File:** field.
	# This catches issues where the title format differs (e.g., Qlty issues).
	match_count=$(gh_issue_list --repo "$repo_slug" \
		--label "function-complexity-debt" --state open \
		--search "\"$issue_key\" in:body" \
		--json number --jq 'length' 2>/dev/null) || match_count="0"

	if [[ "$match_count" -gt 0 ]]; then
		return 0
	fi

	return 1
}

# Close open duplicate function-complexity-debt issues for an exact title.
#
# This is a post-create race repair for cross-machine TOCTOU collisions:
# two runners can both pass pre-create dedup checks, then both create the
# same issue title seconds apart. This helper converges to a single open
# issue by keeping the newest and closing older duplicates immediately.
#
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - issue_title (exact title match)
# Returns:
#   0 always (best-effort)
_complexity_scan_close_duplicate_issues_by_title() {
	local repo_slug="$1"
	local issue_title="$2"

	local issue_numbers=""
	if ! issue_numbers=$(T="$issue_title" gh_issue_list --repo "$repo_slug" \
		--label "function-complexity-debt" --state open \
		--search "in:title \"${issue_title}\"" \
		--limit 100 --json number,title \
		--jq 'map(select(.title == env.T) | .number) | sort | .[]'); then
		echo "[pulse-wrapper] Complexity scan: failed to query duplicates for title: ${issue_title}" >>"$LOGFILE"
		return 0
	fi

	[[ -z "$issue_numbers" ]] && return 0

	local issue_count=0
	local keep_number=""
	local issue_number
	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		issue_count=$((issue_count + 1))
		# Keep the newest issue (largest number) for consistency with
		# run_simplification_dedup_cleanup.
		keep_number="$issue_number"
	done <<<"$issue_numbers"

	if [[ "$issue_count" -le 1 || -z "$keep_number" ]]; then
		return 0
	fi

	local closed_count=0
	while IFS= read -r issue_number; do
		[[ -n "$issue_number" ]] || continue
		[[ "$issue_number" == "$keep_number" ]] && continue
		if gh issue close "$issue_number" --repo "$repo_slug" --reason "not planned" \
			--comment "Auto-closing duplicate from concurrent simplification scan run. Keeping newest issue #${keep_number}." \
			>/dev/null 2>&1; then
			closed_count=$((closed_count + 1))
		fi
	done <<<"$issue_numbers"

	if [[ "$closed_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Complexity scan: closed ${closed_count} duplicate function-complexity-debt issue(s) for title: ${issue_title}" >>"$LOGFILE"
	fi

	return 0
}

# Check if the open function-complexity-debt issue backlog exceeds the cap.
# Arguments: $1 - aidevops_slug, $2 - cap (default 100), $3 - log_prefix
# Exit codes: 0 = under cap (safe to create), 1 = at/over cap (skip)
_complexity_scan_check_open_cap() {
	local aidevops_slug="$1"
	local cap="${2:-200}"
	local log_prefix="${3:-Complexity scan}"

	local total_open=""
	total_open=$(_complexity_graphql_scalar_exact \
		"pulse-complexity-cap-exact-cost" \
		"query { repository(owner:\"${aidevops_slug%%/*}\", name:\"${aidevops_slug##*/}\") { issues(labels:[\"function-complexity-debt\"], states:OPEN) { totalCount } } rateLimit { cost } }" \
		'.data.repository.issues.totalCount') || total_open="0"
	if [[ "${total_open:-0}" -ge "$cap" ]]; then
		echo "[pulse-wrapper] ${log_prefix}: skipping — ${total_open} open function-complexity-debt issues (cap: ${cap})" >>"$LOGFILE"
		return 1
	fi
	return 0
}

# _complexity_scan_permission_gate — check current user has admin access (t2001)
# Sets global _COMPLEXITY_SCAN_SKIP_REVIEW_GATE.
# Returns 1 (call-site should return 0) if scan should be skipped.
_complexity_scan_permission_gate() {
	local aidevops_slug="$1"

	# Permission gate: only admin users may create simplification issues.
	# write/maintain collaborators are excluded — they could otherwise use
	# bot-created function-complexity-debt issues to bypass the maintainer assignee
	# gate (GH#16786, GH#18197). On personal repos, admin = repo owner only.
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null) || current_user=""
	if [[ -n "$current_user" ]]; then
		local perm_level
		# #aidevops:trust-boundary — simplification issue creation requires
		# confirmed admin access; permission lookup failures skip explicitly.
		if ! _gh_collaborator_permission_lookup "$aidevops_slug" "$current_user" perm_level; then
			echo "[pulse-wrapper] Complexity scan: skipped — permission check failed for user '$current_user' on $aidevops_slug (HTTP ${AIDEVOPS_GH_COLLAB_PERMISSION_HTTP:-unknown})" >>"$LOGFILE"
			return 1
		fi
		case "$perm_level" in
		admin) ;; # allowed — repo owner/admin only
		*)
			echo "[pulse-wrapper] Complexity scan: skipped — user '$current_user' has '$perm_level' permission on $aidevops_slug (need admin)" >>"$LOGFILE"
			return 1
			;;
		esac
	fi

	# When the authenticated user IS the repo maintainer, skip the
	# needs-maintainer-review label — the standard auto-dispatch + PR
	# review flow provides sufficient gating (GH#16786).
	local maintainer_from_config
	maintainer_from_config=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$REPOS_JSON" 2>/dev/null)
	[[ -z "$maintainer_from_config" ]] && maintainer_from_config=$(printf '%s' "$aidevops_slug" | cut -d/ -f1)
	_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=false
	if [[ "$current_user" == "$maintainer_from_config" ]]; then
		_COMPLEXITY_SCAN_SKIP_REVIEW_GATE=true
	fi
	return 0
}

# _complexity_scan_pull_latest — pull aidevops repo before scanning (GH#17848, t2001)
# Fail-closed: returns 1 (skip cycle) if pull fails to avoid stale-state warnings.
_complexity_scan_pull_latest() {
	local aidevops_path="$1"

	# GH#17848: Pull latest state before scanning to avoid false-positive
	# proximity warnings from stale local checkouts. The proximity guard and
	# tree-change check both read working-tree files, so a stale checkout
	# (e.g., local repo hasn't pulled a threshold-bump PR yet) produces
	# incorrect violation counts and may create spurious warning issues.
	# Fail-closed: if pull fails, skip this scan cycle rather than proceeding
	# with stale data (which would reintroduce the exact problem we're fixing).
	# Do NOT update COMPLEXITY_SCAN_LAST_RUN on skip — the next cycle retries.
	# GIT_TERMINAL_PROMPT=0 prevents credential prompts from hanging the pulse.
	# GH#18644: timeout_sec 30 prevents network hangs from blocking the pulse
	# cycle. Previously used bare `timeout` which is Linux-only — on macOS it
	# exits immediately with "command not found" and the pull runs without any
	# timeout protection (or, if set -e is active, aborts the stage). The
	# portable timeout_sec helper from shared-constants.sh tries `timeout`,
	# `gtimeout`, and a bash-native PGID-kill fallback.
	if git -C "$aidevops_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		if ! GIT_TERMINAL_PROMPT=0 timeout_sec 30 \
			git -C "$aidevops_path" pull --ff-only --no-rebase >>"$LOGFILE" 2>&1; then
			echo "[pulse-wrapper] Complexity scan: git pull failed for ${aidevops_path} — skipping this cycle to avoid stale-state warnings" >>"$LOGFILE"
			return 1
		fi
	fi
	return 0
}
