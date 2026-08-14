#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Contributor Activity -- Git Commit Activity Computation
# =============================================================================
# Computes per-contributor activity from default-branch git commit history.
# Includes single-repo summaries, per-user breakdowns, and cross-repo
# aggregation with active-day deduplication.
#
# Usage: source "${SCRIPT_DIR}/contributor-activity-helper-activity.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - _resolve_default_branch() from orchestrator
#   - _period_to_since_arg() from orchestrator
#   - PYTHON_HELPERS variable from orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONTRIBUTOR_ACTIVITY_ACTIVITY_LIB_LOADED:-}" ]] && return 0
_CONTRIBUTOR_ACTIVITY_ACTIVITY_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Fetch git log data for compute_activity
#
# Reads git log on the default branch and returns pipe-delimited lines:
#   author_email|committer_email|ISO-date
#
# Arguments:
#   $1 - repo path
#   $2 - period: "day", "week", "month", "year"
# Output: git log lines to stdout (empty string if no commits)
#######################################
_compute_activity_fetch_git_log() {
	local repo_path="$1"
	local period="$2"

	local since_arg
	since_arg=$(_period_to_since_arg "$period")

	local default_branch
	default_branch=$(_resolve_default_branch "$repo_path")

	local git_data=""
	# shellcheck disable=SC2086
	git_data=$(git -C "$repo_path" log "$default_branch" --format='%ae|%ce|%aI' $since_arg) || git_data=""
	echo "$git_data"
	return 0
}

#######################################
# Process git log data and format activity output
#
# Arguments:
#   $1 - git log data (pipe-delimited lines)
#   $2 - format: "markdown" or "json"
#   $3 - period name (for empty-state messages)
# Output: formatted table or JSON to stdout
#######################################
_compute_activity_process() {
	local git_data="$1"
	local format="$2"
	local period="$3"

	if [[ -z "$git_data" ]]; then
		if [[ "$format" == "json" ]]; then
			echo "[]"
		else
			echo "_No activity in the last ${period}._"
		fi
		return 0
	fi

	# Process with python3 for date arithmetic.
	# Variables passed via sys.argv to avoid shell injection.
	echo "$git_data" | python3 -c "
import sys
import json
from collections import defaultdict
from datetime import datetime, timezone

${PYTHON_HELPERS}

contributors = defaultdict(lambda: {
    'direct_commits': 0,
    'pr_merges': 0,
    'days': set(),
})

for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    parts = line.split('|', 2)
    if len(parts) < 3:
        continue
    author_email, committer_email, date_str = parts
    login = email_to_login(author_email)

    # Skip bot accounts (GitHub Actions, Dependabot, Renovate, etc.)
    if is_bot(login):
        continue

    # Also skip if the committer is a bot (Actions, Dependabot, etc.)
    committer_login = email_to_login(committer_email)
    if is_bot(committer_login):
        continue

    try:
        dt = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
    except ValueError:
        continue

    day = dt.strftime('%Y-%m-%d')
    contributors[login]['days'].add(day)

    if is_pr_merge(committer_email):
        contributors[login]['pr_merges'] += 1
    else:
        contributors[login]['direct_commits'] += 1

results = []
for login, data in sorted(contributors.items(), key=lambda x: -(x[1]['direct_commits'] + x[1]['pr_merges'])):
    active_days = len(data['days'])
    total = data['direct_commits'] + data['pr_merges']
    avg_per_day = total / active_days if active_days > 0 else 0

    entry = {
        'login': login,
        'direct_commits': data['direct_commits'],
        'pr_merges': data['pr_merges'],
        'total_commits': total,
        'active_days': active_days,
        'avg_commits_per_day': round(avg_per_day, 1),
    }
    # JSON includes day list for cross-repo deduplication
    if sys.argv[1] == 'json':
        entry['active_days_list'] = sorted(data['days'])
    results.append(entry)

format_type = sys.argv[1]
period_name = sys.argv[2]

if format_type == 'json':
    print(json.dumps(results, indent=2))
else:
    if not results:
        print(f'_No contributor activity in the last {period_name}._')
    else:
        print('| Contributor | Direct Pushes | PRs Merged | Total Commits | Active Days | Avg/Day |')
        print('| --- | ---: | ---: | ---: | ---: | ---: |')
        for r in results:
            print(f'| {r[\"login\"]} | {r[\"direct_commits\"]} | {r[\"pr_merges\"]} | {r[\"total_commits\"]} | {r[\"active_days\"]} | {r[\"avg_commits_per_day\"]} |')
" "$format" "$period"

	return 0
}

#######################################
# Compute activity summary for all contributors in a repo
#
# Reads git log and computes per-contributor stats:
#   - Direct commits (committer = author's own email)
#   - PR merges (committer = noreply@github.com, i.e. GitHub squash-merge)
#   - Total commits
#   - Active days (with day list in JSON for cross-repo deduplication)
#   - Average commits per active day
#
# Arguments:
#   $1 - repo path
#   $2 - period: "day", "week", "month", "year" (default: "month")
#   $3 - output format: "markdown" or "json" (default: "markdown")
# Output: formatted table to stdout
#######################################
compute_activity() {
	local repo_path="$1"
	local period="${2:-month}"
	local format="${3:-markdown}"

	if [[ ! -d "$repo_path/.git" && ! -f "$repo_path/.git" ]]; then
		echo "Error: $repo_path is not a git repository" >&2
		return 1
	fi

	# Get git log: author_email|committer_email|ISO-date (one line per commit)
	# Explicit default branch (no --all) to avoid double-counting squash-merged PRs.
	# With --all, branch commits AND their squash-merge on main are both counted,
	# inflating totals by ~12%. The committer email distinguishes commit types:
	#   noreply@github.com = GitHub squash-merged a PR (author created the PR)
	#   author's own email = direct push
	local git_data
	git_data=$(_compute_activity_fetch_git_log "$repo_path" "$period")

	_compute_activity_process "$git_data" "$format" "$period"
	return 0
}

#######################################
# Get activity for a single user
#
# Arguments:
#   $1 - repo path
#   $2 - GitHub login
# Output: JSON with day/week/month/year breakdown
#######################################
user_activity() {
	local repo_path="$1"
	local target_login="$2"

	if [[ ! -d "$repo_path/.git" && ! -f "$repo_path/.git" ]]; then
		echo "Error: $repo_path is not a git repository" >&2
		return 1
	fi

	# Get default-branch commits with author + committer emails
	local default_branch
	default_branch=$(_resolve_default_branch "$repo_path")
	local git_data
	git_data=$(git -C "$repo_path" log "$default_branch" --format='%ae|%ce|%aI' --since='1.year.ago') || git_data=""

	# Target login passed via sys.argv to avoid shell injection.
	echo "$git_data" | python3 -c "
import sys
import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone

${PYTHON_HELPERS}

target = sys.argv[1]
now = datetime.now(timezone.utc)

periods = {
    'today': now.replace(hour=0, minute=0, second=0, microsecond=0),
    'this_week': now - timedelta(days=now.weekday()),
    'this_month': now.replace(day=1, hour=0, minute=0, second=0, microsecond=0),
    'this_year': now.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0),
}

counts = {p: {'direct_commits': 0, 'pr_merges': 0, 'days': set()} for p in periods}

for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    parts = line.split('|', 2)
    if len(parts) < 3:
        continue
    author_email, committer_email, date_str = parts
    login = email_to_login(author_email)
    if login != target:
        continue

    # Skip if committer is a bot (Actions, Dependabot, etc.)
    committer_login = email_to_login(committer_email)
    if is_bot(committer_login):
        continue

    try:
        dt = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
    except ValueError:
        continue

    day = dt.strftime('%Y-%m-%d')
    for period_name, start in periods.items():
        start_aware = start.replace(tzinfo=timezone.utc) if start.tzinfo is None else start
        if dt >= start_aware:
            counts[period_name]['days'].add(day)
            if is_pr_merge(committer_email):
                counts[period_name]['pr_merges'] += 1
            else:
                counts[period_name]['direct_commits'] += 1

result = {'login': target}
for period_name in ('today', 'this_week', 'this_month', 'this_year'):
    data = counts[period_name]
    total = data['direct_commits'] + data['pr_merges']
    result[period_name] = {
        'direct_commits': data['direct_commits'],
        'pr_merges': data['pr_merges'],
        'total_commits': total,
        'active_days': len(data['days']),
    }

print(json.dumps(result, indent=2))
" "$target_login"

	return 0
}

#######################################
# Collect per-repo JSON for cross_repo_summary
#
# Arguments:
#   $1 - period
#   $2..N - repo paths
# Output: JSON array string (not newline-terminated) to stdout
#         Also sets global repo_count via stdout line "REPO_COUNT=N" on stderr
#######################################
_cross_repo_summary_collect_json() {
	local period="$1"
	shift
	local all_json="["
	local first="true"
	local repo_count=0
	local rp
	for rp in "$@"; do
		if [[ ! -d "$rp/.git" && ! -f "$rp/.git" ]]; then
			echo "Warning: $rp is not a git repository, skipping" >&2
			continue
		fi
		local repo_json
		repo_json=$(compute_activity "$rp" "$period" "json") || repo_json="[]"
		if [[ "$first" == "true" ]]; then
			first="false"
		else
			all_json="${all_json},"
		fi
		all_json="${all_json}{\"data\":${repo_json}}"
		repo_count=$((repo_count + 1))
	done
	all_json="${all_json}]"
	echo "$all_json"
	echo "REPO_COUNT=${repo_count}" >&2
	return 0
}

#######################################
# Aggregate cross-repo JSON and format output
#
# Arguments:
#   $1 - JSON array of {data:[...]} objects
#   $2 - format: "markdown" or "json"
#   $3 - period name
#   $4 - repo count
# Output: formatted table or JSON to stdout
#######################################
_cross_repo_summary_aggregate() {
	local all_json="$1"
	local format="$2"
	local period="$3"
	local repo_count="$4"

	# Aggregate across repos in Python — deduplicate active days via set union
	echo "$all_json" | python3 -c "
import sys
import json

format_type = sys.argv[1]
period_name = sys.argv[2]
repo_count = int(sys.argv[3])

repos = json.load(sys.stdin)

# Aggregate per contributor across all repos.
# active_days uses set union to avoid double-counting days where a
# contributor committed in multiple repos on the same calendar day.
totals = {}
for repo in repos:
    for entry in repo.get('data', []):
        login = entry['login']
        if login not in totals:
            totals[login] = {
                'direct_commits': 0,
                'pr_merges': 0,
                'total_commits': 0,
                'active_days_set': set(),
                'repo_count': 0,
            }
        totals[login]['direct_commits'] += entry.get('direct_commits', 0)
        totals[login]['pr_merges'] += entry.get('pr_merges', 0)
        totals[login]['total_commits'] += entry.get('total_commits', 0)
        # Union of day strings — deduplicates cross-repo overlaps
        for day_str in entry.get('active_days_list', []):
            totals[login]['active_days_set'].add(day_str)
        if entry.get('total_commits', 0) > 0:
            totals[login]['repo_count'] += 1

results = []
for login, data in sorted(totals.items(), key=lambda x: -x[1]['total_commits']):
    active_days = len(data['active_days_set'])
    avg = data['total_commits'] / active_days if active_days > 0 else 0
    results.append({
        'login': login,
        'direct_commits': data['direct_commits'],
        'pr_merges': data['pr_merges'],
        'total_commits': data['total_commits'],
        'active_days': active_days,
        'repos_active': data['repo_count'],
        'avg_commits_per_day': round(avg, 1),
    })

if format_type == 'json':
    print(json.dumps(results, indent=2))
else:
    if not results:
        print(f'_No cross-repo activity in the last {period_name}._')
    else:
        print(f'_Across {repo_count} managed repos:_')
        print()
        print('| Contributor | Direct Pushes | PRs Merged | Total Commits | Active Days | Repos | Avg/Day |')
        print('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
        for r in results:
            print(f'| {r[\"login\"]} | {r[\"direct_commits\"]} | {r[\"pr_merges\"]} | {r[\"total_commits\"]} | {r[\"active_days\"]} | {r[\"repos_active\"]} | {r[\"avg_commits_per_day\"]} |')
" "$format" "$period" "$repo_count"

	return 0
}

#######################################
# Cross-repo activity summary
#
# Aggregates activity across multiple repos without revealing repo names
# (cross-repo privacy). Uses active_days_list from JSON output to
# deduplicate days across repos (set union, not sum).
#
# Arguments:
#   $1..N - repo paths (at least one required)
#   --period day|week|month|year (optional, default: month)
#   --format markdown|json (optional, default: markdown)
# Output: aggregated table to stdout
#######################################
cross_repo_summary() {
	local period="month"
	local format="markdown"
	local -a repo_paths=()

	# Parse arguments
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

	# Collect JSON (with active_days_list) from each repo, then aggregate.
	# Capture repo_count from stderr line "REPO_COUNT=N".
	local all_json repo_count_line repo_count stderr_file
	stderr_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-cross-repo-summary-XXXXXX") || return 1
	trap 'rm -f "${stderr_file:-}"' RETURN
	all_json=$(_cross_repo_summary_collect_json "$period" "${repo_paths[@]}" 2>"$stderr_file") || true
	repo_count_line=$(grep '^REPO_COUNT=' "$stderr_file" 2>/dev/null || echo "REPO_COUNT=0")
	repo_count="${repo_count_line#REPO_COUNT=}"
	cat "$stderr_file" >&2 2>/dev/null || true

	_cross_repo_summary_aggregate "$all_json" "$format" "$period" "$repo_count"
	return 0
}
