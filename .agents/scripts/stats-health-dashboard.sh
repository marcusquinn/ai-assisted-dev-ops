#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Stats Health Dashboard — Orchestrator
# =============================================================================
# Per-repo pinned health issue dashboards.
#
# Extracted from stats-functions.sh via the phased decomposition plan:
#   todo/plans/stats-functions-decomposition.md  (Phase 3)
#
# This module is sourced by stats-functions.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all stats-* configuration constants in the bootstrap
# section of stats-functions.sh.
#
# Sub-libraries (sourced below):
#   - stats-health-dashboard-issue.sh  (issue lifecycle: find/create/resolve/dedup/pin)
#   - stats-health-dashboard-data.sh   (data gathering, body formatting, person stats)
#
# Dependencies on other stats modules:
#   - stats-shared.sh (calls _get_runner_role, _dashboard_identity_aliases)
#
# Globals read:
#   - LOGFILE, REPOS_JSON, PERSON_STATS_INTERVAL, PERSON_STATS_LAST_RUN,
#     PERSON_STATS_CACHE_DIR, SESSION_COUNT_WARN
# Globals written:
#   - none (stats modules write only to disk under ~/.aidevops/logs/)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_HEALTH_DASHBOARD_LOADED:-}" ]] && return 0
_STATS_HEALTH_DASHBOARD_LOADED=1

# t2687: sentinel returned by _find_health_issue when a gh query fails
# (rate limit, network, API 5xx). Callers treat this as "abstain this
# cycle" — never fall through to _create_health_issue, which would
# create a duplicate while the dedup lookups are silently unable to
# see existing ones.
readonly _HEALTH_QUERY_FAILED_SENTINEL="__QUERY_FAILED__"
readonly _HEALTH_CROSS_REPO_MAX_REPOS=30
readonly _HEALTH_IDLE_REFRESH_INTERVAL_DEFAULT=43200
readonly _HEALTH_ACTIVITY_STATE_ACTIVE="active"
readonly _HEALTH_ACTIVITY_STATE_IDLE="idle"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Source sub-libraries ---

# shellcheck source=./stats-health-dashboard-issue.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-health-dashboard-issue.sh"

# shellcheck source=./stats-health-dashboard-data.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/stats-health-dashboard-data.sh"

# shellcheck source=./privacy-guard-helper.sh
# shellcheck disable=SC1091  # sibling library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/privacy-guard-helper.sh"

# --- Orchestration functions ---

#######################################
# Resolve current GitHub login, validating gh output before use.
# Output: validated GitHub login, or a validated local fallback
#######################################
_resolve_current_gh_login_or_fallback() {
	local gh_login=""
	local fallback_login=""

	gh_login=$(_gh_with_timeout read gh api user --jq '.login // ""') || gh_login=""
	if [[ "$gh_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		printf '%s' "$gh_login"
		return 0
	fi

	fallback_login=$(whoami 2>/dev/null) || fallback_login=""
	# Local system usernames are not GitHub logins; accept common POSIX-safe
	# account characters while rejecting whitespace/control characters because
	# this value is reused in labels, cache keys, and gh CLI arguments.
	if [[ "$fallback_login" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]]; then
		echo "[stats] GitHub login unavailable or invalid; using local fallback identity: ${fallback_login}" \
			>>"${LOGFILE:-/dev/null}"
		printf '%s' "$fallback_login"
		return 0
	fi

	echo "[stats] GitHub login unavailable or invalid; using anonymous fallback identity" \
		>>"${LOGFILE:-/dev/null}"
	printf '%s' "unknown-runner"
	return 0
}

#######################################
# Activity guard — returns 0 to proceed, 1 to skip.
# Active repositories refresh on the hourly stats cadence. Idle repositories
# publish their transition to idle immediately, then refresh every 12 hours by
# default. This keeps the dashboard well inside the 48-hour freshness watchdog
# while avoiding full activity scans and GitHub writes for unchanged idle repos.
#######################################
_check_health_issue_activity_guard() {
	local repo_slug="$1"
	local repo_path="$2"
	local runner_user="$3"
	local health_issue_file="$4"

	local guard_pr_count guard_assigned_count guard_auto_dispatch_count guard_worker_count
	local _guard_fields=()
	_HEALTH_ISSUE_ACTIVITY_STATE="$_HEALTH_ACTIVITY_STATE_ACTIVE"
	while IFS= read -r -d '' _gf; do
		_guard_fields+=("$_gf")
	done < <(_scan_active_workers "${repo_path:-}")
	guard_worker_count="${_guard_fields[1]:-0}"
	[[ "${guard_worker_count:-0}" -gt 0 ]] && return 0

	local guard_rc=0
	guard_pr_count=$(gh_pr_list --repo "$repo_slug" --state open \
		--json number --jq 'length' 2>/dev/null) || guard_rc=$?
	[[ $guard_rc -ne 0 ]] && return 0
	[[ "$guard_pr_count" =~ ^[0-9]+$ ]] || guard_pr_count="0"
	[[ "${guard_pr_count:-0}" -gt 0 ]] && return 0

	guard_rc=0
	guard_assigned_count=$(gh_issue_list --repo "$repo_slug" \
		--assignee "$runner_user" --state open \
		--json number --jq 'length' 2>/dev/null) || guard_rc=$?
	[[ $guard_rc -ne 0 ]] && return 0
	[[ "$guard_assigned_count" =~ ^[0-9]+$ ]] || guard_assigned_count="0"
	[[ "${guard_assigned_count:-0}" -gt 0 ]] && return 0

	guard_rc=0
	guard_auto_dispatch_count=$(gh_issue_list --repo "$repo_slug" \
		--label "auto-dispatch" --state open \
		--json number --jq 'length' 2>/dev/null) || guard_rc=$?
	[[ $guard_rc -ne 0 ]] && return 0
	[[ "$guard_auto_dispatch_count" =~ ^[0-9]+$ ]] || guard_auto_dispatch_count="0"
	[[ "${guard_auto_dispatch_count:-0}" -gt 0 ]] && return 0

	_HEALTH_ISSUE_ACTIVITY_STATE="$_HEALTH_ACTIVITY_STATE_IDLE"
	if [[ ! -f "$health_issue_file" ]]; then
		echo "[stats] Health issue: skipping creation for ${repo_slug} — no active PRs, assigned issues, auto-dispatch work, or workers" \
			>>"${LOGFILE:-/dev/null}"
		return 1
	fi

	local refresh_state_file="${health_issue_file}.refresh-state"
	local previous_state="" previous_epoch="0"
	if [[ -f "$refresh_state_file" ]]; then
		IFS='|' read -r previous_state previous_epoch <"$refresh_state_file" 2>/dev/null || {
			previous_state=""
			previous_epoch="0"
		}
	fi
	[[ "$previous_epoch" =~ ^[0-9]+$ ]] || previous_epoch="0"

	# Missing/active state means this is the first observed idle cycle. Publish
	# the transition now so titles never advertise workers or queue activity for
	# the entire idle backoff window.
	[[ "$previous_state" != "$_HEALTH_ACTIVITY_STATE_IDLE" ]] && return 0

	local idle_interval="${HEALTH_IDLE_REFRESH_INTERVAL:-$_HEALTH_IDLE_REFRESH_INTERVAL_DEFAULT}"
	[[ "$idle_interval" =~ ^[0-9]+$ ]] || idle_interval="$_HEALTH_IDLE_REFRESH_INTERVAL_DEFAULT"
	local now_epoch
	now_epoch=$(date +%s)
	if [[ $((now_epoch - previous_epoch)) -ge $idle_interval ]]; then
		return 0
	fi

	echo "[stats] Health issue: deferring unchanged idle dashboard for ${repo_slug} (interval=${idle_interval}s)" \
		>>"${LOGFILE:-/dev/null}"
	return 1
}

#######################################
# Record the activity state only after a dashboard body update succeeds.
# Arguments:
#   $1 - health issue cache file
#   $2 - activity state (active|idle)
#######################################
_record_health_issue_refresh_state() {
	local health_issue_file="$1"
	local activity_state="$2"
	[[ "$activity_state" == "$_HEALTH_ACTIVITY_STATE_ACTIVE" \
		|| "$activity_state" == "$_HEALTH_ACTIVITY_STATE_IDLE" ]] \
		|| activity_state="$_HEALTH_ACTIVITY_STATE_ACTIVE"
	printf '%s|%s\n' "$activity_state" "$(date +%s)" >"${health_issue_file}.refresh-state"
	return 0
}

#######################################
# Persist only the trailing issue number for subsequent dashboard updates.
# Arguments:
#   $1 - resolver output or issue number
#   $2 - health issue cache file path
#######################################
_cache_health_issue_number() {
	local health_issue_number="$1"
	local health_issue_file="$2"
	local cache_issue_number

	cache_issue_number=$(printf '%s\n' "$health_issue_number" | awk '/^[0-9]+$/ { value=$0 } match($0, /\/[0-9]+$/) { value=substr($0, RSTART + 1, RLENGTH - 1) } END { if (value != "") print value }')
	printf '%s\n' "$cache_issue_number" >"$health_issue_file"
	return 0
}

#######################################
# Update the dashboard issue body, preserving failure propagation.
# Arguments:
#   $1 - health issue number
#   $2 - repo slug
#   $3 - rendered issue body
# Returns: 0 on success, 1 when the body edit fails
#######################################
_update_health_issue_body_or_fail() {
	local health_issue_number="$1"
	local repo_slug="$2"
	local body="$3"
	local body_edit_stderr sanitized_body=""

	# Health dashboards aggregate helper output from many local repositories.
	# Sanitize that output before the public write rather than letting one local
	# path prevent the entire dashboard—including its freshness marker—from
	# updating. The write wrapper independently scans the final body.
	sanitized_body=$(privacy_redact_public_text_from_inventory "$body") || {
		echo "[stats] Health issue: could not sanitize public body for #${health_issue_number}" \
			>>"${LOGFILE:-/dev/null}"
		return 1
	}

	# Use gh_issue_edit_safe (not bare `gh issue edit`) so the REST fallback
	# in shared-gh-wrappers-safe-edit.sh fires when GraphQL is rate-limited.
	# Bare `gh issue edit` always uses GraphQL and silently fails the body
	# update when the 5000/hr GraphQL budget is exhausted, leaving the
	# dashboard stale until the budget resets (up to 1h). GH#33.
	body_edit_stderr=$(_gh_with_timeout write gh_issue_edit_safe "$health_issue_number" --repo "$repo_slug" \
		--body "$sanitized_body" 2>&1 >/dev/null) || {
		echo "[stats] Health issue: failed to update body for #${health_issue_number}: ${body_edit_stderr}" \
			>>"${LOGFILE:-/dev/null}"
		return 1
	}
	return 0
}

#######################################
# Refresh the dashboard issue title from the rendered body counts.
# Arguments:
#   $1 - health issue number
#   $2 - repo slug
#   $3 - runner title prefix
#   $4 - rendered issue body
#   $5 - snapshot timestamp (ISO8601 UTC)
#######################################
_refresh_health_issue_title_from_body() {
	local health_issue_number="$1"
	local repo_slug="$2"
	local runner_prefix="$3"
	local body="$4"
	local snapshot_iso="$5"
	local counts_raw pr_count assigned_issue_count worker_count

	# Re-extract headline counts from the rendered body to build the title.
	# Avoids relying on function-local variables from _assemble_health_issue_body.
	counts_raw=$(_extract_body_counts "$body")
	IFS='|' read -r pr_count assigned_issue_count worker_count <<<"$counts_raw"

	_update_health_issue_title \
		"$health_issue_number" "$repo_slug" "$runner_prefix" \
		"$pr_count" "$assigned_issue_count" "$worker_count" "$snapshot_iso"
	return 0
}

#######################################
# Update pinned health issue for a single repo
#
# Creates or updates a pinned GitHub issue with live status:
#   - Open PRs and issues counts
#   - Active headless workers (from ps)
#   - System resources (CPU, RAM)
#   - Last pulse timestamp
#
# One issue per canonical dashboard operator per repo. Uses labels
# "supervisor" or "contributor" plus "operator:<canonical>" for dedup,
# with configured local/GitHub aliases folded into that canonical identity.
# Issue number cached in ~/.aidevops/logs/ to avoid repeated lookups.
#
# Maintainers get [Supervisor:user] issues; non-maintainers get
# [Contributor:user] issues. Role determined by _get_runner_role().
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path (local filesystem)
#   $3 - cross-repo activity markdown (pre-computed by update_health_issues)
#   $4 - cross-repo session time markdown (pre-computed by update_health_issues)
#   $5 - cross-repo person stats markdown (pre-computed by update_health_issues)
# Returns: 0 when refreshed/skipped, 1 when an existing dashboard update fails
#######################################
_update_health_issue_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	local cross_repo_md="${3:-}"
	local cross_repo_session_time_md="${4:-}"
	local cross_repo_person_stats_md="${5:-}"

	[[ -z "$repo_slug" ]] && return 0

	local runner_user
	runner_user=$(_resolve_current_gh_login_or_fallback)

	local runner_role
	runner_role=$(_get_runner_role "$runner_user" "$repo_slug")

	local identity_lines canonical_identity identity_aliases
	identity_lines=$(_dashboard_identity_aliases "$runner_user")
	canonical_identity=$(printf '%s\n' "$identity_lines" | sed -n '1p')
	identity_aliases=$(printf '%s\n' "$identity_lines" | sed '1d')
	[[ -n "$canonical_identity" ]] || canonical_identity="$runner_user"
	[[ -n "$identity_aliases" ]] || identity_aliases="$runner_user"

	local role_config runner_prefix role_label role_label_color role_label_desc role_display
	# Visible title uses runner_user; canonical identity stays in labels/cache/body.
	role_config=$(_resolve_runner_role_config "$runner_user" "$runner_role")
	IFS='|' read -r runner_prefix role_label role_label_color role_label_desc role_display \
		<<<"$role_config"

	local slug_safe="${repo_slug//\//-}"
	local cache_dir="${HOME}/.aidevops/logs"
	local canonical_identity_cache_safe
	canonical_identity_cache_safe=$(_sanitize_runner_identity_for_cache "$canonical_identity")
	local health_issue_file="${cache_dir}/health-issue-${canonical_identity_cache_safe}-${slug_safe}"
	mkdir -p "$cache_dir"

	_HEALTH_ISSUE_ACTIVITY_STATE="$_HEALTH_ACTIVITY_STATE_ACTIVE"
	_check_health_issue_activity_guard \
		"$repo_slug" "$repo_path" "$runner_user" "$health_issue_file" || return 0
	local activity_state="${_HEALTH_ISSUE_ACTIVITY_STATE:-$_HEALTH_ACTIVITY_STATE_ACTIVE}"

	local health_issue_number
	health_issue_number=$(_resolve_health_issue_number \
		"$repo_slug" "$runner_user" "$runner_role" "$runner_prefix" \
		"$role_label" "$role_label_color" "$role_label_desc" \
		"$role_display" "$health_issue_file" \
		"$canonical_identity" "$identity_aliases")
	[[ -z "$health_issue_number" ]] && return 0
	[[ "$health_issue_number" == "$_HEALTH_QUERY_FAILED_SENTINEL" ]] && return 0

	# t2687: periodic dedup scan (at most once per HEALTH_DEDUP_INTERVAL
	# seconds per repo+runner+role, default 1h). Closes duplicates that
	# slipped in during past GraphQL rate-limit windows when the cache
	# was valid so the label-scan inside _find_health_issue never ran.
	_periodic_health_issue_dedup \
		"$repo_slug" "$runner_user" "$runner_role" \
		"$role_label" "$role_display" "$health_issue_number" \
		"$canonical_identity" "$identity_aliases"
	_normalize_health_issue_labels \
		"$health_issue_number" "$repo_slug" "$runner_user" \
		"$runner_role" "$canonical_identity"

	if [[ "$runner_role" == "supervisor" ]]; then
		_ensure_health_issue_pinned "$health_issue_number" "$repo_slug" "$runner_user"
	fi

	_cache_health_issue_number "$health_issue_number" "$health_issue_file"

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	local body
	body=$(_assemble_health_issue_body \
		"$repo_slug" "$repo_path" "$runner_user" "$slug_safe" \
		"$now_iso" "$role_display" "$runner_role" \
		"$cross_repo_md" "$cross_repo_session_time_md" "$cross_repo_person_stats_md" \
		"$canonical_identity" "$identity_aliases")

	_update_health_issue_body_or_fail "$health_issue_number" "$repo_slug" "$body" || return 1
	_refresh_health_issue_title_from_body \
		"$health_issue_number" "$repo_slug" "$runner_prefix" "$body" "$now_iso"
	_record_health_issue_refresh_state "$health_issue_file" "$activity_state"

	return 0
}

#######################################
# Filter repo entries to repos where public routines are authorized.
# Arguments:
#   $1 - newline-delimited slug|path entries
#   $2 - authenticated GitHub user
# Output: authorized slug|path entries
#######################################
_filter_routine_eligible_repo_entries() {
	local repo_entries="$1"
	local routine_runner_user="$2"
	local slug path

	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		if ! aidevops_can_run_repo_routines "$slug" "$routine_runner_user"; then
			echo "[stats] Health dashboard skipped for ${slug}: ${routine_runner_user} is not maintainer-equivalent" >>"$LOGFILE"
			continue
		fi
		printf '%s|%s\n' "$slug" "$path"
	done <<<"$repo_entries"
	return 0
}

#######################################
# Update health issues for ALL pulse-enabled repos
#
# Iterates repos.json and calls _update_health_issue_for_repo for each
# non-local-only repo with a slug. Runs sequentially to avoid gh API
# rate limiting. Best-effort — failures in one repo don't block others.
#######################################
update_health_issues() {
	# t2044 Phase 0: dry-run sentinel. When STATS_DRY_RUN=1, return immediately
	# to exercise the call graph without making gh/git API calls. Temporary
	# scaffolding — removed after Phase 3 merges.
	if [[ "${STATS_DRY_RUN:-}" == "1" ]]; then
		echo "[stats] update_health_issues: dry-run, skipping" >>"$LOGFILE"
		return 0
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
		echo "[stats] Health dashboard skipped: could not resolve authenticated GitHub user" >>"$LOGFILE"
		return 0
	fi

	repo_entries=$(_filter_routine_eligible_repo_entries "$repo_entries" "$routine_runner_user")
	if [[ -z "$repo_entries" ]]; then
		return 0
	fi

	# Refresh person-stats cache if stale (t1426: hourly, not every pulse)
	_refresh_person_stats_cache || true

	# Pre-compute cross-repo summaries ONCE for all health issues.
	# This avoids N×N git log walks (one cross-repo scan per repo dashboard)
	# and redundant DB queries for session time.
	# Person stats read from cache (refreshed hourly by _refresh_person_stats_cache).
	# Skip the optional cross-repo summaries above _HEALTH_CROSS_REPO_MAX_REPOS;
	# the contributor activity helper can time out at that scale and stall the
	# dashboard refresh.
	local cross_repo_md=""
	local cross_repo_session_time_md=""
	local cross_repo_person_stats_md=""
	local activity_helper="${HOME}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	if [[ -x "$activity_helper" ]]; then
		local all_repo_paths
		all_repo_paths=$(printf '%s\n' "$repo_entries" | awk -F'|' 'NF >= 2 && $2 != "" { print $2 }')
		if [[ -n "$all_repo_paths" ]]; then
			local -a cross_args=()
			while IFS= read -r rp; do
				[[ -n "$rp" ]] && cross_args+=("$rp")
			done <<<"$all_repo_paths"
			if [[ ${#cross_args[@]} -gt 1 && ${#cross_args[@]} -le $_HEALTH_CROSS_REPO_MAX_REPOS ]]; then
				cross_repo_md=$(timeout 120 bash "$activity_helper" cross-repo-summary "${cross_args[@]}" --period month --format markdown || echo "_Cross-repo data unavailable._")
				cross_repo_session_time_md=$(timeout 120 bash "$activity_helper" cross-repo-session-time "${cross_args[@]}" --period all --format markdown || echo "_Cross-repo session data unavailable._")
			elif [[ ${#cross_args[@]} -gt $_HEALTH_CROSS_REPO_MAX_REPOS ]]; then
				local cross_repo_skip_message="Cross-repo summary skipped: ${#cross_args[@]} repositories exceeds limit ${_HEALTH_CROSS_REPO_MAX_REPOS}."
				echo "[stats] ${cross_repo_skip_message}" >>"${LOGFILE:-/dev/null}"
				cross_repo_md="_${cross_repo_skip_message}_"
				cross_repo_session_time_md="_${cross_repo_skip_message}_"
			fi
		fi
	fi
	local cross_repo_cache="${PERSON_STATS_CACHE_DIR}/person-stats-cache-cross-repo.md"
	if [[ -f "$cross_repo_cache" ]]; then
		cross_repo_person_stats_md=$(_read_person_stats_cache "cross-repo")
	fi

	local updated=0
	local failed=0
	while IFS='|' read -r slug path; do
		[[ -z "$slug" ]] && continue
		if ! _update_health_issue_for_repo "$slug" "$path" "$cross_repo_md" "$cross_repo_session_time_md" "$cross_repo_person_stats_md"; then
			echo "[stats] Health issue update failed for ${slug}" >>"$LOGFILE"
			failed=$((failed + 1))
			continue
		fi
		updated=$((updated + 1))
	done <<<"$repo_entries"

	if [[ "$updated" -gt 0 ]]; then
		echo "[stats] Health issues: updated $updated repo(s)" >>"$LOGFILE"
	fi
	if [[ "$failed" -gt 0 ]]; then
		echo "[stats] Health issues: failed $failed repo(s)" >>"$LOGFILE"
		return 1
	fi
	return 0
}
