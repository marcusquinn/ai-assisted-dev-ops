#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-footprint.sh — File-footprint overlap throttle for dispatch (t2117/GH#19109)
#
# Prevents parallel dispatch of workers whose target file sets overlap.
# When two issues both modify the same file, whichever PR merges first
# invalidates the other (merge conflict or semantic conflict). The
# update-branch salvage path (t2116) rescues trivial cases, but genuine
# line-conflicting edits still cascade through CONFLICTING-close.
#
# This module is sourced by pulse-dispatch-core.sh. Depends on
# shared-constants.sh being sourced first by the orchestrator.
#
# Functions:
#   - _footprint_extract_paths    — parse file paths from issue body text
#   - _footprint_get_inflight     — collect file footprints for all in-flight issues
#   - _footprint_check_overlap    — check if a candidate's files overlap with in-flight
#
# Integration point: _dispatch_dedup_check_layers() in pulse-dispatch-core.sh
# calls _footprint_check_overlap() after the large-file gate and before the
# 7-layer dedup chain.
#
# Decay: natural — the check queries issues with active status labels
# (status:in-progress, status:in-review, status:claimed). Once the blocking
# issue's PR merges and labels clear, the overlap disappears.

[[ -n "${_DISPATCH_DEDUP_FOOTPRINT_LOADED:-}" ]] && return 0
_DISPATCH_DEDUP_FOOTPRINT_LOADED=1

# Cache for in-flight footprints — built once per pulse cycle, not per candidate.
# Keyed by repo_slug. Format: associative array of file→issue_number mappings.
# Populated lazily on first call to _footprint_check_overlap for each repo.
_FOOTPRINT_CACHE_REPO=""
_FOOTPRINT_CACHE_DATA=""
_FOOTPRINT_CACHE_EPOCH=0

# Maximum age of the footprint cache in seconds. After this, rebuild.
# 30s: long enough to catch concurrent same-file dispatch races (the
# original use-case), short enough to limit blast radius when issues
# close mid-window. See invalidate_footprint_cache_for_issue() for
# immediate eviction on known-close events (t2927/GH#21103).
_FOOTPRINT_CACHE_TTL=30

#######################################
# Extract file paths from an issue body.
#
# Parses explicit edit declarations from the brief template's "Files to Modify" section:
#   - `EDIT: path/to/file.sh:45-60` — existing file edit
#   - `NEW: path/to/file.sh` — new file creation
#   - Plain paths after "File:" prefix
# Context-only list items and "Relevant files" references are intentionally
# ignored because they do not declare implementation ownership.
#
# Strips line-number qualifiers (`:NNN` or `:START-END`) since we only care
# about file-level overlap, not line-level.
#
# Args:
#   $1 = issue body text
# Output: one file path per line (sorted, unique, no line qualifiers)
# Exit: always 0
#######################################
_footprint_extract_paths() {
	local issue_body="$1"
	[[ -n "$issue_body" ]] || return 0

	# EDIT:/NEW:/File: prefixed paths (brief template format). Keep this
	# intent-aware: backticked paths on ordinary list items are often reference
	# context and must not create false dispatch-overlap deferrals (GH#27787).
	# File requires its explicit colon so prose such as "File refs verified"
	# cannot become a synthetic path claim (GH#28861).
	local prefixed
	# shellcheck disable=SC2016 # Backticks are literal regex characters, not shell expansion.
	prefixed=$(printf '%s' "$issue_body" | grep -oE '((EDIT|NEW):?|File:)[[:space:]]+[`"]?[^`"[:space:],]+' 2>/dev/null |
		sed -E 's/^((EDIT|NEW):?|File:)[[:space:]]*//' | sed 's/^[`"]//' | sed 's/[`"]*$//' | sort -u) || prefixed=""

	# Strip line-number qualifiers — we only care about file-level overlap
	# Handles: file.sh:45, file.sh:45-60, file.sh:1477
	printf '%s' "$prefixed" | sed 's/:[0-9]*\(-[0-9]*\)*$//' | sort -u | grep -v '^$' || true
	return 0
}

#######################################
# Get file footprints for all currently in-flight issues in a repo.
#
# "In-flight" = issue has an active status label (status:in-progress,
# status:in-review, status:claimed) which indicates a worker is currently
# processing it. Issues with status:queued are not yet dispatched and
# don't count. Parent-task issues are coordination containers, not worker
# implementation claims, so their broad planning footprints do not block
# worker-ready child dispatch.
#
# Returns a newline-separated list of "file|issue_number" pairs.
# Uses a TTL-based cache to avoid repeated API calls within a pulse cycle.
#
# Args:
#   $1 = repo_slug (owner/repo)
#   $2 = (optional) issue to exclude from results (the candidate itself)
# Output: "file_path|issue_number" pairs, one per line
# Exit: always 0
#######################################
_footprint_get_inflight() {
	local repo_slug="$1"
	local exclude_issue="${2:-}"

	local now_epoch
	now_epoch=$(date +%s)

	# Check cache validity
	if [[ "$_FOOTPRINT_CACHE_REPO" == "$repo_slug" ]] &&
		[[ -n "$_FOOTPRINT_CACHE_DATA" ]] &&
		[[ $((now_epoch - _FOOTPRINT_CACHE_EPOCH)) -lt $_FOOTPRINT_CACHE_TTL ]]; then
		# Cache hit — filter out excluded issue and return
		# Use printf '%b' to expand \n sequences stored in cache
		if [[ -n "$exclude_issue" ]]; then
			printf '%b' "$_FOOTPRINT_CACHE_DATA" | grep -v "|${exclude_issue}$" | grep -v '^$' || true
		else
			printf '%b' "$_FOOTPRINT_CACHE_DATA" | grep -v '^$' || true
		fi
		return 0
	fi

	# Cache miss — rebuild.
	# t3043: parallelise the 3 gh issue list calls. Previously serial
	# (3x 5-15s = 15-45s on cold cache); now concurrent via temp files
	# and background jobs (max(5-15s) ≈ 5-15s — 3x faster on cache miss).
	local _fp_tmpdir
	_fp_tmpdir=$(mktemp -d 2>/dev/null) || _fp_tmpdir="/tmp/fp-$$"
	mkdir -p "$_fp_tmpdir" 2>/dev/null || true

	# Launch all 3 queries in parallel
	(gh issue list --repo "$repo_slug" --label "status:in-progress" --state open \
		--json number,body,labels --limit 50 2>/dev/null || echo "[]") >"${_fp_tmpdir}/in-progress.json" &
	local _fp_pid1=$!

	(gh issue list --repo "$repo_slug" --label "status:in-review" --state open \
		--json number,body,labels --limit 50 2>/dev/null || echo "[]") >"${_fp_tmpdir}/in-review.json" &
	local _fp_pid2=$!

	(gh issue list --repo "$repo_slug" --label "status:claimed" --state open \
		--json number,body,labels --limit 50 2>/dev/null || echo "[]") >"${_fp_tmpdir}/claimed.json" &
	local _fp_pid3=$!

	# Wait for all to complete
	wait "$_fp_pid1" 2>/dev/null || true
	wait "$_fp_pid2" 2>/dev/null || true
	wait "$_fp_pid3" 2>/dev/null || true

	local inflight_issues review_issues claimed_issues
	inflight_issues=$(cat "${_fp_tmpdir}/in-progress.json" 2>/dev/null) || inflight_issues="[]"
	review_issues=$(cat "${_fp_tmpdir}/in-review.json" 2>/dev/null) || review_issues="[]"
	claimed_issues=$(cat "${_fp_tmpdir}/claimed.json" 2>/dev/null) || claimed_issues="[]"

	# Cleanup temp files
	rm -rf "$_fp_tmpdir" 2>/dev/null || true

	# Merge all three lists into one (jq handles dedup by number)
	local all_inflight
	all_inflight=$(printf '%s\n%s\n%s' "$inflight_issues" "$review_issues" "$claimed_issues" |
		jq -s 'add | unique_by(.number)' 2>/dev/null) || all_inflight="[]"

	local issue_count
	issue_count=$(printf '%s' "$all_inflight" | jq 'length' 2>/dev/null) || issue_count=0
	[[ "$issue_count" =~ ^[0-9]+$ ]] || issue_count=0

	local cache_data=""
	local i=0
	while [[ "$i" -lt "$issue_count" ]]; do
		local num body is_parent_task paths
		num=$(printf '%s' "$all_inflight" | jq -r ".[$i].number // empty" 2>/dev/null)
		body=$(printf '%s' "$all_inflight" | jq -r ".[$i].body // empty" 2>/dev/null)
		is_parent_task=$(printf '%s' "$all_inflight" | jq -r ".[$i] | any((.labels // [])[]?; .name == \"parent-task\")" 2>/dev/null) || is_parent_task="false"
		if [[ "$is_parent_task" == "true" ]]; then
			i=$((i + 1))
			continue
		fi

		if [[ -n "$num" && -n "$body" ]]; then
			paths=$(_footprint_extract_paths "$body")
			if [[ -n "$paths" ]]; then
				while IFS= read -r p; do
					[[ -n "$p" ]] || continue
					cache_data="${cache_data}${p}|${num}\n"
				done <<<"$paths"
			fi
		fi
		i=$((i + 1))
	done

	# Store in cache
	_FOOTPRINT_CACHE_REPO="$repo_slug"
	_FOOTPRINT_CACHE_DATA="$cache_data"
	_FOOTPRINT_CACHE_EPOCH="$now_epoch"

	# Return filtered result
	if [[ -n "$exclude_issue" ]]; then
		printf '%b' "$cache_data" | grep -v "|${exclude_issue}$" | grep -v '^$' || true
	else
		printf '%b' "$cache_data" | grep -v '^$' || true
	fi
	return 0
}

#######################################
# Check if a candidate issue's file footprint overlaps with any in-flight issue.
#
# This is the main entry point called from _dispatch_dedup_check_layers.
#
# Args:
#   $1 = issue_number (candidate being considered for dispatch)
#   $2 = repo_slug (owner/repo)
#   $3 = issue_body (body text of the candidate issue)
# Output: on overlap, prints "FOOTPRINT_OVERLAP (issue=#<blocking> files=<list>)"
# Exit:
#   0 = overlap found (do NOT dispatch — defer one cycle)
#   1 = no overlap (safe to dispatch)
#######################################
_footprint_check_overlap() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_body="$3"

	[[ -n "$issue_body" ]] || return 1

	# Extract candidate's file footprint
	local candidate_files
	candidate_files=$(_footprint_extract_paths "$issue_body")
	[[ -n "$candidate_files" ]] || return 1

	# Get in-flight footprints (excluding self)
	local inflight_data
	inflight_data=$(_footprint_get_inflight "$repo_slug" "$issue_number")
	[[ -n "$inflight_data" ]] || return 1

	# Check each candidate file against in-flight footprints
	local overlapping_files=""
	local blocking_issue=""
	while IFS= read -r candidate_file; do
		[[ -n "$candidate_file" ]] || continue

		# Normalise: strip leading ./ or .agents/ for comparison
		local norm_candidate
		norm_candidate=$(printf '%s' "$candidate_file" | sed 's|^\./||' | sed 's|^\.agents/||')

		# Check against each in-flight file
		while IFS= read -r inflight_entry; do
			[[ -n "$inflight_entry" ]] || continue
			local inflight_file="${inflight_entry%|*}"
			local inflight_issue="${inflight_entry##*|}"

			local norm_inflight
			norm_inflight=$(printf '%s' "$inflight_file" | sed 's|^\./||' | sed 's|^\.agents/||')

			if [[ "$norm_candidate" == "$norm_inflight" ]]; then
				overlapping_files="${overlapping_files}${candidate_file}, "
				blocking_issue="$inflight_issue"
				break
			fi
		done <<<"$inflight_data"
	done <<<"$candidate_files"

	if [[ -n "$overlapping_files" && -n "$blocking_issue" ]]; then
		# Trim trailing ", "
		overlapping_files="${overlapping_files%, }"
		printf 'FOOTPRINT_OVERLAP (issue=#%s files=%s)\n' "$blocking_issue" "$overlapping_files"
		return 0
	fi

	return 1
}

#######################################
# Evict all cache entries for a specific issue number.
#
# Called after an issue closes (PR merge, worktree cleanup, stale reset,
# claim release) so the next _footprint_check_overlap call does not
# produce a stale FOOTPRINT_OVERLAP defer against the already-closed
# issue. This provides immediate eviction on known-close events;
# _FOOTPRINT_CACHE_TTL bounds the maximum stale window for untracked
# closes. (t2927/GH#21103)
#
# Safe to call when the cache is empty or the issue is not in the cache —
# both are no-ops. Safe to call when dispatch-dedup-footprint.sh is not
# sourced — callers guard with `declare -F ... && ...`.
#
# Args:
#   $1 = issue_num (number of the issue to evict)
# Exit: always 0
#######################################
invalidate_footprint_cache_for_issue() {
	local issue_num="$1"
	[[ -n "$issue_num" ]] || return 0
	[[ -n "$_FOOTPRINT_CACHE_DATA" ]] || return 0

	# Rebuild cache without entries for this issue.
	# Cache stores "file_path|issue_num\n" (literal \n separators).
	# printf '%b' expands \n to actual newlines for line-by-line filtering.
	local _new_cache_data=""
	local _cache_entry _cache_issue
	while IFS= read -r _cache_entry; do
		[[ -n "$_cache_entry" ]] || continue
		_cache_issue="${_cache_entry##*|}"
		[[ "$_cache_issue" == "$issue_num" ]] && continue
		_new_cache_data="${_new_cache_data}${_cache_entry}\n"
	done <<<"$(printf '%b' "$_FOOTPRINT_CACHE_DATA")"
	_FOOTPRINT_CACHE_DATA="$_new_cache_data"
	return 0
}
