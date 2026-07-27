#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Triage Cache -- Content-hash dedup cache, bot-skip detection, and
# idempotent GH-comment helper.
# =============================================================================
# Extracted from pulse-triage.sh as part of the file-size-debt split
# (parent: GH#21146, child: GH#21326).
#
# Functions in this sub-library:
#   - _triage_content_hash
#   - _triage_is_cached
#   - _triage_update_cache
#   - _triage_increment_failure
#   - _triage_awaiting_contributor_reply
#   - _gh_idempotent_comment
#
# Usage: source "${SCRIPT_DIR}/pulse-triage-cache.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - TRIAGE_CACHE_DIR, TRIAGE_MAX_RETRIES, LOGFILE (set by orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_TRIAGE_CACHE_LIB_LOADED:-}" ]] && return 0
_PULSE_TRIAGE_CACHE_LIB_LOADED=1
_PTC_JSON_ARRAY_TYPE="array"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

# Filter fetched comments through the single trust-boundary definition shared by
# cache hashing and awaiting-contributor detection. Only GitHub-confirmed
# collaborators' marked review comments and GitHub Actions comments are hidden.
# Args: $1=comments JSON array, $2=trusted review marker
# Outputs: filtered comments JSON array
_triage_visible_human_comments_json() {
	local comments_json="$1"
	local review_marker="$2"

	printf '%s' "$comments_json" | jq -c \
		--arg marker "$review_marker" --arg array_type "$_PTC_JSON_ARRAY_TYPE" '
		if type != $array_type then error("invalid comments payload") else
			def trusted_author_association:
				(.association // "") as $association
				| ["OWNER", "MEMBER", "COLLABORATOR"] | index($association) != null;
			def automation_author:
				(.author // "") as $author
				| ["github-actions[bot]", "github-actions"] | index($author) != null;
			[.[]
				| select((automation_author | not))
				| select((
					trusted_author_association and
					((.body // "") | contains($marker))
				) | not)]
		end' 2>/dev/null || return 1
	return 0
}

# Compute a content hash from every public input that can affect triage.
# Excludes github-actions[bot] comments and marked triage reviews posted by a
# GitHub-confirmed collaborator. A public contributor can copy the heading or
# hidden marker, so neither string alone is a trust boundary. The schema prefix
# intentionally invalidates earlier GH#28705 decisions when snapshot identity
# gains another security-relevant public input.
#
# Args: $1=issue_num, $2=repo_slug, $3=body, $4=comments_json,
#       $5=item_kind, $6=PR base SHA, $7=PR head SHA, $8=PR diff,
#       $9=PR files JSON, $10=GitHub-verified public evidence revision,
#       $11=issue/PR title, $12=canonical label-name JSON
# Outputs: sha256 hash to stdout
_triage_content_hash() {
	local issue_num="$1"
	local repo_slug="$2"
	local body="$3"
	local comments_json="$4"
	local item_kind="${5:-issue}"
	local pr_base_sha="${6:-}"
	local pr_head_sha="${7:-}"
	local pr_diff="${8:-}"
	local pr_files="${9:-}"
	local public_revision="${10:-}"
	local issue_title="${11:-}"
	local issue_labels_json="${12:-[]}"
	local cache_schema="${TRIAGE_CACHE_SCHEMA_VERSION:-6}"
	local review_marker="${TRIAGE_REVIEW_COMMENT_MARKER:-<!-- aidevops:triage-review -->}"
	: "$issue_num" "$repo_slug"

	# #aidevops:trust-boundary — only a marked comment whose GitHub-provided
	# author association is trusted can be omitted. Contributor-authored review
	# headings and copied markers remain hash inputs and therefore retrigger
	# triage. Malformed comment JSON is an infrastructure failure, not an empty
	# comment list that could produce a false cache hit.
	local visible_comments_json=""
	visible_comments_json=$(_triage_visible_human_comments_json \
		"$comments_json" "$review_marker") || return 1
	local human_comments=""
	human_comments=$(printf '%s' "$visible_comments_json" | jq -cS '
		[.[] | {
			id: (.id // null),
			author: (.author // ""),
			association: (.association // ""),
			body: (.body // ""),
			created: (.created // ""),
			updated: (.updated // .created // "")
		}] | sort_by(.id)' 2>/dev/null) || return 1
	local canonical_issue_labels=""
	canonical_issue_labels=$(printf '%s' "$issue_labels_json" | jq -ceS '
		if type == "array" and all(.[]; type == "string") then sort
		else error("malformed issue labels") end' 2>/dev/null) || return 1

	printf 'triage-cache-v%s\nkind:%s\nbase:%s\nhead:%s\npublic:%s\ntitle:\n%s\nlabels:\n%s\nbody:\n%s\ncomments:\n%s\ndiff:\n%s\nfiles:\n%s' \
		"$cache_schema" "$item_kind" "$pr_base_sha" "$pr_head_sha" "$public_revision" \
		"$issue_title" "$canonical_issue_labels" "$body" "$human_comments" "$pr_diff" "$pr_files" \
		| shasum -a 256 | cut -d' ' -f1
	return 0
}

# Check if triage content hash matches the cached value.
# Returns 0 if content is unchanged (skip triage), 1 if changed or uncached.
#
# Args: $1=issue_num, $2=repo_slug, $3=current_hash
_triage_is_cached() {
	local issue_num="$1"
	local repo_slug="$2"
	local current_hash="$3"
	local slug_safe="${repo_slug//\//_}"
	local cache_file="${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.hash"

	[[ -f "$cache_file" ]] || return 1

	local cached_hash=""
	cached_hash=$(cat "$cache_file" 2>/dev/null) || return 1
	[[ "$cached_hash" == "$current_hash" ]] && return 0
	return 1
}

# Update the triage content hash cache after a triage attempt.
#
# Args: $1=issue_num, $2=repo_slug, $3=content_hash
_triage_update_cache() {
	local issue_num="$1"
	local repo_slug="$2"
	local content_hash="$3"
	local slug_safe="${repo_slug//\//_}"

	mkdir -p "$TRIAGE_CACHE_DIR" 2>/dev/null || true
	printf '%s' "$content_hash" >"${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.hash" 2>/dev/null || true
	# Reset failure counter on successful cache write
	rm -f "${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.failures" 2>/dev/null || true
	return 0
}

# Increment failure counter and return whether retry cap is reached.
# Returns 0 if cap reached (should cache anyway), 1 if retries remain.
#
# Args: $1=issue_num, $2=repo_slug, $3=content_hash
_triage_increment_failure() {
	local issue_num="$1"
	local repo_slug="$2"
	local content_hash="$3"
	local slug_safe="${repo_slug//\//_}"
	local fail_file="${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.failures"

	mkdir -p "$TRIAGE_CACHE_DIR" 2>/dev/null || true

	local current_count=0
	local stored_hash=""
	if [[ -f "$fail_file" ]]; then
		# Format: "hash:count"
		stored_hash=$(cut -d: -f1 "$fail_file" 2>/dev/null) || stored_hash=""
		current_count=$(cut -d: -f2 "$fail_file" 2>/dev/null) || current_count=0
		# Reset counter if hash changed (new content since last failure)
		if [[ "$stored_hash" != "$content_hash" ]]; then
			current_count=0
		fi
	fi

	current_count=$((current_count + 1))
	printf '%s:%d' "$content_hash" "$current_count" >"$fail_file" 2>/dev/null || true

	if [[ "$current_count" -ge "$TRIAGE_MAX_RETRIES" ]]; then
		return 0
	fi
	return 1
}

#######################################
# GH#17827: Check if an NMR issue is awaiting a contributor reply.
#
# When the last human comment on an NMR issue is from a repo collaborator
# (maintainer asking for clarification), the ball is in the contributor's
# court. Triage adds no value — the issue needs the contributor to respond,
# not another automated review. Skipping triage here avoids the lock/unlock
# noise entirely.
#
# Args: $1=issue_comments (JSON array from gh api)
#       $2=repo_slug
# Returns: 0 if awaiting contributor reply (skip triage), 1 otherwise
#######################################
_triage_awaiting_contributor_reply() {
	local issue_comments="$1"
	local repo_slug="$2"

	# Get the last human comment. As with cache hashing, a review heading or
	# marker copied by a contributor is not trusted and must remain visible.
	local review_marker="${TRIAGE_REVIEW_COMMENT_MARKER:-<!-- aidevops:triage-review -->}"
	local visible_comments_json=""
	visible_comments_json=$(_triage_visible_human_comments_json \
		"$issue_comments" "$review_marker") || return 1
	local last_human_author=""
	last_human_author=$(printf '%s' "$visible_comments_json" | jq -r '
		last
		| .author // ""' 2>/dev/null) || return 1

	[[ -n "$last_human_author" ]] || return 1

	# Check if the last commenter is a repo collaborator (maintainer/member)
	local perm_level=""
	# #aidevops:trust-boundary — contributor-reply triage skipping requires a
	# confirmed collaborator; permission lookup failures keep triage eligible.
	_gh_collaborator_permission_lookup "$repo_slug" "$last_human_author" perm_level || return 1

	case "$perm_level" in
	admin | maintain | write)
		# Last comment is from a collaborator — awaiting contributor reply
		return 0
		;;
	esac

	return 1
}

#######################################
# Idempotent comment posting: race-safe primitive for gate comments.
#
# Multiple pulse instances (different maintainers/machines) can race
# when posting gate comments (consolidation, simplification, blocker).
# Label-only guards have a TOCTOU window: both pulses read "no label",
# both post, producing duplicate comments (observed: GH#17898).
#
# This function checks existing comments for a marker string before
# posting. Fails closed on API errors (never posts if it can't confirm
# the comment is absent).
#
# Arguments:
#   $1 - entity_number (issue or PR number)
#   $2 - repo_slug (owner/repo)
#   $3 - marker (unique string to grep for in existing comments)
#   $4 - comment_body (full comment text to post)
#   $5 - entity_type ("issue" or "pr", default "issue")
#
# Returns:
#   0 - comment posted successfully OR already existed (idempotent)
#   1 - API error fetching comments (fail-closed, caller should retry)
#   2 - missing arguments
#
# Usage:
#   _gh_idempotent_comment "$issue_number" "$repo_slug" \
#       "## Issue Consolidation Needed" "$comment_body"
#######################################
_gh_idempotent_comment() {
	local entity_number="$1"
	local repo_slug="$2"
	local marker="$3"
	local comment_body="$4"
	local entity_type="${5:-issue}"

	if [[ -z "$entity_number" || -z "$repo_slug" || -z "$marker" || -z "$comment_body" ]]; then
		echo "[pulse-wrapper] _gh_idempotent_comment: missing arguments (entity=$entity_number repo=$repo_slug marker_len=${#marker})" >>"$LOGFILE"
		return 2
	fi

	# Fetch existing issue comments and check for marker. Pull-request
	# conversation comments use this same REST endpoint; native `gh pr view
	# --json comments` is GraphQL-only and cannot expose response-owned cost.
	local existing_comments=""
	# t3565: GitHub's issue-comments REST endpoint defaults to the oldest
	# 30 comments. Long-running issues and PRs can have idempotency markers
	# beyond page 1, so normalize paginated gh output before grepping.
	existing_comments=$(set -o pipefail; gh api "repos/${repo_slug}/issues/${entity_number}/comments?per_page=100" \
		--paginate --slurp | jq -r --arg array_type "$_PTC_JSON_ARRAY_TYPE" '
			(if (type == $array_type and ((.[0]? | type) == $array_type)) then .[] else . end)[]
			| .body // ""
		')
	local api_exit=$?

	if [[ $api_exit -ne 0 ]]; then
		# API error — fail closed. Never post when we can't confirm absence.
		echo "[pulse-wrapper] _gh_idempotent_comment: API error (exit=$api_exit) fetching comments for #${entity_number} in ${repo_slug} — skipping (fail closed)" >>"$LOGFILE"
		return 1
	fi

	# Check if marker already exists in any comment
	if printf '%s' "$existing_comments" | grep -qF "$marker"; then
		echo "[pulse-wrapper] _gh_idempotent_comment: marker already present on #${entity_number} in ${repo_slug} — skipping duplicate" >>"$LOGFILE"
		return 0
	fi

	# Marker not found — safe to post
	# t2393: route through gh_{issue,pr}_comment wrappers for sig footer.
	if [[ "$entity_type" == "pr" ]]; then
		gh_pr_comment "$entity_number" --repo "$repo_slug" \
			--body "$comment_body" 2>/dev/null || true
	else
		gh_issue_comment "$entity_number" --repo "$repo_slug" \
			--body "$comment_body" 2>/dev/null || true
	fi

	echo "[pulse-wrapper] _gh_idempotent_comment: posted gate comment on #${entity_number} in ${repo_slug} (marker: ${marker:0:40}...)" >>"$LOGFILE"
	return 0
}
