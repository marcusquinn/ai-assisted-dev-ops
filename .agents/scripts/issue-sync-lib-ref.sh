#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Using /bin/bash directly (not #!/usr/bin/env bash) for compatibility with
# headless environments where a stripped PATH can prevent env from finding bash.
# See issue #2610. This is an intentional exception to the repo's env-bash standard (t135.14).
# =============================================================================
# Issue Sync Library — Ref Management Sub-Library
# =============================================================================
# TODO.md ref:GH# and pr:# management, GitHub issue relationships,
# tier extraction/validation, and orphan TODO seeding functions extracted
# from issue-sync-lib.sh for file-size compliance.
#
# Covers:
#   - ref:GH# field fixing, adding, and pr:# backfill in TODO.md
#   - GitHub issue relationship resolution (task ID → issue number, node ID)
#   - Tier extraction and validation from brief files
#   - Parent task ID detection
#   - Orphan TODO seeding helpers (reverse sync from GitHub)
#
# Usage: source "${SCRIPT_DIR}/issue-sync-lib-ref.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_verbose, sed_inplace,
#     print_success)
#   - issue-sync-lib-parse.sh (_escape_ere, strip_code_fences)
#   - bash 3.2+, awk, sed, grep, jq (for _labels_json_to_tags)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_LIB_REF_LOADED:-}" ]] && return 0
_ISSUE_SYNC_LIB_REF_LOADED=1
_ISLR_GRAPHQL_COST_FILTER='.data.rateLimit.cost // empty'
_ISLR_JSON_FALSE="false"
_ISLR_JSON_TRUE="true"
_ISSUE_SYNC_REPOSITORY_ID_CACHE_FILE=""

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Ref Management — TODO.md ref:GH# and pr:# fields
# =============================================================================

_todo_task_line_num() {
	local task_id="$1"
	local todo_file="$2"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")

	awk -v pat="^[[:space:]]*- \\\\[.\\\\] ${task_id_ere} " '
		/^[[:space:]]*```/ {f=!f; next}
		/<!--[[:space:]]*/ {h=1}
		h && /-->/ {h=0; next}
		!f && !h && $0 ~ pat {print NR; exit}
	' "$todo_file"
	return 0
}

# Fix a mismatched ref:GH# in TODO.md (t179.1).
# Replaces old_number with new_number for the given task.
# Arguments:
#   $1 - task_id
#   $2 - old_number
#   $3 - new_number
#   $4 - todo_file path
fix_gh_ref_in_todo() {
	local task_id="$1"
	local old_number="$2"
	local new_number="$3"
	local todo_file="$4"

	if [[ -z "$old_number" || -z "$new_number" || "$old_number" == "$new_number" ]]; then
		return 0
	fi

	# Find line number outside code fences, then replace only that line.
	# NOTE: regex escapes must be doubled in the dynamic `pat` string (t1983) —
	# BSD awk (macOS default) interprets `\[` in `$0 ~ pat` as literal `\` + `[`
	# rather than a single literal `[`, causing the match to silently miss. The
	# `\\[` / `\\]` form is correct on both BSD awk and gawk: awk's dynamic regex
	# compiler reads `\\` as `\` and `\[` as literal `[`.
	local line_num
	line_num=$(_todo_task_line_num "$task_id" "$todo_file")
	[[ -z "$line_num" ]] && {
		log_verbose "$task_id not found outside code fences/comments"
		return 0
	}
	if ! sed -n "${line_num}p" "$todo_file" | grep -qE "ref:GH#${old_number}([[:space:]]|$)"; then
		log_verbose "$task_id with ref:GH#$old_number not found on real task line"
		return 0
	fi
	sed_inplace "${line_num}s|ref:GH#${old_number}|ref:GH#${new_number}|" "$todo_file"
	log_verbose "Fixed ref:GH#$old_number -> ref:GH#$new_number for $task_id"
	return 0
}

# Add ref:GH#NNN to a task line in TODO.md.
# Idempotent — skips if ref already exists.
# Arguments:
#   $1 - task_id
#   $2 - issue_number
#   $3 - todo_file path
add_gh_ref_to_todo() {
	local task_id="$1"
	local issue_number="$2"
	local todo_file="$3"
	local line_num
	line_num=$(_todo_task_line_num "$task_id" "$todo_file")
	[[ -z "$line_num" ]] && {
		log_verbose "$task_id not found outside code fences/comments"
		return 0
	}

	# Read the target line and insert ref
	local target_line
	target_line=$(sed -n "${line_num}p" "$todo_file")
	# Check if ref already exists on the real task line.
	if printf '%s\n' "$target_line" | grep -qE "ref:GH#${issue_number}([[:space:]]|$)"; then
		return 0
	fi

	# Check if any GH ref exists on the real task line (might be different number).
	if printf '%s\n' "$target_line" | grep -qE 'ref:GH#[0-9]+'; then
		log_verbose "$task_id already has a GH ref, skipping"
		return 0
	fi
	local new_line
	if printf '%s\n' "$target_line" | grep -qE '(^|[[:space:]])ref:none([[:space:]]|$)'; then
		new_line=$(printf '%s\n' "$target_line" | sed -E "s/(^|[[:space:]])ref:none([[:space:]]|$)/\\1ref:GH#${issue_number}\\2/")
	elif echo "$target_line" | grep -qE 'logged:'; then
		new_line=$(echo "$target_line" | sed -E "s/( logged:)/ ref:GH#${issue_number}\1/")
	else
		new_line="${target_line} ref:GH#${issue_number}"
	fi

	# Replace only the specific line
	local new_line_escaped
	new_line_escaped=$(printf '%s' "$new_line" | sed 's/[|&\\]/\\&/g')
	sed_inplace "${line_num}s|.*|${new_line_escaped}|" "$todo_file"
	log_verbose "Added ref:GH#$issue_number to $task_id"
	return 0
}

# Add pr:#NNN to a task line in TODO.md (t280).
# Called when a closing PR is discovered that isn't already recorded.
# Ensures the proof-log is complete.
# Arguments:
#   $1 - task_id
#   $2 - pr_number
#   $3 - todo_file path
add_pr_ref_to_todo() {
	local task_id="$1"
	local pr_number="$2"
	local todo_file="$3"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")

	# Check if pr: ref already exists outside code fences
	if strip_code_fences <"$todo_file" | grep -qE "^\s*- \[.\] ${task_id_ere} .*pr:#${pr_number}"; then
		return 0
	fi

	# Check if any pr: ref already exists outside code fences (don't duplicate)
	if strip_code_fences <"$todo_file" | grep -qE "^\s*- \[.\] ${task_id_ere} .*pr:#"; then
		log_verbose "$task_id already has a pr: ref, skipping"
		return 0
	fi

	# Find line number outside code fences, then modify only that line.
	# NOTE: double-backslash escapes in the dynamic `pat` string — required for
	# BSD awk dynamic-regex semantics (t1983).
	local line_num
	line_num=$(awk -v pat="^[[:space:]]*- \\\\[.\\\\] ${task_id_ere} " \
		'/^[[:space:]]*```/{f=!f; next} !f && $0 ~ pat {print NR; exit}' "$todo_file")
	[[ -z "$line_num" ]] && {
		log_verbose "$task_id not found outside code fences for pr: ref"
		return 0
	}

	local target_line
	target_line=$(sed -n "${line_num}p" "$todo_file")
	local new_line
	if echo "$target_line" | grep -qE ' logged:'; then
		new_line=$(echo "$target_line" | sed -E "s/( logged:)/ pr:#${pr_number}\1/")
	elif echo "$target_line" | grep -qE ' completed:'; then
		new_line=$(echo "$target_line" | sed -E "s/( completed:)/ pr:#${pr_number}\1/")
	else
		new_line="${target_line} pr:#${pr_number}"
	fi

	local new_line_escaped
	new_line_escaped=$(printf '%s' "$new_line" | sed 's/[|&\\]/\\&/g')
	sed_inplace "${line_num}s|.*|${new_line_escaped}|" "$todo_file"

	log_verbose "Added pr:#$pr_number to $task_id (t280: backfill proof-log)"
	return 0
}

# =============================================================================
# Relationships — GitHub Issue Relationships (t1889)
# =============================================================================
# Syncs TODO.md dependency metadata (blocked-by:, blocks:, subtask hierarchy)
# to GitHub's native issue relationships via GraphQL mutations:
#   - addBlockedBy / removeBlockedBy — dependency tracking
#   - addSubIssue / removeSubIssue — parent-child hierarchy
#
# These mutations are NOT idempotent — duplicates return validation errors.
# All functions suppress "already taken" / "duplicate sub-issues" errors.

# Resolve an exact repository slug to its immutable GitHub node ID. GraphQL and
# REST availability can diverge, so each transport gets one bounded attempt and
# only a response that proves the requested owner/name may establish identity.
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: repository node ID on stdout, or non-zero when identity is unproven
_github_repository_slug_matches() {
	local expected="$1"
	local actual="$2"
	local expected_normalized="" actual_normalized=""
	[[ -n "$expected" && -n "$actual" ]] || return 1
	expected_normalized=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
	actual_normalized=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
	[[ "$expected_normalized" == "$actual_normalized" ]] && return 0
	return 1
}

_init_issue_sync_repository_id_cache() {
	if [[ -z "$_ISSUE_SYNC_REPOSITORY_ID_CACHE_FILE" ]]; then
		_ISSUE_SYNC_REPOSITORY_ID_CACHE_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-repository-id-cache.XXXXXX") || return 1
	fi
	return 0
}

_issue_sync_cached_repository_id() {
	local repo="$1" cache_file="${_ISSUE_SYNC_REPOSITORY_ID_CACHE_FILE:-}"
	local cached_repo="" cached_id=""
	[[ -f "$cache_file" ]] || return 1
	while IFS='=' read -r cached_repo cached_id; do
		if [[ "$cached_repo" == "$repo" && -n "$cached_id" ]]; then
			printf '%s\n' "$cached_id"
			return 0
		fi
	done <"$cache_file"
	return 1
}

_cache_issue_sync_repository_id() {
	local repo="$1" repository_id="$2"
	local cache_file="${_ISSUE_SYNC_REPOSITORY_ID_CACHE_FILE:-}"
	[[ -n "$repo" && -n "$repository_id" && -f "$cache_file" ]] || return 0
	_issue_sync_cached_repository_id "$repo" >/dev/null 2>&1 || \
		printf '%s=%s\n' "$repo" "$repository_id" >>"$cache_file"
	return 0
}

_cache_issue_sync_node_id() {
	local issue_number="$1" node_id="$2"
	local cache_file="${_NODE_ID_CACHE_FILE:-}"
	[[ "$issue_number" =~ ^[1-9][0-9]*$ && -n "$node_id" && -f "$cache_file" ]] || return 0
	grep -q "^${issue_number}=" "$cache_file" 2>/dev/null || \
		printf '%s=%s\n' "$issue_number" "$node_id" >>"$cache_file"
	return 0
}

resolve_repository_node_id() {
	local repo="$1"
	[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 1
	local owner="${repo%%/*}"
	local name="${repo##*/}"
	local response="" reported_cost="" repository_id="" response_slug="" cached_id=""
	if cached_id=$(_issue_sync_cached_repository_id "$repo"); then
		printf '%s\n' "$cached_id"
		return 0
	fi

	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub, not shell.
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-repository-id-exact-cost" \
		_gh_with_timeout read gh api graphql \
		-f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){id nameWithOwner}rateLimit{cost}}' \
		-f owner="$owner" -f name="$name" 2>/dev/null) || response=""
	if [[ -n "$response" ]]; then
		reported_cost=$(printf '%s' "$response" | jq -r "$_ISLR_GRAPHQL_COST_FILTER" 2>/dev/null) || reported_cost=""
	fi
	if [[ -n "$response" && "$reported_cost" =~ ^[1-9][0-9]*$ ]] &&
		IFS=$'\034' read -r repository_id response_slug < <(
			printf '%s' "$response" | jq -r \
				'[.data.repository.id, .data.repository.nameWithOwner] | map(. // empty) | join("\u001c")' 2>/dev/null
		) && [[ -n "$repository_id" ]] && _github_repository_slug_matches "$repo" "$response_slug"; then
		_cache_issue_sync_repository_id "$repo" "$repository_id"
		printf '%s\n' "$repository_id"
		return 0
	fi

	response=$(_gh_with_timeout read gh api "repos/${repo}" 2>/dev/null) || response=""
	if [[ -n "$response" ]] && IFS=$'\034' read -r repository_id response_slug < <(
		printf '%s' "$response" | jq -r \
			'[.node_id, .full_name] | map(. // empty) | join("\u001c")' 2>/dev/null
	) && [[ -n "$repository_id" ]] && _github_repository_slug_matches "$repo" "$response_slug"; then
		_cache_issue_sync_repository_id "$repo" "$repository_id"
		printf '%s\n' "$repository_id"
		return 0
	fi
	return 1
}

# Resolve a task ID to a repository-validated GitHub issue mapping. The
# coordinator is authoritative; ref:GH remains a migration projection that is
# backfilled only after both repository and issue node identities are fetched.
# Arguments:
#   $1 - task_id (e.g. t1873.1)
#   $2 - todo_file path
#   $3 - repo slug (owner/repo)
# Returns: issue number on stdout, or empty string if not found
resolve_task_gh_number() {
	local task_id="$1"
	local todo_file="$2"
	local repo="${3:-}"
	[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || return 1
	local repository_id="" mapping="" coordinator="${SCRIPT_DIR}/task-coordinator.mjs"
	repository_id=$(resolve_repository_node_id "$repo" || true)
	[[ -n "$repository_id" ]] || return 1
	if [[ -f "$coordinator" ]]; then
		mapping=$(node "$coordinator" resolve-issue --task-id "$task_id" --forge github \
			--repository-id "$repository_id" 2>/dev/null || true)
		if [[ -n "$mapping" ]]; then
			local mapped_slug="" mapped_role="" mapped_issue_id="" mapped_number="" mapped_project="" mapped_cursor="" mapped_metadata=""
			if ! IFS=$'\034' read -r mapped_slug mapped_role mapped_issue_id mapped_number mapped_project mapped_cursor mapped_metadata < <(
				printf '%s' "$mapping" | jq -r \
					'[.repositorySlug // "", .role // "", .issueId // "", (.displayNumber // "" | tostring), .projectId // "", .stateCursor // "", (.syncMetadata | tojson)] | join("\u001c")'
			); then
				return 1
			fi
			if [[ "$mapped_slug" != "$repo" ]]; then
				local refresh_args=()
				[[ -n "$mapped_project" ]] && refresh_args+=(--project-id "$mapped_project")
				[[ -n "$mapped_cursor" ]] && refresh_args+=(--state-cursor "$mapped_cursor")
				node "$coordinator" bind-issue --task-id "$task_id" --forge github \
					--repository-id "$repository_id" --repository-slug "$repo" --role "$mapped_role" \
					--issue-id "$mapped_issue_id" --display-number "$mapped_number" \
					"${refresh_args[@]}" --sync-metadata "$mapped_metadata" >/dev/null 2>&1 || return 1
			fi
			_cache_issue_sync_node_id "$mapped_number" "$mapped_issue_id"
			printf '%s\n' "$mapped_number"
			return 0
		fi
	fi
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")

	local ref="" issue_json="" issue_id="" issue_number="" issue_state="" issue_cursor=""
	ref=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 |
		grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
	[[ "$ref" =~ ^[1-9][0-9]*$ ]] || return 1
	issue_json=$(_gh_with_timeout read gh issue view "$ref" --repo "$repo" --json id,number,state,updatedAt 2>/dev/null || true)
	[[ -n "$issue_json" ]] || return 1
	if ! IFS=$'\034' read -r issue_id issue_number issue_state issue_cursor < <(
		printf '%s' "$issue_json" | jq -r \
			'[.id // "", (.number // "" | tostring), .state // "", .updatedAt // ""] | join("\u001c")'
	); then
		return 1
	fi
	[[ -n "$issue_id" && "$issue_number" == "$ref" ]] || return 1
	if [[ -f "$coordinator" ]]; then
		local bind_args=()
		[[ -n "$issue_cursor" ]] && bind_args+=(--state-cursor "$issue_cursor")
		node "$coordinator" bind-issue --task-id "$task_id" --forge github \
			--repository-id "$repository_id" --repository-slug "$repo" --role home \
			--issue-id "$issue_id" --display-number "$issue_number" \
			"${bind_args[@]}" \
			--sync-metadata "$(jq -cn --arg state "$issue_state" --arg source ref-gh-backfill '{state:$state,source:$source}')" >/dev/null 2>&1 || return 1
	fi
	_cache_issue_sync_node_id "$issue_number" "$issue_id"
	printf '%s\n' "$issue_number"
	return 0
}

# Validate that a task's repository-scoped immutable mapping resolves to the
# exact display number a caller intends to mutate.
require_task_issue_mapping() {
	local task_id="$1"
	local todo_file="$2"
	local repo="$3"
	local issue_number="$4"
	local resolved=""
	resolved=$(resolve_task_gh_number "$task_id" "$todo_file" "$repo" || true)
	if [[ ! "$issue_number" =~ ^[1-9][0-9]*$ || "$resolved" != "$issue_number" ]]; then
		print_error "Refusing issue write for ${task_id}: #${issue_number} is not validated for ${repo}"
		return 1
	fi
	return 0
}

# Resolve a GitHub issue number to its GraphQL node ID.
# Arguments:
#   $1 - issue_number
#   $2 - repo slug (owner/repo)
# Returns: node ID on stdout, or empty string on failure
resolve_gh_node_id() {
	local issue_number="$1"
	local repo="$2"
	local owner="${repo%%/*}"
	local name="${repo##*/}"
	local response=""
	local reported_cost=""
	local node_id=""
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub, not shell.
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-node-id-exact-cost" \
		_gh_with_timeout read gh api graphql \
		-f query='query($owner:String!,$name:String!,$num:Int!){repository(owner:$owner,name:$name){issue(number:$num){id}}rateLimit{cost}}' \
		-f owner="$owner" -f name="$name" -F num="$issue_number" \
		2>/dev/null) || response=""
	reported_cost=$(printf '%s' "$response" | jq -r "$_ISLR_GRAPHQL_COST_FILTER" 2>/dev/null) || reported_cost=""
	if [[ "$reported_cost" =~ ^[1-9][0-9]*$ ]]; then
		node_id=$(printf '%s' "$response" | jq -r '.data.repository.issue.id // empty' 2>/dev/null) || node_id=""
	fi
	printf '%s\n' "$node_id"
	return 0
}

# Check one bounded native blocked-by connection using response-owned cost.
# Returns: 0=present, 1=absent, 2=lookup unavailable/incomplete.
_gh_native_blocked_by_contains() {
	local blocked_id="$1" blocking_id="$2"
	local payload=""
	local reported_cost=""
	local has_next=""
	local contains=""
	local cache_file="${_RELATIONSHIP_NATIVE_CACHE_FILE:-}" cache_line="" node_id=""
	if [[ -f "$cache_file" ]]; then
		cache_line=$(grep -F -m1 -- "${blocked_id}|" "$cache_file" 2>/dev/null || true)
		if [[ -n "$cache_line" ]]; then
			[[ "$cache_line" == "${blocked_id}|complete|"* ]] || return 2
			grep -Fqx -- "${blocked_id}|complete|${blocking_id}" "$cache_file" && return 0
			return 1
		fi
	fi
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub, not shell.
	payload=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-blocked-by-read-exact-cost" \
		_gh_with_timeout read gh api graphql -f query='
query($blocked:ID!) {
  node(id:$blocked) { ... on Issue { blockedBy(first:100) { nodes { id } pageInfo { hasNextPage } } } }
	rateLimit { cost }
}' -f blocked="$blocked_id" 2>/dev/null) || return 2
	reported_cost=$(printf '%s' "$payload" | jq -r "$_ISLR_GRAPHQL_COST_FILTER" 2>/dev/null) || reported_cost=""
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 2
	contains=$(printf '%s' "$payload" | jq -r --arg id "$blocking_id" \
		'any(.data.node.blockedBy.nodes[]?; .id == $id)' 2>/dev/null) || return 2
	has_next=$(printf '%s' "$payload" | jq -r \
		'.data.node.blockedBy.pageInfo.hasNextPage | if type == "boolean" then tostring else "unknown" end' \
		2>/dev/null) || return 2
	if [[ -f "$cache_file" ]]; then
		if [[ "$has_next" == "$_ISLR_JSON_FALSE" ]]; then
			printf '%s|complete|\n' "$blocked_id" >>"$cache_file"
			while IFS= read -r node_id; do
				[[ -n "$node_id" ]] && printf '%s|complete|%s\n' "$blocked_id" "$node_id" >>"$cache_file"
			done < <(printf '%s' "$payload" | jq -r '.data.node.blockedBy.nodes[]?.id // empty' 2>/dev/null)
		else
			printf '%s|incomplete|\n' "$blocked_id" >>"$cache_file"
		fi
	fi
	[[ "$contains" == "$_ISLR_JSON_TRUE" ]] && return 0
	[[ "$has_next" == "$_ISLR_JSON_FALSE" ]] && return 1
	return 2
}

# Check one bounded native sub-issue connection using response-owned cost.
# Returns: 0=present, 1=absent, 2=lookup unavailable/incomplete.
_gh_native_sub_issue_contains() {
	local parent_id="$1" child_id="$2"
	local payload=""
	local reported_cost=""
	local has_next=""
	local contains=""
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub, not shell.
	payload=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-sub-issue-read-exact-cost" \
		_gh_with_timeout read gh api graphql -f query='
query($parent:ID!) {
  node(id:$parent) { ... on Issue { subIssues(first:100) { nodes { id } pageInfo { hasNextPage } } } }
	rateLimit { cost }
}' -f parent="$parent_id" 2>/dev/null) || return 2
	reported_cost=$(printf '%s' "$payload" | jq -r "$_ISLR_GRAPHQL_COST_FILTER" 2>/dev/null) || reported_cost=""
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 2
	contains=$(printf '%s' "$payload" | jq -r --arg id "$child_id" \
		'any(.data.node.subIssues.nodes[]?; .id == $id)' 2>/dev/null) || return 2
	[[ "$contains" == "$_ISLR_JSON_TRUE" ]] && return 0
	has_next=$(printf '%s' "$payload" | jq -r \
		'.data.node.subIssues.pageInfo.hasNextPage | if type == "boolean" then tostring else "unknown" end' \
		2>/dev/null) || return 2
	[[ "$has_next" == "$_ISLR_JSON_FALSE" ]] && return 1
	return 2
}

# Extract the selected tier from a brief file.
# Looks for "**Selected tier:** `tier:XXX`" in the brief.
# Arguments:
#   $1 - brief file path
# Returns: tier label on stdout (e.g., "tier:simple"), or empty string if not found
#
# t2012: parse the explicit `**Selected tier:**` line first. The previous
# implementation grep-anywhere'd the whole brief and took `head -1`, which
# matched commentary like "use `tier:standard` or higher" or rank-order text
# (`tier:thinking` > `tier:standard` > `tier:simple`) before the actual
# **Selected tier:** line — returning the wrong tier and creating tier label
# collisions with `_validate_tier_checklist`'s override path.
_extract_tier_from_brief() {
	local brief_path="$1"

	if [[ ! -f "$brief_path" ]]; then
		return 0
	fi

	# PRIMARY: parse the explicit `**Selected tier:**` line. The brief
	# template requires this exact prefix; search for it specifically rather
	# than grepping the whole document.
	local selected_line
	selected_line=$(grep -m1 -E '^\*\*Selected tier:\*\*' "$brief_path" 2>/dev/null || true)
	if [[ -n "$selected_line" ]]; then
		local tier
		tier=$(printf '%s' "$selected_line" | grep -oE 'tier:(simple|standard|thinking)' | head -1 || true)
		if [[ -n "$tier" ]]; then
			printf '%s' "$tier"
			return 0
		fi
	fi

	# FALLBACK: grep-anywhere for briefs that don't follow the template.
	# Logged as a warning to stderr so we can chase non-conforming briefs.
	local fallback
	fallback=$(grep -oE 'tier:(simple|standard|thinking)' "$brief_path" 2>/dev/null | head -1 || true)
	if [[ -n "$fallback" ]]; then
		echo "[WARN] _extract_tier_from_brief: brief at $brief_path missing **Selected tier:** line, falling back to first tier mention ($fallback)" >&2
		printf '%s' "$fallback"
	fi
	return 0
}

# Validate tier:simple briefs have all checklist boxes checked AND contain an
# explicit execution contract. Open-ended tier judgment belongs to task creation;
# this function enforces only mechanically provable contract invariants.
# Arguments:
#   $1 - brief file path
#   $2 - selected tier label (e.g., "tier:simple")
# Returns: the validated tier label on stdout
# Exit: 0 always (validation is advisory, not blocking)
_validate_tier_checklist() {
	local brief_path="$1"
	local selected_tier="$2"

	# Only validate tier:simple — standard and thinking don't have hard checklist gates
	if [[ "$selected_tier" != "tier:simple" ]]; then
		printf '%s' "$selected_tier"
		return 0
	fi

	# Check if brief file exists
	if [[ ! -f "$brief_path" ]]; then
		printf '%s' "$selected_tier"
		return 0
	fi

	# Gate 1: Count unchecked boxes in the tier checklist section
	# Pattern: lines between "### Tier checklist" and "**Selected tier:**"
	local unchecked_count
	unchecked_count=$(sed -n '/^### Tier checklist/,/^\*\*Selected tier/p' "$brief_path" |
		grep -c '^\- \[ \]' || true)

	if [[ "$unchecked_count" -gt 0 ]]; then
		echo "[WARN] tier:simple selected but $unchecked_count checklist box(es) unchecked in $brief_path — overriding to tier:standard" >&2
		printf '%s' "tier:standard"
		return 0
	fi

	# Gate 2: Verify one of the canonical prescriptive contracts. Existing-file
	# replacements require matched oldString/newString markers; new files use
	# Full content; deterministic non-content operations use Exact transform.
	local old_count new_count full_count transform_count
	old_count=$(grep -cE '^\*\*oldString:\*\*[[:space:]]*$' "$brief_path" || true)
	new_count=$(grep -cE '^\*\*newString:\*\*[[:space:]]*$' "$brief_path" || true)
	full_count=$(grep -cE '^\*\*Full content:\*\*[[:space:]]*$' "$brief_path" || true)
	transform_count=$(grep -cE '^\*\*Exact transform:\*\*[[:space:]]*' "$brief_path" || true)

	if [[ "$old_count" -ne "$new_count" || ("$old_count" -eq 0 && "$full_count" -eq 0 && "$transform_count" -eq 0) ]]; then
		echo "[WARN] tier:simple selected but brief lacks a complete exact execution contract in $brief_path — overriding to tier:standard" >&2
		printf '%s' "tier:standard"
		return 0
	fi

	printf '%s' "$selected_tier"
	return 0
}

# Detect the parent task ID from a subtask ID.
# t1873.2 → t1873, t1873.2.1 → t1873.2, t1873 → "" (no parent)
# Arguments:
#   $1 - task_id
# Returns: parent task ID on stdout, or empty string if top-level
detect_parent_task_id() {
	local task_id="$1"
	task_identity_parse "$task_id" || return 1
	[[ -n "$TASK_IDENTITY_PARENT_ID" ]] && echo "$TASK_IDENTITY_PARENT_ID"
	return 0
}

# =============================================================================
# t2698: Orphan TODO seeding helpers
# =============================================================================

# Convert a GitHub labels JSON array to space-separated #tag tokens.
# Skips system/operational labels (tier:*, status:*, origin:*, source:*, etc.).
# Applies reverse mapping where needed (e.g. parent-task → #parent).
#
# Arguments:
#   $1 - JSON array of label objects, e.g. [{"name":"enhancement"},...]
# Prints:
#   Space-separated sorted #tag tokens, e.g. "#auto-dispatch #enhancement"
#   Empty string if no mappable labels.
_labels_json_to_tags() {
	local labels_json="$1"
	[[ -z "$labels_json" || "$labels_json" == "[]" ]] && return 0

	local names
	names=$(printf '%s' "$labels_json" | jq -r '.[].name' 2>/dev/null || echo "")
	[[ -z "$names" ]] && return 0

	local tags="" label tag
	while IFS= read -r label; do
		[[ -z "$label" ]] && continue

		# Skip system/operational labels — not part of TODO source-of-truth
		case "$label" in
			tier:* | status:* | origin:* | source:* | needs-* | priority:*) continue ;;
			hold-for-review | no-auto-dispatch | no-takeover) continue ;;
			coderabbit-nits-ok | new-file-smell-ok | complexity-bump-ok) continue ;;
			workflow-cascade-ok | ratchet-bump) continue ;;
		esac

		# Reverse map known label → canonical TODO tag
		tag="$label"
		case "$label" in
			parent-task) tag="parent" ;;
		esac

		tags="${tags:+$tags }#${tag}"
	done <<< "$names"

	[[ -z "$tags" ]] && return 0
	# Sort deterministically (stable) so test assertions are not order-sensitive
	printf '%s' "$tags" | tr ' ' '\n' | sort -u | paste -sd ' ' -
	return 0
}

# Seed a new TODO.md entry for an open orphan GitHub issue.
# Idempotent: no-ops if any entry for the task_id already exists.
# Dry-run aware: emits "would seed: ..." to stderr and returns 0 without writing.
#
# Arguments:
#   $1 - issue_num    (e.g. 20327)
#   $2 - task_id      (e.g. t2698)
#   $3 - title_raw    (full issue title, e.g. "t2698: enhance ...")
#   $4 - labels_json  (JSON array of label objects from gh issue list)
#   $5 - todo_file    (path to TODO.md)
#   $6 - dry_run      ("true" or "")
# Returns:
#   0 = seeded (or dry-run would-seed)
#   1 = skipped (already exists or malformed)
_seed_orphan_todo_line() {
	local num="$1" task_id="$2" title_raw="$3" labels_json="$4"
	local todo_file="$5" dry_run="${6:-}"

	# Guard: empty task_id cannot produce a valid TODO line
	task_identity_validate "$task_id" || return 1

	# Idempotency check: skip if any entry for this task_id already exists
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")
	if strip_code_fences <"$todo_file" | grep -qE "^\s*- \[.\] ${task_id_ere} "; then
		_dedupe_todo_task_lines "$task_id" "$todo_file" || true
		{ log_verbose "ORPHAN already seeded: $task_id (ref:GH#$num) — skipping" || true; }
		return 1
	fi

	# Strip the task_id prefix from title (e.g. "t2698: enhance ..." → "enhance ...")
	local title_body
	title_body=$(printf '%s' "$title_raw" | sed "s|^${task_id}:[[:space:]]*||")

	# Build space-separated #tag tokens from labels
	local tags_str=""
	tags_str=$(_labels_json_to_tags "$labels_json" || true)

	# Compose the TODO line
	local todo_line="- [ ] ${task_id} ${title_body}"
	[[ -n "$tags_str" ]] && todo_line="${todo_line} ${tags_str}"
	todo_line="${todo_line} ref:GH#${num}"

	if [[ "$dry_run" == "true" ]]; then
		printf 'would seed: %s\n' "$todo_line" >&2
		return 0
	fi

	# Append after the last non-empty line (chronological tail)
	printf '\n%s\n' "$todo_line" >> "$todo_file"
	print_success "Seeded orphan TODO: $todo_line"
	return 0
}

# Remove duplicate TODO.md task lines, preserving the richest canonical entry.
# Preference order: completed lines, linked brief lines, detailed metadata, then
# the first occurrence. This repairs historical simplified orphan duplicates
# without discarding useful task metadata from the canonical upper section.
_todo_task_source_line_selection() {
	local task_id="$1"
	local todo_file="$2"
	local task_id_ere=""
	local canonical_line=""
	task_id_ere=$(_escape_ere "$task_id") || return 1
	canonical_line=$(_canonical_todo_task_line "$task_id" "$todo_file") || return 1
	CANONICAL_TODO_LINE="$canonical_line" awk -v task_pattern="$task_id_ere" '
		BEGIN { pattern = "^[[:space:]]*- \\[.\\] " task_pattern " " }
		function without_comments(raw, line, out, pos) {
			line = raw
			out = ""
			while (length(line) > 0) {
				if (in_comment) {
					pos = index(line, "-->")
					if (pos == 0) { line = ""; break }
					line = substr(line, pos + 3)
					in_comment = 0
				} else {
					pos = index(line, "<!--")
					if (pos == 0) { out = out line; line = ""; break }
					out = out substr(line, 1, pos - 1)
					line = substr(line, pos + 4)
					in_comment = 1
				}
			}
			return out
		}
		/^[[:space:]]*```/ { in_fence = !in_fence; next }
		in_fence { next }
		{
			normalized = without_comments($0)
			if (normalized ~ pattern) {
				live_lines = live_lines (live_lines == "" ? "" : ",") NR
				if (canonical_line == 0 && normalized == ENVIRON["CANONICAL_TODO_LINE"]) {
					canonical_line = NR
				}
			}
		}
		END {
			if (canonical_line == 0) { exit 1 }
			print canonical_line "|" live_lines
		}
	' "$todo_file"
	return $?
}

_dedupe_todo_task_lines() {
	local task_id="$1"
	local todo_file="$2"
	local task_id_ere duplicate_count tmp_file selection canonical_line_num live_line_nums stripped

	task_id_ere=$(_escape_ere "$task_id")
	stripped=$(strip_code_fences <"$todo_file") || return 2
	duplicate_count=$(printf '%s\n' "$stripped" | grep -Ec "^[[:space:]]*- \[.\] ${task_id_ere} " || true)
	if [[ "$duplicate_count" -le 1 ]]; then
		return 1
	fi
	selection=$(_todo_task_source_line_selection "$task_id" "$todo_file") || return 2
	canonical_line_num="${selection%%|*}"
	live_line_nums="${selection#*|}"
	[[ "$canonical_line_num" =~ ^[1-9][0-9]*$ ]] || return 2
	[[ "$live_line_nums" =~ ^[1-9][0-9]*(,[1-9][0-9]*)+$ ]] || return 2

	tmp_file=$(mktemp "${todo_file}.dedupe.XXXXXX") || return 2
	if ! awk -v canonical_line_num="$canonical_line_num" -v live_line_nums="$live_line_nums" '
		BEGIN {
			live_count = split(live_line_nums, live_lines, ",")
			for (i = 1; i <= live_count; i += 1) { is_live_line[live_lines[i]] = 1 }
		}
		NR in is_live_line {
			is_task[NR] = 1
			if (NR == canonical_line_num) {
				best_line = NR
			}
		}
		{ lines[NR] = $0 }
		END {
			for (i = 1; i <= NR; i += 1) {
				if (is_task[i] && i != best_line) { continue }
				print lines[i]
			}
		}
	' "$todo_file" >"$tmp_file"; then
		rm -f "$tmp_file"
		return 2
	fi

	if ! mv "$tmp_file" "$todo_file"; then
		rm -f "$tmp_file"
		return 2
	fi

	print_warning "Removed duplicate TODO.md entries for $task_id"
	return 0
}
