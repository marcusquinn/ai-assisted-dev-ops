#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub CLI Wrappers -- REST Fallback (t2574, GH#20243; t2689)
# =============================================================================
# When gh's native `gh issue create|comment|edit|view|list` commands fail and
# GraphQL quota is exhausted (remaining <= threshold), these translators retry
# via `gh api` REST endpoints, which run against GitHub's separate 5000/hour
# core REST budget.
#
# Detection: _rest_should_fallback -- consults gh api rate_limit.
# Write translators (t2574): _rest_issue_create, _rest_issue_comment,
#   _rest_pr_comment, _rest_issue_edit, _rest_pr_create.
# Read translators (t2689, t2772): _rest_issue_view, _rest_issue_list, _rest_pr_list.
#
# Read rewrites are guarded by operation-specific argument and JSON-field
# validators. Shapes without an exact REST equivalent remain on native gh and
# never reach the permissive translator path.
#
# Loaded by shared-gh-wrappers.sh. Do not source directly.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_REST_FALLBACK_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_REST_FALLBACK_LOADED=1

_gh_rest_fallback_dir="${_SHARED_GH_WRAPPERS_DIR:-}"
if [[ -z "$_gh_rest_fallback_dir" && -n "${BASH_SOURCE[0]:-}" ]]; then
	_gh_rest_fallback_dir="${BASH_SOURCE[0]%/*}"
	[[ "$_gh_rest_fallback_dir" == "${BASH_SOURCE[0]}" ]] && _gh_rest_fallback_dir="."
elif [[ -z "$_gh_rest_fallback_dir" && -n "${ZSH_VERSION:-}" && -f "${0:-}" ]]; then
	_gh_rest_fallback_dir="${0%/*}"
	[[ "$_gh_rest_fallback_dir" == "$0" ]] && _gh_rest_fallback_dir="."
fi
if ! declare -F gh_request_state_rate_json >/dev/null 2>&1 && [[ -f "${_gh_rest_fallback_dir}/shared-gh-request-state.sh" ]]; then
	# shellcheck source=./shared-gh-request-state.sh
	# shellcheck disable=SC1091
	source "${_gh_rest_fallback_dir}/shared-gh-request-state.sh"
fi
# shellcheck source=./shared-gh-wrappers-rest-read-semantics.sh
# shellcheck disable=SC1091
source "${_gh_rest_fallback_dir}/shared-gh-wrappers-rest-read-semantics.sh"
unset _gh_rest_fallback_dir

# Threshold below which we route reads/writes through REST instead of GraphQL.
# Env override: AIDEVOPS_GH_REST_FALLBACK_THRESHOLD
#
# Tuning rationale:
#   t2574 (default 10):   only engaged after 99.8% of the GraphQL budget was
#                         spent — by then in-flight ops were already failing.
#   t2744 (default 1000): proactive fallback at 20% remaining. Routes read-
#                         heavy traffic through the 5000/hr REST core pool
#                         while GraphQL keeps reserve for GraphQL-only
#                         mutations. Doubles steady-state capacity.
#   t2902 (default 1500): raised again. Operational data over 4.5 days on
#                         the marcusquinn runtime: 47 lifetime circuit-breaker
#                         fires (~10/day) AND GraphQL still hit 0/5000. The
#                         1000-point reserve was consumed faster than expected
#                         because `gh search` calls in pulse-batch-prefetch
#                         (per-owner per-cycle) were not routed through this
#                         threshold — they bypassed the wrappers entirely.
#                         t2902 wires those call sites in (see
#                         pulse-batch-prefetch-helper.sh) AND raises the
#                         threshold to give earlier headroom (1500 = 30%
#                         remaining). Pair: instrumentation + earlier
#                         fallback. Trivial revert: set back to 1000 here.
#   t3448 (default 3000): route safe read/list/search traffic through REST
#                         before GraphQL drops near the dispatch circuit-breaker
#                         floor. Operational evidence showed repeated trips while
#                         GraphQL was still around 2500/5000 because list/view
#                         bursts drained the remaining headroom between pulse
#                         cycles. Writes and GraphQL-only gates remain unchanged;
#                         this only shifts supported read/list/search translators
#                         to the REST core bucket earlier.
_GH_REST_FALLBACK_THRESHOLD="${AIDEVOPS_GH_REST_FALLBACK_THRESHOLD:-3000}"
_GH_LAST_GRAPHQL_REMAINING=""
_GH_REST_PR_VIEW_CACHE_DIR=""

#######################################
# Return 0 when REST PR view responses may be reused within the configured TTL.
# Pulse may point this at a stable cross-cycle directory; mutation-sensitive
# callers MUST bypass with AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1.
# Returns: 0 when enabled, 1 otherwise.
#######################################
_rest_pr_view_cache_enabled() {
	[[ "${AIDEVOPS_GH_PR_VIEW_CACHE:-0}" == "1" ]] || return 1
	[[ "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" == "1" ]] && return 1
	local ttl="${AIDEVOPS_GH_PR_VIEW_CACHE_TTL:-15}"
	[[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	jq -n 'true' >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Resolve the per-process REST PR view cache directory.
# Returns: path on stdout; 0 on success, 1 on mkdir failure.
#######################################
_rest_pr_view_cache_dir() {
	if [[ -n "${AIDEVOPS_GH_PR_VIEW_CACHE_DIR:-}" ]]; then
		mkdir -p "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR" 2>/dev/null || return 1
		printf '%s' "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR"
		return 0
	fi
	if [[ -z "$_GH_REST_PR_VIEW_CACHE_DIR" ]]; then
		_GH_REST_PR_VIEW_CACHE_DIR="${TMPDIR:-/tmp}/aidevops-gh-pr-view-cache-${$}"
	fi
	mkdir -p "$_GH_REST_PR_VIEW_CACHE_DIR" 2>/dev/null || return 1
	printf '%s' "$_GH_REST_PR_VIEW_CACHE_DIR"
	return 0
}

#######################################
# Build a filesystem-safe REST PR view cache path for repo+PR.
# Args: $1=repo_slug $2=pr_number
# Returns: path on stdout; 0 on success, 1 on mkdir failure.
#######################################
_rest_pr_view_cache_path() {
	local repo="$1"
	local num="$2"
	local dir=""
	dir="$(_rest_pr_view_cache_dir)" || return 1
	local safe_repo=""
	safe_repo="$(printf '%s' "$repo" | tr '/: ' '___')"
	printf '%s/%s__%s.json' "$dir" "$safe_repo" "$num"
	return 0
}

#######################################
# Emit a cached/raw REST PR object using gh-pr-view-compatible projection args.
# Args: $1=raw_json $2=json_fields $3=jq_expr
# Returns: jq exit code, or 0 for raw output.
#######################################
_rest_pr_view_emit_json() {
	local raw_json="$1"
	local json_fields="$2"
	local jq_expr="$3"
	if [[ -n "$json_fields" ]]; then
		jq_expr="$(_rest_pr_object_json_jq "$json_fields" "$jq_expr")"
	fi
	if [[ -n "$jq_expr" ]]; then
		printf '%s\n' "$raw_json" | jq -r "$jq_expr"
		return $?
	fi
	printf '%s\n' "$raw_json"
	return 0
}

#######################################
# Try to emit a fresh cached REST PR object.
# Args: $1=cache_path $2=cache_ttl $3=cache_name $4=json_fields $5=jq_expr
# Returns: 0 when cache emitted, 1 when caller should fetch fresh data.
#######################################
_rest_pr_view_cache_emit_if_fresh() {
	local cache_path="$1"
	local cache_ttl="$2"
	local cache_name="$3"
	local json_fields="$4"
	local jq_expr="$5"
	local cache_now=""
	local cache_mtime=""
	local cache_age=0
	local raw_json=""
	cache_now=$(date +%s 2>/dev/null || printf '0')
	cache_mtime=$(perl -e 'print((stat($ARGV[0]))[9] || 0)' "$cache_path" 2>/dev/null || printf '0')
	if [[ "$cache_now" =~ ^[0-9]+$ && "$cache_mtime" =~ ^[0-9]+$ ]]; then
		cache_age=$(( cache_now - cache_mtime ))
	else
		cache_age=$(( cache_ttl + 1 ))
	fi
	if [[ "$cache_age" -lt 0 || "$cache_age" -gt "$cache_ttl" ]]; then
		gh_record_call other "$cache_name" unknown other stale 2>/dev/null || true
		return 1
	fi
	raw_json="$(jq -c '.' "$cache_path" 2>/dev/null)" || raw_json=""
	if [[ -z "$raw_json" ]]; then
		gh_record_call other "$cache_name" unknown other invalid-json 2>/dev/null || true
		return 1
	fi
	gh_record_call other "$cache_name" unknown other hit 2>/dev/null || true
	_rest_pr_view_emit_json "$raw_json" "$json_fields" "$jq_expr"
	return $?
}

#######################################
# Execute a gh api command with optional wall-clock timeout (t2913).
# Fail-open: if _gh_with_timeout is not loaded, runs gh api directly.
#
# Args: $1=timeout_class (read|write)  $2..=gh api args
# Returns: exit code of the gh api call.
#######################################
_rest_api_call() {
	local _class="$1"; shift
	local _pool="rest-core"
	local _arg
	for _arg in "$@"; do
		case "$_arg" in
		/search/*) _pool="rest-search" ;;
		*) ;;
		esac
	done
	if command -v github_app_api_call >/dev/null 2>&1; then
		github_app_api_call "$_class" "$_pool" "$@"
		return $?
	fi
	if command -v _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout "$_class" "$@"
	else
		"$@"
	fi
	return $?
}

#######################################
# Build the `-F` value for `gh api` that uploads a file's contents as the
# `body` form field. Centralised so the `body=@...` literal lives in exactly
# one place; callers use "$(_rest_body_file_arg "$path")".
#######################################
_rest_body_file_arg() {
	local path="$1"
	printf 'body=@%s' "$path"
	return 0
}

#######################################
# Append the aidevops signature footer to a body file if not already present.
# Used by REST fallback write translators to ensure every GitHub write carries
# the canonical <!-- aidevops:sig --> audit marker (t2707).
#
# Fail-open: a missing helper or write error must never break the write call.
#
# Args: $1=body_file_path
# Returns: 0 always
#######################################
_rest_append_sig() {
	local body_file="$1"
	[[ -f "$body_file" ]] || return 0
	grep -Fqx '<!-- aidevops:sig -->' "$body_file" 2>/dev/null && return 0
	local helper="" _cand
	for _cand in \
		"${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" \
		"$(dirname "${BASH_SOURCE[0]:-$0}")/gh-signature-helper.sh"; do
		[[ -x "$_cand" ]] && { helper="$_cand"; break; }
	done
	[[ -z "$helper" ]] && return 0
	local footer
	footer=$("$helper" footer 2>/dev/null) || return 0
	[[ -n "$footer" ]] && printf '%s' "$footer" >>"$body_file" || true
	return 0
}

#######################################
# Emit one REST helper output line while tolerating early-closing consumers.
#
# Pulse prefetch/list callers may pipe REST fallback output into consumers that
# intentionally exit after the first match. Bash's printf reports EPIPE as noisy
# "Broken pipe" stderr output unless stderr is suppressed at the emit site.
# Return 1 so callers can stop emitting without treating the closed pipe as a
# legitimate REST fallback failure.
#
# Args: $1=line
# Returns: 0 when emitted, 1 when the output pipe is closed.
#######################################
_rest_emit_line() {
	local _line="$1"
	printf '%s\n' "$_line" 2>/dev/null || return 1
	return 0
}

#######################################
# _rest_split_csv: portable CSV tokeniser. Emits one token per line to stdout.
#
# Works in bash 3.2+, zsh 5+, and BusyBox ash — uses POSIX parameter
# expansion only. Does NOT use:
#   - `read -ra arr` (bash-only; zsh emits "bad option: -a")
#   - `read -A arr` (zsh-only; bash emits "invalid option")
#   - `mapfile`/`readarray` (bash 4.4+ only)
#   - `${(f)var}` (zsh-only array expansion)
#
# Args: $1=csv_string $2=delimiter (default: comma)
# Returns: 0 always
#
# Usage:
#   while IFS= read -r _tok; do
#       [[ -n "$_tok" ]] && arr+=("$_tok")
#   done < <(_rest_split_csv "a,b,c")
#######################################
_rest_split_csv() {
	local _str="$1"
	local _delim="${2:-,}"
	while [[ -n "$_str" ]]; do
		if [[ "$_str" == *"$_delim"* ]]; then
			_rest_emit_line "${_str%%"$_delim"*}" || break
			_str="${_str#*"$_delim"}"
		else
			_rest_emit_line "$_str" || break
			_str=""
		fi
	done
	return 0
}

#######################################
# Fetch the full rate-limit projection for shared, auth-scoped persistence.
#######################################
_rest_rate_limit_json_fetch() {
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read gh api rate_limit
		return $?
	fi
	gh api rate_limit
	return $?
}

#######################################
# Return 0 (true) when GraphQL rate limit remaining is <= threshold.
# `gh api rate_limit` is a free endpoint (does not count against quotas).
# Fail-safe: an unavailable or malformed rate projection does not trigger a
# second transport path. Callers retain the original GitHub CLI failure.
#
# Optional arg: $1=pre-computed remaining count (integer string).
# When provided, skips the `gh api rate_limit` call — callers that already
# know the current rate-limit state (e.g. after fetching it once for a loop)
# can pass it to avoid redundant I/O.
#######################################
_rest_should_fallback() {
	# Test/CI override: set _GH_SHOULD_FALLBACK_OVERRIDE=1 to force true without
	# requiring a real rate-limit state. Use in unit tests and manual smoke runs.
	[[ "${_GH_SHOULD_FALLBACK_OVERRIDE:-0}" == "1" ]] && return 0
	# Pulse-cycle override: when the orchestrator has already observed low
	# GraphQL headroom, route supported read/list wrappers through REST without
	# every subprocess re-querying rate_limit or attempting one more GraphQL call.
	[[ "${AIDEVOPS_GH_FORCE_REST_READS:-0}" == "1" ]] && return 0
	local remaining="${1:-}"
	if [[ -z "$remaining" ]]; then
		local _ttl="${AIDEVOPS_GH_REST_FALLBACK_CACHE_TTL:-20}"
		[[ "$_ttl" =~ ^[0-9]+$ ]] || _ttl=20
		[[ "${AIDEVOPS_GH_REST_FALLBACK_DISABLE_CACHE:-0}" != "1" ]] || _ttl=0
		if declare -F gh_request_state_rate_json >/dev/null 2>&1; then
			local rate_json=""
			if ! rate_json=$(gh_request_state_rate_json normal "$_ttl" _rest_rate_limit_json_fetch 2>/dev/null); then
				return 1
			fi
			remaining=$(printf '%s' "$rate_json" | jq -r '.resources.graphql.remaining // ""' 2>/dev/null) || remaining=""
		else
			remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null)
		fi
	fi
	[[ -n "$remaining" ]] || return 1
	[[ "$remaining" =~ ^[0-9]+$ ]] || return 1
	_GH_LAST_GRAPHQL_REMAINING="$remaining"
	if [[ "$remaining" -le "$_GH_REST_FALLBACK_THRESHOLD" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Return 0 when argv contains --search or --search=... .
# Args: gh-style argv
#######################################
_rest_args_have_search() {
	local _arg
	for _arg in "$@"; do
		case "$_arg" in
		--search|--search=*|-S) return 0 ;;
		esac
	done
	return 1
}

#######################################
# Return 0 when pulse/workflow routing should prefer REST for semantically
# equivalent read calls even while GraphQL is healthy. This is not a lower
# synthetic budget; it shares traffic across GitHub's native REST and GraphQL
# pools so GraphQL remains available for GraphQL-only operations.
#######################################
_rest_read_first_enabled() {
	[[ "${AIDEVOPS_GH_REST_FIRST_READS:-0}" == "1" ]] && return 0
	return 1
}

#######################################
# Extract the gh-style --json field list from argv. Emits empty when absent.
# Args: gh-style argv
#######################################
_rest_args_json_fields() {
	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--json) printf '%s' "${2:-}"; return 0 ;;
		--json=*) printf '%s' "${_arg#--json=}"; return 0 ;;
		*) shift ;;
		esac
	done
	return 0
}

#######################################
# Internal: If first arg looks like a GitHub issue URL, extract the repo slug
# and issue number. Returns via stdout on two lines (repo, then num) so we
# stay bash 3.2-compatible (nameref `local -n` is bash 4.3+).
# Caller pattern:  { read -r repo; read -r num; } < <(_rest_normalize_issue_ref "$ref" "$repo")
# If the ref is a bare number, the first line is the current repo arg unchanged.
# Args: $1=url_or_num $2=current_repo_value (empty OK)
#######################################
_rest_normalize_issue_ref() {
	local raw="$1"
	local repo="${2:-}"
	local num=""
	if [[ "$raw" =~ ^https?://github\.com/([^/]+/[^/]+)/(issues|pull)/([0-9]+) ]]; then
		[[ -z "$repo" ]] && repo="${BASH_REMATCH[1]}"
		num="${BASH_REMATCH[3]}"
	else
		num="$raw"
	fi
	printf '%s\n%s\n' "$repo" "$num"
	return 0
}

#######################################
# _rest_issue_create: POST /repos/{owner}/{repo}/issues.
# Parses gh-style args (--title, --body, --body-file, --label, --assignee,
# --milestone) into a REST payload. Emits the issue html_url on stdout,
# mirroring `gh issue create`. Returns underlying gh api exit code.
#######################################
_rest_issue_create() {
	gh_record_call rest _rest_issue_create 2>/dev/null || true
	local title=""
	local body=""
	local body_file=""
	local repo=""
	local milestone=""
	local has_body=0
	local -a labels
	local -a assignees
	local _tok
	labels=()
	assignees=()

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--title) title="${2:-}"; shift 2 ;;
		--title=*) title="${_arg#--title=}"; shift ;;
		--body) body="${2:-}"; has_body=1; shift 2 ;;
		--body=*) body="${_arg#--body=}"; has_body=1; shift ;;
		--body-file) body_file="${2:-}"; has_body=1; shift 2 ;;
		--body-file=*) body_file="${_arg#--body-file=}"; has_body=1; shift ;;
		--label) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_rest_split_csv "${2:-}"); shift 2 ;;
		--label=*) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_rest_split_csv "${_arg#--label=}"); shift ;;
		--assignee) while IFS= read -r _tok; do [[ -n "$_tok" ]] && assignees+=("$_tok"); done < <(_rest_split_csv "${2:-}"); shift 2 ;;
		--assignee=*) while IFS= read -r _tok; do [[ -n "$_tok" ]] && assignees+=("$_tok"); done < <(_rest_split_csv "${_arg#--assignee=}"); shift ;;
		--milestone) milestone="${2:-}"; shift 2 ;;
		--milestone=*) milestone="${_arg#--milestone=}"; shift ;;
		*) shift ;;
		esac
	done

	if [[ -z "$repo" ]]; then
		printf '_rest_issue_create: --repo is required\n' >&2
		return 1
	fi
	if [[ -z "$title" ]]; then
		printf '_rest_issue_create: --title is required\n' >&2
		return 1
	fi

	local tmp_body="" tmp_body_owned=0
	if [[ $has_body -eq 1 ]]; then
		if [[ -n "$body_file" ]]; then
			tmp_body="$body_file"
		else
			tmp_body=$(mktemp -t aidevops-gh-rest-body.XXXXXX) || return 1
			tmp_body_owned=1
			printf '%s' "$body" >"$tmp_body"
		fi
	fi
	[[ -n "$tmp_body" ]] && _rest_append_sig "$tmp_body"

	local -a api_args=(-X POST "/repos/${repo}/issues" -f "title=${title}")
	[[ -n "$tmp_body" ]] && api_args+=(-F "$(_rest_body_file_arg "$tmp_body")")
	local _lbl
	for _lbl in "${labels[@]}"; do
		[[ -n "$_lbl" ]] && api_args+=(-f "labels[]=${_lbl}")
	done
	local _asn
	for _asn in "${assignees[@]}"; do
		[[ -n "$_asn" ]] && api_args+=(-f "assignees[]=${_asn}")
	done
	[[ -n "$milestone" ]] && api_args+=(-F "milestone=${milestone}")

	local html_url rc
	html_url=$(gh api "${api_args[@]}" --jq '.html_url' 2>&1)
	rc=$?

	[[ $tmp_body_owned -eq 1 && -f "$tmp_body" ]] && rm -f "$tmp_body"

	if [[ $rc -eq 0 ]]; then
		printf '%s\n' "$html_url"
	else
		printf '%s\n' "$html_url" >&2
	fi
	return $rc
}

#######################################
# _rest_issue_comment: POST /repos/{owner}/{repo}/issues/{N}/comments.
# Mirrors `gh issue comment <num_or_url> --repo SLUG --body ... | --body-file PATH`.
# Emits the new comment html_url on stdout. Returns underlying gh api exit code.
#######################################
_rest_issue_comment() {
	gh_record_call rest _rest_issue_comment 2>/dev/null || true
	local num_or_url=""
	local repo=""
	local body=""
	local body_file=""
	local has_body=0

	local _first="${1:-}"
	if [[ $# -gt 0 && "$_first" != --* ]]; then
		num_or_url="$_first"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--body) body="${2:-}"; has_body=1; shift 2 ;;
		--body=*) body="${_arg#--body=}"; has_body=1; shift ;;
		--body-file) body_file="${2:-}"; has_body=1; shift 2 ;;
		--body-file=*) body_file="${_arg#--body-file=}"; has_body=1; shift ;;
		*) shift ;;
		esac
	done

	local num=""
	{ read -r repo; read -r num; } < <(_rest_normalize_issue_ref "$num_or_url" "$repo")

	if [[ -z "$repo" || -z "$num" ]]; then
		printf '_rest_issue_comment: issue number and --repo are required\n' >&2
		return 1
	fi
	if [[ ! "$num" =~ ^[0-9]+$ ]]; then
		printf '_rest_issue_comment: invalid issue number: %s\n' "$num" >&2
		return 1
	fi
	if [[ $has_body -eq 0 ]]; then
		printf '_rest_issue_comment: --body or --body-file required\n' >&2
		return 1
	fi

	local tmp_body="" tmp_body_owned=0
	if [[ -n "$body_file" ]]; then
		tmp_body="$body_file"
	else
		tmp_body=$(mktemp -t aidevops-gh-rest-body.XXXXXX) || return 1
		tmp_body_owned=1
		printf '%s' "$body" >"$tmp_body"
	fi
	_rest_append_sig "$tmp_body"

	local out rc
	out=$(gh api -X POST "/repos/${repo}/issues/${num}/comments" \
		-F "$(_rest_body_file_arg "$tmp_body")" --jq '.html_url' 2>&1)
	rc=$?

	[[ $tmp_body_owned -eq 1 && -f "$tmp_body" ]] && rm -f "$tmp_body"

	if [[ $rc -eq 0 ]]; then
		printf '%s\n' "$out"
	else
		printf '%s\n' "$out" >&2
	fi
	return $rc
}

#######################################
# _rest_pr_comment: POST /repos/{owner}/{repo}/issues/{PR}/comments.
# GitHub pull requests share the issue comments REST endpoint, so this mirrors
# _rest_issue_comment while keeping instrumentation and call sites explicit.
# Args: gh-style `pr comment` argv.
#######################################
_rest_pr_comment() {
	gh_record_call rest _rest_pr_comment 2>/dev/null || true
	_rest_issue_comment "$@"
	return $?
}

#######################################
# Return success when one exact value occurs in a newline-separated set.
_rest_lines_contain() {
	local values="$1"
	local expected="$2"
	local value=""
	while IFS= read -r value; do
		[[ -n "$value" && "$value" == "$expected" ]] && return 0
	done <<<"$values"
	return 1
}

#######################################
# Filter requested issue-edit deltas against a validated current set. Adds emit
# only absent values. Removes emit only present values and exclude requested
# adds so add wins, matching the existing full-array computation.
_rest_filter_issue_deltas() {
	local current="$1"
	local candidates="$2"
	local excluded="$3"
	local mode="$4"
	local candidate=""
	local emitted=""
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		_rest_lines_contain "$emitted" "$candidate" && continue
		if [[ "$mode" == "add" ]]; then
			_rest_lines_contain "$current" "$candidate" && continue
		else
			_rest_lines_contain "$current" "$candidate" || continue
			_rest_lines_contain "$excluded" "$candidate" && continue
		fi
		printf '%s\n' "$candidate"
		emitted="${emitted}${emitted:+$'\n'}${candidate}"
	done <<<"$candidates"
	return 0
}

#######################################
# Return success only when the issue snapshot has structurally valid label and
# assignee arrays. Delta mutations must never start from unknown current state.
_REST_ISSUE_JSON_STRING_TYPE=string
_rest_issue_delta_snapshot_valid() {
	local current_json="$1"
	local array_type="array"
	local object_type="object"
	printf '%s' "$current_json" | jq -e \
		--arg array_type "$array_type" --arg object_type "$object_type" \
		--arg string_type "$_REST_ISSUE_JSON_STRING_TYPE" '
		((.labels | type) == $array_type) and
		(all(.labels[]; (type == $object_type) and ((.name | type) == $string_type) and ((.name | length) > 0))) and
		((.assignees | type) == $array_type) and
		(all(.assignees[]; (type == $object_type) and ((.login | type) == $string_type) and ((.login | length) > 0)))
	' >/dev/null 2>&1
	return $?
}

#######################################
# Apply one add/remove array operation through a targeted GitHub REST endpoint.
_rest_issue_apply_array_delta() {
	local method="$1"
	local path="$2"
	local field="$3"
	local values="$4"
	[[ -n "$values" ]] || return 0
	local -a api_args=(-X "$method" "$path")
	local value=""
	while IFS= read -r value; do
		[[ -n "$value" ]] && api_args+=(-f "${field}[]=${value}")
	done <<<"$values"
	_rest_api_call write gh api "${api_args[@]}" >/dev/null 2>&1
	local rc=$?
	[[ $rc -eq 0 ]] && _REST_ISSUE_DELTA_MUTATED=1
	return $rc
}

#######################################
# Remove exact labels through per-label REST endpoints so concurrent unrelated
# additions are never submitted in a stale replacement array.
_rest_issue_remove_label_deltas() {
	local issue_path="$1"
	local label_values="$2"
	local label=""
	local encoded=""
	while IFS= read -r label; do
		[[ -n "$label" ]] || continue
		encoded=$(printf '%s' "$label" | jq -sRr '@uri') || return 1
		_rest_api_call write gh api -X DELETE "${issue_path}/labels/${encoded}" >/dev/null 2>&1 || return 1
		_REST_ISSUE_DELTA_MUTATED=1
	done <<<"$label_values"
	return 0
}

#######################################
# Apply filtered deltas in the phase-specific safe order. Passthrough metadata
# adds first so a rejected replacement leaves existing values intact. General
# status transitions remove first so a failed target add cannot create a dual
# status state. Ownership handoffs may explicitly use add-first when continuous
# acceptance is more important than avoiding a temporary dual-status overlap.
_rest_issue_apply_delta_plan() {
	local issue_path="$1"
	local adds_l="$2"
	local rms_l="$3"
	local adds_a="$4"
	local rms_a="$5"
	local delta_order="$6"
	if [[ "$delta_order" == "remove-first" ]]; then
		_rest_issue_remove_label_deltas "$issue_path" "$rms_l" || return 1
		_rest_issue_apply_array_delta DELETE "${issue_path}/assignees" assignees "$rms_a" || return 1
		_rest_issue_apply_array_delta POST "${issue_path}/labels" labels "$adds_l" || return 1
		_rest_issue_apply_array_delta POST "${issue_path}/assignees" assignees "$adds_a" || return 1
		return 0
	fi
	_rest_issue_apply_array_delta POST "${issue_path}/labels" labels "$adds_l" || return 1
	_rest_issue_apply_array_delta POST "${issue_path}/assignees" assignees "$adds_a" || return 1
	_rest_issue_remove_label_deltas "$issue_path" "$rms_l" || return 1
	_rest_issue_apply_array_delta DELETE "${issue_path}/assignees" assignees "$rms_a" || return 1
	return 0
}

#######################################
# Apply label and assignee deltas without full-array replacement. One validated
# GET filters no-op requests; targeted subresource writes then preserve any
# unrelated value added concurrently after that snapshot.
_rest_issue_edit_preserving_deltas() {
	gh_record_call rest _rest_issue_edit_preserving_deltas 2>/dev/null || true
	_REST_ISSUE_DELTA_FAILURE_STAGE="parse"
	_REST_ISSUE_DELTA_MUTATED=0
	local num_or_url="${1:-}"
	shift || true
	local repo=""
	local delta_order="add-first"
	local required_label=""
	local required_assignee=""
	local -a delta_add_labels=() delta_rm_labels=() delta_add_assignees=() delta_rm_assignees=()
	local arg="" value="" token=""
	while [[ $# -gt 0 ]]; do
		arg="$1"
		[[ "$arg" == *=* ]] && { value="${arg#*=}"; arg="${arg%%=*}"; shift; } || { value="${2:-}"; shift 2; }
		case "$arg" in
		--repo) repo="$value" ;;
		--require-label) required_label="$value" ;;
		--require-assignee) required_assignee="$value" ;;
		--delta-order)
			[[ "$value" == "add-first" || "$value" == "remove-first" ]] || return 1
			delta_order="$value"
			;;
		--add-label) while IFS= read -r token; do [[ -n "$token" ]] && delta_add_labels+=("$token"); done < <(_rest_split_csv "$value") ;;
		--remove-label) while IFS= read -r token; do [[ -n "$token" ]] && delta_rm_labels+=("$token"); done < <(_rest_split_csv "$value") ;;
		--add-assignee) while IFS= read -r token; do [[ -n "$token" ]] && delta_add_assignees+=("$token"); done < <(_rest_split_csv "$value") ;;
		--remove-assignee) while IFS= read -r token; do [[ -n "$token" ]] && delta_rm_assignees+=("$token"); done < <(_rest_split_csv "$value") ;;
		*) return 1 ;;
		esac
	done
	local num=""
	{ read -r repo; read -r num; } < <(_rest_normalize_issue_ref "$num_or_url" "$repo")
	[[ -n "$repo" && "$num" =~ ^[0-9]+$ ]] || return 1

	_REST_ISSUE_DELTA_FAILURE_STAGE="snapshot"
	local issue_path="/repos/${repo}/issues"
	issue_path="${issue_path}/${num}"
	local current_json="" current_labels="" current_assignees=""
	current_json=$(_rest_api_call read gh api "$issue_path" 2>/dev/null) || return 1
	_rest_issue_delta_snapshot_valid "$current_json" || return 1
	current_labels=$(printf '%s' "$current_json" | jq -r '.labels[].name') || return 1
	current_assignees=$(printf '%s' "$current_json" | jq -r '.assignees[].login') || return 1
	_REST_ISSUE_DELTA_FAILURE_STAGE="precondition"
	if [[ -n "$required_label" ]] && ! _rest_lines_contain "$current_labels" "$required_label"; then
		return 1
	fi
	if [[ -n "$required_assignee" ]] && ! _rest_lines_contain "$current_assignees" "$required_assignee"; then
		return 1
	fi

	local adds_l="" rms_l="" adds_a="" rms_a=""
	adds_l=$(_rest_filter_issue_deltas "$current_labels" "$(printf '%s\n' "${delta_add_labels[@]}")" "" add) || return 1
	rms_l=$(_rest_filter_issue_deltas "$current_labels" "$(printf '%s\n' "${delta_rm_labels[@]}")" "$(printf '%s\n' "${delta_add_labels[@]}")" remove) || return 1
	adds_a=$(_rest_filter_issue_deltas "$current_assignees" "$(printf '%s\n' "${delta_add_assignees[@]}")" "" add) || return 1
	rms_a=$(_rest_filter_issue_deltas "$current_assignees" "$(printf '%s\n' "${delta_rm_assignees[@]}")" "$(printf '%s\n' "${delta_add_assignees[@]}")" remove) || return 1

	_REST_ISSUE_DELTA_FAILURE_STAGE="mutation"
	_rest_issue_apply_delta_plan "$issue_path" "$adds_l" "$rms_l" "$adds_a" "$rms_a" "$delta_order" || return 1
	_REST_ISSUE_DELTA_FAILURE_STAGE=""
	return 0
}

#######################################
# Prepare a generic issue-edit delta plan without writing. The validated
# snapshot is used only to filter no-op operations; targeted mutations remain
# safe when unrelated metadata changes after this preflight.
_rest_issue_prepare_delta_plan() {
	local issue_path="$1"
	local add_labels="$2"
	local rm_labels="$3"
	local add_assignees="$4"
	local rm_assignees="$5"
	local current_json=""
	current_json=$(_rest_api_call read gh api "$issue_path" 2>/dev/null) || return 1
	_rest_issue_delta_snapshot_valid "$current_json" || return 1
	local current_labels="" current_assignees=""
	current_labels=$(printf '%s' "$current_json" | jq -r '.labels[].name') || return 1
	current_assignees=$(printf '%s' "$current_json" | jq -r '.assignees[].login') || return 1
	_REST_ISSUE_EDIT_ADDS_L=$(_rest_filter_issue_deltas "$current_labels" "$add_labels" "" add) || return 1
	_REST_ISSUE_EDIT_RMS_L=$(_rest_filter_issue_deltas "$current_labels" "$rm_labels" "$add_labels" remove) || return 1
	_REST_ISSUE_EDIT_ADDS_A=$(_rest_filter_issue_deltas "$current_assignees" "$add_assignees" "" add) || return 1
	_REST_ISSUE_EDIT_RMS_A=$(_rest_filter_issue_deltas "$current_assignees" "$rm_assignees" "$add_assignees" remove) || return 1
	return 0
}

#######################################
# Execute the write phases of a fully parsed and preflighted generic edit.
_rest_issue_execute_edit_plan() {
	local issue_path="$1"
	local has_deltas="$2"
	local has_title="$3"
	local title="$4"
	local has_body="$5"
	local body="$6"
	local body_file="$7"
	local has_milestone="$8"
	local milestone="$9"
	shift 9
	local has_state="$1"
	local state="$2"
	local -a api_args=(-X PATCH "$issue_path")
	[[ $has_title -eq 1 ]] && api_args+=(-f "title=${title}")
	[[ $has_milestone -eq 1 ]] && api_args+=(-F "milestone=${milestone:-null}")
	[[ $has_state -eq 1 ]] && api_args+=(-f "state=${state}")
	local tmp_body="" tmp_body_owned=0
	if [[ $has_body -eq 1 ]]; then
		if [[ -n "$body_file" ]]; then
			tmp_body="$body_file"
		else
			tmp_body=$(mktemp -t aidevops-gh-rest-body.XXXXXX) || return 1
			tmp_body_owned=1
			printf '%s' "$body" >"$tmp_body" || { rm -f "$tmp_body"; return 1; }
		fi
		api_args+=(-F "$(_rest_body_file_arg "$tmp_body")")
	fi
	local rc=0
	if [[ $has_title -eq 1 || $has_body -eq 1 || $has_milestone -eq 1 || $has_state -eq 1 ]]; then
		_REST_ISSUE_EDIT_FAILURE_STAGE="scalar"
		_rest_api_call write gh api "${api_args[@]}" >/dev/null 2>&1
		rc=$?
	fi
	[[ $tmp_body_owned -eq 1 && -f "$tmp_body" ]] && rm -f "$tmp_body"
	[[ $rc -eq 0 ]] || return "$rc"
	if [[ $has_deltas -eq 1 ]]; then
		_REST_ISSUE_EDIT_FAILURE_STAGE="delta"
		_rest_issue_apply_delta_plan "$issue_path" \
			"$_REST_ISSUE_EDIT_ADDS_L" "$_REST_ISSUE_EDIT_RMS_L" \
			"$_REST_ISSUE_EDIT_ADDS_A" "$_REST_ISSUE_EDIT_RMS_A" add-first || return 1
	fi
	_REST_ISSUE_EDIT_FAILURE_STAGE=""
	return 0
}

#######################################
# _rest_issue_edit: PATCH /repos/{owner}/{repo}/issues/{N}.
# Handles --title, --body, --body-file, --add-label, --remove-label,
# --add-assignee, --remove-assignee, --milestone, --state. Scalar fields use
# an array-free PATCH; labels and assignees use targeted REST subresources.
# The ordered phases are preflight, scalar PATCH, then add-first deltas. A
# later failure is explicitly partial: completed earlier phases are retained.
#######################################
_rest_issue_edit() {
	gh_record_call rest _rest_issue_edit 2>/dev/null || true
	_REST_ISSUE_EDIT_FAILURE_STAGE="parse"
	local num_or_url=""
	local repo=""
	local title=""
	local body=""
	local body_file=""
	local milestone=""
	local state=""
	local has_title=0 has_body=0 has_milestone=0 has_state=0
	local -a add_labels
	local -a rm_labels
	local -a add_assignees
	local -a rm_assignees
	local _tok
	add_labels=()
	rm_labels=()
	add_assignees=()
	rm_assignees=()
	local _first="${1:-}"
	if [[ $# -gt 0 && "$_first" != --* ]]; then
		num_or_url="$_first"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		local _arg="$1" _v=""
		[[ "$_arg" == *=* ]] && { _v="${_arg#*=}"; _arg="${_arg%%=*}"; shift; } || { _v="${2:-}"; shift 2; }
		case "$_arg" in
		--repo)            repo="$_v" ;;
		--title)           title="$_v"; has_title=1 ;;
		--body)            body="$_v"; has_body=1 ;;
		--body-file)       body_file="$_v"; has_body=1 ;;
		--add-label)       while IFS= read -r _tok; do [[ -n "$_tok" ]] && add_labels+=("$_tok"); done < <(_rest_split_csv "$_v") ;;
		--remove-label)    while IFS= read -r _tok; do [[ -n "$_tok" ]] && rm_labels+=("$_tok"); done < <(_rest_split_csv "$_v") ;;
		--add-assignee)    while IFS= read -r _tok; do [[ -n "$_tok" ]] && add_assignees+=("$_tok"); done < <(_rest_split_csv "$_v") ;;
		--remove-assignee) while IFS= read -r _tok; do [[ -n "$_tok" ]] && rm_assignees+=("$_tok"); done < <(_rest_split_csv "$_v") ;;
		--milestone)       milestone="$_v"; has_milestone=1 ;;
		--state)           state="$_v"; has_state=1 ;;
		*) return 1 ;;
		esac
	done
	local num=""
	{ read -r repo; read -r num; } < <(_rest_normalize_issue_ref "$num_or_url" "$repo")

	if [[ -z "$repo" || -z "$num" ]]; then
		printf '_rest_issue_edit: issue number and --repo are required\n' >&2
		return 1
	fi
	if [[ ! "$num" =~ ^[0-9]+$ ]]; then
		printf '_rest_issue_edit: invalid issue number: %s\n' "$num" >&2
		return 1
	fi

	local _issue_path="/repos/${repo}/issues/${num}"
	local has_deltas=0
	if [[ ${#add_labels[@]} -gt 0 || ${#rm_labels[@]} -gt 0 ||
		${#add_assignees[@]} -gt 0 || ${#rm_assignees[@]} -gt 0 ]]; then
		has_deltas=1
	fi
	_REST_ISSUE_EDIT_ADDS_L="" _REST_ISSUE_EDIT_RMS_L=""
	_REST_ISSUE_EDIT_ADDS_A="" _REST_ISSUE_EDIT_RMS_A=""
	if [[ $has_deltas -eq 1 ]]; then
		_REST_ISSUE_EDIT_FAILURE_STAGE="snapshot"
		_rest_issue_prepare_delta_plan "$_issue_path" \
			"$(printf '%s\n' "${add_labels[@]}")" "$(printf '%s\n' "${rm_labels[@]}")" \
			"$(printf '%s\n' "${add_assignees[@]}")" "$(printf '%s\n' "${rm_assignees[@]}")" || return 1
	fi

	_rest_issue_execute_edit_plan "$_issue_path" "$has_deltas" \
		"$has_title" "$title" "$has_body" "$body" "$body_file" \
		"$has_milestone" "$milestone" "$has_state" "$state"
	return $?
}

#######################################
# _rest_apply_labels: POST /repos/{owner}/{repo}/issues/{N}/labels.
# PRs share GitHub's issues label endpoint. Best-effort — failures are
# silently ignored (labels are non-critical metadata).
#
# Args: $1=repo_slug  $2=issue_or_pr_number  $3..=label names
# Returns: 0 always
#######################################
_rest_apply_labels() {
	local repo="$1" num="$2"; shift 2
	[[ $# -eq 0 || -z "$num" ]] && return 0
	local -a label_args=(-X POST "/repos/${repo}/issues/${num}/labels")
	local _lbl
	for _lbl in "$@"; do
		[[ -n "$_lbl" ]] && label_args+=(-f "labels[]=${_lbl}")
	done
	gh api "${label_args[@]}" >/dev/null 2>&1 || true
	return 0
}

#######################################
# _rest_pr_autodetect_head
# Returns the current git branch name for use as --head when omitted.
# Returns empty string when in detached HEAD state or outside a git repo.
# Emits an [INFO] log line when auto-detect fires.
#######################################
_rest_pr_autodetect_head() {
	local _branch
	_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
	if [[ -n "$_branch" && "$_branch" != "HEAD" ]]; then
		print_info "gh-wrapper: auto-detected --head=${_branch}"
		printf '%s\n' "$_branch"
	fi
	return 0
}

#######################################
# _rest_pr_autodetect_base <repo>
# Returns the repository's default branch for use as --base when omitted.
# Resolution order:
#   1. gh api /repos/{repo} --jq .default_branch (REST, no GraphQL cost)
#   2. git symbolic-ref refs/remotes/origin/HEAD
#   3. "main" (final fallback)
# Emits an [INFO] log line when auto-detect fires.
#######################################
_rest_pr_autodetect_base() {
	local _repo="${1:-}"
	local _base=""
	if [[ -n "$_repo" ]]; then
		_base=$(gh api "/repos/${_repo}" --jq '.default_branch' 2>/dev/null)
	fi
	if [[ -z "$_base" ]]; then
		_base=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
			| sed 's@^refs/remotes/origin/@@')
	fi
	[[ -z "$_base" ]] && _base="main"
	print_info "gh-wrapper: auto-detected --base=${_base}"
	printf '%s\n' "$_base"
	return 0
}

#######################################
# _rest_pr_create: POST /repos/{owner}/{repo}/pulls.
# Parses gh-style args (--head, --base, --title, --body, --body-file, --draft,
# --label) into a REST payload. Labels are applied via a separate
# POST /repos/{owner}/{repo}/issues/{pr_number}/labels call because the
# GitHub pulls endpoint does not accept a labels field at creation time.
# Emits the PR html_url on stdout, mirroring `gh pr create`. Returns underlying
# gh api exit code.
# When --head or --base are omitted, auto-detects from git HEAD / repo
# default branch respectively (see _rest_pr_autodetect_head/base above).
#######################################
_rest_pr_create() {
	gh_record_call rest _rest_pr_create 2>/dev/null || true
	local title=""
	local head=""
	local base=""
	local body=""
	local body_file=""
	local repo=""
	local draft=0
	local has_body=0
	local -a labels
	local _tok
	labels=()

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--title) title="${2:-}"; shift 2 ;;
		--title=*) title="${_arg#--title=}"; shift ;;
		--head) head="${2:-}"; shift 2 ;;
		--head=*) head="${_arg#--head=}"; shift ;;
		--base) base="${2:-}"; shift 2 ;;
		--base=*) base="${_arg#--base=}"; shift ;;
		--body) body="${2:-}"; has_body=1; shift 2 ;;
		--body=*) body="${_arg#--body=}"; has_body=1; shift ;;
		--body-file) body_file="${2:-}"; has_body=1; shift 2 ;;
		--body-file=*) body_file="${_arg#--body-file=}"; has_body=1; shift ;;
		--draft) draft=1; shift ;;
		--label) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_rest_split_csv "${2:-}"); shift 2 ;;
		--label=*) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_rest_split_csv "${_arg#--label=}"); shift ;;
		*) shift ;;
		esac
	done

	if [[ -z "$repo" ]]; then
		printf '_rest_pr_create: --repo is required\n' >&2
		return 1
	fi
	if [[ -z "$title" ]]; then
		printf '_rest_pr_create: --title is required\n' >&2
		return 1
	fi
	if [[ -z "$head" ]]; then
		head=$(_rest_pr_autodetect_head)
		if [[ -z "$head" ]]; then
			printf '_rest_pr_create: --head is required\n' >&2
			return 1
		fi
	fi
	if [[ -z "$base" ]]; then
		base=$(_rest_pr_autodetect_base "$repo")
	fi

	local tmp_body="" tmp_body_owned=0
	if [[ $has_body -eq 1 ]]; then
		if [[ -n "$body_file" ]]; then
			tmp_body="$body_file"
		else
			tmp_body=$(mktemp -t aidevops-gh-rest-body.XXXXXX) || return 1
			tmp_body_owned=1
			printf '%s' "$body" >"$tmp_body"
		fi
	fi
	[[ -n "$tmp_body" ]] && _rest_append_sig "$tmp_body"

	local -a api_args=(-X POST "/repos/${repo}/pulls"
		-f "title=$title"
		-f "head=$head"
		-f "base=$base")
	[[ -n "$tmp_body" ]] && api_args+=(-F "$(_rest_body_file_arg "$tmp_body")")
	[[ $draft -eq 1 ]] && api_args+=(-F "draft=true")

	local html_url rc
	html_url=$(gh api "${api_args[@]}" --jq '.html_url' 2>&1)
	rc=$?

	[[ $tmp_body_owned -eq 1 && -f "$tmp_body" ]] && rm -f "$tmp_body"

	if [[ $rc -ne 0 ]]; then
		printf '%s\n' "$html_url" >&2
		return $rc
	fi

	printf '%s\n' "$html_url"

	# Apply labels via the issues endpoint (PRs share it).
	if [[ ${#labels[@]} -gt 0 ]]; then
		local pr_number
		pr_number=$(printf '%s' "$html_url" | grep -oE '[0-9]+$' || true)
		[[ -n "$pr_number" ]] && _rest_apply_labels "$repo" "$pr_number" "${labels[@]}"
	fi
	return 0
}

#######################################
# _rest_issue_view: GET /repos/{owner}/{repo}/issues/{N}.  (t2689)
# Parses gh-style args (positional number or URL, --repo, --json, --jq)
# and returns the issue JSON or a jq-filtered value. Mirrors `gh issue view`.
#
# The --json FIELDS flag maps common gh field names onto REST fields so
# proactive REST-first routing can preserve compact gh-shaped output. Field
# names align with `gh issue view --json` for common fields (state, title,
# body, labels, assignees, createdAt). GitHub's REST `node_id` is the exact
# global node identifier returned by the GraphQL-backed gh `id` field.
# Fields without an exact projection remain native.
#
# Returns the underlying gh api exit code.
#######################################
_rest_issue_view() {
	gh_record_call rest _rest_issue_view 2>/dev/null || true
	local num_or_url=""
	local repo=""
	local jq_expr=""
	local json_fields=""

	local _first="${1:-}"
	if [[ $# -gt 0 && "$_first" != --* ]]; then
		num_or_url="$_first"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo | -R) [[ $# -ge 2 ]] || return 2; repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--json) [[ $# -ge 2 ]] || return 2; json_fields="${2:-}"; shift 2 ;;
		--json=*) json_fields="${_arg#--json=}"; shift ;;
		# t3027: accept -q as gh's documented shorthand for --jq. Without this,
		# callers using `gh issue view ... -q '.field'` (the idiomatic gh form)
		# silently lost the jq filter on REST fallback and got the full issue
		# object, breaking downstream string assignments.
		--jq | -q) [[ $# -ge 2 ]] || return 2; jq_expr="${2:-}"; shift 2 ;;
		--jq=* | -q=*) jq_expr="${_arg#*=}"; shift ;;
		*) printf '_rest_issue_view: unsupported argument: %s\n' "$_arg" >&2; return 2 ;;
		esac
	done

	local num=""
	{ read -r repo; read -r num; } < <(_rest_normalize_issue_ref "$num_or_url" "$repo")

	if [[ -z "$repo" || -z "$num" ]]; then
		printf '_rest_issue_view: issue number and --repo are required\n' >&2
		return 1
	fi
	if ! _rest_repo_slug_supported "$repo"; then
		printf '_rest_issue_view: invalid --repo value: %s\n' "$repo" >&2
		return 1
	fi
	if [[ ! "$num" =~ ^[0-9]+$ ]]; then
		printf '_rest_issue_view: invalid issue number: %s\n' "$num" >&2
		return 1
	fi
	if [[ -n "$json_fields" ]] && ! _rest_issue_view_fields_supported "$json_fields"; then
		printf '_rest_issue_view: unsupported JSON field set: %s\n' "$json_fields" >&2
		return 2
	fi

	local _path="/repos/${repo}/issues/${num}"
	local _gh_cmd=(gh api "$_path")
	if [[ -n "$json_fields" ]]; then
		jq_expr="$(_rest_issue_object_json_jq "$json_fields" "$jq_expr")" || return 1
	fi
	[[ -n "$jq_expr" ]] && _gh_cmd+=(--jq "$jq_expr")
	_rest_api_call read "${_gh_cmd[@]}"
	return $?
}

_rest_issue_object_json_jq() {
	local fields="$1"
	local user_jq="$2"
	local projection=""
	local field=""
	local id_projection='id: (if (.node_id | type) == "string" and .node_id != "" then .node_id else error("REST issue node_id must be a non-empty string") end)'
	local actor_projection=""
	local assignees_projection=""
	local labels_projection=""
	actor_projection="$(_rest_jq_actor_projection)"
	assignees_projection="$(_rest_jq_assignees_projection)"
	labels_projection="$(_rest_jq_labels_projection)"
	while IFS= read -r field; do
		[[ -z "$field" ]] && continue
		case "$field" in
		id) projection="${projection}${projection:+,}${id_projection}" ;;
		number) projection="${projection}${projection:+,}number: .number" ;;
		state) projection="${projection}${projection:+,}state: (.state | ascii_upcase)" ;;
		url) projection="${projection}${projection:+,}url: .html_url" ;;
		title) projection="${projection}${projection:+,}title: (.title // \"\")" ;;
		body) projection="${projection}${projection:+,}body: (.body // \"\")" ;;
		createdAt) projection="${projection}${projection:+,}createdAt: .created_at" ;;
		updatedAt) projection="${projection}${projection:+,}updatedAt: .updated_at" ;;
		closedAt) projection="${projection}${projection:+,}closedAt: .closed_at" ;;
		labels) projection="${projection}${projection:+,}labels: ((.labels // []) | ${labels_projection})" ;;
		assignees) projection="${projection}${projection:+,}assignees: ((.assignees // []) | ${assignees_projection})" ;;
		author) projection="${projection}${projection:+,}author: (.user | ${actor_projection})" ;;
		stateReason) projection="${projection}${projection:+,}stateReason: (if .state_reason == null then null else (.state_reason | ascii_upcase) end)" ;;
		closed) projection="${projection}${projection:+,}closed: (.state == \"closed\")" ;;
		locked) projection="${projection}${projection:+,}locked: (if (.locked | type) == \"boolean\" then .locked else error(\"REST issue locked field must be boolean\") end)" ;;
		*) return 1 ;;
		esac
	done < <(_rest_split_csv "$fields")
	[[ -z "$projection" ]] && projection="number: .number"
	local jq_expr="{${projection}}"
	[[ -n "$user_jq" ]] && jq_expr="${jq_expr} | ${user_jq}"
	printf '%s' "$jq_expr"
	return 0
}

# _rest_pr_view: GET /repos/{owner}/{repo}/pulls/{N}; mirrors common
# `gh pr view <N> --repo SLUG [--json FIELDS] [--jq EXPR]` read shapes.
_rest_pr_view() {
	local num_or_url=""
	local repo=""
	local jq_expr=""
	local json_fields=""

	local _first="${1:-}"
	if [[ $# -gt 0 && "$_first" != --* ]]; then
		num_or_url="$_first"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo | -R) [[ $# -ge 2 ]] || return 2; repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--json) [[ $# -ge 2 ]] || return 2; json_fields="${2:-}"; shift 2 ;;
		--json=*) json_fields="${_arg#--json=}"; shift ;;
		--jq | -q) [[ $# -ge 2 ]] || return 2; jq_expr="${2:-}"; shift 2 ;;
		--jq=* | -q=*) jq_expr="${_arg#*=}"; shift ;;
		*) printf '_rest_pr_view: unsupported argument: %s\n' "$_arg" >&2; return 2 ;;
		esac
	done

	local num=""
	{ read -r repo; read -r num; } < <(_rest_normalize_issue_ref "$num_or_url" "$repo")

	if [[ -z "$repo" || -z "$num" ]]; then
		printf '_rest_pr_view: PR number and --repo are required\n' >&2
		return 1
	fi
	if ! _rest_repo_slug_supported "$repo"; then
		printf '_rest_pr_view: invalid --repo value: %s\n' "$repo" >&2
		return 1
	fi
	if [[ ! "$num" =~ ^[0-9]+$ ]]; then
		printf '_rest_pr_view: invalid PR number: %s\n' "$num" >&2
		return 1
	fi
	if [[ -n "$json_fields" ]] && ! _rest_pr_view_fields_supported emergency "$json_fields"; then
		printf '_rest_pr_view: unsupported JSON field set: %s\n' "$json_fields" >&2
		return 2
	fi

	local cache_path=""
	local raw_json=""
	local cache_name="rest_pr_view_cache"
	local cache_ttl="${AIDEVOPS_GH_PR_VIEW_CACHE_TTL:-15}"
	if _rest_pr_view_cache_enabled; then
		cache_path="$(_rest_pr_view_cache_path "$repo" "$num")" || { cache_path=""; gh_record_call other "$cache_name" unknown other bypass 2>/dev/null || true; }
		if [[ -n "$cache_path" && -s "$cache_path" ]]; then
			_rest_pr_view_cache_emit_if_fresh "$cache_path" "$cache_ttl" "$cache_name" "$json_fields" "$jq_expr" && return $?
		elif [[ -n "$cache_path" ]]; then
			gh_record_call other "$cache_name" unknown other miss 2>/dev/null || true
		fi
	elif [[ "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" == "1" ]]; then
		gh_record_call other "$cache_name" unknown other bypass-disabled 2>/dev/null || true
	elif [[ "${AIDEVOPS_GH_PR_VIEW_CACHE:-0}" == "1" ]]; then
		gh_record_call other "$cache_name" unknown other bypass 2>/dev/null || true
	fi

	gh_record_call rest _rest_pr_view 2>/dev/null || true
	local _path="/repos/${repo}/pulls/${num}"
	local _gh_cmd=(gh api "$_path")
	if [[ -n "$cache_path" ]]; then
		raw_json="$(_rest_api_call read "${_gh_cmd[@]}")"
		local _rc=$?
		if [[ $_rc -ne 0 ]]; then
			return $_rc
		fi
		local _tmp_cache="${cache_path}.tmp.$$"
		if printf '%s\n' "$raw_json" >"$_tmp_cache"; then
			:
		else
			_rc=$?
			printf '_rest_pr_view: failed to write temporary cache file: %s\n' "$_tmp_cache" >&2
			rm -f "$_tmp_cache"
			return $_rc
		fi
		if mv "$_tmp_cache" "$cache_path"; then
			gh_record_call other "$cache_name" unknown other store 2>/dev/null || true
		else
			_rc=$?
			printf '_rest_pr_view: failed to move temporary cache file %s to cache path: %s\n' "$_tmp_cache" "$cache_path" >&2
			rm -f "$_tmp_cache"
			return $_rc
		fi
		_rest_pr_view_emit_json "$raw_json" "$json_fields" "$jq_expr"
		return $?
	fi
	if [[ -n "$json_fields" ]]; then
		jq_expr="$(_rest_pr_object_json_jq "$json_fields" "$jq_expr")" || return 1
	fi
	[[ -n "$jq_expr" ]] && _gh_cmd+=(--jq "$jq_expr")
	_rest_api_call read "${_gh_cmd[@]}"
	return $?
}

_rest_pr_object_json_jq() {
	local fields="$1"
	local user_jq="$2"
	local projection=""
	local field=""
	local actor_projection=""
	local labels_projection=""
	actor_projection="$(_rest_jq_actor_projection)"
	labels_projection="$(_rest_jq_labels_projection)"
	while IFS= read -r field; do
		[[ -z "$field" ]] && continue
		case "$field" in
		number) projection="${projection}${projection:+,}number: .number" ;;
		state) projection="${projection}${projection:+,}state: (if (.merged_at != null or .merged == true) then \"MERGED\" else (.state // \"\" | ascii_upcase) end)" ;;
		merged) projection="${projection}${projection:+,}merged: (.merged == true or .merged_at != null)" ;;
		mergedAt) projection="${projection}${projection:+,}mergedAt: .merged_at" ;;
		closedAt) projection="${projection}${projection:+,}closedAt: .closed_at" ;;
		mergeCommit) projection="${projection}${projection:+,}mergeCommit: (if (.merge_commit_sha // \"\") != \"\" then {oid: .merge_commit_sha} else null end)" ;;
		mergedBy) projection="${projection}${projection:+,}mergedBy: (.merged_by | ${actor_projection})" ;;
		mergeable) projection="${projection}${projection:+,}mergeable: (.mergeable | if . == true then \"MERGEABLE\" elif . == false then \"CONFLICTING\" else (. // \"UNKNOWN\") end)" ;;
		isDraft) projection="${projection}${projection:+,}isDraft: (.draft // false)" ;;
		labels) projection="${projection}${projection:+,}labels: ((.labels // []) | ${labels_projection})" ;;
		author) projection="${projection}${projection:+,}author: (.user | ${actor_projection})" ;;
		title) projection="${projection}${projection:+,}title: (.title // \"\")" ;;
		body) projection="${projection}${projection:+,}body: (.body // \"\")" ;;
		url) projection="${projection}${projection:+,}url: .html_url" ;;
		createdAt) projection="${projection}${projection:+,}createdAt: .created_at" ;;
		updatedAt) projection="${projection}${projection:+,}updatedAt: .updated_at" ;;
		baseRefName) projection="${projection}${projection:+,}baseRefName: (.base.ref // \"\")" ;;
		headRefName) projection="${projection}${projection:+,}headRefName: (.head.ref // \"\")" ;;
		headRefOid) projection="${projection}${projection:+,}headRefOid: (.head.sha // \"\")" ;;
		*) return 1 ;;
		esac
	done < <(_rest_split_csv "$fields")
	[[ -z "$projection" ]] && projection="number: .number"
	local jq_expr="{${projection}}"
	[[ -n "$user_jq" ]] && jq_expr="${jq_expr} | ${user_jq}"
	printf '%s' "$jq_expr"
	return 0
}

#######################################
# _rest_pr_list: GET /repos/{owner}/{repo}/pulls.  (t2772)
# Parses gh-style args (--repo, --state, --head, --base, --limit,
# --json, --jq, -q) and returns a JSON array or jq-filtered output.
# Mirrors `gh pr list` for state/head/base filtering.
#
# Search-only filters are handled by the sibling read-semantics translator or
# rejected here. JSON fields are projected to gh-compatible names; unsupported
# fields fail before any API request.
#
# Returns the underlying gh api exit code.
#######################################
_rest_pr_list_json_jq() {
	local fields="$1"
	local user_jq="$2"
	local source_filter="${3:-.}"
	local projection=""
	local field=""
	local actor_projection=""
	local assignees_projection=""
	local labels_projection=""
	actor_projection="$(_rest_jq_actor_projection)"
	assignees_projection="$(_rest_jq_assignees_projection)"
	labels_projection="$(_rest_jq_labels_projection)"
	while IFS= read -r field; do
		[[ -z "$field" ]] && continue
		case "$field" in
		number) projection="${projection}${projection:+,}number: .number" ;;
		state) projection="${projection}${projection:+,}state: (if .merged_at != null then \"MERGED\" else (.state | ascii_upcase) end)" ;;
		isDraft) projection="${projection}${projection:+,}isDraft: (.draft // false)" ;;
		labels) projection="${projection}${projection:+,}labels: ((.labels // []) | ${labels_projection})" ;;
		mergedAt) projection="${projection}${projection:+,}mergedAt: .merged_at" ;;
		url) projection="${projection}${projection:+,}url: .html_url" ;;
		title) projection="${projection}${projection:+,}title: .title" ;;
		body) projection="${projection}${projection:+,}body: (.body // \"\")" ;;
		createdAt) projection="${projection}${projection:+,}createdAt: .created_at" ;;
		updatedAt) projection="${projection}${projection:+,}updatedAt: .updated_at" ;;
		closedAt) projection="${projection}${projection:+,}closedAt: .closed_at" ;;
		baseRefName) projection="${projection}${projection:+,}baseRefName: .base.ref" ;;
		headRefName) projection="${projection}${projection:+,}headRefName: .head.ref" ;;
		headRefOid) projection="${projection}${projection:+,}headRefOid: .head.sha" ;;
		author) projection="${projection}${projection:+,}author: (.user | ${actor_projection})" ;;
		assignees) projection="${projection}${projection:+,}assignees: ((.assignees // []) | ${assignees_projection})" ;;
		*) return 1 ;;
		esac
	done < <(_rest_split_csv "$fields")
	[[ -z "$projection" ]] && projection="number: .number"
	local jq_expr="${source_filter} | [.[] | {${projection}}]"
	[[ -n "$user_jq" ]] && jq_expr="${jq_expr} | ${user_jq}"
	printf '%s' "$jq_expr"
	return 0
}

_rest_pr_list() {
	gh_record_call rest _rest_pr_list 2>/dev/null || true
	local repo=""
	local state="open"
	local limit=30
	local jq_expr=""
	local json_fields=""
	local head_branch=""
	local base_branch=""
	local rest_state=""

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo | -R) [[ $# -ge 2 ]] || return 2; repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--state | -s) [[ $# -ge 2 ]] || return 2; state="${2:-}"; shift 2 ;;
		--state=*) state="${_arg#--state=}"; shift ;;
		--head | -H) [[ $# -ge 2 ]] || return 2; head_branch="${2:-}"; shift 2 ;;
		--head=*) head_branch="${_arg#--head=}"; shift ;;
		--base | -B) [[ $# -ge 2 ]] || return 2; base_branch="${2:-}"; shift 2 ;;
		--base=*) base_branch="${_arg#--base=}"; shift ;;
		--limit | -L) [[ $# -ge 2 ]] || return 2; limit="${2:-}"; shift 2 ;;
		--limit=*) limit="${_arg#--limit=}"; shift ;;
		--json) [[ $# -ge 2 ]] || return 2; json_fields="${2:-}"; shift 2 ;;
		--json=*) json_fields="${_arg#--json=}"; shift ;;
		--jq | -q) [[ $# -ge 2 ]] || return 2; jq_expr="${2:-}"; shift 2 ;;
		--jq=* | -q=*) jq_expr="${_arg#*=}"; shift ;;
		--author | -A | --author=* | --assignee | -a | --assignee=* | --label | -l | --label=* | --search | -S | --search=* | --draft | -d)
			printf '_rest_pr_list: argument requires Search API routing: %s\n' "$_arg" >&2
			return 2
			;;
		*) printf '_rest_pr_list: unsupported argument: %s\n' "$_arg" >&2; return 2 ;;
		esac
	done

	if [[ -z "$repo" || ! "$limit" =~ ^[1-9][0-9]*$ ]] || ! _rest_repo_slug_supported "$repo"; then
		printf '_rest_pr_list: --repo and a positive --limit are required\n' >&2
		return 1
	fi
	if [[ -n "$json_fields" ]] && ! _rest_pr_list_fields_supported direct "$json_fields"; then
		printf '_rest_pr_list: unsupported JSON field set: %s\n' "$json_fields" >&2
		return 2
	fi

	case "$state" in
	open | all) rest_state="$state" ;;
	closed | merged) rest_state="closed" ;;
	*) printf '_rest_pr_list: unsupported state: %s\n' "$state" >&2; return 2 ;;
	esac

	local page_size="$limit"
	[[ "$page_size" -le 100 ]] || page_size=100
	local _query="state=${rest_state}&per_page=${page_size}"
	if [[ -n "$head_branch" ]]; then
		local _head_encoded
		if [[ "$head_branch" != *:* ]]; then
			head_branch="${repo%%/*}:${head_branch}"
		fi
		_head_encoded=$(jq -rn --arg v "$head_branch" '$v | @uri') || return 1
		_query="${_query}&head=${_head_encoded}"
	fi
	if [[ -n "$base_branch" ]]; then
		local _base_encoded
		_base_encoded=$(jq -rn --arg v "$base_branch" '$v | @uri') || return 1
		_query="${_query}&base=${_base_encoded}"
	fi

	local result=""
	result="$(_rest_pr_list_collect_pages "$repo" "$_query" "$state" "$limit" "$page_size")" || return 1
	if [[ -n "$json_fields" ]]; then
		local projection=""
		projection="$(_rest_pr_list_json_jq "$json_fields" "" ".")" || return 1
		result=$(printf '%s' "$result" | jq -c "$projection") || return 1
	fi
	if [[ -n "$jq_expr" ]]; then
		printf '%s' "$result" | jq -r "$jq_expr"
		return $?
	fi
	printf '%s\n' "$result"
	return 0
}

#######################################
# _rest_issue_list: GET /repos/{owner}/{repo}/issues.  (t2689)
# Parses gh-style args (--repo, --state, --label, --assignee, --limit,
# --json, --jq) and returns a JSON array or jq-filtered output.
# Mirrors `gh issue list` for state/label/assignee filtering.
#
# Multiple --label flags are collected and joined into a comma-separated
# `?labels=` query parameter (GitHub REST AND semantics — same as gh CLI).
# Search is handled by the sibling Search API translator. Unknown flags and
# unsupported JSON fields fail before any API request rather than broadening the
# result set.
#
# Returns the underlying gh api exit code.
#######################################
_rest_issue_list_json_jq() {
	local fields="$1"
	local user_jq="$2"
	local projection=""
	local field=""
	local actor_projection=""
	local assignees_projection=""
	local labels_projection=""
	actor_projection="$(_rest_jq_actor_projection)"
	assignees_projection="$(_rest_jq_assignees_projection)"
	labels_projection="$(_rest_jq_labels_projection)"
	while IFS= read -r field; do
		[[ -z "$field" ]] && continue
		case "$field" in
		number) projection="${projection}${projection:+,}number: .number" ;;
		state) projection="${projection}${projection:+,}state: (.state | ascii_upcase)" ;;
		url) projection="${projection}${projection:+,}url: .html_url" ;;
		title) projection="${projection}${projection:+,}title: .title" ;;
		body) projection="${projection}${projection:+,}body: (.body // \"\")" ;;
		createdAt) projection="${projection}${projection:+,}createdAt: .created_at" ;;
		updatedAt) projection="${projection}${projection:+,}updatedAt: .updated_at" ;;
		closedAt) projection="${projection}${projection:+,}closedAt: .closed_at" ;;
		labels) projection="${projection}${projection:+,}labels: ((.labels // []) | ${labels_projection})" ;;
		assignees) projection="${projection}${projection:+,}assignees: ((.assignees // []) | ${assignees_projection})" ;;
		author) projection="${projection}${projection:+,}author: (.user | ${actor_projection})" ;;
		stateReason) projection="${projection}${projection:+,}stateReason: (if .state_reason == null then null else (.state_reason | ascii_upcase) end)" ;;
		closed) projection="${projection}${projection:+,}closed: (.state == \"closed\")" ;;
		*) return 1 ;;
		esac
	done < <(_rest_split_csv "$fields")
	[[ -z "$projection" ]] && projection="number: .number"
	# GH#23442: /repos/{owner}/{repo}/issues returns issues and pull requests;
	# gh issue list returns issues only. Preserve gh-compatible semantics in the
	# REST fallback so dispatch candidate enumeration cannot surface PR targets.
	local jq_expr="[.[] | select(.pull_request == null) | {${projection}}]"
	[[ -n "$user_jq" ]] && jq_expr="${jq_expr} | ${user_jq}"
	printf '%s' "$jq_expr"
	return 0
}

_rest_issue_list() {
	gh_record_call rest _rest_issue_list 2>/dev/null || true
	local repo=""
	local state="open"
	local limit=30
	local jq_expr=""
	local user_jq=""
	local json_fields=""
	local assignee=""
	local author=""
	local -a labels
	local _tok
	labels=()

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		case "$_arg" in
		--repo | -R) [[ $# -ge 2 ]] || return 2; repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${_arg#--repo=}"; shift ;;
		--state | -s) [[ $# -ge 2 ]] || return 2; state="${2:-}"; shift 2 ;;
		--state=*) state="${_arg#--state=}"; shift ;;
		--label | -l) [[ $# -ge 2 ]] || return 2; while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_rest_split_csv "${2:-}"); shift 2 ;;
		--label=*) while IFS= read -r _tok; do [[ -n "$_tok" ]] && labels+=("$_tok"); done < <(_rest_split_csv "${_arg#--label=}"); shift ;;
		--assignee | -a) [[ $# -ge 2 ]] || return 2; assignee="${2:-}"; shift 2 ;;
		--assignee=*) assignee="${_arg#--assignee=}"; shift ;;
		--author | -A) [[ $# -ge 2 ]] || return 2; author="${2:-}"; shift 2 ;;
		--author=*) author="${_arg#--author=}"; shift ;;
		--limit | -L) [[ $# -ge 2 ]] || return 2; limit="${2:-}"; shift 2 ;;
		--limit=*) limit="${_arg#--limit=}"; shift ;;
		--json) [[ $# -ge 2 ]] || return 2; json_fields="${2:-}"; shift 2 ;;
		--json=*) json_fields="${_arg#--json=}"; shift ;;
		--jq | -q) [[ $# -ge 2 ]] || return 2; jq_expr="${2:-}"; shift 2 ;;
		--jq=* | -q=*) jq_expr="${_arg#*=}"; shift ;;
		--search | -S | --search=*) printf '_rest_issue_list: --search requires Search API routing\n' >&2; return 2 ;;
		*) printf '_rest_issue_list: unsupported argument: %s\n' "$_arg" >&2; return 2 ;;
		esac
	done
	user_jq="$jq_expr"

	if [[ -z "$repo" || ! "$limit" =~ ^[1-9][0-9]*$ ]] || ! _rest_repo_slug_supported "$repo"; then
		printf '_rest_issue_list: --repo and a positive --limit are required\n' >&2
		return 1
	fi
	if [[ -n "$json_fields" ]] && ! _rest_issue_list_fields_supported "$json_fields"; then
		printf '_rest_issue_list: unsupported JSON field set: %s\n' "$json_fields" >&2
		return 2
	fi
	case "$state" in
	open | closed | all) ;;
	*) printf '_rest_issue_list: unsupported state: %s\n' "$state" >&2; return 2 ;;
	esac
	[[ -z "$author" ]] || author="$(_rest_resolve_actor_filter "$author")" || return 1
	[[ -z "$assignee" ]] || assignee="$(_rest_resolve_actor_filter "$assignee")" || return 1

	local page_size="$limit"
	if [[ "$page_size" -gt 100 ]]; then
		page_size=100
	fi
	local _query="state=${state}&per_page=${page_size}"
	if [[ ${#labels[@]} -gt 0 ]]; then
		local _labels_encoded=""
		local _label
		for _label in "${labels[@]}"; do
			local _enc
			_enc=$(jq -rn --arg v "$_label" '$v | @uri') || return 1
			_labels_encoded="${_labels_encoded:+${_labels_encoded}%2C}${_enc}"
		done
		_query="${_query}&labels=${_labels_encoded}"
	fi
	if [[ -n "$assignee" ]]; then
		local _assignee_encoded
		_assignee_encoded=$(jq -rn --arg v "$assignee" '$v | @uri') || return 1
		_query="${_query}&assignee=${_assignee_encoded}"
	fi
	if [[ -n "$author" ]]; then
		local _author_encoded
		_author_encoded=$(jq -rn --arg v "$author" '$v | @uri') || return 1
		_query="${_query}&creator=${_author_encoded}"
	fi

	local combined=""
	combined="$(_rest_issue_list_collect_pages "$repo" "$_query" "$limit" "$page_size")" || return 1

	if [[ -n "$json_fields" ]]; then
		jq_expr="$(_rest_issue_list_json_jq "$json_fields" "")" || return 1
	else
		jq_expr='[.[] | select(.pull_request == null)]'
	fi
	local result=""
	result=$(printf '%s' "$combined" | jq -c "${jq_expr} | .[:${limit}]") || return 1
	if [[ -n "$user_jq" ]]; then
		printf '%s' "$result" | jq -r "$user_jq"
	else
		printf '%s\n' "$result"
	fi
	return $?
}
