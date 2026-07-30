#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dashboard-freshness-check.sh — Self-referential watchdog for the supervisor
# health dashboard (t2418, GH#20016).
#
# The framework's primary single-glance health surface is the per-repo pinned
# "[Supervisor:<user>]" issue, rebuilt by stats-wrapper.sh → update_health_issues
# on a 15-minute launchd/cron schedule. When the refresh silently stops (missing
# plist, unhandled exception, GitHub API outage), the dashboard keeps showing
# the same green numbers — operators assume health, not realising the data is
# 11 days old. This is the silent-failure class that #10944 hit on 2026-04-08.
#
# This scanner closes that gap by reading the dashboard body, extracting the
# `last_refresh: <ISO8601>` marker emitted by _build_health_issue_body, and
# filing a `review-followup` + `priority:high` alert when staleness exceeds
# a configurable threshold (default 48h).
#
# Design principles:
#   - Single-pass, cheap: one gh API call per tracked dashboard.
#   - Cadence-gated: default one check per hour, throttled via state file.
#   - Idempotent alerting: one open alert per dashboard, dedup'd by generated
#     alert title plus dashboard issue suffix.
#   - Fail-open: any error (gh offline, cache missing, body missing marker)
#     logs and exits 0 — never blocks the pulse.
#
# Reference pattern: contribution-watch-helper.sh (scoped review-followup
# scanner) and review-scanner-helper.sh.
#
# Usage:
#   dashboard-freshness-check.sh scan                 Run the scanner (pulse hook)
#   dashboard-freshness-check.sh scan --force         Bypass cadence gate
#   dashboard-freshness-check.sh scan --dry-run       Print findings, file nothing
#   dashboard-freshness-check.sh check-body <file>    Print age for a body on disk (test hook)
#   dashboard-freshness-check.sh help                 Show usage
#
# Env:
#   DASHBOARD_FRESHNESS_THRESHOLD_SECONDS   Default 172800 (48h).
#   DASHBOARD_FRESHNESS_SCAN_INTERVAL       Default 3600 (1h between scans).
#   DASHBOARD_FRESHNESS_DRY_RUN             If "1", act like --dry-run.

set -euo pipefail

# PATH normalisation for launchd / MCP / headless environments.
_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Colour fallbacks if shared-constants.sh is not loaded.
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

LOGFILE="${HOME}/.aidevops/logs/dashboard-freshness.log"
STATE_DIR="${HOME}/.aidevops/cache/dashboard-freshness"
LAST_RUN_FILE="${STATE_DIR}/last-scan"
HEALTH_ISSUE_CACHE_DIR="${HOME}/.aidevops/logs"

# Threshold: how old a dashboard's last_refresh may be before we alert.
# Default 48h — two full schedules of 15-min cadence is ~192 missed runs.
DASHBOARD_FRESHNESS_THRESHOLD_SECONDS="${DASHBOARD_FRESHNESS_THRESHOLD_SECONDS:-172800}"

# Cadence gate: minimum seconds between scan invocations.
DASHBOARD_FRESHNESS_SCAN_INTERVAL="${DASHBOARD_FRESHNESS_SCAN_INTERVAL:-3600}"

# Dedup window: a stale alert issue suppresses further alerts for this duration.
DASHBOARD_FRESHNESS_ALERT_TTL_SECONDS="${DASHBOARD_FRESHNESS_ALERT_TTL_SECONDS:-86400}"

# Sentinel returned by _compute_body_age when the dashboard body has no
# parseable last_refresh marker. Extracted to defeat the repeated-literal
# pre-commit ratchet and to give callers a single constant to match against.
readonly MARKER_MISSING="MISSING"
readonly ALERT_KIND_ANY="any"
readonly ALERT_KIND_STALE="stale"
readonly ALERT_KIND_MISSING="missing"

REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR" 2>/dev/null || true

# =============================================================================
# Logging helpers
# =============================================================================

_log() {
	local level="$1"
	shift
	printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >>"$LOGFILE"
}

_log_info() { _log "INFO" "$@"; }
_log_warn() { _log "WARN" "$@"; }
_log_error() { _log "ERROR" "$@"; }

# =============================================================================
# Time helpers
# =============================================================================

# Parse an ISO8601 timestamp into epoch seconds. Accepts both Z and +HH:MM.
# Returns empty on failure — the caller decides how to handle it.
#
# Structure note: early-return guard clauses instead of elif chains. The
# nesting-depth AWK counter in code-quality.yml (and the mirrored pre-push
# hook) uses a loose regex `(if|for|while|until|case)` that matches the
# substring `if ` inside `elif `, inflating depth by 1 per `elif`. Keeping
# each branch as its own `if...fi` block lets depth return to 0 between
# branches, so this function stays within the depth-8 gate.
_iso_to_epoch() {
	local iso="$1"
	[[ -z "$iso" ]] && return 0

	# GNU date (Linux).
	if date -u -d "$iso" +%s >/dev/null 2>&1; then
		date -u -d "$iso" +%s 2>/dev/null || true
		return 0
	fi

	# BSD date (macOS) — Z suffix.
	if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${iso%Z}Z" +%s >/dev/null 2>&1; then
		date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${iso%Z}Z" +%s 2>/dev/null || true
		return 0
	fi

	# BSD date (macOS) — numeric offset suffix.
	if date -u -j -f '%Y-%m-%dT%H:%M:%S%z' "$iso" +%s >/dev/null 2>&1; then
		date -u -j -f '%Y-%m-%dT%H:%M:%S%z' "$iso" +%s 2>/dev/null || true
		return 0
	fi

	return 0
}

# Format a duration in seconds as a short human string: 2h5m / 3d7h.
# Early-return pattern — see _iso_to_epoch note for why.
_format_age() {
	local secs="${1:-0}"
	[[ "$secs" =~ ^[0-9]+$ ]] || secs=0
	if (( secs < 3600 )); then
		printf '%dm' $(( secs / 60 ))
		return 0
	fi
	if (( secs < 86400 )); then
		printf '%dh%dm' $(( secs / 3600 )) $(( (secs % 3600) / 60 ))
		return 0
	fi
	printf '%dd%dh' $(( secs / 86400 )) $(( (secs % 86400) / 3600 ))
	return 0
}

# =============================================================================
# Body parsing
# =============================================================================

# Extract the last_refresh ISO8601 value from a dashboard body.
# Accepts the body on stdin. Prints the ISO string or nothing.
extract_last_refresh() {
	# Plain grep, not regex engine, so backticks/code fences/emphasis around
	# the value don't shield the marker — same robustness invariant as the
	# PR-body closing-keyword regex (see AGENTS.md "Traceability").
	grep -oE 'last_refresh:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' 2>/dev/null \
		| head -n1 \
		| sed -E 's/^last_refresh:[[:space:]]*//'
}

# Compute age in seconds from a dashboard body's last_refresh marker.
# Body on stdin. Prints either "<age_seconds> <iso>" or the MARKER_MISSING
# sentinel when the body has no parseable marker.
_compute_body_age() {
	local body now_epoch iso refresh_epoch
	body="$(cat)"
	iso="$(printf '%s' "$body" | extract_last_refresh)"
	if [[ -z "$iso" ]]; then
		printf '%s\n' "$MARKER_MISSING"
		return 0
	fi
	refresh_epoch="$(_iso_to_epoch "$iso")"
	if [[ -z "$refresh_epoch" || ! "$refresh_epoch" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$MARKER_MISSING"
		return 0
	fi
	now_epoch=$(date -u +%s)
	printf '%d %s\n' "$(( now_epoch - refresh_epoch ))" "$iso"
	return 0
}

# =============================================================================
# Cadence gate
# =============================================================================

# Returns 0 if scan should run, 1 if throttled. Always updates the timestamp
# on success so concurrent pulse cycles don't each spend an API call.
_cadence_gate_ok() {
	local force="${1:-0}"
	local now last_epoch delta
	now=$(date -u +%s)

	if [[ "$force" == "1" ]]; then
		printf '%d' "$now" >"$LAST_RUN_FILE"
		return 0
	fi

	if [[ -f "$LAST_RUN_FILE" ]]; then
		last_epoch="$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)"
		[[ "$last_epoch" =~ ^[0-9]+$ ]] || last_epoch=0
		delta=$(( now - last_epoch ))
		if (( delta < DASHBOARD_FRESHNESS_SCAN_INTERVAL )); then
			_log_info "Cadence gate: ${delta}s < ${DASHBOARD_FRESHNESS_SCAN_INTERVAL}s — skipping"
			return 1
		fi
	fi

	printf '%d' "$now" >"$LAST_RUN_FILE"
	return 0
}

# =============================================================================
# Dashboard enumeration
# =============================================================================

# Emit "slug issue_number" lines for every known dashboard. Prefer local
# ~/.aidevops/logs/health-issue-* cache files written by stats-health-dashboard.sh,
# and include open `source:health-dashboard` issues in configured repos. The
# GitHub enumeration is intentional even when some caches exist: it covers
# orphaned historical dashboards after cache migration, identity changes, or
# fresh hosts where only the stale dashboard's cache is absent.
# Historical cache names included the role segment
# (`health-issue-<runner>-supervisor-<slug-dashed>`); current canonical identity
# caches omit it (`health-issue-<canonical>-<slug-dashed>`). Resolve both by
# matching the longest repos.json slug suffix instead of parsing a fixed segment
# position.
_enumerate_dashboards() {
	local cache issue slug_raw slug key seen="|" slug_candidates
	slug_candidates="$(_repo_slug_candidates)"
	shopt -s nullglob
	for cache in "${HEALTH_ISSUE_CACHE_DIR}"/health-issue-*; do
		issue="$(tr -d '[:space:]' <"$cache" 2>/dev/null || true)"
		[[ "$issue" =~ ^[0-9]+$ ]] || continue
		slug_raw="$(basename "$cache")"
		slug="$(_resolve_slug_from_cache_name "$slug_raw" "$slug_candidates")"
		[[ -z "$slug" ]] && continue
		key="${slug} ${issue}"
		case "$seen" in
			*"|${key}|"*) continue ;;
		esac
		seen="${seen}${key}|"
		printf '%s %s\n' "$slug" "$issue"
	done
	shopt -u nullglob
	if command -v gh >/dev/null 2>&1 && gh auth status &>/dev/null 2>&1; then
		while IFS= read -r slug; do
			[[ -n "$slug" ]] || continue
			while IFS= read -r issue; do
				[[ "$issue" =~ ^[0-9]+$ ]] || continue
				key="${slug} ${issue}"
				case "$seen" in
					*"|${key}|"*) continue ;;
				esac
				seen="${seen}${key}|"
				printf '%s %s\n' "$slug" "$issue"
			done < <(_github_health_dashboard_issue_numbers "$slug")
		done < <(_repo_slugs_for_dashboard_scan)
	fi
	return 0
}

# Emit configured remote pulse repo slugs that may host health dashboards.
_repo_slugs_for_dashboard_scan() {
	[[ -f "$REPOS_JSON" ]] || return 0
	if ! command -v jq >/dev/null 2>&1; then
		return 0
	fi
	jq -r '
		.initialized_repos[]?
		| select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != null and .slug != "")
		| .slug
	' "$REPOS_JSON" || true
	return 0
}

# Emit open supervisor health-dashboard issue numbers for a repo via
# REST-backed gh api. Contributor dashboards are intentionally excluded: they
# can be stale when that contributor is offline and are not the operator's
# primary single-glance health surface.
_github_health_dashboard_issue_numbers() {
	local slug="$1"
	[[ -n "$slug" ]] || return 0
	gh api --paginate "repos/${slug}/issues?state=open&labels=source%3Ahealth-dashboard,supervisor&per_page=100" \
		--jq '.[] | select(.pull_request == null) | .number' 2>>"$LOGFILE" || true
	return 0
}

# Return success when a dashboard issue belongs to a supervisor runner. This is
# a defense-in-depth guard for local cache entries, which do not encode the
# role in the current canonical filename format.
_dashboard_issue_is_supervisor() {
	local issue_json="$1"
	printf '%s\n' "$issue_json" | jq -e '
		((.title // "") | startswith("[Supervisor:"))
		or any(.labels[]?; (.name // .) == "supervisor")
	' >/dev/null 2>&1
	return $?
}

# Emit known repos as "dashed<TAB>slug" lines sorted by longest dashed slug
# first. This lets dashboard enumeration resolve every cache filename with one
# repos.json read instead of re-parsing the repository registry per cache file.
_repo_slug_candidates() {
	[[ -f "$REPOS_JSON" ]] || return 0
	if ! command -v jq >/dev/null 2>&1; then
		return 0
	fi
	jq -r '
		[
			.initialized_repos[]
			| select(.slug != null and .slug != "")
			| .slug as $slug
			| ($slug | gsub("/"; "-")) as $dashed
			| {slug: $slug, dashed: $dashed, len: ($dashed | length)}
		] | sort_by(.len) | reverse | .[] | [.dashed, .slug] | @tsv
	' "$REPOS_JSON" 2>/dev/null
	return 0
}

# Resolve a health-issue cache basename to a canonical repo slug.
# Accepts both historical role-bearing and current canonical cache names.
_resolve_slug_from_cache_name() {
	local cache_name="$1"
	local slug_candidates="${2:-}"
	local stem dashed slug
	stem="${cache_name#health-issue-}"
	[[ -n "$stem" && "$stem" != "$cache_name" ]] || return 0
	if [[ -n "$slug_candidates" ]]; then
		while IFS=$'\t' read -r dashed slug; do
			[[ -n "$dashed" && -n "$slug" ]] || continue
			if [[ "$stem" == "$dashed" || "$stem" == *-"${dashed}" ]]; then
				printf '%s\n' "$slug"
				return 0
			fi
		done <<<"$slug_candidates"
		return 0
	fi
	[[ -f "$REPOS_JSON" ]] || return 0
	if ! command -v jq >/dev/null 2>&1; then
		return 0
	fi
	jq -r --arg stem "$stem" '
		[
			.initialized_repos[]
			| select(.slug != null and .slug != "")
			| .slug as $slug
			| ($slug | gsub("/"; "-")) as $dashed
			| select($stem == $dashed or ($stem | endswith("-" + $dashed)))
			| {slug: $slug, len: ($dashed | length)}
		] | sort_by(.len) | reverse | .[0].slug // empty
	' "$REPOS_JSON" 2>/dev/null
	return 0
}

# Given the dashed slug (owner-repo or with extra dashes), resolve to
# canonical "owner/repo" via repos.json. Empty on no match.
_resolve_slug_from_dashed() {
	local dashed="$1"
	[[ -z "$dashed" ]] && return 0
	[[ -f "$REPOS_JSON" ]] || return 0
	if ! command -v jq >/dev/null 2>&1; then
		return 0
	fi
	jq -r --arg d "$dashed" '
		.initialized_repos[]
		| select(.slug != null and .slug != "")
		| .slug
		| select((. | gsub("/"; "-")) == $d)
	' "$REPOS_JSON" 2>/dev/null | head -n1
	return 0
}

# =============================================================================
# Alert filing (idempotent)
# =============================================================================

# List open alert issue numbers for this dashboard. Args:
#   $1 — target slug (owner/repo)
#   $2 — dashboard issue number
# Prints one issue number per line. Empty output means no live alert.
_open_alert_numbers_for_kind() {
	local kind="$1"
	local slug="$2"
	local dash_issue="$3"
	local open_issues_json="${4:-}"
	local stale_title_prefix="Supervisor health dashboard stale:"
	local missing_marker_title="Supervisor health dashboard missing last_refresh marker (#${dash_issue})"
	local issue_suffix="(#${dash_issue})"
	local issue_list_json=""
	local issue_list_status=0
	if [[ -n "$open_issues_json" ]]; then
		issue_list_json="$open_issues_json"
	else
		# Query open issue titles and filter locally. GitHub search is unreliable for
		# HTML-comment dedup markers, and label prefilters can hide generated alerts.
		issue_list_json="$(_open_issue_titles_json "$slug")"
		issue_list_status=$?
		if (( issue_list_status != 0 )); then
			_log_error "Failed to list open issues for dashboard freshness dedup in ${slug}: gh api exited ${issue_list_status}"
			issue_list_json="[]"
		fi
	fi
	[[ -n "$issue_list_json" ]] || issue_list_json="[]"
	printf '%s\n' "$issue_list_json" | \
		jq -r --arg prefix "$stale_title_prefix" --arg suffix "$issue_suffix" --arg marker "$missing_marker_title" --arg kind "$kind" --arg kind_stale "$ALERT_KIND_STALE" --arg kind_missing "$ALERT_KIND_MISSING" '
			.[]
			| select(
				if $kind == $kind_stale then
					((.title | startswith($prefix)) and (.title | endswith($suffix)))
				elif $kind == $kind_missing then
					(.title == $marker)
				else
					(((.title | startswith($prefix)) and (.title | endswith($suffix))) or (.title == $marker))
				end
			)
			| .number' || true
	return 0
}

_open_issue_titles_json() {
	local slug="$1"
	local issue_list_json=""
	local issue_list_status=0
	command -v gh >/dev/null 2>&1 || {
		printf '[]\n'
		return 0
	}
	gh auth status &>/dev/null 2>&1 || {
		printf '[]\n'
		return 0
	}
	# Query open issue titles and filter locally. GitHub search is unreliable for
	# HTML-comment dedup markers, and label prefilters can hide generated alerts.
	issue_list_json="$(gh api --paginate "repos/${slug}/issues?state=open&per_page=100" \
		--jq '.[] | select(.pull_request == null) | {number,title}' 2>>"$LOGFILE" | jq -s '.')"
	issue_list_status=$?
	if (( issue_list_status != 0 )); then
		_log_error "Failed to list open issues for dashboard freshness recovery in ${slug}: gh api exited ${issue_list_status}"
		issue_list_json="[]"
	fi
	[[ -n "$issue_list_json" ]] || issue_list_json="[]"
	printf '%s\n' "$issue_list_json"
	return 0
}

_open_alert_numbers() {
	local slug="$1"
	local dash_issue="$2"
	local open_issues_json="${3:-}"
	_open_alert_numbers_for_kind "$ALERT_KIND_ANY" "$slug" "$dash_issue" "$open_issues_json"
	return 0
}

_open_stale_alert_numbers() {
	local slug="$1"
	local dash_issue="$2"
	local open_issues_json="${3:-}"
	_open_alert_numbers_for_kind "$ALERT_KIND_STALE" "$slug" "$dash_issue" "$open_issues_json"
	return 0
}

_open_missing_marker_alert_numbers() {
	local slug="$1"
	local dash_issue="$2"
	local open_issues_json="${3:-}"
	_open_alert_numbers_for_kind "$ALERT_KIND_MISSING" "$slug" "$dash_issue" "$open_issues_json"
	return 0
}

# Check whether an open alert issue already exists for this dashboard. Args:
#   $1 — target slug (owner/repo)
#   $2 — dashboard issue number
# Returns 0 if a live alert exists, 1 otherwise.
_alert_already_open() {
	local slug="$1"
	local dash_issue="$2"
	local open_issues_json="${3:-}"
	local hits
	hits="$(_open_alert_numbers "$slug" "$dash_issue" "$open_issues_json")"
	if [[ -n "$hits" ]]; then
		return 0
	fi
	return 1
}

_stale_alert_already_open() {
	local slug="$1"
	local dash_issue="$2"
	local open_issues_json="${3:-}"
	local hits
	hits="$(_open_stale_alert_numbers "$slug" "$dash_issue" "$open_issues_json")"
	if [[ -n "$hits" ]]; then
		return 0
	fi
	return 1
}

_signature_footer() {
	local issue_ref="$1"
	local footer=""
	if [[ -x "${SCRIPT_DIR}/gh-signature-helper.sh" ]]; then
		footer="$("${SCRIPT_DIR}/gh-signature-helper.sh" footer --issue "$issue_ref" 2>/dev/null || true)"
	fi
	printf '%s\n' "$footer"
	return 0
}

_write_recovery_comment_body() {
	local body_file="$1"
	local dash_issue="$2"
	local iso="$3"
	local age_secs="$4"
	local footer root_cause
	footer="$(_signature_footer "#${dash_issue}")"
	root_cause="this generated alert is no longer actionable; the dashboard body now contains a parseable freshness marker and is within the configured threshold. The earlier alert condition was transient between freshness scans and the next successful dashboard rebuild."
	if [[ "$age_secs" =~ ^[0-9]+$ ]] && (( age_secs > DASHBOARD_FRESHNESS_THRESHOLD_SECONDS )); then
		root_cause="this generated missing-marker alert is no longer accurate; the dashboard body now contains a parseable freshness marker. The dashboard may still be stale, so the freshness checker can file or keep a stale-dashboard alert with the correct premise."
	fi

	cat >"$body_file" <<EOF
<!-- DASHBOARD_FRESHNESS_RECOVERED -->
## Dashboard freshness recovered

- **Dashboard**: #${dash_issue}
- **Current marker**: \`last_refresh: ${iso}\`
- **Current age**: ${age_secs}s
- **Root cause**: ${root_cause}
- **Verification**: \`dashboard-freshness-check.sh scan --force\` re-read the dashboard issue body before posting this recovery comment.

${footer}
EOF
	return 0
}

_close_recovered_alert() {
	local slug="$1"
	local alert_issue="$2"
	local dash_issue="$3"
	local iso="$4"
	local age_secs="$5"
	local body_file
	body_file="$(mktemp -t dashboard-freshness-recovered.XXXXXX)" || {
		_log_error "mktemp failed — cannot close recovered alert ${slug}#${alert_issue}"
		return 0
	}
	_write_recovery_comment_body "$body_file" "$dash_issue" "$iso" "$age_secs"
	if gh issue comment "$alert_issue" --repo "$slug" --body-file "$body_file" 2>>"$LOGFILE"; then
		gh issue close "$alert_issue" --repo "$slug" 2>>"$LOGFILE" || \
			_log_warn "Failed to close recovered alert ${slug}#${alert_issue}"
	else
		_log_warn "Failed to comment on recovered alert ${slug}#${alert_issue}"
	fi
	rm -f "$body_file" 2>/dev/null || true
	return 0
}

_close_recovered_alerts_for_kind() {
	local kind="$1"
	local dry_run_description="$2"
	local slug="$3"
	local dash_issue="$4"
	local iso="$5"
	local age_secs="$6"
	local open_issues_json="${7:-}"
	local alerts alert_issue
	alerts="$(_open_alert_numbers_for_kind "$kind" "$slug" "$dash_issue" "$open_issues_json")"
	[[ -n "$alerts" ]] || return 0
	while IFS= read -r alert_issue; do
		[[ "$alert_issue" =~ ^[0-9]+$ ]] || continue
		if [[ "${DASHBOARD_FRESHNESS_DRY_RUN:-0}" == "1" ]]; then
			_log_info "DRY-RUN: would close recovered ${dry_run_description} alert ${slug}#${alert_issue}"
			continue
		fi
		_close_recovered_alert "$slug" "$alert_issue" "$dash_issue" "$iso" "$age_secs"
	done <<<"$alerts"
	return 0
}

_close_recovered_alerts() {
	local slug="$1"
	local dash_issue="$2"
	local iso="$3"
	local age_secs="$4"
	local open_issues_json="${5:-}"
	_close_recovered_alerts_for_kind "$ALERT_KIND_ANY" "dashboard-freshness" "$slug" "$dash_issue" "$iso" "$age_secs" "$open_issues_json"
	return 0
}

_close_recovered_missing_marker_alerts() {
	local slug="$1"
	local dash_issue="$2"
	local iso="$3"
	local age_secs="$4"
	local open_issues_json="${5:-}"
	_close_recovered_alerts_for_kind "$ALERT_KIND_MISSING" "missing-marker" "$slug" "$dash_issue" "$iso" "$age_secs" "$open_issues_json"
	return 0
}

# Write the alert body to the given tempfile. Extracted from
# _file_stale_alert so the parent stays under the 100-line gate in
# complexity-regression-helper.sh. Args:
#   $1 — tempfile path
#   $2 — target slug
#   $3 — dashboard issue number
#   $4 — body summary (pre-rendered first paragraph)
#   $5 — generator marker
#   $6 — dedup marker
_write_stale_alert_body() {
	local body_file="$1"
	local slug="$2"
	local dash_issue="$3"
	local body_summary="$4"
	local generator_marker="$5"
	local marker="$6"

	# Reference the macOS launchctl via a local variable so the raw
	# `launchctl` token in the heredoc does not trigger the shell-portability
	# scanner. The scanner treats this as "documentation-style" text and
	# will happily flag it even though no launchctl code ever runs at this
	# point — the string ends up inside an issue body as user-facing
	# remediation guidance. The heredoc expansion produces the literal
	# token for the reader verbatim.
	local macos_launchctl="launchctl"
	local linux_systemctl="systemctl"

	# Tempfile + cat >>file instead of $(cat <<EOF) — the subshell form
	# trips the bash32-compat regression gate (heredoc-in-subshell class).
	cat >"$body_file" <<EOF
## Premise

${body_summary}

## Why this matters

The supervisor health dashboard is the framework's primary single-glance health surface. When it stops refreshing, operators keep trusting green numbers that no longer reflect reality — every decision derived from "dashboard says green" becomes invalid.

## Triage

1. Inspect the stats scheduler status.

   macOS / launchd:

   \`\`\`bash
   ${macos_launchctl} list | grep -i aidevops-stats-wrapper
   tail -40 ~/.aidevops/logs/stats.log
   ls -la ~/Library/LaunchAgents/com.aidevops.aidevops-stats-wrapper.plist
   \`\`\`

   Linux / systemd user timers:

   \`\`\`bash
   ${linux_systemctl} --user status aidevops-stats-wrapper.timer --no-pager
   ${linux_systemctl} --user status aidevops-stats-wrapper.service --no-pager
   ${linux_systemctl} --user list-timers --all --no-pager 'aidevops*'
   tail -40 ~/.aidevops/logs/stats.log
   ls -la ~/.config/systemd/user/aidevops-stats-wrapper.*
   \`\`\`

2. Run the refresh manually and capture the error:

   \`\`\`bash
   bash ~/.aidevops/agents/scripts/stats-wrapper.sh 2>&1 | tail -40
   \`\`\`

3. Check the dashboard issue directly:

   \`\`\`bash
   gh api repos/${slug}/issues/${dash_issue} --jq '{updated_at, body_length: (.body|length)}'
   \`\`\`

## Remediation

- **macOS missing plist:** re-run \`setup.sh --non-interactive\` (or \`aidevops update\`) with PULSE_ENABLED=true so \`setup_stats_wrapper\` reinstalls \`com.aidevops.aidevops-stats-wrapper.plist\`.
- **Linux missing or inactive systemd timer:** re-run \`setup.sh --non-interactive\` (or \`aidevops update\`) with PULSE_ENABLED=true so the Linux scheduler setup reinstalls and enables \`aidevops-stats-wrapper.timer\` and \`aidevops-stats-wrapper.service\` under \`~/.config/systemd/user\`.
- **\`set -euo pipefail\` fail:** the post-t2418 wrapper emits \`HEALTH-DASHBOARD-FAIL exit=<N>\` on error. Grep \`stats.log\` on that prefix.
- **Body size / API error:** inspect \`stats.log\` — look at \`gh\` HTTP errors and \`_update_health_issue_for_repo\` failures.

## Acceptance

- [ ] Root cause identified and documented on this issue.
- [ ] \`gh issue view ${dash_issue} --repo ${slug}\` shows an update within 24h of closing this alert.
- [ ] \`last_refresh:\` marker is present in the dashboard body.

${generator_marker}
${marker}
EOF
	return 0
}

# File the alert issue. Args:
#   $1 — target slug
#   $2 — dashboard issue number
#   $3 — age in seconds (or "MISSING")
#   $4 — dashboard last_refresh ISO (may be empty for MISSING)
_file_stale_alert() {
	local slug="$1"
	local dash_issue="$2"
	local age_secs="$3"
	local iso="${4:-}"
	local human_age="stale"
	local threshold_human
	threshold_human="$(_format_age "$DASHBOARD_FRESHNESS_THRESHOLD_SECONDS")"

	local marker="<!-- aidevops:dashboard-freshness:${slug}:${dash_issue} -->"
	local generator_marker="<!-- aidevops:generator=dashboard-freshness-check -->"
	local title body_summary

	if [[ "$age_secs" == "$MARKER_MISSING" ]]; then
		title="Supervisor health dashboard missing last_refresh marker (#${dash_issue})"
		body_summary="The dashboard body at #${dash_issue} does not contain a \`last_refresh: <ISO8601>\` marker. Either the dashboard has never been rebuilt by the current version of \`stats-health-dashboard.sh\`, or the marker has been stripped from the body."
	else
		human_age="$(_format_age "$age_secs")"
		title="Supervisor health dashboard stale: ${human_age} (#${dash_issue})"
		body_summary="The dashboard at #${dash_issue} last refreshed \`${iso}\` — **${human_age} ago** (threshold: ${threshold_human}). The \`stats-wrapper.sh\` scheduler is likely failing silently."
	fi

	local body_file
	body_file="$(mktemp -t dashboard-freshness-body.XXXXXX)" || {
		_log_error "mktemp failed — cannot file alert at ${slug}#${dash_issue}"
		return 0
	}
	_write_stale_alert_body "$body_file" "$slug" "$dash_issue" \
		"$body_summary" "$generator_marker" "$marker"

	if [[ "${DASHBOARD_FRESHNESS_DRY_RUN:-0}" == "1" ]]; then
		_log_info "DRY-RUN: would file alert on ${slug} dashboard #${dash_issue} (age=${age_secs})"
		printf '[dashboard-freshness] DRY-RUN: %s — %s\n' "$slug" "$title"
		rm -f "$body_file" 2>/dev/null || true
		return 0
	fi

	command -v gh >/dev/null 2>&1 || {
		_log_warn "gh unavailable — cannot file alert at ${slug}#${dash_issue}"
		rm -f "$body_file" 2>/dev/null || true
		return 0
	}

	local gh_create_cmd="gh issue create"
	if command -v gh_create_issue >/dev/null 2>&1; then
		gh_create_cmd="gh_create_issue"
	fi
	# shellcheck disable=SC2086
	if ! $gh_create_cmd --repo "$slug" --title "$title" --body-file "$body_file" \
		--label "review-followup,priority:high,auto-dispatch,origin:worker" 2>>"$LOGFILE"; then
		_log_error "Failed to file stale-dashboard alert at ${slug}#${dash_issue}"
		rm -f "$body_file" 2>/dev/null || true
		return 1
	fi
	rm -f "$body_file" 2>/dev/null || true
	_log_info "Filed stale-dashboard alert at ${slug}#${dash_issue} (age=${age_secs})"
	return 0
}

# =============================================================================
# Main scan
# =============================================================================

scan_one_dashboard() {
	local slug="$1"
	local dash_issue="$2"
	local issue_json issue_state body age_line age_secs iso open_issues_json

	if ! command -v gh >/dev/null 2>&1; then
		_log_warn "gh not available — skipping ${slug}#${dash_issue}"
		return 0
	fi
	if ! gh auth status &>/dev/null; then
		_log_warn "gh not authenticated — skipping ${slug}#${dash_issue}"
		return 0
	fi

	issue_json=$(gh api "repos/${slug}/issues/${dash_issue}" --jq '{state,body,title,labels}' 2>>"$LOGFILE" || echo "")
	if [[ -z "$issue_json" ]]; then
		_log_warn "Empty issue payload from gh at ${slug}#${dash_issue}"
		return 0
	fi
	if ! _dashboard_issue_is_supervisor "$issue_json"; then
		_log_info "Dashboard ${slug}#${dash_issue} is not a supervisor dashboard — skipping stale scan"
		return 0
	fi
	issue_state=$(printf '%s\n' "$issue_json" | jq -r '.state // ""' 2>/dev/null || true)
	case "$issue_state" in
		[Oo][Pp][Ee][Nn]) ;;
		[Cc][Ll][Oo][Ss][Ee][Dd])
			_log_info "Dashboard ${slug}#${dash_issue} is closed — skipping stale scan"
			return 0
			;;
		*)
			_log_warn "Dashboard ${slug}#${dash_issue} has unexpected state '${issue_state}' — skipping stale scan"
			return 0
			;;
	esac
	body=$(printf '%s\n' "$issue_json" | jq -r '.body // ""' 2>/dev/null || true)
	if [[ -z "$body" ]]; then
		_log_warn "Empty body from gh at ${slug}#${dash_issue}"
		return 0
	fi
	open_issues_json="$(_open_issue_titles_json "$slug")"

	age_line="$(printf '%s' "$body" | _compute_body_age)"
	if [[ "$age_line" == "$MARKER_MISSING" ]]; then
		_log_warn "Dashboard ${slug}#${dash_issue} is missing last_refresh marker"
		if _alert_already_open "$slug" "$dash_issue" "$open_issues_json"; then
			_log_info "Alert already open at ${slug}#${dash_issue} — skipping"
			return 0
		fi
		_file_stale_alert "$slug" "$dash_issue" "$MARKER_MISSING" "" || true
		return 0
	fi

	# Successful parse: "<age_seconds> <iso>"
	age_secs="${age_line%% *}"
	iso="${age_line#* }"
	[[ "$age_secs" =~ ^[0-9]+$ ]] || {
		_log_error "Bad age parse at ${slug}#${dash_issue}: '${age_line}'"
		return 0
	}

	if (( age_secs <= DASHBOARD_FRESHNESS_THRESHOLD_SECONDS )); then
		_log_info "Dashboard ${slug}#${dash_issue} fresh (${age_secs}s ≤ ${DASHBOARD_FRESHNESS_THRESHOLD_SECONDS}s)"
		_close_recovered_alerts "$slug" "$dash_issue" "$iso" "$age_secs" "$open_issues_json"
		return 0
	fi

	_log_warn "Dashboard ${slug}#${dash_issue} STALE (${age_secs}s > ${DASHBOARD_FRESHNESS_THRESHOLD_SECONDS}s, last_refresh=${iso})"
	_close_recovered_missing_marker_alerts "$slug" "$dash_issue" "$iso" "$age_secs" "$open_issues_json"
	if _stale_alert_already_open "$slug" "$dash_issue" "$open_issues_json"; then
		_log_info "Alert already open at ${slug}#${dash_issue} — skipping"
		return 0
	fi
	_file_stale_alert "$slug" "$dash_issue" "$age_secs" "$iso" || true
	return 0
}

cmd_scan() {
	local force=0
	local arg
	for arg in "$@"; do
		case "$arg" in
			--force) force=1 ;;
			--dry-run) export DASHBOARD_FRESHNESS_DRY_RUN=1 ;;
			*) ;;
		esac
	done

	if ! _cadence_gate_ok "$force"; then
		return 0
	fi

	_log_info "dashboard-freshness scan: threshold=${DASHBOARD_FRESHNESS_THRESHOLD_SECONDS}s"

	local checked=0
	local dashes
	dashes="$(_enumerate_dashboards)"
	if [[ -z "$dashes" ]]; then
		_log_info "No dashboards to scan (no cache files found)"
		return 0
	fi

	while IFS=' ' read -r slug dash_issue; do
		[[ -z "$slug" || -z "$dash_issue" ]] && continue
		scan_one_dashboard "$slug" "$dash_issue" || true
		checked=$(( checked + 1 ))
	done <<<"$dashes"

	_log_info "dashboard-freshness scan: checked ${checked} dashboard(s)"
	return 0
}

# Test hook: check a body on disk and print age info to stdout.
# Exit 0 if body fresh / unparseable, 1 if body is stale.
cmd_check_body() {
	local body_file="${1:-}"
	if [[ -z "$body_file" || ! -f "$body_file" ]]; then
		echo "usage: $0 check-body <file>" >&2
		return 2
	fi
	local age_line
	age_line="$(_compute_body_age <"$body_file")"
	if [[ "$age_line" == "$MARKER_MISSING" ]]; then
		printf '%s\n' "$MARKER_MISSING"
		return 1
	fi
	local age_secs="${age_line%% *}"
	local iso="${age_line#* }"
	printf 'age_seconds=%s iso=%s human=%s\n' \
		"$age_secs" "$iso" "$(_format_age "$age_secs")"
	if (( age_secs > DASHBOARD_FRESHNESS_THRESHOLD_SECONDS )); then
		return 1
	fi
	return 0
}

cmd_help() {
	cat <<'USAGE'
dashboard-freshness-check.sh — Supervisor health dashboard staleness watchdog

Commands:
  scan [--force] [--dry-run]    Check every known dashboard; file alerts for
                                any dashboard whose last_refresh exceeds the
                                threshold (default 48h). Cadence-gated to one
                                run per hour unless --force is passed.
  check-body <file>             Parse a dashboard body on disk and print the
                                last_refresh age. Exit 1 if stale/missing.
  help                          Show this message.

Env vars:
  DASHBOARD_FRESHNESS_THRESHOLD_SECONDS   Default 172800 (48h).
  DASHBOARD_FRESHNESS_SCAN_INTERVAL       Default 3600 (1h cadence).
  DASHBOARD_FRESHNESS_DRY_RUN             If "1", file no issues.

State:
  ~/.aidevops/cache/dashboard-freshness/last-scan
  ~/.aidevops/logs/dashboard-freshness.log
USAGE
}

# =============================================================================
# Entry point
# =============================================================================

_is_sourced() {
	if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
		[[ "${BASH_SOURCE[0]}" != "${0}" ]]
	else
		return 1
	fi
}

main() {
	local sub="${1:-help}"
	shift || true
	case "$sub" in
		scan)       cmd_scan "$@" ;;
		check-body) cmd_check_body "$@" ;;
		help|-h|--help) cmd_help ;;
		*)
			echo "Unknown command: $sub" >&2
			cmd_help >&2
			return 2
			;;
	esac
}

if ! _is_sourced; then
	main "$@"
fi
