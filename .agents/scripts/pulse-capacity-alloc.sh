#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-capacity-alloc.sh — Per-priority worker allocation — peak-hours cap, max-worker arithmetic, priority allocation table, debt worker counting, per-repo cap, hygiene + PR salvage helpers.
#
# Extracted from pulse-wrapper.sh in Phase 3 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants and mutable
# _PULSE_HEALTH_* counters in the bootstrap section.
#
# Functions in this module (in source order):
#   - _append_priority_allocations
#   - _check_repo_hygiene
#   - _scan_pr_salvage
#   - apply_peak_hours_cap
#   - calculate_max_workers
#   - calculate_priority_allocations
#   - count_debt_workers
#   - check_repo_worker_cap
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_CAPACITY_ALLOC_LOADED:-}" ]] && return 0
_PULSE_CAPACITY_ALLOC_LOADED=1

#######################################
# Append priority-class worker allocations to state file (t1423)
#
# Reads the allocation file written by calculate_priority_allocations()
# and formats it as a section the pulse agent can act on.
#
# The pulse agent uses this to enforce soft reservations: product repos
# get a guaranteed minimum share of worker slots, tooling gets the rest.
# When one class has no pending work, the other can use freed slots.
#
# Output: allocation summary to stdout (appended to STATE_FILE by caller)
#######################################
_append_priority_allocations() {
	local alloc_file="${HOME}/.aidevops/logs/pulse-priority-allocations"

	echo ""
	echo "# Priority-Class Worker Allocations (t1423)"
	echo ""

	if [[ ! -f "$alloc_file" ]]; then
		echo "- Allocation data not available — using flat pool (no reservations)"
		echo ""
		return 0
	fi

	# Read allocation values
	local max_workers="" product_repos="" tooling_repos="" dispatchable_product_repos="" product_min="" tooling_max="" reservation_pct="" quality_debt_cap_pct=""
	max_workers=$(grep '^MAX_WORKERS=' "$alloc_file" | cut -d= -f2) || max_workers=4
	product_repos=$(grep '^PRODUCT_REPOS=' "$alloc_file" | cut -d= -f2) || product_repos=0
	tooling_repos=$(grep '^TOOLING_REPOS=' "$alloc_file" | cut -d= -f2) || tooling_repos=0
	dispatchable_product_repos=$(grep '^DISPATCHABLE_PRODUCT_REPOS=' "$alloc_file" | cut -d= -f2) || dispatchable_product_repos="$product_repos"
	product_min=$(grep '^PRODUCT_MIN=' "$alloc_file" | cut -d= -f2) || product_min=0
	tooling_max=$(grep '^TOOLING_MAX=' "$alloc_file" | cut -d= -f2) || tooling_max=0
	reservation_pct=$(grep '^PRODUCT_RESERVATION_PCT=' "$alloc_file" | cut -d= -f2) || reservation_pct=60
	quality_debt_cap_pct=$(grep '^QUALITY_DEBT_CAP_PCT=' "$alloc_file" | cut -d= -f2) || quality_debt_cap_pct=30

	echo "Worker pool: **${max_workers}** total slots"
	echo "Product repos (${product_repos}, dispatchable now: ${dispatchable_product_repos}): **${product_min}** reserved slots (${reservation_pct}% target minimum)"
	echo "Tooling repos (${tooling_repos}): **${tooling_max}** slots (remainder)"
	echo "Quality-debt cap: **${quality_debt_cap_pct}%** of worker pool"
	echo ""
	echo "**Enforcement rules:**"
	echo "- Reservations are soft targets, not hard gates. If one class has no dispatchable candidates, immediately reassign its unused slots to the other class."
	echo "- Product repos at daily PR cap are treated as temporarily non-dispatchable for reservation purposes."
	echo "- Do not leave slots idle when runnable scoped work exists in any class."
	echo "- If all ${max_workers} slots are needed for product work, tooling gets 0 (product reservation is a minimum, not a maximum)."
	echo "- Merges (priority 1) and CI fixes (priority 2) are exempt — they always proceed regardless of class."
	echo ""

	return 0
}

#######################################
# Pre-fetch repo hygiene data for LLM triage (t1417)
#
# Appends a "Repo Hygiene" section to the state file with:
#   1. Orphan worktrees — branches with 0 commits ahead of main,
#      no PR (open or merged), and no active worker process.
#   2. Stash summary — count of needs-review stashes per repo.
#   3. Uncommitted changes on main — repos with dirty main worktree.
#
# This data enables the pulse LLM to make intelligent triage decisions
# about cleanup. Deterministic cleanup (merged-PR worktrees, safe stashes)
# is handled by cleanup_worktrees() and cleanup_stashes() before this runs.
# What remains here requires judgment.
#
# Output: hygiene summary to stdout (appended to STATE_FILE by caller)
#######################################
#######################################
# Check a single repo for hygiene issues (GH#5627, extracted from prefetch_hygiene)
#
# Checks for orphan worktrees, stale stashes, and uncommitted changes
# on the default branch. Returns issue descriptions via stdout.
#
# Arguments:
#   $1 - repo_path
#   $2 - repos_json path (for slug lookup)
# Output: issue lines to stdout (empty if no issues)
#######################################
_check_repo_hygiene() {
	local repo_path="$1"
	local repos_json="$2"
	local repo_issues=""

	# 1. Orphan worktrees: 0 commits ahead of default branch, no PR
	local default_branch
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || default_branch="main"
	[[ -z "$default_branch" ]] && default_branch="main"

	local wt_branch="" wt_path=""
	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			wt_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			wt_branch="${BASH_REMATCH[1]}"
		elif [[ -z "$line" && -n "$wt_branch" ]]; then
			# Skip the default branch
			if [[ "$wt_branch" != "$default_branch" ]]; then
				local commits_ahead
				commits_ahead=$(git -C "$repo_path" rev-list --count "${default_branch}..${wt_branch}" 2>/dev/null) || commits_ahead="?"

				if [[ "$commits_ahead" == "0" ]]; then
					# Check if any PR exists (open or merged)
					local has_pr="false"
					if command -v gh &>/dev/null; then
						local pr_check
						# Use first() to guard against duplicate entries in initialized_repos for the same path.
					pr_check=$(gh_pr_list --repo "$(jq -r --arg p "$repo_path" 'first(.initialized_repos[] | select(.path == $p) | .slug)' "$repos_json" 2>/dev/null)" \
						--head "$wt_branch" --state all --json number --jq 'length' 2>/dev/null) || pr_check="0"
						[[ "${pr_check:-0}" -gt 0 ]] && has_pr="true"
					fi

					if [[ "$has_pr" == "false" ]]; then
						# Check for dirty state
						local dirty=""
						local change_count
						change_count=$(git -C "${wt_path:-$repo_path}" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || change_count=0
						[[ "${change_count:-0}" -gt 0 ]] && dirty=" (${change_count} uncommitted files)"

						repo_issues="${repo_issues}  - Orphan worktree: \`${wt_branch}\` — 0 commits, no PR${dirty} (${wt_path})\n"
					fi
				fi
			fi
			wt_path=""
			wt_branch=""
		fi
	done < <(
		git -C "$repo_path" worktree list --porcelain 2>/dev/null
		echo ""
	)

	# 2. Stash summary (needs-review count)
	local stash_count
	stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ')
	if [[ "${stash_count:-0}" -gt 0 ]]; then
		repo_issues="${repo_issues}  - ${stash_count} stash(es) remaining (safe-to-drop already cleaned; these need review)\n"
	fi

	# 3. Uncommitted changes on main worktree
	local main_wt_path="$repo_path"
	local current_branch
	current_branch=$(git -C "$main_wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch=""
	if [[ "$current_branch" == "$default_branch" ]]; then
		local main_dirty
		main_dirty=$(git -C "$main_wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || main_dirty=0
		if [[ "${main_dirty:-0}" -gt 0 ]]; then
			repo_issues="${repo_issues}  - ${main_dirty} uncommitted file(s) on ${default_branch} branch\n"
		fi
	fi

	echo -n "$repo_issues"
	return 0
}

#######################################
# Scan for salvageable closed-unmerged PRs (GH#5627, extracted from prefetch_hygiene)
#
# Arguments:
#   $1 - repos_json path
# Output: salvage summary to stdout
#######################################
_scan_pr_salvage() {
	local repos_json="$1"
	local salvage_helper="${SCRIPT_DIR}/pr-salvage-helper.sh"

	if [[ ! -x "$salvage_helper" ]]; then
		return 0
	fi

	echo ""
	echo "# PR Salvage (closed-unmerged with recoverable code)"
	echo ""

	local salvage_found=false
	local slug="" path=""
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		local salvage_output
		salvage_output=$("$salvage_helper" prefetch "$slug" "$path" 2>/dev/null) || true
		if [[ -n "$salvage_output" ]]; then
			salvage_found=true
			echo "$salvage_output"
		fi
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$salvage_found" == "false" ]]; then
		echo "- No salvageable closed-unmerged PRs detected"
		echo ""
	fi

	return 0
}

#######################################
# Apply peak-hours worker cap (t1677)
#
# When supervisor.peak_hours_enabled is true and the current local time
# falls within the configured window, caps MAX_WORKERS at
# ceil(off_peak_max * peak_hours_worker_fraction), minimum 1.
#
# The cap is applied AFTER the RAM-based calculation so it can only
# reduce, never increase, the worker count.
#
# Settings read via settings-helper.sh (respects env var overrides):
#   supervisor.peak_hours_enabled        (default: false)
#   supervisor.peak_hours_start          (default: 5,  0-23 local hour)
#   supervisor.peak_hours_end            (default: 11, 0-23 local hour)
#   supervisor.peak_hours_tz             (default: America/Los_Angeles)
#   supervisor.peak_hours_worker_fraction (default: 0.2)
#
# Arguments:
#   $1 - current off-peak max_workers value (integer >= 1)
#
# Output: (possibly reduced) max_workers value to stdout
# Returns: 0 always
#######################################
apply_peak_hours_cap() {
	local off_peak_max="$1"

	# Validate input
	[[ "$off_peak_max" =~ ^[0-9]+$ ]] || off_peak_max=1
	[[ "$off_peak_max" -lt 1 ]] && off_peak_max=1

	# Read settings via helper (respects env var overrides)
	local settings_helper="${SCRIPT_DIR}/settings-helper.sh"
	if [[ ! -x "$settings_helper" ]]; then
		echo "$off_peak_max"
		return 0
	fi

	local peak_enabled
	peak_enabled=$("$settings_helper" get supervisor.peak_hours_enabled 2>/dev/null || echo "false")
	if [[ "$peak_enabled" != "true" ]]; then
		echo "$off_peak_max"
		return 0
	fi

	local ph_start="" ph_end="" ph_tz="" ph_fraction=""
	ph_start=$("$settings_helper" get supervisor.peak_hours_start 2>/dev/null || echo "5")
	ph_end=$("$settings_helper" get supervisor.peak_hours_end 2>/dev/null || echo "11")
	ph_tz=$("$settings_helper" get supervisor.peak_hours_tz 2>/dev/null || echo "America/Los_Angeles")
	ph_fraction=$("$settings_helper" get supervisor.peak_hours_worker_fraction 2>/dev/null || echo "0.2")

	# Validate hour values
	[[ "$ph_start" =~ ^[0-9]+$ ]] || ph_start=5
	[[ "$ph_end" =~ ^[0-9]+$ ]] || ph_end=11
	[[ "$ph_start" -gt 23 ]] && ph_start=5
	[[ "$ph_end" -gt 23 ]] && ph_end=11

	# IANA zoneinfo names prevent host-local time from changing this window.
	# Reject host-derived aliases and path traversal before resolving the zone file.
	if [[ ! "$ph_tz" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]] ||
		[[ "$ph_tz" =~ (^|/)(\.|\.\.|localtime|posixrules)(/|$) ]] ||
		[[ ! -f "/usr/share/zoneinfo/${ph_tz}" ]]; then
		echo "[pulse-wrapper] Invalid or unavailable peak-hours timezone '${ph_tz:-<empty>}' — falling back to UTC" >>"$LOGFILE"
		ph_tz="UTC"
	fi

	# Get the configured timezone's current hour (strip leading zero to avoid octal interpretation).
	local current_hour
	current_hour=$(TZ="$ph_tz" date +%H 2>/dev/null) || current_hour=""
	if [[ ! "$current_hour" =~ ^[0-9]{2}$ ]]; then
		echo "[pulse-wrapper] Could not read peak-hours timezone '${ph_tz}' — safely preserving MAX_WORKERS ${off_peak_max}" >>"$LOGFILE"
		echo "$off_peak_max"
		return 0
	fi
	local cur=0 ph_s=0 ph_e=0
	cur=$((10#${current_hour}))
	ph_s=$((10#${ph_start}))
	ph_e=$((10#${ph_end}))

	# Determine if we are inside the peak window
	# Supports overnight windows (start > end, e.g., 22→6)
	local in_peak=false
	if [[ "$ph_s" -le "$ph_e" ]]; then
		# Normal window: in peak when cur >= start AND cur < end
		if [[ "$cur" -ge "$ph_s" && "$cur" -lt "$ph_e" ]]; then
			in_peak=true
		fi
	else
		# Overnight window: in peak when cur >= start OR cur < end
		if [[ "$cur" -ge "$ph_s" || "$cur" -lt "$ph_e" ]]; then
			in_peak=true
		fi
	fi

	if [[ "$in_peak" != "true" ]]; then
		echo "$off_peak_max"
		return 0
	fi

	# Compute capped value: ceil(off_peak_max * fraction), minimum 1
	# Use awk for floating-point arithmetic (bash has no native float support)
	local peak_max
	peak_max=$(awk -v max="$off_peak_max" -v frac="$ph_fraction" \
		'BEGIN { v = max * frac; c = int(v); if (c < v) c++; if (c < 1) c = 1; print c }' \
		2>/dev/null || echo "1")
	[[ "$peak_max" =~ ^[0-9]+$ ]] || peak_max=1
	[[ "$peak_max" -lt 1 ]] && peak_max=1
	[[ "$peak_max" -gt "$off_peak_max" ]] && peak_max="$off_peak_max"

	echo "[pulse-wrapper] Peak hours active (${ph_tz}, window ${ph_s}→${ph_e}, current hour ${cur}): capping MAX_WORKERS ${off_peak_max}→${peak_max} (fraction=${ph_fraction})" >>"$LOGFILE"
	echo "$peak_max"
	return 0
}

#######################################
# Calculate max workers from available RAM
#
# Formula: (free_ram - RAM_RESERVE_MB) / RAM_PER_WORKER_MB
# Clamped to [1, MAX_WORKERS_CAP]
#
# Writes MAX_WORKERS to a file that pulse.md reads via bash.
#######################################
calculate_max_workers() {
	local free_mb
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: use vm_stat for free + inactive (reclaimable) pages
		local page_size="" free_pages="" inactive_pages=""
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
		free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		inactive_pages=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		# Validate integers before arithmetic expansion
		[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=16384
		[[ "$free_pages" =~ ^[0-9]+$ ]] || free_pages=0
		[[ "$inactive_pages" =~ ^[0-9]+$ ]] || inactive_pages=0
		free_mb=$(((free_pages + inactive_pages) * page_size / 1024 / 1024))
	else
		# Linux: use MemAvailable from /proc/meminfo
		free_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)
	fi
	[[ "$free_mb" =~ ^[0-9]+$ ]] || free_mb=8192

	local available_mb=$((free_mb - RAM_RESERVE_MB))
	local max_workers=$((available_mb / RAM_PER_WORKER_MB))

	# Clamp to [1, MAX_WORKERS_CAP]
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	elif [[ "$max_workers" -gt "$MAX_WORKERS_CAP" ]]; then
		max_workers="$MAX_WORKERS_CAP"
	fi

	# Apply peak-hours cap (t1677) — may further reduce max_workers
	max_workers=$(apply_peak_hours_cap "$max_workers")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$max_workers" -lt 1 ]] && max_workers=1

	# Write to a file that pulse.md can read
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	echo "$max_workers" >"$max_workers_file"

	echo "[pulse-wrapper] Available RAM: ${free_mb}MB, reserve: ${RAM_RESERVE_MB}MB, max workers: ${max_workers}" >>"$LOGFILE"
	return 0
}

#######################################
# Count pulse-enabled repos by priority class (t2006)
#
# Single jq pass over repos.json to count product vs tooling repos.
# Prints: "<product_count> <tooling_count>" to stdout.
#
# Arguments:
#   $1 - path to repos.json
#######################################
_count_priority_repos() {
	local repos_json="$1"
	local product_repos=0 tooling_repos=0

	read -r product_repos tooling_repos < <(jq -r '
		.initialized_repos |
		map(select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "")) |
		[
			(map(select(.priority == "product")) | length),
			(map(select(.priority == "tooling")) | length)
		] | @tsv
	' "$repos_json" 2>/dev/null) || true
	product_repos=${product_repos:-0}
	tooling_repos=${tooling_repos:-0}
	[[ "$product_repos" =~ ^[0-9]+$ ]] || product_repos=0
	[[ "$tooling_repos" =~ ^[0-9]+$ ]] || tooling_repos=0

	echo "$product_repos $tooling_repos"
	return 0
}

#######################################
# Count product repos that can dispatch (not blocked by daily PR cap) (t2006)
#
# Iterates product repos from repos.json, checks each against DAILY_PR_CAP.
# Prints: "<dispatchable_count>" to stdout.
#
# Arguments:
#   $1 - path to repos.json
#   $2 - total product repo count
#######################################
_count_dispatchable_product_repos() {
	local repos_json="$1"
	local product_repos="$2"
	local dispatchable=0
	local today_utc
	today_utc=$(date -u +%Y-%m-%d)

	if [[ "$product_repos" -gt 0 && "$DAILY_PR_CAP" -gt 0 ]]; then
		while IFS= read -r slug; do
			[[ -n "$slug" ]] || continue
			local pr_json="" daily_pr_count="" pr_alloc_err=""
			# GH#4412: use --state all to count merged/closed PRs too
			pr_alloc_err=$(mktemp)
			pr_json=$(pulse_pr_list_get --repo "$slug" --state all --json createdAt --limit 200 2>"$pr_alloc_err") || pr_json="[]"
			if [[ -z "$pr_json" ]]; then
				local _pr_alloc_err_msg
				_pr_alloc_err_msg=$(cat "$pr_alloc_err" 2>/dev/null || echo "unknown error")
				echo "[pulse-wrapper] calculate_priority_allocations: gh_pr_list FAILED for ${slug}: ${_pr_alloc_err_msg}" >>"$LOGFILE"
				pr_json="[]"
			fi
			rm -f "$pr_alloc_err"
			daily_pr_count=$(echo "$pr_json" | jq --arg today "$today_utc" '[.[] | select((.createdAt // "") | startswith($today))] | length' 2>/dev/null) || daily_pr_count=0
			[[ "$daily_pr_count" =~ ^[0-9]+$ ]] || daily_pr_count=0
			if [[ "$daily_pr_count" -lt "$DAILY_PR_CAP" ]]; then
				dispatchable=$((dispatchable + 1))
			fi
		done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "" and .priority == "product") | .slug' "$repos_json" 2>/dev/null)
	else
		dispatchable="$product_repos"
	fi
	[[ "$dispatchable" =~ ^[0-9]+$ ]] || dispatchable="$product_repos"

	echo "$dispatchable"
	return 0
}

#######################################
# Compute product_min and tooling_max slot reservations (t2006)
#
# Applies PRODUCT_RESERVATION_PCT with ceiling division and edge-case
# guards (no product repos, no tooling repos, single-slot minimum).
# Prints: "<product_min> <tooling_max>" to stdout.
#
# Arguments:
#   $1 - max_workers (total capacity)
#   $2 - dispatchable_product_repos count
#   $3 - tooling_repos count
#######################################
_compute_slot_reservations() {
	local max_workers="$1"
	local dispatchable_product_repos="$2"
	local tooling_repos="$3"
	local product_min=0 tooling_max=0

	if [[ "$dispatchable_product_repos" -eq 0 ]]; then
		# No product repos — all slots available for tooling
		product_min=0
		tooling_max="$max_workers"
	elif [[ "$tooling_repos" -eq 0 ]]; then
		# No tooling repos — all slots available for product
		product_min="$max_workers"
		tooling_max=0
	else
		# product_min = ceil(max_workers * PRODUCT_RESERVATION_PCT / 100)
		# Using integer arithmetic: ceil(a/b) = (a + b - 1) / b
		product_min=$(((max_workers * PRODUCT_RESERVATION_PCT + 99) / 100))
		# Ensure product_min doesn't exceed max_workers
		if [[ "$product_min" -gt "$max_workers" ]]; then
			product_min="$max_workers"
		fi
		# Ensure at least 1 slot for tooling when tooling repos exist
		# but only when there are multiple slots to distribute (with 1 slot,
		# product keeps it — the reservation is a minimum guarantee)
		if [[ "$max_workers" -gt 1 && "$product_min" -ge "$max_workers" && "$tooling_repos" -gt 0 ]]; then
			product_min=$((max_workers - 1))
		fi
		tooling_max=$((max_workers - product_min))
	fi

	echo "$product_min $tooling_max"
	return 0
}

#######################################
# Write priority allocation file (key=value format) (t2006)
#
# Arguments: $1=alloc_file $2=max_workers $3=product_repos $4=tooling_repos
#            $5=dispatchable_product_repos $6=product_min $7=tooling_max
#######################################
_write_priority_alloc_file() {
	local alloc_file="$1" max_workers="$2" product_repos="$3" tooling_repos="$4"
	local dispatchable_product_repos="$5" product_min="$6" tooling_max="$7"
	{
		echo "MAX_WORKERS=${max_workers}"
		echo "PRODUCT_REPOS=${product_repos}"
		echo "TOOLING_REPOS=${tooling_repos}"
		echo "DISPATCHABLE_PRODUCT_REPOS=${dispatchable_product_repos}"
		echo "PRODUCT_MIN=${product_min}"
		echo "TOOLING_MAX=${tooling_max}"
		echo "PRODUCT_RESERVATION_PCT=${PRODUCT_RESERVATION_PCT}"
		echo "QUALITY_DEBT_CAP_PCT=${QUALITY_DEBT_CAP_PCT}"
	} >"$alloc_file"
	return 0
}

#######################################
# Calculate priority-class worker allocations (t1423, refactored t2006)
#
# Coordinator: reads repos.json counts, computes slot reservations,
# writes allocation file. Delegates to per-concern helpers.
#
# Depends on: calculate_max_workers() having run first (reads pulse-max-workers)
#######################################
calculate_priority_allocations() {
	local repos_json="${REPOS_JSON}"
	local alloc_file="${HOME}/.aidevops/logs/pulse-priority-allocations"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "[pulse-wrapper] repos.json or jq not available — skipping priority allocations" >>"$LOGFILE"
		return 0
	fi
	local max_workers
	max_workers=$(cat "${HOME}/.aidevops/logs/pulse-max-workers" 2>/dev/null || echo 4)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=4

	local product_repos=0 tooling_repos=0
	read -r product_repos tooling_repos < <(_count_priority_repos "$repos_json")
	local dispatchable_product_repos
	dispatchable_product_repos=$(_count_dispatchable_product_repos "$repos_json" "$product_repos")
	if [[ "$dispatchable_product_repos" -lt "$product_repos" ]]; then
		echo "[pulse-wrapper] Product dispatchability reduced by daily PR caps: ${dispatchable_product_repos}/${product_repos} repos can accept new workers" >>"$LOGFILE"
	fi

	local product_min=0 tooling_max=0
	read -r product_min tooling_max < <(_compute_slot_reservations "$max_workers" "$dispatchable_product_repos" "$tooling_repos")
	_write_priority_alloc_file "$alloc_file" "$max_workers" "$product_repos" "$tooling_repos" "$dispatchable_product_repos" "$product_min" "$tooling_max"

	echo "[pulse-wrapper] Priority allocations: product_min=${product_min}, tooling_max=${tooling_max} (${product_repos} product, ${tooling_repos} tooling repos, ${max_workers} total slots)" >>"$LOGFILE"
	return 0
}

#######################################
# Count active debt workers for a repo (quality-debt + file-size-debt + function-complexity-debt)
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - debt type: "quality-debt", "file-size-debt", "function-complexity-debt", or "all" (default: all)
#
# Outputs two lines: active_count queued_count
# Exit code: always 0
#######################################
count_debt_workers() {
	local repo_slug="$1"
	local debt_type="${2:-all}"
	local active=0
	local queued=0

	case "$debt_type" in
	quality-debt)
		active=$(gh_issue_list --repo "$repo_slug" --label "quality-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		queued=$(gh_issue_list --repo "$repo_slug" --label "quality-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		;;
	file-size-debt)
		active=$(gh_issue_list --repo "$repo_slug" --label "file-size-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		queued=$(gh_issue_list --repo "$repo_slug" --label "file-size-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		;;
	function-complexity-debt)
		active=$(gh_issue_list --repo "$repo_slug" --label "function-complexity-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		queued=$(gh_issue_list --repo "$repo_slug" --label "function-complexity-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		;;
	all)
		local qa_active="" qa_queued="" fsd_active="" fsd_queued="" fcd_active="" fcd_queued=""
		qa_active=$(gh_issue_list --repo "$repo_slug" --label "quality-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		qa_queued=$(gh_issue_list --repo "$repo_slug" --label "quality-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		fsd_active=$(gh_issue_list --repo "$repo_slug" --label "file-size-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		fsd_queued=$(gh_issue_list --repo "$repo_slug" --label "file-size-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		fcd_active=$(gh_issue_list --repo "$repo_slug" --label "function-complexity-debt" --label "status:in-progress" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		fcd_queued=$(gh_issue_list --repo "$repo_slug" --label "function-complexity-debt" --label "status:queued" --state open --json number --jq 'length' 2>/dev/null || echo 0)
		active=$((qa_active + fsd_active + fcd_active))
		queued=$((qa_queued + fsd_queued + fcd_queued))
		;;
	esac

	[[ "$active" =~ ^[0-9]+$ ]] || active=0
	[[ "$queued" =~ ^[0-9]+$ ]] || queued=0
	echo "$active"
	echo "$queued"
	return 0
}

#######################################
# Check per-repo worker cap before dispatch
#
# Arguments:
#   $1 - repo path (canonical path on disk)
#   $2 - max workers per repo (default: MAX_WORKERS_PER_REPO or 5)
#   $3 - (optional) pre-fetched output of list_active_worker_processes
#         Pass this when calling inside a loop to avoid repeated ps invocations.
#         Omit (or pass empty) to fetch fresh process data.
#
# Exit codes:
#   0 - at or above cap (skip dispatch for this repo)
#   1 - below cap (safe to dispatch)
#######################################
check_repo_worker_cap() {
	local repo_path="$1"
	local cap="${2:-${MAX_WORKERS_PER_REPO:-5}}"
	local cached_worker_procs="${3:-}"
	local active_for_repo
	local worker_procs

	# Use caller-supplied cache when available to avoid repeated ps calls in loops.
	if [[ -n "$cached_worker_procs" ]]; then
		worker_procs="$cached_worker_procs"
	else
		worker_procs=$(list_active_worker_processes)
	fi

	active_for_repo=$(printf '%s\n' "$worker_procs" | awk -v path="$repo_path" '
		BEGIN { esc=path; gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc) }
		$0 ~ ("--dir[[:space:]]+" esc "([[:space:]]|$)") { count++ }
		END { print count + 0 }
	')
	[[ "$active_for_repo" =~ ^[0-9]+$ ]] || active_for_repo=0

	if [[ "$active_for_repo" -ge "$cap" ]]; then
		return 0
	fi
	return 1
}
