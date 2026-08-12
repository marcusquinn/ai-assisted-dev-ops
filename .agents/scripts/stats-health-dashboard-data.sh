#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Health Dashboard — Data Gathering & Body Formatting Sub-Library
# =============================================================================
# Functions for scanning active workers, gathering system resources,
# computing stats, formatting the health issue body markdown, and
# refreshing person-stats caches.
#
# Usage: source "${SCRIPT_DIR}/stats-health-dashboard-data.sh"
#
# Dependencies:
#   - shared-constants.sh (gh_issue_list, gh_issue_view, gh_issue_edit_safe, etc.)
#   - worker-lifecycle-common.sh (list_active_worker_processes, check_session_count)
#   - stats-shared.sh (_get_runner_role)
#
# Globals read:
#   - LOGFILE, REPOS_JSON, PERSON_STATS_INTERVAL, PERSON_STATS_LAST_RUN,
#     PERSON_STATS_CACHE_DIR, SESSION_COUNT_WARN
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_STATS_HEALTH_DASHBOARD_DATA_LOADED:-}" ]] && return 0
_STATS_HEALTH_DASHBOARD_DATA_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Distinct exit code emitted by contributor-activity-helper.sh when stdout
# contains valid but incomplete data due to rate limits or timeouts. Reuse a
# shared EX_PARTIAL value when the sourcing context already defines one.
readonly STATS_HEALTH_EX_PARTIAL="${EX_PARTIAL:-75}"

# Wall-clock guard for each dashboard person-stats helper invocation. The
# helper already bounds individual GitHub API calls; this keeps the health
# dashboard refresh from spending unbounded time across many contributors.
: "${STATS_HEALTH_PERSON_STATS_TIMEOUT:=60}"

# Wall-clock guard for dashboard Search API budget probes. These probes run
# before optional person-stats helper calls, so they must not become a separate
# unbounded blocking point when GitHub is slow.
: "${STATS_HEALTH_PERSON_STATS_RATE_LIMIT_TIMEOUT:=10}"

# The primary dashboard must publish its freshness marker within the enclosing
# stats-wrapper ceiling. Activity and session-time helpers can walk large local
# histories, so bound each best-effort section independently rather than let a
# single slow history scan consume the whole dashboard refresh budget.
: "${STATS_HEALTH_ACTIVITY_TIMEOUT:=60}"

# --- Functions ---

#######################################
# Read remaining GitHub Search API budget with portable timeout protection.
#
# Output: remaining search requests, or 0 on timeout/failure
#######################################
_stats_health_person_stats_search_remaining() {
	local remaining="0"
	remaining=$(timeout_sec "$STATS_HEALTH_PERSON_STATS_RATE_LIMIT_TIMEOUT" gh api rate_limit --jq '.resources.search.remaining' 2>/dev/null) || remaining="0"
	remaining="${remaining//[^0-9]/}"
	printf '%s\n' "${remaining:-0}"
	return 0
}

#######################################
# Scan active headless worker processes for a repo.
#
# Uses the shared list_active_worker_processes (worker-lifecycle-common.sh)
# as the single source of truth for worker discovery, then filters by
# repo path and formats as markdown for the health issue body.
#
# Arguments:
#   $1 - repo path (used to filter workers by --dir)
# Output: NUL-delimited "workers_md\0worker_count\0"
#######################################
_scan_active_workers() {
	local repo_path="$1"

	local workers_md=""
	local worker_count=0

	# Get deduplicated, zombie-filtered worker list from shared function
	local worker_lines
	worker_lines=$(list_active_worker_processes || true)

	if [[ -n "$worker_lines" ]]; then
		local worker_table=""
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			local w_pid w_etime w_cmd
			read -r w_pid w_etime w_cmd <<<"$line"

			# Extract dir if present — filter to this repo only
			local w_dir=""
			if [[ "$w_cmd" =~ --dir[[:space:]]+([^[:space:]]+) ]]; then
				w_dir="${BASH_REMATCH[1]}"
			fi

			# Only include workers for this repo (or all if dir not detectable)
			if [[ -n "$w_dir" && -n "$repo_path" && "$w_dir" != "$repo_path"* ]]; then
				continue
			fi

			# Extract title if present (--title "...")
			local w_title="headless"
			if [[ "$w_cmd" =~ --title[[:space:]]+\"([^\"]+)\" ]] || [[ "$w_cmd" =~ --title[[:space:]]+([^[:space:]]+) ]]; then
				w_title="${BASH_REMATCH[1]}"
			fi

			local w_title_short="${w_title:0:60}"
			[[ ${#w_title} -gt 60 ]] && w_title_short="${w_title_short}..."
			worker_table="${worker_table}| ${w_pid} | ${w_etime} | ${w_title_short} |
"
			worker_count=$((worker_count + 1))
		done <<<"$worker_lines"

		if [[ "$worker_count" -gt 0 ]]; then
			workers_md="| PID | Uptime | Title |
| --- | --- | --- |
${worker_table}"
		fi
	fi

	if [[ "$worker_count" -eq 0 ]]; then
		workers_md="_No active workers_"
	fi

	# NUL-delimited output preserves multiline workers_md markdown
	printf '%s\0%s\0' "$workers_md" "$worker_count"
	return 0
}

#######################################
# Collect system resource metrics (CPU, memory, processes).
#
# Output: "sys_load_ratio|sys_cpu_cores|sys_load_1m|sys_load_5m|sys_memory|sys_procs"
#######################################
_gather_system_resources() {
	local _mem_unknown="unknown"
	local sys_cpu_cores sys_load_1m sys_load_5m sys_memory sys_procs
	sys_cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "?")
	sys_procs=$(ps aux 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$(uname)" == "Darwin" ]]; then
		local load_str
		load_str=$(sysctl -n vm.loadavg 2>/dev/null || echo "{ 0 0 0 }")
		sys_load_1m=$(echo "$load_str" | awk '{print $2}')
		sys_load_5m=$(echo "$load_str" | awk '{print $3}')

		local page_size vm_free vm_inactive
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "16384")
		vm_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		vm_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=16384
		[[ "$vm_free" =~ ^[0-9]+$ ]] || vm_free=0
		[[ "$vm_inactive" =~ ^[0-9]+$ ]] || vm_inactive=0
		if [[ -n "$vm_free" ]]; then
			local avail_mb=$(((${vm_free:-0} + ${vm_inactive:-0}) * page_size / 1048576))
			if [[ "$avail_mb" -lt 1024 ]]; then
				sys_memory="HIGH pressure (${avail_mb}MB free)"
			elif [[ "$avail_mb" -lt 4096 ]]; then
				sys_memory="medium (${avail_mb}MB free)"
			else
				sys_memory="low (${avail_mb}MB free)"
			fi
		else
			sys_memory="$_mem_unknown"
		fi
	elif [[ -f /proc/loadavg ]]; then
		read -r sys_load_1m sys_load_5m _ </proc/loadavg
		local mem_avail
		mem_avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "")
		if [[ -n "$mem_avail" ]]; then
			if [[ "$mem_avail" -lt 1024 ]]; then
				sys_memory="HIGH pressure (${mem_avail}MB free)"
			elif [[ "$mem_avail" -lt 4096 ]]; then
				sys_memory="medium (${mem_avail}MB free)"
			else
				sys_memory="low (${mem_avail}MB free)"
			fi
		else
			sys_memory="$_mem_unknown"
		fi
	else
		sys_load_1m="?"
		sys_load_5m="?"
		sys_memory="$_mem_unknown"
	fi

	local sys_load_ratio="?"
	if [[ -n "${sys_load_1m:-}" && "${sys_cpu_cores:-0}" -gt 0 && "${sys_cpu_cores}" != "?" ]]; then
		if [[ "$sys_load_1m" =~ ^[0-9]+\.?[0-9]*$ ]] && [[ "$sys_cpu_cores" =~ ^[0-9]+$ ]]; then
			sys_load_ratio=$(awk "BEGIN {printf \"%d\", (${sys_load_1m} / ${sys_cpu_cores}) * 100}" || echo "?")
		fi
	fi

	printf '%s|%s|%s|%s|%s|%s' \
		"$sys_load_ratio" "$sys_cpu_cores" "$sys_load_1m" "$sys_load_5m" "$sys_memory" "$sys_procs"
	return 0
}

_dashboard_provider_auth_summary() {
	local auth_file="${OPENCODE_AUTH_FILE:-${HOME}/.local/share/opencode/auth.json}"
	local openai_status="missing"
	local anthropic_status="missing"

	[[ -n "${OPENAI_API_KEY:-}" ]] && openai_status="env"
	[[ -n "${ANTHROPIC_API_KEY:-}" ]] && anthropic_status="env"
	if [[ -f "$auth_file" && -x "$(command -v jq 2>/dev/null || true)" ]]; then
		if [[ "$openai_status" == "missing" ]] && jq -e '.openai | type == "object" and ((.access // .refresh // .token // .apiKey // "") != "")' "$auth_file" >/dev/null 2>&1; then
			openai_status="oauth"
		fi
		if [[ "$anthropic_status" == "missing" ]] && jq -e '.anthropic | type == "object" and ((.access // .refresh // .token // .apiKey // "") != "")' "$auth_file" >/dev/null 2>&1; then
			anthropic_status="oauth"
		fi
	fi

	printf 'OpenAI: %s; Anthropic: %s; auth file: %s' "$openai_status" "$anthropic_status" "$([[ -f "$auth_file" ]] && printf present || printf missing)"
	return 0
}

_dashboard_latest_match() {
	local file_path="$1"
	local pattern="$2"
	local latest=""
	[[ -f "$file_path" ]] || { printf '%s' "none"; return 0; }
	while IFS= read -r _dash_line; do
		[[ "$_dash_line" == *"$pattern"* ]] || continue
		latest="$_dash_line"
	done <"$file_path"
	[[ -n "$latest" ]] || latest="none"
	printf '%s' "$latest"
	return 0
}

_gather_worker_zero_diagnostics() {
	local worker_count="$1"
	local max_workers="$2"
	local assigned_issue_count="$3"
	local total_issue_count="$4"
	local sys_load_ratio="$5"
	local sys_memory="$6"

	if [[ "$worker_count" != "0" ]]; then
		printf '%s' "_Workers are active; zero-worker diagnostics not needed._"
		return 0
	fi

	local metrics_file="${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl"
	local dispatch_stages_file="${HOME}/.aidevops/logs/dispatch-stages.tsv"
	local pulse_log="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	local last_worker_spawn last_spawn_failure last_stage auth_summary blocker_hint
	last_worker_spawn=$(_dashboard_latest_match "$metrics_file" '"role":"worker"')
	last_spawn_failure=$(_dashboard_latest_match "$pulse_log" 'Launch validation failed')
	last_stage=$(_dashboard_latest_match "$dispatch_stages_file" 'dispatch')
	auth_summary=$(_dashboard_provider_auth_summary)

	blocker_hint="unknown — inspect pulse-current-state-helper.sh --window 15m"
	if [[ "$max_workers" =~ ^[0-9]+$ && "$max_workers" -eq 0 ]]; then
		blocker_hint="max-worker/resource gate: max_workers=0"
	elif [[ "$assigned_issue_count" == "0" && "$total_issue_count" == "0" ]]; then
		blocker_hint="no eligible work visible on dashboard repo"
	elif [[ "$last_spawn_failure" != "none" ]]; then
		blocker_hint="worker launch failure"
	elif [[ "$auth_summary" == *"OpenAI: missing"* && "$auth_summary" == *"Anthropic: missing"* ]]; then
		blocker_hint="auth/model unavailable"
	elif [[ "$sys_load_ratio" =~ ^[0-9]+$ && "$sys_load_ratio" -ge 90 ]]; then
		blocker_hint="resource gate: high CPU/load"
	elif [[ "$sys_memory" == HIGH* ]]; then
		blocker_hint="resource gate: memory pressure"
	fi

	cat <<DIAG
| Signal | Value |
| --- | --- |
| Diagnosis | ${blocker_hint} |
| Provider/Auth Health | ${auth_summary} |
| Last Worker Spawn | ${last_worker_spawn} |
| Last Launch Failure | ${last_spawn_failure} |
| Last Dispatch Stage | ${last_stage} |
| Next Command | \`pulse-current-state-helper.sh --window 15m\` |
DIAG
	return 0
}

#######################################
# Gather live stats for the health issue body.
#
# Collects PR counts, issue counts, active workers, system resources,
# worktree count, max workers, and session count for a single repo.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
#   $3 - runner user
# Output: newline-delimited fields:
#   pr_count, prs_md, assigned_issue_count, total_issue_count,
#   workers_md, worker_count, sys_load_ratio, sys_cpu_cores,
#   sys_load_1m, sys_load_5m, sys_memory, sys_procs,
#   wt_count, max_workers, session_count, session_warning
#######################################
# Render an open-PR summary table from gh pr list JSON + REST check status array.
# Outputs a markdown table on stdout, or "_No open PRs_" when the input is empty.
# GH#21799: extracted from _gather_health_stats so the parent stays under the
# 100-line function-complexity gate after the REST migration.
_render_open_pr_table() {
	local pr_json="$1"
	local pr_checks_json="$2"
	local pr_count
	pr_count=$(echo "$pr_json" | jq 'length')
	if [[ "$pr_count" -le 0 ]]; then
		echo "_No open PRs_"
		return 0
	fi

	printf '| # | Title | Branch | Checks | Review | Updated |\n'
	printf '| --- | --- | --- | --- | --- | --- |\n'
	jq -n --argjson prs "$pr_json" --argjson checks "$pr_checks_json" -r '
		($checks | map({(.number | tostring): .status}) | add // {}) as $check_map |
		$prs[] |
		(.number | tostring) as $n |
		"| #\(.number) | \(.title[:60]) | `\(.headRefName)` | \($check_map[$n] // "unknown") | \(if .reviewDecision == null or .reviewDecision == "" then "NONE" else .reviewDecision end) | \(.updatedAt[:16]) |"
	'
	return 0
}

_gather_health_stats() {
	local repo_slug="$1"
	local repo_path="$2"
	local runner_user="$3"

	# Open PRs — limit 100 for accurate count + table display.
	# GH#21799: drop GraphQL statusCheckRollup; fetch headRefOid + resolve
	# PASS/FAIL/PENDING via REST check-suites (separate budget pool).
	local pr_json
	pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--json number,title,headRefName,headRefOid,updatedAt,reviewDecision \
		--limit 100 2>/dev/null) || pr_json="[]"
	local pr_count
	pr_count=$(echo "$pr_json" | jq 'length')

	# Enrich with REST check status (only when there are PRs to check).
	local pr_checks_json="[]"
	if [[ "$pr_count" -gt 0 ]]; then
		pr_checks_json=$(gh_pr_check_status_rest_batch "$repo_slug" "$pr_json" 2>/dev/null) || pr_checks_json="[]"
		[[ -n "$pr_checks_json" && "$pr_checks_json" != "null" ]] || pr_checks_json="[]"
	fi

	# Open issues — assigned to this runner (actionable) vs total.
	local assigned_issue_count
	assigned_issue_count=$(gh_issue_list --repo "$repo_slug" --state open \
		--assignee "$runner_user" --limit 500 \
		--json number --jq 'length' 2>/dev/null || echo "0")
	local total_issue_count
	total_issue_count=$(gh_issue_list --repo "$repo_slug" --state open \
		--limit 500 \
		--json number,labels --jq '[.[] | select(.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review")) | not)] | length' 2>/dev/null || echo "0")

	# Active headless workers — parse NUL-delimited output from _scan_active_workers.
	local workers_md="" worker_count=0
	{
		local _worker_fields=()
		while IFS= read -r -d '' _wf; do
			_worker_fields+=("$_wf")
		done < <(_scan_active_workers "$repo_path")
		workers_md="${_worker_fields[0]:-_No active workers_}"
		worker_count="${_worker_fields[1]:-0}"
	}

	# System resources
	local sys_raw sys_load_ratio sys_cpu_cores sys_load_1m sys_load_5m sys_memory sys_procs
	sys_raw=$(_gather_system_resources)
	IFS='|' read -r sys_load_ratio sys_cpu_cores sys_load_1m sys_load_5m sys_memory sys_procs <<<"$sys_raw"

	# Worktree count for this repo
	local wt_count=0
	if [[ -d "${repo_path}/.git" ]]; then
		wt_count=$(git -C "$repo_path" worktree list 2>/dev/null | wc -l | tr -d ' ')
	fi

	# Max workers — validate as integer.
	local max_workers="?"
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	if [[ -f "$max_workers_file" ]]; then
		max_workers=$(cat "$max_workers_file" 2>/dev/null || echo "?")
		[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers="?"
	fi

	# Interactive session count (t1398)
	local session_count
	session_count=$(check_session_count)
	local session_warning=""
	if [[ "$session_count" -gt "$SESSION_COUNT_WARN" ]]; then
		session_warning=" **WARNING: exceeds threshold of ${SESSION_COUNT_WARN}**"
		echo "[stats] Session warning: $session_count interactive sessions open (threshold: $SESSION_COUNT_WARN)" >>"$LOGFILE"
	fi

	# PRs table — REST-derived check status by PR number (GH#21799).
	local prs_md
	prs_md=$(_render_open_pr_table "$pr_json" "$pr_checks_json")
	local worker_zero_diagnostics_md
	worker_zero_diagnostics_md=$(_gather_worker_zero_diagnostics \
		"$worker_count" "$max_workers" "$assigned_issue_count" "$total_issue_count" \
		"$sys_load_ratio" "$sys_memory")

	# Output all stats as NUL-delimited fields.
	printf '%s\0' \
		"$pr_count" \
		"$prs_md" \
		"$assigned_issue_count" \
		"$total_issue_count" \
		"$workers_md" \
		"$worker_count" \
		"$sys_load_ratio" \
		"$sys_cpu_cores" \
		"$sys_load_1m" \
		"$sys_load_5m" \
		"$sys_memory" \
		"$sys_procs" \
		"$wt_count" \
		"$max_workers" \
		"$session_count" \
		"$session_warning" \
		"$worker_zero_diagnostics_md"
	return 0
}

#######################################
# Format the Worker Success Rate section markdown.
#
# Arguments:
#   $1 - rate_24h   (display string: "X% (M/T)" or "—")
#   $2 - rate_7d    (display string: "X% (M/T)" or "—")
#   $3 - total_24h  (numeric total run count for 24h window)
#   $4 - total_7d   (numeric total run count for 7d window)
# Output: markdown block to stdout
#######################################
_format_worker_rate_section() {
	local rate_24h="$1"
	local rate_7d="$2"
	local total_24h="$3"
	local total_7d="$4"
	printf '| Window | Success Rate |\n| --- | --- |\n| 24h | %s |\n| 7d | %s |\n\n<!-- worker-success-rate: 24h_total=%s 7d_total=%s -->' \
		"$rate_24h" "$rate_7d" "$total_24h" "$total_7d"
	return 0
}

#######################################
# Compute worker success rates for a given time window.
#
# Arguments:
#   $1 - runner_login  (GitHub username of the runner)
#   $2 - window_hours  (look-back window in hours, e.g. 24 or 168)
# Output: "<merged_count>\t<total_count>\t<rate_display>" to stdout
#######################################
_compute_worker_success_rates() {
	local runner_login="$1"
	local window_hours="$2"
	local _iso_fmt="%Y-%m-%dT%H:%M:%SZ"
	local window_epoch window_start
	if [[ "$(uname)" == "Darwin" ]]; then
		window_epoch=$(date -u -v-"${window_hours}"H +"%s")
		window_start=$(date -u -v-"${window_hours}"H +"$_iso_fmt")
	else
		window_epoch=$(date -u -d "${window_hours} hours ago" +"%s")
		window_start=$(date -u -d "${window_hours} hours ago" +"$_iso_fmt")
	fi
	local merged_count=0 closed_unmerged_count=0 killed_count=0
	local repos_file="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_file" ]]; then
		local slug
		while IFS= read -r slug; do
			[[ -z "$slug" ]] && continue
			local m cu
			m=$(gh pr list \
				--repo "$slug" \
				--author "$runner_login" \
				--label "origin:worker" \
				--state merged \
				--search "created:>${window_start}" \
				--json number \
				--jq 'length' \
				--limit 500 2>/dev/null || echo "0")
			merged_count=$(( merged_count + ${m:-0} ))
			cu=$(gh pr list \
				--repo "$slug" \
				--author "$runner_login" \
				--label "origin:worker" \
				--state closed \
				--search "created:>${window_start}" \
				--json mergedAt \
				--jq '[.[] | select(.mergedAt == null)] | length' \
				--limit 500 2>/dev/null || echo "0")
			closed_unmerged_count=$(( closed_unmerged_count + ${cu:-0} ))
		done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only != true)) | .slug' "$repos_file" 2>/dev/null)
	fi
	local metrics_file="${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl"
	if [[ -f "$metrics_file" ]]; then
		killed_count=$(METRICS_PATH="$metrics_file" EPOCH="$window_epoch" \
			python3 - 2>/dev/null <<'PY'
import json, os
metrics_path = os.environ["METRICS_PATH"]
epoch = int(os.environ["EPOCH"])
count = 0
with open(metrics_path) as f:
    for line in f:
        try:
            d = json.loads(line)
            if d.get("ts", 0) >= epoch and d.get("exit_code") == 124:
                count += 1
        except Exception:
            pass
print(count)
PY
		)
		killed_count="${killed_count:-0}"
	fi
	local total_count=$(( merged_count + closed_unmerged_count + killed_count ))
	local rate_display
	if [[ "$total_count" -lt 5 ]]; then
		rate_display="—"
	else
		local rate_int=$(( 100 * merged_count / total_count ))
		rate_display="${rate_int}% (${merged_count}/${total_count})"
	fi
	printf '%d\t%d\t%s\n' "$merged_count" "$total_count" "$rate_display"
	return 0
}

#######################################
# Build the health issue body markdown.
#
# Arguments: 34 positional parameters (see inline locals below)
# Output: body markdown to stdout
#######################################
_build_health_issue_body() {
	local now_iso="$1"
	local role_display="$2"
	local runner_user="$3"
	local repo_slug="$4"
	local pr_count="$5"
	local assigned_issue_count="$6"
	local total_issue_count="$7"
	local worker_count="$8"
	local max_workers="$9"
	local wt_count="${10}"
	local session_count="${11}"
	local session_warning="${12}"
	local prs_md="${13}" workers_md="${14}"
	local person_stats_md="${15}" cross_repo_person_stats_md="${16}"
	local session_time_md="${17}" cross_repo_session_time_md="${18}"
	local activity_md="${19}" cross_repo_md="${20}"
	local sys_load_ratio="${21}" sys_cpu_cores="${22}" sys_load_1m="${23}" sys_load_5m="${24}"
	local sys_memory="${25}" sys_procs="${26}" runner_role="${27}"
	local worker_success_rate_24h="${28}" worker_success_rate_7d="${29}" worker_total_runs_24h="${30}" worker_total_runs_7d="${31}"
	local worker_zero_diagnostics_md="${32}"
	local canonical_identity="${33:-$runner_user}" identity_aliases="${34:-$runner_user}"
	local _worker_rate_section; _worker_rate_section=$(_format_worker_rate_section "$worker_success_rate_24h" "$worker_success_rate_7d" "$worker_total_runs_24h" "$worker_total_runs_7d")
	local identity_aliases_display; identity_aliases_display=$(printf '%s\n' "$identity_aliases" | paste -sd ', ' -)

	cat <<BODY
## Queue Health Dashboard

**Last pulse**: \`${now_iso}\`
**${role_display}**: \`${runner_user}\` (canonical: \`${canonical_identity}\`; aliases: \`${identity_aliases_display}\`)
**Repo**: \`${repo_slug}\`

<!-- aidevops:dashboard-freshness -->
last_refresh: ${now_iso}

### Summary

| Metric | Count |
| --- | --- |
| Open PRs | ${pr_count} |
| Assigned Issues | ${assigned_issue_count} |
| Total Issues | ${total_issue_count} |
| Active Workers | ${worker_count} |
| Max Workers | ${max_workers} |
| Worktrees | ${wt_count} |
| Interactive Sessions | ${session_count}${session_warning} |

### Open PRs

${prs_md}

### Active Workers

${workers_md}

### Worker Dispatch Diagnostics

${worker_zero_diagnostics_md}

### Worker Success Rate

${_worker_rate_section}

### GitHub activity on this project (last 30 days)

${person_stats_md:-_Person stats unavailable._}

### GitHub activity on all projects (last 30 days)

${cross_repo_person_stats_md:-_Cross-repo person stats unavailable._}

### Work with AI sessions on this project (${runner_user})

${session_time_md}

### Work with AI sessions on all projects (${runner_user})

${cross_repo_session_time_md:-_Single repo or cross-repo session data unavailable._}

### Commits to this project (last 30 days)

${activity_md}

### Commits to all projects (last 30 days)

${cross_repo_md:-_Single repo or cross-repo data unavailable._}

### System Resources

| Metric | Value |
| --- | --- |
| CPU | ${sys_load_ratio}% used (${sys_cpu_cores} cores, load: ${sys_load_1m}/${sys_load_5m}) |
| Memory | ${sys_memory} |
| Processes | ${sys_procs} |

---
_Auto-updated by ${runner_role} stats process. Do not edit manually._
BODY
	return 0
}

#######################################
# Update the health issue title if the stats have changed.
#
# Arguments:
#   $1 - health_issue_number
#   $2 - repo_slug
#   $3 - runner_prefix
#   $4 - pr_count
#   $5 - assigned_issue_count
#   $6 - worker_count
#   $7 - snapshot timestamp (ISO8601 UTC)
#######################################
_update_health_issue_title() {
	local health_issue_number="$1"
	local repo_slug="$2"
	local runner_prefix="$3"
	local pr_count="$4"
	local assigned_issue_count="$5"
	local worker_count="$6"
	local snapshot_iso="$7"

	local pr_label="open PRs"
	[[ "${pr_count:-0}" -eq 1 ]] && pr_label="open PR"
	local issue_label="issues assigned"
	[[ "${assigned_issue_count:-0}" -eq 1 ]] && issue_label="issue assigned"
	local worker_label="local workers"
	[[ "${worker_count:-0}" -eq 1 ]] && worker_label="local worker"

	local title_parts="${pr_count} ${pr_label}, ${assigned_issue_count} ${issue_label}, ${worker_count} ${worker_label}"
	local title_time="${snapshot_iso%:*}"
	title_time="${title_time/T/ }"
	if [[ ! "$title_time" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}$ ]]; then
		title_time=$(date -u +"%Y-%m-%d %H:%M")
	fi
	local title_stats="${runner_prefix} ${title_parts}"
	local health_title="${title_stats} — changed ${title_time} UTC"

	local current_title=""
	local view_output
	view_output=$(gh_issue_view "$health_issue_number" --repo "$repo_slug" --json title --jq '.title' 2>&1)
	local view_exit_code=$?
	if [[ $view_exit_code -eq 0 ]]; then
		current_title="$view_output"
	else
		echo "[stats] Health issue: failed to view title for #${health_issue_number}: ${view_output}" >>"$LOGFILE"
	fi

	local current_stats="${current_title%% — changed *}"
	current_stats="${current_stats% at [0-9][0-9]:[0-9][0-9] UTC}"
	if [[ "$current_stats" != "$title_stats" ]]; then
		local title_edit_stderr
		title_edit_stderr=$(gh_issue_edit_safe "$health_issue_number" --repo "$repo_slug" --title "$health_title" 2>&1 >/dev/null)
		local title_edit_exit_code=$?
		if [[ $title_edit_exit_code -ne 0 ]]; then
			echo "[stats] Health issue: failed to update title for #${health_issue_number}: ${title_edit_stderr}" >>"$LOGFILE"
		fi
	fi

	return 0
}

#######################################
# Gather commit activity markdown for a single repo.
#
# Arguments:
#   $1 - repo path
#   $2 - slug_safe (slug with / replaced by -)
# Output: activity_md to stdout
#######################################
_gather_activity_stats_for_repo() {
	local repo_path="$1"
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		timeout_sec "$STATS_HEALTH_ACTIVITY_TIMEOUT" bash "$activity_helper" summary "$repo_path" --period month --format markdown || echo "_Activity data unavailable._"
	else
		echo "_Activity helper not installed._"
	fi
	return 0
}

#######################################
# Gather session-time markdown for a single repo.
#
# Arguments:
#   $1 - repo path
# Output: session_time_md to stdout
#######################################
_gather_session_time_for_repo() {
	local repo_path="$1"
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		timeout_sec "$STATS_HEALTH_ACTIVITY_TIMEOUT" bash "$activity_helper" session-time "$repo_path" --period all --format markdown || echo "_Session data unavailable._"
	else
		echo "_Activity helper not installed._"
	fi
	return 0
}

#######################################
# Read person-stats from the hourly cache for a repo.
#
# Arguments:
#   $1 - slug_safe (slug with / replaced by -)
# Output: person_stats_md to stdout
#######################################
_read_person_stats_cache() {
	local slug_safe="$1"
	local ps_cache="${PERSON_STATS_CACHE_DIR}/person-stats-cache-${slug_safe}.md"
	if [[ -f "$ps_cache" ]]; then
		local contributor issues prs merged commented remainder
		local data_rows=0
		local all_zero=true
		while IFS='|' read -r remainder contributor issues prs merged commented remainder; do
			issues="${issues//[[:space:]]/}"
			prs="${prs//[[:space:]]/}"
			merged="${merged//[[:space:]]/}"
			commented="${commented//[[:space:]]/}"
			if [[ "$issues" =~ ^[0-9]+$ && "$prs" =~ ^[0-9]+$ && "$merged" =~ ^[0-9]+$ && "$commented" =~ ^[0-9]+$ ]]; then
				data_rows=$((data_rows + 1))
				if [[ $((issues + prs + merged + commented)) -ne 0 ]]; then
					all_zero=false
				fi
			fi
		done <"$ps_cache"
		if [[ "$data_rows" -gt 0 && "$all_zero" == "true" ]]; then
			echo "_GitHub activity unavailable — cached all-zero data predates collection-status diagnostics; refresh pending._"
		else
			cat "$ps_cache"
		fi
	else
		echo "_Person stats not yet cached._"
	fi
	return 0
}

#######################################
# Gather all stats and assemble the health issue body markdown.
#
# Arguments:
#   $1  - repo_slug
#   $2  - repo_path
#   $3  - runner_user
#   $4  - slug_safe
#   $5  - now_iso
#   $6  - role_display
#   $7  - runner_role
#   $8  - cross_repo_md
#   $9  - cross_repo_session_time_md
#   $10 - cross_repo_person_stats_md
#   $11 - canonical identity
#   $12 - identity aliases (newline-delimited)
# Output: body markdown to stdout
#######################################
_assemble_health_issue_body() {
	local repo_slug="$1"
	local repo_path="$2"
	local runner_user="$3"
	local slug_safe="$4"
	local now_iso="$5"
	local role_display="$6"
	local runner_role="$7"
	local cross_repo_md="$8"
	local cross_repo_session_time_md="$9"
	local cross_repo_person_stats_md="${10}"
	local canonical_identity="${11:-$runner_user}"
	local identity_aliases="${12:-$runner_user}"

	# Gather live stats via temp file (avoids subshell variable loss)
	local stats_tmp
	stats_tmp=$(mktemp)
	_gather_health_stats "$repo_slug" "$repo_path" "$runner_user" >"$stats_tmp"

	local pr_count prs_md assigned_issue_count total_issue_count
	local workers_md worker_count sys_load_ratio sys_cpu_cores
	local sys_load_1m sys_load_5m sys_memory sys_procs
	local wt_count max_workers session_count session_warning worker_zero_diagnostics_md
	local stats_field
	local -a stats_fields=()
	while IFS= read -r -d '' stats_field; do
		stats_fields+=("$stats_field")
	done <"$stats_tmp"

	pr_count="${stats_fields[0]:-0}"
	prs_md="${stats_fields[1]:-_No open PRs_}"
	assigned_issue_count="${stats_fields[2]:-0}"
	total_issue_count="${stats_fields[3]:-0}"
	workers_md="${stats_fields[4]:-_No active workers_}"
	worker_count="${stats_fields[5]:-0}"
	sys_load_ratio="${stats_fields[6]:-0}"
	sys_cpu_cores="${stats_fields[7]:-0}"
	sys_load_1m="${stats_fields[8]:-0.00}"
	sys_load_5m="${stats_fields[9]:-0.00}"
	sys_memory="${stats_fields[10]:-unknown}"
	sys_procs="${stats_fields[11]:-0}"
	wt_count="${stats_fields[12]:-0}"
	max_workers="${stats_fields[13]:-?}"
	session_count="${stats_fields[14]:-0}"
	session_warning="${stats_fields[15]:-}"
	worker_zero_diagnostics_md="${stats_fields[16]:-_Workers are active; zero-worker diagnostics not needed._}"
	rm -f "$stats_tmp"

	local activity_md session_time_md person_stats_md
	activity_md=$(_gather_activity_stats_for_repo "$repo_path" "$slug_safe")
	session_time_md=$(_gather_session_time_for_repo "$repo_path")
	person_stats_md=$(_read_person_stats_cache "$slug_safe")

	local sr24h_raw sr7d_raw
	sr24h_raw=$(_compute_worker_success_rates "$runner_user" "24")
	sr7d_raw=$(_compute_worker_success_rates "$runner_user" "168")
	local worker_success_rate_24h worker_total_runs_24h
	worker_success_rate_24h=$(printf '%s' "$sr24h_raw" | cut -f3)
	worker_total_runs_24h=$(printf '%s' "$sr24h_raw" | cut -f2)
	local worker_success_rate_7d worker_total_runs_7d
	worker_success_rate_7d=$(printf '%s' "$sr7d_raw" | cut -f3)
	worker_total_runs_7d=$(printf '%s' "$sr7d_raw" | cut -f2)

	_build_health_issue_body \
		"$now_iso" "$role_display" "$runner_user" "$repo_slug" \
		"$pr_count" "$assigned_issue_count" "$total_issue_count" \
		"$worker_count" "$max_workers" "$wt_count" \
		"$session_count" "$session_warning" \
		"$prs_md" "$workers_md" \
		"$person_stats_md" "$cross_repo_person_stats_md" \
		"$session_time_md" "$cross_repo_session_time_md" \
		"$activity_md" "$cross_repo_md" \
		"$sys_load_ratio" "$sys_cpu_cores" "$sys_load_1m" "$sys_load_5m" \
		"$sys_memory" "$sys_procs" "$runner_role" \
		"$worker_success_rate_24h" "$worker_success_rate_7d" \
		"$worker_total_runs_24h" "$worker_total_runs_7d" \
		"$worker_zero_diagnostics_md" "$canonical_identity" "$identity_aliases"
	return 0
}

#######################################
# Extract headline counts from a rendered health issue body.
#
# Arguments:
#   $1 - body (multiline markdown string)
# Output: "pr_count|assigned_issue_count|worker_count"
#######################################
_extract_body_counts() {
	local body="$1"

	local pr_count=0
	local assigned_issue_count=0
	local worker_count=0

	local body_line
	while IFS= read -r body_line; do
		if [[ "$body_line" =~ ^\|\ Open\ PRs\ \|\ ([0-9]+)\ \|$ ]]; then
			pr_count="${BASH_REMATCH[1]}"
		elif [[ "$body_line" =~ ^\|\ Assigned\ Issues\ \|\ ([0-9]+)\ \|$ ]]; then
			assigned_issue_count="${BASH_REMATCH[1]}"
		elif [[ "$body_line" =~ ^\|\ Active\ Workers\ \|\ ([0-9]+)\ \|$ ]]; then
			worker_count="${BASH_REMATCH[1]}"
		fi
	done <<<"$body"

	printf '%s|%s|%s' "$pr_count" "$assigned_issue_count" "$worker_count"
	return 0
}

#######################################
# Refresh person-stats cache (t1426)
#
# Runs at most once per PERSON_STATS_INTERVAL (default 1h).
# Computes per-repo and cross-repo person-stats, writes markdown
# to cache files. Health issue updates read from cache.
#######################################
_refresh_person_stats_cache() {
	if [[ -f "$PERSON_STATS_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$PERSON_STATS_LAST_RUN" 2>/dev/null || echo "0")
		last_run="${last_run//[^0-9]/}"
		last_run="${last_run:-0}"
		local now
		now=$(date +%s)
		if [[ $((now - last_run)) -lt "$PERSON_STATS_INTERVAL" ]]; then
			return 0
		fi
	fi

	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	[[ -x "$activity_helper" ]] || return 0

	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	mkdir -p "$PERSON_STATS_CACHE_DIR"

	local search_remaining
	search_remaining=$(_stats_health_person_stats_search_remaining)

	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || echo "")

	local repo_count=0
	local search_api_cost_per_contributor=4
	local partial_exit="$STATS_HEALTH_EX_PARTIAL"
	local refreshed_any=false
	while IFS='|' read -r _slug _path; do
		[[ -z "$_slug" ]] && continue
		repo_count=$((repo_count + 1))
	done <<<"$repo_entries"

	local min_budget_needed=$((repo_count * search_api_cost_per_contributor))
	if [[ "$search_remaining" -lt "$min_budget_needed" ]]; then
		echo "[stats] Person stats cache refresh skipped: Search API budget ${search_remaining} < estimated cost ${min_budget_needed} (${repo_count} repos × ${search_api_cost_per_contributor} queries/contributor)" >>"$LOGFILE"
		return 0
	fi

	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue

		search_remaining=$(_stats_health_person_stats_search_remaining)
		if [[ "$search_remaining" -lt "$search_api_cost_per_contributor" ]]; then
			echo "[stats] Person stats cache refresh stopped mid-run: Search API budget exhausted (${search_remaining} remaining)" >>"$LOGFILE"
			break
		fi

		local slug_safe="${slug//\//-}"
		local cache_file="${PERSON_STATS_CACHE_DIR}/person-stats-cache-${slug_safe}.md"
		local md md_rc
		md_rc=0
		md=$(timeout_sec "$STATS_HEALTH_PERSON_STATS_TIMEOUT" bash "$activity_helper" person-stats "$path" --period month --format markdown 2>/dev/null) || md_rc=$?
		if [[ -n "$md" && ( "$md_rc" -eq 0 || "$md_rc" -eq "$partial_exit" ) ]]; then
			echo "$md" >"$cache_file"
			refreshed_any=true
		elif [[ "$md_rc" -ne 0 ]]; then
			echo "[stats] Person stats cache refresh failed for ${slug}: helper exited ${md_rc}" >>"$LOGFILE"
		fi
	done <<<"$repo_entries"

	# Cross-repo person-stats
	search_remaining=$(_stats_health_person_stats_search_remaining)
	local all_repo_paths
	all_repo_paths=$(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false) | .path' "$repos_json" 2>/dev/null || echo "")
	if [[ -n "$all_repo_paths" && "$search_remaining" -ge "$search_api_cost_per_contributor" ]]; then
		local -a cross_args=()
		while IFS= read -r rp; do
			[[ -n "$rp" ]] && cross_args+=("$rp")
		done <<<"$all_repo_paths"
		if [[ ${#cross_args[@]} -gt 1 ]]; then
			local cross_md cross_rc
			cross_rc=0
			cross_md=$(timeout_sec "$STATS_HEALTH_PERSON_STATS_TIMEOUT" bash "$activity_helper" cross-repo-person-stats "${cross_args[@]}" --period month --format markdown 2>/dev/null) || cross_rc=$?
			if [[ -n "$cross_md" && ( "$cross_rc" -eq 0 || "$cross_rc" -eq "$partial_exit" ) ]]; then
				echo "$cross_md" >"${PERSON_STATS_CACHE_DIR}/person-stats-cache-cross-repo.md"
				refreshed_any=true
			elif [[ "$cross_rc" -ne 0 ]]; then
				echo "[stats] Cross-repo person stats cache refresh failed: helper exited ${cross_rc}" >>"$LOGFILE"
			fi
		fi
	fi

	if [[ "$refreshed_any" == "true" ]]; then
		date +%s >"$PERSON_STATS_LAST_RUN"
		echo "[stats] Person stats cache refreshed" >>"$LOGFILE"
	else
		echo "[stats] Person stats cache refresh produced no successful outputs; last-run marker not updated" >>"$LOGFILE"
	fi
	return 0
}
