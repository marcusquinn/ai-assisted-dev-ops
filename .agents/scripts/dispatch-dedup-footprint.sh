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

# Cross-cycle defer state. The live overlap check remains authoritative; this
# state only suppresses unchanged reconsideration until a bounded wake event.
_FOOTPRINT_DEFER_STATE_DIR="${AIDEVOPS_FOOTPRINT_DEFER_STATE_DIR:-${HOME}/.aidevops/cache/footprint-defers}"
_FOOTPRINT_DEFER_TTL_SECONDS="${AIDEVOPS_FOOTPRINT_DEFER_TTL_SECONDS:-1800}"
[[ "$_FOOTPRINT_DEFER_TTL_SECONDS" =~ ^[1-9][0-9]*$ ]] || _FOOTPRINT_DEFER_TTL_SECONDS=1800
_FOOTPRINT_DEFER_SCHEMA="aidevops-footprint-defer/v1"

# Maximum age of the footprint cache in seconds. After this, rebuild.
# 30s: long enough to catch concurrent same-file dispatch races (the
# original use-case), short enough to limit blast radius when issues
# close mid-window. See invalidate_footprint_cache_for_issue() for
# immediate eviction on known-close events (t2927/GH#21103).
_FOOTPRINT_CACHE_TTL=30

#######################################
# Compute a portable SHA-256 digest for text.
# Args: $1 = text
# Output: lowercase hex digest
# Exit: 0 on success, 1 when no digest implementation is available
#######################################
_footprint_hash_text() {
	local value="$1"
	local digest=""
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | sha256sum | awk '{print $1}') || return 1
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | shasum -a 256 | awk '{print $1}') || return 1
	elif command -v openssl >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | openssl dgst -sha256 | awk '{print $NF}') || return 1
	else
		return 1
	fi
	[[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || return 1
	printf '%s\n' "$digest" | tr '[:upper:]' '[:lower:]'
	return 0
}

#######################################
# Prepare the private defer-state directory.
# Exit: 0 when safe, 1 otherwise
#######################################
_footprint_defer_prepare_dir() {
	local state_dir="$_FOOTPRINT_DEFER_STATE_DIR"
	if [[ ! -e "$state_dir" && ! -L "$state_dir" ]]; then
		(umask 077 && mkdir -p "$state_dir") || return 1
	fi
	[[ -d "$state_dir" && ! -L "$state_dir" && -O "$state_dir" ]] || return 1
	chmod 0700 "$state_dir" 2>/dev/null || return 1
	return 0
}

#######################################
# Resolve the state path for a repository candidate without exposing the slug
# in the filename.
# Args: $1 = repo slug, $2 = candidate issue
# Output: absolute state path
#######################################
_footprint_defer_state_path() {
	local repo_slug="$1"
	local issue_number="$2"
	local repo_hash=""
	local normalized_repo=""
	normalized_repo=$(printf '%s' "$repo_slug" | tr '[:upper:]' '[:lower:]')
	repo_hash=$(_footprint_hash_text "$normalized_repo") || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	printf '%s/%s-%s.json\n' "$_FOOTPRINT_DEFER_STATE_DIR" "$repo_hash" "$issue_number"
	return 0
}

#######################################
# Atomically write one validated defer-state object.
# Args: $1 = destination path, $2 = JSON object
#######################################
_footprint_defer_write_json() {
	local state_path="$1"
	local state_json="$2"
	local temp_path=""
	command -v jq >/dev/null 2>&1 || return 1
	printf '%s' "$state_json" | jq -e --arg schema "$_FOOTPRINT_DEFER_SCHEMA" '.schema == $schema' >/dev/null 2>&1 || return 1
	_footprint_defer_prepare_dir || return 1
	temp_path=$(mktemp "${_FOOTPRINT_DEFER_STATE_DIR}/.defer.XXXXXX" 2>/dev/null) || return 1
	if ! printf '%s\n' "$state_json" >"$temp_path"; then
		rm -f "$temp_path" 2>/dev/null || true
		return 1
	fi
	chmod 0600 "$temp_path" 2>/dev/null || {
		rm -f "$temp_path" 2>/dev/null || true
		return 1
	}
	if ! mv -f "$temp_path" "$state_path"; then
		rm -f "$temp_path" 2>/dev/null || true
		return 1
	fi
	return 0
}

#######################################
# Read one structurally valid defer record.
# Args: $1 = state path
# Output: compact JSON
#######################################
_footprint_defer_read_json() {
	local state_path="$1"
	[[ -f "$state_path" && ! -L "$state_path" && -O "$state_path" ]] || return 1
	jq -ce --arg schema "$_FOOTPRINT_DEFER_SCHEMA" '
		select(.schema == $schema)
		| select([.candidate_issue, .blocking_issue, .expires_at] | all(type == "number"))
		| select((.candidate_hash | type) == "string")
		| select((.blocker_hash | type) == "string")
	' "$state_path" 2>/dev/null
	return $?
}

#######################################
# Persist a wake/tombstone so diagnostics can explain why suppression ended.
# Args: $1 = state path, $2 = current JSON, $3 = wake reason
#######################################
_footprint_defer_wake() {
	local state_path="$1"
	local state_json="$2"
	local wake_reason="$3"
	local now_epoch=""
	local updated_json=""
	now_epoch=$(date +%s)
	updated_json=$(printf '%s' "$state_json" | jq -c \
		--arg reason "$wake_reason" --argjson now "$now_epoch" \
		'.active = false | .wake_reason = $reason | .wake_at = $now') || return 1
	_footprint_defer_write_json "$state_path" "$updated_json" || return 1
	if [[ -n "${LOGFILE:-}" ]]; then
		local candidate_issue=""
		local repo_slug=""
		local blocking_issue=""
		candidate_issue=$(printf '%s' "$updated_json" | jq -r '.candidate_issue')
		repo_slug=$(printf '%s' "$updated_json" | jq -r '.repo_slug')
		blocking_issue=$(printf '%s' "$updated_json" | jq -r '.blocking_issue')
		printf '[footprint-defer] event=wake issue=#%s repo=%s blocker=#%s wake_reason=%s ts=%s\n' \
			"$candidate_issue" "$repo_slug" "$blocking_issue" "$wake_reason" "$now_epoch" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Record a newly confirmed live overlap. This runs inside the overlap command
# substitution, so only filesystem/log side effects are used.
# Args: candidate issue, repo slug, candidate files, inflight data,
#       blocking issue, overlapping files
#######################################
_footprint_defer_record_overlap() {
	local issue_number="$1"
	local repo_slug="$2"
	local candidate_files="$3"
	local inflight_data="$4"
	local blocking_issue="$5"
	local overlapping_files="$6"
	local blocker_files=""
	local candidate_hash="" blocker_hash="" state_path="" existing_json=""
	local now_epoch="" expires_at=""
	local state_json=""
	command -v jq >/dev/null 2>&1 || return 0
	blocker_files=$(printf '%s\n' "$inflight_data" | awk -F '|' -v issue="$blocking_issue" '$2 == issue {print $1}' | sort -u)
	[[ -n "$blocker_files" ]] || return 0
	candidate_hash=$(_footprint_hash_text "$candidate_files") || return 0
	blocker_hash=$(_footprint_hash_text "$blocker_files") || return 0
	state_path=$(_footprint_defer_state_path "$repo_slug" "$issue_number") || return 0
	if existing_json=$(_footprint_defer_read_json "$state_path"); then
		if printf '%s' "$existing_json" | jq -e \
			--arg candidate "$candidate_hash" --arg blocker "$blocker_hash" --argjson blocking "$blocking_issue" \
			'.active == true and .candidate_hash == $candidate and .blocker_hash == $blocker and .blocking_issue == $blocking' >/dev/null 2>&1; then
			return 0
		fi
	fi
	now_epoch=$(date +%s)
	expires_at=$((now_epoch + _FOOTPRINT_DEFER_TTL_SECONDS))
	state_json=$(jq -cn \
		--arg schema "$_FOOTPRINT_DEFER_SCHEMA" \
		--arg repo "$repo_slug" \
		--arg candidate_hash "$candidate_hash" \
		--arg blocker_hash "$blocker_hash" \
		--arg overlapping_files "$overlapping_files" \
		--argjson candidate_issue "$issue_number" \
		--argjson blocking_issue "$blocking_issue" \
		--argjson created_at "$now_epoch" \
		--argjson expires_at "$expires_at" \
		'{schema:$schema,repo_slug:$repo,candidate_issue:$candidate_issue,blocking_issue:$blocking_issue,candidate_hash:$candidate_hash,blocker_hash:$blocker_hash,overlapping_files:$overlapping_files,created_at:$created_at,expires_at:$expires_at,suppressed_count:0,active:true,wake_reason:"none",wake_at:0}') || return 0
	_footprint_defer_write_json "$state_path" "$state_json" || return 0
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '[footprint-defer] event=deferred issue=#%s repo=%s blocker=#%s expires_at=%s suppressed=0 wake_reason=none\n' \
			"$issue_number" "$repo_slug" "$blocking_issue" "$expires_at" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Return success when an unchanged durable overlap should suppress this cycle.
# Missing/corrupt/stale state falls through to the authoritative live check.
# Args: $1 = candidate issue, $2 = repo slug, $3 = candidate JSON
# Exit: 0 suppress, 1 reconsider normally
#######################################
_footprint_defer_should_suppress() {
	local issue_number="$1"
	local repo_slug="$2"
	local candidate_json="$3"
	local state_path=""
	local state_json=""
	local candidate_body="" candidate_files="" candidate_hash=""
	local now_epoch="" expires_at=""
	local blocking_issue="" blocker_json="" blocker_state=""
	local blocker_files="" blocker_hash="" updated_json="" suppressed_count=""
	state_path=$(_footprint_defer_state_path "$repo_slug" "$issue_number") || return 1
	if ! state_json=$(_footprint_defer_read_json "$state_path"); then
		[[ -e "$state_path" || -L "$state_path" ]] && rm -f "$state_path" 2>/dev/null || true
		return 1
	fi
	printf '%s' "$state_json" | jq -e '.active == true' >/dev/null 2>&1 || return 1
	if printf '%s' "$candidate_json" | jq -e '[(.labels // [])[]? | if type == "object" then .name else . end] | index("force-dispatch") != null' >/dev/null 2>&1; then
		_footprint_defer_wake "$state_path" "$state_json" "operator_reconsideration" || true
		return 1
	fi
	candidate_body=$(printf '%s' "$candidate_json" | jq -r '.body // ""' 2>/dev/null) || candidate_body=""
	candidate_files=$(_footprint_extract_paths "$candidate_body")
	[[ -n "$candidate_files" ]] || {
		_footprint_defer_wake "$state_path" "$state_json" "candidate_footprint_changed" || true
		return 1
	}
	candidate_hash=$(_footprint_hash_text "$candidate_files") || return 1
	if ! printf '%s' "$state_json" | jq -e --arg hash "$candidate_hash" '.candidate_hash == $hash' >/dev/null 2>&1; then
		_footprint_defer_wake "$state_path" "$state_json" "candidate_footprint_changed" || true
		return 1
	fi
	now_epoch=$(date +%s)
	expires_at=$(printf '%s' "$state_json" | jq -r '.expires_at')
	if [[ ! "$expires_at" =~ ^[0-9]+$ || "$now_epoch" -ge "$expires_at" ]]; then
		_footprint_defer_wake "$state_path" "$state_json" "cooldown_expired" || true
		return 1
	fi
	blocking_issue=$(printf '%s' "$state_json" | jq -r '.blocking_issue')
	if declare -F gh_issue_view >/dev/null 2>&1; then
		blocker_json=$(gh_issue_view "$blocking_issue" --repo "$repo_slug" --json number,state,labels,body 2>/dev/null) || blocker_json=""
	else
		blocker_json=$(gh issue view "$blocking_issue" --repo "$repo_slug" --json number,state,labels,body 2>/dev/null) || blocker_json=""
	fi
	if [[ -n "$blocker_json" ]]; then
		blocker_state=$(printf '%s' "$blocker_json" | jq -r '.state // ""' | tr '[:lower:]' '[:upper:]')
		if [[ "$blocker_state" != "OPEN" ]] || ! printf '%s' "$blocker_json" | jq -e \
			'[(.labels // [])[]? | if type == "object" then .name else . end] | any(. == "status:in-progress" or . == "status:in-review" or . == "status:claimed")' >/dev/null 2>&1; then
			_footprint_defer_wake "$state_path" "$state_json" "blocker_lifecycle_changed" || true
			return 1
		fi
		blocker_files=$(_footprint_extract_paths "$(printf '%s' "$blocker_json" | jq -r '.body // ""')")
		blocker_hash=$(_footprint_hash_text "$blocker_files") || blocker_hash=""
		if [[ -z "$blocker_hash" ]] || ! printf '%s' "$state_json" | jq -e --arg hash "$blocker_hash" '.blocker_hash == $hash' >/dev/null 2>&1; then
			_footprint_defer_wake "$state_path" "$state_json" "blocker_footprint_changed" || true
			return 1
		fi
	fi
	suppressed_count=$(printf '%s' "$state_json" | jq -r '.suppressed_count // 0')
	[[ "$suppressed_count" =~ ^[0-9]+$ ]] || suppressed_count=0
	suppressed_count=$((suppressed_count + 1))
	updated_json=$(printf '%s' "$state_json" | jq -c --argjson count "$suppressed_count" --argjson checked "$now_epoch" \
		'.suppressed_count = $count | .last_checked_at = $checked') || updated_json=""
	[[ -n "$updated_json" ]] && _footprint_defer_write_json "$state_path" "$updated_json" || true
	return 0
}

#######################################
# Return the current/tombstoned defer record for diagnostics.
# Args: $1 = issue number, $2 = repo slug
# Output: compact JSON (or an inactive empty object)
#######################################
_footprint_defer_empty_status_json() {
	local wake_reason="$1"
	jq -cn --arg reason "$wake_reason" '{active:false,wake_reason:$reason}' 2>/dev/null || printf '{}\n'
	return 0
}

_footprint_defer_status_json() {
	local issue_number="$1"
	local repo_slug="$2"
	local state_path=""
	local state_json=""
	local now_epoch=""
	state_path=$(_footprint_defer_state_path "$repo_slug" "$issue_number") || {
		_footprint_defer_empty_status_json "unavailable"
		return 0
	}
	if ! state_json=$(_footprint_defer_read_json "$state_path"); then
		_footprint_defer_empty_status_json "none"
		return 0
	fi
	now_epoch=$(date +%s)
	printf '%s' "$state_json" | jq -c --argjson now "$now_epoch" '
		. + {
			age_seconds: ([$now - (.created_at // $now), 0] | max),
			cooldown_remaining_seconds: ([.expires_at - $now, 0] | max)
		}' 2>/dev/null || _footprint_defer_empty_status_json "parse_error"
	return 0
}

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
		_footprint_defer_record_overlap "$issue_number" "$repo_slug" "$candidate_files" \
			"$inflight_data" "$blocking_issue" "$overlapping_files"
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

	# Rebuild cache without entries for this issue.
	# Cache stores "file_path|issue_num\n" (literal \n separators).
	# printf '%b' expands \n to actual newlines for line-by-line filtering.
	local _new_cache_data=""
	local _cache_entry _cache_issue
	if [[ -n "$_FOOTPRINT_CACHE_DATA" ]]; then
		while IFS= read -r _cache_entry; do
			[[ -n "$_cache_entry" ]] || continue
			_cache_issue="${_cache_entry##*|}"
			[[ "$_cache_issue" == "$issue_num" ]] && continue
			_new_cache_data="${_new_cache_data}${_cache_entry}\n"
		done <<<"$(printf '%b' "$_FOOTPRINT_CACHE_DATA")"
		_FOOTPRINT_CACHE_DATA="$_new_cache_data"
	fi

	# Wake any durable record where this issue is either candidate or blocker.
	# The caller does not always know the repository, so conservatively scan the
	# private bounded state directory; issue-number collisions only cause a safe
	# extra live overlap check.
	local state_path=""
	local state_json=""
	local candidate_issue=""
	local blocking_issue=""
	if [[ -d "$_FOOTPRINT_DEFER_STATE_DIR" && ! -L "$_FOOTPRINT_DEFER_STATE_DIR" ]]; then
		for state_path in "$_FOOTPRINT_DEFER_STATE_DIR"/*.json; do
			[[ -f "$state_path" && ! -L "$state_path" ]] || continue
			state_json=$(_footprint_defer_read_json "$state_path") || continue
			printf '%s' "$state_json" | jq -e '.active == true' >/dev/null 2>&1 || continue
			candidate_issue=$(printf '%s' "$state_json" | jq -r '.candidate_issue')
			blocking_issue=$(printf '%s' "$state_json" | jq -r '.blocking_issue')
			if [[ "$candidate_issue" == "$issue_num" || "$blocking_issue" == "$issue_num" ]]; then
				_footprint_defer_wake "$state_path" "$state_json" "lifecycle_invalidation" || true
			fi
		done
	fi
	return 0
}
