#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contributor Activity -- Person Stats (GitHub API)
# =============================================================================
# Queries GitHub Search API for per-contributor output stats: issues created,
# PRs created, PRs merged, and issues/PRs commented on. Supports single-repo
# and cross-repo aggregation with rate-limit-aware partial results.
#
# Usage: source "${SCRIPT_DIR}/contributor-activity-helper-person.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, sanitize_url, etc.)
#   - _resolve_default_branch() from orchestrator
#   - PYTHON_HELPERS variable from orchestrator
#   - EX_PARTIAL constant from orchestrator
#   - gh CLI (for GitHub Search API)
#   - jq (for JSON assembly)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONTRIBUTOR_ACTIVITY_PERSON_LIB_LOADED:-}" ]] && return 0
_CONTRIBUTOR_ACTIVITY_PERSON_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

: "${PERSON_STATS_GH_API_TIMEOUT:=20}"
: "${PERSON_STATS_CROSS_REPO_GH_API_TIMEOUT:=45}"

#######################################
# Return the active GitHub API timeout budget.
#
# Output: timeout seconds
#######################################
_person_stats_gh_api_timeout() {
	if [[ "${PERSON_STATS_MODE:-single}" == "cross-repo" ]]; then
		printf '%s' "$PERSON_STATS_CROSS_REPO_GH_API_TIMEOUT"
	else
		printf '%s' "$PERSON_STATS_GH_API_TIMEOUT"
	fi
	return 0
}

#######################################
# Run gh api with a portable wall-clock timeout.
#
# Arguments:
#   $@ - gh api arguments
#######################################
_person_stats_gh_api() {
	local timeout_budget
	timeout_budget=$(_person_stats_gh_api_timeout)
	timeout_sec "$timeout_budget" gh api "$@"
	return $?
}

#######################################
# Query a GitHub Search API total_count with timeout classification.
#
# Arguments:
#   $1 - human-readable metric label
#   $2 - GitHub API endpoint/query
# Output: total_count or 0 on recoverable failure
#######################################
_person_stats_query_count() {
	local label="$1"
	local query="$2"
	local value="0"
	local rc=0
	value=$(_person_stats_gh_api "$query" --jq '.total_count' 2>/dev/null) || rc=$?
	if [[ "$rc" -eq 124 ]]; then
		echo "GitHub Search API ${label} query timed out after $(_person_stats_gh_api_timeout)s" >&2
		printf '%s' "0"
		return 124
	fi
	if [[ "$rc" -ne 0 || ! "$value" =~ ^[0-9]+$ ]]; then
		echo "GitHub Search API ${label} query failed" >&2
		printf '%s' "0"
		return 1
	fi
	printf '%s' "$value"
	return 0
}

#######################################
# Extract repo slug from git remote URL
#
# Arguments:
#   $1 - repo path
# Output: owner/repo slug to stdout, or empty on error
#######################################
_person_stats_get_slug() {
	local repo_path="$1"
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || remote_url=""
	if [[ -z "$remote_url" ]]; then
		echo "Error: no origin remote found" >&2
		return 1
	fi
	local slug
	slug=$(echo "$remote_url" | sed -E 's#.*github\.com[:/]##; s/\.git$//')
	if [[ -z "$slug" || "$slug" == "$remote_url" ]]; then
		# t2458: sanitize_url strips embedded credentials from remote URLs.
		echo "Error: could not extract repo slug from $(sanitize_url "$remote_url")" >&2
		return 1
	fi
	echo "$slug"
	return 0
}

#######################################
# Calculate since_date for a period (macOS/Linux portable)
#
# Arguments:
#   $1 - period: "day", "week", "month", "quarter", "year"
# Output: YYYY-MM-DD date string to stdout
#######################################
_person_stats_since_date() {
	local period="$1"
	local since_date
	case "$period" in
	day) since_date=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d '1 day ago' +%Y-%m-%d) ;;
	week) since_date=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d) ;;
	month) since_date=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d) ;;
	quarter) since_date=$(date -v-90d +%Y-%m-%d 2>/dev/null || date -d '90 days ago' +%Y-%m-%d) ;;
	year) since_date=$(date -v-365d +%Y-%m-%d 2>/dev/null || date -d '365 days ago' +%Y-%m-%d) ;;
	*) since_date=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d '30 days ago' +%Y-%m-%d) ;;
	esac
	echo "$since_date"
	return 0
}

#######################################
# Discover contributor logins from git history
#
# Arguments:
#   $1 - repo path
#   $2 - since_date (YYYY-MM-DD)
# Output: comma-separated login list to stdout
#######################################
_person_stats_discover_logins() {
	local repo_path="$1"
	local since_date="$2"

	local default_branch
	default_branch=$(_resolve_default_branch "$repo_path")
	local git_data
	git_data=$(git -C "$repo_path" log "$default_branch" --format='%ae|%ce' --since="$since_date") || git_data=""
	echo "$git_data" | python3 -c "
import sys

${PYTHON_HELPERS}

logins = set()
for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    parts = line.split('|', 1)
    if len(parts) < 2:
        continue
    author_email, committer_email = parts
    login = email_to_login(author_email)
    committer_login = email_to_login(committer_email)
    if is_bot(login) or is_bot(committer_login):
        continue
    logins.add(login)

print(','.join(sorted(logins)))
"
	return 0
}

#######################################
# Query GitHub Search API for per-login stats
#
# Arguments:
#   $1 - comma-separated logins
#   $2 - repo slug (owner/repo)
#   $3 - since_date (YYYY-MM-DD)
# Output: JSON array string to stdout
#         Sets _ps_partial=true on stderr line "PARTIAL=true" if any query fails
#######################################
_person_stats_query_github() {
	local logins_csv="$1"
	local slug="$2"
	local since_date="$3"

	local results_json="["
	local first=true
	local _ps_partial=false
	local IFS=','
	local login
	for login in $logins_csv; do
		# Check search API rate limit before each batch of 4 queries per user
		local remaining
		local remaining_rc=0
		remaining=$(_person_stats_gh_api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || remaining_rc=$?
		if [[ "$remaining_rc" -eq 124 ]]; then
			echo "GitHub rate-limit probe timed out after $(_person_stats_gh_api_timeout)s, returning partial results" >&2
			_ps_partial=true
			break
		fi
		[[ "$remaining" =~ ^[0-9]+$ ]] || remaining=30
		if [[ "$remaining" -lt 5 ]]; then
			# t1429: bail out with partial results instead of sleeping.
			# The old code slept until reset, creating an infinite blocking
			# loop when multiple users x repos exhausted the 30 req/min budget.
			echo "Rate limit exhausted (${remaining} remaining), returning partial results" >&2
			_ps_partial=true
			break
		fi

		# Issues created by this user in this repo since the date
		local issues_created
		local issues_created_rc=0
		issues_created=$(_person_stats_query_count "issues-created" "search/issues?q=author:${login}+repo:${slug}+type:issue+created:>${since_date}&per_page=1") || issues_created_rc=$?
		[[ "$issues_created_rc" -ne 0 ]] && _ps_partial=true

		# PRs created
		local prs_created
		local prs_created_rc=0
		prs_created=$(_person_stats_query_count "prs-created" "search/issues?q=author:${login}+repo:${slug}+type:pr+created:>${since_date}&per_page=1") || prs_created_rc=$?
		[[ "$prs_created_rc" -ne 0 ]] && _ps_partial=true

		# PRs merged
		local prs_merged
		local prs_merged_rc=0
		prs_merged=$(_person_stats_query_count "prs-merged" "search/issues?q=author:${login}+repo:${slug}+type:pr+is:merged+merged:>${since_date}&per_page=1") || prs_merged_rc=$?
		[[ "$prs_merged_rc" -ne 0 ]] && _ps_partial=true

		# Issues/PRs commented on (commenter: qualifier counts unique issues, not comments)
		local commented_on
		local commented_on_rc=0
		commented_on=$(_person_stats_query_count "commented-on" "search/issues?q=commenter:${login}+repo:${slug}+updated:>${since_date}&per_page=1") || commented_on_rc=$?
		[[ "$commented_on_rc" -ne 0 ]] && _ps_partial=true

		if [[ "$first" == "true" ]]; then
			first=false
		else
			results_json+=","
		fi
		results_json+="{\"login\":\"${login}\",\"issues_created\":${issues_created},\"prs_created\":${prs_created},\"prs_merged\":${prs_merged},\"commented_on\":${commented_on}}"
	done
	unset IFS
	results_json+="]"

	echo "$results_json"
	if [[ "$_ps_partial" == "true" ]]; then
		echo "PARTIAL=true" >&2
	fi
	return 0
}

#######################################
# Format person_stats output
#
# Arguments:
#   $1 - JSON array of per-login stats
#   $2 - format: "markdown" or "json"
#   $3 - period name
#   $4 - is_partial: "true" or "false"
# Output: formatted table or JSON to stdout
#######################################
_person_stats_format_output() {
	local results_json="$1"
	local format="$2"
	local period="$3"
	local is_partial="$4"

	# Format output (pass partial flag so callers can detect truncated data)
	echo "$results_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
period_name = sys.argv[2]
is_partial = sys.argv[3] == 'true'

data = json.load(sys.stdin)

# Sort by total output (issues + PRs + comments) descending
for d in data:
    d['total_output'] = d['issues_created'] + d['prs_created'] + d['commented_on']
data.sort(key=lambda x: x['total_output'], reverse=True)

if format_type == 'json':
    result = {'data': data, 'partial': is_partial}
    print(json.dumps(result, indent=2))
else:
    grand_total = sum(d['total_output'] for d in data)
    if grand_total == 0:
        if is_partial:
            print('_GitHub activity unavailable or incomplete — one or more Search API queries failed, timed out, or were rate-limited._')
        else:
            print(f'_No GitHub activity for the last {period_name}._')
    else:
        print(f'| Contributor | Issues | PRs | Merged | Commented | % of Total |')
        print(f'| --- | ---: | ---: | ---: | ---: | ---: |')
        for d in data:
            pct = round(d['total_output'] / grand_total * 100, 1)
            print(f'| {d[\"login\"]} | {d[\"issues_created\"]} | {d[\"prs_created\"]} | {d[\"prs_merged\"]} | {d[\"commented_on\"]} | {pct}% |')
    if is_partial and grand_total > 0:
        print()
        print('<!-- partial-results -->')
        print('_Partial results — one or more GitHub Search API queries failed, timed out, or were rate-limited._')
" "$format" "$period" "$is_partial"

	return 0
}

#######################################
# Per-person GitHub output stats
#
# Queries GitHub Search API for each contributor's issues, PRs, and comments.
# Contributors are auto-discovered from git history (non-bot authors).
#
# Arguments:
#   $1 - repo path (used to derive slug and discover contributors)
#   --period day|week|month|quarter|year (optional, default: month)
#   --format markdown|json (optional, default: markdown)
#   --logins login1,login2 (optional, override auto-discovery)
# Output: per-person table to stdout
#######################################
person_stats() {
	local repo_path=""
	local period="month"
	local format="markdown"
	local logins_override=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--period)
			period="${2:-month}"
			shift 2
			;;
		--format)
			format="${2:-markdown}"
			shift 2
			;;
		--logins)
			logins_override="${2:-}"
			shift 2
			;;
		*)
			if [[ -z "$repo_path" ]]; then
				repo_path="$1"
			fi
			shift
			;;
		esac
	done

	repo_path="${repo_path:-.}"

	if [[ ! -d "$repo_path/.git" && ! -f "$repo_path/.git" ]]; then
		echo "Error: $repo_path is not a git repository" >&2
		return 1
	fi

	local slug
	slug=$(_person_stats_get_slug "$repo_path") || return 1

	local since_date
	since_date=$(_person_stats_since_date "$period")

	# Discover contributor logins from git history or use override
	local logins_csv
	if [[ -n "$logins_override" ]]; then
		logins_csv="$logins_override"
	else
		logins_csv=$(_person_stats_discover_logins "$repo_path" "$since_date")
	fi

	if [[ -z "$logins_csv" ]]; then
		if [[ "$format" == "json" ]]; then
			printf '%s\n' '{"data":[],"partial":false}'
		else
			echo "_No contributors found for the last ${period}._"
		fi
		return 0
	fi

	# Query GitHub Search API for each login.
	# Rate limit: 30 requests/min for search API. With 4 queries per user,
	# we can handle ~7 users per minute. If budget is exhausted, bail out
	# with partial results instead of blocking (t1429).
	local results_json partial_flag ps_stderr
	ps_stderr=$(mktemp)
	results_json=$(_person_stats_query_github "$logins_csv" "$slug" "$since_date" 2>"$ps_stderr") || true
	partial_flag=$(grep '^PARTIAL=' "$ps_stderr" 2>/dev/null | sed 's/PARTIAL=//' || echo "false")
	cat "$ps_stderr" >&2 2>/dev/null || true
	rm -f "$ps_stderr"

	_person_stats_format_output "$results_json" "$format" "$period" "$partial_flag"

	# Return distinct exit code so callers can detect truncated payloads.
	# EX_PARTIAL (75) means "valid output on stdout, but incomplete due to
	# collection failures, rate limiting, or timeouts. Callers should cache the
	# output but mark it as partial.
	if [[ "$partial_flag" == "true" ]]; then
		return "$EX_PARTIAL"
	fi
	return 0
}

#######################################
# Collect per-repo person stats JSON for cross_repo_person_stats
#
# Arguments:
#   $1 - period
#   $2 - logins_override (may be empty)
#   $3..N - repo paths
# Output: newline-separated JSON arrays to stdout
#         Writes "PARTIAL=true" to stderr if any repo was partial
#######################################
_cross_repo_person_stats_collect_json() {
	local period="$1"
	local logins_override="$2"
	shift 2

	local all_json=""
	local repo_count=0
	local any_partial=false
	local rp
	for rp in "$@"; do
		repo_count=$((repo_count + 1))
		if [[ ! -d "$rp/.git" && ! -f "$rp/.git" ]]; then
			echo "Warning: $rp is not a git repository, skipping" >&2
			any_partial=true
			continue
		fi
		local repo_json
		local repo_rc=0
		local -a extra_args=()
		if [[ -n "$logins_override" ]]; then
			extra_args+=(--logins "$logins_override")
		fi
		repo_json=$(PERSON_STATS_MODE=cross-repo person_stats "$rp" --period "$period" --format json ${extra_args[@]+"${extra_args[@]}"}) || repo_rc=$?
		if [[ "$repo_rc" -eq "$EX_PARTIAL" ]]; then
			any_partial=true
		elif [[ "$repo_rc" -ne 0 ]]; then
			any_partial=true
			repo_json='{"data":[],"partial":false}'
		fi
		# person_stats --format json returns {"data": [...], "partial": bool}.
		# Extract the .data array for aggregation.
		local repo_data
		if repo_data=$(echo "$repo_json" | jq -e '.data // empty' 2>/dev/null); then
			all_json+="${repo_data}"$'\n'
		elif echo "$repo_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
			# Fallback: raw array (shouldn't happen, but defensive)
			all_json+="${repo_json}"$'\n'
		else
			echo "Warning: person stats returned invalid JSON, excluding repository data" >&2
			any_partial=true
		fi
	done

	echo -n "$all_json"
	echo "REPO_COUNT=${repo_count}" >&2
	if [[ "$any_partial" == "true" ]]; then
		echo "PARTIAL=true" >&2
	fi
	return 0
}

#######################################
# Aggregate and format cross-repo person stats
#
# Arguments:
#   $1 - merged JSON array (all repos combined)
#   $2 - format: "markdown" or "json"
#   $3 - period name
#   $4 - repo count
#   $5 - is_partial: "true" or "false"
# Output: formatted table or JSON to stdout
#######################################
_cross_repo_person_stats_aggregate() {
	local all_json="$1"
	local format="$2"
	local period="$3"
	local repo_count="$4"
	local is_partial="$5"

	echo "$all_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
period_name = sys.argv[2]
repo_count = int(sys.argv[3])
is_partial = sys.argv[4] == 'true'

data = json.load(sys.stdin)

# Aggregate by login
totals = {}
for d in data:
    login = d['login']
    if login not in totals:
        totals[login] = {'login': login, 'issues_created': 0, 'prs_created': 0, 'prs_merged': 0, 'commented_on': 0}
    totals[login]['issues_created'] += d.get('issues_created', 0)
    totals[login]['prs_created'] += d.get('prs_created', 0)
    totals[login]['prs_merged'] += d.get('prs_merged', 0)
    totals[login]['commented_on'] += d.get('commented_on', 0)

results = list(totals.values())
for r in results:
    r['total_output'] = r['issues_created'] + r['prs_created'] + r['commented_on']
results.sort(key=lambda x: x['total_output'], reverse=True)

if format_type == 'json':
    result = {'repo_count': repo_count, 'contributors': results, 'partial': is_partial}
    print(json.dumps(result, indent=2))
else:
    grand_total = sum(r['total_output'] for r in results)
    if grand_total == 0:
        if is_partial:
            print(f'_Cross-repo GitHub activity unavailable or incomplete across {repo_count} repos — one or more Search API queries or repository collections failed, timed out, or were rate-limited._')
        else:
            print(f'_No GitHub activity across {repo_count} repos for the last {period_name}._')
    else:
        print(f'_Across {repo_count} managed repos:_')
        print()
        print(f'| Contributor | Issues | PRs | Merged | Commented | % of Total |')
        print(f'| --- | ---: | ---: | ---: | ---: | ---: |')
        for r in results:
            pct = round(r['total_output'] / grand_total * 100, 1)
            print(f'| {r[\"login\"]} | {r[\"issues_created\"]} | {r[\"prs_created\"]} | {r[\"prs_merged\"]} | {r[\"commented_on\"]} | {pct}% |')
    if is_partial and grand_total > 0:
        print()
        print('<!-- partial-results -->')
        print('_Partial results — one or more GitHub Search API queries or repository collections failed, timed out, or were rate-limited._')
" "$format" "$period" "$repo_count" "$is_partial"

	return 0
}

#######################################
# Cross-repo per-person GitHub output stats
#
# Aggregates person_stats across multiple repos. Privacy-safe (no repo names).
#
# Arguments:
#   $1..N - repo paths
#   --period day|week|month|quarter|year (optional, default: month)
#   --format markdown|json (optional, default: markdown)
#   --logins login1,login2 (optional, override auto-discovery)
# Output: aggregated per-person table to stdout
#######################################
cross_repo_person_stats() {
	local period="month"
	local format="markdown"
	local logins_override=""
	local -a repo_paths=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--period)
			period="${2:-month}"
			shift 2
			;;
		--format)
			format="${2:-markdown}"
			shift 2
			;;
		--logins)
			logins_override="${2:-}"
			shift 2
			;;
		*)
			repo_paths+=("$1")
			shift
			;;
		esac
	done

	if [[ ${#repo_paths[@]} -eq 0 ]]; then
		echo "Error: at least one repo path required" >&2
		return 1
	fi

	# Collect JSON from each repo, capture repo_count and partial flag from stderr
	local raw_json repo_count_line repo_count partial_line partial_flag crps_stderr
	crps_stderr=$(mktemp)
	raw_json=$(_cross_repo_person_stats_collect_json "$period" "$logins_override" "${repo_paths[@]}" 2>"$crps_stderr") || true
	repo_count_line=$(grep '^REPO_COUNT=' "$crps_stderr" 2>/dev/null || echo "REPO_COUNT=0")
	repo_count="${repo_count_line#REPO_COUNT=}"
	partial_line=$(grep '^PARTIAL=' "$crps_stderr" 2>/dev/null || echo "PARTIAL=false")
	partial_flag="${partial_line#PARTIAL=}"
	cat "$crps_stderr" >&2 2>/dev/null || true
	rm -f "$crps_stderr"

	# Merge all repo arrays into one, then aggregate per login
	local all_json
	all_json=$(echo -n "$raw_json" | jq -s 'add // []')

	_cross_repo_person_stats_aggregate "$all_json" "$format" "$period" "$repo_count" "$partial_flag"

	# Propagate partial status to callers
	if [[ "$partial_flag" == "true" ]]; then
		return "$EX_PARTIAL"
	fi
	return 0
}
