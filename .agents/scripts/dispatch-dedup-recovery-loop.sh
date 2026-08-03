#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-recovery-loop.sh — issue-level worker recovery loop fuse.

_DDH_RECOVERY_LOOP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || _DDH_RECOVERY_LOOP_SCRIPT_DIR=""
if [[ -n "$_DDH_RECOVERY_LOOP_SCRIPT_DIR" && -r "${_DDH_RECOVERY_LOOP_SCRIPT_DIR}/lib/version.sh" ]]; then
	# shellcheck source=lib/version.sh
	source "${_DDH_RECOVERY_LOOP_SCRIPT_DIR}/lib/version.sh"
fi

#######################################
# Count recent worker recovery failures across branches.
#
# A recovery failure is one failed attempt to convert worker-produced local or
# remote branch output into a PR. Counting by issue, not by branch, catches the
# loop where each redispatch gets a fresh branch and therefore evades the older
# same-branch orphan fuse.
#
# Args: $1 = comments JSON, $2 = window seconds
# Outputs: count|latest_iso
# Returns: 0 on parse success, 1 on jq/date failure
#######################################
_ddh_recovery_failure_summary() {
	local comments_json="$1"
	local window_s="$2"
	local now_epoch="" event_list="" count=0 latest_iso="" event_iso=""

	now_epoch=$(date -u +%s 2>/dev/null) || return 1
	event_list=$(printf '%s' "$comments_json" | jq -r '
		(if type == "array" and (.[0]? | type) == "array" then [.[][]]
		elif type == "array" then .
		else [] end) as $items
		| [
			$items[]
			| select((.body // "") | test("WORKER_BRANCH_ORPHAN|WORKER_LOCAL_BRANCH_UNPUSHED"))
			| (.body // "") as $body
			| ($body | capture("ts=(?<ts>[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\\n ]+)")? | .ts) // .created_at // empty
		] as $worker_events
		| if ($worker_events | length) > 0 then
			$worker_events[]
		else
			$items[]
			| select((.body // "") | test("CLAIM_RELEASED reason=worker_branch_orphan|CLAIM_RELEASED reason=worker_local_branch_unpushed"))
			| (.body // "") as $body
			| ($body | capture("ts=(?<ts>[0-9]{4}-[0-9]{2}-[0-9]{2}T[^\\n ]+)")? | .ts) // .created_at // empty
		end
	' 2>/dev/null) || return 1

	while IFS= read -r event_iso; do
		[[ -n "$event_iso" ]] || continue
		local event_epoch=""
		event_epoch=$(date -u -d "$event_iso" +%s 2>/dev/null) ||
			event_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$event_iso" +%s 2>/dev/null) ||
			continue
		[[ "$event_epoch" =~ ^[0-9]+$ ]] || continue
		if [[ $((now_epoch - event_epoch)) -le "$window_s" ]]; then
			count=$((count + 1))
			latest_iso="$event_iso"
		fi
	done <<<"$event_list"

	printf '%s|%s\n' "$count" "$latest_iso"
	return 0
}

#######################################
# Count existing issue-level recovery-loop diagnostics.
# Args: $1 = comments JSON
# Outputs: numeric count
# Returns: 0 always
#######################################
_ddh_count_recovery_loop_blocks() {
	local comments_json="$1"
	local existing_block="0"

	existing_block=$(printf '%s' "$comments_json" | jq -r '
		(if type == "array" and (.[0]? | type) == "array" then [.[][]]
		elif type == "array" then .
		else [] end)
		| [ .[] | (.body // "") | select(contains("worker-recovery-loop:blocked")) ] | length
	' 2>/dev/null) || existing_block="0"
	[[ "$existing_block" =~ ^[0-9]+$ ]] || existing_block=0
	printf '%s' "$existing_block"
	return 0
}

#######################################
# Apply and document the issue-level recovery-loop hold.
#
# Args: $1 issue, $2 repo, $3 count, $4 threshold, $5 window seconds,
#       $6 latest ISO, $7 comments endpoint, $8 comments JSON
# Returns: 0 always
#######################################
_ddh_apply_recovery_loop_hold() {
	local issue_number="$1"
	local repo_slug="$2"
	local count="$3"
	local threshold="$4"
	local window_s="$5"
	local latest_iso="$6"
	local comments_post_endpoint="$7"
	local comments_json="$8"
	local existing_block="0"

	set_issue_status "$issue_number" "$repo_slug" "blocked" >/dev/null 2>&1 || true

	existing_block=$(_ddh_count_recovery_loop_blocks "$comments_json")
	if [[ "$existing_block" -eq 0 ]]; then
		local version=""
		version=$(aidevops_find_version 2>/dev/null || true)
		if [[ -z "$version" && -r "${AGENTS_DIR:-$HOME/.aidevops/agents}/VERSION" ]]; then
			version=$(tr -d '[:space:]' <"${AGENTS_DIR:-$HOME/.aidevops/agents}/VERSION" 2>/dev/null || true)
		fi
		version="${version:-unknown}"
		local diag=""
		# shellcheck disable=SC2016 # Backticks are literal Markdown, not command substitution.
		diag=$(printf '<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->\n<!-- worker-recovery-loop:blocked count=%s threshold=%s window_s=%s latest=%s version=%s -->\n<!-- dispatch-circuit-breaker:worker_recovery_loop -->\n## Dispatch paused: repeated worker recovery failures\n\nThis issue has produced %s worker recovery-failure outcome(s) within the last %s seconds. Those outcomes mean workers produced branch evidence but the automation could not confirm a PR, so another redispatch would likely add more audit comments without solving the issue.\n\n**Action:** applied `status:blocked` and cleared active status labels. Automated dispatch is suspended until a human reviews the runner worktrees/logs, recovers any branch output, or lands a setup-side fix.\n\n**Verification before re-enabling:** confirm a PR exists for the work or confirm there is no unrecovered worker branch output left to preserve, then restore `status:available`.\n<!-- ops:end -->' \
			"$count" "$threshold" "$window_s" "${latest_iso:-unknown}" "$version" "$count" "$window_s")
		gh api "$comments_post_endpoint" --method POST --field body="$diag" >/dev/null 2>&1 || true
	fi

	printf 'WORKER_RECOVERY_LOOP_BLOCKED (issue=%s repo=%s count=%s threshold=%s window_s=%s latest=%s)\n' \
		"$issue_number" "$repo_slug" "$count" "$threshold" "$window_s" "${latest_iso:-unknown}"
	return 0
}

#######################################
# Check repeated worker recovery failures across branches for an issue.
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if dispatch should be held, exit 1 otherwise.
#######################################
check_worker_recovery_failure_loop() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1

	local threshold="${WORKER_RECOVERY_FAILURE_LOOP_THRESHOLD:-2}"
	local window_s="${WORKER_RECOVERY_FAILURE_LOOP_WINDOW_S:-7200}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=2
	[[ "$window_s" =~ ^[0-9]+$ ]] || window_s=7200
	[[ "$threshold" -gt 0 && "$window_s" -gt 0 ]] || return 1

	local comments_post_endpoint=""
	comments_post_endpoint=$(_ddh_issue_comments_endpoint "$repo_slug" "$issue_number")
	local comments_json=""
	comments_json=$(_ddh_fetch_issue_comments "$issue_number" "$repo_slug") || return 1
	[[ -n "$comments_json" ]] || return 1

	local summary="" count="0" latest_iso=""
	summary=$(_ddh_recovery_failure_summary "$comments_json" "$window_s") || return 1
	IFS='|' read -r count latest_iso <<<"$summary"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$count" -ge "$threshold" ]] || return 1

	_ddh_apply_recovery_loop_hold "$issue_number" "$repo_slug" "$count" "$threshold" "$window_s" "$latest_iso" "$comments_post_endpoint" "$comments_json"
	return 0
}
