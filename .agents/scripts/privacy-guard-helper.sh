#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# privacy-guard-helper.sh — Shared library for private-reference guards.
#
# Enumerates private repo slugs from ~/.config/aidevops/repos.json and scans
# free-form text or git diff content that would leak a private repository name
# or local/private path into a public target.
#
# This file is sourced by:
#   - .agents/hooks/privacy-guard-pre-push.sh (the actual git pre-push hook)
#   - .agents/scripts/test-privacy-guard.sh   (the test harness)
#
# It is NOT intended to be executed directly — it is a library. Functions
# exit the caller via `return`, never `exit`, to preserve the hook's control
# flow.
#
# Functions exported:
#   privacy_is_target_public <remote_url>        exit 0 public, 1 private, 2 unknown
#   privacy_enumerate_private_slugs [out_file]   writes one slug per line
#   privacy_scan_text <text> <slugs_file>        scans text bodies/titles
#   privacy_scan_diff <base_sha> <head_sha>      writes "file:line: hit" to stdout
#   privacy_scan_paths                           list of path globs scanned
#   privacy_log <level> <msg>                    tagged stderr log
#
# Cache: ~/.aidevops/cache/repo-privacy.json (TTL 10m)
# Repos: ~/.config/aidevops/repos.json

set -u
# Do NOT set -e here — callers may source this file and we don't want our
# early returns to abort their scripts unexpectedly.

# =============================================================================
# Configuration
# =============================================================================

PRIVACY_REPOS_CONFIG="${PRIVACY_REPOS_CONFIG:-$HOME/.config/aidevops/repos.json}"
PRIVACY_CACHE_FILE="${PRIVACY_CACHE_FILE:-$HOME/.aidevops/cache/repo-privacy.json}"
PRIVACY_CACHE_TTL="${PRIVACY_CACHE_TTL:-600}" # 10 minutes
# Optional local-only inventory. One `person: value`, `client: value`, or
# `repo: owner/repo` entry per line; tabs are also accepted after the class.
PRIVACY_ENTITY_CONFIG="${PRIVACY_ENTITY_CONFIG:-$HOME/.aidevops/configs/privacy-guard-private-entities.txt}"
# Paths whose diffs we scan. Default to the full repository because aidevops is
# public and private names/paths must not land in code, docs, tests, or plans.
# Override with PRIVACY_SCAN_GLOBS_TEXT as a newline/colon/comma-separated list.
PRIVACY_SCAN_GLOBS=(
	"."
)
PRIVACY_SCAN_GLOBS_TEXT="${PRIVACY_SCAN_GLOBS_TEXT:-}"
# Require a left token boundary so credential-looking substrings inside words or
# filenames (for example, task-coordinator.sh) are not treated as secrets.
PRIVACY_CREDENTIAL_PREFIX_ERE='(^|[^A-Za-z0-9_-])(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}'

# =============================================================================
# Logging
# =============================================================================

#######################################
# Emit a tagged log line to stderr.
# Arguments:
#   $1 - level (INFO/WARN/ERROR/BLOCK)
#   $@ - message
#######################################
privacy_log() {
	local level="$1"
	shift
	printf '[privacy-guard][%s] %s\n' "$level" "$*" >&2
	return 0
}

# =============================================================================
# Target-privacy lookup
# =============================================================================

#######################################
# Given a git remote URL, parse owner/repo and ask gh whether it is public.
# Caches positive + negative results to ~/.aidevops/cache/repo-privacy.json
# with a 10-minute TTL to keep hook latency under 500ms on warm cache.
# Arguments:
#   $1 - remote URL (https://github.com/owner/repo.git or git@github.com:owner/repo.git)
# Returns:
#   0 if public, 1 if private, 2 if unknown (fail-open: hook allows push).
#######################################
privacy_is_target_public() {
	local url="$1"
	local slug=""
	local gh_bin="${PRIVACY_GH_BIN:-gh}"

	# Extract owner/repo from either SSH or HTTPS form, strip optional .git
	if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+) ]]; then
		slug="${BASH_REMATCH[1]%.git}"
	else
		privacy_log WARN "Non-GitHub remote ($url) — fail-open, allowing push"
		return 2
	fi

	# Cache hit?
	# NOTE: use `.private | tostring` — NOT `.private // ""`. The `//` operator
	# treats `false` as null-ish and would collapse every public cache entry
	# to an empty string (t1969 regression: cached public → cache miss →
	# unnecessary gh probe). `tostring` returns "true", "false", or "null".
	mkdir -p "$(dirname "$PRIVACY_CACHE_FILE")" 2>/dev/null || true
	if [[ -f "$PRIVACY_CACHE_FILE" ]]; then
		local cached_ts cached_private now
		cached_ts=$(jq -r --arg slug "$slug" '.[$slug].checked_at // ""' "$PRIVACY_CACHE_FILE" 2>/dev/null)
		cached_private=$(jq -r --arg slug "$slug" '.[$slug].private | tostring' "$PRIVACY_CACHE_FILE" 2>/dev/null)
		now=$(date +%s)
		if [[ -n "$cached_ts" && "$cached_private" != "null" ]]; then
			local age=$((now - cached_ts))
			if [[ "$age" -lt "$PRIVACY_CACHE_TTL" ]]; then
				if [[ "$cached_private" == "false" ]]; then
					return 0
				else
					return 1
				fi
			fi
		fi
	fi

	# Cold probe via gh
	if ! command -v "$gh_bin" >/dev/null 2>&1; then
		privacy_log WARN "gh CLI not installed — fail-open, allowing push to $slug"
		return 2
	fi
	if ! "$gh_bin" auth status >/dev/null 2>&1; then
		privacy_log WARN "gh not authenticated — fail-open, allowing push to $slug"
		return 2
	fi

	# Use `.private | tostring` — NOT `.private // "unknown"`. The `//` operator
	# treats `false` as null-ish, so `.private // "unknown"` returns "unknown"
	# for every public repo. `tostring` returns "true", "false", or "null".
	local is_private
	is_private=$("$gh_bin" api "repos/${slug}" --jq '.private | tostring' 2>/dev/null) || {
		privacy_log WARN "gh api repos/${slug} failed — fail-open"
		return 2
	}

	case "$is_private" in
	true)
		_privacy_cache_write "$slug" "true"
		return 1
		;;
	false)
		_privacy_cache_write "$slug" "false"
		return 0
		;;
	*)
		privacy_log WARN "gh returned unexpected privacy value ($is_private) for $slug — fail-open"
		return 2
		;;
	esac
}

#######################################
# Write a slug -> {private, checked_at} entry to the privacy cache.
# Arguments:
#   $1 - slug
#   $2 - privacy string (true|false)
#######################################
_privacy_cache_write() {
	local slug="$1"
	local private="$2"
	local now
	now=$(date +%s)

	mkdir -p "$(dirname "$PRIVACY_CACHE_FILE")" 2>/dev/null || true
	if [[ ! -f "$PRIVACY_CACHE_FILE" ]]; then
		printf '{}\n' >"$PRIVACY_CACHE_FILE"
	fi

	local tmp
	tmp=$(mktemp "${PRIVACY_CACHE_FILE}.XXXXXX")
	jq --arg slug "$slug" --arg private "$private" --argjson now "$now" \
		'.[$slug] = {private: ($private == "true"), checked_at: $now}' \
		"$PRIVACY_CACHE_FILE" >"$tmp" 2>/dev/null && mv "$tmp" "$PRIVACY_CACHE_FILE" || rm -f "$tmp"
	return 0
}

# =============================================================================
# Private-slug enumeration
# =============================================================================

#######################################
# Enumerate private repo slugs from repos.json. A slug is considered private
# if ANY of these conditions hold:
#   - mirror_upstream is set (mirrors are private by design)
#   - local_only: true (no remote, definitionally not public)
#   - the slug's owner is the current gh user AND the repo is private on GH
#
# For speed, we use structural markers only (mirror_upstream, local_only).
# We do NOT probe every slug with gh api — that would cost N network calls
# on every push. Users who want additional slugs covered can add them to
# ~/.aidevops/configs/privacy-guard-extra-slugs.txt (one per line).
#
# Arguments:
#   $1 - (optional) output file path. If omitted, writes to stdout.
#######################################
privacy_enumerate_private_slugs() {
	local out_file="${1:-}"

	if [[ ! -f "$PRIVACY_REPOS_CONFIG" ]]; then
		privacy_log WARN "repos.json not found at $PRIVACY_REPOS_CONFIG"
		return 1
	fi

	local slugs
	slugs=$(jq -r '
		.initialized_repos[]?
		| select(
			(.mirror_upstream // null) != null and (.mirror_upstream // "") != ""
			or (.local_only // false) == true
		)
		| .slug // empty
	' "$PRIVACY_REPOS_CONFIG" 2>/dev/null)

	# Also include extra user-configured slugs
	local extra_file="$HOME/.aidevops/configs/privacy-guard-extra-slugs.txt"
	if [[ -f "$extra_file" ]]; then
		local extras
		extras=$(grep -vE '^\s*(#|$)' "$extra_file" 2>/dev/null || true)
		if [[ -n "$extras" ]]; then
			slugs=$(printf '%s\n%s\n' "$slugs" "$extras")
		fi
	fi

	# De-dupe while preserving order via awk
	slugs=$(printf '%s\n' "$slugs" | awk 'NF && !seen[$0]++')

	if [[ -n "$out_file" ]]; then
		printf '%s\n' "$slugs" >"$out_file"
	else
		printf '%s\n' "$slugs"
	fi
	return 0
}

#######################################
# Enumerate private publication entities as `class<TAB>value` records.
# Repository values are derived from the existing slug inventory; person and
# client aliases are optional local-only configuration and are never logged.
# Arguments:
#   $1 - output file path
#######################################
privacy_enumerate_private_entities() {
	local out_file="$1"
	local slugs_file entity class value

	[[ -z "$out_file" ]] && return 1
	slugs_file=$(mktemp) || return 1
	if ! privacy_enumerate_private_slugs "$slugs_file"; then
		rm -f "$slugs_file"
		return 1
	fi
	: >"$out_file" || {
		rm -f "$slugs_file"
		return 1
	}
	while IFS= read -r entity || [[ -n "$entity" ]]; do
		[[ -z "$entity" ]] && continue
		printf 'repo\t%s\n' "$entity" >>"$out_file"
	done <"$slugs_file"
	rm -f "$slugs_file"

	if [[ -f "$PRIVACY_ENTITY_CONFIG" ]]; then
		while IFS= read -r entity || [[ -n "$entity" ]]; do
			[[ -z "$entity" || "$entity" == \#* ]] && continue
			if [[ "$entity" == *$'\t'* ]]; then
				class="${entity%%$'\t'*}"
				value="${entity#*$'\t'}"
			else
				class="${entity%%:*}"
				value="${entity#*:}"
			fi
			class="${class//[[:space:]]/}"
			value="${value#"${value%%[![:space:]]*}"}"
			value="${value%"${value##*[![:space:]]}"}"
			case "$class" in
			person | client | repo) [[ -n "$value" ]] && printf '%s\t%s\n' "$class" "$value" >>"$out_file" ;;
			esac
		done <"$PRIVACY_ENTITY_CONFIG"
	fi
	return 0
}

#######################################
# Scan text with a tagged entity inventory without emitting matched values.
# Arguments:
#   $1 - text content
#   $2 - entity file from privacy_enumerate_private_entities
#   $3 - optional precomputed aidevops script basename allowlist
# Output: generic hit classes only
#######################################
privacy_scan_public_text() {
	local text="$1"
	local entities_file="$2"
	local aidevops_script_basenames_provided="${3+x}"
	local aidevops_script_basenames="${3:-}"
	local hits=0 class value secret_hits path_hits

	[[ -f "$entities_file" ]] || return 2
	[[ -z "$text" ]] && return 0
	path_hits=$(privacy_scan_local_paths "$text")
	case $? in
	1) printf '%s\n' '[local-path]'; hits=$((hits + 1)) ;;
	2) return 2 ;;
	esac
	if [[ -n "$aidevops_script_basenames_provided" ]]; then
		secret_hits=$(privacy_scan_secret_material_text "$text" "$aidevops_script_basenames")
	else
		secret_hits=$(privacy_scan_secret_material_text "$text")
	fi
	if [[ $? -eq 1 ]]; then
		printf '%s\n' "$secret_hits"
		hits=$((hits + 1))
	fi
	while IFS=$'\t' read -r class value || [[ -n "$class" ]]; do
		[[ -z "$class" || -z "$value" ]] && continue
		if [[ "$text" == *"$value"* ]]; then
			printf '[private-%s]\n' "$class"
			hits=$((hits + 1))
		fi
	done <"$entities_file"
	[[ "$hits" -gt 0 ]] && return 1
	return 0
}

#######################################
# Redact tagged private entities in locally previewed text.
# Arguments: $1=text $2=entity inventory
#######################################
privacy_redact_public_text() {
	local text="$1"
	local entities_file="$2"
	local class value redacted="$text"
	[[ -f "$entities_file" ]] || return 1
	redacted=$(privacy_redact_local_paths "$redacted") || return 1
	while IFS=$'\t' read -r class value || [[ -n "$class" ]]; do
		[[ -z "$class" || -z "$value" ]] && continue
		redacted="${redacted//"$value"/[private-${class}]}"
	done <"$entities_file"
	printf '%s' "$redacted"
	return 0
}

#######################################
# Build a public-safe copy of text from the local entity inventory.
# Arguments: $1=text
#######################################
privacy_redact_public_text_from_inventory() {
	local text="$1"
	local entities_file redacted

	entities_file=$(mktemp) || return 1
	if ! privacy_enumerate_private_entities "$entities_file"; then
		rm -f "$entities_file"
		return 1
	fi
	redacted=$(privacy_redact_public_text "$text" "$entities_file") || {
		rm -f "$entities_file"
		return 1
	}
	rm -f "$entities_file"
	printf '%s' "$redacted"
	return 0
}

#######################################
# Replace local filesystem paths before rendering text for a public surface.
# Mirrors privacy_scan_local_paths() so callers can preserve useful dashboard
# data without bypassing the public-write privacy guard.
# Arguments: $1=text
#######################################
privacy_redact_local_paths() {
	local text="$1"
	# shellcheck disable=SC2016  # sed expressions intentionally use single quotes
	printf '%s' "$text" | sed -E \
		-e 's%(^|[[:space:]`"(:=])/Users/[^[:space:]`")]*%\1[local-path]%g' \
		-e 's%(^|[[:space:]`"(:=])/home/[^[:space:]`")]*%\1[local-path]%g' \
		-e 's%(^|[[:space:]`"(:=])~/(Git|Projects|Code|src|work|dev)/[^[:space:]`")]*%\1[local-path]%g' \
		-e 's%(^|[[:space:]`"(:=])file:///(Users|home)/[^[:space:]`")]*%\1[local-path]%g'
	return 0
}

#######################################
# Fail closed before a GitHub write when its public target or content is unsafe.
# Arguments: $1=repo slug, $2=free-form public text
#######################################
privacy_guard_public_write() {
	local repo="$1"
	local text="$2"
	local target_status entities_file hits scan_rc

	if [[ -z "$repo" || ! "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
		printf '[privacy-guard][BLOCK] Public-write target privacy could not be established.\n' >&2
		return 1
	fi
	if privacy_is_target_public "https://github.com/${repo}.git"; then
		target_status=0
	else
		target_status=$?
	fi
	if [[ "$target_status" -eq 1 ]]; then
		return 0
	fi
	if [[ "$target_status" -ne 0 ]]; then
		printf '[privacy-guard][BLOCK] Public-write target privacy could not be established.\n' >&2
		return 1
	fi
	entities_file=$(mktemp) || return 1
	if ! privacy_enumerate_private_entities "$entities_file"; then
		rm -f "$entities_file"
		printf '[privacy-guard][BLOCK] Private entity inventory could not be loaded.\n' >&2
		return 1
	fi
	hits=$(privacy_scan_public_text "$text" "$entities_file")
	scan_rc=$?
	rm -f "$entities_file"
	if [[ "$scan_rc" -eq 1 ]]; then
		printf '[privacy-guard][BLOCK] Public write contains private material: %s\n' "${hits//$'\n'/, }" >&2
		return 1
	fi
	if [[ "$scan_rc" -ne 0 ]]; then
		printf '[privacy-guard][BLOCK] Private entity scan failed.\n' >&2
		return 1
	fi
	return 0
}

# =============================================================================
# Free-form text scanning (used by gh PATH shim — t2876)
# =============================================================================

#######################################
# Minimum basename length for bare-basename matching. Basenames shorter than
# this are matched only as full slug form (owner/basename) to avoid false
# positives on common short tokens (web, app, api, mvp). Override via env.
#######################################
PRIVACY_BARE_BASENAME_MIN_LEN="${PRIVACY_BARE_BASENAME_MIN_LEN:-6}"

#######################################
# Scan text for full private slug matches.
# Arguments:
#   $1 - text content to scan
#   $2 - file containing newline-separated private slugs
# Output:
#   One matching owner/basename slug per line.
# Returns:
#   0 if no hits, 1 if at least one hit, 2 on setup error.
#######################################
privacy_scan_full_slugs() {
	local text="$1"
	local slugs_file="$2"
	local full_slugs_tmp
	local matched_full_slugs
	local match
	local hits=0

	full_slugs_tmp=$(mktemp) || return 2
	grep '/' "$slugs_file" 2>/dev/null >"$full_slugs_tmp" || true
	if [[ -s "$full_slugs_tmp" ]]; then
		matched_full_slugs=$(printf '%s' "$text" | grep -oF -f "$full_slugs_tmp" 2>/dev/null | sort -u || true)
		if [[ -n "$matched_full_slugs" ]]; then
			while IFS= read -r match; do
				[[ -z "$match" ]] && continue
				printf '%s\n' "$match"
				hits=$((hits + 1))
			done <<< "$matched_full_slugs"
		fi
	fi
	rm -f "$full_slugs_tmp"

	if [[ "$hits" -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Check whether a slug was already emitted as a full-slug match.
# Arguments:
#   $1 - owner/basename slug
#   $2 - newline-separated full slug matches
# Returns:
#   0 if already matched, 1 otherwise.
#######################################
privacy_slug_already_matched() {
	local slug="$1"
	local matched_full_slugs="$2"

	if [[ -n "$matched_full_slugs" && $'\n'"${matched_full_slugs}"$'\n' == *$'\n'"${slug}"$'\n'* ]]; then
		return 0
	fi
	return 1
}

#######################################
# Scan text for bare private basename matches.
# Arguments:
#   $1 - text content to scan
#   $2 - file containing newline-separated private slugs
#   $3 - newline-separated full slug matches to skip
# Output:
#   One matching basename line per hit.
# Returns:
#   0 if no hits, 1 if at least one hit.
#######################################
privacy_scan_bare_basenames() {
	local text="$1"
	local slugs_file="$2"
	local matched_full_slugs="$3"
	local slug owner basename escaped_basename
	local hits=0

	while IFS= read -r slug || [[ -n "$slug" ]]; do
		# Skip blanks and comment lines.
		[[ -z "$slug" || "$slug" == \#* ]] && continue
		# Trim leading/trailing whitespace.
		slug="${slug#"${slug%%[![:space:]]*}"}"
		slug="${slug%"${slug##*[![:space:]]}"}"
		[[ -z "$slug" ]] && continue

		if [[ "$slug" == */* ]]; then
			owner="${slug%/*}"
			basename="${slug##*/}"
		else
			owner=""
			basename="$slug"
		fi
		[[ -z "$basename" ]] && continue

		if [[ -n "$owner" ]] && privacy_slug_already_matched "$slug" "$matched_full_slugs"; then
			continue
		fi

		if [[ ${#basename} -ge "$PRIVACY_BARE_BASENAME_MIN_LEN" ]]; then
			escaped_basename=$(printf '%s' "$basename" | sed -E 's/[][(){}.^$*+?|\\]/\\&/g')
			if printf '%s' "$text" | grep -qE "(^|[^a-zA-Z0-9_-])${escaped_basename}([^a-zA-Z0-9_-]|$)" 2>/dev/null; then
				if [[ -n "$owner" ]]; then
					printf '%s (basename of %s)\n' "$basename" "$slug"
				else
					printf '%s\n' "$basename"
				fi
				hits=$((hits + 1))
			fi
		fi
	done <"$slugs_file"

	if [[ "$hits" -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Scan free-form text content (issue/PR body, title, gh api -f body=value)
# for private repo references and local/private path leaks. Used by
# .agents/scripts/gh PATH shim before letting a write reach a public repo.
#
# Two match forms per slug:
#   1. Full slug "owner/basename" — fixed-string match, low FP risk.
#   2. Bare "basename" with word boundaries — only when len >= MIN_LEN
#      (default 6) so common tokens like "app"/"web"/"api" don't trigger.
#
# Arguments:
#   $1 - text content to scan
#   $2 - file containing newline-separated private slugs (output of
#        privacy_enumerate_private_slugs)
# Output:
#   One line per hit on stdout, format:
#     "owner/basename"                    (full slug form match)
#     "basename (basename of owner/basename)"  (bare basename form match)
# Local/private path detection emits generic labels instead of the raw path so
# the block message does not repeat the sensitive value.
# Returns:
#   0 if no hits, 1 if at least one hit, 2 on argument/setup error.
#######################################
privacy_scan_text() {
	local text="$1"
	local slugs_file="$2"
	local hits=0
	local matched_full_slugs=""
	local full_slug_rc=0
	local basename_hits=""
	local basename_rc=0

	if [[ -z "$slugs_file" || ! -f "$slugs_file" ]]; then
		return 2
	fi
	# Empty text — nothing to scan.
	if [[ -z "$text" ]]; then
		return 0
	fi

	# Phase 0: local/private path matching. Keep output generic to avoid
	# re-printing the path in stderr or GitHub comments.
	local path_hits
	path_hits=$(privacy_scan_local_paths "$text")
	local path_rc=$?
	if [[ "$path_rc" -eq 1 ]]; then
		printf '%s\n' "$path_hits"
		hits=$((hits + 1))
	elif [[ "$path_rc" -eq 2 ]]; then
		return 2
	fi

	# Empty slug list still allows local path scanning above.
	if [[ ! -s "$slugs_file" ]]; then
		if [[ "$hits" -gt 0 ]]; then
			return 1
		fi
		return 0
	fi

	# Phase 1: Full-slug fixed-string matching — single grep -F -f pass over all
	# owner/repo entries at once. Reduces O(N) grep forks (one per slug) to one
	# call regardless of slug count. Only lines with '/' are full slugs; single-
	# token (legacy) entries are handled exclusively in Phase 2 below.
	matched_full_slugs=$(privacy_scan_full_slugs "$text" "$slugs_file")
	full_slug_rc=$?
	if [[ "$full_slug_rc" -eq 1 ]]; then
		printf '%s\n' "$matched_full_slugs"
		hits=$((hits + 1))
	elif [[ "$full_slug_rc" -eq 2 ]]; then
		return 2
	fi

	# Phase 2: Bare-basename word-boundary matching — per-slug loop.
	# Word-boundary patterns are slug-specific (variable basename length guard,
	# per-slug output format) and require per-slug ERE calls. Full slugs already
	# emitted in Phase 1 are skipped to prevent duplicate hits.
	basename_hits=$(privacy_scan_bare_basenames "$text" "$slugs_file" "$matched_full_slugs")
	basename_rc=$?
	if [[ "$basename_rc" -eq 1 ]]; then
		printf '%s\n' "$basename_hits"
		hits=$((hits + 1))
	fi

	if [[ "$hits" -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Scan text for local/private path patterns. Emits generic labels only.
# Built-in patterns catch common macOS/Linux home and repo paths. Optional
# configured ERE patterns live in ~/.aidevops/configs/privacy-guard-private-path-patterns.txt.
# Arguments:
#   $1 - text content to scan
# Returns:
#   0 if no hits, 1 if at least one hit, 2 on setup error.
#######################################
privacy_scan_local_paths() {
	local text="$1"
	[[ -z "$text" ]] && return 0

	local hits=0
	local emitted_builtin=0
	local builtin_patterns=(
		'(^|[[:space:]`"'\''(:=])/Users/[^[:space:]`"'\'')]*'
		'(^|[[:space:]`"'\''(:=])/home/[^[:space:]`"'\'')]*'
		'(^|[[:space:]`"'\''(:=])~/(Git|Projects|Code|src|work|dev)/[^[:space:]`"'\'')]*'
		'(^|[[:space:]`"'\''(:=])file:///(Users|home)/[^[:space:]`"'\'')]*'
	)
	local pattern
	for pattern in "${builtin_patterns[@]}"; do
		if printf '%s' "$text" | grep -qE "$pattern" 2>/dev/null; then
			if [[ "$emitted_builtin" -eq 0 ]]; then
				printf '[local-path]\n'
				emitted_builtin=1
				hits=$((hits + 1))
			fi
		fi
	done

	local patterns_file="$HOME/.aidevops/configs/privacy-guard-private-path-patterns.txt"
	if [[ -f "$patterns_file" ]]; then
		local configured_hit=0
		while IFS= read -r pattern || [[ -n "$pattern" ]]; do
			[[ -z "$pattern" || "$pattern" == \#* ]] && continue
			if printf '%s' "$text" | grep -qE "$pattern" 2>/dev/null; then
				configured_hit=1
			fi
		done <"$patterns_file"
		if [[ "$configured_hit" -eq 1 ]]; then
			printf '[configured-private-path]\n'
			hits=$((hits + 1))
		fi
	fi

	if [[ "$hits" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# =============================================================================
# Secret-material scanning (private-key / credential content)
# =============================================================================

#######################################
# List aidevops script basenames that look credential-like and may be redacted.
# Output:
#   newline-delimited basenames
#######################################
_privacy_aidevops_script_reference_basenames() {
	local source_path="${BASH_SOURCE[0]:-$0}"
	local script_dir=""
	local script_path basename

	script_dir=$(cd "$(dirname "$source_path")" 2>/dev/null && pwd -P) || script_dir=""
	if [[ -z "$script_dir" ]]; then
		return 0
	fi

	for script_path in "$script_dir"/*.sh "$script_dir"/*.mjs \
		"$script_dir"/*/*.sh "$script_dir"/*/*.mjs; do
		[[ -f "$script_path" ]] || continue
		basename="${script_path##*/}"
		if [[ ! "$basename" =~ $PRIVACY_CREDENTIAL_PREFIX_ERE ]]; then
			continue
		fi
		printf '%s\n' "$basename"
	done

	return 0
}

#######################################
# Redact aidevops script file references before credential-prefix scanning.
#
# Some aidevops helper basenames legitimately contain substrings such as
# "sk-" when they are written as `.agents/scripts/...` file references. Those
# are filenames, not credential values. Keep the allowlist narrow by only
# redacting references to shell or Node helper basenames that actually exist
# beside this helper (or one directory below it, matching
# `.agents/scripts/tests/...`).
# Arguments:
#   $1 - text content to redact
#   $2 - optional newline-delimited precomputed basename allowlist
# Output:
#   text with allowed script references replaced by a neutral marker
#######################################
_privacy_redact_aidevops_script_references() {
	local text="$1"
	local basenames_provided="${2+x}"
	local basenames_text="${2:-}"
	local redacted="$text"
	local basename

	if [[ -z "$basenames_provided" ]]; then
		basenames_text=$(_privacy_aidevops_script_reference_basenames)
	fi
	if [[ -z "$basenames_text" ]]; then
		printf '%s' "$redacted"
		return 0
	fi

	while IFS= read -r basename || [[ -n "$basename" ]]; do
		[[ -z "$basename" ]] && continue
		redacted="${redacted//.agents\/scripts\/$basename/[aidevops-script-reference]}"
		redacted="${redacted//.\/\.agents\/scripts\/$basename/[aidevops-script-reference]}"
		redacted="${redacted//\`$basename\`/[aidevops-script-reference]}"
		redacted="${redacted//\"$basename\"/[aidevops-script-reference]}"
		redacted="${redacted// $basename/ [aidevops-script-reference]}"
		redacted="${redacted//$'\n'$basename/$'\n'[aidevops-script-reference]}"
	done <<<"$basenames_text"

	printf '%s' "$redacted"
	return 0
}

#######################################
# Scan free-form text for private-key material or obvious credential values.
# Arguments:
#   $1 - text content to scan
#   $2 - optional precomputed aidevops script basename allowlist
# Output: one finding label per hit class
# Returns: 0 no hits, 1 hit(s)
#######################################
privacy_scan_secret_material_text() {
	local text="$1"
	local basenames_provided="${2+x}"
	local basenames_text="${2:-}"
	local hits=0
	local scan_text

	if [[ -z "$text" ]]; then
		return 0
	fi
	if [[ -n "$basenames_provided" ]]; then
		scan_text=$(_privacy_redact_aidevops_script_references "$text" "$basenames_text")
	else
		scan_text=$(_privacy_redact_aidevops_script_references "$text")
	fi
	if [[ "$scan_text" != "$text" ]]; then
		printf '%s\n' '[privacy-scan][ALLOW] aidevops script file reference' >&2
	fi

	if printf '%s' "$scan_text" | grep -qE -- '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'; then
		printf '%s\n' 'private-key PEM block'
		hits=$((hits + 1))
	fi
	if printf '%s' "$scan_text" | grep -qE -- "$PRIVACY_CREDENTIAL_PREFIX_ERE"; then
		printf '%s\n' 'credential token prefix'
		hits=$((hits + 1))
	fi

	if [[ "$hits" -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Scan all added diff lines for private-key material.
# Arguments:
#   $1 - base SHA (remote tip); may be all zeros for a new branch push
#   $2 - head SHA (local tip)
# Writes: "file:line: finding" lines to stdout
# Returns: 0 no hits, 1 hit(s)
#######################################
privacy_scan_secret_material_diff() {
	local base_sha="$1"
	local head_sha="$2"
	local diff_base="$base_sha"

	if [[ "$base_sha" =~ ^0+$ ]]; then
		local default_branch
		default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||') || default_branch=""
		[[ -z "$default_branch" ]] && default_branch="main"
		diff_base=$(git merge-base "$head_sha" "origin/""${default_branch}" 2>/dev/null) || diff_base=""
		[[ -z "$diff_base" ]] && diff_base=$(git hash-object -t tree /dev/null)
	fi

	local diff_output
	diff_output=$(git diff --unified=0 --no-color "$diff_base" "$head_sha" 2>/dev/null) || return 0
	[[ -z "$diff_output" ]] && return 0

	local hits=0 current_file="" line_num=0 in_pem=0
	local aidevops_script_basenames
	aidevops_script_basenames=$(_privacy_aidevops_script_reference_basenames)
	while IFS= read -r line; do
		case "$line" in
		"+++ b/"*) current_file="${line#+++ b/}"; line_num=0 ;;
		"--- "*) ;;
		"@@ "*)
			local rest="${line#@@ -*+}"
			local new_start="${rest%% *}"
			line_num="${new_start%,*}"
			;;
		"+"*)
			[[ "$line" == "+++ "* ]] && continue
			local added="${line:1}"
			local scan_added
			scan_added=$(_privacy_redact_aidevops_script_references "$added" "$aidevops_script_basenames")
			if [[ "$scan_added" != "$added" ]]; then
				printf '%s:%s: [privacy-scan][ALLOW] aidevops script file reference\n' "$current_file" "$line_num" >&2
			fi
			if [[ "$scan_added" =~ -----BEGIN[[:space:]][A-Z0-9[:space:]]*PRIVATE[[:space:]]KEY----- ]]; then
				printf '%s:%s: private-key PEM block\n' "$current_file" "$line_num"
				hits=$((hits + 1))
				in_pem=1
			elif [[ "$in_pem" -eq 1 ]]; then
				printf '%s:%s: private-key PEM block content\n' "$current_file" "$line_num"
				hits=$((hits + 1))
			fi
			if [[ "$scan_added" =~ -----END[[:space:]][A-Z0-9[:space:]]*PRIVATE[[:space:]]KEY----- ]]; then
				in_pem=0
			fi
			if printf '%s' "$scan_added" | grep -qE -- "$PRIVACY_CREDENTIAL_PREFIX_ERE"; then
				printf '%s:%s: credential token prefix\n' "$current_file" "$line_num"
				hits=$((hits + 1))
			fi
			line_num=$((line_num + 1))
			;;
		" "*) line_num=$((line_num + 1)) ;;
		esac
	done <<<"$diff_output"

	if [[ "$hits" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# =============================================================================
# Diff scanning
# =============================================================================

#######################################
# Build a `git diff` path filter from PRIVACY_SCAN_GLOBS suitable for
# `git diff -- <pathspecs>`. Outputs pathspec args one per line.
#######################################
_privacy_pathspec_args() {
	local glob
	if [[ -n "$PRIVACY_SCAN_GLOBS_TEXT" ]]; then
		local normalized
		normalized=$(printf '%s' "$PRIVACY_SCAN_GLOBS_TEXT" | sed 's/[,:]/\
/g')
		while IFS= read -r glob || [[ -n "$glob" ]]; do
			[[ -z "$glob" ]] && continue
			if [[ "$glob" == */ ]]; then
				printf '%s**\n' "$glob"
			else
				printf '%s\n' "$glob"
			fi
		done <<<"$normalized"
		return 0
	fi
	for glob in "${PRIVACY_SCAN_GLOBS[@]}"; do
		# Glob ending with / → match everything under that directory
		if [[ "$glob" == */ ]]; then
			printf '%s**\n' "$glob"
		else
			printf '%s\n' "$glob"
		fi
	done
	return 0
}

#######################################
# Scan the diff between two SHAs for added lines matching any private slug or
# local/private path. Only lines added (prefix '+') in PRIVACY_SCAN_GLOBS are
# considered — we don't flag pre-existing content that has already been
# pushed. Output format: "file:NNN: slug" for each hit.
# Arguments:
#   $1 - base SHA (remote tip); may be 40 zeros for a new branch push
#   $2 - head SHA (local tip)
#   $3 - file containing newline-separated private slugs
# Writes: "file:line: slug" lines to stdout for each hit
# Returns: 0 if no hits, 1 if at least one hit
#######################################
privacy_scan_diff() {
	local base_sha="$1"
	local head_sha="$2"
	local slugs_file="$3"

	if [[ ! -f "$slugs_file" ]]; then
		return 0
	fi

	# Build path filter args for git diff
	local -a pathspecs=()
	while IFS= read -r p; do
		pathspecs+=("$p")
	done < <(_privacy_pathspec_args)

	# If base is all zeros, this is a new branch push — diff against the merge
	# base with the default branch instead (or fall back to empty tree).
	local diff_base="$base_sha"
	if [[ "$base_sha" =~ ^0+$ ]]; then
		local default_branch
		default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||') || default_branch=""
		if [[ -z "$default_branch" ]]; then
			default_branch="main"
		fi
		diff_base=$(git merge-base "$head_sha" "origin/${default_branch}" 2>/dev/null) || diff_base=""
		if [[ -z "$diff_base" ]]; then
			# Fall back to the git empty tree
			diff_base=$(git hash-object -t tree /dev/null)
		fi
	fi

	# Produce a unified diff of ADDED lines in the path filter
	local diff_output
	diff_output=$(git diff --unified=0 --no-color "$diff_base" "$head_sha" -- "${pathspecs[@]}" 2>/dev/null) || return 0

	if [[ -z "$diff_output" ]]; then
		return 0
	fi

	# Walk the diff, tracking current file and hunk line counter. Match added
	# lines (those starting with "+" but not "+++") against the centralized
	# free-form scanner so diff and gh-write paths share one policy.
	local hits=0
	local current_file=""
	local line_num=0
	while IFS= read -r line; do
		case "$line" in
		"+++ b/"*)
			current_file="${line#+++ b/}"
			line_num=0
			;;
		"--- "*) ;;
		"@@ "*)
			# @@ -old,oldc +new,newc @@ — extract new start
			local rest="${line#@@ -*+}"
			local new_start="${rest%% *}"
			new_start="${new_start%,*}"
			line_num="$new_start"
			;;
		"+"*)
			# Skip the "+++ b/..." which we already handled
			[[ "$line" == "+++ "* ]] && continue
			local added="${line:1}"
			local matching_hits hit
			matching_hits=$(privacy_scan_text "$added" "$slugs_file")
			local scan_rc=$?
			if [[ "$scan_rc" -eq 1 ]]; then
				while IFS= read -r hit; do
					[[ -z "$hit" ]] && continue
					printf '%s:%s: %s\n' "$current_file" "$line_num" "$hit"
					hits=$((hits + 1))
				done <<<"$matching_hits"
			fi
			line_num=$((line_num + 1))
			;;
		" "*)
			line_num=$((line_num + 1))
			;;
		esac
	done <<<"$diff_output"

	if [[ "$hits" -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Scan added diff lines with the tagged public-entity scanner. Output contains
# file/line context and generic hit classes only.
# Arguments: $1=base SHA $2=head SHA $3=tagged entity inventory
#######################################
privacy_scan_public_diff() {
	local base_sha="$1"
	local head_sha="$2"
	local entities_file="$3"
	local diff_base="$base_sha" diff_output
	local current_file="" line_num=0 hits=0 line added matching_hits scan_rc hit
	local aidevops_script_basenames

	[[ -f "$entities_file" ]] || return 2
	if [[ "$base_sha" =~ ^0+$ ]]; then
		local default_branch
		default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||') || default_branch="ma""in"
		diff_base=$(git merge-base "$head_sha" "origin/${default_branch}" 2>/dev/null) || diff_base=""
		[[ -z "$diff_base" ]] && diff_base=$(git hash-object -t tree /dev/null)
	fi
	diff_output=$(git diff --unified=0 --no-color "$diff_base" "$head_sha" -- . 2>/dev/null) || return 2
	aidevops_script_basenames=$(_privacy_aidevops_script_reference_basenames)
	while IFS= read -r line; do
		case "$line" in
		"+""++ b/"*)
			current_file="${line#+""++ b/}"
			line_num=0
			;;
		"@@ "*)
			local rest="${line#@@ -*+}"
			local new_start="${rest%% *}"
			line_num="${new_start%,*}"
			;;
		"+"*)
			[[ "$line" == "+""++ " ]] && continue
			added="${line:1}"
			matching_hits=$(privacy_scan_public_text "$added" "$entities_file" "$aidevops_script_basenames")
			scan_rc=$?
			if [[ "$scan_rc" -eq 1 ]]; then
				while IFS= read -r hit; do
					[[ -n "$hit" ]] && printf '%s:%s: %s\n' "$current_file" "$line_num" "$hit"
				done <<<"$matching_hits"
				hits=$((hits + 1))
			elif [[ "$scan_rc" -ne 0 ]]; then
				return 2
			fi
			line_num=$((line_num + 1))
			;;
		" "*) line_num=$((line_num + 1)) ;;
		esac
	done <<<"$diff_output"
	[[ "$hits" -gt 0 ]] && return 1
	return 0
}
