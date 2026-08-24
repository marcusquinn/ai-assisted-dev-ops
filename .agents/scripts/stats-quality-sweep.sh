#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Quality Sweep -- Orchestrator
# =============================================================================
# Daily code quality sweep orchestrator. Sources sub-libraries for individual
# tool integrations and issue management, and retains the entry point plus
# functions >100 lines (to preserve function-complexity identity keys).
#
# Extracted from the original monolithic stats-quality-sweep.sh:
#   - stats-quality-sweep-tools.sh   -- per-tool sweep functions
#   - stats-quality-sweep-issues.sh  -- quality issue management functions
#   - stats-quality-sweep-coverage.sh -- bot coverage + badge functions
#
# This module is sourced by stats-functions.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all stats-* configuration constants in the bootstrap
# section of stats-functions.sh.
#
# Dependencies on other stats modules:
#   - none (zero inter-cluster edges from C to A or B)
#
# Globals read:
#   - LOGFILE, REPOS_JSON, QUALITY_SWEEP_INTERVAL, QUALITY_SWEEP_LAST_RUN
#   - QUALITY_SWEEP_STATE_DIR, CODERABBIT_ISSUE_SPIKE
#   - Environment overrides: QUALITY_SWEEP_OFFPEAK, QUALITY_SWEEP_PEAK_START,
#     QUALITY_SWEEP_PEAK_END, STATS_DRY_RUN
# Globals written:
#   - none (state written to disk under ~/.aidevops/logs/)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_QUALITY_SWEEP_LOADED:-}" ]] && return 0
_STATS_QUALITY_SWEEP_LOADED=1

# Defensive SCRIPT_DIR fallback — avoids external binary dependency
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Source sub-libraries ---

# shellcheck source=./stats-quality-sweep-coverage.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-quality-sweep-coverage.sh"

# shellcheck source=./stats-quality-sweep-tools.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-quality-sweep-tools.sh"

# shellcheck source=./stats-quality-sweep-issues.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-quality-sweep-issues.sh"

if ! declare -F _gh_current_user_allows_repo_write >/dev/null 2>&1; then
	if [[ -f "${SCRIPT_DIR}/shared-gh-collaborator-permission.sh" ]]; then
		# shellcheck source=./shared-gh-collaborator-permission.sh
		# shellcheck disable=SC1091  # shared helper resolved at runtime via $SCRIPT_DIR
		source "${SCRIPT_DIR}/shared-gh-collaborator-permission.sh"
	fi
fi

# --- Orchestrator functions ---

#######################################
# Daily Code Quality Sweep
#
# Runs once per 24h (guarded by timestamp file). For each pulse-enabled
# repo, ensures a persistent "Daily Code Quality Review" issue exists,
# then runs available quality tools and upserts a rolling summary comment.
#
# Tools checked (in order):
#   1. ShellCheck — local, always available for repos with .sh files
#   2. Qlty CLI — local, if installed (~/.qlty/bin/qlty)
#   3. CodeRabbit — via @coderabbitai mention on the persistent issue
#   4. Codacy — via API if CODACY_API_TOKEN available
#   5. SonarCloud — via API if sonar-project.properties exists
#
# The sweep creates function-complexity-debt issues directly (with
# source:quality-sweep label). The pulse LLM dispatches these as normal
# work — it should NOT independently create issues for the same findings.
# See GH#10308 for the sweep-pulse dedup contract.
#######################################
run_daily_quality_sweep() {
	# t2044 Phase 0: dry-run sentinel. When STATS_DRY_RUN=1, return immediately
	# to exercise the call graph without making gh/git API calls. Temporary
	# scaffolding — removed after Phase 3 merges.
	if [[ "${STATS_DRY_RUN:-}" == "1" ]]; then
		echo "[stats] run_daily_quality_sweep: dry-run, skipping" >>"$LOGFILE"
		return 0
	fi
	# Time-of-day gate — only run during Anthropic's 2x usage boost hours.
	# Claude doubles usage allowance outside peak: for UK/GMT that's 18:00-11:59
	# (standard 1x is only 12:00-17:59). Weekends are 2x all day, all timezones.
	# Reference: https://claude.ai — "Claude 2x usage boost" schedule.
	# Peak hours by timezone (standard 1x only):
	#   Pacific PT:  05:00-10:59    UK GMT:     12:00-17:59
	#   Eastern ET:  08:00-13:59    CET:        13:00-18:59
	# Quality sweep findings trigger LLM worker dispatch via the pulse, so
	# landing findings in the 2x window means workers also run at boosted rates.
	# Override: QUALITY_SWEEP_OFFPEAK=0
	local current_hour current_dow
	current_hour=$(date +%H)
	current_dow=$(date +%u) # 1=Monday, 7=Sunday
	# Weekends (Sat=6, Sun=7) are 2x all day — always run
	if [[ "${QUALITY_SWEEP_OFFPEAK:-1}" == "1" ]] && ((current_dow < 6)); then
		# Weekday: defer during peak hours only (12:00-17:59 UK/GMT).
		# Users in other timezones can override via QUALITY_SWEEP_PEAK_START
		# and QUALITY_SWEEP_PEAK_END environment variables.
		local peak_start peak_end
		peak_start="${QUALITY_SWEEP_PEAK_START:-12}"
		peak_end="${QUALITY_SWEEP_PEAK_END:-18}"
		if ((10#$current_hour >= 10#$peak_start && 10#$current_hour < 10#$peak_end)); then
			echo "[stats] Quality sweep deferred: hour ${current_hour} is peak (${peak_start}:00-$((peak_end - 1)):59), 2x boost inactive" >>"$LOGFILE"
			return 0
		fi
	fi

	# Timestamp guard — run at most once per QUALITY_SWEEP_INTERVAL
	if [[ -f "$QUALITY_SWEEP_LAST_RUN" ]]; then
		local last_run
		last_run=$(cat "$QUALITY_SWEEP_LAST_RUN" || echo "0")
		# Strip whitespace/newlines and validate integer (t1397)
		last_run="${last_run//[^0-9]/}"
		last_run="${last_run:-0}"
		local now
		now=$(date +%s)
		local elapsed=$((now - last_run))
		if [[ "$elapsed" -lt "$QUALITY_SWEEP_INTERVAL" ]]; then
			return 0
		fi
	fi

	command -v gh &>/dev/null || return 0
	gh auth status &>/dev/null 2>&1 || return 0

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || echo "")

	if [[ -z "$repo_entries" ]]; then
		return 0
	fi

	local routine_runner_user
	routine_runner_user=$(aidevops_repo_state_current_user)
	if [[ -z "$routine_runner_user" ]]; then
		echo "[stats] Quality sweep skipped: could not resolve authenticated GitHub user" >>"$LOGFILE"
		return 0
	fi

	echo "[stats] Starting daily code quality sweep..." >>"$LOGFILE"

	local swept=0
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		[[ ! -d "$path" ]] && continue
		if ! aidevops_can_run_repo_routines "$slug" "$routine_runner_user"; then
			echo "[stats] Quality sweep skipped for ${slug}: ${routine_runner_user} is not maintainer-equivalent" >>"$LOGFILE"
			continue
		fi
		_quality_sweep_for_repo "$slug" "$path" || true
		swept=$((swept + 1))
	done <<<"$repo_entries"

	# Update timestamp
	date +%s >"$QUALITY_SWEEP_LAST_RUN"

	echo "[stats] Quality sweep complete: $swept repo(s) swept" >>"$LOGFILE"
	return 0
}

#######################################
# Verify that Qlty scanned the live remote default tip before creating issues.
# The dashboard may still report a scan from a lagging service checkout, but
# remediation issues must not claim that stale findings exist on the current
# default branch.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - scanned repo path
#######################################
_qlty_scan_matches_remote_default() {
	local repo_slug="$1"
	local repo_path="$2"
	local logfile="${LOGFILE:-/dev/null}"
	local local_head
	local remote_head
	local worktree_state

	if ! local_head=$(git -C "$repo_path" rev-parse --verify HEAD 2>/dev/null); then
		printf '[stats] Qlty remediation: cannot resolve scanned HEAD for %s; skipping issue creation\n' \
			"$repo_slug" >>"$logfile"
		return 1
	fi
	if ! worktree_state=$(git -C "$repo_path" status --porcelain --untracked-files=normal 2>/dev/null); then
		printf '[stats] Qlty remediation: cannot inspect scanned checkout for %s; skipping issue creation\n' \
			"$repo_slug" >>"$logfile"
		return 1
	fi
	if [[ -n "$worktree_state" ]]; then
		printf '[stats] Qlty remediation: scanned checkout has local changes for %s; skipping uncommitted scan\n' \
			"$repo_slug" >>"$logfile"
		return 1
	fi
	if ! remote_head=$(gh api "repos/${repo_slug}/commits/HEAD" --jq '.sha // empty' 2>/dev/null); then
		printf '[stats] Qlty remediation: cannot resolve remote default HEAD for %s; skipping issue creation\n' \
			"$repo_slug" >>"$logfile"
		return 1
	fi
	remote_head="${remote_head%%$'\n'*}"
	if [[ -z "$remote_head" || "$local_head" != "$remote_head" ]]; then
		printf '[stats] Qlty remediation: scanned HEAD %s does not match remote default %s for %s; skipping stale scan\n' \
			"${local_head:0:12}" "${remote_head:0:12}" "$repo_slug" >>"$logfile"
		return 1
	fi
	return 0
}

#######################################
# Run Qlty CLI analysis on a repo.
#
# t2066: local SARIF smell count is the PRIMARY grade source. The Qlty Cloud
# badge is fetched best-effort as secondary telemetry and appended to the
# section only when it disagrees with the local grade (so the dashboard
# surfaces the divergence when it exists, but does not pollute the common
# case where they agree). The cloud badge is NEVER used as the primary grade
# — it has been observed 404'ing in production, leaving the dashboard
# reporting "Qlty grade UNKNOWN" while the local SARIF had the exact count
# in hand.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Sets caller variables via stdout (pipe-delimited):
#   qlty_section|qlty_smell_count|qlty_grade
# where qlty_grade is the LOCAL-COMPUTED grade.
#######################################
_sweep_qlty() {
	local repo_slug="$1"
	local repo_path="$2"

	local qlty_bin="${HOME}/.qlty/bin/qlty"
	if [[ ! -x "$qlty_bin" ]] || [[ ! -f "${repo_path}/.qlty/qlty.toml" && ! -f "${repo_path}/.qlty.toml" ]]; then
		printf '%s|%s|%s' "" "0" "UNKNOWN"
		return 0
	fi

	# Use a bounded identity consensus so telemetry and remediation cannot consume
	# a transient cache result as an authoritative count.
	local qlty_sarif
	qlty_sarif=$(_qlty_consensus_sarif "$qlty_bin" "$repo_path") || qlty_sarif=""

	local qlty_result
	qlty_result=$(_build_qlty_section_from_sarif "$qlty_sarif")
	local qlty_section="${qlty_result%%|*}"
	local qlty_remainder="${qlty_result#*|}"
	local qlty_smell_count="${qlty_remainder%%|*}"
	local qlty_grade="${qlty_remainder#*|}"

	qlty_section=$(_append_qlty_cloud_grade_if_divergent "$repo_slug" "$qlty_grade" "$qlty_section")

	# --- 2b. Autonomous Qlty remediation bridge ---
	# When repository-wide debt exceeds the configured absolute threshold, create
	# bounded, per-file remediation issues from this same SARIF scan. The pulse
	# handles dispatch deduplication, worker capacity, and active-PR collisions.
	if [[ -n "$qlty_sarif" && "$qlty_smell_count" =~ ^[0-9]+$ && "$qlty_smell_count" -gt 0 ]] &&
		_qlty_scan_matches_remote_default "$repo_slug" "$repo_path"; then
		local qlty_smell_threshold
		qlty_smell_threshold=$(_repo_qlty_smell_threshold "$repo_path")
		local issues_created
		issues_created=$(_create_simplification_issues "$repo_slug" "$qlty_sarif" "$qlty_smell_threshold")
		if [[ -n "$issues_created" && "$issues_created" -gt 0 ]]; then
			qlty_section="${qlty_section}
_Scheduled ${issues_created} autonomous Qlty remediation issue(s) (tier:thinking)._
"
		fi
	fi

	printf '%s|%s|%s' "$qlty_section" "$qlty_smell_count" "$qlty_grade"
	return 0
}

_qlty_normalized_identities() {
	local qlty_sarif="$1"
	printf '%s\n' "$qlty_sarif" | jq -r '
		.runs[0].results[] |
		[(.ruleId // "unknown"),
		 ([.locations[]?.physicalLocation?.artifactLocation?.uri? | select(. != null)] | sort | join("|"))]
		| @tsv' 2>/dev/null | LC_ALL=C sort
	return 0
}

_qlty_valid_sarif() {
	local qlty_sarif="$1"
	[[ -n "${qlty_sarif//[[:space:]]/}" ]] || return 1
	printf '%s\n' "$qlty_sarif" | jq -e '.runs[0].results | type == "array"' >/dev/null 2>&1
	return $?
}

_qlty_consensus_diagnostic() {
	local reason="$1"
	local repo_path="$2"
	local qlty_bin="$3"
	local attempts="$4"
	local version="unknown"
	local commit="unknown"
	local tree="unknown"
	local config_hash="none"
	local ignore_hash="none"
	version=$("$qlty_bin" --version 2>/dev/null) || version="unknown"
	commit=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null) || commit="unknown"
	tree=$(git -C "$repo_path" rev-parse 'HEAD^{tree}' 2>/dev/null) || tree="unknown"
	if [[ -f "${repo_path}/.qlty/qlty.toml" ]]; then
		config_hash=$(git -C "$repo_path" hash-object '.qlty/qlty.toml' 2>/dev/null) || config_hash="unknown"
	fi
	if [[ -f "${repo_path}/.qltyignore" ]]; then
		ignore_hash=$(git -C "$repo_path" hash-object '.qltyignore' 2>/dev/null) || ignore_hash="unknown"
	fi
	printf '[stats] Qlty telemetry INCONCLUSIVE: %s; version=%s commit=%s tree=%s mode=repository-root cwd=repository-root command="qlty smells --all --sarif --no-snippets --quiet" cache=isolated-per-run config=%s ignore=%s attempts=%s\n' \
		"$reason" "$version" "$commit" "$tree" "$config_hash" "$ignore_hash" "$attempts" >>"${LOGFILE:-/dev/null}"
	return 0
}

_qlty_consensus_sarif() {
	local qlty_bin="$1"
	local repo_path="$2"
	local cache_dir=""
	local first=""
	local second=""
	local third=""
	local first_rc=0
	local second_rc=0
	local third_rc=0
	local first_count="unknown"
	local second_count="unknown"
	local third_count="unknown"
	cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/qlty-sweep-cache.XXXXXX") || return 1
	first=$(CDPATH='' cd -- "$repo_path" && XDG_CACHE_HOME="$cache_dir" "$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || first_rc=$?
	second=$(CDPATH='' cd -- "$repo_path" && XDG_CACHE_HOME="$cache_dir" "$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || second_rc=$?
	if _qlty_valid_sarif "$first"; then
		first_count=$(printf '%s\n' "$first" | jq -r '.runs[0].results | length')
	fi
	if _qlty_valid_sarif "$second"; then
		second_count=$(printf '%s\n' "$second" | jq -r '.runs[0].results | length')
	fi
	if ! _qlty_valid_sarif "$first" || ! _qlty_valid_sarif "$second"; then
		_qlty_consensus_diagnostic "empty or invalid SARIF" "$repo_path" "$qlty_bin" \
			"1:rc=${first_rc},count=${first_count};2:rc=${second_rc},count=${second_count}"
		rm -rf "$cache_dir"
		return 1
	fi
	if [[ "$(_qlty_normalized_identities "$first")" == "$(_qlty_normalized_identities "$second")" ]]; then
		printf '%s' "$second"
		rm -rf "$cache_dir"
		return 0
	fi
	third=$(CDPATH='' cd -- "$repo_path" && XDG_CACHE_HOME="$cache_dir" "$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || third_rc=$?
	if _qlty_valid_sarif "$third"; then
		third_count=$(printf '%s\n' "$third" | jq -r '.runs[0].results | length')
	fi
	if ! _qlty_valid_sarif "$third"; then
		_qlty_consensus_diagnostic "invalid third SARIF" "$repo_path" "$qlty_bin" \
			"1:rc=${first_rc},count=${first_count};2:rc=${second_rc},count=${second_count};3:rc=${third_rc},count=${third_count}"
		rm -rf "$cache_dir"
		return 1
	fi
	if [[ "$(_qlty_normalized_identities "$first")" == "$(_qlty_normalized_identities "$third")" ||
		"$(_qlty_normalized_identities "$second")" == "$(_qlty_normalized_identities "$third")" ]]; then
		printf '%s' "$third"
		rm -rf "$cache_dir"
		return 0
	fi
	_qlty_consensus_diagnostic "unstable normalized identities" "$repo_path" "$qlty_bin" \
		"1:rc=${first_rc},count=${first_count};2:rc=${second_rc},count=${second_count};3:rc=${third_rc},count=${third_count}"
	rm -rf "$cache_dir"
	return 1
}

_build_qlty_section_from_sarif() {
	local qlty_sarif="$1"

	if [[ -z "$qlty_sarif" ]] || ! echo "$qlty_sarif" | jq -e '.runs' &>/dev/null; then
		printf '%s|%s|%s' "### Qlty Maintainability

_Qlty analysis returned empty or failed to parse._
" "inconclusive" "UNKNOWN"
		return 0
	fi

	local qlty_data
	qlty_data=$(_extract_qlty_sarif_summary "$qlty_sarif")
	local qlty_smell_count="${qlty_data%%|*}"
	local qlty_remainder="${qlty_data#*|}"
	local qlty_rules_breakdown="${qlty_remainder%%|*}"
	local qlty_files_breakdown="${qlty_remainder#*|}"
	if [[ ! "$qlty_smell_count" =~ ^[0-9]+$ ]]; then
		printf '%s|%s|%s' "### Qlty Maintainability

_Qlty analysis was inconclusive; no numeric telemetry or remediation evidence was recorded._
" "inconclusive" "UNKNOWN"
		return 0
	fi
	qlty_rules_breakdown=$(_sanitize_markdown "$qlty_rules_breakdown")
	qlty_files_breakdown=$(_sanitize_markdown "$qlty_files_breakdown")

	local qlty_grade
	qlty_grade=$(_compute_qlty_grade_from_count "$qlty_smell_count")
	local qlty_section
	qlty_section=$(_format_qlty_section "$qlty_smell_count" "$qlty_grade" "$qlty_rules_breakdown" "$qlty_files_breakdown")
	printf '%s|%s|%s' "$qlty_section" "$qlty_smell_count" "$qlty_grade"
	return 0
}

_extract_qlty_sarif_summary() {
	local qlty_sarif="$1"

	echo "$qlty_sarif" | jq -r '
		(.runs[0].results | length) as $total |
		([.runs[0].results[] | .ruleId] | group_by(.) | map({rule: .[0], count: length}) | sort_by(-.count)[:8] |
			map("  - \(.rule): \(.count)") | join("\n")) as $rules |
		([.runs[0].results[] | .locations[0].physicalLocation.artifactLocation.uri] |
			group_by(.) | map({file: .[0], count: length}) | sort_by(-.count)[:10] |
			map("  - `\(.file)`: \(.count) smells") | join("\n")) as $files |
		"\($total)|\($rules)|\($files)"
	' || printf '%s' "inconclusive||"
	return 0
}

_format_qlty_section() {
	local qlty_smell_count="$1"
	local qlty_grade="$2"
	local qlty_rules_breakdown="$3"
	local qlty_files_breakdown="$4"

	if [[ "$qlty_smell_count" -eq 0 ]]; then
		printf '%s' "### Qlty Maintainability

- **Total smells**: 0
- **Grade (local, from count)**: ${qlty_grade}

_No smells detected — clean codebase._
"
		return 0
	fi

	printf '%s' "### Qlty Maintainability

- **Total smells**: ${qlty_smell_count}
- **Grade (local, from count)**: ${qlty_grade}
- **By rule (fix these for maximum grade improvement)**:
${qlty_rules_breakdown}
- **Top files (highest smell density)**:
${qlty_files_breakdown}
"
	return 0
}

_append_qlty_cloud_grade_if_divergent() {
	local repo_slug="$1"
	local qlty_grade="$2"
	local qlty_section="$3"
	local cloud_grade

	cloud_grade=$(_fetch_qlty_cloud_grade "$repo_slug")
	if [[ "$cloud_grade" != "UNKNOWN" && "$cloud_grade" != "$qlty_grade" ]]; then
		qlty_section="${qlty_section}
- **Qlty Cloud grade (telemetry, diverges from local)**: ${cloud_grade}
"
	fi
	printf '%s' "$qlty_section"
	return 0
}

_fetch_qlty_cloud_grade() {
	local repo_slug="$1"
	local badge_svg

	badge_svg=$(curl -sS --fail --connect-timeout 5 --max-time 10 \
		"https://qlty.sh/gh/${repo_slug}/maintainability.svg" 2>/dev/null) || badge_svg=""
	if [[ -z "$badge_svg" ]]; then
		printf '%s' "UNKNOWN"
		return 0
	fi

	python3 -c "
import sys, re
svg = sys.stdin.read()
colors = {'#22C55E':'A','#84CC16':'B','#EAB308':'C','#F97316':'D','#EF4444':'F'}
for c in re.findall(r'fill=\"(#[A-F0-9]+)\"', svg):
    if c in colors:
        print(colors[c])
        sys.exit(0)
print('UNKNOWN')
" <<<"$badge_svg" 2>/dev/null || printf '%s' "UNKNOWN"
	return 0
}

#######################################
# Run SonarCloud quality gate check for a repo.
#
# Arguments:
#   $1 - repo path
# Output: pipe-delimited
#   "sonar_section|sweep_gate_status|sweep_total_issues|sweep_high_critical|sweep_sev_inline"
# t2717: sweep_sev_inline is a single-line per-severity summary for the
# dashboard (e.g., "0 BLOCKER · 0 CRITICAL · 98 MAJOR · 196 MINOR · 0 INFO").
# Empty on early-return paths where no SonarCloud data was fetched.
#######################################
_sweep_sonarcloud() {
	local repo_path="$1"

	local sonar_section=""
	local sweep_gate_status="UNKNOWN"
	local sweep_total_issues=0
	local sweep_high_critical=0
	local sweep_sev_inline=""

	[[ -f "${repo_path}/sonar-project.properties" ]] || {
		printf '%s|%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$sweep_sev_inline"
		return 0
	}

	local project_key
	project_key=$(grep '^sonar.projectKey=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)
	local org_key
	org_key=$(grep '^sonar.organization=' "${repo_path}/sonar-project.properties" 2>/dev/null | cut -d= -f2)

	if [[ -z "$project_key" || -z "$org_key" ]]; then
		printf '%s|%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$sweep_sev_inline"
		return 0
	fi

	# URL-encode project_key to prevent injection via crafted sonar-project.properties
	local encoded_project_key
	encoded_project_key=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$project_key" 2>/dev/null) || encoded_project_key=""
	if [[ -z "$encoded_project_key" ]]; then
		echo "[stats] Failed to URL-encode project_key — skipping SonarCloud" >&2
		printf '%s|%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$sweep_sev_inline"
		return 0
	fi

	# SonarCloud public API — quality gate status
	local sonar_status=""
	sonar_status=$(curl -sS --fail --connect-timeout 5 --max-time 20 \
		"https://sonarcloud.io/api/qualitygates/project_status?projectKey=${encoded_project_key}" || echo "")

	if [[ -n "$sonar_status" ]] && echo "$sonar_status" | jq -e '.projectStatus' &>/dev/null; then
		# Single jq pass: extract gate status, conditions, and failing conditions with remediation
		local gate_data
		gate_data=$(echo "$sonar_status" | jq -r '
			(.projectStatus.status // "UNKNOWN") as $status |
			[.projectStatus.conditions[]? | "- **\(.metricKey)**: \(.actualValue) (\(.status))"] | join("\n") as $conds |
			"\($status)|\($conds)"
		') || gate_data="UNKNOWN|"
		local gate_status="${gate_data%%|*}"
		local conditions="${gate_data#*|}"
		# Sanitise API data before embedding in markdown comment
		gate_status=$(_sanitize_markdown "$gate_status")
		conditions=$(_sanitize_markdown "$conditions")
		sweep_gate_status="$gate_status"

		sonar_section="### SonarCloud Quality Gate

- **Status**: ${gate_status}
${conditions}
"
		# Badge-aware diagnostics: when the gate fails, identify the
		# specific failing conditions and provide actionable remediation.
		if [[ "$gate_status" == "ERROR" || "$gate_status" == "WARN" ]]; then
			sonar_section="${sonar_section}$(_sweep_sonarcloud_diagnostics "$sonar_status" "$encoded_project_key")"
		fi
	fi

	# Fetch open issues summary with rule-level breakdown for targeted fixes
	# t2717: parse the 4-field return (total|hc|sev_inline|md).
	local issues_section total_issues high_critical_count sev_inline
	issues_section=$(_sweep_sonarcloud_issues "$encoded_project_key")
	total_issues="${issues_section%%|*}"
	local issues_remainder="${issues_section#*|}"
	high_critical_count="${issues_remainder%%|*}"
	issues_remainder="${issues_remainder#*|}"
	sev_inline="${issues_remainder%%|*}"
	local issues_md="${issues_remainder#*|}"
	[[ "$total_issues" =~ ^[0-9]+$ ]] || total_issues=0
	[[ "$high_critical_count" =~ ^[0-9]+$ ]] || high_critical_count=0
	sweep_total_issues="$total_issues"
	sweep_high_critical="$high_critical_count"
	sweep_sev_inline="$sev_inline"
	if [[ -n "$issues_md" ]]; then
		sonar_section="${sonar_section}${issues_md}"
	fi

	printf '%s|%s|%s|%s|%s' "$sonar_section" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$sweep_sev_inline"
	return 0
}

#######################################
# Run all quality sweep tools for a repo and write results to a sections dir.
#
# t1992: Each section is written to its own temp file (one file per variable)
# so multi-line markdown sections survive the writer/reader round trip.
# The previous implementation used `printf '%s\n'` + `IFS= read -r` chains,
# which silently truncated every section after the first line — fragmenting
# the daily quality-sweep comment.
#
# Arguments:
#   $1 - repo slug
#   $2 - repo path
# Output (single line on stdout): the absolute path of the sections directory.
# Files written inside the sections directory (one file per variable):
#   - tool_count, shellcheck, qlty, qlty_smell_count, qlty_grade
#   - sonar, sweep_gate_status, sweep_total_issues, sweep_high_critical
#   - codacy, coderabbit, review_scan
# The caller is responsible for `rm -rf`ing the directory after consumption.
#######################################
_run_sweep_tools() {
	local repo_slug="$1"
	local repo_path="$2"

	local tool_count=0
	local sweep_gate_status="UNKNOWN"
	local sweep_total_issues=0
	local sweep_high_critical=0
	local sweep_sev_inline=""

	local prev_qlty_smells
	prev_qlty_smells=$(_previous_qlty_smell_count "$repo_slug")

	local shellcheck_section=""
	shellcheck_section=$(_sweep_shellcheck "$repo_slug" "$repo_path")
	[[ -n "$shellcheck_section" ]] && tool_count=$((tool_count + 1))

	local qlty_section="" qlty_smell_count=0 qlty_grade="UNKNOWN"
	local qlty_result
	qlty_result=$(_run_qlty_sweep_tool "$repo_slug" "$repo_path")
	qlty_section="${qlty_result%%|*}"
	local qlty_remainder="${qlty_result#*|}"
	qlty_smell_count="${qlty_remainder%%|*}"
	qlty_grade="${qlty_remainder#*|}"
	[[ -n "$qlty_section" ]] && tool_count=$((tool_count + 1))

	# t2066: compute smell delta vs previous sweep. Signed integer — positive
	# means regression (more smells), negative means improvement. The caller
	# renders the sign + trend arrow in the dashboard.
	local qlty_smell_delta=0
	if [[ "$qlty_smell_count" =~ ^[0-9]+$ ]]; then
		qlty_smell_delta=$((qlty_smell_count - prev_qlty_smells))
	fi

	# Parse _sweep_sonarcloud's 5-field pipe-separated return. sonar_section
	# is the only multi-line field, so strip it with ${..%%|*} (works on
	# newlines) and IFS-split the single-line remainder into the 4 scalars.
	# read(1) fills missing fields as empty, providing 4-field back-compat.
	local sonar_section=""
	local sonar_raw
	sonar_raw=$(_sweep_sonarcloud "$repo_path")
	if [[ -n "$sonar_raw" ]]; then
		sonar_section="${sonar_raw%%|*}"
		IFS='|' read -r sweep_gate_status sweep_total_issues sweep_high_critical sweep_sev_inline <<<"${sonar_raw#*|}"
		[[ -n "$sonar_section" ]] && tool_count=$((tool_count + 1))
		_ensure_sonar_gate_blocker_issue "$repo_slug" "$sweep_gate_status" "$sonar_section"
	fi

	local codacy_section=""
	codacy_section=$(_sweep_codacy "$repo_slug")
	[[ -n "$codacy_section" ]] && tool_count=$((tool_count + 1))

	local coderabbit_section=""
	coderabbit_section=$(_sweep_coderabbit "$repo_slug" "$sweep_gate_status" "$sweep_total_issues")
	_save_sweep_state "$repo_slug" "$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" "$qlty_smell_count" "$qlty_grade"
	tool_count=$((tool_count + 1))

	local review_scan_section=""
	review_scan_section=$(_sweep_review_scanner "$repo_slug")
	[[ -n "$review_scan_section" ]] && tool_count=$((tool_count + 1))

	local sections_dir
	sections_dir=$(_write_sweep_sections_dir \
		"$tool_count" "$shellcheck_section" "$qlty_section" "$qlty_smell_count" \
		"$qlty_grade" "$qlty_smell_delta" "$prev_qlty_smells" "$sonar_section" \
		"$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" \
		"$sweep_sev_inline" "$codacy_section" "$coderabbit_section" "$review_scan_section") || return 1

	# Single-line handshake: just the directory path. The caller reads each
	# section by `cat`ing one file at a time.
	printf '%s\n' "$sections_dir"
	return 0
}

_previous_qlty_smell_count() {
	local repo_slug="$1"
	local prev_state prev_qlty_smells

	prev_state=$(_load_sweep_state "$repo_slug")
	prev_qlty_smells=$(awk -F'|' '{print $4}' <<<"$prev_state")
	[[ "$prev_qlty_smells" =~ ^[0-9]+$ ]] || prev_qlty_smells=0
	printf '%s' "$prev_qlty_smells"
	return 0
}

_run_qlty_sweep_tool() {
	local repo_slug="$1"
	local repo_path="$2"
	local qlty_raw

	qlty_raw=$(_sweep_qlty "$repo_slug" "$repo_path")
	if [[ -z "$qlty_raw" ]]; then
		printf '%s|%s|%s' "" "0" "UNKNOWN"
		return 0
	fi

	printf '%s' "$qlty_raw"
	return 0
}

_write_sweep_sections_dir() {
	local tool_count="$1"
	local shellcheck_section="$2"
	local qlty_section="$3"
	local qlty_smell_count="$4"
	local qlty_grade="$5"
	local qlty_smell_delta="$6"
	local prev_qlty_smells="$7"
	local sonar_section="$8"
	local sweep_gate_status="$9"
	local sweep_total_issues="${10}"
	local sweep_high_critical="${11}"
	local sweep_sev_inline="${12}"
	local codacy_section="${13}"
	local coderabbit_section="${14}"
	local review_scan_section="${15}"
	local sections_dir

	sections_dir=$(mktemp -d 2>/dev/null) || return 1
	printf '%s' "$tool_count" >"${sections_dir}/tool_count"
	printf '%s' "$shellcheck_section" >"${sections_dir}/shellcheck"
	printf '%s' "$qlty_section" >"${sections_dir}/qlty"
	printf '%s' "$qlty_smell_count" >"${sections_dir}/qlty_smell_count"
	printf '%s' "$qlty_grade" >"${sections_dir}/qlty_grade"
	printf '%s' "$qlty_smell_delta" >"${sections_dir}/qlty_smell_delta"
	printf '%s' "$prev_qlty_smells" >"${sections_dir}/qlty_smell_count_prev"
	printf '%s' "$sonar_section" >"${sections_dir}/sonar"
	printf '%s' "$sweep_gate_status" >"${sections_dir}/sweep_gate_status"
	printf '%s' "$sweep_total_issues" >"${sections_dir}/sweep_total_issues"
	printf '%s' "$sweep_high_critical" >"${sections_dir}/sweep_high_critical"
	printf '%s' "$sweep_sev_inline" >"${sections_dir}/sweep_sev_inline"
	printf '%s' "$codacy_section" >"${sections_dir}/codacy"
	printf '%s' "$coderabbit_section" >"${sections_dir}/coderabbit"
	printf '%s' "$review_scan_section" >"${sections_dir}/review_scan"
	printf '%s' "$sections_dir"
	return 0
}

_quality_sweep_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"

	local issue_number
	issue_number=$(_ensure_quality_issue "$repo_slug") || return 0

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# t1992: read each section back from its own file. The previous code
	# used `IFS= read -r` chains which only handled single-line values and
	# silently truncated every multi-line markdown section.
	local sections_dir
	sections_dir=$(_run_sweep_tools "$repo_slug" "$repo_path")
	if [[ -z "$sections_dir" || ! -d "$sections_dir" ]]; then
		echo "[stats] Quality sweep: _run_sweep_tools produced no sections dir for ${repo_slug}" >>"$LOGFILE"
		[[ -n "$sections_dir" && -e "$sections_dir" ]] && rm -rf "$sections_dir"
		return 0
	fi

	local tool_count shellcheck_section qlty_section qlty_smell_count qlty_grade
	local qlty_smell_delta qlty_smell_count_prev
	local sonar_section sweep_gate_status sweep_total_issues sweep_high_critical
	local sweep_sev_inline
	local codacy_section coderabbit_section review_scan_section
	tool_count=$(cat "${sections_dir}/tool_count" 2>/dev/null || echo 0)
	shellcheck_section=$(cat "${sections_dir}/shellcheck" 2>/dev/null || echo "")
	qlty_section=$(cat "${sections_dir}/qlty" 2>/dev/null || echo "")
	qlty_smell_count=$(cat "${sections_dir}/qlty_smell_count" 2>/dev/null || echo 0)
	qlty_grade=$(cat "${sections_dir}/qlty_grade" 2>/dev/null || echo UNKNOWN)
	# t2066: smell delta + previous count for dashboard trend rendering
	qlty_smell_delta=$(cat "${sections_dir}/qlty_smell_delta" 2>/dev/null || echo 0)
	qlty_smell_count_prev=$(cat "${sections_dir}/qlty_smell_count_prev" 2>/dev/null || echo 0)
	sonar_section=$(cat "${sections_dir}/sonar" 2>/dev/null || echo "")
	sweep_gate_status=$(cat "${sections_dir}/sweep_gate_status" 2>/dev/null || echo UNKNOWN)
	sweep_total_issues=$(cat "${sections_dir}/sweep_total_issues" 2>/dev/null || echo 0)
	sweep_high_critical=$(cat "${sections_dir}/sweep_high_critical" 2>/dev/null || echo 0)
	# t2717: per-severity inline summary for the dashboard. Optional; empty
	# string on early-return paths or if the sections file is missing (e.g.,
	# when a stale sections_dir predates this field).
	sweep_sev_inline=$(cat "${sections_dir}/sweep_sev_inline" 2>/dev/null || echo "")
	codacy_section=$(cat "${sections_dir}/codacy" 2>/dev/null || echo "")
	coderabbit_section=$(cat "${sections_dir}/coderabbit" 2>/dev/null || echo "")
	review_scan_section=$(cat "${sections_dir}/review_scan" 2>/dev/null || echo "")
	rm -rf "$sections_dir"

	if [[ "${tool_count:-0}" -eq 0 ]]; then
		echo "[stats] Quality sweep: no tools available for ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	# Update issue body dashboard first (best-effort — comment is secondary)
	# t2717: pass sweep_sev_inline so the dashboard can render the per-
	# severity breakdown in place of the misleading 'high/critical' aggregate.
	_update_quality_issue_body "$repo_slug" "$issue_number" \
		"$sweep_gate_status" "$sweep_total_issues" "$sweep_high_critical" \
		"$now_iso" "$tool_count" "$qlty_smell_count" "$qlty_grade" \
		"$qlty_smell_delta" "$qlty_smell_count_prev" "$sweep_sev_inline"

	# Upsert rolling comment with full findings
	local comment_body
	comment_body=$(_build_sweep_comment \
		"$now_iso" "$repo_slug" "$tool_count" \
		"$shellcheck_section" "$qlty_section" "$sonar_section" \
		"$codacy_section" "$coderabbit_section" "$review_scan_section")

	local comment_stderr=""
	local comment_posted=false
	comment_stderr=$(_upsert_quality_sweep_comment "$issue_number" "$repo_slug" "$comment_body" 2>&1 >/dev/null) && comment_posted=true || {
		echo "[stats] Quality sweep: failed to upsert comment on #${issue_number} in ${repo_slug}: ${comment_stderr}" >>"$LOGFILE"
	}

	if [[ "$comment_posted" == true ]]; then
		echo "[stats] Quality sweep: upserted findings on #${issue_number} in ${repo_slug} (${tool_count} tools)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Read the absolute Qlty smell threshold configured by a managed repository.
# A missing threshold returns 0, preserving remediation for repositories that
# run the sweep without the aidevops threshold gate.
#######################################
_repo_qlty_smell_threshold() {
	local repo_path="$1"
	local conf_file="${repo_path}/.agents/configs/complexity-thresholds.conf"
	local threshold="0"

	if [[ -f "$conf_file" ]]; then
		threshold=$(grep '^QLTY_SMELL_THRESHOLD=' "$conf_file" | cut -d= -f2 || true)
	fi
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold="0"
	printf '%s' "$threshold"
	return 0
}

#######################################
# Create bounded Qlty remediation issues for the repository threshold deficit.
# Every file is eligible, including distributed one- and two-smell files. The
# loop stops once newly scheduled smells cover the deficit or the cycle cap is
# reached; existing per-file issues are skipped without consuming that budget.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - SARIF JSON string from qlty smells
#   $3 - configured absolute smell threshold (0 = remediate any detected debt)
#
# Safety controls: max 5 new issues per sweep, max 30 open issues, one issue per
# file fingerprint, and the pulse's existing repo/worker capacity controls.
#######################################
_create_simplification_issues() {
	local repo_slug="$1"
	local sarif_json="$2"
	local smell_threshold="${3:-0}"
	local LOGFILE="${LOGFILE:-/dev/null}"
	local max_issues_per_sweep=5
	local total_open_cap=30
	local issues_created=0
	local smells_scheduled=0
	local actual_count

	[[ "$smell_threshold" =~ ^[0-9]+$ ]] || smell_threshold=0
	actual_count=$(printf '%s\n' "$sarif_json" | jq -r '.runs[0].results | length' 2>/dev/null || true)
	[[ "$actual_count" =~ ^[0-9]+$ ]] || {
		echo "[stats] Qlty remediation: invalid SARIF count for ${repo_slug}; skipping" >>"${LOGFILE:-/dev/null}"
		printf '%s' "$issues_created"
		return 0
	}

	local smell_deficit="$actual_count"
	if [[ "$smell_threshold" -gt 0 ]]; then
		smell_deficit=$((actual_count - smell_threshold))
	fi
	if [[ "$smell_deficit" -le 0 ]]; then
		echo "[stats] Qlty remediation: actual=${actual_count} threshold=${smell_threshold} deficit=0; no repair required" >>"${LOGFILE:-/dev/null}"
		printf '%s' "$issues_created"
		return 0
	fi

	_ensure_simplification_issue_labels "$repo_slug"

	local smell_files
	smell_files=$(_smell_files_from_sarif "$sarif_json")
	if [[ -z "$smell_files" ]]; then
		printf '%s' "$issues_created"
		return 0
	fi

	local maintainer
	maintainer=$(_simplification_issue_maintainer "$repo_slug")

	local simplification_labels
	simplification_labels=$(_simplification_issue_label_csv "$repo_slug")

	if ! _simplification_issue_open_cap_allows "$repo_slug" "$total_open_cap"; then
		printf '%s' "$issues_created"
		return 0
	fi

	while IFS=$'\t' read -r smell_count file_path; do
		[[ -z "$file_path" ]] && continue
		[[ "$issues_created" -ge "$max_issues_per_sweep" ]] && break
		[[ "$smells_scheduled" -ge "$smell_deficit" ]] && break

		if _create_single_simplification_issue "$repo_slug" "$sarif_json" "$maintainer" \
			"$smell_count" "$file_path" "$simplification_labels" "$actual_count" \
			"$smell_threshold" "$smell_deficit"; then
			issues_created=$((issues_created + 1))
			smells_scheduled=$((smells_scheduled + smell_count))
		fi
	done <<<"$smell_files"

	echo "[stats] Qlty remediation: actual=${actual_count} threshold=${smell_threshold} deficit=${smell_deficit} issues_created=${issues_created} smells_scheduled=${smells_scheduled}" >>"${LOGFILE:-/dev/null}"
	printf '%s' "$issues_created"
	return 0
}

_ensure_simplification_issue_labels() {
	local repo_slug="$1"

	gh label create "function-complexity-debt" --repo "$repo_slug" \
		--description "Functions exceed complexity threshold — needs refactoring before implementation can proceed" \
		--color "E05D44" >/dev/null 2>&1 || true
	gh label create "needs-maintainer-review" --repo "$repo_slug" \
		--description "Requires maintainer approval before automated dispatch" \
		--color "FBCA04" >/dev/null 2>&1 || true
	gh label create "source:quality-sweep" --repo "$repo_slug" \
		--description "Auto-created by stats-functions.sh quality sweep" \
		--color "C2E0C6" --force >/dev/null 2>&1 || true
	gh label create "quality-debt" --repo "$repo_slug" \
		--description "Automated code quality remediation" \
		--color "D4C5F9" >/dev/null 2>&1 || true
	gh label create "auto-dispatch" --repo "$repo_slug" \
		--description "Eligible for autonomous worker dispatch" \
		--color "0E8A16" >/dev/null 2>&1 || true
	gh label create "tier:thinking" --repo "$repo_slug" \
		--description "Opus-tier: architecture, deep reasoning, high-complexity refactors" \
		--color "5319E7" >/dev/null 2>&1 || true
	return 0
}

_smell_files_from_sarif() {
	local sarif_json="$1"

	printf '%s\n' "$sarif_json" | jq -r '
		[.runs[0].results[]? | .locations[0].physicalLocation.artifactLocation.uri? |
		 select(type == "string" and length > 0)] |
		group_by(.) | map({file: .[0], count: length}) |
		sort_by([-.count, .file]) |
		.[] | "\(.count)\t\(.file)"
	' 2>/dev/null || true
	return 0
}

_simplification_issue_maintainer() {
	local repo_slug="$1"
	local maintainer=""

	maintainer=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[]? | select(.slug == $slug) | .maintainer // empty' \
		"${HOME}/.config/aidevops/repos.json" 2>/dev/null) || maintainer=""
	[[ -n "$maintainer" ]] || maintainer="${repo_slug%%/*}"
	printf '%s' "$maintainer"
	return 0
}

_simplification_issue_label_csv() {
	local repo_slug="$1"
	local simplification_labels="function-complexity-debt,quality-debt,source:quality-sweep,auto-dispatch,tier:thinking"

	# #aidevops:trust-boundary — NMR is an external-origin approval gate. When
	# the authenticated sweep identity has repo write authority, the issue author
	# is already trusted and should not be parked behind maintainer review.
	if declare -F _gh_current_user_allows_repo_write >/dev/null 2>&1 &&
		_gh_current_user_allows_repo_write "$repo_slug"; then
		echo "[stats] Function-complexity-debt issues: trusted current user ${AIDEVOPS_GH_WRITE_PERMISSION_USER:-unknown} (${AIDEVOPS_GH_WRITE_PERMISSION_LEVEL:-unknown}) — skipping needs-maintainer-review" >>"$LOGFILE"
	else
		simplification_labels="${simplification_labels},needs-maintainer-review"
		echo "[stats] Function-complexity-debt issues: current user not verified as repo writer (${AIDEVOPS_GH_WRITE_PERMISSION_REASON:-helper-unavailable}) — keeping needs-maintainer-review" >>"$LOGFILE"
	fi
	printf '%s' "$simplification_labels"
	return 0
}

_simplification_issue_open_cap_allows() {
	local repo_slug="$1"
	local total_open_cap="$2"
	local total_open

	total_open=$(gh api graphql -f query="query { repository(owner:\"${repo_slug%%/*}\", name:\"${repo_slug##*/}\") { issues(labels:[\"function-complexity-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount // ""') || total_open=""
	[[ "$total_open" =~ ^[0-9]+$ ]] || total_open="0"
	if [[ "${total_open:-0}" -ge "$total_open_cap" ]]; then
		echo "[stats] Function-complexity-debt issues: skipping — ${total_open} open (cap: ${total_open_cap})" >>"$LOGFILE"
		return 1
	fi
	return 0
}

_create_single_simplification_issue() {
	local repo_slug="$1"
	local sarif_json="$2"
	local maintainer="$3"
	local smell_count="$4"
	local file_path="$5"
	local label_csv="$6"
	local actual_count="${7:-$smell_count}"
	local smell_threshold="${8:-0}"
	local smell_deficit="${9:-$actual_count}"
	local rule_breakdown file_basename issue_title issue_body qlty_sig

	_simplification_issue_exists "$repo_slug" "$file_path" && return 1
	rule_breakdown=$(_simplification_rule_breakdown "$sarif_json" "$file_path")
	file_basename="${file_path##*/}"
	issue_title="simplification: reduce ${smell_count} Qlty smells in ${file_basename}"
	issue_body=$(_build_simplification_issue_body "$file_path" "$smell_count" "$rule_breakdown" \
		"$actual_count" "$smell_threshold" "$smell_deficit")
	qlty_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$issue_body" 2>/dev/null || true)
	issue_body="${issue_body}${qlty_sig}"

	_simplification_gh_create_issue "$repo_slug" "$issue_title" "$maintainer" "$issue_body" "$label_csv"
	return $?
}

_simplification_issue_exists() {
	local repo_slug="$1"
	local file_path="$2"
	local existing_count

	existing_count=$(gh issue list --repo "$repo_slug" \
		--label "function-complexity-debt" --state open \
		--search "\"cited_file=${file_path}\" in:body" \
		--json number --jq 'length' 2>/dev/null) || {
		echo "[stats] Function-complexity-debt issue search failed for ${file_path}; skipping create to avoid duplicates" >>"$LOGFILE"
		return 0
	}
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count="0"
	[[ "${existing_count:-0}" -gt 0 ]] && return 0
	return 1
}

_simplification_rule_breakdown() {
	local sarif_json="$1"
	local file_path="$2"

	echo "$sarif_json" | jq -r --arg fp "$file_path" '
		[.runs[0].results[] |
		 select(.locations[0].physicalLocation.artifactLocation.uri == $fp) |
		 .ruleId] | group_by(.) | map("\(.[0]): \(length)") | join(", ")
	' 2>/dev/null || printf '%s' "(could not parse)"
	return 0
}

_simplification_gh_create_issue() {
	local repo_slug="$1"
	local issue_title="$2"
	local maintainer="$3"
	local issue_body="$4"
	local label_csv="$5"
	local label_args=()
	local label_name

	IFS=',' read -r -a label_args_raw <<<"$label_csv"
	for label_name in "${label_args_raw[@]}"; do
		label_args+=(--label "$label_name")
	done

	gh_create_issue --repo "$repo_slug" \
		--title "$issue_title" \
		"${label_args[@]}" \
		--assignee "$maintainer" \
		--body "$issue_body" >/dev/null 2>&1
	return $?
}

#######################################
# Build the quality issue dashboard body markdown.
#
# Pure formatting function — no API calls. All data pre-gathered by caller.
#
# t2066: added qlty_smell_delta and qlty_smell_count_prev so the dashboard
# can render a trend indicator next to the smell count and the grade row
# shows the grade is derived from the local count (not the cloud badge).
#
# Arguments:
#   $1  - sweep_time
#   $2  - repo_slug
#   $3  - tool_count
#   $4  - badge_indicator
#   $5  - gate_status
#   $6  - total_issues
#   $7  - high_critical (retained for back-compat; not displayed per t2717)
#   $8  - qlty_grade
#   $9  - qlty_smell_count
#   $10 - debt_open
#   $11 - debt_closed
#   $12 - simplified_count
#   $13 - debt_resolution_pct
#   $14 - prs_scanned_lifetime
#   $15 - issues_created_lifetime
#   $16 - bot_coverage_section
#   $17 - qlty_smell_delta (signed int; positive = regression)
#   $18 - qlty_smell_count_prev (previous sweep's smell count; 0 = first run)
#   $19 - sev_inline (t2717; per-severity inline summary, e.g.,
#        "0 BLOCKER · 0 CRITICAL · 98 MAJOR · 196 MINOR · 0 INFO";
#        empty string falls back to legacy high_critical rendering)
# Output: body markdown to stdout
#######################################
_build_quality_issue_body() {
	local sweep_time="$1"
	local repo_slug="$2"
	local tool_count="$3"
	local badge_indicator="$4"
	local gate_status="$5"
	local total_issues="$6"
	local high_critical="$7"
	local qlty_grade="$8"
	local qlty_smell_count="$9"
	local debt_open="${10}"
	local debt_closed="${11}"
	local simplified_count="${12}"
	local debt_resolution_pct="${13}"
	local prs_scanned_lifetime="${14}"
	local issues_created_lifetime="${15}"
	local bot_coverage_section="${16}"
	local qlty_smell_delta="${17:-0}"
	local qlty_smell_count_prev="${18:-0}"
	local sev_inline="${19:-}"

	# t2066: render smell-count trend indicator. The arrow is a simple
	# visual cue; the signed value is authoritative. First-run case (prev=0,
	# no history) shows "baseline" instead of an arrow so the reader knows
	# the delta is meaningless until the second sweep lands.
	local smell_trend=""
	if [[ "$qlty_smell_count_prev" == "0" && "$qlty_smell_count" -gt 0 ]]; then
		smell_trend="(baseline — no prior sweep)"
	elif [[ "$qlty_smell_delta" == "0" ]]; then
		smell_trend="→ 0 (unchanged)"
	elif [[ "$qlty_smell_delta" =~ ^- ]]; then
		# Negative delta = improvement
		smell_trend="↓ ${qlty_smell_delta} (improved)"
	else
		smell_trend="↑ +${qlty_smell_delta} (regressed)"
	fi

	# t2717: prefer the per-severity inline summary (BLOCKER · CRITICAL ·
	# MAJOR · MINOR · INFO) over the legacy '(N high/critical)' aggregate.
	# The legacy label was misleading because it summed MAJOR (a
	# CODE_SMELL severity in SonarCloud's taxonomy) with the true high
	# severities (BLOCKER, CRITICAL). Fall back to the legacy label only
	# when sev_inline is empty (e.g., first sweep after upgrade, or an
	# early-return path where no SonarCloud data was fetched).
	local sonar_issues_detail
	if [[ -n "$sev_inline" ]]; then
		sonar_issues_detail="${total_issues} (${sev_inline})"
	else
		sonar_issues_detail="${total_issues} (${high_critical} high/critical)"
	fi

	cat <<BODY
## Code Audit Routines

**Last sweep**: \`${sweep_time}\`
**Repo**: \`${repo_slug}\`
**Tools run**: ${tool_count}
**Badge status**: ${badge_indicator}

### Quality

| Metric | Value |
| --- | --- |
| SonarCloud gate | ${gate_status} |
| SonarCloud issues | ${sonar_issues_detail} |
| Qlty grade (local, from smell count) | ${qlty_grade} |
| Qlty smells | ${qlty_smell_count} ${smell_trend} |

### Simplification

| Metric | Value |
| --- | --- |
| Open | ${debt_open} |
| Closed | ${debt_closed} |
| Simplified (state tracked) | ${simplified_count} |
| Resolution rate | ${debt_resolution_pct}% |

### PR Scanning

| Metric | Value |
| --- | --- |
| PRs scanned (lifetime) | ${prs_scanned_lifetime} |
| Issues created (lifetime) | ${issues_created_lifetime} |

${bot_coverage_section}

---
_Auto-updated by daily quality sweep. Findings as of \`${sweep_time}\` — may not reflect recent merges between sweeps._
_The codebase is the primary source of truth. This dashboard is a reporting snapshot that may lag behind reality._
_Do not edit manually._
BODY
	return 0
}
